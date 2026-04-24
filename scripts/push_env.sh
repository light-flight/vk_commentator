#!/usr/bin/env bash
# Заливает локальный .env (с VK_TOKEN) в ~/vk_commentator/.env на VPS и
# выставляет chmod 600. Безопасно перезаписывает существующий файл.

set -euo pipefail

REMOTE_DIR='~/vk_commentator'

usage() {
  cat <<'USAGE'
Usage: scripts/push_env.sh --host user@ip [-f <local_env>] [--ssh-opts '...']

Required:
  --host user@ip            SSH-цель (например vk@1.2.3.4)

Optional:
  -f, --file <path>         Локальный .env (по умолчанию: ./.env)
  --ssh-opts '...'          Доп. опции для ssh/scp (например '-i ~/.ssh/vk_vps')
  -h, --help                Показать эту справку

Что делает:
  1. Проверяет, что локальный файл существует и непустой.
  2. Через scp копирует его во временный файл на VPS.
  3. Через ssh: mkdir -p ~/vk_commentator, mv во временный → .env, chmod 600.

Пример:
  scripts/push_env.sh --host vk@1.2.3.4
  scripts/push_env.sh --host vk@1.2.3.4 -f .env.prod --ssh-opts '-i ~/.ssh/vk_vps'
USAGE
}

abort() { echo "Error: $*" >&2; exit 1; }

HOST=''
LOCAL_ENV='.env'
SSH_OPTS=''

while (( $# > 0 )); do
  case "$1" in
    --host)        HOST="${2:-}"; shift 2 ;;
    -f|--file)     LOCAL_ENV="${2:-}"; shift 2 ;;
    --ssh-opts)    SSH_OPTS="${2:-}"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)             echo "Unknown arg: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$HOST"      ]] || { usage >&2; abort '--host is required'; }
[[ -f "$LOCAL_ENV" ]] || abort "локальный env-файл не найден: $LOCAL_ENV"
[[ -s "$LOCAL_ENV" ]] || abort "локальный env-файл пустой: $LOCAL_ENV"

[[ "$HOST" =~ ^[A-Za-z0-9_.@-]+$ ]] || abort "host содержит недопустимые символы: $HOST"
for v in "$HOST"; do
  [[ "$v" != *"'"* && "$v" != *'"'* && "$v" != *'`'* && "$v" != *'$'* && "$v" != *'\'* ]] \
    || abort "shell-метасимвол в служебном параметре запрещён: $v"
done

grep -q '^VK_TOKEN=' "$LOCAL_ENV" \
  || echo "Warning: в '$LOCAL_ENV' нет строки 'VK_TOKEN=...' — заливаю как есть" >&2

read -ra SSH_OPTS_ARR <<< "$SSH_OPTS"

REMOTE_TMP="/tmp/vk_env_$$.$RANDOM"

echo "==> scp ${LOCAL_ENV} → ${HOST}:${REMOTE_TMP}"
scp ${SSH_OPTS_ARR[@]+"${SSH_OPTS_ARR[@]}"} -q "$LOCAL_ENV" "${HOST}:${REMOTE_TMP}"

echo "==> Устанавливаю в ${REMOTE_DIR}/.env (chmod 600)"
ssh ${SSH_OPTS_ARR[@]+"${SSH_OPTS_ARR[@]}"} "$HOST" bash -s <<EOF
set -e
mkdir -p ${REMOTE_DIR}
mv "${REMOTE_TMP}" ${REMOTE_DIR}/.env
chmod 600 ${REMOTE_DIR}/.env
echo "  - $(wc -c < ${REMOTE_DIR}/.env) bytes, $(stat -c '%a %U:%G' ${REMOTE_DIR}/.env 2>/dev/null || stat -f '%Lp %Su:%Sg' ${REMOTE_DIR}/.env)"
EOF

echo
echo "==> Готово. ${HOST}:${REMOTE_DIR}/.env обновлён."
