module c3flac;
import std::io;
import flac;

fn int main(String[] args)
{
	FlacDecoder f = flac::open(tmem, args[1])!!;
	defer (void)f.close();

	//UIntBE format_spec = {io::read_be_uint(&audio_file)!!};
	//assert(format_spec == (UIntBE){'fLaC'}); // 0x664C6143
	return 0;
}

module flac;
import std::io;

faultdef NON_AUDIO_FLAC_UNSUPPORTED, UNSUPPORTED_METADATA_TYPE, BAD_FLAC, BAD_FLAC_MAGIC;//, BAD_FLAC_METADATA_HEADER;

struct FlacDecoder (InStream)
{
	Allocator alloc;
	File* file; // TODO: support reading from any InStream?
	FlacStreamInfo flac_info;
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
	//flac_info.min_block_size = (info_bytes[0] << 16u) | (info_bytes[1] << 8u) | info_bytes[2];

	io::printn(flac_info);

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
				sz num_seek_points = header.size / SEEK_POINT_SIZE;
				log::warn("TODO: handle seek tables");
				nextcase PADDING;
			default:
			case STREAM_INFO:
			case FORBIDDEN: return BAD_FLAC~;
		}
	}
	/*io::read_any(&flac_file, &flac_info) ?? BAD_FLAC~!;
	io::printn(flac_info);
	io::printfn("%s %s", flac_info.min_frame_size, flac_info.max_frame_size);*/
	/*flac_info.min_block_size = io::read_be_ushort(&flac_file) ?? BAD_FLAC~;
	flac_info.max_block_size = io::read_be_ushort(&flac_file) ?? BAD_FLAC~;
	flac_info.min_block_size = io::read_be_ushort(&flac_file) ?? BAD_FLAC~;
*/
	//decoder.flac_info = flac_info;

	/*io::read_be_uint(&flac_file)!!;
	io::read_be_uint(&flac_file)!!;
	char hi_byte =  flac_file.read_byte()!!;
	char mid_byte = flac_file.read_byte()!!;
	char lo_byte =  flac_file.read_byte()!!;
	io::printn((hi_byte << 16) | (mid_byte << 8) | lo_byte);*/

	return decoder;
}

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

constdef FlacMetadataHeaderType : char
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

bitstruct FlacMetadataHeader : uint @bigendian @private
{
	bool last : 31;
	FlacMetadataHeaderType type : 24..30;
	uint size : 0..23;
}

//$assert FlacStreamInfo::size == 34;
/*struct FlacStreamInfo @packed// : char[34] @private
{
	UShortBE  min_block_size/*  : 0..15*/;    // measured in samples, MUST be in the range 16-65535. All frames but the last MUST be >= min_block_size, all MUST be <= max_block_size
	UShortBE  max_block_size/*  : 16..31*/;   // ^
	union @packed
	{
		bitstruct : ulong @bigendian
		{
			uint min_frame_size : 0..23;
			uint max_frame_size : 24..47;
		}
		struct @packed
		{
			char[6] _padding0;
			//bitstruct : 
		}
	}
	/*UIntBE    min_frame_size  : 32..55;   // measured in bytes, 0 means not known.
	UIntBE    max_frame_size  : 56..79;   // ^*/
	UIntBE    sample_rate     /*: 80..99*/;   // in Hz. MUST not be 0 when the flac contains audio, but MAY be 0 when containing non-audio data.
	char      num_channels    /*: 100..102*/; // number of channels minus 1, 1 to 8 channels are supported.
	char      bits_per_sample /*: 103..107*/; // bits per sample minus 1, 4 to 32 bits are supported.
	ULongBE   total_samples   /*: 108..143*/; // number of interchannel samples in stream, 0 means not known.
	UInt128BE md5_checksum    /*: 144..271*/; // checksum of unencoded audio, 0 means not known.
}*/

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

/*bitstruct FlacStreamInfo : char[34] @bigendian @private
{
	ushort  min_block_size  : 0..15;    // measured in samples, MUST be in the range 16-65535. All frames but the last MUST be >= min_block_size, all MUST be <= max_block_size
	ushort  max_block_size  : 16..31;   // ^
	uint    min_frame_size  : 32..55;   // measured in bytes, 0 means not known.
	uint    max_frame_size  : 56..79;   // ^
	uint    sample_rate     : 80..99;   // in Hz. MUST not be 0 when the flac contains audio, but MAY be 0 when containing non-audio data.
	char      num_channels    : 100..102; // number of channels minus 1, 1 to 8 channels are supported.
	char      bits_per_sample : 103..107; // bits per sample minus 1, 4 to 32 bits are supported.
	ulong   total_samples   : 108..143; // number of interchannel samples in stream, 0 means not known.
	uint128 md5_checksum    : 144..271; // checksum of unencoded audio, 0 means not known.
}*/
