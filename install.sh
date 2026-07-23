#!/usr/bin/env bash
#
# install.sh — auto-shutdown 설치 스크립트
#
# 사용법:
#   git clone <repo> && cd auto-shutdown
#   sudo ./install.sh [--with-ssh-keepalive]
#
# 옵션:
#   --with-ssh-keepalive  sshd 에 ClientAlive 설정을 넣어, 죽은 SSH 연결(노트북
#                         절전/네트워크 끊김 등)이 약 3분 내에 자동 정리되게 한다.
#                         SSH 접속 기반 유휴 감지를 신뢰성 있게 만든다.
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

# ---- 옵션 파싱 --------------------------------------------------------------
WITH_SSH_KEEPALIVE=false
for arg in "$@"; do
    case "$arg" in
        --with-ssh-keepalive) WITH_SSH_KEEPALIVE=true ;;
        -h|--help)
            sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "알 수 없는 옵션: $arg" >&2; exit 1 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "오류: root 권한이 필요합니다.  sudo ./install.sh 로 실행하세요." >&2
    exit 1
fi

# ---- SSH keepalive 설정 헬퍼 ------------------------------------------------
# sshd_config 에 지시어를 설정(주석/기존 라인 있으면 치환, 없으면 추가).
set_sshd_directive() {
    local key="$1" val="$2" file=/etc/ssh/sshd_config
    if grep -qE "^[[:space:]]*#?[[:space:]]*${key}\b" "$file"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}\b.*|${key} ${val}|" "$file"
    else
        printf '%s %s\n' "$key" "$val" >> "$file"
    fi
}

configure_ssh_keepalive() {
    local dropin_dir=/etc/ssh/sshd_config.d
    local dropin="$dropin_dir/60-auto-shutdown-keepalive.conf"

    # Include 지시어가 있고 drop-in 디렉터리가 있으면 drop-in 파일로 관리(되돌리기 쉬움).
    if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null \
       && [ -d "$dropin_dir" ]; then
        cat > "$dropin" <<'EOF'
# auto-shutdown: 죽은 SSH 연결을 빠르게 정리해 유휴 감지를 정확하게 유지.
# 서버가 60초마다 클라이언트 생존을 확인하고, 3회(약 3분) 응답 없으면 연결을 끊는다.
ClientAliveInterval 60
ClientAliveCountMax 3
EOF
        chmod 0644 "$dropin"
        echo "    SSH keepalive: $dropin 생성"
    else
        set_sshd_directive ClientAliveInterval 60
        set_sshd_directive ClientAliveCountMax 3
        echo "    SSH keepalive: /etc/ssh/sshd_config 수정"
    fi

    # 설정 문법 검증 후에만 reload (잘못된 설정으로 SSH 잠기는 것 방지).
    local sshd_bin
    sshd_bin=$(command -v sshd || echo /usr/sbin/sshd)
    if ! "$sshd_bin" -t 2>/tmp/auto-shutdown-sshd-test.$$; then
        echo "    ⚠ sshd 설정 검증 실패 — reload 하지 않음. 아래 내용 확인:" >&2
        cat /tmp/auto-shutdown-sshd-test.$$ >&2
        rm -f /tmp/auto-shutdown-sshd-test.$$
        return 1
    fi
    rm -f /tmp/auto-shutdown-sshd-test.$$

    if systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; then
        echo "    SSH keepalive: 적용 완료(ClientAliveInterval=60, CountMax=3, 기존 연결 유지)."
    else
        echo "    ⚠ ssh 서비스 reload 실패 — 수동으로 'sudo systemctl reload ssh' 실행 필요." >&2
    fi
}

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

# 6) (옵션) SSH keepalive
if [ "$WITH_SSH_KEEPALIVE" = true ]; then
    configure_ssh_keepalive || true
fi

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
