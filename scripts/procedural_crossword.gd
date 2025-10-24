extends RefCounted
class_name ProceduralCrosswordGenerator

const DIR_ACROSS := "across"
const DIR_DOWN := "down"
const STARTER_DENYLIST := {
	"ACOUSTICS": true,
}

func generate(
	word_list: CrosswordWordList,
	rows: int,
	cols: int,
	min_length: int,
	max_words: int,
	seed: int,
	category_weights: Dictionary = {}
) -> Dictionary:
	if word_list == null or rows <= 0 or cols <= 0:
		return {}

	var rng := RandomNumberGenerator.new()
	if seed != 0:
		rng.seed = seed
	else:
		rng.randomize()

	var weights := _sanitize_category_weights(category_weights)

	var candidates: Array = word_list.get_all_entries()
	if candidates.is_empty():
		return {}

	candidates = _filtered_entries(candidates, min_length, rows, cols)
	if candidates.is_empty():
		return {}

	candidates = _weighted_shuffle(candidates, weights, rng)
	if candidates.is_empty():
		return {}

	var board: Array = _create_matrix(rows, cols, "")
	var horizontal_mask: Array = _create_matrix(rows, cols, false)
	var vertical_mask: Array = _create_matrix(rows, cols, false)
	var letter_positions: Dictionary = {}
	var placed_entries: Array = []
	var used_words: Dictionary = {}

	var first_entry: Dictionary = _select_start_entry(candidates, min_length, cols, rng, weights)
	if first_entry.is_empty():
		return {}

	var first_word: String = first_entry["word"]
	# Randomize initial placement and direction to diversify offline seeds
	var first_dir := DIR_ACROSS
	var first_row: int
	var first_col: int
	if rng.randf() < 0.5 and first_word.length() <= cols:
		# Horizontal
		first_row = rng.randi_range(0, rows - 1)
		first_col = rng.randi_range(0, max(1, cols - first_word.length()))
		_place_horizontal(first_word, first_row, first_col, board, horizontal_mask, letter_positions)
		first_dir = DIR_ACROSS
	else:
		# Vertical (fallback to horizontal if too tall)
		if first_word.length() <= rows:
			first_row = rng.randi_range(0, max(1, rows - first_word.length()))
			first_col = rng.randi_range(0, cols - 1)
			_place_vertical(first_word, first_row, first_col, board, vertical_mask, letter_positions)
			first_dir = DIR_DOWN
		else:
			first_row = rng.randi_range(0, rows - 1)
			first_col = rng.randi_range(0, max(1, cols - first_word.length()))
			_place_horizontal(first_word, first_row, first_col, board, horizontal_mask, letter_positions)
			first_dir = DIR_ACROSS

	used_words[first_word] = true
	placed_entries.append({
		"word": first_word,
		"clue": first_entry.get("clue", ""),
		"category": first_entry.get("category", ""),
		"direction": first_dir,
		"start": Vector2i(first_row, first_col),
	})

	var failures: int = 0
	var max_failures: int = max(200, max_words * 10)

	for entry in candidates:
		var word: String = entry["word"]
		if used_words.has(word):
			continue
		if word.length() < min_length:
			continue
		if word.length() > max(rows, cols):
			continue

		var placement: Dictionary = _try_place_entry(
			entry,
			board,
			horizontal_mask,
			vertical_mask,
			letter_positions,
			rng
		)
		if not placement.is_empty():
			placed_entries.append(placement)
			used_words[word] = true
			failures = 0
			if placed_entries.size() >= max_words:
				break
		else:
			failures += 1
			if failures >= max_failures:
				break

	if placed_entries.size() < 2:
		return {}

	return _build_layout_result(board, placed_entries)

func _filtered_entries(entries: Array, min_length: int, rows: int, cols: int) -> Array:
	var filtered: Array = []
	var max_dimension: int = max(rows, cols)
	for entry in entries:
		var word: String = entry.get("word", "")
		if word.is_empty():
			continue
		var length: int = word.length()
		if length < min_length:
			continue
		if length > max_dimension:
			continue
		filtered.append(entry.duplicate(true))
	return filtered

func _sanitize_category_weights(category_weights: Dictionary) -> Dictionary:
	var weights: Dictionary = {}
	if category_weights != null:
		for key in category_weights.keys():
			var value := float(category_weights[key])
			if value < 0.0:
				value = 0.0
			weights[str(key)] = value
	if not weights.has("_default"):
		weights["_default"] = 1.0
	elif weights["_default"] <= 0.0:
		weights["_default"] = 0.0
	return weights

