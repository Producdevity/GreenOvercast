# GreenOvercast

<img width="640" height="480" alt="GreenOvercast game library" src="packaging/portmaster/greenovercast/screenshot.png" />

GreenOvercast is a native Xbox Cloud Gaming client for small ARM64 Linux
handhelds. It requests a stream matching the device display and uses hardware
video decoding on supported H700 and Rockchip firmware.

This independent project is not affiliated with or endorsed by Microsoft.

Requires an [Xbox Game Pass plan](https://www.xbox.com/cloud-gaming) that includes cloud gaming and internet access.

## Install

Copy `greenovercast.zip` to PortMaster's autoinstall folder, then open
PortMaster to install it. The folder location for each firmware is listed in
the [PortMaster FAQ](https://portmaster.games/faq.html#do-i-have-to-use-portmaster-to-install-ports).

When the installation finishes, return to the device frontend and launch
GreenOvercast from Ports.

The first launch shows a Microsoft device code. Open
[microsoft.com/link](https://www.microsoft.com/link) on another device and enter
the code to sign in.

GreenOvercast is experimental.

## Controls

| Button             | Library / menus                   | In game                           |
| ------------------ | --------------------------------- | --------------------------------- |
| D-pad / Left Stick | Navigate; hold to scroll faster   | Movement                          |
| A                  | Select, play, or type              | Xbox A                            |
| B                  | Back or cancel                    | Xbox B                            |
| X                  | Search or delete a letter         | Xbox X                            |
| Y                  | Favorite a game or clear search   | Xbox Y                            |
| L1 / R1            | Switch All / Favorites            | Xbox LB / RB                      |
| L2 / R2            | Jump by first letter              | Xbox LT / RT                      |
| Start              | Settings or apply search          | Xbox Menu                         |
| Select             | —                                 | Xbox View                         |
| L3 + R3            | —                                 | Xbox Guide                        |
| Select + Start     | Exit after holding for one second | Exit after holding for one second |

Settings include Xbox/Nintendo face-button layouts, game artwork, and Sign
out. Games that return a 16:9 stream remain letterboxed on 4:3 displays.

## Supported devices

| Device     | OS                              | Status |
| ---------- | ------------------------------- | ------ |
| RG35XX-H   | muOS 2508.4                     | Tested |
| RG40XX-H   | Knulli (Batocera 42)            | Tested |
| RG40XX-H   | ROCKNIX 20260801                | Tested |
| Miyoo Flip | SpruceOS 4.2.0                  | Tested |
| R36S       | AmberELEC prerelease-20250515   | Tested |

Hardware decoding is verified on the H700 systems above. muOS and Knulli use
CedarX; ROCKNIX 20260801 uses the bundled Cedrus modules. Tested Rockchip builds
use Rockchip MPP on RK3566 with SpruceOS and RK3326 with AmberELEC. Other
devices fall back to software decoding, which is too slow for normal gameplay.

The release requires glibc 2.38 or newer. ArkOS ships glibc 2.30 and is not
supported.

## Build

You need a Linux or macOS host with `cmake`, `curl`, `git`, `make`, `patch`,
`perl`, and `python3`.

```sh
tools/bootstrap.sh
tools/zig.sh build
tools/zig.sh build test
tools/zig.sh build fmt-check
```

Build the PortMaster package with:

```sh
PORTMASTER_NEW=/path/to/PortMaster-New tools/zig.sh build package
```

PortMaster-New is large. [JeodC's sparse-checkout guide](https://gist.github.com/JeodC/7a51211ad94ad6084d14042d80a62549)
shows how to fetch only the files needed for packaging.

The package build runs the current PortMaster checks and archive builder. To
queue the finished archive for PortMaster's supported autoinstall flow:

```sh
tools/deploy.sh <ssh-host> zig-out/greenovercast.zip
```

Launch PortMaster from the device frontend to install it. Then launch
GreenOvercast from Ports so the frontend owns the display handoff.

## License

MPL-2.0. See [LICENSE](LICENSE). The Cedar H.264 decoder is LGPLv2.1 and
dynamically linked. Third-party licenses are listed in [THIRDPARTY.md](THIRDPARTY.md).
