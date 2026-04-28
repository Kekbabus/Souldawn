#  server_tile_actions.gd -- Tile action handling (stairs, teleports, doors)
#
#  Loads action definitions from datapacks/tile_actions/*.json
#  Checks step-on triggers after player movement
#  Handles teleport, level_change, use_teleport action types
extends Node

const TILE_ACTION_PATHS := [
	"res://datapacks/tile_actions/stairs_teleports.json",
	"res://datapacks/tile_actions/doors.json",
]

var server: Node = null  # server_main.gd

var _actions: Dictionary = {}  # int action_id -> Dictionary {type, dx, dy, dz, message, ...}


## Loads all tile action definition files listed in TILE_ACTION_PATHS.
func load_actions() -> void:
	for path in TILE_ACTION_PATHS:
		_load_action_file(path)
	print("server_tile_actions: loaded %d action definitions" % _actions.size())


## Loads action definitions from a single JSON file into _actions.
func _load_action_file(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("server_tile_actions: Failed to open '%s'" % path)
		return
	var json := JSON.new()
	var err := json.parse(file.get_as_text())
	file.close()
	if err != OK:
		push_error("server_tile_actions: Failed to parse '%s' -- %s" % [path, json.get_error_message()])
		return
	var data = json.data
	if not data is Dictionary:
		return
	for key in data:
		# Skip comment keys
		if str(key).begins_with("_"):
			continue
		if not str(key).is_valid_int():
			continue
		var action_id: int = int(key)
		var def = data[key]
		if not def is Dictionary:
			continue
		_actions[action_id] = def


#  STEP-ON CHECK -- called after each player move

## Checks if the player stepped on a tile with an action. Returns true if teleported.
func check_step_on(peer_id: int, pos: Vector3i) -> bool:
	var action_id: int = server.map.get_action_id(pos)
	if action_id < 0:
		return false
	if not _actions.has(action_id):
		return false
	var action: Dictionary = _actions[action_id]
	var action_type: String = str(action.get("type", ""))

	match action_type:
		"teleport":
			return _execute_teleport(peer_id, pos, action)
		"level_change":
			return _execute_level_change(peer_id, pos, action)
	return false


## Handles use-action (right-click on tile). Returns true if handled.
func check_use_action(peer_id: int, pos: Vector3i) -> bool:
	var action_id: int = server.map.get_action_id(pos)
	if action_id < 0:
		return false
	if not _actions.has(action_id):
		return false
	var action: Dictionary = _actions[action_id]
	var action_type: String = str(action.get("type", ""))

	match action_type:
		"use_teleport":
			return _execute_teleport(peer_id, pos, action)
		"door_toggle":
			return _execute_door_toggle(peer_id, pos, action_id, action)
		"transform":
			return _execute_door_toggle(peer_id, pos, action_id, action)
	return false


## Teleports the player by the action's dx/dy/dz offset. Sends chunks if z changed.
func _execute_teleport(peer_id: int, pos: Vector3i, action: Dictionary) -> bool:
	if not server._sessions.has(peer_id):
		return false
	var s: Dictionary = server._sessions[peer_id]
	var dx: int = int(action.get("dx", 0))
	var dy: int = int(action.get("dy", 0))
	var dz: int = int(action.get("dz", 0))
	var dest := Vector3i(pos.x + dx, pos.y + dy, pos.z + dz)

	# Check destination is walkable
	if server.map.is_blocking(dest):
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "You cannot go there.")
		return false

	var message: String = str(action.get("message", ""))

	# Move player
	s["position"] = dest
	s["walk_dir"] = Vector2i.ZERO
	server.grid_update(peer_id, dest)

	# Send new position to player (teleport = instant snap)
	server.rpc_id(peer_id, "rpc_player_teleport", peer_id, dest.x, dest.y, dest.z)

	# If z-level changed, send new chunks and entities
	if dz != 0:
		server.chunks.send_initial_chunks(peer_id, dest)
		server.entities.send_entities_on_z(peer_id, dest.z)

	# Broadcast to nearby players on both floors
	for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
		if pid != peer_id:
			server.rpc_id(pid, "rpc_player_move", peer_id, dest.x, dest.y, dest.z)
	for pid in server.get_players_in_range(dest, server.NEARBY_RANGE):
		if pid != peer_id:
			server.rpc_id(pid, "rpc_player_move", peer_id, dest.x, dest.y, dest.z)

	if not message.is_empty():
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", message)
	return true


## Handles a level change (stairs up/down) by computing exit offset and delegating to teleport.
func _execute_level_change(peer_id: int, pos: Vector3i, action: Dictionary) -> bool:
	if not server._sessions.has(peer_id):
		return false
	var direction: String = str(action.get("direction", ""))
	var dz: int = 1 if direction == "up" else -1
	var exit_dir: String = str(action.get("exit_direction", "south"))

	# Calculate exit offset based on direction
	var dx: int = 0
	var dy: int = 0
	match exit_dir:
		"north": dy = -1
		"south": dy = 1
		"east": dx = 1
		"west": dx = -1

	var dest := Vector3i(pos.x + dx, pos.y + dy, pos.z + dz)
	var teleport_action := {
		"dx": dx, "dy": dy, "dz": dz,
		"message": str(action.get("message", "")),
	}
	return _execute_teleport(peer_id, pos, teleport_action)


## Toggles a door/transform tile: swaps the tile_id and action_id, pushes player if needed.
func _execute_door_toggle(peer_id: int, pos: Vector3i, current_action_id: int, action: Dictionary) -> bool:
	var target_action_id: int = int(action.get("target_action_id", 0))
	if target_action_id <= 0:
		return false

	# Find the tile_id for the target state using action_id_to_tile_id mapping
	var target_tile_id: int = server.map.get_tile_id_for_action(target_action_id)
	if target_tile_id <= 0:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "The door won't budge.")
		return false

	# If the open door has a push_dir, push the player out of the way
	var push_dir: String = str(action.get("push_dir", ""))
	if not push_dir.is_empty() and server._sessions.has(peer_id):
		var s: Dictionary = server._sessions[peer_id]
		var pp: Vector3i = s["position"]
		if pp == pos:
			var push_offset := _dir_to_offset(push_dir)
			var push_dest := Vector3i(pos.x + push_offset.x, pos.y + push_offset.y, pos.z)
			if not server.is_tile_blocked(push_dest, peer_id):
				s["position"] = push_dest
				server.grid_update(peer_id, push_dest)
				server.rpc_id(peer_id, "rpc_player_teleport", peer_id, push_dest.x, push_dest.y, push_dest.z)

	# Swap the tile in the map
	server.map.swap_tile_action(pos, current_action_id, target_action_id, target_tile_id)

	# Broadcast tile update to nearby clients
	for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
		server.rpc_id(pid, "rpc_tile_update", pos.x, pos.y, pos.z, target_tile_id)

	return true


## Converts a cardinal direction string ("north", "south", etc.) to a Vector2i offset.
func _dir_to_offset(dir: String) -> Vector2i:
	match dir:
		"north": return Vector2i(0, -1)
		"south": return Vector2i(0, 1)
		"east": return Vector2i(1, 0)
		"west": return Vector2i(-1, 0)
	return Vector2i.ZERO
