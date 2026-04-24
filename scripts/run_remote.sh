#!/usr/bin/env bash
# Запускает commentator.rb в detached tmux на удалённом VPS одной локальной командой.
#
# Зависимости на VPS: ssh, ruby, git, tmux. Файл .env с VK_TOKEN должен лежать
# в ~/vk_commentator/ (создаётся вручную после первого clone).

set -euo pipefail

REPO_URL='https://github.com/light-flight/vk_commentator.git'
REMOTE_DIR='~/vk_commentator'

usage() {
  cat <<'USAGE'
Usage: scripts/run_remote.sh --host user@ip -u <topic_url> -t 'DD.MM.YY HH:MM:SS' (-m <msg> ... | -f <file>) [options]

Required:
  --host user@ip            SSH-цель (например vk@1.2.3.4)
  -u, --url <url>           VK topic URL (https://vk.com/topic-XXX_YYY)
  -t, --time '...'          Время в формате 'DD.MM.YY HH:MM:SS' (всегда МСК)
  -m, --message <msg>       Текст комментария (можно повторять)
  -f, --messages-file <p>   Альтернатива -m: файл, по строке на сообщение

Optional:
  --session NAME            Имя tmux-сессии (по умолчанию: vk)
  --force                   Если tmux-сессия с таким именем уже есть — убить её
  --ssh-opts '...'          Доп. опции для ssh/scp (например '-i ~/.ssh/vk_vps')
  -h, --help                Показать эту справку

Пример:
  scripts/run_remote.sh \
    --host vk@1.2.3.4 \
    -u 'https://vk.com/topic-236828463_57620976' \
    -t '08.05.26 22:00:00' \
    -m 'Сообщение 1' -m 'Сообщение 2'
USAGE
}

abort() { echo "Error: $*" >&2; exit 1; }

HOST=''
URL=''
TARGET_TIME=''
MESSAGES_FILE=''
SESSION='vk'
FORCE=0
SSH_OPTS=''
MESSAGES=()

while (( $# > 0 )); do
  case "$1" in
    --host)             HOST="${2:-}"; shift 2 ;;
    -u|--url)           URL="${2:-}"; shift 2 ;;
    -t|--time)          TARGET_TIME="${2:-}"; shift 2 ;;
    -m|--message)       MESSAGES+=("${2:-}"); shift 2 ;;
    -f|--messages-file) MESSAGES_FILE="${2:-}"; shift 2 ;;
    --session)          SESSION="${2:-}"; shift 2 ;;
    --force)            FORCE=1; shift ;;
    --ssh-opts)         SSH_OPTS="${2:-}"; shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *)                  echo "Unknown arg: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$HOST"        ]] || { usage >&2; abort '--host is required'; }
[[ -n "$URL"         ]] || { usage >&2; abort '-u/--url is required'; }
[[ -n "$TARGET_TIME" ]] || { usage >&2; abort '-t/--time is required'; }

if [[ -n "$MESSAGES_FILE" ]]; then
  [[ -f "$MESSAGES_FILE" ]] || abort "messages file not found: $MESSAGES_FILE"
  while IFS= read -r line; do
    [[ -n "$line" ]] && MESSAGES+=("$line")
  done < "$MESSAGES_FILE"
fi

