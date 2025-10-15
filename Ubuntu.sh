#!/bin/bash
#==============================================================================
# Script: Advanced Server Setup Automation
# Description: Automated server configuration with intelligent swap management
# Usage: sudo ./setup.sh [hostname]
#==============================================================================

# Fix apt_pkg issue nếu python3 system bị ghi đè
if ! python3 -c "import apt_pkg" >/dev/null 2>&1; then
    log_warning "apt_pkg lỗi — khôi phục Python system cho apt..."
    if [[ -x /usr/bin/python3.12 ]]; then
        ln -sf /usr/bin/python3.12 /usr/bin/python3
        log_success "Đã khôi phục /usr/bin/python3 → Python 3.12"
    fi
fi


set -euo pipefail
IFS=$'\n\t'

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
# Color Codes
#------------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m'

#------------------------------------------------------------------------------
# Logging
#------------------------------------------------------------------------------
log()         { echo -e "${GREEN}[INFO]${NC} $*" | tee -a "$LOG_FILE"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; }
log_step() {
  echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
  echo -e "${BLUE}[STEP]${NC} $*" | tee -a "$LOG_FILE"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
}
log_success() { echo -e "${GREEN}[✓]${NC} $*" | tee -a "$LOG_FILE"; }

#------------------------------------------------------------------------------
# Error handler
#------------------------------------------------------------------------------
error_exit() {
  log_error "$1"
  log_error "Script thất bại tại dòng ${BASH_LINENO[0]}"
  exit "${2:-1}"
}
trap 'error_exit "Lỗi không xác định xảy ra"' ERR

