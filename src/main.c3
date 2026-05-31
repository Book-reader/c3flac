module c3flac;
import std::io;
import flac;

fn int main(String[] args)
{
	FlacDecoder f = flac::open(tmem, args[1])!!;
	defer (void)f.close();

	//char[1024] buf;
	//f.read(&buf)!!;

	//UIntBE format_spec = {io::read_be_uint(&audio_file)!!};
	//assert(format_spec == (UIntBE){'fLaC'}); // 0x664C6143
	return 0;
}

module flac;
import std::io;
import std::math;

faultdef NON_AUDIO_FLAC_UNSUPPORTED, UNSUPPORTED_METADATA_TYPE, BAD_FLAC, BAD_FLAC_MAGIC;//, BAD_FLAC_METADATA_HEADER;

enum TriBool : char {UNKNOWN, FALSE, TRUE}

struct FlacDecoder (InStream)
{
	Allocator alloc;
	File* file; // TODO: support reading from any InStream?
	FlacStreamInfo flac_info;
	SeekPoint[] seek_points;
	bool variable_block_size;
	long prev_frame_number;
}

fn FlacDecoder? open(Allocator alloc, String file)
{
	io::printn(file);
	File flac_file = file::open(file, "rb")!;

	uint magic = io::read_be_uint(&flac_file) ?? BAD_FLAC~!;
	if (magic != 'fLaC') return BAD_FLAC_MAGIC~;

	FlacDecoder decoder;
	decoder.alloc = alloc;
	decoder.file = alloc::clone(alloc, flac_file);

	const STREAM_INFO_SIZE = 34;
	FlacMetadataHeader header;
	io::read_any(decoder.file, &header) ?? BAD_FLAC~!;
	if (header.type != STREAM_INFO || header.size != STREAM_INFO_SIZE) return BAD_FLAC~;

	char[STREAM_INFO_SIZE] info_bytes;
	io::read_all(decoder.file, &info_bytes) ?? BAD_FLAC~!;

	// https://www.rfc-editor.org/rfc/rfc9639.html#name-streaminfo
	FlacStreamInfo flac_info;
	flac_info.min_block_size         = bitorder::read(info_bytes[:2], UShortBE);//(info_bytes[0] << 8u) | info_bytes[1];
	flac_info.max_block_size         = bitorder::read(info_bytes[2:2], UShortBE);//(info_bytes[2] << 8u) | info_bytes[3];
	flac_info.min_frame_size         = (info_bytes[4] << 16u) | (info_bytes[5] << 8u) | info_bytes[6];
	flac_info.max_frame_size         = (info_bytes[7] << 16u) | (info_bytes[8] << 8u) | info_bytes[9];
	flac_info.sample_rate            = (info_bytes[10] << 12u) | (info_bytes[11] << 4u) | (info_bytes[12] >> 4u);
	flac_info.num_channels           = (info_bytes[12] >> 1u) & 0x03 + 1;
	flac_info.bits_per_sample        = ((info_bytes[12] & 0x01) << 4u) | (info_bytes[13] >> 4u) + 1;
	flac_info.interchannel_samples   = ((ulong)(info_bytes[13] & 0x0F) << 32ul) | bitorder::read(info_bytes[14:4], UIntBE);// ((ulong)info_bytes[14] << 24ul) | ((ulong)info_bytes[15] << 16ul) | ((ulong)info_bytes[16] << 8ul) | info_bytes[17];
	flac_info.md5_checksum           = bitorder::read(info_bytes[18:16], UInt128BE);

	if (flac_info.sample_rate == 0) return NON_AUDIO_FLAC_UNSUPPORTED~;
	if (flac_info.min_block_size < 16 || flac_info.max_block_size > 65535 || flac_info.min_block_size > flac_info.max_block_size) return BAD_FLAC~;
	if (flac_info.bits_per_sample < 4 || flac_info.bits_per_sample > 32) return BAD_FLAC~;

	decoder.flac_info = flac_info;
	decoder.variable_block_size = flac_info.min_block_size != flac_info.max_block_size;

	io::printn(flac_info);

	bool has_seek_table = false;
	while (!header.last)
	{
		io::read_any(decoder.file, &header) ?? BAD_FLAC~!;
		io::printn(header);
		switch (header.type)
		{
			case PADDING:
			case APPLICATION: // just ignore application metadata headers
			case VORBIS_COMMENT: // ignore vorbis metadata for now (TODO: add an option to read it)
			case CUE_SHEET: // TODO
			case PICTURE: // TODO
				io::skip(decoder.file, header.size) ?? BAD_FLAC~!;
			case SEEK_TABLE:
				const SEEK_POINT_SIZE = 18;
				if (header.size % SEEK_POINT_SIZE != 0) return BAD_FLAC~;
				if (has_seek_table) return BAD_FLAC~; // can only have one seek table
				has_seek_table = true;
				sz num_seek_points = header.size / SEEK_POINT_SIZE;
				SeekPoint[] seek_points = alloc::alloc_array(alloc, SeekPoint, num_seek_points);
				foreach (&seek_point : seek_points)
				{
					seek_point.sample_number = io::read_be_ulong(decoder.file)  ?? BAD_FLAC~!;
					seek_point.offset        = io::read_be_ulong(decoder.file)  ?? BAD_FLAC~!;
					seek_point.num_samples   = io::read_be_ushort(decoder.file) ?? BAD_FLAC~!;
				}
				decoder.seek_points = seek_points;
			default:
			case STREAM_INFO:
			case FORBIDDEN: return BAD_FLAC~;
		}
	}

	decode_frame_header(&decoder)!!;
	//for (int i = 0; i < 20; i++) // find & decode more frame headers
	while (true)
	{
		char prev_byte = decoder.file.read_byte()!!;
		while (true)
		{
			char next_byte = decoder.file.read_byte()!!;
			char third_byte = decoder.file.read_byte()!!;
			char fourth_byte = decoder.file.read_byte()!!;
			decoder.file.seek(-2, FROM_CURSOR)!!;
			if (prev_byte == 0xFF && next_byte == (0xF8 | (char)decoder.variable_block_size) && (third_byte >> 4u) != 0 && fourth_byte & 0x01 == 0) break;
			prev_byte = next_byte;
		}
		decoder.file.seek(-2, FROM_CURSOR)!!; // seek back to the start of the header part
		io::printf("Scanned to what seems to be a frame header, ");
		decode_frame_header(&decoder)!!; // decode the next frame header
	}

	return decoder;
}

