# MCP/ — 本机 MCP 工具集（为 DSH 注册的外部 Model Context Protocol 服务器）

本目录集中存放为本机 DeepSeek Harness（DSH）接入的 **外部 MCP 工具**：可运行副本、安装方式、
使用方法、快捷启动脚本与 DSH 注册片段。遵循 `custom/` 的 fork 友好原则：自带文档、可整体移除、
不修改上游。

## 分类结构

```
MCP/
├── README.md                  # 本文件（总览）
├── game-engine/               # 分类：游戏引擎
│   ├── godot-mcp/             #   Godot 4.x 引擎控制（157 工具，git 子模块）
│   └── godot-mcp-local/       #   本地文档 + 快捷脚本（README / godot-mcp.ps1 / 配置示例）
└── ide/                       # 分类：IDE
    └── qtcreator-mcp/         #   Qt Creator 20 内置 MCP Server（64 工具）
        ├── README.md
        └── scripts/start-qtcreator.ps1, check-server.ps1
```

## 工具总览

| 工具 | 分类 | 功能 | 工具数 | 传输 | 状态 | 迁移方式 |
| --- | --- | --- | --- | --- | --- | --- |
| [godot-mcp](game-engine/godot-mcp-local/README.md) | game-engine | 控制 Godot 引擎：项目管理、场景编辑、运行时操控（`game_eval` 等） | 157 | stdio | ✅ 已注册 `mcp__godot__*` | **子模块**（本地文档/脚本在 `godot-mcp-local/`） |
| [qtcreator-mcp](ide/qtcreator-mcp/README.md) | ide | 控制 Qt Creator：构建、调试、断点、文件、符号导航 | 64 | streamable-http (`127.0.0.1:46327`) | ✅ 已注册 `mcp__qtcreator__*` | 文档+脚本（工具本体随 Qt 安装） |

## 安装方式汇总

| 工具 | 安装 |
| --- | --- |
| godot-mcp | 见 [本地文档](game-engine/godot-mcp-local/README.md)：`git submodule update --init --recursive` + `npm install` + `npm run build`；需 Node ≥18、Godot ≥4.4（本机 Steam 版 4.7.x，`GODOT_PATH` 用户环境变量已配置） |
| qtcreator-mcp | 见 [其 README](ide/qtcreator-mcp/README.md)：Qt Creator 升级到 **20.0.1**（MaintenanceTool）+ 启用 `mcpserver` 插件 + Preferences 固定端口 **46327** |

## 占位符说明

本目录文档为保护本机隐私，**不包含任何本机绝对路径/用户名**，一律使用下列占位符，请按本机实际值替换：

| 占位符 | 含义 |
| --- | --- |
| `~` | 用户主目录（Windows 下为 `C:\Users\<用户名>`） |
| `<GODOT_MCP_HOME>` | godot-mcp 安装目录（原位置；本机已配用户环境变量 `GODOT_PATH`，具体值不入库） |
| `<GODOT_EXE>` | Godot 可执行文件路径 |
| `<GODOT_PROJECT>` | Godot 示例项目路径 |
| `<QT_CREATOR_HOME>` | Qt Creator 安装目录 |
| `<QT_CREATOR_EXE>` | `qtcreator.exe` 路径 |
| `<QT_MAINTENANCE_TOOL>` | Qt MaintenanceTool 路径 |

## DSH 注册总览（`~/.dsh/cordis.patch.yml`，HMR 即时生效）

```yaml
- insert:   # godot —— stdio
    - id: mcp-godot
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: godot
        transport: stdio
        command: node
        args: ['<GODOT_MCP_HOME>/build/index.js']
        env:
          GODOT_PATH: '<GODOT_EXE>'
- insert:   # qtcreator —— streamable-http（需 Qt Creator 运行中）
    - id: mcp-qtcreator
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: qtcreator
        transport: streamable-http
        url: 'http://127.0.0.1:46327/'
```

## 快捷启动脚本

```powershell
# Godot：校验或前台启动 MCP 服务器
.\game-engine\godot-mcp-local\scripts\godot-mcp.ps1        # 校验（构建+Godot 路径+握手+工具数）
.\game-engine\godot-mcp-local\scripts\godot-mcp.ps1 -Serve # 前台启动（stdio）

# Qt Creator：启动 + 等待 + 验证
.\ide\qtcreator-mcp\scripts\start-qtcreator.ps1            # 启动 Creator 并等 46327 就绪
.\ide\qtcreator-mcp\scripts\start-qtcreator.ps1 -Check     # 就绪后握手并列出工具
.\ide\qtcreator-mcp\scripts\check-server.ps1 -Tools        # 仅检查端点 + 工具清单
```

## 原位置对照（复制迁移清单）

按安全原则，**正在使用的内容一律复制而非移动**，原位置保留并继续生效：

| 内容 | 原位置（继续使用） | 迁移副本/文档 |
| --- | --- | --- |
| godot-mcp 完整安装 | `<GODOT_MCP_HOME>` | `game-engine\godot-mcp\`（git 子模块）+ `game-engine\godot-mcp-local\`（本地文档/脚本） |
| Godot 用户环境变量 | `GODOT_PATH`（用户级，持久） | 文档化于各 README |
| DSH 注册（godot + qtcreator） | `~/.dsh/cordis.patch.yml` | 片段见本文件与各子 README |
| Qt Creator 20.0.1（mcpserver 插件） | `<QT_CREATOR_HOME>`（Qt 更新器管理） | 文档化于 `ide\qtcreator-mcp\README.md` |
| 插件启用 / 端口配置 | `%APPDATA%\QtProject\QtCreator.ini` | 文档化于 `ide\qtcreator-mcp\README.md` |

## 注意事项

- **godot-mcp**：运行时 `game_*` 工具需在 Godot 项目注册 `McpInteractionServer` autoload
  （`custom/MCP/game-engine/godot-mcp/build/scripts/mcp_interaction_server.gd`，监听 9090）；项目管理类工具无需。
- **qtcreator-mcp**：MCP 服务器存活于 IDE 进程内，**Qt Creator 需保持运行**；端口固定 46327。
- **切换生效位置**：若要把 DSH 的 godot 桥改指向子模块，编辑 `cordis.patch.yml` 中 `mcp-godot`
  的 `args` 路径为 `<REPO_ROOT>/custom/MCP/game-engine/godot-mcp/build/index.js`（见本地文档），HMR 自动重连。
- 安全性提示（DSH 设计原则）：MCP 服务器命令是 agent 沙箱之外的可信可执行代码，注册前请确认来源可信。
