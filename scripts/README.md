# scripts 目录说明

各脚本的作用与用法：

| 脚本 | 作用 | 用法 |
|---|---|---|
| common.sh | 公共库：路径/工具链常量、分层规则 layer_for()、安全重置 safe_reset()。被其他脚本 source，不直接执行 | — |
| apply_overlay.sh | 把 overlay（common + projects/<项目>）拷贝覆盖到内核树，并校验 MANIFEST 完整性、dts/Makefile 接线 | `apply_overlay.sh <project> [--force]` |
| build_kernel.sh | 一键构建：重置内核树基线 → 应用 overlay → distclean/defconfig → 编 zImage + dtb（从 MANIFEST 提取）+ modules → 打包到 ../output/<project>/ | `build_kernel.sh <project> [--no-reset] [--targets "..."] [--no-modules] [--no-package] [--jobs N]` |
| restore_baseline.sh | 把内核树恢复成干净基线（丢弃全部改动，含未跟踪文件） | `restore_baseline.sh [--force]` |
| capture_changes.sh | 把内核树里的手工修改回收到 overlay（编辑-编译-回收闭环），过滤构建产物 | `capture_changes.sh <project> [--dry-run]` |
| extract_overlay.sh | 从 git 分支差异提取定制重建 overlay 与 MANIFEST（慎用：对学习项目跑 --branch IMX6 会提取出厂全部定制） | `extract_overlay.sh [<project>] [--branch IMX6] [--base <分支>]` |
| update_board.sh | 把 ../output/<project>/ 的产物部署到 TFTP / NFS 服务目录，板子复位即可验证 | `update_board.sh <project> [tftp\|nfs\|all]` |

## 常用命令速查

```bash
build_kernel.sh gengtao-bsp-0901                        # 一键构建（最常用）
update_board.sh gengtao-bsp-0901 tftp                   # 部署内核+dtb 到 TFTP
update_board.sh gengtao-bsp-0901 all                    # 连同内核模块一起更新
restore_baseline.sh                                     # 内核树恢复干净基线
```

## 注意

- **危险脚本**：build_kernel.sh / restore_baseline.sh 会执行 `git reset --hard` + `git clean -fd`，
  内核树里未提交/未跟踪的改动会被**彻底删除**。改代码只改 overlay，不直接改内核树。
- 误改内核树时：先 `capture_changes.sh <project>` 回收到 overlay，再跑构建。
