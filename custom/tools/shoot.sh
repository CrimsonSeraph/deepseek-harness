#!/usr/bin/env bash
# shoot.sh — 启动一次 Qt/QML 窗口并抓取指定尺寸的截图
#
# 设计要点（针对历史上出现过的卡死/静默失败）：
#   * set -euo pipefail + trap cleanup EXIT/INT/TERM：失败一定非 0 退出，且一定清理进程与临时文件；
#   * --timeout 是「从启动 qml.exe 到抓图完成」的整体预算，超时以退出码 6 结束；
#   * 外层再套 coreutils timeout 看门狗，即使 cap.ps1 本身卡住也不会拖住调用方；
#   * 启动后确认进程存活，进程死了立刻报错并回显 QML 错误（不再等到超时）；
#   * 校验 cap.ps1 退出码、PNG 存在、PNG 非空、PNG 真实尺寸（从 IHDR 读）；
#   * 清理用 taskkill //F //T //PID <winpid>，且只针对本次启动的进程。
#
# 用法: shoot.sh [选项] <宽> <高> <desktop|mobile> <输出名>
# 退出码: 0 成功 / 2 参数错误 / 3 前置条件失败 / 4 QML 进程异常退出 /
#         5 截图失败 / 6 看门狗超时 / 7 输出 PNG 无效
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

usage() {
    cat >&2 <<'EOF'
用法: shoot.sh [选项] <宽> <高> <desktop|mobile> <输出名>

必填位置参数:
  宽 高               目标窗口尺寸（逻辑像素，配合模板里的 targetWidth/targetHeight）
  desktop|mobile      使用哪个窗口（写入模板的 kind 属性）
  输出名              输出文件名（不含扩展名），只允许 [A-Za-z0-9._-]

选项:
  --qml <file>        截图入口 QML 模板；必须包含
                        property int targetWidth: ...
                        property int targetHeight: ...
                        property string kind: "..."
                      三行标记，缺失即失败退出（不再静默按错误尺寸截图）
  --out-dir <dir>     输出目录，PNG 写到 <out-dir>/<输出名>.png
  --log-dir <dir>     日志目录（默认 <工作目录>/logs）
  --work-dir <dir>    工作目录（默认 $SHOT_WORK_DIR 或系统临时目录/qml-shot）
  --module-dir <dir>  QML 模块根目录（内含 <模块名>/qmldir），作为 qml.exe -I 参数
  --module <name>     QML 模块名（默认 Schedule）
  --title <text>      目标窗口标题标识（默认 $SHOT_TITLE 或 SHOTWIN）
  --timeout <sec>     从启动 qml.exe 到抓到图的整体预算秒数（默认 $SHOT_TIMEOUT 或 10）
  --settle-ms <ms>    找到窗口后的稳定等待毫秒数（默认 600）
  --qt-bin <dir>      Qt bin 目录（含 qml.exe）；默认自动探测
  --backend <name>    Qt Quick 后端（默认 software，抓图稳定性优先）
  --strict-size       要求 PNG 尺寸与请求尺寸一致，否则以退出码 7 失败
  --keep-temp         保留生成的 cur-*.qml 与日志
  --kill-stale        抓图前先清理残留的 qml.exe（会误伤无关 qml 进程，默认关闭）
  -h, --help          显示本帮助

环境变量: QT_BIN_DIR QT_ROOT_DIR QT_SEARCH_ROOTS SHOT_WORK_DIR SHOT_TITLE SHOT_TIMEOUT SHOT_BACKEND
EOF
}

