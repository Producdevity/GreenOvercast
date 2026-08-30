// SPDX-License-Identifier: GPL-2.0

#include <linux/module.h>
#include <linux/of.h>

#include "greenovercast_h700_ve_dtbo.h"

static int overlay_id = -1;

static int __init greenovercast_h700_overlay_init(void)
{
	return of_overlay_fdt_apply(greenovercast_h700_ve_dtbo,
				    greenovercast_h700_ve_dtbo_len,
				    &overlay_id, NULL);
}

static void __exit greenovercast_h700_overlay_exit(void)
{
	if (overlay_id >= 0)
		of_overlay_remove(&overlay_id);
}

module_init(greenovercast_h700_overlay_init);
module_exit(greenovercast_h700_overlay_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("H700 Cedrus device-tree overlay");
