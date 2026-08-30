# ROCKNIX H700 kernel modules

ROCKNIX 20260801 does not expose the H700 video engine. This package includes
two modules built for its stock 7.0.11 kernel: the Linux Cedrus driver and a
device-tree overlay that adds the video-engine node.

The corresponding source is in `vendor/rocknix-h700-cedrus/` in the
GreenOvercast source release. `tools/build-rocknix-h700-cedrus.sh` rebuilds the
modules from an exact prepared ROCKNIX kernel tree.

Source versions:

- ROCKNIX `20260801`, commit `3b9cb1f6bf48ee9ca0cf01edd9af52ca2a6b73fb`
- Linux `7.0.11`
- config SHA-256 `ea1abaf7109d6132e0ecd3cee51d8e08cde5e2143813f017ed35399950482081`
- `Module.symvers` SHA-256 `b95c5a532ae10737d39bac79823e1977db7ec603410b4ab2b77edabc8dd41674`

The modules are GPL-2.0-only. The H616 support is based on the upstream Cedrus
work linked from `vendor/manifest.lock`.
