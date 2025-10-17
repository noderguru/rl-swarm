#!/usr/bin/env bash
set -euo pipefail

# === Paths & Defaults ===
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$ROOT/logs"
ML_DIR="$ROOT/modal-login"
ML_TEMP="$ML_DIR/temp-data"

# === Env (без интерактива) ===
export CONNECT_TO_TESTNET=true
export HF_HUB_DOWNLOAD_TIMEOUT=120
export HUGGINGFACE_ACCESS_TOKEN="None"
export GENSYN_RESET_CONFIG="${GENSYN_RESET_CONFIG:-}"
export CPU_ONLY="${CPU_ONLY:-}"
export SWARM_CONTRACT="${SWARM_CONTRACT:-0xFaD7C5e93f28257429569B854151A1B8DCD404c2}"
export PRG_CONTRACT="${PRG_CONTRACT:-0x51D4db531ae706a6eC732458825465058fA23a35}"
export PRG_GAME=true
GENRL_TAG="${GENRL_TAG:-0.1.10}"

# === API-key activation check (новое) ===
REQUIRE_API_KEY_ACTIVATION="${REQUIRE_API_KEY_ACTIVATION:-1}"   # 1=ждать активацию, 0=пропустить
API_KEY_WAIT_SECONDS="${API_KEY_WAIT_SECONDS:-300}"              # общий таймаут ожидания, сек

DEFAULT_IDENTITY_PATH="$ROOT/swarm.pem"
export IDENTITY_PATH="${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}"

# === Colors & echo ===
GREEN="\033[32m"; BLUE="\033[34m"; RED="\033[31m"; YELLOW="\033[33m"; RESET="\033[0m"
echo_green(){ echo -e "${GREEN}$1${RESET}"; }
echo_blue (){ echo -e "${BLUE}$1${RESET}"; }
echo_red  (){ echo -e "${RED}$1${RESET}"; }
echo_yel  (){ echo -e "${YELLOW}$1${RESET}"; }

mkdir -p "$LOG_DIR"

cleanup() {
  echo_green ">> Stopping background processes…"
  [[ -n "${ML_PID:-}" ]] && kill "$ML_PID" &>/dev/null || true
  [[ -n "${LT_PID:-}" ]] && kill "$LT_PID" &>/dev/null || true
}
trap cleanup EXIT SIGINT SIGTERM

# === Tools check ===
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || return 1
}
ensure_pkg() {
  if ! need_cmd "$1"; then
    echo_yel ">> Installing $1…"
    apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$1"
  fi
}

ensure_pkg jq
ensure_pkg curl

# === Start modal-login server ===
start_modal_login() {
  echo_green ">> Starting modal-login server…"
  cd "$ML_DIR"

  # Node & Yarn
  if ! need_cmd node; then
    echo_yel "Node.js not found → install NVM + Node.js"
    export NVM_DIR="$HOME/.nvm"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    # shellcheck disable=SC1090
    . "$NVM_DIR/nvm.sh"
    nvm install node
  else
    echo_green "Node.js: $(node -v)"
  fi

  if ! need_cmd yarn; then
    echo_yel "Yarn not found → npm i -g yarn"
    npm install -g yarn >/dev/null 2>&1
  fi

  ENV_FILE="$ML_DIR/.env"
  if [[ -f "$ENV_FILE" ]]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' "3s/.*/SWARM_CONTRACT_ADDRESS=${SWARM_CONTRACT}/" "$ENV_FILE"
      sed -i '' "4s/.*/PRG_CONTRACT_ADDRESS=${PRG_CONTRACT}/" "$ENV_FILE"
    else
      sed -i "3s/.*/SWARM_CONTRACT_ADDRESS=${SWARM_CONTRACT}/" "$ENV_FILE"
      sed -i "4s/.*/PRG_CONTRACT_ADDRESS=${PRG_CONTRACT}/" "$ENV_FILE"
    fi
  fi

  yarn install --immutable        &> "$LOG_DIR/yarn_install.log"
  echo_green ">> Building modal-login…"
  yarn build                      &> "$LOG_DIR/yarn_build.log"
  echo_green ">> Running modal-login…"
  yarn start                      &> "$LOG_DIR/yarn_start.log" &
  ML_PID=$!
  echo_green ">> modal-login PID: $ML_PID"
  cd "$ROOT"
}

# === Localtunnel until JSON appear ===
ensure_modal_json() {
  if [[ -f "$ML_TEMP/userData.json" && -f "$ML_TEMP/userApiKey.json" ]]; then
    echo_green ">> JSON already present — skipping login."
    return 0
  fi

  echo_green ">> Start localtunnel for login…"
  npm install -g localtunnel >/dev/null 2>&1 || true
  lt --port 3000 > "$LOG_DIR/lt.log" 2>&1 &
  LT_PID=$!
  sleep 3

  TUNNEL_URL="$(grep -Eo 'https://[^ ]+' "$LOG_DIR/lt.log" | head -n1 || true)"
  IP="$(curl -4 -s ifconfig.me || echo 'your-IP')"

  echo_blue  "   Open in browser: ${TUNNEL_URL:-<wait 3-10s and recheck lt.log>}"
  echo_blue  "   Password = your IP: $IP"
  echo_green "   Waiting for JSON files to appear…"

  while [[ ! -f "$ML_TEMP/userData.json" || ! -f "$ML_TEMP/userApiKey.json" ]]; do
    sleep 5
  done

  echo_green ">> JSON files created."
  kill "$LT_PID" 2>/dev/null || true
}

