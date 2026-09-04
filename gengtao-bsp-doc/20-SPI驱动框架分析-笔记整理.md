# 20 SPI 驱动框架分析（本板笔记）

> 文档编号：20  
> 日期：2026-09-04  
> 板卡：正点原子 ATK-MX6ULL（CORE V2.0 + ALPHA V2.4）  
> 内核：4.1.15（本仓库 `linux-imx6ull-kernel-code`）  
> 本板实例：SoC **ECSPI3**（`ecspi@02010000` → master **`spi2`**）+ 从设备 **ICM-20608@CS0**（`spi2.0`）  
> 关联：`19`（架构图速览）、`18`（设备树匹配与调用链）、`16`/`17`（六轴落地与复盘）  
> 素材：`drivers/spi/spi.c`、`spi-imx.c`、`spi-bitbang.c`；`drivers/char/icm20608.c`

---

## 目录

| 章 | 内容 |
|----|------|
| [一](#一简介与读法) | 目标与读法 |
| [二](#二第一部分spi-框架三层) | 三层 + 文本图 1/2 |
| [三](#三总线设备驱动模型图3) | `spi_bus_type` 注册对称 |
| [四](#四关键结构体) | master / device / driver / message / transfer |
| [五](#五结构体关系图4) | 对象如何互相挂接 |
| [六](#六注册路径spi_register_master--spi_register_driver) | 对称注册 |
| [七](#七代码走读--总线驱动spi-imx) | 控制器侧（`spi-imx`）；OF 建 device、传输路径 |
| [八](#八第二部分代码走读设备驱动) | 从设备侧（`icm20608`） |
| [九](#九本板对象速查) | 本板文件与符号对照 |
| [十](#十一句话) | 收束 |
| **[十一](#十一icm-20608-打通流程按本文分析思路适配)** | **ICM-20608 分层打通** |

---

## 一、简介与读法

本文目标：结合本仓库代码，分析 **SPI 总线框架**（总线层 / 核心层 / 设备层）及 **ICM-20608** 落地路径。分为：

1. **框架部分**（§二～§六）：结构体关系与注册对称  
2. **走读部分**（§七～§八）：`spi-imx` 与 `icm20608` 源码  
3. **实战部分**（§十一）：L0～L4 分层验收

建议读法：先把本文文本图看熟，再对照 `19`；抠调用链时回 `18` §五/§六。

---

## 二、第一部分：SPI 框架（三层）

分析 SPI 驱动 = 分析 Linux 里 **总线 — 设备 — 驱动** 各层对象及其关系。先建立整体框架，再往框架上「放零件」。

### 2.1 文本图① — 分层总览

```text
┌──────────────────── 用户空间 ────────────────────┐
│                 应用程序                          │
└───────────────────────┬──────────────────────────┘
                        │
┌──────────────────── 内核空间 ────────────────────┐
│                                                  │
│  【SPI 设备驱动层】                                │
│     SPI 设备驱动 ──→ spi_driver ←──→ spi_device  │
│                                                  │
│  ═══════════════ SPI 核心（spi.c）═══════════════ │
│                                                  │
│  【SPI 总线驱动层】                                │
│     SPI 总线驱动 ──→ spi_master ──→ transfer 钩子 │
│                                                  │
│  ── 特定控制器硬件相关操作代码 ─────────────────── │
└───────────────────────┬──────────────────────────┘
                        │
┌───────────────────── 硬件 ───────────────────────┐
│  SPI 主控 ════ SCLK/MOSI/MISO/CS ════ SPI 从设备… │
└──────────────────────────────────────────────────┘
```

### 2.2 文本图② — 双总线 + 对象关系

```text
应用层：  /dev/icm20608（misc）   （可选：/dev/spidevX.Y）
              │
内核：   spi_driver …     「spi_driver」(spidev)
              \              /
               \__ spi bus __/
                    │    │
               spi_device …
                    │
               spi.c
                    │
               spi_master 对象
                    ▲
                    │ 构造
     platform bus ──┤
          │         │
  platform_driver（spi_imx）
          │
硬件： ECSPI控制器 ════ 总线 ════ SPI设备0/1/2…
```

### 2.3 三层各自职责

#### SPI 总线驱动层（主机 / 控制器）

通信中起 **主机** 作用：产生时钟、拉片选、移位收发。随 SoC 而异，由芯片厂商提供。

**本板文件：** `drivers/spi/spi-imx.c`（经 `spi-bitbang.c` 注册 master）。

该层主要工作：

1. 分配/填充 `spi_master`，挂 bitbang 或 transfer 钩子  
2. 做片上 SPI 主机相关初始化（时钟、IO、中断、寄存器、**cs-gpios**）  
3. 通过核心层把 master 登记进内核（`spi_register_master`）  

#### SPI 总线核心层（中间层）

连接总线驱动层与设备驱动层；**与具体芯片无关**，使用内核 `spi.c`。

主要提供：

1. master 注册（`spi_register_master`；按 aliases 取 `bus_num`）  
2. `of_register_spi_devices`：按 dts 子节点实例化 `spi_device`  
3. `spi_sync` / `spi_write_then_read`：主从数据传输入口  
4. `spi_register_driver`：登记设备驱动并匹配  

#### SPI 设备驱动层（从机侧软件）

面向具体外设协议：写寄存器、读传感器、出字符设备/sysfs。

**本板文件：** `drivers/char/icm20608.c`（overlay）。

该层主要工作：

1. 声明 `spi_driver` + `of_match_table` / `id_table`  
2. `probe` 里 `spi_setup`、初始化芯片、注册 misc  
3. 通过 `spi_write` / `spi_write_then_read` 访问器件  

---

## 三、总线—设备—驱动模型（文本图③）

`spi` 使用 `spi_bus_type`，属于总线—设备—驱动模型。

### 3.1 文本图③ — `spi_bus_type` 注册对称

```text
                    Bus (spi_bus_type)
                   /                  \
            【dev 链表】              【Drv 链表】
         （spi_device 等）          （spi_driver 等）
                ▲                        ▲
                │                        │
         of_register_spi_device    spi_register_driver
         / spi_add_device
                │                        │
┌───────────────┴────────┐    ┌──────────┴──────────────┐
│ SPI 总线驱动程序        │    │ SPI 设备驱动程序          │
│ 1. 分配 spi_master      │    │ 1. 填 spi_driver         │
│ 2. 设 bitbang/transfer  │    │ 2. 设置 .probe /          │
│ 3. spi_register_master  │    │    of_match_table 等      │
└─────────────────────────┘    └─────────────────────────┘
                \                        /
                 \→ 互相遍历对方链表 ←/
                      │
            of_register_spi_device 建 spi_device
            spi_match_device → .probe 绑定
                      │
               绑定 spi_device
               (.chip_select / .master / .driver)
```

与分层图的对应：

| 图③ 元素 | 分层图位置 |
|----------|------------|
| 总线驱动程序 | 总线驱动层 |
| 设备驱动程序 | 设备驱动层 |
| `spi_register_master` / `spi_register_driver` | **核心层**提供 |

---

## 四、关键结构体

核心层主要提供「连接方法」，不负责填充 SoC/芯片私有数据；结构体重点在 **总线驱动层** 与 **设备驱动层**。

### 4.1 总线驱动层

#### 厂商私有结构（`spi_imx_data`）

内含 `spi_bitbang`、寄存器基址、时钟、IRQ、完成量、**chipselect[]（GPIO）** 等（`spi-imx.c`）。

#### `spi_master`（标识一条物理 SPI 总线）

关键字段：`bus_num`、`num_chipselect`、`mode_bits`、`setup` / `transfer*`、`dev.of_node` 等。  
本板：`bus_num=2`（aliases `spi2`），设备名 **`spi2`**。

#### bitbang / transfer 钩子（通信方法）

本板经 `spi_bitbang`：

| 钩子 | 本板函数 | 作用 |
|------|----------|------|
| `chipselect` | `spi_imx_chipselect` | 拉高/拉低 GPIO CS |
| `setup_transfer` | `spi_imx_setupxfer` | 按 speed/bpw 配控制器 |
| `txrx_bufs` | `spi_imx_transfer` | 真正收发 |

缺少这些钩子的 master **无法完成传输**。

#### `spi_message` / `spi_transfer`（一次 SPI 事务描述）

```text
spi_message
  └─ transfers 链表：若干 spi_transfer
        tx_buf / rx_buf / len
        bits_per_word / speed_hz / cs_change …
```

全双工：同一拍可同时有 `tx_buf` 与 `rx_buf`。  
设备驱动常用封装：`spi_write`、`spi_write_then_read`（内部组 message 再 `spi_sync`）。

### 4.2 设备驱动层

#### `spi_driver`

一套驱动方法。本板 `icm20608_driver` 使用：

- `.probe` / `.remove`  
- `of_match_table`（`compatible = "alientek,icm20608"`）  
- `id_table`（`"icm20608"`）

#### `spi_device`

描述总线上的一颗真实从设备：`chip_select`、`mode`、`max_speed_hz`、`modalias`、`master` 等。  
本板：`spi2.0`，CS=0，Mode3，8 MHz。

---

## 五、结构体关系（文本图④）

### 5.1 文本图④ — 对象挂接关系

```text
              ┌──────── spi_transfer ────────┐
              │ tx_buf | rx_buf | len | …    │
              └──────────────▲───────────────┘
                             │ transfers
              ┌──────────────┴───────────────┐
              │        spi_message           │
              └──────────────▲───────────────┘
                             │ spi_sync
              ┌──────────────┴───────────────┐
              │  spi_imx_data（spi-imx.c）    │
              │  bitbang | base | clk | cs[] │
              │              | master        │
              └──────────────┬───────────────┘
                             │ master
              ┌──────────────┴───────────────┐
              │         spi_master (spi2)    │
              │  bus_num=2  num_chipselect=1 │
              └──────────────┬───────────────┘
                             │
              ┌──────────────┴───────────────┐
              │  spi_device (spi2.0)         │
              │  cs=0  mode=3  8MHz          │
              └──────────────┬───────────────┘
                             │ driver
              ┌──────────────┴───────────────┐
              │  spi_driver (icm20608)       │
              │  probe → misc / sysfs        │
              └──────────────────────────────┘
```

### 5.2 三对关系

| 关系 | 含义 |
|------|------|
| **master ↔ device** | 与硬件「控制器 ↔ 从设备」一致；一个 master 可挂多个 CS 上的 device；device 通过 `.master` 指回 |
| **master ↔ transfer 钩子** | master 是物理总线抽象；bitbang/transfer 是通信方法 |
| **driver ↔ device** | driver 是一套方法；device 是具体芯片实例；**一对多**（同类多颗芯片） |

---

## 六、注册路径：`spi_register_master` / `spi_register_driver`

本树 4.1.15 的注册对称性（与图③一致）：

### 6.1 `spi_register_master`

1. `of_alias_get_id(..., "spi")` → 本板 `bus_num=2` → `dev_set_name(..., "spi%u")`  
2. `device_add(&master->dev)` → 出现 `spi2`  
3. （queued 路径）初始化传输队列  
4. `of_register_spi_devices(master)` → 按 dts 子节点建 `spi_device`  

本板入口常为：`spi_imx_probe` → **`spi_bitbang_start`** → `spi_register_master`。

### 6.2 `spi_register_driver`

1. `sdrv->driver.bus = &spi_bus_type`；包装 `spi_drv_probe`  
2. `driver_register` → 入 Drv 链，并对已有 `spi_device` 做 `driver_attach`  
3. 匹配成功 → `spi_drv_probe` → `sdrv->probe(spi)`  

**对称性：** 先注册哪边都行；后到的一侧会扫另一侧链表并尝试匹配。

### 6.3 本板调用入口

| 步骤 | 本板符号 | 文件 |
|------|----------|------|
| 注册 master | `spi_bitbang_start` → `spi_register_master` | `spi-imx.c` / `spi-bitbang.c` / `spi.c` |
| 建 device | `of_register_spi_devices` → `of_register_spi_device` | `spi.c` |
| 注册 driver | `module_spi_driver(icm20608_driver)` | `icm20608.c` |
| 匹配 | `spi_match_device` → `icm20608_probe` | `spi.c` / `icm20608.c` |

细节深挖：`18` §五/§六；架构总览：`19`。

---

## 七、代码走读 — 总线驱动（`spi-imx`）

本板 SPI 控制器经 **platform 总线** 出现，probe 里构造 `spi_master` 并注册。

```text
of_platform_populate → platform_device(ecspi@02010000)   【设备先到】
        ↓
module_platform_driver(spi_imx) → spi_imx_probe          【驱动后到】
  · 读 fsl,spi-num-chipselects、cs-gpios
  · ioremap / clk / irq
  · 填 bitbang 钩子
  · spi_bitbang_start → spi_register_master → spi2
  · of_register_spi_devices → spi2.0
```

### 7.1 `spi_imx_probe`：master 如何就绪

| 步骤 | 做什么 |
|------|--------|
| OF match | `spi_imx_dt_ids` 命中 `fsl,imx6ul-ecspi` / `fsl,imx51-ecspi` |
| 片选数 | `fsl,spi-num-chipselects` |
| CS GPIO | **`of_get_named_gpio(np, "cs-gpios", i)`**（属性名必须复数） |
| 钩子 | `chipselect` / `setup_transfer` / `txrx_bufs` |
| 硬件 | MMIO、IRQ、`clk_ipg`/`clk_per`、reset |
| 登记 | `master->dev.of_node = pdev->dev.of_node`；`spi_bitbang_start` |
| 日志 | `spi_imx 2010000.ecspi: probed` |

### 7.2 `of_register_spi_devices`：从 dts 到 `spi2.0`

#### 7.2.1 调用时机

`spi_register_master` 末尾调用 `of_register_spi_devices(master)`：

```text
for_each_available_child_of_node(master->dev.of_node, nc)
    of_register_spi_device(master, nc)
```

#### 7.2.2 解析 dts → 填 `spi_device`

对 `icm20608@0`：

| 属性 | 结果 |
|------|------|
| `compatible` | `of_modalias_node` → modalias **`icm20608`** |
| `reg` | `chip_select = 0` |
| `spi-cpol` / `spi-cpha` | `mode \|= SPI_CPOL\|SPI_CPHA`（Mode3） |
| `spi-max-frequency` | `max_speed_hz = 8000000` |
| 挂在哪个 master | 决定设备名 **`spi2.0`** |

#### 7.2.3 `spi_add_device`

设备进入 `spi_bus_type` 的 dev 链；若驱动已在，立即 `spi_match_device` → probe。

### 7.3 传输路径：`spi_write_then_read` → `spi_imx_transfer`

#### 7.3.1 设备驱动层：读寄存器

```text
icm20608_read_regs(spi, reg, buf, len)
  tx = reg | 0x80          /* ICM-20608 读标志 */
  spi_write_then_read(spi, &tx, 1, buf, len)
```

写寄存器：`spi_write(spi, {reg&0x7f, data}, 2)`。

#### 7.3.2 核心层：组 message 并下发

```text
spi_write_then_read
  → 构造 spi_message + 两个 spi_transfer（先写后读）
  → spi_sync(spi, message)
       → master 队列 / transfer 路径
```

#### 7.3.3 控制器层

```text
spi_imx_chipselect(ACTIVE)     /* GPIO1_IO20 拉低 */
spi_imx_setupxfer / transfer   /* 配时钟、移位收发 */
spi_imx_chipselect(INACTIVE)
```

#### 7.3.4 本板一次读 WHO_AM_I 的完整垂直路径

```text
cat .../whoami
  → show_whoami
       → icm20608_read_onereg(0x75)
            → spi_write_then_read(tx=0xF5, rx=1)
                 → spi_sync
                      → spi_imx_transfer + GPIO CS
                           → 期望返回 0xAF
```

---

## 八、代码走读 — 设备驱动（`icm20608`）

### 8.1 device 创建（master 注册时）

见 §7.2：`icm20608@0` → `spi2.0`。此时驱动可能尚未加载。

### 8.2 driver 绑定与 probe

```text
module_spi_driver(icm20608_driver)
  → spi_register_driver
  → spi_match_device（OF：alientek,icm20608）
  → spi_drv_probe → icm20608_probe(spi)
       → spi->mode |= SPI_MODE_3；spi_setup(spi)
       → icm20608_init_hw：复位、WHO_AM_I、开 accel/gyro
       → misc_register → /dev/icm20608 + sysfs
```

判据：`dmesg` 见 `WHO_AM_I=0xaf OK`；`/dev/icm20608` 存在；`spi2.0/driver` 指向 `icm20608`。

---

## 九、本板对象速查

| 对象 | 本板值 | 来源 |
|------|--------|------|
| platform 设备 | `2010000.ecspi` | `ecspi@02010000` |
| platform 驱动 | `spi_imx` | `spi-imx.c` |
| `spi_master` | `spi2` | aliases `spi2 = &ecspi3` |
| `spi_device` | `spi2.0` | `icm20608@0`，`reg=<0>` |
| `spi_driver` | `icm20608` | `icm20608.c` |
| CS | GPIO1_IO20 | `cs-gpios` |
| 模式 / 时钟 | Mode3 / 8 MHz | `spi-cpol`/`cpha`/`spi-max-frequency` |
| 用户接口 | `/dev/icm20608` + sysfs | `misc_register` |
| 验证寄存器 | WHO_AM_I=`0xAF` | 地址 `0x75` |

---

## 十、一句话

三层（总线驱动 / 核心 / 设备驱动）+ `spi_bus_type` 上 device↔driver 对称注册，把 SPI 框架串起来；结构体上是 **master+transfer 钩子管总线，device+driver 管芯片，message/transfer 管一帧传输**。  
本仓库落到：`of_platform_populate` → `spi_imx` → `spi2` → `spi2.0` → `icm20608` → `/dev/icm20608`。

---

## 十一、ICM-20608 打通流程（按本文分析思路适配）

> 本章把 §二～§八 的 **同一套分析思路**（先总图 → 放结构体 → 看注册 → 走读代码）落到本板 **ICM-20608** 打通。  
> 落地步骤细节见 `16`（L0～L5）；匹配与调用链见 `18`；问题见 `17`。

### 11.1 先建立总图：ICM-20608 在 SPI 框架里的位置

```text
┌──────────────────── 用户空间 ─────────────────────────────┐
│  cat .../icm20608/whoami    cat .../accel_z    ioctl     │
└────────────────────────────┬──────────────────────────────┘
                             │
┌──────────────────── 内核空间 ─────────────────────────────┐
│ 【设备驱动层】 icm20608.c                                  │
│   icm20608_driver ──match──► spi_device(spi2.0, CS=0)     │
│   icm20608_probe → misc → /dev/icm20608 + sysfs           │
│                             │                              │
│ ═════════════ spi.c（spi_sync / match / OF）══════════════ │
│                             │                              │
│ 【总线驱动层】 spi-imx.c                                    │
│   spi_imx_driver → spi_master(spi2) → spi_imx_transfer    │
│                             │                              │
│ 【platform 侧】 of_platform_populate → pdev(ecspi@02010000)│
└─────────────────────────────┬──────────────────────────────┘
                              │ ECSPI3 + GPIO CS
┌───────────────────── 硬件 ─────────────────────────────────┐
│  SoC ECSPI3 @ 0x02010000 ════ U6 ICM-20608 @ CS0          │
└────────────────────────────────────────────────────────────┘
```

**本板 ICM-20608 要点：**

| 维度 | 本板实现 |
|------|----------|
| device 来源 | dts `icm20608@0` → `of_register_spi_device` |
| driver 绑定 | `spi_match_device` + `icm20608_probe` |
| 用户接口 | `misc_register` → `/dev/icm20608` |
| 器件验证 | WHO_AM_I=`0xAF`；平放 `accel_z`≈1g 量级 |

### 11.2 双总线视角（对照 §2.2）

ICM-20608 打通涉及 **两条总线、两次匹配**：

```text
【第一次：platform 总线 — 造「主机」】
dtb: ecspi@02010000 (status=okay, pinctrl_ecspi3, cs-gpios)
  → of_platform_populate → platform_device
  → platform_driver_register(spi_imx)
  → spi_imx_probe → spi_master(spi2)

【第二次：spi 总线 — 绑「从机」】
dtb: icm20608@0 (compatible, reg=0, Mode3, 8MHz)
  → of_register_spi_devices → spi_device(spi2.0)
  → spi_register_driver(icm20608) → match → icm20608_probe
  → /dev/icm20608
```

硬件信号链（写 dts 前必对）：

```text
ICM-20608(U6) ──SCLK/MOSI/MISO── ECSPI3 ── UART2 脚复用
                CS ── GPIO1_IO20（cs-gpios）
                reg = <0>   （片选索引，不是节点名 @0 本身）
前提：disabled &uart2 / &flexcan2
```

### 11.3 往框架上放零件：ICM-20608 结构体对照表

| 结构体 | 本板实例 / 值 | 谁创建 / 谁填充 | 文件 |
|--------|---------------|-----------------|------|
| `platform_device` | `ecspi@02010000` | `of_platform_populate` | `drivers/of/platform.c` |
| `spi_imx_data` | ECSPI3 控制器私有数据 | `spi_imx_probe` | `spi-imx.c` |
| `spi_master` | **`spi2`** | `spi_bitbang_start` → `spi_register_master` | `spi-imx.c` → `spi.c` |
| transfer 钩子 | `spi_imx_transfer` 等 | `spi_imx_probe` | `spi-imx.c` |
| `spi_device` | **`spi2.0`**，CS=0，Mode3 | `of_register_spi_device` | `spi.c` |
| `spi_driver` | `icm20608_driver` | `module_spi_driver` | `icm20608.c` |
| `spi_message`/`transfer` | 读 WHO_AM_I / 14 字节传感器块 | `spi_write_then_read` 内部 | `spi.c` / `icm20608.c` |

**文本图④（ICM-20608 单实例版）：**

```text
         spi_transfer (tx=0xF5 / rx=whoami)
              ▲
              │ icm20608_read_onereg
              │
    spi_device (spi2.0) ◄─── master ───► spi_master (spi2)
         │   ▲                              │ bitbang
         │   │ driver                       ▼
         └───┴──► icm20608_driver     spi_imx_transfer
                      │ probe                    ▲
                      ▼                          │
                 icm20608_init_hw ──spi_sync─────┘
                      │
                 misc_register → /dev/icm20608
```

三对关系在本板上的体现：

| 关系 | ICM-20608 实例 |
|------|----------------|
| master ↔ device | `spi2` 下挂 `spi2.0`；`spi->master` 指回 `spi2` |
| master ↔ transfer | `spi2` → bitbang → `spi_imx_transfer` |
| driver ↔ device | 一个 `icm20608_driver` 绑定一个 `spi2.0` |

### 11.4 注册与匹配时序（对照 §三、§六）

```text
① unflatten_device_tree
        ↓
② imx6ul_init_machine
     of_platform_populate → platform_device(ecspi@02010000)
        ↓
③ module_platform_driver(spi_imx)
     → spi_imx_probe
     → spi_bitbang_start → spi_register_master → spi2
     → of_register_spi_devices
          → spi_device spi2.0（此时 driver 可能尚未注册）
        ↓
④ device_initcall: module_spi_driver(icm20608)
     → spi_register_driver
     → spi_match_device(alientek,icm20608)
     → icm20608_probe → /dev/icm20608
```

对称注册在本板上的 **两次**：

| 次序 | 核心 API | 左侧（device/dev） | 右侧（driver） | ICM-20608 结果 |
|------|----------|--------------------|----------------|----------------|
| 1 | `spi_register_master` | 登记 `spi2` + 建 `spi2.0` | 若驱动已注册则 match | 设备节点出现 |
| 2 | `spi_register_driver` | 扫已有 device | 登记 `icm20608_driver` | bind + probe |

### 11.5 分层打通：L0～L4 与 SPI 三层对应

用 `16` 的验证层级，映射到本文 **三层框架**：

| 层级 | SPI 框架层 | 要做什么 | 成功判据 | 卡住了先查 |
|------|------------|----------|----------|------------|
| **L0** | 总线驱动 + 核心 | `SPI`/`SPI_IMX`；`&ecspi3` 尚未 okay 也可先确认配置 | `spi_imx` 驱动在；uart2/flexcan2 策略清楚 | Kconfig、引脚冲突认知 |
| **L1** | OF → device 前提 | `&ecspi3 okay` + `icm20608@0`，重编 dtb | `/proc/device-tree/.../icm20608@0`；有 `spi_imx ... probed` | 旧 dtb、属性写错 |
| **L2** | master + 枚举 | 总线枚举出 `spi2.0` | `ls /sys/bus/spi/devices/` 见 `spi2.0` | aliases、子节点 available |
| **L3** | 设备驱动注册 | overlay `icm20608.c`，`CONFIG_ICM20608=y`，重编内核 | `/dev/icm20608`；WHO_AM_I OK | 只更 dtb、compatible |
| **L4** | probe + 用户态 | 读 accel/gyro/temp，做姿态变化 | sysfs 数值合理变化 | Mode3、CS、供电 |

**打通最小闭环：**

```text
L0：SPI 配置与引脚冲突清楚   ← 总线驱动层前提
L1：dtb 有 ecspi3 + icm20608@0 ← OF 节点
L2：spi2.0 出现               ← master + of_register_spi_devices
L3：/dev/icm20608 + WHO_AM_I  ← spi_driver probe
L4：六轴读数随姿态变化        ← spi_sync 全链路
```

### 11.6 代码走读：总线侧（L0/L1/L2 对应 §七）

本板 dts 关键片段：

```dts
&flexcan2 { status = "disabled"; };
&uart2    { status = "disabled"; };

&ecspi3 {
	fsl,spi-num-chipselects = <1>;
	cs-gpios = <&gpio1 20 GPIO_ACTIVE_LOW>;
	pinctrl-names = "default";
	pinctrl-0 = <&pinctrl_ecspi3>;
	status = "okay";

	icm20608@0 {
		compatible = "alientek,icm20608";
		reg = <0>;
		spi-cpol;
		spi-cpha;
		spi-max-frequency = <8000000>;
	};
};
```

走读链：

```text
imx6ul_init_machine
  of_platform_populate
    → platform_device(ecspi@02010000)

module_platform_driver(spi_imx)
  spi_imx_probe
    of_get_named_gpio(..., "cs-gpios", 0) → GPIO1_IO20
    master->dev.of_node = &ecspi3
    spi_bitbang_start → spi_register_master
      of_register_spi_devices
        of_register_spi_device(icm20608@0)
          reg → chip_select = 0
          compatible → modalias = icm20608
          → spi2.0
```

### 11.7 代码走读：设备侧（L3/L4 对应 §八）

驱动匹配表（`icm20608.c`）：

```text
of_match_table:  "alientek,icm20608"   ← dts compatible
id_table:        "icm20608"            ← of_modalias 生成名兜底
probe:           icm20608_probe
```

probe 内部：

```text
icm20608_probe(spi)
  ├─ spi_setup（Mode3）
  ├─ icm20608_init_hw
  │    写 PWR_MGMT_1 复位 → 读 WHO_AM_I 期望 0xAF
  │    → 开 accel/gyro、配量程
  │         └─ spi_write / spi_write_then_read → spi_imx
  ├─ misc_register → /dev/icm20608
  └─ 保存 spi 指针供 sysfs/ioctl
```

**读 accel_z 时的路径：**

```text
cat .../icm20608/accel_z
  → show_sensor_field
       → icm20608_read_sensor（0x3B 起 14 字节）
            → spi_write_then_read
                 → spi_sync → spi_imx_transfer → ECSPI3
```

### 11.8 按三层框架回查失败

| 现象 | 框架层 | 对应 L | 先查 |
|------|--------|--------|------|
| 无 `spi_imx ... probed` | 总线驱动 / platform | L0/L1 | `SPI_IMX`、`&ecspi3`、pinctrl、uart2 冲突 |
| 有 probed，devices 空 | OF（device 前提） | L1/L2 | 子节点、dtb 是否更新 |
| 有 `spi2.0`，driver 空 | 设备驱动 match | L3 | 驱动未编进、`compatible` |
| `can't get cs gpios` | 总线驱动 | L1 | 写成 `cs-gpio`（单数） |
| WHO_AM_I 非 `0xAF` | probe 内传输 | L3/L4 | Mode3、CS、供电、接线 |
| L0 时 devices 空 | — | L0 | **正常**（尚未启用 `&ecspi3`） |

### 11.9 板上速查（打通验收）

```bash
# L1
find /proc/device-tree -name 'icm20608@0'
dmesg | grep -i spi_imx

# L2
ls /sys/bus/spi/devices/

# L3/L4
ls -l /sys/bus/spi/devices/spi2.0/driver
ls -l /dev/icm20608
dmesg | grep -i icm20608

# L4 读数
cat /sys/class/misc/icm20608/whoami
cat /sys/class/misc/icm20608/accel_z
cat /sys/class/misc/icm20608/temp
```

### 11.10 本章一句话

**按本文思路打通 ICM-20608 = 先在 platform 总线上用 `spi-imx` 造出 `spi2`，再在 spi 总线上用 dts + `of_register_spi_*` 造 `spi2.0`，最后用 `icm20608_driver` match/probe 出 `/dev/icm20608`；L0→L4 逐层验收，传输统一走 `spi_message` → `spi_sync` → `spi_imx_transfer`。**

---

## 参考

- 本仓库：`19`（架构与双总线）、`18`（匹配调用链）、`16`（L0～L5 落地）、`17`（问题排查）
