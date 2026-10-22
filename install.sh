#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# wifi-crack-termux 安装器
#
#   bash <(curl -fsSL https://cdn.jsdelivr.net/gh/xkxxs/wifi-crack-termux@master/install.sh)
#
# 从仓库目录直接运行也行： bash install.sh
# 卸载：                    bash install.sh --uninstall
# ============================================================

set -euo pipefail

REPO="xkxxs/wifi-crack-termux"
BRANCH="master"

CDN_BASE="https://cdn.jsdelivr.net/gh/${REPO}@${BRANCH}"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
PROXY_BASE="https://gh-proxy.com/https://raw.githubusercontent.com/${REPO}/${BRANCH}"

PREFIX_DIR="${PREFIX:-/data/data/com.termux/files/usr}"
SHARE_DIR="$PREFIX_DIR/share/wifi-crack"
BIN_DIR="$PREFIX_DIR/bin"
TARGET="$SHARE_DIR/wifi-crack.sh"
WRAPPER="$BIN_DIR/wifi-crack"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
DATA_DIR="$HOME_DIR/.wifi-crack"
DICT_DIR="$DATA_DIR/dict"
DICT_DST="$DICT_DIR/幻影WiFi字典.txt"
LEGACY_DICT="$HOME_DIR/幻影WiFi字典.txt"

# 字典文件名需要 URL 编码才能从 raw 拉取
DICT_PATH="%E5%B9%BB%E5%BD%B1WiFi%E5%AD%97%E5%85%B8.txt"

WITH_DICT=1
ASSUME_YES=0
ACTION="install"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
step()  { echo -e "${CYAN}[*]${NC} $*"; }
error() { echo -e "${RED}[-]${NC} $*"; }
die()   { error "$*"; exit 1; }

usage() {
    cat <<EOF
wifi-crack-termux 安装器

用法:
  bash install.sh               安装（默认同时安装字典，若还没有）
  bash install.sh --no-dict     安装但不下载字典
  bash install.sh --uninstall   卸载（保留 ~/.wifi-crack 里的字典和结果）
  bash install.sh -y            不再询问（当前没有交互，留作兼容）
  bash install.sh -h            显示帮助

安装位置:
  程序   $TARGET
  命令   $WRAPPER
  字典   $DICT_DST

环境变量:
  PREFIX    Termux 前缀，默认 /data/data/com.termux/files/usr
EOF
}

while (( $# > 0 )); do
    case "$1" in
        -u|--uninstall) ACTION="uninstall" ;;
        --no-dict)      WITH_DICT=0 ;;
        -y|--yes)       ASSUME_YES=1 ;;
        -h|--help)      usage; exit 0 ;;
        *)              die "未知参数: $1（用 -h 查看帮助）" ;;
    esac
    shift
done

have_cmd() { command -v "$1" >/dev/null 2>&1; }

fetch() { # fetch <url> <输出文件>
    local url="$1" out="$2"
    if have_cmd curl; then
        curl -fsSL --retry 2 --connect-timeout 15 "$url" -o "$out" && return 0
        return 1
    fi
    if have_cmd wget; then
        wget -q --timeout=20 -O "$out" "$url" && return 0
        return 1
    fi
    die "需要 curl 或 wget：pkg install curl"
}

# 按 gh-proxy → CDN → raw 顺序尝试
download() { # download <仓库内路径> <输出文件>
    local path="$1" out="$2" base
    for base in "$PROXY_BASE" "$CDN_BASE" "$RAW_BASE"; do
        step "下载 ${base}/${path}"
        if fetch "$base/$path" "$out"; then
            [[ -s "$out" ]] || continue
            return 0
        fi
        warn "失败，换下一个源"
    done
    return 1
}

check_env() {
    (( EUID != 0 )) || die "请不要用 root 运行安装器（脚本运行时会自己 su 提权）"
    [[ -d "$PREFIX_DIR" ]] || die "未检测到 Termux 环境（\$PREFIX=$PREFIX_DIR 不存在）"
    [[ -d "$BIN_DIR" ]] || die "找不到 $BIN_DIR"
    [[ -w "$BIN_DIR" ]] || die "$BIN_DIR 不可写，请用 Termux 普通用户运行（不要 sudo）"
    have_cmd bash || die "缺少 bash"
}

# 找到脚本本体：从仓库目录运行时用本地文件，管道安装时下载
SELF_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SELF_DIR=""
fi

resolve_source() {
    local out="$1"
    if [[ -n "$SELF_DIR" && -f "$SELF_DIR/wifi-crack.sh" ]]; then
        step "使用本地文件: $SELF_DIR/wifi-crack.sh"
        cp "$SELF_DIR/wifi-crack.sh" "$out"
        return 0
    fi
    download "wifi-crack.sh" "$out"
}

