extends Node
class_name ArchipelagoClient

signal connection_state_changed(state: int)
signal connection_failed(reason: String)
signal location_checked(location_ids: Array)
signal items_received(location_ids: Array)
signal direct_clues_received(total_count: int, new_count: int)
signal print_json(message: String)
signal slot_data_received(data: Dictionary)
signal color_indicator_received()
signal letter_hint_received(new_hints_count: int)

enum ConnectionState {
	DISCONNECTED,
	CONNECTING,
	SOCKET_CONNECTED,
	AUTHENTICATING,
	CONNECTED,
}

const GAME_NAME := "CrosswordAP"
const AP_DEBUG_LOG := preload("res://scripts/ap_debug_log.gd")
const GAME_VERSION := {
	"major": 0,
	"minor": 6,
	"build": 3,
	"revision": 0,
	"class": "Version",
}
const ITEMS_HANDLING := 0b111
const TAGS := []
const AP_SUBPROTOCOL := "archipelago"
const AP_COMPRESSION_EXTENSIONS := [
	"permessage-deflate",
	"permessage-deflate; client_no_context_takeover",
	"permessage-deflate; server_no_context_takeover",
	"permessage-deflate; client_no_context_takeover; server_no_context_takeover",
]

const DEBUG_GENERAL := false
const DEBUG_ITEM_SYNC := false
const DEBUG_PACKET_RECEIPTS := false
const SYNC_DEDUP_WINDOW_MSEC := 250

const WS_STATE_CONNECTING := 0
const WS_STATE_OPEN := 1
const WS_STATE_CLOSING := 2
const WS_STATE_CLOSED := 3
const WS_CLOSE_PROTOCOL_ERROR := 1002

var websocket := WebSocketPeer.new()
var state: int = ConnectionState.DISCONNECTED
var connected: bool = false
var host: String = ""
var port: int = 0
var password: String = ""
var player_name: String = ""
var room_info: Dictionary = {}
var data_package: Dictionary = {}
var slot_data: Dictionary = {}
var last_error: String = ""
var uuid: String = ""
var manual_disconnect: bool = false
var data_package_requested: bool = false
var connect_sent: bool = false
var last_processed_item_index: int = -1  # Track which items we've already processed
var use_tls_connection: bool = false
var requesting_subprotocol: bool = true
var subprotocol_retry_attempted: bool = false
var my_slot: int = -1
var clue_item_id: int = 0
var color_indicator_item_id: int = 0
var letter_hint_item_id: int = 0
var total_direct_clues_seen: int = 0  # Track cumulative direct clues across all packets
var total_letter_hint_items_seen: int = 0
var clue_items_resolved: bool = false  # Track if we've resolved item IDs
var ignored_received_items_packets: int = 0
var ignored_received_items_total: int = 0
var last_sync_msec: int = -1000000

func _ready() -> void:
	AP_DEBUG_LOG.start_session("archipelago_client_ready")
	uuid = OS.get_unique_id()
	set_process(false)
	if websocket == null:
		push_error("WebSocketPeer not available. Networking disabled.")
		AP_DEBUG_LOG.event("APClient", "websocket_peer_missing")

func connect_to_server(host_address: String, host_port: int, host_password: String = "", name: String = "") -> bool:
	AP_DEBUG_LOG.start_session("connect_to_server")
	AP_DEBUG_LOG.event("APClient", "connect_requested", {
		"host": host_address,
		"port": host_port,
		"player": name,
		"password_len": host_password.length(),
		"state": state,
	})
	if name.strip_edges().is_empty():
		last_error = "Player name required"
		emit_signal("connection_failed", last_error)
		AP_DEBUG_LOG.event("APClient", "connect_rejected_local", {"reason": last_error})
		return false
	if state != ConnectionState.DISCONNECTED:
		disconnect_from_server()
	manual_disconnect = false
	subprotocol_retry_attempted = false
	var host_part := host_address.strip_edges()
	var use_tls := false
	if host_part.begins_with("ws://"):
		host_part = host_part.substr(5)
	elif host_part.begins_with("wss://"):
		host_part = host_part.substr(6)
		use_tls = true
	if host_part.is_empty():
		host_part = "127.0.0.1"
	if not host_address.begins_with("ws://") and not host_address.begins_with("wss://"):
		var lower_host := host_part.to_lower()
		var is_local := lower_host.begins_with("127.") or lower_host.begins_with("localhost") or lower_host.begins_with("192.168.") or lower_host.begins_with("10.") or lower_host.begins_with("0.")
		use_tls = not is_local
	host = host_part
	port = host_port
	use_tls_connection = use_tls
	password = host_password
	player_name = name
	AP_DEBUG_LOG.event("APClient", "connect_normalized", {
		"host": host,
		"port": port,
		"use_tls": use_tls_connection,
	})
	return _open_websocket(false)

