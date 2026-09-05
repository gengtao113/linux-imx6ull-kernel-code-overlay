# 23 电容触摸：设备树匹配机制与 I2C→input 流程总结

> 文档编号：23  
> 日期：2026-09-04  
> 板卡：正点原子 ATK-MX6ULL（CORE V2.0 + ALPHA V2.4）  
> 驱动：本工程 **`gt9xx.c`**（`compatible = "goodix,gt9xx"`；取自 `origin/IMX6`）  
> 关联：`14`/`15`（I2C）、`21`（落地顺序）、`22`（问题复盘）、`09`（显示侧 OF 匹配对照）  
> 阅读建议：先看 **§一 核心分工** → **§二 设备树匹配** → **§三 数据流（对照源码）** → **§四 与本板验收对照**。

> **易混：** 主线内核另有 `drivers/input/touchscreen/goodix.c`（`goodix,gt911` 等）。本板走的是正点原子 **`gt9xx.c`**，与出厂 dts 的 `"goodix,gt9xx"` 一致；下文函数名均指 overlay `common/.../gt9xx.c`。

---

## 一、核心分工：I2C 与 Input 各司其职

```text
                    ┌─────────────────────────────┐
  触摸芯片 @0x5d    │     I2C 子系统（搬运）        │
  SCL/SDA ─────────►│  时序 / 协议 / i2c_transfer  │
                    │  不解释「这是 X/Y」            │
                    └──────────────┬──────────────┘
                                   │ 原始字节（寄存器映像）
                                   ▼
                    ┌─────────────────────────────┐
                    │  设备驱动 gt9xx（翻译）        │
                    │  解析坐标 / 触点 / 抬起        │
                    └──────────────┬──────────────┘
                                   │ input_report_* / input_sync
                                   ▼
                    ┌─────────────────────────────┐
                    │     Input 子系统（分发）       │
                    │  标准事件 EV_ABS / EV_SYN    │
                    │  → /dev/input/eventX         │
                    └──────────────┬──────────────┘
                                   ▼
                         用户态 hexdump / LVGL evdev
```

| 子系统 | 职责 | 不知道什么 | 本板关键 API / 节点 |
|--------|------|------------|---------------------|
| **I2C** | 物理通信：地址、读写寄存器、搬运字节 | 数据语义（坐标？温度？） | `i2c_transfer`；总线 `i2c-1`（`21a4000`） |
| **Input** | 屏蔽硬件差异，标准化事件，暴露给用户态 | 总线上怎么读寄存器 | `input_report_abs` / `input_sync`；`/dev/input/event1` |
| **gt9xx 驱动** | **交汇点**：两边都实现 | — | `i2c_driver` + `input_dev` |

一句话：**I2C 搬砖，Input 说人话，gt9xx 当翻译官。**

---

## 二、结合点：设备树匹配 + probe（两套框架在驱动里汇合）

典型 I2C 触摸驱动必须同时挂上两套接口：

| 角色 | 做什么 | 本工程代码 |
|------|--------|------------|
| **作为 I2C 设备** | 注册 `i2c_driver`，靠 OF `compatible` + `reg` 与硬件匹配；匹配成功调 `probe` | `goodix_ts_driver` / `goodix_ts_probe` |
| **作为 Input 设备** | 在 `probe` 里 `input_allocate_device` + `input_register_device`，创建 `/dev/input/eventX` | `gtp_request_input_dev()` |

### 2.1 本板设备树节点（匹配「身份证」）

文件：`…/imx6ull-14x14-evk-emmc-gengtao0901-1024-600.dts`

```dts
&i2c2 {
	goodix_ts@5d {
		compatible = "goodix,gt9xx";   /* ★ 与驱动 of_match_table 对齐 */
		reg = <0x5d>;                  /* ★ I2C 7-bit 地址 */
		status = "okay";
		pinctrl-names = "default";
		pinctrl-0 = <&ts_int_pin &ts_reset_pin>;
		interrupt-parent = <&gpio1>;
		interrupts = <9 0>;            /* GPIO1_IO09 → CT_INT */
		goodix,rst-gpio = <&gpio5 9 GPIO_ACTIVE_LOW>;  /* CT_RST */
		goodix,irq-gpio = <&gpio1 9 GPIO_ACTIVE_LOW>;
	};
};
```

