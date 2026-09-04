# 16 ICM-20608（六轴 G-sensor）打通：分析思路与落地顺序

> 文档编号：16  
> 日期：2026-09-03  
> 板卡：正点原子 ATK-MX6ULL（CORE V2.0 + ALPHA V2.4）  
> 器件：底板 **ICM-20608（U6）** — 3 轴加速度 + 3 轴陀螺仪（六轴）  
> 目标：ECSPI3 通信正常 → 读 **WHO_AM_I=0xAF** → 用户态可读加速度/陀螺仪（G-sensor 打通）  
> 日期：2026-09-03（L0～L3 落地/板上验证：2026-09-04）  
> 实施人：按本文改 overlay / 编译 / 板载验证  
> 关联：`04`（原理图）、`11`（AP3216C 同类方法论）、`14`/`15`（总线分层思路，本器件走 **SPI** 非 I2C）、`origin/IMX6`（出厂 dts 片段）

---

## 一、先定结论（避免走弯路）

1. **ICM-20608 在本板上走 SPI，不是 I2C。**  
   与 AP3216C（I2C1@0x1E）完全不同；不要按 I2C 子系统去配 `&i2c1`。
2. **正确路径：**

   ```text
   用户态读数（ioctl / sysfs / 自写 app）
        ↑
   /dev/icm20608 或 IIO sysfs（取决于驱动选型）
        ↑
   SPI 设备驱动（alientek,icm20608 或自研 / backport）
        ↑
   ECSPI3 总线 + 设备树 icm20608@0
        ↑
   硬件：U6 ICM-20608 ← ECSPI3_SCLK/MOSI/MISO；CS→GPIO1_IO20；INT→6D_INT→GPIO1_IO10
   ```

3. **进度（相对 `gengtao-bsp-0901`，2026-09-04）：**
   - **L0 / L1 / L2 已完成**：引脚冲突已解除；板上 **`spi2.0`**；WHO_AM_I=`0xAF` 已在驱动 probe 中确认；
   - **L3 已完成**：`CONFIG_ICM20608=y`；`dmesg` probe OK；`/dev/icm20608`；sysfs `whoami=0xaf`，`accel_z`≈1g raw；
   - **L4 进行中**：步骤 A 平放基线、D 温度已通过；**B 倾斜 / C 转动待对照**。
4. **推荐落地顺序：** 先解决引脚冲突 + 启用 ECSPI3（L0～L1）→ 总线枚举（L2）→ 引入驱动读 WHO_AM_I / 六轴（L3～L4）→ 可选中断 `6D_INT`（L5）。
5. **中断脚可第二阶段再接。** 首轮用轮询读 `ACCEL_*` / `GYRO_*` 寄存器即可证明 G-sensor 打通。

---

## 二、分析思路（为什么这样判断）

### 1. 从原理图抽出信号链

资料：

- `IMX6ULL_ALPHA_V2.4(底板原理图).pdf` → **6 AIXS SENSOR（U6 ICM-20608）**
- `IMX6ULL_CORE_V2.0(核心板原理图).pdf` → UART2 / GPIO 经座子引出

```text
ICM-20608 (U6)
  VDD / VDDIO ── VCC_3V3（L3 + C11/C12/C13 滤波）
  SCLK  (Pin2) ── ECSPI3_SCLK  ← SoC UART2_RX 复用
  SDI   (Pin3) ── ECSPI3_MOSI  ← SoC UART2_CTS 复用
  SDO   (Pin4) ── ECSPI3_MISO  ← SoC UART2_RTS 复用
  CS    (Pin5) ── ECSPI3_SS0   ← SoC UART2_TX 复用为 GPIO1_IO20（软件片选）
  INT   (Pin6) ── 6D_INT       ← SoC JTAG_MOD → GPIO1_IO10
  FSYNC (Pin8) ── GND（未用）
  GND / RESV ── GND
```

| 项 | 原理图事实 | 写进软件时 |
|----|------------|------------|
| 总线 | **ECSPI3**（SoC `ecspi@02010000`，aliases **`spi2 = &ecspi3`**） | `&ecspi3` 子节点 |
| 片选 | 硬件接 **SS0**，正点原子 dts 用 **GPIO 软件 CS** | `cs-gpios = <&gpio1 20 GPIO_ACTIVE_LOW>` |
| SPI 模式 | ICM-20608 规格：**Mode 3**（CPOL=1, CPHA=1） | `spi-cpol; spi-cpha;` |
| 最高时钟 | 手册允许较高；正点原子用 **8 MHz** | `spi-max-frequency = <8000000>;` |
| 中断 | `6D_INT` → **GPIO1_IO10** | `interrupts = <10 IRQ_TYPE_LEVEL_LOW>;`（二期） |
| 供电 | `VCC_3V3`，无独立使能脚 | 一般不写 regulator |

核心板 / SoC 脚位（写 pinctrl 时用）：

| 板级信号 | SoC pad / GPIO | ECSPI3 功能 |
|----------|----------------|-------------|
| ECSPI3_SCLK | `UART2_RX_DATA` → ECSPI3_SCLK | `MX6UL_PAD_UART2_RX_DATA__ECSPI3_SCLK` |
| ECSPI3_MOSI | `UART2_CTS_B` → ECSPI3_MOSI | `MX6UL_PAD_UART2_CTS_B__ECSPI3_MOSI` |
| ECSPI3_MISO | `UART2_RTS_B` → ECSPI3_MISO | `MX6UL_PAD_UART2_RTS_B__ECSPI3_MISO` |
| CS（软件） | `UART2_TX_DATA` → **GPIO1_IO20** | `MX6UL_PAD_UART2_TX_DATA__GPIO1_IO20` |
| 6D_INT | `JTAG_MOD` → **GPIO1_IO10** | `MX6UL_PAD_JTAG_MOD__GPIO1_IO10` |

### 2. 从现有 dts 看出冲突点

当前 `imx6ull-14x14-evk-gengtao0901.dts`（相对 EVK；**L0 已处理冲突**）：

| 节点 | 占用脚 | 与 ECSPI3 关系 | 本工程（2026-09-04） |
|------|--------|----------------|----------------------|
| `&uart2` | UART2_TX/RX（及 RTS/CTS 走 UART3 复用） | **TX/RX 与 ECSPI3 SCLK/CS 冲突** | 已 **`disabled`** |
| `&flexcan2` | UART2_RTS/CTS → FLEXCAN2_RX/TX | **与 ECSPI3 MISO/MOSI 冲突** | 已 **`disabled`** |
| `&ecspi3` | ECSPI3 + `icm20608@0` | 六轴设备树 | **L1 已通**（板上 `spi2.0`） |

