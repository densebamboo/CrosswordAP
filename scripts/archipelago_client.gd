extends Node
class_name ArchipelagoClient

signal connection_state_changed(state: int)
signal connection_failed(reason: String)
signal location_checked(location_ids: Array)
signal items_received(location_ids: Array)
signal print_json(message: String)
signal slot_data_received(data: Dictionary)

enum ConnectionState {
	DISCONNECTED,
	CONNECTING,
	SOCKET_CONNECTED,
	AUTHENTICATING,
	CONNECTED,
}

const GAME_NAME := "CrosswordAP"
const GAME_VERSION := {
	"major": 0,
	"minor": 6,
	"build": 2,
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
var use_tls_connection: bool = false
var requesting_subprotocol: bool = true
var subprotocol_retry_attempted: bool = false
var my_slot: int = -1
var clue_item_id: int = 0

func _ready() -> void:
	uuid = OS.get_unique_id()
	set_process(false)
	if websocket == null:
		push_error("WebSocketPeer not available. Networking disabled.")

func connect_to_server(host_address: String, host_port: int, host_password: String = "", name: String = "") -> bool:
	if name.strip_edges().is_empty():
		last_error = "Player name required"
		emit_signal("connection_failed", last_error)
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
	return _open_websocket(false)

func disconnect_from_server() -> void:
	if state == ConnectionState.DISCONNECTED:
		return
	manual_disconnect = true
	if websocket != null and websocket.get_ready_state() in [WS_STATE_CONNECTING, WS_STATE_OPEN]:
		websocket.close(1000, "Client disconnect")
	_reset_state()

func _reset_state() -> void:
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
	use_tls_connection = false
	requesting_subprotocol = true
	subprotocol_retry_attempted = false
	websocket = null
	set_process(false)
	emit_signal("connection_state_changed", state)

func _process(_delta: float) -> void:
	if state == ConnectionState.DISCONNECTED or websocket == null:
		return
	websocket.poll()
	var ready := websocket.get_ready_state()
	if ready == WS_STATE_OPEN:
		if state == ConnectionState.CONNECTING or state == ConnectionState.SOCKET_CONNECTED:
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
			print_debug("[APClient] WebSocket closed code=%d reason=%s" % [close_code, close_reason])
			if _try_fallback_without_subprotocol(close_reason, close_code):
				return
			var message := "Connection closed"
			if not close_reason.is_empty():
				message = "%s: %s" % [message, close_reason]
			_handle_error(message)

func _on_ws_connected() -> void:
	state = ConnectionState.SOCKET_CONNECTED
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
	match cmd:
		"RoomInfo":
			room_info = packet
			if not data_package_requested:
				_request_data_package()
		"DataPackage":
			data_package = packet.get("data", {})
			_resolve_clue_item_id()
			if not connect_sent:
				_send_connect()
		"ConnectionRefused":
			var errors: Array = packet.get("errors", [])
			var reason := ", ".join(errors)
			_handle_error("Connection refused: %s" % reason)
		"Connected":
			state = ConnectionState.CONNECTED
			connected = true
			slot_data = packet.get("slot_data", {})
			if typeof(slot_data) != TYPE_DICTIONARY:
				slot_data = {}
			my_slot = int(packet.get("slot", -1))
			emit_signal("connection_state_changed", state)
			if not slot_data.is_empty():
				emit_signal("slot_data_received", slot_data)
			_send_sync()
		"ReceivedItems":
			var items: Array = packet.get("items", [])
			var clue_locations: Array = []
			for item_variant in items:
				var item_dict: Dictionary = item_variant
				var item_id: int = 0
				if item_dict.has("item"):
					var raw: Variant = item_dict.get("item", 0)
					if typeof(raw) == TYPE_INT:
						item_id = raw
					elif typeof(raw) == TYPE_FLOAT:
						item_id = int(raw)
				var loc_id: int = item_dict.get("location", 0)
				print_debug("[APClient] ReceivedItem item=%d loc=%d clue_id=%d" % [item_id, loc_id, clue_item_id])
				# Handle Clue items (unlock new clues)
				if clue_item_id != 0 and item_id == clue_item_id and loc_id != 0:
					clue_locations.append(loc_id)
					print_debug("[APClient] Matched Clue item, appending loc=%d" % loc_id)
			if not clue_locations.is_empty():
				emit_signal("items_received", clue_locations)
		"RoomUpdate":
			var checked: Array = packet.get("checked_locations", [])
			if not checked.is_empty():
				emit_signal("location_checked", checked)
		"PrintJSON":
			var lines: Array = packet.get("data", [])
			var out := _format_printjson(lines)
			if not out.strip_edges().is_empty():
				emit_signal("print_json", out)
		"Bounced":
			pass
		_:
			print_debug("[APClient] Unhandled packet: %s" % cmd)

func _request_data_package() -> void:
	data_package_requested = true
	var payload := {
		"cmd": "GetDataPackage",
		"games": [GAME_NAME],
	}
	_send_packet(payload)

func _send_connect() -> void:
	connect_sent = true
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
	_send_packet({"cmd": "Sync"})

func _send_packet(payload: Dictionary) -> void:
	if websocket == null:
		print_debug("[APClient] Dropped packet; websocket missing: %s" % str(payload.get("cmd", payload)))
		return
	if websocket.get_ready_state() != WS_STATE_OPEN:
		print_debug("[APClient] Dropped packet; socket not open state=%d cmd=%s" % [state, str(payload.get("cmd", payload))])
		return
	var array_payload := []
	array_payload.append(payload)
	var text := JSON.stringify(array_payload)
	print_debug("[APClient] Sending packet: %s" % text)
	websocket.send_text(text)

func send_status_update(status: int) -> void:
	if state != ConnectionState.CONNECTED or not connected:
		print_debug("[APClient] Cannot send status while disconnected: %d" % status)
		return
	_send_packet({"cmd": "StatusUpdate", "status": status})

func send_goal() -> void:
	# ClientStatus.CLIENT_GOAL = 30
	send_status_update(30)

func send_location_checks(location_ids: Array) -> void:
	if state != ConnectionState.CONNECTED or not connected:
		print_debug("[APClient] Cannot send checks while disconnected: %s (state=%d connected=%s)" % [str(location_ids), state, str(connected)])
		return
	var payload := {
		"cmd": "LocationChecks",
		"locations": location_ids,
	}
	_send_packet(payload)

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

func _handle_error(message: String) -> void:
	last_error = message
	print_debug("[APClient] %s" % message)
	emit_signal("connection_failed", message)
	_reset_state()

func _resolve_clue_item_id() -> void:
	clue_item_id = 0
	print_debug("[APClient] data_package keys: %s" % str(data_package.keys()))
	var games_variant: Variant = data_package.get("games", null)
	if typeof(games_variant) == TYPE_DICTIONARY:
		var games: Dictionary = games_variant
		print_debug("[APClient] games keys: %s" % str(games.keys()))
		var game_data_variant: Variant = games.get(GAME_NAME, null)
		if typeof(game_data_variant) == TYPE_DICTIONARY:
			var game_data: Dictionary = game_data_variant
			print_debug("[APClient] game_data keys: %s" % str(game_data.keys()))
			var items_variant: Variant = game_data.get("item_name_to_id", null)
			if typeof(items_variant) == TYPE_DICTIONARY:
				var items_map: Dictionary = items_variant
				print_debug("[APClient] item_name_to_id: %s" % str(items_map))
				var resolved: Variant = items_map.get("Clue", 0)
				match typeof(resolved):
					TYPE_INT:
						clue_item_id = resolved
					TYPE_FLOAT:
						clue_item_id = int(resolved)
	print_debug("[APClient] Resolved Clue item_id=%d" % clue_item_id)

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
	print_debug("[APClient] %s. Retrying without subprotocol." % message)
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
			var map_variant: Variant = game_data.get("item_id_to_name", null)
			if typeof(map_variant) == TYPE_DICTIONARY:
				var m: Dictionary = map_variant
				if m.has(item_id):
					return String(m[item_id])
				var key := String.num_int64(item_id)
				if m.has(key):
					return String(m[key])
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
	if lower.find(" sent ") != -1:
		var sender_name: String = players[0] if players.size() > 0 else ""
		var receiver_name: String = players[1] if players.size() > 1 else ""
		if my_slot != -1 and player_slots.size() > 1:
			if player_slots[1] == my_slot and sender_name != "":
				return "Received '%s' from '%s'" % [display_name, sender_name]
			if player_slots[0] == my_slot and receiver_name != "":
				return "Sent '%s' to '%s'" % [display_name, receiver_name]
		if receiver_name != "":
			return "Sent '%s' to '%s'" % [display_name, receiver_name]
		return "Sent '%s'" % display_name
	if lower.find("found") != -1 or lower.find("received") != -1:
		# If there are two players and you are the second, you received it.
		if my_slot != -1 and player_slots.size() > 1 and player_slots[1] == my_slot:
				return "Received '%s' from '%s'" % [display_name, players[0]]
		return "Received '%s'" % display_name
	return raw_text
