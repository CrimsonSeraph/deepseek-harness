---
name: qt-screenshot
description: 给 Qt/QML 桌面应用启动真实窗口并按窗口句柄截图，带硬超时、空白帧检测、PNG 校验与进程清理；用于视觉检查、多尺寸回归对比，以及排查「窗口出不来 / 截图为空白 / 脚本卡死」类问题
whenToUse: 需要给 Qt/QML 应用启动窗口并截图，用于视觉检查或回归对比；或者截图脚本出现卡住、截图空白、退出码不可信、需要批量跑多尺寸截图时
---

# Qt/QML 截图

用真实窗口 + 按句柄抓图的方式给 Qt/QML 应用出图，用于视觉检查和回归对比。
整条链路只有两种结局：**要么产出非空且非空白的 PNG 并返回 0，要么在有限时间内报错并返回非 0**，
不允许卡住，也不允许「命令成功但图是白屏」。

## 工具位置

| 脚本                                 | 作用                                                                            |
| ------------------------------------ | ------------------------------------------------------------------------------- |
| `<仓库根>/custom/tools/shoot.sh`     | 单尺寸：生成 `cur.qml` → 启动 `qml.exe` → 等窗口 → 抓图 → 校验 → 清理           |
| `<仓库根>/custom/tools/cap.ps1`      | 按标题/进程定位可见窗口，`PrintWindow` 抓该窗口位图并存 PNG（带 `-TimeoutSec`） |
| `<仓库根>/custom/tools/run_shots.sh` | 批量：建模块目录 → 离屏烟测 → 逐尺寸抓图 → 汇总                                 |
| `<仓库根>/custom/tools/preflight.sh` | 前置自检：命令、Qt、残留进程、源目录、`qmldir`、模板标记                        |
| `<仓库根>/custom/tools/selftest.sh`  | 故意失败测试：证明失败路径有时间上限且返回非 0                                  |
| `<仓库根>/custom/tools/lib.sh`       | 共用函数（路径转换、PID、PNG 头解析、日志提炼）                                 |

脚本目录可用环境变量 `QT_SHOT_TOOLS` 覆盖。如果本 skill 被单独复制到
`$DSH_HOME/skills/`，请把 `custom/tools/` 一并复制过去并设置 `QT_SHOT_TOOLS` 指向它。

模板放在本 skill 的 `resources/`：`single.qml.example`（截图入口）、`shots.qml.example`（离屏烟测入口）、
`broken-window.qml`（故意失败夹具）。复制到工作目录的 `templates/` 下再改成被测应用的样子。

## 前置检查

1. **PATH 里有 Qt 的 `qml.exe`**：确认 `mingw_64/bin`（或实际使用的 kit）与 `mingw64/bin` 可用。
   脚本会按 `QT_BIN_DIR` → PATH → `QT_ROOT_DIR`/`QT_SEARCH_ROOTS` 的顺序自动探测；
   探测不到就直接失败，不要靠猜。
   ```bash
   "$QT_SHOT_TOOLS/preflight.sh" --qml <模板> --src <QML 源目录> --module-dir <模块根> --module <模块名>
   ```
2. **清残留渲染进程**：`taskkill //F //IM qml.exe`（或 `preflight.sh --kill`）。
   上一轮没退干净的 `qml.exe` 会留下同名窗口，让这一轮抓到旧内容。
3. **QML 源目录存在且非空**，`qmldir` 生成正确：第一行 `module <模块名>`，
   模块目录下每个 `*.qml` 都有一行 `<名字> 1.0 <名字>.qml`，并以 `depends QtQuick` 结尾。
   `run_shots.sh` 与 `preflight.sh` 都会逐条核对。
4. **窗口标题含约定标识**（默认 `SHOTWIN`），且截图模板里确实出现该标识。
   没设标题或标题被 QML 错误打断，`cap.ps1` 就找不到窗口。
5. **模板含三个标记**：`property int targetWidth:` / `property int targetHeight:` / `property string kind:`。
   缺任何一个，`shoot.sh` 直接以退出码 3 失败——绝不能出现「sed 没改到、按错误尺寸截图」还返回 0 的情况。

## 标准流程

