import io
import tarfile

from autodeploy import count_loc

count_loc_in_archive = count_loc.count_loc_in_archive
count_text_lines = count_loc.count_text_lines
format_loc_line = count_loc.format_loc_line
git_rev_exists = count_loc.git_rev_exists
is_documentation_path = count_loc.is_documentation_path


def _archive(files: dict[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as tar:
        for name, data in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def test_documentation_paths_are_skipped() -> None:
    assert is_documentation_path("README.md")
    assert is_documentation_path("docs/audits/2026-09-27.md")
    assert is_documentation_path("docs")
    assert not is_documentation_path("main.py")


def test_line_count_keeps_a_file_without_a_trailing_newline() -> None:
    assert count_text_lines(b"") == 0
    assert count_text_lines(b"a\nb\n") == 2
    assert count_text_lines(b"a\nb") == 2


def test_archive_counts_code_and_skips_docs_and_binary() -> None:
    archive = _archive(
        {
            "main.py": b"a\nb\n",
            "docs/readme.md": b"c\nd\n",
            "pic.bin": b"a\x00b\n",
        }
    )
    assert count_loc_in_archive(archive) == 2


def test_loc_line_shows_the_delta() -> None:
    assert format_loc_line(29007, None) == "Строк кода: 29 007"
    assert format_loc_line(10, 10) == "Строк кода: 10 (без изменений в этом деплое)"
    assert format_loc_line(12, 10) == "Строк кода: 12 (+2 в этом деплое)"
    assert format_loc_line(8, 10) == "Строк кода: 8 (-2 в этом деплое)"


def test_blank_previous_revision_is_ignored() -> None:
    assert git_rev_exists("") is False
    assert git_rev_exists("0" * 40) is False


def test_hidden_directories_are_not_mistaken_for_docs() -> None:
    assert not is_documentation_path(".docs/x.py")
    assert not is_documentation_path(".github/workflows/ci.yml")
    assert is_documentation_path("./docs/x.py")


def test_lock_files_are_not_counted() -> None:
    archive = _archive(
        {
            "main.py": b"a\n",
            "poetry.lock": b"x\n" * 100,
            "web/package-lock.json": b"{}\n" * 100,
        }
    )
    assert count_loc_in_archive(archive) == 1
