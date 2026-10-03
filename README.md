# Usage example
requires `alsa-utils` package on nixos

```console
$ c3c build
$ ./build/c3flac <some flac file> | aplay -t raw -f S32_LE -c2 -r44100
```

If your flac file doesn't have a 44.1khz sample rate, change the `-r` flag to
match it.

It currently upscales all samples to 32 bit little endian when
outputting to stdout. This is done by the demo program to make it more
convenient to use flacs with different numbers of bits per sample without
changing the command, and is not a limitation of the library.

# Limitations and disclaimers

- I'm still working on an API to make this more useable as a library, and
  there are likely many optisations that I could make.
- Some files have minor audio crackling when decoded and I haven't
  found what's causing it yet (Probably some bad bit maths), but it doesn't
  cause any sudden loud noises.
- I haven't tested this on files with 32-bit samples, don't expect it to work
  properly with them (There may be unexpected loud noises or smth, try at your
  own risk.)
- This isn't _100%_ spec compliant, it can decode most "regular" flac files,
  but running it on the files in `resources/flac-test-files/` may result in
  incorrect behaviour for some of them. It also doesn't support variable
  block size yet, which I haven't encountered in any files I've tested so far,
  but should be implemented at some point.
