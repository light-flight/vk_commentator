# vk_commentator

Отправляет один или несколько комментариев в топик ВКонтакте в точно заданный момент с миллисекундной точностью. Каждый комментарий уходит из своего прогретого HTTPS-соединения в отдельном потоке с VPS в МСК/СПб (ping 5-15 мс до VK).

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

## Подготовка

**VPS обязателен.** В МСК/СПб (Selectel/Timeweb, ~150 ₽/мес) — без него пинг до VK 50-150 мс и миллисекундная точность недостижима. SSH по ключу + sudo для `apt`.

**Токен.** Открыть в браузере:
```
https://oauth.vk.com/authorize?client_id=2685278&scope=offline,wall,groups&redirect_uri=https://oauth.vk.com/blank.html&display=page&response_type=token&revoke=1
```
После согласия URL станет `.../blank.html#access_token=vk1.a.XXXXX&...`. Скопировать **только** значение токена (без `access_token=`) в локальный `.env`:
```
VK_TOKEN=vk1.a.XXXXX
```
`expires_in=0` — бессрочный (scope `offline`).

## Запуск

Считаем VPS голым (только что выкатили / `rm -rf ~/vk_commentator` / новый инстанс). Из корня проекта локально:

```bash
# 1. Зависимости на VPS (idempotent — на уже настроенном инстансе ничего не делает)
ssh user@1.2.3.4 'sudo apt update && sudo apt install -y ruby git tmux'

# 2. Залить локальный .env → ~/vk_commentator/.env (chmod 600)
scripts/push_env.sh --host user@1.2.3.4

# 3. Запустить commentator.rb в detached tmux-сессии 'vk' на VPS
scripts/run_remote.sh \
  --host user@1.2.3.4 \
  -u 'https://vk.com/topic-236828463_57620976' \
  -t '08.05.26 22:00:00' \
  -m 'Комментарий 1' -m 'Комментарий 2'
```

`run_remote.sh` сам поднимает репо в `~/vk_commentator` (`git init` + `fetch` + `checkout` если `.git` нет, `git pull` если есть; `.env` не трогает), копирует сообщения файлом (экранирование `$`, `'`, `"`, `` ` `` внутри текста безопасно), пересоздаёт tmux-сессию если уже была, запускает `commentator.rb` с логом в `~/vk_commentator/last_run.log` и печатает первые строки локально.

После шага 3 локальный терминал не нужен — tmux на VPS доживёт до момента X и закроется сам.

**Сразу после шага 3 проверить в выводе**, что строка `Scheduled:` показывает `MSK` и ожидаемое локальное время. `-t` всегда трактуется как `Europe/Moscow` независимо от системной таймзоны (страховка от VPS в UTC). Переопределить: `TZ='Asia/Tokyo' ...` (но обычно не нужно).

**Холостой прогон (опц.).** Те же три шага, но `-t` через 2-3 минуты, `-u` свой топик. Если не хочешь постить — добавь `--dry-run` (прогреет соединения и подождёт, но запрос не отправит). Без `--dry-run` — настоящий комментарий, server-side таймстемп проверяется через `ssh user@1.2.3.4 'cd ~/vk_commentator && ruby check_timestamp.rb "<url>?post=<comment_id>"'`.

### Полезное

- `scripts/run_remote.sh -h` — все флаги (`--session`, `--ssh-opts '-i ~/.ssh/vk_vps'`, `-f messages.txt`).
- Live-вывод: `ssh user@1.2.3.4 -t tmux attach -t vk` (detach: `Ctrl+b d`).
- Полный лог: `ssh user@1.2.3.4 cat ~/vk_commentator/last_run.log`.
- Прервать: `ssh user@1.2.3.4 tmux kill-session -t vk`.
- Ротация токена — только шаг 2 (`push_env.sh`).

### Ручной fallback (если wrapper недоступен)

```bash
ssh user@1.2.3.4
cd ~/vk_commentator && git pull
tmux new -s vk
ruby commentator.rb -u '<url>' -t '08.05.26 22:00:00' -m '...' -m '...'
# Ctrl+b d, exit
```

## Если что-то пошло не так

- **`VK ERROR 5`** — токен протух/отозван. [vk.com/settings?act=apps](https://vk.com/settings?act=apps) → отозвать → перевыпустить → повторить шаг 2.
- **`VK ERROR 9: Flood control`** — сделать сообщения уникальнее (хотя бы добавить нулевой ширины пробел).
- **API упал** — DevTools fallback: открыть страницу топика, в Console вставить [js/click_direct.js](js/click_direct.js), вызвать `click('22:00:00')`.
- **Один комментарий через сырой сокет на VPS:** `bash bash/commentator.sh 'msg' '08.05.26 22:00:00' '<url>'`.
- **VPS отвалился, времени мало** — локально, в tmux: `ruby commentator.rb -u '<url>' -t '...' -m '...'`. Пинг 50-150 мс, но лучше промазать на 100 мс, чем не выстрелить.
