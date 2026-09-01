#!/bin/bash
# 应用 overlay 到内核树：先 common 后 project（项目层压过公共层）
# 用法: apply_overlay.sh <project> [--force] [--no-verify]
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/common.sh"

PROJECT="${1:?用法: apply_overlay.sh <project> [--force] [--no-verify]}"
FORCE=0; VERIFY=1
for a in "${@:2}"; do
    case "$a" in
        --force) FORCE=1 ;;
        --no-verify) VERIFY=0 ;;
        *) die "未知参数: $a" ;;
    esac
done

[ -d "$OVERLAY_DIR/projects/$PROJECT" ] || die "项目不存在: $OVERLAY_DIR/projects/$PROJECT"
[ -f "$OVERLAY_DIR/MANIFEST" ] || die "缺少 MANIFEST"

cd "$KERNEL_DIR"
git rev-parse --git-dir >/dev/null 2>&1 || die "不是 git 仓库: $KERNEL_DIR"

# 1. 内核树状态预检：cp -rf 会覆盖未回收的修改
DIRTY=$(tree_porcelain | wc -l)
if [ "$DIRTY" -gt 0 ] && [ "$FORCE" -eq 0 ]; then
    die "内核树不干净（$DIRTY 项改动）。请先 capture_changes.sh 回收或 restore_baseline.sh（强制覆盖加 --force）"
fi

# 2. 上游升级冲突检测（基线前进时才触发）
base_sha=$(awk '/^# base\(/ {print $3}' "$OVERLAY_DIR/MANIFEST")
cur_sha=$(git rev-parse "$BASE_BRANCH")
if [ "$base_sha" != "$cur_sha" ]; then
    # 基线前进时逐文件检测：仅在确有整文件覆盖冲突时才告警
    CONFLICTS=$(awk '$1=="M" {print $2}' "$OVERLAY_DIR/MANIFEST" | while read -r p; do
        [ -f "$OVERLAY_DIR/.baseline/$p" ] || continue
        if ! git show "$BASE_BRANCH:$p" 2>/dev/null | cmp -s - "$OVERLAY_DIR/.baseline/$p"; then
            echo "  $p: 上游已修改，overlay 整文件覆盖将丢失上游改动（需人工合并）"
        fi
    done)
    if [ -n "$CONFLICTS" ]; then
        warn "$BASE_BRANCH 已从提取基线 $base_sha 前进到 $cur_sha，以下整文件覆盖将丢失上游改动:"
        warn "$CONFLICTS"
    fi
fi

# 3. 拷贝覆盖：先 common 后 project
cp -rf "$OVERLAY_DIR/common/." "$KERNEL_DIR/"
cp -rf "$OVERLAY_DIR/projects/$PROJECT/." "$KERNEL_DIR/"
# 清除 .gitkeep 占位文件（仅用于让空目录进 git，不属于定制内容）
# 注意排除 overlay 自身目录（overlay 是内核树的子模块，不能误删其占位文件）
find "$KERNEL_DIR" -path "$OVERLAY_DIR" -prune -o -name .gitkeep -delete 2>/dev/null || true

# 4. 完整性校验：树中路径集合 == MANIFEST 路径集合
if [ "$VERIFY" -eq 1 ]; then
    TMPD=$(mktemp -d)
    trap 'rm -rf "$TMPD"' EXIT
    grep -v '^#' "$OVERLAY_DIR/MANIFEST" | awk '{print $2}' | sort > "$TMPD/manifest_paths"
    tree_porcelain -uall | sed 's/^...//' | sort > "$TMPD/tree_paths"

    MISSING=$(comm -23 "$TMPD/manifest_paths" "$TMPD/tree_paths")
    EXTRA=$(comm -13 "$TMPD/manifest_paths" "$TMPD/tree_paths")
    if [ -n "$MISSING" ]; then
        echo "以下 MANIFEST 文件未在树中生效:"; echo "$MISSING"
        die "overlay 应用不完整（分层或提取有误）"
    fi
    if [ -n "$EXTRA" ]; then
        warn "树中存在 MANIFEST 之外的文件（用户残留或构建产物）:"
        echo "$EXTRA" | head -20
    fi

    # dts/Makefile 专项断言：MANIFEST 中的每个 dts 都要有对应 dtb 目标
    for d in $(grep -v '^#' "$OVERLAY_DIR/MANIFEST" \
        | awk '$2 ~ /^arch\/arm\/boot\/dts\/.*\.dts$/ {sub(/^.*\//,"",$2); sub(/\.dts$/,"",$2); print $2}'); do
        grep -q "$d.dtb" arch/arm/boot/dts/Makefile \
            || die "dts/Makefile 缺 $d.dtb 目标（新增 dts 记得在 project 的 dts/Makefile 里接线）"
    done
fi

echo "apply 完成: $(grep -cv '^#' "$OVERLAY_DIR/MANIFEST") 个文件已覆盖到内核树"
