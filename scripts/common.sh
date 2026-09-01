#!/bin/bash
# overlay 工具链公共库
# 常量可用环境变量覆盖；提供 die/warn/layer_for/safe_reset

LINUX_ROOT=${LINUX_ROOT:-/home/gengtao/linux-imx6ull-code}
KERNEL_DIR=${KERNEL_DIR:-$LINUX_ROOT/linux-imx6ull-kernel-code}
OVERLAY_DIR=${OVERLAY_DIR:-$LINUX_ROOT/linux-kernel-overlay}
OUTPUT_DIR=${OUTPUT_DIR:-$LINUX_ROOT/output}
TOOLCHAIN=${TOOLCHAIN:-/usr/local/arm/gcc-linaro-4.9.4-2017.01-x86_64_arm-linux-gnueabihf}
# 注意：不用环境变量 CROSS_COMPILE 做默认值——用户 shell 环境可能已导出
# buildroot 等其他工具链前缀（会与内核构建冲突）。编译脚本里显式 export 本变量。
LINARO_CROSS=${LINARO_CROSS:-$TOOLCHAIN/bin/arm-linux-gnueabihf-}

# 内核基线分支（safe_reset 以此为基准，切勿改错）
BASE_BRANCH=master-gengtao-0901

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }

# 分层规则：内核树相对路径 -> overlay 层（调用前需设置 PROJECT）
layer_for() {
    case "$1" in
        arch/arm/boot/dts/*|arch/arm/configs/*|drivers/video/*|drivers/tty/vt/vt.c)
            echo "projects/${PROJECT:?PROJECT 未设置}" ;;
        *)
            echo "common" ;;
    esac
}

# 安全重置内核树到基线。
# 注意：绝不在非 BASE_BRANCH 分支上执行 git reset --hard —— 那会把当前分支 ref
# 直接移到基线提交，销毁该分支历史。非 BASE_BRANCH 一律 checkout -f BASE_BRANCH。
# 用法: safe_reset [--force]
safe_reset() {
    local force="$1"
    cd "$KERNEL_DIR" || exit 1
    git rev-parse --git-dir >/dev/null 2>&1 || die "不是 git 仓库: $KERNEL_DIR"

    local dirty
    dirty=$(git status --porcelain | wc -l)
    if [ "$dirty" -gt 0 ] && [ "$force" != "--force" ]; then
        die "内核树不干净（$dirty 项改动）。请先 capture_changes.sh 回收，或确认丢弃后加 --force"
    fi

    local untracked
    untracked=$(git clean -nd)
    if [ -n "$untracked" ]; then
        echo "将删除的未跟踪文件/目录预览:"
        echo "$untracked" | head -20
    fi

    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)
    if [ "$branch" = "$BASE_BRANCH" ]; then
        git reset --hard "$BASE_BRANCH"
    else
        git checkout -f "$BASE_BRANCH"    # 只动 HEAD/工作树，保护原分支 ref
    fi
    git clean -fd
}
