#!/usr/bin/env bash
# run_shots.sh — 批量跑通「构建 QML 模块 → 离屏烟测 → 逐尺寸抓图 → 汇总」的完整流程
#
# 与历史临时脚本的区别：
#   * 不再无条件 rm -rf：只有 --clean-module / --clean-shots 才删，且删除前校验路径位于工作目录之内；
#   * 离屏烟测的退出码会被检查，日志里的 QML 错误会让整批失败，不再“打印一下退出码就算完”；
#   * 离屏进程会被回收，残留 qml.exe 会被报告；
#   * 每个尺寸都走 shoot.sh（带超时、trap、PNG 校验），默认失败即停（--keep-going 才继续）。
#
# 用法:
#   run_shots.sh --src <QML 源目录> [选项] [--size 宽x高:desktop|mobile:输出名 ...]
# 退出码: 0 全部成功 / 2 参数错误 / 3 前置条件失败 / 4 离屏烟测失败 /
#         其它: 与首个失败的 shoot.sh 退出码一致（5 截图失败 / 6 看门狗超时 / 7 PNG 无效）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

DEFAULT_SIZES=(
    "1180x760:desktop:desktop-1180x760"
    "900x600:desktop:desktop-900x600"
    "700x500:desktop:desktop-700x500"
    "640x420:desktop:desktop-640x420"
    "390x844:mobile:mobile-390x844"
    "320x568:mobile:mobile-320x568"
    "844x390:mobile:mobile-844x390"
)

usage() {
    cat >&2 <<'EOF'
用法: run_shots.sh --src <QML 源目录> [选项] [--size 宽x高:desktop|mobile:输出名 ...]

  --src <dir>          QML 源目录（必填，复制其中的 *.qml 到模块目录）
  --work-dir <dir>     工作目录（默认 $SHOT_WORK_DIR 或系统临时目录/qml-shot）
  --out-dir <dir>      截图输出目录（默认 <工作目录>/shots）
  --log-dir <dir>      日志目录（默认 <工作目录>/logs）
  --module <name>      QML 模块名（默认 Schedule）
  --module-dir <dir>   模块根目录（默认 <工作目录>/mod）
  --template <file>    单窗口截图模板（默认 <工作目录>/templates/single.qml）
  --shots-qml <file>   离屏烟测入口（默认 <工作目录>/templates/shots.qml）
  --title <text>       目标窗口标题标识（默认 $SHOT_TITLE 或 SHOTWIN）
  --timeout <sec>      单个尺寸的整体预算秒数（默认 $SHOT_TIMEOUT 或 10）
  --offscreen-timeout <sec>  离屏烟测超时（默认 60）
  --size <规格>        可重复；规格 = 宽x高:desktop|mobile:输出名
                       不给 --size 时使用内置 7 组常用尺寸
  --clean-module       抓图前清空模块目录（默认只覆盖写入）
  --clean-shots        抓图前清空输出目录（会删掉上一轮截图，默认关闭）
  --no-offscreen       跳过离屏烟测
  --no-preflight       跳过前置自检
  --keep-going         某个尺寸失败后继续跑其余尺寸（默认失败即停）
  --keep-temp          保留各尺寸的 cur-*.qml 与日志
  --kill-stale         抓图前清理残留 qml.exe
  -h, --help           显示本帮助

环境变量: QT_BIN_DIR QT_ROOT_DIR QT_SEARCH_ROOTS SHOT_WORK_DIR SHOT_TITLE SHOT_TIMEOUT SHOT_BACKEND
EOF
}

