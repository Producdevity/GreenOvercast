# FFmpeg

GreenOvercast ships `libavcodec`, `libavutil`, and `libswscale` from FFmpeg
9.0 under LGPLv2.1-or-later.

Source: <https://ffmpeg.org/releases/ffmpeg-9.0.tar.xz>

SHA-256: `7f607a00dd0d28a729d5a4811205812eef01cf6ef6155025febb6f36a9062d52`

H.264 V4L2 Request support comes from the ROCKNIX patch at:

<https://github.com/ROCKNIX/distribution/blob/e9e6b8531df13bc9058ca1771dab5f0c4fd5e98e/packages/multimedia/ffmpeg/patches/v4l2-request/0001-v4l2-request.patch>

Patch SHA-256: `afd04c202c27081c355d8d34b58a52c4141de26433007e27ed6e0d2093d10d3c`

`tools/build-dependencies.sh` contains the complete build configuration. The
libraries are dynamically linked. The license text is in
`licenses/LICENSE.FFmpeg.txt`.
