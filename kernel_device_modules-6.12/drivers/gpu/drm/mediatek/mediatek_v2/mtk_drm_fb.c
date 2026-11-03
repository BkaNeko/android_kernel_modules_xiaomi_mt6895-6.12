// SPDX-License-Identifier: GPL-2.0
/*
 * Copyright (c) 2021 MediaTek Inc.
 */

#include <drm/drm_crtc_helper.h>
#include <drm/drm_fb_helper.h>
#include <drm/drm_framebuffer.h>
#include <drm/drm_gem.h>
#include <drm/drm_modeset_helper.h>
#include <linux/dma-buf.h>

#include "mtk_drm_drv.h"
#include "mtk_drm_fb.h"
#include "mtk_drm_gem.h"
#include "mtk_drm_crtc.h"

/*
 * mtk specific framebuffer structure.
 *
 * @fb: drm framebuffer object.
 * @gem_obj: array of gem objects.
 */
struct mtk_drm_fb {
	struct drm_framebuffer base;
	/* xaga: MIUI/HyperOS HWC tags the 0x0a.. modifier to mean "premultiplied
	 * blend", not a memory layout. Keep it private so KMS core accepts the
	 * buffer as linear instead of rejecting the atomic commit.
	 */
	u64 legacy_blend_modifier;
	/* For now we only support a single plane */
	struct drm_gem_object *gem_obj;
};

#define to_mtk_fb(x) container_of(x, struct mtk_drm_fb, base)

struct drm_gem_object *mtk_fb_get_gem_obj(struct drm_framebuffer *fb)
{
	struct mtk_drm_fb *mtk_fb = to_mtk_fb(fb);

	return mtk_fb->gem_obj;
}

size_t mtk_fb_get_size(struct drm_framebuffer *fb)
{
	struct mtk_drm_fb *mtk_fb = to_mtk_fb(fb);
	struct mtk_drm_gem_obj *mtk_gem = NULL;

	if (!mtk_fb->gem_obj)
		return 0;

	mtk_gem = to_mtk_gem_obj(mtk_fb->gem_obj);
	if (!mtk_gem)
		return 0;

	return mtk_gem->size;
}

dma_addr_t mtk_fb_get_dma(struct drm_framebuffer *fb)
{
	struct mtk_drm_fb *mtk_fb = to_mtk_fb(fb);
	struct mtk_drm_gem_obj *mtk_gem = NULL;

	if ((!mtk_fb) || (!mtk_fb->gem_obj))
		return 0;

	mtk_gem = to_mtk_gem_obj(mtk_fb->gem_obj);
	if (!mtk_gem)
		return 0;

	return mtk_gem->dma_addr;
}

bool mtk_drm_fb_is_secure(struct drm_framebuffer *fb)
{
	struct drm_gem_object *gem = NULL;
	struct mtk_drm_gem_obj *mtk_gem = NULL;


	if (!fb)
		return false;
	gem = mtk_fb_get_gem_obj(fb);
	if (!gem)
		return false;
	mtk_gem = to_mtk_gem_obj(gem);
	return mtk_gem->sec;
}

int mtk_fb_get_sec_id(struct drm_framebuffer *fb)
{
	struct drm_gem_object *gem = NULL;
	struct mtk_drm_gem_obj *mtk_gem = NULL;


	if (!fb)
		return false;
	gem = mtk_fb_get_gem_obj(fb);
	if (!gem)
		return false;
	mtk_gem = to_mtk_gem_obj(gem);
	return mtk_gem->sec_id;
}
EXPORT_SYMBOL_GPL(mtk_fb_get_sec_id);


u64 mtk_fb_get_modifier(struct drm_framebuffer *fb)
{
	struct mtk_drm_fb *mtk_fb = to_mtk_fb(fb);

	return mtk_fb->legacy_blend_modifier ? : fb->modifier;
}
EXPORT_SYMBOL_GPL(mtk_fb_get_modifier);

/* xaga: legacy RGB blend hint (0x0a0000000000000X), only for RGB formats */
static bool xaga_fb_has_legacy_blend_hint(const struct drm_mode_fb_cmd2 *mode)
{
	if ((mode->modifier[0] & ~1ULL) != 0x0a00000000000000ULL)
		return false;
	switch (mode->pixel_format) {
	case DRM_FORMAT_XRGB8888:
	case DRM_FORMAT_XBGR8888:
	case DRM_FORMAT_ARGB8888:
	case DRM_FORMAT_ABGR8888:
	case DRM_FORMAT_RGBX8888:
	case DRM_FORMAT_BGRX8888:
	case DRM_FORMAT_RGBA8888:
	case DRM_FORMAT_BGRA8888:
	case DRM_FORMAT_ABGR2101010:
		return true;
	default:
		return false;
	}
}

static int mtk_drm_fb_create_handle(struct drm_framebuffer *fb,
				    struct drm_file *file_priv,
				    unsigned int *handle)
{
	struct mtk_drm_fb *mtk_fb = to_mtk_fb(fb);

	return drm_gem_handle_create(file_priv, mtk_fb->gem_obj, handle);
}

static void mtk_drm_fb_destroy(struct drm_framebuffer *fb)
{
	struct mtk_drm_fb *mtk_fb = to_mtk_fb(fb);

	drm_framebuffer_cleanup(fb);
	drm_gem_object_put(mtk_fb->gem_obj);

	kfree(mtk_fb);
}

static const struct drm_framebuffer_funcs mtk_drm_fb_funcs = {
	.create_handle = mtk_drm_fb_create_handle,
	.destroy = mtk_drm_fb_destroy,
};

