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

func _read_text_resource_or_file(path: String) -> String:
	# Try loading via ResourceLoader (if imported as a resource in the editor)
	var res := ResourceLoader.load(path)
	if res != null and res.has_method("get_text"):
		return String(res.call("get_text"))
	# Fallback to raw file access
	var file := FileAccess.open(path, FileAccess.READ)
	if file != null:
		return file.get_as_text()
	# Final fallback: embedded backup script, if present
	return _read_embedded_backup()

func _read_embedded_backup() -> String:
	var scr := load("res://assets/crossword_wordlist_data.gd")
	if scr == null:
		return ""
	# Instantiate the script directly (it extends RefCounted)
	var obj = scr.new()
	if obj != null and obj.has_method("get_text"):
		return String(obj.call("get_text"))
	return ""

func _load_from_file(path: String) -> bool:
	var contents: String = _read_text_resource_or_file(path)
	if contents.is_empty():
		# Provide helpful diagnostics
		var error_code := FileAccess.get_open_error()
		print("Unable to open word list: %s (error: %d)" % [path, error_code])
		if not FileAccess.file_exists(path):
			print("File does not exist: %s" % path)
		push_error("Unable to open word list: %s (error: %d)" % [path, error_code])
		return false
	return _parse_text(contents)

func _parse_text(text: String) -> bool:
	var current_category := ""
	var lines: PackedStringArray = text.split("\n", false)
	for raw_line in lines:
		var line := String(raw_line).strip_edges()
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