install_files() {
    local tmpdir wrapper_tmp
    tmpdir="$(mktemp -d "${TMPDIR:-${PREFIX_DIR}/tmp}/wifi-crack-install.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" EXIT

    resolve_source "$tmpdir/wifi-crack.sh" || die "下载失败，请检查网络或改用 git clone 本地安装"
    bash -n "$tmpdir/wifi-crack.sh" || die "脚本语法检查失败，可能下载到损坏的文件"

    # 程序本体
    mkdir -p "$SHARE_DIR"
    if [[ -f "$TARGET" ]] && cmp -s "$tmpdir/wifi-crack.sh" "$TARGET"; then
        step "程序已是同一版本，跳过覆盖"
    else
        cp "$tmpdir/wifi-crack.sh" "$TARGET.tmp"
        chmod 755 "$TARGET.tmp"
        mv -f "$TARGET.tmp" "$TARGET"
        info "已安装程序: $TARGET"
    fi

    # 快捷命令
    wrapper_tmp="$tmpdir/wifi-crack"
    cat > "$wrapper_tmp" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
# 由 wifi-crack-termux/install.sh 生成，重装或卸载请重新运行安装器
exec "$TARGET" "\$@"
EOF
    chmod 755 "$wrapper_tmp"
    if [[ -f "$WRAPPER" ]] && ! cmp -s "$wrapper_tmp" "$WRAPPER"; then
        cp -f "$WRAPPER" "$WRAPPER.bak"
        warn "已备份原有命令到 $WRAPPER.bak"
    fi
    mv -f "$wrapper_tmp" "$WRAPPER"
    info "已创建命令: $WRAPPER"

    # 字典（可选，已存在则不覆盖）
    if (( WITH_DICT )); then
        mkdir -p "$DICT_DIR"
        if [[ -f "$DICT_DST" ]]; then
            step "字典已存在，保留: $DICT_DST"
        elif [[ -f "$LEGACY_DICT" ]]; then
            # 旧版把字典放在 home 根目录，顺手收进来
            if mv -f "$LEGACY_DICT" "$DICT_DST" 2>/dev/null; then
                info "已把旧字典迁移到: $DICT_DST"
            else
                warn "旧字典迁移失败，仍保留在 $LEGACY_DICT"
            fi
        elif [[ -n "$SELF_DIR" && -f "$SELF_DIR/幻影WiFi字典.txt" ]]; then
            cp "$SELF_DIR/幻影WiFi字典.txt" "$DICT_DST"
            info "已安装字典: $DICT_DST"
        elif download "$DICT_PATH" "$tmpdir/dict.txt"; then
            mv -f "$tmpdir/dict.txt" "$DICT_DST"
            info "已安装字典: $DICT_DST"
        else
            warn "字典下载失败，可稍后手动放到 $DICT_DST"
        fi
    fi
}

post_check() {
    echo ""
    step "环境检查"
    [[ ":$PATH:" == *":$BIN_DIR:"* ]] ||
        warn "$BIN_DIR 不在 PATH 中，重开 Termux 或用绝对路径 $WRAPPER"

    if have_cmd cmd; then
        info "cmd wifi: 可用"
    else
        warn "没找到 cmd 命令，运行时会报错（应为 /system/bin/cmd，Android 11+）"
    fi

    if (( EUID == 0 )); then
        info "当前已是 root"
    elif have_cmd su || have_cmd sudo; then
        info "检测到 su/sudo，运行时自动提权"
    else
        warn "未检测到 su/sudo：设备需要 root，否则无法运行"
    fi
}

do_install() {
    echo ""
    echo -e "${BOLD}wifi-crack-termux 安装器${NC}"
    echo -e "${BOLD}════════════════════════════════════════${NC}"
    check_env
    install_files
    post_check

    echo ""
    echo -e "${BOLD}════════════════════════════════════════${NC}"
    info "安装完成，直接运行："
    echo ""
    echo -e "  ${BOLD}wifi-crack${NC}          # 交互菜单"
    echo -e "  ${BOLD}wifi-crack -s${NC}       # 扫描附近 WiFi"
    echo -e "  ${BOLD}wifi-crack -h${NC}       # 全部用法"
    echo ""
    echo -e "  仅限测试你自己拥有或已获得授权的网络。"
    echo -e "  卸载： ${BOLD}bash <(curl -fsSL ${PROXY_BASE}/install.sh) --uninstall${NC}"
}

do_uninstall() {
    echo ""
    echo -e "${BOLD}wifi-crack-termux 卸载${NC}"
    echo -e "${BOLD}════════════════════════════════════════${NC}"
    rm -f "$WRAPPER" "$WRAPPER.bak"
    rm -rf "$SHARE_DIR"
    info "已移除命令和程序"
    step "保留用户数据（如需删除请手动操作）："
    echo -e "    $DATA_DIR/            # 字典 dict/、结果 results/"
    echo -e "    $LEGACY_DICT"
    echo -e "    $HOME_DIR/wifi-results/"
}

if [[ "$ACTION" == "uninstall" ]]; then
    do_uninstall
else
    do_install
fi
