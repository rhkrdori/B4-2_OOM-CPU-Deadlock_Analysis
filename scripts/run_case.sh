#!/usr/bin/env bash
# 한 번의 실행(케이스)을 돌리고 증거를 runs/<케이스이름>/ 에 모은다.
# 사용법: ./run_case.sh <케이스이름> [KEY=VALUE ...]
#   예)   ./run_case.sh oom_before MEMORY_LIMIT=64 CPU_MAX_OCCUPY=100 MULTI_THREAD_ENABLE=false
#
# 조절 가능한 값(환경변수):
#   MAX_RUN    최대 관찰 시간(초). 넘으면 "생존"으로 기록하고 종료시킴 (기본 600)
#   STALL_SEC  로그가 이 시간(초) 동안 안 늘면 무응답(데드락 의심)으로 판단 (기본 60)
#   INTERVAL   monitor.sh 기록 주기(초) (기본 2)

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

CASE=${1:?"사용법: $0 <case-name> [KEY=VALUE ...]"}; shift
for kv in "$@"; do export "$kv"; done

MAX_RUN=${MAX_RUN:-600}
STALL_SEC=${STALL_SEC:-60}
INTERVAL=${INTERVAL:-2}

OUT="$SCRIPT_DIR/runs/$CASE"
rm -rf "$OUT"; mkdir -p "$OUT/applog"
export AGENT_LOG_DIR="$OUT/applog"   # 실행마다 앱 로그를 분리해서 보관
source "$SCRIPT_DIR/env.sh"

# ---- 사전 점검 ----
if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: root 로 실행하면 앱이 부트 단계에서 실패합니다. 일반 사용자로 실행하세요." >&2
  exit 1
fi
APP_BIN=$(find_bin) || exit 1
if port_in_use "$AGENT_PORT"; then
  echo "포트 $AGENT_PORT 사용 중 → 해제 대기..."
  wait_port_free "$AGENT_PORT" || exit 1
fi

env | grep -E '^(AGENT_|MEMORY_LIMIT|CPU_MAX_OCCUPY|MULTI_THREAD_ENABLE)' | sort > "$OUT/env.txt"
echo "APP_BIN=$APP_BIN" >> "$OUT/env.txt"

echo "================================================================"
echo "[$(ts)] CASE=$CASE  MEMORY_LIMIT=$MEMORY_LIMIT CPU_MAX_OCCUPY=$CPU_MAX_OCCUPY MULTI_THREAD_ENABLE=$MULTI_THREAD_ENABLE"
echo "         MAX_RUN=${MAX_RUN}s STALL_SEC=${STALL_SEC}s  → 결과: runs/$CASE/"

log_bytes() {
  find "$OUT/app.log" "$OUT/applog" -type f -exec cat {} + 2>/dev/null | wc -c
}

# ---- 실행 ----
START_EPOCH=$(date +%s); START_TS=$(ts)
"$APP_BIN" > "$OUT/app.log" 2>&1 < /dev/null &
ROOT=$!
sleep 1
"$SCRIPT_DIR/monitor.sh" "$ROOT" "$INTERVAL" "$OUT/monitor.log" > /dev/null &
MON=$!

