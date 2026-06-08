module c3flac;
import std::io;
import flac;

fn int main(String[] args)
{
	/*$if $feature(PLAY_TO_STDOUT):
		log::set_priority_all(CRITICAL);
	$else*/
		log::set_priority_all(DEBUG);
	//$endif
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


faultdef
	NON_AUDIO_FLAC_UNSUPPORTED,
	UNSUPPORTED_METADATA_TYPE,
	BAD_FLAC,
	BAD_FLAC_FRAME_HEADER,
	BAD_FLAC_SUBFRAME_HEADER,
	BAD_CODED_NUMBER,
	BAD_CODED_RESIDUAL,
	BAD_FLAC_MAGIC,
	// BAD_FLAC_METADATA_HEADER,
;

enum TriBool : char {UNKNOWN, FALSE, TRUE}

struct FlacDecoder (InStream)
{
	Allocator alloc;
	File* file; // TODO: support reading from any InStream?
	BitReader bit_reader;
	FlacStreamInfo flac_info;
	//FlacFrame current_frame;
	FlacSeekPoint[] seek_points;
	bool variable_block_size;
	long prev_frame_number;
}

struct FlacFrame (Printable)
{
	long frame_number;
	uint sample_rate;
	ushort block_size;
	ushort frame_crc; // TODO: handle
	FlacFrameChannels channels;
	char bit_depth;
	char header_crc; // TODO: handle
	char decoded_subframes;
	FlacSubframe[] subframes;
}
fn sz? FlacFrame.to_format(&self, Formatter* fmt) @dynamic => io::struct_to_format((FlacFrame){...*self, .subframes = self.subframes[:self.decoded_subframes]}, fmt, false);

struct FlacSubframe (Printable)
{
	FlacSubframeType type;
	char predictor_order;
	char bits_per_sample;
	char wasted_bits;
	int[] samples; // TODO: when I do streaming these won't be all the samples, these will only be the last N samples for the predictor to work with, with constant subframes it will be empty or only the last decoded subframe
}
fn sz? FlacSubframe.to_format(&self, Formatter* fmt) @dynamic => io::struct_to_format(*self, fmt, false);

fn FlacDecoder? open(Allocator alloc, String file)
{
	log::debug(file);
	File flac_file = file::open(file, "rb")!;

	uint magic = io::read_be_uint(&flac_file) ?? BAD_FLAC~!;
	if (magic != 'fLaC') return BAD_FLAC_MAGIC~;

	FlacDecoder decoder;
	decoder.alloc = alloc;
	decoder.file = alloc::clone(alloc, flac_file);
	decoder.bit_reader.init(decoder.file);

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

	log::debug("%s", flac_info);

	bool has_seek_table = false;
	while (!header.last)
	{
		io::read_any(decoder.file, &header) ?? BAD_FLAC~!;
		//log::debug("%s", header);
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
				FlacSeekPoint[] seek_points = alloc::alloc_array(alloc, FlacSeekPoint, num_seek_points);
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

	while (true)
	{
		FlacFrame? frame = decode_frame(&decoder);
		if (catch err = frame)
		{
			if (err != io::UNEXPECTED_EOF) abort("%s %s", err, file);
			return decoder;
		}
		//log::debug("%s", frame.subframes[0]);
		$if $feature(PLAY_TO_STDOUT):
			if (@unlikely(frame.channels.num_channels != 2)) abort("Tried to output audio with a channel count other than 2 (got %s) %s", frame.channels, file);
			if (@unlikely(frame.sample_rate != 44100)) abort("sample rate not 44.1 kHz");
			// used to convert each sample into a 32-bit sample so it can be piped into `aplay -t raw -f S32_LE -c2 -r44100`
			int shift_bits = bitsizeof(int) - frame.bit_depth;
			@each_channel_sample(&frame; int[] channel_samples)
			{
				foreach (sample : channel_samples)
				{
					io::write_le_int(io::stdout(), sample << shift_bits)!!;
				}
			};
		$endif
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

fn FlacFrame? decode_frame(FlacDecoder* flac) @private
{
	FlacFrame frame = decode_frame_header(flac)!;
	switch (frame.channels)
	{
		case MONO:
		case STEREO:
		case THREE:
		case FOUR:
		case FIVE:
		case SIX:
		case SEVEN:
		case EIGHT:
			for (sz i = 0; i < frame.channels.num_channels; i++)
			{
				frame.subframes[frame.decoded_subframes++] = decode_subframe(flac, &frame)!;
			}
		case STEREO_LEFT_SIDE:
			decode_stereo_left_side_frame(flac, &frame)!;
		case STEREO_MID_SIDE:
			decode_stereo_mid_side_frame(flac, &frame)!;
		case STEREO_RIGHT_SIDE:
			decode_stereo_side_right_frame(flac, &frame)!;
	}
	decode_frame_footer(flac, &frame)!;
	return frame;
}

fn void? decode_stereo_mid_side_frame(FlacDecoder* flac, FlacFrame* frame)
{
	FlacSubframe mid_channel = decode_subframe(flac, frame)!;
	FlacSubframe side_channel = decode_subframe(flac, frame, true)!;
	assert(mid_channel.samples.len == side_channel.samples.len && mid_channel.samples.len == frame.block_size);
	for (sz i = 0; i < frame.block_size; i++)
	{
		int mid = mid_channel.samples[i] << 1;
		int side = side_channel.samples[i];
		// if (side % 2 == 1) mid += 1;
		mid += side % 2;
		mid_channel.samples[i] = (mid + side) >> 1; // now the left channel
		side_channel.samples[i] = (mid - side) >> 1; // now the right channel
	}
	frame.subframes[frame.decoded_subframes++] = mid_channel;
	frame.subframes[frame.decoded_subframes++] = side_channel;
}

fn void? decode_stereo_left_side_frame(FlacDecoder* flac, FlacFrame* frame)
{
	FlacSubframe left_channel = decode_subframe(flac, frame)!;
	FlacSubframe side_channel = decode_subframe(flac, frame, true)!;
	assert(left_channel.samples.len == side_channel.samples.len && left_channel.samples.len == frame.block_size);
	for (sz i = 0; i < frame.block_size; i++)
	{
		int left = left_channel.samples[i];
		int side = side_channel.samples[i];
		side_channel.samples[i] = left - side; // now the right channel
	}
	frame.subframes[frame.decoded_subframes++] = left_channel;
	frame.subframes[frame.decoded_subframes++] = side_channel;
}

fn void? decode_stereo_side_right_frame(FlacDecoder* flac, FlacFrame* frame)
{
	FlacSubframe side_channel = decode_subframe(flac, frame, true)!;
	FlacSubframe right_channel = decode_subframe(flac, frame)!;
	assert(right_channel.samples.len == side_channel.samples.len && right_channel.samples.len == frame.block_size);
	for (sz i = 0; i < frame.block_size; i++)
	{
		int side = side_channel.samples[i];
		int right = right_channel.samples[i];
		side_channel.samples[i] = right + side; // now the left channel
	}
	frame.subframes[frame.decoded_subframes++] = side_channel;
	frame.subframes[frame.decoded_subframes++] = right_channel;
}


macro void @each_channel_sample(FlacFrame* frame; @body(int[] channel_samples))
{
	int[FlacFrameChannels.EIGHT.num_channels] vals;

	for (sz i = 0; i < frame.block_size; i++)
	{
		for (sz j = 0; j < frame.channels.num_channels; j++)
		{
			vals[j] = frame.subframes[j].samples[i];
		}
		@body(vals[:frame.channels.num_channels]);
	}
}

// This will always start and end at a byte boundary so the file can be read from directly
fn FlacFrame? decode_frame_header(FlacDecoder* self) @private
{
	self.bit_reader.clear();
	FlacFrame next_frame /*@noinit*/;

	log::debug("Decoding frame header");
	FlacFrameHeaderFirstPart header_part_1;
	io::read_any(self.file, &header_part_1)!;

	if (@unlikely(header_part_1.sync_code != SYNC_CODE)) return BAD_FLAC_FRAME_HEADER~; // TODO: have a feature flag to disable some runtime validity checking.
	if (@unlikely(header_part_1.variable_block_size != self.variable_block_size)) return BAD_FLAC_FRAME_HEADER~;
	if (@unlikely(header_part_1.reserved_bit != 0)) return BAD_FLAC_FRAME_HEADER~;

	FlacFrameBlockSizeType block_size_type; // if it's uncommon the stored value after the coded value is the real value - 1
	switch (char block_size_bits = header_part_1.block_size_bits)
	{
		case 0b0000        : return BAD_FLAC_FRAME_HEADER~;
		case 0b0001        : next_frame.block_size = 192;
		case 0b0010..0b0101: next_frame.block_size = 144 * (1 << block_size_bits);/*(ushort)math::pow(2, block_size_bits)*/ // TODO: check if this gets constant folded
		case 0b0110        : block_size_type = UNCOMMON_8;
		case 0b0111        : block_size_type = UNCOMMON_16;
		case 0b1000..0b1111: next_frame.block_size = 1 << block_size_bits;/*(ushort)math::pow(2, block_size_bits)*/ // TODO: same as above
		default            : unreachable();
	}

	FlacFrameSampleRateType sample_rate_type;

	switch (char sample_rate_bits = header_part_1.sample_rate_bits)
	{
		case 0b0000        : sample_rate_type = ONLY_STORED_IN_STREAMINFO;
		case 0b0001..0b1011: next_frame.sample_rate = SAMPLE_RATE_TABLE[sample_rate_bits];
		case 0b1100        : sample_rate_type = UNCOMMON_KHZ_8;
		case 0b1101        : sample_rate_type = UNCOMMON_HZ_16;
		case 0b1110        : sample_rate_type = UNCOMMON_HZ_16_DIV10;
		case 0b1111        : return BAD_FLAC_FRAME_HEADER~;
		default            : unreachable();
	}

	if (header_part_1.channel_bits >= FlacFrameChannels::values.len) return BAD_FLAC_FRAME_HEADER~; // reserved values
	next_frame.channels = FlacFrameChannels::from_ordinal(header_part_1.channel_bits);

	FlacFrameBitDepth bit_depth = FlacFrameBitDepth::from_ordinal(header_part_1.bit_depth_bits);
	switch (bit_depth)
	{
		case RESERVED:
			return BAD_FLAC_FRAME_HEADER~;
		case ONLY_STORED_IN_STREAMINFO:
			next_frame.bit_depth = self.flac_info.bits_per_sample;
		default:
			next_frame.bit_depth = (char)bit_depth.bit_depth;
	}

	if (self.variable_block_size) abort("TODO: Handling the coded number with variable block sizes is not implemented yet");
	next_frame.frame_number = decode_coded_number(self)!;
	// NOTE: don't rely on these coded numbers for seeking, but do validate them
	// TODO: could I maybe compare against self.current_frame.frame_number instead of using a dedicated prev_frame_number?
	if (next_frame.frame_number != self.prev_frame_number + 1) return BAD_FLAC_FRAME_HEADER~;
	self.prev_frame_number = next_frame.frame_number;

	switch (block_size_type)
	{
		case COMMON: break;
		case UNCOMMON_8: next_frame.block_size = self.file.read_byte()! + 1;
		case UNCOMMON_16:
			ushort block_size = io::read_be_ushort(self.file)!;
			if (block_size == ushort::max) return BAD_FLAC_FRAME_HEADER~;
			next_frame.block_size = block_size + 1;
	}

	switch (sample_rate_type)
	{
		case COMMON: break;
		case ONLY_STORED_IN_STREAMINFO: next_frame.sample_rate = self.flac_info.sample_rate;
		case UNCOMMON_KHZ_8: next_frame.sample_rate = (ushort)self.file.read_byte()! * 1000;
		case UNCOMMON_HZ_16: next_frame.sample_rate = io::read_be_ushort(self.file)!;
		case UNCOMMON_HZ_16_DIV10: next_frame.sample_rate = io::read_be_ushort(self.file)! * 10;
	}

	next_frame.header_crc = self.file.read_byte()!; // TODO: handle?
	next_frame.subframes = alloc::new_array/*alloc_array*/(self.alloc, FlacSubframe, next_frame.channels.num_channels);

	//log::debug("frame %s, block size: {%s %s}, sample rate: {%s %s}, channels: %s, bit depth: %s", frame_number, block_size_type, block_size, sample_rate_type, sample_rate_hz, channels, bit_depth);
	log::debug("%s", next_frame);
	// self.current_frame = next_frame;
	return next_frame;
}

fn FlacSubframe? decode_subframe(FlacDecoder* flac, FlacFrame* frame, bool extra_depth_bit = false) @private
{
	FlacSubframe subframe = decode_subframe_header(flac, frame)!;
	decode_subframe_data(flac, frame, &subframe, extra_depth_bit)!;
	return subframe;
}

// A subframe header is not guaranteed to be byte aligned unless it is the first after a frame header so it needs to use the bit reader
// I need to make sure the bit reader is properly reset after using the regular file reader with something that is guaranteed to be byte aligned so it doesn't re-use old data stored when it was last used
fn FlacSubframe? decode_subframe_header(FlacDecoder* self, FlacFrame* frame) @private
{
	FlacSubframe subframe;
	// TODO: compact these first 3 read_bits calls into a single read_bits(8) call and do the rest of the bit stuff manually, it should improve performance
	if (@unlikely(self.bit_reader.read_bits(1)! != 0)) return BAD_FLAC_SUBFRAME_HEADER~;
	switch (char v = self.bit_reader.read_bits(6)!)
	{
		case 0x00: subframe.type = CONSTANT;
		case 0x01: subframe.type = VERBATIM;
		case 0x0D..0x1F:
		case 0x02..0x07: return BAD_FLAC_SUBFRAME_HEADER~;
		case 0x08..0x0C:
			subframe.type = FIXED_PREDICTOR;
			subframe.predictor_order = v - 8;
		case 0x20..0x3F:
			subframe.type = LINEAR_PREDICTOR;
			subframe.predictor_order = v - 31;
		default: unreachable();
	}

	subframe.bits_per_sample = frame.bit_depth;

	bool has_wasted_bits = self.bit_reader.read_bits(1)! != 0;
	if (has_wasted_bits)
	{
		subframe.wasted_bits = self.bit_reader.read_unary_number(char)! + 1;
		subframe.bits_per_sample -= subframe.wasted_bits;
		if (subframe.wasted_bits >= frame.bit_depth) return BAD_FLAC~;
	}

	log::debug("%s", subframe);
	//if (has_wasted_bits) abort("TODO: wasted bits are not supported yet");
	return subframe;
}

fn void? decode_subframe_data(FlacDecoder* self, FlacFrame* frame, FlacSubframe* subframe, bool extra_depth_bit) @private
{
	switch (subframe.type)
	{
		case CONSTANT:
			// TODO: optimise constant subframes to only store the value once
			/*subframe.samples = alloc::alloc_array(self.alloc, int, 1);
			subframe.samples[0] = decode_subframe_constant_sample(self, frame, subframe)!;*/
			subframe.samples = alloc::alloc_array(self.alloc, int, frame.block_size);
			subframe.samples[..] = decode_subframe_constant_sample(self, frame, subframe, extra_depth_bit)!;
		case VERBATIM:
			subframe.samples = alloc::alloc_array(self.alloc, int, frame.block_size);
			for (sz i = 0; i < subframe.samples.len; i++)
			{
				subframe.samples[i] = decode_subframe_constant_sample(self, frame, subframe, extra_depth_bit)!;
			}
		case FIXED_PREDICTOR:
			subframe.samples = alloc::alloc_array(self.alloc, int, frame.block_size);
			for (sz i = 0; i < subframe.predictor_order; i++)
			{
				subframe.samples[i] = decode_subframe_constant_sample(self, frame, subframe, extra_depth_bit)!;
			}
			FlacCodedResidualState residual;
			residual.init(self, frame, subframe)!;
			for (sz i = subframe.predictor_order; i < subframe.samples.len; i++)
			{
				subframe.samples[i] = residual.next(self)! + get_subframe_fixed_predictor_prediction(self, subframe, i)!;
			}
		case LINEAR_PREDICTOR:
			subframe.samples = alloc::alloc_array(self.alloc, int, frame.block_size);
			for (sz i = 0; i < subframe.predictor_order; i++)
			{
				subframe.samples[i] = decode_subframe_constant_sample(self, frame, subframe, extra_depth_bit)!;
			}
			char coefficient_precision = self.bit_reader.read_bits(4)! + 1;
			log::debug("coefficient_precision: %s %.8b", coefficient_precision, coefficient_precision);
			if (@unlikely(coefficient_precision == (1 << 4))) return BAD_FLAC~;
			char prediction_shift = self.bit_reader.read_bits(5)!;
			if (@unlikely(prediction_shift & 0x10 != 0)) return BAD_FLAC~; // if the fifth bit is set it's attempting to do a negative shift, which isn't allowed (see Appendix B.4)
			log::debug("prediction_shift: %s %.5b", prediction_shift, prediction_shift);
			short[32] coefficients /*@noinit*/;
			for (sz i = 0; i < subframe.predictor_order; i++)
			{
				ushort val = (ushort)self.bit_reader.read_more_bits(coefficient_precision)!;
				log::debug("%.4b", val);
				int shift_bits = bitsizeof(short) - coefficient_precision;
				coefficients[i] = (short)(val << shift_bits) >> shift_bits; // sign extend
			}
			FlacCodedResidualState residual;
			residual.init(self, frame, subframe)!;
			for (sz i = subframe.predictor_order; i < subframe.samples.len; i++)
			{
				long prediction;
				foreach (j, coefficient : coefficients[:subframe.predictor_order])
				{
					prediction += (long)coefficient * subframe.samples[i - (j + 1)];
				}
				prediction >>= prediction_shift;
				subframe.samples[i] = residual.next(self)! + (int)prediction;
			}
	}
	if (subframe.wasted_bits > 0)
	{
		foreach (&sample : subframe.samples)
		{
			*sample <<= subframe.wasted_bits;
		}
	}
}

fn void? decode_frame_footer(FlacDecoder* self, FlacFrame* frame)
{
	self.bit_reader.clear(); // we are now byte aligned, clear the bit reader. TODO: there is a redundant clear in decode_frame_header because of this
	ushort crc = io::read_be_ushort(self.file)!;
	frame.frame_crc = crc;
}

fn int? decode_subframe_constant_sample(FlacDecoder* self, FlacFrame* frame, FlacSubframe* subframe, bool extra_depth_bit) @private
{
	int bits_remaining = subframe.bits_per_sample + (int)extra_depth_bit;
	uint res = self.bit_reader.read_more_bits(bits_remaining)!;
	//if (@unlikely(res > int::max || (res << subframe.wasted_bits) > int::max)) abort("correlated side channel resulted in a value over 32 bits, TODO: handle?");
	log::debug("sample before: %s, sample after: %s", res, res << subframe.wasted_bits);
	//res <<= subframe.wasted_bits;
	int shift_bits = bitsizeof(int) - subframe.bits_per_sample;
	return (int)(res << shift_bits) >> shift_bits; // sign extend the decoded value
}

fn int? get_subframe_fixed_predictor_prediction(FlacDecoder* self, FlacSubframe* subframe, sz n) @private
{
	// TODO: maybe move this switch into the place it's used so it only switches once and then does a full loop without any more branching
	switch (subframe.predictor_order)
	{
		case 0: return 0;
		case 1: return subframe.samples[n - 1];
		case 2: return (int)(2 * (long)subframe.samples[n - 1] - subframe.samples[n - 2]);
		case 3: return (int)(3 * (long)subframe.samples[n - 1] - 3 * (long)subframe.samples[n - 2] + subframe.samples[n - 3]);
		case 4: return (int)(4 * (long)subframe.samples[n - 1] - 6 * (long)subframe.samples[n - 2] + 4 * (long)subframe.samples[n - 3] - subframe.samples[n - 4]);
		default: unreachable();
	}
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
			coded_number = (((first & 0x01) << 30) | (second << 24) | (third << 18) | (fourth << 12) | (fifth << 6) | sixth) + 1;
		case 0xFE:
			long second = read_coded_tail_byte(self)!;
			long third = read_coded_tail_byte(self)!;
			long fourth = read_coded_tail_byte(self)!;
			long fifth = read_coded_tail_byte(self)!;
			long sixth = read_coded_tail_byte(self)!;
			long seventh = read_coded_tail_byte(self)!;
			coded_number = ((second << 30) | (third << 24) | (fourth << 18) | (fifth << 12) | (sixth << 6) | seventh) + 1;
		default: return BAD_CODED_NUMBER~;
	}
	return coded_number;
}

fn char? read_coded_tail_byte(FlacDecoder* self) @inline
{
	char b = self.file.read_byte()!;
	if (@unlikely(!is_valid_coded_tail_byte(b))) return BAD_CODED_NUMBER~;
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
enum FlacFrameChannels : char (char num_channels, bool is_correlated) @private
{
	MONO {1, false},
	STEREO {2, false},
	THREE {3, false},
	FOUR {4, false},
	FIVE {5, false},
	SIX {6, false},
	SEVEN {7, false},
	EIGHT {8, false},
	STEREO_LEFT_SIDE {2, true},
	STEREO_RIGHT_SIDE {2, true},
	STEREO_MID_SIDE {2, true},
}
enum FlacFrameBitDepth : char (ichar bit_depth) @private
{
	ONLY_STORED_IN_STREAMINFO{-1},
	BPS_8{8},
	BPS_12{12},
	RESERVED{-1},
	BPS_16{16},
	BPS_20{20},
	BPS_24{24},
	BPS_32{32},
}
enum FlacSubframeType : char @private
{
	CONSTANT,
	VERBATIM,
	FIXED_PREDICTOR,
	LINEAR_PREDICTOR,
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

struct FlacSeekPoint @private
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

struct FlacCodedResidualState //@nopadding
{
	ushort num_partitions;
	ushort num_residual_samples;
	ushort num_first_residual_samples;
	char parameter_size;
	char current_partition_parameter;
	short current_partition;
	ushort current_partition_sample_num;
	char residual_sample_bits;
}

const char ESCAPED_PARTITION = 0xFF;

fn void? FlacCodedResidualState.init(&self, FlacDecoder* decoder, FlacFrame* frame, FlacSubframe* subframe)
{
	FlacCodedResidualState new @noinit;
	char coding_method = decoder.bit_reader.read_bits(2)!;
	switch (coding_method)
	{
		case 0b00: new.parameter_size = 4;
		case 0b01: new.parameter_size = 5;
		case 0b10..0b11: return BAD_CODED_RESIDUAL~;
		default: unreachable();
	}
	char partition_order = decoder.bit_reader.read_bits(4)!;
	new.num_partitions = 1 << partition_order;
	new.current_partition = -1;
	new.num_residual_samples = (frame.block_size >> partition_order);
	new.num_first_residual_samples = new.num_residual_samples - subframe.predictor_order;
	new.current_partition_sample_num = new.num_residual_samples;
	*self = new;

	if (@unlikely(frame.block_size % new.num_partitions != 0)) return BAD_CODED_RESIDUAL~;
	if (@unlikely(new.num_residual_samples <= subframe.predictor_order)) return BAD_CODED_RESIDUAL~;
}

fn int? FlacCodedResidualState.next(&self, FlacDecoder* decoder)
{
	if (self.current_partition_sample_num == self.num_residual_samples)
	{
		if (self.current_partition <= 0) @swap(self.num_residual_samples, self.num_first_residual_samples);
		self.current_partition ++;
		self.current_partition_sample_num = 0;
		char parameter = decoder.bit_reader.read_bits(self.parameter_size)!;
		if (parameter == (1 << self.parameter_size) - 1) // it's an escape code, 0b1111 for a parameter size of 4 or 0b11111 for a parameter size of 5
		{
			parameter = ESCAPED_PARTITION;
			self.residual_sample_bits = decoder.bit_reader.read_bits(5)!;
		}
		self.current_partition_parameter = parameter;
	}
	defer self.current_partition_sample_num ++;

	if (self.current_partition_parameter == ESCAPED_PARTITION) // it's an escaped partition with fixed residual sample sizes
	{
		if (self.residual_sample_bits == 0) return 0;
		uint raw_sample = decoder.bit_reader.read_more_bits(self.residual_sample_bits)!;
		int shift_bits = bitsizeof(int) - self.residual_sample_bits;
		int final_sample = (int)(raw_sample << shift_bits) >> shift_bits; // make use of signed int sign extension when right shifting to sign extend the sample
		return (int)final_sample;
	}
	else // it's a rice-coded residual
	{
		uint most_significant_part = decoder.bit_reader.read_unary_number(uint)!;
		uint least_significant_part = self.current_partition_parameter == 0 ? 0 : decoder.bit_reader.read_more_bits(self.current_partition_parameter)!;
		uint folded_residual = (most_significant_part << self.current_partition_parameter) | least_significant_part;

		// These both get optimised to the same thing so I use the more readable one
		uint final_sample = folded_residual % 2 == 0 ? (folded_residual >> 1) : ~(folded_residual >> 1);
		//uint maybe_invert_mask = -(folded_residual & 0x01);
		//int final_sample = (int)((folded_residual >> 1) ^ maybe_invert_mask);

		return (int)final_sample;
	}
}


<*
 @require nbits > 0 && nbits <= 32
*>
fn uint? BitReader.read_more_bits(&self, int nbits)
{
	uint res;
	while (nbits >= 8)
	{
		res = (res << 8) | self.read_bits(8)!;
		nbits -= 8;
	}
	if (nbits != 0)
	{
		res = (res << nbits) | self.read_bits(nbits)!;
	}
	return res;
}

macro BitReader.read_unary_number(&self, $NumType)
{
	$NumType res = 0;
	while (self.read_bits(1)! == 0) res++;
	return res;
}
