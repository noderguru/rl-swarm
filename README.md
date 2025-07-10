### GenRL v0.5.3

Для стабильной работы нужна CUDA не ниже 12.6
```bash
tmux new-session -s gensyn
```
```bash
apt update && apt install -y python3-dev python3.12-venv build-essential curl git jq && \
git clone https://github.com/noderguru/rl-swarm.git /root/rl-swarm && \
cd /root/rl-swarm
```
```bash
python3 -m venv .venv
source .venv/bin/activate
```
```bash
./run_rl_swarm.sh
```
мониторинг загрузки карты в реальном режиме времени
```bash
watch -n 1 nvidia-smi
```

