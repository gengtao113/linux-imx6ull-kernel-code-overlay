# 04 硬件原理图归纳（核心板 + ALPHA 底板）

> 文档编号：04  
> 日期：2026-09-01  
> 资料：
> - `IMX6ULL_CORE_V2.0(核心板原理图).pdf`（8 页，2022/4/14）
> - `IMX6ULL_ALPHA_V2.4(底板原理图).pdf`（5 页，2023/4/4）  
> 板卡：正点原子 ATK-MX6ULL（CORE + ALPHA 底板）

---

## 一、两块板怎么分工

| 板子 | 职责 | 对 BSP 的意义 |
|------|------|----------------|
| **核心板 CORE V2.0** | CPU、DDR、eMMC、电源、SoC 引脚引出 | 决定内存/存储/供电；多数引脚名在核心板定义后到座子 |
| **底板 ALPHA V2.4** | 网口、LCD、TF、USB、音频、传感器、外设座 | 决定外设芯片型号、PHY 地址、复位脚、连接器 |

日常写 dts，**外设多看底板**；**eMMC/内存/启动相关看核心板**。

---

## 二、核心板（CORE V2.0）要点

### 1. 电源（Sheet: POWER / CPUPWR）

- 输入：`DC5V`
- 主要轨：
  - `VDD_ARM_SOC_IN` ≈ **1.275V**（CPU/SoC）
  - `DRAM_1V35` = **1.35V**（LVDDR3）
  - `DCDC_3V3` = **3.3V**（多数 IO：GPIO / LCDIF / ENET / UART 等）
  - `SNVS_3V3`（RTC / SNVS）
  - `NVCC_SD`：**1.8V / 3.3V 可切换**（受 `SD1_VSELECT` 控制）
  - `VCC_CSI` ≈ **2.8V**（摄像头）

### 2. 内存与存储（Sheet: LVDDR3 / FLASH）

| 项 | 原理图信息 | 板子实测/常用配置 |
|----|------------|-------------------|
| DRAM | LVDDR3，1.35V | 启动日志常见 **512 MiB** |
| eMMC | `KLM8G1GETF`，挂在 **USDHC2 / NAND 复用脚**，8bit | 约 **8GB** eMMC |
| NAND 封装位 | 原理图保留 NAND 焊盘/选配 | 本学习板走 **eMMC**，不走 NAND |

### 3. SoC 侧已引出的关键信号（Sheet: LCDNET 等）

- **RGB LCD**：`LCD_DATA0~23` + `PCLK/DE/HSYNC/VSYNC`；背光 `BLT_PWM`（GPIO1_IO08）
- **双网 MAC**：`ENET1_*` / `ENET2_*`（RMII 相关脚在 SoC 侧）
- **MDIO 总线**：`ENET_MDIO` = GPIO1_IO06，`ENET_MDC` = GPIO1_IO07（两路 PHY 共用）
- **调试串口**：`UART1_TXD/RXD`（控制台）
- **SNVS_TAMPER0~9**：大量板级控制脚（网口复位/中断、蜂鸣器等）经此引出到底板

---

## 三、底板（ALPHA V2.4）要点

### 页结构

| Sheet | 内容 |
|-------|------|
| 1 DEVICE1 | RS232/RS485、CAN、TF、CSI 摄像头、RGB LCD、六轴、LED/KEY/蜂鸣器 |
| 2 DEVICE2 | 音频 WM8960、USB HUB/Host 等 |
| 3 ENET | 双网口 PHY + RJ45 |
| 4/5 PIN / POWER | 核心板座子脚位、拨码、底板电源 |

### 1. 网口（当前启动阻塞相关，最重要）

| 项 | ENET1 | ENET2 |
|----|-------|-------|
| PHY 芯片 | **SR8201F**（U14，LAN8720 兼容） | **SR8201F**（U15） |
| 模式 | **RMII** | **RMII** |
| PHY 地址（硬件拉脚） | **0x02** | **0x01** |
| 复位脚 | `ENET1_RST` = **SNVS_TAMPER7 = GPIO5_IO07** | `ENET2_RST` = **SNVS_TAMPER8 = GPIO5_IO08** |
| 中断脚 | `ENET1_INT` ≈ SNVS_TAMPER5 | `ENET2_INT` ≈ SNVS_TAMPER6 |
| 晶振 | 各 25MHz | 各 25MHz |
| 座子 | ATK911105A（带灯 RJ45） | 同上 |

**对 dts 的直接含义：**

