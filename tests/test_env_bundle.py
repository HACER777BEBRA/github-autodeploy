import pytest

from autodeploy.env_bundle import (
    collect_app_env,
    collect_deploy_env,
    quote_compose,
    render_compose_env,
    render_shell_env,
    split_keys,
)


def test_keys_split_on_commas_and_spaces() -> None:
    assert split_keys("BOT_TOKEN, LOG_CHAT_ID\nDATABASE_URL BOT_TOKEN") == [
        "BOT_TOKEN",
        "LOG_CHAT_ID",
        "DATABASE_URL",
    ]


def test_bad_key_names_are_rejected() -> None:
    with pytest.raises(ValueError, match="invalid"):
        split_keys("OK $(rm)")


def test_compose_settings_are_rejected() -> None:
    with pytest.raises(ValueError, match="reserved"):
        split_keys("COMPOSE_PROJECT_NAME")


def test_only_listed_secrets_get_into_the_app_env() -> None:
    values = collect_app_env(
        {"ENV_KEYS": "A", "APP_NAME": "bot"},
        {"A": "1", "SSH_PRIVATE_KEY": "secret"},
    )
    assert values == {"A": "1"}


def test_missing_required_secret_fails() -> None:
    with pytest.raises(ValueError, match="missing required secrets: B"):
        collect_app_env({"ENV_KEYS": "A B", "REQUIRED_ENV_KEYS": "B"}, {"A": "1"})


def test_required_key_must_be_listed_in_env_keys() -> None:
    with pytest.raises(ValueError, match="not listed in env_keys: B"):
        collect_app_env(
            {"ENV_KEYS": "A", "REQUIRED_ENV_KEYS": "B"}, {"A": "1", "B": "2"}
        )


def test_deploy_env_has_no_app_secrets() -> None:
    values = collect_deploy_env({"APP_NAME": "bot", "A": "secret", "ENV_KEYS": "A"})
    assert values["APP_NAME"] == "bot"
    assert "A" not in values
    assert "ENV_KEYS" not in values
    assert values["READY_TIMEOUT"] == "90"


def test_bad_log_mask_regex_fails_early() -> None:
    with pytest.raises(ValueError, match="log_mask_regex"):
        collect_deploy_env({"LOG_MASK_REGEX": "chat_id=("})


@pytest.mark.parametrize("timeout", ["0", "-5", "abc"])
def test_bad_ready_timeout_fails_early(timeout: str) -> None:
    with pytest.raises(ValueError, match="ready_timeout"):
        collect_deploy_env({"READY_TIMEOUT": timeout})


def test_compose_values_are_not_interpolated() -> None:
    assert quote_compose("p$ss ${HOME}") == "'p$ss ${HOME}'"
    assert quote_compose("a\nb") == "'a\nb'"


def test_compose_values_with_single_quote_are_escaped() -> None:
    assert quote_compose('it\'s $x "q" \\ \n') == '"it\'s \\$x \\"q\\" \\\\ \\n"'


def test_compose_env_render() -> None:
    assert render_compose_env({"A": "1", "B": ""}) == "A='1'\nB=''\n"


def test_shell_values_are_quoted() -> None:
    assert render_shell_env({"A": "it's $x"}) == "A='it'\"'\"'s $x'\n"