正点原子出厂 `imx6ull-alientek-emmc.dts`（`origin/IMX6`）的处理方式：

```dts
&flexcan2 { status = "disabled"; };   /* 释放 UART2_RTS/CTS */
&uart2    { status = "disabled"; };   /* 释放 UART2_TX/RX；调试串口改 UART1 */
&ecspi3   { status = "okay"; ... icm20608@0 { ... }; };
```

**结论：** 要打通六轴，必须像出厂 dts 一样 **关掉 flexcan2**，并 **禁用或改脚 uart2**；否则 pinctrl 无法同时满足 CAN/UART 与 ECSPI3。

### 3. 驱动选型（本树 4.1.15 事实）

| 方案 | 说明 | 推荐阶段 |
|------|------|----------|
| **A. `spidev` + 用户态读寄存器** | 改 `compatible = "spidev"` 或 `CONFIG_SPI_SPIDEV`，用 `spidev_test`/自写程序读 `0x75` | **L2 硬件门禁** |
| **B. 正点原子 `alientek,icm20608` 驱动** | dts 已写此 compatible；驱动在 **课程/SDK 包** 中，**不在** `origin/IMX6` 内核树 | **L3～L4 正式打通** |
| **C. 自研 SPI 字符设备 / IIO 驱动** | 参考课程 `icm20608.c` + 寄存器手册 | 无 SDK 时 |
| **D. 主线 `inv_mpu6050` + `invensense,icm20608`** | 新内核才有 SPI + ICM20608；4.1.15 版仅 **I2C MPU6050** | backport 成本高，非首选 |

出厂 dts 片段（`origin/IMX6`）：

```bash
git -C ~/linux-imx6ull/linux-imx6ull-kernel-code \
  show origin/IMX6:arch/arm/boot/dts/imx6ull-alientek-emmc.dts | \
  sed -n '/&ecspi3/,/^};/p'
```

要点：

```dts
&ecspi3 {
    fsl,spi-num-chipselects = <1>;
    cs-gpios = <&gpio1 20 GPIO_ACTIVE_LOW>;  /* 注意是 cs-gpios 复数 */
    pinctrl-names = "default";
    pinctrl-0 = <&pinctrl_ecspi3>;
    status = "okay";

    icm20608@0 {
        compatible = "alientek,icm20608";
        reg = <0>;
        spi-max-frequency = <8000000>;
    };
};
```

`pinctrl_ecspi3`（同文件 `&iomuxc` 内）：

```dts
pinctrl_ecspi3: ecspi3grp {
    fsl,pins = <
        MX6UL_PAD_UART2_RTS_B__ECSPI3_MISO   0x100b1
        MX6UL_PAD_UART2_CTS_B__ECSPI3_MOSI   0x100b1
        MX6UL_PAD_UART2_RX_DATA__ECSPI3_SCLK 0x100b1
        MX6UL_PAD_UART2_TX_DATA__GPIO1_IO20  0x100b0  /* CS */
    >;
};
```

### 4. SPI 寄存器协议（调不通时对照）

| 寄存器 | 偏移 | 用途 |
|--------|------|------|
| **WHO_AM_I** | `0x75` | 上电后读，期望 **`0xAF`**（ICM-20608） |
| PWR_MGMT_1 | `0x6B` | `0x80` 复位；`0x01` 选时钟源唤醒 |
| PWR_MGMT_2 | `0x6C` | `0x00` 打开加速度计+陀螺仪各轴 |
| GYRO_CONFIG | `0x1B` | 陀螺仪量程 |
| ACCEL_CONFIG | `0x1C` | 加速度计量程 |
| ACCEL_XOUT_H … GYRO_ZOUT_L | `0x3B`～`0x48` | 连续 **14 字节**（ax,ay,az,temp,gx,gy,gz） |

**SPI 读写规则（全双工）：**

- 写寄存器：地址字节 **bit7 = 0**
- 读寄存器：地址字节 **bit7 = 1**（即 `addr | 0x80`）
- 读 N 字节：主机发 **N+1** 字节；第 1 字节为带读标志的地址，第 2 字节起为有效数据

**最小初始化序列（与正点原子/裸机一致）：**

```text
写 0x6B ← 0x80    // 复位，延时 ~100ms
写 0x6B ← 0x01    // 时钟源
读 0x75           // 应为 0xAF
写 0x6C ← 0x00    // 使能 accel+gyro
写 0x1B / 0x1C    // 量程（按需求）
读 0x3B 起 14 字节 // 六轴 + 温度
```

---

## 三、落地顺序（建议严格按层做）

> 原则与文档 **`11`（AP3216C）** 相同：**先总线探测 → 再绑驱动 → 再用户态读数**；中断最后加。  
> **每层做完必须过本层「完成后验证」再进入下一层。**

### 分层验证总览（速查）

| 层 | 做完后至少确认 | 不通过时先查 |
|----|----------------|--------------|
| **L0** | SPI 核心 + `spi_imx` 已编进内核；引脚冲突已处理 | defconfig、`flexcan2`/`uart2`、pinctrl |
| **L1** | dtb 反编译可见 `&ecspi3` + `icm20608@0` | 改错 dts、未重编 dtb、U-Boot 旧 dtb |
| **L2** | SPI 控制器 probe；WHO_AM_I **0xAF** | `cs-gpios`、SPI 模式、接线、供电 |
| **L3** | 驱动 `probe` 成功；模块/内置符号存在 | compatible、Kconfig、overlay 未 apply |
| **L4** | 加速度随倾斜变化、陀螺仪随转动变化 | 初始化序列、字节序、量程换算 |
| **L5** | （可选）`6D_INT` 在 `/proc/interrupts` 计数增加 | GPIO1_IO10 pinctrl、驱动 `request_irq` |

---

### L0 — 引脚冲突 + SPI 控制器基础

> **本工程现状（`gengtao-bsp-0901`，2026-09-04）：L0 已完成。**  
> - L0.1：`&flexcan2`、`&uart2` 已改为 `status = "disabled"`；  
> - L0.2：`CONFIG_SPI=y`、`CONFIG_SPI_IMX=y` 已确认（无需再改 defconfig）。  
> 下一步直接做 **L1**（启用 `&ecspi3` + `icm20608@0`）。

