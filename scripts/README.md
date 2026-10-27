# agent-leak-app 장애 분석 자동화

OOM / CPU Spike / Deadlock 을 각각 Before·After 로 실행하고, 증거를 모아 GitHub Issue 형식 리포트 초안까지 만듭니다.

## 파일
| 파일 | 역할 |
|---|---|
| `env.sh` | 환경변수 + `upload_files`, `api_keys/secret.key`, 로그 디렉터리 준비 |
| `monitor.sh` | 관제 로그 (CPU/MEM/RSS/스레드/디스크/방화벽) |
| `run_case.sh` | 1회 실행 → 종료/생존/무응답 판정 + 증거 수집 (`runs/<케이스>/`) |
| `run_all.sh` | 6회 실행 후 리포트 생성 |
| `make_report.sh` | `reports/01_OOM.md`, `02_CPU.md`, `03_DEADLOCK.md` 생성 |
| `analyze_schedule.sh` | (보너스) 로그로 스케줄링 패턴 분석 |

## 1. 준비
`agent-app-leak.zip` 을 이 폴더에 풀어 둡니다 (스크립트가 `agent*x86*` / `agent*arm64*` 를 자동으로 찾음).

### Linux 라면 바로
```bash
cd agent-mission
sed -i 's/\r$//' *.sh && chmod +x *.sh
```

### Mac / Windows 라면 Docker 로
```bash
docker run -it --name agent-lab -v "$PWD":/work -w /work ubuntu:22.04 bash
```
컨테이너 안에서:
```bash
apt update && apt install -y procps iproute2 psmisc
useradd -m agent && chown -R agent /work
su agent
cd /work && sed -i 's/\r$//' *.sh && chmod +x *.sh
```
(root 로 실행하면 앱이 부트 단계에서 실패하므로 반드시 일반 사용자로 실행)

## 2. 실행
```bash
./run_all.sh
```
- 일부만: `./run_all.sh oom` / `./run_all.sh cpu deadlock`
- 단일 실행: `./run_case.sh test1 MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=true`
- 관제만 따로: `./monitor.sh agent-leak-app 2 monitor.log`

기본 설정 (리포트 기준):

| 케이스 | Before | After | 고정값 |
|---|---|---|---|
| OOM | `MEMORY_LIMIT=256` | `MEMORY_LIMIT=512` | CPU_MAX_OCCUPY=50, MULTI_THREAD_ENABLE=false |
| CPU | `CPU_MAX_OCCUPY=80` | `CPU_MAX_OCCUPY=50` | MEMORY_LIMIT=512, MULTI_THREAD_ENABLE=false |
| Deadlock | `MULTI_THREAD_ENABLE=true` | `MULTI_THREAD_ENABLE=false` | MEMORY_LIMIT=512, CPU_MAX_OCCUPY=50 |

| 변수 | 기본 | 의미 |
|---|---|---|
| `MAX_RUN` | 120 | 최대 관찰 시간(초). 넘으면 "생존" 처리 후 종료 (After 실행용) |
| `STALL_SEC` | 30 | 로그가 이 시간 동안 안 늘면 무응답(데드락) 판정 |
| `OOM_BEFORE_LIMIT` 등 | 위 표 | 값을 바꾸고 싶을 때만 (`CPU_BEFORE_MAX`, `CPU_AFTER_MAX`, `OOM_AFTER_LIMIT`) |

종료 코드가 128보다 크면 시그널 종료로 기록합니다 (예: CPU Before 의 `143 (SIGTERM)`).

## 3. 결과
```
runs/<케이스>/
  app.log              프로그램 표준출력/에러
  applog/              AGENT_LOG_DIR 로 남은 앱 로그
  monitor.log          관제 로그
  top_system.txt       10초마다 시스템 전체 top
  ps_samples.txt       10초마다 ps
  deadlock_evidence.txt  무응답 시: ps -ef, ps -L, top -H, 스레드 wchan(futex)
  key_lines.txt        MemoryGuard / WATCHDOG / WAITING 등 핵심 로그
  result.env           결과·생존 시간·최대 RSS/CPU
reports/*.md           GitHub Issue 에 붙여넣을 리포트 초안
```

## 4. 제출 전 할 일
- 리포트의 **원인 분석 문장은 초안**입니다. 실제 로그 문구(예: 어떤 자원을 WAITING 했는지)를 보고 고쳐 쓰세요.
- 스크린샷이 필요하면 실행 중 다른 터미널에서 `top -p $(pgrep -f agent-app-leak | tail -1)` 또는 `htop` 을 캡처하세요.
- 보너스: `./analyze_schedule.sh runs/deadlock_after/app.log`
