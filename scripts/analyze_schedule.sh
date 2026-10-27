#!/usr/bin/env bash
# (보너스) 로그 타임스탬프로 스레드/워커 실행 순서와 교체 주기를 뽑는다.
# 사용법: ./analyze_schedule.sh [로그파일]   (기본: runs/deadlock_after/app.log)
#
# 로그 한 줄에서 [YYYY-MM-DD HH:MM:SS(.mmm)] 와 [Thread-X]/[Worker-X] 같은 태그를 찾아
#  1) 실행 순서(연속 구간을 하나로 묶음)
#  2) 스레드별 연속 실행 구간 길이/횟수
#  3) 교체 간격 통계
# 를 출력한다. 로그 형식이 다르면 TAG_RE 를 바꾸면 된다.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG=${1:-"$SCRIPT_DIR/runs/deadlock_after/app.log"}
TAG_RE=${TAG_RE:-'(Thread|Worker|Task|Proc|Process|Job)[-_ ]?[A-Za-z0-9]+'}

[ -f "$LOG" ] || { echo "로그 없음: $LOG"; exit 1; }

grep -E "$TAG_RE" "$LOG" | awk -v re="$TAG_RE" '
function tosec(s,   d,t,h,m,x){ split(s,d," "); split(d[2],t,":"); return t[1]*3600+t[2]*60+t[3] }
{
  if (!match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ T][0-9][0-9]:[0-9][0-9]:[0-9][0-9](\.[0-9]+)?/)) next
  ts=substr($0,RSTART,RLENGTH); gsub("T"," ",ts)
  if (!match($0, re)) next
  tag=substr($0,RSTART,RLENGTH)
  n++; T[n]=tosec(ts); G[n]=tag; RAW[n]=ts
}
END{
  if(n==0){print "태그가 있는 로그 줄을 찾지 못했습니다. TAG_RE 를 조정하세요."; exit}
  print "== 1) 실행 순서 (연속 구간 묶음, 처음 40개) =="
  seg=0; start=1
  for(i=1;i<=n+1;i++){
    if(i==n+1 || G[i]!=G[start]){
      seg++; len=T[i-1]-T[start]; cnt=i-start
      if(seg<=40) printf "%3d. %-14s %s  ~ %.3fs 동안 %d줄\n", seg, G[start], RAW[start], len, cnt
      segs[G[start]]++; seglen[G[start]]+=len; total_len+=len
      if(seg>1){ sw[seg]=T[start]-prev_start }
      prev_start=T[start]; start=i
    }
  }
  print ""
  print "== 2) 스레드별 통계 =="
  for(g in segs) printf "%-14s 구간 %3d회, 평균 연속 실행 %.3fs\n", g, segs[g], seglen[g]/segs[g]
  print ""
  print "== 3) 교체 간격 =="
  mn=1e9; mx=0; s=0; c=0
  for(k=2;k<=seg;k++){ d=sw[k]; s+=d; c++; if(d<mn)mn=d; if(d>mx)mx=d }
  if(c>0) printf "교체 %d회, 평균 %.3fs, 최소 %.3fs, 최대 %.3fs\n", c, s/c, mn, mx
  print ""
  print "해석 가이드:"
  print " - 한 스레드가 끝날 때까지 다른 스레드가 안 나오면 → FCFS"
  print " - 스레드가 번갈아 나오고 교체 간격이 거의 일정하면 → Round-Robin (간격 ≈ 타임 퀀텀)"
  print " - 특정 스레드가 항상 먼저/더 자주 실행되면 → Priority"
}'