#------------------------------------------------------------------------------
# Validation
#------------------------------------------------------------------------------
check_root() {
  if [[ $EUID -ne 0 ]]; then
    error_exit "Bạn phải chạy script này với quyền root (sudo)." 1
  fi
}
check_os() {
  if ! command -v apt >/dev/null 2>&1; then
    error_exit "Script này chỉ hỗ trợ hệ Debian/Ubuntu (APT)." 1
  fi
}
validate_hostname() {
  local hostname="$1"
  if [[ ! "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    error_exit "Hostname không hợp lệ: '$hostname'." 1
  fi
}

#------------------------------------------------------------------------------
# Utils
#------------------------------------------------------------------------------
bytes_to_gb() { local b=$1; echo "scale=2; $b / 1024 / 1024 / 1024" | bc; }
gb_to_bytes() { local g=$1; echo "$((g * 1024 * 1024 * 1024))"; }
confirm_action() {
  local prompt="$1" response
  read -r -p "$(echo -e "${CYAN}$prompt [Y/n]:${NC} ")" response
  response=${response,,}
  [[ -z "$response" || "$response" == "y" || "$response" == "yes" ]]
}

#------------------------------------------------------------------------------
# Hostname
#------------------------------------------------------------------------------
set_hostname() {
  local current_hostname; current_hostname=$(hostname)
  echo ""; log "Hostname hiện tại: ${CYAN}$current_hostname${NC}"

  if [[ -z "$NEW_HOSTNAME" ]]; then
    if confirm_action "Bạn có muốn thay đổi hostname không?"; then
      read -r -p "$(echo -e "${CYAN}Nhập hostname mới:${NC} ")" user_hostname
      if [[ -n "$user_hostname" ]]; then
        validate_hostname "$user_hostname"; apply_hostname "$user_hostname"
      else
        log_warning "Không nhập hostname mới, giữ nguyên."
      fi
    else
      log "Giữ nguyên hostname: $current_hostname"
    fi
  else
    validate_hostname "$NEW_HOSTNAME"; apply_hostname "$NEW_HOSTNAME"
  fi
}
apply_hostname() {
  local new_name="$1"
  log "Đang đặt hostname: ${CYAN}$new_name${NC}"
  hostnamectl set-hostname "$new_name" || error_exit "Không thể đặt hostname"
  if ! grep -q "127.0.1.1" /etc/hosts; then
    echo "127.0.1.1    $new_name" >> /etc/hosts
  else
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1    $new_name/" /etc/hosts
  fi
  log_success "Hostname đã đặt: $(hostname)"
}

#------------------------------------------------------------------------------
# System Update
#------------------------------------------------------------------------------
update_system() {
  log "Cập nhật danh sách gói..."
  apt update
  log "Nâng cấp hệ thống..."
  DEBIAN_FRONTEND=noninteractive apt upgrade -y
  log "Cài gói phụ thuộc cơ bản..."
  DEBIAN_FRONTEND=noninteractive apt install -y \
    software-properties-common apt-transport-https ca-certificates \
    gnupg lsb-release bc
  log_success "Đã cập nhật hệ thống"
}

#------------------------------------------------------------------------------
# Python Installation (Ubuntu/Debian, ưu tiên 3.13) — SAFE & CORRECT
#------------------------------------------------------------------------------
install_python_latest() {
  log "Đang cài Python hiện đại (ưu tiên 3.13) theo cách an toàn..."

  # 1) Thêm PPA deadsnakes (nếu chưa có)
  if ! grep -q "deadsnakes" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
    add-apt-repository -y ppa:deadsnakes/ppa || log_warning "Không thể thêm PPA deadsnakes — sẽ thử package mặc định"
  fi
  apt update -y

  # 2) Cài python3.13 (không cài *-distutils vì đã deprecated)
  local PYBIN=""
  if apt-cache show python3.13 >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt install -y python3.13 python3.13-venv python3.13-dev
    PYBIN="/usr/bin/python3.13"
  else
    log_warning "Không có python3.13 trong repo — dùng python3 mặc định"
    DEBIAN_FRONTEND=noninteractive apt install -y python3 python3-venv python3-dev
    PYBIN="$(command -v python3)"
  fi

  # 3) Symlink an toàn để 'python' dùng đúng interpreter (không đụng /usr/bin/python3)
  ln -sf "$PYBIN" /usr/local/bin/python

  # 4) ensurepip + nâng pip/setuptools/wheel cho đúng interpreter (tránh pip 3.12)
  python -m ensurepip --upgrade
  python -m pip install --upgrade --ignore-installed pip setuptools wheel

  # 5) Symlink 'pip' → pip của interpreter này (nếu có pip3.13)
  local PIP_CANDIDATE
  PIP_CANDIDATE="$(command -v pip3.13 || true)"
  if [[ -n "$PIP_CANDIDATE" ]]; then
    ln -sf "$PIP_CANDIDATE" /usr/local/bin/pip
  else
    # fallback: trỏ pip về "python -m pip" qua wrapper nhỏ
    cat >/usr/local/bin/pip <<'EOF'
#!/bin/sh
exec /usr/local/bin/python -m pip "$@"
EOF
    chmod +x /usr/local/bin/pip
  fi

  # 6) Cài sẵn các thư viện phổ biến (yêu cầu 2: có requests/pydantic/rich/psutil/colorama)
  python -m pip install --upgrade --ignore-installed \
    requests pydantic rich psutil colorama

  # 7) Kiểm tra
  log_success "Python: $(python --version 2>&1)"
  log_success "pip:    $(python -m pip --version 2>&1)"
  log "Gợi ý: luôn cài gói bằng: ${CYAN}python -m pip install <pkg>${NC}"
}

#------------------------------------------------------------------------------
# Node.js Installation
#------------------------------------------------------------------------------
install_nodejs_latest() {
  log "Cài Node.js LTS..."
  apt remove -y nodejs npm 2>/dev/null || true
  apt autoremove -y
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - || error_exit "Không thể thêm NodeSource repository"
  DEBIAN_FRONTEND=noninteractive apt install -y nodejs
  npm install -g npm@latest
  log "Cài các công cụ Node global..."
  npm install -g pm2 yarn pnpm
  log_success "Node.js: $(node --version) | npm: $(npm --version)"
}

#------------------------------------------------------------------------------
# Essential Packages
#------------------------------------------------------------------------------
install_essential_packages() {
  log "Cài đặt gói công cụ thiết yếu..."
  local packages=(
    build-essential git curl wget vim nano htop iotop nethogs net-tools dnsutils
    unzip zip tar neofetch tmux screen jq tree rsync ncdu nload glances sysstat ufw
  )
  DEBIAN_FRONTEND=noninteractive apt install -y "${packages[@]}" || \
    log_warning "Một số gói không cài được, tiếp tục..."
  log_success "Đã cài gói thiết yếu"
}

#------------------------------------------------------------------------------
# Intelligent Swap
#------------------------------------------------------------------------------
setup_swap() {
  log "Phân tích swap hiện tại..."
  local current_swap_bytes current_swap_gb
  current_swap_bytes=$(free -b | awk '/^Swap:/ {print $2}')
  current_swap_gb=$(bytes_to_gb "$current_swap_bytes")
  log "Swap hiện tại: ${CYAN}${current_swap_gb} GB${NC}"
  log "Swap mục tiêu: ${CYAN}${TARGET_SWAP_GB} GB${NC}"

  local needed_bytes=$((TARGET_SWAP_BYTES - current_swap_bytes))
  if [[ $needed_bytes -le 0 ]]; then
    log_success "Đủ swap (${current_swap_gb} GB >= ${TARGET_SWAP_GB} GB)"
    return 0
  fi

  local needed_gb; needed_gb=$(bytes_to_gb "$needed_bytes")
  log "Cần thêm: ${YELLOW}${needed_gb} GB${NC}"

  if [[ -f "$SWAP_FILE" ]]; then
    if swapon --show | grep -q "$SWAP_FILE"; then
      log_warning "Swap file $SWAP_FILE đang active, tắt để cấu hình lại..."
      swapoff "$SWAP_FILE"
    fi
    log "Xóa swap file cũ..."; rm -f "$SWAP_FILE"
  fi

  local add_gb; add_gb=$(echo "scale=0; ($needed_bytes + 1073741823) / 1073741824" | bc)
  log "Tạo swap file mới: ${CYAN}${add_gb} GB${NC}..."
  if fallocate -l "${add_gb}G" "$SWAP_FILE" 2>/dev/null; then
    log_success "Đã tạo bằng fallocate"
  else
    log_warning "fallocate lỗi, dùng dd (chậm hơn)..."
    dd if=/dev/zero of="$SWAP_FILE" bs=1G count="$add_gb" status=progress
  fi

  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE"
  swapon "$SWAP_FILE"

  if ! grep -q "$SWAP_FILE" /etc/fstab; then
    echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    log_success "Đã thêm vào /etc/fstab"
  fi

  local final_swap_gb; final_swap_gb=$(bytes_to_gb "$(free -b | awk '/^Swap:/ {print $2}')")
  log_success "Swap mới: ${GREEN}${final_swap_gb} GB${NC} (đã thêm ${add_gb} GB)"
}

#------------------------------------------------------------------------------
# System Optimization
#------------------------------------------------------------------------------
optimize_system() {
  log "Tối ưu hệ thống..."

  log "Cấu hình swap optimization..."
  cat >/etc/sysctl.d/99-swap-optimization.conf <<EOF
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=5
EOF

  log "Cấu hình network optimization..."
  cat >/etc/sysctl.d/99-network-optimization.conf <<EOF
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
EOF

  log "Cấu hình file system optimization..."
  cat >/etc/sysctl.d/99-fs-optimization.conf <<EOF
fs.file-max=2097152
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=512
EOF

  log "Cấu hình security hardening..."
  cat >/etc/sysctl.d/99-security.conf <<EOF
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

  sysctl -p /etc/sysctl.d/99-swap-optimization.conf >/dev/null 2>&1
  sysctl -p /etc/sysctl.d/99-network-optimization.conf >/dev/null 2>&1
  sysctl -p /etc/sysctl.d/99-fs-optimization.conf >/dev/null 2>&1
  sysctl -p /etc/sysctl.d/99-security.conf >/dev/null 2>&1

  log "Giới hạn kích thước system journal..."
  mkdir -p /etc/systemd/journald.conf.d
  cat >/etc/systemd/journald.conf.d/size-limit.conf <<EOF
[Journal]
SystemMaxUse=100M
SystemMaxFileSize=10M
EOF
  systemctl restart systemd-journald

  log "Cấu hình UFW firewall cơ bản..."
  ufw --force reset >/dev/null 2>&1
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow ssh
  echo "y" | ufw enable >/dev/null 2>&1

  log_success "Đã tối ưu hệ thống"
}

#------------------------------------------------------------------------------
# Cleanup
#------------------------------------------------------------------------------
cleanup_system() {
  log "Dọn dẹp hệ thống..."
  apt autoremove -y
  apt autoclean -y
  apt clean
  journalctl --vacuum-time=7d >/dev/null 2>&1
  find /var/cache/apt/archives -type f -delete 2>/dev/null || true
  log_success "Dọn dẹp xong"
}

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------
display_summary() {
  local final_swap_gb; final_swap_gb=$(free -h | awk '/^Swap:/ {print $2}')
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║       ✨ HOÀN TẤT THIẾT LẬP MÁY CHỦ THÀNH CÔNG ✨         ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BLUE}🖥️  Hostname:${NC}      $(hostname)"
  echo -e "  ${BLUE}💻 OS:${NC}             $(lsb_release -d | cut -f2)"
  echo -e "  ${BLUE}🔧 Kernel:${NC}         $(uname -r)"
  echo -e "  ${BLUE}🐍 Python:${NC}         $(python --version 2>&1 | awk '{print $2}')"
  echo -e "  ${BLUE}📦 pip:${NC}            $(python -m pip --version 2>&1 | awk '{print $2}')"
  echo -e "  ${BLUE}🟢 Node.js:${NC}        $(node --version 2>&1)"
  echo -e "  ${BLUE}📚 npm:${NC}            $(npm --version 2>&1)"
  echo -e "  ${BLUE}💾 Swap:${NC}           ${final_swap_gb}"
  echo -e "  ${BLUE}🧠 RAM:${NC}            $(free -h | awk '/^Mem:/ {print $2}')"
  echo ""
  echo -e "  ${GREEN}✓${NC} Swap swappiness = 10 | BBR | TCP FastOpen"
  echo -e "  ${GREEN}✓${NC} FS + Security hardening | UFW enabled (22/tcp)"
  echo -e "  ${GREEN}✓${NC} Gói thiết yếu: unzip, neofetch, screen, tmux, htop,..."
  echo ""
  echo -e "${BLUE}📝 Log file:${NC} $LOG_FILE"
  echo ""
  echo -e "  ${YELLOW}1.${NC} Khởi động lại để áp dụng đầy đủ: ${GREEN}sudo reboot${NC}"
  echo -e "  ${YELLOW}2.${NC} Kiểm tra firewall: ${GREEN}sudo ufw status${NC}"
  echo -e "  ${YELLOW}3.${NC} Monitor: ${GREEN}htop${NC} / ${GREEN}glances${NC}"
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
main() {
  clear
  echo -e "${GREEN}"
  cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║         🚀 ADVANCED SERVER SETUP AUTOMATION 🚀               ║
║    Tự động cài đặt, cấu hình và tối ưu hóa máy chủ           ║
║    với phần mềm mới nhất và quản lý swap thông minh          ║
╚═══════════════════════════════════════════════════════════════╝
EOF
  echo -e "${NC}"

  log "Kiểm tra hệ thống..."
  check_root
  check_os

  touch "$LOG_FILE"
  log "Log file: $LOG_FILE"

  log_step "Bước 1: Cấu hình Hostname"
  set_hostname

  log_step "Bước 2: Cập nhật & Nâng cấp Hệ thống"
  update_system

  log_step "Bước 3: Cài đặt Python mới nhất (3.13) & pip"
  install_python_latest

  log_step "Bước 4: Cài đặt Node.js LTS & công cụ"
  install_nodejs_latest

  log_step "Bước 5: Cài đặt Các Gói Thiết yếu"
  install_essential_packages

  log_step "Bước 6: Quản lý Swap Thông minh (Mục tiêu: ${TARGET_SWAP_GB}GB)"
  setup_swap

  log_step "Bước 7: Tối ưu hóa Hệ thống"
  optimize_system

  log_step "Bước 8: Dọn dẹp Hệ thống"
  cleanup_system

  display_summary
  log_success "Script hoàn thành!"

  echo ""
  if confirm_action "Bạn có muốn khởi động lại ngay bây giờ để áp dụng đầy đủ các thay đổi không?"; then
    log "Khởi động lại trong 5 giây..."
    sleep 5
    reboot
  else
    log "Vui lòng khởi động lại thủ công: ${GREEN}sudo reboot${NC}"
  fi
  exit 0
}

main "$@"
