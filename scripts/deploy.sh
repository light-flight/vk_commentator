#!/usr/bin/env bash
# Обновляет код на VPS (git pull) и перезапускает бота. Запущенные задания
# (процессы commentator.rb) не трогает — они переживают рестарт (KillMode=process),
# бот при старте переподхватывает их.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/deploy.sh --host user@ip [--ssh-opts '...'] [--no-pull]

  --no-pull   только перезапустить сервис (например, после push_env.sh)
USAGE
}

abort() { echo "Error: $*" >&2; exit 1; }

HOST=''
SSH_OPTS=''
PULL=1

while (( $# > 0 )); do
  case "$1" in
    --host)     HOST="${2:-}"; shift 2 ;;
    --ssh-opts) SSH_OPTS="${2:-}"; shift 2 ;;
    --no-pull)  PULL=0; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "Unknown arg: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$HOST" ]] || { usage >&2; abort '--host is required'; }
[[ "$HOST" =~ ^[A-Za-z0-9_.@-]+$ ]] || abort "host содержит недопустимые символы: $HOST"

read -ra SSH_OPTS_ARR <<< "$SSH_OPTS"

echo "==> Deploy на ${HOST}"
ssh ${SSH_OPTS_ARR[@]+"${SSH_OPTS_ARR[@]}"} "$HOST" bash -s <<EOF
set -e
SUDO=''
[ "\$(id -u)" -eq 0 ] || SUDO='sudo -n'
cd "\$HOME/vk_commentator"
[ -f .env ] || { echo "ERROR: .env отсутствует — scripts/push_env.sh --host ${HOST}" >&2; exit 1; }
if [ "${PULL}" = "1" ]; then
  echo "  - git pull --ff-only"
  git pull -q --ff-only
  echo "  - HEAD: \$(git log --oneline -1)"
fi
echo "  - systemctl restart vk-bot"
\$SUDO systemctl restart vk-bot
sleep 2
\$SUDO systemctl --no-pager --lines=0 status vk-bot || true
echo "--- journal ---"
\$SUDO journalctl -u vk-bot --no-pager -n 10 || true
EOF

echo
echo "==> Готово. Логи: ssh ${HOST} journalctl -u vk-bot -f"
