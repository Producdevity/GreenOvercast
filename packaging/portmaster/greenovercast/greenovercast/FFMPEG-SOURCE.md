# FFmpeg

GreenOvercast ships `libavcodec`, `libavutil`, and `libswscale` from FFmpeg
4.4.8 under LGPLv2.1-or-later.

Source: <https://ffmpeg.org/releases/ffmpeg-4.4.8.tar.xz>

SHA-256: `c73848c4ae283d9eaee7be3b276affbc3543380483555500d0dd2c9b7e1c39c3`

`tools/build-dependencies.sh` contains the complete build configuration. The
libraries are dynamically linked and may be replaced with ABI-compatible
builds. The license text is in `licenses/LICENSE.FFmpeg.txt`.
