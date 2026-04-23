from dataclasses import dataclass

from Options import Choice, Range, Toggle, OptionGroup, PerGameCommonOptions


class TotalWords(Range):
    """Total number of words to place in the crossword puzzle."""

    display_name = "Total Words"
    range_start = 10
    range_end = 30
    default = 20


class InitialClues(Range):
    """How many clues are revealed to the player at the start."""

    display_name = "Initial Revealed Clues"
    range_start = 3
    range_end = 30
    default = 5


class ColorIndicator(Choice):
    """How the Color Indicator is configured.
    The Color Indicator turns cells green and locks them in if correct and turns them red if incorrect.
    
    start_with: Color Indicator will be available from the start.
    item: Color Indicator will be added to the item pool and enabled once found.
    no_indicator: Color Indicator will be disabled and will not be added to the item pool."""
    display_name = "Color Indicator"
    option_start_with = 0
    option_item = 1
    option_no_indicator = 2
    default = 1


class LetterHintsEnabled(Toggle):
    """Enable Letter Hints that reveal individual letters when used.
    Right-Click on a space to use a Letter Hint.

    If true, all filler items will become Letter Hints.
    If false, receive nothing as filler."""
    display_name = "Enable Letter Hints"
    default = 1


class StartingLetterHints(Range):
    """Number of Letter Hints available at the start.
    Not Applicable if letter_hints_enabled is set to false."""
    display_name = "Starting Letter Hints"
    range_start = 0
    range_end = 50
    default = 3


class IncludeEasyWords(Toggle):
    """Include easy difficulty words in the puzzle."""
    display_name = "Include Easy Words"
    default = 1


class IncludeMediumWords(Toggle):
    """Include medium difficulty words in the puzzle."""
    display_name = "Include Medium Words"
    default = 1


class IncludeHardWords(Toggle):
    """Include hard difficulty words in the puzzle."""
    display_name = "Include Hard Words"
    default = 0


option_groups = [
    OptionGroup("Crossword Setup", [
        TotalWords,
        InitialClues,
    ]),
    OptionGroup("Word Difficulty", [
        IncludeEasyWords,
        IncludeMediumWords,
        IncludeHardWords,
    ]),
    OptionGroup("Hints and Items", [
        ColorIndicator,
        LetterHintsEnabled,
        StartingLetterHints,
    ]),
]


@dataclass
class CrosswordOptions(PerGameCommonOptions):
    """Options for the Crossword Archipelago world."""

    total_words: TotalWords
    initial_clues: InitialClues
    color_indicator: ColorIndicator
    letter_hints_enabled: LetterHintsEnabled
    starting_letter_hints: StartingLetterHints
    include_easy_words: IncludeEasyWords
    include_medium_words: IncludeMediumWords
    include_hard_words: IncludeHardWords
    
    def __post_init__(self):
        if not (self.include_easy_words.value or self.include_medium_words.value or self.include_hard_words.value):
            self.include_easy_words.value = True

