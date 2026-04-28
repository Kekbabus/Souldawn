#  client_main.gd -- client entry point & orchestrator
#
#  Owns the ENet peer, input handling, camera, coordinate helpers.
#  Delegates to subsystem scripts for UI, entities, combat, inventory.
extends Node2D

const SERVER_IP_DEFAULT := "127.0.0.1"
const SERVER_PORT_DEFAULT := 8080
const TILE_SIZE := 32

var _server_ip: String = SERVER_IP_DEFAULT
var _server_port: int = SERVER_PORT_DEFAULT
const MOVE_SEND_INTERVAL := 0.15
const DEFAULT_GROUND_SPEED := 150.0
const ANIM_SPEEDUP := 1.0

# fixed tile viewport -- always show exactly this many tiles
const TARGET_TILES_X := 15
const TARGET_TILES_Y := 11

var auth: Node = null
var chat: Node = null
var entities: Node = null
var players: Node = null
var combat: Node = null
var inventory: Node = null
var map: Node = null
var containers: Node = null
var ui: Node = null

var _local_peer_id: int = 0
var _local_entity_id: int = 0
var _local_gender: String = "male"
var _last_sent_dir: Vector2i = Vector2i.ZERO
var _move_send_timer: float = 0.0
var _camera: Camera2D = null
var _world: Node2D = null
var _logged_in: bool = false
var _is_dead: bool = false
var _crosshair_mode: bool = false
var _crosshair_rune_slot: int = -1
var _crosshair_rune_cid: int = -1
var _current_z: int = 7
var _magic_walls: Dictionary = {}  # Vector3i -> true (tracks magic wall positions for client-side blocking)
var _last_process_tile: Vector2i = Vector2i(-9999, -9999)


## Initializes subsystems, wires cross-references, and sets up the game world.
func _ready() -> void:
	_load_client_config()
	_world = Node2D.new()
	_world.name = "World"
	_world.visible = false
	add_child(_world)

	_camera = Camera2D.new()
	_camera.name = "Camera"
	_camera.enabled = false
	add_child(_camera)

	# Instantiate subsystems
	auth = preload("res://Scripts/client_auth.gd").new()
	auth.name = "ClientAuth"
	add_child(auth)

	chat = preload("res://Scripts/client_chat.gd").new()
	chat.name = "ClientChat"
	add_child(chat)

	players = preload("res://Scripts/client_players.gd").new()
	players.name = "ClientPlayers"
	add_child(players)

	entities = preload("res://Scripts/client_entities.gd").new()
	entities.name = "ClientEntities"
	add_child(entities)

	combat = preload("res://Scripts/client_combat.gd").new()
	combat.name = "ClientCombat"
	add_child(combat)

	inventory = preload("res://Scripts/client_inventory.gd").new()
	inventory.name = "ClientInventory"
	add_child(inventory)

	map = preload("res://Scripts/client_map.gd").new()
	map.name = "ClientMap"
	add_child(map)

	containers = preload("res://Scripts/client_containers.gd").new()
	containers.name = "ClientContainers"
	add_child(containers)

	ui = preload("res://Scripts/client_ui.gd").new()
	ui.name = "ClientUI"
	add_child(ui)

	# Wire cross-references
	auth.client = self
	chat.client = self
	players.client = self
	entities.client = self
	combat.client = self
	inventory.client = self
	map.client = self
	containers.client = self
	ui.client = self

	# Build tile lookup from TileSet atlases
	map.build_tile_lookup()

	# Setup UI -- old programmatic UI (auth/death stay, rest replaced by scene UI)
	auth.setup_login_ui()
	# combat.setup_stats_hud()  # Replaced by sidebar health/mana bars
	combat.setup_death_overlay()
	combat.load_sprite_config()
	# inventory.setup_inventory_ui()  # Replaced by sidebar backpack
	# Note: containers.setup_ui() is NOT called -- the old floating container panel
	# is replaced by sidebar containers in client_ui. But container world markers
	# (corpse dots) still work since handle_container_spawn doesn't need setup_ui().
	ui.setup_ui()

	# Reparent world and camera into the SubViewport for proper rendering
	var game_vp: SubViewport = ui.get_game_viewport()
	if game_vp:
		remove_child(_world)
		game_vp.add_child(_world)
		remove_child(_camera)
		game_vp.add_child(_camera)
		# Connect resize to recalculate zoom
		game_vp.size_changed.connect(_update_camera_zoom)
		_update_camera_zoom()

	# Network callbacks (connection happens on login attempt)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	print("client: ready -- waiting for login")


## Called when ENet connection to the server succeeds.
func _on_connected() -> void:
	_local_peer_id = multiplayer.get_unique_id()
	_local_entity_id = -_local_peer_id
	print("client: connected as peer %d" % _local_peer_id)
	# Now send the pending login/register request
	auth._send_pending_request()

## Called when ENet connection to the server fails.
func _on_connection_failed() -> void:
	push_error("client: connection failed")
	auth.show_error("Could not connect to server.")
	_disconnect_peer()

## Called when the server drops the connection.
func _on_server_disconnected() -> void:
	print("client: server disconnected")
	_return_to_login("Server disconnected.")

## Loads client configuration from client_config.json.
## Checks the executable's directory first (for deployed builds), then res:// (for editor).
func _load_client_config() -> void:
	var data: Dictionary = {}
	var exe_dir := OS.get_executable_path().get_base_dir()
	var paths := [
		exe_dir + "/client_config.json",
		"res://client_config.json",
	]
	for path in paths:
		var file := FileAccess.open(path, FileAccess.READ)
		if file != null:
			var json := JSON.new()
			if json.parse(file.get_as_text()) == OK and json.data is Dictionary:
				data = json.data
			file.close()
			print("client: loaded config from %s" % path)
			break
	if data.is_empty():
		print("client: no config found, using defaults")
		return
	_server_ip = str(data.get("server_ip", SERVER_IP_DEFAULT))
	_server_port = int(data.get("server_port", SERVER_PORT_DEFAULT))
	print("client: server %s:%d" % [_server_ip, _server_port])


