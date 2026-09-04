# 17 ICM-20608 G-sensor 打通-问题复盘

> 文档编号：17  
> 日期：2026-09-04  
> 板卡：正点原子 ATK-MX6ULL（CORE V2.0 + ALPHA V2.4）  
> 器件：底板 **U6 ICM-20608**（3 轴加速度 + 3 轴陀螺仪）  
> 关联：`04`（原理图）、`16`（分析与落地顺序）、`18`（匹配机制与**代码调用链**）、`19`/`20`（SPI 架构与框架）、`origin/IMX6`（出厂 dts 片段）  
> 结果：✅ `/dev/icm20608`；`spi2.0` 已绑驱动；`WHO_AM_I=0xAF`；sysfs 可读 accel/gyro/temp（L4 平放基线已过；倾斜/转动可继续补记；L5 中断未做）

---

## 一、目标与软件链

```text
用户态：cat sysfs / ioctl
      ↑
/dev/icm20608（misc）+ accel_*/gyro_*/temp/whoami
      ↑
drivers/char/icm20608.c（CONFIG_ICM20608）
      ↑
dts：&ecspi3 → icm20608@0（reg=<0>，Mode3，cs-gpios）
      ↑
硬件：ECSPI3_SCLK/MOSI/MISO；CS→GPIO1_IO20；（INT→GPIO1_IO10 二期）
```

目标：在 NXP 纯净基线 + overlay（`gengtao-bsp-0901`）下，解除 UART2 脚复用冲突，启用 ECSPI3，引入自研 SPI+misc 驱动，板上可读 WHO_AM_I 与六轴 raw。

与 AP3216C（文档 **11/12**）对照：**总线是 SPI 不是 I2C**；冲突点是 **引脚复用** 不是 **同址从设备**。

---

## 二、现象时间线

| 阶段 | 关键现象 | 结论 |
|------|----------|------|
| A. 起点 | 无 `&ecspi3`；`uart2`/`flexcan2` 为 okay；无 icm20608 驱动 | 六轴未配置；UART2 脚被占用 |
| B. L0 | `CONFIG_SPI`/`SPI_IMX` 已为 y；禁 uart2/flexcan2 | 框架就绪；引脚策略已定 |
| C. L0 板上 | `/sys/bus/spi/devices/` **空**；但有 `spi_imx` 驱动目录 | **正常**：未开 ecspi3 前无设备；勿当 SPI 坏了 |
| D. L1 开发机 | `dtc` 路径写错（`arch/arm/boot/dts/*.dtb`）→ FATAL | 产物在 `linux-imx6ull-kernel-build-output/`，需写具体文件名 |
| E. L1 反编译 | 大量 Warning，但 `ecspi@02010000` + `icm20608@0` 已进 dtb | Warning 可忽略；验的是最终节点内容 |
| F. L2 | 板上出现 **`spi2.0`**；`of_node`→`icm20608@0`；`spi_imx ... probed` | 控制器 + 设备枚举通；尚无驱动绑定时 driver 可为空 |
| G. L3 | 引入驱动 + `CONFIG_ICM20608=y`；新 zImage | `WHO_AM_I=0xaf OK`；`/dev/icm20608`；driver→icm20608 |
| H. L4-A | 平放 `az`≈16600；`ax/ay` 很小；gyro 小零漂 | ✅ 基线符合 +1g；倾斜/转动可继续验 |

---

## 三、根因与修复

### 问题 1：`uart2` / `flexcan2` 与 ECSPI3 引脚冲突

**根因**

```text
原理图：ICM-20608 走 ECSPI3（UART2_RX/CTS/RTS/TX 复用）
EVK dts：&uart2、&flexcan2 已 okay，占用同一组脚
→ 无法同时给六轴配 pinctrl_ecspi3
```

| 节点 | 占用 | 与 ECSPI3 |
|------|------|-----------|
| `&uart2` | UART2_TX/RX | 与 CS/SCLK 冲突 |
| `&flexcan2` | UART2_RTS/CTS → CAN2 | 与 MISO/MOSI 冲突 |

**修复**（对齐 `origin/IMX6` 的 `alientek-emmc.dts`）：

