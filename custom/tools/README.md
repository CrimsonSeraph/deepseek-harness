# custom/tools/ — 可独立运行的工具脚本

本目录存放个人定制的命令行工具。约定：

- 每个脚本都能**单独运行**，不依赖 agent、不依赖 DSH；
- 参数一律显式传入或用环境变量覆盖，**脚本内不写死本机绝对路径**；
- 退出码语义明确：`0` 只代表真正成功，失败一律非 0，且失败路径有时间上限（不会挂住）。

当前工具集是 **Qt/QML 窗口截图链路**：给 Qt/QML 桌面应用启动真实窗口，
按窗口句柄抓图，用于视觉检查与多尺寸回归对比。

## 依赖

- MSYS2 / Git Bash 环境（提供 `bash`、`cygpath`、`timeout`、`sed`、`od`、`taskkill`）
- Windows PowerShell 5.1（`powershell.exe`）
- Qt 运行时：`qml.exe`（`<Qt 安装根>/<版本>/<kit>/bin`）
- 可选：无。PNG 尺寸校验直接从 IHDR 读，不依赖 python

## 快速开始

```bash
TOOLS=<仓库根>/custom/tools
WORK=<工作目录>          # 放 mod/、templates/、shots/、logs/
mkdir -p "$WORK/templates"
cp "$TOOLS/../skills/qt-screenshot/resources/single.qml.example" "$WORK/templates/single.qml"
cp "$TOOLS/../skills/qt-screenshot/resources/shots.qml.example"  "$WORK/templates/shots.qml"
# 按被测应用改这两个模板，然后：

"$TOOLS/preflight.sh" --qml "$WORK/templates/single.qml" --src <QML 源目录> \
    --module-dir "$WORK/mod" --module <模块名> --kill

"$TOOLS/run_shots.sh" --src <QML 源目录> --work-dir "$WORK" --module <模块名> \
    --template "$WORK/templates/single.qml" --shots-qml "$WORK/templates/shots.qml" \
    --timeout 10 --clean-module --kill-stale \
    --size 1180x760:desktop:desktop-1180x760 \
    --size 320x568:mobile:mobile-320x568
```

## 环境变量

| 变量 | 作用 | 默认 |
| --- | --- | --- |
| `QT_BIN_DIR` | Qt bin 目录（含 `qml.exe`），最高优先级 | 自动探测 |
| `QT_ROOT_DIR` | Qt 安装根目录，参与自动探测 | 空 |
| `QT_SEARCH_ROOTS` | 自动探测时扫描的根目录列表 | `/c/Qt /d/Qt /e/Qt /f/Qt` |
| `QT_KIT` | 同一版本有多个 kit 时优先匹配的 kit 名 | `mingw` |
| `SHOT_WORK_DIR` | 工作目录 | 系统临时目录 `/qml-shot` |
| `SHOT_TITLE` | 目标窗口标题标识 | `SHOTWIN` |
| `SHOT_TIMEOUT` | 单尺寸整体预算秒数 | `10` |
| `SHOT_BACKEND` | Qt Quick 后端 | `software` |
| `QT_SHOT_TOOLS` | 工具目录位置（skill 正文用它定位脚本） | 空 |

## lib.sh

共用函数库，被同目录脚本以 `source` 方式加载，不单独执行。
导出：日志与 `die`、`abs_path` / `to_winpath`（`cygpath -w`）、`safe_rm_rf`（删除前校验路径在工作目录内）、
`winpid_of`（MSYS PID → Windows PID）、`proc_alive` / `winpid_alive`、
`kill_render_process` / `kill_stale_renderers`、`qt_bin_dir`、`now_ms`、
`png_size`（读 IHDR 取真实宽高）、`report_qml_log`（提炼日志里的 QML 错误）。

## preflight.sh

截图前的环境自检：必需命令、Qt 与 `qml.exe`、残留 `qml.exe`、QML 源目录、
`qmldir` 正确性（模块头 / 每个 `*.qml` 都有条目）、截图模板的三个标记与标题标识。

```bash
preflight.sh [--qml <模板>] [--src <QML 源目录>] [--module-dir <模块根>]
             [--module <名字>] [--title <标题标识>] [--qt-bin <目录>] [--kill]
```

退出码：`0` 通过；`3` 有检查项不通过（缺什么会逐条列出）。

