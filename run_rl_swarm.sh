#!/bin/bash
set -euo pipefail

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

echo_green ">> Starting modal-login server…"
mkdir -p "$LOG_DIR"
cd "$ML_DIR"
if ! command -v node &>/dev/null; then
    echo_green "Node.js not found → install NVM+Node.js"
    export NVM_DIR="$HOME/.nvm"
    curl -so- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    . "$NVM_DIR/nvm.sh"
    nvm install node
fi
command -v yarn &>/dev/null || npm install -g yarn
sed -i "3s/.*/SMART_CONTRACT_ADDRESS=${SWARM_CONTRACT}/" .env
yarn install --immutable &> "$LOG_DIR/yarn_install.log"
yarn build                &> "$LOG_DIR/yarn_build.log"
yarn start                &> "$LOG_DIR/yarn_start.log" &
ML_PID=$!
echo_green ">> modal-login PID: $ML_PID"
cd "$ROOT"

if [[ -f "$ML_TEMP/userData.json" && -f "$ML_TEMP/userApiKey.json" ]]; then
    echo_green ">> JSON-files done — skip login"
else
    echo_green ">> Start localtunnel for login..."
    npm install -g localtunnel &>/dev/null
    lt --port 3000 > "$LOG_DIR/lt.log" 2>&1 &
    LT_PID=$!
    sleep 5
    TUNNEL_URL=$(grep -o 'https://[^ ]*' "$LOG_DIR/lt.log" | head -n1)
    IP=$(curl -4 -s ifconfig.me)
    echo_green "   Open in browser: $TUNNEL_URL"
    echo_green "   Password = your IP: $IP"
    echo_green "   wait create JSON…"
    while [[ ! -f "$ML_TEMP/userData.json" || ! -f "$ML_TEMP/userApiKey.json" ]]; do
        sleep 10
        echo_green "   still waiting…"
    done
    kill "$LT_PID"
    echo_green ">> JSON-files create"
fi

ORG_ID=$(jq -r '
  if type=="string" then . 
  elif has("orgId") then .orgId 
  elif (.data? and .data.orgId) then .data.orgId 
  else to_entries[0].value.orgId 
  end
' "$ML_TEMP/userData.json")

if [[ -z "$ORG_ID" || "$ORG_ID" == "null" ]]; then
    echo_red ">> WARNING: It was not possible to extract org_id-Modal-Login can give errors when registering peers."
else
    export ORG_ID
    echo_green ">> ORG_ID = $ORG_ID"
fi

echo_green ">> Installing Python requirements…"
pip install --upgrade pip &>/dev/null
pip install \
  gensyn-genrl==0.1.4 \
  reasoning-gym>=0.1.20 \
  trl \
  hivemind@git+https://github.com/gensyn-ai/hivemind@639c964a8019de63135a2594663b5bec8e5356dd \
  &> "$LOG_DIR/python_deps.log"

echo_green ">> Launching rl-swarm (auto-restart on crash)…"
while true; do
    if python -m rgym_exp.runner.swarm_launcher \
           --config-path "$ROOT/rgym_exp/config" \
           --config-name "rg-swarm.yaml"; then
        echo_green ">> rl-swarm finished normally, exit."
        break
    else
        CODE=$?
        echo_red ">> rl-swarm crashed (exit $CODE). Restarting in 5s…"
        sleep 5
    fi
done

cleanup
exit 0
