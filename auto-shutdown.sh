#!/usr/bin/env bash
#
# auto-shutdown.sh — EC2 유휴 감지 후 자동 종료
#
# systemd timer 가 1분마다 이 스크립트를 실행한다. 매 실행마다 "지금 사용 중인가?"를
# 판정하고, 사용 중이면 마지막 활동 시각을 갱신한다. 마지막 활동으로부터
# IDLE_MINUTES 이상 지났으면 인스턴스를 종료(shutdown)한다.
#
# 설계 원칙: 오탐(사용 중인데 종료)을 절대 피한다. 아래 신호 중 하나라도 잡히면
# 즉시 '사용 중'으로 보고 종료를 미룬다.

set -u

CONFIG_FILE="${CONFIG_FILE:-/etc/auto-shutdown/config.env}"

# ---- 기본값 (config 에서 덮어씀) -------------------------------------------
ENABLED=true
IDLE_MINUTES=30
CPU_THRESHOLD=5
CHECK_INTERVAL=3
WATCH_PORTS="8888"
# 한 줄에 패턴 하나. 매칭되는 프로세스가 있으면 사용 중(check_watch_processes 참고).
WATCH_PROCESSES=""
# 매칭 프로세스가 이 시간(시)보다 오래 돌았으면 예외에서 뺀다. 0 이면 상한 없음.
WATCH_PROCESS_MAX_HOURS=3
CHECK_DISK_IO=true
DISK_IO_THRESHOLD_KBPS=200
CHECK_NET_IO=true
NET_IO_THRESHOLD_KBPS=200
# true(기본) 면 실제 로그인 세션/SSH 연결이 있는 것만으로도 종료를 막는다.
#   여기서 '실제'는 detached tmux/screen 을 제외한 값이다(count_login_sessions 주석 참고).
# false 면 세션은 로그에만 남기고, CPU/디스크/네트워크가 낮으면 접속 중이어도 종료한다.
SESSION_BLOCKS_SHUTDOWN=true
KEEPALIVE_FILE=/var/lib/auto-shutdown/keepalive
DRY_RUN=false
LOG_FILE=/var/log/auto-shutdown.log
MAX_LOG_BYTES=5242880

# 상태 디렉터리(테스트 시 env/config 로 덮어쓸 수 있음)
STATE_DIR=/var/lib/auto-shutdown

# shellcheck disable=SC1090
[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"

STATE_FILE="$STATE_DIR/last-active"
mkdir -p "$STATE_DIR"

# ---- 로그 -------------------------------------------------------------------
log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    # 로그 파일이 너무 커지면 뒷부분만 남기고 잘라낸다.
    if [ -f "$LOG_FILE" ]; then
        local size
        size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$size" -gt "$MAX_LOG_BYTES" ]; then
            tail -n 1000 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE"
        fi
    fi
    printf '%s %s\n' "$ts" "$1" | tee -a "$LOG_FILE" >/dev/null
    # systemd journal 로도 남긴다(로그 파일이 지워져도 조회 가능).
    logger -t auto-shutdown -- "$1" 2>/dev/null || true
}

now() { date +%s; }

# 부팅 시각(epoch). 상태파일이 없을 때 초기값으로 사용.
boot_time() { awk '/^btime/ {print $2}' /proc/stat; }

# ---- '사용 중' 판정 신호들 --------------------------------------------------
# 각 함수: 사용 중이면 사유 문자열을 stdout 으로 출력하고 0 리턴, 아니면 1 리턴.

check_keepalive() {
    if [ -n "$KEEPALIVE_FILE" ] && [ -e "$KEEPALIVE_FILE" ]; then
        echo "keepalive_file"
        return 0
    fi
    return 1
}

