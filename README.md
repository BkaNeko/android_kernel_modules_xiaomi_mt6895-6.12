# kernel_xiaomi_mt6895-6.12

> **移植状态总览：** 见 [STATUS.md](STATUS.md)。
>
> **设备：** `xaga`（Redmi Note 11T Pro / POCO X4 GT / Redmi K50i），联发科天玑 8100（`MT6895`），运行 Android 16 / HyperOS 4，内核 Linux 6.12 GKI。
>
> **当前重点：** 显示链路自建（不再依赖 LK 交接）+ 系统启动完整打通（`sys.boot_completed=1`）。

---

## 项目简介

本仓库是 `xaga` 的 **Android 6.12 外部内核模块（OOT）移植树**：

| 项 | 说明 |
|---|---|
| **基础树** | OPPO 6.12 联发科模块树（`kernel_device_modules-6.12`，Kleaf / mgk 构建模型） |
| **移植来源** | 小米 5.10 ESK 内核（`../baselines/kernel/kernel_xiaomi_mt6895`，`16.2-rebase`）与官方 5.10 内核（`xaga-s-oss`） |
| **内核版本** | Linux 6.12（GKI 通用内核 + MTK mgk 规则），实测 `6.12.23-4k` |
| **配套内核源码** | OPPO 6.12 内核基础（`../android_kernel_oddo_mt6895`） |

---

## 当前状态

### 🟢 已在真机验证

- **内核与用户空间启动：** 6.12 GKI 内核可完整引导进 Android 用户空间，`init`、`zygote64`、`system_server`、`SurfaceFlinger`、`DisplayManagerService`、`hwcomposer` 均正常运行。
- **硬件加密与安全：** Microtrust Beanpod TEE 520（`isee`）工作正常，负责 KeyMint 与 `/data` 的 FBE 解密。
- **存储：** UFS 3.1 稳定，`mt6363_vufs12` / `mt6363_vufs18` 常开电源域，无 I/O 错误。
- **显示子系统：** MTK DRM v2、DSI、DSC 与 L16 双面板（`panel-l16`）可初始化并扫描输出。
- **外设驱动：** Goodix 电容指纹（`goodix_cap`，已适配 6.12 SPI API）、Novatek NVT36672C 触摸、AW86927 触觉、`bq28z610` 电量计、`ln8000`/`sc8551` 双电荷泵、平台电源管理。
- **Mali CSF 基础设施：** `mali_kbase_mt6895.ko`、`mali_mgm.ko`、`mali_prot_alloc.ko` 编译干净，导出 `/dev/mali0`，可向 MCU 地址空间（AS0）加载 CSF 固件，并接入 `gpufreq_v2` 与 `ged.ko`。
- **FHCTL 跳频控制：** 已切换到 MCUPM v2，并通过 `-EPROBE_DEFER` 正确处理依赖顺序，`[FHCTL] !_inited` 已消除。

### 🟡 正在推进

- **SurfaceFlinger 交接：** 显示通路可由内核自行建立并扫描输出，但 SurfaceFlinger 帧的稳定接管仍在验证。详见下节「显示链路攻坚记录」。
- **GPU 3D 加速：** Mali CSF 一致性（coherency）与 AS1 页表相关告警仍在收敛。

---

## 显示链路攻坚记录

这是本轮移植中最关键、也最容易踩坑的环节。记录已确认的机制与对应修复，避免后续重复走弯路。

### 1. LK（Bootloader）留下的图层不可用

实测寄存器快照：

```
LK state before config  OVL0 EN=0xe00001  SRC_CON=0x2  ROI=0x99c021c
                        L1 CON=0x21ff  PITCH=0x10e0  ADDR=0xfeb89000
```

含义：

- LK 的 logo 图层在 **OVL0 的 L1**（`SRC_CON=0x2` 即 bit1），不在 L0；
- 宽度只有 **540**（`0x21c`，DSC 双 slice 的半宽），stride `4320`（`0x10e0`）；
- 所以 LK 交接过来只显示**半屏**。

**结论：** 任何「保留并复用 LK 图层」的方案都拿不到全屏画面，必须由内核重新建立完整通路。

### 2. 通路配置的总闸门：`mtk_drm_crtc_usage_enable()`

```c
/* 主屏分支 */
if (priv->ovl_usage[main_disp_idx] != 0 &&
    (priv->ovl_usage[main_disp_idx] & ~occupied_ovl) == 0) {
    DDPPR_ERR("main display ovl drained, occupied_ovl %x\n", occupied_ovl);
    return DISP_OPENING;      /* ← 关键 */
}
```

只要 LK 的图层仍占着 OVL，这里就返回 `DISP_OPENING`，于是：

