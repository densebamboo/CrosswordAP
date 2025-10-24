from dataclasses import dataclass

from Options import Range, OptionGroup, PerGameCommonOptions


class TotalWords(Range):
    """Total number of words to place in the crossword puzzle."""

    display_name = "Total Words"
    range_start = 10
    range_end = 30
    default = 25


class InitialClues(Range):
    """How many clues are revealed to the player at the start."""

    display_name = "Initial Revealed Clues"
    range_start = 0
    range_end = 40
    default = 6


option_groups = [
    OptionGroup("Clue Options", [
        TotalWords,
        InitialClues,
    ])
]


@dataclass
class CrosswordOptions(PerGameCommonOptions):
    """Options for the Crossword Archipelago world."""

    total_words: TotalWords
    initial_clues: InitialClues