SRC_DIR=""
WORK_DIR=""
OUT_DIR=""
LOG_DIR=""
MODULE_DIR=""
MODULE_NAME="Schedule"
TEMPLATE=""
SHOTS_QML=""
TITLE="${SHOT_TITLE:-SHOTWIN}"
TIMEOUT="${SHOT_TIMEOUT:-10}"
OFFSCREEN_TIMEOUT=60
CLEAN_MODULE=0
CLEAN_SHOTS=0
RUN_OFFSCREEN=1
RUN_PREFLIGHT=1
KEEP_GOING=0
KEEP_TEMP=0
KILL_STALE=0
SIZES=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --src)               SRC_DIR="${2:-}"; shift 2 ;;
        --work-dir)          WORK_DIR="${2:-}"; shift 2 ;;
        --out-dir)           OUT_DIR="${2:-}"; shift 2 ;;
        --log-dir)           LOG_DIR="${2:-}"; shift 2 ;;
        --module)            MODULE_NAME="${2:-}"; shift 2 ;;
        --module-dir)        MODULE_DIR="${2:-}"; shift 2 ;;
        --template)          TEMPLATE="${2:-}"; shift 2 ;;
        --shots-qml)         SHOTS_QML="${2:-}"; shift 2 ;;
        --title)             TITLE="${2:-}"; shift 2 ;;
        --timeout)           TIMEOUT="${2:-}"; shift 2 ;;
        --offscreen-timeout) OFFSCREEN_TIMEOUT="${2:-}"; shift 2 ;;
        --size)              SIZES+=("${2:-}"); shift 2 ;;
        --clean-module)      CLEAN_MODULE=1; shift ;;
        --clean-shots)       CLEAN_SHOTS=1; shift ;;
        --no-offscreen)      RUN_OFFSCREEN=0; shift ;;
        --no-preflight)      RUN_PREFLIGHT=0; shift ;;
        --keep-going)        KEEP_GOING=1; shift ;;
        --keep-temp)         KEEP_TEMP=1; shift ;;
        --kill-stale)        KILL_STALE=1; shift ;;
        -h|--help)           usage; exit 0 ;;
        *)                   usage; die 2 "未知选项: $1" ;;
    esac
done

[ -n "$SRC_DIR" ] || { usage; die 2 "必须指定 --src <QML 源目录>"; }
SRC_DIR="$(abs_path "$SRC_DIR")"
[ -d "$SRC_DIR" ] || die 3 "源目录不存在: $SRC_DIR"

WORK_DIR="$(abs_path "${WORK_DIR:-${SHOT_WORK_DIR:-${TMPDIR:-/tmp}/qml-shot}}")"
OUT_DIR="$(abs_path "${OUT_DIR:-${WORK_DIR}/shots}")"
LOG_DIR="$(abs_path "${LOG_DIR:-${WORK_DIR}/logs}")"
MODULE_DIR="$(abs_path "${MODULE_DIR:-${WORK_DIR}/mod}")"
TEMPLATE="$(abs_path "${TEMPLATE:-${WORK_DIR}/templates/single.qml}")"
SHOTS_QML="$(abs_path "${SHOTS_QML:-${WORK_DIR}/templates/shots.qml}")"

if [ "${#SIZES[@]}" -eq 0 ]; then
    SIZES=("${DEFAULT_SIZES[@]}")
fi

for spec in "${SIZES[@]}"; do
    case "$spec" in
        *:*:*) : ;;
        *) die 2 "--size 规格应为 宽x高:desktop|mobile:输出名，实际: $spec" ;;
    esac
    dims="${spec%%:*}"
    case "$dims" in
        [0-9]*x[0-9]*) : ;;
        *) die 2 "--size 的尺寸部分应为 宽x高，实际: $spec" ;;
    esac
done

[ -f "$TEMPLATE" ] || die 3 "截图模板不存在: $TEMPLATE（可先复制 skill 的 resources/single.qml.example 并改造）"

mkdir -p "$WORK_DIR" "$OUT_DIR" "$LOG_DIR" "$MODULE_DIR"