func _weighted_shuffle(entries: Array, weights: Dictionary, rng: RandomNumberGenerator) -> Array:
	var keyed: Array = []
	var default_weight: float = max(float(weights.get("_default", 1.0)), 0.0)
	for entry in entries:
		var category: String = str(entry.get("category", ""))
		var weight: float = max(float(weights.get(category, default_weight)), 0.0)
		if weight <= 0.0:
			continue
		var random_value: float = rng.randf()
		if random_value <= 0.0:
			random_value = 0.000001
		var key: float = pow(random_value, 1.0 / weight)
		keyed.append({
			"key": key,
			"entry": entry,
		})
	keyed.sort_custom(func(a, b):
		return a["key"] > b["key"]
	)
	var result: Array = []
	for item in keyed:
		result.append(item["entry"])
	return result

func _select_start_entry(entries: Array, min_length: int, cols: int, rng: RandomNumberGenerator, weights: Dictionary) -> Dictionary:
	var options: Array = []
	for entry in entries:
		var word: String = entry["word"]
		if word.length() >= min_length and word.length() <= cols:
			options.append(entry)
	if options.is_empty():
		return {}
	options = _weighted_shuffle(options, weights, rng)
	if options.is_empty():
		return {}
	# Shuffle and choose the first not in the denylist to avoid repetition
	_shuffle_array(options, rng)
	for entry in options:
		var w: String = entry.get("word", "")
		if not STARTER_DENYLIST.has(w):
			return entry
	# Fallback to first option
	return options[0]

func _try_place_entry(
	entry: Dictionary,
	board: Array,
	horizontal_mask: Array,
	vertical_mask: Array,
	letter_positions: Dictionary,
	rng: RandomNumberGenerator
) -> Dictionary:
	var word: String = entry["word"]
	var length: int = word.length()
	var indices: Array = []
	for i in range(length):
		var letter := word[i]
		if letter_positions.has(letter):
			indices.append(i)
	if indices.is_empty():
		return {}
	_shuffle_array(indices, rng)

	for index in indices:
		var letter := word[index]
		var positions: Array = letter_positions.get(letter, [])
		if positions.is_empty():
			continue
		var samples: Array = positions.duplicate()
		_shuffle_array(samples, rng)
		for pos in samples:
			var row: int = pos.x
			var col: int = pos.y
			var directions: Array = []
			if horizontal_mask[row][col]:
				directions.append(DIR_DOWN)
			if vertical_mask[row][col]:
				directions.append(DIR_ACROSS)
			if directions.is_empty():
				continue
			_shuffle_array(directions, rng)
			for direction in directions:
				if direction == DIR_ACROSS:
					var start_col: int = col - index
					if _can_place_horizontal(
						word,
						row,
						start_col,
						board,
						horizontal_mask,
						vertical_mask
					):
						_place_horizontal(
							word,
							row,
							start_col,
							board,
							horizontal_mask,
							letter_positions
						)
						return {
							"word": word,
							"clue": entry.get("clue", ""),
							"category": entry.get("category", ""),
							"direction": DIR_ACROSS,
							"start": Vector2i(row, start_col),
						}
				else:
					var start_row: int = row - index
					if _can_place_vertical(
						word,
						start_row,
						col,
						board,
						horizontal_mask,
						vertical_mask
					):
						_place_vertical(
							word,
							start_row,
							col,
							board,
							vertical_mask,
							letter_positions
						)
						return {
							"word": word,
							"clue": entry.get("clue", ""),
							"category": entry.get("category", ""),
							"direction": DIR_DOWN,
							"start": Vector2i(start_row, col),
						}
	return {}

func _can_place_horizontal(
	word: String,
	row: int,
	col: int,
	board: Array,
	horizontal_mask: Array,
	vertical_mask: Array
) -> bool:
	var rows := board.size()
	if rows == 0:
		return false
	var cols: int = board[0].size()
	if col < 0 or col + word.length() > cols:
		return false
	if row < 0 or row >= rows:
		return false
	if col > 0 and board[row][col - 1] != "":
		return false
	var end_col := col + word.length()
	if end_col < cols and board[row][end_col] != "":
		return false

	var intersects := false

	for i in range(word.length()):
		var c := col + i
		var existing: String = board[row][c]
		var letter := word[i]
		if existing != "" and existing != letter:
			return false
		if horizontal_mask[row][c]:
			return false
		if existing == "":
			if (row > 0 and board[row - 1][c] != "") or (row + 1 < rows and board[row + 1][c] != ""):
				return false
		else:
			if not vertical_mask[row][c]:
				return false
			intersects = true
	return intersects

