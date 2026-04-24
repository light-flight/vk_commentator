# vk_commentator

Отправляет один или несколько комментариев в топик ВКонтакте в точно заданный момент с миллисекундной точностью. Каждый комментарий уходит из своего прогретого HTTPS-соединения в отдельном потоке.

## Структура

```
commentator.rb        основной скрипт (Ruby, VK API)
check_timestamp.rb    проверка server-side таймстемпа комментария
scripts/run_remote.sh обёртка: одной локальной командой стартует всё в tmux на VPS
scripts/push_env.sh   заливает локальный .env в ~/vk_commentator/.env на VPS
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

**Один раз** — подготовить VPS:

```bash
ssh user@vps
sudo apt install -y ruby git tmux
git clone https://github.com/light-flight/vk_commentator.git ~/vk_commentator
echo 'VK_TOKEN=vk1.a.XXXXX' > ~/vk_commentator/.env && chmod 600 ~/vk_commentator/.env
exit
```

(если репозиторий ещё не клонирован — `scripts/run_remote.sh` сам сделает `git clone`, но `.env` положить руками всё равно придётся.)

### Залить `.env` на VPS одной локальной командой

Если `.env` лежит у тебя локально, не надо ssh-иться и пересоздавать его на VPS — можно перезалить из проекта:

```bash
scripts/push_env.sh --host user@1.2.3.4
# или с другим путём / ключом:
scripts/push_env.sh --host user@1.2.3.4 -f .env.prod --ssh-opts '-i ~/.ssh/vk_vps'
```

Скрипт делает `mkdir -p ~/vk_commentator` (на случай первого раза до `git clone`), кладёт файл как `~/vk_commentator/.env` и сразу выставляет `chmod 600`. Полезно при ротации токена.

### Запуск одной командой с локальной машины

```bash
scripts/run_remote.sh \
  --host user@1.2.3.4 \
  -u 'https://vk.com/topic-236828463_57620976' \
  -t '08.05.26 22:00:00' \
  -m 'Комментарий 1' -m 'Комментарий 2'
```

Скрипт:
1. Делает `git pull` (или `clone`, если первый раз) в `~/vk_commentator` на VPS.
2. Копирует сообщения файлом — экранирование `$`, `'`, `"`, `` ` `` и т.д. внутри текста безопасно «из коробки».
3. Если tmux-сессия с таким именем уже есть — убивает и пересоздаёт (повторный запуск безопасен).
4. Запускает `commentator.rb` в detached `tmux`-сессии (по умолчанию `vk`), пишет вывод в `~/vk_commentator/last_run.log`.
5. Печатает первые строки лога локально — убедись, что строка `Scheduled:` показывает нужное время и `MSK`.

После этого SSH-сессия и локальный терминал больше не нужны — `tmux` на VPS доживёт до момента X. Когда `commentator.rb` отработает, tmux-сессия закрывается сама; полный лог остаётся в `last_run.log`.

Полезное:
- `scripts/run_remote.sh -h` — все флаги (`--session`, `--ssh-opts`, `-f messages.txt`).
- Live-вывод: `ssh user@1.2.3.4 -t tmux attach -t vk` (detach: `Ctrl+b d`).
- После завершения — лог запуска: `ssh user@1.2.3.4 cat ~/vk_commentator/last_run.log`.
- Прервать вручную: `ssh user@1.2.3.4 tmux kill-session -t vk`.

### Ручной fallback (если wrapper недоступен)

```bash
ssh user@vps
cd ~/vk_commentator && git pull
tmux new -s vk
ruby commentator.rb -u '<url>' -t '08.05.26 22:00:00' -m '...' -m '...'
# Ctrl+b d, exit
```

## Если что-то пошло не так

- **`VK ERROR 5`** — токен протух/отозван. [vk.com/settings?act=apps](https://vk.com/settings?act=apps) → отозвать → перевыпустить.
- **`VK ERROR 9: Flood control`** — сделать сообщения уникальнее (хотя бы добавить нулевой ширины пробел).
- **API упал** — DevTools fallback: открыть страницу топика, в Console вставить [js/click_direct.js](js/click_direct.js), вызвать `click('22:00:00')`.
- **Один комментарий через сырой сокет:** `bash bash/commentator.sh 'msg' '08.05.26 22:00:00' '<url>'`.
