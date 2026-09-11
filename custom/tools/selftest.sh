#!/usr/bin/env bash
# selftest.sh — 故意失败测试：证明脚本在窗口出不来 / 模板不合法 / QML 崩溃时
#               会在有限时间内以非 0 退出，而不是卡住或假装成功。
#
# 用例:
#   1 marker-missing   模板缺少 targetWidth/targetHeight/kind 标记 → 期望 3，且 5s 内返回
#   2 window-missing   窗口标题永远不匹配 → 期望 5（cap.ps1 超时未找到窗口），且整体不超过 --timeout
#   3 qml-crash        QML 加载即失败 → 期望 4（进程秒退），且不超过预算
#   4 cap-timeout      cap.ps1 直接面对不存在的窗口 → 期望 1，且不超过 TimeoutSec + 3s
#   5 hidden-window    进程活着但窗口从不显示 → 期望 1（可见窗口过滤），且不产出任何 PNG
#   6 no-residual      全部用例跑完后没有残留 qml.exe
#
# 用法: selftest.sh --template <可用模板> [--module-dir <模块根>] [--work-dir <目录>]
#                    [--timeout <秒>] [--qt-bin <目录>]
# 退出码: 0 全部用例通过 / 1 有用例不符合预期 / 3 前置条件不满足
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

usage() {
    cat >&2 <<'EOF'
用法: selftest.sh --template <可用的截图模板> [选项]

  --template <file>   正常模板（必需；用于 window-missing 与 qml-crash 用例）
  --module-dir <dir>  QML 模块根目录（可选）
  --work-dir <dir>    临时工作目录（默认系统临时目录/qt-shot-selftest）
  --timeout <sec>     shoot.sh 侧整体预算（默认 10）
  --qt-bin <dir>      Qt bin 目录（含 qml.exe）
  -h, --help          显示本帮助

退出码: 0 全部符合预期 / 1 存在不符合预期的用例 / 3 前置条件不满足
EOF
}

TEMPLATE=""
MODULE_DIR=""
WORK_DIR="${TMPDIR:-/tmp}/qt-shot-selftest"
TIMEOUT="${SHOT_TIMEOUT:-10}"
QT_BIN=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --template)   TEMPLATE="${2:-}"; shift 2 ;;
        --module-dir) MODULE_DIR="${2:-}"; shift 2 ;;
        --work-dir)   WORK_DIR="${2:-}"; shift 2 ;;
        --timeout)    TIMEOUT="${2:-}"; shift 2 ;;
        --qt-bin)     QT_BIN="${2:-}"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage; die 3 "未知选项: $1" ;;
    esac
done

[ -n "$TEMPLATE" ] || { usage; die 3 "必须指定 --template"; }
TEMPLATE="$(abs_path "$TEMPLATE")"
[ -f "$TEMPLATE" ] || die 3 "模板不存在: $TEMPLATE"

WORK_DIR="$(abs_path "$WORK_DIR")"
mkdir -p "$WORK_DIR"
if [ -z "$QT_BIN" ]; then
    QT_BIN="$(qt_bin_dir || true)"
fi
[ -n "$QT_BIN" ] || die 3 "找不到 Qt bin 目录（设置 QT_BIN_DIR）"
export PATH="${QT_BIN}:${PATH}"

PASS=0
FAIL=0
LAST_RC=0
LAST_MS=0
LAST_LOG=""

run_timed() {
    local log="$1"; shift
    local t0 t1
    t0="$(now_ms)"
    set +e
    "$@" > "$log" 2>&1
    LAST_RC=$?
    set -e
    t1="$(now_ms)"
    LAST_MS=$(( t1 - t0 ))
    LAST_LOG="$log"
}

check_case() {
    local name="$1" expect_rc="$2" max_ms="$3" desc="$4"
    if [ "$LAST_RC" -eq "$expect_rc" ] && [ "$LAST_MS" -le "$max_ms" ]; then
        PASS=$((PASS + 1))
        printf 'PASS %-16s rc=%s(期望 %s) 用时=%sms(上限 %sms)  %s\n' \
            "$name" "$LAST_RC" "$expect_rc" "$LAST_MS" "$max_ms" "$desc"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL %-16s rc=%s(期望 %s) 用时=%sms(上限 %sms)  %s\n' \
            "$name" "$LAST_RC" "$expect_rc" "$LAST_MS" "$max_ms" "$desc" >&2
        printf '----- %s 输出尾部 -----\n' "$LAST_LOG" >&2
        tail -n 12 "$LAST_LOG" >&2 || true
    fi
}

SHOOT="${SCRIPT_DIR}/shoot.sh"
CAP="${SCRIPT_DIR}/cap.ps1"
COMMON_ARGS=(--work-dir "$WORK_DIR/work" --out-dir "$WORK_DIR/shots" --log-dir "$WORK_DIR/logs")
if [ -n "$MODULE_DIR" ]; then
    COMMON_ARGS+=(--module-dir "$(abs_path "$MODULE_DIR")")
fi

printf '==== Qt 截图工具 故意失败测试 ====\n'
printf '模板: %s\n模块: %s\n预算: %ss\n\n' "$TEMPLATE" "${MODULE_DIR:-<未指定>}" "$TIMEOUT"

