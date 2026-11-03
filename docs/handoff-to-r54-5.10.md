# 交接：给 5.10 r54p1 树的可复用结论

> 来源：xaga (MT6895) 6.12 / OPPO 内核树上对同一份 `mali_csffw.bin` 与 CSF 驱动的逆向与实测。
> 目标树：`qqcandy-kernel-src/drivers/gpu/mediatek/mali-r54-test`（`r54p1-11eac0`，与本项目同版本）。
>
> 先说明边界：逐文件核对后，**5.10 的 r54 树在下列位置都是正确的**，本项目的大部分修复只是把 6.12
> 的偏离拉回它的行为。因此这份交接以「知识 + 工具 + 排除项」为主，不含需要 5.10 修的 bug。
> 逐项对照结论见文末 §6。

## 1. CSF 固件事实（版本无关，可直接用于 r54p1）

固件 `mali_csffw.bin`（本项目实测 md5 `5594d779d10bb95dcd24f6f577a874da`，git_sha `093dce3`，
在文件 `0x321`）。

### 镜像格式

| 项 | 值 |
|---|---|
| magic | `0xC3F13A6E` |
| version | `3` |
| 头部长度 | `0x14` |
| entry 头 | `u32`：`type = h & 0xFF`、`size = (h >> 8) & 0xFF`、`bit30 = updatable`、`bit31 = optional` |

**最容易踩的坑：`size` 的单位是「字节」且包含 header 本身**，不是字数。按字数解析会得到一堆
看似合法但错位的 entry。

interface entry 字段顺序：`flags, virtual_start, virtual_end, data_start, data_end`。

### 代码段位置（反汇编必需）

| 区间 | VA | 文件偏移 |
|---|---|---|
| 代码 | `0x00800000-0x00820000` | **`0x26c4 - 0x16a50`** |
| GLB/数据 | `0x01000000-0x01040000` 与 `0x02000000-0x02040000`（互为别名） | `0x16a50 - 0x42230` |

换算：`file = 0x26c4 + (VA - 0x800000)`。

反汇编准备：

```sh
llvm-objcopy --input-target=binary --output-target=elf32-littlearm \
  --binary-architecture=arm --rename-section .data=.text,code,readonly,alloc \
  fw_code.bin fw.elf
llvm-objdump -d --triple=thumbv7m-none-eabi --adjust-vma=0x800000 fw.elf
```

MCU 是 ARMv7-M 类核（Thumb-2，有 SysTick、CFSR 在 `0xE000ED28`）。

## 2. 「固件卡住」到底意味着什么

固件崩溃时会打印 `Firmware hang detected at PC 0x........` + `CSFFW Oops!`。其中两个 PC 值得记住：

- **`0x809e00` / `0x809e02` / `0x809e1c`** = 在等 `GPU_IRQ_RAWSTAT` 的
  **bit17 `CLEAN_CACHES_COMPLETED`**。这是「缓存清理命令发出去了，硬件没完成」。
- 反汇编（`VA 0x809dec`）：

```asm
809df6: movw r0,#0x3020 ; movt r0,#0x4000   ; GPU_IRQ_RAWSTAT (MCU 视角 0x40003020)
809e00: ldr  r1,[r0]
809e02: tst.w r1,#0x20000                   ; CLEAN_CACHES_COMPLETED
809e06: beq  0x809e00                       ; 死等
809e0c: str  r1,[r0,#4]                     ; GPU_IRQ_CLEAR
809e1a: str  r2,[r0,#0x10]                  ; GPU_COMMAND = 0x00020004
809e1c: ldr  r2,[r0] ; tst r2,#0x20000
809e22: beq  0x809e1c                       ; 再次死等
```

这是一个**带 pending 标志的缓存清理合并例程**，与内核 `kbase_gpu_flush_caches()` 的设计一一对应。
固件写 `0x00020004` = `GPU_COMMAND_CODE_FLUSH_CACHES(0x04) | (0x200 << 8)`，
`0x200` = `PAYLOAD_OTHER_INVALIDATE`。

> 注意：固件在 `0x809e00` 死循环**观测到的是 MCU 视角的 RAWSTAT**，不受内核 `GPU_IRQ_MASK` 影响。
> 所以「内核没开中断」这类推测不成立；看到这个 PC 就是硬件层没完成。

## 3. MCU ↔ AP 寄存器对照表（排查必用）

MCU 看到的 GPU 寄存器块基址是 `0x40003000`，AP 是 `0x13000000`，偏移相同。

