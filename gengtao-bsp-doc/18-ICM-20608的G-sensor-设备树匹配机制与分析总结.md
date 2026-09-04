# 18 ICM-20608：设备树与内核匹配机制

> 文档编号：18  
> 日期：2026-09-04  
> 板卡：正点原子 ATK-MX6ULL（CORE V2.0 + ALPHA V2.4）  
> 器件：底板 **U6 ICM-20608**（ECSPI3，CS=GPIO1_IO20）  
> 关联：`04`（原理图）、`16`（落地顺序）、`17`（问题复盘）、`19`/`20`（SPI 架构与框架）  
> 素材：`imx6ull-14x14-evk-gengtao0901.dts` `&ecspi3`；`common/drivers/char/icm20608.c`；`drivers/spi/spi.c` / `spi-imx.c`（4.1.15）  
> 走读重点：**§二** `pinctrl_ecspi3: ecspi3grp` 与 PAD_CTL；**§三** 为何 `cs-gpios` 在 `&ecspi3`；**§六** 代码调用链；**§七** 深挖 `platform_driver_register`；落地见 **`16`**，踩坑见 **`17`**，框架见 **`19`/`20`**

---

## 目录

| 章 | 内容 |
|----|------|
| [一](#一一句话结论) | 一句话结论（两层匹配） |
| [二](#二本板-dts-字段对照) | 本板 dts 字段对照（含 **`label: nodename`**、PAD_CTL） |
| [三](#三为何-cs-gpios-写在-ecspi3-下而不是-icm206080) | **为何 `cs-gpios` 写在 `&ecspi3` 下** |
| [四](#四驱动侧匹配表icm20608c) | 驱动侧匹配表 |
| [五](#五匹配全过程按启动顺序) | 匹配全过程（概念步骤） |
| [六](#六代码调用链走读地图) | 代码调用链（走读地图） |
| [七](#七深挖platform_driver_registerspi_imx_driver) | 深挖 `platform_driver_register(&spi_imx_driver)` |
| [八](#八与屏--网的对照) | 与屏 / 网的对照 |
| [九](#九失败时按层回查) | 失败时按层回查 |
| [十](#十板上速查命令) | 板上速查命令 |
| [十一](#十一一句话) | 一句话收束 |

---

## 一、一句话结论

ICM-20608 在本板是 **两层匹配**：

```text
① 控制器：dtsi ecspi@02010000  ↔  spi_imx（platform）→ SPI 主控制器 spi2
② 从设备：dts  icm20608@0     ↔  icm20608（spi_driver）→ /dev/icm20608
```

键是 **`compatible` + `reg`（片选号）+ SPI 模式/频率**；本板设备名 **`spi2.0`**（aliases：`spi2 = &ecspi3`，见 `16`）。

---

## 二、本板 dts 字段对照

板级节点（`imx6ull-14x14-evk-gengtao0901.dts`）：

```dts
&flexcan2 { status = "disabled"; };   /* 释放 UART2_RTS/CTS */
&uart2    { status = "disabled"; };   /* 释放 UART2_TX/RX；调试用 UART1 */

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

| dts 项 | 作用 | 谁消费 |
|--------|------|--------|
| `&ecspi3` | 引用 dtsi `ecspi3: ecspi@02010000`，打开控制器 | `spi-imx` |
| `status = "okay"` | 覆盖 dtsi 默认 `disabled` | OF / 驱动 probe |
| `pinctrl-0 = <&pinctrl_ecspi3>` | 引用 label `pinctrl_ecspi3` → 节点 `ecspi3grp`；UART2 脚 → ECSPI3 + CS；行末为 PAD_CTL | pinctrl（控制器 probe 时） |
| `fsl,spi-num-chipselects` | 片选个数 | `spi_imx_probe` |
| **`cs-gpios`** | 软件片选 GPIO（**复数**属性名）；**必须在控制器节点** | `spi_imx_probe` → `of_get_named_gpio`（详解见 [§三](#三为何-cs-gpios-写在-ecspi3-下而不是-icm206080)） |
| 子节点 `icm20608@0` | 在该 master 下登记一个 **spi_device** | SPI 核心 `of_register_spi_devices` |
| `compatible` | 驱动匹配字符串 | `icm20608_of_match` |
| `reg = <0>` | **片选索引** → `spi->chip_select` | `of_register_spi_device` |
| `spi-cpol` / `spi-cpha` | Mode 3（CPOL=1,CPHA=1） | 同上 → `spi->mode` |
| `spi-max-frequency` | 最高时钟 8 MHz | 同上 → `spi->max_speed_hz` |

dtsi 中控制器骨架：

```dts
ecspi3: ecspi@02010000 {
	compatible = "fsl,imx6ul-ecspi", "fsl,imx51-ecspi";
	reg = <0x02010000 0x4000>;
	...
	status = "disabled";   /* 板级 &ecspi3 改成 okay */
};
```

aliases（决定总线号习惯）：

```dts
spi2 = &ecspi3;   /* 本板 Linux 设备常为 spi2.0 */
```

pinctrl：

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

#### `pinctrl_ecspi3: ecspi3grp` 写法含义

这是设备树常见的 **「标签 : 节点名」** 写法，两半含义不同：

```text
pinctrl_ecspi3 : ecspi3grp { ... }
       │              │
       │              └─ node name：OF 树里的节点名（习惯：功能 + grp）
       └─ label：编译后生成 phandle；用 &pinctrl_ecspi3 引用这一整组 pin
```

| 部分 | 角色 | 本板用法 |
|------|------|----------|
| **`pinctrl_ecspi3`** | **label（标签）** | 给别处引用：`pinctrl-0 = <&pinctrl_ecspi3>` |
| **`ecspi3grp`** | **node name（节点名）** | 出现在 OF / `/proc/device-tree`；`grp` 表示一组 pin 配置 |

补充说明：

1. **`ecspi3grp`** 只是节点名，表示「ECSPI3 的一组引脚」（MISO/MOSI/SCLK/CS）。i.MX 板级 dts 常用 `xxxgrp`，**无特殊内核语义**；换名也可以，只要引用方一致。  
2. **`pinctrl_ecspi3`** 是标签，不是属性名。`&ecspi3` 里 `pinctrl-0 = <&pinctrl_ecspi3>` 靠它找到这组 `fsl,pins`；控制器 probe 时 `pinctrl_bind_pins` 按 phandle 落地到 IOMUXC。  
3. 本板定义位置：`&iomuxc` → `imx6ul-evk { ... }` 内；使用位置：`&ecspi3` 的 `pinctrl-0`。

与引用如何串起来：

```dts
/* 定义（在 &iomuxc / imx6ul-evk 下） */
pinctrl_ecspi3: ecspi3grp {
	fsl,pins = < ... >;
};

/* 使用（在控制器节点） */
&ecspi3 {
	pinctrl-names = "default";
	pinctrl-0 = <&pinctrl_ecspi3>;   /* 引用上面的 label */
	status = "okay";
};
```

```text
&ecspi3 要脚
    → pinctrl-0 指向 &pinctrl_ecspi3（label → phandle）
        → 落到节点 ecspi3grp
            → 四行 fsl,pins：UART2 脚复用成 ECSPI3 + GPIO CS
```

**一句话：** `pinctrl_ecspi3` 是给 `&` 引用的标签；`ecspi3grp` 是这组引脚配置节点的名字；合在一起表示「名为 `ecspi3grp` 的 pinctrl 组，标签叫 `pinctrl_ecspi3`」。

##### 如果没有标签呢？

可以，但 **引用方式会变难**。设备树语法允许只写节点名、不写 label：

```dts
/* 仅节点名，无 label */
ecspi3grp {
	fsl,pins = < ... >;
};
```

此时：

| 点 | 说明 |
|----|------|
| 节点本身 | 仍然合法；`fsl,pins` 仍会进 dtb |
| **`&pinctrl_ecspi3`** | **不可用**（没有这个 label） |
| 如何引用 | 不能再用简洁的 `&标签`，通常要改成 **完整路径 phandle**，或给节点补上 label |

示例（示意：用路径引用，可读性差，板级 dts 很少这么写）：

```dts
&ecspi3 {
	/* 无 label 时，不能写 &pinctrl_ecspi3 */
	pinctrl-0 = <&{/soc/aips-bus@02000000/.../iomuxc@.../imx6ul-evk/ecspi3grp}>;
};
```

因此本板（以及几乎所有 i.MX 例程）都用 **`label: nodename`**：

- **有 label**：`pinctrl-0 = <&pinctrl_ecspi3>` —— 短、稳、可跨文件引用  
- **无 label**：节点还在，但 `&` 快捷引用没了，维护成本高  

注意：没有 label **不等于**可以省略整个 pinctrl 节点；`&ecspi3` 仍必须通过某种 phandle 指到含 `fsl,pins` 的那组配置，否则脚复用不会生效。

#### `fsl,pins` 行末 `0x100b1` / `0x100b0` 是什么？

每一行是：**宏名 = 选哪颗 pad、复用到哪个功能**；**行末十六进制 = PAD_CTL（SW_PAD_CTL 电气参数）**，不是 ALT 编号。

```text
MX6UL_PAD_UART2_RTS_B__ECSPI3_MISO   0x100b1
│                                    │
│                                    └─ CONFIG：写入 IOMUXC SW_PAD_CTL
│                                       （驱动强度、上下拉、速度、边沿等）
└─ PIN_FUNC_ID：展开为 mux/conf/input 寄存器偏移 + mux_mode
   （本例：UART2_RTS 脚 → ALT 到 ECSPI3_MISO）
```

与屏（`09` 的 `0x79`）、网（`10` 的 `0x4001B009`）同类：都是 **整寄存器 PAD_CTL 值**。本处 **无** 高位 `0x40000000`（`IMX_PAD_SION`），SPI 这几脚一般不需要 SION。

**`0x100b1` 按位（i.MX6UL / 内核 `fsl,imx6ul-pinctrl` 绑定）：**

`0x100b1 = 0x10000 | 0xB1`

| 位域 | 值 | 含义 |
|------|-----|------|
| HYS `[16]` | 1 | 输入迟滞开（Schmitt） |
| PUS / PUE / PKE `[15:12]` | 0 | **未开**上下拉 / keeper |
| ODE `[11]` | 0 | 非开漏 |
| SPEED `[7:6]` | `10b` | 中速 |
| DSE `[5:3]` | `110b`（6） | 驱动约 **43Ω** |
| SRE `[0]` | 1 | **快**边沿（Fast） |

口语：开迟滞、中速、较强驱动、快边沿、无上下拉 —— 适合 **SCLK / MOSI / MISO**。

**与 `0x100b0` 的差别（仅 bit0）：**

| CONFIG | SRE | 本板用途 |
|--------|-----|----------|
| `0x100b1` | 快 | MISO / MOSI / SCLK |
| `0x100b0` | 慢 | CS（GPIO1_IO20） |

细位域以 **i.MX6ULL RM → IOMUXC → SW_PAD_CTL_PAD_xxx** 为准；内核说明见 `Documentation/devicetree/bindings/pinctrl/fsl,imx6ul-pinctrl.txt`。

**前提（匹配之前）：** 必须 `disabled` 掉占用同脚的 `&uart2` / `&flexcan2`（见 `17` 问题 1）。

---

## 三、为何 `cs-gpios` 写在 `&ecspi3` 下，而不是 `icm20608@0`

> 问题：本板写法是  
> `cs-gpios = <&gpio1 20 GPIO_ACTIVE_LOW>;`  
> 为何挂在 **控制器** `&ecspi3`，而不是从设备子节点 `icm20608@0`？

### 3.1 一句话结论

**`cs-gpios` 描述的是「这条 SPI 主机有几根片选、每根接到哪个 GPIO」**，属于 **master（控制器）资源**；  
子节点 `icm20608@0` 只通过 **`reg = <0>`** 声明「我用第 0 号片选」。  
二者分工不同，所以 `cs-gpios` **必须**写在 `&ecspi3` 下。

### 3.2 设备树分层：谁管什么

```text
&ecspi3 {                          ← spi_master / 控制器节点
    fsl,spi-num-chipselects = <1>; ← 本总线有几个 CS 槽位
    cs-gpios = <&gpio1 20 ...>;    ← CS[0]、CS[1]… 各自绑哪个 GPIO
    pinctrl-0 = <&pinctrl_ecspi3>; ← 主机脚（含 CS 的 pad 复用）

    icm20608@0 {                   ← spi_device / 从设备节点
        compatible = "...";
        reg = <0>;                 ← 只用「片选索引」= 0，不是 GPIO 号
        spi-cpol; spi-cpha; ...    ← 该从设备的传输模式 / 频率
    };
};
```

| 属性位置 | 语义 | 消费者 |
|----------|------|--------|
| `&ecspi3` 的 **`cs-gpios`** | 主机侧片选线表 | `spi_imx_probe` |
| `&ecspi3` 的 `fsl,spi-num-chipselects` | 表有多长 | 同上 |
| `icm20608@0` 的 **`reg`** | 选用表中第几个 CS | `of_register_spi_device` → `spi->chip_select` |
| `icm20608@0` 的 `spi-cpol` / `cpha` / `spi-max-frequency` | 该从设备传输参数 | 同上 → `spi->mode` / `max_speed_hz` |

一根总线上可以挂多个从设备（CS0、CS1…），片选 GPIO 表只应在控制器上出现 **一次**；每个从设备只报自己的索引。

硬件语义也一致：CS 是挂在这条 SPI **控制器**上的主机侧信号，不是「传感器驱动私有属性」。

### 3.3 内核：谁读 `cs-gpios`（必须在控制器 of_node）

`spi_imx_probe` 里的 `np` 是 **platform 设备的 of_node**，即 **`ecspi@02010000` / `&ecspi3`**，**不是**子节点：

```c
/* drivers/spi/spi-imx.c — spi_imx_probe */
struct device_node *np = pdev->dev.of_node;   /* ← &ecspi3 */

ret = of_property_read_u32(np, "fsl,spi-num-chipselects", &num_cs);
...
for (i = 0; i < master->num_chipselect; i++) {
	int cs_gpio = of_get_named_gpio(np, "cs-gpios", i);
	...
	spi_imx->chipselect[i] = cs_gpio;
	ret = devm_gpio_request(&pdev->dev, spi_imx->chipselect[i], DRIVER_NAME);
	...
}
```

要点：

1. 读的是 **控制器节点** 上的 `cs-gpios`（属性名必须是 **复数** `cs-gpios`）  
2. 结果放进主机私有数组 **`spi_imx->chipselect[]`**  
3. 若写到 `icm20608@0` 下，这里 **根本读不到** → 常见 `can't get cs gpios` / CS 无效  

真正拉脚时，用的是从设备的 **索引**，不是子节点上的 GPIO 属性：

```c
/* drivers/spi/spi-imx.c — spi_imx_chipselect */
static void spi_imx_chipselect(struct spi_device *spi, int is_active)
{
	struct spi_imx_data *spi_imx = spi_master_get_devdata(spi->master);
	int gpio = spi_imx->chipselect[spi->chip_select];
	...
	gpio_set_value(gpio, ...);
}
```

本板对应关系：

```text
dts:  cs-gpios = <&gpio1 20 GPIO_ACTIVE_LOW>;  →  chipselect[0] = GPIO1_IO20
dts:  icm20608@0 { reg = <0>; }                →  spi->chip_select = 0
传输时: chipselect[spi->chip_select]           →  拉 GPIO1_IO20
```

### 3.4 内核：子节点解析了什么（没有 `cs-gpios`）

`of_register_spi_device()` 遍历的是 **子节点** `nc`，只填从设备协议相关字段：

```c
/* drivers/spi/spi.c — of_register_spi_device(master, nc) */
of_property_read_u32(nc, "reg", &value);
spi->chip_select = value;                 /* 片选索引 */

if (of_find_property(nc, "spi-cpha", NULL))
	spi->mode |= SPI_CPHA;
if (of_find_property(nc, "spi-cpol", NULL))
	spi->mode |= SPI_CPOL;
/* spi-max-frequency → max_speed_hz */
/* compatible → of_modalias → modalias */
```

子节点侧 **不会** 去读 `cs-gpios`。把片选 GPIO 写进 `icm20608@0`，对 4.1.15 这条路径是 **无效属性**（OF 树里可能还在，但无人消费）。

### 3.5 启动时间线：为何必须先在控制器上备好

```text
① spi_imx_probe（&ecspi3）
     读 cs-gpios → 填 chipselect[]、申请 GPIO
     → spi_bitbang_start → spi_register_master
     → of_register_spi_devices

② of_register_spi_device（icm20608@0）
     只设 chip_select=0、mode、频率 → 得到 spi2.0

③ 之后任意传输（WHO_AM_I / accel_z …）
     spi_imx_chipselect 用 chipselect[0] 拉脚
```

片选硬件能力是 **造 master 时** 就要齐的；从设备节点只是「订购」某一个 CS 槽位。  
这也解释了：`pinctrl` 里把 UART2_TX 配成 `GPIO1_IO20` 与 `cs-gpios` 指向同一脚，二者都挂在 **控制器侧**（一个管 pad 复用，一个管运行时拉高拉低）。

### 3.6 若误写到 `icm20608@0` 下会怎样

```dts
&ecspi3 {
	/* 没有 cs-gpios */
	icm20608@0 {
		cs-gpios = <&gpio1 20 GPIO_ACTIVE_LOW>;  /* 错误位置 */
		reg = <0>;
		...
	};
};
```

| 结果 | 原因 |
|------|------|
| `spi_imx` 报 `can't get cs gpios`，或 CS 无效 | probe 只看控制器节点 |
| 子节点上的 `cs-gpios` 被忽略 | `of_register_spi_device` 不解析它 |
| WHO_AM_I 读不对 / 总线无应答 | 片选没按预期动作 |

同类易错：属性名写成 **`cs-gpio`（单数）** —— 即便写在 `&ecspi3` 下，`of_get_named_gpio(np, "cs-gpios", i)` 同样失败（见 `17`）。

### 3.7 本章收束

```text
cs-gpios  = ECSPI 主机驱动在 spi_imx_probe 里从「控制器 of_node」读的片选线表
reg=<0>  = 从设备选用表下标 0 → spi2.0 → 传输时拉 chipselect[0]=GPIO1_IO20
```

**写在 `&ecspi3`：正确且唯一有效位置（对本板 `spi-imx`）。写在 `icm20608@0`：设备树语义与内核消费点都不匹配。**

---

## 四、驱动侧匹配表（`icm20608.c`）

```c
static const struct of_device_id icm20608_of_match[] = {
	{ .compatible = "alientek,icm20608", },
	{ }
};

static const struct spi_device_id icm20608_id[] = {
	{ "icm20608", 0 },
	{ }
};

static struct spi_driver icm20608_driver = {
	.driver = {
		.name           = "icm20608",
		.of_match_table = of_match_ptr(icm20608_of_match),
	},
	.id_table = icm20608_id,
	.probe    = icm20608_probe,
	.remove   = icm20608_remove,
};
module_spi_driver(icm20608_driver);
```

| 表 | 匹配什么 | 本板 dts 对应 |
|----|----------|----------------|
| **`of_match_table`** | `compatible` 全串 **`alientek,icm20608`** | 子节点唯一项（OF 主路径） |
| **`id_table`** | `spi->modalias` / 名字 **`icm20608`** | OF 去厂商前缀后的 modalias 兜底 |

`spi_drv_probe` **不强制** `id_table`，本驱动仍双备 OF + id，便于稳健。

---

## 五、匹配全过程（按启动顺序）

### 5.1 总览

```text
U-Boot 加载 dtb
        ↓
① platform：ecspi@02010000 匹配 spi-imx
   → 选 pinctrl_ecspi3、解析 cs-gpios、注册 spi_master
   → 本板总线号对应 aliases → spi2
        ↓
② of_register_spi_devices(master)
   → 遍历 &ecspi3 下 available 子节点
   → icm20608@0：reg=0、compatible、cpol/cpha、max-frequency
   → 创建 spi_device → 设备名 spi2.0
        ↓
③ 总线匹配 spi_match_device
   → 优先 of_driver_match_device（alientek,icm20608）
   → 否则 id_table / modalias
        ↓
④ spi_drv_probe → icm20608_probe
   → spi_setup(Mode3) → 复位/读 WHO_AM_I=0xAF → 开 accel/gyro
   → misc_register → /dev/icm20608 + sysfs
        ↓
⑤ 用户态：cat whoami / accel_z
```

第二层是 **`spi_device`**；子节点 **`reg` 表示片选索引**（本板为 0 → `spi2.0`）。

函数级细节见 [§六](#六代码调用链走读地图)。

### 5.2 Step 1 — 控制器起来（ECSPI3 → `spi2`）

| 条件 | 说明 |
|------|------|
| `CONFIG_SPI` + `CONFIG_SPI_IMX` | 框架 + 控制器驱动 |
| `&ecspi3 { status=okay; pinctrl-0=...; cs-gpios=... }` | 节点可用 + 脚 + 片选 |
| dtsi `compatible = "fsl,imx6ul-ecspi", "fsl,imx51-ecspi"` | 匹配 `spi-imx`（表含两项） |

成功信号（L1/L2）：

```text
spi_imx 2010000.ecspi: probed
ls /sys/bus/spi/devices/   → spi2.0（绑驱动前也可能已有设备节点）
```

`reg = <0x02010000>` 只描述控制器 MMIO，**不是**片选 0。

### 5.3 Step 2 — 子节点变成 `spi_device`

SPI 核心在 `spi_register_master` 末尾：

```text
of_register_spi_devices(master)
  for_each_available_child_of_node(master->dev.of_node, nc)
      of_register_spi_device(master, nc)
```

对 `icm20608@0`（`drivers/spi/spi.c`）：

| 属性 | 结果 |
|------|------|
| `reg` | `spi->chip_select = 0` |
| `compatible` | `of_modalias_node` → 常见 modalias **`icm20608`** |
| `spi-cpol` / `spi-cpha` | `spi->mode \|= SPI_CPOL \| SPI_CPHA`（Mode3） |
| `spi-max-frequency` | `spi->max_speed_hz = 8000000` |
| 挂在哪个 master | 决定是 `spi2.0` 还是其它 `spiX.0` |

板上核对：

```bash
find /proc/device-tree -name 'icm20608@0'
# .../ecspi@02010000/icm20608@0

ls /sys/bus/spi/devices/
# spi2.0

readlink /sys/bus/spi/devices/spi2.0/of_node
# .../ecspi@02010000/icm20608@0
```

`@0` 只是节点名习惯；**真正片选以 `reg` 为准**。

### 5.4 Step 3 — `spi_match_device`：谁绑谁

```text
spi_match_device(dev, drv):
  1) of_driver_match_device  → 对 of_match_table（alientek,icm20608）  ← 本板主路径
  2) ACPI（本板无关）
  3) spi_match_id(id_table) → modalias / 名字 "icm20608"
  4) 名字与 drv->name 比较（兜底）
```

本板：步骤 1 即成功 → 驱动与 `spi2.0` 绑定。

### 5.5 Step 4 — `icm20608_probe`

框架侧：

```c
/* spi.c：spi_drv_probe */
ret = sdrv->probe(to_spi_device(dev));
```

驱动侧：

```text
icm20608_probe(spi)
  → spi->mode |= SPI_MODE_3；spi_setup(spi)
  → icm20608_init_hw：
       写 PWR_MGMT_1 复位 → 读 WHO_AM_I 期望 0xAF
       → 开 accel/gyro、配量程/采样
  → misc_register → /dev/icm20608 + sysfs
  → dmesg：WHO_AM_I=0xaf OK；probe OK
```

判据：

```bash
dmesg | grep -i icm20608
ls -l /dev/icm20608
ls -l /sys/bus/spi/devices/spi2.0/driver   # → .../icm20608
```

### 5.6 Step 5 — 用户态读数（匹配之后）

```text
cat /sys/class/misc/icm20608/whoami
  → show_whoami → spi_write_then_read(addr|0x80, ...)
cat .../accel_z
  → show_sensor_field → 读 0x3B 起 14 字节 → 解析 az
```

`spi` 指针在 probe 里保存；此后传输走 **master `spi2` + CS0（GPIO1_IO20）**。

---

## 六、代码调用链（走读地图）

> 对应上文「五、总览」①～⑤；内核路径以 `linux-imx6ull-kernel-code/` 为根。  
> 驱动源文件在 overlay：`linux-kernel-overlay/common/drivers/char/icm20608.c`（apply 后等同 `drivers/char/icm20608.c`）。  
> 行号随版本可能微调，**以函数名为准**。

两层绑定：

```text
platform 总线：ecspi@02010000  ↔  spi_imx
spi      总线：spi2.0           ↔  icm20608
```

### 6.0 函数 ↔ `*.c` 文件速查

| `*.c` 文件 | 本链路要看的函数 / 符号 | 对应步骤 |
|------------|-------------------------|----------|
| `drivers/spi/spi-imx.c` | `spi_imx_driver`、`spi_imx_dt_ids[]`、`spi_imx_probe`、`spi_imx_transfer` | ①⑤ |
| `drivers/spi/spi.c` | `spi_register_master`、`of_register_spi_devices`、`of_register_spi_device`、`spi_match_device`、`spi_drv_probe`、`spi_register_driver`、`spi_write_then_read` / `spi_sync` | ①～⑤ |
| `drivers/char/icm20608.c` | `icm20608_driver`、`icm20608_of_match[]`、`icm20608_id[]`、`icm20608_probe`、`icm20608_init_hw`、`icm20608_read_regs` / `write_reg`、`show_*` | ③④⑤ |
| `drivers/of/base.c` | `of_modalias_node` | ② |
| `drivers/of/device.c` | `of_match_device` | ①③ |
| `drivers/base/dd.c` | `really_probe` | ①④ |
| `drivers/base/pinctrl.c` | `pinctrl_bind_pins` | ① |
| `drivers/char/misc.c` | `misc_register` | ④ |

头文件：

| 头文件 | 符号 |
|--------|------|
| `include/linux/spi/spi.h` | `module_spi_driver`、`spi_register_driver` |
| `include/linux/icm20608.h` | `ICM20608_GET_DATA` / `GET_WHOAMI` |

### 6.1 总调用图（对照总览 ①～⑤）

```text
① 控制器
of_platform_populate → platform_device(ecspi@02010000)
  compatible: "fsl,imx6ul-ecspi","fsl,imx51-ecspi"
        ↓
platform_driver_register(&spi_imx_driver)
  → really_probe()
       ├─ pinctrl_bind_pins()              ← 消费 pinctrl-0=&pinctrl_ecspi3
       └─ spi_imx_probe(pdev)              drivers/spi/spi-imx.c
            ├─ of_match_device(spi_imx_dt_ids)
            ├─ of_property_read_u32(..., "fsl,spi-num-chipselects")
            ├─ of_get_named_gpio(..., "cs-gpios", i)  ← 必须复数属性名
            ├─ ioremap / clk / irq
            ├─ spi_bitbang 钩子（txrx_bufs 等）
            └─ spi_register_master / spi_bitbang_start
                 → of_register_spi_devices(master)   ← 进入②
                 → dmesg: spi_imx 2010000.ecspi: probed

② 从设备
of_register_spi_devices(master)
  for_each_available_child_of_node(...)
    └─ of_register_spi_device(master, nc)
         ├─ of_modalias_node()             → modalias≈"icm20608"
         ├─ of_property_read_u32("reg")    → chip_select=0
         ├─ spi-cpol / spi-cpha            → mode |= CPOL|CPHA
         ├─ spi-max-frequency              → max_speed_hz=8e6
         └─ spi_add_device → 设备名 "spi2.0"  ← 可立刻进③④

③ 匹配（驱动侧，可先可后）
module_spi_driver(icm20608_driver)
  → spi_register_driver
       → driver_register → 对已有 spi_device 再匹配

spi_bus_type.match = spi_match_device
  1) of_driver_match_device → alientek,icm20608   ← 本板主路径
  2) ACPI（跳过）
  3) spi_match_id / 名字兜底

④ probe
really_probe → spi_drv_probe
  → icm20608_probe(spi)
       → spi_setup
       → icm20608_init_hw：复位 + WHO_AM_I + 开传感器
            → spi_write / spi_write_then_read → spi_imx 传输路径
       → misc_register → /dev/icm20608 + sysfs

⑤ 用户态
cat .../whoami → show_whoami → icm20608_read_onereg → spi_write_then_read
cat .../accel_z → show_sensor_field → 读 0x3B 块 → 解析
```

### 6.2 分文件函数表（按走读顺序）

#### A. 驱动模块入口

| 顺序 | 文件 | 函数 / 符号 | 作用 |
|------|------|-------------|------|
| A1 | `icm20608.c` | `module_spi_driver(icm20608_driver)` | `module_init` → `spi_register_driver` |
| A2 | `include/linux/spi/spi.h` | `module_spi_driver` | 宏展开 |
| A3 | `spi.c` | `spi_register_driver` | `driver.bus = &spi_bus_type`；包装 `spi_drv_probe` |
| A4 | `icm20608.c` | `icm20608_driver` / `of_match` / `id` | 匹配表 + `probe` |

#### B. 控制器：`spi-imx` → master `spi2`

| 顺序 | 文件 | 函数 | 作用 |
|------|------|------|------|
| B1 | dtsi `ecspi3@02010000` | — | `compatible = "fsl,imx6ul-ecspi", "fsl,imx51-ecspi"` |
| B2 | 板级 dts `&ecspi3` | — | `status=okay`、pinctrl、`cs-gpios`、子节点 |
| B3 | `spi-imx.c` | `spi_imx_dt_ids[]` | 含 `fsl,imx6ul-ecspi` / `fsl,imx51-ecspi` |
| B4 | `spi-imx.c` | `spi_imx_probe` | 片选 GPIO、MMIO、clk、IRQ、bitbang |
| B5 | 同上 | `spi_register_master` 相关 | 注册 master；触发 `of_register_spi_devices` |

pinctrl：`really_probe` → `pinctrl_bind_pins` 消费 `&ecspi3` 的 `pinctrl-0`。

#### C. 从设备：dts 子节点 → `spi_device`

| 顺序 | 文件 | 函数 | 作用 |
|------|------|------|------|
| C1 | `spi.c` | `of_register_spi_devices` | `for_each_available_child` |
| C2 | 同上 | `of_register_spi_device` | 解析 `icm20608@0` |
| C3 | `of/base.c` | `of_modalias_node` | `"alientek,icm20608"` → modalias **`icm20608`** |
| C4 | `of_register_spi_device` | 读 `reg` / mode / frequency | **chip_select=0**，Mode3，8MHz |
| C5 | `spi.c` | `spi_add_device` 等 | 设备名 **`spi2.0`** |

#### D. 匹配 + 框架 probe

| 顺序 | 文件 | 函数 | 作用 |
|------|------|------|------|
| D1 | `spi.c` | `spi_match_device` | 总线 `.match` |
| D2 | OF 核心 | `of_driver_match_device` | 命中 **`alientek,icm20608`** |
| D3 | `spi.c` | `spi_drv_probe` | 调驱动 `probe` |
| D4 | `icm20608.c` | `icm20608_probe` | 见下节 |

#### E. `icm20608_probe` 内部

| 顺序 | 文件 | 函数 | 作用 |
|------|------|------|------|
| E1 | `icm20608.c` | `spi_setup` | 确认 Mode3 / 8bit |
| E2 | 同上 | `icm20608_init_hw` | 复位、WHO_AM_I、量程 |
| E3 | 同上 | `icm20608_write_reg` / `read_regs` | SPI 全双工协议（读地址 `|0x80`） |
| E4 | `misc.c` | `misc_register` | **`/dev/icm20608`** + sysfs groups |

### 6.3 读数路径（sysfs / ioctl）

```text
cat /sys/class/misc/icm20608/whoami
  → show_whoami
       → icm20608_read_onereg(0x75)
            → spi_write_then_read(tx={0xF5}, rx=1)
                 → spi_sync → spi_imx bitbang/transfer

cat .../accel_z
  → show_sensor_field
       → icm20608_read_sensor（0x3B 起 14 字节）
            → 同上 SPI 路径

ioctl(ICM20608_GET_DATA) → icm20608_ioctl → icm20608_read_sensor → 同上
```

### 6.4 IDE 走读锚点

| 目的 | 搜什么 / 下断点 |
|------|-----------------|
| ① 控制器 | `spi_imx_probe`、`cs-gpios`、`spi_imx ... probed` |
| ② 子节点 | `of_register_spi_device`、`of_modalias_node` |
| ③ 匹配 | `spi_match_device`、`of_match_device` |
| ④ 进驱动 | `spi_drv_probe`、`icm20608_probe`、`icm20608_init_hw` |
| ④ 出节点 | `misc_register` |
| ⑤ 读数 | `show_whoami`、`icm20608_read_regs`、`spi_write_then_read` |

### 6.5 dts 字段 ↔ 代码落点

| dts | 落到代码的位置 |
|-----|----------------|
| `&ecspi3` / `ecspi@02010000` | `spi_imx_probe` 的 `pdev`；master 的 of_node |
| `status = "okay"` | OF 创建 platform 设备；子节点 available |
| `fsl,spi-num-chipselects` | `spi_imx_probe` → `num_cs` |
| **`cs-gpios`** | `of_get_named_gpio(np, "cs-gpios", i)`；写成 `cs-gpio` 会失败 |
| `pinctrl-0 = <&pinctrl_ecspi3>` | `really_probe` → `pinctrl_bind_pins` |
| `compatible = "alientek,icm20608"` | `of_match_device` ↔ `icm20608_of_match`；modalias 去前缀 |
| `reg = <0>` | `spi->chip_select = 0` → 设备名 `spi2.0` |
| `spi-cpol` / `spi-cpha` | `spi->mode \|= SPI_CPOL\|SPI_CPHA` |
| `spi-max-frequency` | `spi->max_speed_hz` |

---

## 七、深挖：`platform_driver_register(&spi_imx_driver)`

> 对应 §六 总调用图 **①**；本行**不是立刻操作 ECSPI 寄存器**，而是：把 `spi-imx` 挂到 **platform 总线**，再对**已有** platform 设备做一轮 match；命中 `ecspi@02010000` 后才进 `spi_imx_probe`。

### 7.1 入口

```c
/* drivers/spi/spi-imx.c（结构示意） */
static struct platform_driver spi_imx_driver = {
	.probe = spi_imx_probe,
	.driver = {
		.name = "spi_imx",
		.of_match_table = spi_imx_dt_ids,  /* 含 fsl,imx6ul-ecspi 等 */
	},
};
/* init 时 platform_driver_register(&spi_imx_driver) */
```

### 7.2 总览

```text
platform_driver_register(&spi_imx_driver)
        │
        ▼
A. 包装成通用 device_driver，挂到 platform 总线
   （driver.probe = platform_drv_probe → 稍后才调 spi_imx_probe）
        │
        ▼
B. driver_register → bus_add_driver → driver_attach
        │
        ▼
C. 遍历已有 platform_device：platform_match
     → of_driver_match_device（本板主路径）
        │ 命中 ecspi@02010000
        ▼
D. really_probe
     1) pinctrl_bind_pins   ← 选 pinctrl_ecspi3
     2) platform_drv_probe → spi_imx_probe(pdev)
        （cs-gpios / ioremap / 注册 master / of_register_spi_devices）
```

对本板 OF 匹配：

```text
设备：ecspi@02010000
  compatible = "fsl,imx6ul-ecspi", "fsl,imx51-ecspi"

驱动：spi_imx_dt_ids[]
  有 "fsl,imx6ul-ecspi"、"fsl,imx51-ecspi"

of_match_device：第一项或第二项均可命中 ✓
```

### 7.3 一句话抓住本质

```text
这一行 = 「把 spi-imx 挂到 platform 总线」+「对已有 platform 设备做一轮 OF 匹配」
命中 ecspi@02010000 后：pinctrl → platform_drv_probe → spi_imx_probe
在此之前：不碰 ECSPI 寄存器，也不创建 spi2.0
```

---

## 八、与屏 / 网的对照

| 维度 | 屏 `09` | 网 `10` | **六轴本文** |
|------|---------|---------|--------------|
| 总线类型 | platform（lcdif） | platform（fec） | platform + **SPI device** |
| 控制器匹配 | lcdif compatible | fec compatible | **`fsl,imx6ul-ecspi`** |
| 从设备匹配 | — | PHY | **`alientek,icm20608`** |
| `reg` 含义 | MMIO | MMIO / PHY 站号 | **片选索引 0** |
| pinctrl | lcdif | enet | **`pinctrl_ecspi3` + cs-gpios** |
| 用户接口 | `/dev/fb0` | `eth0` | **`/dev/icm20608`** |
| 本板设备名 | — | — | **`spi2.0`** |

通用方法不变：**原理图 → dts 节点 → 驱动 of_match → probe → 用户态验证**。

---

## 九、失败时按层回查

| 现象 | 卡在哪一步 | 先查 |
|------|------------|------|
| 无 `spi_imx ... probed`、无 spi 设备 | Step 1 | `SPI`/`SPI_IMX`、`&ecspi3 status`、pinctrl、uart2/flexcan2 冲突 |
| 有 probed，但 `devices/` 空 | Step 2 | 子节点是否 available、dtb 是否更新 |
| 有 `spi2.0`，driver 为空 | Step 3～4 | 驱动未编进、`compatible`、只更了 dtb |
| `WHO_AM_I` 非 `0xAF` / init failed | Step 4 读写 | Mode3、`cs-gpios`、供电、接线 |
| `can't get cs gpios` | Step 1 片选 | 属性名是否写成 **`cs-gpio`（单数）** |
| L0 时 devices 空 | — | **正常**（见 `17`）；先确认 `spi_imx` 驱动目录存在 |

---

## 十、板上速查命令

```bash
# 设备树是否挂在 ECSPI3 下
find /proc/device-tree -name 'icm20608@0'
ls /proc/device-tree/soc/aips-bus@02000000/spba-bus@02000000/ecspi@02010000/

# spi_device / 驱动绑定
ls -l /sys/bus/spi/devices/spi2.0/driver
# 期望 → .../drivers/icm20608

readlink /sys/bus/spi/devices/spi2.0/of_node
# 期望含 ecspi@02010000/icm20608@0

# 匹配结果
dmesg | grep -iE 'ecspi|spi_imx|icm20608'
ls -l /dev/icm20608
cat /sys/class/misc/icm20608/whoami
cat /sys/class/misc/icm20608/accel_z
```

---

## 十一、一句话

**`&ecspi3` 打开控制器并配好 pinctrl/`cs-gpios` → 子节点 `icm20608@0` 用 `reg`/`compatible`/Mode3 建成 `spi2.0` → `of_match` 命中 `alientek,icm20608` 进入 `icm20608_probe` → 校验 WHO_AM_I=0xAF 后 misc 出 `/dev/icm20608`。**
