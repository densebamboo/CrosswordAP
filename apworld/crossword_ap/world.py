from __future__ import annotations

from typing import Dict, List, Optional, Tuple

from BaseClasses import Region, Item, ItemClassification
from worlds.AutoWorld import WebWorld, World

from .items import CLUE_ITEM_TABLE, CrosswordItem
from .locations import CLUE_LOCATION_TABLE, CrosswordLocation
from .options import CrosswordOptions, option_groups
from .puzzle_generator import CrosswordPuzzleGenerator, PuzzleLayout
from .wordlist import load_word_entries


MIN_WORDS = 10
MAX_WORDS = 30


class CrosswordAPWeb(WebWorld):
    theme = "grassFlowers"
    option_groups = option_groups
    tutorials: List = []


class CrosswordAPWorld(World):
    game = "CrosswordAP"
    web = CrosswordAPWeb()
    data_version = 1
    required_client_version = (0, 6, 2)

    option_definitions = CrosswordOptions
    options_dataclass = CrosswordOptions
    item_name_to_id = CLUE_ITEM_TABLE
    location_name_to_id = CLUE_LOCATION_TABLE
    _puzzle_layout: Optional[PuzzleLayout]
    _puzzle_seed: Optional[int]
    _actual_clue_total: Optional[int]

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._puzzle_layout = None
        self._puzzle_seed = None
        self._actual_clue_total = None

    def create_items(self) -> None:
        self._ensure_puzzle_generated()
        total = self._total_words()
        initial = min(total, self.options.initial_clues.value)
        clue_count = max(0, total - initial)
        filler_count = max(0, total - clue_count)
        for _ in range(clue_count):
            self.multiworld.itempool.append(self.create_item("Clue"))
        for _ in range(filler_count):
            self.multiworld.itempool.append(self.create_item("Nothing"))

    def create_item(self, name: str) -> CrosswordItem:
        if name == "Nothing":
            return Item(name, ItemClassification.filler, CLUE_ITEM_TABLE[name], self.player)
        return CrosswordItem(name, self.player)

    def create_regions(self) -> None:
        self._ensure_puzzle_generated()
        menu = Region("Menu", self.player, self.multiworld)
        puzzle = Region("Crossword Grid", self.player, self.multiworld)

        self.multiworld.regions.append(menu)
        self.multiworld.regions.append(puzzle)

        menu.connect(puzzle)

        total = self._total_words()
        for index in range(1, total + 1):
            location_name = f"Solved {index} Words"
            location_id = CLUE_LOCATION_TABLE[location_name]
            loc = CrosswordLocation(self.player, location_name, location_id, puzzle)
            # Ensure the last check can never be a Clue (so the final word isn't forced without a clue)
            if index == total:
                loc.item_rule = lambda item: getattr(item, "name", None) != "Clue"
            puzzle.locations.append(loc)


    def set_rules(self) -> None:
        # Client-driven completion: generator does not enforce a goal; client will send GOAL on puzzle completion
        self.multiworld.completion_condition[self.player] = (lambda state: True)

    def fill_slot_data(self) -> Dict:
        self._ensure_puzzle_generated()
        layout_dict: Dict = {}
        entry_count = 0
        if self._puzzle_layout:
            layout_dict = self._puzzle_layout.as_dict()
            entry_count = len(layout_dict.get("entries", []))
        slot_total = self._total_words()
        return {
            "total_words": slot_total,
            "initial_clues": min(slot_total, self.options.initial_clues.value),
            "puzzle_layout": layout_dict,
            "puzzle_seed": self._puzzle_seed,
            "entry_count": entry_count,
        }

    def _total_words(self) -> int:
        if self._actual_clue_total is not None:
            return self._actual_clue_total
        # Clamp requested words to supported range.
        requested = int(self.options.total_words.value)
        return max(MIN_WORDS, min(requested, MAX_WORDS))

    def _ensure_puzzle_generated(self) -> None:
        if self._puzzle_layout is not None:
            return

        word_entries = load_word_entries()
        generator = CrosswordPuzzleGenerator(self.random)
        target = self._total_words()
        min_length = 3
        attempts_per_size = 120
        sizes = [15, 17, 19, 21, 23]
        best: Optional[Tuple[int, PuzzleLayout, int]] = None  # (difference, layout, seed)

        for size in sizes:
            for _ in range(attempts_per_size):
                seed = self.random.getrandbits(32)
                layout = generator.generate(
                    word_entries,
                    rows=size,
                    cols=size,
                    min_length=min_length,
                    max_words=target,
                    seed=seed,
                    category_weights=self._default_category_weights(),
                )
                if layout is None:
                    continue
                entry_count = len(layout.entries)
                difference = abs(target - entry_count)
                if entry_count == target:
                    self._puzzle_layout = layout
                    self._puzzle_seed = seed
                    self._actual_clue_total = entry_count
                    return
                if best is None or difference < best[0]:
                    best = (difference, layout, seed)

        if best is None:
            raise RuntimeError("Failed to generate a crossword puzzle with the available word list.")

        _, layout, seed = best
        self._puzzle_layout = layout
        self._puzzle_seed = seed
        self._actual_clue_total = len(layout.entries)

    @staticmethod
    def _default_category_weights() -> Dict[str, float]:
        return {
            "EASY WORDS": 0.7,
            "MEDIUM WORDS": 1.2,
            "HARD WORDS": 0.7,
            "_default": 1.0,
        }
