# auto-shutdown

EC2 인스턴스가 **일정 시간(기본 30분) 동안 아무도 쓰지 않으면 스스로 종료(stop)**되게 하는 작은 도구입니다. 파이프라인을 쓰고 인스턴스를 끄지 않아 새는 비용을 막습니다.

- **순수 bash + systemd** — 외부 패키지 의존성 0. 어떤 EC2(Ubuntu/Amazon Linux 등)에서도 동작.
- **오탐 방지 우선** — SSH 접속·감시 포트·CPU·디스크/네트워크 I/O 중 **하나라도** 활동이 있으면 종료를 미룹니다. CPU가 낮아도 I/O로 돌아가는 NGS 잡·대용량 다운로드는 보호됩니다.
- **유령 세션은 무시** — detached `tmux`/`screen` 은 아무도 접속 안 해도 `who`에 영원히 남아 종료를 막습니다. 이 항목은 걸러냅니다 ([자세히](#동작-방식)).
- **git clone → `sudo ./install.sh`** 한 번으로 다른 인스턴스에도 그대로 적용.
- **`--with-ssh-keepalive` 옵션** — 죽은 SSH 연결이 오래 남아 종료를 막는 문제를 방지 (아래 [설치](#옵션-with-ssh-keepalive-권장) 참고).

## 설치

```bash
git clone https://github.com/YushinJung/auto-shutdown.git
cd auto-shutdown
sudo ./install.sh
```

설치되면 systemd 타이머가 **부팅 5분 후부터 1분마다** 유휴 여부를 검사합니다.

### 옵션: `--with-ssh-keepalive` (권장)

```bash
sudo ./install.sh --with-ssh-keepalive
```

SSH 접속을 유휴 판단 신호로 쓰는데, 기본 sshd 설정은 **죽은 연결(노트북 절전·와이파이 끊김 등)을 약 2시간 동안 ESTABLISHED로 붙들고** 있습니다. 그 동안 "접속 중"으로 오판돼 종료가 안 됩니다. 이 옵션은 sshd에 `ClientAliveInterval 60` / `ClientAliveCountMax 3` 을 설정해 **죽은 연결이 약 3분 내에 자동 정리**되게 만듭니다(기존 연결은 유지, 설정 문법 검증 후 reload). `sshd_config.d/` 를 쓰는 시스템에서는 drop-in 파일로 관리되어 제거도 깔끔합니다.

> 참고: VS Code Remote-SSH나 Claude Code 원격 세션은 창/세션이 열려 있는 한 SSH 연결을 유지합니다. 이건 정상 동작이며, 세션을 정상 종료하면 연결도 닫힙니다. keepalive는 "정상 종료가 아닌" 유령 연결을 빠르게 정리하는 안전장치입니다.

> ⚠ **EC2 shutdown behavior 확인 필수**
> 이 도구는 인스턴스 내부에서 `shutdown -h now`를 실행합니다.
> - `stop` (기본값) → 인스턴스 **중지**(EBS 유지, 비용 절감) ✅
> - `terminate` → 인스턴스 **삭제** ❌
>
> 콘솔: EC2 > 인스턴스 > 작업 > 인스턴스 설정 > 종료 동작 변경 → **중지(stop)**
> 설치 스크립트도 마지막에 이 경고를 출력합니다.

## 동작 방식

매 검사마다 아래 신호 중 **하나라도** 잡히면 "사용 중"으로 보고 "마지막 활동 시각"을 갱신합니다. 마지막 활동으로부터 `IDLE_MINUTES` 이상 지나야만 종료합니다.

| 신호 | 감지 방법 | 종료를 막는가 |
|------|-----------|---------------|
| 감시 포트 (Jupyter 등) | `ss` established, `WATCH_PORTS` | 예 |
| CPU 사용률 | `/proc/stat` 델타 > `CPU_THRESHOLD`% | 예 |
| 디스크 I/O | `/proc/diskstats` 델타 > 임계 | 예 |
| 네트워크 I/O | `/proc/net/dev` 델타 > 임계 | 예 |
| 수동 keepalive | `keepalive` 파일 존재 | 예 |
| 로그인 세션 | `who` (**detached tmux/screen 제외**) | 예 (`SESSION_BLOCKS_SHUTDOWN=false` 면 아니오) |
| SSH 연결 (VS Code Remote 포함) | `ss` established, 포트 22 | 예 (`SESSION_BLOCKS_SHUTDOWN=false` 면 아니오) |
| detached tmux/screen | `who` 호스트 필드 | **아니오** (로그에 `mux=N` 으로만 표시) |

CPU/디스크/네트워크는 세션 유무와 무관하게 **매 검사마다** 측정하고 로그에 남깁니다.

> **`who`를 그대로 믿으면 안 되는 이유 (실제로 겪은 문제)**
> `tmux`/`screen` 세션은 자기 pty를 utmp에 등록하고, **SSH 연결이 끊긴 뒤에도 그 항목을 남깁니다.** 그래서 아무도 접속해 있지 않아도 `who`는 계속 `1 user`를 보고하고, tmux 서버가 죽거나 재부팅할 때까지 유지됩니다.
>
> ```
> $ who
> yushin  pts/5  2026-07-30 16:16 (tmux(47323).%0)   ← 접속자 0명인데 1 user
> $ tmux list-clients
> (비어 있음 = 아무도 붙어 있지 않음)
> ```
>
> 실제로 `tmux new -s archive` 후 detach 하고 나간 인스턴스가 **19시간 동안** `BUSY reason=login_session(1users)` 만 찍으며 안 꺼진 사례가 있었습니다. `--with-ssh-keepalive`로도 못 막습니다 — 정리할 SSH 연결 자체가 없기 때문입니다.
>
> **그래서 `who`에서 tmux/screen 항목을 빼고 셉니다.** 판별은 호스트 필드로 합니다(`(tmux(47323).%0)` vs 실제 로그인의 `(203.0.113.10)`). 제외된 개수는 로그에 `mux=N` 으로 남아 진단할 수 있습니다.

**즉 정책은 이렇습니다:**

| 상황 | 판정 |
|------|------|
| SSH로 사람이 접속해 있음 | CPU가 0%여도 **안 꺼짐** |
| detached tmux만 남아 있고 아무도 접속 안 함 | CPU/디스크/네트워크가 낮으면 **꺼짐** |
| detached tmux 안에서 잡이 실제로 돌고 있음 | CPU/디스크/네트워크에 걸려 **안 꺼짐** |

> ⚠ 접속만 해두고 자리를 비우면(VS Code·Claude Code 창을 켜둔 채 퇴근 등) `ss` 에 연결이 남아 안 꺼집니다. 이게 싫으면 `SESSION_BLOCKS_SHUTDOWN=false` 로 바꾸세요 — 접속 여부를 무시하고 CPU/I/O만으로 판단합니다.

> RAM은 종료 판단에 쓰지 않습니다. 유휴 상태에서도 캐시/상주 프로세스로 높게 유지되어 영영 종료가 안 되는 문제를 막기 위함입니다.

> ⚠ CPU는 코어 전체 평균입니다(8 vCPU에서 1코어 20% 사용 = 전체 2.5%). 대용량 다운로드처럼 CPU는 거의 안 쓰고 네트워크/디스크만 쓰는 작업은 `CPU_THRESHOLD`로 못 잡습니다 — 이런 작업은 `NET_IO_THRESHOLD_KBPS`/`DISK_IO_THRESHOLD_KBPS`가 지켜주므로 값을 너무 높게 잡지 마세요. 반대로 CPU를 거의 안 쓰는 사람의 작업(로그 읽기, 코드 리뷰 등)은 이 도구 입장에서 유휴와 구분이 안 되니, 오래 그렇게 있을 예정이면 `touch keepalive`로 수동 보호하세요.

## 설정

설정 파일: `/etc/auto-shutdown/config.env` (값 변경 시 다음 검사부터 자동 반영)

| 항목 | 기본값 | 설명 |
|------|--------|------|
| `ENABLED` | `true` | `false`면 감지·로그만 남기고 종료 안 함(관찰 모드) |
| `IDLE_MINUTES` | `30` | 이 시간 동안 계속 유휴면 종료 |
| `CPU_THRESHOLD` | `5` | CPU 사용률(%) 이하를 유휴로 간주 |
| `WATCH_PORTS` | `"8888"` | 공백 구분. 비우면 포트 검사 안 함 |
| `CHECK_DISK_IO` / `DISK_IO_THRESHOLD_KBPS` | `true` / `200` | 디스크 I/O 감지 |
| `CHECK_NET_IO` / `NET_IO_THRESHOLD_KBPS` | `true` / `200` | 네트워크 I/O 감지 |
| `SESSION_BLOCKS_SHUTDOWN` | `true` | 접속한 사람이 있으면 CPU가 낮아도 종료 안 함. `false`면 접속 무시하고 CPU/I/O로만 판단 |
| `DRY_RUN` | `false` | `true`면 실제 종료 대신 로그만 |

## 로그 확인

**`/var/log/auto-shutdown.log`** 한 파일만 보면 됩니다.

```bash
tail -f /var/log/auto-shutdown.log
```

예시 — 사람이 접속을 끊고, detached tmux 만 남은 뒤 종료되는 흐름:
```
2026-07-23 14:02:01 BUSY  reason=ssh_conn(1) cpu=1% disk=0KB/s net=8KB/s sessions=0 mux=1 ssh=1 idle_reset
2026-07-23 14:20:01 IDLE  cpu=1% disk=0KB/s net=3KB/s sessions=0 mux=1 ssh=0 idle_for=17m/30m
2026-07-23 14:33:01 IDLE  cpu=0% disk=0KB/s net=0KB/s sessions=0 mux=1 ssh=0 idle_for=30m/30m -> SHUTDOWN NOW
```

| 필드 | 뜻 |
|------|-----|
| `cpu=` `disk=` `net=` | 매 검사마다 실측한 값. 세션 유무와 무관하게 항상 기록 |
| `sessions=` | **실제** 로그인 수 (detached tmux/screen 제외) |
| `mux=` | 제외된 tmux/screen 항목 수. `sessions=0 mux=1` = 유령 세션만 있음 |
| `ssh=` | 포트 22 established 연결 수. pty 없는 접속(VS Code·Claude Code)은 `who`에 안 잡히므로 이 필드로만 보입니다 |

위 예시에서 `mux=1`은 끝까지 유지되지만(tmux가 살아 있음) 종료를 막지 않습니다. 14:20에 `ssh=1 → 0` 으로 바뀌며 사람이 나간 시점이 드러납니다.

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
4. **tmux 필터 확인** — `tmux new -s test` 로 세션을 만들고 detach(`Ctrl-b d`) 한 뒤 로그를 보면 `mux=1` 이 뜨지만 `sessions=` 는 늘지 않아야 합니다. `who` 는 이때 1 user 를 보고합니다(정상 — 걸러진 것).
5. 확인되면 `DRY_RUN=false`, `IDLE_MINUTES=30` 으로 되돌리기.

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
./install.sh --with-ssh-keepalive
```
