from BaseClasses import Item, ItemClassification

# Item IDs
# - Clue: progression item, multiple copies in pool (one per solved word)
# - Nothing: filler item to avoid unlocking additional clues beyond the pool
# Note: Victory is an event item with no ID and is NOT included here
CLUE_ITEM_TABLE: dict[str, int] = {
    "Clue": 1001,
    "Nothing": 1002,
}


class CrosswordItem(Item):
    game: str = "CrosswordAP"

    def __init__(self, name: str, player: int) -> None:
        super().__init__(name, ItemClassification.progression, CLUE_ITEM_TABLE[name], player)
