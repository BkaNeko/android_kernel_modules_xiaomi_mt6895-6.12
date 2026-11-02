# MT6895 CSF 固件逆向：GPU 卡在 CLEAN_CACHES_COMPLETED

> 对象：`/vendor/firmware/mali_csffw.bin`（282624 字节，md5 `5594d779d10bb95dcd24f6f577a874da`）
> 对应内核 DDK：`r54p1-11eac0`；用户态 GLES：`v1.r54p1-11eac0`（版本一致，非版本问题）
> 结论时间：2026-11-03

## 1. 固件镜像格式

| 字段 | 值 |
|---|---|
| magic | `0xC3F13A6E` |
| version | `3` |
| 头部长度 | `0x14` |
| entry 头 | `u32`：`type = h & 0xFF`、`size = (h >> 8) & 0xFF`（**单位字节，含 header**）、`bit30 = updatable`、`bit31 = optional` |
| 首个 entry 偏移 | `0x14` |

entry 类型：`0` interface、`1` configuration、`3` trace buffer、`4` timeline metadata、
`6` build info、`7` func call list、`8` page fault cnt、`9` core dump。

### 内存布局（interface entry）

字段顺序：`flags, virtual_start, virtual_end, data_start, data_end`

| # | flags | VA 区间 | 文件偏移 | 用途 |
|---|---|---|---|---|
| 0 | `0x9` | `0x00400000-0x00410000` | `0x131c-0x1398` | MCU 接口页 |
| 1 | `0x9` | `0x00410000-0x00420000` | `0x13a0-0x26c4` | MCU 接口页 |
| 2 | `0x9` | `0x00000000-0x00010000` | — | 低地址 |
| 3 | `0xd` | **`0x00800000-0x00820000`** | **`0x26c4-0x16a50`** | **代码段（0x1438c 字节）** |
| 4 | — | `0x02000000-0x02040000` | — | 栈/数据（SP=0x0202ff68 在此） |
| 5 | — | `0x01000000-0x01040000` | — | — |
| 6 | — | `0x03000000-0x03040000` | — | — |
| 7 | — | `0x04000000-0x04010000` | — | — |

**VA → 文件偏移换算**：`file = 0x26c4 + (VA - 0x800000)`（仅代码段）

## 2. 崩溃现场

```
Firmware hang detected at PC 0x00809e00 / 0x809e02 / 0x809e1c
===================== CSFFW Oops! =====================
Exception: SysTick
R0: 0x40003020   R4: 0x40033004   R11: 0x400320d4
R12: 0x0202b728  SP: 0x0202ff68   LR: 0x0081033b
CSHWIF0..3 is disabled
ITER_ENDPOINT_ALLOW_LO=0x130013   (6 个 shader 核)
ITER_ENDPOINT_READY_LO=0x0        (没有核 ready)
```

调用者 `LR = 0x81033b`（`BL` 在 `0x810336`）：做一次链表插入后调用缓存同步例程。

## 3. 崩溃函数反汇编（文件偏移 `0xc4c4`，VA `0x809dec`）

```asm
809dec: movw r0, #0xbe70
809df0: movt r0, #0x202          ; r0 = 0x0202be70 （RAM 里的 pending 标志）
809df4: ldr  r1, [r0]
809df6: movw r0, #0x3020
809dfa: movt r0, #0x4000         ; r0 = 0x40003020  GPU_IRQ_RAWSTAT (MCU 视角)
809dfe: cbz  r1, 0x809e12
809e00: ldr  r1, [r0]            ; ← 崩溃 PC
809e02: tst.w r1, #0x20000       ; CLEAN_CACHES_COMPLETED (bit17)
809e06: beq  0x809e00            ; ★ 死循环等待
809e08: mov.w r1, #0x20000
809e0c: str  r1, [r0, #0x4]      ; GPU_IRQ_CLEAR
809e0e: movs r1, #0x0
809e10: b    0x809e14
809e12: movs r1, #0x1
809e14: movs r2, #4
809e16: movt r2, #0x2            ; r2 = 0x00020004
809e1a: str  r2, [r0, #0x10]     ; GPU_COMMAND = 0x00020004
809e1c: ldr  r2, [r0]            ; ← 崩溃 PC
809e1e: tst.w r2, #0x20000
809e22: beq  0x809e1c            ; ★ 再次死循环等待
809e24: cbz  r1, 0x809e2c
809e26: mov.w r1, #0x20000
809e2a: str  r1, [r0, #0x4]      ; GPU_IRQ_CLEAR
809e2c: bx   lr
```

