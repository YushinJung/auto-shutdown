# auto-shutdown

EC2 인스턴스가 **일정 시간(기본 30분) 동안 아무도 쓰지 않으면 스스로 종료(stop)**되게 하는 작은 도구입니다. 파이프라인을 쓰고 인스턴스를 끄지 않아 새는 비용을 막습니다.

- **순수 bash + systemd** — 외부 패키지 의존성 0. 어떤 EC2(Ubuntu/Amazon Linux 등)에서도 동작.
- **오탐 방지 우선** — SSH 세션·감시 포트·CPU·디스크/네트워크 I/O 중 **하나라도** 활동이 있으면 종료를 미룹니다. CPU가 낮아도 I/O로 돌아가는 NGS 잡·대용량 다운로드는 보호됩니다.
- **git clone → `sudo ./install.sh`** 한 번으로 다른 인스턴스에도 그대로 적용.

## 설치

```bash
git clone https://github.com/YushinJung/auto-shutdown.git
cd auto-shutdown
sudo ./install.sh
```

설치되면 systemd 타이머가 **부팅 5분 후부터 1분마다** 유휴 여부를 검사합니다.

> ⚠ **EC2 shutdown behavior 확인 필수**
> 이 도구는 인스턴스 내부에서 `shutdown -h now`를 실행합니다.
> - `stop` (기본값) → 인스턴스 **중지**(EBS 유지, 비용 절감) ✅
> - `terminate` → 인스턴스 **삭제** ❌
>
> 콘솔: EC2 > 인스턴스 > 작업 > 인스턴스 설정 > 종료 동작 변경 → **중지(stop)**
> 설치 스크립트도 마지막에 이 경고를 출력합니다.

## 동작 방식

매 검사마다 아래 신호 중 **하나라도** 잡히면 "사용 중"으로 보고 "마지막 활동 시각"을 갱신합니다. 마지막 활동으로부터 `IDLE_MINUTES` 이상 지나야만 종료합니다.

| 신호 | 감지 방법 |
|------|-----------|
| 로그인 세션 | `who` |
| SSH 연결 (VS Code Remote 포함) | `ss` established, 포트 22 |
| 감시 포트 (Jupyter 등) | `ss` established, `WATCH_PORTS` |
| CPU 사용률 | `/proc/stat` 델타 > `CPU_THRESHOLD`% |
| 디스크 I/O | `/proc/diskstats` 델타 > 임계 |
| 네트워크 I/O | `/proc/net/dev` 델타 > 임계 |
| 수동 keepalive | `keepalive` 파일 존재 |

> RAM은 종료 판단에 쓰지 않습니다. 유휴 상태에서도 캐시/상주 프로세스로 높게 유지되어 영영 종료가 안 되는 문제를 막기 위함입니다.

## 설정

설정 파일: `/etc/auto-shutdown/config.env` (값 변경 시 다음 검사부터 자동 반영)

| 항목 | 기본값 | 설명 |
|------|--------|------|
| `ENABLED` | `true` | `false`면 감지·로그만 남기고 종료 안 함(관찰 모드) |
| `IDLE_MINUTES` | `30` | 이 시간 동안 계속 유휴면 종료 |
| `CPU_THRESHOLD` | `5` | CPU 사용률(%) 이하를 유휴로 간주 |
| `WATCH_PORTS` | `"8888"` | 공백 구분. 비우면 포트 검사 안 함 |
| `CHECK_DISK_IO` / `DISK_IO_THRESHOLD_KBPS` | `true` / `1000` | 디스크 I/O 감지 |
| `CHECK_NET_IO` / `NET_IO_THRESHOLD_KBPS` | `true` / `1000` | 네트워크 I/O 감지 |
| `DRY_RUN` | `false` | `true`면 실제 종료 대신 로그만 |

## 로그 확인

**`/var/log/auto-shutdown.log`** 한 파일만 보면 됩니다.

```bash
tail -f /var/log/auto-shutdown.log
```

예시:
```
2026-07-23 14:02:01 BUSY  reason=ssh_conn(2) idle_reset
2026-07-23 14:20:01 IDLE  cpu=0% no_sessions idle_for=17m/30m
2026-07-23 14:33:01 IDLE  cpu=0% no_sessions idle_for=30m/30m -> SHUTDOWN NOW
```

보조로 systemd journal 에도 남습니다: `journalctl -u auto-shutdown`

## 자주 쓰는 명령

```bash
# 상태/다음 실행 시각
systemctl status auto-shutdown.timer
systemctl list-timers auto-shutdown.timer

# 지금 한 번 수동 검사(로그로 결과 확인)
sudo systemctl start auto-shutdown.service

# 자동 종료 임시 중단 / 재개 (예: 밤새 돌릴 잡이 있을 때)
sudo touch /var/lib/auto-shutdown/keepalive   # 중단
sudo rm    /var/lib/auto-shutdown/keepalive   # 재개

# 잠깐 완전히 끄기 / 다시 켜기
sudo systemctl stop  auto-shutdown.timer
sudo systemctl start auto-shutdown.timer
```

## 처음 도입 시 권장 검증

실제로 인스턴스를 꺼보기 전에 안전하게 확인하세요.

1. `/etc/auto-shutdown/config.env` 에서 `DRY_RUN=true`, `IDLE_MINUTES=2` 로 설정.
2. 접속을 끊고 부하 없이 2분 두기 → 로그에 `WOULD SHUTDOWN` 이 찍히는지 확인.
3. SSH 접속 / Jupyter 포트 연결 / CPU 부하(`yes >/dev/null &`) / `touch keepalive` 를 각각 걸어보고 → `BUSY reason=...` 로 타이머가 리셋되는지 확인.
4. 확인되면 `DRY_RUN=false`, `IDLE_MINUTES=30` 으로 되돌리기.

## 제거

```bash
sudo ./uninstall.sh            # 서비스만 제거(설정·로그 보존)
sudo ./uninstall.sh --purge    # 설정·상태·로그까지 전부 삭제
```

## EC2 user-data 로 자동 설치(선택)

새 인스턴스 생성 시 user-data 에 넣으면 부팅과 동시에 설치됩니다.

```bash
#!/bin/bash
cd /opt
git clone https://github.com/YushinJung/auto-shutdown.git
cd auto-shutdown
./install.sh
```