const ushort SYNC_CODE @private = 0b111111111111100;
const uint[0xF] SAMPLE_RATE_TABLE =
{
	[0x0] = uint::max,
	[0xC..0xE] = uint::max,
	[0x1] = 88_200,  // 88.2  kHz
	[0x2] = 176_400, // 176.4 kHz
	[0x3] = 192_000, // 192   kHz
	[0x4] = 8_000,   // 8     kHz
	[0x5] = 16_000,  // 16    kHz
	[0x6] = 22_050,  // 22.05 kHz
	[0x7] = 24_000,  // 24    kHz
	[0x8] = 32_000,  // 32    kHz
	[0x9] = 44_100,  // 44.1  kHz
	[0xA] = 48_000,  // 48    kHz
	[0xB] = 96_000,  // 96    kHz
};

fn void? decode_frame_header(FlacDecoder* self) @private
{
	io::printn("Decoding frame header");
	FlacFrameHeaderFirstPart header_part_1;
	io::read_any(self.file, &header_part_1)!;
	//io::printfn("header pt 1 %.32b", ((UIntBE)(uint)header_part_1).val);
	if (@unlikely(header_part_1.sync_code != SYNC_CODE)) return BAD_FLAC~; // TODO: have a feature flag to disable some runtime validity checking.
	if (@unlikely(header_part_1.variable_block_size != self.variable_block_size)) return BAD_FLAC~;
	if (@unlikely(header_part_1.reserved_bit != 0)) return BAD_FLAC~;

	FlacFrameBlockSizeType block_size_type; // if it's uncommon the stored value after the coded value is the real value - 1
	ushort block_size /*@noinit*/; // TODO: add back @noninit when I really care about performance
	switch (char block_size_bits = header_part_1.block_size_bits)
	{
		case 0b0000        : return BAD_FLAC~;
		case 0b0001        : block_size = 192;
		case 0b0010..0b0101: block_size = 144 * (1 << block_size_bits);/*(ushort)math::pow(2, block_size_bits)*/ // TODO: check if this gets constant folded
		case 0b0110        : block_size_type = UNCOMMON_8;
		case 0b0111        : block_size_type = UNCOMMON_16;
		case 0b1000..0b1111: block_size = 1 << block_size_bits;/*(ushort)math::pow(2, block_size_bits)*/ // TODO: same as above
		default            : unreachable();
	}

	FlacFrameSampleRateType sample_rate_type;
	uint sample_rate_hz /*@noinit*/;

	switch (char sample_rate_bits = header_part_1.sample_rate_bits)
	{
		case 0b0000        : sample_rate_type = ONLY_STORED_IN_STREAMINFO;
		case 0b0001..0b1011: sample_rate_hz = SAMPLE_RATE_TABLE[sample_rate_bits];
		case 0b1100        : sample_rate_type = UNCOMMON_KHZ_8;
		case 0b1101        : sample_rate_type = UNCOMMON_HZ_16;
		case 0b1110        : sample_rate_type = UNCOMMON_HZ_16_DIV10;
		case 0b1111        : return BAD_FLAC~;
		default            : unreachable();
	}

	if (header_part_1.channel_bits >= FlacFrameChannels::values.len) return BAD_FLAC~; // reserved values
	FlacFrameChannels channels = FlacFrameChannels::from_ordinal(header_part_1.channel_bits);

	FlacFrameBitDepth bit_depth = FlacFrameBitDepth::from_ordinal(header_part_1.bit_depth_bits);
	if (bit_depth == RESERVED) return BAD_FLAC~;

	if (self.variable_block_size) abort("Handling the coded number with variable block sizes is not implemented yet");
	long frame_number = decode_coded_number(self)!;
	if (frame_number != self.prev_frame_number + 1) return BAD_FLAC~;
	self.prev_frame_number = frame_number;
	io::printfn("frame %s, block size: {%s %s}, sample rate: {%s %s}, channels: %s, bit depth: %s", frame_number, block_size_type, block_size, sample_rate_type, sample_rate_hz, channels, bit_depth);
}

