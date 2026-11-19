from autodeploy.notice import format_deploy_notice


def test_success_notice_is_bold_with_check() -> None:
    text = format_deploy_notice(
        "20e8a40abc",
        "Merge pull request #117 from owner/fix/deploy\n\nВспомогательный merge",
        "https://github.com/owner/repo/actions/runs/1",
        loc_line="Строк кода: 29 007 (-2 в этом деплое)",
    )
    assert text == (
        "✅ <b>Деплой успешно завершен!</b>\n"
        "\n"
        "Commit: <code>20e8a40</code>\n"
        "Merge pull request #117 from owner/fix/deploy\n"
        "\n"
        "Вспомогательный merge\n"
        "\n"
        "Строк кода: 29 007 (-2 в этом деплое)\n"
        "Все этапы пройдены успешно\n"
        '<a href="https://github.com/owner/repo/actions/runs/1">'
        "Проверить в Actions</a>"
    )


def test_failure_notice_uses_cross_and_stage_marks() -> None:
    text = format_deploy_notice(
        "abcdef0",
        "сломанный <деплой>",
        "https://github.com/owner/repo/actions/runs/2",
        test_status="success",
        build_status="failure",
        deploy_status="skipped",
    )
    assert text is not None
    assert "❌ <b>Деплой завершился с ошибкой!</b>" in text
    assert "✅ <b>Тесты/Линтер:</b> успешно" in text
    assert "❌ <b>Сборка:</b> ошибка" in text
    assert "⏭️ <b>Деплой:</b> пропущен" in text
    assert "сломанный &lt;деплой&gt;" in text


def test_app_name_goes_into_the_title_escaped() -> None:
    text = format_deploy_notice("abc1234", "", None, app="bot<1>")
    assert text is not None
    assert text.startswith("✅ <b>Деплой bot&lt;1&gt; успешно завершен!</b>")


def test_url_quotes_are_escaped_in_the_link() -> None:
    text = format_deploy_notice("abc1234", "сообщение", 'https://e.com/r/1?q="x"')
    assert text is not None
    assert 'href="https://e.com/r/1?q=&quot;x&quot;"' in text


def test_notice_is_skipped_without_sha() -> None:
    assert format_deploy_notice("  ", "локальный запуск", None) is None


def test_long_commit_message_is_truncated_without_breaking_entities() -> None:
    text = format_deploy_notice("abc1234", "<" * 5000, None)
    assert text is not None
    assert len(text) < 4096
    assert "&lt;…" in text
    assert "&l…" not in text
