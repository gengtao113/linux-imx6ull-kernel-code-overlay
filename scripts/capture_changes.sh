#!/bin/bash
# 可选：把编译树中的手工修改回收到 overlay（编辑-编译-回收闭环）
# 用法: capture_changes.sh <project> [--dry-run]
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/common.sh"

PROJECT="${1:?用法: capture_changes.sh <project> [--dry-run]}"
DRY=0
[ "${2:-}" = "--dry-run" ] && DRY=1

cd "$KERNEL_DIR"

# 构建产物/生成文件过滤
filter_source() {
    case "$1" in
        *.o|*.ko|*.mod.c|*.cmd|*.dtb|*.a|*.so|*.tmp|*.lst) return 1 ;;
        .config|.config.old|Module.symvers|modules.order|modules.builtin|System.map) return 1 ;;
        vmlinux|vmlinux.o|vmlinux.gz|zImage|Image|*.tmp_*) return 1 ;;
        include/config/*|include/generated/*|arch/*/include/generated/*) return 1 ;;
        *) return 0 ;;
    esac
}

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
git status --porcelain -uall | sed 's/^...//' > "$TMPD/paths"

CNT=0
while read -r p; do
    [ -n "$p" ] || continue
    filter_source "$p" || continue
    layer=$(layer_for "$p")
    if [ "$DRY" -eq 1 ]; then
        echo "  $p -> $layer"
    else
        mkdir -p "$OVERLAY_DIR/$layer/$(dirname "$p")"
        cp -f "$p" "$OVERLAY_DIR/$layer/$p"
        echo "  $p -> $layer"
    fi
    CNT=$((CNT+1))
done < "$TMPD/paths"

echo "capture 完成: $CNT 个文件（$([ "$DRY" -eq 1 ] && echo dry-run)）"
echo "注意: 若文件状态有增删变化，建议重跑 extract_overlay.sh 校正 MANIFEST"
