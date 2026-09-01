#!/bin/bash
# 恢复内核树到干净基线（保护当前分支历史，见 common.sh safe_reset）
# 用法: restore_baseline.sh [--force]
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/common.sh"

safe_reset "${1:-}"

cd "$KERNEL_DIR"
[ -z "$(tree_porcelain)" ] || die "恢复后内核树仍不干净"
[ "$(git rev-parse HEAD)" = "$(git rev-parse "$BASE_BRANCH")" ] || die "HEAD 不在 $BASE_BRANCH"
echo "OK: 内核树已恢复到干净 $BASE_BRANCH 基线 $(git rev-parse --short HEAD)"
