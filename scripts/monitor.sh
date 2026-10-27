#!/usr/bin/env bash
# 프로세스 관제 스크립트
# 사용법: ./monitor.sh <PID 또는 프로세스이름> [주기(초), 기본 2] [로그파일]
# 출력 예:
# [2026-10-23 14:00:00] PROCESS:agent-app-leak PID:1234 STATE:S CPU:1.2% MEM:5.1% RSS:80MB THREADS:3 PROCS:2 DISK:50G FIREWALL:active
#
# - CPU% 는 /proc/<pid>/stat 의 utime+stime 증가량으로 계산한 "현재 구간" 사용률이다.
#   (ps 의 %CPU 는 실행 시작부터의 평균이라 순간적인 스파이크가 묻힌다)
# - 자식 프로세스까지 합산한다. 100% = 코어 1개를 꽉 쓴 상태.

TARGET=${1:?"사용법: $0 <PID|name> [interval] [logfile]"}
INTERVAL=${2:-2}
LOG=${3:-}

CLK=$(getconf CLK_TCK)
MEMTOTAL_KB=$(awk '/^MemTotal/{print $2}' /proc/meminfo)

descendants() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; descendants "$c"; done
}

resolve_root() {
  if [[ $TARGET =~ ^[0-9]+$ ]]; then
    [ -d "/proc/$TARGET" ] && echo "$TARGET"
    return
  fi
  local p
  for p in $(pgrep -f -- "$TARGET"); do
    # monitor.sh 자기 자신(인자에 이름이 들어있음)은 제외
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'monitor.sh' && continue
    echo "$p"; return
  done
}

firewall_status() {
  if command -v ufw >/dev/null 2>&1; then
    local s; s=$(ufw status 2>/dev/null | head -n 1)
    case "$s" in
      *inactive*) echo inactive; return ;;
      *active*) echo active; return ;;
    esac
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    echo active; return
  fi
  echo unknown
}
FIREWALL=$(firewall_status)

out() {
  if [ -n "$LOG" ]; then echo "$1" | tee -a "$LOG"; else echo "$1"; fi
}

declare -A prev
prev_t=""

while :; do
  root=$(resolve_root)
  now=$(date '+%Y-%m-%d %H:%M:%S')
  if [ -z "$root" ]; then
    out "[$now] PROCESS:$TARGET STATUS:GONE"
    exit 0
  fi

  now_t=$(date +%s.%N)
  declare -A cur=()
  dticks=0; rss_kb=0; threads=0; procs=0; main_state="?"; main_rss=-1; name="?"
  for p in $root $(descendants "$root"); do
    st=$(cat "/proc/$p/stat" 2>/dev/null) || continue
    rest=${st##*) }
    read -r -a f <<< "$rest"
    # rest 기준: f[0]=state, f[11]=utime, f[12]=stime
    t=$(( f[11] + f[12] ))
    cur[$p]=$t
    if [ -n "${prev[$p]:-}" ]; then dticks=$(( dticks + t - prev[$p] )); fi
    r=$(awk '/^VmRSS/{print $2}' "/proc/$p/status" 2>/dev/null); r=${r:-0}
    th=$(awk '/^Threads/{print $2}' "/proc/$p/status" 2>/dev/null); th=${th:-0}
    rss_kb=$(( rss_kb + r )); threads=$(( threads + th )); procs=$(( procs + 1 ))
    if [ "$r" -gt "$main_rss" ]; then
      main_rss=$r; main_state=${f[0]}
      # comm 은 15자에서 잘리므로(agent-leak-app-) 실행 파일 이름을 쓴다
      name=$(tr '\0' '\n' < "/proc/$p/cmdline" 2>/dev/null | head -n 1)
      name=${name##*/}
      [ -n "$name" ] || name=$(cat "/proc/$p/comm" 2>/dev/null)
    fi
  done

  if [ -z "$prev_t" ]; then
    cpu="0.0"
  else
    cpu=$(awk -v d="$dticks" -v c="$CLK" -v a="$prev_t" -v b="$now_t" \
      'BEGIN{dt=b-a; if(dt<=0)dt=1; printf "%.1f", d/c/dt*100}')
  fi
  mem=$(awk -v r="$rss_kb" -v t="$MEMTOTAL_KB" 'BEGIN{printf "%.1f", r/t*100}')
  disk=$(df -h / 2>/dev/null | awk 'NR==2{print $4}')

  out "[$now] PROCESS:$name PID:$root STATE:$main_state CPU:${cpu}% MEM:${mem}% RSS:$(( rss_kb / 1024 ))MB THREADS:$threads PROCS:$procs DISK:$disk FIREWALL:$FIREWALL"

  unset prev; declare -A prev
  for k in "${!cur[@]}"; do prev[$k]=${cur[$k]}; done
  unset cur
  prev_t=$now_t
  sleep "$INTERVAL"
done