## Initiates connection to the server. Returns true if connection attempt started.
func connect_to_server() -> bool:
	# Always create a fresh peer
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(_server_ip, _server_port)
	if err != OK:
		auth.show_error("Failed to connect to server.")
		return false
	multiplayer.multiplayer_peer = peer
	print("client: connecting to %s:%d …" % [_server_ip, _server_port])
	return true

## Closes and clears the multiplayer peer.
func _disconnect_peer() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null

## Tears down the game session and returns to the login screen with an error message.
func _return_to_login(message: String) -> void:
	_logged_in = false
	_is_dead = false
	_cleanup_all()
	_world.visible = false
	_disconnect_peer()
	# Hide death dialog if showing
	if combat: combat._hide_death_dialog()
	# Hide game UI
	var chat_layer := get_node_or_null("ChatLayer")
	if chat_layer: chat_layer.visible = false
	var stats_layer := get_node_or_null("StatsLayer")
	if stats_layer: stats_layer.visible = false
	if ui: ui.hide_hud()
	auth.show_login()
	auth.show_error(message)
	# Rescue camera
	if _camera != null and is_instance_valid(_camera) and _camera.get_parent() != self:
		_camera.get_parent().remove_child(_camera)
		add_child(_camera)
		_camera.enabled = false

## Frees all players, entities, map data, containers, and UI overlays.
func _cleanup_all() -> void:
	players.cleanup_all()
	entities.cleanup_all()
	map.clear()
	containers.cleanup()
	if ui:
		ui.close_all_containers()
		ui.clear_all_entity_overlays()


#  INPUT & GAME LOOP

## Main game loop -- processes input, animations, overlays, and floor visibility.
func _process(delta: float) -> void:
	if not _logged_in:
		return
	ui.process_chat_focus()
	_process_input(delta)
	players.process_movement_animation(delta)
	players.update_speech_bubble_positions()
	entities.process_entity_animation(delta)
	entities.process_npc_animation(delta)
	entities.update_floating_numbers(delta)
	ui.update_entity_overlays()
	if inventory._dragging:
		inventory.update_drag_preview()
	combat.process_blood_spills()
	# Tibia-style roof hiding -- only check when player tile changes
	if players._players.has(_local_entity_id):
		var pdata: Dictionary = players._players[_local_entity_id]
		var pnode: Node2D = pdata["node"]
		var cur_tile := Vector2i(
			int(floor(pnode.position.x / TILE_SIZE)),
			int(floor(pnode.position.y / TILE_SIZE)))
		if cur_tile != _last_process_tile:
			_last_process_tile = cur_tile
			map.update_floor_visibility(pnode.position, _current_z)
			entities.update_z_visibility(_current_z)
			players.update_z_visibility(_current_z, _local_entity_id)
			containers.update_z_visibility(_current_z)
			containers.check_proximity(cur_tile)


## Sends movement RPCs based on held arrow/numpad keys, rate-limited by MOVE_SEND_INTERVAL.
## Uses client-side prediction (pre-walking): starts the walk animation locally before
## the server confirms, so movement feels instant. Server corrections snap back if needed.
func _process_input(delta: float) -> void:
	if _is_dead:
		return
	if Input.is_key_pressed(KEY_CTRL):
		return
	_move_send_timer -= delta
	if _move_send_timer > 0.0:
		return
	var dir := _get_held_direction()
	if dir == Vector2i.ZERO:
		return
	rpc_id(1, "rpc_move_direction", dir.x, dir.y)
	_move_send_timer = MOVE_SEND_INTERVAL
	# Pre-walk: start the local walk animation immediately without waiting for server
	if players._players.has(_local_entity_id):
		var pdata: Dictionary = players._players[_local_entity_id]
		var pnode: Node2D = pdata["node"]
		var cur_tile := Vector2i(
			int(round(pnode.position.x / TILE_SIZE)),
			int(round(pnode.position.y / TILE_SIZE)))
		# Only pre-walk if not already mid-animation toward a different tile
		if not pdata["moving"] and pdata["move_queue"].is_empty():
			var target_tile := Vector3i(cur_tile.x + dir.x, cur_tile.y + dir.y, _current_z)
			# Client-side blocking check -- don't pre-walk into walls, entities, or players
			var tile_blocked: bool = map.is_blocking(target_tile)
			# Check magic walls
			if not tile_blocked and _magic_walls.has(target_tile):
				tile_blocked = true
			if not tile_blocked:
				var target_tile_2d := Vector2i(cur_tile.x + dir.x, cur_tile.y + dir.y)
				# Check entities at target tile
				if entities.get_entity_at_tile(target_tile_2d) > 0:
					tile_blocked = true
				# Check other players at target tile
				if not tile_blocked:
					for eid in players._players:
						if eid == _local_entity_id:
							continue
						var other: Dictionary = players._players[eid]
						var onode: Node2D = other["node"]
						var otile := Vector2i(
							int(round(onode.position.x / TILE_SIZE)),
							int(round(onode.position.y / TILE_SIZE)))
						if otile == target_tile_2d:
							tile_blocked = true
							break
			if not tile_blocked:
				var target_pixel := Vector2((cur_tile.x + dir.x) * TILE_SIZE, (cur_tile.y + dir.y) * TILE_SIZE)
				pdata["_prewalk_from"] = Vector2(cur_tile.x * TILE_SIZE, cur_tile.y * TILE_SIZE)
				pdata["_prewalk_active"] = true
				if absf(dir.y) >= absf(dir.x):
					pdata["facing"] = "north" if dir.y < 0 else "south"
				else:
					pdata["facing"] = "west" if dir.x < 0 else "east"
				players._start_move(pdata, target_pixel)


