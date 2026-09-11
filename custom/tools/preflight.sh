#!/usr/bin/env bash
# preflight.sh — 截图前的环境自检（缺什么就直接失败，不进入截图流程）
#
# 检查项：
#   1. 必需命令（powershell / taskkill / cygpath / timeout / sed …）；
#   2. Qt bin 目录与 qml.exe 是否存在、能否正常执行；
#   3. 是否有残留的 qml.exe（--kill 时清理，避免抓到上一轮遗留窗口）；
#   4. QML 源目录是否存在且含 *.qml；
#   5. 模块目录与 qmldir 是否生成正确（模块名、每个 qml 一行、depends QtQuick）；
#   6. 截图入口模板是否含 targetWidth / targetHeight / kind 三个标记。
#
# 用法: preflight.sh [--qml <模板>] [--src <QML 源目录>] [--module-dir <模块根>]
#                    [--module <名字>] [--title <标题标识>] [--kill] [--qt-bin <dir>]
# 退出码: 0 通过 / 3 前置条件不满足
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

usage() {
    cat >&2 <<'EOF'
用法: preflight.sh [选项]

  --qml <file>        截图入口模板，校验 targetWidth/targetHeight/kind 标记
  --src <dir>         QML 源目录，校验存在且含 *.qml
  --module-dir <dir>  QML 模块根目录，校验 <模块名>/qmldir
  --module <name>     QML 模块名（默认 Schedule）
  --title <text>      目标窗口标题标识（默认 $SHOT_TITLE 或 SHOTWIN）
  --qt-bin <dir>      Qt bin 目录（含 qml.exe）；默认自动探测
  --kill              清理残留的 qml.exe
  -h, --help          显示本帮助

退出码: 0 全部通过 / 3 前置条件不满足
EOF
}

QML_TEMPLATE=""
SRC_DIR=""
MODULE_DIR=""
MODULE_NAME="Schedule"
TITLE="${SHOT_TITLE:-SHOTWIN}"
QT_BIN=""
DO_KILL=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --qml)        QML_TEMPLATE="${2:-}"; shift 2 ;;
        --src)        SRC_DIR="${2:-}"; shift 2 ;;
        --module-dir) MODULE_DIR="${2:-}"; shift 2 ;;
        --module)     MODULE_NAME="${2:-}"; shift 2 ;;
        --title)      TITLE="${2:-}"; shift 2 ;;
        --qt-bin)     QT_BIN="${2:-}"; shift 2 ;;
        --kill)       DO_KILL=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage; die 3 "未知选项: $1" ;;
    esac
done

FAILED=0
check_ok()   { printf '  [ok]   %s\n' "$*"; }
check_fail() { printf '  [FAIL] %s\n' "$*" >&2; FAILED=$((FAILED + 1)); }

printf '== 1. 必需命令 ==\n'
for c in cygpath powershell taskkill timeout sed grep od; do
    if command -v "$c" >/dev/null 2>&1; then
        check_ok "$c -> $(command -v "$c")"
    else
        check_fail "缺少命令 $c"
    fi
done

printf '== 2. Qt 运行时 ==\n'
if [ -z "$QT_BIN" ]; then
    QT_BIN="$(qt_bin_dir || true)"
fi
if [ -z "$QT_BIN" ]; then
    check_fail "找不到 Qt bin 目录（设置 QT_BIN_DIR 或把 Qt 的 <版本>/<kit>/bin 加入 PATH）"
else
    check_ok "Qt bin 目录: $QT_BIN"
    if [ -x "${QT_BIN}/qml.exe" ]; then
        check_ok "qml.exe: ${QT_BIN}/qml.exe"
        VER="$(PATH="${QT_BIN}:${PATH}" qml.exe --version 2>&1 | head -n 1 || true)"
        if [ -n "$VER" ]; then
            check_ok "版本: $VER"
        fi
    else
        check_fail "缺少 ${QT_BIN}/qml.exe"
    fi
fi

printf '== 3. 残留渲染进程 ==\n'
STALE="$(tasklist //FI "IMAGENAME eq qml.exe" //NH 2>/dev/null | grep -i "qml.exe" || true)"
if [ -z "$STALE" ]; then
    check_ok "没有残留 qml.exe"
elif [ "$DO_KILL" -eq 1 ]; then
    kill_stale_renderers
    check_ok "已清理残留 qml.exe"
else
    check_fail "存在残留 qml.exe（加 --kill 清理；残留窗口可能让截图抓到上一轮内容）"
    printf '%s\n' "$STALE" >&2
fi

printf '== 4. QML 源目录 ==\n'
if [ -n "$SRC_DIR" ]; then
    SRC_DIR="$(abs_path "$SRC_DIR")"
    if [ ! -d "$SRC_DIR" ]; then
        check_fail "源目录不存在: $SRC_DIR"
    else
        COUNT="$(find "$SRC_DIR" -maxdepth 1 -name '*.qml' -type f | wc -l | tr -d ' ')"
        if [ "$COUNT" -gt 0 ]; then
            check_ok "$SRC_DIR 下 $COUNT 个 *.qml"
        else
            check_fail "$SRC_DIR 下没有 *.qml"
        fi
    fi
fi

printf '== 5. QML 模块（qmldir） ==\n'
if [ -n "$MODULE_DIR" ]; then
    MODULE_DIR="$(abs_path "$MODULE_DIR")"
    QMLDIR="${MODULE_DIR}/${MODULE_NAME}/qmldir"
    if [ ! -f "$QMLDIR" ]; then
        check_fail "缺少 qmldir: $QMLDIR"
    else
        head_line="$(head -n 1 "$QMLDIR")"
        if [ "$head_line" = "module ${MODULE_NAME}" ]; then
            check_ok "qmldir 模块头正确: $head_line"
        else
            check_fail "qmldir 第一行应为 \"module ${MODULE_NAME}\"，实际: $head_line"
        fi
        MISSING=""
        while IFS= read -r f; do
            b="$(basename "$f" .qml)"
            grep -qE "^${b}[[:space:]]" "$QMLDIR" || MISSING="${MISSING} ${b}.qml"
        done < <(find "${MODULE_DIR}/${MODULE_NAME}" -maxdepth 1 -name '*.qml' -type f)
        if [ -z "$MISSING" ]; then
            check_ok "qmldir 覆盖了模块目录下全部 *.qml"
        else
            check_fail "qmldir 缺少条目:$MISSING"
        fi
    fi
fi

printf '== 6. 截图入口模板 ==\n'
if [ -n "$QML_TEMPLATE" ]; then
    QML_TEMPLATE="$(abs_path "$QML_TEMPLATE")"
    if [ ! -f "$QML_TEMPLATE" ]; then
        check_fail "模板不存在: $QML_TEMPLATE"
    else
        for marker in 'property int targetWidth:' 'property int targetHeight:' 'property string kind:'; do
            if grep -qF -- "$marker" "$QML_TEMPLATE"; then
                check_ok "标记存在: $marker"
            else
                check_fail "模板缺少标记: $marker"
            fi
        done
        if grep -qF -- "$TITLE" "$QML_TEMPLATE"; then
            check_ok "模板里出现约定的窗口标题标识 [$TITLE]"
        else
            check_fail "模板里没有标题标识 [$TITLE]（cap.ps1 将找不到窗口）"
        fi
    fi
fi

if [ "$FAILED" -gt 0 ]; then
    die 3 "前置检查失败 $FAILED 项"
fi
printf '前置检查通过\n'
exit 0
