#!/bin/bash

#==============================================================================
# Script: Advanced Server Setup Automation
# Description: Automated server configuration with intelligent swap management
# Usage: sudo ./setup.sh [hostname]
#==============================================================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures
IFS=$'\n\t'        # Safe Internal Field Separator

#------------------------------------------------------------------------------
# Configuration Variables
#------------------------------------------------------------------------------
readonly NEW_HOSTNAME="${1:-}"
readonly TARGET_SWAP_GB=3
readonly TARGET_SWAP_BYTES=$((TARGET_SWAP_GB * 1024 * 1024 * 1024))
readonly SWAP_FILE="/swapfile"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/var/log/server-setup-$(date +%Y%m%d-%H%M%S).log"

#------------------------------------------------------------------------------
# Color Codes for Output
#------------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m' # No Color

#------------------------------------------------------------------------------
# Logging Functions
#------------------------------------------------------------------------------
log() {
    echo -e "${GREEN}[INFO]${NC} $*" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"
}

log_step() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
    echo -e "${BLUE}[STEP]${NC} $*" | tee -a "$LOG_FILE"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $*" | tee -a "$LOG_FILE"
}

#------------------------------------------------------------------------------
# Error Handler
#------------------------------------------------------------------------------
error_exit() {
    log_error "$1"
    log_error "Script thất bại tại dòng ${BASH_LINENO[0]}"
    exit "${2:-1}"
}

trap 'error_exit "Lỗi không xác định xảy ra"' ERR

#------------------------------------------------------------------------------
# Validation Functions
#------------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "Bạn phải chạy script này với quyền root (sudo)." 1
    fi
}

check_os() {
    if ! command -v apt &> /dev/null; then
        error_exit "Script này chỉ hỗ trợ hệ thống Debian/Ubuntu với APT package manager." 1
    fi
}

