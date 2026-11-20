# auto-shutdown

EC2 인스턴스가 **일정 시간(기본 30분) 동안 아무도 쓰지 않으면 스스로 종료(stop)**되게 하는 작은 도구입니다. 파이프라인을 쓰고 인스턴스를 끄지 않아 새는 비용을 막습니다.

- **순수 bash + systemd** — 외부 패키지 의존성 0. 어떤 EC2(Ubuntu/Amazon Linux 등)에서도 동작.
- **오탐 방지 우선** — 하트비트·감시 포트·CPU·디스크/네트워크 I/O 중 **하나라도** 활동이 있으면 종료를 미룹니다. CPU가 낮아도 I/O로 돌아가는 NGS 잡·대용량 다운로드는 보호됩니다.
- **유령 세션은 무시** — detached `tmux`/`screen` 은 아무도 접속 안 해도 `who`에 영원히 남아 종료를 막습니다. 이 항목은 걸러냅니다 ([자세히](#동작-방식)).
- **에이전트 상시 SSH 연결도 무시** — Claude Code 같은 pty 없는 SSH 연결은 작업이 없어도 계속 붙어 있습니다. 기본값(`SSH_BLOCKS_SHUTDOWN=false`)은 이걸 종료 근거로 쓰지 않고, 대신 **하트비트 파일**로 실제 활동을 봅니다 ([자세히](#하트비트-활동-기반-보호)).
- **git clone → `sudo ./install.sh`** 한 번으로 다른 인스턴스에도 그대로 적용.
- **`--with-ssh-keepalive` 옵션** — 죽은 SSH 연결이 오래 남아 종료를 막는 문제를 방지 (아래 [설치](#옵션---with-ssh-keepalive-권장) 참고).
- **`--with-global-heartbeat` 옵션** — 계정이 여러 개인 서버에서 모든 사용자의 로그인 셸에 하트비트를 한 번에 적용 (아래 [다중 사용자 서버](#계정이-여러-개인-서버-전역-설치) 참고).

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

기본 sshd 설정은 **죽은 연결(노트북 절전·와이파이 끊김 등)을 약 2시간 동안 ESTABLISHED로 붙들고** 있고, 그 연결의 로그인 세션도 `who` 에 남아 있습니다. 그 동안 "접속 중"으로 오판돼 종료가 안 됩니다. 이 옵션은 sshd에 `ClientAliveInterval 60` / `ClientAliveCountMax 3` 을 설정해 **죽은 연결이 약 3분 내에 자동 정리**되게 만듭니다(기존 연결은 유지, 설정 문법 검증 후 reload). `sshd_config.d/` 를 쓰는 시스템에서는 drop-in 파일로 관리되어 제거도 깔끔합니다.

> 참고: VS Code Remote-SSH나 Claude Code 원격 세션은 창/세션이 열려 있는 한 SSH 연결을 유지합니다. 이 연결 자체는 기본값(`SSH_BLOCKS_SHUTDOWN=false`)에서 종료를 막지 않습니다 — keepalive가 정리해주는 건 죽은 연결에 딸린 **로그인 세션**(`who` 항목)쪽입니다.

> ⚠ **EC2 shutdown behavior 확인 필수**
> 이 도구는 인스턴스 내부에서 `shutdown -h now`를 실행합니다.
> - `stop` (기본값) → 인스턴스 **중지**(EBS 유지, 비용 절감) ✅
> - `terminate` → 인스턴스 **삭제** ❌
>
> 콘솔: EC2 > 인스턴스 > 작업 > 인스턴스 설정 > 종료 동작 변경 → **중지(stop)**
> 설치 스크립트도 마지막에 이 경고를 출력합니다.

### 옵션: `--with-global-heartbeat` (계정이 여러 개면 권장)

```bash
sudo ./install.sh --with-global-heartbeat
```

`/etc/profile.d/auto-shutdown-heartbeat.sh` 를 설치해, **모든 사용자**의 대화형 **로그인** 셸이 프롬프트마다 자기 홈에 하트비트를 남기게 합니다. 계정마다 `~/.bashrc` 를 손댈 필요가 없고, 나중에 추가되는 계정도 자동으로 적용됩니다. 자세한 배경과 적용 범위는 [다중 사용자 서버](#계정이-여러-개인-서버-전역-설치)를 보세요.

`uninstall.sh` 가 이 파일도 함께 제거합니다.

## 동작 방식

매 검사마다 아래 신호 중 **하나라도** 잡히면 "사용 중"으로 보고 "마지막 활동 시각"을 갱신합니다. 마지막 활동으로부터 `IDLE_MINUTES` 이상 지나야만 종료합니다.

| 신호 | 감지 방법 | 종료를 막는가 |
|------|-----------|---------------|
| 감시 포트 (Jupyter 등) | `ss` established, `WATCH_PORTS` | 예 |
| 감시 프로세스 (파이프라인 등) | `pgrep -f`, `WATCH_PROCESSES` | 예 |
| CPU 사용률 | `/proc/stat` 델타 > `CPU_THRESHOLD`% | 예 |
| 디스크 I/O | `/proc/diskstats` 델타 > 임계 | 예 |
| 네트워크 I/O | `/proc/net/dev` 델타 > 임계 | 예 |
| 수동 keepalive | `keepalive` 파일 존재 | 예 |
| 하트비트 | `HEARTBEAT_FILES` mtime < `HEARTBEAT_MAX_AGE_MINUTES` | 예 |
| 로그인 세션 | `who` (**detached tmux/screen 제외**) | **아니오** (기본값 `SESSION_BLOCKS_SHUTDOWN=false`; `true` 면 예) |
| SSH 연결 (VS Code Remote·Claude Code 포함) | `ss` established, 포트 22 | **아니오** (기본값 `SSH_BLOCKS_SHUTDOWN=false`; `true` 면 예) |
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
| 터미널 창만 열어두고 자리를 비움 (`who` 에 잡힘) | 하트비트가 만료되고 CPU/I/O가 낮으면 **꺼짐** |
| 터미널에서 실제로 명령을 치고 있음 | `PROMPT_COMMAND` 하트비트가 신선해서 **안 꺼짐** |
| Claude Code 등 pty 없는 SSH만 붙어 있음 | 하트비트가 만료되고 CPU/I/O가 낮으면 **꺼짐** |
| 그 에이전트가 실제로 작업 중 | 하트비트가 신선해서 **안 꺼짐** |
| detached tmux만 남아 있고 아무도 접속 안 함 | CPU/디스크/네트워크가 낮으면 **꺼짐** |
| detached tmux 안에서 잡이 실제로 돌고 있음 | CPU/디스크/네트워크에 걸려 **안 꺼짐** |

## 하트비트 (활동 기반 보호)

> **CPU만으로는 "쓰고 있는가"를 알 수 없어서 (실제로 겪은 문제)**
> Claude Code 같은 에이전트는 pty를 받지 않는 `sshd: user@notty` 로 접속해서 `who` 에 안 보이고, 작업이 없어도 연결을 끊지 않습니다. 2주치 로그 8281줄 중 **3556줄이 `reason=ssh_conn`** 이었고, 그 사이 idle 타이머는 매분 리셋돼 인스턴스가 영영 안 꺼졌습니다.
>
> ```
> 10:33:22 BUSY reason=ssh_conn(4) cpu=0% disk=0KB/s net=6KB/s sessions=0 mux=0 ssh=4
> ```
>
> 그래서 SSH 연결은 종료 근거에서 빼고(`SSH_BLOCKS_SHUTDOWN=false`), 대신 활동 자체를 신호로 씁니다. 추론은 원격에서 돌고 이 박스는 파일 읽기/grep 만 하므로 CPU는 평상시 0~2% 라, CPU 임계값으로는 작업 중인 에이전트를 지킬 수 없습니다.

`KEEPALIVE_FILE` 은 "있으면 영구 보호"인 수동 스위치입니다. 하트비트는 "최근에 touch 됐으면 보호"로, 끄는 걸 잊어도 TTL이 지나면 자동으로 풀립니다.

```bash
mkdir -p ~/.cache/auto-shutdown && touch ~/.cache/auto-shutdown/heartbeat
```

기본 경로는 `/home/*/.cache/auto-shutdown/heartbeat` (글롭)이고 TTL은 30분입니다. root가 아닌 사용자도 쓸 수 있는 경로이므로 passwordless sudo 없이 훅에서 touch 할 수 있습니다.

> **TTL은 `IDLE_MINUTES` 에 더해집니다.** TTL 안에 있는 동안은 매 검사가 "사용 중"으로 판정해 마지막 활동 시각을 갱신하므로, 마지막 touch 로부터 실제 종료까지는 `HEARTBEAT_MAX_AGE_MINUTES + IDLE_MINUTES` 입니다.
>
> 기본값 `30 + 30 = 약 60분`. Claude의 프롬프트 캐시가 1시간 유지되므로, **그 안에 돌아오면 캐시가 살아 있는 상태로 이어서 작업할 수 있도록** 맞춘 값입니다. `IDLE_MINUTES` 를 바꾸면 이 합도 같이 바뀌니, 1시간을 유지하려면 두 값의 합을 60으로 두세요. 더 빨리 끄려면 TTL을 줄이면 됩니다 — 검사 간격이 1분이라 3~5분으로도 동작합니다.

### 터미널 작업도 하트비트로 (필수, 계정별)

`SESSION_BLOCKS_SHUTDOWN` 의 기본값이 `false` 이므로, **터미널로 접속해 있다는 사실만으로는 종료를 막지 못합니다.** `who` 를 신호로 쓰면 터미널 창을 열어둔 채 자리를 비울 때 영영 안 꺼집니다 — 실측으로 로그 8281줄 중 3216줄이 `reason=login_session` 이었고, **10시간 연속**(`sessions=4`) 안 꺼진 밤이 있었습니다.

대신 아래를 걸면 "창만 열어둔 상태"와 "실제로 쓰는 상태"가 구분됩니다. 명령을 칠 때마다 touch 되고, 마지막 명령으로부터 약 60분 뒤에 꺼집니다.

```bash
# ~/.bashrc
PROMPT_COMMAND="mkdir -p \"\$HOME/.cache/auto-shutdown\" && touch \"\$HOME/.cache/auto-shutdown/heartbeat\"${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
```

(기존 `PROMPT_COMMAND` 가 있으면 뒤에 이어 붙입니다. 없으면 그냥 단독으로 동작합니다.)

### 계정이 여러 개인 서버 (전역 설치)

> ⚠ **계정 하나라도 빠뜨리면 그 사용자의 저부하 작업이 조용히 종료됩니다.**
> `SESSION_BLOCKS_SHUTDOWN=false` 에서 터미널 접속은 보호 근거가 아니므로, 위 `~/.bashrc` 설정이 없는 계정은 `who` 에 보여도 보호되지 않습니다. 실제로 겪은 상황: 한 인스턴스에서 한 계정에만 설정을 걸었는데, 최근 로그인 횟수는 오히려 설정이 없는 다른 계정이 52회 대 26회로 더 많았습니다. 그 계정의 2시간대 터미널 세션은 CPU/IO 가 낮으면 약 60분 뒤에 종료됩니다.
>
> 한동안 사고가 안 나서 더 위험합니다 — `HEARTBEAT_FILES` 글롭이 `/home/*` 에서 **가장 최근 mtime 하나**만 보기 때문에, 설정을 건 사람이 활동하는 동안은 박스 전체가 살아 있습니다. 그 사람이 조용해지는 순간 드러납니다.

설치할 때 옵션 하나로 전체 계정에 적용합니다.

```bash
sudo ./install.sh --with-global-heartbeat
```

`/etc/profile.d/auto-shutdown-heartbeat.sh` 가 깔리고, 모든 사용자의 대화형 로그인 셸이 프롬프트마다 자기 홈(`~/.cache/auto-shutdown/heartbeat`)에 touch 합니다. 나중에 추가되는 계정도 자동으로 커버됩니다.

- 계정별 `~/.bashrc` 설정과 **같이 둬도 안전합니다.** 마커(`__auto_shutdown_hb`)를 공유하고 로그인 셸이 `/etc/profile` → `~/.bashrc` 순서로 읽으므로, `PROMPT_COMMAND` 에 중복으로 들어가지 않습니다.
- 대화형이 아닐 때는 아무것도 하지 않습니다. `profile.d` 는 `sh` 로도 읽히므로 `case "$-" in *i*)` 로 감쌌습니다.
- **이미 열려 있는 셸에는 적용되지 않습니다.** 재접속하거나 `source /etc/profile.d/auto-shutdown-heartbeat.sh` 하세요.
- **비로그인 대화형 셸은 적용되지 않습니다.** `/etc/profile` 은 로그인 셸만 읽습니다. SSH 접속(`sshd` 가 띄우는 셸)은 로그인 셸이라 괜찮지만, 그 안에서 다시 띄운 `bash`, `screen` 윈도우 등은 커버되지 않습니다. VS Code 통합 터미널은 설정에 따라 다릅니다. 그런 셸까지 확실히 하려면 계정별 `~/.bashrc` 설정을 함께 두세요 — 마커가 같아서 중복되지 않습니다.
- 홈 디렉터리 권한이 `700` 이어도 괜찮습니다 — 검사 스크립트는 `User=root` 로 돌아 다른 계정의 하트비트를 읽습니다.

확인:

```bash
# 새 세션을 하나 열고
echo "$PROMPT_COMMAND"              # __auto_shutdown_hb 가 보여야 함
ls -la ~/.cache/auto-shutdown/      # heartbeat 파일 mtime 확인
```

> 비대화형 셸(`ssh host 'cmd'`, 스크립트, **Claude Code 의 Bash 툴**)은 프롬프트를 그리지 않으므로 이 경로로 보호되지 않습니다. 에이전트 작업은 아래 훅이 담당합니다.

### Claude Code 훅으로 자동 touch

`~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "async": true,
        "command": "mkdir -p \"$HOME/.cache/auto-shutdown\" && touch \"$HOME/.cache/auto-shutdown/heartbeat\"" }] }
    ],
    "PostToolUse": [
      { "hooks": [{ "type": "command", "async": true,
        "command": "mkdir -p \"$HOME/.cache/auto-shutdown\" && touch \"$HOME/.cache/auto-shutdown/heartbeat\"" }] }
    ],
    "SessionStart": [
      { "hooks": [{ "type": "command", "async": true,
        "command": "mkdir -p \"$HOME/.cache/auto-shutdown\" && touch \"$HOME/.cache/auto-shutdown/heartbeat\"" }] }
    ]
  }
}
```

`PostToolUse` 가 있어야 프롬프트 한 번으로 오래 도는 에이전트 실행도 보호됩니다. `async: true` 라 턴을 지연시키지 않습니다.

> 로그의 `hb=` 필드로 상태를 볼 수 있습니다: `hb=-` 는 하트비트 파일 없음, `hb=3m` 은 3분 전 touch.

> RAM은 종료 판단에 쓰지 않습니다. 유휴 상태에서도 캐시/상주 프로세스로 높게 유지되어 영영 종료가 안 되는 문제를 막기 위함입니다.

> ⚠ CPU는 코어 전체 평균입니다(8 vCPU에서 1코어 20% 사용 = 전체 2.5%). 대용량 다운로드처럼 CPU는 거의 안 쓰고 네트워크/디스크만 쓰는 작업은 `CPU_THRESHOLD`로 못 잡습니다 — 이런 작업은 `NET_IO_THRESHOLD_KBPS`/`DISK_IO_THRESHOLD_KBPS`가 지켜주므로 값을 너무 높게 잡지 마세요. 반대로 CPU를 거의 안 쓰는 사람의 작업(로그 읽기, 코드 리뷰 등)은 이 도구 입장에서 유휴와 구분이 안 되니, [하트비트](#하트비트-활동-기반-보호)를 걸거나 오래 그렇게 있을 예정이면 `touch keepalive`로 수동 보호하세요.

## 설정

설정 파일: `/etc/auto-shutdown/config.env` (값 변경 시 다음 검사부터 자동 반영)

| 항목 | 기본값 | 설명 |
|------|--------|------|
| `ENABLED` | `true` | `false`면 감지·로그만 남기고 종료 안 함(관찰 모드) |
| `IDLE_MINUTES` | `30` | 이 시간 동안 계속 유휴면 종료 |
| `CPU_THRESHOLD` | `5` | CPU 사용률(%) 이하를 유휴로 간주 |
| `WATCH_PORTS` | `"8888"` | 공백 구분. 비우면 포트 검사 안 함 |
| `WATCH_PROCESSES` | `""` | **줄 단위**로 `pgrep -f` 패턴을 적음. 매칭되는 프로세스가 있으면 종료 안 함. 비우면 검사 안 함 |
| `WATCH_PROCESS_MAX_HOURS` | `3` | 감시 프로세스가 이 시간보다 오래 돌았으면 예외에서 뺌. `0`이면 상한 없음 |
| `CHECK_DISK_IO` / `DISK_IO_THRESHOLD_KBPS` | `true` / `200` | 디스크 I/O 감지 |
| `CHECK_NET_IO` / `NET_IO_THRESHOLD_KBPS` | `true` / `200` | 네트워크 I/O 감지 |
| `SESSION_BLOCKS_SHUTDOWN` | `false` | `true` 면 `who` 에 로그인 세션이 있으면 CPU가 낮아도 종료 안 함. 창만 열어둔 채 자리를 비우면 안 꺼지므로 기본값은 `false` 이고, 터미널 작업은 하트비트로 보호 |
| `SSH_BLOCKS_SHUTDOWN` | `false` | pty 없는 SSH 연결(포트 22)만으로 종료를 막을지. `true` 면 Claude Code 연결이 있는 동안 영영 안 꺼짐 |
| `HEARTBEAT_FILES` | `"/home/*/.cache/auto-shutdown/heartbeat"` | 하트비트 파일 목록(공백 구분, 글롭 가능). 가장 최근 mtime 하나만 봄 |
| `HEARTBEAT_MAX_AGE_MINUTES` | `30` | 하트비트 유효 시간(분). `IDLE_MINUTES` 에 더해짐(30+30=약 60분). `0` 이면 하트비트 검사 끔 |
| `DRY_RUN` | `false` | `true`면 실제 종료 대신 로그만 |

### 프로세스 예외 (`WATCH_PROCESSES`)

다른 인스턴스의 작업이 끝나길 기다리는 파이프라인처럼, **오래 돌지만 대기 구간엔 CPU/I/O를 거의 안 쓰는** 작업은 detached tmux 안에서 돌리면 유휴로 판정되어 꺼집니다. 이런 작업은 명령줄 패턴을 등록해 보호합니다.

```bash
# /etc/auto-shutdown/config.env
WATCH_PROCESSES="
ATG_PIP-seq_QC/src/main.py
other_pipeline/run.sh
"
```

- 한 줄에 패턴 하나(`pgrep -f` 확장 정규식, 공백 포함 가능). 빈 줄과 `#` 주석 줄은 무시합니다.
- 매칭되면 로그에 `BUSY reason=process:<패턴>(pid=...)` 로 남습니다.
- 패턴은 경로까지 넣어 **좁게** 쓰세요. `main.py` 만 쓰면 무관한 프로세스까지 잡힙니다. 등록 전에 `pgrep -af '<패턴>'` 으로 무엇이 잡히는지 확인하세요.
- 명령줄 전체를 보므로 `vim .../main.py` 처럼 파일을 열어두기만 해도 매칭됩니다.
- 멈춘 작업이 인스턴스를 무한정 켜두지 않도록 `WATCH_PROCESS_MAX_HOURS`(기본 `3`)보다 오래 실행된 프로세스는 예외에서 뺍니다. 실행 시간은 `ps etimes`(대기 시간 포함)로 재고, 초과하면 로그에 `WARN process:... 초과 → 예외 해제`가 남습니다. 그 뒤엔 CPU/I/O로만 판단하므로 **3시간 넘게 걸리는 파이프라인이면 값을 늘리세요**(`0` = 상한 없음).

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
| `ssh=` | 포트 22 established 연결 수. pty 없는 접속(VS Code·Claude Code)은 `who`에 안 잡히므로 이 필드로만 보입니다. 기본값에서는 **종료를 막지 않고 진단용으로만** 기록됩니다 |
| `hb=` | 하트비트 나이. `-` 는 파일 없음, `3m` 은 3분 전 touch |

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
3. Jupyter 포트 연결 / CPU 부하(`yes >/dev/null &`) / `touch keepalive` 를 각각 걸어보고 → `BUSY reason=...` 로 타이머가 리셋되는지 확인. (터미널 접속 자체는 기본값에서 타이머를 리셋하지 않습니다 — 아래 하트비트가 그 역할입니다.)
4. **하트비트 확인** — `touch ~/.cache/auto-shutdown/heartbeat` 후 `BUSY reason=heartbeat(0m<30m)` 이 찍히는지, `touch -d "40 minutes ago"` 로 만료시키면 다시 `IDLE` 로 돌아가는지 확인.
5. **tmux 필터 확인** — `tmux new -s test` 로 세션을 만들고 detach(`Ctrl-b d`) 한 뒤 로그를 보면 `mux=1` 이 뜨지만 `sessions=` 는 늘지 않아야 합니다. `who` 는 이때 1 user 를 보고합니다(정상 — 걸러진 것).
6. 확인되면 `DRY_RUN=false`, `IDLE_MINUTES=30` 으로 되돌리기.

## 기존 설치 업그레이드

`install.sh` 는 이미 있는 `/etc/auto-shutdown/config.env` 를 **덮어쓰지 않습니다.** 두 가지를 직접 챙겨야 합니다.

**새 항목은 안 생깁니다.** 재설치만 하면 `SSH_BLOCKS_SHUTDOWN`, `HEARTBEAT_*` 가 설정 파일에 없습니다 — 스크립트 내장 기본값이 적용되므로 동작은 바뀌지만, 파일을 보고 설정을 확인할 수는 없습니다. 주석과 함께 명시하려면 새 `config.env` 의 해당 블록을 직접 복사해 넣으세요.

**바뀐 기본값은 적용되지 않습니다.** `SESSION_BLOCKS_SHUTDOWN` 의 기본값이 `true` → `false` 로 바뀌었지만, 기존 설정 파일에 `=true` 가 적혀 있으면 그 값이 계속 이깁니다. 바꾸려면:

```bash
sudo sed -i 's/^SESSION_BLOCKS_SHUTDOWN=.*/SESSION_BLOCKS_SHUTDOWN=false/' /etc/auto-shutdown/config.env
```

재시작은 필요 없습니다(다음 검사부터 반영). **먼저 하트비트를 걸어두세요** — 이걸 바꾸면 터미널 접속만으로는 더 이상 보호되지 않습니다. 계정이 여러 개면 `~/.bashrc` 를 계정마다 손대는 대신 전역 설치가 안전합니다:

```bash
sudo ./install.sh --with-global-heartbeat
```

기존 설치에 이 옵션만 추가로 적용해도 됩니다(스크립트/유닛은 다시 깔리고 `config.env` 는 그대로 보존됩니다).

## 제거

```bash
sudo ./uninstall.sh            # 서비스만 제거(설정·로그 보존)
sudo ./uninstall.sh --purge    # 설정·상태·로그까지 전부 삭제
```

`--with-global-heartbeat` 로 깔린 `/etc/profile.d/auto-shutdown-heartbeat.sh` 와 `--with-ssh-keepalive` drop-in 은 둘 다 함께 제거됩니다. 계정별로 직접 넣은 `~/.bashrc` 설정과 `~/.cache/auto-shutdown` 은 건드리지 않으므로 필요하면 수동으로 지우세요.

## EC2 user-data 로 자동 설치(선택)

새 인스턴스 생성 시 user-data 에 넣으면 부팅과 동시에 설치됩니다.

```bash
#!/bin/bash
cd /opt
git clone https://github.com/YushinJung/auto-shutdown.git
cd auto-shutdown
./install.sh --with-ssh-keepalive --with-global-heartbeat
```

(계정이 하나뿐이면 `--with-global-heartbeat` 는 생략해도 됩니다. 단 그 계정의 `~/.bashrc` 나 에이전트 훅 중 하나는 반드시 하트비트를 남겨야 합니다.)
