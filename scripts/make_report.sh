#!/usr/bin/env bash
# runs/ 에 모인 증거로 GitHub Issue 형식 리포트 초안(reports/*.md)을 만든다.
# 수치·로그는 자동으로 채워지고, 원인 분석 문장은 초안이므로 실제 로그를 보고 다듬어야 한다.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNS="${RUNS:-$SCRIPT_DIR/runs}"
REP="${REP:-$SCRIPT_DIR/reports}"
mkdir -p "$REP"

v() { # v <case> <KEY>
  [ -f "$RUNS/$1/result.env" ] || { echo "N/A"; return; }
  ( source "$RUNS/$1/result.env"; eval "echo \${$2}" )
}

# monitor.log 를 최대 N줄로 고르게 샘플링 (처음/끝 포함)
monitor_excerpt() {
  local f="$RUNS/$1/monitor.log" n=${2:-12}
  [ -f "$f" ] || { echo "(monitor.log 없음)"; return; }
  awk -v n="$n" '{a[NR]=$0} END{
    if(NR<=n){for(i=1;i<=NR;i++)print a[i]; exit}
    step=(NR-1)/(n-1); last=0
    for(k=0;k<n;k++){i=int(1+k*step+0.5); if(i!=last){print a[i]; last=i}}
  }' "$f"
}

# RSS 또는 CPU 를 텍스트 막대그래프로
bar_graph() { # bar_graph <case> RSS|CPU
  local f="$RUNS/$1/monitor.log" key=$2
  [ -f "$f" ] || return
  grep -E "$key:[0-9]" "$f" | awk -v k="$key" '
    { match($0, k":[0-9.]+"); val=substr($0,RSTART+length(k)+1,RLENGTH-length(k)-1)+0
      t=substr($2,1,8); v[NR]=val; tm[NR]=t; if(val>mx)mx=val }
    END{ if(mx==0)mx=1; step=(NR>20)?int(NR/20):1
      for(i=1;i<=NR;i+=step){ w=int(v[i]/mx*40); s=""; for(j=0;j<w;j++)s=s"#";
        printf "%s %8.1f %s\n", tm[i], v[i], s } }'
}

