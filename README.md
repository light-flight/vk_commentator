# vk_commentator

Отправляет один или несколько комментариев в топик ВКонтакте в точно заданный момент с миллисекундной точностью. Каждый комментарий уходит из своего прогретого HTTPS-соединения в отдельном потоке.

## Структура

```
commentator.rb        основной скрипт (Ruby, VK API)
check_timestamp.rb    проверка server-side таймстемпа комментария
.env                  VK_TOKEN
js/click*.js          DevTools fallback
bash/commentator.sh   fallback на raw TLS-сокете (1 сообщение)
```

## Подготовка (один раз)

**Токен.** Открыть в браузере:
```
https://oauth.vk.com/authorize?client_id=2685278&scope=offline,wall,groups&redirect_uri=https://oauth.vk.com/blank.html&display=page&response_type=token&revoke=1
```
После согласия URL станет `.../blank.html#access_token=vk1.a.XXXXX&...`. Скопировать **только** значение токена (без `access_token=`) в `.env`:
```
VK_TOKEN=vk1.a.XXXXX
```
`expires_in=0` — бессрочный (scope `offline`).

## Использование

```bash
ruby commentator.rb \
  -u 'https://vk.com/topic-236828463_57620976' \
  -t '08.05.26 22:00:00' \
  -m 'Комментарий 1' -m 'Комментарий 2' -m 'Комментарий 3'
```

Альтернативы: `-f messages.txt` (по строке на сообщение), `--test` (разрешить ближайшее/прошлое время), `--dry-run` (не отправлять). Полный help: `ruby commentator.rb --help`.

Время в `-t` всегда трактуется как **МСК** (`Europe/Moscow`) — независимо от системной таймзоны (важно для VPS в UTC). Переопределить можно так: `TZ='Asia/Tokyo' ruby commentator.rb ...`.

## Чек-лист на день X

1. **Часы.** Mac: `sudo sntp -sS time.apple.com`. Linux: `timedatectl status` → `System clock synchronized: yes`.
2. **Тестовый прогон** на своём топике, время через 2 минуты:
   ```bash
   TS=$(date -v+2M '+%d.%m.%y %H:%M:%S')   # Mac; Linux: date -d '+2 min' '+%d.%m.%y %H:%M:%S'
   ruby commentator.rb -u <тестовый_url> -t "$TS" -m 'test'
   ```
   Проверить таймстемп: `ruby check_timestamp.rb '<url>?post=<comment_id>'`.
3. **Боевой запуск за 1-3 часа до X в `tmux`** (переживёт закрытие терминала и SSH-disconnect):
   ```bash
   tmux new -s vk
   ruby commentator.rb -u '<url>' -t '08.05.26 22:00:00' -m '...' -m '...'
   # detach: Ctrl+b d
   ```
   Вернуться: `tmux attach -t vk`. **Сразу после запуска проверить в логе**, что строка `Scheduled:` показывает `MSK` и ожидаемое локальное время — это страховка от расхождения таймзоны на VPS.
4. **После 22:00:00** — глазами в топик + `check_timestamp.rb` для server-side таймстемпов.

## VPS (опционально)

Для ping 5-15 мс до VK вместо 50-150 — VPS в МСК/СПб (Selectel/Timeweb, ~150 ₽/мес).

```bash
ssh user@vps
sudo apt install -y ruby git tmux
git clone <repo> vk_commentator && cd vk_commentator
echo 'VK_TOKEN=vk1.a.XXXXX' > .env && chmod 600 .env

tmux new -s vk
ruby commentator.rb -u '<url>' -t '08.05.26 22:00:00' -m '...' -m '...'
# Ctrl+b d, exit — tmux-сессия живёт сама
```

Вернуться позже: `ssh user@vps`, `tmux attach -t vk`.

## Если что-то пошло не так

- **`VK ERROR 5`** — токен протух/отозван. [vk.com/settings?act=apps](https://vk.com/settings?act=apps) → отозвать → перевыпустить.
- **`VK ERROR 9: Flood control`** — сделать сообщения уникальнее (хотя бы добавить нулевой ширины пробел).
- **API упал** — DevTools fallback: открыть страницу топика, в Console вставить [js/click_direct.js](js/click_direct.js), вызвать `click('22:00:00')`.
- **Один комментарий через сырой сокет:** `bash bash/commentator.sh 'msg' '08.05.26 22:00:00' '<url>'`.