RESULT=""
last_size=-1; last_change=$(date +%s); last_snap=0
while kill -0 "$ROOT" 2>/dev/null; do
  now=$(date +%s); elapsed=$(( now - START_EPOCH ))
  TPID=$(target_pid "$ROOT")

  # 10초마다 시스템 전체 top / 프로세스 ps 스냅샷 (특정 프로세스만 튀는지 확인용)
  if [ $(( now - last_snap )) -ge 10 ]; then
    last_snap=$now
    { echo "===== $(ts) (+${elapsed}s)"; top -b -n 1 2>/dev/null | head -n 15; } >> "$OUT/top_system.txt"
    { echo "===== $(ts) (+${elapsed}s)"; ps -o pid,ppid,stat,%cpu,%mem,rss,nlwp,etime,cmd -p "$ROOT" $(descendants "$ROOT") 2>/dev/null; } >> "$OUT/ps_samples.txt"
  fi

  size=$(log_bytes)
  if [ "$size" != "$last_size" ]; then last_size=$size; last_change=$now; fi

  if [ $(( now - last_change )) -ge "$STALL_SEC" ]; then
    RESULT="STALLED"
    echo "[$(ts)] 로그가 ${STALL_SEC}초간 멈춤 + PID $TPID 생존 → 무응답 증거 수집"
    {
      echo "### ps -ef | grep agent"
      ps -ef | grep -i agent | grep -v grep
      echo
      for i in 1 2 3; do
        echo "### [$i/3] $(ts)  ps -L (스레드별 상태)"
        ps -L -o pid,lwp,stat,%cpu,%mem,rss,wchan:24,comm -p "$TPID"
        echo
        echo "### [$i/3] $(ts)  top -H"
        top -H -b -n 1 -p "$TPID" 2>/dev/null | head -n 20
        echo
        sleep 5
      done
      echo "### /proc/$TPID/status"
      grep -E '^(Name|State|Threads|VmRSS|voluntary_ctxt_switches|nonvoluntary_ctxt_switches)' "/proc/$TPID/status"
      echo
      echo "### 스레드별 커널 대기 지점 (wchan: futex_* 이면 락 대기)"
      for t in /proc/"$TPID"/task/*; do
        printf '%s  state=%s  wchan=%s\n' "$(basename "$t")" \
          "$(awk '/^State/{print $2,$3}' "$t/status" 2>/dev/null)" "$(cat "$t/wchan" 2>/dev/null)"
      done
      echo
      echo "### 로그 마지막 30줄"
      tail -n 30 "$OUT/app.log"
    } > "$OUT/deadlock_evidence.txt" 2>&1
    break
  fi

  if [ "$elapsed" -ge "$MAX_RUN" ]; then
    RESULT="SURVIVED"
    echo "[$(ts)] ${MAX_RUN}초 동안 생존 → 관찰 종료"
    break
  fi
  sleep 1
done

EXIT_CODE=""
if [ -z "$RESULT" ]; then
  wait "$ROOT"; EXIT_CODE=$?
  RESULT="EXITED"
else
  # 관찰 끝 → 직접 종료 (TERM 후 안 죽으면 KILL)
  kill_tree "$ROOT" TERM; sleep 3; kill_tree "$ROOT" KILL
  wait "$ROOT" 2>/dev/null
fi
# 종료 코드가 128 보다 크면 시그널로 종료된 것 (예: 143 = 128 + 15 = SIGTERM)
SIGNAL=""
if [ -n "$EXIT_CODE" ] && [ "$EXIT_CODE" -gt 128 ]; then
  SIGNAL="SIG$(kill -l $(( EXIT_CODE - 128 )) 2>/dev/null)"
fi
END_EPOCH=$(date +%s); END_TS=$(ts)
DURATION=$(( END_EPOCH - START_EPOCH ))
sleep "$INTERVAL"; kill "$MON" 2>/dev/null; wait "$MON" 2>/dev/null

# ---- 핵심 로그 추출 ----
grep -n -i -E 'MemoryGuard|SELF-TERMINAT|limit exceeded|Cache Flushed|MEMORY RECOVERED|Threshold Violated|Peak reached|cooldown|WATCHDOG|SIGTERM|SIGKILL|ABORT|WAITING|BLOCKED|deadlock|lock|CRITICAL|FATAL|ERROR|Traceback' \
  "$OUT/app.log" "$OUT"/applog/* 2>/dev/null > "$OUT/key_lines.txt"

PEAK_RSS=$(grep -o 'RSS:[0-9]*' "$OUT/monitor.log" 2>/dev/null | cut -d: -f2 | sort -n | tail -n 1)
PEAK_CPU=$(grep -o 'CPU:[0-9.]*' "$OUT/monitor.log" 2>/dev/null | cut -d: -f2 | sort -n | tail -n 1)
PEAK_MEM=$(grep -o 'MEM:[0-9.]*' "$OUT/monitor.log" 2>/dev/null | cut -d: -f2 | sort -n | tail -n 1)

cat > "$OUT/result.env" <<EOF
CASE='$CASE'
RESULT='$RESULT'
EXIT_CODE='$EXIT_CODE'
SIGNAL='$SIGNAL'
START_TS='$START_TS'
END_TS='$END_TS'
DURATION=$DURATION
MAX_RUN=$MAX_RUN
MEMORY_LIMIT='$MEMORY_LIMIT'
CPU_MAX_OCCUPY='$CPU_MAX_OCCUPY'
MULTI_THREAD_ENABLE='$MULTI_THREAD_ENABLE'
PEAK_RSS_MB='${PEAK_RSS:-0}'
PEAK_CPU='${PEAK_CPU:-0}'
PEAK_MEM='${PEAK_MEM:-0}'
EOF

echo "[$(ts)] 결과: $RESULT  exit=${EXIT_CODE:--}${SIGNAL:+($SIGNAL)}  생존 ${DURATION}s  최대RSS ${PEAK_RSS:-?}MB  최대CPU ${PEAK_CPU:-?}%"
wait_port_free "$AGENT_PORT" >/dev/null 2>&1
