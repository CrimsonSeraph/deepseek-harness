# godot-mcp — Godot 引擎 MCP 服务器（分类：game-engine）

仓库：[tugcantopaloglu/godot-mcp](https://github.com/tugcantopaloglu/godot-mcp)（v3.1.0，MIT，157 工具，Godot 4.4+，本机 Steam 版 Godot 4.7.x）

> **本目录是「复制副本」**：`<GODOT_MCP_HOME>` 为原始安装位置，当前仍被 DSH 桥接进程直接使用
> （`node <GODOT_MCP_HOME>/build/index.js`），因此按安全原则复制而非移动。切换 DSH 指向本副本的
> 方法见下文「DSH 注册」。上游原始 README 保留为 `README.upstream.md`。
> 本文件不包含本机绝对路径/用户名，占位符定义见上级 `MCP/README.md`。

## 目录内容

| 路径 | 说明 |
| --- | --- |
| `./` | 完整可运行副本：源码 + `node_modules` + 构建产物 `build/`（含 `scripts/mcp_interaction_server.gd`）。`node_modules/` 与 `build/` 已 gitignore、不入库；克隆后执行 `npm install`（自动触发 build）即可重新生成 |
| `README.md`（本文件） | 安装 / 使用 / 注册说明 |
| `README.upstream.md` | 上游官方 README（原样保留） |
| `scripts/godot-mcp.ps1` | 校验或前台启动服务器 |

## 安装方式（原位置重装步骤）

```powershell
git clone https://github.com/tugcantopaloglu/godot-mcp.git <GODOT_MCP_HOME>
cd <GODOT_MCP_HOME>
npm install          # 会触发 prepare -> npm run build（tsc 编译到 build/）
npm audit fix        # 可选：清零已知漏洞（2026-08 实测 18 -> 0）
```

要求：Node.js >= 18（本机 v22）；Godot 4.4+（本机 Steam 版 **4.7.x**，路径见 `<GODOT_EXE>`）。

## 环境变量

| 变量 | 值 | 说明 |
| --- | --- | --- |
| `GODOT_PATH` | Godot 可执行文件路径 | 已写入**用户级环境变量**（持久）；也可在 DSH 注册片段中显式给出 |

## DSH 注册（用户级 `~/.dsh/cordis.patch.yml`）

```yaml
- insert:
    - id: mcp-godot
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: godot
        transport: stdio
        command: node
        args:
          - '<GODOT_MCP_HOME>/build/index.js'   # 原位置（当前生效）
          # - '<REPO_ROOT>/custom/MCP/game-engine/godot-mcp/build/index.js'  # 若切到本副本
        env:
          GODOT_PATH: '<GODOT_EXE>'
```

改完后 HMR 自动生效（无需重启 DSH），工具以 `mcp__godot__<名称>` 出现（共 157 个）。

## 使用方法

1. **项目管理类**（无需运行游戏）：`run_project`、`create_scene`、`read_scene`、`validate_script`、`list_project_files` 等。
2. **运行时类 `game_*`**（需游戏运行 + autoload）：
   - 将 `build/scripts/mcp_interaction_server.gd` 复制到 Godot 项目（如 `<GODOT_PROJECT>`）；
   - Godot：**Project → Project Settings → Autoload** 注册为 `McpInteractionServer`；
   - 之后 `game_eval`、`game_get_scene_tree`、`game_screenshot`、`game_key_press` 等生效（监听 `127.0.0.1:9090`）。

## 快捷脚本

```powershell
.\scripts\godot-mcp.ps1              # 校验：构建产物 + Godot 路径 + MCP 握手 + 工具数
.\scripts\godot-mcp.ps1 -Serve       # 前台启动服务器（stdio），供 MCP 客户端连接/调试
.\scripts\godot-mcp.ps1 -GodotPath D:\Godot\Godot.exe
```

## 原位置对照

| 内容 | 原位置 | 本副本 |
| --- | --- | --- |
| godot-mcp 完整安装 | `<GODOT_MCP_HOME>` | `custom/MCP/game-engine/godot-mcp/` |
| 用户环境变量 | `GODOT_PATH`（用户级，持久） | 文档化于上表 |
| DSH 注册 | `~/.dsh/cordis.patch.yml`（`mcp-godot` 块，指向原位置） | 文档化于上节 |
| 客户端配置示例 | `<GODOT_MCP_HOME>/mcp-client-config.example.json` | 本目录同名文件 |