# 아래 셋은 사유 문자열이 아니라 개수(0 이상)를 출력한다.
#
# tmux/screen 같은 터미널 멀티플렉서는 자기 pty 를 utmp 에 등록해두고, SSH 연결이
# 끊긴 뒤에도 그 항목을 그대로 남긴다(detached 세션). 그래서 아무도 접속해 있지
# 않아도 `who` 는 계속 사용자를 보고하고, 이 상태가 tmux 서버가 죽거나 재부팅할
# 때까지 유지된다. 이런 항목은 '사람이 붙어 있다'의 근거가 될 수 없으므로 실제
# 로그인 수에서 제외한다. 판별 근거는 who 의 마지막 필드(호스트):
#   detached tmux :  someuser  pts/5  2026-07-30 16:16  (tmux(47323).%0)
#   실제 로그인   :  someuser  pts/0  2026-07-30 16:16  (203.0.113.10)
# 호스트 필드가 아예 없는 로컬 콘솔 로그인은 마지막 필드가 시각이라 걸리지 않는다.
# 참고: tmux/screen 만 처리한다. 그 외 멀티플렉서는 커버하지 않는다.
_MUX_RE='(tmux|screen)'

# 멀티플렉서 항목을 제외한 '실제' 로그인 세션 수.
# NF>0 은 빈 줄 방어. 빈 줄은 $NF 가 비어 있어 정규식에 안 걸리므로, 없으면
# 로그인 1건으로 잘못 세어 종료를 영영 막는다.
count_login_sessions() {
    who 2>/dev/null | awk -v re="$_MUX_RE" 'NF>0 && $NF !~ re' | wc -l
}

# 멀티플렉서(detached tmux 등) 항목 수. 종료 판정에는 안 쓰고 로그 진단용으로만 남긴다.
count_multiplexer_sessions() {
    who 2>/dev/null | awk -v re="$_MUX_RE" 'NF>0 && $NF ~ re' | wc -l
}

# pty 를 안 받는 SSH 접속(VS Code Remote-SSH, Claude Code 등 `sshd: user@notty`)은
# utmp 에 안 남아 `who` 로는 아예 안 보인다. 실제 접속 여부는 이 검사가 담당한다.
count_ssh_connections() {
    ss -tnH state established '( sport = :22 )' 2>/dev/null | wc -l
}

check_watch_ports() {
    local port n
    for port in $WATCH_PORTS; do
        n=$(ss -tnH state established "( sport = :$port )" 2>/dev/null | wc -l)
        if [ "$n" -gt 0 ]; then
            echo "port:${port}(${n}conn)"
            return 0
        fi
    done
    return 1
}

# WATCH_PROCESSES 의 패턴(한 줄에 하나, pgrep -f 확장 정규식) 중 하나라도 명령줄에
# 매칭되는 프로세스가 있으면 사용 중. CPU/I/O 를 거의 안 쓰는 대기 구간(다른
# 인스턴스의 작업 완료를 기다리는 파이프라인 등)을 지키기 위한 것.
# 패턴에 공백을 넣을 수 있도록 공백이 아니라 줄 단위로 나눈다. 앞뒤 공백은 무시하고,
# 빈 줄과 # 으로 시작하는 줄은 건너뛴다.
# WATCH_PROCESS_MAX_HOURS(>0)보다 오래 실행된 프로세스(ps etimes 기준)는 멈춘 것으로
# 보고 예외에서 뺀다. 이때는 다른 신호(CPU/I/O 등)로만 판단한다.
# 주의: -f 는 명령줄 전체를 보므로 `vim .../main.py` 처럼 파일을 열어만 둬도 매칭된다.
check_watch_processes() {
    local pat pid etimes fresh expired max_secs
    max_secs=$(( ${WATCH_PROCESS_MAX_HOURS:-0} * 3600 ))
    while IFS= read -r pat; do
        pat="${pat#"${pat%%[![:space:]]*}"}"
        pat="${pat%"${pat##*[![:space:]]}"}"
        case "$pat" in ''|'#'*) continue ;; esac
        fresh=""
        expired=""
        for pid in $(pgrep -f -- "$pat" 2>/dev/null); do
            etimes=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
            [ -n "$etimes" ] || continue   # 그새 끝난 프로세스
            if [ "$max_secs" -gt 0 ] && [ "$etimes" -gt "$max_secs" ]; then
                expired="${expired:+$expired,}${pid}"
            else
                fresh="${fresh:+$fresh,}${pid}"
            fi
        done
        if [ -n "$fresh" ]; then
            echo "process:${pat}(pid=${fresh})"
            return 0
        fi
        # 상한을 넘긴 프로세스만 남았다 → 예외에서 뺀다(CPU/I/O 로만 판단). 멈춘
        # 작업이 인스턴스를 무한정 켜두는 것을 막기 위함. 매 검사마다 경고를 남긴다.
        [ -n "$expired" ] && log "WARN  process:${pat}(pid=${expired}) 실행 ${WATCH_PROCESS_MAX_HOURS}h 초과 → 예외 해제"
    done <<< "$WATCH_PROCESSES"
    return 1
}

