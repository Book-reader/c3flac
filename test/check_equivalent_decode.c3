module flac @test;
import std::collections::range;
import std::io;
import std::os::process;

const String[*] COMMAND = { "ffmpeg", "-i", "REPLACEME", "-f", "s%sle", "-c:a", "pcm_s%sle", "-" };

struct SongFile @private { String name; typeid sample_type; }
const SongFile[*] FILES =
{
	{ "demo-indep.flac",  short },
	{ "demo.flac",        short },
	{ "demo2.flac",       int },
	{ "demo3.flac",       int },
	{ "demo4.flac",       short },
	{ "demo5.flac",       int },
	{ "demo6-indep.flac", int },
	{ "demo6.flac",       int },
	{ "demo7.flac",       short },
	{ "demo8.flac",       short },
};

fn void ensure_equal_decode () => @pool ()
{
	foreach (file : FILES)
	{
		int sample_bits = (int)file.sample_type.size * 8;
		io::printfn ("Decoding %s (%d bits)", file.name, sample_bits);
		String[*] command = COMMAND;
		command[2] = file.name;
		command[4] = string::tformat (command[4], sample_bits);
		command[6] = string::tformat (command[6], sample_bits);

		Process ffmpeg = process::spawn (&command)!!;
		defer (void)ffmpeg.destroy ();

		int[] ffmpeg_output = stream_to_ints (tmem, ffmpeg.stdout (), file.sample_type);

		ffmpeg.join ()!!;

		FlacDecoder f = flac::open(tmem, file.name, {})!!;
		defer (void)f.close();

		sz sample_idx = 0;
		sz frame_num  = 0;

		// test::eq (own_output.len, ffmpeg_output.len);
		int shift_bits = sample_bits - f.flac_info.bits_per_sample;
		if (catch err = f.@each_frame(; int[][] raw_samples)
		{
			assert (raw_samples.len == 2, "Must be stero");
			test::eq (raw_samples[0].len, raw_samples[1].len);
			sz err_count = 0;
			frame_num ++;

			for (sz i = 0; i < raw_samples[0].len; i ++)
			{
				for (sz j = 0; j < 2; j ++)
				{
					defer sample_idx ++;
					if (sample_idx >= ffmpeg_output.len)
					{
						static bool triggered = false;
						if (!triggered)
						{
							log::error ("Own output was longer than ffmpeg output of %d", ffmpeg_output.len);
							triggered = true;
						}
						continue;
					}
					int sample = raw_samples[j][i] << shift_bits;

					if (ffmpeg_output[sample_idx] != sample)
					{
						err_count ++;
						log::error ("Own output (%d, 0x%x), differed from ffmpeg output (%d, 0x%x) at frame %d, channel %d, sample %d",
						        sample, (uint)sample, ffmpeg_output[sample_idx], (uint)ffmpeg_output[sample_idx], frame_num, j, i);
						assert (false);
					}
				}
			}
			/*foreach (channel_num, channel : raw_samples)
			{
				foreach (i, sample : channel)
				{
					defer sample_idx ++;
					if (sample_idx >= ffmpeg_output.len) assert (false, "Own output was longer than ffmpeg output of %d", ffmpeg_output.len);

					if (ffmpeg_output[sample_idx] != sample)
					{
						err_count ++;
						log::error ("Own output (%d, %x), differed from ffmpeg output (%d, %x) at frame %d, channel %d, sample %d",
						        sample, sample, ffmpeg_output[sample_idx], ffmpeg_output[sample_idx], frame_num, channel_num, i);
					}
				}
			}*/
			log::error ("%d of %d samples in frame %d were incorrect", err_count, raw_samples[0].len * raw_samples.len, frame_num);
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

fn int[] stream_to_ints (Allocator alloc, File file, typeid type) => @pool ()
{
	assert (type == int || type == short);
	List {int} ints;
	ints.tinit ();

	while (!file.eof ())
	{
		if (catch err = ints.push ((type == int) ? io::read_le_int (&file) : io::read_le_short (&file)))
		{
			if (err != io::EOF) err~!!;
			break;
		}
	}

	return ints.to_array (alloc);
}