## cap.ps1

按窗口标题（可选按 Windows PID）定位**可见**窗口，用 `PrintWindow(PW_RENDERFULLCONTENT)`
抓取该窗口自身位图并保存为 PNG。不抓全屏，因此不会被其它窗口遮挡，也不会拍进桌面无关内容。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File cap.ps1 `
  -TitlePart SHOTWIN -OutPath <输出.png> [-TargetPid <winpid>] [-TimeoutSec 10]
```

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-TitlePart` | 必填 | 标题需包含的子串 |
| `-OutPath` | 必填（`-List` 除外） | 输出 PNG（Windows 路径） |
| `-TimeoutSec` | `10` | 等窗口的硬上限，**从脚本启动算起**（含 `Add-Type` 编译时间） |
| `-PollMs` | `200` | 轮询间隔毫秒 |
| `-SettleMs` | `600` | 找到窗口后等首次绘制的毫秒数 |
| `-MinBytes` | `512` | 判定 PNG 非空的最小字节数 |
| `-TargetPid` | `0` | 只接受属于该进程的窗口；进程退出立刻返回 7 |
| `-Exact` | 关 | 标题完全相等才算匹配 |
| `-List` | 关 | 只枚举候选窗口（含可见性、句柄、PID、尺寸），不抓图 |
| `-IncludeHidden` | 关 | 枚举时把不可见窗口也算进来（排查用） |
| `-NoBlankCheck` | 关 | 关闭空白帧检测（不推荐） |
| `-BlankRatio` | `0.995` | 客户区主色占比达到该值即判为空白帧 |
| `-CaptureRetries` | `5` | 空白帧重试次数（每次先 `RedrawWindow` 强制重绘） |
| `-RetryDelayMs` | `400` | 空白帧重试间隔毫秒 |
| `-AllowScreenFallback` | 关 | 允许最后退化到抓屏（默认关闭） |
| `-LegacyDpiScale` | 关 | 宿主 DPI 感知声明失败时按注册表缩放还原物理像素 |
| `-Quiet` | 关 | 只输出最终结果行 |

成功时输出一行：

```
OK hwnd=0x005A0DF2 pid=14736 title=[SHOTWIN] size=1493x997 dpi=120 method=printwindow bytes=53621 file=...png
```

失败时输出 `ERROR <退出码> <原因>`。退出码：

| 码 | 含义 |
| --- | --- |
| 0 | 成功 |
| 1 | 在 `-TimeoutSec` 内没找到标题匹配的**可见**窗口（超时不会无限等待） |
| 2 | 窗口矩形非法（宽或高 ≤ 0） |
| 3 | 抓图失败（`PrintWindow` / `BitBlt` / `CopyFromScreen` 全部失败） |
| 4 | PNG 未写出、为空或小于 `-MinBytes` |
| 5 | 抓到空白帧（客户区整幅同色），调试图仍会保存供排查 |
| 6 | 内部错误（`Add-Type`、`System.Drawing`、P/Invoke 编译失败） |
| 7 | `-TargetPid` 指定的进程已退出 |

> **编码要求**：`cap.ps1` 必须保存为 **UTF-8 with BOM**。
> Windows PowerShell 5.1 会把无 BOM 的 `.ps1` 当 ANSI/GBK 解析，中文注释会变成乱码并报出
> `Missing expression after ','` 之类与真实原因无关的语法错误。

## shoot.sh

抓单个尺寸：生成 `cur.qml` → 清残留 → 启动 `qml.exe` → 等窗口 → 调 `cap.ps1` 抓图 →
校验 PNG → 清理进程与临时文件。

```bash
shoot.sh [选项] <宽> <高> <desktop|mobile> <输出名>

  --qml <file>         截图入口模板（必须含 targetWidth / targetHeight / kind 三个标记）
  --out-dir <dir>      输出目录，PNG 写到 <out-dir>/<输出名>.png
  --log-dir <dir>      日志目录（默认 <工作目录>/logs）
  --work-dir <dir>     工作目录
  --module-dir <dir>   QML 模块根目录（作为 qml.exe -I）
  --module <name>      QML 模块名
  --title <text>       目标窗口标题标识（默认 SHOTWIN）
  --timeout <sec>      从启动 qml.exe 到抓到图的整体预算（默认 10）
  --settle-ms <ms>     找到窗口后的稳定等待（默认 600）
  --qt-bin <dir>       Qt bin 目录
  --backend <name>     Qt Quick 后端（默认 software）
  --strict-size        要求 PNG 尺寸与请求尺寸一致
  --keep-temp          保留 cur-*.qml
  --kill-stale         抓图前清理残留 qml.exe
