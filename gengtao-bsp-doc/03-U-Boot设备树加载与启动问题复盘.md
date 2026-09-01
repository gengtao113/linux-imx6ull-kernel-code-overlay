# 03 U-Boot 设备树加载与启动问题复盘

> 文档编号：03  
> 日期：2026-09-01  
> 板卡：正点原子 ATK-MX6ULL ALPHA|MINI（eMMC，7 寸 1024×600 屏）  
> 关联：01-内核BSP框架搭建与启动问题复盘（问题 3/4 的深入展开）  
> 状态：U-Boot/dtb 加载路径 ✅ 已解决；NFS/eth0 ⏳ 待 dts 定制

---

## 一、背景

学习项目采用 **overlay 定制框架**：内核树保持 NXP 纯净基线，板级 dts 放在 `projects/gengtao-bsp-0901/`，编译时由 `apply_overlay.sh` 拷贝覆盖，产物经 TFTP 部署到板子。

板子启动链路：

```
U-Boot TFTP 拉 zImage + dtb → bootz 启动内核 → NFS 挂载 rootfs（192.168.3.51 板 / 192.168.3.52 主机）
```

本文复盘 2026-09-01 调试过程中，从「改了 fdt_file 却不生效」到「TFTP File not found 仍继续启动」的完整分析与解决过程。

---

## 二、现象时间线

| 阶段 | U-Boot TFTP 加载的 dtb | 内核侧表现 |
|------|------------------------|------------|
| 最初 | `imx6ull-14x14-evk-emmc.dtb`（官方） | `IP-Config: Device 'eth0' not found`，NFS 失败 |
| 设置 fdt_file 后 | 仍加载 `imx6ull-14x14-evk-emmc.dtb` | 同上，`setenv fdt_file` 无效 |
| bootcmd 改用 `${fdt_file}` 后 | `imx6ull-14x14-emmc-7-1024x600-c.dtb` | TFTP `File not found`，内核仍启动（不可靠） |
| bootcmd 写死定制 dtb 名后 | `imx6ull-14x14-evk-emmc-gengtao0901-1024-600.dtb` | TFTP 成功，dtb 加载正确 ✅ |

---

## 三、分层根因

```
┌─────────────────────────────────────────────────────────┐
│  Layer 1: bootcmd 硬编码 dtb，忽略 fdt_file              │  ← 已解决
├─────────────────────────────────────────────────────────┤
│  Layer 2: fdt_file 被板级代码覆盖；${fdt_file} 不可靠    │  ← 已解决
├─────────────────────────────────────────────────────────┤
│  Layer 3: TFTP 失败仍用 0x83000000 旧 dtb 启动           │  ← 需避免
├─────────────────────────────────────────────────────────┤
│  Layer 4: 定制 dtb 与官方 dtb md5 相同，dts 未真正定制   │  ← 待解决
├─────────────────────────────────────────────────────────┤
│  Layer 5: 缺 phy-reset-gpios 等 → eth0 不可用 → NFS 失败 │  ← 待解决
└─────────────────────────────────────────────────────────┘
```

---

## 四、问题 1：setenv fdt_file 无效

### 现象（U-Boot 环境变量 vs 实际行为）

用户执行：

```bash
setenv fdt_file imx6ull-14x14-evk-emmc-gengtao0901-1024-600.dtb
saveenv
reset
```

复位后 TFTP 日志仍显示：

```
Filename 'imx6ull-14x14-evk-emmc.dtb'.
```

同时 `printenv` 显示：

```
fdt_file=imx6ull-14x14-emmc-7-1024x600-c.dtb    # 出厂默认（7 寸屏 dtb 名）
bootcmd=tftp 80800000 zImage; tftp 83000000 imx6ull-14x14-evk-emmc.dtb; bootz 80800000 - 83000000
fdtfile                             # 未定义
```

### 分析过程

1. **对比变量与实际 TFTP 文件名**：`bootcmd` 里 dtb 文件名是字面量 `imx6ull-14x14-evk-emmc.dtb`，没有 `${fdt_file}` → 改 `fdt_file` 对启动无影响。
2. **排除 fdtfile 变量**：本板 U-Boot 未定义 `fdtfile`，只有 `fdt_file`。
3. **结论**：根因在 `bootcmd`，不在 `fdt_file`。

### 根因

`bootcmd` 硬编码 dtb 文件名，环境变量 `fdt_file` 从未被引用。

### 初步尝试（不完整）

```bash
setenv bootcmd 'tftp 80800000 zImage; tftp 83000000 ${fdt_file}; bootz 80800000 - 83000000'
saveenv
```

改完后 bootcmd 确实会读 `fdt_file`，但引出了下一个问题。

---

## 五、问题 2：${fdt_file} 被板级代码覆盖 + TFTP File not found

### 现象（U-Boot 日志）