| 属性 | 谁用 | 作用 |
|------|------|------|
| `compatible` | I2C/OF 核心 | 与 `goodix_match_table` 字符串匹配 |
| `reg = <0x5d>` | I2C 核心 | 生成 `i2c_client`，地址 0x5d（板上曾见 `1-005d`） |
| `pinctrl-0` | pinctrl | 复用 INT/RST 脚为 GPIO |
| `goodix,*-gpio` | `gtp_parse_dt()` | `of_get_named_gpio` 取脚号 |
| `interrupts` | （可选）中断描述 | 本驱动主要用 `gpio_to_irq(irq-gpio)` |

### 2.2 驱动侧匹配表与注册

```c
/* gt9xx.c — of_match_table */
static const struct of_device_id goodix_match_table[] = {
    { .compatible = "goodix,gt9xx", },
    { .compatible = "goodix,gt1151", },
    /* ... */
    { },
};

static struct i2c_driver goodix_ts_driver = {
    .probe    = goodix_ts_probe,
    .remove   = goodix_ts_remove,
    .id_table = goodix_ts_id,
    .driver = {
        .name           = "goodix-ts",   /* GTP_I2C_NAME */
        .of_match_table = goodix_match_table,
    },
};

/* module_init */
i2c_add_driver(&goodix_ts_driver);   /* 挂到 I2C 核心；之后等 client 匹配 */
```

**匹配成功后的内核行为（概念）：**

```text
dtb 展开 → i2c@21a4000 子节点 goodix_ts@5d
         → I2C 核心创建 i2c_client（addr=0x5d, of_node=...）
         → compatible 命中 goodix_match_table
         → 调用 goodix_ts_probe(client, ...)
```

日志对照（本板）：

```text
<<-GTP-INFO->> GTP driver installing...
<<-GTP-INFO->> GTP Driver Version: ...
<<-GTP-INFO->> GTP I2C Address: 0x5d
```

### 2.3 probe 里同时「认 I2C」和「建 Input」

```text
goodix_ts_probe()
  ├─ gtp_parse_dt()              ← 读 dts gpio
  ├─ gtp_request_io_port()       ← gpio_request + 复位序列
  ├─ gtp_power_switch()          ← 本工程：无 supply 可跳过
  ├─ gtp_i2c_test() / init_panel ← 用 I2C 读芯片确认通信
  ├─ gtp_request_input_dev()     ← ★ Input：allocate + register → eventX
  └─ gtp_request_irq()           ← request_irq(goodix_ts_irq_handler)
       或失败则 hrtimer 轮询
```

`gtp_request_input_dev()` 要点：

```c
ts->input_dev = input_allocate_device();
/* 声明会报 EV_ABS / EV_SYN 等 */
input_set_abs_params(..., ABS_MT_POSITION_X, ...);
input_set_abs_params(..., ABS_MT_POSITION_Y, ...);
ts->input_dev->name = "goodix-ts";
input_register_device(ts->input_dev);   /* 之后 /proc/bus/input/devices 可见 */
```

本板验收：`Name="goodix-ts"`，`Handlers=event1`。

---

## 三、完整数据流：从摸屏到 `/dev/input/eventX`

结合 **`gt9xx.c`** 源码，触摸发生时路径如下。

### 3.1 总览

```text
手指按下
  → 芯片拉 CT_INT（GPIO1_IO09）
  → CPU 中断 → goodix_ts_irq_handler()
  → disable_irq + queue_work(goodix_wq, &ts->work)
  → goodix_ts_work_func()          【进程上下文，可睡、可 I2C】
       ├─ gtp_i2c_read(..., 坐标寄存器 0x814E)
       ├─ 解析 finger / touch_num / X,Y,W
       ├─ gtp_touch_down/up() → input_report_abs(...)
       ├─ input_sync()
       └─ gtp_i2c_write(end_cmd) 清状态 + enable_irq
  → Input 核心环形缓冲
  → 用户态 read(/dev/input/event1) / hexdump / LVGL
```

### 3.2 步骤 1：中断触发 + `queue_work` 机制详解

硬件：`CT_INT` → `GPIO1_IO09`。  
probe 里：`ts->client->irq = gpio_to_irq(gtp_int_gpio)`，再 `request_irq(..., goodix_ts_irq_handler, ...)`。

