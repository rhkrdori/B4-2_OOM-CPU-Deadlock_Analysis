#!/usr/bin/env bash
# 공통 함수 모음 (다른 스크립트에서 source 해서 사용)

# 실행할 바이너리 찾기: APP_BIN 이 지정돼 있으면 그대로, 아니면 CPU 아키텍처에 맞는 파일을 찾는다.
find_bin() {
  if [ -n "${APP_BIN:-}" ]; then echo "$APP_BIN"; return; fi
  local arch
  case "$(uname -m)" in
    x86_64|amd64) arch=x86 ;;
    aarch64|arm64) arch=arm64 ;;
    *) arch="$(uname -m)" ;;
  esac
  local f
  f=$(find "$SCRIPT_DIR" -maxdepth 3 -type f -name "agent*${arch}*" ! -name '*.zip' 2>/dev/null | head -n 1)
  if [ -z "$f" ]; then
    echo "ERROR: agent-app-leak-${arch} 바이너리를 찾지 못했습니다. APP_BIN=/경로 로 지정하세요." >&2
    return 1
  fi
  chmod +x "$f" 2>/dev/null
  echo "$f"
}

# 자식/손자 프로세스 PID 목록 (PyInstaller 바이너리는 부트로더+실제 프로세스 2개로 뜬다)
descendants() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do
    echo "$c"
    descendants "$c"
  done
}

# 트리에서 메모리(RSS)를 가장 많이 쓰는 프로세스 = 실제 애플리케이션 프로세스
target_pid() {
  local root=$1 best=$1 best_rss=-1 p r
  for p in $root $(descendants "$root"); do
    r=$(awk '/^VmRSS/{print $2}' "/proc/$p/status" 2>/dev/null)
    r=${r:-0}
    if [ "$r" -gt "$best_rss" ]; then best_rss=$r; best=$p; fi
  done
  echo "$best"
}

port_in_use() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q ":$1 "
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | grep -q ":$1 "
  else
    return 1
  fi
}

wait_port_free() {
  local i
  for i in $(seq 1 30); do
    port_in_use "$1" || return 0
    sleep 1
  done
  echo "WARN: 포트 $1 이 30초 동안 해제되지 않았습니다." >&2
  return 1
}

kill_tree() {
  local root=$1 sig=${2:-TERM} p
  for p in $(descendants "$root") "$root"; do
    kill "-$sig" "$p" 2>/dev/null
  done
}

ts() { date '+%Y-%m-%d %H:%M:%S'; }
