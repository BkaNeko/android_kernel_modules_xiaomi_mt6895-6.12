#!/usr/bin/env bash
#
# xaga (Redmi Note 11T Pro / POCO X4 GT / Redmi K50i) 6.12 kernel build + packaging.
#
# Default = full compile + pack (toolchain/deps handling modeled after
# clang_build_fix.sh: dependency preflight, clang env, clean build):
#   1. kernel config      gki_defconfig + mgk_64_k612_defconfig + vendor/xaga.config
#   2. kernel Image + Image.gz (gzip, per xaga packaging requirement)
#   3. in-tree modules    (refreshes Module.symvers)
#   4. out-of-tree modules -> 200 x .ko (make M=) + 4 in-tree deps in vendor_boot
#   5. DTS: mt6895.dtb (SoC base) + xaga.dtbo / xaga_global.dtbo (fdtoverlay check)
#   6. boot_new.img       magiskboot -n: Image.gz kernel + 6.12 kernelsu in official boot
#   7. vendor_boot_new.img mkbootimg: official ramdisk with 200 x 6.12 .ko (200 OOT + 4 in-tree), DTBO_TAG
#                        dtb slot, vrt name=[]/type=[platform], padded 64MB
#   8. dtbo_new.img       DTOv1 single entry (xaga.dtbo), NOT padded
#
# --modules-only: compile modules only (config + in-tree + 200 .ko hard assert),
#                 no Image / DTS / packaging.
#
# Usage: ./build.sh [--modules-only] [--no-clean] [--skip=BOOT,VENDOR,DTBO]
#
# Overridable via env: K M OUT XAGA IMG_DIR OFFICIAL OUT_IMG
#                      MKBOOTIMG MKDTBO MAGISKBOOT KERNELSU PEM
#                      LLVM_PREFIX JOBS USE_CCACHE=1 (prepend ccache to clang)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths (all overridable; defaults relative to this script's directory)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XAGA="${XAGA:-$(cd "$SCRIPT_DIR/.." && pwd)}"
M="${M:-$SCRIPT_DIR/kernel_device_modules-6.12}"
OUT="${OUT:-$SCRIPT_DIR/out}"
IMG_DIR="${IMG_DIR:-$XAGA/images}"
OFFICIAL="${OFFICIAL:-$IMG_DIR/offical}"          # official 5.10 images
OUT_IMG="${OUT_IMG:-$IMG_DIR/out}"                # packaged 6.12 images
MKBOOTIMG="${MKBOOTIMG:-$IMG_DIR/building/tools/mkbootimg.py}"
MKDTBO="${MKDTBO:-$IMG_DIR/building/tools/mkdtbo.py}"
MAGISKBOOT="${MAGISKBOOT:-$IMG_DIR/building/tools/magiskboot}"
KERNELSU="${KERNELSU:-$IMG_DIR/building/tools/android16-6.12_kernelsu.ko}"
PEM="${PEM:-$M/certs/mtk_signing_key.pem}"
LLVM_PREFIX="${LLVM_PREFIX:-$HOME/clang}"   # AOSP clang-r536225 (OPPO build.config.constants); NOT apt clang-18
JOBS="${JOBS:-$(nproc)}"
VERMAGIC_VER="6.12.76-4k"

MODULES_ONLY=0
SKIP_CLEAN=0
SKIP=""
for arg in "$@"; do
    case "$arg" in
        --modules-only) MODULES_ONLY=1 ;;
        --no-clean) SKIP_CLEAN=1 ;;
        --skip=*) SKIP=",${arg#--skip=}," ;;     # normalized: ,BOOT,VENDOR,
        --help|-h) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "unknown arg: $arg (try --help)" >&2; exit 2 ;;
    esac
done

DTS_DIR="$M/arch/arm64/boot/dts/mediatek"
WORK="$(mktemp -d /home/bkaneko/work/tmpbuild/xaga_build.XXXXXX)"

# ---------------------------------------------------------------------------
# Progress visualization: every log() line carries [HH:MM:SS] + (N/8) step
# counter + cumulative time T+mm:ss + per-step duration +mm:ss. The step
# number is parsed from the message's own "N/8" prefix (sub-steps like
# "4b/8" and --skip steps don't disturb the counter). The bottom bar
# (progress_bar) is drawn with \r when stdout is a TTY, otherwise the
# step lines alone are printed (log file friendly).
# ---------------------------------------------------------------------------
BUILD_START_EPOCH="$(date +%s)"
BUILD_TOTAL_STEPS=8
BUILD_STEP_NUM=0
BUILD_STEP_EPOCH="$BUILD_START_EPOCH"

fmt_ts() { date +%H:%M:%S; }
fmt_dur() {  # fmt_dur <seconds> -> mm:ss
    local s=$(( $1 % 60 )) m=$(( ($1 / 60) % 60 )) h=$(( $1 / 3600 ))
    if [ "$h" -gt 0 ]; then printf '%dh%02dm%02ds' "$h" "$m" "$s"
    else printf '%dm%02ds' "$m" "$s"; fi
}

log() {
    local now_epoch step_dur total_dur msg="$*" step_tag=""
    now_epoch="$(date +%s)"
    step_dur=$(( now_epoch - BUILD_STEP_EPOCH ))
    total_dur=$(( now_epoch - BUILD_START_EPOCH ))
    BUILD_STEP_EPOCH="$now_epoch"
    # step number lives in the message ("N/8" or "4b/8"); only count whole
    # steps so sub-steps don't advance the progress counter
    if [[ "$msg" =~ ^([0-9]+)[ab]?/ ]]; then
        BUILD_STEP_NUM="${BASH_REMATCH[1]}"
        step_tag=" ($BUILD_STEP_NUM/$BUILD_TOTAL_STEPS)"
    fi
    echo -e "\n\033[1;32m[$(fmt_ts)]$step_tag T+$(fmt_dur $total_dur) +$(fmt_dur $step_dur) === $msg ===\033[0m"
}

# progress_bar <label> <cur> <total>: draw/refresh one line; no-op when not a TTY
progress_bar() {
    [ -t 1 ] || return 0
    local label="$1" cur="$2" total="$3" pct filled bar
    [ "$total" -gt 0 ] || total=1
    pct=$(( cur * 100 / total ))
    filled=$(( pct / 2 ))
    bar=$(printf '%*s' "$filled" '' | tr ' ' '=')
    printf '\r\033[K\033[1;36m%s [%-50s] %3d%% (%d/%d)\033[0m' \
        "$label" "$bar" "$pct" "$cur" "$total"
}

progress_clear() { [ -t 1 ] && printf '\r\033[K'; }

# log_raw: informational line that does NOT consume a step number
log_raw() { echo -e "\033[1;33m[$*]\033[0m"; }

skip() { [[ "$SKIP" == *,$1,* ]]; }

