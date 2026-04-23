extends Control

const WORD_LIST := preload("res://scripts/crossword_word_list.gd")
const PROCEDURAL_GENERATOR: Script = preload("res://scripts/procedural_crossword.gd")
const DEFAULT_WORD_LIST_PATH := "res://assets/crossword_wordlist.txt"
const DIRECTIONS := {
	"across": Vector2i(0, 1),
	"down": Vector2i(1, 0),
}
const MIN_ENTRY_LENGTH := 3
const DEBUG_NAV := false
const DEBUG_CLICK_TRACKING := false
const DEBUG_CORRECT_STATE := false
const DEBUG_COLOR_INDICATOR := true
const CATEGORY_PRIORITY := {
	"EASY WORDS": 0,
	"MEDIUM WORDS": 1,
	"HARD WORDS": 2,
}
var _clue_font: Font = preload("res://fonts/monogram-extended.ttf")
var _clue_font_size: int = 32
var _clue_label_settings: LabelSettings = null

signal entry_solved(entry_id: int, entry: Dictionary)
signal solved_count_changed(total_solved: int)

enum PlayMode {
	OFFLINE,
	ARCHIPELAGO,
}

@export var cell_px: int = 40
@export var cell_scene: PackedScene
@export var grid_rows: int = 15
@export var grid_cols: int = 15
@export var max_words: int = 40
@export var enable_state_overlay: bool = true:
	set(value):
		enable_state_overlay = value
		_update_all_cells_overlay_enabled()
@export var min_words: int = 10
@export var random_seed: int = 0
@export var trim_generated_grid: bool = false
@export var allow_fallback_word_list: bool = true
@export_file("*.txt") var word_list_path: String = DEFAULT_WORD_LIST_PATH
@export var auto_generate_on_ready: bool = false
@export_range(0.0, 5.0, 0.1) var easy_word_weight: float = 0.7
@export_range(0.0, 5.0, 0.1) var medium_word_weight: float = 1.2
@export_range(0.0, 5.0, 0.1) var hard_word_weight: float = 0.7
@export_range(0.0, 5.0, 0.1) var fallback_word_weight: float = 1.0
@export_range(0.0, 1.0, 0.05) var weighting_strength: float = 0.3  # 0=uniform (most random), 1=use category weights
@export var clue_solved_overlay_color: Color = Color(0.0, 0.8, 0.0, 0.3)  # Green with transparency
@export var clue_new_overlay_color: Color = Color(1.0, 0.84, 0.0, 0.3)  # Gold with transparency

@export_category("Background")
@export var enable_background_gradient: bool = true
@export var background_gradient_top_color: Color = Color(0.105, 0.105, 0.18, 1.0)
@export var background_gradient_bottom_color: Color = Color(0.027, 0.031, 0.075, 1.0)
@export_range(0.0, 360.0, 1.0) var background_gradient_angle_deg: float = 90.0
@export var background_gradient_size: Vector2i = Vector2i(512, 512)

var rows: int
var cols: int
var cells: Array = []                              # 2D array of CrosswordCell or null
var numbers: Dictionary[Vector2i, Vector2i] = {}
var word_list = null
var puzzle_solution: Array = []
var across_entries: Array = []
var down_entries: Array = []
var player_grid: Array = []
var cell_slot_lookup: Dictionary = {}
var current_entry: Dictionary = {}
var current_direction: String = "across"
var current_entry_id: int = -1
var current_cell: Vector2i = Vector2i(-1, -1)
var _previous_current_cell: Vector2i = Vector2i(-1, -1)
var highlighted_cells: Array = []
var is_generating: bool = false
var _next_entry_id: int = 1
var _suppress_list_selection: bool = false
var _generation_counter: int = 0
var mask: Array[String] = []
var _last_focus_change_frame: int = -1
var _last_clicked_cell: Vector2i = Vector2i(-1, -1)

var grid_container: GridContainer
var across_scroll: ScrollContainer
var down_scroll: ScrollContainer
var across_list: VBoxContainer
var down_list: VBoxContainer
var active_clue_label: Label
var free_letter_counter: Label
var letter_hint_count: Label
var regenerate_button: Button
var easy_words_toggle: CheckButton
var hard_words_toggle: CheckButton
var across_buttons: Array = []
var down_buttons: Array = []
var ap_name_input: LineEdit
var ap_host_input: LineEdit
var ap_port_input: LineEdit
var ap_password_input: LineEdit
var ap_connect_button: Button
var across_selected_index: int = -1
var down_selected_index: int = -1
var _letter_input_from_clue: bool = false
var _pending_advance_entry_id: int = -1
var easy_words_enabled: bool = true
var hard_words_enabled: bool = true
var current_mode: PlayMode = PlayMode.OFFLINE
var entry_lookup: Dictionary = {}
var solved_entry_count: int = 0
const ARCHIPELAGO_CLIENT_SCRIPT: Script = preload("res://scripts/archipelago_client.gd")
var ap_client = null
const INITIAL_REVEALED_CLUES := 6
var hidden_entry_queue: Array[int] = []
var revealed_entry_count: int = 0
var unlocked_entry_count: int = 0
var current_player_name: String = ""
var current_host: String = "archipelago.gg"
var has_color_indicator: bool = false
var letter_hints_enabled: bool = true
const SAVE_DIR := "user://ap_progress"
const SAVE_VERSION := 1
var _save_pending: bool = false
var _last_save_msec: int = 0
var ap_slot_data: Dictionary = {}
var initial_reveal_override: int = INITIAL_REVEALED_CLUES
var claimed_location_ids: Dictionary = {}
var sent_checks_for_entries: Dictionary = {}  # Track which entry IDs we've sent location checks for
var _status_locked: bool = false
var _using_minimal_word_list: bool = false
var letter_hints_used: int = 0
var letter_hints_available: int = 0
var total_letter_hint_items_received: int = 0
var processed_clue_locations: Dictionary = {}  # Track which clue location IDs we've already processed
var total_direct_clues_received: int = 0  # Total count of direct clues (no location) ever received
var _puzzle_ready: bool = false
var _pending_clue_locations: Dictionary = {}
var _pending_direct_clue_total: int = -1
var _pending_direct_clue_new: int = 0
var _pending_color_indicator: bool = false
var _pending_letter_hints: int = 0
var _hold_position_next_input: bool = false
var _background_gradient_rect: TextureRect
var _background_gradient_texture: GradientTexture2D

func _nav_log(msg: String) -> void:
	if DEBUG_NAV:
		print_debug("[NAV] %s" % msg)

func _update_all_cells_overlay_enabled() -> void:
	if cells.is_empty():
		return
	for row in cells:
		if row == null:
			continue
		for cell in row:
			if cell != null and cell is CrosswordCell:
				cell.set_state_overlay_enabled(enable_state_overlay)

func _ready() -> void:
	# Create LabelSettings for clue buttons
	_clue_label_settings = LabelSettings.new()
	_clue_label_settings.font = _clue_font
	_clue_label_settings.font_size = _clue_font_size
	
	add_to_group("grid_manager")
	if cell_scene == null:
		push_error("Assign 'cell_scene' (CrosswordCell.tscn) in the Inspector.")
		return
	_background_gradient_rect = get_node_or_null("BackgroundGradient") as TextureRect
	_apply_background_gradient()

	grid_container = get_node_or_null("Margin/Layout/CenterPanel/CellsContainer/Cells")
	across_scroll = get_node_or_null("Margin/Layout/AcrossPanel/AcrossScroll")
	across_list = get_node_or_null("Margin/Layout/AcrossPanel/AcrossScroll/AcrossMargin/AcrossList")
	down_scroll = get_node_or_null("Margin/Layout/DownPanel/DownScroll")
	down_list = get_node_or_null("Margin/Layout/DownPanel/DownScroll/DownMargin/DownList")
	active_clue_label = get_node_or_null("ActiveClue")
	free_letter_counter = get_node_or_null("Margin/Layout/CenterPanel/FreeLetterCounter")
	letter_hint_count = get_node_or_null("LetterHintCount")
	if letter_hint_count != null:
		letter_hint_count.visible = false
	regenerate_button = get_node_or_null("Margin/Layout/CenterPanel/Controls/RegenerateButton")

	# Ensure overlays draw above the grid
	if active_clue_label != null:
		active_clue_label.z_index = 1000
	var controls_container := get_node_or_null("Margin/Layout/CenterPanel/Controls") as Control
	if controls_container != null:
		controls_container.z_index = 1000
	var cells_container_control := get_node_or_null("Margin/Layout/CenterPanel/CellsContainer") as Control
	if cells_container_control != null:
		cells_container_control.z_index = 0
	if regenerate_button == null:
		print("[DEBUG] Failed to find RegenerateButton at expected path")
		# Try to find it by searching the scene tree
		regenerate_button = _find_button_by_text("Generate")
		if regenerate_button != null:
			print("[DEBUG] Found RegenerateButton by searching for 'Generate' text")
	else:
		print("[DEBUG] Found RegenerateButton at expected path")
	easy_words_toggle = get_node_or_null("Margin/Layout/CenterPanel/Controls/EasyWordsToggleContainer/EasyWordsToggle")
	hard_words_toggle = get_node_or_null("Margin/Layout/CenterPanel/Controls/HardWordsToggleContainer/HardWordsToggle")
	ap_host_input = get_node_or_null("Margin/Layout/CenterPanel/Controls/APControls/APHostInput")
	ap_name_input = get_node_or_null("Margin/Layout/CenterPanel/Controls/APControls/APNameInput")
	ap_port_input = get_node_or_null("Margin/Layout/CenterPanel/Controls/APControls/APPortInput")
	ap_password_input = get_node_or_null("Margin/Layout/CenterPanel/Controls/APControls/APPasswordInput")
	ap_connect_button = get_node_or_null("Margin/Layout/CenterPanel/Controls/APControls/APConnectButton")
	if ap_client == null:
		ap_client = ARCHIPELAGO_CLIENT_SCRIPT.new()
		add_child(ap_client)
	if ap_client != null:
		if not ap_client.connection_state_changed.is_connected(_on_ap_client_state_changed):
			ap_client.connection_state_changed.connect(_on_ap_client_state_changed)
		if not ap_client.connection_failed.is_connected(_on_ap_client_failed):
			ap_client.connection_failed.connect(_on_ap_client_failed)
		if not ap_client.location_checked.is_connected(_on_ap_location_checked):
			ap_client.location_checked.connect(_on_ap_location_checked)
		if not ap_client.items_received.is_connected(_on_ap_items_received):
			ap_client.items_received.connect(_on_ap_items_received)
		if not ap_client.print_json.is_connected(_on_ap_print_message):
			ap_client.print_json.connect(_on_ap_print_message)
		if not ap_client.slot_data_received.is_connected(_on_ap_slot_data_received):
			ap_client.slot_data_received.connect(_on_ap_slot_data_received)
		if not ap_client.color_indicator_received.is_connected(_on_ap_color_indicator_received):
			ap_client.color_indicator_received.connect(_on_ap_color_indicator_received)
		if not ap_client.direct_clues_received.is_connected(_on_ap_direct_clues_received):
			ap_client.direct_clues_received.connect(_on_ap_direct_clues_received)
		if not ap_client.letter_hint_received.is_connected(_on_ap_letter_hint_received):
			ap_client.letter_hint_received.connect(_on_ap_letter_hint_received)
	if ap_name_input != null and ap_name_input.text.strip_edges().is_empty():
		ap_name_input.text = current_player_name if current_player_name != "" else ""
	if ap_host_input != null and ap_host_input.text.strip_edges().is_empty():
		ap_host_input.text = current_host
	var across_label := get_node_or_null("Margin/Layout/AcrossPanel/AcrossLabel") as Label
	var down_label := get_node_or_null("Margin/Layout/DownPanel/DownLabel") as Label
	if across_label != null:
		across_label.visible = false
		var settings := across_label.label_settings
		if settings != null:
			if settings.font != null:
				_clue_font = settings.font
			_clue_font_size = settings.font_size
	if down_label != null:
		down_label.visible = false

	if grid_container == null or across_scroll == null or down_scroll == null or across_list == null or down_list == null or regenerate_button == null:
		push_error("GridManager scene is missing required UI nodes.")
		print_debug("[DEBUG] grid_container=%s across_scroll=%s down_scroll=%s across_list=%s down_list=%s regenerate_button=%s" % [
			str(grid_container != null), str(across_scroll != null), str(down_scroll != null), 
			str(across_list != null), str(down_list != null), str(regenerate_button != null)])
		return
	
	if active_clue_label == null:
		push_warning("ActiveClue label not found - clue messages will not display")

	if ap_connect_button != null:
		ap_connect_button.pressed.connect(_on_ap_connect_pressed)
		_update_ap_button_text()
	else:
		push_warning("AP connect button not found; Archipelago mode disabled.")

	grid_container.columns = grid_cols
	grid_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	# Ensure the generate button is properly connected
	if regenerate_button.pressed.is_connected(_on_regenerate_pressed):
		print("[DEBUG] Generate button already connected")
	else:
		print("[DEBUG] Connecting generate button")
		regenerate_button.pressed.connect(_on_regenerate_pressed)
	
	# Double-check the connection worked
	if regenerate_button.pressed.is_connected(_on_regenerate_pressed):
		print("[DEBUG] Generate button connection confirmed")
	else:
		push_error("Failed to connect generate button!")
	
	# Verify button state
	print("[DEBUG] Generate button disabled: %s, visible: %s" % [str(regenerate_button.disabled), str(regenerate_button.visible)])

	if easy_words_toggle != null:
		easy_words_enabled = easy_words_toggle.button_pressed
		easy_words_toggle.toggled.connect(_on_easy_words_toggled)
	else:
		push_warning("Easy words toggle not found; defaulting to enabled.")
		easy_words_enabled = true

	if hard_words_toggle != null:
		hard_words_enabled = hard_words_toggle.button_pressed
		hard_words_toggle.toggled.connect(_on_hard_words_toggled)
	else:
		push_warning("Hard words toggle not found; defaulting to enabled.")
		hard_words_enabled = true
	
	# Initialize letter hint counter display
	_update_letter_hint_counter()

	_enter_offline_mode(auto_generate_on_ready)

