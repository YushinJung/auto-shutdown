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
CHECK_DISK_IO=true
DISK_IO_THRESHOLD_KBPS=1000
CHECK_NET_IO=true
NET_IO_THRESHOLD_KBPS=1000
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

check_login_sessions() {
    local n
    n=$(who 2>/dev/null | wc -l)
    if [ "$n" -gt 0 ]; then
        echo "login_session(${n}users)"
        return 0
    fi
    return 1
}

check_ssh_connections() {
    local n
    n=$(ss -tnH state established '( sport = :22 )' 2>/dev/null | wc -l)
    if [ "$n" -gt 0 ]; then
        echo "ssh_conn(${n})"
        return 0
    fi
    return 1
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

# CPU/디스크/네트워크를 CHECK_INTERVAL 동안 측정. 사용 중이면 사유 출력 후 0 리턴.
check_resource_usage() {
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
    LAST_CPU_USAGE=$cpu_usage

    if [ "$cpu_usage" -gt "$CPU_THRESHOLD" ]; then
        echo "cpu(${cpu_usage}%>${CPU_THRESHOLD}%)"
        return 0
    fi

    if [ "$CHECK_DISK_IO" = true ]; then
        # 섹터(512B) → KB/s
        disk_kbps=$(( (d2 - d1) * 512 / 1024 / CHECK_INTERVAL ))
        if [ "$disk_kbps" -gt "$DISK_IO_THRESHOLD_KBPS" ]; then
            echo "disk_io(${disk_kbps}KB/s)"
            return 0
        fi
    fi

    if [ "$CHECK_NET_IO" = true ]; then
        net_kbps=$(( (n2 - n1) / 1024 / CHECK_INTERVAL ))
        if [ "$net_kbps" -gt "$NET_IO_THRESHOLD_KBPS" ]; then
            echo "net_io(${net_kbps}KB/s)"
            return 0
        fi
    fi

    return 1
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
    local reason=""

    # 빠른 신호부터 검사. 하나라도 걸리면 '사용 중'.
    reason=$(check_keepalive)       || \
    reason=$(check_login_sessions)  || \
    reason=$(check_ssh_connections) || \
    reason=$(check_watch_ports)     || \
    reason=$(check_resource_usage)  || reason=""

    local t_now
    t_now=$(now)

    if [ -n "$reason" ]; then
        # 사용 중 → 마지막 활동 시각 갱신, 종료 안 함.
        echo "$t_now" > "$STATE_FILE"
        log "BUSY  reason=${reason} idle_reset"
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

    idle_secs=$((t_now - last_active))
    [ "$idle_secs" -lt 0 ] && idle_secs=0
    idle_min=$((idle_secs / 60))
    threshold_secs=$((IDLE_MINUTES * 60))

    local status="cpu=${LAST_CPU_USAGE}% no_sessions idle_for=${idle_min}m/${IDLE_MINUTES}m"

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
