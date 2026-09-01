#!/bin/bash
#=========================================================
# 正点原子 I.MX6ULL 开发板 Linux 内核更新脚本
# 把 output/<project>/ 里的编译产物更新到 TFTP / NFS 服务目录，板子复位即可验证
# 用法: ./update_board.sh <project> [tftp|nfs|all]  默认 tftp
#   tftp  更新 zImage + dtb 到 TFTP 目录（最快验证）
#   nfs   更新内核模块到 NFS 根文件系统
#   all   TFTP + NFS 全部更新
#=========================================================

set -e  # 任一命令出错即退出

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/common.sh"

PROJECT="${1:?用法: $0 <project> [tftp|nfs|all]}"
MODE=${2:-tftp}

#------------------------ 可修改配置项 --------------------------------
TFTP_DIR=/home/gengtao/linux-imx6ull/tftpboot                  # TFTP 目录（uboot 从此拉取内核）
ROOTFS_DIR=/home/gengtao/linux-imx6ull/nfs/rootfs              # NFS 根文件系统（更新模块用）
DTB=imx6ull-14x14-emmc-7-1024x600-c                           # 板载屏幕对应设备树（学习目标名）
#----------------------------------------------------------------------

OUT="$OUTPUT_DIR/$PROJECT"

usage()
{
    echo "用法: $0 <project> [tftp|nfs|all]"
    echo "  tftp  更新 zImage + dtb 到 TFTP 目录（默认）"
    echo "  nfs   更新内核模块到 NFS 根文件系统"
    echo "  all   TFTP + NFS 全部更新"
    exit 1
}

case "$MODE" in
    tftp|nfs|all) ;;
    *) usage ;;
esac

echo "=============================================="
echo " i.MX6ULL Linux 内核更新脚本"
echo "   项目     : ${PROJECT}"
echo "   产物目录 : ${OUT}"
echo "   模式     : ${MODE}"
echo "=============================================="

# 1. 更新 TFTP（zImage + dtb）
if [ "${MODE}" == "tftp" ] || [ "${MODE}" == "all" ]; then
    if [ ! -f "${OUT}/zImage" ]; then
        echo "[错误] 未找到 ${OUT}/zImage，请先执行 build_kernel.sh ${PROJECT}"
        exit 1
    fi
    if [ ! -d "${TFTP_DIR}" ]; then
        echo "[错误] TFTP 目录不存在: ${TFTP_DIR}"
        exit 1
    fi
    echo "-- 更新 TFTP 目录: ${TFTP_DIR} --"
    cp -v "${OUT}/zImage" "${TFTP_DIR}/"
    if [ -f "${OUT}/${DTB}.dtb" ]; then
        cp -v "${OUT}/${DTB}.dtb" "${TFTP_DIR}/"
    else
        echo "WARN: ${OUT}/${DTB}.dtb 不存在（尚未编写该 dts），跳过。"
        echo "      第一阶段可先用官方 dtb 启动：uboot 里把 fdt_file 改成 imx6ull-14x14-evk-emmc.dtb"
    fi
fi

# 2. 更新 NFS（内核模块）
if [ "${MODE}" == "nfs" ] || [ "${MODE}" == "all" ]; then
    if [ ! -f "${OUT}/modules.tar.bz2" ]; then
        echo "[错误] 未找到 ${OUT}/modules.tar.bz2"
        exit 1
    fi
    echo "-- 更新 NFS 根文件系统: ${ROOTFS_DIR} --"
    tar -jxf "${OUT}/modules.tar.bz2" -C "${ROOTFS_DIR}"
fi

echo ""
echo "=============================================="
echo " 更新完成! 复位板子后依次执行验证:"
echo "   uname -a"
echo "   cat /sys/class/graphics/fb0/virtual_size"
echo "=============================================="