func _update_ap_button_text() -> void:
	if ap_connect_button == null:
		return
	var label := "Connect"
	if ap_client != null:
		var client_state: int = ap_client.get_state()
		if client_state == ArchipelagoClient.ConnectionState.CONNECTED:
			label = "Disconnect"
		elif client_state != ArchipelagoClient.ConnectionState.DISCONNECTED:
			label = "Cancel"
	ap_connect_button.text = label

func _update_active_clue_message(message: String, temporary: bool = true) -> void:
	if _status_locked:
		return
	if active_clue_label != null:
		active_clue_label.text = message
		# Restore the current clue after a short delay (only for temporary messages)
		if temporary:
			await get_tree().create_timer(2.0).timeout
			_update_active_clue_label()

func _on_ap_client_state_changed(new_state: int) -> void:
	match new_state:
		ArchipelagoClient.ConnectionState.CONNECTING:
			_update_active_clue_message("Connecting to server...", false)
		ArchipelagoClient.ConnectionState.SOCKET_CONNECTED:
			_update_active_clue_message("Socket connected. Awaiting data package...", false)
		ArchipelagoClient.ConnectionState.AUTHENTICATING:
			_update_active_clue_message("Authenticating...", false)
		ArchipelagoClient.ConnectionState.CONNECTED:
			if ap_client != null:
				current_host = ap_client.host
				if current_player_name == "":
					current_player_name = ap_client.player_name
				if ap_host_input != null:
					ap_host_input.text = current_host
			if current_player_name != "":
				_update_active_clue_message("Connected as %s" % current_player_name, false)
		ArchipelagoClient.ConnectionState.DISCONNECTED:
			if current_mode == PlayMode.ARCHIPELAGO:
				_update_active_clue_message("Disconnected", false)
	_update_ap_button_text()

func _on_ap_client_failed(reason: String) -> void:
	push_warning(reason)
	_update_active_clue_message(reason, false)
	if current_mode == PlayMode.ARCHIPELAGO:
		_enter_offline_mode(false)
	_update_ap_button_text()

func _on_ap_print_message(message: String) -> void:
	if message.strip_edges().is_empty():
		return
	_update_active_clue_message(message, false)

func _on_ap_slot_data_received(data: Dictionary) -> void:
	ap_slot_data = data.duplicate(true)
	if current_mode == PlayMode.ARCHIPELAGO:
		_apply_archipelago_slot_data()

func _apply_archipelago_slot_data() -> void:
	if ap_slot_data.is_empty():
		_update_active_clue_message("Waiting for Archipelago slot data...", false)
		return
	
	# Check color_indicator option
	var color_indicator_option: int = ap_slot_data.get("color_indicator", 1)  # default to "item"
	match color_indicator_option:
		0:  # start_with
			has_color_indicator = true
		1:  # item (will be enabled when item is received)
			has_color_indicator = false
		2:  # no_indicator
			has_color_indicator = false
	
	if DEBUG_COLOR_INDICATOR:
		var option_name := "unknown"
		match color_indicator_option:
			0: option_name = "start_with"
			1: option_name = "item"
			2: option_name = "no_indicator"
		print_debug("[ColorIndicator] Slot data loaded: option=%s has_indicator=%s" % [option_name, str(has_color_indicator)])
	
	# Check if letter hints are enabled
	letter_hints_enabled = bool(ap_slot_data.get("letter_hints_enabled", true))
	
	# Set starting letter hints (only if not restoring from save and if enabled)
	var starting_hints: int = 0
	if letter_hints_enabled:
		starting_hints = int(ap_slot_data.get("starting_letter_hints", 0))
	
	var layout_variant = ap_slot_data.get("puzzle_layout", {})
	if typeof(layout_variant) != TYPE_DICTIONARY:
		push_warning("Archipelago slot data missing puzzle layout.")
		return
	var converted_layout := _convert_archipelago_layout(layout_variant)
	if converted_layout.is_empty():
		push_warning("Failed to convert Archipelago puzzle layout.")
		return
	var entry_list_variant: Variant = converted_layout.get("entries", [])
	var entry_count: int = 0
	if typeof(entry_list_variant) == TYPE_ARRAY:
		for idx in range(entry_list_variant.size()):
			var entry_variant = entry_list_variant[idx]
			print_debug("[APLayout] entry[%d] number=%s loc_idx=%s" % [idx, str(entry_variant.get("number", "?")), str(entry_variant.get("location_index", "?"))])
	if typeof(entry_list_variant) == TYPE_ARRAY:
		entry_count = entry_list_variant.size()
	initial_reveal_override = clamp(int(ap_slot_data.get("initial_clues", INITIAL_REVEALED_CLUES)), 0, entry_count)
	_nav_log("applying archipelago layout entries=%d initial_reveal=%d" % [entry_count, initial_reveal_override])
	_apply_layout(converted_layout)
	_refresh_revealed_clue_buttons()
	var restored := _restore_saved_progress()
	if restored:
		print_debug("[APSave] Restored progress for %s" % _get_current_puzzle_id())
		# Hints were restored from save, don't reset them
	else:
		print_debug("[APSave] No saved progress applied for %s" % _get_current_puzzle_id())
		# New game, set starting hints and reset tracking
		letter_hints_available = starting_hints
		total_letter_hint_items_received = starting_hints
		if ap_client != null:
			ap_client.set_total_letter_hint_items_seen(total_letter_hint_items_received)
		_update_letter_hint_counter()
		print_debug("[LetterHint] New game - reset to starting_hints=%d" % starting_hints)
	
	# Refresh cell states based on color_indicator setting
	_refresh_all_cell_states()
	
	if entry_count > 0:
		if restored:
			_update_active_clue_message("Synced %d Archipelago clues (progress restored)" % entry_count, false)
		else:
			_update_active_clue_message("Synced %d Archipelago clues" % entry_count, false)
	else:
		_update_active_clue_message("Archipelago puzzle ready", false)
	_queue_save_progress()
	_puzzle_ready = true
	_flush_pending_archipelago_items()
	_update_letter_hint_counter()

func _flush_pending_archipelago_items() -> void:
	if not _puzzle_ready:
		return
	if _pending_color_indicator:
		_pending_color_indicator = false
		_apply_color_indicator_item()
	if _pending_direct_clue_total >= 0 or _pending_direct_clue_new > 0:
		var total := _pending_direct_clue_total
		var new_count := _pending_direct_clue_new
		_pending_direct_clue_total = -1
		_pending_direct_clue_new = 0
		if total < 0:
			total = total_direct_clues_received + new_count
			_handle_direct_clue_total(total, new_count)
	if not _pending_clue_locations.is_empty():
		var queued: Array = []
		for key in _pending_clue_locations.keys():
			queued.append(int(key))
		_pending_clue_locations.clear()
		if not queued.is_empty():
			_process_ap_locations(queued, true)
	if _pending_letter_hints > 0:
		var queued_hints := _pending_letter_hints
		_pending_letter_hints = 0
		_apply_new_letter_hints(queued_hints)
	_update_letter_hint_counter()

func grant_direct_clues(count: int) -> void:
	if count <= 0:
		return
	var target_total := total_direct_clues_received + count
	_handle_direct_clue_total(target_total, count)

func grant_clue_locations(location_ids: Array) -> void:
	if location_ids.is_empty():
		return
	_process_ap_locations(location_ids, true, true)

func _convert_archipelago_layout(layout: Dictionary) -> Dictionary:
	var converted := {}
	var mask_variant = layout.get("mask", [])
	var mask_array: Array[String] = []
	if typeof(mask_variant) == TYPE_ARRAY:
		for row_variant in mask_variant:
			mask_array.append(str(row_variant))
	converted["mask"] = mask_array

	var board_variant = layout.get("board", [])
	var board_array: Array = []
	if typeof(board_variant) == TYPE_ARRAY:
		for row_variant in board_variant:
			if typeof(row_variant) != TYPE_ARRAY:
				continue
			var row_array: Array = []
			for cell in row_variant:
				row_array.append(str(cell))
			board_array.append(row_array)
	converted["board"] = board_array

	var entries_variant = layout.get("entries", [])
	var entries_array: Array = []
	if typeof(entries_variant) == TYPE_ARRAY:
		for entry_variant in entries_variant:
			if typeof(entry_variant) != TYPE_DICTIONARY:
				continue
			var entry_dict: Dictionary = entry_variant.duplicate(true)
			var start_variant = entry_dict.get("start", [])
			var start_vec := Vector2i.ZERO
			if typeof(start_variant) == TYPE_ARRAY and start_variant.size() >= 2:
				start_vec = Vector2i(int(start_variant[0]), int(start_variant[1]))
			entry_dict["start"] = start_vec
			entries_array.append(entry_dict)
	converted["entries"] = entries_array
	if mask_array.is_empty() or board_array.is_empty():
		return {}
	return converted

func _refresh_revealed_clue_buttons() -> void:
	var combined_entries: Array = []
	combined_entries.append_array(across_entries)
	combined_entries.append_array(down_entries)
	for entry_variant in combined_entries:
		var entry: Dictionary = entry_variant
		if entry.get("revealed", false):
			var entry_id: int = entry.get("id", -1)
			if entry_id > 0:
				entry_lookup[entry_id] = entry
				_update_button_for_entry(entry)
func _sanitize_key(value: String) -> String:
	var sanitized := str(value)
	var forbidden := ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]
	for token in forbidden:
		sanitized = sanitized.replace(token, "_")
	return sanitized

func _get_current_puzzle_id() -> String:
	if current_mode != PlayMode.ARCHIPELAGO:
		return ""
	if ap_slot_data.is_empty():
		return ""
	var seed_value := int(ap_slot_data.get("puzzle_seed", 0))
	if seed_value == 0:
		return ""
	var host_key := current_host
	if host_key.is_empty() and ap_client != null:
		host_key = ap_client.host
	if host_key.is_empty():
		host_key = "host"
	var player_key := current_player_name
	if player_key.is_empty() and ap_client != null:
		player_key = ap_client.player_name
	if player_key.is_empty():
		player_key = "player"
	var port_value := 0
	if ap_client != null:
		port_value = ap_client.port
	return "ap_%s_%d_%s_%d" % [_sanitize_key(host_key), port_value, _sanitize_key(player_key), seed_value]

func _get_save_path(puzzle_id: String) -> String:
	return "%s/%s.json" % [SAVE_DIR, puzzle_id]

func _ensure_save_dir() -> bool:
	var err := DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	if err != OK and err != ERR_ALREADY_EXISTS:
		push_warning("Failed to create save folder: %s (err=%d)" % [SAVE_DIR, err])
		return false
	return true

func _queue_save_progress() -> void:
	if current_mode != PlayMode.ARCHIPELAGO:
		return
	if ap_slot_data.is_empty():
		return
	if player_grid.is_empty():
		return
	if _save_pending:
		return
	_save_pending = true
	call_deferred("_save_progress_now")

func _save_progress_now() -> void:
	_save_pending = false
	if current_mode != PlayMode.ARCHIPELAGO:
		return
	if ap_slot_data.is_empty() or player_grid.is_empty():
		return
	var puzzle_id := _get_current_puzzle_id()
	if puzzle_id.is_empty():
		return
	if not _ensure_save_dir():
		return
	var snapshot := _capture_progress_snapshot()
	if snapshot.is_empty():
		return
	print_debug("[APSave] Snapshot revealed=%s solved=%s hidden=%s" % [str(snapshot.get("revealed_ids", [])), str(snapshot.get("solved_ids", [])), str(snapshot.get("hidden_queue", []))])
	var json := JSON.stringify(snapshot)
	var file := FileAccess.open(_get_save_path(puzzle_id), FileAccess.WRITE)
	if file == null:
		push_warning("Failed to open save file for writing: %s" % _get_save_path(puzzle_id))
		return
	file.store_string(json)
	_last_save_msec = Time.get_ticks_msec()
	print_debug("[APSave] Stored progress %s" % _get_save_path(puzzle_id))

func _capture_progress_snapshot() -> Dictionary:
	var grid_snapshot: Array = []
	for r in range(player_grid.size()):
		var row_variant: Variant = player_grid[r]
		var row_snapshot: Array = []
		if typeof(row_variant) == TYPE_ARRAY:
			var row_array: Array = row_variant
			for c in range(row_array.size()):
				row_snapshot.append(str(row_array[c]))
		grid_snapshot.append(row_snapshot)
	var revealed_ids: Array = []
	var solved_ids: Array = []
	var all_entries: Array = []
	all_entries.append_array(across_entries)
	all_entries.append_array(down_entries)
	for entry_variant in all_entries:
		var entry: Dictionary = entry_variant
		var entry_id: int = entry.get("id", -1)
		if entry_id <= 0:
			continue
		if entry.get("revealed", false):
			revealed_ids.append(entry_id)
		if entry.get("solved", false):
			solved_ids.append(entry_id)
	return {
		"version": SAVE_VERSION,
		"puzzle_seed": ap_slot_data.get("puzzle_seed", 0),
		"initial_clues": initial_reveal_override,
		"revealed_ids": revealed_ids,
		"solved_ids": solved_ids,
		"hidden_queue": hidden_entry_queue.duplicate(),
		"claimed_locations": claimed_location_ids.keys(),
		"sent_check_entries": sent_checks_for_entries.keys(),
		"player_grid": grid_snapshot,
		"unlocked_entry_count": unlocked_entry_count,
		"revealed_entry_count": revealed_entry_count,
		"solved_entry_count": solved_entry_count,
		"current_entry_id": current_entry_id,
		"current_direction": current_direction,
		"letter_hints_available": letter_hints_available,
		"letter_hints_used": letter_hints_used,
		"processed_clue_locations": processed_clue_locations.keys(),
		"total_direct_clues_received": total_direct_clues_received,
		"has_color_indicator": has_color_indicator,
		"ap_last_item_index": ap_client.get_last_processed_item_index() if ap_client != null else -1,
		"total_letter_hint_items_received": total_letter_hint_items_received,
	}

