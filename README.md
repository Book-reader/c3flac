Usage example (requires `alsa-utils` package on nixos):

```console
$ ./build/c3flac <some flac file> | aplay -t raw -f S32_LE -c2 -r44100
```


If your flac file isn't 44.1khz change the `-r` flag to match it, currently
upscales all samples to 32 bit little endian when outputting to stdout for
consistency, this is a feature of the demo program to make it more convenient
to use flacs with different sample sizes without changing the command and not
a limitation of the library.

I'm still working on an API to make this more useable as a library, and there
are likely many optisations that I could make.