这是一个**带 pending 标志的缓存清理合并逻辑**（与内核 `kbase_gpu_flush_caches()` /
`cache_clean_in_progress` 的设计完全对应）：

1. 若 pending 置位，先等上一次清理完成并清中断；
2. 发 `GPU_COMMAND`；
3. 等 `CLEAN_CACHES_COMPLETED` 置位；
4. 若本次不是"续等"，保留该位给下一次观察。

**结论：固件在等 GPU 硬件的「缓存清理完成」中断，该中断永不产生。**

## 4. 寄存器对照表（MCU 视角 ↔ AP 视角）

MCU 看到的 GPU 寄存器块基址是 `0x40003000`，AP 是 `0x13000000`（同一寄存器组，偏移相同）。

| MCU 地址 | 偏移 | AP 地址 | 名称 | 说明 |
|---|---|---|---|---|
| `0x40003020` | `0x20` | `0x13003020` | `GPU_IRQ_RAWSTAT` | **未被掩码的原始中断状态** ← 固件就在读它 |
| `0x40003024` | `0x24` | `0x13003024` | `GPU_IRQ_CLEAR` | 写 1 清对应位 |
| `0x40003028` | `0x28` | `0x13003028` | `GPU_IRQ_MASK` | 中断掩码 |
| `0x4000302c` | `0x2c` | `0x1300302c` | `GPU_IRQ_STATUS` | 掩码后的状态 |
| `0x40003030` | `0x30` | `0x13003030` | `GPU_COMMAND` | 命令寄存器 |
| — | `0x34` | `0x13003034` | `GPU_STATUS` | 全局状态 |
| `0x400320d4` | `0x20d4` | `0x130020d4` | （MCU 侧私有） | 崩溃快照 R11 |
| `0x40033004` | `0x3004` | `0x13003004` | （MCU 侧私有） | 崩溃快照 R4 |

### 相关中断位（`GPU_IRQ_*`）

| bit | 值 | 名称 |
|---|---|---|
| 0 | `0x1` | `GPU_FAULT` |
| 1 | `0x2` | `GPU_PROTECTED_FAULT` |
| 8 | `0x100` | `RESET_COMPLETED` |
| 9 | `0x200` | `POWER_CHANGED_SINGLE` |
| 10 | `0x400` | `POWER_CHANGED_ALL` |
| 16 | `0x10000` | `PRFCNT_SAMPLE_COMPLETED` |
| **17** | **`0x20000`** | **`CLEAN_CACHES_COMPLETED`** ← 卡在这里 |
| 18 | `0x40000` | `DOORBELL_MIRROR` |
| 19 | `0x80000` | `MCU_STATUS_GPU_IRQ` |

## 5. GPU_COMMAND 编码（CSF）

```c
#define GPU_COMMAND_CODE_PAYLOAD(opcode, payload) ((u32)opcode | ((u32)payload << 8))
```

| code | 名称 |
|---|---|
| `0x00` | `NOP` |
| `0x01` | `RESET` |
| `0x03` | `TIME` |
| **`0x04`** | **`FLUSH_CACHES`** |
| `0x05` | `SET_PROTECTED_MODE` |
| `0x06` | `FINISH_HALT` |
| `0x07` | `CLEAR_FAULT` |
| `0x08` | `FLUSH_PA_RANGE` |