| MCU | 偏移 | AP | 名称 |
|---|---|---|---|
| `0x40003020` | `0x20` | `0x13003020` | `GPU_IRQ_RAWSTAT`（未被掩码） |
| `0x40003024` | `0x24` | `0x13003024` | `GPU_IRQ_CLEAR` |
| `0x40003028` | `0x28` | `0x13003028` | `GPU_IRQ_MASK` |
| `0x4000302c` | `0x2c` | `0x1300302c` | `GPU_IRQ_STATUS`（掩码后） |
| `0x40003030` | `0x30` | `0x13003030` | `GPU_COMMAND` |
| — | `0x34` | `0x13003034` | `GPU_STATUS` |
| — | `0x304` | `0x13000304` | `COHERENCY_ENABLE` |

### `GPU_IRQ` 位

| bit | 值 | 名称 |
|---|---|---|
| 0 | `0x1` | `GPU_FAULT` |
| 1 | `0x2` | `GPU_PROTECTED_FAULT` |
| 8 | `0x100` | `RESET_COMPLETED` |
| 9 | `0x200` | `POWER_CHANGED_SINGLE` |
| 10 | `0x400` | `POWER_CHANGED_ALL` |
| 16 | `0x10000` | `PRFCNT_SAMPLE_COMPLETED` |
| **17** | **`0x20000`** | **`CLEAN_CACHES_COMPLETED`** |
| 18 | `0x40000` | `DOORBELL_MIRROR` |
| 19 | `0x80000` | `MCU_STATUS_GPU_IRQ` |

### `GPU_COMMAND` 在 r54（CSF）上的编码

```c
#define GPU_COMMAND_CODE_PAYLOAD(opcode, payload) ((u32)opcode | ((u32)payload << 8))
```

**是 `<< 8`，不是 `<< 16`**（用 `<<16` 去解码固件写的 `0x00020004` 会得到错误结论）。

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

payload 位（左移 8）：L2 `[1:0]`（`0x1` clean、`0x3` clean+invalidate）、
LSC `[5:4]`（`0x10` / `0x30`）、OTHER `bit9`（`0x200` invalidate）。

内核发的是 `0x3304`（L2+LSC clean+invalidate），合法。

## 4. 一个极有用的现场工具：任意寄存器读写

给内核加一个 `/proc` 节点，用 `ioremap` + `readl/writel` 直接读写物理地址，输出到 dmesg。
排查显示/GPU 这类问题比任何日志都直接（本项目靠它把「模糊怀疑」变成「确定结论」）。

支持三个命令即可：

```
echo "r 0x13003020"      > /proc/xaga_reg   # 读 32 位
echo "d 0x13000120 48"   > /proc/xaga_reg   # 连续读 48 个字
echo "w 0x13003030 0x3304" > /proc/xaga_reg # 写 32 位
```

### 用它做的决定性实验：验证「缓存清理到底能不能完成」

```sh
echo "w 0x13003024 0x20000"    > /proc/xaga_reg   # 清旧完成位
echo "w 0x13003030 0x00003304" > /proc/xaga_reg   # 手动发 FLUSH_CACHES(L2+LSC)
sleep 1
echo "r 0x13003020"            > /proc/xaga_reg   # 看 bit17 是否置位
```

- bit17 置位 → 硬件能清理，问题在内核调用时序
- bit17 不置位 → 硬件/电源/一致性层面，别再在内核等待逻辑里找

## 5. 把「unstable GPU clk/pwr」变成可判断的信号

`busy_wait_cache_operation()` 失败时只打印一句
`Stuck waiting on CLEAN_CACHES_COMPLETED bit, ...`，信息量太低。建议在失败分支补一份转储：

```c
dev_err(kbdev->dev,
    "cache-clean stuck RAWSTAT=0x%08x MASK=0x%08x STATUS=0x%08x GPU_STATUS=0x%08x "
    "in_progress=%d host_pwr_iface=%d\n", ...);
dev_err(kbdev->dev,
    "domains READY shader=%llx tiler=%llx l2=%llx stack=%llx | "
    "PWRTRANS shader=%llx tiler=%llx l2=%llx stack=%llx\n", ...);
```

两个实现注意点：

1. `kbase_reg_read32/64` **不加锁**（纯 `mali_readl/readq`），所以可以在持 `hwaccess_lock`
   的路径里直接调用，不会自死锁；但用 `lockdep_assert_held()` 把契约写清楚。
