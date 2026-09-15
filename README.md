# vk_commentator

Отправляет один или несколько комментариев в обсуждение (топик) ВКонтакте в точно заданный момент с миллисекундной точностью. Задания ставятся с телефона через Telegram-бота, стреляет VPS: каждый комментарий уходит из своего прогретого HTTPS-соединения, с упреждением `RTT/2 + lead_ms`, чтобы запрос *пришёл* на сервер VK ровно в цель.

## Структура

```
bot.rb                     Telegram-бот: мастер заданий, очередь, отчёты (systemd на VPS)
commentator.rb             CLI: один запуск = одно задание (его и спавнит бот)
check_timestamp.rb         server-side таймстемп комментария
lib/vk_commentator/        Config, VkClient, Scheduler, Runner, Telegram, JobStore, JobManager, Bot
deploy/vk-bot.service.tpl  шаблон systemd unit
scripts/setup_vps.sh       полная настройка VPS одной командой (apt, chrony, repo, unit)
scripts/push_env.sh        заливает локальный .env на VPS
scripts/deploy.sh          git pull + restart бота
scripts/run_remote.sh      ручной fallback: запуск commentator.rb в tmux на VPS без бота
jobs/                      состояние заданий на VPS (json, лог, результат), в git не попадает
js/, bash/                 аварийные fallback-и (DevTools, raw TLS)
```

## Как это работает

```
iPhone (Telegram) ──/new──▶ bot.rb (VPS) ──spawn──▶ commentator.rb ──▶ api.vk.com
                  ◀─отчёт──          ◀─result.json──
```

`commentator.rb` спит до `T-15s`, открывает по TLS-соединению на комментарий, делает по 5 вызовов `utils.getServerTime` и берёт медиану RTT, затем busy-wait и выстрел в `T − RTT/2 − lead_ms`. Все потоки отпускаются одновременно (разброс между выстрелами < 1 мс). После выстрела запрашивает `board.getComments` и пишет server-side `date` комментария в отчёт.

Время везде — `Europe/Moscow`, независимо от таймзоны VPS.

## Подготовка

**VPS.** Любой Linux с systemd и `apt` (Debian/Ubuntu). Амстердам даёт RTT до VK ~40-60 мс — компенсируется упреждением; МСК/СПб (~5-15 мс) точнее. SSH по ключу, `sudo` без пароля (или root).

**VK токен.** Открыть в браузере:
```
https://oauth.vk.com/authorize?client_id=2685278&scope=offline,wall,groups&redirect_uri=https://oauth.vk.com/blank.html&display=page&response_type=token&revoke=1
```
После согласия URL станет `.../blank.html#access_token=vk1.a.XXXXX&...`. Скопировать **только** значение токена. `expires_in=0` — бессрочный (scope `offline`).