```c
/* goodix_ts_irq_handler */
static irqreturn_t goodix_ts_irq_handler(int irq, void *dev_id)
{
    struct goodix_ts_data *ts = dev_id;
    gtp_irq_disable(ts);                 /* disable_irq_nosync，先关中断 */
    queue_work(goodix_wq, &ts->work);    /* 把 work 挂到工作队列 */
    return IRQ_HANDLED;
}
```

#### 3.2.1 为什么要「关中断 + 丢队列」，而不是在 ISR 里直接读 I2C？

| 上下文 | 能否睡眠 / 阻塞 | 本驱动要做的事 |
|--------|-----------------|----------------|
| **硬中断 ISR**（`goodix_ts_irq_handler`） | **不能** `msleep` / 长时间自旋；I2C 传输常会等完成、可能调度 | 只做「记账 + 投递」 |
| **工作队列进程上下文**（`goodix_ts_work_func`） | **可以** 睡眠、拿锁、调 `i2c_transfer` | 读坐标、上报 input、清芯片状态 |

因此模式是经典的 **top half / bottom half**：

```text
top half（中断里，越短越好）
  gtp_irq_disable()     → 暂时不再进 ISR，避免读点未完成又重入
  queue_work(...)       → 把 bottom half 挂到队列
  return IRQ_HANDLED

bottom half（稍后由内核线程执行）
  goodix_ts_work_func() → I2C 读点 + input_report + enable_irq
```

#### 3.2.2 `goodix_wq` 从哪来？什么类型？

模块初始化时创建**单线程工作队列**：

```c
/* goodix_ts_init() */
goodix_wq = create_singlethread_workqueue("goodix_wq");
/* 内核会起一个内核线程，名字里通常带 goodix_wq */
```

| 点 | 含义 |
|----|------|
| `create_singlethread_workqueue` | 队列背后 **一个** worker 线程，work **串行**执行 |
| 名字 `"goodix_wq"` | `ps`/`top` 里可看到对应 kthread（便于对照） |
| 与系统 `system_wq` 区别 | 专用队列：触摸耗时的 I2C 不和别的随便 work 抢同一默认池策略（本驱动选择独立队列） |

probe 里绑定处理函数：

```c
INIT_WORK(&ts->work, goodix_ts_work_func);
/* ts->work 里记下「要跑的函数 = goodix_ts_work_func」 */
```

#### 3.2.3 `queue_work(goodix_wq, &ts->work)` 内核大致做什么？

```text
queue_work(wq, work)
  │
  ├─ 若该 work 已在队列里（PENDING）→ 通常直接返回 false，不重复入队
  │     （同一 ts->work 未跑完前，再次 queue 往往被合并）
  │
  ├─ 把 work 挂到 wq 的链表
  │
  └─ 唤醒该 wq 的 worker 内核线程（若在睡）
         │
         ▼
    worker 线程被调度（进程上下文）
         │
         ├─ 从队列取出 work
         ├─ 调用 work->func(work)
         │     即 goodix_ts_work_func(work)
         │     内部用 container_of(work, struct goodix_ts_data, work) 找回 ts
         └─ 跑完后 work 可再次被 queue_work
```

要点：

1. **`queue_work` 本身很快**：只入队 + 唤醒，**不**在 ISR 里执行 `goodix_ts_work_func`。  
2. **真正干活的时刻**不确定：取决于调度；一般很快，但允许延迟。  
3. **同一 `work` 同时只能有一份在队列/运行**：频繁中断不会无限堆积多份同一 work（未执行完时再 queue 常被忽略）。  
4. 执行时已是 **进程上下文** → 可以 `i2c_transfer`、可以相对长时间处理。

#### 3.2.4 和 `disable_irq` / `enable_irq` 怎么配合？

```c
/* ISR */
gtp_irq_disable(ts);          /* 内部：disable_irq_nosync(client->irq) */
queue_work(goodix_wq, &ts->work);

/* work_func 末尾（读点、sync、写 end_cmd 之后） */
gtp_irq_enable(ts);           /* enable_irq，允许下一次 CT_INT */
```

```text
INT 来 ──► ISR：关中断 + queue_work
              │
              │  （这段时间即使芯片再拉 INT，也不再进 handler）
              ▼
         worker：读 I2C、上报、清芯片缓冲
              │
              ▼
         enable_irq ──► 可以响应下一次触摸中断
```