```dts
&flexcan2 { status = "disabled"; };
&uart2    { status = "disabled"; };   /* 调试继续用 UART1 */

&ecspi3 {
	fsl,spi-num-chipselects = <1>;
	cs-gpios = <&gpio1 20 GPIO_ACTIVE_LOW>;  /* 必须是 cs-gpios 复数 */
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

### 问题 2：基线无驱动；`origin/IMX6` 仅有 dts

**根因**：出厂分支只有 `compatible = "alientek,icm20608"` 的节点，**没有**对应 `.c`；4.1.15 的 `inv_mpu6050` 仅支持 **I2C MPU6050**，不能直接绑本板 SPI ICM-20608。

**修复**：自研 SPI + misc 驱动（对标 AP3216C 路径），编进内核：

| overlay 路径 | 作用 |
|--------------|------|
| `common/drivers/char/icm20608.c` | 驱动：复位、WHO_AM_I、读 0x3B 起 14 字节 |
| `common/include/linux/icm20608.h` | ioctl |
| `common/drivers/char/Kconfig` / `Makefile` | `ICM20608` |
| `projects/.../imx_v7_defconfig` | `CONFIG_ICM20608=y` |

必须 **`build_kernel.sh` → 更新 zImage**（+ 已含节点的 dtb）。只换 dtb 只会有 `spi2.0`、不会有 `/dev/icm20608`。

### 问题 3：Linux SPI 总线号 ≠「SPI3」字面

**根因**：aliases 写 `spi2 = &ecspi3`；内核按启用控制器编号，本板启用后设备为 **`spi2.0`**。

**本板对照**：

| 硬件 | 控制器 | Linux |
|------|--------|-------|
| ECSPI3（ICM-20608） | `ecspi@02010000` | **`spi2`** / 设备 **`spi2.0`** |

不确定时：

```bash
readlink /sys/bus/spi/devices/spi2.0/of_node
# 期望含 ecspi@02010000/icm20608@0
```

### 问题 4：L0 时 `devices/` 为空 → 误判 SPI 未就绪

**根因**：L0 只确认 `CONFIG_SPI`/`SPI_IMX` 与引脚策略；**尚未** `status=okay` 的 `&ecspi3`，故无 `spiX.Y`。

**正确判据（L0）**：

```bash
ls /sys/bus/platform/drivers/spi_imx*   # 有 bind/uevent 即驱动已进内核
# devices/ 为空在 L0 属正常
```

### 问题 5：`dtc` 路径 / 通配符用法错误

**根因**：

1. 构建产物在 **`linux-imx6ull-kernel-build-output/`**，不在 `arch/arm/boot/dts/`  
2. `dtc` **不展开** `*`；需写具体 `.dtb` 名  
3. 反编译大量 Warning 来自 NXP 老风格节点名，**不是失败**

**正确写法**：

```bash
cd linux-imx6ull-kernel-build-output
dtc -I dtb -O dts -o ./xxx.decompiled.dts imx6ull-14x14-evk-emmc-gengtao0901-1024-600.dtb
grep -A30 'ecspi@02010000' ./xxx.decompiled.dts
```

### 问题 6：板上找 `.config` / overlay 里 `grep CONFIG_ICM20608` 搜不到 Kconfig

**根因**：

| 误区 | 事实 |
|------|------|
| 板上 `grep .config` | rootfs **通常没有** 内核 `.config`；配置已编进 zImage |
| `grep CONFIG_ICM20608` 搜 Kconfig | 源文件写的是 **`config ICM20608`**（无 `CONFIG_` 前缀） |

**正确查法**：

```bash
# 开发机
grep CONFIG_ICM20608 .config          # 或 overlay 下 ../.config
grep -n 'config ICM20608' common/drivers/char/Kconfig

# 板上以运行结果为准
dmesg | grep -i icm20608
ls /dev/icm20608
```

### 问题 7：`cs-gpio` 写成单数

**根因**：i.MX SPI 控制器认 **`cs-gpios`（复数）**；写成 `cs-gpio` 时片选可能不动（正点原子资料亦有此坑）。

**修复**：dts 使用 `cs-gpios = <&gpio1 20 GPIO_ACTIVE_LOW>;`

---

## 四、易误判项（短表）

| 现象 | 真实含义 |
|------|----------|
| L0 `/sys/bus/spi/devices/` 空 | **未开 ecspi3 时正常**；有 `spi_imx` 驱动目录即可 |
| `dtc` 一堆 Warning | 多为 schema 提示；无 FATAL 且文件已生成即可 |
| `spi2.0` 存在但 driver 空 | L1/L2 仅有设备节点；**尚未绑** `alientek` 驱动，属过程态 |
| 本驱动有 dmesg 成功日志 | 与 AP3216C 不同；可用 dmesg，但仍以节点+sysfs 为准 |
| 平放 `accel_z`≠精确 16384 | 约 1.5e4～1.7e4 即可；有零偏/安装误差正常 |
| 静止 `gyro_*` 非 0 | **零漂**，可接受；转动时应明显变大 |
| BusyBox 报 `unexpected "done"` | `for` 循环结束后多敲了一次 `done`，与传感器无关 |
| 当成 I2C 去配 `&i2c1` | 本板六轴是 **SPI/ECSPI3** |
| 用 4.1.15 `inv_mpu6050` | 仅 I2C MPU6050，不适用 |
| 过早配 `6D_INT` | 干扰首轮排查；驱动未 `request_irq` 时只改 dts 无效 |

---

## 五、最终验收（板上）

```bash
dmesg | grep -i icm20608
# icm20608 spi2.0: WHO_AM_I=0xaf OK
# icm20608 spi2.0: icm20608 probe OK, /dev/icm20608

