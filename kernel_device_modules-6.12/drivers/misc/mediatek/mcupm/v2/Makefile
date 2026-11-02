# SPDX-License-Identifier: GPL-2.0
ccflags-y += -I$(DEVICE_MODULES_PATH)/drivers/misc/mediatek/mcupm/include
ccflags-y += -I$(DEVICE_MODULES_PATH)/drivers/misc/mediatek/mcupm/v2

obj-$(CONFIG_MTK_TINYSYS_MCUPM_SUPPORT) += mcupm.o
mcupm-y += mcupm_driver.o
mcupm-y += mcupm_plt.o
mcupm-y += mcupm_logger.o
mcupm-y += mcupm_timesync.o

