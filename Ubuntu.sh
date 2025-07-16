#!/bin/bash

# Lấy tên hostname được truyền vào từ dòng lệnh
NEW_HOSTNAME="$1"

# --- Bắt đầu script ---

# 0. Kiểm tra quyền root
if [[ $EUID -ne 0 ]]; then
   echo "Lỗi: Bạn phải chạy script này với quyền root (sudo)."
   exit 1
fi

echo "============================================="
echo "  Bắt đầu quá trình thiết lập máy chủ... "
echo "============================================="

# 1. Đặt hostname mới
if [ -z "$NEW_HOSTNAME" ]; then
    echo "Không có hostname nào được nhập, bỏ qua bước đổi tên."
else
    echo ""
    echo "--- Bước 1: Đổi hostname thành '$NEW_HOSTNAME' ---"
    hostnamectl set-hostname "$NEW_HOSTNAME"
fi

# 2. Cập nhật hệ thống
echo ""
echo "--- Bước 2: Cập nhật và nâng cấp hệ thống ---"
apt update && apt upgrade -y

# 3. Cài đặt các gói cần thiết
echo ""
echo "--- Bước 3: Cài đặt các gói cần thiết ---"
apt install -y neofetch unzip nodejs npm python3 python3-pip build-essential git curl wget vim htop

# 4. Tạo và kích hoạt swap file
echo ""
echo "--- Bước 4: Tạo và kích hoạt 5GB RAM ảo (swap) ---"
SWAP_FILE="/swapfile"
if [ -f "$SWAP_FILE" ]; then
    echo "Thông báo: Tệp tin swap '$SWAP_FILE' đã tồn tại."
else
    fallocate -l 5G $SWAP_FILE
    chmod 600 $SWAP_FILE
    mkswap $SWAP_FILE
    swapon $SWAP_FILE
    echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
fi

echo ""
echo "============================================="
echo " HOÀN TẤT TOÀN BỘ QUÁ TRÌNH! "
echo "============================================="
echo "Hostname mới của bạn là: $(hostname)"
