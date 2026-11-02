/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Compatibility shims for the r54 GPU platform layer on 6.12.
 *
 * The r54 sources come from a 5.10 kernel, where this header papered over
 * interfaces that only existed in the 6.12 MTK GPU stack. On 6.12 almost
 * everything lives in the real headers, so only the helpers that the 6.12
 * tree still does not export are stubbed below.
 */
#ifndef _MTK_COMPAT_510_H_
#define _MTK_COMPAT_510_H_

#include <linux/types.h>
#include <ged_dvfs.h>
#include <mtk_gpufreq.h>
#include <gpufreq_v2.h>

/* Per-engine utilization counters: 6.12 GED only exports the combined one */
static inline int ged_dvfs_get_util_3d(void)
{
	return -1;
}

static inline int ged_dvfs_get_util_ta(void)
{
	return -1;
}

static inline int ged_dvfs_get_util_comp(void)
{
	return -1;
}

static inline int ged_dvfs_get_util_active(void)
{
	return -1;
}

#endif /* _MTK_COMPAT_510_H_ */
