#!/bin/bash

set -euo pipefail

# Максимальное количество автоматических рестартов
MAX_RESTART_COUNT=999999
restart_count=0
LOGIN_SERVER_PID=""
TUNNEL_PID=""
TRAINING_PID=""
ROOT=$PWD

export IDENTITY_PATH
export GENSYN_RESET_CONFIG
export CONNECT_TO_TESTNET=true
export ORG_ID
export HF_HUB_DOWNLOAD_TIMEOUT=120
export SWARM_CONTRACT="0x7745a8FE4b8D2D2c3BB103F8dCae822746F35Da0"
export HUGGINGFACE_ACCESS_TOKEN="None"

DEFAULT_IDENTITY_PATH="$ROOT"/swarm.pem
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

GENSYN_RESET_CONFIG=${GENSYN_RESET_CONFIG:-""}

ORG_ID=${ORG_ID:-""}

GREEN_TEXT="\033[32m"
BLUE_TEXT="\033[34m"
RED_TEXT="\033[31m"
YELLOW_TEXT="\033[33m"
RESET_TEXT="\033[0m"

echo_green() {
    echo -e "$GREEN_TEXT$1$RESET_TEXT"
}

echo_blue() {
    echo -e "$BLUE_TEXT$1$RESET_TEXT"
}

echo_red() {
    echo -e "$RED_TEXT$1$RESET_TEXT"
}

echo_yellow() {
    echo -e "$YELLOW_TEXT$1$RESET_TEXT"
}

ROOT_DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"
get_external_ipv4() {
    local ipv4=$(curl -4 -s --connect-timeout 5 ifconfig.me 2>/dev/null)
    
    if [ -n "$ipv4" ]; then
        echo "$ipv4"
    else
        echo "Unable to fetch"
    fi
}

check_login_success() {
    local temp_data_dir="$ROOT_DIR/modal-login/temp-data"
    
    if [ ! -f "$temp_data_dir/userData.json" ] || [ ! -f "$temp_data_dir/userApiKey.json" ]; then
        return 1  # Файлы не найдены
    fi
    
    if grep -q '"activated"[[:space:]]*:[[:space:]]*true' "$temp_data_dir/userApiKey.json"; then
        return 0  # Успех - логин завершен и активирован
    else
        return 1  # Логин есть, но не активирован
    fi
}

cleanup_processes() {
    echo_yellow ">> Cleaning up processes..."
    
    # Убиваем процесс обучения если запущен
    if [ -n "$TRAINING_PID" ] && kill -0 "$TRAINING_PID" 2>/dev/null; then
        kill -TERM "$TRAINING_PID" 2>/dev/null || true
        sleep 2
        kill -KILL "$TRAINING_PID" 2>/dev/null || true
    fi
    
    if [ -n "$TUNNEL_PID" ] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
        kill -TERM "$TUNNEL_PID" 2>/dev/null || true
        sleep 1
        kill -KILL "$TUNNEL_PID" 2>/dev/null || true
    fi
    
    if [ -n "$LOGIN_SERVER_PID" ] && kill -0 "$LOGIN_SERVER_PID" 2>/dev/null; then
        kill -TERM "$LOGIN_SERVER_PID" 2>/dev/null || true
        sleep 1
        kill -KILL "$LOGIN_SERVER_PID" 2>/dev/null || true
    fi
    
    pkill -f "yarn start" 2>/dev/null || true
    pkill -f "node.*modal-login" 2>/dev/null || true
    pkill -f "lt --port 3000" 2>/dev/null || true
    pkill -f "python.*code_gen_exp" 2>/dev/null || true
    
    sleep 1
}

cleanup() {
    echo ""
    echo_green ">> Shutting down RL Swarm..."
    
    cleanup_processes
    
    echo_green ">> RL Swarm stopped."
}

errnotify() {
    echo_red ">> An error was detected while running rl-swarm. See $ROOT/logs for full logs."
}