#### L0.1 处理引脚冲突（必做）

在 `imx6ull-14x14-evk-gengtao0901.dts` 中至少：

```dts
&flexcan2 {
    status = "disabled";   /* 释放 UART2_RTS/CTS → ECSPI3 MISO/MOSI */
};

&uart2 {
    status = "disabled";   /* 释放 UART2_TX/RX；调试请继续用 UART1 */
};
```

若板载必须用 CAN2 或 UART2，只能 **二选一**：六轴与 CAN2/UART2 不能同时占用同一组 UART2 脚。

**已落地：** 上述两处已在板级 dts 中改为 `disabled`（注释标明给 ICM-20608 用）。

#### L0.2 确认内核 SPI 已打开

> **本工程现状（`gengtao-bsp-0901`）**：`imx_v7_defconfig` 中下列两项已 `=y`。L0 **无需再为「打开 SPI」单独改一版**，确认即可。下一步直接做 **L1**（或 L2 临时验证时再开 `CONFIG_SPI_SPIDEV`）。

##### 内核两项配置各开什么、有何作用

| 配置 | 打开后内核里有什么 | 对 ICM-20608 打通的作用 |
|------|-------------------|-------------------------|
| **`CONFIG_SPI=y`** | SPI 核心：`spi_master` / `spi_device` / `spi_driver`、匹配、`spi_sync` / `spi_transfer` 等 | 没有它，后面所有 SPI 设备驱动（含 ICM-20608、`spidev`）都编不进来、也跑不起来 |
| **`CONFIG_SPI_IMX=y`** | i.MX ECSPI 控制器驱动（`spi-imx`），按 dts `ecspi@02010000` 等节点创建 **SPI 总线** | 把 SoC 的 **ECSPI3** 变成 Linux 上的一条 SPI 总线；`&ecspi3 { status=okay }` 才会真正 probe，并出现 `spiX.0` 这类设备 |

串起来看：

```text
CONFIG_SPI      →  框架（怎么传消息、怎么匹配驱动）
CONFIG_SPI_IMX  →  硬件控制器 ECSPI3 → /sys/bus/spi/devices/spiX.Y

再叠上：
  dts &ecspi3 + icm20608@0
  ICM20608 / spidev 驱动  →  读 WHO_AM_I / 六轴数据
```

对照文档 **11**（AP3216C）：`CONFIG_SPI` ≈ `CONFIG_I2C`，`CONFIG_SPI_IMX` ≈ `CONFIG_I2C_IMX`。

**L2 临时验证** 还需（二选一）：

| 配置 | 作用 |
|------|------|
| `CONFIG_SPI_SPIDEV=m/y` | 通用 `spidev`，用户态直接 ioctl 读寄存器（≈ I2C 侧的 `CONFIG_I2C_CHARDEV`） |
| 自研 / 正点原子 `icm20608` 驱动 | 正式路径，见 L3 |

#### L0 完成后验证

```bash
# 内核配置（开发机 defconfig / 板上 .config）
grep -E 'CONFIG_SPI=|CONFIG_SPI_IMX=' \
  projects/gengtao-bsp-0901/arch/arm/configs/imx_v7_defconfig
# 期望：CONFIG_SPI=y、CONFIG_SPI_IMX=y

# dts 冲突节点（开发机；需 -E 才能用 |）
grep -AE6 '(&flexcan2|&uart2)' \
  projects/gengtao-bsp-0901/arch/arm/boot/dts/imx6ull-14x14-evk-gengtao0901.dts
# 期望：两处 status = "disabled"

# 板上（L0 阶段）
ls /sys/bus/spi/devices/
ls /sys/bus/platform/drivers/spi_imx* 2>/dev/null
```

##### 本工程实测结果（2026-09-04）及说明

| 检查项 | 实测 | 是否符合 L0 预期 | 说明 |
|--------|------|------------------|------|
| defconfig | `CONFIG_SPI=y`、`CONFIG_SPI_IMX=y` | **是** | SPI 框架 + i.MX 控制器驱动已编进内核 |
| `&flexcan2` / `&uart2` | 均为 `status = "disabled"` | **是** | UART2 相关脚已让给后续 ECSPI3 |
| `/sys/bus/platform/drivers/spi_imx*` | 有 `bind` / `uevent` / `unbind` | **是** | 说明 `spi_imx` 驱动已加载；**不等于** 已有 SPI 设备 |
| `/sys/bus/spi/devices/` | **空** | **是（正常）** | L0 **尚未**启用 `&ecspi3`，不会出现 `spiX.0`；要到 **L1** 写好节点并部署 **dtb** 后才有 |

要点：

- L0 只验证「引脚冲突已解除 + SPI 框架/控制器驱动就绪」。
- **`devices/` 为空不代表失败**，只说明控制器节点还没在设备树里打开。
- 部署含 L0 改动的 dtb 后，板上再确认 `flexcan2`/`uart2` 不会误 probe 即可；SPI 设备列表留给 L1。

| 检查项 | 通过标准 | 本工程（2026-09-04） |
|--------|----------|----------------------|
| defconfig | `CONFIG_SPI`、`CONFIG_SPI_IMX` 为 `y` | **通过** |
| 引脚策略 | flexcan2/uart2 已 disabled | **通过** |
| spi_imx 驱动 | `/sys/bus/platform/drivers/spi_imx*` 存在 | **通过** |
| spi devices 空 | L0 阶段允许为空 | **符合预期** |

**L0 完整结论：通过。** 可进入 **L1**。

---

### L1 — 设备树：启用 ECSPI3 + ICM-20608 节点

> **本工程现状（`gengtao-bsp-0901`，2026-09-04）：L1 已完成（含板上）。**  
> - 已增加 `pinctrl_ecspi3`、`pinctrl_icm20608`（中断脚预留）；  
> - 已启用 `&ecspi3` + `icm20608@0`（`cs-gpios`、Mode3、8MHz）；  
> - 板上已出现 **`spi2.0`**（详见 L2 实测）；下一步做 WHO_AM_I。

在 `&iomuxc` → `imx6ul-evk` 内增加 `pinctrl_ecspi3`（及可选 `pinctrl_icm20608` 中断脚）。