payload 位（左移 8）：L2 `[1:0]`（`001` clean、`003` clean+invalidate）、
LSC `[5:4]`（`0x10` clean、`0x30` clean+invalidate）、OTHER `bit9`（`0x200` invalidate）。

对照：

| 来源 | 写入 GPU_COMMAND 的值 | 解码 |
|---|---|---|
| **固件** | `0x00020004` | `FLUSH_CACHES` + `OTHER_INVALIDATE` |
| **内核** | `0x00003304` | `FLUSH_CACHES` + L2 clean+invalidate + LSC clean+invalidate |

**两者都是合法的 CSF 编码**（已核对：我们的 `GPU_COMMAND_CODE_PAYLOAD` 与 5.10
能正常工作的 r54 驱动完全一致，都是 `<< 8`）。所以**不是命令编码错误**。

## 6. 已排除的可能

| 假设 | 排除依据 |
|---|---|
| 内核/用户态 Mali 版本不匹配 | 两者都是 `r54p1-11eac0` |
| GPU_COMMAND 编码用错（JM vs CSF） | 我们的 csf_macros 宏与 5.10 逐字一致，写入 `0x3304` 合法 |
| 固件读的是被掩码的 STAT | 固件读 `+0x20` = `RAWSTAT`，不受 MASK 影响 |
| 只配了半宽/显示链路问题 | 显示已单独验证正常（全宽 logo） |
| shader/tiler 未上电 | `xaga_prepower` 已开启，PRESENT/READY/PWRTRANS 均匹配 |

## 7. 因果链（当前认定）

```
GPU 硬件不执行 FLUSH_CACHES
  → CLEAN_CACHES_COMPLETED 永不置位
  ├─ 内核侧：busy_wait_cache_operation() 超时
  │           "Cache clean timed out … unstable GPU clk/pwr"
  │           → kbase_prepare_to_reset_gpu → GPU reset
  └─ 固件侧：0x809e00 死循环 → SysTick → CSFFW Oops
              → CSHWIF0..3 disabled
              → KCPU fence 永不 signal（445 条阻塞）
  → SurfaceFlinger 卡死 → Watchdog 杀 system_server
  → bootanim 永不结束 → boot_completed 不置位 + 屏幕黑
```

时间线佐证：18s 内核首次缓存清理超时 → 33s 固件崩 → 之后 SHAREABILITY_FAULT /
"Unsuccessful GPU reset" 刷屏（都是次生现象）。

## 8. 下一步需要的现场数据

已加入诊断（`device/mali_kbase_device_hw.c`）：缓存清理失败时打印

```
xaga: cache-clean stuck RAWSTAT=… MASK=… STAT=… GPU_STATUS=… in_progress=… host_pwr_iface=…
xaga: power PWR_IRQ_RAWSTAT=… PWR_IRQ_MASK=… PWR_IRQ_STATUS=… PWR_STATUS=…
```

判读：

| 现象 | 结论 |
|---|---|
| `host_pwr_iface=1` 且 `PWR_STATUS` 显示核未 ready | 走 HOST_POWER 协议却未完成 → 我们的 `xaga_prepower` 直写 PWRON 绕过了协议，可能反而破坏了状态 |
| `host_pwr_iface=0` | 电源由固件代理，MCU 未运行时核无法真正上电（先有鸡还是先有蛋） |
| `GPU_STATUS` 有异常位 | 直接按位查规范 |
| `RAWSTAT` 里连 `RESET_COMPLETED` 都没有 | GPU 处于复位状态，命令全被丢弃 |

### 现场验证手段（无需重编）

```bash
# 读原始状态
echo "r 0x13003020" > /proc/xaga_reg      # RAWSTAT
echo "r 0x13003034" > /proc/xaga_reg      # GPU_STATUS
echo "d 0x13000800 12" > /proc/xaga_reg   # HOST_POWER 块

# 手动发一次 L2+LSC 清理，看 bit17 是否置位
echo "w 0x13003024 0x20000"  > /proc/xaga_reg   # 清旧位
echo "w 0x13003030 0x00003304" > /proc/xaga_reg # FLUSH_CACHES(L2+LSC cln+inv)
sleep 1
echo "r 0x13003020" > /proc/xaga_reg            # 应出现 bit17
dmesg | grep xaga_reg | tail -3
```