## Returns true if any chat input field currently has keyboard focus.
func _is_chat_focused() -> bool:
	if chat._chat_input != null and chat._chat_input.has_focus():
		return true
	var ui_chat: LineEdit = ui.get_chat_input() as LineEdit
	if ui_chat != null and ui_chat.has_focus():
		return true
	return false


## Handles discrete input events: drag release, turn-in-place, hotkeys, click interactions.
func _input(event: InputEvent) -> void:
	if not _logged_in:
		return
	# Handle drag release
	if inventory._dragging and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		inventory.end_drag(event.global_position)
		get_viewport().set_input_as_handled()
		return
	# Dead -- block all game input (death dialog handles respawn/logout)
	if _is_dead:
		return
	# Ctrl+arrow = turn in place
	if event is InputEventKey and event.pressed and not event.echo and Input.is_key_pressed(KEY_CTRL):
		var turn := -1
		match event.keycode:
			KEY_UP, KEY_KP_8:    turn = 0
			KEY_RIGHT, KEY_KP_6: turn = 1
			KEY_DOWN, KEY_KP_2:  turn = 2
			KEY_LEFT, KEY_KP_4:  turn = 3
		if turn >= 0:
			rpc_id(1, "rpc_turn_direction", turn)
			return
	# F-keys: F1-F12 = hotkey bar (all configurable)
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_F1: ui.handle_hotkey(0); return
			KEY_F2: ui.handle_hotkey(1); return
			KEY_F3: ui.handle_hotkey(2); return
			KEY_F4: ui.handle_hotkey(3); return
			KEY_F5: ui.handle_hotkey(4); return
			KEY_F6: ui.handle_hotkey(5); return
			KEY_F7: ui.handle_hotkey(6); return
			KEY_F8: ui.handle_hotkey(7); return
			KEY_F9: ui.handle_hotkey(8); return
			KEY_F10: ui.handle_hotkey(9); return
			KEY_F11: ui.handle_hotkey(10); return
			KEY_F12: ui.handle_hotkey(11); return
	# Escape cancels crosshair mode
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE and _crosshair_mode:
		_exit_crosshair_mode()
		return
	# Left-click in crosshair mode: use rune on target tile
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if not is_mouse_over_game_viewport():
			return
		if _crosshair_mode:
			var world_pos := get_world_mouse_position()
			var tile_pos := Vector2i(int(floor(world_pos.x / TILE_SIZE)), int(floor(world_pos.y / TILE_SIZE)))
			rpc_id(1, "rpc_use_rune", _crosshair_rune_slot, tile_pos.x, tile_pos.y, _current_z)
			_exit_crosshair_mode()
			return
		if inventory._slider_open:
			return
		if not inventory._dragging:
			var world_pos := get_world_mouse_position()
			var tile_pos := Vector2i(int(floor(world_pos.x / TILE_SIZE)), int(floor(world_pos.y / TILE_SIZE)))
			# Proximity check -- must be within 1 tile of player
			var player_tile := Vector2i.ZERO
			if players._players.has(_local_entity_id):
				var pnode: Node2D = players._players[_local_entity_id]["node"]
				player_tile = Vector2i(int(floor(pnode.position.x / TILE_SIZE)), int(floor(pnode.position.y / TILE_SIZE)))
			if absi(tile_pos.x - player_tile.x) <= 1 and absi(tile_pos.y - player_tile.y) <= 1:
				var ground_item: Dictionary = inventory.get_ground_item_at(tile_pos)
				if not ground_item.is_empty():
					inventory._drag_ground_pos = Vector3i(tile_pos.x, tile_pos.y, _current_z)
					inventory._drag_ground_item_id = ground_item["item_id"]
					var ground_count: int = int(ground_item.get("count", 1))
					var ground_sprite: String = str(ground_item.get("sprite", ""))
					inventory.start_drag("ground", -1, -1, "", Color.GOLD, ground_count, ground_sprite)
				else:
					var corpse_cid: int = containers.get_corpse_at_tile(tile_pos)
					if corpse_cid >= 0:
						inventory._drag_ground_pos = Vector3i(tile_pos.x, tile_pos.y, _current_z)
						inventory._drag_container_id = corpse_cid
						inventory.start_drag("corpse_move", -1, corpse_cid, "", Color(0.5, 0.3, 0.1))
	# Right-click: attack entity or pick up ground item
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and not event.pressed:
		if not is_mouse_over_game_viewport():
			return
		if inventory._slider_open:
			return
		var world_pos := get_world_mouse_position()
		var tile_pos := Vector2i(int(floor(world_pos.x / TILE_SIZE)), int(floor(world_pos.y / TILE_SIZE)))
		if event.shift_pressed:
			inventory.try_pickup_at(tile_pos)
			return
		var eid: int = entities.get_entity_at_tile(tile_pos)
		if eid > 0:
			rpc_id(1, "rpc_attack_request", eid)
		else:
			# Check for another player at this tile (PVP targeting)
			var target_player_eid := _get_player_at_tile(tile_pos)
			if target_player_eid != 0 and target_player_eid != _local_entity_id:
				# Player entity IDs are negative peer IDs, so peer_id = -eid
				rpc_id(1, "rpc_attack_player", -target_player_eid)
			else:
				rpc_id(1, "rpc_use_tile", tile_pos.x, tile_pos.y, _current_z)


## Returns the player entity_id at the given tile, or 0 if none.
func _get_player_at_tile(tile_pos: Vector2i) -> int:
	for eid in players._players:
		var data: Dictionary = players._players[eid]
		var node: Node2D = data["node"]
		var ptile := Vector2i(
			int(round(node.position.x / TILE_SIZE)),
			int(round(node.position.y / TILE_SIZE)))
		if ptile == tile_pos:
			return eid
	return 0