// If it's a fixed block size stream this is a frame number, if it's a variable block size stream this is the sample number of the first sample in the frame
fn long? decode_coded_number(FlacDecoder* self) @private
{
	long coded_number /*@noinit*/ = -1; // -1 temporarily for testing to detect invalid value (max value cannot be over 2^36, 2^31 when encoding a frame number)
	// https://www.rfc-editor.org/rfc/rfc9639.html#section-9.1.5
	switch (long first = self.file.read_byte()!, (char)first)
	{
		case 0x00..0x7F: coded_number = (first & (char)(~0x80)) + 1;
		case 0xC0..0xDF:
			long second = read_coded_tail_byte(self)!;
			coded_number = (((first & 0x1F) << 6) | second) + 1;
		case 0xE0..0xEF:
			long second = read_coded_tail_byte(self)!;
			long third = read_coded_tail_byte(self)!;
			coded_number = (((first & 0x0F) << 12) | (second << 6) | third) + 1;
		case 0xF0..0xF7:
			long second = read_coded_tail_byte(self)!;
			long third = read_coded_tail_byte(self)!;
			long fourth = read_coded_tail_byte(self)!;
			coded_number = (((first & 0x07) << 18) | (second << 12) | (third << 6) | fourth) + 1;
		case 0xF8..0xFB:
			long second = read_coded_tail_byte(self)!;
			long third = read_coded_tail_byte(self)!;
			long fourth = read_coded_tail_byte(self)!;
			long fifth = read_coded_tail_byte(self)!;
			coded_number = (((first & 0x03) << 24) | (second << 18) | (third << 12) | (fourth << 6) | fifth) + 1;
		case 0xFC..0xFD:
			long second = read_coded_tail_byte(self)!;
			long third = read_coded_tail_byte(self)!;
			long fourth = read_coded_tail_byte(self)!;
			long fifth = read_coded_tail_byte(self)!;
			long sixth = read_coded_tail_byte(self)!;
			coded_number = (((first & 1) << 30) | (second << 24) | (third << 18) | (fourth << 12) | (fifth << 6) | sixth) + 1;
		case 0xFE:
			long second = read_coded_tail_byte(self)!;
			long third = read_coded_tail_byte(self)!;
			long fourth = read_coded_tail_byte(self)!;
			long fifth = read_coded_tail_byte(self)!;
			long sixth = read_coded_tail_byte(self)!;
			long seventh = read_coded_tail_byte(self)!;
			coded_number = ((second << 30) | (third << 24) | (fourth << 18) | (fifth << 12) | (sixth << 6) | seventh) + 1;
		default: return BAD_FLAC~;
	}
	return coded_number;
}

