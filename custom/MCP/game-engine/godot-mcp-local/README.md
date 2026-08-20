# godot-mcp-local — godot-mcp 本地文档与脚本（分类：game-engine）

godot-mcp 本体以 **git 子模块** 形式挂载于 `custom/MCP/game-engine/godot-mcp/`，
指向 https://github.com/CrimsonSeraph/godot-mcp（含 tsconfig 的 `node10` 修复）。
本目录保存原本随「复制副本」一并入库的本地文档与快捷脚本——子模块内不存放本地修改，
克隆仓库后需先 `git submodule update --init --recursive` 拉取本体。

| 路径 | 说明 |
| --- | --- |
| `README.md`（本文件） | 安装 / 使用 / 注册说明 |
| `README.upstream.md` | 上游官方 README（原样保留） |
| `scripts/godot-mcp.ps1` | 校验或前台启动服务器（构建产物位于子模块内） |
| `mcp-client-config.example.json` | 客户端注册配置示例 |

## 安装方式（首次克隆后）

```powershell
git submodule update --init --recursive   # 拉取 godot-mcp 子模块
cd custom/MCP/game-engine/godot-mcp
npm install                                # 触发 prepare -> npm run build（tsc 编译到 build/）
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
          - '<REPO_ROOT>/custom/MCP/game-engine/godot-mcp/build/index.js'
        env:
          GODOT_PATH: '<GODOT_EXE>'
```

改完后 HMR 自动生效（无需重启 DSH），工具以 `mcp__godot__<名称>` 出现（共 157 个）。

## 使用方法

1. **项目管理类**（无需运行游戏）：`run_project`、`create_scene`、`read_scene`、`validate_script`、`list_project_files` 等。
2. **运行时类 `game_*`**（需游戏运行 + autoload）：
   - 将 `custom/MCP/game-engine/godot-mcp/build/scripts/mcp_interaction_server.gd` 复制到 Godot 项目（如 `<GODOT_PROJECT>`）；
   - Godot：**Project → Project Settings → Autoload** 注册为 `McpInteractionServer`；
   - 之后 `game_eval`、`game_get_scene_tree`、`game_screenshot`、`game_key_press` 等生效（监听 `127.0.0.1:9090`）。

## 快捷脚本

```powershell
.\scripts\godot-mcp.ps1              # 校验：构建产物 + Godot 路径 + MCP 握手 + 工具数
.\scripts\godot-mcp.ps1 -Serve       # 前台启动服务器（stdio），供 MCP 客户端连接/调试
.\scripts\godot-mcp.ps1 -GodotPath D:\Godot\Godot.exe
```

## 原位置对照

| 内容 | 原位置（继续使用） | 现在 |
| --- | --- | --- |
| godot-mcp 本体 | `<GODOT_MCP_HOME>` | 子模块 `custom/MCP/game-engine/godot-mcp/` |
| 本地文档 / 快捷脚本 | 随复制副本入库 | 本目录 `godot-mcp-local/` |
| 用户环境变量 | `GODOT_PATH`（用户级，持久） | 文档化于上表 |
| DSH 注册 | `~/.dsh/cordis.patch.yml`（`mcp-godot` 块） | 文档化于上节 |
| 客户端配置示例 | `<GODOT_MCP_HOME>/mcp-client-config.example.json` | 本目录同名文件 |
