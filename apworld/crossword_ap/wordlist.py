from __future__ import annotations

from importlib import resources
from pathlib import Path
from typing import Dict, Iterable, List

PACKAGE_NAME = __package__ or "crossword_ap"
FALLBACK_ASSET_PATH = Path(__file__).resolve().parents[2] / "assets" / "crossword_wordlist.txt"


def _iter_lines(text: str) -> Iterable[str]:
    for raw_line in text.splitlines():
        yield raw_line.rstrip("\n")


def _load_embedded_wordlist() -> List[str]:
    try:
        data = resources.read_text(PACKAGE_NAME, "crossword_wordlist.txt", encoding="utf-8")
    except (FileNotFoundError, UnicodeDecodeError):
        return []
    return list(_iter_lines(data))


def _load_external_wordlist() -> List[str]:
    if not FALLBACK_ASSET_PATH.exists():
        return []
    return list(_iter_lines(FALLBACK_ASSET_PATH.read_text(encoding="utf-8")))


def load_word_entries() -> List[Dict[str, str]]:
    """
    Parse the crossword word list into dictionaries containing word/clue/category.

    The parser mirrors the client implementation so both sides share the same data source.
    """
    lines = _load_embedded_wordlist()
    if not lines:
        lines = _load_external_wordlist()
    if not lines:
        raise FileNotFoundError(
            "Crossword word list not found in package resources "
            f"or at {FALLBACK_ASSET_PATH}"
        )

    entries: List[Dict[str, str]] = []
    current_category = ""
    for raw_line in lines:
        line = raw_line.strip()
        if not line:
            continue
        separator_index = line.find(":")
        if separator_index == -1:
            current_category = line
            continue

        lhs = line[:separator_index].strip()
        rhs = line[separator_index + 1 :].strip()
        if not rhs:
            current_category = lhs
            continue

        entry = {
            "word": lhs.upper(),
            "clue": rhs,
            "category": current_category,
        }
        entries.append(entry)

    return entries
