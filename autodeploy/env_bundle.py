from __future__ import annotations

import json
import os
import re
import shlex
import sys
from pathlib import Path

KEY_RE = re.compile(r"^[A-Z_][A-Z0-9_]*$")
DEPLOY_KEYS = (
    "APP_NAME",
    "NEW_IMAGE",
    "GHCR_TOKEN",
    "GHCR_USERNAME",
    "ENV_KEYS",
    "REQUIRED_ENV_KEYS",
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
    return keys


def collect(environ: dict[str, str], secrets: dict[str, str]) -> dict[str, str]:
    app_keys = split_keys(environ.get("ENV_KEYS"))
    missing = [k for k in split_keys(environ.get("REQUIRED_ENV_KEYS")) if not secrets.get(k)]
    if missing:
        raise ValueError(f"missing required secrets: {', '.join(missing)}")
    values = {k: environ.get(k, "") for k in DEPLOY_KEYS}
    values.update({k: secrets.get(k, "") for k in app_keys})
    return values


def render(values: dict[str, str]) -> str:
    return "".join(f"{k}={shlex.quote(v)}\n" for k, v in values.items())


def main() -> int:
    secrets = json.loads(os.environ.get("SECRETS_JSON") or "{}")
    try:
        values = collect(dict(os.environ), secrets)
    except ValueError as exc:
        print(exc, file=sys.stderr)
        return 1
    path = Path(sys.argv[1])
    path.write_text(render(values), encoding="utf-8")
    path.chmod(0o600)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
