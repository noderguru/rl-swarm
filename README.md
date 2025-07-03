### GenRL v0.5.1

Для стабильной работы нужна CUDA не ниже 12.6
```bash
tmux new-session -s gensyn
```
```bash
apt update && apt install -y python3-dev build-essential curl git
```
```bash
git clone https://github.com/noderguru/rl-swarm.git
cd /root/rl-swarm
```
```bash
python3 -m venv .venv
source .venv/bin/activate
```
```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
export NVM_DIR="$HOME/.nvm"
source "$NVM_DIR/nvm.sh"
```
```bash
nvm install 20.18.0
nvm use 20.18.0
```
```bash
./run_rl_swarm.sh
```
Если не хватает 15 секунд на старт
```bash
sed -i "s/startup_timeout: float = 15/startup_timeout: float = 120/" $(find $VIRTUAL_ENV/lib -type f -name p2p_daemon.py)
```

когда запросит логин

![image](https://github.com/user-attachments/assets/662fb432-d932-430a-b9df-c281c274c379)

открываем еще одну вкладку в терминале текущего сервака
```bash
npm install -g localtunnel
lt --port 3000
```
выдаст ссылку, переходим по ней и в поле пароль вписываем IP сервака c которого запустили команду. 
посмотреть ip сервака
```bash
curl -4 ifconfig.me
```
если надо еще раз залогинится
```bash
lt --port 3000
```
мониторинг загрузки карты в реальном режиме времени
```bash
watch -n 1 nvidia-smi
```

![image](https://github.com/user-attachments/assets/ffc3a3bc-889f-4635-a5a5-5a3d4ca2202f)

