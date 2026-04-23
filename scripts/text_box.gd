extends LineEdit

var _normalizing := false

func _ready() -> void:
	text_changed.connect(_on_text_changed)

func _on_text_changed(new_text: String) -> void:
	if _normalizing: return
	_normalizing = true

	var t := new_text.strip_edges()
	if t.length() > 1:
		t = t.left(1)

	if t.length() == 1:
		var c := t[0]
		var is_ascii_letter := ((c >= "A" and c <= "Z") or (c >= "a" and c <= "z"))
		if is_ascii_letter:
			t = t.to_upper()
		else:
			t = ""  # reject non-letters

	if OS.is_debug_build():
		print_debug("[TextBox] text_changed -> '%s'" % t)

	text = t
	caret_column = text.length()
	_normalizing = false
