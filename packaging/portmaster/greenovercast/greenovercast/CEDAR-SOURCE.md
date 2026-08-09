# GreenOvercast Cedar subset

This directory contains the LGPLv2.1-or-later H.264 decoder subset of
Allwinner's `media-codec` repository at commit
`a912bbe300d522e199001bd903bab22e54eff37b`. The upstream source is
<https://github.com/allwinner-zh/media-codec>.

GreenOvercast builds these files into the replaceable
`libgreenovercast-cedar.so`; they are never linked into the MPL executable.
`tools/build-cedarx.sh` is the complete build recipe.

The maintained changes are limited to the aarch64/H616 port:

- pointer-width-safe register addresses;
- preservation of 32-bit H616 IOMMU addresses;
- the H616 VE-version query;
- corrected initialization, teardown, and codec-registration error paths;
- explicit definitions for globals that older C compilers treated as common
  symbols;
- removal of Android-oriented runtime plugin scanning.

The project-owned `/dev/cedar_dev` and ION runtime and the narrow public ABI
live under `src/media/video/`. The full license text is installed as
`licenses/LICENSE.CedarX.txt` beside the shared library.