```

退出码：`0` 成功 / `2` 参数错误 / `3` 前置条件不满足（含模板缺标记）/
`4` QML 进程异常退出 / `5` 截图失败 / `6` 截图看门狗超时 / `7` 输出 PNG 无效。

成功时输出：

```
OK name=desktop-1180x760 kind=desktop requested=1180x760 actual=1493x997 bytes=53621 elapsed=2578ms file=...png
```

`actual` 是含窗口边框的物理像素（125% 缩放时约等于 逻辑尺寸 × 1.25 + 边框），
与 `requested` 不同属正常；需要严格相等时加 `--strict-size`。

## run_shots.sh

批量流程：前置自检 → 建模块目录与 `qmldir` → 离屏烟测 → 逐尺寸调用 `shoot.sh` → 汇总表。

```bash
run_shots.sh --src <QML 源目录> [选项] [--size 宽x高:desktop|mobile:输出名 ...]

  --work-dir / --out-dir / --log-dir / --module-dir / --module / --template / --shots-qml
  --title / --timeout / --offscreen-timeout <秒，默认 60>
  --size <规格>        可重复；不给时使用内置常用尺寸表
  --clean-module       抓图前清空模块目录
  --clean-shots        抓图前清空输出目录（会删掉上一轮截图，默认关闭）
  --no-offscreen       跳过离屏烟测
  --no-preflight       跳过前置自检
  --keep-going         某个尺寸失败后继续跑其余尺寸（默认失败即停）
  --keep-temp / --kill-stale
```

退出码：`0` 全部成功 / `2`、`3` 同 `shoot.sh` / `4` 离屏烟测失败（超时未退出、退出码非 0、
或日志里存在 `TypeError` / `ReferenceError` / `is not a function` / `SyntaxError` 等 QML 错误）/
其它情况沿用**首个失败尺寸**的 `shoot.sh` 退出码。

成功时打印汇总表（名称、PNG 真实尺寸、字节数、文件路径）。

## selftest.sh

故意失败测试：验证「出不来、给错、崩溃、空白」这些路径都有时间上限并且返回非 0。

```bash
selftest.sh --template <可用模板> [--module-dir <模块根>] [--work-dir <目录>]
            [--timeout <秒>] [--qt-bin <目录>]
```

用例与期望：

| 用例 | 期望退出码 | 时间上限 |
| --- | --- | --- |
| `marker-missing` 模板缺标记 | 3 | 5s |
| `window-missing` 标题永不匹配 | 5 | `--timeout` |
| `qml-crash` QML 加载即失败 | 4 | `--timeout` |
| `cap-timeout` `cap.ps1` 找不到窗口 | 1 | `-TimeoutSec` + 3s |
| `hidden-window` 进程活着但窗口从不显示 | 1 且不产出 PNG | `-TimeoutSec` + 3s |
| `no-residual` 跑完后没有残留 `qml.exe` | — | — |

退出码：`0` 全部符合预期 / `1` 有不符合预期的用例 / `3` 前置条件不满足。

## 设计约束

这些约束是本工具集存在的理由，改动脚本时不要退化：

1. 任何等待都有硬上限，并且**从上一次调用的起点计时**，不出现「超时 + 未知开销」。
2. 失败一律非 0，绝不「卡住」或「假装成功」；外部再套一层看门狗兜底。
3. 抓图必须按窗口句柄，禁止全屏截图（遮挡与隐私风险）。
4. 产物必须校验：文件存在、非空、PNG 头可解析、客户区不是空白帧。
5. 清理用 `taskkill //F //T //PID <winpid>`，只针对本次启动的进程；按镜像名杀进程只作兜底。
6. 删除文件/目录必须显式开启（`--clean-*`）且校验目标在工作目录之内，禁止无保护的 `rm -rf`。
7. 传给 Windows 原生命令的路径一律经 `cygpath -w -a` 转换。