## Returns the currently held movement direction from arrow/numpad keys, including diagonals.
func _get_held_direction() -> Vector2i:
	if Input.is_key_pressed(KEY_HOME) or Input.is_key_pressed(KEY_KP_7):     return Vector2i(-1, -1)
	if Input.is_key_pressed(KEY_PAGEUP) or Input.is_key_pressed(KEY_KP_9):   return Vector2i(1, -1)
	if Input.is_key_pressed(KEY_END) or Input.is_key_pressed(KEY_KP_1):      return Vector2i(-1, 1)
	if Input.is_key_pressed(KEY_PAGEDOWN) or Input.is_key_pressed(KEY_KP_3): return Vector2i(1, 1)
	if Input.is_key_pressed(KEY_UP) or Input.is_key_pressed(KEY_KP_8):       return Vector2i(0, -1)
	if Input.is_key_pressed(KEY_DOWN) or Input.is_key_pressed(KEY_KP_2):     return Vector2i(0, 1)
	if Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_KP_4):     return Vector2i(-1, 0)
	if Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_KP_6):    return Vector2i(1, 0)
	return Vector2i.ZERO


#  COORDINATE HELPERS

## Adjusts camera zoom so exactly TARGET_TILES_X × TARGET_TILES_Y tiles are visible.
func _update_camera_zoom() -> void:
	var game_vp: SubViewport = ui.get_game_viewport() if ui else null
	if game_vp == null or _camera == null:
		return
	var vp_size: Vector2 = Vector2(game_vp.size)
	if vp_size.x <= 0 or vp_size.y <= 0:
		return
	# How many pixels the target tile area should occupy
	var world_width: float = TARGET_TILES_X * TILE_SIZE
	var world_height: float = TARGET_TILES_Y * TILE_SIZE
	# Zoom = viewport_pixels / world_pixels (higher zoom = more zoomed in)
	var zoom_x: float = vp_size.x / world_width
	var zoom_y: float = vp_size.y / world_height
	# Use the larger zoom to maintain fixed tile count (crops excess, never shows more tiles)
	var zoom_val: float = maxf(zoom_x, zoom_y)
	_camera.zoom = Vector2(zoom_val, zoom_val)

## Converts the current mouse position to world coordinates via the game SubViewport.
func get_world_mouse_position() -> Vector2:
	# Use the game SubViewport if available, otherwise fall back to main viewport
	var game_vp: SubViewport = ui.get_game_viewport() if ui else null
	if game_vp:
		# The SubViewport has its own canvas transform (includes camera zoom/position)
		# Use its mouse_position and canvas_transform directly
		var vp_mouse := game_vp.get_mouse_position()
		var canvas_xform := game_vp.get_canvas_transform()
		return canvas_xform.affine_inverse() * vp_mouse
	var viewport := get_viewport()
	var camera := viewport.get_camera_2d()
	if camera != null:
		return camera.get_global_mouse_position()
	var canvas_xform := viewport.get_canvas_transform()
	return canvas_xform.affine_inverse() * viewport.get_mouse_position()


#  SERVER -> CLIENT RPCs (dispatched to subsystems)

## Enters crosshair targeting mode for using a rune on a target tile.
func enter_crosshair_mode(rune_slot: int, container_id: int = -1) -> void:
	_crosshair_mode = true
	_crosshair_rune_slot = rune_slot
	_crosshair_rune_cid = container_id
	Input.set_default_cursor_shape(Input.CURSOR_CROSS)


## Exits crosshair targeting mode and restores the default cursor.
func _exit_crosshair_mode() -> void:
	_crosshair_mode = false
	_crosshair_rune_slot = -1
	_crosshair_rune_cid = -1
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)


## Returns true if the mouse cursor is over the game viewport area (not sidebar/chat).
func is_mouse_over_game_viewport() -> bool:
	if ui == null or ui._hud == null:
		return true
	var gvc: Control = ui._hud.get_node_or_null("MainHBox/CenterColumn/GameViewportContainer")
	if gvc == null:
		return true
	var mouse_pos := get_viewport().get_mouse_position()
	return gvc.get_global_rect().has_point(mouse_pos)


## Server confirms login -- spawns local player, attaches camera, shows HUD.
@rpc("any_peer")
func rpc_enter_world(peer_id: int, x: int, y: int, z: int, display_name: String, speed: int, outfit: String = "", gender: String = "male") -> void:
	_logged_in = true
	_local_gender = gender
	_world.visible = true
	auth.hide_login()
	_current_z = z
	_last_process_tile = Vector2i(-9999, -9999)
	map.set_current_z(z)
	# Show game UI
	var chat_layer := get_node_or_null("ChatLayer")
	if chat_layer: chat_layer.visible = true
	var stats_layer := get_node_or_null("StatsLayer")
	if stats_layer: stats_layer.visible = true
	ui.show_hud()
	var eid := -peer_id
	players.spawn_player_entity(eid, Vector3i(x, y, z), display_name, float(speed), outfit)
	var data: Dictionary = players._players[eid]
	var node: Node2D = data["node"]
	if _camera.get_parent() != node:
		_camera.get_parent().remove_child(_camera)
		node.add_child(_camera)
	_camera.position = Vector2(TILE_SIZE / 2.0, TILE_SIZE / 2.0)
	_camera.enabled = true
	_camera.make_current()
	# Play spawn effect on the player's tile
	combat.play_effect_at_tile(combat._spawn_effect, x, y)
	entities.update_z_visibility(z)