validate_hostname() {
    local hostname="$1"
    if [[ ! "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        error_exit "Hostname không hợp lệ: '$hostname'. Hostname chỉ được chứa chữ cái, số và dấu gạch ngang." 1
    fi
}

#------------------------------------------------------------------------------
# Utility Functions
#------------------------------------------------------------------------------
bytes_to_gb() {
    local bytes=$1
    echo "scale=2; $bytes / 1024 / 1024 / 1024" | bc
}

gb_to_bytes() {
    local gb=$1
    echo "$((gb * 1024 * 1024 * 1024))"
}

confirm_action() {
    local prompt="$1"
    local response
    read -r -p "$(echo -e "${CYAN}$prompt [Y/n]:${NC} ")" response
    response=${response,,} # to lowercase
    [[ -z "$response" || "$response" == "y" || "$response" == "yes" ]]
}

#------------------------------------------------------------------------------
# Hostname Management
#------------------------------------------------------------------------------
set_hostname() {
    local current_hostname
    current_hostname=$(hostname)
    
    echo ""
    log "Hostname hiện tại: ${CYAN}$current_hostname${NC}"
    
    if [[ -z "$NEW_HOSTNAME" ]]; then
        if confirm_action "Bạn có muốn thay đổi hostname không?"; then
            read -r -p "$(echo -e "${CYAN}Nhập hostname mới:${NC} ")" user_hostname
            if [[ -n "$user_hostname" ]]; then
                validate_hostname "$user_hostname"
                apply_hostname "$user_hostname"
            else
                log_warning "Không có hostname nào được nhập, giữ nguyên hostname hiện tại."
            fi
        else
            log "Giữ nguyên hostname: $current_hostname"
        fi
    else
        validate_hostname "$NEW_HOSTNAME"
        apply_hostname "$NEW_HOSTNAME"
    fi
}

apply_hostname() {
    local new_name="$1"
    log "Đang đặt hostname thành: ${CYAN}$new_name${NC}"
    
    hostnamectl set-hostname "$new_name" || error_exit "Không thể đặt hostname"
    
    # Cập nhật /etc/hosts
    if ! grep -q "127.0.1.1" /etc/hosts; then
        echo "127.0.1.1    $new_name" >> /etc/hosts
    else
        sed -i "s/127.0.1.1.*/127.0.1.1    $new_name/" /etc/hosts
    fi
    
    log_success "Hostname đã được đặt thành: $(hostname)"
}

#------------------------------------------------------------------------------
# System Update
#------------------------------------------------------------------------------
update_system() {
    log "Đang cập nhật danh sách gói..."
    apt update || error_exit "Không thể cập nhật danh sách gói"
    
    log "Đang nâng cấp hệ thống (có thể mất vài phút)..."
    DEBIAN_FRONTEND=noninteractive apt upgrade -y || error_exit "Không thể nâng cấp hệ thống"
    
    log "Đang cài đặt các gói phụ thuộc cơ bản..."
    DEBIAN_FRONTEND=noninteractive apt install -y \
        software-properties-common \
        apt-transport-https \
        ca-certificates \
        gnupg \
        lsb-release \
        bc || error_exit "Không thể cài đặt các gói phụ thuộc"
    
    log_success "Hệ thống đã được cập nhật thành công"
}

#------------------------------------------------------------------------------
# Python Installation
#------------------------------------------------------------------------------
install_python_latest() {
    log "Đang thêm PPA deadsnakes để cài đặt Python mới nhất..."
    
    # Thêm PPA cho Python mới nhất
    add-apt-repository -y ppa:deadsnakes/ppa || log_warning "Không thể thêm PPA deadsnakes"
    apt update
    
    # Cài đặt Python 3.12 (hoặc phiên bản mới nhất có sẵn)
    local python_versions=("3.13" "3.12" "3.11" "3.10")
    local installed=false
    
    for version in "${python_versions[@]}"; do
        if apt-cache show "python${version}" &> /dev/null; then
            log "Đang cài đặt Python ${version}..."
            DEBIAN_FRONTEND=noninteractive apt install -y \
                "python${version}" \
                "python${version}-dev" \
                "python${version}-venv" \
                "python${version}-distutils" 2>/dev/null || continue
            
            # Cập nhật alternatives
            update-alternatives --install /usr/bin/python3 python3 "/usr/bin/python${version}" 1
            update-alternatives --set python3 "/usr/bin/python${version}"
            
            installed=true
            log_success "Python ${version} đã được cài đặt và đặt làm mặc định"
            break
        fi
    done
    
    if [[ "$installed" == false ]]; then
        log_warning "Không thể cài đặt Python mới nhất từ PPA, sử dụng phiên bản mặc định"
        DEBIAN_FRONTEND=noninteractive apt install -y python3 python3-pip python3-venv python3-dev
    fi
    
    # Cài đặt pip mới nhất
    log "Đang cài đặt pip mới nhất..."
    curl -sS https://bootstrap.pypa.io/get-pip.py | python3
    python3 -m pip install --upgrade pip setuptools wheel
    
    log_success "Python: $(python3 --version) | pip: $(python3 -m pip --version | cut -d' ' -f2)"
}

#------------------------------------------------------------------------------
# Node.js Installation
#------------------------------------------------------------------------------
install_nodejs_latest() {
    log "Đang cài đặt Node.js LTS mới nhất..."
    
    # Xóa Node.js cũ nếu có
    apt remove -y nodejs npm 2>/dev/null || true
    apt autoremove -y
    
    # Cài đặt NodeSource repository cho Node.js LTS
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - || error_exit "Không thể thêm NodeSource repository"
    
    # Cài đặt Node.js
    DEBIAN_FRONTEND=noninteractive apt install -y nodejs || error_exit "Không thể cài đặt Node.js"
    
    # Cập nhật npm lên phiên bản mới nhất
    npm install -g npm@latest
    
    # Cài đặt các công cụ global hữu ích
    log "Đang cài đặt các công cụ Node.js toàn cục..."
    npm install -g pm2 yarn pnpm
    
    log_success "Node.js: $(node --version) | npm: $(npm --version)"
}

#------------------------------------------------------------------------------
# Essential Packages Installation
#------------------------------------------------------------------------------
install_essential_packages() {
    log "Đang cài đặt các gói công cụ thiết yếu..."
    
    local packages=(
        build-essential
        git
        curl
        wget
        vim
        nano
        htop
        iotop
        nethogs
        net-tools
        dnsutils
        unzip
        zip
        tar
        neofetch
        tmux
        screen
        jq
        tree
        rsync
        ncdu
        nload
        glances
        sysstat
        ufw
    )
    
    DEBIAN_FRONTEND=noninteractive apt install -y "${packages[@]}" || \
        log_warning "Một số gói không thể cài đặt, tiếp tục..."
    
    log_success "Các gói thiết yếu đã được cài đặt"
}

#------------------------------------------------------------------------------
# Intelligent Swap Management
#------------------------------------------------------------------------------
setup_swap() {
    log "Đang phân tích swap hiện tại..."
    
    # Lấy tổng swap hiện tại (bytes)
    local current_swap_bytes
    current_swap_bytes=$(free -b | awk '/^Swap:/ {print $2}')
    local current_swap_gb
    current_swap_gb=$(bytes_to_gb "$current_swap_bytes")
    
    log "Swap hiện tại: ${CYAN}${current_swap_gb} GB${NC}"
    log "Swap mục tiêu: ${CYAN}${TARGET_SWAP_GB} GB${NC}"
    
    # Tính toán swap cần thêm
    local needed_bytes=$((TARGET_SWAP_BYTES - current_swap_bytes))
    
    if [[ $needed_bytes -le 0 ]]; then
        log_success "Hệ thống đã có đủ swap (${current_swap_gb} GB >= ${TARGET_SWAP_GB} GB)"
        return 0
    fi
    
    local needed_gb
    needed_gb=$(bytes_to_gb "$needed_bytes")
    log "Cần thêm: ${YELLOW}${needed_gb} GB${NC} swap để đạt mục tiêu ${TARGET_SWAP_GB} GB"
    
    # Kiểm tra xem swap file đã tồn tại chưa
    if [[ -f "$SWAP_FILE" ]]; then
        if swapon --show | grep -q "$SWAP_FILE"; then
            log_warning "Swap file $SWAP_FILE đã được kích hoạt, đang tắt để cấu hình lại..."
            swapoff "$SWAP_FILE"
        fi
        log "Xóa swap file cũ..."
        rm -f "$SWAP_FILE"
    fi
    
    # Làm tròn lên GB
    local add_gb
    add_gb=$(echo "scale=0; ($needed_bytes + 1073741823) / 1073741824" | bc)
    
    log "Đang tạo swap file mới: ${CYAN}${add_gb} GB${NC}..."
    
    # Tạo swap file với fallocate (nhanh hơn dd)
    if fallocate -l "${add_gb}G" "$SWAP_FILE" 2>/dev/null; then
        log_success "Đã tạo swap file bằng fallocate"
    else
        log_warning "fallocate thất bại, sử dụng dd (có thể chậm hơn)..."
        dd if=/dev/zero of="$SWAP_FILE" bs=1G count="$add_gb" status=progress || \
            error_exit "Không thể tạo swap file"
    fi
    
    # Thiết lập permissions
    chmod 600 "$SWAP_FILE"
    
    # Tạo swap
    mkswap "$SWAP_FILE" || error_exit "Không thể tạo swap"
    
    # Kích hoạt swap
    swapon "$SWAP_FILE" || error_exit "Không thể kích hoạt swap"
    
    # Thêm vào fstab nếu chưa có
    if ! grep -q "$SWAP_FILE" /etc/fstab; then
        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
        log_success "Đã thêm swap vào /etc/fstab để tự động mount khi khởi động"
    fi
    
    # Kiểm tra tổng swap sau khi thêm
    local final_swap_bytes
    final_swap_bytes=$(free -b | awk '/^Swap:/ {print $2}')
    local final_swap_gb
    final_swap_gb=$(bytes_to_gb "$final_swap_bytes")
    
    log_success "Swap mới: ${GREEN}${final_swap_gb} GB${NC} (đã thêm ${add_gb} GB)"
}

#------------------------------------------------------------------------------
# System Optimization
#------------------------------------------------------------------------------
optimize_system() {
    log "Đang tối ưu hóa hệ thống..."
    
    # Tối ưu swap
    log "Cấu hình swap optimization..."
    cat > /etc/sysctl.d/99-swap-optimization.conf <<EOF
# Swap Optimization
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=5
EOF
    
    # Tối ưu network
    log "Cấu hình network optimization..."
    cat > /etc/sysctl.d/99-network-optimization.conf <<EOF
# Network Optimization
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
EOF
    
    # Tối ưu file system
    log "Cấu hình file system optimization..."
    cat > /etc/sysctl.d/99-fs-optimization.conf <<EOF
# File System Optimization
fs.file-max=2097152
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=512
EOF
    
    # Tối ưu security
    log "Cấu hình security hardening..."
    cat > /etc/sysctl.d/99-security.conf <<EOF
# Security Hardening
kernel.dmesg_restrict=1
kernel.kptr_restrict=2
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.icmp_ignore_bogus_error_responses=1
net.ipv4.tcp_syncookies=1
EOF
    
    # Áp dụng tất cả cấu hình
    sysctl -p /etc/sysctl.d/99-swap-optimization.conf >/dev/null 2>&1
    sysctl -p /etc/sysctl.d/99-network-optimization.conf >/dev/null 2>&1
    sysctl -p /etc/sysctl.d/99-fs-optimization.conf >/dev/null 2>&1
    sysctl -p /etc/sysctl.d/99-security.conf >/dev/null 2>&1
    
    # Tối ưu systemd journal
    log "Giới hạn kích thước system journal..."
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/size-limit.conf <<EOF
[Journal]
SystemMaxUse=100M
SystemMaxFileSize=10M
EOF
    systemctl restart systemd-journald
    
    # Bật và cấu hình UFW firewall
    log "Cấu hình firewall cơ bản..."
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    echo "y" | ufw enable >/dev/null 2>&1
    
    log_success "Hệ thống đã được tối ưu hóa"
}

#------------------------------------------------------------------------------
# Cleanup
#------------------------------------------------------------------------------
cleanup_system() {
    log "Đang dọn dẹp hệ thống..."
    
    apt autoremove -y
    apt autoclean -y
    apt clean
    
    # Xóa log cũ
    journalctl --vacuum-time=7d >/dev/null 2>&1
    
    # Xóa cache
    find /var/cache/apt/archives -type f -delete 2>/dev/null || true
    
    log_success "Dọn dẹp hoàn tất"
}

#------------------------------------------------------------------------------
# Summary Display
#------------------------------------------------------------------------------
display_summary() {
    local final_swap_gb
    final_swap_gb=$(free -h | awk '/^Swap:/ {print $2}')
    
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}║       ✨ HOÀN TẤT THIẾT LẬP MÁY CHỦ THÀNH CÔNG ✨         ║${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}╭─────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${CYAN}│${NC} ${MAGENTA}📋 THÔNG TIN HỆ THỐNG${NC}                                    ${CYAN}│${NC}"
    echo -e "${CYAN}╰─────────────────────────────────────────────────────────────╯${NC}"
    echo ""
    echo -e "  ${BLUE}🖥️  Hostname:${NC}      $(hostname)"
    echo -e "  ${BLUE}💻 OS:${NC}             $(lsb_release -d | cut -f2)"
    echo -e "  ${BLUE}🔧 Kernel:${NC}         $(uname -r)"
    echo -e "  ${BLUE}🐍 Python:${NC}         $(python3 --version 2>&1 | cut -d' ' -f2)"
    echo -e "  ${BLUE}📦 pip:${NC}            $(python3 -m pip --version 2>&1 | cut -d' ' -f2)"
    echo -e "  ${BLUE}🟢 Node.js:${NC}        $(node --version 2>&1)"
    echo -e "  ${BLUE}📚 npm:${NC}            $(npm --version 2>&1)"
    echo -e "  ${BLUE}💾 Swap:${NC}           ${final_swap_gb}"
    echo -e "  ${BLUE}🧠 RAM:${NC}            $(free -h | awk '/^Mem:/ {print $2}')"
    echo ""
    echo -e "${CYAN}╭─────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${CYAN}│${NC} ${MAGENTA}🎯 TỐI ƯU HÓA ĐÃ ÁP DỤNG${NC}                                ${CYAN}│${NC}"
    echo -e "${CYAN}╰─────────────────────────────────────────────────────────────╯${NC}"
    echo ""
    echo -e "  ${GREEN}✓${NC} Swap swappiness = 10 (giảm sử dụng swap)"
    echo -e "  ${GREEN}✓${NC} BBR congestion control (tối ưu network)"
    echo -e "  ${GREEN}✓${NC} TCP FastOpen enabled"
    echo -e "  ${GREEN}✓${NC} File system optimization"
    echo -e "  ${GREEN}✓${NC} Security hardening applied"
    echo -e "  ${GREEN}✓${NC} UFW firewall enabled (port 22 open)"
    echo -e "  ${GREEN}✓${NC} System journal size limited"
    echo ""
    echo -e "${CYAN}╭─────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${CYAN}│${NC} ${MAGENTA}📦 CÔNG CỤ ĐÃ CÀI ĐẶT${NC}                                   ${CYAN}│${NC}"
    echo -e "${CYAN}╰─────────────────────────────────────────────────────────────╯${NC}"
    echo ""
    echo -e "  ${YELLOW}▸${NC} Python với pip, venv"
    echo -e "  ${YELLOW}▸${NC} Node.js với npm, yarn, pnpm, pm2"
    echo -e "  ${YELLOW}▸${NC} Build tools: gcc, g++, make"
    echo -e "  ${YELLOW}▸${NC} Version control: git"
    echo -e "  ${YELLOW}▸${NC} Editors: vim, nano"
    echo -e "  ${YELLOW}▸${NC} Monitoring: htop, iotop, nethogs, glances, sysstat"
    echo -e "  ${YELLOW}▸${NC} Network: net-tools, dnsutils, nload"
    echo -e "  ${YELLOW}▸${NC} Utilities: tmux, screen, jq, tree, rsync, ncdu"
    echo ""
    echo -e "${BLUE}📝 Log file:${NC} $LOG_FILE"
    echo ""
    echo -e "${CYAN}╭─────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${CYAN}│${NC} ${YELLOW}💡 KHUYẾN NGHỊ${NC}                                            ${CYAN}│${NC}"
    echo -e "${CYAN}╰─────────────────────────────────────────────────────────────╯${NC}"
    echo ""
    echo -e "  ${YELLOW}1.${NC} Khởi động lại để áp dụng đầy đủ: ${GREEN}sudo reboot${NC}"
    echo -e "  ${YELLOW}2.${NC} Kiểm tra thông tin hệ thống: ${GREEN}neofetch${NC}"
    echo -e "  ${YELLOW}3.${NC} Monitor resources: ${GREEN}htop${NC} hoặc ${GREEN}glances${NC}"
    echo -e "  ${YELLOW}4.${NC} Kiểm tra firewall: ${GREEN}sudo ufw status${NC}"
    echo -e "  ${YELLOW}5.${NC} Kiểm tra swap: ${GREEN}free -h${NC}"
    echo ""
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------
main() {
    # Banner
    clear
    echo -e "${GREEN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║         🚀 ADVANCED SERVER SETUP AUTOMATION 🚀               ║
║                                                               ║
║    Tự động cài đặt, cấu hình và tối ưu hóa máy chủ          ║
║    với phần mềm mới nhất và quản lý swap thông minh          ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    
    # Pre-flight checks
    log "Đang kiểm tra hệ thống..."
    check_root
    check_os
    
    # Tạo log file
    touch "$LOG_FILE"
    log "Log file: $LOG_FILE"
    
    # Execute setup steps
    log_step "Bước 1: Cấu hình Hostname"
    set_hostname
    
    log_step "Bước 2: Cập nhật và Nâng cấp Hệ thống"
    update_system
    
    log_step "Bước 3: Cài đặt Python Mới nhất"
    install_python_latest
    
    log_step "Bước 4: Cài đặt Node.js LTS Mới nhất"
    install_nodejs_latest
    
    log_step "Bước 5: Cài đặt Các Gói Thiết yếu"
    install_essential_packages
    
    log_step "Bước 6: Quản lý Swap Thông minh (Mục tiêu: ${TARGET_SWAP_GB}GB)"
    setup_swap
    
    log_step "Bước 7: Tối ưu hóa Hệ thống"
    optimize_system
    
    log_step "Bước 8: Dọn dẹp Hệ thống"
    cleanup_system
    
    # Display summary
    display_summary
    
    log_success "Script hoàn thành thành công!"
    
    # Reboot prompt
    echo ""
    if confirm_action "Bạn có muốn khởi động lại ngay bây giờ để áp dụng đầy đủ các thay đổi không?"; then
        log "Đang khởi động lại trong 5 giây..."
        sleep 5
        reboot
    else
        log "Vui lòng khởi động lại thủ công bằng lệnh: ${GREEN}sudo reboot${NC}"
    fi
    
    exit 0
}

#------------------------------------------------------------------------------
# Script Entry Point
#------------------------------------------------------------------------------
main "$@"
