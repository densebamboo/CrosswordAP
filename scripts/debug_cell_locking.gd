extends Node

# Debug script for cell locking behavior
# Attach this to the scene or call from grid_manager

const ENABLED := false

static func log_cell_state(cell: CrosswordCell, context: String = "") -> void:
	if not ENABLED:
		return
	if cell == null:
		print_debug("[CellLock] %s: cell is null" % context)
		return
	
	var locked := cell.is_locked()
	var editable := cell._text.editable if cell._text else false
	var current_state := cell._current_state
	var state_name := "UNKNOWN"
	match current_state:
		0: state_name = "NONE"
		1: state_name = "CORRECT"
		2: state_name = "INCORRECT"
	
	var overlay_visible := cell._state_overlay.visible if cell._state_overlay else false
	var overlay_enabled := cell._state_overlay_enabled
	var letter := cell.get_letter()
	var solution := cell.solution_letter
	
	print_debug("[CellLock] %s: pos=(%d,%d) letter='%s' solution='%s' state=%s locked=%s editable=%s overlay_visible=%s overlay_enabled=%s" % [
		context,
		cell.row,
		cell.col,
		letter,
		solution,
		state_name,
		str(locked),
		str(editable),
		str(overlay_visible),
		str(overlay_enabled)
	])

static func log_word_completion(entry: Dictionary, grid_manager) -> void:
	if not ENABLED:
		return
	
	var entry_id: int = entry.get("id", -1)
	var number: int = entry.get("number", -1)
	var answer: String = entry.get("answer", "")
	var solved: bool = entry.get("solved", false)
	var mode := "OFFLINE" if grid_manager.current_mode == 0 else "ARCHIPELAGO"
	var has_indicator: bool = grid_manager.has_color_indicator
	
	print_debug("[CellLock] ========== WORD COMPLETION ==========")
	print_debug("[CellLock] Entry: id=%d number=%d answer='%s' solved=%s" % [entry_id, number, answer, str(solved)])
	print_debug("[CellLock] Mode: %s has_color_indicator=%s" % [mode, str(has_indicator)])
	
	var cells_list: Array = entry.get("cells", [])
	print_debug("[CellLock] Cells in word: %d" % cells_list.size())
	for i in range(cells_list.size()):
		var cell_pos := cells_list[i] as Vector2i
		if grid_manager._is_in_bounds(cell_pos):
			var cell := grid_manager.cells[cell_pos.x][cell_pos.y] as CrosswordCell
			log_cell_state(cell, "  Cell[%d]" % i)
	print_debug("[CellLock] ==========================================")
