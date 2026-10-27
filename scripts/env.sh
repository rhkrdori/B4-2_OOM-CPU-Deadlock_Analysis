#!/usr/bin/env bash
# agent-leak-app 실행에 필요한 환경변수와 디렉터리를 준비한다.
# 사용법: source ./env.sh   (값을 바꾸려면 source 전에 export 해두면 된다)

export AGENT_HOME="${AGENT_HOME:-$HOME/agent_home}"
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR="$AGENT_HOME/upload_files"
export AGENT_KEY_PATH="$AGENT_HOME/api_keys"
export AGENT_LOG_DIR="${AGENT_LOG_DIR:-$AGENT_HOME/logs}"
export MEMORY_LIMIT="${MEMORY_LIMIT:-256}"          # 50~512 (MB)
export CPU_MAX_OCCUPY="${CPU_MAX_OCCUPY:-80}"       # 10~100 (%)
export MULTI_THREAD_ENABLE="${MULTI_THREAD_ENABLE:-false}"

mkdir -p "$AGENT_UPLOAD_DIR" "$AGENT_KEY_PATH" "$AGENT_LOG_DIR"
if [ ! -f "$AGENT_KEY_PATH/secret.key" ]; then
  printf '%s' 'agent_api_key_test' > "$AGENT_KEY_PATH/secret.key"
fi