设置 `fdt_file=gengtao0901-1024-600.dtb` 并改 bootcmd 用 `${fdt_file}` 后，复位日志：

```
Filename 'imx6ull-14x14-emmc-7-1024x600-c.dtb'.
Loading: *
TFTP error: 'File not found' (1)
Not retrying...
## Flattened Device Tree blob at 83000000
   Booting using the fdt blob at 83000000
```

### 分析过程

1. **变量被改写**：用户 setenv 的是 `gengtao0901-1024-600.dtb`，实际 TFTP 请求的却是 `imx6ull-14x14-emmc-7-1024x600-c.dtb`（正点原子出厂 7 寸屏 dtb 名）→ 说明 **saveenv 后、bootcmd 执行前，`fdt_file` 被板级 init 覆盖回出厂默认值**。
2. **PC 侧文件盘点**：TFTP 目录 `/home/gengtao/linux-imx6ull/tftpboot/` 只有：
   - `imx6ull-14x14-evk-emmc.dtb`
   - `imx6ull-14x14-evk-emmc-gengtao0901-1024-600.dtb`  
   **没有** `imx6ull-14x14-emmc-7-1024x600-c.dtb` → TFTP 必然失败。
3. **失败后仍 boot 的原因**：
   - 第二次 `tftp 83000000 ...` 失败后，`0x83000000` 内存中仍是 **上一次成功 boot 留下的 dtb**（官方 evk-emmc 或更早残留）。
   - U-Boot 的 `bootz 80800000 - 83000000` **不会**因 TFTP 失败而中止，也**不会**校验 dtb 是否与本次请求的文件一致。
   - 因此出现「File not found 但内核仍启动」——行为不可预测，可能表现为 NFS 失败、外设异常等。

### 根因

| 子问题 | 说明 |
|--------|------|
| fdt_file 不可靠 | 板级代码（推测为 board_late_init）按板型覆盖 `fdt_file` |
| TFTP 目标不存在 | 出厂 dtb 名不在主机 tftpboot 目录 |
| 陈旧 dtb 启动 | TFTP 失败后复用 0x83000000 内存残留，无校验 |

### 危险点说明

> **TFTP 报 File not found 后，U-Boot 仍用内存里 0x83000000 的旧 dtb 启动（上次 boot 残留），这不可靠，可能导致各种奇怪问题。**

验证 dtb 是否真正加载成功的唯一可靠标志：

```
Filename 'xxx.dtb'
Loading: ###
done
Bytes transferred = xxxxx
```

必须看到 **`done`**，不能仅有 `File not found` 后继续 boot。

---

## 六、问题 3：定制 dtb 文件名对了，内容却与官方相同

### 现象（PC 侧 md5 对比）

```bash
md5sum tftpboot/imx6ull-14x14-evk-emmc.dtb \
       tftpboot/imx6ull-14x14-evk-emmc-gengtao0901-1024-600.dtb
# 结果：2c4e99dbedda05cc0131e31c8e0f6903（完全相同）
```

### 分析过程

1. **dts 结构**：`imx6ull-14x14-evk-emmc-gengtao0901-1024-600.dts` include `imx6ull-14x14-evk-gengtao0901.dts`，后者从官方 EVK dts 复制，仅 emmc 层追加 `usdhc2` 8bit 配置。
2. **编译结果**：与官方 `imx6ull-14x14-evk-emmc.dts` 编译产物字节级相同 → **换 dtb 文件名不改变内核行为**。
3. **结论**：Layer 4 问题——overlay 里「有定制文件」≠「编译出不同的 dtb」。

### 根因

板级 dts 尚未加入 ALPHA 板与官方 EVK 的差异项（phy-reset-gpios、1024×600 屏参等），编译产物等价于官方 emmc dtb。

---

## 七、问题 4：U-Boot 网通、内核 eth0 不通（关联问题）

### 现象（内核启动日志）

```
libphy: fec_enet_mii_bus: probed
fec 20b4000.ethernet eth0: registered PHC device 0
fec 2188000.ethernet eth1: registered PHC device 1
...
IP-Config: Failed to open eth0
IP-Config: Device `eth0' not found
```

### 分析过程

| 对比项 | U-Boot | Linux 内核 |
|--------|--------|------------|
| FEC1 TFTP | ✅ 正常 | ❌ IP-Config 失败 |
| PHY 复位 | U-Boot 自有初始化 | 依赖 dtb `phy-reset-gpios` |

对照 IMX6 出厂分支 `imx6ull-14x14-evk.dts`，ALPHA 板需要而当前 `gengtao0901.dts` 缺少：

```dts
&fec1 {
    pinctrl-0 = <&pinctrl_enet1 &pinctrl_fec1_reset>;
    phy-reset-gpios = <&gpio5 7 GPIO_ACTIVE_LOW>;
    phy-reset-duration = <200>;
    ...
};