func disconnect_from_server() -> void:
	if state == ConnectionState.DISCONNECTED:
		return
	AP_DEBUG_LOG.event("APClient", "disconnect_requested", {"state": state, "connected": connected})
	manual_disconnect = true
	if websocket != null and websocket.get_ready_state() in [WS_STATE_CONNECTING, WS_STATE_OPEN]:
		websocket.close(1000, "Client disconnect")
	_reset_state()

func debug_simulate_connection_drop() -> void:
	if state == ConnectionState.DISCONNECTED:
		AP_DEBUG_LOG.event("APClient", "debug_connection_drop_skipped", {"reason": "already_disconnected"})
		return
	AP_DEBUG_LOG.event("APClient", "debug_connection_drop", {
		"previous_state": state,
		"connected": connected,
		"last_processed_item_index": last_processed_item_index,
	})
	if websocket != null and websocket.get_ready_state() in [WS_STATE_CONNECTING, WS_STATE_OPEN]:
		websocket.close(1000, "Debug simulated connection drop")
	websocket = null
	state = ConnectionState.DISCONNECTED
	connected = false
	manual_disconnect = false
	data_package_requested = false
	connect_sent = false
	set_process(false)
	emit_signal("connection_state_changed", state)

func _reset_state() -> void:
	AP_DEBUG_LOG.event("APClient", "reset_state", {
		"previous_state": state,
		"connected": connected,
		"last_processed_item_index": last_processed_item_index,
		"direct_clues_seen": total_direct_clues_seen,
		"letter_hints_seen": total_letter_hint_items_seen,
	})
	state = ConnectionState.DISCONNECTED
	connected = false
	host = ""
	port = 0
	password = ""
	player_name = ""
	room_info.clear()
	data_package.clear()
	slot_data.clear()
	last_error = ""
	manual_disconnect = false
	data_package_requested = false
	connect_sent = false
	clue_items_resolved = false
	use_tls_connection = false
	requesting_subprotocol = true
	subprotocol_retry_attempted = false
	last_processed_item_index = -1
	total_direct_clues_seen = 0
	total_letter_hint_items_seen = 0
	ignored_received_items_packets = 0
	ignored_received_items_total = 0
	last_sync_msec = -1000000
	websocket = null
	set_process(false)
	emit_signal("connection_state_changed", state)

func _process(_delta: float) -> void:
	if state == ConnectionState.DISCONNECTED or websocket == null:
		return
	websocket.poll()
	var ready := websocket.get_ready_state()
	if ready == WS_STATE_OPEN:
		if state == ConnectionState.CONNECTING:
			_on_ws_connected()
		_process_packets()
	elif ready == WS_STATE_CLOSING:
		if manual_disconnect:
			_reset_state()
		else:
			_handle_error("Connection closing")
	elif ready == WS_STATE_CLOSED:
		if manual_disconnect:
			_reset_state()
		else:
			var close_code := websocket.get_close_code()
			var close_reason := websocket.get_close_reason()
			AP_DEBUG_LOG.event("APClient", "websocket_closed", {
				"close_code": close_code,
				"close_reason": close_reason,
				"state": state,
				"requesting_subprotocol": requesting_subprotocol,
			})
			if DEBUG_GENERAL: print_debug("[APClient] WebSocket closed code=%d reason=%s" % [close_code, close_reason])
			if _try_fallback_without_subprotocol(close_reason, close_code):
				return
			var message := "Connection closed"
			if not close_reason.is_empty():
				message = "%s: %s" % [message, close_reason]
			_handle_error(message)

func _on_ws_connected() -> void:
	state = ConnectionState.SOCKET_CONNECTED
	AP_DEBUG_LOG.event("APClient", "websocket_open", {
		"host": host,
		"port": port,
		"use_tls": use_tls_connection,
		"requesting_subprotocol": requesting_subprotocol,
	})
	emit_signal("connection_state_changed", state)
	_request_data_package()