# ---------------------------------------------------------------- 用例 1
BAD_TEMPLATE="${WORK_DIR}/template-no-marker.qml"
printf 'import QtQuick\nItem { }\n' > "$BAD_TEMPLATE"
run_timed "${WORK_DIR}/case1.log" \
    "$SHOOT" "${COMMON_ARGS[@]}" --qml "$BAD_TEMPLATE" --timeout "$TIMEOUT" \
    320 568 mobile selftest-no-marker
check_case "marker-missing" 3 5000 "模板缺标记必须立刻失败"

# ---------------------------------------------------------------- 用例 2
run_timed "${WORK_DIR}/case2.log" \
    "$SHOOT" "${COMMON_ARGS[@]}" --qml "$TEMPLATE" --timeout "$TIMEOUT" \
    --title "SHOTWIN-SELFTEST-ABSENT" \
    320 568 mobile selftest-window-missing
check_case "window-missing" 5 $(( TIMEOUT * 1000 )) "窗口等不到必须在 --timeout 预算内失败，不能挂住"

# ---------------------------------------------------------------- 用例 3
BROKEN_TEMPLATE="${WORK_DIR}/template-broken.qml"
cat > "$BROKEN_TEMPLATE" <<'EOF'
// 故意失败测试夹具：import 一个不存在的模块，qml.exe 加载即失败退出
import QtQuick
import ThisModuleDoesNotExist 1.0

Item {
    property int targetWidth: 320
    property int targetHeight: 568
    property string kind: "mobile"
}
EOF
run_timed "${WORK_DIR}/case3.log" \
    "$SHOOT" "${COMMON_ARGS[@]}" --qml "$BROKEN_TEMPLATE" --timeout "$TIMEOUT" \
    320 568 mobile selftest-qml-crash
check_case "qml-crash" 4 $(( TIMEOUT * 1000 )) "QML 崩溃必须被识别为进程异常退出"

# ---------------------------------------------------------------- 用例 4
CAP_TIMEOUT=4
CAP_OUT_WIN="$(to_winpath "${WORK_DIR}/cap-should-not-exist.png")"
rm -f "${WORK_DIR}/cap-should-not-exist.png"
run_timed "${WORK_DIR}/case4.log" \
    powershell -NoProfile -ExecutionPolicy Bypass -File "$CAP" \
    -TitlePart "SHOTWIN-SELFTEST-ABSENT" -TimeoutSec "$CAP_TIMEOUT" -OutPath "$CAP_OUT_WIN"
check_case "cap-timeout" 1 $(( (CAP_TIMEOUT + 3) * 1000 )) "cap.ps1 轮询必须带硬超时"

# ---------------------------------------------------------------- 用例 5
# 历史故障：同名但 visible: false 的兄弟窗口会被抓到，产出一张纯背景色的 PNG。
# 这里用「进程活着但窗口从不显示」的夹具，要求 cap.ps1 不产出任何 PNG 并以 1 结束。
HIDDEN_QML="${WORK_DIR}/hidden-window.qml"
cat > "$HIDDEN_QML" <<'EOF'
// 故意失败测试夹具：进程活着，但窗口永不显示（visible: false）
import QtQuick
Window {
    property int targetWidth: 320
    property int targetHeight: 568
    property string kind: "mobile"
    title: "SHOTWIN"
    width: 320
    height: 568
    visible: false
    Timer { interval: 60000; running: true; repeat: true }
}
EOF
QT_QUICK_BACKEND="${SHOT_BACKEND:-software}" qml.exe "$(to_winpath "$HIDDEN_QML")" > "${WORK_DIR}/case5-qml.log" 2>&1 &
HID_PID=$!
disown "$HID_PID" 2>/dev/null || true
HID_WINPID="$(winpid_of "$HID_PID" || true)"
sleep 1.5
HID_OUT="${WORK_DIR}/hidden-should-not-exist.png"
rm -f "$HID_OUT"
run_timed "${WORK_DIR}/case5.log" \
    powershell -NoProfile -ExecutionPolicy Bypass -File "$CAP" \
    -TitlePart "SHOTWIN" -TargetPid "${HID_WINPID:-0}" -TimeoutSec "$CAP_TIMEOUT" -OutPath "$(to_winpath "$HID_OUT")"
check_case "hidden-window" 1 $(( (CAP_TIMEOUT + 3) * 1000 )) "不可见窗口必须拒绝抓图，不能产出纯背景 PNG"
if [ -e "$HID_OUT" ]; then
    FAIL=$((FAIL + 1))
    printf 'FAIL %-16s 不可见窗口仍然产出了 PNG: %s\n' "hidden-window-png" "$HID_OUT" >&2
fi
kill_render_process "$HID_PID" "${HID_WINPID:-}"

# ---------------------------------------------------------------- 用例 6
STALE="$(tasklist //FI "IMAGENAME eq qml.exe" //NH 2>/dev/null | grep -i "qml.exe" || true)"
if [ -z "$STALE" ]; then
    PASS=$((PASS + 1))
    printf 'PASS %-16s %s\n' "no-residual" "没有残留 qml.exe"
else
    FAIL=$((FAIL + 1))
    printf 'FAIL %-16s 残留进程:\n%s\n' "no-residual" "$STALE" >&2
fi

printf '\n===== 结果: %s 通过, %s 失败 =====\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
