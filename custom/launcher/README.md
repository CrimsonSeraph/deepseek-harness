# DeepSeek Harness 启动器（custom/launcher）

本目录是 **非上游本地扩展**（fork 友好原则）：启动脚本从用户目录
`~\.dsh-web-launcher` 迁移并优化而来，收纳进仓库的 `custom/` 子目录，
不修改任何上游文件，也不会与上游更新冲突。

## 文件清单

| 文件 | 作用 |
| --- | --- |
| `start-dsh.bat` | 入口：环境检测、端口检测、启动后端控制台窗口 |
| `_backend.cmd` | 后端窗口内执行的步骤：浅拉取（fetch --depth=1）→ 子模块同步 → pnpm install → build → lefthook → 启动 dsh web 并打开应用窗口 |
| `run-web.ps1` | 方案 B 助手：运行 `pnpm dsh web --no-open`，捕获其打印的**带 token 地址**，再用专属 Edge/Chrome `--app` 窗口打开；控制台与 dsh web 进程同窗口，关窗即停服 |
| `launcher.html` | （保留的备选等待页，当前流程未使用；支持 `?port=` 参数） |
| `.gitattributes` | 限定本目录 `.bat`/`.cmd` 工作区为 CRLF（仓库内仍为 LF），保证 cmd.exe 可靠解析 |

## 使用方法

1. 直接双击 `start-dsh.bat`；
2. 或让桌面快捷方式指向它：右键「DeepSeek Harness」快捷方式 → 属性 → 目标改为
   本仓库 `custom\launcher\start-dsh.bat` 的绝对路径（起始位置可留空）。

## 工作流程（方案 B：专属应用窗口）

1. 检测 `node` / `pnpm` 是否可用（缺失时给出友好提示）；
2. 检测端口（默认 `3080`）是否已被监听：
   - 已在运行 → 打开应用（Edge `--app` → Chrome `--app` → 默认浏览器）；
   - 未运行 → 在独立控制台窗口（标题 `DeepSeek Harness backend`）中依次执行
     **浅拉取**（`git fetch --depth=1` + `git reset --hard FETCH_HEAD`，只取目标分支最新提交，本地仅保留最新一次提交）、
     **子模块同步**（`git submodule update --init --recursive`，对齐到拉取后记录的子模块提交，如 `custom/MCP/game-engine/godot-mcp`）、
     安装依赖、构建、安装 git hooks（仅首次），期间进度显示在此控制台窗口；
3. 最后 `_backend.cmd` 调用 `run-web.ps1`：以 `--no-open` 运行 `pnpm dsh web`，
   捕获它打印的带 token 地址（`http://127.0.0.1:3080/?token=...`），随后用一个
   **专属 Edge/Chrome `--app` 窗口**打开该地址 —— 浏览器接收签名 cookie 后即进入应用；
   `run-web.ps1` 与 dsh web 同处一个控制台进程树，关闭该窗口即停止服务。
   设 `DSH_NO_BROWSER=1` 时不打开应用窗口，仅以 `--no-open` 方式运行服务（无头/CI）。

> 为什么必须走 `run-web.ps1`：`dsh web` 用每次进程随机生成的 token 保护页面，裸地址
> `http://127.0.0.1:3080` 在无有效 cookie 时返回 `401 … authentication required`。
> 只有 dsh web 自己打印的带 token 地址能完成首次登录，故启动器须捕获该地址后用它打开专属窗口。

## 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `DSH_PORT` | `3080` | 服务端口（同时用于端口检测与 URL） |
| `DSH_APP_DIR` | 脚本位置推导 | 仓库根目录覆盖 |
| `DSH_NO_PULL` | - | 设为任意值跳过浅拉取 |
| `DSH_NO_INSTALL` | - | 设为任意值跳过 pnpm install |
| `DSH_NO_BUILD` | - | 设为任意值跳过 pnpm run build（日常已构建时可加快启动） |
| `DSH_NO_BROWSER` | - | 设为任意值不打开浏览器（用于无头/CI 场景） |
| `DSH_DRY_RUN` | - | 仅打印后端步骤，不真正执行（诊断用） |
| `DSH_PULL_BRANCH` | `master` | 浅拉取的目标分支 |
| `DSH_PULL_FORCE` | - | 本地有未推送提交时仍强制对齐远端（reset --hard） |

示例：日常快速启动（不拉取、不重装、不重建）：

```bat
set DSH_NO_PULL=1 & set DSH_NO_INSTALL=1 & set DSH_NO_BUILD=1
start-dsh.bat
```

## 与上游同步

`custom/` 路径在上游仓库中不存在，合并上游更新时不会与之冲突；如需整体移除本地扩展，删除 `custom/` 目录即可。

## 浅拉取说明

- 每次启动执行 `git fetch --depth=1 origin <分支>`，只下载目标分支的最新一次提交；
- 拉取后本地仅保留最新一次提交（`reflog expire` + `git gc --prune=now` 清理旧对象），仓库始终处于浅克隆状态；
- 浅拉取后执行 `git submodule update --init --recursive`，把子模块（如 `custom/MCP/game-engine/godot-mcp`）对齐到新提交记录的版本；首次会自动克隆子模块；
- **安全保护**：工作区有未提交修改时跳过更新；本地有未推送提交时保留本地并提示（推送后可自动对齐，或设 `DSH_PULL_FORCE=1` 强制对齐）；
- 本地提交请先推送到远端再更新，否则会被浅拉取对齐时丢弃。

## 故障排查

- **提示找不到 pnpm**：执行 `corepack enable pnpm` 后重试；
- **构建/安装失败**：看后端控制台窗口中的报错日志（窗口由 `cmd /k` 保持打开）；
- **端口被占用**：其他程序占用 3080 时，改用 `set DSH_PORT=3081` 等端口；
- **页面提示 `dsh web authentication required`**：dsh web 用随机进程 token 保护页面，必须通过
  `dsh web:` 打印的地址（含 `?token=`）访问。若手动打开了不含 token 的裸地址
  （`http://127.0.0.1:3080`）或浏览器里没有有效 cookie，就会看到该提示。直接双击本启动器即可，
  启动器会捕获 dsh web 打印的带 token 地址并用专属应用窗口打开；若已单独启动后端，请复制后端
  控制台里 `dsh web:` 开头的完整地址到浏览器打开（只访问一次后浏览器会保存 30 天 cookie，之后裸地址也可用）。
- **中文乱码**：两个脚本以 GBK（代码页 936）保存以匹配中文 Windows 控制台（cmd 默认代码页 936）；若系统为其他区域设置，中文可能显示为乱码，可将脚本转为对应代码页或启用系统级 UTF-8（`chcp 65001` 需要脚本以 UTF-8 保存，二者不可混用）。
- **报错 `... was unexpected at this time.`**：位于括号块内的 echo 文本不能包含未转义的 ASCII 半角括号（cmd 会将其解析为嵌套块，紧随其后的内容被当作命令）。本脚本已统一改用全角括号（如（pnpm install --ignore-scripts））；自行修改时请沿用此约定，或用 `^(` / `^)` 转义。
