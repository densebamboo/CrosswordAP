from __future__ import annotations

from typing import Dict, List, Optional, Tuple

from BaseClasses import Region, Item, ItemClassification
from worlds.AutoWorld import WebWorld, World
from worlds.generic.Rules import set_rule

from .items import CLUE_ITEM_TABLE, CrosswordItem
from .locations import CLUE_LOCATION_TABLE, CrosswordLocation
from .options import CrosswordOptions, ColorIndicator, option_groups
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
    data_version = 3
    required_client_version = (0, 6, 3)

    options_dataclass = CrosswordOptions
    options: CrosswordOptions
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
        self._distributed_clue_count = 0

    def _compute_clue_item_count(self) -> int:
        total = self._total_words()
        initial = min(total, self.options.initial_clues.value)
        return min(max(0, total - initial), max(0, total - 1))

    def create_items(self) -> None:
        self._ensure_puzzle_generated()
        total = self._total_words()
        clue_count = self._compute_clue_item_count()
        filler_count = max(0, total - clue_count)
        self._distributed_clue_count = clue_count
        
        # Add Color Indicator if enabled
        indicator_mode = int(self.options.color_indicator.value)
        if indicator_mode == ColorIndicator.option_item:
            if filler_count > 0:
                filler_count -= 1
            self.multiworld.itempool.append(self.create_item("Color Indicator"))
        
        # Add Letter Hints if enabled
        letter_hints_enabled = bool(self.options.letter_hints_enabled.value)
        if letter_hints_enabled:
            # Replace ALL filler items with Letter Hints
            for _ in range(filler_count):
                self.multiworld.itempool.append(self.create_item("Letter Hint"))
            filler_count = 0
        
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
        initial_free = min(total, self.options.initial_clues.value)
        self._distributed_clue_count = self._compute_clue_item_count()
        for index in range(1, total + 1):
            location_name = f"Solved {index} Words"
            location_id = CLUE_LOCATION_TABLE[location_name]
            loc = CrosswordLocation(self.player, location_name, location_id, puzzle)
            
            # Prevent Color Indicator from being placed too early (before 10%) or too late (after 70%)
            min_for_indicator = max(1, int(total * 0.10))
            max_for_indicator = max(1, int(total * 0.80))
            if index < min_for_indicator or index > max_for_indicator:
                # Can't place Color Indicator here
                loc.item_rule = lambda item: getattr(item, "name", None) != "Color Indicator"
            
            # Ensure the last check can never be a Clue (so the final word isn't forced without a clue)
            if index == total:
                loc.item_rule = lambda item: getattr(item, "name", None) not in ["Clue", "Color Indicator"]
            
            required_clues = min(max(0, index - initial_free), self._distributed_clue_count)
            if required_clues > 0:
                set_rule(
                    loc,
                    lambda state, required=required_clues, player=self.player: state.has(
                        "Clue", player, required
                    ),
                )
            puzzle.locations.append(loc)

        victory_location = CrosswordLocation(
            self.player,
            "Crossword Completed",
            CLUE_LOCATION_TABLE["Crossword Completed"],
            puzzle,
        )
        victory_location.event = True
        victory_location.place_locked_item(self.create_item("Crossword Completed"))
        if self._distributed_clue_count > 0:
            set_rule(
                victory_location,
                lambda state, required=self._distributed_clue_count, player=self.player: state.has(
                    "Clue", player, required
                ),
            )
        puzzle.locations.append(victory_location)

    def set_rules(self) -> None:
        # Completion is tied to the Crossword Completed item awarded for the final word.
        self.multiworld.completion_condition[self.player] = (
            lambda state, player=self.player: state.has("Crossword Completed", player)
        )

    def fill_slot_data(self) -> Dict:
        self._ensure_puzzle_generated()
        self._distributed_clue_count = self._compute_clue_item_count()
        layout_dict: Dict = {}
        entry_count = 0
        if self._puzzle_layout:
            layout_dict = self._puzzle_layout.as_dict()
            entry_count = len(layout_dict.get("entries", []))
        slot_total = self._total_words()
        indicator_mode = int(self.options.color_indicator.value)
        indicator_enabled = indicator_mode == ColorIndicator.option_start_with
        starting_hints = int(self.options.starting_letter_hints.value)
        hints_enabled = bool(self.options.letter_hints_enabled.value)
        return {
            "total_words": slot_total,
            "initial_clues": min(slot_total, self.options.initial_clues.value),
            "puzzle_layout": layout_dict,
            "puzzle_seed": self._puzzle_seed,
            "entry_count": entry_count,
            "clue_item_count": self._distributed_clue_count,
            "completion_location": CLUE_LOCATION_TABLE["Crossword Completed"],
            "state_overlay_enabled": indicator_enabled,
            "color_indicator": indicator_mode,
            "letter_hints_enabled": hints_enabled,
            "starting_letter_hints": starting_hints,
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
        # Filter out disabled difficulty categories
        word_entries = self._filter_by_difficulty(word_entries)
        
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

    def _filter_by_difficulty(self, word_entries: List[Dict]) -> List[Dict]:
        """Filter word entries based on difficulty toggles."""
        excluded_categories = set()
        
        if not self.options.include_easy_words.value:
            excluded_categories.add("EASY WORDS")
        if not self.options.include_medium_words.value:
            excluded_categories.add("MEDIUM WORDS")
        if not self.options.include_hard_words.value:
            excluded_categories.add("HARD WORDS")
        
        if not excluded_categories:
            return word_entries
        
        return [
            entry for entry in word_entries
            if entry.get("category", "") not in excluded_categories
        ]
