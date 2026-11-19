#!/bin/sh
# Giảm ghi thẻ nhớ ở mức hệ điều hành của Pi (chạy MỘT lần, bằng sudo):  sudo ./pi-reduce-writes.sh [--no-swap]
#
#  1. journald chỉ giữ log trong RAM (Storage=volatile, tối đa 16 MB) → log hệ thống + Docker daemon không ghi thẻ.
#  2. Tắt rsyslog nếu có (bản Raspberry Pi OS cũ ghi /var/log/syslog, messages…).
#  3. Docker mặc định không lưu log container (log-driver none) — chỉ khi chưa có /etc/docker/daemon.json.
#     Các file compose trong thư mục này đã tự đặt logging none, bước này để phủ cả container chạy tay.
#  4. Kiểm tra (không tự sửa) noatime trên phân vùng gốc và /tmp có nằm trong RAM không.
#  5. --no-swap: tắt swap trên thẻ (dphys-swapfile). Pi 3 chỉ có 1 GB RAM: chỉ dùng khi `free -m` cho thấy còn dư.
# Script chỉ thêm file cấu hình riêng (tên msmart-*), không sửa file hệ thống có sẵn. Khởi động lại Pi sau khi chạy.
set -eu

[ "$(id -u)" = 0 ] || { echo "cần chạy bằng sudo" >&2; exit 1; }
NO_SWAP=0
[ "${1:-}" = "--no-swap" ] && NO_SWAP=1

echo "== journald: log trong RAM"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/msmart-volatile.conf <<'EOF'
# Do msmart edge/pi-reduce-writes.sh tạo: log hệ thống chỉ trong RAM, mất khi khởi động lại.
[Journal]
Storage=volatile
RuntimeMaxUse=16M
EOF
systemctl restart systemd-journald
if [ -d /var/log/journal ]; then
  echo "   /var/log/journal còn log cũ trên thẻ (không còn ghi thêm). Xoá nếu muốn: sudo rm -rf /var/log/journal"
fi

echo "== rsyslog"
if systemctl list-unit-files rsyslog.service >/dev/null 2>&1 && systemctl is-enabled rsyslog >/dev/null 2>&1; then
  systemctl disable --now rsyslog
  echo "   đã tắt rsyslog (journald vẫn giữ log trong RAM: journalctl)"
else
  echo "   không có rsyslog đang bật"
fi

echo "== Docker: log-driver mặc định"
if [ -f /etc/docker/daemon.json ]; then
  echo "   đã có /etc/docker/daemon.json — không ghi đè. Muốn tắt log mặc định, thêm \"log-driver\": \"none\" vào file đó."
else
  mkdir -p /etc/docker
  printf '{\n  "log-driver": "none"\n}\n' > /etc/docker/daemon.json
  echo "   đã tạo /etc/docker/daemon.json (log-driver none); có hiệu lực sau khi khởi động lại Docker/Pi"
fi

echo "== Kiểm tra"
if awk '$2 == "/" && $4 ~ /noatime/ { found = 1 } END { exit !found }' /etc/fstab; then
  echo "   phân vùng gốc đã có noatime"
else
  echo "   CHƯA có noatime cho / trong /etc/fstab: thêm ',noatime' vào cột tuỳ chọn của dòng '/' rồi khởi động lại"
fi
if [ "$(findmnt -n -o FSTYPE /tmp 2>/dev/null || true)" = "tmpfs" ]; then
  echo "   /tmp đã nằm trong RAM"
else
  echo "   /tmp đang ở trên thẻ (các container đã có /tmp riêng trong RAM; với hệ điều hành có thể: sudo systemctl enable tmp.mount nếu có)"
fi

echo "== Swap"
if [ "$NO_SWAP" = 1 ]; then
  if command -v dphys-swapfile >/dev/null 2>&1; then
    dphys-swapfile swapoff || true
    systemctl disable --now dphys-swapfile || true
    echo "   đã tắt dphys-swapfile"
  else
    echo "   không thấy dphys-swapfile; kiểm tra bằng: swapon --show"
  fi
else
  swapon --show 2>/dev/null || true
  echo "   giữ nguyên swap (thêm --no-swap để tắt; cân nhắc RAM 1 GB của Pi 3)"
fi

echo "Xong. Khởi động lại Pi: sudo reboot"