若手动发命令后 bit17 仍不置位，则确认硬件/电源层面问题，而非命令或编码问题。

## 9. 补充：时钟与 MFG 包装层（round 2）

### 时钟已确认正常

真机日志：

```
[CSF CLK] clk_prepare_enable(bg3d) = 0 / (pll_main) = 0 / (pll_sc) = 0
[CSF CLK CCF] mux_0: rate=429999955 Hz | mux_1: rate=385000031 Hz
[CSF CLK FMETER] MFGPLL calc=430000 kHz fmeter=430015 kHz | MFGSCPLL calc=385000 fmeter=385023 kHz
[CSF CLK] CLK_CFG_30 read-back: 0xff030000 (bits 16:17 = 1:1)
```

`mt6895_acquire_clocks()` 拿到了 DT 里全部 9 个时钟（`mfgcfg_bg3d`、`mfg_ao_mfgpll`、
`mfgsc_ao_mfgscpll`、`mfg_sel_0/1`、`mfgpll_ck`、`mfgscpll_ck`、`mfg_ref_ck`、
`mfgsc_ref_ck`），使能全部返回 0，两个 PLL 均锁定且 fmeter 与计算值一致。
**所以"时钟没开"不成立。**

### 真正可疑处：手写的 platform 代码

| 文件 | 行数 | 说明 |
|---|---|---|
| `platform/mt6895/mali_kbase_config_mt6895.c`（我们） | 910 | 含 `mt6895_acquire_clocks` / `mt6895_power_on_clocks` / `mt6895_power_off_clocks` / `mt6895_pdca_config` / `mt6895_apply_stock_hw_sequences` / `xaga_prepower_cores` |
| 同文件（5.10 r54 能正常工作） | 506 | 只有标准 `pm_callback_*`，时钟由通用 `kbase_pm` 走 DT 列表 |

也就是说：**我们的时钟上电序列和 MFG 包装层初始化都是手写反向出来的**，不是 5.10 的原路径。

`mt6895_apply_stock_hw_sequences()`（mask=0x7）当前做：

- **bit0** I2M Protector：`0x13fbf000+0xF60..0xFA8`，末写 `0x20300317`（`GPM_ENABLE`）
- **bit1** DCM：`MFG_DCM_CON_0(0x010)`、`MFG_ASYNC_CON_1(0x024)`、`MFG_GLOBAL_CON(0x0B0)`、
  `MFG_QCHANNEL_CON(0x0B4)` 置 bit4、`MFG_RPC_AO_CLK_CFG(0x13f91034)` 清 bit0、
  MFGRPC AXI protect 清 `0x000f000f`
- **bit2** ACP 一致性序列：`0x168`、`0x8E0..0x928`

`xaga_prepower_cores()` 则直接写 `STACK/SHADER/TILER_PWRON`（0xE20 / 0x180 / 0x190）
并轮询 `READY` / `PWRTRANS`，然后清 `GPU_IRQ_CLEAR(0x024)` 与 `MCU_GPU_IRQ_CLEAR(0x3024)`。

**注意**：直写 `PWRON` 是"旧式/无 host power interface"的做法。若
`has_host_pwr_iface == 1`（`KBASE_HW_FEATURE_POWER_CONTROL`），DDK 本应通过
`PWR_COMMAND`(0x828) / `PWR_CMDARG`(0x830) / `PWR_STATUS`(0x820) 握手，直写 `PWRON`
会绕过这套状态机。这是目前最可疑的单点。

### 下轮判据（新代码已会打印）

```
xaga: cache-clean stuck … host_pwr_iface=?
xaga: power PWR_IRQ_RAWSTAT=… PWR_STATUS=…
```

- `host_pwr_iface=1` → 我们的 prepower 绕过协议 → 改为让 DDK 走 `PWR_COMMAND`，
  或把 prepower 限定在 `host_pwr_iface==0` 时执行
