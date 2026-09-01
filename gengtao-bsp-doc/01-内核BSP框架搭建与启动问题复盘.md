# 01 内核 BSP 框架搭建与启动问题复盘

> 文档编号：01
> 日期：2026-09-01
> 板卡：正点原子 ATK-MX6ULL（eMMC 核心板，7 寸 1024x600 屏）
> 目标：基于 NXP 纯净基线（4.1.15-2.1.0）从零开始，逐个外设打通驱动

---

## 一、环境概览

| 项 | 值 |
|---|---|
| 内核树 | `~/linux-imx6ull-code/linux-imx6ull-kernel-code`（分支 master-gengtao-0901，NXP 纯净基线） |
| 定制框架 | `~/linux-imx6ull-code/linux-kernel-overlay`（common 公共层 + projects/gengtao-bsp-0901 板级层） |
| 交叉编译器 | Linaro GCC 4.9.4（`/usr/local/arm/...`，无需 Yocto SDK） |
| 宿主机 gcc | Ubuntu 13.3.0（引发问题 1 的关键） |
| 板子启动方式 | U-Boot TFTP 拉取 zImage + dtb，NFS 挂载 rootfs（192.168.3.51 板 / 192.168.3.52 主机） |
| 参考对照 | IMX6 分支（出厂全部定制）+ `~/linux-imx6ull/` 参考工作区 |

---

## 二、问题 1：宿主机 GCC 13 下 scripts/dtc 链接失败

### 现象（编译日志）

```
HOSTLD  scripts/dtc/dtc
/usr/bin/ld: scripts/dtc/dtc-parser.tab.o:(.bss+0x50): multiple definition of `yylloc'; scripts/dtc/dtc-lexer.lex.o:(.bss+0x0): first defined here
collect2: error: ld returned 1 exit status
make[2]: *** [scripts/Makefile.host:100：scripts/dtc/dtc] 错误 1
```

### 分析过程

1. **定位阶段**：报错发生在链接 dtc 时，两个目标文件各自在 `.bss` 段定义了 `yylloc`——这是"试探性定义"（tentative definition / common symbol）冲突的典型特征，而不是普通的重定义（那会报在编译期）
2. **版本关联**：common symbol 合并是老链接器的默认行为，GCC 10 起默认改为 `-fno-common`。查宿主机 `gcc --version` = 13.3.0，确认踩中
3. **源码定位**：`grep yylloc scripts/dtc/`——`dtc-lexer.l` 与 `dtc-parser.y` 各自写了 `YYLTYPE yylloc;`（旧内核 4.1.15 的 dtc 代码就是这么写的）
4. **对照参考**：参考工作区 overlay 里的 `dtc-lexer.l` 已是 `extern YYLTYPE yylloc;`——与基线仅一行之差，直接验证了修复方案

### 根因

GCC 10+ 默认 `-fno-common`，词法器与解析器对 `yylloc` 的重复 tentative definition 不再被链接器合并。

### 修改点

| 文件 | 行 | 修改 |
|---|---|---|
| `scripts/dtc/dtc-lexer.l` | 42 | `YYLTYPE yylloc;` → `extern YYLTYPE yylloc;` |
| `scripts/dtc/dtc-lexer.lex.c_shipped` | 640 | 同上 |

- 定义保留在 `dtc-parser.y`（唯一），词法器仅 extern 引用
- 经验：**先改 `.l` 再改 `_shipped`**（mtime 顺序），避免 make 因 `_shipped` 比 `.l` 旧而用 flex 重新生成整个文件
- 验证：`make scripts` 通过，`scripts/dtc/dtc` 正常链接

### 后续归属

该补丁最终进入 overlay 的 `common/scripts/dtc/`（构建适配层），内核树本身保持纯净基线。

---

## 三、问题 2：新分支编译 dtb 报"没有规则可制作目标"

### 现象（编译日志）

```
make[1]: *** 没有规则可制作目标"arch/arm/boot/dts/imx6ull-14x14-emmc-7-1024x600-c.dtb"。 停止。
make: *** [arch/arm/Makefile:322：imx6ull-14x14-emmc-7-1024x600-c.dtb] 错误 2
```

### 分析过程

1. **报错语义**：make 找不到目标规则，只有两种可能——dts 源文件不存在，或 dts/Makefile 没有登记该 dtb 目标
2. **文件盘点**：`ls arch/arm/boot/dts/imx6ull*`——新分支只有官方 evk/arm2 系列；`grep imx6ull arch/arm/boot/dts/Makefile`——没有 emmc 屏幕变体目标
3. **分支对照**：`git ls-tree IMX6 arch/arm/boot/dts/` 有 35 个 imx6ull-14x14 文件；`git diff master-gengtao-0901 IMX6 -- arch/arm/boot/dts/Makefile` 显示 IMX6 分支追加了 16 个 dtb 目标（14 个屏幕变体 + 2 个 alientek）
4. **看目标 dts 内容**：`git show IMX6:...7-1024x600-c.dts` = `#include "imx6ull-14x14-evk-emmc.dts"` + 1024x600 时序 + 触摸节点

