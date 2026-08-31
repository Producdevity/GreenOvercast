# Third-party licenses

GreenOvercast is MPL-2.0. The components below are linked or bundled into the
release. Full license texts for the bundled libraries ship alongside the port in
`packaging/portmaster/greenovercast/greenovercast/licenses/`.

| Library                                                                         | License           | Role                                                         |
| ------------------------------------------------------------------------------- | ----------------- | ------------------------------------------------------------ |
| [libdatachannel](https://github.com/paullouisageneau/libdatachannel) (v0.24.3)  | MPL-2.0           | WebRTC peer connection, data channels, media tracks (static) |
| [libjuice](https://github.com/paullouisageneau/libjuice)                        | MPL-2.0           | ICE, bundled with libdatachannel (static)                    |
| [libsrtp](https://github.com/cisco/libsrtp)                                     | BSD-3-Clause      | SRTP, bundled with libdatachannel (static)                   |
| [usrsctp](https://github.com/sctplab/usrsctp)                                   | BSD-3-Clause      | SCTP for data channels, bundled with libdatachannel (static) |
| [nlohmann/json](https://github.com/nlohmann/json)                               | MIT               | JSON support used by libdatachannel (header-only)            |
| [plog](https://github.com/SergiusTheBest/plog)                                  | MIT               | Logging used by libdatachannel (header-only)                 |
| [CedarX](https://github.com/allwinner-zh/media-codec) (Allwinner H.264 decoder) | LGPLv2.1-or-later | Hardware H.264 decode (shared)                               |
| [Linux Cedrus](https://www.kernel.org/) (7.0.11)                               | GPL-2.0-only      | ROCKNIX H700 V4L2 Request decoder modules                    |
| [Rockchip MPP](https://github.com/rockchip-linux/mpp) (v1.1.0)                  | Apache-2.0/MIT    | Optional Rockchip H.264 decode (shared)                      |
| [FFmpeg](https://ffmpeg.org/) (libavcodec, libavutil, libswscale)               | LGPLv2.1-or-later | H.264 decode, JPEG artwork, and color conversion             |
| [libudev-zero](https://github.com/illiliti/libudev-zero)                        | ISC               | V4L2 media-device discovery (static)                         |
| [SDL2](https://www.libsdl.org/)                                                 | Zlib              | Window, renderer, audio, and controller input (device)       |
| [OpenSSL](https://www.openssl.org/)                                             | Apache-2.0        | TLS, WebRTC DTLS, and credential encryption (static)         |
| [libcurl](https://curl.se/)                                                     | curl (MIT-style)  | HTTP for Xbox services (static)                              |
| [Opus](https://opus-codec.org/)                                                 | BSD-3-Clause      | Audio decode (static)                                        |