# ---------------------------------------------------------------------------
# Locate the OPPO 6.12 kernel source tree (K)
# ---------------------------------------------------------------------------
locate_kernel() {
    local candidates=()
    [ -n "${K:-}" ] && candidates+=("$K")
    candidates+=(
        "$SCRIPT_DIR/android_kernel_oddo_mt6895"          # GitHub remote name
        "$SCRIPT_DIR/../android_kernel_oddo_mt6895"
        "$SCRIPT_DIR/../../android_kernel_oddo_mt6895"
        "$SCRIPT_DIR/xaga/android_kernel_oddo_mt6895"
        "$SCRIPT_DIR/../xaga/android_kernel_oddo_mt6895"
        "$SCRIPT_DIR/../../xaga/android_kernel_oddo_mt6895"
    )
    local c
    for c in "${candidates[@]}"; do
        if [ -f "$c/arch/arm64/configs/gki_defconfig" ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

if K="$(locate_kernel)"; then
    log_raw "kernel source: $K"
else
    echo "OPPO 6.12 kernel source not found automatically." >&2
    echo "Set K=<path> or enter it now (expects arch/arm64/configs/gki_defconfig):" >&2
    read -r -p "K=" K
    if [ -z "${K:-}" ] || [ ! -f "$K/arch/arm64/configs/gki_defconfig" ]; then
        echo "ERROR: invalid kernel path: $K" >&2
        exit 1
    fi
fi

INC="-I$M/drivers/gpu/mediatek/gpueb -I$M/drivers/misc/mediatek/blocktag -I$M -I$M/drivers -I$M/include -I$M/include/soc/mediatek -I$M/drivers/clk/mediatek -I$M/drivers/gpu/mediatek/gpufreq -I$M/drivers/gpu/mediatek/gpufreq/v2/include -I$M/drivers/gpu/mediatek/gpueb/include -I$M/drivers/gpu/mediatek/ged/include -I$M/drivers/gpu/mediatek/ged -I$M/drivers/gpu/mediatek/gpufreq/v1 -I$M/drivers/gpu/mediatek/mt-plat -I$M/drivers/misc/mediatek/typec/tcpc/inc -I$M/drivers/misc/mediatek/mtk-interconnect -I$M/drivers/misc/mediatek/include -I$M/drivers/misc/mediatek/include/mt-plat -I$M/drivers/misc/mediatek/mminfra -I$M/drivers/misc/mediatek/power_throttling -I$M/drivers/misc/mediatek/dcm -I$M/drivers/misc/mediatek/dcm/include -I$M/drivers/misc/mediatek/mdpm -I$M/drivers/misc/mediatek/aee/mrdump -I$M/drivers/misc/mediatek/aee/aed -I$M/drivers/misc/mediatek/mcupm/include -I$M/drivers/misc/mediatek/pbm -I$M/drivers/misc/mediatek/sda/include -I$M/drivers/misc/mediatek/mdp -I$M/drivers/misc/mediatek/smi -I$M/drivers/misc/mediatek/mmdvfs -I$M/drivers/misc/mediatek/qos -I$M/drivers/misc/mediatek/mm_monitor -I$M/drivers/misc/mediatek/mmp -I$M/drivers/misc/mediatek/vcp/rv -I$M/drivers/misc/mediatek/vcp/rv_v2 -I$M/drivers/misc/mediatek/vcp/include -I$M/drivers/misc/mediatek/iommu -I$M/drivers/iommu/arm/arm-smmu-v3 -I$M/drivers/ufs -I$M/drivers/iommu -I$M/drivers/memory -I$M/drivers/usb/mtu3 -I$M/drivers/char/rpmb -I$M/drivers/char/rpmb/core -I$M/drivers/char/rpmb/drrpmb_gp/public -I$M/drivers/mmc/host -I$M/drivers/power/supply -I$M/drivers/tee/gud/700/MobiCoreDriver -I$M/drivers/tee/gud/700/MobiCoreDriver/public -I$M/drivers/dma-buf/heaps -I$M/drivers/media/platform/mtk-vcodec -I$M/drivers/gpu/drm/mediatek/dpc -I$M/drivers/gpu/mediatek/gpufreq/v2 -I$M/drivers/gpu/mediatek/gpufreq -I$K/drivers/devfreq -I$K/drivers/mmc/host -I$K/drivers/tty/serial/8250 -I$K/drivers/dma -I$K/drivers/ufs/host -I$K/drivers/ufs/core -I$K/drivers/usb/typec -I$K/kernel -I$K/include -I$M/drivers/thermal -I$M/drivers/thermal/mediatek -I$M/drivers/misc/mediatek/slbc -I$M/drivers/misc/mediatek/geniezone/include -I$M/drivers/misc/mediatek/geniezone/public -I$M/drivers/misc/mediatek/trusted_mem/public -I$M/drivers/tee/teei/520/common/include -I$M/drivers/tee/teei/520/public -I$M/drivers/tee/teei/520/tz_driver/include"
INC="$INC -I$M/drivers/misc/mediatek/tinysys_scmi -I$M/drivers/misc/mediatek/perf_common"


# ---------------------------------------------------------------------------
# Preflight: build tools, paths, clang env (clang_build_fix.sh style)
# ---------------------------------------------------------------------------
preflight() {
    local missing=()
    for t in bc bison flex lz4 cpio python3 gzip; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    local LLVM_DIR="${LLVM_PREFIX%/bin}"
    LLVM_DIR="${LLVM_DIR%/}"
    [ -x "$LLVM_DIR/bin/clang" ] || missing+=("clang ($LLVM_DIR/bin/clang)")
    [ -x "$LLVM_DIR/bin/ld.lld" ] || missing+=("ld.lld ($LLVM_DIR/bin/ld.lld)")
    command -v aarch64-linux-gnu-ld >/dev/null 2>&1 || missing+=("aarch64-linux-gnu-ld")
    if [ ${#missing[@]} -gt 0 ]; then
        echo "ERROR: missing build tools: ${missing[*]}" >&2
        echo "  sudo apt-get install -y bc bison flex lz4 unzip ccache cpio python3 binutils-aarch64-linux-gnu" >&2
        echo "  clang: install AOSP clang-r536225 (OPPO build.config.constants) under \$HOME/clang," >&2
        echo "         e.g. curl -L https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/..." >&2
        exit 1
    fi
    for p in "$K" "$M" "$PEM"; do
        [ -e "$p" ] || { echo "missing required path: $p" >&2; exit 1; }
    done
    if [ "$MODULES_ONLY" -eq 0 ]; then
        for p in "$OFFICIAL/boot.img" "$OFFICIAL/vendor_boot.img" \
                 "$MAGISKBOOT" "$MKBOOTIMG" "$MKDTBO" "$KERNELSU"; do
            [ -e "$p" ] || { echo "missing required path: $p" >&2; exit 1; }
        done
    fi
    export PATH="$LLVM_DIR/bin:$PATH"
    export LLVM_PREFIX="$LLVM_DIR/bin/"
    export KCONFIG_EXT_PREFIX="$M/"   # REQUIRED for every make (module symbols)
    export PYTHONPATH="$WORK"
    # gki stub: mkbootimg.py imports it at module load; signing only runs with
    # --gki_signing_key (never passed), so a stub that fails loud is enough
    mkdir -p "$WORK/gki"
    cat > "$WORK/gki/generate_gki_certificate.py" <<'PYEOF'
def generate_gki_certificate(**kwargs):
    raise SystemExit("gki signing not supported (no --gki_signing_key)")
PYEOF
    MAKE_CC=()
    if [ "${USE_CCACHE:-0}" -eq 1 ]; then
        command -v ccache >/dev/null 2>&1 || { echo "USE_CCACHE=1 but ccache not found" >&2; exit 1; }
        MAKE_CC=(CC="ccache clang" CXX="ccache clang++")
        log_raw "ccache enabled"
    fi
}

# ---------------------------------------------------------------------------
# 1. Clean
# ---------------------------------------------------------------------------
clean() {
    log "1/8 clean $OUT + module tree artifacts"
    rm -rf "$OUT" && mkdir -p "$OUT"
    find "$M" \( -name '*.o' -o -name '*.ko' -o -name '*.cmd' -o -name '*.mod*' \
        -o -name 'modules.order' -o -name 'Module.symvers' -o -name '.tmp_versions' \) \
        -exec rm -rf {} + 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 2. Kernel config (gki + mgk + xaga fragment)
# ---------------------------------------------------------------------------
config() {
    log "2/8 kernel config (gki_defconfig + mgk_64_k612 + xaga.config)"
    ( cd "$K" && make "${MAKE_CC[@]}" O="$OUT" ARCH=arm64 LLVM=1 gki_defconfig > "$WORK/config1.log" 2>&1 ) || { cat "$WORK/config1.log"; exit 1; }
    ( cd "$K" && KCONFIG_CONFIG="$OUT/.config" ./scripts/kconfig/merge_config.sh -m \
        "$OUT/.config" \
        "$M/arch/arm64/configs/mgk_64_k612_defconfig" \
        "$M/arch/arm64/configs/vendor/xaga.config" > "$WORK/merge.log" 2>&1 ) || { cat "$WORK/merge.log"; exit 1; }
    # xaga has no hardware virtualization: the MT6895 boot chain (LK/ATF, 5.10
    # era) provides no pKVM-capable EL2/hyp, so protected-KVM init hangs early
    # (unknown-SMC / hyp install). Drop kvm-arm.mode=protected from the baked
    # gki CONFIG_CMDLINE, turn KVM off (KVM_ARM64/ARM_PKVM_GUEST/VFIO_PKVM_IOMMU
    # follow via olddefconfig), and disable the MTK pKVM modules. merge_config
    # here is -m (only-add, never overrides), so fix them up like
    # CONFIG_MODULE_SIG_KEY below.
    sed -i \
        -e 's|^CONFIG_KVM=y|# CONFIG_KVM is not set|' \
        -e 's|kvm-arm.mode=protected ||' \
        -e 's|^CONFIG_MTK_PKVM_MKP=m|# CONFIG_MTK_PKVM_MKP is not set|' \
        -e 's|^CONFIG_MTK_PKVM_MTK_SMC_HANDLER=m|# CONFIG_MTK_PKVM_MTK_SMC_HANDLER is not set|' \
        -e 's|^CONFIG_MTK_PKVM_TMEM=m|# CONFIG_MTK_PKVM_TMEM is not set|' \
        -e 's|^CONFIG_MTK_PKVM_SMMU=m|# CONFIG_MTK_PKVM_SMMU is not set|' \
        -e 's|^CONFIG_MTK_PKVM_ISP=m|# CONFIG_MTK_PKVM_ISP is not set|' \
        -e 's|^CONFIG_MTK_PKVM_CMDQ=m|# CONFIG_MTK_PKVM_CMDQ is not set|' \
        -e 's|^CONFIG_ARM_FFA_TRANSPORT=.*|# CONFIG_ARM_FFA_TRANSPORT is not set|' \
        -e 's|^CONFIG_ARM64_AMU_EXTN=y|# CONFIG_ARM64_AMU_EXTN is not set|' \
        -e 's|^CONFIG_ARM64_MTE=y|# CONFIG_ARM64_MTE is not set|' \
        -e 's|^CONFIG_ARM64_EPAN=y|# CONFIG_ARM64_EPAN is not set|' \
        -e 's|^CONFIG_ARM64_SME=y|# CONFIG_ARM64_SME is not set|' \
        -e 's|^CONFIG_ARM64_BTI=y|# CONFIG_ARM64_BTI is not set|' \
        -e 's|^CONFIG_ARM64_E0PD=y|# CONFIG_ARM64_E0PD is not set|' \
        -e 's|^CONFIG_KASAN=y|# CONFIG_KASAN is not set|' \
        -e 's|^CONFIG_KASAN_HW_TAGS=y|# CONFIG_KASAN_HW_TAGS is not set|' \
        -e 's|^CONFIG_MTK_ECCCI_DRIVER=m|# CONFIG_MTK_ECCCI_DRIVER is not set|' \
        -e 's|^CONFIG_USB_G_SERIAL=.*|# CONFIG_USB_G_SERIAL is not set|' \
        -e 's|^CONFIG_U_SERIAL_CONSOLE=.*|# CONFIG_U_SERIAL_CONSOLE is not set|' \
        -e 's|^CONFIG_XAGA_KMSG2USB=.*|# CONFIG_XAGA_KMSG2USB is not set|' \
        -e 's|^CONFIG_CPU_MITIGATIONS=.*|# CONFIG_CPU_MITIGATIONS is not set|' \
        -e 's|^CONFIG_MICROTRUST_TZ_DRIVER_MTK_BOOTPROF=.*|# CONFIG_MICROTRUST_TZ_DRIVER_MTK_BOOTPROF is not set|' \
        "$OUT/.config"
    ( cd "$K" && make "${MAKE_CC[@]}" O="$OUT" ARCH=arm64 LLVM=1 olddefconfig > "$WORK/config2.log" 2>&1 )
    sed -i "s|^CONFIG_MODULE_SIG_KEY=.*|CONFIG_MODULE_SIG_KEY=\"$PEM\"|" "$OUT/.config"
    grep -q '^CONFIG_XAGA_MARKER_WRITER=y' "$OUT/.config" \
        || { echo "ERROR: CONFIG_XAGA_MARKER_WRITER missing after merge" >&2; exit 1; }
    if grep -q 'kvm-arm.mode' "$OUT/.config"; then
        echo "ERROR: kvm-arm.mode still present after KVM disable" >&2
        exit 1
    fi
    if grep -q '^CONFIG_KVM=y' "$OUT/.config"; then
        echo "ERROR: CONFIG_KVM still enabled after disable" >&2
        exit 1
    fi
    for sym in AMU_EXTN MTE EPAN SME BTI E0PD; do
        if grep -q "^CONFIG_ARM64_${sym}=y" "$OUT/.config"; then
            echo "ERROR: CONFIG_ARM64_${sym} still enabled after disable" >&2
            exit 1
        fi
    done
    if grep -q '^CONFIG_KASAN=y' "$OUT/.config"; then
        echo "ERROR: CONFIG_KASAN still enabled after disable" >&2
        exit 1
    fi
    if grep -q '^CONFIG_ARM_FFA_TRANSPORT=y' "$OUT/.config" || grep -q '^CONFIG_ARM_FFA_TRANSPORT=m' "$OUT/.config"; then
        echo "ERROR: CONFIG_ARM_FFA_TRANSPORT still enabled after disable" >&2
        exit 1
    fi
    if grep -q '^CONFIG_XAGA_KMSG2USB=y' "$OUT/.config"; then
        echo "ERROR: CONFIG_XAGA_KMSG2USB still enabled after disable" >&2
        exit 1
    fi
    if grep -q '^CONFIG_USB_G_SERIAL=y' "$OUT/.config" || grep -q '^CONFIG_USB_G_SERIAL=m' "$OUT/.config"; then
        echo "ERROR: CONFIG_USB_G_SERIAL still enabled after disable" >&2
        exit 1
    fi
    if grep -q '^CONFIG_MICROTRUST_TZ_DRIVER_MTK_BOOTPROF=y' "$OUT/.config" || grep -q '^CONFIG_MICROTRUST_TZ_DRIVER_MTK_BOOTPROF=m' "$OUT/.config"; then
        echo "ERROR: CONFIG_MICROTRUST_TZ_DRIVER_MTK_BOOTPROF still enabled after disable" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# 3. Kernel Image + Image.gz (gz, per xaga requirement)
# ---------------------------------------------------------------------------
kernel() {
    log "3/8 kernel Image + Image.gz"
    ( cd "$K" && make "${MAKE_CC[@]}" O="$OUT" ARCH=arm64 LLVM=1 -j"$JOBS" Image > "$WORK/kernel.log" 2>&1 ) || { echo "=== KERNEL IMAGE ERROR LOG ==="; cat "$WORK/kernel.log"; exit 1; }
    # gzip -n: no embedded filename/timestamp (MTK bootloader requirement)
    gzip -n -c "$OUT/arch/arm64/boot/Image" > "$OUT/arch/arm64/boot/Image.gz"
    ls -la "$OUT/arch/arm64/boot/Image.gz"
}

# ---------------------------------------------------------------------------
# 4. Modules: in-tree (Module.symvers) + out-of-tree 200 x .ko
# ---------------------------------------------------------------------------
modules() {
    log "4/8 in-tree modules (Module.symvers)"
    ( cd "$K" && make "${MAKE_CC[@]}" O="$OUT" ARCH=arm64 LLVM=1 -j"$JOBS" modules > "$WORK/inmod.log" 2>&1 ) || { echo "=== IN-TREE MODULES ERROR LOG ==="; cat "$WORK/inmod.log"; exit 1; }

    log "4b/8 out-of-tree modules -> 200+ x .ko (KBUILD_MODPOST_WARN=1)"
    # progress: count .ko as they are produced; poll in background on a TTY
    if [ -t 1 ]; then
        make -C "$K" O="$OUT" ARCH=arm64 LLVM=1 KCONFIG_EXT_PREFIX="$M/" M="$M" \
            MTK_PLATFORM=mt6895 CONFIG_MTK_PLATFORM=mt6895 \
            DEVICE_MODULES_PATH="$M" DEVCIE_MODULES_INCLUDE="$INC" \
            KBUILD_MODPOST_WARN=1 -j"$JOBS" modules > "$WORK/ootmod.log" 2>&1 &
        local MPID=$!
        local MCUR=0
        while kill -0 "$MPID" 2>/dev/null; do
            MCUR="$(find "$M" -name '*.ko' | wc -l)"
            progress_bar "OOT modules" "$MCUR" 200
            sleep 2
        done
        wait "$MPID" || { echo "=== OOT MODULES ERROR LOG ==="; cat "$WORK/ootmod.log"; exit 1; }
        MCUR="$(find "$M" -name '*.ko' | wc -l)"
        progress_bar "OOT modules" "$MCUR" 200
        progress_clear
    else
        make -C "$K" O="$OUT" ARCH=arm64 LLVM=1 KCONFIG_EXT_PREFIX="$M/" M="$M" \
            MTK_PLATFORM=mt6895 CONFIG_MTK_PLATFORM=mt6895 \
            DEVICE_MODULES_PATH="$M" DEVCIE_MODULES_INCLUDE="$INC" \
            KBUILD_MODPOST_WARN=1 -j"$JOBS" modules > "$WORK/ootmod.log" 2>&1 || { echo "=== OOT MODULES ERROR LOG ==="; cat "$WORK/ootmod.log"; exit 1; }
    fi
    NKO="$(find "$M" -name '*.ko' | wc -l)"
    [ "$NKO" -ge 200 ] || { echo "ERROR: expected at least 200 .ko, got $NKO" >&2; exit 1; }
    echo "$NKO .ko built"
}

# ---------------------------------------------------------------------------
# 5. DTS: SoC base + board overlays, fdtoverlay check
# ---------------------------------------------------------------------------
dtc_cpp() {  # dtc_cpp <in.dts> <out.dtb> [extra flags]
    cpp -nostdinc -I"$M/include" -I"$K/include" \
        -I"$M/arch/arm64/boot/dts" -I"$K/arch/arm64/boot/dts" -I. \
        -undef -D__DTS__ -x assembler-with-cpp "$1" 2>/dev/null \
    | "$OUT/scripts/dtc/dtc" -@ -I dts -O dtb -o "$2" -
}

dts() {
    log "5/8 DTS: mt6895.dtb + xaga.dtbo + xaga_global.dtbo"
    mkdir -p "$WORK/dts" "$OUT/dts"
    [ -x "$OUT/scripts/dtc/dtc" ] || ( cd "$K" && make "${MAKE_CC[@]}" O="$OUT" ARCH=arm64 LLVM=1 -j"$JOBS" scripts_dtc > "$WORK/dtc.log" 2>&1 ) || { echo "=== DTC BUILD ERROR LOG ==="; cat "$WORK/dtc.log"; exit 1; }
    dtc_cpp "$DTS_DIR/mt6895.dts"        "$WORK/dts/mt6895.dtb"
    dtc_cpp "$DTS_DIR/xaga.dts"          "$WORK/dts/xaga.dtbo"
    dtc_cpp "$DTS_DIR/xaga_global.dts"   "$WORK/dts/xaga_global.dtbo"
    "$OUT/scripts/dtc/fdtoverlay" -i "$WORK/dts/mt6895.dtb" "$WORK/dts/xaga.dtbo" \
        -o "$WORK/dts/apply_xaga.dtb" 2>&1 || { echo "ERROR: fdtoverlay xaga failed" >&2; exit 1; }
    cp "$WORK/dts/mt6895.dtb" "$WORK/dts/xaga.dtbo" "$WORK/dts/xaga_global.dtbo" "$OUT/dts/"
    ls -la "$WORK/dts/"
}

# ---------------------------------------------------------------------------
# 6. boot_new.img: official boot + Image.gz kernel + 6.12 kernelsu (magiskboot -n)
# ---------------------------------------------------------------------------
pack_boot() {
    log "6/8 boot_new.img (magiskboot -n + 6.12 kernelsu)"
    local BD="$WORK/boot"; mkdir -p "$BD"; cd "$BD"
    local BOOT_BASE="$OFFICIAL/boot.img"
    [ -f "$OFFICIAL/boot_a.img" ] && BOOT_BASE="$OFFICIAL/boot_a.img"
    "$MAGISKBOOT" unpack -n -h "$BOOT_BASE" > "$WORK/boot_unpack.log" 2>&1
    cp "$OUT/arch/arm64/boot/Image.gz" kernel
    # ramdisk is kept compressed by -n; decompress, swap kernelsu, recompress.
    # IMPORTANT: the official boot ramdisk is LEGACY lz4 (magic 02 21 4c 18)
    # and LK's decompressor expects legacy format - recompress with lz4 -l!
    # Using standard lz4 (04 22 4d 18) yields "rootfs image is not initramfs
    # (invalid magic)" -> VFS: Unable to mount root fs -> panic (2026-08-11).
    lz4 -l -d -f ramdisk.cpio ramdisk.raw > /dev/null 2>&1 || true
    "$MAGISKBOOT" cpio ramdisk.raw "add 0755 kernelsu.ko $KERNELSU" \
        > "$WORK/boot_cpio.log" 2>&1
    # xaga: adb root / debuggable boot props. android init loads /prop.default
    # from the ramdisk before system/vendor build.prop, and ro.* is immutable
    # once set, so these win over the release-keys values. The OS4 port is a
    # user build: without this adbd refuses "adb root" and shell cannot read
    # kmsg.
    cat > "$WORK/prop.adbroot" <<'PROPEOF'
ro.debuggable=1
ro.secure=0
ro.adb.secure=0
service.adb.root=1
PROPEOF
    "$MAGISKBOOT" cpio ramdisk.raw "add 0644 prop.default $WORK/prop.adbroot" \
        >> "$WORK/boot_cpio.log" 2>&1
    lz4 -l -9 -f ramdisk.raw ramdisk_new.lz4 > /dev/null 2>&1
    cp ramdisk_new.lz4 ramdisk.cpio
    "$MAGISKBOOT" repack -n "$BOOT_BASE" > "$WORK/boot_repack.log" 2>&1
    cp new-boot.img "$OUT_IMG/boot_new.img"
    ls -la "$OUT_IMG/boot_new.img"
}

# ---------------------------------------------------------------------------
# 7. vendor_boot_new.img: official ramdisk, 5.10 .ko removed, 200 x 6.12 .ko (200 OOT + 4 in-tree)
# ---------------------------------------------------------------------------
pack_vendor() {
    log "7/8 vendor_boot_new.img (no 5.10 modules, mkbootimg, padded 64MB)"
    local VD="$WORK/vb"; mkdir -p "$VD"; cd "$VD"
    # magiskboot unpack on vendor_boot exits 3 (VBMETA handling) and may
    # return BEFORE ramdisk.cpio is fully written (race, 2026-08-11). Worse,
    # the extracted ramdisk.cpio / vendor_ramdisk_official.lz4 is the PURE
    # lz4 stream missing the last 2,005B cpio TRAILER!!! tail - decompressing
    # it yields a truncated 80MB cpio (liblogwrap.so 8,704B vs 19,440B,
    # system/lib64 49 vs 72 entries) -> kernel initrd parsing reads wrong
    # offsets -> "liblogwrap.so invalid shdr" (2026-08-11 real-device).
    # Use the FULL vendor_ramdisk segment dd'd from the official vendor_boot
    # (42,743,860B incl. TRAILER tail, decompresses to 88,036,352B).
    "$MAGISKBOOT" unpack -n -h "$OFFICIAL/vendor_boot.img" > "$WORK/vb_unpack.log" 2>&1 || true
    cd "$VD/vendor_ramdisk"
    local VR_SRC="${VENDOR_RAMDISK_LZ4:-$IMG_DIR/building/tools/vendor_ramdisk_official_full.bin}"
    lz4 -d -f "$VR_SRC" vr.raw > /dev/null 2>&1 || true
    # integrity gate: full official ramdisk decompresses to >= 88MB
    # (80MB cpio + 7.2MB tail with the second TRAILER!!! at EOF);
    # anything less means a truncated source
    local VR_SZ="$(stat -c %s vr.raw 2>/dev/null || echo 0)"
    if [ "$VR_SZ" -lt 88000000 ]; then
        echo "ERROR: vendor ramdisk extraction incomplete ($VR_SZ bytes, expected >= 88000000)" >&2
        echo "  source: $VR_SRC" >&2
        exit 1
    fi
    mkdir -p rd && cd rd
    # cpio returns 2 on some entries (hardlink warnings); unpack is fine
    cpio -idmv < ../vr.raw > /dev/null 2>&1 || true

    # xaga debug (TEMPORARY): /xaga_boot.sh is executed as root by the kernel
    # xaga_boot thread ~20s after boot. It flips SELinux permissive, opens
    # dmesg and dumps surfaceflinger's EGL mappings so the release-adbd build
    # can still be diagnosed. Remove together with kernel/xaga_boot.c.
    cat > xaga_boot.sh <<'XAGADBG'
#!/system/bin/sh
exec >/data/local/tmp/xaga_boot.txt 2>&1
echo "== boot =="
date
cat /proc/uptime
id
setenforce 0
echo "enforce=$(cat /sys/fs/selinux/enforce 2>&1)"
echo 0 > /proc/sys/kernel/dmesg_restrict 2>/dev/null
echo 0 > /proc/sys/kernel/kptr_restrict 2>/dev/null
echo "== props =="
getprop | grep -E "ro.debuggable|ro.hardware.egl|ro.vendor.build.fingerprint|ro.vndk.version|ro.secure"
for i in 1 2 3 4 5 6 7 8 9 10; do
  p=$(pidof surfaceflinger)
  if [ -n "$p" ]; then
    echo "== SF pid=$p =="
    cat /proc/$p/maps 2>&1 | grep -iE "egl|mali|meow"
    echo "dom=$(cat /proc/$p/attr/current 2>&1)"
    break
  fi
  sleep 2
done
echo "== dmesg mali =="
dmesg 2>&1 | grep -iE "mali|kbase|gpu" | tail -80
echo "== logcat egl =="
logcat -d -b all 2>/dev/null | grep -iE "libEGL|dlopen|egl" | tail -60
echo "== done =="
XAGADBG

    # xaga/OS4: the device runs a patched LK + stock vbmeta, and the ported ROM
    # relies on an fstab whose AVB tokens were stripped (new-port fstab_noavb).
    # Packing the stock ramdisk fstab with ,avb / ,avb= / ,avb_keys= makes
    # first-stage fs_mgr verify the re-signed OS4 partitions against the stock
    # vbmeta; the mount then fails, init cannot exec /system/bin/init and dies
    # with exit 127. Strip ONLY the AVB tokens - never touch fileencryption=,
    # keydirectory= or inlinecrypt (that would break FBE on /data).
    find first_stage_ramdisk -maxdepth 1 -name 'fstab*' -type f | while read -r f; do
        python3 - "$f" <<'PYEOF'
import re, sys
p = sys.argv[1]
with open(p, encoding='utf-8', errors='surrogateescape') as fh:
    s = fh.read()
new, n = re.subn(r',avb(?:_keys)?(?:=[^,\s]*)?', '', s)
if n:
    with open(p, 'w', encoding='utf-8', errors='surrogateescape') as fh:
        fh.write(new)
    print("  %s: removed %d AVB token(s)" % (p, n))
PYEOF
    done

    # remove all 5.10 modules, install 6.12 ones
    find . -name '*.ko' -delete
    cp $(find "$M" -name '*.ko') lib/modules/
    # xaga: OOT modules also need 4 in-tree (K tree) modules that are built
    # as =m in 6.12 (not inside Image): drm_display_helper (drm_dp_* for
    # mediatek-drm), drm_dma_helper (drm_gem_dma_vm_ops), and the IIO buffer
    # pair (mt6375-adc). Official 5.10 ramdisk also ships kfifo_buf.ko.
    cp "$OUT/drivers/gpu/drm/display/drm_display_helper.ko" \
       "$OUT/drivers/gpu/drm/drm_dma_helper.ko" \
       "$OUT/drivers/iio/buffer/industrialio-triggered-buffer.ko" \
       "$OUT/drivers/iio/buffer/kfifo_buf.ko" \
       lib/modules/
    if [ -f "$OUT/drivers/thermal/thermal-generic-adc.ko" ]; then
        cp "$OUT/drivers/thermal/thermal-generic-adc.ko" lib/modules/
        cp "$OUT/drivers/thermal/thermal-generic-adc.ko" lib/modules/thermal_generic_adc.ko
    fi
    # Stage MediaTek vendor firmware blobs (GZ, TEE, SSPM, MCUPM, PI_IMG)
    local FW_DIR="$SCRIPT_DIR/vendor_firmware"
    if [ -d "$FW_DIR" ]; then
        mkdir -p lib/firmware vendor/firmware
        find "$FW_DIR" -type f ! -name '.*' ! -name 'README.md' -exec cp -f {} lib/firmware/ \; 2>/dev/null || true
        find "$FW_DIR" -type f ! -name '.*' ! -name 'README.md' -exec cp -f {} vendor/firmware/ \; 2>/dev/null || true
    fi

    # xaga: official 5.10 modules carry no DWARF (40MB vs our 130MB for the
    # same 198 modules). Drop debug sections, keep .symtab + __ksymtab so
    # modinfo/depmod/insmod all still work (2026-08-10).
    find lib/modules -name '*.ko' -exec "${LLVM_PREFIX}llvm-strip" --strip-debug {} +
    cd lib/modules
    ls *.ko | sed 's|\.ko$||' | sort > modules.load
    cp modules.load modules.load.recovery
    # depmod: temp version dir (flat layout), move metadata out, drop prefix
    local VER="$VERMAGIC_VER"
    mkdir -p "$VER" && cp *.ko "$VER/"
    depmod -b "$VD/vendor_ramdisk/rd" "$VER" 2>/dev/null || true
    for f in modules.dep modules.alias modules.softdep modules.symbols; do
        [ -f "$VER/$f" ] && cp "$VER/$f" .
    done
    sed -i "s|$VER/||g" modules.dep   # flat layout: strip version-dir prefix
    rm -rf "$VER"
    # xaga: first-stage init (libmodprobe) orders insmod by modules.dep
    # dependency graph (topological + alphabetical tie-break), NOT by
    # modules.load. mediatek-drm has no *symbol* deps on mtk_iommu or
    # mtk-scpsys-mt6895, so libmodprobe alphabetically loads it first; but
    # dispsys_config's DT deps (power-domains scpsys, iommus disp_iommu)
    # then are not yet registered -> probe waits forever -> no drm dev ->
    # recovery graphics timeout (real-device 2026-08-12). Inject pseudo
    # deps so libmodprobe loads them first.
    python3 - <<'PYEOF'
dep_path = 'modules.dep'
with open(dep_path) as f:
    lines = f.readlines()
out = []
for line in lines:
    # dispsys_config depends on iommu/scpsys/smi (DT deps, not symbols)
    if line.startswith('mediatek-drm.ko:'):
        deps = line.rstrip('\n').split(':', 1)[1]
        extra = ['mtk_iommu.ko', 'mtk-scpsys-mt6895.ko', 'mtk-smi.ko']
        add = [d for d in extra if d not in deps.split()]
        if add:
            line = line.rstrip('\n') + (' ' if deps else '') + ' '.join(add) + '\n'
    # extcon-mtk-usb resolves the UDC's role switch via tcpc; without a
    # symbol dep libmodprobe loads it (e) before tcpc_mt6375 (t), so
    # mtk_usb_extcon_tcpc_init fails (-ENODEV, no retry) -> mtu3 UDC stays
    # inactive -> USB gadget never enumerates (g_serial ttyGS0 invisible,
    # fastbootd no UDC). Force tcpc before extcon (real-device 2026-08-12).
    if line.startswith('extcon-mtk-usb.ko:'):
        deps = line.rstrip('\n').split(':', 1)[1]
        extra = ['tcpc_mt6375.ko', 'tcpc_class.ko']
        add = [d for d in extra if d not in deps.split()]
        if add:
            line = line.rstrip('\n') + (' ' if deps else '') + ' '.join(add) + '\n'
    # gz_ipc_mod binds to virtio device registered by gz_virtio_mod
    if line.startswith('gz_ipc_mod.ko:'):
        deps = line.rstrip('\n').split(':', 1)[1]
        extra = ['gz_virtio_mod.ko']
        add = [d for d in extra if d not in deps.split()]
        if add:
            line = line.rstrip('\n') + (' ' if deps else '') + ' '.join(add) + '\n'
    # isee.ko should load after mcDrvModule.ko (stock alignment line 87/104)
    if line.startswith('isee.ko:'):
        deps = line.rstrip('\n').split(':', 1)[1]
        extra = ['mcDrvModule.ko']
        add = [d for d in extra if d not in deps.split()]
        if add:
            line = line.rstrip('\n') + (' ' if deps else '') + ' '.join(add) + '\n'
    # fhctl.ko must load after mcupm.ko, mtk_gpueb.ko, and mtk_tinysys_ipi.ko
    if line.startswith('fhctl.ko:'):
        deps = line.rstrip('\n').split(':', 1)[1]
        extra = ['mcupm.ko', 'mtk_gpueb.ko', 'mtk_tinysys_ipi.ko']
        add = [d for d in extra if d not in deps.split()]
        if add:
            line = line.rstrip('\n') + (' ' if deps else '') + ' '.join(add) + '\n'
    # mali_prot_alloc.ko must load after mtk_gpueb and ged
    if line.startswith('mali_prot_alloc.ko:'):
        deps = line.rstrip('\n').split(':', 1)[1]
        extra = ['mtk_gpueb.ko', 'ged.ko']
        add = [d for d in extra if d not in deps.split()]
        if add:
            line = line.rstrip('\n') + (' ' if deps else '') + ' '.join(add) + '\n'
    # mali_kbase_mt6895.ko must load after memory allocators, ged, mfgcfg clock driver, and fhctl
    if line.startswith('mali_kbase_mt6895.ko:'):
        deps = line.rstrip('\n').split(':', 1)[1]
        extra = ['mali_prot_alloc.ko', 'mali_mgm.ko', 'ged.ko', 'clk-mt6895-mfgcfg.ko', 'fhctl.ko']
        add = [d for d in extra if d not in deps.split()]
        if add:
            line = line.rstrip('\n') + (' ' if deps else '') + ' '.join(add) + '\n'
    # mtk_gpufreq_mt6895.ko must load after fhctl.ko for dynamic frequency hopping
    if line.startswith('mtk_gpufreq_mt6895.ko:'):
        deps = line.rstrip('\n').split(':', 1)[1]
        extra = ['fhctl.ko']
        add = [d for d in extra if d not in deps.split()]
        if add:
            line = line.rstrip('\n') + (' ' if deps else '') + ' '.join(add) + '\n'
    # ged.ko must load after mtk_gpu_qos and sspm_v3
    if line.startswith('ged.ko:'):
        deps = line.rstrip('\n').split(':', 1)[1]
        extra = ['sspm_v3.ko', 'mtk_gpu_qos.ko']
        add = [d for d in extra if d not in deps.split()]
        if add:
            line = line.rstrip('\n') + (' ' if deps else '') + ' '.join(add) + '\n'
    # mtk_gpu_qos.ko must load after mtk_qos
    if line.startswith('mtk_gpu_qos.ko:'):
        deps = line.rstrip('\n').split(':', 1)[1]
        extra = ['mtk_qos.ko']
        add = [d for d in extra if d not in deps.split()]
        if add:
            line = line.rstrip('\n') + (' ' if deps else '') + ' '.join(add) + '\n'
    # mtk_qos.ko must load after sspm_v3 and tinysys-scmi
    if line.startswith('mtk_qos.ko:'):
        deps = line.rstrip('\n').split(':', 1)[1]
        extra = ['sspm_v3.ko', 'tinysys-scmi.ko']
        add = [d for d in extra if d not in deps.split()]
        if add:
            line = line.rstrip('\n') + (' ' if deps else '') + ' '.join(add) + '\n'
    # sspm_v3.ko must load after tinysys-scmi
    if line.startswith('sspm_v3.ko:'):
        deps = line.rstrip('\n').split(':', 1)[1]
        extra = ['tinysys-scmi.ko']
        add = [d for d in extra if d not in deps.split()]
        if add:
            line = line.rstrip('\n') + (' ' if deps else '') + ' '.join(add) + '\n'
    # mt6375-battery.ko must load after mt6375 core, auxadc, adc and charger framework
    if line.startswith('mt6375-battery.ko:'):
        deps = line.rstrip('\n').split(':', 1)[1]
        extra = ['mt6375.ko', 'mt6375-auxadc.ko', 'mt6375-adc.ko', 'mtk_charger_framework.ko', 'charger_class.ko']
        add = [d for d in extra if d not in deps.split()]
        if add:
            line = line.rstrip('\n') + (' ' if deps else '') + ' '.join(add) + '\n'
    out.append(line)
with open(dep_path, 'w') as f:
    f.writelines(out)
PYEOF
    # xaga: order modules.load by dependency (modules.dep) so first-stage
    # insmod never hits "Unknown symbol" - alphabetical order loads e.g.
    # cache-parity (c) before mrdump (m) which it depends on (2026-08-10).
    python3 - modules.dep <<'PYEOF' > modules.load
import sys

deps = {}
for line in open(sys.argv[1]):
    if ':' not in line:
        continue
    mod, rest = line.split(':', 1)
    mod = mod.strip()
    if mod.endswith('.ko'):
        mod = mod[:-3]
    deps[mod] = [x.strip()[:-3] if x.strip().endswith('.ko') else x.strip()
                 for x in rest.split() if x.strip()]

order, remaining = [], set(deps)
while remaining:
    ready = sorted(m for m in remaining if not (set(deps[m]) & remaining))
    if not ready:
        ready = sorted(remaining)
    order += ready
    remaining -= set(ready)

sys.stdout.write('\n'.join(order) + '\n')
PYEOF
    # xaga: xhci-mtk-hcd-v2 must insmod BEFORE mtu3. mtu3's probe runs
    # ssusb_host_init (of_platform_populate) then ssusb_get_host_rscs, which
    # reads the xhci child node's pdev->dev.driver synchronously; if the xhci
    # driver is not registered yet, dev.driver is NULL and
    # to_platform_driver(NULL) yields a -0x28 garbage pointer that crashes
    # ssusb_host_exit_v2 on the first mode switch (2026-08-11). There is no
    # symbol dependency between the two, so the topological sort puts mtu3
    # first alphabetically.
    #
    # NOTE: only xhci must precede mtu3. The typec/charger/extcon chain must
    # stay AFTER mtu3 (as in official 5.10: mtu3 then mt6375/tcpc/extcon):
    # extcon-mtk-usb resolves mtu3's role switch via usb_role_switch_get()
    # in probe and fails with 'failed to get usb role' if mtu3 has not
    # registered it yet (2026-08-11 real device).
    #
    # Run 91: Re-enable mali_kbase_mt6895 in early modules.load now that
    # guarded CSG 6 auto-patch is active, allowing SurfaceFlinger to access /dev/mali0.
    # Exclude clk-disable-unused to prevent early display clock shutdown.
    python3 - <<'PYEOF' > modules.load.tmp
import sys
mods = [l.strip() for l in open('modules.load') if l.strip()]
exclude = {'clk-disable-unused', 'clk_disable_unused'}
mods = [m for m in mods if m not in exclude and m.removesuffix('.ko') not in exclude]
present = [m for m in ['xhci-mtk-hcd-v2'] if m in mods]
rest = [m for m in mods if m not in present]
try:
    idx = rest.index('mtu3')
except ValueError:
    idx = len(rest)
sys.stdout.write('\n'.join(rest[:idx] + present + rest[idx:]) + '\n')
PYEOF
    mv modules.load.tmp modules.load
    # xaga: keep modules.load.recovery in sync - recovery first-stage init
    # (libmodprobe) reads modules.load.recovery, NOT modules.load, so the
    # dependency-ordered list must be replicated or recovery loads modules in
    # plain alphabetical order and e.g. mtk_iommu/mtk-scpsys-mt6895 land AFTER
    # mediatek-drm -> dispsys_config probe waits on iommu/power-domain that are
    # not yet loaded -> no drm dev -> recovery graphics timeout (2026-08-12).
    cp modules.load modules.load.recovery
    # Set default module options for mali_kbase (also customizable via magiskboot repack)
    cat << 'EOF' > modules.options
options mali_kbase_mt6895 xaga_prepower=0 mali_strip_share=0 mali_force_coh_none=0
EOF
    cp modules.options modules.options.recovery 2>/dev/null || true
    if [ -f "$VD/vendor_ramdisk/rd/lib/modules/isee.ko" ]; then
        if llvm-nm -u "$VD/vendor_ramdisk/rd/lib/modules/isee.ko" 2>/dev/null | grep -q 'bootprof_log_boot' || \
           nm -u "$VD/vendor_ramdisk/rd/lib/modules/isee.ko" 2>/dev/null | grep -q 'bootprof_log_boot'; then
            echo "FATAL ERROR: bootprof_log_boot still undefined in isee.ko!" >&2
            exit 1
        fi
    fi

    # Verify symbol resolution and provider load order for all modules in modules.load
    local ALL_SYMVERS="$WORK/all_Module.symvers"
    cat "$OUT/Module.symvers" "$M/Module.symvers" 2>/dev/null > "$ALL_SYMVERS" || cp "$OUT/Module.symvers" "$ALL_SYMVERS"
    echo "Running check_syms validation on vendor ramdisk modules..."
    python3 "$SCRIPT_DIR/scripts/check_syms.py" "$ALL_SYMVERS" "$VD/vendor_ramdisk/rd/lib/modules" modules.load || {
        echo "ERROR: check_syms validation failed! Unresolved symbols or ordering violations detected." >&2
        exit 1
    }
    cd "$VD/vendor_ramdisk/rd"
    sed -i 's/^ro\.debuggable=0/ro.debuggable=1/' prop.default 2>/dev/null || true

    find . | cpio -o -H newc > "$VD/vr_new.cpio" 2>/dev/null || true
    # IMPORTANT: compress with lz4 -l (legacy, magic 02 21 4c 18) - the
    # vendor_ramdisk is the kernel's initrd (/dev/ram), and both LK and the
    # kernel expect the legacy format. Standard lz4 (04 22 4d 18) yields
    # 'rootfs image is not initramfs (invalid magic)' -> VFS: Unable to
    # mount root fs -> panic (2026-08-11). Decompress above uses standard
    # lz4 -d (official stream is standard frame; -l decompress is unstable).
    lz4 -l -9 -f "$VD/vr_new.cpio" "$VD/vr_new.lz4" > /dev/null 2>&1

    # dtb slot: DTBO_TAG container of the SoC base (matches official format)
    python3 "$MKDTBO" "$VD/dtb_container.bin" "$WORK/dts/mt6895.dtb" > /dev/null

    python3 "$MKBOOTIMG" --vendor_boot "$VD/vendor_boot_new.img" \
        --vendor_ramdisk "$VD/vr_new.lz4" \
        --dtb "$VD/dtb_container.bin" \
        --vendor_cmdline "bootopt=64S3,32N2,64N2 log_buf_len=8M clk_ignore_unused androidboot.selinux=permissive enforcing=0 xaga.no_reboot=1" \
        --base 0x40000000 --kernel_offset 0 --ramdisk_offset 0x26f00000 \
        --tags_offset 0x7c80000 --dtb_offset 0x7c80000 \
        --header_version 4 --pagesize 4096 --board "" > "$WORK/vb_mkboot.log" 2>&1
    # pad to 64MB
    python3 - "$VD/vendor_boot_new.img" << 'EOF'
import sys
p = sys.argv[1]
data = open(p, 'rb').read()
data += b'\x00' * (67108864 - len(data))
open(p, 'wb').write(data)
EOF
    # xaga self-check: the repacked vendor ramdisk must still carry the full
    # official system section (system/etc/recovery.fstab + toybox bin set).
    # The extraction gate above already guarantees vr.raw is the full 80MB;
    # this second gate catches any repack-time regression. Fail loud instead
    # of shipping a bad vendor_boot. NOTE: avoid `grep -q` in a pipe here -
    # set -o pipefail turns grep's early-exit SIGPIPE into a pipe failure.
    local VRFILE="$VD/vr_new.cpio"
    if [ "$(cpio -it < "$VRFILE" 2>/dev/null | grep -c '^system/etc/recovery.fstab$')" -eq 0 ]; then
        echo "ERROR: vendor ramdisk missing system/etc/recovery.fstab (truncated unpack?)" >&2
        echo "  ramdisk cpio: $(stat -c %s "$VRFILE") bytes; official full is 88036352" >&2
        exit 1
    fi
    # the compressed vendor_ramdisk must be LEGACY lz4 (02 21 4c 18) - it is
    # the kernel's initrd; standard format (04 22 4d 18) -> VFS mount fail
    if [ "$(od -A n -t x1 -N 4 "$VD/vr_new.lz4" 2>/dev/null | tr -d ' \n')" != "02214c18" ]; then
        echo "ERROR: vr_new.lz4 is not legacy lz4 (kernel initrd format)" >&2
        echo "  head: $(od -A n -t x1 -N 4 "$VD/vr_new.lz4" 2>/dev/null) (want 02 21 4c 18)" >&2
        exit 1
    fi
    cp "$VD/vendor_boot_new.img" "$OUT_IMG/vendor_boot_new.img"
    ls -la "$OUT_IMG/vendor_boot_new.img"
}

# ---------------------------------------------------------------------------
# 8. dtbo_new.img: DTOv1 single entry, NOT padded
# ---------------------------------------------------------------------------
pack_dtbo() {
    log "8/8 dtbo_new.img (DTOv1 single entry, unpadded)"
    python3 "$MKDTBO" "$OUT_IMG/dtbo_new.img" "$WORK/dts/xaga.dtbo"
    ls -la "$OUT_IMG/dtbo_new.img"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
preflight
[ "$SKIP_CLEAN" -eq 1 ] || clean
if [ "$MODULES_ONLY" -eq 1 ]; then
    config
    modules
else
    config
    kernel
    modules
    dts
    skip BOOT || pack_boot
    skip VENDOR || pack_vendor
    skip DTBO || pack_dtbo
fi

log "DONE. artifacts:"
if [ "$MODULES_ONLY" -eq 1 ]; then
    echo "out-of-tree modules: $(find "$M" -name '*.ko' | wc -l) x .ko in $M"
    echo "Module.symvers: $(ls -la "$OUT/Module.symvers" 2>/dev/null | awk '{print $5, $9}')"
else
    ls -la "$OUT/arch/arm64/boot/Image.gz" "$OUT/dts/"
    echo "out-of-tree modules: $(find "$M" -name '*.ko' | wc -l) x .ko in $M"
    ls -la "$OUT_IMG"/boot_new.img "$OUT_IMG"/vendor_boot_new.img "$OUT_IMG"/dtbo_new.img 2>/dev/null
fi
BUILD_END_EPOCH="$(date +%s)"
echo "build log: $WORK (kept for inspection)"
echo -e "\033[1;32m[$(fmt_ts)] total build time: $(fmt_dur $(( BUILD_END_EPOCH - BUILD_START_EPOCH )))\033[0m"