```c
only_output = (usage == DISP_OPENING);
/* only_output 为真时：只配 DSI，OVL/RDMA/DSC/mutex/图层全部跳过 */
```

这是早期所有显示改动「改了没效果」的根本原因——全被挡在这个闸门外。

### 3. 图层编程依赖帧完成中断

MT6895 的 `mtk_mmsys_driver_data` **没有设置 `shadow_register`**（默认 `false`），于是：

```c
/* atomic_flush：仅当 shadow_register == true 才走这里 */
if (priv->data->shadow_register == true) {
    mtk_disp_mutex_acquire(mutex[0]);
    mtk_crtc_ddp_config(crtc);
    mtk_disp_mutex_release(mutex[0]);
}

/* 否则只能靠 DPP 帧完成中断 */
if (priv->data->shadow_register == false)
    mtk_crtc_ddp_config(crtc);      /* 位于 mtk_crtc_ddp_irq() */
```

自建通路时该中断路径不通，SurfaceFlinger 每帧提交会被静默丢弃，屏幕停留在 LK 残留画面，随后 LK framebuffer 被释放而转黑。

### 4. 宽度不一致：OVL 540 vs DSC 1080

实测：

```
OVL0  ROI    = 0x099c021c   → 2460 × 540
RDMA0 SIZE0  = 0x21c        → 540
DSC   ENC_W  = 0x0438021c   → enc_pic_width = 1080, enc_slice_width = 540
```

`cfg.w` 来自 `DSI_GET_VIRTUAL_WIDTH`，而新版面板驱动 `mediatek_drm_panel_drv` 返回的是 **LK 交接的 LCM 参数 `resolution[0] = 540`**，整条通路于是被配成半宽，而 DSC 仍按 1080 编码——数据量差一半。

### 5. 路径长度被重复计算

```c
#define __mtk_crtc_path_len(...)  (ovl_comp_nr + ddp_comp_nr)
```

MT6895 的 `path[]` 数组**本身已包含 OVL**（开头即 `OVL1_2L, OVL0`）。若再单独提供 `ovl_path`，长度会变成 `24 + 3 = 27`，组件索引整体错位。对比 MT6985 的 `path[]` 从 `DLI_ASYNC0` 开始、不含 OVL，才适合单独给 `ovl_path`。

### 对应修复

| 位置 | 修复 |
|---|---|
| `mtk_drm_drv.c` | 判断 LK 未编程通路（OVL `SRC_CON` 图层掩码为空）时跳过交接路径，走普通 enable |
| `mtk_drm_crtc.c` | `mtk_drm_crtc_usage_enable()` 在未接管 LK framebuffer 时返回 `DISP_ENABLE` |
| `mtk_drm_crtc.c` | `mtk_drm_crtc_init_para()` 改为幂等，可从普通 enable 路径调用 |
| `mtk_drm_crtc.c` | crtc0 在 `shadow_register == false` 时于 flush 阶段编程 pending planes |
| `mtk_dsi.c` | 虚拟宽度强制跟随 CRTC 模式宽度（1080），不再采用被改小的 LCM 值 |
| `mtk_disp_ovl.c` | 保留 bootloader 已启用图层的 `RDMA_CTRL`；启用真实图层时清除 `FORCE_RELAY` |
| `mtk_drm_drv.c` | 撤销多余的 `ovl_path` 表，恢复 `path_len` 正确性 |

### 诊断能力

树内保留了以下排查手段（发布前需清理）：

- 构建指纹打印、`videolfb` tag 上报；
- 首次配置前/后的全量寄存器快照：MUTEX / OVL L0–L3 / RDMA0 / DSC / DSI / XBAR；
- `cmdq` 超时回调中的安全寄存器读取与通路状态；
- `ddp_config` 各提前返回点的限流日志（`busy` / `pending_planes`）。

---

## 系统启动阻塞：AW86927 触觉

`system_server` 曾无限循环：

```
Tried to start aidl service android.hardware.vibrator.IVibrator/vibratorfeature  ×55
init: Could not find 'aidl/.../vibratorfeature' for ctl.interface_start
```

排查结论（以 5.10 正常工作状态为基准）：

```
5.10 上 /sys/class/leds/ 只有 lcd-backlight（没有 vibrator！）
HAL : vendor.xiaomi.hardware.vibratorfeature.service
实例: android.hardware.vibrator.IVibrator/default
硬件: AW86927 haptic（i2c1 / 0x5A），内核线程 [aw86927_vibrato]
```

即 **xaga 的振动器是 I2C 上的 AW86927，与 `regulator-vibrator` 无关**。