trap cleanup SIGINT SIGTERM
trap errnotify ERR

run_main() {
    cd "$ROOT_DIR"
    
    echo -e "\033[38;5;224m"
    cat << "EOF"
    ██████  ██            ███████ ██     ██  █████  ██████  ███    ███ 
    ██   ██ ██            ██      ██     ██ ██   ██ ██   ██ ████  ████ 
    ██████  ██      █████ ███████ ██  █  ██ ███████ ██████  ██ ████ ██ 
    ██   ██ ██                 ██ ██ ███ ██ ██   ██ ██   ██ ██  ██  ██ 
    ██   ██ ███████       ███████  ███ ███  ██   ██ ██   ██ ██      ██ 
                                                                        
    From Gensyn (Modified auto-install version)
    
EOF
    echo -e "$RESET_TEXT"
    
    mkdir -p "$ROOT/logs"
    
    if [ "$CONNECT_TO_TESTNET" = true ]; then
        echo_green ">> Setting up Node.js environment..."
        
        export NVM_DIR="$HOME/.nvm"
        
        if [ ! -d "$NVM_DIR" ]; then
            echo "Installing NVM..."
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
        fi
        
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
        
        REQUIRED_NODE_VERSION="20"
        CURRENT_NODE_VERSION=""
        
        if command -v node > /dev/null 2>&1; then
            CURRENT_NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
        fi
        
        if [ -z "$CURRENT_NODE_VERSION" ] || [ "$CURRENT_NODE_VERSION" -lt "$REQUIRED_NODE_VERSION" ]; then
            echo_yellow ">> Node.js version is too old or not installed. Installing Node.js 20 LTS..."
            nvm install 20
            nvm use 20
            nvm alias default 20
        else
            echo_green ">> Node.js version is adequate: $(node -v)"
        fi
        
        echo_yellow ">> Updating npm..."
        npm install -g npm@latest
        
        if ! command -v lt &> /dev/null; then
            echo_green ">> Installing localtunnel..."
            npm install -g localtunnel
        fi
        
        echo_yellow ">> Fetching external IPv4 address..."
        EXTERNAL_IPV4=$(get_external_ipv4)
        
        echo_green ">> Setting up login server..."
        cd modal-login
        
        if ! command -v yarn > /dev/null 2>&1; then
            if grep -qi "ubuntu" /etc/os-release 2> /dev/null || uname -r | grep -qi "microsoft"; then
                echo "Detected Ubuntu or WSL Ubuntu. Installing Yarn via npm..."
                npm install -g yarn
            else
                echo "Yarn not found. Installing Yarn globally with npm..."
                npm install -g yarn
            fi
        fi
        
        ENV_FILE="$ROOT"/modal-login/.env
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "3s/.*/SWARM_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
        else
            sed -i "3s/.*/SWARM_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
        fi
        
        yarn install --immutable
        
        if [ ! -d ".next" ] || [ ! -f ".next/BUILD_ID" ]; then
            echo "Building server"
            yarn build > "$ROOT/logs/yarn.log" 2>&1
        else
            echo_green ">> Server already built, skipping build step"
        fi
        
        yarn start >> "$ROOT/logs/yarn.log" 2>&1 &
        LOGIN_SERVER_PID=$!
        echo "Started server process: $LOGIN_SERVER_PID"
        sleep 5
        
        echo_green ">> Starting localtunnel..."
        lt --port 3000 > "$ROOT/logs/localtunel.log" 2>&1 &
        TUNNEL_PID=$!
        sleep 5
        
        TUNNEL_URL=$(grep -o 'https://[^[:space:]]*' "$ROOT/logs/localtunel.log" | head -1)
        
        cd ..
        
        if check_login_success; then
            echo_green ">> Found existing authorization (userData.json + userApiKey.json with activated: true)"
        else
            echo_green "========================================="
            echo_green "  LocalTunnel URL: $TUNNEL_URL"
            echo_green "  Password (IPv4): $EXTERNAL_IPV4"
            echo_green "========================================="
            echo_yellow ">> Waiting for login and activation..."
            
            while ! check_login_success; do
                sleep 5
            done
            
            echo_green ">> Login successful and activated!"
        fi
        
        ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json)
        echo_green ">> ORG_ID: $ORG_ID"
    fi
    
    echo_green ">> Getting requirements..."
    pip install --upgrade pip
    
    echo_green ">> Installing GenRL..."
    
    if ! command -v ollama > /dev/null 2>&1; then
        echo_green ">> Installing Ollama..."
        if [[ "$OSTYPE" == "darwin"* ]]; then
            if ! command -v brew > /dev/null 2>&1; then
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            fi
            brew install ollama
        else
            curl -fsSL https://ollama.com/install.sh | sh -s -- -y
        fi
    fi
    
    if ! ollama list > /dev/null 2>&1; then
        echo ">> Starting ollama server..."
        nohup ollama serve > /tmp/ollama.log 2>&1 &
        sleep 3
    fi
    
    pip install -r code_gen_exp/requirements.txt
    
    if [ ! -d "$ROOT/configs" ]; then
        mkdir "$ROOT/configs"
    fi
    
    if [ -f "$ROOT/configs/code-gen-swarm.yaml" ]; then
        if ! cmp -s "$ROOT/code_gen_exp/config/code-gen-swarm.yaml" "$ROOT/configs/code-gen-swarm.yaml"; then
            if [ -z "$GENSYN_RESET_CONFIG" ]; then
                echo_green ">> Found differences in code-gen-swarm.yaml. If you would like to reset to the default, set GENSYN_RESET_CONFIG to a non-empty value."
            else
                echo_green ">> Found differences in code-gen-swarm.yaml. Backing up existing config."
                mv "$ROOT/configs/code-gen-swarm.yaml" "$ROOT/configs/code-gen-swarm.yaml.bak"
                cp "$ROOT/code_gen_exp/config/code-gen-swarm.yaml" "$ROOT/configs/code-gen-swarm.yaml"
            fi
        fi
    else
        cp "$ROOT/code_gen_exp/config/code-gen-swarm.yaml" "$ROOT/configs/code-gen-swarm.yaml"
    fi
    
    echo_green ">> Done!"
    
    HUGGINGFACE_ACCESS_TOKEN="None"
    echo_green ">> HuggingFace upload: Disabled (automatic)"
    
    echo_green ">> Model selection: Automatic (default model from config)"
    
    if ! hf auth logout > /dev/null 2>&1; then
        unset HF_TOKEN
        unset HUGGING_FACE_HUB_TOKEN
        hf auth logout > /dev/null 2>&1 || true
    fi
    
    echo_green ">> Starting RL Swarm training..."
    echo_yellow ">> Press Ctrl+C to stop"
    echo_green "========================================="
    
    python -m code_gen_exp.runner.swarm_launcher \
        --config-path "$ROOT/code_gen_exp/config" \
        --config-name "code-gen-swarm.yaml" \
        2>&1 | tee "$ROOT/logs/swarm.log" &
    
    TRAINING_PID=$!
    
    wait $TRAINING_PID
    return $?
}

run_with_restart() {
    while [ $restart_count -lt $MAX_RESTART_COUNT ]; do
        echo_green ">> Starting RL Swarm (attempt $((restart_count + 1)))..."
        
        if run_main; then
            echo_green ">> Training completed successfully"
            break
        else
            EXIT_CODE=$?
            restart_count=$((restart_count + 1))
            echo_red ">> Error detected (Exit code: $EXIT_CODE). Restarting in 10 seconds... (attempt $restart_count)"
            
            cleanup_processes
            
            LOGIN_SERVER_PID=""
            TUNNEL_PID=""
            TRAINING_PID=""
            
            sleep 10
        fi
    done
}

run_with_restart
cleanup

exit 0
