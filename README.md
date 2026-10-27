# B4-2 시스템 장애 분석: OOM · CPU · Deadlock

`agent-leak-app`을 리눅스(WSL2 Ubuntu)에서 실행하며 세 가지 장애를 재현하고, 관제 데이터와 로그를 근거로 원인을 분석한 GitHub Issue 형식 리포트입니다.

## 리포트

| 장애 | 리포트 | 한 줄 요약 |
|---|---|---|
| OOM | [01_OOM.md](reports/01_OOM.md) | 메모리 누수로 256MB 도달 시 MemoryGuard가 SIGKILL로 자가 종료 → 512MB로 올리자 캐시 정리 후 생존 |
| CPU | [02_CPU.md](reports/02_CPU.md) | 앱 부하가 50%를 넘자 Watchdog이 SIGTERM으로 종료 → 한도 50%로 맞추자 cooldown으로 생존 |
| Deadlock | [03_Deadlock.md](reports/03_Deadlock.md) | 두 워커 스레드가 서로의 락을 쥔 채 대기 → 싱글 스레드로 바꾸자 정상 동작 |

## 결과 요약 (Before & After)

| 장애 | 환경변수 | Before | After |
|---|---|---|---|
| OOM | `MEMORY_LIMIT` 256 → 512 | 약 28~33초 후 종료 (exit 137, SIGKILL) | 캐시 정리 후 계속 실행 |
| CPU | `CPU_MAX_OCCUPY` 80 → 50 | 약 27~52초 후 종료 (exit 143, SIGTERM) | 50%에서 cooldown, 계속 실행 |
| Deadlock | `MULTI_THREAD_ENABLE` true → false | 약 9초 후 로그 정지, PID 유지, 전 스레드 `futex_do_wait` | 로그 계속 출력 |

## 실행 환경

- Windows + WSL2 Ubuntu, x86 바이너리 `agent-leak-app-x86`
- 일반 사용자 계정(uid=1000)으로 실행
- 10/21: 직접 실행하며 수동 관찰 (스크린샷)
- 10/23: [scripts/](scripts/)의 자동화 스크립트로 6회(장애별 Before/After) 재현 (로그)

## 폴더 구성

```
reports/   장애별 리포트 3건
images/    10/21 수동 실행 스크린샷
logs/      10/23 자동 재현 로그 (실행별 폴더)
  ├─ app.log               프로그램 실행 로그
  ├─ applog/agent_app.log  앱이 AGENT_LOG_DIR에 남긴 로그
  ├─ monitor.log           monitor.sh 관제 로그
  ├─ ps_samples.txt        10초마다 ps
  ├─ top_system.txt        10초마다 시스템 전체 top
  ├─ key_lines.txt         핵심 로그 줄
  ├─ result.env            결과, 종료 코드, 생존 시간, 최대 RSS/CPU
  └─ deadlock_evidence.txt (deadlock_before만) ps -L, top -H, 스레드별 wchan
scripts/   관제·재현 자동화 스크립트 (사용법은 scripts/README.md)
```

실행 파일(`agent-leak-app-*`)과 제공 zip은 저장소에 포함하지 않았습니다.