## Server spawns another player in the world.
@rpc("any_peer")
func rpc_player_spawn(peer_id: int, x: int, y: int, z: int, display_name: String, speed: int, outfit: String = "") -> void:
	var eid := -peer_id
	if players._players.has(eid):
		return
	players.spawn_player_entity(eid, Vector3i(x, y, z), display_name, float(speed), outfit)
	combat.play_effect_at_tile(combat._spawn_effect, x, y)

## Server notifies a player moved; updates z-level if local player changed floors.
@rpc("any_peer")
func rpc_player_move(peer_id: int, x: int, y: int, z: int, step_ms: int = 0) -> void:
	var eid := -peer_id
	if eid == _local_entity_id and z != _current_z:
		_current_z = z
		_last_process_tile = Vector2i(-9999, -9999)
		map.set_current_z(z)
		entities.update_z_visibility(z)
		entities.handle_combat_clear()
	players.handle_player_move(eid, x, y, z, step_ms)

## Server teleports a player instantly (no walk animation).
@rpc("any_peer")
func rpc_player_teleport(peer_id: int, x: int, y: int, z: int) -> void:
	var eid := -peer_id
	if eid == _local_entity_id and z != _current_z:
		_current_z = z
		_last_process_tile = Vector2i(-9999, -9999)
		map.set_current_z(z)
		entities.update_z_visibility(z)
		entities.handle_combat_clear()
	players.handle_player_teleport(eid, x, y, z)
	# Refresh visibility for all players after any teleport (z-level may have changed)
	players.update_z_visibility(_current_z, _local_entity_id)

## Server removes a player from the world.
@rpc("any_peer")
func rpc_player_despawn(peer_id: int) -> void:
	players.handle_player_despawn(-peer_id)

## Server notifies a player changed facing direction.
@rpc("any_peer")
func rpc_player_face(peer_id: int, direction: int) -> void:
	players.handle_player_face(-peer_id, direction)

## Server sends a chat message to display.
@rpc("any_peer")
func rpc_receive_chat(channel: String, sender: String, text: String) -> void:
	ui.receive_chat(channel, sender, text)

## Server spawns a monster/entity with sprite and health data.
@rpc("any_peer")
func rpc_entity_spawn(eid: int, definition_id: String, display_name: String,
		x: int, y: int, z: int, health: int, max_health: int, speed: int, sprite: String = "") -> void:
	entities.handle_entity_spawn(eid, definition_id, display_name, x, y, z, health, max_health, speed, sprite)

## Server moves an entity to a new tile.
@rpc("any_peer")
func rpc_entity_move(eid: int, x: int, y: int, z: int, step_ms: int = 0) -> void:
	entities.handle_entity_move(eid, x, y, z, step_ms)

## Server updates an entity's facing direction (when attacking, etc.).
@rpc("any_peer")
func rpc_entity_face(eid: int, direction: int) -> void:
	entities.handle_entity_face(eid, direction)

## Server removes an entity from the world.
@rpc("any_peer")
func rpc_entity_despawn(eid: int) -> void:
	entities.handle_entity_despawn(eid)

## Server reports damage dealt to an entity.
@rpc("any_peer")
func rpc_entity_damage(eid: int, damage: int, damage_type: String, health: int, max_health: int) -> void:
	entities.handle_entity_damage(eid, damage, damage_type, health, max_health)

## Server sets the player's combat target (shows outline).
@rpc("any_peer")
func rpc_combat_target(eid: int) -> void:
	entities.handle_combat_target(eid)

## Server clears the player's combat target.
@rpc("any_peer")
func rpc_combat_clear() -> void:
	entities.handle_combat_clear()

## Server reports XP gained from killing a monster.
@rpc("any_peer")
func rpc_experience_gain(amount: int, _x: int, _y: int, _z: int) -> void:
	# Show XP number on the local player
	if players._players.has(_local_entity_id):
		var node: Node2D = players._players[_local_entity_id]["node"]
		entities.show_xp_number(node.position + Vector2(TILE_SIZE / 2.0, 0), amount)

## Server reports damage dealt to a player.
@rpc("any_peer")
func rpc_player_damage(peer_id: int, damage: int, damage_type: String, health: int, max_health: int) -> void:
	combat.handle_player_damage(-peer_id, damage, damage_type, health, max_health)
	# Update sidebar health bar if this is the local player
	if -peer_id == _local_entity_id:
		ui.update_health(health, max_health)

## Server updates a player's skull type (none, white, yellow, red).
@rpc("any_peer")
func rpc_player_skull(peer_id: int, skull: String) -> void:
	var eid := -peer_id
	if players._players.has(eid):
		players._players[eid]["skull"] = skull
		# Update the name label with skull emoji and color
		var overlay_key := "player_%d" % eid
		if ui._entity_overlays.has(overlay_key):
			var data: Dictionary = ui._entity_overlays[overlay_key]
			var name_label: Label = data.get("name_label")
			if name_label:
				var display_name: String = str(players._players[eid].get("display_name", ""))
				match skull:
					"white":
						name_label.text = "💀 " + display_name
						name_label.add_theme_color_override("font_color", Color.WHITE)
					"yellow":
						name_label.text = "💀 " + display_name
						name_label.add_theme_color_override("font_color", Color.YELLOW)
					"red":
						name_label.text = "☠ " + display_name
						name_label.add_theme_color_override("font_color", Color.RED)
					_:
						name_label.text = display_name
						name_label.add_theme_color_override("font_color", Color(0, 0.8, 0))

## Server notifies the local player has died.
@rpc("any_peer")
func rpc_player_death(xp_loss: int) -> void:
	combat.handle_player_death(xp_loss)
	ui.show_death(xp_loss)

## Server confirms respawn -- repositions player and restores health.
@rpc("any_peer")
func rpc_respawn_result(x: int, y: int, z: int, health: int, max_health: int) -> void:
	combat.handle_respawn_result(x, y, z, health, max_health)
	ui.hide_death()
	# Update z-level for floor visibility
	if z != _current_z:
		_current_z = z
		_last_process_tile = Vector2i(-9999, -9999)
		map.set_current_z(z)
		entities.update_z_visibility(z)

