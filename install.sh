#!/usr/bin/env bash
#
# install.sh — auto-shutdown 설치 스크립트
#
# 사용법:
#   git clone <repo> && cd auto-shutdown
#   sudo ./install.sh [--with-ssh-keepalive] [--with-global-heartbeat]
#
# 옵션:
#   --with-ssh-keepalive  sshd 에 ClientAlive 설정을 넣어, 죽은 SSH 연결(노트북
#                         절전/네트워크 끊김 등)과 그에 딸린 로그인 세션이 약 3분
#                         내에 자동 정리되게 한다. 로그의 sessions=/ssh= 진단값을
#                         정확하게 유지한다.
#
#   --with-global-heartbeat
#                         /etc/profile.d 에 하트비트 스니펫을 설치해, 모든 사용자의
#                         대화형 '로그인' 셸이 명령을 칠 때마다 자기 홈에 하트비트를
#                         남기게 한다. SESSION_BLOCKS_SHUTDOWN=false 에서는 터미널
#                         접속 자체가 보호 근거가 아니므로, 계정이 여러 개인 서버라면
#                         이걸 쓰는 편이 안전하다(계정별 ~/.bashrc 설정을 빠뜨리면
#                         그 사용자의 저부하 작업이 보호되지 않는다).
#                         SSH 접속은 로그인 셸이라 적용되지만, 비로그인 대화형
#                         셸(중첩 bash, screen 윈도우 등)은 /etc/profile 을 읽지
#                         않으므로 적용되지 않는다 — 그쪽까지 필요하면 계정별
#                         ~/.bashrc 설정을 함께 쓸 것.
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
PROFILED_DST=/etc/profile.d/auto-shutdown-heartbeat.sh

# ---- 옵션 파싱 --------------------------------------------------------------
WITH_SSH_KEEPALIVE=false
WITH_GLOBAL_HEARTBEAT=false
for arg in "$@"; do
    case "$arg" in
        --with-ssh-keepalive) WITH_SSH_KEEPALIVE=true ;;
        --with-global-heartbeat) WITH_GLOBAL_HEARTBEAT=true ;;
        -h|--help)
            sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
# auto-shutdown: 죽은 SSH 연결과 그 로그인 세션을 빠르게 정리해 유휴 감지를 정확하게 유지.
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

# ---- 전역 하트비트 설치 헬퍼 ------------------------------------------------
# /etc/profile.d 에 스니펫을 깔아, 모든 사용자의 대화형 로그인 셸이 프롬프트마다
# 자기 홈에 하트비트를 남기게 한다. /etc/profile 은 로그인 셸만 읽으므로 SSH 접속은
# 커버되지만 비로그인 대화형 셸(중첩 bash 등)은 커버되지 않는다.
#
# 대화형이 아닐 때는 함수 정의조차 하지 않는다: profile.d 는 bash 뿐 아니라 sh
# 로도 읽히고, 비대화형 셸에는 프롬프트가 없어 PROMPT_COMMAND 가 무의미하다.
# 마커 이름(__auto_shutdown_hb)을 사용자별 ~/.bashrc 설정과 공유하므로, 둘을
# 같이 두어도 PROMPT_COMMAND 에 중복으로 들어가지 않는다(로그인 셸은
# /etc/profile -> ~/.bashrc 순서로 읽는다).
configure_global_heartbeat() {
    cat > "$PROFILED_DST" <<'HBEOF'
# auto-shutdown 하트비트 — 모든 사용자의 대화형 셸에 적용.
#
# SESSION_BLOCKS_SHUTDOWN=false 이므로 `who` 에 잡히는 것만으로는 보호되지 않는다.
# 프롬프트가 뜰 때마다(=명령을 칠 때마다) touch 해서, 창만 열어둔 상태와 실제로
# 쓰는 상태를 구분한다. 사용자별 ~/.bashrc 설정과 같은 마커를 쓰므로 중복되지 않는다.
case "$-" in
    *i*)
        __auto_shutdown_hb() {
            mkdir -p "$HOME/.cache/auto-shutdown" 2>/dev/null \
                && touch "$HOME/.cache/auto-shutdown/heartbeat" 2>/dev/null
            return 0
        }
        case "${PROMPT_COMMAND-}" in
            *__auto_shutdown_hb*) ;;
            *) PROMPT_COMMAND="__auto_shutdown_hb${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
        esac
        ;;
esac
HBEOF
    chmod 0644 "$PROFILED_DST"

    # 문법 검증: sh 로도 읽히므로 양쪽 다 본다.
    local ok=true
    bash -n "$PROFILED_DST" 2>/dev/null || ok=false
    sh   -n "$PROFILED_DST" 2>/dev/null || ok=false
    if [ "$ok" != true ]; then
        echo "    ⚠ 전역 하트비트: 문법 검증 실패 — $PROFILED_DST 제거함." >&2
        rm -f "$PROFILED_DST"
        return 1
    fi

    echo "    전역 하트비트: $PROFILED_DST 설치"
    echo "                   (이미 열려 있는 셸은 재접속 또는 'source $PROFILED_DST' 필요)"
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

# 7) (옵션) 전역 하트비트
if [ "$WITH_GLOBAL_HEARTBEAT" = true ]; then
    configure_global_heartbeat || true
fi

echo
echo "==> 설치 완료."
echo "    상태 확인:   systemctl status auto-shutdown.timer"
echo "    다음 실행:   systemctl list-timers auto-shutdown.timer"
echo "    로그 확인:   tail -f /var/log/auto-shutdown.log"
echo "    설정 변경:   sudo nano $CONFIG_DST   (다음 검사부터 자동 반영)"
echo "    종료 임시중단: sudo touch $STATE_DIR/keepalive"

# 8) EC2 shutdown behavior 경고
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
