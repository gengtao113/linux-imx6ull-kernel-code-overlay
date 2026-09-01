#!/bin/bash
# 一键构建：重置基线 -> apply overlay -> 编译 -> 打包到树外 output/
# 用法: build_kernel.sh <project> [--no-reset] [--targets "t1 t2"] [--no-modules] [--no-package] [--jobs N]
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/common.sh"

PROJECT="${1:?用法: build_kernel.sh <project> [--no-reset] [--targets ...] [--no-modules] [--no-package] [--jobs N]}"
shift
NO_RESET=0; NO_MODULES=0; NO_PACKAGE=0; TARGETS=""; JOBS=$(nproc)
while [ $# -gt 0 ]; do
    case "$1" in
        --no-reset)   NO_RESET=1 ;;
        --no-modules) NO_MODULES=1 ;;
        --no-package) NO_PACKAGE=1 ;;
        --targets)    TARGETS="${2:?--targets 需要参数}"; shift ;;
        --jobs)       JOBS="${2:?--jobs 需要参数}"; shift ;;
        *) die "未知参数: $1" ;;
    esac
    shift
done

OUT="$OUTPUT_DIR/$PROJECT"

# ① 重置内核树到干净基线（应用过 overlay 的树必有改动，故强制）
if [ "$NO_RESET" -eq 0 ]; then
    safe_reset --force
fi

# ② 应用 overlay（树刚重置过必干净，--force 冗余但无害）
"$SCRIPT_DIR/apply_overlay.sh" "$PROJECT" --force

# ③ 编译
[ -x "${LINARO_CROSS}gcc" ] || die "未找到交叉编译器 ${LINARO_CROSS}gcc（可用 TOOLCHAIN=... 覆盖）"
export ARCH=arm
export CROSS_COMPILE="$LINARO_CROSS"   # 显式导出，覆盖 shell 环境里可能存在的其他前缀
cd "$KERNEL_DIR"
make distclean
make imx_v7_defconfig -j"$JOBS"

if [ -n "$TARGETS" ]; then
    for t in $TARGETS; do
        make "$t" -j"$JOBS"
    done
else
    make zImage -j"$JOBS"

    # 设备树目标列表从 MANIFEST 动态提取（你新增 dts 后自动生效）
    DTBS=$(grep -v '^#' "$OVERLAY_DIR/MANIFEST" \
        | awk '$2 ~ /^arch\/arm\/boot\/dts\/.*\.dts$/ {sub(/^.*\//,"",$2); sub(/\.dts$/,"",$2); print $2}')
    if [ -n "$DTBS" ]; then
        for d in $DTBS; do
            make "$d.dtb" -j"$JOBS"
        done
    else
        echo "MANIFEST 中暂无 dts（跳过设备树编译，可在 project 中添加）"
    fi

    [ "$NO_MODULES" -eq 1 ] || make modules -j"$JOBS"
fi

# ④ 打包到树外 output/<project>/
if [ "$NO_PACKAGE" -eq 0 ] && [ -z "$TARGETS" ]; then
    rm -rf "$OUT"
    mkdir -p "$OUT/tmp"
    make modules_install INSTALL_MOD_PATH="$OUT/tmp"
    ( cd "$OUT/tmp/lib/modules" && tar -jcvf "$OUT/modules.tar.bz2" . )
    rm -rf "$OUT/tmp"
    cp arch/arm/boot/zImage "$OUT/"
    for d in $DTBS; do
        cp "arch/arm/boot/dts/$d.dtb" "$OUT/"
    done
    echo "产物目录: $OUT"
    ls "$OUT"
fi

echo "build 完成。如需恢复内核树干净基线: $SCRIPT_DIR/restore_baseline.sh"