## Server sends updated HP, MP, level, and XP values.
@rpc("any_peer")
func rpc_stats_update(health: int, max_health: int, mana: int, max_mana: int, level: int, xp: int, xp_next: int) -> void:
	combat.handle_stats_update(health, max_health, mana, max_mana, level, xp, xp_next)
	ui.update_stats(health, max_health, mana, max_mana, level, xp, xp_next)

## Server sends updated attack, defense, armor, capacity, and speed values.
@rpc("any_peer")
func rpc_combat_stats(attack: int, defense: int, armor: int, weight: float, max_cap: float, speed: int = 0, ground_speed: float = 150.0) -> void:
	ui.update_combat_stats(attack, defense, armor, weight, max_cap, speed, ground_speed)

## Server triggers a spell visual effect at a tile position.
@rpc("any_peer")
func rpc_spell_effect(caster_peer_id: int, spell_id: String, x: int, y: int, z: int, value: int) -> void:
	combat.handle_spell_effect(caster_peer_id, spell_id, x, y, z, value)

## Server triggers a visual effect on a single tile (monster waves/areas).
@rpc("any_peer")
func rpc_tile_effect(effect_name: String, x: int, y: int, _z: int) -> void:
	combat.play_effect_at_tile(effect_name, x, y)

## Server places a persistent field on a tile.
@rpc("any_peer")
func rpc_field_spawn(x: int, y: int, _z: int, field_type: String, duration: float = 45.0) -> void:
	var pos := Vector3i(x, y, _z)
	if field_type == "magic_wall":
		_magic_walls[pos] = true
	var node_name := "Field_%d_%d_%d" % [x, y, _z]
	var existing: Node = _world.get_node_or_null(node_name)
	if existing != null:
		existing.queue_free()

	var field_node := Node2D.new()
	field_node.name = node_name
	field_node.position = Vector2(x * TILE_SIZE, y * TILE_SIZE)
	field_node.z_index = 1

	# Load field config with decay stages from sprite_config.json
	var field_config: Dictionary = {}
	var sc_file := FileAccess.open("res://datapacks/sprite_config.json", FileAccess.READ)
	if sc_file:
		var sc_json := JSON.new()
		if sc_json.parse(sc_file.get_as_text()) == OK and sc_json.data is Dictionary:
			field_config = sc_json.data.get("field_sprites", {}).get(field_type, {})
		sc_file.close()

	var stages: Array = field_config.get("stages", [])
	if not stages.is_empty():
		var anim := _create_field_anim(stages[0])
		if anim != null:
			field_node.add_child(anim)
			# Set up stage transitions
			if stages.size() > 1 and duration > 0:
				var stage_time: float = duration / float(stages.size())
				for i in range(1, stages.size()):
					var stage_data: Dictionary = stages[i]
					var timer := Timer.new()
					timer.wait_time = stage_time * float(i)
					timer.one_shot = true
					timer.autostart = true
					var fn := field_node
					timer.timeout.connect(func():
						if is_instance_valid(fn):
							for child in fn.get_children():
								if child is AnimatedSprite2D:
									child.queue_free()
							var new_anim := _create_field_anim(stage_data)
							if new_anim != null:
								fn.add_child(new_anim)
					)
					field_node.add_child(timer)
		else:
			_add_field_fallback(field_node, field_type)
	else:
		_add_field_fallback(field_node, field_type)
	_world.add_child(field_node)


func _create_field_anim(stage: Dictionary) -> AnimatedSprite2D:
	var frame_paths: Array = stage.get("frames", [])
	var fps: float = float(stage.get("fps", 4.0))
	if frame_paths.is_empty():
		return null
	var sf := SpriteFrames.new()
	sf.add_animation("default")
	sf.set_animation_speed("default", fps)
	sf.set_animation_loop("default", true)
	for fpath in frame_paths:
		var fp: String = str(fpath)
		if ResourceLoader.exists(fp):
			sf.add_frame("default", load(fp))
	if sf.get_frame_count("default") == 0:
		return null
	var anim := AnimatedSprite2D.new()
	anim.sprite_frames = sf
	anim.centered = false
	anim.play("default")
	return anim


func _add_field_fallback(field_node: Node2D, field_type: String) -> void:
	var rect := ColorRect.new()
	rect.size = Vector2(TILE_SIZE, TILE_SIZE)
	match field_type:
		"fire_field": rect.color = Color(1.0, 0.3, 0.0, 0.5)
		"poison_field": rect.color = Color(0.0, 0.8, 0.0, 0.5)
		"energy_field": rect.color = Color(0.3, 0.3, 1.0, 0.5)
		"magic_wall": rect.color = Color(0.8, 0.8, 1.0, 0.7)
		_: rect.color = Color(1.0, 0.5, 0.0, 0.5)
	field_node.add_child(rect)

## Server removes a persistent field from a tile.
@rpc("any_peer")
func rpc_field_despawn(x: int, y: int, _z: int) -> void:
	var node_name := "Field_%d_%d_%d" % [x, y, _z]
	_magic_walls.erase(Vector3i(x, y, _z))
	var existing: Node = _world.get_node_or_null(node_name)
	if existing != null:
		existing.queue_free()

## Server triggers area effects on all tiles in a pattern (monster abilities).
@rpc("any_peer")
func rpc_area_effect(effect_name: String, x: int, y: int, _z: int, _pattern: String, _facing: int) -> void:
	# Handled via individual rpc_tile_effect calls instead
	pass

