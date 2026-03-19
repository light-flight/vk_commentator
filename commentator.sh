#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export $(grep -v '^#' .env | xargs)
[[ $TOPIC_URL =~ topic-([0-9]+)_([0-9]+) ]]
(( $# >= 2 )) || { echo "Usage: $0 msg 'DD.MM.YY HH:MM:SS'" >&2; exit 1; }
TS=$(date -j -f '%d.%m.%y %H:%M:%S' "$2" +%s)
(( TS > $(date +%s) )) || { echo "In the past" >&2; exit 1; }
BODY="group_id=${BASH_REMATCH[1]}&topic_id=${BASH_REMATCH[2]}&message=$(printf '%s' "$1"|xxd -p|tr -d '\n'|sed 's/../%&/g')&access_token=$VK_TOKEN&v=5.199"
REQ=$(printf 'POST /method/board.createComment HTTP/1.1\r\nHost: api.vk.com\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' ${#BODY} "$BODY")
P=/tmp/vk_$$; mkfifo "$P"; trap 'rm -f "$P"' EXIT
D=$((TS-$(date +%s))); (( D > 5 )) && sleep $((D-5))
openssl s_client -connect api.vk.com:443 -servername api.vk.com -quiet 2>/dev/null <"$P" &
exec 3>"$P"; sleep .5
perl -MTime::HiRes -e 'Time::HiRes::sleep('$TS'-Time::HiRes::time())'
printf '%s' "$REQ" >&3; exec 3>&-
wait 2>/dev/null
