# github-autodeploy

Автовыкладка из GitHub Actions: пуш в `main` → тесты → Docker-образ в GHCR → выкладка по SSH через `docker compose` → уведомление в Telegram (необязательно).

Подключается в любой репозиторий как reusable workflow.

## Как подключить

1. В репозитории приложения создать `.github/workflows/deploy.yml`:

```yaml
name: Deploy

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  autodeploy:
    uses: HACER777BEBRA/github-autodeploy/.github/workflows/deploy.yml@main
    permissions:
      contents: read
      packages: write
    secrets: inherit
    with:
      autodeploy_repository: HACER777BEBRA/github-autodeploy
      app_name: my-bot
      env_keys: BOT_TOKEN LOG_CHAT_ID DATABASE_URL
```

Полный пример — `examples/real-estate-client-bot.yml`.

Так подключается репозиторий того же владельца, что и `HACER777BEBRA/github-autodeploy`. Если приложение лежит у другого пользователя или в другой организации, `secrets: inherit` секреты не передаст — см. [Репозиторий приложения у другого владельца](#репозиторий-приложения-у-другого-владельца).

2. Положить в репозиторий prod-compose (по умолчанию `docker-compose.prod.yml`). Требования:
   - `image: ${NEW_IMAGE:?image digest is required}`;
   - `container_name` равен `app_name`;
   - `env_file: [.env]`;
   - при необходимости `user: "${HOST_UID}:${HOST_GID}"`.

3. Завести секреты в репозитории приложения:

| Секрет | Зачем |
| --- | --- |
| `SERVER_IP`, `SERVER_USER` | куда выкладывать |
| `SERVER_PORT` | порт SSH, если не `22` (необязательно) |
| `SSH_PRIVATE_KEY` | ключ без пароля для входа на сервер |
| `SSH_HOST_FINGERPRINT` | `SHA256:...` ключа сервера, сверяется с `ssh-keyscan` |
| всё из `env_keys` | попадёт в `.env` на сервере |
| `BOT_TOKEN`, `LOG_CHAT_ID` | необязательно: уведомление в Telegram, см. ниже |
| `AUTODEPLOY_TOKEN` | только если этот репозиторий приватный: токен с правом чтения на него |

Отпечаток сервера: `ssh-keyscan -t ed25519 HOST | ssh-keygen -lf -` (для нестандартного порта — `ssh-keyscan -p PORT ...`).

### Уведомления в Telegram

Необязательны: приложению не нужен Telegram, чтобы выкладываться.

- Уведомление отправляется, только если заданы оба секрета: с токеном бота и с id чата. По умолчанию это `BOT_TOKEN` и `LOG_CHAT_ID`; другие имена задаются через `notify_token_secret` / `notify_chat_secret`.
- Если секретов нет, шаг просто пропускается.
- Чтобы выключить уведомления совсем, передайте `notify_token_secret: ""`.
- Ошибка отправки не делает запуск красным: она видна как предупреждение в логе.

### Версии

Пример выше подключает `@main`. Чтобы выкладка не менялась сама, укажите тег или SHA и в `uses: ...@<ref>`, и в `autodeploy_ref` — так workflow и скрипты будут из одной версии.

### Репозиторий приложения у другого владельца

GitHub передаёт секреты по `secrets: inherit` только в reusable workflow того же владельца (того же пользователя, организации или enterprise). Если приложение лежит, например, в `someone/app`, а workflow вызывается как `HACER777BEBRA/github-autodeploy/.github/workflows/deploy.yml@...`, все секреты внутри приходят пустыми:

- выкладка падает с ошибкой `Secrets were not passed` (в старых версиях — `Missing required environment variable: SERVER_IP`);
- уведомление в Telegram пропускается: токен и id чата тоже пусты.

Явная передача (`secrets: { SERVER_IP: ..., ... }` вместо `inherit`) здесь целиком не помогает: GitHub принимает только секреты, объявленные в `on.workflow_call.secrets` вызываемого workflow, а имена из `env_keys` и `notify_*_secret` у каждого приложения свои, заранее их не объявить. Поэтому workflow библиотеки секреты не объявляет и рассчитан на `inherit`.

Обход — положить копию workflow в репозиторий приложения и вызывать её локально: вызов `./...` идёт внутри одного репозитория, и `inherit` работает.

1. Скопировать `deploy.yml` нужной версии (SHA или тег) под другим именем, чтобы не путать с вызывающим workflow:

   ```bash
   SHA=<sha коммита github-autodeploy>
   curl -fsSL "https://raw.githubusercontent.com/HACER777BEBRA/github-autodeploy/$SHA/.github/workflows/deploy.yml" -o .github/workflows/autodeploy.yml
   ```

   У копии только `on: workflow_call`, сама по себе она не запускается.

2. В `.github/workflows/deploy.yml` приложения вызывать копию и закрепить скрипты на тот же SHA:

   ```yaml
   jobs:
     autodeploy:
       uses: ./.github/workflows/autodeploy.yml
       permissions:
         contents: read
         packages: write
       secrets: inherit
       with:
         autodeploy_repository: HACER777BEBRA/github-autodeploy
         autodeploy_ref: <тот же SHA>
         app_name: my-bot
         env_keys: BOT_TOKEN LOG_CHAT_ID DATABASE_URL
   ```

3. Обновляться так же парой: перекачать `autodeploy.yml` с нового SHA и поменять `autodeploy_ref` в одном коммите. Иначе workflow и скрипты окажутся из разных версий.

Скрипты (`scripts/`, `remote/`) по-прежнему берутся из этого репозитория через `autodeploy_repository`/`autodeploy_ref`; для этого секреты не нужны, пока репозиторий публичный.

## Параметры

| Параметр | По умолчанию | Что делает |
| --- | --- | --- |
| `autodeploy_repository` | — | `owner/name` этого репозитория, откуда берутся скрипты |
| `autodeploy_ref` | `main` | ветка или тег скриптов |
| `app_name` | — | имя контейнера и каталога `$HOME/<app_name>` на сервере |
| `app_label` | пусто | имя в заголовке уведомления |
| `deploy_branch` | `main` | пуш в какую ветку выкладывается |
| `image_name` | `ghcr.io/<owner>/<repo>` | образ, приводится к нижнему регистру |
| `dockerfile`, `build_context` | `Dockerfile`, `.` | сборка |
| `compose_file` | `docker-compose.prod.yml` | путь в репозитории приложения |
| `python_version` | `3.13` | для тестов |
| `test_command` | pip install + `ruff check .` + `pytest tests/` | пусто — без тестов |
| `env_keys` | — | имена секретов для `.env`, через пробел или запятую |
| `required_env_keys` | пусто | подмножество `env_keys`; если секрет пуст, выкладка падает |
| `writable_dirs` | пусто | каталоги внутри `$HOME/<app_name>`, владелец — пользователь SSH, права `700` |
| `ready_markers` | пусто | строки лога, по одной на строку; все должны появиться за `ready_timeout` |
| `ready_timeout` | `90` | секунды |
| `log_mask_regex` | пусто | регулярное выражение Python: что заменять на `***` при печати логов |
| `post_deploy_script` | пусто | скрипт из репозитория приложения после выкладки; получает только `SSH_CONFIG`, `SSH_TARGET`, `APP_NAME`, `PATH`, `HOME` (секретов нет), его ошибка выкладку не валит |
| `notify_token_secret`, `notify_chat_secret` | `BOT_TOKEN`, `LOG_CHAT_ID` | имена секретов для Telegram; пусто — без уведомлений |

## Что происходит

- PR в `deploy_branch` — только тесты.
- Пуш в `deploy_branch`:
  1. тесты (`test_command`);
  2. образ собирается через buildx с кэшем GitHub Actions, уходит в GHCR с тегом полного sha, дальше передаётся digest;
  3. выкладки одного приложения идут строго по очереди (`concurrency`), старая не перезапишет новую;
  4. `scripts/push_remote.sh` сверяет ключ сервера, собирает `.env` только из `env_keys` и служебный `.env.deploy`, копирует их, compose-файл и `remote/deploy.sh` на сервер;
  5. `remote/deploy.sh` логинится в GHCR через временный конфиг docker, тянет образ до 5 раз, отдаёт `writable_dirs` пользователю SSH, поднимает compose с `--pull never` и ждёт `ready_markers` (без них — `healthy` или просто запуск без перезапусков);
  6. если приложение не поднялось, возвращаются прошлые образ, `.env` и compose-файл; после успеха удаляются неиспользуемые образы этого приложения;
  7. уведомление в Telegram, если настроено: sha, сообщение коммита, число строк кода с дельтой (без `docs/`, `*.md` и lock-файлов), статусы этапов, ссылка на запуск.

Значения в `.env` пишутся так, что Compose не подставляет в них переменные: `$` в паролях сохраняется как есть.

## Разработка

```bash
pip install -r requirements-dev.txt
ruff check .
pytest
shellcheck scripts/*.sh remote/*.sh examples/*.sh
```