根因：`xiaomi-mt6895-common.dtsi` 定义了 `aw8697_haptic@5a` 节点，但 `mt6895.dts` 从未 include 该文件 → DTB 中没有设备 → `haptic.ko`（一直在 `modules.load` 中）无设备可绑 → HAL 失败 → `boot_completed` 永不置位。

修复：新增 `xaga-aw8697-haptic.dtsi`，从 common 抽出节点与 pinctrl，由 `mt6895.dts` include，避免引入整个 common 干扰现有显示配置。

---

## 目录结构

```
kernel_device_modules-6.12/                 主模块树（Kleaf/BUILD.bazel + Kbuild 双构建路径）
├── arch/arm64/boot/dts/mediatek/
│   ├── mt6895.dts                          板级主 DTS
│   └── xaga-aw8697-haptic.dtsi             振动器节点
├── drivers/gpu/drm/mediatek/mediatek_v2/   显示核心（DRM/DSI/DSC/OVL/RDMA）
├── drivers/gpu/mediatek/mali-valhall/      Mali CSF GPU
└── drivers/input/misc/aw8697_haptic/       AW8697 / AW86927 触觉
build.sh                                    一键编译打包脚本
STATUS.md                                   移植状态总览
BRINGUP.md                                  上电与对齐指南
xaga-drm-restore.md                         MTK DRM 依赖链恢复指南
xaga-log-capture.md                         日志抓取方法（XAGR 环缓冲、expdb、panic 调试）
README.md                                   本文件
```

---

## 上游来源

本代码库部分内容来自以下公开仓库：

