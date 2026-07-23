#!/usr/bin/env bash
#
# install.sh — auto-shutdown 설치 스크립트
#
# 사용법:
#   git clone <repo> && cd auto-shutdown
#   sudo ./install.sh
#
# 비대화형(예: EC2 user-data)에서도 그대로 호출 가능하다.

set -euo pipefail

# 이 스크립트가 있는 디렉터리(repo 루트)
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SBIN_DST=/usr/local/sbin/auto-shutdown.sh
CONFIG_DIR=/etc/auto-shutdown
CONFIG_DST="$CONFIG_DIR/config.env"
STATE_DIR=/var/lib/auto-shutdown
SYSTEMD_DIR=/etc/systemd/system

if [ "$(id -u)" -ne 0 ]; then
    echo "오류: root 권한이 필요합니다.  sudo ./install.sh 로 실행하세요." >&2
    exit 1
fi

echo "==> auto-shutdown 설치 중..."

# 1) 감지 스크립트 배치
install -m 0755 "$SRC_DIR/auto-shutdown.sh" "$SBIN_DST"
echo "    스크립트:  $SBIN_DST"

# 2) 설정 파일 배치(기존 설정은 보존)
mkdir -p "$CONFIG_DIR"
if [ -f "$CONFIG_DST" ]; then
    echo "    설정:      $CONFIG_DST (이미 있음 — 덮어쓰지 않음)"
else
    install -m 0644 "$SRC_DIR/config.env" "$CONFIG_DST"
    echo "    설정:      $CONFIG_DST (신규 생성)"
fi

# 3) 상태 디렉터리
mkdir -p "$STATE_DIR"

# 4) systemd 유닛 배치
install -m 0644 "$SRC_DIR/systemd/auto-shutdown.service" "$SYSTEMD_DIR/auto-shutdown.service"
install -m 0644 "$SRC_DIR/systemd/auto-shutdown.timer"   "$SYSTEMD_DIR/auto-shutdown.timer"
echo "    systemd:   $SYSTEMD_DIR/auto-shutdown.{service,timer}"

# 5) 활성화
systemctl daemon-reload
systemctl enable --now auto-shutdown.timer
echo "    타이머 활성화 완료."

echo
echo "==> 설치 완료."
echo "    상태 확인:   systemctl status auto-shutdown.timer"
echo "    다음 실행:   systemctl list-timers auto-shutdown.timer"
echo "    로그 확인:   tail -f /var/log/auto-shutdown.log"
echo "    설정 변경:   sudo nano $CONFIG_DST   (다음 검사부터 자동 반영)"
echo "    종료 임시중단: sudo touch $STATE_DIR/keepalive"

# 6) EC2 shutdown behavior 경고
cat <<'WARN'

────────────────────────────────────────────────────────────────────────
⚠  중요: EC2 인스턴스의 "shutdown behavior" 를 반드시 확인하세요.
   이 도구는 인스턴스 내부에서 `shutdown -h now` 를 실행합니다.
   - shutdown behavior = stop      → 인스턴스가 '중지'됩니다(EBS 유지, 비용 절감). ✅ 정상
   - shutdown behavior = terminate → 인스턴스가 '삭제'됩니다. ❌ 위험!

   콘솔: EC2 > 인스턴스 선택 > 작업 > 인스턴스 설정 > 종료 동작 변경 → "중지(stop)"
   CLI:  aws ec2 modify-instance-attribute \
             --instance-id <ID> \
             --instance-initiated-shutdown-behavior stop
   (기본값은 stop 이지만, 확실히 하려면 위로 확인하세요.)
────────────────────────────────────────────────────────────────────────
WARN
