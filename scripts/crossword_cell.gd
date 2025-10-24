extends Control
class_name CrosswordCell

const DEBUG_NAV := true

signal cell_focused(row: int, col: int)
signal letter_input(row: int, col: int, letter: String)
signal navigation_requested(row: int, col: int, offset: Vector2i, reason: String)

enum CellState {
	NONE,
	CORRECT,
	INCORRECT,
}

@export var highlight_color: Color = Color(0.8, 0.8, 0.2, 0.4)
@export var highlight_active_cell_color: Color = Color(1.0, 0.9, 0.4, 0.55)
@export var conflict_color: Color = Color(0.85, 0.2, 0.2, 0.55)
@export var correct_color: Color = Color(0.2, 0.75, 0.35, 0.55)

var row: int = -1
var col: int = -1
var solution_letter: String = ""

var _suppress_text_signal: bool = false

var _panel: Panel
var _text: LineEdit
var _label: Label
var _state_overlay: ColorRect
var _highlight_overlay: ColorRect

func _ensure_nodes() -> bool:
	if _panel == null:
		_panel = get_node_or_null("Panel")
	if _text == null:
		_text = get_node_or_null("Panel/TextBox")
	if _label == null:
		_label = get_node_or_null("Panel/NumLabel")
	if _state_overlay == null:
		_state_overlay = get_node_or_null("Panel/StateOverlay")
	if _highlight_overlay == null:
		_highlight_overlay = get_node_or_null("Panel/HighlightOverlay")
	return _panel != null and _text != null and _label != null and _state_overlay != null and _highlight_overlay != null

func _ready() -> void:
	if not _ensure_nodes():
		push_error("CrosswordCell is missing expected child nodes.")
		return
	_text.text_changed.connect(_on_text_changed)
	_text.focus_entered.connect(_on_focus_entered)
	_text.gui_input.connect(_on_gui_input)

func configure_coords(r: int, c: int) -> void:
	row = r
	col = c

func set_solution(letter: String) -> void:
	solution_letter = letter

func set_number_text(text: String) -> void:
	if not _ensure_nodes():
		return
	_label.text = text
	_label.visible = text != ""

func grab_cell_focus() -> void:
	if not _ensure_nodes():
		return
	_text.grab_focus()
	_text.deselect()
	_text.caret_column = _text.text.length()

func set_letter(letter: String, emit_signal: bool = false, normalize: bool = true) -> void:
	if not _ensure_nodes():
		return
	var value := letter
	if normalize:
		var normalized := value.strip_edges()
		if normalized.length() > 1:
			normalized = normalized.substr(0, 1)
		if normalized.length() == 1:
			var ch := normalized[0]
			var is_letter := (ch >= "A" and ch <= "Z") or (ch >= "a" and ch <= "z")
			if is_letter:
				value = normalized.to_upper()
			else:
				value = ""
		else:
			value = ""
	_suppress_text_signal = not emit_signal
	_text.text = value
	_text.caret_column = _text.text.length()
	_suppress_text_signal = false
	if DEBUG_NAV:
		print_debug("[Cell %d,%d] set_letter normalize=%s value='%s'" % [row, col, str(normalize), value])

func get_letter() -> String:
	if not _ensure_nodes():
		return ""
	return _text.text

func clear_letter() -> void:
	set_letter("", false)
	set_state(CellState.NONE)

func set_state(state: int) -> void:
	if not _ensure_nodes():
		return
	match state:
		CellState.CORRECT:
			_state_overlay.color = correct_color
			_state_overlay.visible = true
		CellState.INCORRECT:
			_state_overlay.color = conflict_color
			_state_overlay.visible = true
		CellState.NONE:
			_state_overlay.visible = false

func set_highlighted(active: bool, is_current: bool = false) -> void:
	if not _ensure_nodes():
		return
	if active:
		_highlight_overlay.color = highlight_active_cell_color if is_current else highlight_color
		_highlight_overlay.visible = true
	else:
		_highlight_overlay.visible = false

func _on_focus_entered() -> void:
	emit_signal("cell_focused", row, col)

func _on_text_changed(new_text: String) -> void:
	if not _ensure_nodes():
		return
	if _suppress_text_signal:
		return
	emit_signal("letter_input", row, col, new_text)

func _on_gui_input(event: InputEvent) -> void:
	if not _ensure_nodes():
		return
	var key_event := event as InputEventKey
	if key_event == null or not key_event.pressed:
		return
	if key_event.echo and key_event.unicode != 0:
		return
	if DEBUG_NAV:
		print_debug("[Cell %d,%d] keycode=%d unicode=%d" % [row, col, key_event.keycode, key_event.unicode])

	var unicode := key_event.unicode
	if unicode > 0 and not key_event.ctrl_pressed and not key_event.alt_pressed:
		var ch := String.chr(unicode)
		var is_letter := ((ch >= "A" and ch <= "Z") or (ch >= "a" and ch <= "z"))
		if is_letter:
			set_letter(ch, false)
			emit_signal("letter_input", row, col, get_letter())
			accept_event()
			return
		accept_event()
		return

	match key_event.keycode:
		KEY_LEFT:
			emit_signal("navigation_requested", row, col, Vector2i(0, -1), "arrow")
			accept_event()
		KEY_RIGHT:
			emit_signal("navigation_requested", row, col, Vector2i(0, 1), "arrow")
			accept_event()
		KEY_UP:
			emit_signal("navigation_requested", row, col, Vector2i(-1, 0), "arrow")
			accept_event()
		KEY_DOWN:
			emit_signal("navigation_requested", row, col, Vector2i(1, 0), "arrow")
			accept_event()
		KEY_BACKSPACE:
			if key_event.ctrl_pressed or key_event.alt_pressed:
				return
			if _text.text.is_empty():
				emit_signal("navigation_requested", row, col, Vector2i(0, -1), "backspace")
			else:
				set_letter("", true)
			accept_event()
		KEY_TAB:
			var offset := Vector2i(0, 1)
			if key_event.shift_pressed:
				offset = Vector2i(0, -1)
			emit_signal("navigation_requested", row, col, offset, "tab")
			accept_event()
		KEY_ENTER, KEY_KP_ENTER:
			emit_signal("navigation_requested", row, col, Vector2i(1, 0), "enter")
			accept_event()