ls -l /dev/icm20608
ls -l /sys/bus/spi/devices/spi2.0/driver
# → .../bus/spi/drivers/icm20608

cd /sys/class/misc/icm20608
cat whoami          # 0xaf
cat accel_z         # 平放约 +1.6e4
```

功能对照（量程 accel ±2g / gyro ±2000°/s；详细步骤见文档 **16** L4）：

| 实验 | 期望 | 本工程 |
|------|------|--------|
| 平放静止 | `az`≈+1g raw；`ax/ay` 小；gyro 小零漂 | ✅ az≈16600 |
| 倾斜 | X/Y/Z 重力分量重分配 | 可继续补记 |
| 转动 | 对应 `gyro_*` 瞬时变大 | 可继续补记 |
| 温度 | `temp` 有稳定整数 | ✅ ≈5473 |

---

## 六、overlay 变更清单

| 类型 | 路径 |
|------|------|
| dts | `projects/gengtao-bsp-0901/.../imx6ull-14x14-evk-gengtao0901.dts` |
| 驱动 | `common/drivers/char/icm20608.c`、`Kconfig`、`Makefile` |
| 头文件 | `common/include/linux/icm20608.h` |
| defconfig | `projects/.../arch/arm/configs/imx_v7_defconfig` |
| MANIFEST | 登记上述 `A`/`M` |
| 文档 | **`16`** 落地顺序；本文 **`17`**；**`04`** 补六轴/学习顺序 |

构建部署：

```bash
linux-kernel-overlay/scripts/build_kernel.sh gengtao-bsp-0901
linux-kernel-overlay/scripts/update_board.sh gengtao-bsp-0901 tftp
```

---

## 七、未做项（二期）

| 项 | 说明 |
|----|------|
| **L4 倾斜/转动补记** | 平放基线已过；按 **16** 步骤 B/C 手工对照即可完全勾选 |
| **L5 `6D_INT`** | `GPIO1_IO10`；须改驱动 `request_irq`，只改 dts 无效 |
| ioctl 测试程序 | sysfs 已够验收；需要再写用户态 |
| 主线 IIO / inv_mpu backport | 非首轮必需 |

---

## 八、经验沉淀（可复用到其它 SPI 器件）

1. **先原理图对总线与引脚**，再查 EVK dts 是否 **pinctrl 冲突**（UART/CAN/SPI 互抢）。  
2. **先枚举总线设备（`spiX.Y` + of_node）再绑驱动**，分层不堆问题。  
3. **出厂若只有 dts 无驱动，按同类器件（如 AP3216C）路径自研或从 SDK 引入。**  
4. **验最终 dtb（反编译）再上板**；`dtc` Warning ≠ 失败。  
5. **改驱动必须换 zImage**；只换 dtb 只解决节点描述。  
6. **片选属性用 `cs-gpios`**；SPI 模式按芯片手册（ICM-20608 为 Mode3）。  
7. **成功判据优先 `/dev` + 绑定 + WHO_AM_I/sysfs**；配置宏在开发机 `.config` 查。

与 I2C 光感（文档 **12**）对照记忆：

| | AP3216C | ICM-20608 |
|--|---------|-----------|
| 冲突类型 | 同址 `fxls8471@1e` | 引脚 `uart2`/`flexcan2` |
| 总线号坑 | I2C1≠必然 `i2c-0` | ECSPI3→本板 `spi2.0` |
| 驱动来源 | `origin/IMX6` 有 `.c` | 仅有 dts，需自研 |
| 成功日志 | 出厂常无 dmesg | 本驱动有 probe 日志 |

---

## 九、一句话

**禁用与 UART2 冲突的 `flexcan2`/`uart2`，启用 `&ecspi3` + `icm20608@0`，引入 `CONFIG_ICM20608` 自研驱动；本板设备为 `spi2.0`；以 `/dev/icm20608` + `WHO_AM_I=0xAF` + 平放 `accel_z`≈1g 判打通；L0 时空 `devices/`、dtc Warning、板上无 `.config` 均属常见误判；中断留二期。**
