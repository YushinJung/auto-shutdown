#!/usr/bin/env bash
#
# uninstall.sh — auto-shutdown 제거 스크립트
#
# 사용법: sudo ./uninstall.sh
# 설정 파일(/etc/auto-shutdown)과 로그는 기본적으로 남긴다.
# 전부 지우려면:  sudo ./uninstall.sh --purge

set -euo pipefail

PURGE=false
[ "${1:-}" = "--purge" ] && PURGE=true

if [ "$(id -u)" -ne 0 ]; then
    echo "오류: root 권한이 필요합니다.  sudo ./uninstall.sh 로 실행하세요." >&2
    exit 1
fi

echo "==> auto-shutdown 제거 중..."

systemctl disable --now auto-shutdown.timer 2>/dev/null || true
rm -f /etc/systemd/system/auto-shutdown.timer
rm -f /etc/systemd/system/auto-shutdown.service
systemctl daemon-reload

rm -f /usr/local/sbin/auto-shutdown.sh
echo "    서비스/타이머/스크립트 제거 완료."

if [ "$PURGE" = true ]; then
    rm -rf /etc/auto-shutdown
    rm -rf /var/lib/auto-shutdown
    rm -f  /var/log/auto-shutdown.log
    echo "    설정/상태/로그까지 모두 삭제(--purge)."
else
    echo "    설정(/etc/auto-shutdown), 상태(/var/lib/auto-shutdown), 로그는 보존."
    echo "    전부 지우려면: sudo ./uninstall.sh --purge"
fi

echo "==> 제거 완료."
