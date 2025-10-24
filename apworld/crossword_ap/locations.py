from BaseClasses import Location

# Each location corresponds to solving the nth word in the crossword.
CLUE_LOCATION_TABLE: dict[str, int] = {f"Solved {index} Words": 2000 + index for index in range(1, 41)}


class CrosswordLocation(Location):
    game: str = "CrosswordAP"

    def __init__(self, player: int, name: str, address: int, parent_region) -> None:
        super().__init__(player, name, address, parent_region)