fn char? read_coded_tail_byte(FlacDecoder* self) @inline
{
	char b = self.file.read_byte()!;
	if (@unlikely(!is_valid_coded_tail_byte(b))) return BAD_FLAC~;
	return b & (char)~0xC0;
}

macro bool is_valid_coded_tail_byte(char c) @private => c & 0xC0 == 0x80; // byte must start with 0b10

fn void? FlacDecoder.close(&self) @dynamic
{
	defer alloc::free(self.alloc, self.file);
	self.file.close()!;
}

fn sz? FlacDecoder.read(&self, char[] buf) @dynamic
{
	abort("TODO");
}

fn char? FlacDecoder.read_byte(&self) @dynamic
{
	return io::UNSUPPORTED_OPERATION~;
}

constdef FlacMetadataHeaderType : char @private
{
	STREAM_INFO,
	PADDING,
	APPLICATION,
	SEEK_TABLE,
	VORBIS_COMMENT,
	CUE_SHEET,
	PICTURE,
	// 7..126 are reserved
	FORBIDDEN = 127,
}

enum FlacFrameBlockSizeType  : char @private {COMMON, UNCOMMON_8, UNCOMMON_16}
enum FlacFrameSampleRateType : char @private {COMMON, ONLY_STORED_IN_STREAMINFO, UNCOMMON_KHZ_8, UNCOMMON_HZ_16, UNCOMMON_HZ_16_DIV10}
enum FlacFrameChannels    : char @private
{
	MONO,
	STEREO,
	THREE,
	FOUR,
	FIVE,
	SIX,
	SEVEN,
	EIGHT,
	STEREO_LEFT_SIDE,
	STEREO_RIGHT_SIDE,
	STEREO_MID_SIDE,
}
enum FlacFrameBitDepth : char @private
{
	ONLY_STORED_IN_STREAMINFO,
	BPS_8,
	BPS_12,
	RESERVED,
	BPS_16,
	BPS_20,
	BPS_24,
	BPS_32,
}

bitstruct FlacMetadataHeader : uint @bigendian @private
{
	bool last : 31;
	FlacMetadataHeaderType type : 24..30;
	uint size : 0..23;
}

struct FlacStreamInfo @private
{
	ushort  min_block_size;         // measured in samples, MUST be in the range 16-65535. All frames but the last MUST be >= min_block_size, all MUST be <= max_block_size
	ushort  max_block_size;         // ^
	uint    min_frame_size;         // measured in bytes, 0 means not known.
	uint    max_frame_size;         // ^
	uint    sample_rate;            // in Hz. MUST not be 0 when the flac contains audio, but MAY be 0 when containing non-audio data.
	char    num_channels;           // number of channels minus 1, 1 to 8 channels are supported.
	char    bits_per_sample;        // bits per sample minus 1, 4 to 32 bits are supported.
	ulong   interchannel_samples;   // number of interchannel samples in stream, 0 means not known.
	uint128 md5_checksum;           // checksum of unencoded audio, 0 means not known.
}

struct SeekPoint @private
{
	ulong sample_number;
	ulong offset;
	ushort num_samples;
}

bitstruct FlacFrameHeaderFirstPart : uint/*char[4]*/ @bigendian @private
{
	ushort sync_code           : 17..31/*0..14*/;
	bool   variable_block_size : 16/*15*/;
	char   block_size_bits     : 12..15/*16..19*/;
	char   sample_rate_bits    : 8..11/*20..23*/;
	char   channel_bits        : 4..7/*24..27*/;
	char   bit_depth_bits      : 1..3/*28..30*/;
	char   reserved_bit        : 0..0/*31*/; // MUST be 0
}
