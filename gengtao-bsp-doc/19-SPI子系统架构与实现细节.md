# 19 SPI 子系统：架构与实现细节（对照架构图）

> 文档编号：19  
> 日期：2026-09-04  
> 板卡：正点原子 ATK-MX6ULL（CORE V2.0 + ALPHA V2.4）  
> 内核：4.1.15（本仓库 `linux-imx6ull-kernel-code`）  
> 本板实例：SoC **ECSPI3**（`ecspi@02010000` → master **`spi2`**）+ 从设备 **ICM-20608@CS0**（`spi2.0`）  
> 关联：`16`/`17`/`18`（六轴落地与匹配）；**`20`（SPI 框架笔记，含文本图）**  
> 素材：`drivers/spi/spi.c`、`spi-imx.c`、`spi-bitbang.c`；`drivers/char/icm20608.c`；`drivers/of/platform.c`

---

## 目录

| 章 | 对应哪张图 | 内容 |
|----|------------|------|
| [一](#一一句话) | — | 一句话 + 两层总线 |
| [二](#二图1分层总览用户空间--内核--硬件) | 图1 | 分层总览 |
| [三](#三图2双总线platform--spi) | 图2 | platform 总线 + spi 总线；[§3.4 `of_platform_populate` 详解](#34-of_platform_populate--platform_deviceecspi02010000-详解) |
| [四](#四图3注册对称master--driver) | 图3 | `spi_register_master` / `spi_register_driver` |
| [五](#五本板启动时序串起来) | 三图合一 | 从 dtb 到 `/dev/icm20608` |
| [六](#六读数路径与-spidev) | 图1/图2 上半 | 传输与用户态接口 |
| [七](#七文件与符号速查) | — | 走读锚点 |
| [八](#八一句话收束) | — | 收束 |

---

## 一、一句话

Linux SPI 是 **两层总线、四类对象**：

```text
platform 总线：platform_device(ecspi@02010000)  ↔  platform_driver(spi_imx)
                      ↓ probe 里「构造」
                 spi_master（本板 spi2）+ bitbang/transfer 钩子

spi 总线：     spi_device(spi2.0)               ↔  spi_driver(icm20608)
```

中间夹着 **`spi.c`**：注册、匹配、`spi_sync` / `spi_write_then_read`，把「设备驱动」和「控制器驱动」拆开。

---

## 二、图1：分层总览（用户空间 → 内核 → 硬件）

### 2.1 架构复述（按图）

```text
┌─────────────────────────── 用户空间 ───────────────────────────┐
│  应用程序（cat whoami / accel_z / ioctl）                        │
└───────────────────────────────┬────────────────────────────────┘
                                │ open / read / ioctl / sysfs
┌─────────────────────────── 内核空间 ───────────────────────────┐
│                                                                │
│  【SPI 设备驱动层】                                             │
│     SPI 设备驱动 ──→ spi_driver  ←匹配→  spi_device            │
│     （本板：icm20608.c）         （本板：spi2.0，CS=0）          │
│                                │                               │
│  ═══════════════════ SPI 核心（spi.c）════════════════════════  │
│                                │ spi_sync / spi_write_then_read│
│  【SPI 总线驱动层】                                             │
│     SPI 总线驱动 ──→ spi_master ──→ transfer / bitbang         │
│     （本板：spi-imx.c）  （spi2）     （spi_imx_transfer 等）   │
│                                │                               │
│  ── 特定控制器硬件相关操作（读写 ECSPI 寄存器 + GPIO CS）────── │
└───────────────────────────────┬────────────────────────────────┘
                                │ MMIO / IRQ / GPIO
┌──────────────────────────── 硬件 ──────────────────────────────┐
│  SPI 主控（SoC ECSPI3 @ 0x02010000）                            │
│       ║ SCLK / MOSI / MISO / CS(GPIO1_IO20)                    │
│  SPI 从设备（ICM-20608 @ CS0 等）                                │
└────────────────────────────────────────────────────────────────┘
```

### 2.2 图中对象 → 本板代码

| 图中概念 | 本板落点 | 文件 |
|----------|----------|------|
| SPI 设备驱动 | `icm20608_driver` / `icm20608_probe` | `drivers/char/icm20608.c` |
| `spi_device` | `spi2.0`，`chip_select=0`，Mode3 | 由 `spi.c` 的 `of_register_spi_device` 创建 |
| SPI 核心 | 匹配、`spi_sync`、注册 master/driver | `drivers/spi/spi.c` |
| SPI 总线驱动 | `spi_imx_driver` / `spi_imx_probe` | `drivers/spi/spi-imx.c` |
| `spi_master` | 设备名 `spi2`（aliases：`spi2 = &ecspi3`） | `spi_bitbang_start` → `spi_register_master` |
| 传输钩子 | `bitbang.txrx_bufs = spi_imx_transfer` 等 | `spi-imx.c` |
| 硬件相关操作 | ECSPI 寄存器 + `spi_imx_chipselect`（GPIO） | 同上 |
| 硬件主控 | ECSPI3 MMIO `0x02010000` | dtsi `ecspi@02010000` |
| 硬件从设备 | U6 ICM-20608 | 原理图见 `04`/`16` |

### 2.3 一次读数怎么穿过各层

```text
cat .../misc/icm20608/whoami
  → show_whoami / icm20608_read_onereg     【设备驱动层】
       → spi_write_then_read(spi, …)       【SPI 核心】
            → spi_sync → master 队列/transfer
                 → spi_imx_transfer        【总线驱动】
                      → 写/读 ECSPI + 拉 CS  【硬件相关操作】
                           → 线 → 芯片       【硬件】
```

---

## 三、图2：双总线（platform + spi）

图2 的关键信息：**控制器不直接挂在 spi 总线上**，而是先走 **platform 总线**；probe 成功后才「构造」出 `spi_master`，再挂到 **spi 总线**一侧。

### 3.1 架构复述（按图，换成本板名字）

```text
应用层：  /dev/icm20608（misc）          /dev/spidev2.0（可选，spidev）
                │                              │
                ▼                              ▼
内核：   spi_driver(icm20608)            spidev 通用接口
                \                            /
                 \______ spi bus ___________/
                        │         │
                   spi_device   spi_device …
                   (spi2.0)
                        │
                   spi.c
                        │
                   spi_master 对象 (spi2)
                        ▲
                        │ 构造（probe 里）
         platform bus ──┤
              │         │
    platform_driver     platform_device
    (spi_imx_driver)    (ecspi@02010000)   ← of_platform_populate 建出
              │
硬件：   ECSPI3 ════ SCLK/MOSI/MISO/CS ════ SPI 设备（ICM-20608）
```

图中的 platform 侧总线驱动 → 本板就是 **`spi_imx_driver`**。  
从设备来源 → 本板用 **设备树子节点**（`icm20608@0`），经 `of_register_spi_device` 建成 `spi_device`（见 `18`）。

### 3.2 左半：platform 侧如何「构造」master

```text
① of_platform_populate（设备先到，见 [§3.4](#34-of_platform_populate--platform_deviceecspi02010000-详解)）
   dtb → device_node ecspi@02010000
   → platform_device 挂到 platform 总线

② platform_driver_register(&spi_imx_driver)（驱动后到；本树用 module_platform_driver）
   → platform_match（OF：fsl,imx6ul-ecspi / fsl,imx51-ecspi）
   → spi_imx_probe
        ├─ 解析 fsl,spi-num-chipselects、cs-gpios
        ├─ 填 spi_bitbang 钩子（chipselect / txrx_bufs / setup）
        └─ spi_bitbang_start → spi_register_master
             → 出现 spi2，并 of_register_spi_devices
```

对应代码骨架：

```c
/* mach-imx6ul.c：设备侧 */
of_platform_populate(NULL, of_default_bus_match_table, NULL, NULL);

/* spi-imx.c：驱动侧 */
module_platform_driver(spi_imx_driver);
/* probe 内： */
master->dev.of_node = pdev->dev.of_node;
spi_imx->bitbang.txrx_bufs = spi_imx_transfer;
spi_bitbang_start(&spi_imx->bitbang);   /* 内调 spi_register_master */
```

### 3.3 右半：spi 侧 device ↔ driver

```text
of_register_spi_devices(master)
  → 遍历 &ecspi3 下 available 子节点
  → of_register_spi_device → spi_add_device → spi_device(spi2.0)

module_spi_driver(icm20608_driver)
  → spi_register_driver
  → spi_match_device（OF：alientek,icm20608）
  → spi_drv_probe → icm20608_probe
```

| 图2 元素 | 本板 |
|----------|------|
| platform bus 上的控制器驱动 | `spi_imx_driver` |
| 构造出的 `spi_master` | `spi2` |
| spi bus 上的 `spi_device` | `spi2.0` |
| spi bus 上的 `spi_driver` | `icm20608` |
| 应用节点 | `/dev/icm20608`（misc，**不是**必须走 spidev） |
| spidev | `/dev/spidev2.0`（需单独绑 `spidev` 兼容串；本板主路径不用） |

### 3.4 `of_platform_populate` → `platform_device(ecspi@02010000)` 详解

> 图2 左侧「设备从哪来」：本板**不手写** `platform_device_register`，而是由 **dtb → OF → `of_platform_populate`** 在启动早期自动建出 `platform_device`，再与 `spi_imx_driver` 在 platform 总线上匹配。  
> 源码：`drivers/of/platform.c`（4.1.15）；本板入口：`arch/arm/mach-imx/mach-imx6ul.c` → `imx6ul_init_machine`。

#### 3.4.1 一句话：它干什么？

**把设备树里「看起来像平台设备」的节点，变成挂在 platform 总线上的 `platform_device`。**

- 输入：已经 `unflatten` 好的 `device_node` 树（只有 OF 描述，还没有 Linux 设备对象）  
- 输出：一批 `platform_device`（如 `2010000.ecspi`）挂进 `platform_bus_type`  
- **不做**：不调用 `spi_imx_probe`，不创建 `spi_master` / `spi2.0`，不碰 ECSPI 寄存器  

#### 3.4.2 本板何时调用、四个参数

```c
/* arch/arm/mach-imx/mach-imx6ul.c */
static void __init imx6ul_init_machine(void)
{
	...
	of_platform_populate(NULL, of_default_bus_match_table, NULL, NULL);
	...
}
```

| 参数 | 本板取值 | 含义 |
|------|----------|------|
| `root` | `NULL` | 从设备树根 `/` 开始 |
| `matches` | `of_default_bus_match_table` | 哪些节点算「总线」、要**递归子节点**（见下） |
| `lookup` | `NULL` | 不用 auxdata 改名/塞 platform_data |
| `parent` | `NULL` | 顶层 pdev 挂在 platform 总线根上 |

`of_default_bus_match_table`（同文件）：

```c
{ .compatible = "simple-bus", },
{ .compatible = "simple-mfd", },
{ .compatible = "arm,amba-bus", },  /* 可选 */
{ }
```

本板路径上 `aips-bus` / `spba-bus` 都带 **`"simple-bus"`**，因此会递归进 `ecspi@02010000`。

时序：**populate 很早（init_machine）**；`spi_imx` 在 `module_platform_driver`（更晚）才注册 → **pdev 先到，驱动后到**。

#### 3.4.3 函数内部调用链（4.1.15）

```text
of_platform_populate(root=NULL, matches, lookup=NULL, parent=NULL)
  │
  ├─ root = of_find_node_by_path("/")     ← 拿到设备树根
  │
  └─ for_each_child_of_node(root, child)  ← 只扫根的直接孩子（如 soc）
        └─ of_platform_bus_create(child, matches, lookup, parent, strict=true)
              │
              ├─ [strict] 无 compatible → 跳过
              ├─ arm,primecell → 走 amba（本板 ECSPI 不走这条）
              │
              ├─ of_platform_device_create_pdata(bus, ...)
              │     ├─ !of_device_is_available(np) → 跳过（status=disabled）
              │     ├─ 已设 OF_POPULATED → 跳过（防重复）
              │     ├─ of_device_alloc(np)
              │     │     · 从 reg/interrupts 填 resource（MMIO、IRQ）
              │     │     · dev->dev.of_node = np
              │     │     · 设备名：of_device_make_bus_id → 如 2010000.ecspi
              │     ├─ bus = platform_bus_type
              │     └─ of_device_add(dev) → 挂入 platform 总线
              │           （若驱动已在，可能立刻 match/probe；本板此时驱动通常还没注册）
              │
              └─ if (dev 创建成功 && of_match_node(matches, bus))
                    │   ← 节点 compatible 含 simple-bus / simple-mfd 才递归
                    └─ for_each_child_of_node(bus, child)
                          of_platform_bus_create(child, ...)   ← 递归
```

关键判断（常被忽略）：

```c
dev = of_platform_device_create_pdata(...);
if (!dev || !of_match_node(matches, bus))
	return 0;   /* 不递归子节点 */

for_each_child_of_node(bus, child)
	of_platform_bus_create(child, ...);
```

| 节点类型 | 建 pdev？ | 递归子节点？ |
|----------|-----------|--------------|
| `simple-bus`（aips/spba） | 是（总线壳） | **是** |
| `ecspi@02010000`（控制器） | **是**（目标） | **否**（compatible 不是 simple-bus） |
| `icm20608@0`（SPI 从设备） | **否**（父不是总线递归目标时根本扫不到；即便扫到也不该当 platform 设备） | — |
| `status = "disabled"` | **否**（`of_device_is_available` 失败） | — |

因此：**`icm20608@0` 不会被 populate 建成 platform_device**；它留给 `spi_register_master` → `of_register_spi_devices`。

#### 3.4.4 本板递归路径（落到 ECSPI3）

```text
/ （根，populate 不给根自己建 pdev，只扫孩子）
 └─ soc
      └─ aips-bus@02000000          compatible 含 "simple-bus" → 建 pdev + 递归
           └─ spba-bus@02000000     同上
                └─ ecspi@02010000   compatible = "fsl,imx6ul-ecspi", ...
                     status = okay（板级 &ecspi3）
                     → of_device_alloc / of_device_add
                     → platform_device **2010000.ecspi**
                     → 非 simple-bus → **停止递归**
                          （子节点 icm20608@0 不在此处理）
```

对应 dtsi 骨架：

```dts
aips-bus@02000000 {
	compatible = "fsl,aips-bus", "simple-bus";
	spba-bus@02000000 {
		compatible = "fsl,spba-bus", "simple-bus";
		ecspi3: ecspi@02010000 {
			compatible = "fsl,imx6ul-ecspi", "fsl,imx51-ecspi";
			reg = <0x02010000 0x4000>;
			status = "disabled";   /* 板级 &ecspi3 改 okay */
		};
	};
};
```

#### 3.4.5 `of_device_alloc` 从节点填了什么

对 `ecspi@02010000`：

| OF 属性 | 填到 pdev 的什么 |
|---------|------------------|
| `reg = <0x02010000 0x4000>` | `resource`：MMIO 窗口（`spi_imx_probe` 再 ioremap） |
| `interrupts = <…>` | `resource`：IRQ |
| 节点指针 | `dev->dev.of_node`（后续读 `cs-gpios`、子节点靠它） |
| 自动命名 | 设备名 **`2010000.ecspi`**（地址 + 节点名习惯） |

**注意：** 此时还没有解析 `cs-gpios` / `pinctrl-0`；那些在更晚的 `spi_imx_probe` / `pinctrl_bind_pins` 里消费。

#### 3.4.6 和后面 SPI 链路的边界

```text
of_platform_populate          → 只有 platform_device(2010000.ecspi)
        ↓（驱动后注册）
platform_driver_register(spi_imx)
        ↓ match compatible
spi_imx_probe                 → 读 cs-gpios、注册 spi_master(spi2)
        ↓
of_register_spi_devices       → 子节点 icm20608@0 → spi_device(spi2.0)
        ↓
icm20608_probe                → /dev/icm20608
```

| 步骤 | 产物 | 谁负责 |
|------|------|--------|
| populate | `platform_device` | `of_platform_populate` |
| 控制器 probe | `spi_master` / `spi2` | `spi_imx_probe` |
| 从设备枚举 | `spi_device` / `spi2.0` | `of_register_spi_devices` |
| 芯片驱动 | `/dev/icm20608` | `icm20608_probe` |

#### 3.4.7 本板 dts 要点（populate 能看见控制器的前提）

| 项 | 作用 |
|----|------|
| dtsi `ecspi3: ecspi@02010000` | 有 `compatible` + `reg`；默认 `disabled` |
| `&ecspi3 { status = "okay"; … }` | `of_device_is_available` 通过，才会建 pdev |
| 祖先带 `simple-bus` | populate 能递归到该节点 |
| `disabled` `&uart2` / `&flexcan2` | 释放引脚（见 `17`）；与 populate 建 pdev 无直接关系，但影响后续 pinctrl |
| aliases `spi2 = &ecspi3` | 影响 **master 总线号**（更晚）；populate 本身不读 aliases |

`reg = <0x02010000>` 是控制器 **MMIO**，不是片选号。

#### 3.4.8 走读锚点

| 目的 | 搜什么 |
|------|--------|
| 入口 | `imx6ul_init_machine`、`of_platform_populate` |
| 递归规则 | `of_platform_bus_create`、`of_match_node(matches` |
| 建设备 | `of_platform_device_create_pdata`、`of_device_alloc`、`of_device_add` |
| 跳过 disabled | `of_device_is_available` |
| 本板结果 | `2010000.ecspi`；`/sys/bus/platform/devices/2010000.ecspi` |

#### 3.4.9 本章一句话

**`of_platform_populate` = 从 `/` 往下扫：有 compatible 且 available 的节点 → 建 `platform_device`；仅当该节点匹配 `simple-bus`（等）时才递归孩子。**  
对本板：递归穿过 aips/spba，建出 **`2010000.ecspi`**，然后停下；**`icm20608@0` 不在这里创建。**

---

## 四、图3：注册对称（master ↔ driver）

### 4.1 架构复述（按图）

```text
                    Bus (spi_bus_type)
                   /                  \
            【dev 链表】              【Drv 链表】
         （spi_device 等）          （spi_driver 等）
                ▲                        ▲
                │                        │
      spi_add_device /              spi_register_driver
      of_register_spi_device
                │                        │
┌───────────────┴────────┐    ┌──────────┴──────────────┐
│ SPI 总线驱动程序        │    │ SPI 设备驱动程序          │
│ 1. 分配 spi_master      │    │ 1. 填 spi_driver         │
│ 2. 设 bitbang/transfer  │    │ 2. .probe / of_match …   │
│ 3. spi_register_master  │    │ 3. spi_register_driver   │
└─────────────────────────┘    └─────────────────────────┘
                \                        /
                 \→ 互相遍历对方链表 ←/
                      │
            of_register_spi_devices 建 spi_device
            spi_match_device → .probe 绑定
```

**对称性：** 先注册 master（并建出 `spi2.0`）或先注册 `icm20608` 驱动都行；后到的一侧会扫另一侧并尝试匹配。

### 4.2 本板：总线驱动侧（左）

| 步骤 | 符号 | 说明 |
|------|------|------|
| 注册 platform 驱动 | `module_platform_driver(spi_imx_driver)` | `spi-imx.c` |
| probe | `spi_imx_probe` | 片选 GPIO、MMIO、clk、IRQ |
| 启动 master | `spi_bitbang_start` → `spi_register_master` | 得 `spi2` |
| 建从设备 | `of_register_spi_devices` | 得 `spi2.0` |

### 4.3 本板：设备驱动侧（右）

| 步骤 | 符号 | 说明 |
|------|------|------|
| 注册 | `module_spi_driver(icm20608_driver)` | `icm20608.c` |
| 匹配 | `spi_match_device` → OF `alientek,icm20608` | `spi.c` |
| probe | `spi_drv_probe` → `icm20608_probe` | WHO_AM_I + misc |

### 4.4 `spi_match_device`（4.1.15）

```text
1) of_driver_match_device     ← 本板主路径（alientek,icm20608）
2) acpi_driver_match_device   ← 本板无关
3) spi_match_id(id_table)     ← modalias / "icm20608"
4) strcmp(modalias, drv->name)
```

---

## 五、本板启动时序（三图合一）

```text
① U-Boot 加载 dtb（含 &ecspi3 okay + icm20608@0）
        ↓
② of_platform_populate → platform_device(ecspi@02010000)
        ↓
③ platform_driver_register(spi_imx)
     → spi_imx_probe
          · pinctrl_ecspi3（UART2 脚 → ECSPI3 + GPIO CS）
          · cs-gpios = GPIO1_IO20
          · spi_bitbang_start → spi_register_master → spi2
          · of_register_spi_devices → spi2.0
        ↓
④ module_spi_driver(icm20608)（可与③交错）
     → spi_match_device → icm20608_probe
          · spi_setup(Mode3)
          · WHO_AM_I == 0xAF
          · misc_register → /dev/icm20608 + sysfs
        ↓
⑤ 用户态：cat whoami / accel_z
```

成功信号：

```text
dmesg: spi_imx 2010000.ecspi: probed
dmesg: icm20608 ... WHO_AM_I=0xaf OK
ls /sys/bus/spi/devices/spi2.0/driver  → .../icm20608
ls /dev/icm20608
```

---

## 六、读数路径与 spidev

### 6.1 本板主路径（专用驱动 + misc）

```text
cat /sys/class/misc/icm20608/whoami
  → show_whoami → icm20608_read_onereg(0x75)
       → spi_write_then_read(tx={0xF5}, rx=1)
            → spi_sync → spi_imx 传输路径
                 → CS=GPIO1_IO20，Mode3，≤8MHz
```

`spi` 指针在 probe 里保存；此后所有传输走 **master `spi2` + CS0**。

### 6.2 图2 上的 spidev（通用字符设备）

可选路径：子节点 `compatible = "spidev"` → `/dev/spidev2.0`，用户态用 `spidev` ioctl 自己组帧。  
本板验收主路径是 **`icm20608` misc/sysfs**，不依赖 spidev。

---

## 七、文件与符号速查

### 7.1 按图分层

| 层 | 文件 | 关键符号 |
|----|------|----------|
| 设备驱动 | `drivers/char/icm20608.c` | `icm20608_driver`、`icm20608_probe`、`show_*` |
| 核心 | `drivers/spi/spi.c` | `spi_bus_type`、`spi_register_master`、`of_register_spi_*`、`spi_match_device`、`spi_sync` |
| 总线驱动 | `drivers/spi/spi-imx.c` | `spi_imx_probe`、`spi_imx_transfer`、`spi_imx_chipselect` |
| bitbang 胶水 | `drivers/spi/spi-bitbang.c` | `spi_bitbang_start` |
| 头文件 | `include/linux/spi/spi.h` | `spi_master` / `spi_device` / `spi_message` / `spi_transfer` |

### 7.2 建议走读顺序

1. `spi_imx_probe` → `spi_bitbang_start` → `spi_register_master`  
2. `of_register_spi_device`（`reg` / Mode / frequency）  
3. `spi_match_device` → `icm20608_probe`  
4. `spi_write_then_read` → `spi_imx_transfer`  

细节调用链见 **`18` §五/§六**。

---

## 八、一句话收束

**platform 上用 `spi_imx` 造出 `spi2`，spi 总线上用 dts 子节点造出 `spi2.0`，再用 `icm20608` 驱动 match/probe 出 `/dev/icm20608`；传输统一走 `spi_message`/`spi_transfer` → `spi_sync` → `spi_imx_transfer`。**
