"""
Minimal .puz file parser for CrosswordAP
Based on .puz format specification: https://code.google.com/archive/p/puz/wikis/FileFormat.wiki
"""

import struct
from typing import Tuple, List, Dict, Optional


class PuzParseError(Exception):
    """Raised when .puz file cannot be parsed"""
    pass


class PuzPuzzle:
    """Represents a parsed crossword puzzle from a .puz file"""
    
    def __init__(self):
        self.width: int = 0
        self.height: int = 0
        self.solution: List[str] = []  # Grid solution (with black squares as '.')
        self.fill: List[str] = []  # Player fill (usually empty, '-' for empty cells)
        self.title: str = ""
        self.author: str = ""
        self.copyright: str = ""
        self.clues: List[str] = []  # All clues in order (across then down)
        self.notes: str = ""
        
    def get_grid(self) -> List[List[str]]:
        """Convert solution string to 2D grid"""
        grid = []
        for row in range(self.height):
            start = row * self.width
            end = start + self.width
            grid.append(list(self.solution[start:end]))
        return grid
    
    def get_clue_map(self) -> Dict[str, List[Tuple[int, str]]]:
        """
        Returns clues organized by direction.
        Format: {"across": [(number, clue), ...], "down": [(number, clue), ...]}
        """
        grid = self.get_grid()
        numbering = self._get_numbering(grid)
        
        across_clues = []
        down_clues = []
        clue_idx = 0
        
        # Process in standard order: across first, then down
        for direction in ["across", "down"]:
            for number, positions in sorted(numbering.items()):
                if direction in positions:
                    clue = self.clues[clue_idx] if clue_idx < len(self.clues) else ""
                    if direction == "across":
                        across_clues.append((number, clue))
                    else:
                        down_clues.append((number, clue))
                    clue_idx += 1
        
        return {
            "across": across_clues,
            "down": down_clues
        }
    
    def _get_numbering(self, grid: List[List[str]]) -> Dict[int, Dict[str, Tuple[int, int]]]:
        """
        Calculate clue numbering based on grid.
        Returns: {clue_number: {"across": (row, col), "down": (row, col)}}
        """
        numbering = {}
        current_number = 1
        
        for r in range(self.height):
            for c in range(self.width):
                if grid[r][c] == '.':  # Black square
                    continue
                
                # Check if this cell starts an across word
                starts_across = (c == 0 or grid[r][c-1] == '.') and (c + 1 < self.width and grid[r][c+1] != '.')
                
                # Check if this cell starts a down word
                starts_down = (r == 0 or grid[r-1][c] == '.') and (r + 1 < self.height and grid[r+1][c] != '.')
                
                if starts_across or starts_down:
                    if current_number not in numbering:
                        numbering[current_number] = {}
                    
                    if starts_across:
                        numbering[current_number]["across"] = (r, c)
                    if starts_down:
                        numbering[current_number]["down"] = (r, c)
                    
                    current_number += 1
        
        return numbering


def parse_puz_file(file_path: str) -> PuzPuzzle:
    """
    Parse a .puz file and return a PuzPuzzle object.
    
    Args:
        file_path: Path to the .puz file
        
    Returns:
        PuzPuzzle object containing puzzle data
        
    Raises:
        PuzParseError: If file cannot be parsed
    """
    try:
        with open(file_path, 'rb') as f:
            data = f.read()
    except IOError as e:
        raise PuzParseError(f"Cannot read file: {e}")
    
    if len(data) < 52:
        raise PuzParseError("File too small to be a valid .puz file")
    
    puzzle = PuzPuzzle()
    
    # Parse header (first 52 bytes)
    # Checksum values we'll skip for now
    offset = 0x2C  # Skip to width/height
    
    puzzle.width = data[offset]
    puzzle.height = data[offset + 1]
    
    if puzzle.width == 0 or puzzle.height == 0:
        raise PuzParseError("Invalid grid dimensions")
    
    num_cells = puzzle.width * puzzle.height
    
    # Skip clue count and puzzle type for now
    offset = 0x34  # Start of solution
    
    # Read solution (answer grid)
    solution_end = offset + num_cells
    if len(data) < solution_end:
        raise PuzParseError("File too short for grid data")
    
    puzzle.solution = [chr(b) if b != 0x2E else '.' for b in data[offset:solution_end]]
    offset = solution_end
    
    # Read fill (player state) - usually all dashes
    fill_end = offset + num_cells
    if len(data) < fill_end:
        raise PuzParseError("File too short for fill data")
    
    puzzle.fill = [chr(b) if b != 0x2D else '-' for b in data[offset:fill_end]]
    offset = fill_end
    
    # Read null-terminated strings: title, author, copyright, then clues
    strings = []
    current_string = bytearray()
    
    while offset < len(data):
        byte = data[offset]
        offset += 1
        
        if byte == 0:  # Null terminator
            try:
                strings.append(current_string.decode('iso-8859-1'))
            except UnicodeDecodeError:
                strings.append(current_string.decode('utf-8', errors='replace'))
            current_string = bytearray()
        else:
            current_string.append(byte)
    
    # Assign strings to puzzle fields
    if len(strings) < 3:
        raise PuzParseError("Missing required string fields")
    
    puzzle.title = strings[0]
    puzzle.author = strings[1]
    puzzle.copyright = strings[2]
    
    # Remaining strings are clues (and possibly notes at the end)
    puzzle.clues = strings[3:]
    
    # Notes might be in a special section (we'll skip advanced parsing for now)
    # If last string looks like notes, separate it
    if puzzle.clues and len(puzzle.clues[-1]) > 100:
        puzzle.notes = puzzle.clues.pop()
    
    return puzzle


def validate_puzzle_for_apworld(puzzle: PuzPuzzle, max_words: int = 30) -> Tuple[bool, Optional[str]]:
    """
    Validate that a puzzle is suitable for CrosswordAP.
    
    Returns:
        (is_valid, error_message)
    """
    # Check grid size (reasonable limits for display)
    if puzzle.width > 21 or puzzle.height > 21:
        return False, f"Grid too large: {puzzle.width}x{puzzle.height} (max 21x21)"
    
    if puzzle.width < 5 or puzzle.height < 5:
        return False, f"Grid too small: {puzzle.width}x{puzzle.height} (min 5x5)"
    
    # Count words
    clue_map = puzzle.get_clue_map()
    total_words = len(clue_map["across"]) + len(clue_map["down"])
    
    if total_words > max_words:
        return False, f"Too many words: {total_words} (max {max_words})"
    
    if total_words < 10:
        return False, f"Too few words: {total_words} (min 10)"
    
    # Verify we have clues for all words
    if len(puzzle.clues) < total_words:
        return False, f"Missing clues: found {len(puzzle.clues)}, expected {total_words}"
    
    return True, None


if __name__ == "__main__":
    # Simple test
    import sys
    if len(sys.argv) > 1:
        try:
            puzzle = parse_puz_file(sys.argv[1])
            print(f"Title: {puzzle.title}")
            print(f"Author: {puzzle.author}")
            print(f"Grid: {puzzle.width}x{puzzle.height}")
            print(f"Clues: {len(puzzle.clues)}")
            
            clue_map = puzzle.get_clue_map()
            print(f"Across: {len(clue_map['across'])}")
            print(f"Down: {len(clue_map['down'])}")
            
            valid, error = validate_puzzle_for_apworld(puzzle)
            if valid:
                print("✓ Valid for CrosswordAP")
            else:
                print(f"✗ Invalid: {error}")
                
        except PuzParseError as e:
            print(f"Error: {e}")
    else:
        print("Usage: python puz_parser.py <file.puz>")
