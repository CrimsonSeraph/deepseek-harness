# custom/ — 本地扩展目录（非上游）

本目录集中存放 deepseek-harness 仓库的**本地自定义内容**，遵循 fork 友好原则：

- **不修改上游文件**；确需修改时改动最小化，并在提交信息中注明；
- **自带文档**：每个子目录含 README 说明用途、用法与依赖；
- **可整体移除**：删除 `custom/` 不影响上游功能；
- **不与上游冲突**：上游仓库不存在 `custom/` 路径，`git pull` 合并时无交集。

## 子目录

| 目录 | 内容 |
| --- | --- |
| `launcher/` | Web 启动脚本（start-dsh.bat、_backend.cmd、launcher.html、README） |
| `plugins/` | 本地已安装第三方插件清单与安装方式（2026-08 快照） |

后续扩展（如 `patches/`、`utils/`）请继续放在本目录下并补充 README。