# === Parse ORG_ID from userData.json (robust jq) ===
extract_org_id() {
  local f="$ML_TEMP/userData.json"
  if [[ ! -f "$f" ]]; then
    echo_red ">> userData.json not found."
    return 1
  fi

  ORG_ID="$(jq -r '
    if type=="string" then .
    elif has("orgId") then .orgId
    elif (.data? and .data.orgId) then .data.orgId
    else to_entries[0].value.orgId
    end
  ' "$f" 2>/dev/null || echo "")"

  if [[ -z "$ORG_ID" || "$ORG_ID" == "null" ]]; then
    echo_red ">> WARNING: Failed to extract ORG_ID (Modal-Login may misbehave on peer registration)."
  else
    export ORG_ID
    echo_green ">> ORG_ID = $ORG_ID"
  fi
}

# === Optional: wait for API key activation ===
wait_api_key_activation() {
  if [[ "${REQUIRE_API_KEY_ACTIVATION}" != "1" ]]; then
    echo_yel ">> API-key activation check skipped (REQUIRE_API_KEY_ACTIVATION=0)."
    return 0
  fi

  if [[ -z "${ORG_ID:-}" || "$ORG_ID" == "null" ]]; then
    echo_yel ">> API-key activation check skipped (ORG_ID empty)."
    return 0
  fi

  echo_green ">> Waiting for API key activation (timeout ${API_KEY_WAIT_SECONDS}s)…"
  local deadline=$(( $(date +%s) + API_KEY_WAIT_SECONDS ))
  while true; do
    local raw
    raw="$(curl -fsS --max-time 5 \
            --get "http://127.0.0.1:3000/api/get-api-key-status" \
            --data-urlencode "orgId=${ORG_ID}" 2>/dev/null || true)"

    local st=""
    if [[ "$raw" == "activated" ]]; then
      st="activated"
    else
      st="$(jq -r '(.status // .state // empty)' <<<"$raw" 2>/dev/null || echo "")"
    fi

    if [[ "$st" == "activated" ]]; then
      echo_green ">> API key is activated! Proceeding…"
      break
    fi

    if (( $(date +%s) >= deadline )); then
      echo_yel ">> Activation wait timed out — proceeding anyway."
      break
    fi

    echo_blue ">> Waiting for API key to be activated…"
    sleep 5
  done
}

# === Python deps ===
install_python_reqs() {
  echo_green ">> Installing Python requirements…"
  if need_cmd python3; then
    PY=python3
  else
    PY=python
  fi
  $PY -m pip install --upgrade pip        2>&1 | tee -a "$LOG_DIR/python_deps.log"
  $PY -m pip install \
    "gensyn-genrl==${GENRL_TAG}" \
    "reasoning-gym>=0.1.20" \
    "git+https://github.com/gensyn-ai/hivemind@639c964a8019de63135a2594663b5bec8e5356dd" \
    2>&1 | tee -a "$LOG_DIR/python_deps.log"
}

# === Config sync ===
sync_config() {
  mkdir -p "$ROOT/configs"
  local SRC="$ROOT/rgym_exp/config/rg-swarm.yaml"
  local DST="$ROOT/configs/rg-swarm.yaml"
  if [[ -f "$DST" ]]; then
    if ! cmp -s "$SRC" "$DST"; then
      if [[ -n "$GENSYN_RESET_CONFIG" ]]; then
        mv "$DST" "$DST.bak.$(date +%s)" || true
        cp "$SRC" "$DST"
        echo_green ">> Config reset to default (backup saved)."
      else
        echo_yel ">> Config differs. Keep existing (set GENSYN_RESET_CONFIG to overwrite)."
      fi
    fi
  else
    cp "$SRC" "$DST"
    echo_green ">> Config created: configs/rg-swarm.yaml"
  fi
}

# === Main ===
echo -e "\033[38;5;224m"
cat <<'ASCII'
    ██████  ██            ███████ ██     ██  █████  ██████  ███    ███
    ██   ██ ██            ██      ██     ██ ██   ██ ██   ██ ████  ████
    ██████  ██      █████ ███████ ██  █  ██ ███████ ██████  ██ ████ ██
    ██   ██ ██                 ██ ██ ███ ██ ██   ██ ██   ██ ██  ██  ██
    ██   ██ ███████       ███████  ███ ███  ██   ██ ██   ██ ██      ██
ASCII
echo -en "${RESET}"

echo_green ">> participate in the AI Prediction Market: true"
echo_green ">> Playing PRG game: true"

start_modal_login
ensure_modal_json
extract_org_id
wait_api_key_activation
install_python_reqs
sync_config

echo_green ">> Launching rl-swarm with auto-restart on crash/OOM…"
echo_blue  ">> Using default model from config (no prompt)."
echo_blue  ">> HF token disabled (HUGGINGFACE_ACCESS_TOKEN=None)."

while true; do
  if python -m rgym_exp.runner.swarm_launcher \
       --config-path "$ROOT/rgym_exp/config" \
       --config-name "rg-swarm.yaml"; then
    echo_green ">> rl-swarm finished normally."
  else
    CODE=$?
    echo_red ">> rl-swarm exited code $CODE. Restarting in 5s…"
  fi
  sleep 5
done