### 根因

分支 master-gengtao-0901 是 NXP 纯净基线，正点原子的板级定制（dts、驱动、defconfig 共数百文件）只存在于 IMX6 分支。缺的不止一个 dts。

### 解决（架构决策）

搭建 **overlay 定制框架**（仿参考工作区）：内核树永远保持干净基线，所有定制放 overlay，构建时拷贝覆盖。

```
linux-kernel-overlay/
├── MANIFEST                          # 定制清单（基线 sha + 文件列表）
├── common/                           # 公共定制（dtc 补丁等）
├── projects/gengtao-bsp-0901/        # 板级定制（由用户从零逐步添加）
├── .baseline/                        # 上游升级冲突检测快照
└── scripts/                          # common/apply_overlay/build_kernel/... 工具链
```

关键设计：设备树目标列表**由 MANIFEST 动态提取**（新增 dts 自动编 dtb）；apply_overlay.sh 校验"新增 dts 必须接线 Makefile"。这与学习目标匹配：每个外设 = 往 overlay 里加一个 dts（+ 接线 + 可能的驱动），构建→板载验证→提交里程碑。

---

## 四、问题 3：板子启动卡在 NFS 挂载失败（网卡不通）

### 现象（启动日志关键行）

```
libphy: fec_enet_mii_bus: probed
fec 20b4000.ethernet eth0: registered PHC device 0
fec 2188000.ethernet eth1: registered PHC device 1
...
IP-Config: Failed to open eth0
IP-Config: Device `eth0' not found
```

### 分析过程

1. **找缺失的正常日志**：健康启动路径里，fec 注册之后必然有一条 `xxx 20b4000.ethernet:01: attached PHY driver [yyy] (...)`。本日志 libphy 之后直接断掉——**PHY 从未 attach**
2. **硬件确认**：ATK 板网口 PHY 是 LAN8720A（SMSC 芯片）
3. **配置核对**：`grep PHY arch/arm/configs/imx_v7_defconfig`——基线只有 `CONFIG_MICREL_PHY=y`（官方 EVK 用的 KSZ8081），**没有 `CONFIG_SMSC_PHY`**
4. **驱动能力核对**：基线 `fec_main.c` 已支持 `phy-reset-gpios`（3344 行）/`phy-handle`（3500 行），驱动框架 OK——缺的是 PHY 驱动本身 + ATK 板的板级适配（LAN8720A 需要 i.MX 输出 50MHz 参考时钟与正确的复位时序，IMX6 分支 overlay 里有 fec_main.c/smsc.c 补丁）
5. **对照 U-Boot 行为**：U-Boot 阶段 TFTP 下载正常（U-Boot 用自己的 PHY 初始化流程），说明硬件链路本身没问题，问题在内核侧配置

### 根因

1. 基线内核未编译 SMSC PHY 驱动（defconfig 缺 `CONFIG_SMSC_PHY`）
2. ATK 板的 LAN8720A 需要 fec 驱动的板级适配（时钟/复位），基线内核没有
3. NFS rootfs 依赖 eth0 → 网卡不通 → 挂载失败 → 无登录 shell

### 修改点（= 第一个学习任务，待完成）

| 步骤 | 内容 | 学习价值 |
|---|---|---|
| 1 | overlay 板级 defconfig 加 `CONFIG_SMSC_PHY=y` | 配置（机械） |
| 2 | 写板级 dts：fec pinctrl + phy-reset-gpios + phy-mode rmii | dts 节点编写 |
| 3 | 必要时适配 fec_main.c（对照 IMX6 分支补丁） | 驱动板级适配 |
| 4 | Makefile 接线 + MANIFEST 登记 → 构建 → 部署 → 板载验证 | 框架工作流 |

### 验证成功的标志

启动日志出现 `attached PHY driver [smsc LAN8710/LAN8720]` → NFS 挂载成功 → 出现登录提示符。

---

## 五、问题 4：U-Boot 未加载预期的 dtb（改 fdt_file 无效）

### 现象（U-Boot 日志）

修改 `fdt_file=imx6ull-14x14-evk-emmc.dtb` 并保存后，复位日志仍显示：

```
Filename 'imx6ull-14x14-emmc-7-1024x600-c.dtb'.
Bytes transferred = 40381 (9dbd hex)
```

### 分析过程

1. **字节数比对**：日志 40381 字节与 tftpboot 里旧的 7 寸 dtb 大小完全一致 → 确认加载的就是旧文件，且 tftpboot 里当时根本没有 evk-emmc.dtb（改完后 TFTP 会因文件不存在而失败，而不是静默换文件）
2. **查同类历史**：参考工作区文档《内核部署验证-问题排查复盘》记录过完全相同的坑——出厂 bootcmd **硬编码 dtb 文件名**，`${fdt_file}` 变量从未被引用（当时硬编码的是 4.3 寸文件名）
3. **推断**：本板 uboot 同样硬编码了 7 寸文件名 → 改 fdt_file 无效

### 根因

bootcmd 硬编码 dtb 文件名，环境变量 fdt_file 未被引用。

### 修改点

| 位置 | 修改 |
|---|---|
| 主机 tftpboot/ | 编译并放入官方 `imx6ull-14x14-evk-emmc.dtb`（阶段一应急） |
| 板子 u-boot | `setenv bootcmd 'tftp 80800000 zImage; tftp 83000000 ${fdt_file}; bootz 80800000 - 83000000'` + `setenv fdt_file imx6ull-14x14-evk-emmc.dtb` + `saveenv` |

---

## 六、修改点汇总

| # | 修改 | 位置 | 状态 |
|---|---|---|---|
| 1 | dtc `extern yylloc` 补丁（2 文件各 1 行） | overlay/common/scripts/dtc/ | ✅ 已生效 |
| 2 | overlay 定制框架（脚本/清单/文档） | linux-kernel-overlay/ | ✅ 搭建并全链路验证 |
| 3 | 官方 evk-emmc dtb | tftpboot/ | ✅ 已编译放入 |
| 4 | bootcmd 改用 ${fdt_file} | 板子 u-boot env | ⏳ 需串口确认 |
| 5 | CONFIG_SMSC_PHY + fec dts 适配 | overlay 板级层 | ⏳ 第一个学习任务 |

## 七、遗留事项

- **网卡打通**（问题 3）是当前唯一阻塞：网络不通 → 无 NFS rootfs → 无法登录验证后续所有外设
- wm8960 probe failed、lcdif display#1 重名等日志噪音源于"旧定制 dtb + 新基线内核"混用，自写 dts 后自然消失
- 每个外设打通后建议在 overlay 目录 git 提交里程碑，便于回退对比
