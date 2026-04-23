extends RefCounted
class_name APDebugLog

const ENABLED := true
const LOG_DIR := "user://logs"
const MAX_ARRAY_ITEMS := 25
const MAX_STRING_LENGTH := 500

static var _session_id := ""
static var _log_path := ""
static var _file: FileAccess = null
static var _opening := false

static func start_session(context: String = "startup") -> void:
	if not ENABLED:
		return
	if _file != null or _opening:
		return
	_opening = true
	var now := Time.get_datetime_dict_from_system()
	_session_id = "%04d%02d%02d_%02d%02d%02d_%d" % [
		int(now.get("year", 0)),
		int(now.get("month", 0)),
		int(now.get("day", 0)),
		int(now.get("hour", 0)),
		int(now.get("minute", 0)),
		int(now.get("second", 0)),
		Time.get_ticks_msec() % 100000,
	]
	_ensure_log_dir()
	_log_path = "%s/crossword_ap_%s.log" % [LOG_DIR, _session_id]
	_file = FileAccess.open(_log_path, FileAccess.WRITE)
	_opening = false
	if _file != null:
		event("APDebugLog", "session_start", {
			"context": context,
			"session_id": _session_id,
			"log_path": _log_path,
		})
	else:
		print_debug("[APLog] Failed to open debug log at %s" % _log_path)

static func event(source: String, name: String, data: Dictionary = {}) -> void:
	if not ENABLED:
		return
	if _file == null:
		start_session("lazy")
	if _file == null:
		print_debug("[APLog] %s.%s %s" % [source, name, JSON.stringify(_sanitize(data))])
		return
	var row := {
		"t_msec": Time.get_ticks_msec(),
		"session": _session_id,
		"source": source,
		"event": name,
		"data": _sanitize(data),
	}
	var line := JSON.stringify(row)
	print_debug("[APLog] %s" % line)
	if _file != null:
		_file.store_line(line)
		_file.flush()

static func get_log_path() -> String:
	return _log_path

static func _ensure_log_dir() -> void:
	var root := DirAccess.open("user://")
	if root == null:
		return
	if not root.dir_exists("logs"):
		root.make_dir_recursive("logs")

static func _sanitize(value: Variant) -> Variant:
	match typeof(value):
		TYPE_DICTIONARY:
			var result := {}
			for key in value.keys():
				var key_text := str(key)
				var lower := key_text.to_lower()
				if lower.find("password") != -1:
					result[key_text] = "<redacted len=%d>" % str(value[key]).length()
				elif lower.find("answer") != -1:
					result[key_text] = "<answer len=%d>" % str(value[key]).length()
				else:
					result[key_text] = _sanitize(value[key])
			return result
		TYPE_ARRAY:
			var result: Array = []
			var limit: int = min(value.size(), MAX_ARRAY_ITEMS)
			for i in range(limit):
				result.append(_sanitize(value[i]))
			if value.size() > MAX_ARRAY_ITEMS:
				result.append({
					"_truncated": true,
					"shown": MAX_ARRAY_ITEMS,
					"total": value.size(),
				})
			return result
		TYPE_STRING:
			if value.length() > MAX_STRING_LENGTH:
				return "%s... <truncated %d chars total>" % [value.substr(0, MAX_STRING_LENGTH), value.length()]
			return value
		TYPE_VECTOR2I:
			return [value.x, value.y]
		TYPE_VECTOR2:
			return [value.x, value.y]
		_:
			return value