QML_TEMPLATE=""
OUT_DIR=""
LOG_DIR=""
WORK_DIR=""
MODULE_DIR=""
MODULE_NAME="Schedule"
TITLE="${SHOT_TITLE:-SHOTWIN}"
TIMEOUT="${SHOT_TIMEOUT:-10}"
SETTLE_MS=600
QT_BIN=""
BACKEND="${SHOT_BACKEND:-software}"
KEEP_TEMP=0
STRICT_SIZE=0
KILL_STALE=0
POSITIONAL=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --qml)        QML_TEMPLATE="${2:-}"; shift 2 ;;
        --out-dir)    OUT_DIR="${2:-}"; shift 2 ;;
        --log-dir)    LOG_DIR="${2:-}"; shift 2 ;;
        --work-dir)   WORK_DIR="${2:-}"; shift 2 ;;
        --module-dir) MODULE_DIR="${2:-}"; shift 2 ;;
        --module)     MODULE_NAME="${2:-}"; shift 2 ;;
        --title)      TITLE="${2:-}"; shift 2 ;;
        --timeout)    TIMEOUT="${2:-}"; shift 2 ;;
        --settle-ms)  SETTLE_MS="${2:-}"; shift 2 ;;
        --qt-bin)     QT_BIN="${2:-}"; shift 2 ;;
        --backend)    BACKEND="${2:-}"; shift 2 ;;
        --strict-size) STRICT_SIZE=1; shift ;;
        --keep-temp)  KEEP_TEMP=1; shift ;;
        --kill-stale) KILL_STALE=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        --)           shift; POSITIONAL+=("$@"); break ;;
        -*)           usage; die 2 "未知选项: $1" ;;
        *)            POSITIONAL+=("$1"); shift ;;
    esac
done

[ "${#POSITIONAL[@]}" -eq 4 ] || { usage; die 2 "需要 4 个位置参数，实际 ${#POSITIONAL[@]} 个"; }

W="${POSITIONAL[0]}"
H="${POSITIONAL[1]}"
KIND="${POSITIONAL[2]}"
NAME="${POSITIONAL[3]}"

case "$W" in ''|*[!0-9]*) die 2 "宽必须是正整数: $W" ;; esac
case "$H" in ''|*[!0-9]*) die 2 "高必须是正整数: $H" ;; esac
[ "$W" -gt 0 ] && [ "$W" -le 10000 ] || die 2 "宽超出范围(1-10000): $W"
[ "$H" -gt 0 ] && [ "$H" -le 10000 ] || die 2 "高超出范围(1-10000): $H"
case "$KIND" in desktop|mobile) : ;; *) die 2 "第三个参数必须是 desktop 或 mobile: $KIND" ;; esac
case "$NAME" in ''|*[!A-Za-z0-9._-]*) die 2 "输出名只允许 [A-Za-z0-9._-]: $NAME" ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) die 2 "--timeout 必须是正整数秒: $TIMEOUT" ;; esac
[ "$TIMEOUT" -ge 3 ] || die 2 "--timeout 至少 3 秒（当前 $TIMEOUT）"

[ -n "$QML_TEMPLATE" ] || die 2 "缺少 --qml <模板文件>"
[ -f "$QML_TEMPLATE" ] || die 3 "模板文件不存在: $QML_TEMPLATE"

WORK_DIR="$(abs_path "${WORK_DIR:-${SHOT_WORK_DIR:-${TMPDIR:-/tmp}/qml-shot}}")"
MODULE_DIR="$(abs_path "${MODULE_DIR:-${WORK_DIR}/mod}")"
OUT_DIR="$(abs_path "${OUT_DIR:-${WORK_DIR}/shots}")"
LOG_DIR="$(abs_path "${LOG_DIR:-${WORK_DIR}/logs}")"
QML_TEMPLATE="$(abs_path "$QML_TEMPLATE")"

need_cmd cygpath powershell timeout taskkill sed grep od

if [ -z "$QT_BIN" ]; then
    QT_BIN="$(qt_bin_dir || true)"
fi
[ -n "$QT_BIN" ] || die 3 "找不到 Qt bin 目录（请设置 QT_BIN_DIR 或在 PATH 中加入 Qt 的 <版本>/<kit>/bin）"
[ -x "${QT_BIN}/qml.exe" ] || die 3 "QT_BIN 下没有 qml.exe: ${QT_BIN}/qml.exe"
export PATH="${QT_BIN}:${PATH}"
need_cmd qml.exe