func _process_packets() -> void:
	if websocket == null:
		return
	while websocket.get_available_packet_count() > 0:
		var packet: PackedByteArray = websocket.get_packet()
		var text := packet.get_string_from_utf8()
		if text.is_empty():
			continue
		var message = JSON.parse_string(text)
		if message == null:
			AP_DEBUG_LOG.event("APClient", "json_parse_failed", {
				"bytes": packet.size(),
				"preview": text.substr(0, 240),
			})
			continue
		match typeof(message):
			TYPE_ARRAY:
				for entry_variant in message:
					if typeof(entry_variant) == TYPE_DICTIONARY:
						_process_packet(entry_variant)
			TYPE_DICTIONARY:
				_process_packet(message)
			_:
				pass

func _process_packet(packet: Dictionary) -> void:
	var cmd: String = packet.get("cmd", "")
	if DEBUG_PACKET_RECEIPTS or cmd in ["RoomInfo", "DataPackage", "ConnectionRefused", "Connected"]:
		AP_DEBUG_LOG.event("APClient", "packet_received", {
			"cmd": cmd,
			"keys": packet.keys(),
		})
	if DEBUG_GENERAL: print_debug("[APClient] Received packet: cmd=%s" % cmd)
	match cmd:
		"RoomInfo":
			room_info = packet
			var checksum_keys: Array = []
			var checksums_variant: Variant = packet.get("datapackage_checksums", {})
			if typeof(checksums_variant) == TYPE_DICTIONARY:
				checksum_keys = (checksums_variant as Dictionary).keys()
			AP_DEBUG_LOG.event("APClient", "room_info", {
				"players": (packet.get("players", []) as Array).size() if typeof(packet.get("players", [])) == TYPE_ARRAY else -1,
				"datapackage_checksum_count": checksum_keys.size(),
				"datapackage_checksums": checksum_keys,
			})
			if not data_package_requested:
				_request_data_package()
		"DataPackage":
			data_package = packet.get("data", {})
			var game_keys: Array = []
			if typeof(data_package) == TYPE_DICTIONARY:
				var games_variant: Variant = data_package.get("games", {})
				if typeof(games_variant) == TYPE_DICTIONARY:
					game_keys = (games_variant as Dictionary).keys()
			AP_DEBUG_LOG.event("APClient", "data_package", {
				"top_keys": data_package.keys() if typeof(data_package) == TYPE_DICTIONARY else [],
				"game_count": game_keys.size(),
				"games": game_keys,
			})
			if not clue_items_resolved:
				_resolve_clue_item_id()
				clue_items_resolved = true
			if not connect_sent:
				_send_connect()
		"ConnectionRefused":
			var errors: Array = packet.get("errors", [])
			var reason := ", ".join(errors)
			AP_DEBUG_LOG.event("APClient", "connection_refused", {"errors": errors})
			_handle_error("Connection refused: %s" % reason)
		"Connected":
			state = ConnectionState.CONNECTED
			connected = true
			slot_data = packet.get("slot_data", {})
			if typeof(slot_data) != TYPE_DICTIONARY:
				slot_data = {}
			my_slot = int(packet.get("slot", -1))
			AP_DEBUG_LOG.event("APClient", "connected", {
				"slot": my_slot,
				"team": packet.get("team", -1),
				"slot_data_keys": slot_data.keys(),
				"checked_locations": (packet.get("checked_locations", []) as Array).size() if typeof(packet.get("checked_locations", [])) == TYPE_ARRAY else -1,
				"missing_locations": (packet.get("missing_locations", []) as Array).size() if typeof(packet.get("missing_locations", [])) == TYPE_ARRAY else -1,
				"last_processed_item_index": last_processed_item_index,
			})
			if DEBUG_ITEM_SYNC: print_debug("[APClient] Connected! slot=%d last_processed_item_index=%d" % [my_slot, last_processed_item_index])
			emit_signal("connection_state_changed", state)
			if not slot_data.is_empty():
				emit_signal("slot_data_received", slot_data)
			if DEBUG_ITEM_SYNC: print_debug("[APClient] About to send Sync after Connected")
			_send_sync()
		"ReceivedItems":
			var items: Array = packet.get("items", [])
			var index: int = packet.get("index", 0)  # Index is the position of the LAST item in this packet
			
			if items.is_empty():
				if DEBUG_ITEM_SYNC: print_debug("[APClient] ReceivedItems: empty packet")
				return
			
			# The 'index' parameter represents the index in the server's item list
			# Items don't have individual indices - we calculate based on packet position
			# If index=5 and we have 3 items, they are at indices 3, 4, 5 (server indices)
			var packet_end_index := index
			
			if DEBUG_ITEM_SYNC: print_debug("[APClient] ReceivedItems: %d items, packet_index=%d, last_processed=%d" % [items.size(), packet_end_index, last_processed_item_index])
			
			# Determine which items in the packet are actually new
			if DEBUG_ITEM_SYNC: print_debug("[APClient] Evaluating %d received items (current last=%d)" % [items.size(), last_processed_item_index])

			# Process new items
			var clue_source_locations: Array[int] = []
			var color_indicator_unlocked := false
			var new_letter_hints := 0
			var new_direct_clues := 0
			var previous_last_processed := last_processed_item_index
			
			var new_highest_index := last_processed_item_index
			var processed_count := 0
			
			# Calculate the starting server index for items in this packet
			# Packet index represents the LAST item, so first item is at (index - size + 1)
			var packet_start_index := packet_end_index - items.size() + 1
			
			# If packet_start_index is negative, it means this is a retroactive packet
			# We need to convert negative indices to absolute indices
			# The server sends negative indices when reconnecting - they mean "these are the last N items"
			# So if we have 12 items with indices -11 to 0, that means absolute indices 0 to 11
			var absolute_start_index := packet_start_index
			if packet_start_index < 0:
				# Negative start means we're looking at retroactive items
				# Convert to absolute: if we have items at -11..-0, those are absolute 0..11
				absolute_start_index = 0
			var item_log: Array = []
			
			for i in range(items.size()):
				var item_variant = items[i]
				var item_dict: Dictionary = item_variant if typeof(item_variant) == TYPE_DICTIONARY else {}
				var item_id: int = 0
				if item_dict.has("item"):
					var raw: Variant = item_dict.get("item", 0)
					if typeof(raw) == TYPE_INT:
						item_id = raw
					elif typeof(raw) == TYPE_FLOAT:
						item_id = int(raw)
				var loc_id: int = item_dict.get("location", 0)
				
				# Calculate the absolute server index for this item
				var item_server_index: int = absolute_start_index + i
				if i < 20:
					item_log.append({
						"i": i,
						"server_index": item_server_index,
						"item_id": item_id,
						"location": loc_id,
						"will_process": item_server_index > last_processed_item_index,
					})
				
				if DEBUG_ITEM_SYNC and i < 3:  # Log first 3 items for debugging
					print_debug("[APClient]   Item[%d]: server_index=%d item_id=%d loc_id=%d" % [i, item_server_index, item_id, loc_id])
				
				# Only process items we haven't seen before
				var should_process := item_server_index > last_processed_item_index
				
				if should_process:
					new_highest_index = max(new_highest_index, item_server_index)
					processed_count += 1
					
					# Handle Clue items (unlock new clues)
					if clue_item_id != 0 and item_id == clue_item_id:
						new_direct_clues += 1
						if loc_id > 0:
							clue_source_locations.append(int(loc_id))
					if color_indicator_item_id != 0 and item_id == color_indicator_item_id:
						color_indicator_unlocked = true
					if letter_hint_item_id != 0 and item_id == letter_hint_item_id:
						new_letter_hints += 1
				elif DEBUG_ITEM_SYNC and i < 3:
					print_debug("[APClient]   Skipping already processed (server_index=%d <= last=%d)" % [item_server_index, last_processed_item_index])
			
			# Update our tracking
			if new_highest_index > last_processed_item_index:
				last_processed_item_index = new_highest_index
			total_direct_clues_seen += new_direct_clues
			total_letter_hint_items_seen += new_letter_hints
			if processed_count > 0 or DEBUG_ITEM_SYNC:
				ignored_received_items_packets = 0
				ignored_received_items_total = 0
				AP_DEBUG_LOG.event("APClient", "received_items_processed", {
					"item_count": items.size(),
					"packet_index": packet_end_index,
					"packet_start_index": packet_start_index,
					"absolute_start_index": absolute_start_index,
					"previous_last_processed": previous_last_processed,
					"new_last_processed": last_processed_item_index,
					"processed_count": processed_count,
					"new_letter_hints": new_letter_hints,
					"new_direct_clues": new_direct_clues,
					"clue_source_location_count": clue_source_locations.size(),
					"clue_source_locations": clue_source_locations,
					"color_indicator": color_indicator_unlocked,
					"sample_items": item_log,
				})
			else:
				ignored_received_items_packets += 1
				ignored_received_items_total += items.size()
				if ignored_received_items_packets == 1 or ignored_received_items_packets % 10 == 0:
					AP_DEBUG_LOG.event("APClient", "received_items_ignored_summary", {
						"ignored_packets": ignored_received_items_packets,
						"ignored_items": ignored_received_items_total,
						"last_packet_item_count": items.size(),
						"packet_index": packet_end_index,
						"last_processed_item_index": last_processed_item_index,
					})
			
			if DEBUG_ITEM_SYNC: print_debug("[APClient] Processed %d new items: hints=%d clues=%d source_locs=%s" % [processed_count, new_letter_hints, new_direct_clues, clue_source_locations])
			
			# Emit signals
			if color_indicator_unlocked:
				emit_signal("color_indicator_received")
			if new_letter_hints > 0:
				if DEBUG_ITEM_SYNC: print_debug("[APClient] Emitting letter_hint_received with count=%d" % new_letter_hints)
				emit_signal("letter_hint_received", new_letter_hints)
			if new_direct_clues > 0:
				if DEBUG_ITEM_SYNC: print_debug("[APClient] Emitting direct_clues_received with total=%d new=%d" % [total_direct_clues_seen, new_direct_clues])
				emit_signal("direct_clues_received", total_direct_clues_seen, new_direct_clues)
		"RoomUpdate":
			var checked: Array = packet.get("checked_locations", [])
			AP_DEBUG_LOG.event("APClient", "room_update", {
				"checked_count": checked.size(),
				"checked_locations": checked,
			})
			if not checked.is_empty():
				emit_signal("location_checked", checked)
		"PrintJSON":
			var lines: Array = packet.get("data", [])
			var out := _format_printjson(lines)
			if not out.strip_edges().is_empty():
				emit_signal("print_json", out)
				# When we get a message, items might have been sent - request sync to get updated items
				if DEBUG_GENERAL: print_debug("[APClient] PrintJSON received, requesting Sync to check for new items")
				_send_sync()
		"Bounced":
			pass
		_:
			if DEBUG_GENERAL: print_debug("[APClient] Unhandled packet: %s" % cmd)

