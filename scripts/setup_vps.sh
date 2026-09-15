#!/usr/bin/env bash
# Полная idempotent-настройка VPS под Telegram-бота одной локальной командой:
# apt (ruby git chrony), репо в ~/vk_commentator, systemd unit vk-bot, запуск.
# .env не трогает — заливай отдельно: scripts/push_env.sh --host ...
#
# Требования: ssh по ключу, пользователь с sudo без пароля (или root).

set -euo pipefail

REPO_URL='https://github.com/light-flight/vk_commentator.git'
BRANCH='main'

usage() {
  cat <<'USAGE'
Usage: scripts/setup_vps.sh --host user@ip [--branch main] [--ssh-opts '...']

Что делает на VPS:
  1. apt install -y ruby git chrony; включает chrony (NTP-синхронизация часов)
  2. clone/pull репо в ~/vk_commentator
  3. ставит /etc/systemd/system/vk-bot.service, enable + restart
  4. печатает статус сервиса и хвост журнала

После: scripts/push_env.sh --host user@ip  (если .env ещё не залит) и
       scripts/deploy.sh --host user@ip    (перезапуск после push_env / обновлений)
USAGE
}

abort() { echo "Error: $*" >&2; exit 1; }

HOST=''
SSH_OPTS=''

while (( $# > 0 )); do
  case "$1" in
    --host)     HOST="${2:-}"; shift 2 ;;
    --branch)   BRANCH="${2:-}"; shift 2 ;;
    --ssh-opts) SSH_OPTS="${2:-}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "Unknown arg: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$HOST" ]] || { usage >&2; abort '--host is required'; }
[[ "$HOST"   =~ ^[A-Za-z0-9_.@-]+$ ]] || abort "host содержит недопустимые символы: $HOST"
[[ "$BRANCH" =~ ^[A-Za-z0-9_./-]+$ ]] || abort "branch содержит недопустимые символы: $BRANCH"

read -ra SSH_OPTS_ARR <<< "$SSH_OPTS"

echo "==> Настройка ${HOST} (branch ${BRANCH})"
ssh ${SSH_OPTS_ARR[@]+"${SSH_OPTS_ARR[@]}"} "$HOST" bash -s <<EOF
set -e
SUDO=''
[ "\$(id -u)" -eq 0 ] || SUDO='sudo -n'

echo "  - apt: ruby git chrony"
\$SUDO apt-get update -qq
\$SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ruby git chrony >/dev/null
\$SUDO systemctl enable --now chrony >/dev/null 2>&1 || \$SUDO systemctl enable --now chronyd >/dev/null 2>&1 || true
\$SUDO timedatectl set-timezone Europe/Moscow 2>/dev/null || true

REMOTE_DIR="\$HOME/vk_commentator"
if [ -d "\$REMOTE_DIR/.git" ]; then
  echo "  - git pull в \$REMOTE_DIR"
  cd "\$REMOTE_DIR"
  git fetch -q origin ${BRANCH}
  git checkout -q -B ${BRANCH} origin/${BRANCH}
else
  echo "  - git clone в \$REMOTE_DIR"
  git clone -q --branch ${BRANCH} ${REPO_URL} "\$REMOTE_DIR"
  cd "\$REMOTE_DIR"
fi
mkdir -p jobs

echo "  - systemd unit vk-bot.service (user=\$USER home=\$HOME)"
sed -e "s|__USER__|\$USER|g" -e "s|__HOME__|\$HOME|g" deploy/vk-bot.service.tpl \
  | \$SUDO tee /etc/systemd/system/vk-bot.service >/dev/null
\$SUDO systemctl daemon-reload
\$SUDO systemctl enable vk-bot >/dev/null 2>&1

if [ -f .env ]; then
  \$SUDO systemctl restart vk-bot
  sleep 2
  echo
  \$SUDO systemctl --no-pager --lines=0 status vk-bot || true
  echo "--- journal ---"
  \$SUDO journalctl -u vk-bot --no-pager -n 15 || true
else
  echo
  echo "  ! .env отсутствует — сервис установлен, но не запущен."
  echo "    Залей: scripts/push_env.sh --host ${HOST}   затем   scripts/deploy.sh --host ${HOST}"
fi

echo
echo "  - ruby: \$(ruby -v)"
echo "  - ntp:  \$(chronyc tracking 2>/dev/null | grep -E 'System time|Leap status' | tr -s ' ' | paste -sd ';' - || echo 'n/a')"
EOF

echo
echo "==> Готово."
