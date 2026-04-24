# vk_commentator

Отправляет один или несколько комментариев в топик ВКонтакте в **точно заданный момент времени** с миллисекундной точностью. Каждый комментарий уходит из своего прогретого HTTPS-соединения в отдельном потоке, поэтому все сообщения покидают машину в пределах десятков микросекунд друг от друга.

## Структура

```
vk_commentator/
  commentator.rb        основной скрипт (Ruby, API)
  check_timestamp.rb    пост-проверка комментария по ?post=N
  .env                  VK_TOKEN
  README.md
  js/
    click.js            DevTools fallback (без таймера)
    click_direct.js     DevTools fallback (с busy-wait)
  bash/
    commentator.sh      fallback на raw TLS-сокете (1 сообщение)
```

## Подготовка (один раз)

### Токен

Открыть в браузере (Kate Mobile client_id + scope `offline,wall,groups`):
```
https://oauth.vk.com/authorize?client_id=2685278&scope=offline,wall,groups&redirect_uri=https://oauth.vk.com/blank.html&display=page&response_type=token&revoke=1
```
После согласия URL станет `https://oauth.vk.com/blank.html#access_token=vk1.a.XXXXX&expires_in=0&user_id=YYYY`.

Скопировать **только** значение `access_token` (без `access_token=`) в `.env`:
```
VK_TOKEN=vk1.a.XXXXX
```

`expires_in=0` означает бессрочный токен (эффект scope `offline`). `.env` уже в [.gitignore](.gitignore).

### Часы

Перед боевым запуском синхронизировать системные часы:
```bash
sudo sntp -sS time.apple.com
```
Либо включить автосинхронизацию в System Settings -> General -> Date & Time.

## Использование

```bash
ruby commentator.rb \
  -u 'https://vk.com/topic-236828463_57620976' \
  -t '08.05.26 22:00:00' \
  -m 'Комментарий 1' \
  -m 'Комментарий 2' \
  -m 'Комментарий 3'
```

Из файла (по одному сообщению на строку):
```bash
ruby commentator.rb -u <url> -t '08.05.26 22:00:00' -f messages.txt
```

Все флаги: `ruby commentator.rb --help`.

### Флаги

| Флаг | Назначение |
|---|---|
| `-u, --url URL` | URL топика, например `https://vk.com/topic-236828463_57620976` |
| `-t, --time TIME` | Целевой момент `DD.MM.YY HH:MM:SS` |
| `-m, --message MSG` | Текст комментария (можно несколько раз) |
| `-f, --messages-file FILE` | Альтернатива `-m` — файл со списком |
| `--test` | Разрешить целевое время в прошлом / прямо сейчас |
| `--dry-run` | Прогреть соединения и дойти до момента X, но не отправлять |

## Чек-лист на день X

1. **Тестовый прогон** на своём пустом топике:
   ```bash
   TS=$(date -v+2M '+%d.%m.%y %H:%M:%S')
   ruby commentator.rb -u <свой_тестовый_топик> -t "$TS" -m 'test 1' -m 'test 2'
   ```
   Убедиться, что комментарии появились и проверить таймстемп через [check_timestamp.rb](check_timestamp.rb):
   ```bash
   ruby check_timestamp.rb '<url_топика>?post=<comment_id>'
   ```

2. **Синхронизировать часы:** `sudo sntp -sS time.apple.com`.

3. **Боевой запуск за 1-3 часа до X** в `screen` или `tmux`, чтобы скрипт пережил случайное закрытие терминала:
   ```bash
   tmux new -s vk
   ruby commentator.rb -u '<боевой_url>' -t '<DD.MM.YY HH:MM:SS>' -m '...' -m '...'
   # detach: Ctrl+b d
   ```

4. **После 22:00:00** глазами проверить топик и при желании прогнать `check_timestamp.rb` на каждый созданный `comment_id`, чтобы увидеть точный server-side таймстемп.

## Если что-то пошло не так

- **`VK ERROR 5: User authorization failed`** — токен протух или отозван. [vk.com/settings?act=apps](https://vk.com/settings?act=apps) -> отозвать Kate Mobile -> перевыпустить токен через тот же OAuth-URL.
- **`VK ERROR 9: Flood control`** — слишком много одинаковых/частых комментариев. Сделать сообщения уникальными (хотя бы добавить нулевой ширины пробел в конец).
- **`VK ERROR 100: ...`** — обычно битые `group_id`/`topic_id`. Проверить URL топика.
- **API упал в день X** — переключиться на DevTools fallback из `js/`. Открыть страницу топика, в DevTools вставить содержимое [js/click_direct.js](js/click_direct.js), вызвать `click('22:00:00')`. Не такой быстрый, но работает без токена.
- **Bash-fallback** ([bash/commentator.sh](bash/commentator.sh)) — для одного сообщения через сырой TLS-сокет:
  ```bash
  bash bash/commentator.sh 'msg' '08.05.26 22:00:00' 'https://vk.com/topic-...'
  ```

## Технические детали

- **Параллелизм:** `Net::HTTP::Post`-объекты и keep-alive соединения собраны заранее (`pre_warm_connections`). В момент X каждый поток вызывает только готовый `http.request(req)` — нет парсинга URL, сериализации формы, TLS-handshake. MRI GVL не мешает, потому что `http.request` уходит в I/O и отпускает GVL.
- **Точность:** coarse `sleep` до `target_time - 5s`, дальше busy-wait `nil until Time.now >= target_time` в каждом потоке. Все потоки выходят из busy-wait в пределах десятков микросекунд.
- **Логи:** для каждого сообщения отдельная строка с индексом, `fired_at` (.%L), RTT и `comment_id` или ошибкой.