static struct mtk_drm_fb *
mtk_drm_framebuffer_init(struct drm_device *dev,
			 const struct drm_mode_fb_cmd2 *mode,
			 struct drm_gem_object *obj)
{
	struct mtk_drm_fb *mtk_fb;
	struct drm_mode_fb_cmd2 linear_mode;
	u64 legacy_blend = 0;
	int ret;

	/* xaga: two halves, and the second one was missing.  The MIUI HWC hands
	 * us a private RGB blend hint 0x0a0000000000000X.  Core KMS cannot
	 * validate it, so it has to be replaced with a linear modifier for the
	 * fb we register -- but the original value still has to reach OVL, which
	 * reads it back through mtk_fb_get_modifier() to decide
	 * MTK_FMT_PREMULTIPLIED vs opaque blending.  Detecting the hint, forcing
	 * linear and then dropping the value makes mtk_fb_get_modifier() return
	 * fb->modifier (linear), so premultiplied layers composite as opaque.
	 */
	if (xaga_fb_has_legacy_blend_hint(mode)) {
		dev_info_once(dev->dev,
			      "xaga: legacy RGB blend hint kept private, KMS layout linear\n");
		legacy_blend = mode->modifier[0];
		linear_mode = *mode;
		linear_mode.modifier[0] = DRM_FORMAT_MOD_LINEAR;
		mode = &linear_mode;
	}

	mtk_fb = kzalloc(sizeof(*mtk_fb), GFP_KERNEL);
	if (!mtk_fb)
		return ERR_PTR(-ENOMEM);

	drm_helper_mode_fill_fb_struct(dev, &mtk_fb->base, mode);

	mtk_fb->gem_obj = obj;
	mtk_fb->legacy_blend_modifier = legacy_blend;

	ret = drm_framebuffer_init(dev, &mtk_fb->base, &mtk_drm_fb_funcs);
	if (ret) {
		DRM_ERROR("failed to initialize framebuffer\n");
		kfree(mtk_fb);
		return ERR_PTR(ret);
	}

	return mtk_fb;
}

struct drm_framebuffer *
mtk_drm_framebuffer_create(struct drm_device *dev,
			   const struct drm_mode_fb_cmd2 *mode,
			   struct drm_gem_object *obj)
{
	struct mtk_drm_fb *mtk_fb;

	mtk_fb = mtk_drm_framebuffer_init(dev, mode, obj);
	if (IS_ERR(mtk_fb))
		return ERR_CAST(mtk_fb);

	return &mtk_fb->base;
}

/*
 * Wait for any exclusive fence in fb's gem object's reservation object.
 *
 * Returns -ERESTARTSYS if interrupted, else 0.
 */
int mtk_fb_wait(struct drm_framebuffer *fb)
{
	struct drm_gem_object *gem;
	struct dma_resv *resv;
	//long ret;

	if (!fb)
		return 0;

	gem = mtk_fb_get_gem_obj(fb);
	if (!gem || !gem->dma_buf || !gem->dma_buf->resv)
		return 0;

	resv = gem->dma_buf->resv;
	/* display wait for sync(DWFS), /kernel-5.15/drivers/dma-buf/dma-resv.c */
	/*
	ret = dma_resv_wait_timeout_rcu(resv, false, true,
					MAX_SCHEDULE_TIMEOUT);
	*/

	/* MAX_SCHEDULE_TIMEOUT on success, -ERESTARTSYS if interrupted */
	/*
	if (ret < 0) {
		DDPAEE("%s:%d, invalid ret:%ld\n",
			__func__, __LINE__,
			ret);
		return ret;
	}
	*/
	return 0;
}

struct drm_framebuffer *
mtk_drm_mode_fb_create(struct drm_device *dev, struct drm_file *file,
		       const struct drm_mode_fb_cmd2 *cmd)
{
	struct mtk_drm_fb *mtk_fb = NULL;
	struct drm_gem_object *gem = NULL;
	struct mtk_drm_gem_obj *mtk_gem = NULL;
	unsigned int width = cmd->width;
	unsigned int height = cmd->height;
	unsigned int size, bpp;
	int ret;

	if (cmd->pixel_format == DRM_FORMAT_C8)
		goto fb_init;

	gem = drm_gem_object_lookup(file, cmd->handles[0]);
	if (!gem)
		return ERR_PTR(-ENOENT);

	bpp = mtk_drm_format_plane_cpp(cmd->pixel_format, 0);
	size = (height - 1) * cmd->pitches[0] + width * bpp;
	size += cmd->offsets[0];

	mtk_gem = to_mtk_gem_obj(gem);

	if (disp_sec_cb.cb != NULL)
		DDPINFO("mtk_gem->sec %d\n", mtk_gem->sec);
	else if (cmd->modifier[0] & MTK_FMT_SECURE)
		mtk_gem->sec = true;

	//TO-DO: should need remove "!mtk_gem->sec"
	if (gem->size < size && !mtk_gem->sec) {
		DRM_ERROR("%s:%d, size:(%ld,%d), sec:%d\n",
			__func__, __LINE__,
			gem->size, size,
			mtk_gem->sec);
		DRM_ERROR("w:%d, h:%d, bpp:(%d,%d), pitch:%d, offset:%d\n",
			width, height,
			cmd->pixel_format, bpp,
			cmd->pitches[0],
			cmd->offsets[0]);
		ret = -EINVAL;
		goto unreference;
	}

fb_init:
	mtk_fb = mtk_drm_framebuffer_init(dev, cmd, gem);
	if (IS_ERR(mtk_fb)) {
		ret = PTR_ERR(mtk_fb);
		goto unreference;
	}

	return &mtk_fb->base;

unreference:
	drm_gem_object_put(gem);
	return ERR_PTR(ret);
}