```dts
&fec1 {
    phy-mode = "rmii";
    phy-handle = <&ethphy0>;
    phy-reset-gpios = <&gpio5 7 GPIO_ACTIVE_LOW>;
    phy-reset-duration = <200>;
    /* pinctrl 需含 pinctrl_fec1_reset */
};

&fec2 {
    phy-mode = "rmii";
    phy-handle = <&ethphy1>;
    phy-reset-gpios = <&gpio5 8 GPIO_ACTIVE_LOW>;
    phy-reset-duration = <200>;
};

/* MDIO 下 */
ethphy0: ethernet-phy@2 { reg = <2>; };  /* ENET1 */
ethphy1: ethernet-phy@1 { reg = <1>; };  /* ENET2 */
```

内核侧还需 SMSC/兼容 PHY 驱动（如 `CONFIG_SMSC_PHY`）。U-Boot 能 TFTP、内核 NFS 挂不上，多半就是复位脚/PHY 驱动未配齐。

### 2. 显示与触摸

- 接口：**24bit RGB LCD**（40pin FPC）
- 控制：`LCD_DE / HSYNC / VSYNC / PCLK`，背光 `BLT_PWM`
- 触摸：走 **I2C2**（`CT_INT` / `CT_RST`）
- 部分 `LCD_DATA` 经 **SGM3157** 模拟开关与启动相关信号复用——写屏参时注意脚位是否被拨码/开关切走

### 3. 存储与启动相关（底板侧）

- **TF 卡**：`USDHC1`，4bit，带 CD
- **拨码/跳线**：可选 eMMC / NAND / MicroSD / USB 等启动组合（见 PIN 页 BOOT 相关表）
- 本学习环境：核心板 **eMMC 启动 U-Boot**，内核/dtb 走 **TFTP**，rootfs 走 **NFS**

### 4. 其他外设（后续逐个打通）

| 外设 | 芯片/接口 | 总线/脚 |
|------|-----------|---------|
| 调试串口转 RS232 | SP3232 | UART3（可选跳线） |
| RS485 | SP3485 | UART3 相关 |
| CAN | TJA1050 | CAN1_TX/RX |
| 音频 | **WM8960** | I2S + I2C |
| 六轴 | **ICM-20608** | ECSPI3 + 中断 |
| 摄像头 | 18pin CSI 座 | CSI 8bit + I2C2 |
| LED / KEY / BEEP | GPIO | `LED0` / `KEY0` / `BEEP` |
| USB | Host/HUB 等 | USB OTG / HUB |

---

## 四、核心板座 → 底板信号对照（写 dts 常用）

| 板级信号 | SoC 脚（核心板） | 用途 |
|----------|------------------|------|
| ENET1_RST | SNVS_TAMPER7 / GPIO5_IO07 | FEC1 PHY 复位 |
| ENET2_RST | SNVS_TAMPER8 / GPIO5_IO08 | FEC2 PHY 复位 |
| ENET1_INT | SNVS_TAMPER5 / GPIO5_IO05 | FEC1 PHY 中断 |
| ENET2_INT | SNVS_TAMPER6 / GPIO5_IO06 | FEC2 PHY 中断 |
| ENET_MDIO / MDC | GPIO1_IO06 / GPIO1_IO07 | 双 PHY 管理总线 |
| BLT_PWM | GPIO1_IO08 | LCD 背光 |
| LED0 | GPIO_3 | 板载 LED |
| KEY0 | GPIO | 按键 |
| SD1_* | USDHC1 | TF 卡 |
| SD2_* / eMMC | USDHC2 | 核心板 eMMC |

---

## 五、和当前软件状态的对应关系

| 硬件事实 | 当前软件缺口 |
|----------|--------------|
| 双 SR8201F，RMII，PHY 地址 2/1 | dts 仍接近官方 EVK，未必带对复位脚 |
| PHY 复位在 GPIO5_IO07/08 | 需 `phy-reset-gpios` + `pinctrl_fec*_reset` |
| 需 SMSC 兼容 PHY 驱动 | defconfig 可能缺 `CONFIG_SMSC_PHY` |
| 7 寸 1024×600 RGB 屏 | lcdif timing 仍可能是 480×272（EVK 默认） |
| eMMC 在核心板 USDHC2 | emmc dts 已有 usdhc2 8bit 片段，可继续核对 |

**建议学习顺序（对照原理图）：**  
网口（FEC+PHY 复位）→ 能 NFS 登录 → LCD 时序/背光 → TF/按键 LED → 音频/传感器。

---

## 六、一句话总览

- **核心板**：i.MX6ULL + LVDDR3 + eMMC + 电源，把 SoC 脚引到座子。  
- **ALPHA 底板**：双网口 SR8201F（RMII，地址 2/1，复位 GPIO5_7/8）、24bit RGB LCD、TF、USB、WM8960、六轴等。  
- **写 BSP 时**：网口/屏/外设以底板原理图为准；存储与供电以核心板为准。
