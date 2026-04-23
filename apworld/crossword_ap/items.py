from BaseClasses import Item, ItemClassification

# Item IDs
# - Clue: progression item, multiple copies in pool (one per solved word)
# - Nothing: filler item to avoid unlocking additional clues beyond the pool
# - Victory: progression item awarded on puzzle completion (event location)
CLUE_ITEM_TABLE: dict[str, int] = {
    "Clue": 1001,
    "Nothing": 1002,
    "Crossword Completed": 1003,
    "Color Indicator": 1004,
    "Letter Hint": 1005,
}


class CrosswordItem(Item):
    game: str = "CrosswordAP"

    def __init__(self, name: str, player: int) -> None:
        if name == "Clue":
            classification = ItemClassification.progression
        elif name == "Crossword Completed":
            classification = ItemClassification.progression
        elif name == "Color Indicator":
            classification = ItemClassification.useful
        elif name == "Letter Hint":
            classification = ItemClassification.useful
        else:
            classification = ItemClassification.filler
        super().__init__(name, classification, CLUE_ITEM_TABLE[name], player)
        if name == "Crossword Completed":
            self.event = True
