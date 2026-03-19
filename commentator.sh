#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
while IFS='=' read -r k v; do [[ "$k" && "$k" != \#* ]] && export "$k=$v"; done < .env

[[ "$TOPIC_URL" =~ topic-([0-9]+)_([0-9]+) ]]
GID=${BASH_REMATCH[1]} TID=${BASH_REMATCH[2]}

(( $# >= 2 )) || { echo "Usage: $0 'msg' 'DD.MM.YY HH:MM:SS'" >&2; exit 1; }

ENC=$(printf '%s' "$1" | xxd -p | tr -d '\n' | tr 'a-f' 'A-F' | sed 's/../%&/g')
TS=$(date -j -f '%d.%m.%y %H:%M:%S' "$2" +%s)
NOW=$(date +%s)
(( TS > NOW )) || { echo "In the past" >&2; exit 1; }

BODY="group_id=$GID&topic_id=$TID&message=$ENC&access_token=$VK_TOKEN&v=5.199"
REQ=$(printf 'POST /method/board.createComment HTTP/1.1\r\nHost: api.vk.com\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' ${#BODY} "$BODY")

PIPE=/tmp/vk_$$
mkfifo "$PIPE"; trap 'rm -f "$PIPE"' EXIT

echo "[*] Fire at $(date -j -f %s "$TS" +%H:%M:%S)"

D=$((TS - NOW))
(( D > 5 )) && { echo "[*] Sleep $((D-5))s"; sleep $((D-5)); }

openssl s_client -connect api.vk.com:443 -servername api.vk.com -quiet 2>/dev/null <"$PIPE" &
exec 3>"$PIPE"; sleep 0.5
echo "[*] TLS ready"

while (( $(date +%s) < TS )); do :; done

printf '%s' "$REQ" >&3; exec 3>&-
echo "[*] Sent at $(date +%H:%M:%S)"
wait 2>/dev/null