key_lines() { # key_lines <case> <regex> [n]
  # app.log(화면 출력)과 applog/agent_app.log 는 같은 내용이라 하나만 본다 (중복 방지)
  local n=${3:-15} f="$RUNS/$1/app.log"
  [ -s "$f" ] || f=$(ls "$RUNS/$1"/applog/* 2>/dev/null | head -n 1)
  grep -h -i -E "$2" "$f" 2>/dev/null | tail -n "$n"
}

last_lines() { tail -n "${2:-10}" "$RUNS/$1/app.log" 2>/dev/null; }

top_snapshot() { # 가장 CPU 가 높았던 시점 근처의 top 스냅샷 하나
  local f="$RUNS/$1/top_system.txt"
  [ -f "$f" ] || { echo "(top 스냅샷 없음)"; return; }
  # printf 안에서 > 를 쓰면 awk 가 파일 출력으로 해석하므로 인덱스를 먼저 계산
  awk '/^=====/{n++} {blk[n]=blk[n]$0"\n"} END{k=n; if(n>1)k=n-1; printf "%s", blk[k]}' "$f"
}

# 로그의 LOCK ACQUIRED / WAITING for 줄에서 스레드별 보유·대기 락 표 만들기
lock_table() {
  local f="$RUNS/$1/app.log"
  [ -s "$f" ] || f=$(ls "$RUNS/$1"/applog/* 2>/dev/null | head -n 1)
  awk '
    function thread(   s, t) { s=$0; t=""
      while (match(s, /\[[A-Za-z]+-Thread-[0-9]+\]/)) { t=substr(s,RSTART+1,RLENGTH-2); s=substr(s,RSTART+RLENGTH) }
      return t }
    function res(   s) { if (match($0, /: \[[^]]+\]|for \[[^]]+\]/)) { s=substr($0,RSTART,RLENGTH); sub(/^[^[]*\[/,"",s); sub(/\]$/,"",s); return s } return "" }
    /LOCK ACQUIRED/ { t=thread(); if(t!=""){ if(!(t in seen)){order[++n]=t; seen[t]=1}; hold[t]=res() } }
    /WAITING for/   { t=thread(); if(t!=""){ if(!(t in seen)){order[++n]=t; seen[t]=1}; wait[t]=res() } }
    END { for(i=1;i<=n;i++){ t=order[i]; printf "| %s | `%s` | `%s` |\n", t, hold[t], wait[t] } }
  ' "$f" 2>/dev/null
}

exit_desc() { # 종료 코드 + 시그널 (예: 143 (SIGTERM))
  local c s; c=$(v "$1" EXIT_CODE); s=$(v "$1" SIGNAL)
  [ -z "$c" ] && { echo "-"; return; }
  if [ -n "$s" ]; then echo "$c ($s)"; else echo "$c"; fi
}

result_row() { # | case | env | 결과 | 종료코드 | 생존시간 | 최대RSS | 최대CPU |
  printf '| %s | MEMORY_LIMIT=%s, CPU_MAX_OCCUPY=%s, MULTI_THREAD_ENABLE=%s | %s | %s | %ss | %sMB | %s%% |\n' \
    "$1" "$(v "$1" MEMORY_LIMIT)" "$(v "$1" CPU_MAX_OCCUPY)" "$(v "$1" MULTI_THREAD_ENABLE)" \
    "$(v "$1" RESULT)" "$(exit_desc "$1")" "$(v "$1" DURATION)" "$(v "$1" PEAK_RSS_MB)" "$(v "$1" PEAK_CPU)"
}

TABLE_HEAD='| 실행 | 설정 | 결과 | 종료 코드 | 생존 시간 | 최대 RSS | 최대 CPU(OS 측정) |
|---|---|---|---|---|---|---|'
RESULT_NOTE='> 결과: `EXITED`=프로세스가 스스로 종료 / `SURVIVED`=최대 관찰 시간(MAX_RUN) 동안 생존 / `STALLED`=PID 는 살아있지만 로그가 멈춤'

# ------------------------------------------------------------------ OOM
if [ -d "$RUNS/oom_before" ]; then
cat > "$REP/01_OOM.md" <<EOF
# [Bug] OOM - 메모리 누수로 MEMORY_LIMIT($(v oom_before MEMORY_LIMIT)MB) 도달 시 MemoryGuard 가 프로세스 강제 종료

## 1. Description (현상 설명)
- \`agent-leak-app\` 을 \`MEMORY_LIMIT=$(v oom_before MEMORY_LIMIT)\` 로 실행하면 약 **$(v oom_before DURATION)초** 뒤 프로세스가 예고 없이 종료됨.
- 실행 시각: $(v oom_before START_TS) ~ $(v oom_before END_TS)
- 종료 직전까지 CPU 는 낮게 유지되고, 물리 메모리(RSS)만 시간에 따라 계속 증가함.

## 2. Evidence & Logs (증거 자료)
### monitor.sh 관제 로그 (발췌)
\`\`\`
$(monitor_excerpt oom_before 12)
\`\`\`

### RSS(MB) 추이
\`\`\`
$(bar_graph oom_before RSS)
\`\`\`

### 종료 직전/직후 실행 로그
\`\`\`
$(key_lines oom_before 'MemoryGuard|SELF-TERMINAT|limit exceeded|CRITICAL' 10)
\`\`\`

### ps 스냅샷 (종료 직전)
\`\`\`
$(tail -n 4 "$RUNS/oom_before/ps_samples.txt" 2>/dev/null)
\`\`\`

## 3. Root Cause Analysis (원인 분석)
- 관제 로그에서 RSS 가 $(head -n 1 "$RUNS/oom_before/monitor.log" 2>/dev/null | grep -o 'RSS:[0-9]*MB') → 최대 **$(v oom_before PEAK_RSS_MB)MB** 로 꾸준히 증가했고, 줄어드는 구간이 없음 → 할당한 객체가 해제되지 않는 **메모리 누수**.
- 프로세스의 힙(Heap) 영역은 malloc/객체 생성으로 커지며, 참조가 남아있는 객체는 GC 가 회수하지 못함. 실제 사용 중인 페이지가 늘어날수록 RSS(물리 메모리 점유)가 증가함.
- 앱 내부 MemoryGuard 가 사용량이 MEMORY_LIMIT 이상이 되는 순간 시스템 전체 불안정(커널 OOM Killer 발동, 스왑으로 인한 전체 지연)을 막기 위해 스스로 종료함 → 로그의 \`Memory limit exceeded\` / \`Self-terminating process\` 가 근거.
- 종료 코드 **$(exit_desc oom_before)**: 128 + 9 = SIGKILL. 정리 작업 없이 즉시 끝나는 시그널로 스스로를 종료한 것 (OS 측 증거).
- 즉, 크래시(버그로 인한 예외)가 아니라 **누수 → 임계치 도달 → 보호 정책에 의한 자가 종료**.

## 4. Workaround & Verification (조치 및 검증)
- 조치: \`MEMORY_LIMIT\` 을 $(v oom_before MEMORY_LIMIT) → $(v oom_after MEMORY_LIMIT) 로 상향 (\`export MEMORY_LIMIT=$(v oom_after MEMORY_LIMIT)\`, 필요 시 ~/.bash_profile 에 반영)

$TABLE_HEAD
$(result_row oom_before)
$(result_row oom_after)

$RESULT_NOTE

### After 실행 마지막 관제 로그
\`\`\`
$(tail -n 5 "$RUNS/oom_after/monitor.log" 2>/dev/null)
\`\`\`
\`\`\`
$(key_lines oom_after 'MemoryGuard|SELF-TERMINAT|limit exceeded|Reached Limit|cleanup|Cache Flushed|MEMORY RECOVERED' 8)
\`\`\`

- 결론: 한도를 늘리면 생존 시간이 늘어나지만 RSS 는 계속 증가하므로 **임시 조치**일 뿐임.
- 근본 해결 제안: 누적되는 캐시/리스트에 크기 제한(LRU, maxlen) 적용, 사용이 끝난 객체 참조 제거, tracemalloc 등으로 누수 지점 프로파일링.
EOF
fi

# ------------------------------------------------------------------ CPU
if [ -d "$RUNS/cpu_before" ]; then
cat > "$REP/02_CPU.md" <<EOF
# [Bug] CPU - 부하 50% 초과 시 Watchdog 정책에 의해 SIGTERM 종료

## 1. Description (현상 설명)
- \`CPU_MAX_OCCUPY=$(v cpu_before CPU_MAX_OCCUPY)\` 로 실행 시 CpuWorker 부하가 계속 오르다 약 **$(v cpu_before DURATION)초** 후 \`CPU Threshold Violated!\` 를 출력하고 종료됨.
- 실행 시각: $(v cpu_before START_TS) ~ $(v cpu_before END_TS)
- 종료 코드: **$(exit_desc cpu_before)** — 128 + 시그널 번호. 143 이면 128 + 15 = SIGTERM 으로 종료된 것
- OS 측정 최대 CPU 사용률: $(v cpu_before PEAK_CPU)% (코어 1개 = 100%)

## 2. Evidence & Logs (증거 자료)
### monitor.sh 관제 로그 (발췌)
\`\`\`
$(monitor_excerpt cpu_before 12)
\`\`\`

### CPU(%) 추이
\`\`\`
$(bar_graph cpu_before CPU)
\`\`\`

### top (시스템 전체, 종료 직전)
\`\`\`
$(top_snapshot cpu_before)
\`\`\`

### 부하 상승 및 종료 로그
\`\`\`
$(key_lines cpu_before 'CpuWorker|Threshold Violated|WATCHDOG|SIGTERM|CRITICAL' 12)
\`\`\`

## 3. Root Cause Analysis (원인 분석)
- CpuWorker 의 \`Current Load\` 가 계속 오르다가 **처음 50% 를 넘은 측정**에서 위반 판정 → 부트 단계의 \`Recommend Under 50%\` 경고와 일치. 설정값($(v cpu_before CPU_MAX_OCCUPY)%)이 아니라 50% 기준으로 판정되는 것으로 보임.
- 예외/스택 로그 없이 종료 코드 $(exit_desc cpu_before) 로 끝남 → 버그 크래시가 아니라 **Watchdog 과점유 방지 정책의 의도된 종료**.
- 관측 한계: 앱 로그의 Load 와 OS 측정값(monitor.sh 최대 $(v cpu_before PEAK_CPU)%)을 비교해, 차이가 크면 \`Current Load\` 는 앱 내부 지표로 판단.
- 관련 OS 원리: CPU 는 스케줄러가 시간을 나눠주는 자원이라 한 프로세스가 독점하면 다른 프로세스의 실행 차례가 늦어져 전체 응답이 지연됨. Watchdog 은 SIGKILL(9) 대신 SIGTERM(15)으로 정리할 기회를 주며 원인 프로세스만 내림.

## 4. Workaround & Verification (조치 및 검증)
- 조치: \`CPU_MAX_OCCUPY\` 를 $(v cpu_before CPU_MAX_OCCUPY) → $(v cpu_after CPU_MAX_OCCUPY) 로 변경

$TABLE_HEAD
$(result_row cpu_before)
$(result_row cpu_after)

$RESULT_NOTE

### After 실행 관제 로그 (발췌)
\`\`\`
$(monitor_excerpt cpu_after 8)
\`\`\`
\`\`\`
$(key_lines cpu_after 'Maximum CPU Limit|Peak reached|cooldown|Threshold Violated|SIGTERM' 8)
\`\`\`

- 결론: 한도를 권장값(50%) 이하로 두면 앱이 Peak 도달 시 cooldown 으로 부하를 스스로 낮춰 Watchdog 종료가 발생하지 않음. 다만 부하 상한을 낮춘 임시 조치임.
- 근본 해결 제안: 연산 루프에 yield/sleep 삽입, 작업 분할, nice/cgroup(cpu.max)로 CPU 상한 설정, 알고리즘 복잡도 개선.
EOF
fi

# ------------------------------------------------------------------ Deadlock
if [ -d "$RUNS/deadlock_before" ]; then
cat > "$REP/03_DEADLOCK.md" <<EOF
# [Bug] Deadlock - MULTI_THREAD_ENABLE=true 에서 스레드 간 순환 락 대기로 프로세스 무응답

## 1. Description (현상 설명)
- \`MULTI_THREAD_ENABLE=$(v deadlock_before MULTI_THREAD_ENABLE)\` 로 실행 시 프로세스는 종료되지 않고 PID 가 유지되지만, **${STALL_SEC:-30}초 이상 로그가 전혀 늘지 않는 무응답 상태**가 됨 (결과: $(v deadlock_before RESULT)).
- 실행 시각: $(v deadlock_before START_TS), 관찰 종료까지 $(v deadlock_before DURATION)초

## 2. Evidence & Logs (증거 자료)
### PID 존재 / 스레드 상태 / 락 대기 지점
\`\`\`
$(cat "$RUNS/deadlock_before/deadlock_evidence.txt" 2>/dev/null | head -n 120)
\`\`\`

### monitor.sh — CPU/MEM 변화 정체 구간
\`\`\`
$(tail -n 10 "$RUNS/deadlock_before/monitor.log" 2>/dev/null)
\`\`\`

### 마지막 로그 지점
\`\`\`
$(key_lines deadlock_before 'Attempting to lock|LOCK ACQUIRED|Need resource|WAITING|BLOCKED' 10)
\`\`\`

## 3. Root Cause Analysis (원인 분석)
**스레드-락 대기 관계 (로그에서 추출)**

| 스레드 | 보유 중인 락 | 기다리는 락 |
|---|---|---|
$(lock_table deadlock_before)

- PID 는 살아있으나(ps -ef) 스레드 상태가 모두 \`S\`(sleep)이고 CPU 0%, RSS 변화 없음 → 무한 루프(CPU 100%)가 아니라 **무언가를 기다리며 잠든 상태**.
- 모든 스레드의 wchan 이 \`$(grep -o 'wchan=[a-z_]*' "$RUNS/deadlock_before/deadlock_evidence.txt" 2>/dev/null | head -n 1 | cut -d= -f2)\` → futex 는 리눅스가 락(mutex)을 구현하는 커널 기능. 스레드가 락을 얻지 못해 커널에서 잠들어 기다리는 중이라는 OS 측 증거.
- 위 표처럼 각 스레드가 락 하나를 쥔 채 상대가 쥔 락을 기다림 → 서로의 자원을 기다리는 **순환 대기**. 메인 스레드는 \`Waiting for worker threads to complete\` 이후 워커 종료를 기다리며 함께 멈춤.
- 교착상태 4조건 충족:
  1. 상호 배제: 락은 한 번에 한 스레드만 보유
  2. 점유 대기: 이미 락 하나를 쥔 채 다른 락을 요청
  3. 비선점: 다른 스레드가 쥔 락을 강제로 뺏을 수 없음
  4. 순환 대기: A→B→A 대기 사슬
- (식사하는 철학자 문제에서 모두가 왼쪽 포크를 들고 오른쪽 포크를 기다리는 상황과 같음)

## 4. Workaround & Verification (조치 및 검증)
- 조치: \`MULTI_THREAD_ENABLE=false\` 로 단일 스레드 실행 → 락 경쟁 자체가 사라져 순환 대기가 생길 수 없음

$TABLE_HEAD
$(result_row deadlock_before)
$(result_row deadlock_after)

$RESULT_NOTE

### After 실행 마지막 로그 (계속 진행됨)
\`\`\`
$(last_lines deadlock_after 10)
\`\`\`

- 근본 해결 제안: 모든 스레드가 락을 **같은 순서로** 획득(순환 대기 제거), \`acquire(timeout=...)\` 로 타임아웃 후 재시도(점유 대기 완화), 락 범위 최소화 또는 큐 기반 설계로 공유 자원 제거.
EOF
fi

echo "리포트 생성 완료:"
ls -1 "$REP"/*.md 2>/dev/null
