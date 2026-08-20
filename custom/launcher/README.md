# DeepSeek Harness 启动器（custom/launcher）

本目录是 **非上游本地扩展**（fork 友好原则）：启动脚本从用户目录
`~\.dsh-web-launcher` 迁移并优化而来，收纳进仓库的 `custom/` 子目录，
不修改任何上游文件，也不会与上游更新冲突。

## 文件清单

| 文件 | 作用 |
| --- | --- |
| `start-dsh.bat` | 入口：环境检测、端口检测、启动后端窗口、打开应用/等待页 |
| `_backend.cmd` | 后端窗口内执行的步骤：浅拉取（fetch --depth=1）→ pnpm install → build → lefthook → pnpm dsh web --no-open |
| `launcher.html` | 启动等待页：轮询端口，就绪后自动跳转（支持 `?port=` 参数） |
| `.gitattributes` | 限定本目录 `.bat`/`.cmd` 工作区为 CRLF（仓库内仍为 LF），保证 cmd.exe 可靠解析 |

## 使用方法

1. 直接双击 `start-dsh.bat`；
2. 或让桌面快捷方式指向它：右键「DeepSeek Harness」快捷方式 → 属性 → 目标改为
   本仓库 `custom\launcher\start-dsh.bat` 的绝对路径（起始位置可留空）。

## 工作流程

1. 检测 `node` / `pnpm` 是否可用（缺失时给出友好提示）；
2. 检测端口（默认 `3080`）是否已被监听：
   - 已在运行 → 直接打开应用，**不会**重复启动后端；
   - 未运行 → 在独立控制台窗口（标题 `DeepSeek Harness backend`）中依次执行
     **浅拉取**（`git fetch --depth=1` + `git reset --hard FETCH_HEAD`，只取目标分支最新提交，本地仅保留最新一次提交）、
     安装依赖、构建、安装 git hooks（仅首次）、启动 `pnpm dsh web --no-open`，
     同时打开 `launcher.html` 轮询等待就绪；
     `--no-open` 禁止 dsh web 自行打开浏览器，应用窗口统一由启动器打开（避免双窗口）；
3. 浏览器选择：Edge → Chrome → 系统默认浏览器。

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
- **安全保护**：工作区有未提交修改时跳过更新；本地有未推送提交时保留本地并提示（推送后可自动对齐，或设 `DSH_PULL_FORCE=1` 强制对齐）；
- 本地提交请先推送到远端再更新，否则会被浅拉取对齐时丢弃。

## 故障排查

- **提示找不到 pnpm**：执行 `corepack enable pnpm` 后重试；
- **构建/安装失败**：看后端控制台窗口中的报错日志（窗口由 `cmd /k` 保持打开）；
- **端口被占用**：其他程序占用 3080 时，改用 `set DSH_PORT=3081` 等端口；
- **中文乱码**：两个脚本以 GBK（代码页 936）保存以匹配中文 Windows 控制台（cmd 默认代码页 936）；若系统为其他区域设置，中文可能显示为乱码，可将脚本转为对应代码页或启用系统级 UTF-8（`chcp 65001` 需要脚本以 UTF-8 保存，二者不可混用）。
- **报错 `... was unexpected at this time.`**：位于括号块内的 echo 文本不能包含未转义的 ASCII 半角括号（cmd 会将其解析为嵌套块，紧随其后的内容被当作命令）。本脚本已统一改用全角括号（如（pnpm install --ignore-scripts））；自行修改时请沿用此约定，或用 `^(` / `^)` 转义。