func _can_place_vertical(
	word: String,
	row: int,
	col: int,
	board: Array,
	horizontal_mask: Array,
	vertical_mask: Array
) -> bool:
	var rows := board.size()
	if rows == 0:
		return false
	var cols: int = board[0].size()
	if col < 0 or col >= cols:
		return false
	if row < 0 or row + word.length() > rows:
		return false
	if row > 0 and board[row - 1][col] != "":
		return false
	var end_row := row + word.length()
	if end_row < rows and board[end_row][col] != "":
		return false

	var intersects := false

	for i in range(word.length()):
		var r := row + i
		var existing: String = board[r][col]
		var letter := word[i]
		if existing != "" and existing != letter:
			return false
		if vertical_mask[r][col]:
			return false
		if existing == "":
			if (col > 0 and board[r][col - 1] != "") or (col + 1 < cols and board[r][col + 1] != ""):
				return false
		else:
			if not horizontal_mask[r][col]:
				return false
			intersects = true
	return intersects

func _place_horizontal(
	word: String,
	row: int,
	col: int,
	board: Array,
	horizontal_mask: Array,
	letter_positions: Dictionary
) -> void:
	for i in range(word.length()):
		var c := col + i
		var existing: String = board[row][c]
		var letter := word[i]
		if existing == "":
			board[row][c] = letter
			_record_letter(letter_positions, letter, Vector2i(row, c))
		horizontal_mask[row][c] = true

func _place_vertical(
	word: String,
	row: int,
	col: int,
	board: Array,
	vertical_mask: Array,
	letter_positions: Dictionary
) -> void:
	for i in range(word.length()):
		var r := row + i
		var existing: String = board[r][col]
		var letter := word[i]
		if existing == "":
			board[r][col] = letter
			_record_letter(letter_positions, letter, Vector2i(r, col))
		vertical_mask[r][col] = true

func _record_letter(letter_positions: Dictionary, letter: String, pos: Vector2i) -> void:
	if not letter_positions.has(letter):
		letter_positions[letter] = []
	var arr: Array = letter_positions[letter]
	arr.append(pos)

func _create_matrix(rows: int, cols: int, default_value) -> Array:
	var matrix: Array = []
	for r in range(rows):
		var row: Array = []
		for c in range(cols):
			row.append(default_value)
		matrix.append(row)
	return matrix

func _shuffle_array(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var temp = arr[i]
		arr[i] = arr[j]
		arr[j] = temp

func _build_layout_result(board: Array, entries: Array) -> Dictionary:
	var rows: int = board.size()
	if rows == 0:
		return {}
	var cols: int = board[0].size()
	for r in range(rows):
		for c in range(cols):
			if board[r][c] == "":
				board[r][c] = "#"

	var bounds: Dictionary = _find_letter_bounds(board)
	if bounds.is_empty():
		return {}

	var min_row: int = bounds["min_row"]
	var max_row: int = bounds["max_row"]
	var min_col: int = bounds["min_col"]
	var max_col: int = bounds["max_col"]

	var trimmed_board: Array = []
	var trimmed_mask: Array[String] = []
	for r in range(min_row, max_row + 1):
		var row_array: Array = []
		var mask_row: String = ""
		for c in range(min_col, max_col + 1):
			var value: String = board[r][c]
			row_array.append(value)
			if value != "#":
				mask_row += "."
			else:
				mask_row += "#"
		trimmed_board.append(row_array)
		trimmed_mask.append(mask_row)

	var trimmed_entries: Array = []
	for entry in entries:
		var new_entry: Dictionary = entry.duplicate(true)
		var start: Vector2i = new_entry.get("start", Vector2i.ZERO)
		new_entry["start"] = Vector2i(start.x - min_row, start.y - min_col)
		trimmed_entries.append(new_entry)

	return {
		"board": trimmed_board,
		"mask": trimmed_mask,
		"entries": trimmed_entries,
	}

func _find_letter_bounds(board: Array) -> Dictionary:
	var rows: int = board.size()
	if rows == 0:
		return {}
	var cols: int = board[0].size()
	var min_row: int = rows
	var max_row: int = -1
	var min_col: int = cols
	var max_col: int = -1

	for r in range(rows):
		var row_array: Array = board[r]
		for c in range(cols):
			var value: String = row_array[c]
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
		return {}

	return {
		"min_row": min_row,
		"max_row": max_row,
		"min_col": min_col,
		"max_col": max_col,
	}