```bash
TOOLS=${QT_SHOT_TOOLS:-<仓库根>/custom/tools}
WORK=<工作目录>            # 放 mod/、templates/、shots/、logs/
OUT=<输出目录>

# 1) 建模块目录：把 QML 源复制到 <WORK>/mod/<模块名>，并生成 qmldir
#    （run_shots.sh 会自动做；也可以手工做，注意 qmldir 内容）
# 2) 离屏烟测：先确认所有尺寸都能加载、没有 QML 错误、进程能退出
QT_QPA_PLATFORM=offscreen qml.exe -I "<模块根 Windows 路径>" "<shots.qml>"
# 3) 逐尺寸抓图
"$TOOLS/run_shots.sh" --src <QML 源目录> --work-dir "$WORK" --out-dir "$OUT" \
    --module <模块名> --template "$WORK/templates/single.qml" \
    --shots-qml "$WORK/templates/shots.qml" --timeout 10 \
    --size 1180x760:desktop:desktop-1180x760 \
    --size 320x568:mobile:mobile-320x568
```

单尺寸调用：

```bash
"$TOOLS/shoot.sh" --qml <模板> --out-dir "$OUT" --module-dir <模块根> --timeout 10 \
    1180 760 desktop desktop-1180x760
```

单尺寸内部顺序：复制/生成 `cur.qml` → 校验三处替换生效 → `taskkill` 清本次残留 →
启动 `qml.exe`（记录 Windows PID）→ 确认进程存活 → **轮询等窗口，整体不超过 `--timeout`（默认 10s）** →
`cap.ps1` 按 `标题 + PID + 可见性` 定位窗口 → `PrintWindow` 抓图 → 空白帧检测与重试 →
校验 PNG 存在、非空、尺寸可解析 → 以退出码 0/非 0 结束 → `trap cleanup` 结束进程、删临时文件。

成功时最后一行是可解析的汇总：

```
OK name=desktop-1180x760 kind=desktop requested=1180x760 actual=1493x997 bytes=53621 elapsed=2578ms file=...png
```

`requested` 与 `actual` 不同是正常的：窗口有标题栏/边框，`actual` 是含边框的物理像素
（本机 125% 缩放时约等于 逻辑尺寸×1.25 + 边框）。用 `--strict-size` 可以要求两者一致。

## 硬性规则

- **`cap.ps1` 不得无超时轮询**：必须有 `-TimeoutSec`（默认 10），到点写 `ERROR 1 ...` 并 `exit 1`。
  超时预算从脚本启动算起，含 `Add-Type` 编译时间。
- **`shoot.sh` 不得在没有 `set -euo pipefail` 和 `trap ... EXIT` 的情况下运行**：
  失败必须非 0 退出，并且一定清理进程与临时文件。
- **不要用全屏截图**：一律按窗口句柄抓（`PrintWindow` + `PW_RENDERFULLCONTENT`）。
  全屏截图会被其它窗口遮挡，也会把桌面上的无关内容拍进图里。
- **失败就报错退出，不要手动杀进程「绕过」继续跑**。
  卡住/空白都是缺陷信号：先定位（看日志里的 QML 错误、看 `cap.ps1 -List` 的输出），再继续。
- **日志里有 QML 错误导致窗口出不来，先修 QML 再截图**，不要靠加长等待时间硬扛。
- **截图前确认窗口可见且标题匹配**：只接受 `IsWindowVisible` 为真的窗口；
  同名但不可见的兄弟窗口还没绘制，抓到的是纯背景色。
- **只接受非空且非空白的 PNG**：客户区网格采样，主色占比 ≥ 0.995 判为空白帧，
  先 `RedrawWindow` 强制重绘重试，仍空白则退出码 5，并把调试图留在磁盘上。
- **杀掉的是本次启动的进程**：`taskkill //F //T //PID <winpid>`（MSYS 的 `kill` 对 Windows GUI 进程不一定有效，
  只作兜底）；需要按镜像名清理时属于兜底路径，会打印警告。

## 退出码

| 脚本           | 退出码                                                                                                                            |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `shoot.sh`     | 0 成功 / 2 参数错误 / 3 前置条件（模板、目录、命令）不满足 / 4 QML 进程异常退出 / 5 截图失败 / 6 截图看门狗超时 / 7 输出 PNG 无效 |
| `cap.ps1`      | 0 成功 / 1 超时未找到可见窗口 / 2 窗口矩形非法 / 3 抓图失败 / 4 PNG 无效 / 5 空白帧 / 6 内部错误 / 7 目标进程已退出               |
| `run_shots.sh` | 0 全部成功 / 2、3 同上 / 4 离屏烟测失败 / 其它沿用首个失败的 `shoot.sh` 退出码                                                    |
| `selftest.sh`  | 0 全部符合预期 / 1 有用例不符合预期 / 3 前置条件不满足                                                                            |

## 故意失败测试

改完脚本必须跑一遍 `selftest.sh`，确认失败路径仍有时间上限：