在板级 dts 增加（本工程已写在 `&flexcan2` 之后）：

```dts
&ecspi3 {
    fsl,spi-num-chipselects = <1>;
    cs-gpios = <&gpio1 20 GPIO_ACTIVE_LOW>;
    pinctrl-names = "default";
    pinctrl-0 = <&pinctrl_ecspi3>;
    status = "okay";

    icm20608@0 {
        compatible = "alientek,icm20608";   /* L2 用 spidev 时可改为 "linux,spidev" */
        reg = <0>;
        spi-cpol;
        spi-cpha;
        spi-max-frequency = <8000000>;

        /* 二期中断（L5） */
        /* pinctrl-names = "default"; */
        /* pinctrl-0 = <&pinctrl_icm20608>; */
        /* interrupt-parent = <&gpio1>; */
        /* interrupts = <10 IRQ_TYPE_LEVEL_LOW>; */
    };
};
```

`pinctrl_ecspi3` / `pinctrl_icm20608`（本工程已写入 `&iomuxc`）：

```dts
pinctrl_ecspi3: ecspi3grp {
    fsl,pins = <
        MX6UL_PAD_UART2_RTS_B__ECSPI3_MISO   0x100b1
        MX6UL_PAD_UART2_CTS_B__ECSPI3_MOSI   0x100b1
        MX6UL_PAD_UART2_RX_DATA__ECSPI3_SCLK 0x100b1
        MX6UL_PAD_UART2_TX_DATA__GPIO1_IO20  0x100b0  /* CS */
    >;
};

pinctrl_icm20608: icm20608grp {
    fsl,pins = <
        MX6UL_PAD_JTAG_MOD__GPIO1_IO10  0xb0b0  /* L5 再用 */
    >;
};
```

#### L1 完成后验证

```bash
# 开发机：进入构建产物目录（本工程 overlay 习惯路径）
cd ~/linux-imx6ull/linux-imx6ull-kernel-code/linux-kernel-overlay/linux-imx6ull-kernel-build-output
ls *.dtb
# 本工程实际产物名示例：
#   imx6ull-14x14-evk-emmc-gengtao0901-1024-600.dtb
# 注意：dtc 不会展开通配符到多个文件；请写具体文件名，或先 ls 再代入

dtc -I dtb -O dts -o ./imx6ull-14x14-evk-emmc-gengtao0901-1024-600.decompiled.dts \
  imx6ull-14x14-evk-emmc-gengtao0901-1024-600.dtb
grep -A30 'ecspi@02010000' ./imx6ull-14x14-evk-emmc-gengtao0901-1024-600.decompiled.dts
# 期望：status = "okay"；子节点 icm20608@0；cs-gpios；spi-cpol

# 板上：设备树是否进树（部署新 dtb 并重启后）
find /proc/device-tree -name '*ecspi*' -o -name '*icm20608*'
ls /proc/device-tree/soc/aips-bus@02000000/spba-bus@02000000/ecspi@02010000/
# 期望有 status、以及子节点 icm20608@0

# 板上：SPI 设备应不再为空（对比 L0）
ls /sys/bus/spi/devices/
# 期望形如 spi0.0 或 spi2.0；of_node 路径含 ecspi@02010000
dmesg | grep -iE 'ecspi|spi_imx|icm20608'
```

##### 开发机反编译说明（本工程实测）

| 错误写法 | 原因 |
|----------|------|
| `dtc ... arch/arm/boot/dts/imx6ull-*.dtb` | 构建产物在 **`linux-imx6ull-kernel-build-output/`** 根下，不在 `arch/arm/boot/dts/`；且 `dtc` **不展开 shell 通配符**（需自己写全名或由 shell 展开到**单个**文件） |

正确示例：

```bash
cd linux-imx6ull-kernel-build-output
dtc -I dtb -O dts -o ./imx6ull-14x14-evk-emmc-gengtao0901-1024-600.decompiled.dts \
  imx6ull-14x14-evk-emmc-gengtao0901-1024-600.dtb
```

##### `dtc` 这条命令怎么用

| 参数 | 含义 |
|------|------|
| `-I dtb` | **输入格式**是二进制设备树（Device Tree Blob） |
| `-O dts` | **输出格式**是可读的设备树源码文本 |
| `-o ./xxx.decompiled.dts` | 输出文件写到**当前目录**（相对路径 `./`） |
| 最后一个参数 | 要反编译的 **`.dtb` 文件名**（须写具体名字，不要依赖未展开的通配符） |

整句含义：**把刚编出来的 `.dtb` 还原成可读 `.dts`，落在当前目录，方便 `grep` / 人工对照。**

说明：大量 `Warning` 来自 dtc 对 NXP 老风格节点名/地址格式的检查，**可忽略**，只要无 `FATAL ERROR` 且 `.decompiled.dts` 已生成即可。

##### 为什么要反编译再分析（好处）

1. **验的是最终产物，不是源文件。** 改的是 `*.dts`，板上跑的是 `*.dtb`；中间可能 include/覆盖/编译脚本选错文件。反编译能确认「这次构建打进包里的」是否真有 `&ecspi3` / `icm20608@0`。
2. **比只看源码更接近内核实际看到的树。** 反编译结果是展开、合并后的完整树（含 `imx6ull.dtsi` 等），能直接看到 `ecspi@02010000` 的最终 `status`、`cs-gpios`、子节点。
3. **部署前就能拦住问题。** 不必先烧板再猜「是不是没更新 dtb」；开发机上 `grep ecspi@02010000` 不过，就不要上板。
4. **排障时有对照基线。** 板上 `/proc/device-tree` 与开发机反编译结果应对齐；不一致时优先查 U-Boot 是否加载了旧 dtb。

本工程 2026-09-04 反编译已确认：`ecspi@02010000` 为 `okay`，含 `icm20608@0` / `cs-gpios` / `spi-cpol`。

| 检查项 | 通过标准 | 本工程（2026-09-04） |
|--------|----------|----------------------|
| dts 源码 | `&ecspi3` okay + `icm20608@0` + `pinctrl_ecspi3` | **已写入** |
| 构建产物 dtb | 反编译可见 `ecspi@02010000` + `icm20608@0` | **开发机已确认** |
| 冲突 | `flexcan2`、`uart2` 已 disabled | **已满足（L0）** |
| 板上 `/proc/device-tree` / of_node | `ecspi@02010000` + `icm20608@0` | **通过**（见 L2 实测 `spi2.0`） |
| `/sys/bus/spi/devices/` | 出现 `spiX.0` | **通过：`spi2.0`** |

