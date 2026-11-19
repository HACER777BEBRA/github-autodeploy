"""Собирает файлы для сервера: `.env` приложения и `.env.deploy` для deploy.sh.

Секреты приложения попадают только в `.env` (формат env_file Docker Compose),
а `.env.deploy` содержит лишь служебные переменные и читается shell-ом.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import sys
from pathlib import Path

KEY_RE = re.compile(r"^[A-Z_][A-Z0-9_]*$")
# Compose читает эти переменные из .env проекта как свои настройки.
RESERVED_PREFIXES = ("COMPOSE_",)
DEPLOY_KEYS = (
    "APP_NAME",
    "NEW_IMAGE",
    "GHCR_TOKEN",
    "GHCR_USERNAME",
    "WRITABLE_DIRS",
    "READY_MARKERS",
    "READY_TIMEOUT",
    "LOG_MASK_REGEX",
)


def split_keys(raw: str | None) -> list[str]:
    keys = [k for k in re.split(r"[\s,]+", raw or "") if k]
    bad = [k for k in keys if not KEY_RE.fullmatch(k)]
    if bad:
        raise ValueError(f"invalid variable names: {', '.join(bad)}")
    reserved = [k for k in keys if k.startswith(RESERVED_PREFIXES)]
    if reserved:
        raise ValueError(f"reserved variable names: {', '.join(reserved)}")
    return list(dict.fromkeys(keys))


def collect_app_env(environ: dict[str, str], secrets: dict[str, str]) -> dict[str, str]:
    app_keys = split_keys(environ.get("ENV_KEYS"))
    required = split_keys(environ.get("REQUIRED_ENV_KEYS"))
    not_listed = [k for k in required if k not in app_keys]
    if not_listed:
        raise ValueError(
            f"required_env_keys not listed in env_keys: {', '.join(not_listed)}"
        )
    missing = [k for k in required if not secrets.get(k)]
    if missing:
        raise ValueError(f"missing required secrets: {', '.join(missing)}")
    return {k: secrets.get(k, "") for k in app_keys}


def collect_deploy_env(environ: dict[str, str]) -> dict[str, str]:
    values = {k: environ.get(k, "") for k in DEPLOY_KEYS}
    if values["LOG_MASK_REGEX"]:
        try:
            re.compile(values["LOG_MASK_REGEX"])
        except re.error as exc:
            raise ValueError(f"invalid log_mask_regex: {exc}") from exc
    timeout = values["READY_TIMEOUT"] or "90"
    if not timeout.isdigit() or int(timeout) <= 0:
        raise ValueError(f"ready_timeout must be a positive integer: {timeout}")
    values["READY_TIMEOUT"] = timeout
    return values


def quote_compose(value: str) -> str:
    """Значение для env_file Docker Compose без подстановки переменных.

    В одинарных кавычках Compose ничего не раскрывает и допускает переводы
    строк. Одинарную кавычку внутри них экранировать нельзя, поэтому такие
    значения пишутся в двойных кавычках с экранированием `\\`, `"`, `$` и
    переводов строк.
    """
    if "'" not in value:
        return f"'{value}'"
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("$", "\\$")
        .replace("\r", "\\r")
        .replace("\n", "\\n")
    )
    return f'"{escaped}"'


def render_compose_env(values: dict[str, str]) -> str:
    return "".join(f"{k}={quote_compose(v)}\n" for k, v in values.items())


def render_shell_env(values: dict[str, str]) -> str:
    return "".join(f"{k}={shlex.quote(v)}\n" for k, v in values.items())


def _write_private(path: Path, text: str) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    path.chmod(0o600)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: python -m autodeploy.env_bundle OUT_DIR", file=sys.stderr)
        return 2
    secrets = json.loads(os.environ.get("SECRETS_JSON") or "{}")
    environ = dict(os.environ)
    try:
        app_env = collect_app_env(environ, secrets)
        deploy_env = collect_deploy_env(environ)
    except ValueError as exc:
        print(exc, file=sys.stderr)
        return 1
    out = Path(sys.argv[1])
    _write_private(out / ".env", render_compose_env(app_env))
    _write_private(out / ".env.deploy", render_shell_env(deploy_env))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