```bash
"$TOOLS/selftest.sh" --template <可用模板> --module-dir <模块根> --work-dir <临时目录> --timeout 10
```

参考结果（本机实测，`--timeout 10`）：

| 用例                   | 期望                 | 实测    |
| ---------------------- | -------------------- | ------- |
| 模板缺标记             | 3，≤5s               | 3，0.7s |
| 窗口标题永不匹配       | 5，≤10s              | 5，8.1s |
| QML 加载即失败         | 4，≤10s              | 4，3.3s |
| `cap.ps1` 找不到窗口   | 1，≤7s               | 1，4.6s |
| 进程活着但窗口从不显示 | 1，≤7s，且不产出 PNG | 1，4.6s |

## 故障排查

- **一直没图、日志停在 `powershell ... cap.ps1`**：先看有没有超时参数。历史上没有超时的
  `cap.ps1` 会无限轮询，表现为 `ps -W` 里长期挂着一个 `powershell` 进程。
  现在 `cap.ps1` 有 `-TimeoutSec`，`shoot.sh` 外面还套了 `timeout` 看门狗，
  出现退出码 6 说明看门狗被触发——那是脚本缺陷，要修脚本而不是加大超时。
- **`cap.ps1` 报找不到窗口**：
  ```bash
  powershell -NoProfile -File "$TOOLS/cap.ps1" -TitlePart SHOTWIN -List -IncludeHidden
  ```
  列出同名窗口的句柄、PID、可见性、尺寸。若只有 `visible=False` 的窗口，
  说明该窗口根本没显示：检查 QML 的 `visible` 绑定，以及日志里有没有运行期错误。
- **PNG 是白屏/纯色**：脚本会以退出码 5 失败并留下调试图。真实原因通常是窗口刚创建还没绘制，
  或该窗口本来就不可见；先看调试图，再决定是改 `--settle-ms`、修 QML 还是改模板。
- **进程残留**：`tasklist //FI "IMAGENAME eq qml.exe"`。
  日志里出现 `QObject::~QObject: Timers cannot be stopped from another thread` 或
  `QDxgiVSyncService not destroyed in time` 说明 Qt 退出路径不干净，
  `shoot.sh` 的清理会用 `taskkill //F //T //PID` 兜底强杀。
- **离屏烟测通过但窗口截图失败**：离屏不创建真实窗口，能过说明 QML 语法/绑定没问题，
  问题在窗口创建路径（标题、`visible`、尺寸下限）。

## 踩坑记录

- `QQmlListModel.count` 是**属性不是方法**：写成 `sessionModel.count()` 会抛
  `TypeError: Property 'count' of object ... is not a function`，
  窗口初始化中断、标题设不上，`cap.ps1` 就找不到窗口。统一写 `sessionModel.count`。
- `ps -W` 里卡住的 `powershell` 通常就是 `cap.ps1`：没有超时会一直轮询。
- `run_shots.sh` 开头无条件 `rm -rf "$SHOTS"` 会清掉上一轮截图：
  删除必须显式（`--clean-module` / `--clean-shots`）且校验路径在工作目录之内。
- 同一个 `cap.ps1` 的 PID 可能跨多轮一直没退出：批量脚本必须自己管超时与清理。
- 同名但 `visible: false` 的兄弟窗口会抓到纯背景色 PNG：
  定位窗口必须同时要求「可见」并带上本次启动的 PID。
- `[ cond ] && cmd` 单独成行在 `set -e` 下会让脚本意外退出（条件为假时整行返回 1）：
  写成 `if ...; then ...; fi`。
- `cap.ps1` 必须存为 **UTF-8 with BOM**：Windows PowerShell 5.1 对无 BOM 的 `.ps1` 按 ANSI/GBK 解析，
  中文注释会变成乱码并报出 `Missing expression after ','` 之类与真实原因无关的语法错误。
  用编辑器改动后要确认 BOM 还在。
- MSYS 的 `bash` 里 `$!` 是 MSYS PID，`taskkill //F //PID` 要的是 Windows PID：
  用 `/proc/<pid>/winpid` 取（`lib.sh` 的 `winpid_of`），不要直接把 `$!` 交给 `taskkill`。
- 传给 `qml.exe` / `powershell` 的路径一律用 `cygpath -w -a` 转成 Windows 路径，
  不要把 `/tmp/...` 这类 MSYS 路径直接塞给原生程序。
- 离屏 `qml.exe` 未必自己退出：`run_shots.sh` 用 `timeout` 兜住，并在烟测后检查残留进程。
