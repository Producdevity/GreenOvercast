# Ad playback tests

Build with `tools/zig.sh build ad-player-test`. The default test uses the native
player with mock ad servers and tracking endpoints. It makes no network requests.

Generate fixtures on a host with FFmpeg:

```sh
ffmpeg -f lavfi -i testsrc2=size=640x360:rate=30 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 -t 5 \
  -c:v libx264 -profile:v high -bf 2 -g 60 -pix_fmt yuv420p \
  -c:a aac -ac 2 -movflags +faststart ad-test.mp4
ffmpeg -f lavfi -i color=blue:size=30x30 -frames:v 1 ad-icon.png
ffmpeg -f lavfi -i testsrc2=size=1920x1080 -frames:v 1 ad-panel.png
ffmpeg -i ad-test.mp4 -t 3 -c copy ad-short.mp4
ffmpeg -i ad-test.mp4 -filter_complex '[0:a]atrim=duration=4[a]' \
  -map 0:v -map '[a]' -c:v copy -c:a aac ad-video-tail.mp4
```

Copy the test executable, fixtures and release libraries into one directory on
the target. Launch it through the device frontend, with no other app running:

```sh
LD_LIBRARY_PATH=. ./greenovercast-ad-test.aarch64 \
  ad-test.mp4 ad-icon.png ad-short.mp4 ad-video-tail.mp4 ad-panel.png
```

It checks paced MP4/AAC playback, multi-ad pods, wrapper and inline tracking, AdChoices
pause/resume, empty inventory, invalid and truncated media, video extending
beyond audio, wrapper loops, and cancellation. A successful
synthetic test does not prove that an ad provider served a real advertisement.

For a live VAST URL, including a [Google sample ad](https://developers.google.com/interactive-media-ads/docs/sdks/html5/client-side/tags):

```sh
LD_LIBRARY_PATH=. ./greenovercast-ad-test.aarch64 --live-ad "$VAST_URL"
```

This sends real media and tracking requests. NVIDIA session reports are recorded
locally; no NVIDIA account is attached to the test.