mkdir -p "$WORK_DIR" "$OUT_DIR" "$LOG_DIR" || die 3 "工作目录创建失败"

if [ "$KILL_STALE" -eq 1 ]; then
    kill_stale_renderers
fi

OUT_PNG="${OUT_DIR}/${NAME}.png"
LOG_FILE="${LOG_DIR}/single-${NAME}.log"
CAP_LOG="${LOG_DIR}/single-${NAME}.cap.log"
CUR_QML="${WORK_DIR}/cur-${NAME}.qml"

# ---------------------------------------------------------------- 生成 cur.qml
# 三个标记必须都存在：缺失时 sed 会静默不改，截出来的就是错误尺寸 —— 这里直接失败
for marker in 'property int targetWidth:' 'property int targetHeight:' 'property string kind:'; do
    grep -qF -- "$marker" "$QML_TEMPLATE" || die 3 "模板缺少标记 \"$marker\": $QML_TEMPLATE"
done

sed -e "s/property int targetWidth: .*/property int targetWidth: ${W}/" \
    -e "s/property int targetHeight: .*/property int targetHeight: ${H}/" \
    -e "s/property string kind: .*/property string kind: \"${KIND}\"/" \
    -- "$QML_TEMPLATE" > "$CUR_QML"

grep -qE "^[[:space:]]*property int targetWidth: ${W}[[:space:]]*$" "$CUR_QML" || die 3 "targetWidth 替换失败"
grep -qE "^[[:space:]]*property int targetHeight: ${H}[[:space:]]*$" "$CUR_QML" || die 3 "targetHeight 替换失败"
grep -qE "^[[:space:]]*property string kind: \"${KIND}\"[[:space:]]*$" "$CUR_QML" || die 3 "kind 替换失败"

rm -f -- "$OUT_PNG"

# ---------------------------------------------------------------- 启动 + 清理
PID=""
WINPID=""
cleanup() {
    local rc=$?
    kill_render_process "${PID:-}" "${WINPID:-}"
    if [ "$KEEP_TEMP" -eq 0 ]; then
        rm -f -- "$CUR_QML" 2>/dev/null || true
    fi
    return "$rc"
}
trap cleanup EXIT INT TERM

START_MS="$(now_ms)"
: > "$LOG_FILE"
MODULE_WIN="$(to_winpath "$MODULE_DIR")"
CUR_QML_WIN="$(to_winpath "$CUR_QML")"
OUT_WIN="$(to_winpath "$OUT_PNG")"

log "启动 qml.exe: ${W}x${H} ${KIND} -> ${OUT_PNG}"
cd "$WORK_DIR"
QT_QUICK_BACKEND="$BACKEND" qml.exe -I "$MODULE_WIN" "$CUR_QML_WIN" > "$LOG_FILE" 2>&1 &
PID=$!

# 取 Windows PID（cap.ps1 用它过滤窗口，避免抓到上一轮残留窗口）
for _ in $(seq 1 20); do
    WINPID="$(winpid_of "$PID" || true)"
    if [ -n "$WINPID" ]; then
        break
    fi
    sleep 0.05
done
[ -n "$WINPID" ] || warn "未能取得 Windows PID，窗口过滤退化为按标题匹配"
# 从 shell 作业表移除：清理走 taskkill，不需要 bash 再打印作业终止通知
disown "$PID" 2>/dev/null || true

# 进程是否活着（QML 语法错误/TypeError 会让它秒退；cap.ps1 也会用 -TargetPid 兜住后续退出）
sleep 0.3
if ! proc_alive "$PID"; then
    err "QML 进程启动后立即退出（pid=${PID}）"
    report_qml_log "$LOG_FILE"
    die 4 "QML 进程异常退出: ${NAME}"
fi