**L1 完整结论：通过（开发机 dtb + 板上 `spi2.0`）。** 进入 **L2**（剩余：WHO_AM_I）。  
说明：此时 `compatible = "alientek,icm20608"`，尚无驱动时 `spi2.0` 存在但 **driver 可能为空**；属正常，L2/L3 再处理。

---

### L2 — 板上验证：SPI 通信 + WHO_AM_I

> L2 是 **硬件 + ECSPI3 + 片选 + SPI 模式** 的门禁；**尚未需要** 正式 `alientek` 驱动。

#### SPI 总线号如何确定

| 层级 | 本板事实 |
|------|----------|
| **硬件** | ICM-20608 挂在 **ECSPI3** |
| **设备树 aliases** | `spi2 = &ecspi3`（`imx6ull.dtsi`） |
| **内核** | 启用几个 ECSPI，就有几个 `spiX`；**仅启用 ecspi3 时常见为 `spi0` 或 `spi2`**，以板上为准 |

```bash
ls /sys/bus/spi/devices/
# 期望形如 spi0.0 或 spi2.0（0 为 reg 片选号）

# 看控制器 of_node
for d in /sys/bus/spi/devices/spi*; do
  echo -n "$d -> "
  readlink "$d/of_node" 2>/dev/null
done
# 路径含 ecspi@02010000 即为 ECSPI3

dmesg | grep -iE 'ecspi|spi_imx|icm20608'
ls -l /sys/bus/spi/devices/
```

##### 本工程板上实测（2026-09-04）

```text
[root@gengtao ]# ls /sys/bus/spi/devices/
spi2.0

[root@gengtao ]# for d in /sys/bus/spi/devices/spi*; do
>   echo -n "$d -> "
>   readlink "$d/of_node" 2>/dev/null
> done
/sys/bus/spi/devices/spi2.0 -> .../ecspi@02010000/icm20608@0

[root@gengtao ]# dmesg | grep -iE 'ecspi|spi_imx|icm20608'
spi_imx 2010000.ecspi: probed

[root@gengtao ]# ls -l /sys/bus/spi/devices/
spi2.0 -> .../2010000.ecspi/spi_master/spi2/spi2.0
```

| 日志/现象 | 含义 | 判断 |
|-----------|------|------|
| `spi2.0` | Linux SPI 设备名：总线 **2**、片选 **0**（对应 `reg = <0>`） | 与 aliases `spi2 = &ecspi3` 一致 |
| `of_node` → `ecspi@02010000/icm20608@0` | 该设备来自设备树 **ECSPI3 下的 ICM-20608 节点** | L1 dtb 已真正加载 |
| `spi_imx 2010000.ecspi: probed` | ECSPI3 控制器驱动 probe 成功（`0x02010000`） | 控制器层 OK |
| 尚无 `icm20608` 驱动绑定日志 | `compatible = "alientek,icm20608"` 但内核无对应驱动 | **正常**；下一步用 `spidev` 或引正式驱动读 WHO_AM_I |

##### 为什么这样排查（原因）

L2 不要一上来就怀疑「芯片坏了 / 寄存器错了」，先把 **软件枚举链** 钉死：

```text
dts 写对 → dtb 部署生效 → spi_imx probe → 出现 spiX.Y → of_node 指向正确节点
        → 再谈 SPI 时序 / WHO_AM_I / 正式驱动
```

| 排查步骤 | 回答的问题 | 不通过时该查什么 |
|----------|------------|------------------|
| `ls .../spi/devices/` | 内核有没有认出 SPI 从设备？ | dtb 未更新、`&ecspi3` 未 okay、pinctrl/冲突 |
| `readlink .../of_node` | 这个 `spi2.0` **是不是** 我们的 `icm20608@0`？ | 绑到别的控制器/别的子节点，别对错总线做传输 |
| `dmesg` 看 `spi_imx ... probed` | ECSPI3 控制器是否起来？ | `CONFIG_SPI_IMX`、时钟、控制器节点 status |
| `ls -l` 看 symlink 路径 | 确认落在 `2010000.ecspi` / `spi_master/spi2` | 与 SoC 地址、aliases 交叉核对 |

对比 L0：当时 `devices/` **为空**（未开 ecspi3）；现在有 `spi2.0`，说明 **L1 板上侧已通**，L2 剩余门禁是 **实际 SPI 读写 WHO_AM_I=0xAF**。

#### 用 spidev 读 WHO_AM_I（示例思路）

设备树临时改为 `compatible = "linux,spidev";`，内核打开 `CONFIG_SPI_SPIDEV`，部署后出现 `/dev/spidevX.Y`（本板预期 **`/dev/spidev2.0`**）。

读 `0x75` 的典型事务（Mode 3，8 MHz）：

```c
/* 读 1 字节：tx = { 0x75|0x80, 0x00 }，rx 第 2 字节为 WHO_AM_I */
uint8_t tx[] = { 0xF5, 0x00 };
uint8_t rx[2];
spi_ioctl(SPI_IOC_MESSAGE(1), ...);
/* rx[1] 应为 0xAF */
```

也可用内核文档 `Documentation/spi/spidev_test.c` 交叉编译测试。

#### L2 完成后验证

```bash
# —— 总线枚举（本工程已过）——
ls /sys/bus/spi/devices/          # 期望 spi2.0
# of_node / dmesg 见上文实测

# —— 寄存器通信（待做）——
# WHO_AM_I：用户态 / spidev 读 0x75，期望 0xAF
```

| 检查项 | 通过标准 | 本工程（2026-09-04） |
|--------|----------|----------------------|
| 控制器 | `dmesg` 有 `spi_imx 2010000.ecspi: probed`，无失败 | **通过** |
| SPI 设备 | 存在 **`spi2.0`**，`of_node` 指向 `icm20608@0` | **通过** |
| 片选 | 传输时 CS（GPIO1_20）拉低（示波器/逻辑分析可选） | 待 WHO_AM_I 时一并确认 |
| WHO_AM_I | 读 `0x75` 得 **`0xAF`** | **通过**（随 L3 probe，见下） |

**L2 总线枚举：通过。** WHO_AM_I 已由 L3 驱动 probe 一并确认。

