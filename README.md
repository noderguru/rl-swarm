<img width="736" height="434" alt="image" src="https://github.com/user-attachments/assets/22331fd5-9e18-46a9-b898-51dacb4cd47d" />


1) полный автоинсталл в tmux без докера
2) логин через localtunel (в логах покажет линк и пароль)
3) при первом удачном логине файлы авторизации не удаляются после остановки или ошибки в скрипте (не надо заново логинится как раньше)
4) при любой ошибке и падении скрипта (включая OOM) = авторестарт
5) не требует ввода HF токена
6) модель автоматом выбирается дефолтная в зависимости от производительности сервака или GPU
7) автоматом выставлено участие в AI Prediction Market

--------------------------------------------------
## Обнова v0.6.4
```bash
tmux attach -t gensyn
```
```bash
deactivate
```
```bash
rm -rf /root/.cache
```
```bash
rm -rf .venv && git pull && python3 -m venv .venv && source .venv/bin/activate
```

===================================================
### GenRL v0.6.4
===================================================

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

=======================================================================

мониторинг загрузки карты в реальном режиме времени
```bash
watch -n 1 nvidia-smi
```
======================================================================

Для слабеньких видео
```bash
FILE="/root/rl-swarm/rgym_exp/config/rg-swarm.yaml"; \
sed -i -e '17s/^[[:space:]]*num_generations:.*/  num_generations: 2/' \
       -e '18s/^[[:space:]]*num_transplant_trees:.*/  num_transplant_trees: 1/' \
       -e '20s/^[[:space:]]*dtype:.*/  dtype: '\''bfloat16'\''/' \
       -e '85s/^[[:space:]]*num_train_samples:.*/    num_train_samples: 1/' \
       -e '96s/^[[:space:]]*beam_size:.*/    beam_size: 20/' "$FILE"; \
grep -q 'enable_gradient_checkpointing' "$FILE" || sed -i '21i \  enable_gradient_checkpointing: true' "$FILE"; \
grep -q 'PYTORCH_CUDA_ALLOC_CONF' /root/rl-swarm/run_rl_swarm-exp.sh || \
sed -i '1a export PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True,max_split_size_mb:128"' /root/rl-swarm/run_rl_swarm-exp.sh
```
```bash
bash run_rl_swarm-exp.sh
```