## Server spawns a projectile flying from source to destination tile.
@rpc("any_peer")
func rpc_projectile(sx: int, sy: int, dx: int, dy: int, proj_type: String) -> void:
	combat.handle_projectile(sx, sy, dx, dy, proj_type)

## Server notifies a spell cast failed (shows exhaust poof).
@rpc("any_peer")
func rpc_spell_fail(peer_id: int) -> void:
	combat.handle_spell_fail(peer_id)

## Server sends the list of active status conditions (combat, haste, etc.).
@rpc("any_peer")
func rpc_status_update(statuses: Array) -> void:
	ui.update_status_icons(statuses)

## Server sends the remaining food timer in seconds.
@rpc("any_peer")
func rpc_food_timer(seconds: float) -> void:
	ui.update_food_timer(seconds)

## Server responds to a login attempt with success/failure.
@rpc("any_peer")
func rpc_login_result(success: bool, message: String) -> void:
	auth.handle_login_result(success, message)

## Server sends the list of characters for the logged-in account.
@rpc("any_peer")
func rpc_character_list(characters: Array) -> void:
	auth.handle_character_list(characters)

## Server sends updated outfit sprites and colors for a player.
@rpc("any_peer")
func rpc_outfit_update(peer_id: int, _outfit_id: String, sprites_json: String, head: String, body: String, legs: String, feet: String) -> void:
	var eid := -peer_id
	players.handle_outfit_update(eid, sprites_json, head, body, legs, feet)

## Server sends updated skill levels and progress percentages.
@rpc("any_peer")
func rpc_skills_update(skills: Array) -> void:
	ui.update_skills(skills)

## Server confirms logout -- returns to character select.
@rpc("any_peer")
func rpc_logout_result() -> void:
	auth.handle_logout_result()

## Server sends the player's inventory contents.
@rpc("any_peer")
func rpc_inventory_update(items: Array) -> void:
	inventory.handle_inventory_update(items)

## Server sends the player's equipped items.
@rpc("any_peer")
func rpc_equipment_update(data: Array) -> void:
	inventory.handle_equipment_update(data)
	ui.update_equipment(data)

## Server notifies a ground item appeared or disappeared at a tile.
@rpc("any_peer")
func rpc_ground_item(x: int, y: int, z: int, item_id: String, count: int, present: bool, sprite: String = "") -> void:
	inventory.handle_ground_item(x, y, z, item_id, count, present, sprite)

## Server sends a chunk of map tile data.
@rpc("any_peer")
func rpc_map_chunk(cx: int, cy: int, cz: int, tiles: Array) -> void:
	map.handle_map_chunk(cx, cy, cz, tiles)
	# Only invalidate visibility if this chunk is on or above player's z-level
	# (affects roof detection). Skip for distant z-levels.
	if cz >= _current_z:
		_last_process_tile = Vector2i(-9999, -9999)

## Server updates a single tile on the map.
@rpc("any_peer")
func rpc_tile_update(x: int, y: int, z: int, tile_id: int) -> void:
	map.handle_tile_update(x, y, z, tile_id)

## Server spawns a container (corpse, chest) in the world.
@rpc("any_peer")
func rpc_container_spawn(cid: int, x: int, y: int, z: int, display_name: String, sprite: String = "", is_corpse: bool = false) -> void:
	containers.handle_container_spawn(cid, x, y, z, display_name, sprite, is_corpse)

## Server removes a container from the world.
@rpc("any_peer")
func rpc_container_despawn(cid: int) -> void:
	containers.handle_container_despawn(cid)

## Server updates a container's sprite.
@rpc("any_peer")
func rpc_container_sprite(cid: int, sprite_path: String) -> void:
	containers.handle_container_sprite_update(cid, sprite_path)

## Server opens a container window with its item contents.
@rpc("any_peer")
func rpc_container_open(cid: int, display_name: String, items: Array, capacity: int = -1, sprite: String = "") -> void:
	ui.open_container(cid, display_name, items, capacity, sprite)

## Server closes a container window.
@rpc("any_peer")
func rpc_container_close(cid: int) -> void:
	ui.close_container(cid)

## Server moves a container to a new world position.
@rpc("any_peer")
func rpc_container_move(cid: int, x: int, y: int, z: int) -> void:
	containers.handle_container_move(cid, x, y, z)

## Server sends NPC dialogue text.
@rpc("any_peer")
func rpc_npc_dialogue(npc_name: String, text: String) -> void:
	ui.receive_chat("npc", npc_name, text)

## Server spawns an NPC in the world.
@rpc("any_peer")
func rpc_npc_spawn(npc_id: int, display_name: String, x: int, y: int, z: int, sprite_json: String = "") -> void:
	entities.handle_npc_spawn(npc_id, display_name, x, y, z, sprite_json)

## Server removes an NPC from the world.
@rpc("any_peer")
func rpc_npc_despawn(npc_id: int) -> void:
	entities.handle_npc_despawn(npc_id)

## Server moves an NPC to a new tile.
@rpc("any_peer")
func rpc_npc_move(npc_id: int, x: int, y: int, _z: int, step_ms: int) -> void:
	entities.handle_npc_move(npc_id, x, y, step_ms)

## Server opens a shop -- displays offers in chat.
@rpc("any_peer")
func rpc_shop_open(npc_name: String, offers: Array) -> void:
	var header := "--- %s's Shop ---" % npc_name
	ui.receive_chat("npc", npc_name, header)
	for offer in offers:
		if offer is Array and offer.size() >= 4:
			var item_name: String = str(offer[1])
			var buy_price: int = int(offer[2])
			var sell_price: int = int(offer[3])
			var line := "  %s -- Buy: %d gp, Sell: %d gp" % [item_name, buy_price, sell_price]
			ui.receive_chat("npc", npc_name, line)
	var footer := "Use /buy <item> <count> or /sell <item> <count>"
	ui.receive_chat("npc", npc_name, footer)