# ---- CPU / I/O 스냅샷 (한 번의 sleep 으로 세 가지 델타를 함께 계산) ----------

# /proc/stat 에서 (idle, total) 반환
_cpu_snapshot() {
    local cpu user nice system idle iowait irq softirq steal _rest total
    read -r cpu user nice system idle iowait irq softirq steal _rest < /proc/stat
    total=$((user + nice + system + idle + iowait + irq + softirq + steal))
    echo "$idle $total"
}

# /proc/diskstats 에서 읽기+쓰기 섹터 합계 반환(loop/ram 장치 제외). 섹터=512B.
_disk_sectors() {
    awk '$3 !~ /^(loop|ram|dm-)/ { r += $6; w += $10 } END { print r + w }' /proc/diskstats
}

# /proc/net/dev 에서 rx+tx 바이트 합계 반환(lo 제외).
_net_bytes() {
    awk -F'[: ]+' 'NR>2 && $2 != "lo" { rx += $3; tx += $11 } END { print rx + tx }' /proc/net/dev
}

# CPU/디스크/네트워크를 CHECK_INTERVAL 동안 측정해 전역 변수에 기록한다:
#   LAST_CPU_USAGE / LAST_DISK_KBPS / LAST_NET_KBPS / USAGE_REASON(사용 중이면 사유, 아니면 "")
# 주의: `$(measure_resources)` 처럼 서브셸에서 호출하면 전역 변수가 부모 셸로
# 전파되지 않는다. 반드시 그냥 호출해서 부모(main) 셸에서 실행되게 할 것.
measure_resources() {
    local c1 c2 idle1 total1 idle2 total2 dtotal didle cpu_usage
    local d1 d2 n1 n2 disk_kbps net_kbps

    c1=$(_cpu_snapshot)
    [ "$CHECK_DISK_IO" = true ] && d1=$(_disk_sectors) || d1=0
    [ "$CHECK_NET_IO" = true ] && n1=$(_net_bytes) || n1=0

    sleep "$CHECK_INTERVAL"

    c2=$(_cpu_snapshot)
    [ "$CHECK_DISK_IO" = true ] && d2=$(_disk_sectors) || d2=0
    [ "$CHECK_NET_IO" = true ] && n2=$(_net_bytes) || n2=0

    read -r idle1 total1 <<< "$c1"
    read -r idle2 total2 <<< "$c2"
    dtotal=$((total2 - total1))
    didle=$((idle2 - idle1))
    if [ "$dtotal" -le 0 ]; then
        cpu_usage=0
    else
        cpu_usage=$(( (100 * (dtotal - didle)) / dtotal ))
    fi

    disk_kbps=0
    # 섹터(512B) → KB/s
    [ "$CHECK_DISK_IO" = true ] && disk_kbps=$(( (d2 - d1) * 512 / 1024 / CHECK_INTERVAL ))

    net_kbps=0
    [ "$CHECK_NET_IO" = true ] && net_kbps=$(( (n2 - n1) / 1024 / CHECK_INTERVAL ))

    LAST_CPU_USAGE=$cpu_usage
    LAST_DISK_KBPS=$disk_kbps
    LAST_NET_KBPS=$net_kbps

    USAGE_REASON=""
    if [ "$cpu_usage" -gt "$CPU_THRESHOLD" ]; then
        USAGE_REASON="cpu(${cpu_usage}%>${CPU_THRESHOLD}%)"
    elif [ "$CHECK_DISK_IO" = true ] && [ "$disk_kbps" -gt "$DISK_IO_THRESHOLD_KBPS" ]; then
        USAGE_REASON="disk_io(${disk_kbps}KB/s)"
    elif [ "$CHECK_NET_IO" = true ] && [ "$net_kbps" -gt "$NET_IO_THRESHOLD_KBPS" ]; then
        USAGE_REASON="net_io(${net_kbps}KB/s)"
    fi
}

