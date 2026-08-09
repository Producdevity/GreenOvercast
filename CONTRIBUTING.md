# Contributing

GreenOvercast is a Zig-first project. Zig owns the application lifecycle,
authentication, cloud-session flow, catalog, controller mapping, UI, protocol
encoding, and RTP parsing. C and C++ stay at native-library and hardware-media
boundaries such as libdatachannel, CedarX, SDL2, curl, Opus, OpenSSL, and
FFmpeg.

## Setup

```sh
tools/bootstrap.sh
tools/zig.sh build test
tools/zig.sh build fmt-check
```

## Code style

- Keep product behavior in Zig. Use C or C++ where a native library or device
  interface makes it the clearer boundary.
- Keep each native adapter behind a small header with explicit ownership.
- No browser, WebView, JS runtime, or player subprocess in the product path.
- Bounded queues, explicit ownership, no detached threads.
- Run `tools/zig.sh build fmt-check` before submitting.

## Submitting changes

Open a pull request. Keep commits focused.
Please disclose AI usage and only commit code you understand.
