#!/bin/bash
set -euo pipefail

main() {
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  export CONNECT_TO_TESTNET=true
  export HF_HUB_DOWNLOAD_TIMEOUT=120
  export HUGGINGFACE_ACCESS_TOKEN="None"
  export GENSYN_RESET_CONFIG="${GENSYN_RESET_CONFIG:-}"
  export CPU_ONLY="${CPU_ONLY:-}"
  export SWARM_CONTRACT="${SWARM_CONTRACT:-0xFaD7C5e93f28257429569B854151A1B8DCD404c2}"
  DEFAULT_IDENTITY_PATH="$ROOT/swarm.pem"
  export IDENTITY_PATH="${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}"

  LOG_DIR="$ROOT/logs"
  ML_DIR="$ROOT/modal-login"
  ML_TEMP="$ML_DIR/temp-data"

  GREEN="\033[32m"; RED="\033[31m"; RESET="\033[0m"
  echo_green(){ echo -e "${GREEN}$1${RESET}"; }
  echo_red  (){ echo -e "${RED}$1${RESET}"; }

  cleanup() {
    echo_green ">> Stopping background processes…"
    [[ -n "${ML_PID:-}" ]] && kill "$ML_PID" &>/dev/null || true
    [[ -n "${LT_PID:-}" ]] && kill "$LT_PID" &>/dev/null || true
  }
  trap cleanup EXIT SIGINT SIGTERM

  echo_green ">> Checking for jq…"
  if ! command -v jq &>/dev/null; then
    echo_green ">> jq not found — installing…"
    apt-get update
    apt-get install -y jq
  fi

  echo_green ">> Checking modal-login directory..."
  if [[ ! -d "$ML_DIR" ]]; then
    echo_green ">> modal-login folder not found, cloning..."
    git clone https://github.com/gensyn-ai/modal-login.git "$ML_DIR"
  fi

  echo_green ">> Starting modal-login server…"
  mkdir -p "$LOG_DIR"
  cd "$ML_DIR"

  NODE_VERSION="$(node -v 2>/dev/null || echo "v0.0.0")"
  if [[ "${NODE_VERSION#v}" < "20.18.0" ]]; then
      echo_green "Node.js ${NODE_VERSION} is incompatible → installing NVM + Node.js v20.18.0"
      export NVM_DIR="$HOME/.nvm"
      curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
      source "$NVM_DIR/nvm.sh"
      nvm install 20.18.0
      nvm use 20.18.0
  else
      echo_green "Node.js found and compatible: $NODE_VERSION"
  fi

  if ! command -v yarn &>/dev/null; then
      echo_green "Yarn not found → Installing via npm"
      npm install -g yarn
  fi

  echo_green "-> Updating SMART_CONTRACT_ADDRESS in .env"
  sed -i "3s/.*/SMART_CONTRACT_ADDRESS=${SWARM_CONTRACT}/" .env

  echo_green "-> Installing modal-login dependencies"
  set +e
  yarn install --immutable 2>&1 | tee "$LOG_DIR/yarn_install.log"
  INSTALL_STATUS=${PIPESTATUS[0]}
  set -e
  if [[ $INSTALL_STATUS -ne 0 ]]; then
    echo_red ">> Warning: modal-login dependencies install failed (code $INSTALL_STATUS), continuing anyway"
  fi

  echo_green "-> Building modal-login"
  yarn build &> "$LOG_DIR/yarn_build.log"
  echo_green "-> Launching modal-login (background)"
  yarn start &> "$LOG_DIR/yarn_start.log" &
  ML_PID=$!
  echo_green ">> modal-login PID: $ML_PID"

  cd "$ROOT"

  echo_green ">> Checking for existing JSON credentials…"
  if [[ -s "$ML_TEMP/userData.json" && -s "$ML_TEMP/userApiKey.json" ]]; then
    echo_green ">> JSON files found — skipping login"
  else
    echo_green ">> JSON not found — launching localtunnel for login…"
    npm install -g localtunnel
    lt --port 3000 > "$LOG_DIR/lt.log" 2>&1 &
    LT_PID=$!
    sleep 5
    TUNNEL_URL=$(grep -o 'https://[^ ]*' "$LOG_DIR/lt.log" | head -n1 || echo "http://localhost:3000")
    IP=$(curl -4 -s ifconfig.me)
    echo_green "   Open in browser: $TUNNEL_URL"
    echo_green "   Password = your IP: $IP"
    echo_green "   Waiting for JSON files…"
    while [[ ! -s "$ML_TEMP/userData.json" || ! -s "$ML_TEMP/userApiKey.json" ]]; do
      sleep 5
      echo_green "   still waiting…"
    done
    kill "$LT_PID" &>/dev/null || true
    echo_green ">> JSON files created"
  fi

  echo_green ">> Extracting ORG_ID from userData.json…"
  RAW=$(<"$ML_TEMP/userData.json")
  if [[ "$RAW" =~ ^".*"$ ]]; then
    ORG_ID="${RAW:1:-1}"
  else
    ORG_ID=$(jq -r '
      if has("orgId") then .orgId
      elif (.data? and .data.orgId) then .data.orgId
      else to_entries[0].value.orgId
      end
    ' "$ML_TEMP/userData.json")
  fi
  if [[ -z "$ORG_ID" || "$ORG_ID" == "null" ]]; then
    echo_red ">> WARNING: ORG_ID extraction failed — peer registration may error"
  else
    export ORG_ID
    echo_green ">> ORG_ID = $ORG_ID"
  fi

  echo_green ">> Installing Python requirements…"
  pip install --upgrade pip 2>&1 | tee -a "$LOG_DIR/python_deps.log"
  pip install \
    gensyn-genrl==0.1.4 \
    reasoning-gym>=0.1.20 \
    trl \
    hivemind@git+https://github.com/gensyn-ai/hivemind@639c964a8019de63135a2594663b5bec8e5356dd \
    2>&1 | tee -a "$LOG_DIR/python_deps.log"

  echo_green ">> Launching rl-swarm (auto-restart on crash or timeout)…"
  timeout --foreground 30m python -m rgym_exp.runner.swarm_launcher \
    --config-path "$ROOT/rgym_exp/config" \
    --config-name "rg-swarm.yaml"
}

RESTART_DELAY=15
while true; do
  main
  CODE=$?
  if [[ $CODE -eq 124 ]]; then
    echo -e "\033[31m>> rl-swarm likely hanged (timeout)\033[0m"
  else
    echo -e "\033[31m>> rl-swarm crashed with code $CODE\033[0m"
  fi
  echo ">> Restarting in $RESTART_DELAY seconds..."
  sleep $RESTART_DELAY
done
