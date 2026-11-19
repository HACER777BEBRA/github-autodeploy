#!/usr/bin/env python3
from __future__ import annotations

import io
import subprocess
import sys
import tarfile

DOC_SUFFIXES = (".md", ".rst", ".adoc")
ZERO_SHA = "0" * 40


def is_documentation_path(path: str) -> bool:
    normalized = path.replace("\\", "/").lstrip("./")
    name = normalized.rsplit("/", 1)[-1].lower()
    if name.endswith(DOC_SUFFIXES):
        return True
    return normalized == "docs" or normalized.startswith("docs/")


def is_text_content(data: bytes) -> bool:
    return b"\x00" not in data


def count_text_lines(data: bytes) -> int:
    if not data:
        return 0
    return data.count(b"\n") + (0 if data.endswith(b"\n") else 1)


def format_int(value: int) -> str:
    return f"{value:,}".replace(",", " ")


def format_loc_line(current: int, previous: int | None) -> str:
    current_text = format_int(current)
    if previous is None:
        return f"Строк кода: {current_text}"
    delta = current - previous
    if delta == 0:
        return f"Строк кода: {current_text} (без изменений в этом деплое)"
    delta_text = format_int(delta)
    if delta > 0:
        delta_text = f"+{delta_text}"
    return f"Строк кода: {current_text} ({delta_text} в этом деплое)"


def count_loc_in_archive(archive: bytes) -> int:
    total = 0
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as tar:
        for member in tar.getmembers():
            if not member.isfile() or is_documentation_path(member.name):
                continue
            extracted = tar.extractfile(member)
            if extracted is None:
                continue
            data = extracted.read()
            if not is_text_content(data):
                continue
            total += count_text_lines(data)
    return total


def git_rev_exists(rev: str) -> bool:
    if not rev or rev == ZERO_SHA:
        return False
    completed = subprocess.run(
        ["git", "cat-file", "-e", f"{rev}^{{commit}}"],
        capture_output=True,
        check=False,
    )
    return completed.returncode == 0


def git_archive(rev: str) -> bytes:
    return subprocess.check_output(["git", "archive", "--format=tar", rev])


def count_loc(rev: str) -> int:
    return count_loc_in_archive(git_archive(rev))


def build_loc_line(current_rev: str, previous_rev: str = "") -> str:
    current = count_loc(current_rev)
    previous = count_loc(previous_rev) if git_rev_exists(previous_rev) else None
    return format_loc_line(current, previous)


def main() -> int:
    current_rev = sys.argv[1] if len(sys.argv) > 1 else "HEAD"
    previous_rev = sys.argv[2] if len(sys.argv) > 2 else ""
    print(build_loc_line(current_rev, previous_rev))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
