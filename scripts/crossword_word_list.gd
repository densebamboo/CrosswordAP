extends RefCounted
class_name CrosswordWordList

const DEFAULT_PATH := "res://assets/crossword_wordlist.txt"

var entries_by_length: Dictionary = {}    # length -> Array[Dictionary]
var all_entries: Array = []               # each: {word, clue, category}

static func from_file(path: String = DEFAULT_PATH) -> CrosswordWordList:
	var list := CrosswordWordList.new()
	var ok := list._load_from_file(path)
	if not ok:
		return null
	return list

func get_entries_for_length(length: int) -> Array:
	if not entries_by_length.has(length):
		return []
	return entries_by_length[length]

func get_all_entries() -> Array:
	return all_entries.duplicate(true)

func _load_from_file(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Unable to open word list: %s" % path)
		return false

	var current_category := ""
	while file.get_position() < file.get_length():
		var raw_line := file.get_line()
		var line := raw_line.strip_edges()

		if line.is_empty():
			continue

		var sep_index := line.find(":")
		if sep_index == -1:
			current_category = line
			continue

		var lhs := line.substr(0, sep_index).strip_edges()
		var rhs := line.substr(sep_index + 1).strip_edges()

		if rhs.is_empty():
			current_category = lhs
			continue

		var word := lhs.to_upper()
		var clue := rhs

		var entry := {
			"word": word,
			"clue": clue,
			"category": current_category,
		}

		all_entries.append(entry)

		var length := word.length()
		if not entries_by_length.has(length):
			entries_by_length[length] = []
		entries_by_length[length].append(entry)

	return true