pinctrl_fec1_reset: fec1_resetgrp {
    fsl,pins = <
        MX6ULL_PAD_SNVS_TAMPER7__GPIO5_IO07  0x79
    >;
};
```

### 根因

硬件网口正常（U-Boot 已证明），内核侧 dtb 缺少 ATK 板 PHY 复位/引脚配置，导致 eth0 无法用于 NFS。此问题与 U-Boot dtb 加载无关，需在 overlay dts 中补齐（参见 01 文档问题 3）。

---

## 八、最终解决方案（U-Boot 部分）

### 做法：在 bootcmd 中写死定制 dtb 文件名

不依赖 `${fdt_file}`，避免被板级代码覆盖：

```bash
setenv bootcmd 'tftp 80800000 zImage; tftp 83000000 imx6ull-14x14-evk-emmc-gengtao0901-1024-600.dtb; bootz 80800000 - 83000000'
saveenv
reset
```

### 部署前确认（主机）

```bash
ls -l /home/gengtao/linux-imx6ull/tftpboot/imx6ull-14x14-evk-emmc-gengtao0901-1024-600.dtb

# 若不存在
linux-kernel-overlay/scripts/update_board.sh gengtao-bsp-0901 tftp
```

### 验证成功的标志（U-Boot 日志）

```
Filename 'imx6ull-14x14-evk-emmc-gengtao0901-1024-600.dtb'
Loading: ###
done
Bytes transferred = 36093 (8cfd hex)
## Flattened Device Tree blob at 83000000
   Booting using the fdt blob at 83000000
```

**不得**出现 `File not found`。

---

## 九、分析方法论（可复用）

1. **先看 U-Boot 实际 TFTP 的文件名**，不要只看 `printenv fdt_file`（变量可能未使用或被覆盖）。
2. **必查 `printenv bootcmd`**：是否硬编码 dtb 名、是否使用 `${变量}`。
3. **PC 端 md5 对比 dtb**：确认「文件名定制了」是否等于「内容定制了」。
4. **U-Boot 通、内核不通** → 优先怀疑 dtb 内容/驱动配置，而非硬件。
5. **TFTP File not found 但仍 boot** → 怀疑 0x83000000 内存残留；必须以 `Loading: ... done` 为准。

### 推荐排查命令清单

**板子 U-Boot：**

```bash
printenv fdt_file
printenv fdtfile
printenv bootcmd
```

**主机 PC：**

```bash
ls -l /home/gengtao/linux-imx6ull/tftpboot/*.dtb
md5sum /home/gengtao/linux-imx6ull/tftpboot/*.dtb
```

---

## 十、后续待办（dts / 内核侧）

| # | 任务 | 目的 | 状态 |
|---|------|------|------|
| 1 | bootcmd 写死定制 dtb 名 | U-Boot 加载正确文件 | ✅ 已完成 |
| 2 | overlay dts 补 FEC phy-reset-gpios + pinctrl | 内核 eth0 可用 | ⏳ 待做 |
| 3 | overlay dts 补 1024×600 lcdif 时序 | 屏幕显示正确 | ⏳ 待做 |
| 4 | 重新 build，md5 与官方 dtb 不同 | 确认定制生效 | ⏳ 待做 |
| 5 | defconfig 加 CONFIG_SMSC_PHY 等 | LAN8720A PHY 驱动 | ⏳ 参见 01 文档 |

### 验证 NFS 成功的标志（内核日志）

```
IP-Config: Complete
VFS: Mounted root (nfs filesystem)
...
login:
```

---

## 十一、修改点汇总

| # | 修改 | 位置 | 状态 |
|---|------|------|------|
| 1 | bootcmd 写死 `imx6ull-14x14-evk-emmc-gengtao0901-1024-600.dtb` | 板子 U-Boot env（MMC） | ✅ |
| 2 | TFTP 部署定制 dtb | `/home/gengtao/linux-imx6ull/tftpboot/` | ✅ |
| 3 | dts 补 ALPHA 板网口/屏参 | overlay/projects/gengtao-bsp-0901/arch/arm/boot/dts/ | ⏳ |
| 4 | 重新编译并确认 dtb md5 变化 | build_kernel.sh | ⏳ |

---

## 十二、一句话总结

**U-Boot 侧**：根因是 `bootcmd` 未加载预期 dtb（先硬编码官方名，后 `${fdt_file}` 被板级覆盖）；TFTP 失败时 U-Boot 仍用 `0x83000000` 旧 dtb 启动，行为不可控。**解决方式**是在 `bootcmd` 中写死定制 dtb 文件名，并确认 TFTP `done` 成功。

**内核侧**：即使 dtb 加载正确，当前编译产物与官方 EVK dtb 相同，且缺少 ALPHA 板 phy-reset 等配置，NFS/eth0 仍需通过 overlay dts 定制后重新编译解决。