func _request_data_package() -> void:
	data_package_requested = true
	AP_DEBUG_LOG.event("APClient", "send_get_data_package", {"game": GAME_NAME})
	var payload := {
		"cmd": "GetDataPackage",
		"games": [GAME_NAME],
	}
	_send_packet(payload)

func _send_connect() -> void:
	connect_sent = true
	AP_DEBUG_LOG.event("APClient", "send_connect", {
		"game": GAME_NAME,
		"player": player_name,
		"items_handling": ITEMS_HANDLING,
		"slot_data": true,
	})
	var payload := {
		"cmd": "Connect",
		"password": password,
		"game": GAME_NAME,
		"name": player_name,
		"uuid": uuid,
		"version": GAME_VERSION,
		"items_handling": ITEMS_HANDLING,
		"tags": TAGS,
		"slot_data": true,
	}
	_send_packet(payload)
	state = ConnectionState.AUTHENTICATING
	emit_signal("connection_state_changed", state)

func _send_sync() -> void:
	var now := Time.get_ticks_msec()
	if now - last_sync_msec < SYNC_DEDUP_WINDOW_MSEC:
		return
	last_sync_msec = now
	var payload := {
		"cmd": "Sync",
	}
	# Don't include items field - let server send all items and we'll filter client-side
	if DEBUG_ITEM_SYNC: print_debug("[APClient] Sending Sync (last_processed=%d)" % last_processed_item_index)
	AP_DEBUG_LOG.event("APClient", "send_sync", {"last_processed_item_index": last_processed_item_index})
	_send_packet(payload)

