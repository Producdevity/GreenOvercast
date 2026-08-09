# Target ABI headers

This directory contains only the public headers needed to cross-compile against
the libraries supplied by muOS 2508.4. It is not a source vendor directory.

| Library | Header version | Runtime role |
|---|---:|---|
| SDL2 | 2.28.5 | display, audio, controller input |
| curl | 8.7.1 | HTTPS transport |
| FFmpeg | libavcodec 58.134, libavutil 56.70, libswscale 5.9 | software decode fallback and RGB conversion |
| libdatachannel | 0.24.3 | WebRTC C API |

The retained set is the transitive compiler dependency closure of the project
sources. Library sources, tests, examples, build files, and private headers do
not belong here. Exact library provenance and licensing are recorded in
`vendor/manifest.lock`.
