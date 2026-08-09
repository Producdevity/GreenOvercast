# Third-party licenses

GreenOvercast is MPL-2.0. The libraries below are linked or bundled into the
release. Full license texts for the bundled libraries ship alongside the port in
`packaging/portmaster/greenovercast/greenovercast/licenses/`.

| Library                                                                         | License           | Role                                                         |
| ------------------------------------------------------------------------------- | ----------------- | ------------------------------------------------------------ |
| [libdatachannel](https://github.com/paullouisageneau/libdatachannel) (v0.24.3)  | MPL-2.0           | WebRTC peer connection, data channels, media tracks (static) |
| [libjuice](https://github.com/paullouisageneau/libjuice)                        | MPL-2.0           | ICE, bundled with libdatachannel (static)                    |
| [libsrtp](https://github.com/cisco/libsrtp)                                     | BSD-3-Clause      | SRTP, bundled with libdatachannel (static)                   |
| [usrsctp](https://github.com/sctplab/usrsctp)                                   | BSD-3-Clause      | SCTP for data channels, bundled with libdatachannel (static) |
| [CedarX](https://github.com/allwinner-zh/media-codec) (Allwinner H.264 decoder) | LGPLv2.1-or-later | Hardware H.264 decode, dynamically linked and replaceable    |
| [FFmpeg](https://ffmpeg.org/) (libavcodec, libavutil, libswscale)               | LGPLv2.1-or-later | Software H.264 fallback decode and color conversion          |
| [SDL2](https://www.libsdl.org/)                                                 | Zlib              | Window, renderer, audio, and controller input                |
| [OpenSSL](https://www.openssl.org/)                                             | Apache-2.0        | TLS, WebRTC DTLS, and credential encryption                  |
| [libcurl](https://curl.se/)                                                     | curl (MIT-style)  | HTTP for Xbox services                                       |
| [Opus](https://opus-codec.org/)                                                 | BSD-3-Clause      | Audio decode                                                 |

SDL2, OpenSSL, libcurl, Opus, and FFmpeg are dynamic system libraries on the
target device and are not redistributed here.

CedarX is the only LGPL component in the product path. It is built from source
in `vendor/cedarx/`, linked as a private, replaceable shared library, and
documented in `packaging/portmaster/greenovercast/greenovercast/CEDAR-SOURCE.md`.

[Zig](https://ziglang.org/) 0.14.1 (MIT) is the build toolchain; it is not
linked into or distributed with the release.