---

### L3 — 引入 ICM-20608 驱动

> **本工程现状（`gengtao-bsp-0901`，2026-09-04）：L3 已完成（含板上）。**  
> 按 AP3216C 同类路径自研 SPI + misc 驱动；部署新 zImage 后 probe / `/dev/icm20608` / sysfs 均通过。

#### 已落地文件（overlay `common/` + 已 sync 进内核树）

| 路径 | 作用 |
|------|------|
| `drivers/char/icm20608.c` | SPI 驱动：`probe` 里复位/读 WHO_AM_I、注册 `/dev/icm20608` + sysfs |
| `include/linux/icm20608.h` | ioctl：`ICM20608_GET_DATA` / `ICM20608_GET_WHOAMI` |
| `drivers/char/Kconfig` | `config ICM20608`（`depends on SPI`） |
| `drivers/char/Makefile` | `obj-$(CONFIG_ICM20608) += icm20608.o` |
| `imx_v7_defconfig` | `CONFIG_ICM20608=y` |
| dts（L1 已写） | `compatible = "alientek,icm20608"` |

驱动要点：

- `of_match`：`alientek,icm20608`（与 dts 一致）
- SPI 读：地址 `| 0x80`；写：地址 `& 0x7F`
- `probe`：复位 → 读 **WHO_AM_I 期望 `0xAF`** → 开 accel/gyro → `misc_register`
- 用户接口：`/dev/icm20608`；sysfs：`accel_*` / `gyro_*` / `temp` / `whoami`

##### 这段 Kconfig 怎么理解（对照 AP3216C）

Kconfig **不是驱动代码本身**，而是内核的「开关菜单」：声明有一个叫 `ICM20608` 的选项，用户/`defconfig` 打开后，才会去编译对应的 `.c`。

| 写法 | 含义 |
|------|------|
| `config ICM20608` | 定义配置符号 → 宏 **`CONFIG_ICM20608`** |
| `tristate "..."` | `y` 编进内核 / `m` 模块 / `n` 不编 |
| `depends on SPI` | 依赖 `CONFIG_SPI` |

三件套必须对齐：`Kconfig` 声明 → `Makefile` 的 `obj-$(CONFIG_ICM20608)` → `defconfig` 的 `=y`。本工程已全部落地。

注意：在 overlay 目录 `grep CONFIG_ICM20608` **搜不到** Kconfig 行——源文件写的是 `config ICM20608`（无 `CONFIG_` 前缀）；`CONFIG_` 是 make 生成 `.config` / 编译宏时自动加的。

#### L3 完成后验证

```bash
# —— 开发机（内核树根目录，编译后）——
grep CONFIG_ICM20608 .config
# 或从 overlay 目录：grep CONFIG_ICM20608 ../.config
# 期望：CONFIG_ICM20608=y

# —— 板上（部署新 zImage 后；根文件系统通常没有 .config）——
dmesg | grep -i icm20608
ls -l /dev/icm20608
ls -l /sys/bus/spi/devices/spi2.0/driver
cat /sys/class/misc/icm20608/whoami
cat /sys/class/misc/icm20608/accel_z
```

##### 本工程板上实测（2026-09-04）

**开发机：**

```text
$ grep CONFIG_ICM20608 ../.config
CONFIG_ICM20608=y
```

**板上：**

```text
[root@gengtao ]# grep CONFIG_ICM20608 .config
grep: .config: No such file or directory
# 说明：板子跑的是已编译的 zImage，rootfs 里一般没有内核 .config；
#       配置是否编进内核，以开发机 .config + dmesg/设备节点为准，不必在板上找 .config。

[root@gengtao ]# dmesg | grep -i icm20608
icm20608 spi2.0: WHO_AM_I=0xaf OK
icm20608 spi2.0: icm20608 probe OK, /dev/icm20608

[root@gengtao ]# ls -l /dev/icm20608
crw-rw----    1 root     0          10,  62 ... /dev/icm20608

[root@gengtao ]# ls -l /sys/bus/spi/devices/spi2.0/driver
.../spi2.0/driver -> .../bus/spi/drivers/icm20608

[root@gengtao ]# cat /sys/class/misc/icm20608/whoami
0xaf

[root@gengtao ]# cat /sys/class/misc/icm20608/accel_z
16554
# 多次读取约 14867～16617，平放时接近 +1g（±2g 量程下 raw≈16384）
```

| 日志/现象 | 含义 | 判断 |
|-----------|------|------|
| 开发机 `CONFIG_ICM20608=y` | 驱动已编进本次内核 | 通过 |
| 板上无 `.config` | rootfs 不带 Kconfig 产物，属正常 | 忽略 |
| `WHO_AM_I=0xaf OK` | SPI 读写通，芯片 ID 正确（同时结案 L2 WHO_AM_I） | **通过** |
| `probe OK, /dev/icm20608` | misc 注册成功 | **通过** |
| `driver → icm20608` | `spi2.0` 已绑定本驱动（非空悬） | **通过** |
| `whoami` → `0xaf` | 用户态 sysfs 可读寄存器 | **通过** |
| `accel_z` ≈ 1.5e4 | 平放 Z 轴约 1g raw，数值有轻微抖动属正常 | **通过**（L4 再做倾斜对照） |

| 检查项 | 通过标准 | 本工程（2026-09-04） |
|--------|----------|----------------------|
| 源码三件套 | `icm20608.c` + Kconfig/Makefile + `CONFIG_ICM20608=y` | **通过** |
| dts compatible | `alientek,icm20608` | **通过** |
| 板上 probe | `dmesg` 有 WHO_AM_I=`0xAF` 与 probe OK | **通过** |
| `/dev/icm20608` + 绑定 | 设备存在，`spi2.0/driver`→`icm20608` | **通过** |
| sysfs | `whoami=0xaf`；`accel_z` 约 1g raw | **通过** |

**L3 完整结论：通过。** 可进入 **L4**（倾斜/转动验收）。  
说明：L3 probe 成功已同时完成 L2 的 WHO_AM_I 门禁。

### L4 — 用户态读 G-sensor（加速度 + 陀螺仪）

> **设计原则：** L3 已证明「能通信、能 probe、能读数」；L4 只做 **物理对照**——不改内核，只用现有 sysfs，用手改变板姿，看 raw 是否按预期变。  
> **不必**先写 `icm20608_app`；sysfs 足够验收。ioctl 留给后续应用开发。

