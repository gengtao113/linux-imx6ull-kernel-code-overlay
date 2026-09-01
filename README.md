# i.MX6ULL 内核 overlay 定制（学习项目）

内核树 `../linux-imx6ull-kernel-code` 保持 **master-gengtao-0901 干净基线**
（NXP 官方 4.1.15-2.1.0），零直接改动。所有定制放在本目录，编译时先拷贝覆盖再编译。

## 目录结构

```
linux-kernel-overlay/
├── MANIFEST               # 定制清单（基线 sha + 每行 "<状态> <路径> <层>"）
├── common/                # 公共定制：构建适配补丁等（当前：dtc extern yylloc 补丁）
├── projects/gengtao-bsp-0901/ # 你的板级定制（dts/drivers 等，从零开始往里加）
├── gengtao-bsp-doc/       # 学习笔记与问题排查复盘文档
├── .baseline/             # 修改文件的基线侧快照（未来内核升级冲突检测用）
└── scripts/
    ├── common.sh                 # 公共库（路径/工具链/分层规则/safe_reset）
    ├── build_kernel.sh           # 一键：重置基线 + apply + 编译 + 打包到 ../output/
    ├── apply_overlay.sh          # overlay → 内核树（先 common 后 project）
    ├── restore_baseline.sh       # 内核树恢复干净基线
    ├── capture_changes.sh        # 把内核树里的手工修改回收到 overlay
    ├── extract_overlay.sh        # 从 git 分支提取定制（慎用，见下）
    └── update_board.sh           # 部署产物到 TFTP/NFS，板子复位验证
```

## 学习工作流（核心）

```
① 写代码：只改 overlay 里的文件，绝不直接改内核树
   vim linux-kernel-overlay/projects/gengtao-bsp-0901/arch/arm/boot/dts/xxx.dts

② 一键构建（重置内核树 → 应用 overlay → 编译 → 产物到 ../output/gengtao-bsp-0901/）
   linux-kernel-overlay/scripts/build_kernel.sh gengtao-bsp-0901

③ 部署到板子
   linux-kernel-overlay/scripts/update_board.sh gengtao-bsp-0901 tftp
   （改了内核模块时用 all）

④ 板子复位验证 → 通了就 git 提交 overlay 作为一个里程碑
```

### 快速循环（改完只想快速验证）

```bash
# 只重编内核镜像（跳过重置/清理，增量秒级~分钟级）
linux-kernel-overlay/scripts/apply_overlay.sh gengtao-bsp-0901 --force
cd ../linux-imx6ull-kernel-code
source ../linux-kernel-overlay/scripts/common.sh
make ARCH=arm CROSS_COMPILE=$LINARO_CROSS zImage -j$(nproc)
../linux-kernel-overlay/scripts/update_board.sh gengtao-bsp-0901 tftp
```

### 新增一个外设的标准步骤

1. 看硬件原理图 → 引脚（pinctrl）、总线（I2C/SPI）、中断脚
2. 在 overlay 里写 dts 节点（模仿内核树里 NXP evk dts 的写法）
3. **dts 记得接线**：把新 dtb 目标加到
   `projects/gengtao-bsp-0901/arch/arm/boot/dts/Makefile`
   （apply_overlay.sh 会校验，漏了直接报错提示）
4. 内核配置开启对应驱动 CONFIG（改 `projects/gengtao-bsp-0901/arch/arm/configs/imx_v7_defconfig`）
5. 构建 → 部署 → 板子验证（dmesg、/dev 节点、sysfs）
6. 卡住了再看参考答案：`git -C ../linux-imx6ull-kernel-code show IMX6:arch/arm/boot/dts/xxx.dts`
   （IMX6 分支有出厂全部实现，先自己想再看）

## 关键约束（务必遵守）

- **永远只改 overlay，不改内核树**。build_kernel.sh 每次都会 `git reset --hard` +
  `git clean -fd` 重置内核树，内核树里未提交的改动会被**彻底删除**。
  若不小心在内核树改了代码：先 `capture_changes.sh gengtao-bsp-0901` 回收到 overlay 再构建。
- 设备树目标列表、编译内容全部由 MANIFEST 驱动：新加了 dts 就自动编对应 dtb。
- 第一阶段（还没有自己的 dts 时）：板子用官方 dtb 启动——
  uboot 里 `setenv fdt_file imx6ull-14x14-evk-emmc.dtb; saveenv`。
  屏幕时序不对属正常现象，第一阶段目标只是"内核能启动"。
- `extract_overlay.sh --branch IMX6` 会把出厂全部定制（数百文件）提取进 overlay，
  **不要**对学习项目跑它；要看参考实现，提取到独立项目
  （`extract_overlay.sh atk-mx6ull-ref --branch IMX6`）。

## 里程碑建议

每打通一个外设，在 overlay 目录里提交一次：
`git -C linux-kernel-overlay add -A && git -C linux-kernel-overlay commit -m "打通 XXX 驱动"`
出问题时可用 git 历史精确对比回退。