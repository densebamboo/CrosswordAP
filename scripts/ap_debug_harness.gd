extends Node
class_name APDebugHarness

const AP_DEBUG_LOG := preload("res://scripts/ap_debug_log.gd")

static func prepare_client_for_packet_tests(ap_client: ArchipelagoClient) -> void:
	if ap_client == null:
		AP_DEBUG_LOG.event("APHarness", "prepare_failed", {"reason": "missing_client"})
		return
	AP_DEBUG_LOG.start_session("ap_debug_harness")
	ap_client.connect_sent = true
	ap_client._process_packet({
		"cmd": "DataPackage",
		"data": {
			"games": {
				"CrosswordAP": {
					"item_name_to_id": {
						"Clue": 1001,
						"Nothing": 1002,
						"Crossword Completed": 1003,
						"Color Indicator": 1004,
						"Letter Hint": 1005,
					},
					"location_name_to_id": _build_location_name_to_id(),
				},
			},
		},
	})
	ap_client.state = ArchipelagoClient.ConnectionState.CONNECTED
	ap_client.connected = true
	ap_client.my_slot = 1
	AP_DEBUG_LOG.event("APHarness", "client_prepared", {
		"state": ap_client.get_state(),
		"last_processed_item_index": ap_client.get_last_processed_item_index(),
	})

static func run_received_items_sequence(grid_manager) -> void:
	if grid_manager == null:
		AP_DEBUG_LOG.event("APHarness", "received_items_sequence_failed", {"reason": "missing_grid_manager"})
		return
	if not _grid_ready_for_item_tests(grid_manager):
		AP_DEBUG_LOG.event("APHarness", "received_items_sequence_skipped", {
			"reason": "grid_not_ap_ready",
			"snapshot": _grid_snapshot(grid_manager),
		})
		return
	var ap_client: ArchipelagoClient = grid_manager.ap_client
	if ap_client == null:
		AP_DEBUG_LOG.event("APHarness", "received_items_sequence_failed", {"reason": "missing_ap_client"})
		return
	prepare_client_for_packet_tests(ap_client)
	AP_DEBUG_LOG.event("APHarness", "received_items_sequence_start", _grid_snapshot(grid_manager))
	ap_client._process_packet({
		"cmd": "ReceivedItems",
		"index": 0,
		"items": [
			{"item": 1001, "location": 0, "player": 1},
		],
	})
	ap_client._process_packet({
		"cmd": "ReceivedItems",
		"index": 1,
		"items": [
			{"item": 1001, "location": 2001, "player": 1},
		],
	})
	ap_client._process_packet({
		"cmd": "ReceivedItems",
		"index": 1,
		"items": [
			{"item": 1001, "location": 2001, "player": 1},
		],
	})
	ap_client._process_packet({
		"cmd": "ReceivedItems",
		"index": 3,
		"items": [
			{"item": 1002, "location": 2002, "player": 1},
			{"item": 1005, "location": 2003, "player": 1},
		],
	})
	AP_DEBUG_LOG.event("APHarness", "received_items_sequence_done", _grid_snapshot(grid_manager))

static func run_retroactive_items_sequence(grid_manager) -> void:
	if grid_manager == null:
		AP_DEBUG_LOG.event("APHarness", "retroactive_sequence_failed", {"reason": "missing_grid_manager"})
		return
	if not _grid_ready_for_item_tests(grid_manager):
		AP_DEBUG_LOG.event("APHarness", "retroactive_sequence_skipped", {
			"reason": "grid_not_ap_ready",
			"snapshot": _grid_snapshot(grid_manager),
		})
		return
	var ap_client: ArchipelagoClient = grid_manager.ap_client
	if ap_client == null:
		AP_DEBUG_LOG.event("APHarness", "retroactive_sequence_failed", {"reason": "missing_ap_client"})
		return
	prepare_client_for_packet_tests(ap_client)
	AP_DEBUG_LOG.event("APHarness", "retroactive_sequence_start", _grid_snapshot(grid_manager))
	ap_client._process_packet({
		"cmd": "ReceivedItems",
		"index": -1,
		"items": [
			{"item": 1001, "location": 0, "player": 1},
			{"item": 1001, "location": 0, "player": 1},
			{"item": 1005, "location": 0, "player": 1},
		],
	})
	AP_DEBUG_LOG.event("APHarness", "retroactive_sequence_done", _grid_snapshot(grid_manager))

static func audit_unsent_solved_entries(grid_manager) -> void:
	if grid_manager == null:
		AP_DEBUG_LOG.event("APHarness", "unsent_audit_failed", {"reason": "missing_grid_manager"})
		return
	var unsent: Array = []
	var combined: Array = []
	combined.append_array(grid_manager.across_entries)
	combined.append_array(grid_manager.down_entries)
	for entry_variant in combined:
		var entry: Dictionary = entry_variant
		var entry_id := int(entry.get("id", -1))
		if entry_id <= 0:
			continue
		if entry.get("solved", false) and not grid_manager.sent_checks_for_entries.has(entry_id):
			unsent.append({
				"entry_id": entry_id,
				"number": entry.get("number", 0),
				"direction": entry.get("direction", ""),
			})
	AP_DEBUG_LOG.event("APHarness", "unsent_solved_entries_audit", {
		"unsent": unsent,
		"unsent_count": unsent.size(),
		"connected": grid_manager.ap_client.is_ap_connected() if grid_manager.ap_client else false,
		"sent_check_entries": grid_manager.sent_checks_for_entries.keys(),
	})

static func _build_location_name_to_id() -> Dictionary:
	var locations := {}
	for i in range(1, 41):
		locations["Solved %d Words" % i] = 2000 + i
	locations["Crossword Completed"] = 3000
	return locations

static func _grid_ready_for_item_tests(grid_manager) -> bool:
	if grid_manager == null:
		return false
	return grid_manager.current_mode == grid_manager.PlayMode.ARCHIPELAGO and grid_manager._puzzle_ready

static func _grid_snapshot(grid_manager) -> Dictionary:
	return {
		"mode": grid_manager.current_mode,
		"puzzle_ready": grid_manager._puzzle_ready,
		"hidden_queue_count": grid_manager.hidden_entry_queue.size(),
		"revealed_entry_count": grid_manager.revealed_entry_count,
		"unlocked_entry_count": grid_manager.unlocked_entry_count,
		"solved_entry_count": grid_manager.solved_entry_count,
		"claimed_locations": grid_manager.claimed_location_ids.keys(),
		"processed_clue_locations": grid_manager.processed_clue_locations.keys(),
		"sent_check_entries": grid_manager.sent_checks_for_entries.keys(),
		"total_direct_clues_received": grid_manager.total_direct_clues_received,
		"letter_hints_available": grid_manager.letter_hints_available,
	}