#### 接口怎么用（本工程）

| 接口 | 路径 / 命令 | L4 是否必需 |
|------|-------------|-------------|
| **sysfs（推荐）** | `/sys/class/misc/icm20608/` | **是** — 手工验收用这个 |
| ioctl | `/dev/icm20608` + `ICM20608_GET_DATA` | 否 — 应用联调再用 |

```bash
cd /sys/class/misc/icm20608
ls
# 期望：accel_x accel_y accel_z gyro_x gyro_y gyro_z temp whoami ...

# 一次读齐（便于对照）
for f in accel_x accel_y accel_z gyro_x gyro_y gyro_z temp whoami; do
  printf '%-8s %s\n' "$f" "$(cat $f)"
done
```

量程与 raw 换算（驱动初始化：accel **±2g**，gyro **±2000°/s**）：

| 量 | 满量程 | 灵敏度（约） | 物理含义 |
|----|--------|--------------|----------|
| 加速度 | ±2g | 16384 LSB/g | 平放 Z≈**+16384**（+1g）；侧放则 X 或 Y≈±16384 |
| 陀螺仪 | ±2000°/s | 16.4 LSB/(°/s) | 静止时接近 0（有零漂正常）；转动时对应轴明显变大 |
| 温度 | — | 见手册换算 | 仅作有数即可，不卡死验收 |

#### 验收步骤（建议按序做）

**步骤 A — 静止平放（基线）**

1. 板子屏幕朝上、尽量水平静止 2～3 秒。  
2. 连续读几次：

```bash
for i in 1 2 3 4 5; do
  echo "--- $i ---"
  echo "ax=$(cat /sys/class/misc/icm20608/accel_x) ay=$(cat /sys/class/misc/icm20608/accel_y) az=$(cat /sys/class/misc/icm20608/accel_z)"
  echo "gx=$(cat /sys/class/misc/icm20608/gyro_x) gy=$(cat /sys/class/misc/icm20608/gyro_y) gz=$(cat /sys/class/misc/icm20608/gyro_z)"
  sleep 0.3
done
```

| 期望 | 说明 |
|------|------|
| `|az|` 明显大于 `|ax|`、`|ay|` | 重力主要在 Z |
| `az` 大约在 **+12000～+20000** | 约 +1g；L3 实测约 1.5e4，合格 |
| `gx/gy/gz` 绝对值不大 | 静止零漂可接受（不必为 0） |

##### 本工程步骤 A 实测（2026-09-04，平放静止）

一次读齐：

```text
accel_x  -208
accel_y  50
accel_z  16618
gyro_x   -23
gyro_y   -3
gyro_z   -7
temp     5472
whoami   0xaf
```

连续 5 次：

```text
--- 1 ---  ax=-209  ay=-5   az=16577  gx=-25 gy=-3 gz=-8
--- 2 ---  ax=-239  ay=2    az=16573  gx=-24 gy=-3 gz=-7
--- 3 ---  ax=-197  ay=-10  az=16595  gx=-23 gy=-3 gz=-7
--- 4 ---  ax=-236  ay=8    az=16605  gx=-24 gy=-3 gz=-7
--- 5 ---  ax=-193  ay=-10  az=16575  gx=-23 gy=-3 gz=-7
```

| 现象 | 判断 |
|------|------|
| `az`≈**16570～16620**（≈+1.01g） | 重力在 Z，符合平放 |
| `|ax|`、`|ay|` 仅百级，远小于 `az` | 水平分量小，基线干净 |
| `gyro_*` 约 -25～0 | 静止零漂，可接受 |
| `whoami=0xaf` | 通信仍正常 |

**步骤 A：通过。**

> BusyBox 提示：`for ...; do ...; done` 只输入一次 `done`。若循环已结束再多敲一行 `done`，会报 `syntax error: unexpected "done"`，与传感器无关。

**步骤 B — 倾斜（验加速度计）**

1. 缓慢把板子 **绕 Y 轴倾斜**（一侧抬高），再读 `accel_x/y/z`。  
2. 再 **绕 X 轴倾斜**，对比。

| 期望 | 说明 |
|------|------|
| 倾斜后 `|ax|` 或 `|ay|` 增大，`|az|` 减小 | 重力分量从 Z 转到水平轴 |
| 翻转 180°（板底朝上） | `az` 应变为 **负的约 -1g** |

**步骤 C — 转动（验陀螺仪）**

1. 平放静止，记下 `gyro_*` 基线。  
2. 用手快速绕某一轴转动（如绕 Z 在桌面平面旋转），同时连读 `gyro_z`。

| 期望 | 说明 |
|------|------|
| 转动瞬间对应轴 `|gyro_*|` 明显变大 | 有角速度输出 |
| 停稳后再读 | 回到接近基线（仍可有零漂） |

**步骤 D —（可选）温度**

```bash
cat /sys/class/misc/icm20608/temp
```

有稳定整数即可；不做精确室温换算也可过 L4。

##### 本工程步骤 D 实测

```text
cat /sys/class/misc/icm20608/temp
5473
```

有稳定读数（约 5472～5473），**步骤 D：通过**（未做精确换算）。

#### L4 完成后验证

| 检查项 | 通过标准 | 本工程（2026-09-04） |
|--------|----------|----------------------|
| 平放基线（A） | `az`≈+1g raw；`ax/ay` 相对小 | **通过**（az≈16600） |
| 倾斜（B） | X/Y/Z 随倾角合理重分配 | **待做** |
| 转动（C） | 对应 `gyro_*` 瞬时变化 | **待做** |
| whoami / 温度（D） | `0xaf`；temp 有数 | **通过** |

**L4 进度：A/D 已过；完成 B（倾斜）+ C（转动）后即可结案。**  
L4 **不要求** 写应用；若以后要做显示/姿态解算，再基于 `ioctl(ICM20608_GET_DATA)` 或持续读 sysfs 写用户程序。

---

### L5 —（可选）数据就绪中断 `6D_INT`

硬件：`6D_INT` → **GPIO1_IO10**（`JTAG_MOD` 复用 GPIO）。

设备树（见 L1 注释）+ 驱动内：

- `INT_PIN_CFG` / `INT_ENABLE` 配置 **RAW_RDY_INT**
- `request_threaded_irq` + `IRQ_TYPE_LEVEL_LOW`
- 中断里读 FIFO 或 `0x3B` 块读