| API | 本驱动用法 | 作用 |
|-----|------------|------|
| `disable_irq_nosync` | `gtp_irq_disable` | 关中断且**不等待**其它 CPU 上的 handler 结束（ISR 里用更合适） |
| `enable_irq` | `gtp_irq_enable` | 重新允许该 irq 线 |
| `irq_is_disable` 标志 | 自旋锁保护 | 避免重复 disable/enable 失衡 |

若 **不在 work 末尾 `enable_irq`**：读点做完后中断一直关着 → 后续触摸无事件（只摸一下有数据、再摸没有）。本驱动在 `exit_work_func` 路径和成功路径都会 `gtp_irq_enable`。

#### 3.2.5 和「直接在中断里 `schedule_work` / tasklet」的对比（概念）

| 机制 | 上下文 | 能否睡眠 | gt9xx 为何用 workqueue |
|------|--------|----------|-------------------------|
| 硬中断 | 中断 | 否 | 不能做 I2C |
| softirq / tasklet | 软中断 | 否 | 仍不宜阻塞式 I2C |
| **workqueue** | 内核线程 | **是** | ✅ 适合 `i2c_transfer` |
| 用户线程 | 用户态 | 是 | 驱动里不这么干 |

#### 3.2.6 轮询兜底（同一套 queue_work）

若 `request_irq` 失败，驱动用 `hrtimer` 周期触发，**同样** `queue_work(goodix_wq, &ts->work)`，bottom half 仍是 `goodix_ts_work_func`——只是触发源从「硬件 INT」变成「定时器」。

---

工作函数入口先组「16 位寄存器地址 + 读缓冲」，再调用 `gtp_i2c_read`：

```c
/* 坐标区起始：GTP_READ_COOR_ADDR = 0x814E（gt9xx.h） */
u8 point_data[...] = {
    GTP_READ_COOR_ADDR >> 8,
    GTP_READ_COOR_ADDR & 0xFF,
    /* 后面由 I2C 读回状态字节 + 触点数据 */
};
ret = gtp_i2c_read(ts->client, point_data, 12);
```

`gtp_i2c_read` 本质是两次消息的 **combined transaction**：

```c
msgs[0]: 写 2 字节寄存器地址（高字节在前）
msgs[1]: I2C_M_RD 读 len-2 字节数据
ret = i2c_transfer(client->adapter, msgs, 2);
```

| 层次 | 作用 |
|------|------|
| `gtp_i2c_read` | 驱动封装：重试、失败则 `gtp_reset_guitar` |
| `i2c_transfer` | I2C 核心：把 `i2c_msg` 交给适配器 |
| `i2c-imx`（本板） | 控制器驱动：产生 SCL/SDA 波形 |

**此时得到的仍是芯片私有字节流**，I2C 子系统不解析。

首包关键字段（驱动约定）：

```text
point_data[0..1]  寄存器地址（发出去的）
point_data[2]     finger 状态：bit7=数据就绪，bit3..0=触点数
point_data[3..]   每点 8 字节：id, X_L, X_H, Y_L, Y_H, W_L, W_H, ...
```

多指时再 `gtp_i2c_read` 续读。

### 3.4 步骤 3：解析并 Input 上报

```c
input_x = coor_data[pos+1] | (coor_data[pos+2] << 8);
input_y = coor_data[pos+3] | (coor_data[pos+4] << 8);
input_w = coor_data[pos+5] | (coor_data[pos+6] << 8);
gtp_touch_down(ts, id, input_x, input_y, input_w);
/* ... */
input_sync(ts->input_dev);
```

`gtp_touch_down` / `gtp_touch_up`：

```c
/* 按下/移动 */
input_mt_slot(ts->input_dev, id);
input_report_abs(..., ABS_MT_TRACKING_ID, id);
input_report_abs(..., ABS_MT_POSITION_X, x);
input_report_abs(..., ABS_MT_POSITION_Y, y);
input_report_abs(..., ABS_MT_TOUCH_MAJOR, w);
input_report_abs(..., ABS_MT_WIDTH_MAJOR, w);

/* 抬起 */
input_report_abs(..., ABS_MT_TRACKING_ID, -1);
```

然后写 `end_cmd` 到芯片清「有新数据」标志，并 `gtp_irq_enable`。

### 3.5 步骤 4：用户空间获取

Input 核心把事件排进设备缓冲；用户态：

