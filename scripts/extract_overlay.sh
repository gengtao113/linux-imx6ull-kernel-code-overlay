#!/bin/bash
# 从 git 分支提取定制改动到 overlay（幂等：重建 common/projects/.baseline，绝不碰 scripts/）
# 用法: extract_overlay.sh [<project>] [--branch IMX6] [--base master-gengtao-0901]
# 警告: 对学习项目跑 --branch IMX6 会把出厂全部定制（数百文件）提取进来，
#       如需参考出厂实现，请提取到独立项目（如 projects/atk-mx6ull-ref）。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/common.sh"

PROJECT="${1:-gengtao-bsp-0901}"
SRC_BRANCH="IMX6"
for a in "${@:2}"; do
    case "$a" in
        --branch=*) SRC_BRANCH="${a#*=}" ;;
        --base=*)   BASE_BRANCH="${a#*=}" ;;
        *) die "未知参数: $a" ;;
    esac
done

# 工作树未提交补丁（git archive 取不到，从工作树提取）
W_FILES="scripts/dtc/dtc-lexer.l scripts/dtc/dtc-lexer.lex.c_shipped"

cd "$KERNEL_DIR"

# 1. 前置校验
git rev-parse --verify -q "$BASE_BRANCH" >/dev/null || die "缺少基线分支 $BASE_BRANCH"
git rev-parse --verify -q "$SRC_BRANCH"  >/dev/null || die "缺少源分支 $SRC_BRANCH"

# 2. 清空 overlay 内容区（保留 scripts/），幂等重建
rm -rf "$OVERLAY_DIR/common" "$OVERLAY_DIR/projects/$PROJECT" "$OVERLAY_DIR/.baseline"
mkdir -p "$OVERLAY_DIR/common" "$OVERLAY_DIR/projects/$PROJECT" "$OVERLAY_DIR/.baseline"

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

# 3. 生成状态清单并分流
git diff --name-status "$BASE_BRANCH..$SRC_BRANCH" > "$TMPD/status" || die "git diff 失败"
[ -s "$TMPD/status" ] || die "$BASE_BRANCH..$SRC_BRANCH 无差异"
# 防御：git archive 的参数展开依赖无空格/引号路径（只查路径列，状态与路径之间本就是制表符）
awk '{print $2}' "$TMPD/status" | grep -qE '[[:space:]"]' && die "存在含空格/引号的路径，extract_overlay.sh 不支持"

while read -r st path; do
    [ -n "$path" ] || continue
    layer_for "$path"
done < "$TMPD/status" > "$TMPD/layers"

paste "$TMPD/status" "$TMPD/layers" > "$TMPD/manifest_raw"
awk '$3=="common"                 {print $2}' "$TMPD/manifest_raw" > "$TMPD/common.list"
awk -v p="projects/$PROJECT" '$3==p {print $2}' "$TMPD/manifest_raw" > "$TMPD/project.list"

# 4. 提取完整文件（A/M 一视同仁）：2 次 git archive 替代数百次 git show
if [ -s "$TMPD/common.list" ]; then
    git archive "$SRC_BRANCH" -- $(cat "$TMPD/common.list") | tar -xf - -C "$OVERLAY_DIR/common"
fi
if [ -s "$TMPD/project.list" ]; then
    git archive "$SRC_BRANCH" -- $(cat "$TMPD/project.list") | tar -xf - -C "$OVERLAY_DIR/projects/$PROJECT"
fi

# 5. 工作树未提交补丁（W 状态）
: > "$TMPD/w.list"
for f in $W_FILES; do
    grep -qF "$f" "$TMPD/manifest_raw" && { warn "$f 已在分支差异中，跳过 W 提取"; continue; }
    [ -f "$KERNEL_DIR/$f" ] || { warn "$f 不在内核树，跳过"; continue; }
    layer=$(layer_for "$f")
    mkdir -p "$OVERLAY_DIR/$layer/$(dirname "$f")"
    cp -f "$KERNEL_DIR/$f" "$OVERLAY_DIR/$layer/$f"
    echo "W	$f	$layer" >> "$TMPD/manifest_raw"
    echo "$f" >> "$TMPD/w.list"
done

# 6. 生成 MANIFEST（含 base 注释）
base_sha=$(git rev-parse "$BASE_BRANCH")
{
    echo "# overlay MANIFEST - 由 extract_overlay.sh 生成"
    echo "# date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# base($BASE_BRANCH): $base_sha"
    echo "# branch($SRC_BRANCH): $(git rev-parse "$SRC_BRANCH")"
    sed -e '/^$/d' "$TMPD/manifest_raw" | awk '{printf "%s\t%s\t%s\n", $1, $2, $3}'
} > "$OVERLAY_DIR/MANIFEST"

# 7. 生成 .baseline 快照（M 状态的基线侧内容，供未来上游冲突检测）
while read -r st path layer; do
    [ "$st" = "M" ] || continue
    if [ -n "$(git cat-file -e "$BASE_BRANCH:$path" 2>/dev/null && echo yes)" ]; then
        mkdir -p "$OVERLAY_DIR/.baseline/$(dirname "$path")"
        git show "$BASE_BRANCH:$path" > "$OVERLAY_DIR/.baseline/$path"
    fi
done < "$TMPD/manifest_raw"

echo "extract 完成: $(grep -cv '^#' "$OVERLAY_DIR/MANIFEST") 个文件"
