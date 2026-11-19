# github-autodeploy

Автовыкладка из GitHub Actions: пуш в `main` → тесты → Docker-образ в GHCR → выкладка по SSH через `docker compose` → уведомление в Telegram.

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

2. Положить в репозиторий prod-compose (по умолчанию `docker-compose.prod.yml`). Требования:
   - `image: ${NEW_IMAGE:?image digest is required}`;
   - `container_name` равен `app_name`;
   - `env_file: [.env]`;
   - при необходимости `user: "${HOST_UID}:${HOST_GID}"`.

3. Завести секреты в репозитории приложения:

| Секрет | Зачем |
| --- | --- |
| `SERVER_IP`, `SERVER_USER` | куда выкладывать |
| `SSH_PRIVATE_KEY` | ключ без пароля для входа на сервер |
| `SSH_HOST_FINGERPRINT` | `SHA256:...` ключа сервера, сверяется с `ssh-keyscan` |
| всё из `env_keys` | попадёт в `.env` на сервере |
| `BOT_TOKEN`, `LOG_CHAT_ID` | уведомление; имена меняются через `notify_token_secret` / `notify_chat_secret`, без них уведомление пропускается |
| `AUTODEPLOY_TOKEN` | только если этот репозиторий приватный: токен с правом чтения на него |

Отпечаток сервера: `ssh-keyscan -t ed25519 HOST | ssh-keygen -lf -`.

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
| `required_env_keys` | пусто | без них выкладка падает |
| `writable_dirs` | пусто | каталоги внутри `$HOME/<app_name>`, владелец — пользователь SSH, права `700` |
| `ready_markers` | пусто | строки лога, по одной на строку; все должны появиться за `ready_timeout` |
| `ready_timeout` | `90` | секунды |
| `log_mask_regex` | пусто | что заменять на `***` при печати логов |
| `post_deploy_script` | пусто | скрипт из репозитория приложения после выкладки; получает `SSH_CONFIG` и `SSH_TARGET`, его ошибка выкладку не валит |

## Что происходит

- PR в `deploy_branch` — только тесты.
- Пуш в `deploy_branch`:
  1. тесты (`test_command`);
  2. образ с тегом полного sha уходит в GHCR, дальше передаётся digest;
  3. `scripts/push_remote.sh` сверяет ключ сервера, собирает одноразовый `.env.deploy` только из `env_keys` и копирует его, compose-файл и `remote/*.sh` на сервер;
  4. `remote/deploy.sh` логинится в GHCR, тянет образ до 5 раз, пишет `.env` (`0600`), отдаёт `writable_dirs` пользователю SSH, поднимает compose с `--pull never` и ждёт `ready_markers` (без них — `healthy` или просто запуск); `.env.deploy` удаляется;
  5. `remote/verify.sh` проверяет, что контейнер запущен;
  6. уведомление в Telegram: sha, сообщение коммита, число строк кода с дельтой (без `docs/` и `*.md`), статусы этапов, ссылка на запуск.

## Разработка

```bash
pip install -r requirements-dev.txt
ruff check .
pytest
```