func _restore_saved_progress() -> bool:
	var puzzle_id := _get_current_puzzle_id()
	if puzzle_id.is_empty():
		print_debug("[APSave] No puzzle id; skip restore")
		return false
	var path := _get_save_path(puzzle_id)
	if not FileAccess.file_exists(path):
		print_debug("[APSave] No existing save for %s" % path)
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		print_debug("[APSave] Failed to open save for reading: %s" % path)
		return false
	var contents := file.get_as_text()
	var parsed: Variant = JSON.parse_string(contents)
	if typeof(parsed) != TYPE_DICTIONARY:
		print_debug("[APSave] Save file malformed for %s" % path)
		return false
	return _apply_saved_progress(parsed)

func _array_to_id_set(array: Array) -> Dictionary:
	var set: Dictionary = {}
	for value in array:
		match typeof(value):
			TYPE_INT:
				set[value] = true
			TYPE_FLOAT:
				set[int(value)] = true
			TYPE_STRING:
				var parsed := int(String(value))
				if parsed != 0 or String(value) == "0":
					set[parsed] = true
	return set

func _apply_saved_progress(state: Dictionary) -> bool:
	if state.get("version", 0) != SAVE_VERSION:
		print_debug("[APSave] Save version mismatch (found %s)" % str(state.get("version", "?")))
		return false
	var expected_seed := int(ap_slot_data.get("puzzle_seed", 0))
	if expected_seed != 0 and expected_seed != int(state.get("puzzle_seed", -1)):
		print_debug("[APSave] Puzzle seed mismatch expected=%d saved=%d" % [expected_seed, int(state.get("puzzle_seed", -1))])
		return false
	var saved_grid = state.get("player_grid", [])
	if typeof(saved_grid) != TYPE_ARRAY:
		print_debug("[APSave] Saved grid missing or invalid")
		return false
	var saved_rows: int = saved_grid.size()
	if saved_rows != player_grid.size():
		print_debug("[APSave] Saved grid row mismatch saved=%d expected=%d" % [saved_rows, player_grid.size()])
		return false
	var saved_cols: int = cols
	var saved_indicator_variant: Variant = state.get("has_color_indicator", null)
	if typeof(saved_indicator_variant) == TYPE_BOOL:
		has_color_indicator = saved_indicator_variant
		if DEBUG_COLOR_INDICATOR:
			print_debug("[ColorIndicator] Restored indicator from save: %s" % str(has_color_indicator))
	for r in range(rows):
		var saved_row: Variant = saved_grid[r]
		if typeof(saved_row) != TYPE_ARRAY:
			print_debug("[APSave] Saved row %d invalid" % r)
			continue
		var saved_row_array: Array = saved_row
		for c in range(min(saved_row_array.size(), cols)):
			var letter: String = str(saved_row_array[c])
			player_grid[r][c] = letter
			var cell := cells[r][c] as CrosswordCell
			if cell == null:
				continue
			if letter == "#":
				cell.clear_letter()
				continue
			cell.set_letter(letter, false, false)
			var solution_letter: String = str(puzzle_solution[r][c])
			var normalized := letter.strip_edges().to_upper()
			if normalized.is_empty() or solution_letter.is_empty():
				cell.set_state(CrosswordCell.CellState.NONE)
			else:
				var expected: String = solution_letter.strip_edges().to_upper()
				var correct := normalized == expected
				_apply_cell_state_from_correctness(cell, correct)
	var revealed_set := _array_to_id_set(state.get("revealed_ids", []))
	var solved_set := _array_to_id_set(state.get("solved_ids", []))
	var claimed_set := _array_to_id_set(state.get("claimed_locations", []))
	var sent_checks_set := _array_to_id_set(state.get("sent_check_entries", []))
	print_debug("[APSave] Restoring revealed=%s solved=%s hidden=%s" % [str(state.get("revealed_ids", [])), str(state.get("solved_ids", [])), str(state.get("hidden_queue", []))])
	hidden_entry_queue = []
	var hidden_variant = state.get("hidden_queue", [])
	if typeof(hidden_variant) == TYPE_ARRAY:
		for entry_id_variant in hidden_variant:
			match typeof(entry_id_variant):
				TYPE_INT:
					hidden_entry_queue.append(entry_id_variant)
				TYPE_FLOAT:
					hidden_entry_queue.append(int(entry_id_variant))
				TYPE_STRING:
					var parsed := int(String(entry_id_variant))
					if parsed != 0 or String(entry_id_variant) == "0":
						hidden_entry_queue.append(parsed)
	var combined_entries: Array = []
	combined_entries.append_array(across_entries)
	combined_entries.append_array(down_entries)
	for entry_index in range(combined_entries.size()):
		var entry: Dictionary = combined_entries[entry_index]
		var entry_id: int = entry.get("id", -1)
		if entry_id <= 0:
			continue
		var revealed := revealed_set.has(entry_id)
		var solved := solved_set.has(entry_id)
		entry["revealed"] = revealed
		entry["solved"] = solved
		if solved:
			_update_cells_for_entry(entry, true)
		entry_lookup[entry_id] = entry
	revealed_entry_count = revealed_set.size()
	unlocked_entry_count = revealed_set.size()
	solved_entry_count = solved_set.size()
	claimed_location_ids.clear()
	sent_checks_for_entries.clear()
	for key in claimed_set.keys():
		claimed_location_ids[key] = true
	for key in sent_checks_set.keys():
		sent_checks_for_entries[key] = true
	initial_reveal_override = int(state.get("initial_clues", initial_reveal_override))
	_populate_clue_lists()
	var saved_entry_id := int(state.get("current_entry_id", -1))
	if saved_entry_id != -1 and entry_lookup.has(saved_entry_id):
		var saved_entry: Dictionary = entry_lookup[saved_entry_id]
		current_direction = str(state.get("current_direction", saved_entry.get("direction", "across")))
		_set_active_entry(saved_entry, Vector2i(-1, -1), false)
	else:
		_select_initial_entry()
	
	# Restore letter hints available
	letter_hints_available = int(state.get("letter_hints_available", 0))
	letter_hints_used = int(state.get("letter_hints_used", letter_hints_used))
	var saved_hint_total_variant: Variant = state.get("total_letter_hint_items_received", null)
	if typeof(saved_hint_total_variant) in [TYPE_INT, TYPE_FLOAT]:
		total_letter_hint_items_received = int(saved_hint_total_variant)
	else:
		total_letter_hint_items_received = int(max(0, letter_hints_available + letter_hints_used))
	_update_letter_hint_counter()
	
	# Restore processed clue locations
	var processed_locs: Array = state.get("processed_clue_locations", [])
	processed_clue_locations.clear()
	for loc in processed_locs:
		processed_clue_locations[int(loc)] = true
	
	# Restore total_direct_clues_received from save
	# If not in save file, calculate from revealed entries (for old saves)
	var saved_total_clues = state.get("total_direct_clues_received", -1)
	if saved_total_clues >= 0:
		total_direct_clues_received = saved_total_clues
		print_debug("[APSave] Restored total_direct_clues=%d from save" % total_direct_clues_received)
	else:
		# Fallback: calculate from number of revealed entries
		total_direct_clues_received = revealed_set.size()
		print_debug("[APSave] Calculated total_direct_clues=%d from revealed entries" % total_direct_clues_received)
	
	var saved_last_item_index := int(state.get("ap_last_item_index", -1))
	if ap_client != null:
		var previous_last: int = int(ap_client.get_last_processed_item_index())
		if saved_last_item_index > previous_last:
			ap_client.set_last_processed_item_index(saved_last_item_index)
		var previous_direct_total: int = int(ap_client.get_total_direct_clues_seen())
		if total_direct_clues_received > previous_direct_total:
			ap_client.set_total_direct_clues_seen(total_direct_clues_received)
		var previous_hint_total: int = int(ap_client.get_total_letter_hint_items_seen())
		if total_letter_hint_items_received > previous_hint_total:
			ap_client.set_total_letter_hint_items_seen(total_letter_hint_items_received)
		var client_last: int = int(ap_client.get_last_processed_item_index())
		var client_direct_total: int = int(ap_client.get_total_direct_clues_seen())
		var client_hint_total: int = int(ap_client.get_total_letter_hint_items_seen())
		var pending_hint_items: int = int(max(0, client_hint_total - total_letter_hint_items_received))
		_pending_letter_hints = pending_hint_items
		print_debug("[APSave] Restored indices: last_item=%d (client_now=%d prev=%d) direct_clues_seen=%d (client_now=%d prev=%d) hints_seen=%d (client_now=%d prev=%d) pending_hint_items=%d" % [saved_last_item_index, client_last, previous_last, total_direct_clues_received, client_direct_total, previous_direct_total, total_letter_hint_items_received, client_hint_total, previous_hint_total, pending_hint_items])

	_refresh_revealed_clue_buttons()
	print_debug("[APSave] Restore complete revealed_count=%d unlocked=%d solved=%d hints=%d" % [revealed_entry_count, unlocked_entry_count, solved_entry_count, letter_hints_available])
	return true

func _set_generate_enabled(enabled: bool) -> void:
	if regenerate_button != null:
		regenerate_button.disabled = not enabled

func _clear_board() -> void:
	_clear_player_progress()
	_clear_existing_grid()
	rows = 0
	cols = 0
	player_grid.clear()
	puzzle_solution.clear()
	mask.clear()

func _is_block(r: int, c: int) -> bool:
	if mask.is_empty():
		return true
	if r < 0 or r >= mask.size():
		return true
	if c < 0 or c >= mask[r].length():
		return true
	return mask[r][c] == '#'

func _assign_numbers() -> void:
	numbers.clear()
	var next_num := 1
	for r in range(rows):
		for c in range(cols):
			if _is_block(r, c):
				continue
			var starts_across := (c == 0 or _is_block(r, c - 1)) and (c + 1 < cols and not _is_block(r, c + 1))
			var starts_down := (r == 0 or _is_block(r - 1, c)) and (r + 1 < rows and not _is_block(r + 1, c))
			if starts_across or starts_down:
				numbers[Vector2i(r, c)] = Vector2i(
					next_num if starts_across else -1,
					next_num if starts_down else -1
				)
				next_num += 1

func _draw_numbers() -> void:
	for r in range(rows):
		for c in range(cols):
			var cell := cells[r][c] as CrosswordCell
			if cell != null:
				cell.set_number_text("")

	for key: Vector2i in numbers.keys():
		var r: int = key.x
		var c: int = key.y
		var pair: Vector2i = numbers[key]
		var label_num: int = max(pair.x, pair.y)
		if label_num <= 0:
			continue
		var cell := cells[r][c] as CrosswordCell
		if cell != null:
			cell.set_number_text(str(label_num))

func _clear_player_progress() -> void:
	_suppress_list_selection = true
	_clear_clue_buttons(across_list, across_buttons)
	_clear_clue_buttons(down_list, down_buttons)
	_suppress_list_selection = false
	if active_clue_label != null:
		active_clue_label.text = "CrosswordAP"
	_puzzle_ready = false
	
	var across_label := get_node_or_null("Margin/Layout/AcrossPanel/AcrossLabel") as Label
	var down_label := get_node_or_null("Margin/Layout/DownPanel/DownLabel") as Label
	if across_label != null:
		across_label.visible = false
	if down_label != null:
		down_label.visible = false
	_pending_clue_locations.clear()
	_pending_direct_clue_total = -1
	_pending_direct_clue_new = 0
	_pending_color_indicator = false
	_last_focus_change_frame = -1

	cell_slot_lookup.clear()
	across_entries.clear()
	down_entries.clear()
	entry_lookup.clear()
	solved_entry_count = 0
	hidden_entry_queue.clear()
	revealed_entry_count = 0
	unlocked_entry_count = 0
	claimed_location_ids.clear()
	sent_checks_for_entries.clear()
	letter_hints_used = 0
	letter_hints_available = 0
	total_letter_hint_items_received = 0
	_pending_letter_hints = 0
	_update_letter_hint_counter()
	puzzle_solution.clear()
	player_grid.clear()
	numbers.clear()
	current_entry = {}
	current_entry_id = -1
	current_cell = Vector2i(-1, -1)
	highlighted_cells.clear()
	_next_entry_id = 1
	across_selected_index = -1
	down_selected_index = -1

	for r in range(cells.size()):
		var row_cells: Array = cells[r]
		for c in range(row_cells.size()):
			var cell := row_cells[c] as CrosswordCell
			if cell == null:
				continue
			cell.clear_letter()
			cell.set_highlighted(false)
			cell.set_state(CrosswordCell.CellState.NONE)

func _clear_clue_buttons(container: VBoxContainer, store: Array) -> void:
	for child in container.get_children():
		child.queue_free()
	store.clear()

func _release_clue_focus() -> void:
	var released := false
	for button in across_buttons:
		var b := button as Button
		if b != null and b.has_focus():
			b.release_focus()
			released = true
	for button in down_buttons:
		var b := button as Button
		if b != null and b.has_focus():
			b.release_focus()
			released = true
	if released:
		_nav_log("released clue focus")