#  CLIENT -> SERVER RPC STUBS (Godot needs these for signature registration)

## Stub: client sends movement direction to server.
@rpc("any_peer")
func rpc_move_direction(_dx: int, _dy: int) -> void:
	pass

## Stub: client sends a chat message to server.
@rpc("any_peer")
func rpc_send_chat(_channel: String, _text: String) -> void:
	pass

## Stub: client requests to attack an entity.
@rpc("any_peer")
func rpc_attack_request(_entity_id: int) -> void:
	pass

## Stub: client requests to attack another player (PVP).
@rpc("any_peer")
func rpc_attack_player(_target_peer_id: int) -> void:
	pass

## Stub: client requests to use/interact with a tile.
@rpc("any_peer")
func rpc_use_tile(_x: int, _y: int, _z: int) -> void:
	pass

## Stub: client takes an item from a container slot.
@rpc("any_peer")
func rpc_container_take(_cid: int, _index: int) -> void:
	pass

## Stub: client drops a container item to the ground.
@rpc("any_peer")
func rpc_container_drop_to_ground(_cid: int, _index: int, _x: int, _y: int, _z: int) -> void:
	pass

## Stub: client puts an inventory item into a container.
@rpc("any_peer")
func rpc_container_put(_cid: int, _inv_index: int) -> void:
	pass

## Stub: client moves a ground item into a container.
@rpc("any_peer")
func rpc_ground_to_container(_cid: int, _x: int, _y: int, _z: int, _item_id: String) -> void:
	pass

## Stub: client moves a container to a new ground position.
@rpc("any_peer")
func rpc_move_container(_cid: int, _x: int, _y: int, _z: int) -> void:
	pass

## Stub: client picks up a container from the ground.
@rpc("any_peer")
func rpc_pickup_ground_container(_cid: int) -> void:
	pass

## Stub: client requests to close a container.
@rpc("any_peer")
func rpc_container_close_request(_cid: int) -> void:
	pass

## Stub: client requests to open their backpack.
@rpc("any_peer")
func rpc_open_backpack() -> void:
	pass

## Stub: client opens a nested container inside another container.
@rpc("any_peer")
func rpc_open_item_in_container(_parent_cid: int, _slot_index: int) -> void:
	pass

## Stub: client moves an item between containers/equipment/ground.
@rpc("any_peer")
func rpc_move_item(_from_uid: int, _from_index: int, _to_uid: int, _to_index: int,
		_to_x: int, _to_y: int, _to_z: int, _count: int, _slot_name: String) -> void:
	pass

## Stub: client buys an item from a shop.
@rpc("any_peer")
func rpc_shop_buy(_item_id: String, _count: int) -> void:
	pass

## Stub: client sells an item to a shop.
@rpc("any_peer")
func rpc_shop_sell(_item_id: String, _count: int) -> void:
	pass

## Stub: client requests respawn after death.
@rpc("any_peer")
func rpc_request_respawn() -> void:
	pass

## Stub: client turns in place without moving.
@rpc("any_peer")
func rpc_turn_direction(_direction: int) -> void:
	pass

## Stub: client registers a new account.
@rpc("any_peer")
func rpc_register(_username: String, _password: String) -> void:
	pass

## Stub: client logs in with credentials.
@rpc("any_peer")
func rpc_login(_username: String, _password: String) -> void:
	pass

## Stub: client requests logout.
@rpc("any_peer")
func rpc_logout() -> void:
	pass

## Stub: client selects a character from the character list.
@rpc("any_peer")
func rpc_select_character(_char_id: int) -> void:
	pass

## Stub: client creates a new character.
@rpc("any_peer")
func rpc_create_character(_character_name: String, _vocation: String = "none", _gender: String = "male") -> void:
	pass

## Stub: client picks up a ground item.
@rpc("any_peer")
func rpc_pickup_item(_x: int, _y: int, _z: int, _item_id: String) -> void:
	pass

## Stub: client drops an inventory item at their feet.
@rpc("any_peer")
func rpc_drop_item(_slot_index: int) -> void:
	pass

## Stub: client drops an inventory item at a specific tile.
@rpc("any_peer")
func rpc_drop_item_at(_slot_index: int, _x: int, _y: int, _z: int) -> void:
	pass

## Stub: client moves a ground item to another tile.
@rpc("any_peer")
func rpc_move_ground_item(_sx: int, _sy: int, _sz: int, _item_id: String, _dx: int, _dy: int, _dz: int, _count: int = 0) -> void:
	pass

## Stub: client equips an inventory item.
@rpc("any_peer")
func rpc_equip_item(_slot_index: int) -> void:
	pass

## Stub: client unequips an item from a slot.
@rpc("any_peer")
func rpc_unequip_item(_slot_name: String) -> void:
	pass

## Stub: client casts a spell by ID.
@rpc("any_peer")
func rpc_cast_spell(_spell_id: String) -> void:
	pass

## Stub: client uses an inventory item (food, potions, etc.).
@rpc("any_peer")
func rpc_use_item(_slot_index: int) -> void:
	pass

## Stub: client uses a rune on a target tile.
@rpc("any_peer")
func rpc_use_rune(_slot_index: int, _target_x: int, _target_y: int, _target_z: int) -> void:
	pass

## Stub: client changes outfit appearance and colors.
@rpc("any_peer")
func rpc_change_outfit(_outfit_id: String, _head: String, _body: String, _legs: String, _feet: String) -> void:
	pass

## Stub: client performs a drag-and-drop operation between UI elements.
@rpc("any_peer")
func rpc_drag_drop(_source_type: String, _source_index: int, _source_slot: String,
		_dest_type: String, _dest_index: int, _dest_slot: String,
		_dest_x: int, _dest_y: int, _dest_z: int) -> void:
	pass
