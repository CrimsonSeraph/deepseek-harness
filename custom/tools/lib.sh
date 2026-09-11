#!/usr/bin/env bash
# lib.sh — Qt/QML 窗口截图工具的共用函数库（被同目录脚本以 source 方式加载）
#
# 约定：
#   * 所有函数失败时要么返回非 0，要么用 die 直接以指定退出码结束，绝不静默吞错；
#   * 涉及 Windows 路径的地方统一用 to_winpath（cygpath -w）转换，不把 MSYS 路径交给原生 exe；
#   * 不写死任何本机绝对路径，路径来源只有「命令行参数 > 环境变量 > 基于脚本位置/临时目录的默认值」。

# ------------------------------------------------------------------ 日志
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '[%s] 警告: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
err()  { printf '[%s] 错误: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# die <退出码> <消息...>
die() {
    local code="$1"; shift
    err "$*"
    exit "$code"
}

need_cmd() {
    local missing=()
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        die 3 "缺少命令: ${missing[*]}（请确认 MSYS2/Git Bash 与 Qt bin 已加入 PATH）"
    fi
}

# ------------------------------------------------------------------ 路径
abs_path() {
    # 不要求路径已存在；优先 realpath，其次纯字符串归一化
    if command -v realpath >/dev/null 2>&1; then
        realpath -m -- "$1"
    else
        case "$1" in
            /*) printf '%s\n' "$1" ;;
            *)  printf '%s\n' "$(pwd)/$1" ;;
        esac
    fi
}

# MSYS 路径 → Windows 路径（交给 qml.exe / powershell 用；两端都必须是绝对路径）
to_winpath() {
    cygpath -w -a -- "$1"
}

# 删除目录前的最小安全校验：非空、足够长、位于 expect_root 之下
# safe_rm_rf <目标> <必须位于其下的根目录>
safe_rm_rf() {
    local target="$1" root="$2"
    [ -n "$target" ] || die 3 "拒绝删除空路径"
    local real_target real_root
    real_target="$(abs_path "$target")"
    real_root="$(abs_path "$root")"
    [ "$real_target" != "/" ] || die 3 "拒绝删除根目录"
    [ "$real_target" != "$real_root" ] || die 3 "拒绝删除工作目录本身: $real_target"
    [ "${#real_target}" -ge 12 ] || die 3 "路径过短，拒绝删除: $real_target"
    case "$real_target" in
        "$real_root"/*) : ;;
        *) die 3 "拒绝删除工作目录之外的路径: $real_target" ;;
    esac
    rm -rf -- "$real_target"
}

# ------------------------------------------------------------------ 进程
# MSYS pid → Windows pid（taskkill 需要 Windows pid）
winpid_of() {
    local msys_pid="$1" winpid=""
    if [ -r "/proc/${msys_pid}/winpid" ]; then
        winpid="$(cat "/proc/${msys_pid}/winpid" 2>/dev/null || true)"
    fi
    if [ -z "$winpid" ]; then
        winpid="$(ps -W 2>/dev/null | awk -v p="$msys_pid" '$2 == p { print $4; exit }')"
    fi
    [ -n "$winpid" ] && printf '%s\n' "$winpid"
    return 0
}

proc_alive() {
    kill -0 "$1" 2>/dev/null
}

winpid_alive() {
    [ -n "${1:-}" ] || return 1
    tasklist //FI "PID eq $1" //NH 2>/dev/null | grep -q "$1"
}

# 结束本次启动的渲染进程：
#   1) taskkill //F //T //PID <winpid>（对 Windows GUI 进程比 MSYS kill 可靠，且带上子进程树）；
#   2) 兜底 MSYS kill；
#   3) 仍不死（Qt 退出路径不干净留下无响应进程）时按镜像名强杀。
# 只在失败路径上做额外探测，避免在正常路径上多花几百毫秒。
kill_render_process() {
    local msys_pid="${1:-}" winpid="${2:-}"
    if [ -n "$winpid" ] && taskkill //F //T //PID "$winpid" >/dev/null 2>&1; then
        return 0
    fi
    if [ -n "$msys_pid" ] && proc_alive "$msys_pid"; then
        kill "$msys_pid" 2>/dev/null || true
        sleep 0.3
        if proc_alive "$msys_pid"; then
            warn "pid=${msys_pid}(winpid=${winpid:-?}) 未能退出，按镜像名强杀 qml.exe"
            taskkill //F //T //IM qml.exe >/dev/null 2>&1 || true
        fi
    fi
    return 0
}

# 清理历史残留的 qml.exe（截图前调用，避免抓到上一轮遗留窗口）
kill_stale_renderers() {
    local list
    list="$(tasklist //FI "IMAGENAME eq qml.exe" //NH 2>/dev/null | grep -i "qml.exe" || true)"
    if [ -z "$list" ]; then
        return 0
    fi
    warn "发现残留 qml.exe，先清理:"
    printf '%s\n' "$list" >&2
    taskkill //F //IM qml.exe >/dev/null 2>&1 || true
    sleep 0.5
}

# ------------------------------------------------------------------ Qt
# 定位 Qt bin 目录（含 qml.exe）：
#   1) QT_BIN_DIR
#   2) PATH 里已有的 qml.exe
#   3) QT_ROOT_DIR / QT_SEARCH_ROOTS 下的 <root>/<版本>/<kit>/bin
qt_bin_dir() {
    if [ -n "${QT_BIN_DIR:-}" ] && [ -x "${QT_BIN_DIR}/qml.exe" ]; then
        printf '%s\n' "$QT_BIN_DIR"
        return 0
    fi
    local on_path=""
    on_path="$(command -v qml.exe 2>/dev/null || true)"
    if [ -n "$on_path" ]; then
        dirname "$on_path"
        return 0
    fi

    local roots=()
    if [ -n "${QT_ROOT_DIR:-}" ]; then
        roots+=("$QT_ROOT_DIR")
    fi
    # 只是 Qt 安装盘的常见挂载点，可用 QT_SEARCH_ROOTS 覆盖
    # shellcheck disable=SC2206
    roots+=(${QT_SEARCH_ROOTS:-/c/Qt /d/Qt /e/Qt /f/Qt})

    local root candidates=()
    while IFS= read -r candidate; do
        if [ -n "$candidate" ]; then
            candidates+=("$candidate")
        fi
    done < <(for root in "${roots[@]}"; do
                 if [ -d "$root" ]; then
                     find "$root" -maxdepth 4 -type f -name 'qml.exe' 2>/dev/null
                 fi
             done | sort -rV)
    if [ "${#candidates[@]}" -eq 0 ]; then
        return 1
    fi

    # 同一个 Qt 版本下可能有多个 kit：优先 QT_KIT（默认 mingw），否则取版本最高的
    local kit="${QT_KIT:-mingw}" c
    for c in "${candidates[@]}"; do
        case "$c" in
            *"$kit"*) dirname "$c"; return 0 ;;
        esac
    done
    dirname "${candidates[0]}"
    return 0
}

# ------------------------------------------------------------------ 其它
now_ms() {
    local t
    t="$(date +%s%3N 2>/dev/null || true)"
    case "$t" in
        ''|*[!0-9]*) printf '%s000\n' "$(date +%s)" ;;
        *) printf '%s\n' "$t" ;;
    esac
}

# 从 PNG 的 IHDR 读取真实宽高（不依赖 python / PowerShell）
# png_size <file> → "宽x高"
png_size() {
    local file="$1" bytes
    bytes="$(od -An -tu1 -j16 -N8 -- "$file" 2>/dev/null | tr -s ' \n' ' ' | sed -e 's/^ *//' -e 's/ *$//')"
    [ -n "$bytes" ] || return 1
    # shellcheck disable=SC2086
    set -- $bytes
    [ "$#" -eq 8 ] || return 1
    printf '%sx%s\n' \
        "$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 ))" \
        "$(( $5 * 16777216 + $6 * 65536 + $7 * 256 + $8 ))"
}

file_size() {
    if stat -c%s -- "$1" >/dev/null 2>&1; then
        stat -c%s -- "$1"
    else
        wc -c < "$1" | tr -d ' '
    fi
}

# 打印日志尾部并提炼 QML 运行期错误（窗口出不来时最需要看到这些行）
report_qml_log() {
    local log_file="$1" lines="${2:-15}"
    [ -f "$log_file" ] || { warn "日志不存在: $log_file"; return 0; }
    err "----- $log_file (最后 $lines 行) -----"
    tail -n "$lines" "$log_file" >&2 || true
    local hits
    hits="$(grep -nE "TypeError|ReferenceError|is not a function|Unable to assign|SyntaxError|Cannot assign|Error:|QQmlApplicationEngine failed" "$log_file" | head -n 10 || true)"
    if [ -n "$hits" ]; then
        err "----- 疑似导致窗口出不来的 QML 错误 -----"
        printf '%s\n' "$hits" >&2
    fi
}