func _create_clue_button(text: String, direction: String, index: int, entry_id: int) -> Button:
	var button := Button.new()
	button.toggle_mode = true
	button.clip_text = false
	button.text = text
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.focus_mode = Control.FOCUS_ALL
	button.focus_neighbor_left = ""
	button.focus_neighbor_right = ""
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_WORD_ELLIPSIS
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if _clue_label_settings != null:
		button.add_theme_font_override("font", _clue_label_settings.font)
		button.add_theme_font_size_override("font_size", _clue_label_settings.font_size)
	button.add_theme_constant_override("line_spacing", 2)
	button.pressed.connect(_on_clue_button_pressed.bind(direction, index))
	button.gui_input.connect(_on_clue_button_gui_input.bind(direction, index, button))
	button.set_meta("entry_id", entry_id)
	
	# Create a solved overlay panel (green)
	var solved_overlay := Panel.new()
	solved_overlay.name = "SolvedOverlay"
	solved_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	solved_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	solved_overlay.visible = false
	
	# Create a StyleBoxFlat for the green overlay
	var solved_style := StyleBoxFlat.new()
	solved_style.bg_color = clue_solved_overlay_color
	solved_style.corner_radius_top_left = 3
	solved_style.corner_radius_top_right = 3
	solved_style.corner_radius_bottom_left = 3
	solved_style.corner_radius_bottom_right = 3
	# Expand the overlay slightly beyond the button bounds to ensure full coverage
	solved_style.expand_margin_left = 1
	solved_style.expand_margin_right = 1
	solved_style.expand_margin_top = 1
	solved_style.expand_margin_bottom = 1
	solved_overlay.add_theme_stylebox_override("panel", solved_style)
	
	button.add_child(solved_overlay)
	
	# Create a new clue overlay panel (yellow/gold)
	var new_overlay := Panel.new()
	new_overlay.name = "NewClueOverlay"
	new_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	new_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	new_overlay.visible = false
	
	# Create a StyleBoxFlat for the yellow/gold overlay
	var new_style := StyleBoxFlat.new()
	new_style.bg_color = clue_new_overlay_color
	new_style.corner_radius_top_left = 3
	new_style.corner_radius_top_right = 3
	new_style.corner_radius_bottom_left = 3
	new_style.corner_radius_bottom_right = 3
	new_style.expand_margin_left = 1
	new_style.expand_margin_right = 1
	new_style.expand_margin_top = 1
	new_style.expand_margin_bottom = 1
	new_overlay.add_theme_stylebox_override("panel", new_style)
	
	button.add_child(new_overlay)
	
	return button

func _set_button_group_state(buttons: Array, selected_idx: int) -> void:
	for i in range(buttons.size()):
		var button := buttons[i] as Button
		if button == null:
			continue
		button.button_pressed = (i == selected_idx)

func _ensure_clue_visible(direction: String, index: int) -> void:
	if index < 0:
		return
	var container := across_scroll
	var buttons := across_buttons
	if direction == "down":
		container = down_scroll
		buttons = down_buttons
	if index >= 0 and index < buttons.size():
		var button := buttons[index] as Button
		if button != null and container != null:
			container.ensure_control_visible(button)

func _on_clue_button_pressed(direction: String, index: int) -> void:
	if _suppress_list_selection:
		return
	if direction == "across":
		if index >= 0 and index < across_entries.size():
			var entry: Dictionary = across_entries[index]
			_set_active_entry(entry)
			_focus_cell(current_cell, true)
			if index >= 0 and index < across_buttons.size():
				var btn := across_buttons[index] as Button
				if btn != null:
					btn.release_focus()
	else:
		if index >= 0 and index < down_entries.size():
			var entry: Dictionary = down_entries[index]
			_set_active_entry(entry)
			_focus_cell(current_cell, true)
			if index >= 0 and index < down_buttons.size():
				var btn := down_buttons[index] as Button
				if btn != null:
					btn.release_focus()

func _on_clue_button_gui_input(event: InputEvent, direction: String, index: int, source_button: Button) -> void:
	var key_event := event as InputEventKey
	if key_event == null or not key_event.pressed:
		return
	if key_event.echo and key_event.keycode not in [KEY_BACKSPACE, KEY_UP, KEY_DOWN]:
		return
	match key_event.keycode:
		KEY_UP:
			_move_clue_focus(direction, index, -1)
			if source_button != null:
				source_button.accept_event()
			return
		KEY_DOWN:
			_move_clue_focus(direction, index, 1)
			if source_button != null:
				source_button.accept_event()
			return
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			_on_clue_button_pressed(direction, index)
			if source_button != null:
				source_button.release_focus()
				source_button.accept_event()
			return
		KEY_BACKSPACE:
			_handle_backspace_from_clue()
			if source_button != null:
				source_button.accept_event()
			return
		KEY_DELETE:
			_handle_delete_from_clue()
			if source_button != null:
				source_button.accept_event()
			return
	var unicode := key_event.unicode
	if unicode > 0 and not key_event.ctrl_pressed and not key_event.alt_pressed:
		var ch := String.chr(unicode)
		_handle_character_from_clue(ch)
		if source_button != null:
			source_button.accept_event()
		return

func _move_clue_focus(direction: String, index: int, delta: int) -> void:
	var buttons: Array = []
	var entries: Array = []
	if direction == "down":
		buttons = down_buttons
		entries = down_entries
	else:
		buttons = across_buttons
		entries = across_entries
	if buttons.is_empty() or entries.is_empty():
		return
	var new_index := index + delta
	if new_index < 0 or new_index >= buttons.size():
		return
	_nav_log("clue_focus direction=%s index=%d -> %d" % [direction, index, new_index])
	var entry: Dictionary = entries[new_index]
	if entry.has("cells") and entry["cells"].size() > 0:
		_set_active_entry(entry, entry["cells"][0], false)
	else:
		_set_active_entry(entry, Vector2i(-1, -1), false)
	var button := buttons[new_index] as Button
	if button != null:
		button.grab_focus()

