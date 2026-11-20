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

# --with-ssh-keepalive 로 설치했을 때 만든 drop-in 정리(있으면).
KEEPALIVE_DROPIN=/etc/ssh/sshd_config.d/60-auto-shutdown-keepalive.conf
if [ -f "$KEEPALIVE_DROPIN" ]; then
    rm -f "$KEEPALIVE_DROPIN"
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    echo "    SSH keepalive drop-in 제거."
elif grep -qE '^ClientAliveInterval 60' /etc/ssh/sshd_config 2>/dev/null; then
    echo "    참고: /etc/ssh/sshd_config 에 넣은 ClientAlive 설정은 그대로 둡니다(수동 제거 가능)."
fi

# --with-global-heartbeat 로 설치했을 때 만든 profile.d 스니펫 정리(있으면).
# 남겨두면 모든 사용자 셸이 아무도 읽지 않는 파일을 계속 touch 한다.
PROFILED=/etc/profile.d/auto-shutdown-heartbeat.sh
if [ -f "$PROFILED" ]; then
    rm -f "$PROFILED"
    echo "    전역 하트비트 스니펫 제거(이미 열려 있는 셸은 재접속 시 반영)."
fi

if [ "$PURGE" = true ]; then
    rm -rf /etc/auto-shutdown
    rm -rf /var/lib/auto-shutdown
    rm -f  /var/log/auto-shutdown.log
    echo "    설정/상태/로그까지 모두 삭제(--purge)."
    echo "    참고: 사용자별 하트비트(~/.cache/auto-shutdown)와 ~/.bashrc 설정은 건드리지 않습니다."
else
    echo "    설정(/etc/auto-shutdown), 상태(/var/lib/auto-shutdown), 로그는 보존."
    echo "    전부 지우려면: sudo ./uninstall.sh --purge"
fi

echo "==> 제거 완료."