```bash
hexdump -C /dev/input/event1
# 或 LVGL：EVDEV_NAME=/dev/input/event1
```

与文档 **21** L4 实测对应关系：

| hexdump 片段 | 驱动上报 |
|--------------|----------|
| `03 00`（EV_ABS）+ `35 00` | `ABS_MT_POSITION_X` |
| `03 00` + `36 00` | `ABS_MT_POSITION_Y` |
| `03 00` + `39 00` + `ff ff ff ff` | `ABS_MT_TRACKING_ID = -1`（抬起） |
| `00 00 …`（EV_SYN） | `input_sync()` |

---

## 四、源码函数索引（对照阅读）

| 函数 | 文件位置（约） | 所属侧 | 作用 |
|------|----------------|--------|------|
| `goodix_ts_init` / `i2c_add_driver` | 文末 | I2C | 注册驱动 |
| `goodix_ts_probe` | ~682 | 两边 | 解析 dts、申请 IO、建 input、申请中断 |
| `gtp_parse_dt` | ~597 | OF | `goodix,irq-gpio` / `rst-gpio` |
| `gtp_request_io_port` | ~503 | GPIO | request + 复位选址 |
| `gtp_request_input_dev` | ~559 | Input | allocate / register |
| `gtp_request_irq` | ~531 | IRQ | `request_irq` 或 timer 轮询 |
| `goodix_ts_irq_handler` | ~346 | IRQ | 关中断 + `queue_work` |
| `goodix_ts_work_func` | ~225 | 驱动核心 | I2C 读点 + 上报 |
| `gtp_i2c_read` / `write` | ~99/~129 | I2C | `i2c_transfer` 封装 |
| `gtp_touch_down` / `up` | ~208/~219 | Input | `input_report_abs` |
| `input_sync` | work_func 末尾 | Input | 提交一帧 |

路径：`linux-kernel-overlay/common/drivers/input/touchscreen/gt9xx.c`（及同步后的内核树同名文件）。

---

## 五、与本板验收对照（把机制钉到现象）

| 机制环节 | 板上怎么验 |
|----------|------------|
| I2C 总线活着 | `i2cdetect -l` → `i2c-1`/`21a4000`；`i2cdetect -y 1` 见 `5d` |
| OF 匹配 + probe | `dmesg \| grep GTP` 有 Version / Address；失败见文档 **22** |
| Input 节点创建 | `Name="goodix-ts"` → `event1` |
| I2C→Input 通路通 | `hexdump -C /dev/input/event1` 摸屏有 EV_ABS |
| 用户态应用 | L5：LVGL `EVDEV_NAME=/dev/input/event1`（待做） |

**匹配失败常见分层（与文档 22 呼应）：**

```text
compatible 不对 / 未编进 gt9xx     → 根本不进 probe
pinctrl 抢脚                         → Error applying setting
gpio 被 VSD_3V3 等占用               → request GPIO -EBUSY
regulator 强制失败（出厂逻辑）         → GTP power on failed
以上都过但没摸屏测                    → 有 event 节点但 hexdump 无数据
```

---

## 六、和显示文档 09 的对照（帮助建立统一心智）

| | 显示（文档 09） | 触摸（本文） |
|--|-----------------|--------------|
| 硬件 | LCDIF | 触摸 IC @ I2C2 |
| 搬运/产生像素或字节 | LCDIF 扫 timing | **I2C** 读寄存器 |
| 内核抽象 | framebuffer `/dev/fb0` | **input** `/dev/input/eventX` |
| 板级驱动 | mxsfb | **gt9xx** |
| dts 关键 | `compatible` + timings | `compatible` + `reg` + gpio/pinctrl |
| 匹配后果 | `mxsfb_probe` | `goodix_ts_probe` |

两边都是：**设备树描述硬件 → compatible 绑定驱动 → probe 创建设备节点 → 用户态打开节点。**

---

## 七、一句话

**I2C 只负责把触摸芯片寄存器字节搬进 CPU；gt9xx 在 probe 里用 dts 的 `goodix,gt9xx`/`0x5d` 完成匹配并注册 `input_dev`；摸屏时中断唤醒工作队列，经 `i2c_transfer` 读 `0x814E` 坐标区，再 `input_report_abs` + `input_sync` 变成 `/dev/input/event1` 上的标准事件。**