- `host_pwr_iface=0` → 直写 PWRON 正确，问题在 MFG 包装层某个序列（对比 5.10 的
  `0x13fbf0xx` 初值）

## 10. 根因（round 3）：官方 GPU 电源序列被移除，MTCMOS/BUCK 从未执行

### 对照 5.10（同芯片、能正常工作）

```c
/* 5.10 r54-test, platform/mt6895/mali_kbase_config_mt6895.c */
if (!gpufreq_power_ctrl_enable()) { ... return 0; }
...
/* on,off/ SWCG(BG3D)/ MTCMOS/ BUCK */
if (gpufreq_power_control(GPU_PWR_ON) < 0) { ... }
```

### 我们 6.12 的版本

```c
/* xaga: no gpufreq/GPUEB call here. The whole AOC/Buck/MTCMOS/Clock
 * sequence is executed locally below ... */
```

往下实际只有 **读** SPM/INFRACFG/MFGRPC 状态做打印 + 手写时钟序列
（`mt6895_power_on_clocks`）与 `mt6895_pdca_config`。**没有任何代码真正打开
MTCMOS 电源域或设置 BUCK 电压。**

`grep gpufreq_power_control` 在 6.12 platform 文件里只有一行注释命中。

### 后果链

```
5.10: gpufreq_power_control(GPU_PWR_ON)
        → SWCG(BG3D) → MTCMOS → BUCK 按官方顺序
我们: 只开时钟，MTCMOS/BUCK 未执行
  → GPU 的电源状态机停在未完成状态（PWR_STATUS 不匹配 / L2 未真正上电）
  → GPU_COMMAND(FLUSH_CACHES) 被丢弃
  → CLEAN_CACHES_COMPLETED(bit17) 永不置位
  ├─ 内核 busy_wait_cache_operation() 超时 → GPU reset
  └─ 固件 0x809e00 死循环 → CSFFW Oops → CSHWIF0..3 关闭
```

旁证：6.12 代码里留着 `xaga_keep_gpu_on` 参数与注释
> "re-initialising the CSF firmware on every runtime power cycle fails
>  ('Firmware initialization failed')"

—— 正是电源序列不完整导致断电/上电后 GPU 无法回到确定状态，才被迫用
"永不关 GPU"来绕过。

### 修复

`platform/mt6895/mali_kbase_config_mt6895.c`：

```c
/* 上电 */
if (!mtk_common_gpufreq_bringup()) {
    int pwr_ret = gpufreq_power_control(GPU_PWR_ON);
    dev_info(kbdev->dev, "xaga: gpufreq_power_control(ON) = %d\n", pwr_ret);
}

/* 下电（对称） */
if (!mtk_common_gpufreq_bringup()) {
    int pwr_ret = gpufreq_power_control(GPU_PWR_OFF);
    dev_info(kbdev->dev, "xaga: gpufreq_power_control(OFF) = %d\n", pwr_ret);
}
```

`gpufreq_power_control()` 的行为（`gpufreq/v2/gpufreq_v2.c:833`）：

- `gpufreq_power_ctrl_enable()` 为假 → 直接返回成功；
- GPUEB 就绪 → 走 IPI `CMD_POWER_CONTROL` 交给 GPUEB；
- 否则 → 调用 AP 侧 `gpufreq_fp->power_control()`（SWCG/MTCMOS/BUCK）。

即：**GPUEB 没起来时会自动回落到 AP 路径**，正是 bring-up 阶段需要的。

已验证：`mali_kbase_mt6895.ko` 出现未定义符号 `U gpufreq_power_control`，
`check_syms` 0 unresolved，`modules.load` 中 `mtk_gpufreq_mt6895`(207) 早于
`mali_kbase_mt6895`(230)。

### 下轮判据

```
xaga: gpufreq_power_control(ON) = 0        ← 官方序列执行成功
xaga: cache-clean stuck …                  ← 应消失
Firmware hang detected                     ← 应为 0
```

