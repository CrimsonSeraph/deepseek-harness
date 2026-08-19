# qtcreator-mcp — Qt Creator 20 官方内置 MCP Server（分类：ide）

官方文档：[Set up Qt Creator MCP server](https://doc.qt.io/qtcreator/creator-how-to-mcp-server.html)
（插件 `mcpserver`，源码 `qt-creator/src/plugins/mcpserver`，本机 **Qt Creator 20.0.1**，端口 **46327**，64 工具）

> 本工具**无需独立安装目录**：MCP 服务器内置于 Qt Creator 20+ 的 IDE 进程内（`<QT_CREATOR_HOME>`）。
> 本目录存放：安装/使用说明 + 快捷启动脚本 + DSH 注册片段。

## 目录内容

| 路径 | 说明 |
| --- | --- |
| `README.md`（本文件） | 安装 / 使用 / 注册说明 |
| `scripts/start-qtcreator.ps1` | 启动（或复用）Qt Creator 并等待 MCP 端口就绪，可选 `-Check` 验证 |
| `scripts/check-server.ps1` | 检查 46327 端点：握手 + 工具清单（`-Tools`） |

## 安装方式（一次性，已完成）

1. **升级 Qt Creator 到 20+**（18 无此插件）：
   ```powershell
   & '<QT_MAINTENANCE_TOOL>' update qt.tools.qtcreator_gui qt.tools.qtcreator qtcreator extensions `
     --confirm-command --accept-licenses --default-answer --accept-obligations
   ```
   说明：首次运行可能只自更新维护工具，需重复一次；仅指定 Creator 组件，避免拖入 Design Studio（2.6GB）。
2. **启用 mcpserver 插件**（`DisabledByDefault`）—— 已写入用户设置 `%APPDATA%\QtProject\QtCreator.ini`：
   ```ini
   [Plugins]
   ForceEnabled=mcpserver
   ```
   或 GUI：**Help → About Plugins** 勾选 "Qt Creator MCP Server"。
3. **设置固定端口**：**Preferences(Options) → AI → Qt Creator MCP Server** → Port = `46327`
   （页面显示 "The MCP Server is running, listening on: 127.0.0.1:46327" 即成功；
   "Enable MCP Server" 默认开启，Listen 保持默认即可）。

## DSH 注册（用户级 `~/.dsh/cordis.patch.yml`）

```yaml
- insert:
    - id: mcp-qtcreator
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: qtcreator
        transport: streamable-http
        url: 'http://127.0.0.1:46327/'
```

HMR 自动生效；工具以 `mcp__qtcreator__<名称>` 出现（64 个：`build`、`debug`、`add_breakpoint`、
`evaluate_expression`、`execute_command`、`file_plain_text`、`find_files_in_projects`、`search_in_file` 等）。

## 使用方法

1. **保持 Qt Creator 运行** —— MCP 服务器存活于 IDE 进程内，关闭即断。
2. 典型调用：构建（`mcp__qtcreator__build`）、调试（`debug` + 断点 + `debugger_continue`）、
   读改文件（`file_plain_text` / `set_file_plain_text`）、导航（`find_files_in_projects`、`search_in_file(s)`）。

## 快捷脚本

```powershell
.\scripts\start-qtcreator.ps1                 # 启动 Creator + 等待 46327 就绪
.\scripts\start-qtcreator.ps1 -Check          # 就绪后做 MCP 握手 + 列工具
.\scripts\check-server.ps1 -Tools             # 仅检查：握手 + 工具清单
```

## 原位置对照

| 内容 | 原位置 | 说明 |
| --- | --- | --- |
| Qt Creator 20.0.1（含 mcpserver.dll / McpServerLib.dll） | `<QT_CREATOR_HOME>` | 由 MaintenanceTool 安装，未复制（体积大且由 Qt 更新器管理） |
| 插件启用配置 | `%APPDATA%\QtProject\QtCreator.ini` → `[Plugins] ForceEnabled=mcpserver` | 已生效 |
| MCP 端口设置 | 同上 ini `[McpServer]`（GUI 页面修改） | 固定 46327 |
| DSH 注册 | `~/.dsh/cordis.patch.yml`（`mcp-qtcreator` 块） | 文档化于上节 |

## 注意事项

- 调试工具（`debugger_*`、断点）需要当前 Qt Creator 会话中打开了项目。
- 若端口被占，改 Preferences 里的 Port 并同步更新 DSH 注册的 `url`。
- Qt 在线安装器管理本机 Creator，升级/卸载一律走 `<QT_MAINTENANCE_TOOL>`；本目录占位符定义见上级 `MCP/README.md`。
