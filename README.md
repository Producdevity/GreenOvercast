# GreenOvercast

GreenOvercast is a native Xbox Cloud Gaming client for small ARM64 Linux
handhelds. It streams at 720p and uses the H700 video decoder.

Built for the Anbernic RG35XX-H (muOS) and validated on the RG40XX-H (Knulli).

This independent project is not affiliated with or endorsed by Microsoft.

Requires an [Xbox Game Pass plan](https://www.xbox.com/cloud-gaming) that includes cloud gaming and internet access.

## Install

Install `greenovercast.zip` through PortMaster, then launch GreenOvercast from
the Ports section of the device frontend.

The first launch shows a Microsoft device code. Open
[microsoft.com/link](https://www.microsoft.com/link) on another device and enter
the code to sign in. Knulli asks you to sign in again after a reboot.

GreenOvercast is experimental and has only been tested on the devices below.

## Controls

| Button             | Action                                      |
| ------------------ | ------------------------------------------- |
| D-pad / Left Stick | Navigate                                    |
| A                  | Select                                      |
| B                  | Back                                        |
| X                  | Open search / delete a letter               |
| Y                  | Change aspect ratio / clear search          |
| L1 / R1            | Xbox LB / RB                                |
| L2 / R2            | Xbox LT / RT                                |
| Start              | Apply search / Xbox Menu                    |
| Select             | Xbox View                                   |
| L3 + R3            | Xbox Guide                                  |
| Select + Start     | Exit GreenOvercast after holding one second |

In-game controls use the standard Xbox controller layout.

The aspect-ratio setting applies to the next game you start. Most games only
support 16:9.

## Supported devices

| Device   | OS                   | Status |
| -------- | -------------------- | ------ |
| RG35XX-H | muOS 2508.4          | Tested |
| RG40XX-H | Knulli (Batocera 42) | Tested |

Hardware decoding currently only works on H700 devices. Other devices fall
back to software decoding, which is too slow for normal gameplay.

The release requires glibc 2.38 or newer. ArkOS ships glibc 2.30 and is not
supported.

## Build

You need a Linux or macOS host with `cmake`, `curl`, `git`, `make`, `patch`,
`perl`, and `python3`.

```sh
tools/bootstrap.sh           # fetch Zig 0.14.1
tools/zig.sh build smoke     # cross-build the aarch64 smoke binary
tools/zig.sh build product-check # compile the Zig product modules
tools/zig.sh build test      # host unit tests
tools/zig.sh build fmt-check # format check
```

Build the release and PortMaster package with:

```sh
tools/build-release.sh
PORTMASTER_NEW=/path/to/PortMaster-New tools/package-portmaster.sh
```

`package-portmaster.sh` runs the current PortMaster-New checks and archive
builder. To queue the finished archive for PortMaster's supported autoinstall
flow:

```sh
tools/deploy.sh <ssh-host> zig-out/greenovercast.zip
```

Launch PortMaster from the device frontend to install it. Then launch
GreenOvercast from Ports so the frontend owns the display handoff.

## License

MPL-2.0. See [LICENSE](LICENSE). The Cedar H.264 decoder is LGPLv2.1 and
dynamically linked. Third-party licenses are listed in [THIRDPARTY.md](THIRDPARTY.md).