2. 这份转储是 ~21 次 MMIO（5×32 位 + 8×64 位），在 spinlock + 关中断下会扰动它要观测的时序。
   **必须限流**（例如按 stall 类型分别计数，每种前 3 次完整打印，之后只打一行 suppressed），
   并留一个 `module_param` 开关。

### 读出来的判据

| 现象 | 结论 |
|---|---|
| `RAWSTAT` 只有 bit9/bit10（POWER_CHANGED） | 电源变化报了，但清理命令没被完成 |
| `RAWSTAT` 完全没有 `RESET_COMPLETED` | GPU 处于复位状态，命令全部被丢弃 |
| `domains l2=…` 的 READY 与 PRESENT 不匹配，或 `l2` 的 PWRTRANS 非 0 | 缓存操作依赖的域没就绪 |
| `GPU_STATUS` bit7 | 处于 protected mode |

## 6. 排除项：这些方向不必再花时间

| 假设 | 排除依据 |
|---|---|
| 内核/用户态 Mali 版本不匹配 | 两者需一致；本项目是 r54p1 对 r54p1 |
| `GPU_COMMAND` 该用 `<<16` 编码 | r54 是 `<<8`；与 5.10 r54 驱动逐字一致 |
| 固件读的是被掩码的 `STAT` | 它读 `+0x20` = `RAWSTAT`，不受 MASK 影响 |
| 时钟没开导致 | 实测 9 个时钟全部 `clk_prepare_enable=0`，两个 PLL fmeter 与计算值一致（430/385 MHz） |
| L2 需要单独写 `L2_PWRON` | r54 DDK 只读 `L2_READY`（`0x160`），从不写 `L2_PWRON`（`0x1A0`）；且 `kbase_pm_wait_for_l2_powered()` 在 MCU 启动前已经等过 |
| 双 pipe / 540 宽 ROI 是配错 | 联发科 LK 自己也用 `ROI=0x99c021c`（540×2460），属正常拓扑 |
| `virtual_width` 要按 dual-pipe 减半 | 5.10 的 `mtk_dsi_get_virtual_width()` 直接返回 `adjusted_mode.hdisplay`，不做减半 |

## 7. 一条通用正确性规则（如果以后要加「rate 变化后重初始化」）

不要在被 `poweron()` 调用的 `set_data_rate()` 里把 `clk_refcnt` 清零。那会让**已上电的硬件**带着
引用计数 0，之后 `poweroff()` 跳过真正下电，恢复流程与错乱的引用打架。

正确做法：记录「上次 init 实际使用的 rate」，在 `poweron()` **入口**比较：

```c
if (++dsi->clk_refcnt != 1 && dsi->data_rate == last_init_rate)
        return 0;                       /* 真的可以跳过 */
/* 否则继续走完整 init */
...
last_init_rate = dsi->data_rate;        /* 成功返回前记录 */
```

加减计数必须与 `poweroff()` 的 `--clk_refcnt`、失败路径的 `err_refcount` 回滚保持同一谓词
（本项目是 `disp_helper_get_stage()==NORMAL || xaga_force_dsi_reinit`）。

## 8. 逐项对照结论：5.10 r54 树本来就对的地方

| 项目 | 5.10 r54 状态 | 本项目 6.12 状态 |
|---|---|---|
| 电源序列 | 调 `gpufreq_power_control(GPU_PWR_ON/OFF)`（SWCG→MTCMOS→BUCK） | 曾被移除，只开时钟 → 已恢复调用 |
| 电源回调返回值 | `return 2`（`GPU_STATE_IN_RESET`，触发 `kbase_pm_init_hw()` 重写一致性/L2/中断） | 曾 `return 0`（INTACT，什么都不做）→ 已改 2 |
| GPUEB IPI recv 表 | `recv_item_num = 4`，不读 `cb_opt` | 曾为 5 且越界读 `+4` → 已修 |
| `mtk_dsi_get_virtual_width()` | 返回 `adjusted_mode.hdisplay` | 曾减半 → 已恢复 |
| ESD 比较器 | 只有 `ESD_CHECK_CMP`（读 GCE slot，与读路径一致） | 小米私有 `MI_DISP_ESD_CHECK_CMP` 读错 buffer → 已按视频/命令模式分流 |
| 一致性模式 | 由 DTS `system-coherency = <0>`（ACE_LITE）决定 | 曾被参数强制 `NONE(31)`，连带关掉了 `L2_MMU_CONFIG_ALLOW_SNOOP_DISPARITY` |