func _handle_character_from_clue(ch: String) -> void:
	if current_cell.x < 0 or current_cell.y < 0:
		return
	var letter := ch.strip_edges()
	if letter.is_empty():
		return
	var code := letter.unicode_at(0)
	var is_letter := (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
	if not is_letter:
		return
	letter = String.chr(code).to_upper()
	_nav_log("clue_type letter='%s'" % letter)
	var cell := cells[current_cell.x][current_cell.y] as CrosswordCell
	if cell == null:
		return
	_letter_input_from_clue = true
	cell.set_letter(letter, true)
	_focus_cell(current_cell, false)

func _handle_backspace_from_clue() -> void:
	if current_cell.x < 0 or current_cell.y < 0:
		return
	var cell := cells[current_cell.x][current_cell.y] as CrosswordCell
	if cell == null:
		return
	if not cell.get_letter().is_empty():
		_nav_log("clue_backspace cleared cell")
		cell.set_letter("", true)
		# Ensure the state overlay is cleared immediately
		cell.set_state(CrosswordCell.CellState.NONE)
		# Re-check entries touching this cell to clear any solved overlays
		_check_entries_for_cell(current_cell)
		_focus_cell(current_cell, false)
		return
	_nav_log("clue_backspace moving to previous cell")
	if _advance(-1, false):
		var prev := current_cell
		if _is_in_bounds(prev):
			var prev_cell := cells[prev.x][prev.y] as CrosswordCell
			if prev_cell != null:
				prev_cell.set_letter("", true)
				_focus_cell(prev, false)

func _handle_delete_from_clue() -> void:
	if current_cell.x < 0 or current_cell.y < 0:
		return
	var cell := cells[current_cell.x][current_cell.y] as CrosswordCell
	if cell == null:
		return
	if cell.is_locked():
		return
	if not cell.get_letter().is_empty():
		_nav_log("clue_delete cleared cell")
		cell.set_letter("", true)
		cell.set_state(CrosswordCell.CellState.NONE)
		_check_entries_for_cell(current_cell)
	else:
		cell.set_state(CrosswordCell.CellState.NONE)
	_focus_cell(current_cell, false)

func _generate_puzzle() -> void:
	print("[DEBUG] Generate button pressed")
	if is_generating:
		print("[DEBUG] Already generating, ignoring")
		return
	print("[DEBUG] Ensuring word list...")
	if not _ensure_word_list():
		print("[DEBUG] Failed to ensure word list")
		return
	print("[DEBUG] Word list loaded successfully")
	# Surface word list size for parity diagnostics
	var wl_count: int = 0
	if word_list != null:
		var wl_all: Array = word_list.get_all_entries()
		if typeof(wl_all) == TYPE_ARRAY:
			wl_count = wl_all.size()
	_update_active_clue_message("Loaded word list (%d entries)" % wl_count)

	is_generating = true

	var generator_seed := random_seed
	if generator_seed != 0:
		generator_seed += _generation_counter
	_generation_counter += 1

	var generator := PROCEDURAL_GENERATOR.new() as ProceduralCrosswordGenerator
	if generator == null:
		push_error("Failed to instantiate procedural crossword generator.")
		is_generating = false
		return
	initial_reveal_override = INITIAL_REVEALED_CLUES

	# Enforce a minimum number of words in the generated puzzle
	var min_required: int = clamp(min_words, 1, max_words)
	# If using a tiny built-in fallback list, relax the minimum to improve success
	if _using_minimal_word_list:
		min_required = min(min_required, 6)

	var layout: Dictionary = {}
	var attempts := 0
	var max_attempts: int
	if _using_minimal_word_list:
		max_attempts = 20
	else:
		max_attempts = 10
	while attempts < max_attempts:
		var attempt_seed := generator_seed
		if generator_seed != 0:
			attempt_seed += attempts
		layout = generator.generate(
			word_list,
			grid_rows,
			grid_cols,
			MIN_ENTRY_LENGTH,
			max_words,
			attempt_seed,
			_build_category_weights(),
			trim_generated_grid
		)
		var entries_arr: Array = layout.get("entries", [])
		var entry_count: int = 0
		if typeof(entries_arr) == TYPE_ARRAY:
			entry_count = entries_arr.size()
		if not layout.is_empty() and entry_count >= min_required:
			break
		attempts += 1

	var final_entries: Array = layout.get("entries", [])
	var final_count: int = 0
	if typeof(final_entries) == TYPE_ARRAY:
		final_count = final_entries.size()
	if layout.is_empty() or final_count < min_required:
		if not layout.is_empty() and final_count >= 2:
			push_warning("Generated a smaller puzzle (%d words) below min %d due to constraints." % [final_count, min_required])
		else:
			push_warning("Failed to generate crossword with at least %d words (got %d). Try again or reduce min words." % [min_required, final_count])
			is_generating = false
			return

	_apply_layout(layout)
	_update_letter_hint_counter()
	is_generating = false

func _apply_layout(layout: Dictionary) -> void:
	_clear_player_progress()
	_clear_existing_grid()

	mask = layout.get("mask", [])
	rows = mask.size()
	if mask.is_empty():
		cols = 0
	else:
		cols = mask[0].length()

	if rows <= 0 or cols <= 0:
		push_warning("Generated crossword layout is empty.")
		return

	grid_container.columns = cols
	# Ensure no extra spacing from the container; we handle spacing via per-cell margins
	grid_container.add_theme_constant_override("h_separation", 0)
	grid_container.add_theme_constant_override("v_separation", 0)
	# Don’t clip child content so overlays can render fully
	grid_container.clip_contents = false
	_build_grid_from_mask()

	_assign_numbers()
	_draw_numbers()

	var entries: Array = layout.get("entries", [])
	var slots: Array = []
	var assignments: Array = []

	for entry in entries:
		var word: String = entry.get("word", "")
		if word.length() < MIN_ENTRY_LENGTH:
			continue

		var direction: String = entry.get("direction", "across")
		var start: Vector2i = entry.get("start", Vector2i.ZERO)
		var cells_list: Array = []
		for i in range(word.length()):
			var pos: Vector2i
			if direction == "across":
				pos = Vector2i(start.x, start.y + i)
			else:
				pos = Vector2i(start.x + i, start.y)
			cells_list.append(pos)
		var number_pair: Vector2i = numbers.get(start, Vector2i(-1, -1))
		var number: int
		if direction == "across":
			number = number_pair.x
		else:
			number = number_pair.y
		if number <= 0:
			continue
		var location_index: int = int(entry.get("location_index", slots.size() + 1))

		slots.append({
			"direction": direction,
			"number": number,
			"start": start,
			"length": word.length(),
			"cells": cells_list,
			"location_index": location_index,
		})
		assignments.append({
			"word": word,
			"clue": entry.get("clue", ""),
			"category": entry.get("category", ""),
			"location_index": location_index,
		})

	var board: Array = layout.get("board", [])
	_store_puzzle_results(slots, assignments, board)
	_draw_numbers()
	_populate_clue_lists()
	_select_initial_entry()
	_print_debug_clues()

func _clear_existing_grid() -> void:
	cells.clear()
	if not is_instance_valid(grid_container):
		return
	while grid_container.get_child_count() > 0:
		var child := grid_container.get_child(0)
		grid_container.remove_child(child)
		child.queue_free()
	grid_container.custom_minimum_size = Vector2.ZERO
	grid_container.size = Vector2.ZERO
	grid_container.position = Vector2.ZERO
	var parent_container := grid_container.get_parent() as Control
	if parent_container != null:
		parent_container.queue_sort()

func _build_grid_from_mask() -> void:
	cells.resize(rows)

	var block_style := StyleBoxFlat.new()
	block_style.bg_color = Color.BLACK
	# No border on black blocks; keep footprint identical to white cells without lines
	block_style.border_color = Color(0, 0, 0, 0)
	block_style.set_border_width_all(0)
	block_style.anti_aliasing = false
	grid_container.custom_minimum_size = Vector2(cols * cell_px, rows * cell_px)
	grid_container.size = grid_container.custom_minimum_size
	grid_container.position = Vector2.ZERO

	for r in range(rows):
		cells[r] = []
		for c in range(cols):
			if _is_block(r, c):
				# Wrap block in a MarginContainer to create an even 2px gap on all sides
				var wrapper := MarginContainer.new()
				wrapper.custom_minimum_size = Vector2(cell_px, cell_px)
				wrapper.add_theme_constant_override("margin_left", 2)
				wrapper.add_theme_constant_override("margin_right", 2)
				wrapper.add_theme_constant_override("margin_top", 2)
				wrapper.add_theme_constant_override("margin_bottom", 2)
				var block := Panel.new()
				# Fill the wrapper content area exactly (ensures same footprint as letter cells)
				block.anchor_left = 0.0
				block.anchor_top = 0.0
				block.anchor_right = 1.0
				block.anchor_bottom = 1.0
				block.offset_left = 0.0
				block.offset_top = 0.0
				block.offset_right = 0.0
				block.offset_bottom = 0.0
				block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				block.size_flags_vertical = Control.SIZE_EXPAND_FILL
				block.custom_minimum_size = Vector2(max(0, cell_px - 4), max(0, cell_px - 4))
				block.add_theme_stylebox_override("panel", block_style)
				wrapper.add_child(block)
				grid_container.add_child(wrapper)
				cells[r].append(null)
				continue

			var cell_instance := cell_scene.instantiate()
			var cell := cell_instance as CrosswordCell
			if cell == null:
				push_error("cell_scene must inherit from CrosswordCell.")
				cell_instance.queue_free()
				cells[r].append(null)
				continue

			# Wrap each letter cell to create a uniform 2px margin on all sides
			var wrapper := MarginContainer.new()
			wrapper.custom_minimum_size = Vector2(cell_px, cell_px)
			wrapper.add_theme_constant_override("margin_left", 2)
			wrapper.add_theme_constant_override("margin_right", 2)
			wrapper.add_theme_constant_override("margin_top", 2)
			wrapper.add_theme_constant_override("margin_bottom", 2)

			# Inner cell size minus margins
			cell.custom_minimum_size = Vector2(max(0, cell_px - 4), max(0, cell_px - 4))
			cell.configure_coords(r, c)
			cell.set_number_text("")
			cell.set_letter("", false)
			cell.set_state(CrosswordCell.CellState.NONE)
			cell.set_state_overlay_enabled(enable_state_overlay)

			var input := cell.get_node_or_null("Panel/TextBox") as LineEdit
			if input != null:
				var box := StyleBoxFlat.new()
				box.bg_color = Color(1, 1, 1, 0)
				box.border_color = Color(0, 0, 0, 0)
				box.set_border_width_all(0)
				input.add_theme_stylebox_override("normal", box)
				input.add_theme_stylebox_override("focus", box)

			cell.cell_focused.connect(_on_cell_focused)
			cell.letter_input.connect(_on_cell_letter_input)
			cell.navigation_requested.connect(_on_cell_navigation_requested)
			cell.cell_clicked.connect(_on_cell_clicked)
			cell.hint_requested.connect(_on_hint_requested)

			wrapper.add_child(cell)
			grid_container.add_child(wrapper)
			cells[r].append(cell)

func _store_puzzle_results(slots: Array, assignments: Array, board: Array) -> void:
	puzzle_solution = board.duplicate(true)
	across_entries.clear()
	down_entries.clear()
	cell_slot_lookup.clear()
	entry_lookup.clear()
	_next_entry_id = 1

	player_grid.resize(rows)
	for r in range(rows):
		player_grid[r] = []
		for c in range(cols):
			if _is_block(r, c):
				player_grid[r].append("#")
				continue

			player_grid[r].append("")
			var cell := cells[r][c] as CrosswordCell
			if cell == null:
				continue
			cell.clear_letter()
			cell.set_highlighted(false)
			cell.set_state(CrosswordCell.CellState.NONE)
			cell.set_solution(board[r][c])

	for i in range(slots.size()):
		var slot: Dictionary = slots[i]
		var assignment: Dictionary = assignments[i]
		if assignment == null:
			continue

		var slot_cells: Array = slot["cells"].duplicate()
		var location_index: int = int(slot.get("location_index", i + 1))
		var slot_data := {
			"id": _next_entry_id,
			"number": slot["number"],
			"clue": assignment["clue"],
			"answer": assignment["word"],
			"category": assignment.get("category", ""),
			"cells": slot_cells,
			"direction": slot["direction"],
			"length": slot["length"],
			"start": slot["start"],
			"solved": false,
			"revealed": false,
			"location_index": location_index,
		}
		_next_entry_id += 1

		if slot["direction"] == "across":
			across_entries.append(slot_data)
		else:
			down_entries.append(slot_data)

		_register_slot_cells(slot_data)
		entry_lookup[slot_data["id"]] = slot_data
		var start_pos: Vector2i = slot["start"]
		if _is_in_bounds(start_pos):
			var start_cell := cells[start_pos.x][start_pos.y] as CrosswordCell
			if start_cell != null:
				start_cell.set_number_text(str(slot["number"]))

	_setup_clue_visibility(initial_reveal_override)

func _register_slot_cells(slot_data: Dictionary) -> void:
	for cell_pos in slot_data["cells"]:
		var pos := cell_pos as Vector2i
		if not cell_slot_lookup.has(pos):
			cell_slot_lookup[pos] = {}
		cell_slot_lookup[pos][slot_data["direction"]] = slot_data

func _setup_clue_visibility(initial_reveal_count: int) -> void:
	hidden_entry_queue.clear()
	revealed_entry_count = 0
	unlocked_entry_count = 0
	var all_entries: Array = []
	for i in range(across_entries.size()):
		var entry: Dictionary = across_entries[i]
		entry["revealed"] = false
		all_entries.append(entry)
		entry_lookup[entry.get("id", -1)] = entry
	for i in range(down_entries.size()):
		var entry: Dictionary = down_entries[i]
		entry["revealed"] = false
		all_entries.append(entry)
		entry_lookup[entry.get("id", -1)] = entry
	if all_entries.is_empty():
		return
	if current_mode == PlayMode.OFFLINE:
		for entry in all_entries:
			entry["revealed"] = true
			revealed_entry_count += 1
		return
	var reveal_target: int = min(initial_reveal_count, all_entries.size())
	var rng := RandomNumberGenerator.new()
	if random_seed != 0:
		rng.seed = random_seed + int(_generation_counter) * 7919 + 1337
	else:
		rng.randomize()
	var ordered_entries: Array = _order_entries_by_priority(all_entries, rng)
	for i in range(ordered_entries.size()):
		var entry: Dictionary = ordered_entries[i]
		var entry_id: int = entry.get("id", -1)
		if i < reveal_target:
			entry["revealed"] = true
			revealed_entry_count += 1
		else:
			entry["revealed"] = false
			hidden_entry_queue.append(entry_id)
		entry_lookup[entry_id] = entry

func _current_total_words() -> int:
	# Prefer explicit slot data if present
	var total_variant: Variant = ap_slot_data.get("total_words", null)
	var total: int = 0
	match typeof(total_variant):
		TYPE_INT:
			total = total_variant
		TYPE_FLOAT:
			total = int(total_variant)
		_:
			total = across_entries.size() + down_entries.size()
	if total <= 0:
		total = across_entries.size() + down_entries.size()
	return total

func _next_unclaimed_index() -> int:
	if ap_client == null:
		return 0
	var total: int = _current_total_words()
	for i in range(1, total + 1):
		var ap_id: int = int(ap_client.get_location_id_for_clue(i))
		if ap_id <= 0:
			continue
		if not claimed_location_ids.has(ap_id):
			return i
	return 0

func _send_goal_if_complete() -> void:
	var total: int = _current_total_words()
	if solved_entry_count < total:
		return
	if _status_locked:
		return
	# If online, notify AP server; otherwise just update UI
	if ap_client != null and ap_client.is_ap_connected():
		ap_client.send_goal()
	# Show completion and then lock future updates
	_update_active_clue_message("Crossword Completed!")
	_status_locked = true

func _order_entries_by_priority(entries: Array, rng: RandomNumberGenerator) -> Array:
	var buckets: Dictionary = {}
	for entry_variant in entries:
		var entry: Dictionary = entry_variant as Dictionary
		var priority: int = _entry_priority(entry)
		var bucket: Array = buckets.get(priority, []) as Array
		bucket.append(entry)
		buckets[priority] = bucket
	var ordered: Array = []
	var priority_keys: Array = buckets.keys()
	priority_keys.sort()
	for key_variant in priority_keys:
		var key: int = key_variant
		var bucket: Array = buckets.get(key, []) as Array
		if bucket.size() > 1:
			for i in range(bucket.size() - 1, 0, -1):
				var j: int = rng.randi_range(0, i)
				var temp: Dictionary = bucket[i] as Dictionary
				var swap_entry: Dictionary = bucket[j] as Dictionary
				bucket[i] = swap_entry
				bucket[j] = temp
		for entry_variant in bucket:
			ordered.append(entry_variant as Dictionary)
	return ordered

func _entry_is_revealed(entry: Dictionary) -> bool:
	return entry.get("revealed", false)

func _entry_priority(entry: Dictionary) -> int:
	var category: String = entry.get("category", "")
	if CATEGORY_PRIORITY.has(category):
		return CATEGORY_PRIORITY[category]
	return 1

func _format_entry_button_text(entry: Dictionary) -> String:
	if _entry_is_revealed(entry):
		return _format_clue_display(entry.get("number", 0), entry.get("clue", ""))
	var number: int = entry.get("number", 0)
	return "%d. [Locked]" % number

func _configure_clue_button(button: Button, entry: Dictionary) -> void:
	if button == null:
		return
	button.text = _format_entry_button_text(entry)
	button.disabled = not _entry_is_revealed(entry)
	button.tooltip_text = ""
	
	# Update solved overlay (green)
	var solved_overlay := button.get_node_or_null("SolvedOverlay")
	if solved_overlay != null:
		solved_overlay.visible = entry.get("solved", false)
	
	# Update new clue overlay (yellow/gold) - only in archipelago mode
	var new_overlay := button.get_node_or_null("NewClueOverlay")
	if new_overlay != null:
		# Show if newly revealed and not solved, hide if solved or not new
		var is_new: bool = entry.get("newly_revealed", false)
		var is_solved: bool = entry.get("solved", false)
		new_overlay.visible = is_new and not is_solved and current_mode == PlayMode.ARCHIPELAGO

func _update_button_for_entry(entry: Dictionary) -> void:
	var entry_id: int = entry.get("id", -1)
	for button in across_buttons:
		var b := button as Button
		if b != null and b.get_meta("entry_id", -1) == entry_id:
			_configure_clue_button(b, entry)
			return
	for button in down_buttons:
		var b := button as Button
		if b != null and b.get_meta("entry_id", -1) == entry_id:
			_configure_clue_button(b, entry)
			return

func _set_entry_revealed(entry_id: int) -> bool:
	if not entry_lookup.has(entry_id):
		return false
	var entry: Dictionary = entry_lookup[entry_id]
	if _entry_is_revealed(entry):
		return false
	entry["revealed"] = true
	# Mark as newly revealed in archipelago mode
	if current_mode == PlayMode.ARCHIPELAGO:
		entry["newly_revealed"] = true
	entry_lookup[entry_id] = entry
	_update_button_for_entry(entry)
	if current_entry_id == entry_id:
		current_entry = entry
		_update_active_clue_label()
	_queue_save_progress()
	return true

func _reveal_next_hidden_entry() -> bool:
	var revealed := false
	while not hidden_entry_queue.is_empty() and not revealed:
		var entry_id := hidden_entry_queue[0]
		hidden_entry_queue.remove_at(0)
		revealed = _set_entry_revealed(entry_id)
	if revealed:
		revealed_entry_count += 1
		unlocked_entry_count += 1
	return revealed

func _populate_clue_lists() -> void:
	_suppress_list_selection = true
	_clear_clue_buttons(across_list, across_buttons)
	_clear_clue_buttons(down_list, down_buttons)
	_sort_entry_lists()

	for i in range(across_entries.size()):
		var entry: Dictionary = across_entries[i]
		entry["list_index"] = i
		var button := _create_clue_button("", "across", i, entry.get("id", -1))
		_configure_clue_button(button, entry)
		across_list.add_child(button)
		across_buttons.append(button)

	for i in range(down_entries.size()):
		var entry: Dictionary = down_entries[i]
		entry["list_index"] = i
		var button := _create_clue_button("", "down", i, entry.get("id", -1))
		_configure_clue_button(button, entry)
		down_list.add_child(button)
		down_buttons.append(button)

	_suppress_list_selection = false
	
	var across_label := get_node_or_null("Margin/Layout/AcrossPanel/AcrossLabel") as Label
	var down_label := get_node_or_null("Margin/Layout/DownPanel/DownLabel") as Label
	if across_label != null:
		across_label.visible = true
	if down_label != null:
		down_label.visible = true

func _select_initial_entry() -> void:
	var entry := _find_first_revealed(across_entries)
	if entry.is_empty():
		entry = _find_first_revealed(down_entries)
	if entry.is_empty():
		_set_active_entry({})
		return
	var entry_cells: Array = entry.get("cells", [])
	var focus := Vector2i(-1, -1)
	if entry_cells.size() > 0:
		focus = entry_cells[0] as Vector2i
	_set_active_entry(entry, focus)

func _find_first_revealed(entries: Array) -> Dictionary:
	for entry_variant in entries:
		var entry: Dictionary = entry_variant as Dictionary
		if entry.get("revealed", false):
			return entry
	return {}

func _set_active_entry(entry: Dictionary, focus_pos: Vector2i = Vector2i(-1, -1), grab_focus: bool = true) -> void:
	if entry.is_empty():
		_clear_highlight()
		current_entry = {}
		current_entry_id = -1
		if active_clue_label != null:
			active_clue_label.text = "Select a clue"
		solved_entry_count = 0
		return
	_nav_log("set_active_entry id=%s dir=%s" % [str(entry.get("id", -1)), entry.get("direction", "across")])

	# Clear "newly_revealed" flag when a clue is clicked
	if entry.get("newly_revealed", false):
		var entry_id: int = entry.get("id", -1)
		if entry_lookup.has(entry_id):
			entry["newly_revealed"] = false
			entry_lookup[entry_id] = entry
			_update_button_for_entry(entry)

	_clear_highlight()
	current_entry = entry
	current_entry_id = entry.get("id", -1)
	current_direction = entry.get("direction", "across")
	highlighted_cells = []
	for cell_pos in entry["cells"]:
		highlighted_cells.append(cell_pos)

	if focus_pos == Vector2i(-1, -1):
		focus_pos = highlighted_cells[0]

	_update_list_selection(entry)
	_update_active_clue_label()
	_focus_cell(focus_pos, grab_focus)

func _update_list_selection(entry: Dictionary) -> void:
	_suppress_list_selection = true
	if entry.get("direction", "across") == "across":
		_set_button_group_state(across_buttons, entry.get("list_index", -1))
		_set_button_group_state(down_buttons, -1)
		down_selected_index = -1
		across_selected_index = entry.get("list_index", -1)
		_ensure_clue_visible("across", across_selected_index)
	else:
		_set_button_group_state(down_buttons, entry.get("list_index", -1))
		_set_button_group_state(across_buttons, -1)
		across_selected_index = -1
		down_selected_index = entry.get("list_index", -1)
		_ensure_clue_visible("down", down_selected_index)
	_suppress_list_selection = false

func _update_active_clue_label() -> void:
	if _status_locked:
		return
	if active_clue_label == null:
		return
	if current_entry_id == -1 or current_entry.is_empty():
		active_clue_label.text = "Select a clue"
		return
	var suffix := "A" if current_direction == "across" else "D"
	var clue_text: String = current_entry.get("clue", "") if _entry_is_revealed(current_entry) else "[Locked]"
	active_clue_label.text = "%d%s. %s" % [
		current_entry.get("number", 0),
		suffix,
		clue_text,
	]

func _focus_cell(pos: Vector2i, grab_focus: bool = true) -> void:
	if not _is_in_bounds(pos):
		return
	var cell := cells[pos.x][pos.y] as CrosswordCell
	if cell == null:
		return
	_nav_log("focus_cell pos=%s grab=%s" % [str(pos), str(grab_focus)])
	_previous_current_cell = current_cell
	current_cell = pos
	_last_focus_change_frame = Engine.get_process_frames()
	_refresh_highlight()
	if grab_focus:
		_release_clue_focus()
		cell.grab_cell_focus()

func _refresh_highlight() -> void:
	for pos in highlighted_cells:
		var cell := cells[pos.x][pos.y] as CrosswordCell
		if cell == null:
			continue
		cell.set_highlighted(true, pos == current_cell)

func _clear_highlight() -> void:
	for pos in highlighted_cells:
		var cell := cells[pos.x][pos.y] as CrosswordCell
		if cell != null:
			cell.set_highlighted(false)
	highlighted_cells.clear()

func is_cell_current(pos: Vector2i) -> bool:
	return current_cell == pos

func _select_entry_for_cell(pos: Vector2i, prefer_direction: String = "", grab_focus: bool = true) -> void:

	if cell_slot_lookup.is_empty():
		_focus_cell(pos, grab_focus)
		return

	var options: Dictionary = cell_slot_lookup.get(pos, {})
	if options.is_empty():
		_focus_cell(pos, grab_focus)
		return
	_nav_log("select_entry_for_cell pos=%s prefer=%s options=%s" % [str(pos), prefer_direction, str(options.keys())])

	var direction := ""
	if not prefer_direction.is_empty() and options.has(prefer_direction):
		direction = prefer_direction
	elif options.has(current_direction):
		direction = current_direction
	elif options.has("across"):
		direction = "across"
	elif options.has("down"):
		direction = "down"
	else:
		for key in options.keys():
			direction = key
			break

	if direction.is_empty():
		_focus_cell(pos, grab_focus)
		return

	var entry: Dictionary = options[direction]
	_set_active_entry(entry, pos, grab_focus)

func _on_cell_focused(row: int, col: int) -> void:
	var pos := Vector2i(row, col)
	if pos == current_cell:
		return
	_select_entry_for_cell(pos, current_direction)

func _on_cell_clicked(row: int, col: int, _was_current: bool) -> void:
	var pos := Vector2i(row, col)
	var has_active := (pos == _last_clicked_cell)
	_last_clicked_cell = pos
	
	var options: Dictionary = cell_slot_lookup.get(pos, {})
	var is_across := options.has("across")
	var is_down := options.has("down")
	var is_intersection := is_across and is_down
	var cell := cells[pos.x][pos.y] as CrosswordCell
	var num_label := cell.get_number_text() if cell else ""
	var has_num_label := num_label != ""
	var selected_direction := ""
	
	if DEBUG_CLICK_TRACKING:
		var num_info := ""
		if is_across and is_down:
			var across_num: int = options["across"].get("number", 0)
			var down_num: int = options["down"].get("number", 0)
			num_info = "%d across, %d down" % [across_num, down_num]
		elif is_across:
			var across_num: int = options["across"].get("number", 0)
			num_info = "%d across" % across_num
		elif is_down:
			var down_num: int = options["down"].get("number", 0)
			num_info = "%d down" % down_num
		
		var clue_info := ""
		if has_num_label and num_label != "":
			if is_across and not is_down:
				clue_info = " -> %s across" % num_label
			elif is_down and not is_across:
				clue_info = " -> %s down" % num_label
			elif is_intersection:
				var across_num: int = options["across"].get("number", 0)
				var down_num: int = options["down"].get("number", 0)
				var label_num: int = int(num_label)
				if label_num == across_num and label_num == down_num:
					clue_info = " -> %d across or %d down" % [across_num, down_num]
				elif label_num == across_num:
					clue_info = " -> %d across" % across_num
				elif label_num == down_num:
					clue_info = " -> %d down" % down_num
				else:
					clue_info = " -> %d across or %d down" % [across_num, down_num]
		
		print_debug("[Overlay] cell_click pos=%s had_active=%s across=%s down=%s intersection=%s has_num=%s num_label=%s (%s)%s" % [str(pos), str(has_active), str(is_across), str(is_down), str(is_intersection), str(has_num_label), num_label, num_info, clue_info])
	
	# Determine selected direction from number label
	if has_num_label and num_label != "":
		if is_across and not is_down:
			selected_direction = "across"
		elif is_down and not is_across:
			selected_direction = "down"
		elif is_intersection:
			var across_num: int = options["across"].get("number", 0)
			var down_num: int = options["down"].get("number", 0)
			var label_num: int = int(num_label)
			if label_num == across_num and label_num != down_num:
				selected_direction = "across"
			elif label_num == down_num and label_num != across_num:
				selected_direction = "down"
	
	if has_active and is_intersection:
		_toggle_direction(pos)
	elif not has_active and selected_direction != "":
		if selected_direction == "across":
			_set_active_entry(options["across"], pos)
		elif selected_direction == "down":
			_set_active_entry(options["down"], pos)

func _on_hint_requested(row: int, col: int) -> void:
	var pos := Vector2i(row, col)
	if not _is_in_bounds(pos):
		return
	if puzzle_solution.is_empty() or row >= puzzle_solution.size() or col >= puzzle_solution[row].size():
		return
	
	# Always update position even if hint fails
	_select_entry_for_cell(pos, current_direction)
	
	# In Archipelago mode, check if hints are enabled and available
	if current_mode == PlayMode.ARCHIPELAGO:
		if not letter_hints_enabled:
			_update_active_clue_message("Letter Hints are disabled!")
			return
		if letter_hints_available <= 0:
			_update_active_clue_message("No Letter Hints available!")
			return
	
	var cell := cells[row][col] as CrosswordCell
	if cell == null:
		return
	
	var solution_letter: String = puzzle_solution[row][col]
	if solution_letter.is_empty() or solution_letter == "#":
		return
	
	# Don't give hints for already correct letters
	var current_letter := cell.get_letter().to_upper()
	if current_letter == solution_letter.to_upper():
		_update_active_clue_message("Letter already correct!")
		return
	
	# Fill in the correct letter
	cell.set_letter(solution_letter, true, true)
	player_grid[row][col] = solution_letter
	
	# Set to correct state (green)
	_apply_cell_state_from_correctness(cell, true)
	
	# Update hint counters
	if current_mode == PlayMode.ARCHIPELAGO:
		letter_hints_available -= 1
	else:
		letter_hints_used += 1
	_update_letter_hint_counter()
	
	_check_entries_for_cell(pos)
	_queue_save_progress()
	print_debug("[Hint] Revealed letter '%s' at (%d, %d)" % [solution_letter, row, col])

func _update_letter_hint_counter() -> void:
	if letter_hint_count != null:
		var board_ready := false
		match current_mode:
			PlayMode.OFFLINE:
				board_ready = not player_grid.is_empty()
			PlayMode.ARCHIPELAGO:
				board_ready = _puzzle_ready
			_:
				board_ready = false

		if not board_ready:
			letter_hint_count.visible = false
			return

		if current_mode == PlayMode.OFFLINE:
			letter_hint_count.text = "Letter Hints Used: %d" % letter_hints_used
			letter_hint_count.visible = true
		elif current_mode == PlayMode.ARCHIPELAGO:
			if letter_hints_enabled:
				letter_hint_count.text = "Letter Hints Available: %d" % letter_hints_available
				letter_hint_count.visible = true
			else:
				letter_hint_count.visible = false
		else:
			letter_hint_count.visible = false

func _on_cell_letter_input(row: int, col: int, letter: String) -> void:
	if player_grid.is_empty():
		return
	_nav_log("letter_input cell=%s letter='%s'" % [str(Vector2i(row, col)), letter])

	var pos := Vector2i(row, col)
	if not _is_in_bounds(pos):
		return

	player_grid[row][col] = letter
	_queue_save_progress()

	var cell := cells[row][col] as CrosswordCell
	if cell == null:
		return

	if letter.is_empty():
		cell.set_state(CrosswordCell.CellState.NONE)
		return

	var hold_position := Input.is_key_pressed(KEY_SHIFT)
	_hold_position_next_input = hold_position

	var solution_letter: String = puzzle_solution[row][col]
	var correct := solution_letter != "" and letter == solution_letter
	var applied_state := _apply_cell_state_from_correctness(cell, correct)
	if current_mode == PlayMode.ARCHIPELAGO:
		if DEBUG_COLOR_INDICATOR:
			var overlay_visible := enable_state_overlay and has_color_indicator
			var overlay_state := "visible" if overlay_visible else "hidden"
			var state_name := "NONE"
			match applied_state:
				CrosswordCell.CellState.CORRECT:
					state_name = "CORRECT"
				CrosswordCell.CellState.INCORRECT:
					state_name = "INCORRECT"
			print_debug("[ColorIndicator] Cell %s: enable_overlay=%s has_indicator=%s letter_correct=%s state=%s overlay=%s" % [str(pos), str(enable_state_overlay), str(has_color_indicator), str(correct), state_name, overlay_state])
	else:
		if DEBUG_CORRECT_STATE and correct:
			print_debug("[CorrectState] Cell marked correct: pos=%s editable=%s" % [str(pos), str(cell._text.editable)])
	_check_entries_for_cell(pos)
	_pending_advance_entry_id = current_entry_id
	call_deferred("_deferred_advance", 1)

func _deferred_advance(step: int) -> void:
	var hold_position := _hold_position_next_input
	_hold_position_next_input = false
	var from_clue := _letter_input_from_clue
	_letter_input_from_clue = false
	if current_entry_id != _pending_advance_entry_id:
		_pending_advance_entry_id = -1
		return
	_pending_advance_entry_id = -1
	if hold_position:
		return
	_advance(step, not from_clue)

func _check_entries_for_cell(pos: Vector2i) -> void:
	var options: Dictionary = cell_slot_lookup.get(pos, {})
	for key in options.keys():
		var entry: Dictionary = options[key]
		var entry_id: int = entry.get("id", -1)
		var was_solved: bool = entry.get("solved", false)
		var now_solved: bool = _is_entry_solved(entry)
		if now_solved and not was_solved:
			print_debug("[APCheck] Entry solved id=%d number=%d loc_idx=%d" % [entry_id, entry.get("number", 0), int(entry.get("location_index", -1))])
			entry["solved"] = true
			entry["newly_revealed"] = false  # Clear new overlay when solved
			entry_lookup[entry_id] = entry
			solved_entry_count += 1
			if current_mode == PlayMode.ARCHIPELAGO:
				_update_cells_for_entry(entry, true)
				_send_archipelago_location_for_entry(entry)
			_update_button_for_entry(entry)
			emit_signal("entry_solved", entry_id, entry)
			emit_signal("solved_count_changed", solved_entry_count)
			_queue_save_progress()
			_send_goal_if_complete()
		elif was_solved and not now_solved:
			# In Archipelago mode, once solved, keep the overlay locked
			if current_mode == PlayMode.ARCHIPELAGO:
				# Keep overlay locked, don't allow unsolved state
				return
			# Word was edited back to unsolved; clear overlays and update count (offline only)
			entry["solved"] = false
			entry_lookup[entry_id] = entry
			_update_cells_for_entry(entry, false)
			_update_button_for_entry(entry)
			solved_entry_count = max(0, solved_entry_count - 1)
			emit_signal("solved_count_changed", solved_entry_count)
			_queue_save_progress()

func _update_cells_for_entry(entry: Dictionary, solved: bool) -> void:
	var cells_list: Array = entry.get("cells", []) as Array
	for cell_pos_variant in cells_list:
		var cell_pos := cell_pos_variant as Vector2i
		if not _is_in_bounds(cell_pos):
			continue
		var cell: CrosswordCell = cells[cell_pos.x][cell_pos.y] as CrosswordCell
		if cell == null:
			continue
		if solved:
			cell.set_highlighted(false)
			_apply_cell_state_from_correctness(cell, true)
		else:
			cell.set_state(CrosswordCell.CellState.NONE)

func _send_archipelago_location_for_entry(entry: Dictionary) -> void:
	if ap_client == null or not ap_client.is_ap_connected():
		print_debug("[APCheck] Cannot send location: client=%s connected=%s" % [str(ap_client != null), str(ap_client.is_ap_connected() if ap_client else false)])
		return
	
	# Check if we already sent a check for this specific entry
	var entry_id: int = entry.get("id", -1)
	if entry_id < 0:
		print_debug("[APCheck] Invalid entry_id for entry: %s" % str(entry))
		return
	if sent_checks_for_entries.has(entry_id):
		print_debug("[APCheck] Already sent check for entry_id=%d (word '%s')" % [entry_id, str(entry.get("answer", ""))])
		return
	
	# Send the next sequential location check (1, 2, 3, ...) based on how many we've sent
	var next_check_index := sent_checks_for_entries.size() + 1
	var next_ap_id: int = ap_client.get_location_id_for_clue(next_check_index)
	if next_ap_id <= 0:
		print_debug("[APCheck] Invalid next_ap_id for check_index %d" % next_check_index)
		return
	
	print_debug("[APCheck] Sending location check #%d (ap_id=%d) for word '%s' (clue %d, entry_id=%d)" % [next_check_index, next_ap_id, str(entry.get("answer", "")), entry.get("number", 0), entry_id])
	ap_client.send_location_checks([next_ap_id])
	sent_checks_for_entries[entry_id] = true
	# Don't add to claimed_location_ids here - wait for the server to confirm via location_checked or items_received
	var clue_number: int = entry.get("number", 0)
	_nav_log("sent location check #%d (ap_id=%d) for clue %d" % [next_check_index, next_ap_id, clue_number])
	_update_active_clue_message("Solved %d Word%s" % [next_check_index, "s" if next_check_index != 1 else ""])
	_queue_save_progress()

func _on_ap_location_checked(location_ids: Array) -> void:
	_process_ap_locations(location_ids, false)

func _on_ap_items_received(location_ids: Array) -> void:
	if not _puzzle_ready:
		for loc_variant in location_ids:
			var loc_id := _coerce_int(loc_variant)
			if loc_id == 0:
				continue
			_pending_clue_locations[loc_id] = true
		return
	_process_ap_locations(location_ids, true)

func _on_ap_direct_clues_received(total_from_server: int, new_from_packet: int = -1) -> void:
	if not _puzzle_ready:
		if total_from_server > _pending_direct_clue_total:
			_pending_direct_clue_total = total_from_server
		if new_from_packet > 0:
			_pending_direct_clue_new += new_from_packet
		return
	_handle_direct_clue_total(total_from_server, new_from_packet)

func _handle_direct_clue_total(total_from_server: int, new_clues_override: int = -1) -> void:
	# The server sends us the total count of all direct clues we've ever received
	# Compare to what we had before and add the difference
	print_debug("[APDirectClues] Received packet with %d total direct clues, we had %d before" % [total_from_server, total_direct_clues_received])
	
	var diff := total_from_server - total_direct_clues_received
	var new_clues := new_clues_override
	if new_clues < 0:
		new_clues = diff
	else:
		if diff > 0:
			new_clues = max(new_clues, diff)

	if new_clues <= 0:
		print_debug("[APDirectClues] No new direct clues (already had all %d)" % total_from_server)
		total_direct_clues_received = max(total_direct_clues_received, total_from_server)
		return

	var revealed_count := 0
	for i in range(new_clues):
		if _reveal_next_hidden_entry():
			revealed_count += 1

	if revealed_count <= 0:
		print_debug("[APDirectClues] No hidden entries left to reveal")
		total_direct_clues_received = max(total_direct_clues_received, total_from_server)
		return

	if revealed_count == 1:
		_update_active_clue_message("Found Clue")
	else:
		_update_active_clue_message("Found %d Clues" % revealed_count)
	_populate_clue_lists()
	_queue_save_progress()
	print_debug("[APDirectClues] Revealed %d new clues!" % revealed_count)
	if diff > 0:
		total_direct_clues_received = max(total_direct_clues_received, total_from_server)
	else:
		total_direct_clues_received = max(total_direct_clues_received + revealed_count, total_from_server)

func _on_ap_color_indicator_received() -> void:
	if not _puzzle_ready:
		_pending_color_indicator = true
		return
	_apply_color_indicator_item()

func _apply_color_indicator_item() -> void:
	has_color_indicator = true
	if DEBUG_COLOR_INDICATOR:
		print_debug("[ColorIndicator] Item received! has_indicator=true - refreshing all cell states")
	_update_active_clue_message("Color Indicator Unlocked!")
	_refresh_all_cell_states()
	_queue_save_progress()

func _apply_background_gradient() -> void:
	if _background_gradient_rect == null:
		return
	_background_gradient_rect.visible = enable_background_gradient
	if not enable_background_gradient:
		_background_gradient_rect.texture = null
		return
	if _background_gradient_texture == null:
		_background_gradient_texture = GradientTexture2D.new()
	var gradient := Gradient.new()
	gradient.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_LINEAR
	gradient.set_color(0, background_gradient_top_color)
	gradient.set_offset(0, 0.0)
	if gradient.get_point_count() < 2:
		gradient.add_point(1.0, background_gradient_bottom_color)
	else:
		gradient.set_color(1, background_gradient_bottom_color)
		gradient.set_offset(1, 1.0)
	_background_gradient_texture.gradient = gradient
	_background_gradient_texture.width = max(1, background_gradient_size.x)
	_background_gradient_texture.height = max(1, background_gradient_size.y)
	_background_gradient_texture.fill = GradientTexture2D.FILL_LINEAR
	var angle_rad := deg_to_rad(background_gradient_angle_deg)
	var direction := Vector2(cos(angle_rad), sin(angle_rad)).normalized()
	if direction.is_zero_approx():
		direction = Vector2.UP
	var half := direction * 0.5
	var center := Vector2(0.5, 0.5)
	_background_gradient_texture.fill_from = center - half
	_background_gradient_texture.fill_to = center + half
	_background_gradient_rect.texture = _background_gradient_texture

func _apply_new_letter_hints(count: int) -> void:
	if count <= 0:
		return
	letter_hints_available += count
	total_letter_hint_items_received += count
	_update_letter_hint_counter()
	_queue_save_progress()
	if count == 1:
		_update_active_clue_message("Received Letter Hint")
	else:
		_update_active_clue_message("Received %d Letter Hints" % count)
	print_debug("[LetterHint] Added %d new hints! Now have %d available" % [count, letter_hints_available])

func _on_ap_letter_hint_received(new_hints: int) -> void:
	# Only process if letter hints are enabled
	if not letter_hints_enabled:
		print_debug("[LetterHint] Received hints but feature is disabled, ignoring")
		return

	# The signal now contains only NEW hints, not total
	print_debug("[LetterHint] Received %d new hints" % new_hints)

	if ap_client == null:
		print_debug("[LetterHint] AP client missing; ignoring packet")
		return

	var server_total: int = int(ap_client.get_total_letter_hint_items_seen())
	var accounted: int = total_letter_hint_items_received + _pending_letter_hints
	var actual_new: int = int(max(0, server_total - accounted))
	if actual_new <= 0:
		print_debug("[LetterHint] All hints already applied (server_total=%d accounted=%d)" % [server_total, accounted])
		return
	print_debug("[LetterHint] Resolving %d new hints (server_total=%d accounted=%d)" % [actual_new, server_total, accounted])

	if not _puzzle_ready:
		_pending_letter_hints += actual_new
		print_debug("[LetterHint] Puzzle not ready; queued %d hints (pending=%d)" % [actual_new, _pending_letter_hints])
		return

	_apply_new_letter_hints(actual_new)

func _apply_cell_state_from_correctness(cell: CrosswordCell, correct: bool) -> int:
	if cell == null:
		return CrosswordCell.CellState.NONE
	var target_state := CrosswordCell.CellState.NONE
	if current_mode == PlayMode.ARCHIPELAGO:
		if has_color_indicator:
			target_state = CrosswordCell.CellState.CORRECT if correct else CrosswordCell.CellState.INCORRECT
		else:
			target_state = CrosswordCell.CellState.NONE
	else:
		target_state = CrosswordCell.CellState.CORRECT if correct else CrosswordCell.CellState.INCORRECT
	cell.set_state(target_state)
	return target_state

func _refresh_all_cell_states() -> void:
	# Refresh all cell states to show correct colors based on has_color_indicator
	for r in range(puzzle_solution.size()):
		for c in range(puzzle_solution[r].size()):
			if cells[r][c] != null:
				var cell := cells[r][c] as CrosswordCell
				var letter := cell.get_letter()
				var solution_letter := str(puzzle_solution[r][c])
				if letter != "" and solution_letter != "":
					var correct := letter.to_upper() == solution_letter.to_upper()
					_apply_cell_state_from_correctness(cell, correct)

func _coerce_int(value: Variant) -> int:
	match typeof(value):
		TYPE_INT:
			return value
		TYPE_FLOAT:
			return int(value)
		TYPE_STRING:
			var text := String(value).strip_edges()
			if text.is_empty():
				return 0
			var parsed := int(text)
			if parsed != 0 or text == "0":
				return parsed
	return 0

func _process_ap_locations(location_ids: Array, unlock_clues: bool, force: bool = false) -> void:
	if not force and current_mode != PlayMode.ARCHIPELAGO:
		return
	if location_ids.is_empty():
		return
	
	# Filter out locations we've already processed
	var new_locations: Array = []
	for loc_variant in location_ids:
		var loc_id := _coerce_int(loc_variant)
		if loc_id == 0:
			continue
		if processed_clue_locations.has(loc_id):
			print_debug("[APProcess] Skipping already processed clue location %d" % loc_id)
			continue
		new_locations.append(loc_id)
	
	if new_locations.is_empty():
		print_debug("[APProcess] No new clue locations to process")
		return
	
	print_debug("[APProcess] Processing %d new clue locations" % new_locations.size())
	
	var revealed := false
	var new_location_logged := false
	for loc_variant in new_locations:
		var loc_id := _coerce_int(loc_variant)
		if claimed_location_ids.has(loc_id):
			continue
		claimed_location_ids[loc_id] = true
		new_location_logged = true
		if unlock_clues:
			var did_reveal := _reveal_next_hidden_entry()
			revealed = did_reveal or revealed
			if did_reveal:
				processed_clue_locations[loc_id] = true
	if unlock_clues:
		if revealed:
			_update_active_clue_message("Found Clue")
			# Refresh UI to show the newly unlocked clue button.
			_populate_clue_lists()
		elif new_location_logged:
			_update_active_clue_message("All clues discovered")
	if new_location_logged:
		_queue_save_progress()

func _is_entry_solved(entry: Dictionary) -> bool:
	var cells_list: Array = entry.get("cells", []) as Array
	var answer: String = str(entry.get("answer", ""))
	if cells_list.is_empty():
		return false
	if answer.length() != cells_list.size():
		return false
	for i in range(cells_list.size()):
		var cell_pos := cells_list[i] as Vector2i
		if not _is_in_bounds(cell_pos):
			return false
		var cell := cells[cell_pos.x][cell_pos.y] as CrosswordCell
		if cell == null:
			return false
		var letter := cell.get_letter()
		var normalized := letter.strip_edges().to_upper()
		# Keep the saved grid synchronized with what the player actually sees.
		if not player_grid.is_empty():
			var current_saved := player_grid[cell_pos.x][cell_pos.y] as String
			if current_saved.strip_edges().to_upper() != normalized:
				player_grid[cell_pos.x][cell_pos.y] = normalized if normalized != "" else ""
				_queue_save_progress()
		if normalized.is_empty():
			return false
		var expected := answer.substr(i, 1).to_upper()
		if normalized != expected:
			return false
	return true

func _on_cell_navigation_requested(row: int, col: int, offset: Vector2i, reason: String) -> void:
	_release_clue_focus()
	_nav_log("nav_request from=%s reason=%s offset=%s" % [str(Vector2i(row, col)), reason, str(offset)])
	var origin := Vector2i(row, col)
	match reason:
		"backspace":
			# Clear overlay on the origin cell if it is already blank
			var origin_cell := cells[origin.x][origin.y] as CrosswordCell
			if origin_cell != null and origin_cell.get_letter().is_empty():
				origin_cell.set_state(CrosswordCell.CellState.NONE)
				_check_entries_for_cell(origin)
			if _advance(-1):
				var prev := current_cell
				if _is_in_bounds(prev):
					var prev_cell := cells[prev.x][prev.y] as CrosswordCell
					if prev_cell != null:
						prev_cell.set_letter("", true)
						player_grid[prev.x][prev.y] = ""
						prev_cell.set_state(CrosswordCell.CellState.NONE)
						# Re-evaluate any entries touching this cell so overlays clear when a word becomes unsolved
						_check_entries_for_cell(prev)
						return
		"tab":
			if offset.y < 0:
				_select_previous_entry()
			else:
				_select_next_entry()
			return
		"enter":
			_toggle_direction(origin)
			return
		"arrow":
			_move_by_offset(origin, offset, true)
			return
		_:
			_move_by_offset(origin, offset, true)

func _move_by_offset(origin: Vector2i, offset: Vector2i, update_direction: bool) -> void:
	if offset == Vector2i.ZERO:
		return

	var pos := origin + offset
	while _is_in_bounds(pos) and cells[pos.x][pos.y] == null:
		pos += offset

	if not _is_in_bounds(pos):
		return
	if cells[pos.x][pos.y] == null:
		return

	_last_clicked_cell = pos
	
	if DEBUG_CLICK_TRACKING:
		print_debug("[Navigation] arrow_key from=%s to=%s offset=%s _last_clicked_cell=%s" % [str(origin), str(pos), str(offset), str(_last_clicked_cell)])
	
	if update_direction:
		var preferred := _direction_from_offset(offset)
		_select_entry_for_cell(pos, preferred)
	else:
		_focus_cell(pos)

func _advance(step: int, grab_focus: bool = true) -> bool:
	if current_entry.is_empty():
		return false

	var entry_cells: Array = current_entry["cells"]
	if entry_cells.is_empty():
		return false

	var index := _find_position_index(entry_cells, current_cell)
	if index == -1:
		index = 0 if step > 0 else entry_cells.size() - 1
	index += step

	while index >= 0 and index < entry_cells.size():
		var next_pos: Vector2i = entry_cells[index]
		var next_cell := cells[next_pos.x][next_pos.y] as CrosswordCell
		if next_cell != null:
			_focus_cell(next_pos, grab_focus)
			return true
		index += step

	return false

func _direction_from_offset(offset: Vector2i) -> String:
	if abs(offset.x) > abs(offset.y):
		return "down"
	return "across"

func _toggle_direction(pos: Vector2i) -> void:
	var target_direction := "down" if current_direction == "across" else "across"
	var options: Dictionary = cell_slot_lookup.get(pos, {})
	if options.has(target_direction):
		_set_active_entry(options[target_direction], pos)
		return

	var alternate_dir := ""
	for key in options.keys():
		var dir := key as String
		if dir != current_direction and options.has(dir):
			alternate_dir = dir
			break
	if not alternate_dir.is_empty():
		_set_active_entry(options[alternate_dir], pos)
		return

	_try_toggle_from_entry_cells(target_direction, pos)

func _try_toggle_from_entry_cells(target_direction: String, origin: Vector2i) -> void:
	if current_entry.is_empty():
		return
	var entry_cells: Array = current_entry.get("cells", [])
	for cell_pos_variant in entry_cells:
		var cell_pos := cell_pos_variant as Vector2i
		if cell_pos == origin:
			continue
		var alt_options: Dictionary = cell_slot_lookup.get(cell_pos, {})
		if alt_options.has(target_direction):
			_set_active_entry(alt_options[target_direction], cell_pos)
			return
		for key in alt_options.keys():
			var dir := key as String
			if dir != current_direction and alt_options.has(dir):
				_set_active_entry(alt_options[dir], cell_pos)
				return

func _select_next_entry() -> void:
	_select_entry_in_direction(true)

func _select_previous_entry() -> void:
	_select_entry_in_direction(false)

func _select_entry_in_direction(forward: bool) -> void:
	var list: Array = across_entries if current_direction == "across" else down_entries
	if list.is_empty():
		return

	var idx := _find_entry_index(list, current_entry_id)
	if idx == -1:
		idx = 0 if forward else list.size() - 1
	else:
		idx = _wrap_index(idx + (1 if forward else -1), list.size())

	_set_active_entry(list[idx])

func _find_entry_index(list: Array, entry_id: int) -> int:
	for i in range(list.size()):
		if list[i].get("id", -1) == entry_id:
			return i
	return -1

func _wrap_index(value: int, size: int) -> int:
	if size <= 0:
		return 0
	var result := value % size
	if result < 0:
		result += size
	return result

func _find_position_index(list: Array, pos: Vector2i) -> int:
	for i in range(list.size()):
		if list[i] == pos:
			return i
	return -1

func _is_in_bounds(pos: Vector2i) -> bool:
	return pos.x >= 0 and pos.x < rows and pos.y >= 0 and pos.y < cols

func _on_regenerate_pressed() -> void:
	print_debug("[Generate] Button pressed!")
	_status_locked = false
	_generate_puzzle()

func _on_easy_words_toggled(pressed: bool) -> void:
	easy_words_enabled = pressed

func _on_hard_words_toggled(pressed: bool) -> void:
	hard_words_enabled = pressed

func _build_category_weights() -> Dictionary:
	# Start from configured weights
	var easy_weight: float = easy_word_weight
	var medium_weight: float = medium_word_weight
	var hard_weight: float = hard_word_weight
	var default_weight: float = fallback_word_weight
	
	# Apply toggles
	if not easy_words_enabled:
		easy_weight = 0.0
	if not hard_words_enabled:
		hard_weight = 0.0
	
	# Blend toward 1.0 (uniform) to reduce favoritism
	var s: float = clamp(weighting_strength, 0.0, 1.0)
	var easy_eff: float = lerp(1.0, easy_weight, s)
	var med_eff: float = lerp(1.0, medium_weight, s)
	var hard_eff: float = lerp(1.0, hard_weight, s)
	var def_eff: float = lerp(1.0, default_weight, s)
	
	return {
		"EASY WORDS": easy_eff,
		"MEDIUM WORDS": med_eff,
		"HARD WORDS": hard_eff,
		"_default": def_eff,
	}

func _ensure_word_list() -> bool:
	if word_list != null:
		return true
	
	# Try the configured path first
	word_list = WORD_LIST.from_file(word_list_path)
	if word_list != null:
		_using_minimal_word_list = false
		print("[DEBUG] Loaded word list from configured path: %s" % word_list_path)
		var wl_count := 0
		var wl_all: Array = word_list.get_all_entries()
		if typeof(wl_all) == TYPE_ARRAY:
			wl_count = wl_all.size()
		_update_active_clue_message("Loaded word list (%d entries)" % wl_count)
		return true
	
	# Fallback to default path if the configured path fails
	if word_list_path != DEFAULT_WORD_LIST_PATH:
		print("Failed to load word list from '%s', trying default path '%s'" % [word_list_path, DEFAULT_WORD_LIST_PATH])
		word_list = WORD_LIST.from_file(DEFAULT_WORD_LIST_PATH)
		if word_list != null:
			_using_minimal_word_list = false
			print("[DEBUG] Loaded word list from default path: %s" % DEFAULT_WORD_LIST_PATH)
			var wl_count := 0
			var wl_all: Array = word_list.get_all_entries()
			if typeof(wl_all) == TYPE_ARRAY:
				wl_count = wl_all.size()
			_update_active_clue_message("Loaded word list (%d entries)" % wl_count)
			return true
	
	# Final fallback: try loading from user:// directory (in case file was copied there)
	var user_path := "user://crossword_wordlist.txt"
	print("Failed to load word list from res://, trying user path '%s'" % user_path)
	word_list = WORD_LIST.from_file(user_path)
	if word_list != null:
		_using_minimal_word_list = false
		print("Successfully loaded word list from user directory")
		var wl_count := 0
		var wl_all: Array = word_list.get_all_entries()
		if typeof(wl_all) == TYPE_ARRAY:
			wl_count = wl_all.size()
		_update_active_clue_message("Loaded word list (%d entries)" % wl_count)
		return true
	
	# Ultimate fallback: create a minimal in-memory word list (optional)
	if not allow_fallback_word_list:
		push_error("Word list not found. Falling back to a tiny built-in list. To avoid this, include assets/crossword_wordlist.txt in export.")
		# Continue anyway to keep parity (both debug and export will at least generate something)
	print("Creating minimal fallback word list")
	word_list = _create_minimal_word_list()
	_using_minimal_word_list = word_list != null
	if _using_minimal_word_list:
		var wl_all: Array = word_list.get_all_entries()
		var wl_count := 0
		if typeof(wl_all) == TYPE_ARRAY:
			wl_count = wl_all.size()
		_update_active_clue_message("Using fallback word list (%d entries)" % wl_count)
	return word_list != null

func _create_minimal_word_list() -> CrosswordWordList:
	# Create a minimal word list in memory as final fallback
	var minimal_list := CrosswordWordList.new()
	# Add some basic words manually to ensure the game can still work
	var basic_words: Dictionary[String, String] = {
		"CAT": "Feline pet",
		"DOG": "Canine pet", 
		"BOOK": "Something you read",
		"TREE": "Tall plant with trunk",
		"WATER": "Clear liquid you drink",
		"HOUSE": "Building where people live",
		"APPLE": "Red or green fruit",
		"CHAIR": "Furniture you sit on",
		"TABLE": "Furniture for eating",
		"LIGHT": "Opposite of darkness",
		"PHONE": "Device for calling",
		"BREAD": "Baked food staple",
		"SMILE": "Happy facial expression",
		"MUSIC": "Art made of sound",
		"HEART": "Organ that pumps blood",
		"PAPER": "You write on this",
		"FLOWER": "Colorful plant part",
		"WINDOW": "Glass opening in wall",
		"BRIDGE": "Structure over water",
		"SUMMER": "Hot season of year"
	}
	
	for word_key in basic_words.keys():
		var word_str: String = String(word_key)
		var clue: String = String(basic_words[word_key])
		var entry := {
			"word": word_str,
			"clue": clue,
			"category": "EASY WORDS"
		}
		minimal_list.all_entries.append(entry)
		
		var length: int = word_str.length()
		if not minimal_list.entries_by_length.has(length):
			minimal_list.entries_by_length[length] = []
		minimal_list.entries_by_length[length].append(entry)
	
	return minimal_list

func _find_button_by_text(text: String) -> Button:
	# Recursively search for a button with specific text
	return _search_node_for_button(self, text)

func _search_node_for_button(node: Node, text: String) -> Button:
	if node is Button:
		var button := node as Button
		if button.text == text:
			return button
	
	for child in node.get_children():
		var result := _search_node_for_button(child, text)
		if result != null:
			return result
	
	return null

func _print_debug_clues() -> void:
	if across_entries.is_empty() and down_entries.is_empty():
		return

	print("--- Across ---")
	for entry in across_entries:
		print("%d. %s (%s)" % [entry["number"], entry["clue"], entry["answer"]])

	print("--- Down ---")
	for entry in down_entries:
		print("%d. %s (%s)" % [entry["number"], entry["clue"], entry["answer"]])

func _entry_number_less(a: Dictionary, b: Dictionary) -> bool:
	var a_number: int = a.get("number", 0)
	var b_number: int = b.get("number", 0)
	if a_number == b_number:
		var a_start: Vector2i = a.get("start", Vector2i.ZERO)
		var b_start: Vector2i = b.get("start", Vector2i.ZERO)
		if a_start.x == b_start.x:
			return a_start.y < b_start.y
		return a_start.x < b_start.x
	return a_number < b_number

func _sort_entry_lists() -> void:
	across_entries.sort_custom(Callable(self, "_entry_number_less"))
	down_entries.sort_custom(Callable(self, "_entry_number_less"))

func _format_clue_display(number: int, clue: String) -> String:
	var words: PackedStringArray = clue.strip_edges().split(" ", false)
	if words.is_empty():
		return "%d. %s" % [number, ""]

	var max_chars := 22
	var first_words: Array[String] = []
	var second_words: Array[String] = []

	for i in range(words.size()):
		var word := words[i]
		if first_words.is_empty():
			first_words.append(word)
			continue

		var candidate := "%s %s" % [" ".join(first_words), word]
		if candidate.length() <= max_chars:
			first_words.append(word)
		else:
			var slice := words.slice(i, words.size())
			second_words.clear()
			for part in slice:
				second_words.append(part)
			break

	if second_words.is_empty() and words.size() > first_words.size():
		var slice_remaining := words.slice(first_words.size(), words.size())
		second_words.clear()
		for part in slice_remaining:
			second_words.append(part)

	var first_line: String = " ".join(first_words).strip_edges()
	var second_line: String = " ".join(second_words).strip_edges()

	if second_line.is_empty():
		return "%d. %s" % [number, first_line]

	return "%d. %s" % [number, "%s\n%s" % [first_line, second_line]]


func _on_ap_connect_pressed() -> void:
	if ap_client != null and ap_client.get_state() != ArchipelagoClient.ConnectionState.DISCONNECTED:
		_enter_offline_mode(false)
		return

	var name_text := ""
	if ap_name_input != null:
		name_text = ap_name_input.text.strip_edges()
	if name_text.is_empty():
		push_warning("Player name required for Archipelago connection; keeping offline mode.")
		_update_ap_button_text()
		return

	var host_text := ""
	if ap_host_input != null:
		host_text = ap_host_input.text.strip_edges()
	if host_text.is_empty():
		host_text = "archipelago.gg"

	var port_text := ""
	if ap_port_input != null:
		port_text = ap_port_input.text.strip_edges()
	var password := ""
	if ap_password_input != null:
		password = ap_password_input.text.strip_edges()

	if port_text.is_empty():
		push_warning("Port required for Archipelago connection; keeping offline mode.")
		_update_ap_button_text()
		return

	var port := port_text.to_int()
	if port <= 0:
		push_warning("Invalid Archipelago port '%s'; keeping offline mode." % port_text)
		_update_ap_button_text()
		return

	if _attempt_archipelago_connect(host_text, name_text, port, password):
		_enter_archipelago_mode()
		current_player_name = name_text
		current_host = host_text
		_update_active_clue_message("Connected as %s" % current_player_name)
	else:
		push_warning("Failed to connect to Archipelago; keeping offline mode.")
		_update_ap_button_text()

func _attempt_archipelago_connect(host: String, name: String, port: int, password: String) -> bool:
	_nav_log("attempt_archipelago_connect host=%s name=%s port=%d password_len=%d" % [host, name, port, password.length()])
	if ap_client == null:
		push_warning("Archipelago client not available; cannot connect.")
		return false
	return ap_client.connect_to_server(host, port, password, name)

func _enter_offline_mode(generate_puzzle: bool = true) -> void:
	if ap_client != null and ap_client.is_ap_connected():
		ap_client.disconnect_from_server()
	if current_mode == PlayMode.ARCHIPELAGO:
		_save_progress_now()
	_pending_clue_locations.clear()
	_pending_direct_clue_total = -1
	_pending_direct_clue_new = 0
	_pending_color_indicator = false
	_puzzle_ready = false
	current_mode = PlayMode.OFFLINE
	if free_letter_counter != null:
		free_letter_counter.visible = false
	_nav_log("entered offline mode generate=%s" % [str(generate_puzzle)])
	_set_generate_enabled(true)
	_clear_board()
	ap_slot_data.clear()
	initial_reveal_override = INITIAL_REVEALED_CLUES
	_save_pending = false
	_status_locked = false
	if generate_puzzle:
		_generate_puzzle()
	_update_ap_button_text()
	if ap_name_input != null and current_player_name != "":
		ap_name_input.text = current_player_name
	if ap_host_input != null and current_host != "":
		ap_host_input.text = current_host
	if letter_hint_count != null:
		letter_hint_count.visible = false

func _enter_archipelago_mode() -> void:
	if current_mode == PlayMode.ARCHIPELAGO:
		return
	current_mode = PlayMode.ARCHIPELAGO
	_pending_clue_locations.clear()
	_pending_direct_clue_total = -1
	_pending_direct_clue_new = 0
	_pending_color_indicator = false
	_puzzle_ready = false
	if free_letter_counter != null:
		free_letter_counter.visible = true
	_nav_log("entered archipelago mode (stub)")
	_set_generate_enabled(false)
	_clear_board()
	initial_reveal_override = INITIAL_REVEALED_CLUES
	_apply_archipelago_slot_data()
	_update_ap_button_text()