func _send_packet(payload: Dictionary) -> bool:
	if websocket == null:
		if DEBUG_GENERAL: print_debug("[APClient] Dropped packet; websocket missing: %s" % str(payload.get("cmd", payload)))
		AP_DEBUG_LOG.event("APClient", "packet_dropped", {
			"reason": "missing_websocket",
			"cmd": payload.get("cmd", ""),
		})
		return false
	if websocket.get_ready_state() != WS_STATE_OPEN:
		if DEBUG_GENERAL: print_debug("[APClient] Dropped packet; socket not open state=%d cmd=%s" % [state, str(payload.get("cmd", payload))])
		AP_DEBUG_LOG.event("APClient", "packet_dropped", {
			"reason": "socket_not_open",
			"cmd": payload.get("cmd", ""),
			"state": state,
			"ready_state": websocket.get_ready_state(),
		})
		return false
	var array_payload := []
	array_payload.append(payload)
	var text := JSON.stringify(array_payload)
	if DEBUG_GENERAL: print_debug("[APClient] Sending packet: %s" % text)
	AP_DEBUG_LOG.event("APClient", "packet_sent", {
		"cmd": payload.get("cmd", ""),
		"bytes": text.length(),
	})
	var err := websocket.send_text(text)
	if err != OK:
		AP_DEBUG_LOG.event("APClient", "packet_send_failed", {
			"cmd": payload.get("cmd", ""),
			"error": err,
		})
		return false
	return true

