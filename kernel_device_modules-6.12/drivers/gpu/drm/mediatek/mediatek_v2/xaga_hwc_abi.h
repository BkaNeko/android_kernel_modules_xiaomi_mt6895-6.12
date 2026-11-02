/* SPDX-License-Identifier: GPL-2.0 */
#ifndef __XAGA_HWC_ABI_H__
#define __XAGA_HWC_ABI_H__

#include <linux/types.h>

struct drm_device;
struct drm_file;

/* The vendor HyperOS HWC uses the 4.14 layering ABI: ioctl 0xc0806445
 * (DRM_IOWR(0x45, 128 bytes)), 3 displays and 60-byte layer entries.
 * The 6.12 driver uses 4 displays and 72-byte entries, so the request has
 * to be translated or HRT reads garbage (invalid layer num -1).
 */
#define XAGA_HWC_DISPLAYS 3
#define XAGA_HWC_MAX_LAYERS 64

struct xaga_hwc_layer {
	__u32 ovl_id;
	__u32 src_fmt;
	__s32 dataspace;
	__u32 dst_offset_x, dst_offset_y;
	__u32 dst_width, dst_height;
	__s32 ext_sel_layer;
	__u32 src_offset_x, src_offset_y;
	__u32 src_width, src_height;
	__u32 layer_caps;
	__u32 clip;
	__u8 compress;
	__u8 secure;
};

struct xaga_hwc_layering {
	__u64 input_config[XAGA_HWC_DISPLAYS];
	__s32 disp_mode[XAGA_HWC_DISPLAYS];
	__s32 disp_mode_idx[XAGA_HWC_DISPLAYS];
	__s32 layer_num[XAGA_HWC_DISPLAYS];
	__s32 gles_head[XAGA_HWC_DISPLAYS];
	__s32 gles_tail[XAGA_HWC_DISPLAYS];
	__s32 hrt_num;
	__s32 res_idx;
	__u32 hrt_weight;
	__u32 hrt_idx;
	__u64 mml_cfg[XAGA_HWC_DISPLAYS];
};

int xaga_layering_rule_ioctl(struct drm_device *dev, void *data,
			     struct drm_file *file_priv);

#endif
