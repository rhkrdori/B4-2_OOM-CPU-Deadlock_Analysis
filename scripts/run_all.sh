#!/usr/bin/env bash
# 3가지 장애 × (Before / After) = 6번 실행 후 리포트까지 자동 생성
# 사용법: ./run_all.sh            # 전부
#         ./run_all.sh oom cpu    # 일부만 (oom | cpu | deadlock)
#
# 설정값 (리포트 01_OOM / 02_CPU / 03_Deadlock 기준)
#   OOM      : MEMORY_LIMIT        256 → 512   (CPU_MAX_OCCUPY=50,  MULTI_THREAD_ENABLE=false)
#   CPU      : CPU_MAX_OCCUPY       80 → 50    (MEMORY_LIMIT=512,   MULTI_THREAD_ENABLE=false)
#   Deadlock : MULTI_THREAD_ENABLE true → false (MEMORY_LIMIT=512, CPU_MAX_OCCUPY=50)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

OOM_BEFORE_LIMIT=${OOM_BEFORE_LIMIT:-256}   # MB  (Before: 약 30초 후 MemoryGuard 종료)
OOM_AFTER_LIMIT=${OOM_AFTER_LIMIT:-512}     #     (After : 캐시 정리 후 계속 실행)
CPU_BEFORE_MAX=${CPU_BEFORE_MAX:-80}        # %   (Before: 부하 50% 초과 시 SIGTERM, exit 143)
CPU_AFTER_MAX=${CPU_AFTER_MAX:-50}          #     (After : 50%에서 cooldown)
SAFE_MEM=512
SAFE_CPU=50

export MAX_RUN=${MAX_RUN:-120}    # After 실행 관찰 시간(초). Before 는 30~45초 안에 끝남
export STALL_SEC=${STALL_SEC:-30} # 데드락은 시작 약 9초 뒤 로그가 멈춤

GROUPS_TO_RUN=${*:-"oom cpu deadlock"}
R="$SCRIPT_DIR/run_case.sh"

for g in $GROUPS_TO_RUN; do
  case "$g" in
    oom)
      "$R" oom_before MEMORY_LIMIT="$OOM_BEFORE_LIMIT" CPU_MAX_OCCUPY=$SAFE_CPU MULTI_THREAD_ENABLE=false
      "$R" oom_after  MEMORY_LIMIT="$OOM_AFTER_LIMIT"  CPU_MAX_OCCUPY=$SAFE_CPU MULTI_THREAD_ENABLE=false
      ;;
    cpu)
      "$R" cpu_before CPU_MAX_OCCUPY="$CPU_BEFORE_MAX" MEMORY_LIMIT=$SAFE_MEM MULTI_THREAD_ENABLE=false
      "$R" cpu_after  CPU_MAX_OCCUPY="$CPU_AFTER_MAX"  MEMORY_LIMIT=$SAFE_MEM MULTI_THREAD_ENABLE=false
      ;;
    deadlock)
      "$R" deadlock_before MULTI_THREAD_ENABLE=true  MEMORY_LIMIT=$SAFE_MEM CPU_MAX_OCCUPY=$SAFE_CPU
      "$R" deadlock_after  MULTI_THREAD_ENABLE=false MEMORY_LIMIT=$SAFE_MEM CPU_MAX_OCCUPY=$SAFE_CPU
      ;;
    *) echo "알 수 없는 그룹: $g (oom|cpu|deadlock)" >&2 ;;
  esac
done

"$SCRIPT_DIR/make_report.sh"
