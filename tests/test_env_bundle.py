import pytest

from autodeploy.env_bundle import collect, render, split_keys


def test_keys_split_on_commas_and_spaces() -> None:
    assert split_keys("BOT_TOKEN, LOG_CHAT_ID\nDATABASE_URL") == [
        "BOT_TOKEN",
        "LOG_CHAT_ID",
        "DATABASE_URL",
    ]


def test_bad_key_names_are_rejected() -> None:
    with pytest.raises(ValueError):
        split_keys("OK $(rm)")


def test_only_listed_secrets_get_into_the_bundle() -> None:
    values = collect(
        {"ENV_KEYS": "A", "APP_NAME": "bot"},
        {"A": "1", "SSH_PRIVATE_KEY": "secret"},
    )
    assert values["A"] == "1"
    assert values["APP_NAME"] == "bot"
    assert "SSH_PRIVATE_KEY" not in values


def test_missing_required_secret_fails() -> None:
    with pytest.raises(ValueError, match="B"):
        collect({"ENV_KEYS": "A B", "REQUIRED_ENV_KEYS": "B"}, {"A": "1"})


def test_values_are_shell_quoted() -> None:
    assert render({"A": "it's $x"}) == "A='it'\"'\"'s $x'\n"