func send_status_update(status: int) -> void:
	if state != ConnectionState.CONNECTED or not connected:
		if DEBUG_GENERAL: print_debug("[APClient] Cannot send status while disconnected: %d" % status)
		return
	_send_packet({"cmd": "StatusUpdate", "status": status})

func send_goal() -> void:
	# ClientStatus.CLIENT_GOAL = 30
	send_status_update(30)

func send_location_checks(location_ids: Array) -> bool:
	if state != ConnectionState.CONNECTED or not connected:
		if DEBUG_GENERAL: print_debug("[APClient] Cannot send checks while disconnected: %s (state=%d connected=%s)" % [str(location_ids), state, str(connected)])
		AP_DEBUG_LOG.event("APClient", "location_checks_dropped_disconnected", {
			"locations": location_ids,
			"state": state,
			"connected": connected,
		})
		return false
	var payload := {
		"cmd": "LocationChecks",
		"locations": location_ids,
	}
	AP_DEBUG_LOG.event("APClient", "send_location_checks", {"locations": location_ids})
	return _send_packet(payload)

func mock_receive_items(location_ids: Array) -> void:
	if state != ConnectionState.CONNECTED:
		return
	emit_signal("items_received", location_ids)

func is_ap_connected() -> bool:
	return state == ConnectionState.CONNECTED and connected

func get_state() -> int:
	return state

func get_slot_data() -> Dictionary:
	return slot_data.duplicate(true)

func get_last_processed_item_index() -> int:
	return last_processed_item_index

func set_last_processed_item_index(value: int) -> void:
	last_processed_item_index = max(last_processed_item_index, int(value))

func restore_item_tracking(last_index: int, direct_clues: int, letter_hints: int) -> void:
	last_processed_item_index = int(last_index)
	total_direct_clues_seen = int(max(0, direct_clues))
	total_letter_hint_items_seen = int(max(0, letter_hints))

func get_total_direct_clues_seen() -> int:
	return total_direct_clues_seen

func set_total_direct_clues_seen(total: int) -> void:
	total_direct_clues_seen = max(total_direct_clues_seen, int(total))

func get_total_letter_hint_items_seen() -> int:
	return total_letter_hint_items_seen

func set_total_letter_hint_items_seen(total: int) -> void:
	total_letter_hint_items_seen = max(total_letter_hint_items_seen, int(total))

func _handle_error(message: String) -> void:
	last_error = message
	if DEBUG_GENERAL: print_debug("[APClient] %s" % message)
	AP_DEBUG_LOG.event("APClient", "error", {"message": message, "state": state})
	emit_signal("connection_failed", message)
	_reset_state()

func _resolve_clue_item_id() -> void:
	clue_item_id = 0
	color_indicator_item_id = 0
	letter_hint_item_id = 0
	if DEBUG_GENERAL: print_debug("[APClient] data_package keys: %s" % str(data_package.keys()))
	var games_variant: Variant = data_package.get("games", null)
	if typeof(games_variant) == TYPE_DICTIONARY:
		var games: Dictionary = games_variant
		if DEBUG_GENERAL: print_debug("[APClient] games keys: %s" % str(games.keys()))
		var game_data_variant: Variant = games.get(GAME_NAME, null)
		if typeof(game_data_variant) == TYPE_DICTIONARY:
			var game_data: Dictionary = game_data_variant
			if DEBUG_GENERAL: print_debug("[APClient] game_data keys: %s" % str(game_data.keys()))
			var items_variant: Variant = game_data.get("item_name_to_id", null)
			if typeof(items_variant) == TYPE_DICTIONARY:
				var items_map: Dictionary = items_variant
				if DEBUG_GENERAL: print_debug("[APClient] item_name_to_id: %s" % str(items_map))
				var resolved: Variant = items_map.get("Clue", 0)
				match typeof(resolved):
					TYPE_INT:
						clue_item_id = resolved
					TYPE_FLOAT:
						clue_item_id = int(resolved)
				var color_resolved: Variant = items_map.get("Color Indicator", 0)
				match typeof(color_resolved):
					TYPE_INT:
						color_indicator_item_id = color_resolved
					TYPE_FLOAT:
						color_indicator_item_id = int(color_resolved)
				var hint_resolved: Variant = items_map.get("Letter Hint", 0)
				match typeof(hint_resolved):
					TYPE_INT:
						letter_hint_item_id = hint_resolved
					TYPE_FLOAT:
						letter_hint_item_id = int(hint_resolved)
	if DEBUG_ITEM_SYNC: print_debug("[APClient] Resolved Clue item_id=%d" % clue_item_id)
	if DEBUG_ITEM_SYNC: print_debug("[APClient] Resolved Color Indicator item_id=%d" % color_indicator_item_id)
	if DEBUG_ITEM_SYNC: print_debug("[APClient] Resolved Letter Hint item_id=%d" % letter_hint_item_id)
	AP_DEBUG_LOG.event("APClient", "item_ids_resolved", {
		"clue_item_id": clue_item_id,
		"color_indicator_item_id": color_indicator_item_id,
		"letter_hint_item_id": letter_hint_item_id,
	})