**Telegram.** У [@BotFather](https://t.me/BotFather) создать бота → `TELEGRAM_BOT_TOKEN`. У [@userinfobot](https://t.me/userinfobot) узнать свой числовой id → `TELEGRAM_USER_ID` (бот отвечает только ему).

Локальный `.env`:
```
VK_TOKEN=vk1.a.XXXXX
TELEGRAM_BOT_TOKEN=123456789:AAAA...
TELEGRAM_USER_ID=12345678
# необязательно:
# LEAD_MS=0          доп. упреждение в мс (см. калибровку), можно менять через /lead
# VK_METHOD=board    board (board.createComment) | wall (wall.createComment)
```

## Запуск

Из корня проекта локально, VPS считаем голым:

```bash
scripts/setup_vps.sh --host user@1.2.3.4     # apt, chrony, clone, systemd unit
scripts/push_env.sh  --host user@1.2.3.4     # .env → ~/vk_commentator/.env (chmod 600)
scripts/deploy.sh    --host user@1.2.3.4     # (пере)запуск бота
```

Дальше — только телефон. Написать боту `/start`.

### Команды бота

| Команда | Что делает |
|---|---|
| `/new` | Мастер: ссылка на топик → время (`DD.MM.YY HH:MM:SS` или просто `22:00:00`) → тексты (каждая строка = отдельный комментарий, можно несколькими сообщениями) → `/done` → превью с кнопками «Запланировать» / «Dry-run» / «Отмена». При одинаковых текстах предложит уникализировать (невидимые символы против flood control). |
| `/list` | Все задания: время, количество, статус, обратный отсчёт |
| `/cancel <id>` | Убить процесс задания. `/cancel` без номера прерывает мастер |
| `/dryrun <id>` | Холостой прогон копии задания через 45 с: прогрев, RTT, выстрел без отправки. Проверка связи и калибровка |
| `/log <id>` | Хвост лога задания |
| `/status` | Часы VPS, offset NTP (chrony), валидность VK-токена и RTT до VK, активные задания |
| `/lead <ms>` | Упреждение по умолчанию для новых заданий (может быть отрицательным) |
| `/token vk1.a...` | Обновить VK-токен (проверяется через `users.get`, сообщение удаляется из чата) |
| `/check <url?post=N>` | Server-side время конкретного комментария |

По завершении задания бот присылает отчёт: RTT, упреждение, момент выстрела, и по каждому комментарию — `comment_id`, server-side секунду и ссылку, либо ошибку VK с подсказкой.

### Калибровка `lead_ms`

У VK server-side `date` с точностью до секунды, поэтому калибруем по границе секунды. Поставить 2-3 задания в свой тестовый топик на `XX:XX:00` с `/lead 0`, `/lead 10`, `/lead -10`, посмотреть в отчётах, в какую секунду упал комментарий (`server HH:MM:SS`): если в `:59` — упреждение великовато, если в `:00` — ок. Итоговое значение — `/lead <ms>`. Асимметрия маршрута обычно 5-10 мс, дальше улучшать нечем.

### Обновление

```bash
scripts/deploy.sh --host user@1.2.3.4              # git pull + restart
scripts/push_env.sh --host user@1.2.3.4 && scripts/deploy.sh --host user@1.2.3.4 --no-pull   # новый .env
```

Рестарт бота не убивает запущенные задания (`KillMode=process`, свой pgroup) — бот при старте переподхватывает живые процессы, перезапускает потерянные (если время ещё не прошло) и сообщает о пропущенных.

Логи бота: `ssh user@1.2.3.4 journalctl -u vk-bot -f`. Логи задания: `/log <id>` или `~/vk_commentator/jobs/<id>.log`.

## Ручной запуск без бота

CLI совместим с прежним:

```bash
ruby commentator.rb -u 'https://vk.com/topic-236828463_57620976' -t '08.05.26 22:00:00' \
  -m 'Комментарий 1' -m 'Комментарий 2' [--dry-run] [--method board|wall] [--lead-ms 5] [--result out.json]
```

Через tmux на VPS одной локальной командой: `scripts/run_remote.sh --host user@1.2.3.4 -u '<url>' -t '...' -m '...'` (см. `-h`). Проверка server-side времени: `ruby check_timestamp.rb '<url>?post=<comment_id>'`.

## Если что-то пошло не так

- **`VK ERROR 5`** — токен протух/отозван. [vk.com/settings?act=apps](https://vk.com/settings?act=apps) → отозвать → перевыпустить → `/token vk1.a...`.
- **`VK ERROR 15: Access denied`** на `board.createComment` — переключить метод: `VK_METHOD=wall` в `.env` (или наоборот). Проверить `/status`.
- **`VK ERROR 9: Flood control`** — уникализировать тексты (кнопка в мастере) или разнести.
- **Бот молчит** — `journalctl -u vk-bot -n 50`; `/status` показывает, жив ли токен и NTP.
- **Часы VPS уехали** — `/status` покажет offset chrony; `sudo chronyc makestep`.
- **API упал** — DevTools fallback: открыть страницу топика, в Console вставить [js/click_direct.js](js/click_direct.js), вызвать `click('22:00:00')`.
- **Один комментарий через сырой сокет на VPS:** `bash bash/commentator.sh 'msg' '08.05.26 22:00:00' '<url>'`.