# ---------------------------------------------------------------- 截图
# --timeout 是整体预算：减去已经花掉的时间，再预留 3.5s 给 PowerShell 启动、收尾与清理。
# 这样默认 --timeout 10 时，任何失败路径都在 10s 内以非 0 退出（含清理时间）。
ELAPSED_MS=$(( $(now_ms) - START_MS ))
REMAIN_MS=$(( TIMEOUT * 1000 - ELAPSED_MS - 3500 ))
CAP_TIMEOUT=$(( REMAIN_MS / 1000 ))
[ "$CAP_TIMEOUT" -ge 2 ] || CAP_TIMEOUT=2
[ "$CAP_TIMEOUT" -le "$TIMEOUT" ] || CAP_TIMEOUT="$TIMEOUT"

log "等待窗口标题包含 [${TITLE}]，最多 ${CAP_TIMEOUT}s（整体预算 ${TIMEOUT}s）"

set +e
timeout --kill-after=3 $(( TIMEOUT + 10 )) \
    powershell -NoProfile -ExecutionPolicy Bypass -File "${SCRIPT_DIR}/cap.ps1" \
    -TitlePart "$TITLE" \
    -TargetPid "${WINPID:-0}" \
    -TimeoutSec "$CAP_TIMEOUT" \
    -SettleMs "$SETTLE_MS" \
    -OutPath "$OUT_WIN" > "$CAP_LOG" 2>&1
CAP_RC=$?
set -e

if [ "$CAP_RC" -eq 124 ] || [ "$CAP_RC" -eq 137 ]; then
    err "截图看门狗触发（cap.ps1 超过 $(( TIMEOUT + 10 ))s 未返回）——这属于脚本缺陷，请检查 cap.ps1"
    tail -n 5 "$CAP_LOG" >&2 || true
    die 6 "截图看门狗超时: ${NAME}"
fi

if [ "$CAP_RC" -ne 0 ]; then
    CAP_ERR="$(grep -m1 -E '^ERROR [0-9]+ ' "$CAP_LOG" 2>/dev/null || true)"
    [ -n "$CAP_ERR" ] || CAP_ERR="ERROR ${CAP_RC} (cap.ps1 未输出结构化错误)"
    case "$CAP_RC" in
        7) report_qml_log "$LOG_FILE"; die 4 "QML 进程在等待窗口期间退出: ${CAP_ERR}" ;;
        *) report_qml_log "$LOG_FILE"; die 5 "截图失败: ${CAP_ERR}" ;;
    esac
fi

log "$(grep -m1 -E '^OK ' "$CAP_LOG" 2>/dev/null || true)"

# ---------------------------------------------------------------- 校验产物
[ -f "$OUT_PNG" ] || die 7 "PNG 未生成: $OUT_PNG"
BYTES="$(file_size "$OUT_PNG")"
[ "$BYTES" -gt 0 ] || die 7 "PNG 为空文件: $OUT_PNG"
ACTUAL="$(png_size "$OUT_PNG" || true)"
[ -n "$ACTUAL" ] || die 7 "PNG 头部解析失败（不是有效 PNG）: $OUT_PNG"

REQUESTED="${W}x${H}"
GEOMETRY_NOTE=""
if [ "$ACTUAL" != "$REQUESTED" ]; then
    # 窗口有最小尺寸/边框时，实际抓到的像素尺寸与请求尺寸不同属正常现象
    GEOMETRY_NOTE=" (请求 ${REQUESTED}，实际含窗口边框)"
    if [ "$STRICT_SIZE" -eq 1 ]; then
        die 7 "PNG 尺寸 ${ACTUAL} 与请求 ${REQUESTED} 不一致（--strict-size）"
    fi
fi

ELAPSED_MS=$(( $(now_ms) - START_MS ))
printf 'OK name=%s kind=%s requested=%s actual=%s bytes=%s elapsed=%sms file=%s%s\n' \
    "$NAME" "$KIND" "$REQUESTED" "$ACTUAL" "$BYTES" "$ELAPSED_MS" "$OUT_PNG" "$GEOMETRY_NOTE"
exit 0