func get_location_id_for_clue(clue_number: int) -> int:
	if clue_number <= 0:
		return 0
	var game_data_variant: Variant = data_package.get(GAME_NAME, null)
	if typeof(game_data_variant) == TYPE_DICTIONARY:
		var game_data: Dictionary = game_data_variant
		var locations_variant: Variant = game_data.get("locations", null)
		if typeof(locations_variant) == TYPE_DICTIONARY:
			var locations: Dictionary = locations_variant
			var location_name := "Solved %d Words" % clue_number
			var resolved: Variant = locations.get(location_name, 0)
			if typeof(resolved) == TYPE_INT:
				return resolved
			if typeof(resolved) == TYPE_FLOAT:
				return int(resolved)
	# Fallback to the known location id formula used by the AP world.
	return 2000 + clue_number

func _open_websocket(request_subprotocol: bool) -> bool:
	var previous := websocket
	if previous != null:
		var prev_state := previous.get_ready_state()
		if prev_state == WS_STATE_OPEN or prev_state == WS_STATE_CONNECTING:
			previous.close(1000, "Reconnecting")
	websocket = WebSocketPeer.new()
	if websocket == null:
		last_error = "WebSocketPeer not available"
		emit_signal("connection_failed", last_error)
		return false
	requesting_subprotocol = request_subprotocol
	if request_subprotocol and websocket.has_method("set_supported_protocols"):
		websocket.set_supported_protocols(PackedStringArray([AP_SUBPROTOCOL]))
	if websocket.has_method("set_supported_extensions"):
		websocket.set_supported_extensions(PackedStringArray(AP_COMPRESSION_EXTENSIONS))
	if websocket.has_method("set_supports_per_message_deflate"):
		websocket.set_supports_per_message_deflate(true)
	var url := _build_ws_url()
	AP_DEBUG_LOG.event("APClient", "websocket_open_attempt", {
		"url": url,
		"use_tls": use_tls_connection,
		"request_subprotocol": request_subprotocol,
	})
	var err := OK
	if use_tls_connection:
		var tls := TLSOptions.client()
		if tls == null:
			tls = TLSOptions.client_unsafe()
		err = websocket.connect_to_url(url, tls)
	else:
		err = websocket.connect_to_url(url)
	if err != OK:
		last_error = "Failed to connect: %d" % err
		emit_signal("connection_failed", last_error)
		AP_DEBUG_LOG.event("APClient", "websocket_open_failed", {"error": err, "url": url})
		return false
	data_package_requested = false
	connect_sent = false
	state = ConnectionState.CONNECTING
	emit_signal("connection_state_changed", state)
	set_process(true)
	return true

func _build_ws_url() -> String:
	var prefix := "ws://"
	if use_tls_connection:
		prefix = "wss://"
	if host.find(":") != -1:
		return "%s%s" % [prefix, host]
	return "%s%s:%d" % [prefix, host, port]

func _try_fallback_without_subprotocol(close_reason: String, close_code: int) -> bool:
	if subprotocol_retry_attempted:
		return false
	if not requesting_subprotocol:
		return false
	var protocol_issue := close_reason.find("Requested sub-protocol") != -1 or close_code == WS_CLOSE_PROTOCOL_ERROR
	if protocol_issue:
		return _retry_without_subprotocol("Server did not acknowledge WebSocket subprotocol")
	if state == ConnectionState.CONNECTING:
		return _retry_without_subprotocol("WebSocket handshake ended before protocol negotiation")
	return false

func _retry_without_subprotocol(message: String) -> bool:
	if subprotocol_retry_attempted:
		return false
	if not requesting_subprotocol:
		return false
	# Some proxies drop Sec-WebSocket-Protocol; retry without insisting on it.
	subprotocol_retry_attempted = true
	if DEBUG_GENERAL: print_debug("[APClient] %s. Retrying without subprotocol." % message)
	AP_DEBUG_LOG.event("APClient", "retry_without_subprotocol", {"reason": message})
	if websocket != null:
		var prev_state := websocket.get_ready_state()
		if prev_state == WS_STATE_OPEN or prev_state == WS_STATE_CONNECTING:
			websocket.close(1000, "Retry without subprotocol")
			websocket = null
	return _open_websocket(false)

