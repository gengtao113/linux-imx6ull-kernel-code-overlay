# gengtao-bsp-0901 板级定制层

这里放你板子（ATK-MX6ULL，eMMC，7 寸 1024x600 屏）的定制内容，
目录结构与内核树保持一致：

```
projects/gengtao-bsp-0901/
├── arch/arm/boot/dts/          # 板级 dts + dts/Makefile 接线
├── arch/arm/configs/           # 板级 defconfig
└── drivers/                    # 板级驱动适配（如需）
```

新增文件后记得更新 MANIFEST（或先在内核树改、再用 capture_changes.sh 回收），
apply_overlay.sh 会校验 MANIFEST 完整性与 dts/Makefile 接线。