(( ${#MESSAGES[@]} > 0 )) || abort 'хотя бы одно сообщение (-m или -f) обязательно'

[[ "$URL"         =~ ^https?://([a-z0-9.-]+\.)?vk\.com/topic-[0-9]+_[0-9]+ ]] \
  || abort "URL не похож на VK topic: $URL"
[[ "$TARGET_TIME" =~ ^[0-9]{2}\.[0-9]{2}\.[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] \
  || abort "время должно быть в формате 'DD.MM.YY HH:MM:SS', получено: $TARGET_TIME"
[[ "$SESSION"     =~ ^[A-Za-z0-9_.-]+$ ]] \
  || abort "session-имя содержит недопустимые символы: $SESSION"
[[ "$HOST"        =~ ^[A-Za-z0-9_.@-]+$ ]] \
  || abort "host содержит недопустимые символы: $HOST"

for v in "$URL" "$TARGET_TIME" "$SESSION" "$HOST"; do
  [[ "$v" != *"'"* && "$v" != *'"'* && "$v" != *'`'* && "$v" != *'$'* && "$v" != *'\'* ]] \
    || abort "shell-метасимвол в служебном параметре запрещён: $v"
done

read -ra SSH_OPTS_ARR <<< "$SSH_OPTS"

LOCAL_TMP="$(mktemp -t vk_messages.XXXXXX)"
trap 'rm -f "$LOCAL_TMP"' EXIT
for m in "${MESSAGES[@]}"; do
  printf '%s\n' "$m" >> "$LOCAL_TMP"
done

echo "==> Готовим запуск на ${HOST}"
echo "    URL:       ${URL}"
echo "    Time:      ${TARGET_TIME} (МСК)"
echo "    Messages:  ${#MESSAGES[@]} шт."
echo "    Session:   ${SESSION}${FORCE:+ (force=1)}"
echo

echo "==> scp messages → ${HOST}:/tmp/vk_messages.txt"
scp ${SSH_OPTS_ARR[@]+"${SSH_OPTS_ARR[@]}"} -q "$LOCAL_TMP" "${HOST}:/tmp/vk_messages.txt"

REMOTE_RUBY_CMD="cd ${REMOTE_DIR} && ruby commentator.rb -u '${URL}' -t '${TARGET_TIME}' -f messages.txt"

echo "==> Bootstrap на VPS (clone/pull, .env check, tmux start)"
ssh ${SSH_OPTS_ARR[@]+"${SSH_OPTS_ARR[@]}"} "$HOST" bash -s <<EOF
set -e

for tool in tmux ruby git; do
  command -v "\$tool" >/dev/null 2>&1 || { echo "ERROR: '\$tool' не установлен на VPS. apt install -y ruby git tmux" >&2; exit 1; }
done

if [ -d ${REMOTE_DIR} ]; then
  echo "  - ${REMOTE_DIR} уже есть → git pull"
  cd ${REMOTE_DIR}
  git pull --ff-only
else
  echo "  - клонирую ${REPO_URL} → ${REMOTE_DIR}"
  git clone ${REPO_URL} ${REMOTE_DIR}
  cd ${REMOTE_DIR}
fi

if [ ! -f .env ]; then
  echo "ERROR: ${REMOTE_DIR}/.env отсутствует. Создай: echo 'VK_TOKEN=vk1.a.XXXXX' > ${REMOTE_DIR}/.env && chmod 600 ${REMOTE_DIR}/.env" >&2
  exit 1
fi

mv /tmp/vk_messages.txt ./messages.txt

if tmux has-session -t ${SESSION} 2>/dev/null; then
  if [ "${FORCE}" = "1" ]; then
    echo "  - tmux-сессия '${SESSION}' существует → убиваю (--force)"
    tmux kill-session -t ${SESSION}
  else
    echo "ERROR: tmux-сессия '${SESSION}' уже существует. Прибей вручную (tmux kill-session -t ${SESSION}) или запусти с --force." >&2
    exit 1
  fi
fi

echo "  - tmux new-session -d -s ${SESSION}"
tmux new-session -d -s ${SESSION} "${REMOTE_RUBY_CMD}; echo; echo '--- скрипт завершился, нажми Enter чтобы закрыть окно ---'; read"

sleep 2
echo
echo "--- tmux pane (${SESSION}) ---"
tmux capture-pane -t ${SESSION} -p
echo "--- /tmux pane ---"
EOF

cat <<HINT

==> Готово. Скрипт работает в tmux на ${HOST}.

Подключиться позже и посмотреть лог:
  ssh ${SSH_OPTS} ${HOST} -t tmux attach -t ${SESSION}

Убить запуск (если что-то пошло не так):
  ssh ${SSH_OPTS} ${HOST} tmux kill-session -t ${SESSION}

Проверь, что в выводе выше строка 'Scheduled:' показывает нужное время в MSK.
HINT