# ---- 종료 -------------------------------------------------------------------
do_shutdown() {
    local reason="$1"
    if [ "$DRY_RUN" = true ]; then
        log "IDLE  ${reason} -> WOULD SHUTDOWN (dry_run=true, 실제 종료 안 함)"
        return 0
    fi
    log "IDLE  ${reason} -> SHUTDOWN NOW"
    /sbin/shutdown -h now "auto-shutdown: 유휴 상태 ${IDLE_MINUTES}분 초과" 2>/dev/null \
        || shutdown -h now 2>/dev/null \
        || systemctl poweroff
}

# ---- 메인 -------------------------------------------------------------------
main() {
    LAST_CPU_USAGE=0
    LAST_DISK_KBPS=0
    LAST_NET_KBPS=0
    USAGE_REASON=""

    # 세션 개수는 항상 수집해 로그에 남긴다. session_count 는 detached tmux/screen 을
    # 제외한 '실제' 로그인 수이고, mux_count 는 제외된 개수(진단용).
    local session_count mux_count ssh_count
    session_count=$(count_login_sessions)
    mux_count=$(count_multiplexer_sessions)
    ssh_count=$(count_ssh_connections)

    # CPU/디스크/네트워크는 세션 유무와 무관하게 매번 측정한다: 로그에 항상 남기고,
    # 세션이 있어도 자원 사용이 실제로 낮으면 idle 판정에 반영하기 위해.
    measure_resources

    local reason=""
    reason=$(check_keepalive)
    if [ -z "$reason" ]; then
        reason=$(check_watch_ports)
    fi
    if [ -z "$reason" ]; then
        reason=$(check_watch_processes)
    fi
    if [ -z "$reason" ] && [ "$SESSION_BLOCKS_SHUTDOWN" = true ]; then
        if [ "$session_count" -gt 0 ]; then
            reason="login_session(${session_count}users)"
        elif [ "$ssh_count" -gt 0 ]; then
            reason="ssh_conn(${ssh_count})"
        fi
    fi
    if [ -z "$reason" ]; then
        reason="$USAGE_REASON"
    fi

    local t_now
    t_now=$(now)

    local ctx="cpu=${LAST_CPU_USAGE}% disk=${LAST_DISK_KBPS}KB/s net=${LAST_NET_KBPS}KB/s sessions=${session_count} mux=${mux_count} ssh=${ssh_count}"

    if [ -n "$reason" ]; then
        # 사용 중 → 마지막 활동 시각 갱신, 종료 안 함.
        echo "$t_now" > "$STATE_FILE"
        log "BUSY  reason=${reason} ${ctx} idle_reset"
        return 0
    fi

    # 유휴 상태. 마지막 활동 시각 확인(없으면 부팅 시각으로 초기화).
    local last_active idle_secs idle_min threshold_secs
    if [ -f "$STATE_FILE" ]; then
        last_active=$(cat "$STATE_FILE")
    else
        last_active=$(boot_time)
        echo "$last_active" > "$STATE_FILE"
    fi
    # 상태파일이 손상된 경우 방어
    case "$last_active" in
        ''|*[!0-9]*) last_active=$t_now; echo "$last_active" > "$STATE_FILE" ;;
    esac
    # 상태파일은 /var/lib 에 있어 재부팅 후에도 남는다. 이전 부팅에서 기록된 값이면
    # 부팅 시각부터 다시 센다. 안 그러면 부팅 직후 첫 검사(OnBootSec=5min)에서
    # idle_for=1568m 처럼 계산돼 켜자마자 꺼진다.
    local t_boot
    t_boot=$(boot_time)
    if [ "$last_active" -lt "$t_boot" ]; then
        last_active=$t_boot
        echo "$last_active" > "$STATE_FILE"
    fi

    idle_secs=$((t_now - last_active))
    [ "$idle_secs" -lt 0 ] && idle_secs=0
    idle_min=$((idle_secs / 60))
    threshold_secs=$((IDLE_MINUTES * 60))

    local status="${ctx} idle_for=${idle_min}m/${IDLE_MINUTES}m"

    if [ "$idle_secs" -ge "$threshold_secs" ]; then
        if [ "$ENABLED" != true ]; then
            log "IDLE  ${status} (ENABLED=false, 종료 안 함)"
            return 0
        fi
        do_shutdown "$status"
    else
        log "IDLE  ${status}"
    fi
}

main "$@"