# ---------------------------------------------------------------- 前置自检
if [ "$RUN_PREFLIGHT" -eq 1 ]; then
    log "前置自检"
    PRE_ARGS=(--qml "$TEMPLATE" --src "$SRC_DIR" --module "$MODULE_NAME" --title "$TITLE")
    if [ "$KILL_STALE" -eq 1 ]; then
        PRE_ARGS+=(--kill)
    fi
    "${SCRIPT_DIR}/preflight.sh" "${PRE_ARGS[@]}" || die 3 "前置自检未通过"
fi

# ---------------------------------------------------------------- 构建模块目录
log "构建 QML 模块: ${SRC_DIR} -> ${MODULE_DIR}/${MODULE_NAME}"
if [ "$CLEAN_MODULE" -eq 1 ]; then
    # 只有显式要求、且路径确实在工作目录之下才删除
    safe_rm_rf "$MODULE_DIR" "$WORK_DIR"
fi
if [ "$CLEAN_SHOTS" -eq 1 ]; then
    safe_rm_rf "$OUT_DIR" "$WORK_DIR"
fi
mkdir -p "${MODULE_DIR}/${MODULE_NAME}" "$OUT_DIR"

shopt -s nullglob
QML_FILES=("$SRC_DIR"/*.qml)
shopt -u nullglob
[ "${#QML_FILES[@]}" -gt 0 ] || die 3 "$SRC_DIR 下没有 *.qml"

cp -f -- "${QML_FILES[@]}" "${MODULE_DIR}/${MODULE_NAME}/"

{
    echo "module ${MODULE_NAME}"
    for f in "${QML_FILES[@]}"; do
        b="$(basename "$f" .qml)"
        echo "${b} 1.0 ${b}.qml"
    done
    echo "depends QtQuick"
} > "${MODULE_DIR}/${MODULE_NAME}/qmldir"

# qmldir 必须覆盖全部 qml，否则 import 会静默缺组件
for f in "${QML_FILES[@]}"; do
    b="$(basename "$f" .qml)"
    grep -qE "^${b}[[:space:]]" "${MODULE_DIR}/${MODULE_NAME}/qmldir" || die 3 "qmldir 条目缺失: ${b}"
done
log "模块目录就绪（${#QML_FILES[@]} 个 QML 文件）"

QT_BIN="$(qt_bin_dir || true)"
[ -n "$QT_BIN" ] || die 3 "找不到 Qt bin 目录（设置 QT_BIN_DIR）"
export PATH="${QT_BIN}:${PATH}"
MODULE_WIN="$(to_winpath "$MODULE_DIR")"

# ---------------------------------------------------------------- 离屏烟测
if [ "$RUN_OFFSCREEN" -eq 1 ]; then
    if [ ! -f "$SHOTS_QML" ]; then
        warn "跳过离屏烟测：入口不存在 $SHOTS_QML"
    else
        OFFSCREEN_LOG="${LOG_DIR}/offscreen.log"
        log "离屏烟测: ${SHOTS_QML}（超时 ${OFFSCREEN_TIMEOUT}s）"
        set +e
        timeout --kill-after=3 "$OFFSCREEN_TIMEOUT" \
            env QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND="${SHOT_BACKEND:-software}" \
            qml.exe -I "$MODULE_WIN" "$(to_winpath "$SHOTS_QML")" > "$OFFSCREEN_LOG" 2>&1
        OFF_RC=$?
        set -e

        # 离屏进程理论上应自行退出；若超时被杀，说明退出路径不干净（退出路径残留会污染后续抓图）
        if [ "$OFF_RC" -eq 124 ] || [ "$OFF_RC" -eq 137 ]; then
            report_qml_log "$OFFSCREEN_LOG" 20
            die 4 "离屏烟测超时（${OFFSCREEN_TIMEOUT}s）未退出，退出路径不干净"
        fi
        if [ "$OFF_RC" -ne 0 ]; then
            report_qml_log "$OFFSCREEN_LOG" 20
            die 4 "离屏烟测失败，退出码 $OFF_RC"
        fi

        if grep -qE "TypeError|ReferenceError|is not a function|SyntaxError|QQmlApplicationEngine failed to load component" "$OFFSCREEN_LOG"; then
            report_qml_log "$OFFSCREEN_LOG" 20
            die 4 "离屏烟测日志里存在 QML 错误，先修 QML 再截图"
        fi
        log "离屏烟测通过（日志 ${OFFSCREEN_LOG}）"
    fi

    STALE="$(tasklist //FI "IMAGENAME eq qml.exe" //NH 2>/dev/null | grep -i "qml.exe" || true)"
    if [ -n "$STALE" ]; then
        warn "离屏烟测后仍有残留 qml.exe，清理:"
        printf '%s\n' "$STALE" >&2
        kill_stale_renderers
    fi
fi

# ---------------------------------------------------------------- 逐尺寸抓图
SHOOT_ARGS=(--qml "$TEMPLATE" --out-dir "$OUT_DIR" --log-dir "$LOG_DIR"
            --work-dir "$WORK_DIR" --module-dir "$MODULE_DIR" --module "$MODULE_NAME"
            --title "$TITLE" --timeout "$TIMEOUT")
if [ "$KEEP_TEMP" -eq 1 ]; then
    SHOOT_ARGS+=(--keep-temp)
fi
if [ "$KILL_STALE" -eq 1 ]; then
    SHOOT_ARGS+=(--kill-stale)
fi

declare -a RESULTS=()
FAILED_CODE=0

for spec in "${SIZES[@]}"; do
    dims="${spec%%:*}"
    rest="${spec#*:}"
    kind="${rest%%:*}"
    name="${rest#*:}"
    W="${dims%%x*}"
    H="${dims#*x}"

    if OUT_LINE="$("${SCRIPT_DIR}/shoot.sh" "${SHOOT_ARGS[@]}" "$W" "$H" "$kind" "$name" 2>&1)"; then
        printf '%s\n' "$OUT_LINE"
        RESULTS+=("$(printf '%s\n' "$OUT_LINE" | grep -m1 '^OK ' || printf 'OK name=%s (no summary)' "$name")")
    else
        RC=$?
        printf '%s\n' "$OUT_LINE" >&2
        err "尺寸 ${spec} 抓图失败（退出码 ${RC}）"
        RESULTS+=("FAIL name=${name} rc=${RC}")
        FAILED_CODE="$RC"
        if [ "$KEEP_GOING" -eq 0 ]; then
            die "$RC" "抓图失败即停（如需跑完其余尺寸请加 --keep-going）"
        fi
    fi
done

# ---------------------------------------------------------------- 汇总
printf '\n===== 抓图汇总 =====\n'
printf '%-22s %-12s %-9s %s\n' "名称" "PNG 尺寸" "字节" "文件"
FAIL_COUNT=0
for line in "${RESULTS[@]}"; do
    if [ "${line#OK }" = "$line" ]; then
        printf '%s\n' "$line" >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi
    name="$(printf '%s\n' "$line" | sed -n 's/.*name=\([^ ]*\).*/\1/p')"
    actual="$(printf '%s\n' "$line" | sed -n 's/.*actual=\([^ ]*\).*/\1/p')"
    bytes="$(printf '%s\n' "$line" | sed -n 's/.*bytes=\([^ ]*\).*/\1/p')"
    file="$(printf '%s\n' "$line" | sed -n 's/.*file=\([^ ]*\).*/\1/p')"
    printf '%-22s %-12s %-9s %s\n' "$name" "$actual" "$bytes" "$file"
done

if [ "$FAIL_COUNT" -gt 0 ] || [ "$FAILED_CODE" -ne 0 ]; then
    die "$FAILED_CODE" "有 ${FAIL_COUNT} 个尺寸未产出有效 PNG"
fi
log "全部 ${#SIZES[@]} 个尺寸完成"
exit 0
