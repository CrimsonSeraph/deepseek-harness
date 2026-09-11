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
| `MCP/` | 本机 MCP 工具集（godot-mcp、qtcreator-mcp）：可运行副本、安装/使用说明、快捷启动脚本、DSH 注册片段 |
| `skills/` | 个人 agent skill 包，每个 skill 一个目录、内含 `SKILL.md`；用法与接入方式见 [`skills/README.md`](skills/README.md) |
| `tools/` | 可独立运行的命令行工具与脚本（Qt/QML 截图链路等）；逐个工具的用途、参数、退出码见 [`tools/README.md`](tools/README.md) |

## skills/ 与 tools/ 的分工

- `tools/` 放**能直接执行的脚本**：参数化、可单独运行、退出码语义明确，不依赖 agent 也能用。
- `skills/` 放**给 agent 看的操作说明**：`SKILL.md` 描述触发场景、标准流程、硬性规则与踩坑，
  正文引用 `tools/` 中的脚本，必要时在 `resources/` 里附带 QML 模板等素材。

**skill 需要额外接入 DSH 才会生效**：DSH 不会扫描 `custom/skills/`。
它默认的技能根目录是 `$DSH_HOME/skills`（即 `~/.dsh/skills`）与 `~/.agents/skills`，
项目级还包括 `<项目根>/.dsh/skills`、`<项目根>/.agents/skills`。
把 `custom/skills/` 加进技能根目录，或配置成额外的 skill 提供者目录，
并在重启 DSH / 刷新会话之后，skill 才会出现在 agent 的可用技能列表中。
三种接入方式（设置面板添加目录、复制或链接到扫描根、插件安装）见 [`skills/README.md`](skills/README.md)。

后续扩展（如 `patches/`、`utils/`）请继续放在本目录下并补充 README。