func _player_name_from_slot(slot: int) -> String:
	var players_variant: Variant = room_info.get("players", [])
	if typeof(players_variant) == TYPE_ARRAY:
		for p in players_variant:
			if typeof(p) == TYPE_DICTIONARY:
				var ps: int = int(p.get("slot", -1))
				if ps == slot:
					var name := String(p.get("name", "Player %d" % slot))
					return name
	return "Player %d" % slot

func _item_name_by_id(item_id: int) -> String:
	var games_variant: Variant = data_package.get("games", null)
	if typeof(games_variant) == TYPE_DICTIONARY:
		var games: Dictionary = games_variant
		var game_data_variant: Variant = games.get(GAME_NAME, null)
		if typeof(game_data_variant) == TYPE_DICTIONARY:
			var game_data: Dictionary = game_data_variant
			# Try item_id_to_name first (if it exists)
			var map_variant: Variant = game_data.get("item_id_to_name", null)
			if typeof(map_variant) == TYPE_DICTIONARY:
				var m: Dictionary = map_variant
				if m.has(item_id):
					return String(m[item_id])
				var key := String.num_int64(item_id)
				if m.has(key):
					return String(m[key])
			# Fallback: reverse lookup in item_name_to_id
			var name_to_id_variant: Variant = game_data.get("item_name_to_id", null)
			if typeof(name_to_id_variant) == TYPE_DICTIONARY:
				var name_to_id: Dictionary = name_to_id_variant
				for item_name in name_to_id.keys():
					var id_value = name_to_id[item_name]
					if int(id_value) == item_id:
						return String(item_name)
	return str(item_id)

func _format_printjson(lines: Array) -> String:
	var last_item_name: String = ""
	var players: Array[String] = []
	var player_slots: Array[int] = []
	var out_text_parts: Array[String] = []
	for part in lines:
		match typeof(part):
			TYPE_DICTIONARY:
				var t := String(part.get("type", ""))
				if t == "item_id":
					var iid: int = int(part.get("item", 0))
					last_item_name = _item_name_by_id(iid)
					out_text_parts.append(last_item_name)
				elif t == "player_id":
					var ps: int = int(part.get("player", -1))
					player_slots.append(ps)
					var pname := _player_name_from_slot(ps)
					players.append(pname)
					out_text_parts.append(pname)
				else:
					out_text_parts.append(String(part.get("text", "")))
			TYPE_STRING:
				out_text_parts.append(String(part))
			_:
				pass
	var raw_text := "".join(out_text_parts)
	var lower := raw_text.to_lower()
	# Suppress noisy compression warnings from the server.
	if lower.find("compressed websocket") != -1 or lower.find("permessage-deflate") != -1:
		return ""
	# Replace verbose connection help text with a concise message.
	if lower.find("now that you are connected") != -1 and lower.find("help") != -1:
		return "Connected to Archipelago"
	# Determine perspective and format succinctly.
	# Canonicalize item display names
	var display_name := last_item_name
	if display_name == "0":
		display_name = "Nothing"
	elif display_name == "1005" or display_name == "Letter Hint":
		display_name = "Letter Hint"
	
	# Don't show "Nothing" or "Clue" item messages - we handle them with our own logic
	if display_name == "Nothing" or display_name == "Clue":
		return ""
	
	if lower.find(" sent ") != -1:
		var sender_name: String = players[0] if players.size() > 0 else ""
		var receiver_name: String = players[1] if players.size() > 1 else ""
		if my_slot != -1 and player_slots.size() > 1:
			if player_slots[1] == my_slot and sender_name != "":
				return "Received %s from %s" % [display_name, sender_name]
			if player_slots[0] == my_slot and receiver_name != "":
				return "Sent %s to %s" % [display_name, receiver_name]
		if receiver_name != "":
			return "Sent %s to %s" % [display_name, receiver_name]
		return "Sent %s" % display_name
	if lower.find("found") != -1 or lower.find("received") != -1:
		# If there are two players and you are the second, you received it.
		if my_slot != -1 and player_slots.size() > 1 and player_slots[1] == my_slot:
				return "Received %s from %s" % [display_name, players[0]]
		return "Received %s" % display_name
	return raw_text