## 11. 更深一层根因（round 4）：GPUEB 的 IPI 通道表解析错位

### 现象

```
[GPU/EB] gpueb_ipidev (with 8 IPI) has registered.
[FHCTL-DIAG] [GPUEB] ipi_get channel_id: 4
[FHCTL-DIAG] [GPUEB] ipi_register fail, ret -3      ← IPI_UNAVAILABLE
[FHCTL-DIAG] [GPUEB] init failed for pll mfgpll: -517
```

`-3` = `IPI_UNAVAILABLE`（`include/linux/soc/mediatek/mtk_tinysys_ipi.h:113`
"can't find this ipi pin define"），来自
`mtk_ipi_register()`：`if (!ipidev->table[ipi_id].pin_recv) return IPI_UNAVAILABLE;`

### 原因：recv-table 每条元素个数与 DT 不一致

`drivers/gpu/mediatek/gpueb/gpueb_ipi.c`：

```c
enum table_item_num {
    send_item_num = 3,
    recv_item_num = 5,      /* ← 5.10 是 4 */
};
gpueb_mboxdev.recv_count = cnt_elems / recv_item_num;
...
i * recv_item_num,     /* chan_id */
i * recv_item_num + 1, /* mbox   */
i * recv_item_num + 2, /* msg_size */
i * recv_item_num + 3, /* recv_opt */
i * recv_item_num + 4, /* cb_opt（5.10 没有这个字段）*/
```

而 DT（`mt6895.dts` 的 `gpueb@13c00000`）每条 recv 只有 **4** 个数：

```
recv-table = <0 0 4 0>, <1 0 8 1>, <2 0 1 0>, <3 0 1 0>,
             <4 0 1 1>, <5 0 4 1>, <6 0 1 1>, <7 0 6 1>;
```

32 个元素 / 5 = **6**（应为 8），且 `chan_id` 全部按步长 5 错位读取。
通道 4（`IPI_ID_FHCTL`）因此没有 recv pin → `IPI_UNAVAILABLE`。

更糟的是 `+4`（cb_opt）这一读：stride=4 时 `i=7` 会索引第 32 个元素（越界），
读取失败后 `return false`，**整个 IPI 表初始化直接失败**。

### 后果

GPUEB 的 IPI 全不可用 →

- `clk-fhctl-gpueb` 的 gpu0/gpu2/gpu3 全部 init 失败（观察到的 `-517`）
- `gpufreq_v2` 给 GPUEB 发 `CMD_POWER_CONTROL` 走同一条 IPI → **发不出去**
- MT6895 的 AP 侧没有电源序列（`platform_eb_fp` 无 `.power_control`，
  `__gpufreq_power_control()` 是空实现直接 `return 1`），电源只能由 EB 执行
- ⇒ **GPU 永远得不到 MTCMOS/BUCK 上电** → `GPU_COMMAND(FLUSH_CACHES)` 被丢弃
  → `CLEAN_CACHES_COMPLETED` 永不置位 → 固件 `0x809e00` 死循环 → CSFFW Oops

### 修复

1. `recv_item_num` 改为 4（与 5.10 及本 DT 一致）；
2. 改为从 `recv-name-table` 推导每条元素个数（`cnt_elems / name_cnt`），
   同时兼容 4 词与 5 词布局；
3. `cb_opt(+4)` 仅在 stride > 4 时读取，否则默认 0 且不因越界中止初始化；
4. 增加诊断输出：`xaga: recv table <n> elems, stride <s>` 与
   `xaga: recv pins = 8 [0 1 2 3 4 5 6 7 ]`。

### 判据

```
xaga: recv table 32 elems, stride 4      ← 正确
xaga: recv pins = 8 [0 1 2 3 4 5 6 7 ]   ← 通道齐全
[FHCTL-DIAG] [GPUEB] ipi_register fail   ← 应消失
xaga: gpufreq_power_control(ON) = ...    ← 应不再返回负值
```
