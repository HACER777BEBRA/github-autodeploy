import html
import os
import sys

# Telegram принимает до 4096 символов; остальная часть уведомления короткая.
MAX_SUMMARY_CHARS = 3000


def _escape_limited(text: str, limit: int) -> str:
    """Экранирует текст и обрезает его, не разрывая HTML-сущности."""
    escaped = html.escape(text)
    if len(escaped) <= limit:
        return escaped
    parts: list[str] = []
    size = 0
    for char in text:
        piece = html.escape(char)
        if size + len(piece) > limit - 1:
            break
        parts.append(piece)
        size += len(piece)
    return "".join(parts).rstrip() + "…"


def _stage(status: str | None, name: str) -> str:
    labels = {
        "success": f"✅ <b>{name}:</b> успешно",
        "failure": f"❌ <b>{name}:</b> ошибка",
        "cancelled": f"⚠️ <b>{name}:</b> отменен",
        "skipped": f"⏭️ <b>{name}:</b> пропущен",
    }
    key = (status or "").strip() or "skipped"
    return labels.get(key, f"❓ <b>{name}:</b> {html.escape(key)}")


def format_deploy_notice(
    sha: str | None,
    message: str | None,
    url: str | None,
    *,
    test_status: str | None = "success",
    build_status: str | None = "success",
    deploy_status: str | None = "success",
    loc_line: str | None = None,
    app: str | None = None,
) -> str | None:
    short_sha = (sha or "").strip()[:7]
    if not short_sha:
        return None

    def finished(status: str | None) -> bool:
        return (status or "skipped") in {"success", "skipped"}

    name = (app or "").strip()
    target = f"Деплой {html.escape(name)}" if name else "Деплой"
    if (
        (test_status or "") == "success"
        and finished(build_status)
        and finished(deploy_status)
    ):
        emoji = "✅"
        title = f"{target} успешно завершен!"
        status_text = "Все этапы пройдены успешно"
    else:
        emoji = "❌"
        title = f"{target} завершился с ошибкой!"
        status_text = "\n".join(
            [
                _stage(test_status, "Тесты/Линтер"),
                _stage(build_status, "Сборка"),
                _stage(deploy_status, "Деплой"),
            ]
        )

    parts = [
        f"{emoji} <b>{title}</b>",
        "",
        f"Commit: <code>{html.escape(short_sha)}</code>",
    ]
    summary = (message or "").strip()
    if summary:
        parts.append(_escape_limited(summary, MAX_SUMMARY_CHARS))
    parts.append("")
    loc = (loc_line or "").strip()
    if loc:
        parts.append(html.escape(loc))
    parts.append(status_text)
    link = (url or "").strip()
    if link:
        parts.append(
            f'<a href="{html.escape(link, quote=True)}">Проверить в Actions</a>'
        )
    return "\n".join(parts)


def main() -> int:
    text = format_deploy_notice(
        os.environ.get("COMMIT_SHA"),
        os.environ.get("COMMIT_MESSAGE"),
        os.environ.get("WORKFLOW_URL"),
        test_status=os.environ.get("TEST_STATUS"),
        build_status=os.environ.get("BUILD_STATUS"),
        deploy_status=os.environ.get("DEPLOY_STATUS"),
        loc_line=os.environ.get("LOC_LINE"),
        app=os.environ.get("APP_LABEL"),
    )
    if not text:
        print("empty deploy notice", file=sys.stderr)
        return 1
    with open(sys.argv[1], "w", encoding="utf-8") as handle:
        handle.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