- **[XagaForge/android_kernel_xiaomi_mt6895](https://github.com/XagaForge/android_kernel_xiaomi_mt6895)** — xaga 社区 GKI 5.10 内核，提供板级 DTS 与小米驱动（`panel-l16`、触摸、充电、触觉 OOT 驱动）。
- **[ramabondanp/alps-kernel_device_modules-6.12](https://github.com/ramabondanp/alps-kernel_device_modules-6.12)** — MTK ALPS 6.12 OOT 模块树，提供平台模块、DRM 依赖链与 `BUILD.bazel` / `mgk_64.bzl` 映射参考。
- **[RengokuSensei/android_kernel_modules_xiaomi_mt6895-6.12](https://github.com/RengokuSensei/android_kernel_modules_xiaomi_mt6895-6.12)** — 本移植的上游演进分支（Run 系列提交），FHCTL/MCUPM 依赖顺序修复即来自其 Run 102。

其他基础来源：OPPO 6.12 内核与模块树、小米 5.10 官方内核、LineageOS xaga 源码。

---

## 编译

在包含配套内核（`../android_kernel_oddo_mt6895`）的完整工作区中，`./build.sh` 完成全量编译与打包。

### 流程

1. **配置：** `gki_defconfig` + `mgk_64_k612_defconfig` + `vendor/xaga.config`
2. **内核镜像：** `Image` + `Image.gz`
3. **树内模块：** 生成 / 刷新 `Module.symvers`
4. **外部模块：** 编译 **230+ 个 `.ko`**（`make M=`）
5. **DTS 编译：** `mt6895.dtb`（SoC 基础）+ `xaga.dtbo` / `xaga_global.dtbo`（经 `fdtoverlay` 校验）
6. **镜像打包：**
   - `images/out/boot_new.img` — `magiskboot -n`：`Image.gz` + KernelSU
   - `images/out/vendor_boot_new.img` — `mkbootimg`：官方 vendor ramdisk + 6.12 `.ko`（`llvm-strip --strip-debug`，约 25MB）+ 重建 `modules.load` / `modules.dep`
   - `images/out/dtbo_new.img` — DTOv1 格式

### 常用命令

```bash
./build.sh                        # 全量编译 + 打包，输出到 images/out/
./build.sh --modules-only         # 仅编译模块，不打包镜像
./build.sh --no-clean             # 增量编译
./build.sh --skip=BOOT,VENDOR     # 跳过指定镜像打包
./build.sh --help
```

### 环境变量

| 变量 | 说明 |
|---|---|
| `K` | 6.12 基础内核树路径（`android_kernel_oddo_mt6895`） |
| `M` | 模块树路径（`./kernel_device_modules-6.12`） |
| `LLVM_PREFIX` | AOSP Clang 工具链路径（推荐 **clang-r536225**） |
| `JOBS` | 并行编译任务数（默认 `nproc`） |
| `OFFICIAL` | 官方系统镜像目录（用于提取 vendor ramdisk） |
| `VENDOR_RAMDISK_LZ4` | 官方 vendor ramdisk 完整包 |

### 刷机

```bash
sudo sh images/out/shua.sh        # 刷入 dtbo_a / boot_a / vendor_boot_a（A 槽）
```

> 注意：不要使用 `fastboot reboot`，请手动重启以保证槽位与镜像一致。

---

## 已移植组件（来自 5.10 基线）

全部驱动注册在 Kleaf 的 `kernel/kleaf/mgk_64.bzl` 与 `BUILD.bazel` 中：

| 模块 | 说明 |
|---|---|
| **goodix_cap** | Goodix GF3626ZS9 电容指纹（适配 6.12 SPI API） |
| **simtray** | SIM 卡托状态检测 |
| **hwid** | `/sys/hwid` 硬件板型识别 |
| **xiaomi_touch + double_click** | 小米触摸框架 + 双击唤醒 |
| **NVT36672C** | Novatek SPI 触摸屏（适配 6.12） |
| **aw8697 haptic** | 艾为线性触觉马达（AW8697 / AW86927） |
| **leds-ktz8863a + panel-l16 ×2** | 背光控制器 + L16 DSC 双面板（含 ESD 恢复） |
| **ln8000 / sc8551 / sc8561 / bq28z610** | 双电荷泵 + 电量计（`bms` power supply） |
| **pd_cp_manager + 充电框架** | 完整 `mtk_charger` / `mtk_pd_*` 套件 |
| **6 颗摄像头传感器** | `s5khm2`、`s5k4h7`、`ov16a1`、`s5kgw1`、`gc02m1`、`ov02b10`（`src-v4l2`） |
| **KTD2687 闪光灯** | 双 LED 相机闪光 + 闪光子系统接线 |
| **MTK Pump Express** | `pep`/`pep20`/`pep40`/`pep45`/`pep50`/`pep50p` 快充协议 |
| **MTK 平台模块（123 个 ko）** | 与 ALPS 树同步的完整平台模块套件 |
| **MTK DRM 子系统（60+ 模块）** | `mediatek_v2`（80+ 文件）、`mml`、`gpufreq v2`、`slbc`、`system_heap`、`mmdvfs`、`vmm`（0 未定义符号） |
| **Microtrust Beanpod TEE 520（`isee`）** | KeyMint 与用户数据解密驱动 |
| **Mali Valhall GPU** | Dimensity 8100 Mali-G610 MC6 CSF 驱动，接入 MT6895 DVFS、电源管理与 Android HAL（`r54p1-11eac0`） |

### Mali Valhall CSF 架构要点

- **CSF 后端：** 直接命令流前端（`MALI_USE_CSF=1`），对接 Valhall（Mali-G610 MC6）硬件调度器。
- **VMA 与内存子系统：** 迁移到 6.12 的 `vm_flags_set()` / `vm_flags_clear()`，DMA-BUF attach 外层加 `dma_resv_lock()`；`thirdparty/mali_kbase_mmap.c` 改用 `current->mm->get_unmapped_area()`。
- **一致性（Coherency）：** 采用硬件原生 `COHERENCY_ACE_LITE`，DTS 中 `system-coherency = <0>`，并启用 `L2_MMU_CONFIG_ALLOW_SNOOP_DISPARITY`。
- **ACP 上电序列：** 保留 MT6895 `mali_hw_seq_mask=7`（寄存器 `0x168`、`0x8E0..0x928`），保证 CPU/GPU 共享缓存行同步。

---

## 已知问题与后续计划

### 待解决

1. **SurfaceFlinger 稳定接管** — 内核可建立通路并扫描输出，但 SF 帧接管需继续验证（关注日志 `free frame buffer` 是否出现、OVL 是否切到 SF 图层）。
2. **GPU 3D 加速一致性** — AS1 页表与 coherency 告警仍在收敛（`mali: Flush for GPU page table update did not complete`）。
3. **USB gadget 稳定性** — 6.12 上 `mtu3` 出现 `gadget SUSPEND` / `RESET` 循环，adb 可用但不稳。抓日志建议「启动 60s → fastboot → 读取 `/data/local/tmp`」。
4. **KernelSU** — LKM 版（`6.12.76-4k`）与本地 `6.12.23` vermagic 不匹配，需改为 `CONFIG_KSU=y` 内建编译。

### 下一步

1. 完成 SurfaceFlinger 帧接管，确认画面全宽 1080 且图层切换正常。
2. 清理移植期调试代码（`xaga.no_reboot`、`xaga_boot` kthread、`/proc/xaga_status`、强制 `enforcing=0` 等）后发布。
3. 恢复并验证 DVFS / MMQOS 策略。
4. 充电、PD 快充、摄像头、指纹全链路功能验证。

---

## 许可证

内核与模块遵循 GNU General Public License（GPL），具体见各源文件声明。
