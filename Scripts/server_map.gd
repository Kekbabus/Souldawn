#  server_map.gd -- Map loading, tile storage, walkability, and ground speed
#
#  Loads terrain_tiles.json for tile_id properties (walkable, ground_speed).
#  Loads .map.json for tile stacks, action_ids, spawn points, and
#  action_id <-> tile_id mappings used by door/teleport systems.
extends Node

const DEFAULT_GROUND_SPEED := 150.0

var server: Node = null  # server_main.gd

var _tile_defs: Dictionary = {}  # int tile_id -> {walkable, ground_speed, blocks_projectile}

var _tile_stacks: Dictionary = {}   # Vector3i -> Array[int] (tile_ids bottom-to-top)
var _action_ids: Dictionary = {}    # Vector3i -> int (action_id)
var _action_id_to_tile_id: Dictionary = {}  # String action_id -> int tile_id
var _spawn_points: Array = []       # Array of spawn point Dictionaries
var _map_name: String = ""


## Loads tile definitions (walkable, ground_speed, blocks_projectile) from a JSON file.
func load_tile_defs(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("server_map: Failed to open tile defs '%s'" % path)
		return
	var json := JSON.new()
	var err := json.parse(file.get_as_text())
	file.close()
	if err != OK:
		push_error("server_map: Failed to parse tile defs -- %s" % json.get_error_message())
		return
	var data = json.data
	if not data is Array:
		push_error("server_map: tile defs root is not an Array")
		return
	for entry in data:
		if not entry is Dictionary:
			continue
		var tid: int = int(entry.get("tile_id", 0))
		if tid <= 0:
			continue
		_tile_defs[tid] = {
			"walkable": bool(entry.get("walkable", true)),
			"ground_speed": float(entry.get("ground_speed", DEFAULT_GROUND_SPEED)),
			"blocks_projectile": bool(entry.get("blocks_projectile", false)),
		}
	print("server_map: loaded %d tile definitions" % _tile_defs.size())


## Loads the full map (tile stacks, action_ids, spawn points) from a .map.json file.
func load_map(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("server_map: Failed to open map '%s'" % path)
		return
	var json := JSON.new()
	var err := json.parse(file.get_as_text())
	file.close()
	if err != OK:
		push_error("server_map: Failed to parse map -- %s" % json.get_error_message())
		return
	var data: Dictionary = json.data
	_map_name = str(data.get("name", "unknown"))

	# Load action_id -> tile_id lookup
	var aid_map = data.get("action_id_to_tile_id", {})
	if aid_map is Dictionary:
		for key in aid_map:
			_action_id_to_tile_id[str(key)] = int(aid_map[key])

	# Load layers
	var layers = data.get("layers", [])
	if not layers is Array:
		push_error("server_map: 'layers' is not an Array")
		return
	var total_tiles := 0
	for layer in layers:
		if not layer is Dictionary:
			continue
		var z_level: int = int(layer.get("z_level", 7))
		var fmt: String = str(layer.get("format", "sparse"))
		if fmt == "sparse":
			total_tiles += _load_sparse_layer(layer, z_level)

		# Load action_id layer for this z-level
		var aid_layer = layer.get("action_id_layer", {})
		if aid_layer is Dictionary:
			for key in aid_layer:
				var parts: PackedStringArray = str(key).split(",")
				if parts.size() == 2:
					var ax: int = int(parts[0])
					var ay: int = int(parts[1])
					_action_ids[Vector3i(ax, ay, z_level)] = int(aid_layer[key])

	# Load spawn points
	var spawns = data.get("spawn_points", [])
	if spawns is Array:
		_spawn_points = spawns

	print("server_map: loaded map '%s' -- %d tiles, %d action_ids, %d spawn points" % [
		_map_name, total_tiles, _action_ids.size(), _spawn_points.size()])


## Parses a sparse tile layer and populates _tile_stacks. Returns the number of tiles loaded.
func _load_sparse_layer(layer: Dictionary, z_level: int) -> int:
	var tiles = layer.get("sparse_tiles", [])
	if not tiles is Array:
		return 0
	var count := 0
	for entry in tiles:
		if not entry is Dictionary:
			continue
		var x: int = int(entry.get("x", 0))
		var y: int = int(entry.get("y", 0))
		var stack = entry.get("stack", [])
		if not stack is Array or stack.is_empty():
			continue
		# Stack entries can be plain tile_id (int) or [tile_id, alt_tile] (array)
		# Server only needs tile_ids, not alt_tile transforms
		var parsed_stack: Array = []
		for tid in stack:
			if tid is Array and tid.size() >= 1:
				parsed_stack.append(tid)  # keep as-is for streaming to client
			else:
				parsed_stack.append(tid)
		_tile_stacks[Vector3i(x, y, z_level)] = parsed_stack
		count += 1
	return count


#  QUERIES -- used by server_main for movement validation

## Returns true if the position has no tile data (void/empty).
func is_void(pos: Vector3i) -> bool:
	return not _tile_stacks.has(pos)


## Returns true if the tile at this position blocks movement.
## A position is blocking if:
##   - It has no tiles (void)
##   - Any tile in the stack is non-walkable
func is_blocking(pos: Vector3i) -> bool:
	if not _tile_stacks.has(pos):
		return true  # void = can't walk
	var stack: Array = _tile_stacks[pos]
	for entry in stack:
		var tid: int = int(entry[0]) if entry is Array else int(entry)
		var def: Dictionary = _tile_defs.get(tid, {})
		if not def.is_empty() and not bool(def.get("walkable", true)):
			return true
	return false


## Returns the ground speed for a position (from the bottom tile in the stack).
## Falls back to DEFAULT_GROUND_SPEED if no data.
func get_ground_speed(pos: Vector3i) -> float:
	if not _tile_stacks.has(pos):
		return DEFAULT_GROUND_SPEED
	var stack: Array = _tile_stacks[pos]
	if stack.is_empty():
		return DEFAULT_GROUND_SPEED
	var bottom = stack[0]
	var bottom_tid: int = int(bottom[0]) if bottom is Array else int(bottom)
	var def: Dictionary = _tile_defs.get(bottom_tid, {})
	return float(def.get("ground_speed", DEFAULT_GROUND_SPEED))


## Returns the tile stack at a position, or empty array.
func get_tile_stack(pos: Vector3i) -> Array:
	return _tile_stacks.get(pos, [])


## Returns the action_id at a position, or -1 if none.
func get_action_id(pos: Vector3i) -> int:
	return _action_ids.get(pos, -1)


func get_tile_id_for_action(action_id: int) -> int:
	## Returns the tile_id mapped to an action_id, or -1.
	return _action_id_to_tile_id.get(str(action_id), -1)


func swap_tile_action(pos: Vector3i, old_action_id: int, new_action_id: int, new_tile_id: int) -> void:
	## Swaps the action_id and top tile at a position (for door toggles).
	_action_ids[pos] = new_action_id
	# Update the tile stack -- replace the top tile with the new one
	if _tile_stacks.has(pos):
		var stack: Array = _tile_stacks[pos]
		if stack.size() > 0:
			stack[stack.size() - 1] = new_tile_id


## Returns all spawn points from the map.
func get_spawn_points() -> Array:
	return _spawn_points


## Returns true if the position blocks projectiles.
func blocks_projectile(pos: Vector3i) -> bool:
	if not _tile_stacks.has(pos):
		return false
	var stack: Array = _tile_stacks[pos]
	for entry in stack:
		var tid: int = int(entry[0]) if entry is Array else int(entry)
		var def: Dictionary = _tile_defs.get(tid, {})
		if not def.is_empty() and bool(def.get("blocks_projectile", false)):
			return true
	return false
