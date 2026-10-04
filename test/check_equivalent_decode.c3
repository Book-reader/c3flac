module flac @test;
import std::collections::range;
import std::io;
import std::os::process;

const String[*] COMMAND = { "ffmpeg", "-i", "REPLACEME", "-f", "s32le", "-c:a", "pcm_s32le", "-" };

const String[*] FILES =
{
	"demo-indep.flac",
	"demo.flac",
	"demo2.flac",
	"demo3.flac",
	"demo4.flac",
	"demo5.flac",
	"demo6-indep.flac",
	"demo6.flac",
	"demo7.flac",
	"demo8.flac",
};

fn void ensure_equal_decode () => @pool ()
{
	foreach (file : FILES)
	{
		io::printfn ("Decoding %s", file);
		String[*] command = COMMAND;
		command[2] = file;

		Process ffmpeg = process::spawn (&command)!!;
		defer (void)ffmpeg.destroy ();

		int[] ffmpeg_output = stream_to_ints (tmem, ffmpeg.stdout ());

		ffmpeg.join ()!!;

		FlacDecoder f = flac::open(tmem, file, {.upscale_to_32bit})!!;
		defer (void)f.close();

		sz sample_idx = 0;
		sz frame_num  = 0;

		// test::eq (own_output.len, ffmpeg_output.len);

		int shift_bits = bitsizeof(int) - f.flac_info.bits_per_sample;
		if (catch err = f.@each_frame(; int[][] raw_samples)
		{
			frame_num ++;
			foreach (channel_num, channel : raw_samples)
			{
				foreach (sample_raw : channel)
				{
					defer sample_idx ++;
					if (sample_idx >= ffmpeg_output.len) assert (false, "Own output was longer than ffmpeg output of %d", ffmpeg_output.len);
					int sample = sample_raw << shift_bits;

					if (@unlikely (ffmpeg_output[sample_idx] != sample))
					{
						assert (false, "Own output (%d, %x), differed from ffmpeg output (%d, %x) at index %d, frame %d, channel %d",
						        sample, sample, ffmpeg_output[sample_idx], ffmpeg_output[sample_idx], sample_idx, frame_num, channel_num);
					}
				}
			}
		})
		{
			if (err != io::UNEXPECTED_EOF) err~!!;
		}

		if (sample_idx != ffmpeg_output.len) assert (false, "Own output length of %d differed from ffmpeg output of %d", sample_idx, ffmpeg_output.len);

		/*for (sz i = 0; i < own_output.len; i ++)
		{
			if (@unlikely (ffmpeg_output[i] != own_output[i]))
			{
				assert (false, "Own output (%d, %x), differed from ffmpeg output (%d, %x) at index %d",
				        own_output[i], own_output[i], ffmpeg_output[i], ffmpeg_output[i], i);
			}
		}*/
	}
}


module flac @private @if (env::TESTING);
import std::collections::list;
import std::io;

fn int[] stream_to_ints (Allocator alloc, File file) => @pool ()
{
	List {int} ints;
	ints.tinit ();

	while (!file.eof ())
	{
		if (catch err = ints.push (io::read_le_int (&file)))
		{
			if (err != io::EOF) err~!!;
			break;
		}
	}

	return ints.to_array (alloc);
}