注意：

- **仅改 dts 不会自动有中断**；驱动必须 `request_irq`。
- GPIO1_IO10 与 JTAG 调试脚复用，一般 Linux 下可作 GPIO 输入。

#### L5 完成后验证

```bash
cat /proc/interrupts | grep -i icm
# 数据就绪或定时采样后计数增加
```

---

## 四、构建与部署提醒

```bash
# 在 linux-kernel-overlay 习惯流程下（以你仓库脚本为准）
./scripts/build_kernel.sh gengtao-bsp-0901
./scripts/update_board.sh gengtao-bsp-0901 tftp
```

| 改动内容 | 必须更新 | 对应验证层 |
|----------|----------|------------|
| 仅 dts（ecspi3 / 禁 uart2/flexcan2） | **dtb** | L0～L1 |
| `spidev` / 读 WHO_AM_I | dtb + 可能需 zImage（`CONFIG_SPI_SPIDEV`） | L2 |
| 新增 `icm20608` 驱动 | **zImage**（+ dtb） | L3～L4 |
| 用户态测试程序 | **不强制**；L4 用 sysfs 即可 | L4 |
| 中断 | zImage + dtb | L5 |

U-Boot 确认加载的是定制 dtb（见 `03`），避免仍用旧 EVK 树。

---

## 五、易踩坑（短表）

| 坑 | 说明 |
|----|------|
| 当成 I2C 器件 | ICM-20608 在本板走 **ECSPI3**，不是 I2C1 |
| 不关 `flexcan2` / `uart2` | 与 ECSPI3 **同一组 UART2 脚**，pinctrl 冲突必失败 |
| `cs-gpio` 写成单数 | i.MX SPI 控制器需 **`cs-gpios`**（复数），否则片选不动 |
| SPI 模式错误 | 须 **Mode 3**（`spi-cpol` + `spi-cpha`） |
| 读寄存器时序错 | 全双工：读 N 字节要发 N+1；地址 **bit7=1** 表示读 |
| 只更 dtb 不更内核 | 无驱动则 `/dev/icm20608` 不会出现 |
| `origin/IMX6` 无驱动源码 | 仅有 dts；驱动在课程/SDK，需自行引入 |
| 用 4.1.15 `inv_mpu6050` | 仅 **I2C MPU6050**，不支持本板 SPI ICM-20608 |
| WHO_AM_I 读错 | 期望 **0xAF**；若 `0xFF`/`0x00` 先查供电、CS、模式、接线 |
| 过早配中断 | 先 L2 WHO_AM_I + L4 数据，再 L5 中断 |

---

## 六、验收标准（打通即停）

按层勾选：

- [x] **L0** `CONFIG_SPI` + `CONFIG_SPI_IMX`；`flexcan2`/`uart2` 冲突已处理（2026-09-04）
- [x] **L1** dts 已写 `&ecspi3` + `icm20608@0`；板上 **`spi2.0`**（2026-09-04）
- [x] **L2** 总线枚举 + WHO_AM_I=`0xAF`（随 L3 probe，2026-09-04）
- [x] **L3** 驱动 probe OK；`/dev/icm20608`；sysfs `whoami`/`accel_z` 可读（2026-09-04）
- [ ] **L4** 平放 A/温度 D 已过；**倾斜 B / 转动 C 待做**
- [ ] **L5**（可选）`6D_INT` 中断计数增加

首轮打通：**L0～L4 全部勾上即可停。**

---

## 七、源码与资料速查

| 资源 | 路径 / 命令 |
|------|-------------|
| 底板原理图 | `gengtao-bsp-doc/IMX6ULL_ALPHA_V2.4(底板原理图).pdf`（6 AIXS SENSOR / U6） |
| 核心板原理图 | `gengtao-bsp-doc/IMX6ULL_CORE_V2.0(核心板原理图).pdf` |
| 出厂 dts（ecspi3） | `git show origin/IMX6:arch/arm/boot/dts/imx6ull-alientek-emmc.dts` |
| SoC dtsi | `arch/arm/boot/dts/imx6ull.dtsi`（`ecspi3@02010000`，`spi2 = &ecspi3`） |
| 引脚宏 | `arch/arm/boot/dts/imx6ul-pinfunc.h`（`ECSPI3_*`、`JTAG_MOD→GPIO1_IO10`） |
| 本板当前 dts | `projects/gengtao-bsp-0901/.../imx6ull-14x14-evk-gengtao0901.dts` |
| SPI 控制器驱动 | `drivers/spi/spi-imx.c` |
| 内核 IMU（不适用本板 SPI） | `drivers/iio/imu/inv_mpu6050/`（仅 I2C MPU6050） |
| 硬件归纳 | 文档 **`04`** |
| 同类方法论 | 文档 **`11`**（I2C AP3216C） |
| I2C 架构参考 | 文档 **`14`/`15`**（分层思想可类比 SPI：`spi_register_controller` → `spi_device` → `spi_driver`） |

---

## 八、与 AP3216C（文档 11）的对照

| 维度 | AP3216C（11） | ICM-20608（本文） |
|------|---------------|-------------------|
| 总线 | I2C1，`i2c-0` | **ECSPI3**，`spiX.0` |
| 地址/片选 | `reg = <0x1e>` | `reg = <0>` + **GPIO1_IO20 CS** |
| 匹配键 | `LiteOn,ap3216c` | `alientek,icm20608` |
| 出厂驱动位置 | `origin/IMX6:drivers/char/ap3216c.c` | **需从 SDK/课程引入** |
| 引脚冲突 | `fxls8471@1e` | **`uart2` + `flexcan2`** |
| 首轮验证 | `i2cdetect` / `i2cget` | **WHO_AM_I `0xAF`**（spidev） |
| 用户接口 | `/dev/ap3216c` | `/dev/icm20608` 或 IIO sysfs |

---

## 九、一句话

**ALPHA 底板 ICM-20608 = ECSPI3 + GPIO1_IO20 片选；禁用与 UART2 冲突的 `flexcan2`/`uart2`，按 `origin/IMX6` 补 `&ecspi3` 与 `pinctrl_ecspi3`，先用 SPI 读出 WHO_AM_I=0xAF，再引入 `alientek,icm20608` 驱动读六轴；`6D_INT→GPIO1_IO10` 留作二期。每层做完先过该层验证再往下。**
