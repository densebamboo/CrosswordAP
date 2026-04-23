from __future__ import annotations

import math
import random
from dataclasses import dataclass
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

Direction = str
EntryDict = Dict[str, Any]
Position = Tuple[int, int]

DIR_ACROSS: Direction = "across"
DIR_DOWN: Direction = "down"


@dataclass
class PuzzleLayout:
    board: List[List[str]]
    mask: List[str]
    entries: List[EntryDict]

    def as_dict(self) -> Dict[str, Any]:
        return {
            "board": self.board,
            "mask": self.mask,
            "entries": self.entries,
        }


class CrosswordPuzzleGenerator:
    STARTER_DENYLIST = {"ACOUSTICS"}

    def __init__(self, rng: random.Random) -> None:
        self._rng = rng

    def generate(
        self,
        word_entries: Sequence[EntryDict],
        rows: int,
        cols: int,
        min_length: int,
        max_words: int,
        seed: Optional[int],
        category_weights: Optional[Dict[str, float]] = None,
    ) -> Optional[PuzzleLayout]:
        if rows <= 0 or cols <= 0:
            return None
        if not word_entries:
            return None

        rng = random.Random(seed)
        weights = self._sanitize_category_weights(category_weights or {})

        candidates = self._filtered_entries(word_entries, min_length, rows, cols)
        if not candidates:
            return None
        candidates = self._weighted_shuffle(candidates, weights, rng)
        if not candidates:
            return None

        board = self._create_matrix(rows, cols, "")
        horizontal_mask = self._create_matrix(rows, cols, False)
        vertical_mask = self._create_matrix(rows, cols, False)
        letter_positions: Dict[str, List[Position]] = {}
        placed_entries: List[EntryDict] = []
        used_words: Dict[str, bool] = {}

        first_entry = self._select_start_entry(candidates, min_length, cols, rng, weights)
        if not first_entry:
            return None

        first_word = first_entry["word"]
        # Randomize first placement to diversify seeds
        if rng.random() < 0.5 and len(first_word) <= cols:
            # Horizontal start
            first_row = rng.randrange(rows)
            first_col = rng.randrange(max(1, cols - len(first_word) + 1))
            self._place_horizontal(
                first_word,
                first_row,
                first_col,
                board,
                horizontal_mask,
                letter_positions,
            )
            first_dir = DIR_ACROSS
            first_start = (first_row, first_col)
        else:
            # Vertical start (fallback to horizontal if too long)
            if len(first_word) > rows:
                first_row = rng.randrange(rows)
                first_col = rng.randrange(max(1, cols - len(first_word) + 1))
                self._place_horizontal(
                    first_word,
                    first_row,
                    first_col,
                    board,
                    horizontal_mask,
                    letter_positions,
                )
                first_dir = DIR_ACROSS
                first_start = (first_row, first_col)
            else:
                first_row = rng.randrange(max(1, rows - len(first_word) + 1))
                first_col = rng.randrange(cols)
                self._place_vertical(
                    first_word,
                    first_row,
                    first_col,
                    board,
                    vertical_mask,
                    letter_positions,
                )
                first_dir = DIR_DOWN
                first_start = (first_row, first_col)

        placed_entries.append(
            {
                "word": first_word,
                "clue": first_entry.get("clue", ""),
                "category": first_entry.get("category", ""),
                "direction": first_dir,
                "start": first_start,
            }
        )
        placed_entries[-1]["location_index"] = len(placed_entries)
        used_words[first_word] = True

        failures = 0
        max_failures = max(200, max_words * 10)

        for entry in candidates:
            word = entry["word"]
            if word in used_words:
                continue
            length = len(word)
            if length < min_length or length > max(rows, cols):
                continue

            placement = self._try_place_entry(
                entry,
                board,
                horizontal_mask,
                vertical_mask,
                letter_positions,
                rng,
            )
            if placement:
                placement["location_index"] = len(placed_entries) + 1
                placed_entries.append(placement)
                used_words[word] = True
                failures = 0
                if len(placed_entries) >= max_words:
                    break
            else:
                failures += 1
                if failures >= max_failures:
                    break

        if len(placed_entries) < 2:
            return None

        return self._build_layout_result(board, placed_entries)

    def _filtered_entries(
        self, entries: Sequence[EntryDict], min_length: int, rows: int, cols: int
    ) -> List[EntryDict]:
        filtered: List[EntryDict] = []
        max_dimension = max(rows, cols)
        for entry in entries:
            word = entry.get("word", "")
            if not word:
                continue
            length = len(word)
            if length < min_length or length > max_dimension:
                continue
            filtered.append(dict(entry))
        return filtered

    def _sanitize_category_weights(self, category_weights: Dict[str, float]) -> Dict[str, float]:
        weights: Dict[str, float] = {}
        for key, value in category_weights.items():
            safe_value = max(float(value), 0.0)
            weights[str(key)] = safe_value
        if "_default" not in weights:
            weights["_default"] = 1.0
        elif weights["_default"] <= 0.0:
            weights["_default"] = 0.0
        return weights

    def _weighted_shuffle(
        self, entries: Sequence[EntryDict], weights: Dict[str, float], rng: random.Random
    ) -> List[EntryDict]:
        keyed: List[Tuple[float, EntryDict]] = []
        default_weight = max(float(weights.get("_default", 1.0)), 0.0)
        for entry in entries:
            category = str(entry.get("category", ""))
            weight = max(float(weights.get(category, default_weight)), 0.0)
            if weight <= 0.0:
                continue
            random_value = rng.random()
            if random_value <= 0.0:
                random_value = 1e-6
            key = math.pow(random_value, 1.0 / weight)
            keyed.append((key, entry))
        keyed.sort(key=lambda pair: pair[0], reverse=True)
        return [entry for _, entry in keyed]

    def _select_start_entry(
        self,
        entries: Sequence[EntryDict],
        min_length: int,
        cols: int,
        rng: random.Random,
        weights: Dict[str, float],
    ) -> Optional[EntryDict]:
        # Collect candidates that fit on the first row as the seed entry.
        options: List[EntryDict] = []
        for entry in entries:
            word = entry["word"]
            if min_length <= len(word) <= cols:
                options.append(entry)
        if not options:
            return None
        # Shuffle and try to pick a starter not in the denylist to avoid repetitive openers.
        rng.shuffle(options)
        for entry in options:
            if entry.get("word", "") not in self.STARTER_DENYLIST:
                return entry
        # Fallback: return any (still shuffled) entry if all are denied.
        return options[0] if options else None

    def _try_place_entry(
        self,
        entry: EntryDict,
        board: List[List[str]],
        horizontal_mask: List[List[bool]],
        vertical_mask: List[List[bool]],
        letter_positions: Dict[str, List[Position]],
        rng: random.Random,
    ) -> Optional[EntryDict]:
        word = entry["word"]
        length = len(word)
        indices = [i for i in range(length) if letter_positions.get(word[i])]
        if not indices:
            return None
        rng.shuffle(indices)

        for index in indices:
            letter = word[index]
            positions = list(letter_positions.get(letter, []))
            if not positions:
                continue
            rng.shuffle(positions)

            for row, col in positions:
                directions: List[Direction] = []
                if horizontal_mask[row][col]:
                    directions.append(DIR_DOWN)
                if vertical_mask[row][col]:
                    directions.append(DIR_ACROSS)
                if not directions:
                    continue
                rng.shuffle(directions)
                for direction in directions:
                    if direction == DIR_ACROSS:
                        start_col = col - index
                        if self._can_place_horizontal(
                            word,
                            row,
                            start_col,
                            board,
                            horizontal_mask,
                            vertical_mask,
                        ):
                            self._place_horizontal(
                                word,
                                row,
                                start_col,
                                board,
                                horizontal_mask,
                                letter_positions,
                            )
                            return {
                                "word": word,
                                "clue": entry.get("clue", ""),
                                "category": entry.get("category", ""),
                                "direction": DIR_ACROSS,
                                "start": (row, start_col),
                            }
                    else:
                        start_row = row - index
                        if self._can_place_vertical(
                            word,
                            start_row,
                            col,
                            board,
                            horizontal_mask,
                            vertical_mask,
                        ):
                            self._place_vertical(
                                word,
                                start_row,
                                col,
                                board,
                                vertical_mask,
                                letter_positions,
                            )
                            return {
                                "word": word,
                                "clue": entry.get("clue", ""),
                                "category": entry.get("category", ""),
                                "direction": DIR_DOWN,
                                "start": (start_row, col),
                            }
        return None

    def _can_place_horizontal(
        self,
        word: str,
        row: int,
        col: int,
        board: List[List[str]],
        horizontal_mask: List[List[bool]],
        vertical_mask: List[List[bool]],
    ) -> bool:
        rows = len(board)
        if rows == 0:
            return False
        cols = len(board[0])
        if col < 0 or col + len(word) > cols:
            return False
        if row < 0 or row >= rows:
            return False
        if col > 0 and board[row][col - 1] != "":
            return False
        end_col = col + len(word)
        if end_col < cols and board[row][end_col] != "":
            return False

        intersects = False

        for i, letter in enumerate(word):
            c = col + i
            existing = board[row][c]
            if existing and existing != letter:
                return False
            if horizontal_mask[row][c]:
                return False
            if not existing:
                if (row > 0 and board[row - 1][c] != "") or (
                    row + 1 < rows and board[row + 1][c] != ""
                ):
                    return False
            else:
                if not vertical_mask[row][c]:
                    return False
                intersects = True
        return intersects

    def _can_place_vertical(
        self,
        word: str,
        row: int,
        col: int,
        board: List[List[str]],
        horizontal_mask: List[List[bool]],
        vertical_mask: List[List[bool]],
    ) -> bool:
        rows = len(board)
        if rows == 0:
            return False
        cols = len(board[0])
        if col < 0 or col >= cols:
            return False
        if row < 0 or row + len(word) > rows:
            return False
        if row > 0 and board[row - 1][col] != "":
            return False
        end_row = row + len(word)
        if end_row < rows and board[end_row][col] != "":
            return False

        intersects = False

        for i, letter in enumerate(word):
            r = row + i
            existing = board[r][col]
            if existing and existing != letter:
                return False
            if vertical_mask[r][col]:
                return False
            if not existing:
                if (col > 0 and board[r][col - 1] != "") or (
                    col + 1 < cols and board[r][col + 1] != ""
                ):
                    return False
            else:
                if not horizontal_mask[r][col]:
                    return False
                intersects = True
        return intersects

    def _place_horizontal(
        self,
        word: str,
        row: int,
        col: int,
        board: List[List[str]],
        horizontal_mask: List[List[bool]],
        letter_positions: Dict[str, List[Position]],
    ) -> None:
        for i, letter in enumerate(word):
            c = col + i
            existing = board[row][c]
            if not existing:
                board[row][c] = letter
                self._record_letter(letter_positions, letter, (row, c))
            horizontal_mask[row][c] = True

    def _place_vertical(
        self,
        word: str,
        row: int,
        col: int,
        board: List[List[str]],
        vertical_mask: List[List[bool]],
        letter_positions: Dict[str, List[Position]],
    ) -> None:
        for i, letter in enumerate(word):
            r = row + i
            existing = board[r][col]
            if not existing:
                board[r][col] = letter
                self._record_letter(letter_positions, letter, (r, col))
            vertical_mask[r][col] = True

    def _record_letter(
        self,
        letter_positions: Dict[str, List[Position]],
        letter: str,
        pos: Position,
    ) -> None:
        letter_positions.setdefault(letter, []).append(pos)

    def _create_matrix(self, rows: int, cols: int, default_value: Any) -> List[List[Any]]:
        return [[default_value for _ in range(cols)] for _ in range(rows)]

    def _build_layout_result(
        self, board: List[List[str]], entries: List[EntryDict]
    ) -> Optional[PuzzleLayout]:
        rows = len(board)
        if rows == 0:
            return None
        cols = len(board[0])
        for r in range(rows):
            for c in range(cols):
                if board[r][c] == "":
                    board[r][c] = "#"

        bounds = self._find_letter_bounds(board)
        if bounds is None:
            return None

        min_row, max_row, min_col, max_col = bounds
        trimmed_board: List[List[str]] = []
        trimmed_mask: List[str] = []
        for r in range(min_row, max_row + 1):
            row_array: List[str] = []
            mask_row_chars: List[str] = []
            for c in range(min_col, max_col + 1):
                value = board[r][c]
                row_array.append(value)
                mask_row_chars.append("." if value != "#" else "#")
            trimmed_board.append(row_array)
            trimmed_mask.append("".join(mask_row_chars))

        trimmed_entries: List[EntryDict] = []
        for entry in entries:
            start_row, start_col = entry.get("start", (0, 0))
            trimmed_entry = dict(entry)
            trimmed_entry["start"] = [start_row - min_row, start_col - min_col]
            trimmed_entries.append(trimmed_entry)

        return PuzzleLayout(trimmed_board, trimmed_mask, trimmed_entries)

    def _find_letter_bounds(self, board: List[List[str]]) -> Optional[Tuple[int, int, int, int]]:
        rows = len(board)
        if rows == 0:
            return None
        cols = len(board[0])
        min_row = rows
        max_row = -1
        min_col = cols
        max_col = -1

        for r in range(rows):
            for c in range(cols):
                value = board[r][c]
                if value == "#" or value == "":
                    continue
                if r < min_row:
                    min_row = r
                if r > max_row:
                    max_row = r
                if c < min_col:
                    min_col = c
                if c > max_col:
                    max_col = c

        if max_row == -1 or max_col == -1:
            return None
        return min_row, max_row, min_col, max_col
