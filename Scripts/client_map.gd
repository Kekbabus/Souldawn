#  client_map.gd -- Server-driven tile map renderer.
#
#  Builds a tile_id -> {source_id, atlas_coords} lookup from TileSet resources.
#  Creates TileMapLayer nodes programmatically per stack-layer per z-level.
#  Manages floor visibility and roof detection for multi-level maps.
extends Node

const CHUNK_SIZE := 16
const TILE_SIZE := 32
const ROOF_CHECK_RADIUS := 4

const TILESET_PATHS := [
	"res://datapacks/tilesCustom_tileset.tres",
	"res://datapacks/tilesTrees_tileset.tres",
	"res://datapacks/tilesCustom_walls.tres",
]

var client: Node2D = null

var _tile_lookup: Dictionary = {}   # int tile_id -> Dictionary
var _tilesets: Array = []           # loaded TileSet resources

var _tile_stacks: Dictionary = {}   # Vector3i -> Array[int]
var _chunks_received: int = 0
var _tile_defs: Dictionary = {}     # int tile_id -> {walkable, ground_speed}

var _floor_nodes: Dictionary = {}   # int z -> Node2D
var _layer_maps: Dictionary = {}    # "z_layer" -> TileMapLayer
var _rendered_chunks: Dictionary = {} # "cx_cy_cz" -> bool

var _current_z: int = 7
var _last_vis_tile := Vector2i(-9999, -9999)
var _last_vis_z: int = -1
var _player_covered: bool = false


#  INITIALIZATION -- build tile_id -> {tileset, source_id, atlas_coords}

## Loads all TileSet resources and builds the tile_id -> atlas info lookup table.
func build_tile_lookup() -> void:
	for path in TILESET_PATHS:
		if not ResourceLoader.exists(path):
			push_warning("client_map: TileSet not found at %s" % path)
			continue
		var tileset: TileSet = load(path) as TileSet
		if tileset == null:
			continue
		_tilesets.append(tileset)
		_scan_tileset(tileset)
	print("client_map: built tile lookup -- %d tile_ids mapped from %d tilesets" % [
		_tile_lookup.size(), _tilesets.size()])
	_load_tile_defs()


## Loads tile walkability data from terrain_tiles.json for client-side blocking checks.
func _load_tile_defs() -> void:
	var file := FileAccess.open("res://datapacks/tiles/terrain_tiles.json", FileAccess.READ)
	if file == null:
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK or not json.data is Array:
		file.close()
		return
	for entry in json.data:
		if not entry is Dictionary:
			continue
		var tid: int = int(entry.get("tile_id", 0))
		if tid <= 0:
			continue
		_tile_defs[tid] = {"walkable": bool(entry.get("walkable", true))}
	file.close()


## Returns true if the tile at pos blocks movement (void or non-walkable tile in stack).
func is_blocking(pos: Vector3i) -> bool:
	if not _tile_stacks.has(pos):
		return true  # void = can't walk
	for entry in _tile_stacks[pos]:
		var tid: int = int(entry[0]) if entry is Array else int(entry)
		var def: Dictionary = _tile_defs.get(tid, {})
		if not def.is_empty() and not bool(def.get("walkable", true)):
			return true
	return false


## Resolves the correct z-level for dropping an item at (x, y) from the player's z.
## Resolves the correct z-level for dropping an item at (x, y) from the player's z.
func resolve_drop_z(_x: int, _y: int, player_z: int) -> int:
	return player_z


## Scans a single TileSet for atlas sources and maps tile_id custom data to atlas coords.
func _scan_tileset(tileset: TileSet) -> void:
	for src_idx in range(tileset.get_source_count()):
		var source_id: int = tileset.get_source_id(src_idx)
		var source = tileset.get_source(source_id)
		if not source is TileSetAtlasSource:
			continue
		var atlas: TileSetAtlasSource = source as TileSetAtlasSource
		var grid := atlas.get_atlas_grid_size()
		for r in range(grid.y):
			for c in range(grid.x):
				var coords := Vector2i(c, r)
				if not atlas.has_tile(coords):
					continue
				# Scan base tile and all alternative tiles
				var alt_count: int = atlas.get_alternative_tiles_count(coords)
				for alt_idx in range(alt_count):
					var alt_id: int = atlas.get_alternative_tile_id(coords, alt_idx)
					var td := atlas.get_tile_data(coords, alt_id)
					if td == null:
						continue
					var raw_tid = td.get_custom_data("tile_id")
					if not (raw_tid is int) or raw_tid <= 0:
						continue
					if _tile_lookup.has(raw_tid):
						continue
					_tile_lookup[int(raw_tid)] = {
						"tileset": tileset,
						"source_id": source_id,
						"atlas_coords": coords,
						"alt_tile": alt_id,
					}


#  CHUNK RECEPTION & RENDERING

## Receives a chunk of tile data from the server, stores it, and renders it.
func handle_map_chunk(cx: int, cy: int, cz: int, tiles: Array) -> void:
	var origin_x: int = cx * CHUNK_SIZE
	var origin_y: int = cy * CHUNK_SIZE
	for entry in tiles:
		if not entry is Array or entry.size() < 3:
			continue
		var lx: int = int(entry[0])
		var ly: int = int(entry[1])
		var stack = entry[2]
		if not stack is Array:
			continue
		# Store stack as-is (entries can be int or [int, int])
		_tile_stacks[Vector3i(origin_x + lx, origin_y + ly, cz)] = stack
	_chunks_received += 1
	_render_chunk(cx, cy, cz, tiles)
	# Force floor visibility re-check since new tile data may affect roof detection
	_last_vis_tile = Vector2i(-9999, -9999)


## Returns (or creates) the parent Node2D for all layers on a given z-level.
func _get_floor_node(z: int) -> Node2D:
	if _floor_nodes.has(z):
		return _floor_nodes[z]
	var node := Node2D.new()
	node.name = "Floor_Z%d" % z
	if z < _current_z:
		node.z_index = -(_current_z - z) * 100
		node.visible = false
	elif z > _current_z:
		node.z_index = (z - _current_z) * 100
	else:
		node.z_index = 0
	client._world.add_child(node)
	_floor_nodes[z] = node
	return node


## Public accessor for the floor node at a given z-level.
func get_floor_node(z: int) -> Node2D:
	return _get_floor_node(z)


## Returns (or creates) the TileMapLayer for a specific z-level and stack layer index.
## Layers are inserted in child order (not z_index) to match editor hierarchy behavior.
func _get_layer_map(z: int, layer_idx: int) -> TileMapLayer:
	var key := "%d_%d" % [z, layer_idx]
	if _layer_maps.has(key):
		return _layer_maps[key]
	var floor_node: Node2D = _get_floor_node(z)
	var tml := TileMapLayer.new()
	tml.name = "Layer_%d" % layer_idx
	# Don't set z_index — rely on child order like the editor does.
	# Insert at the correct position so layers stay sorted by index.
	var insert_pos: int = floor_node.get_child_count()
	for i in range(floor_node.get_child_count()):
		var sibling: Node = floor_node.get_child(i)
		# Parse the layer index from sibling name "Layer_X" or "Layer_X_tsY"
		var sname: String = sibling.name
		if sname.begins_with("Layer_"):
			var parts: PackedStringArray = sname.substr(6).split("_")
			var sibling_idx: int = int(parts[0])
			if sibling_idx > layer_idx:
				insert_pos = i
				break
	floor_node.add_child(tml)
	if insert_pos < floor_node.get_child_count() - 1:
		floor_node.move_child(tml, insert_pos)
	_layer_maps[key] = tml
	return tml


## Places tiles from a chunk into the appropriate TileMapLayer nodes via set_cell().
func _render_chunk(cx: int, cy: int, cz: int, tiles: Array) -> void:
	var chunk_key := "%d_%d_%d" % [cx, cy, cz]
	if _rendered_chunks.has(chunk_key):
		return
	_rendered_chunks[chunk_key] = true

	var origin_x: int = cx * CHUNK_SIZE
	var origin_y: int = cy * CHUNK_SIZE

	for entry in tiles:
		if not entry is Array or entry.size() < 3:
			continue
		var lx: int = int(entry[0])
		var ly: int = int(entry[1])
		var stack = entry[2]
		if not stack is Array or stack.is_empty():
			continue
		var world_x: int = origin_x + lx
		var world_y: int = origin_y + ly
		var cell := Vector2i(world_x, world_y)

		for layer_idx in range(stack.size()):
			var tile_entry = stack[layer_idx]
			var tid: int = 0
			var alt_tile: int = 0
			if tile_entry is Array and tile_entry.size() >= 2:
				tid = int(tile_entry[0])
				alt_tile = int(tile_entry[1])
			else:
				tid = int(tile_entry)
			if tid <= 0:
				continue
			if not _tile_lookup.has(tid):
				continue
			var info: Dictionary = _tile_lookup[tid]
			var tileset: TileSet = info["tileset"] as TileSet
			var source_id: int = info["source_id"]
			var atlas_coords: Vector2i = info["atlas_coords"]
			var final_alt: int = int(info.get("alt_tile", 0))
			if alt_tile != 0:
				final_alt = alt_tile

			var tml: TileMapLayer = _get_layer_map(cz, layer_idx)
			if tml.tile_set == null:
				tml.tile_set = tileset
			elif tml.tile_set != tileset:
				var ts_key := "%d_%d_%d" % [cz, layer_idx, tileset.get_instance_id()]
				if not _layer_maps.has(ts_key):
					var extra_tml := TileMapLayer.new()
					extra_tml.name = "Layer_%d_ts%d" % [layer_idx, tileset.get_instance_id()]
					extra_tml.tile_set = tileset
					var floor_node: Node2D = _get_floor_node(cz)
					# Insert right after the primary layer for this index
					var primary_tml: TileMapLayer = _get_layer_map(cz, layer_idx)
					var insert_at: int = primary_tml.get_index() + 1
					floor_node.add_child(extra_tml)
					floor_node.move_child(extra_tml, mini(insert_at, floor_node.get_child_count() - 1))
					_layer_maps[ts_key] = extra_tml
				tml = _layer_maps[ts_key]

			tml.set_cell(cell, source_id, atlas_coords, final_alt)


#  FLOOR VISIBILITY

## Sets the active z-level and forces a visibility re-check on next update.
func set_current_z(z: int) -> void:
	_current_z = z
	_last_vis_tile = Vector2i(-9999, -9999)


## Shows/hides floor nodes based on the player's z-level and roof coverage.
func update_floor_visibility(player_pixel_pos: Vector2, player_z: int) -> void:
	var player_tile := Vector2i(
		int(floor(player_pixel_pos.x / TILE_SIZE)),
		int(floor(player_pixel_pos.y / TILE_SIZE)))
	if player_tile == _last_vis_tile and player_z == _last_vis_z:
		return
	_last_vis_tile = player_tile
	_last_vis_z = player_z
	_player_covered = _is_covered(player_tile, player_z)

	for z in _floor_nodes:
		var node: Node2D = _floor_nodes[z]
		var floor_z: int = int(z)
		if floor_z == player_z:
			node.visible = true
			node.modulate = Color.WHITE
			node.z_index = 0
		elif floor_z > player_z:
			if _player_covered:
				node.visible = false
			else:
				node.visible = true
				node.modulate = Color.WHITE
				node.z_index = (floor_z - player_z) * 100
		else:
			# Lower floors: show tiles but dimmed (Tibia-style see-through)
			node.visible = true
			node.modulate = Color(0.6, 0.6, 0.6, 1.0)
			node.z_index = -(player_z - floor_z) * 100


## Returns true if any tile exists above the player within ROOF_CHECK_RADIUS.
func _is_covered(tile_pos: Vector2i, player_z: int) -> bool:
	for dx in range(-ROOF_CHECK_RADIUS, ROOF_CHECK_RADIUS + 1):
		for dy in range(-ROOF_CHECK_RADIUS, ROOF_CHECK_RADIUS + 1):
			var check_x: int = tile_pos.x + dx
			var check_y: int = tile_pos.y + dy
			for z in _floor_nodes:
				if int(z) <= player_z:
					continue
				if _tile_stacks.has(Vector3i(check_x, check_y, int(z))):
					return true
	return false


#  QUERIES & CLEANUP

## Returns the tile stack array at the given world position, or empty.
func get_tile_stack(pos: Vector3i) -> Array:
	return _tile_stacks.get(pos, [])

func handle_tile_update(x: int, y: int, z: int, tile_id: int) -> void:
	## Server changed a tile (door opened/closed). Update the top tile.
	var pos := Vector3i(x, y, z)
	if not _tile_lookup.has(tile_id):
		return
	var info: Dictionary = _tile_lookup[tile_id]
	var tileset: TileSet = info["tileset"] as TileSet
	var source_id: int = info["source_id"]
	var atlas_coords: Vector2i = info["atlas_coords"]
	var alt: int = int(info.get("alt_tile", 0))

	# Update stored tile stack -- replace top entry
	if _tile_stacks.has(pos):
		var stack: Array = _tile_stacks[pos]
		if stack.size() > 0:
			stack[stack.size() - 1] = tile_id

	# Find the highest layer TileMapLayer for this z and update the cell
	# Doors are typically on the wall layer (highest layer index with a tile at this pos)
	var best_key := ""
	var best_idx := -1
	for key in _layer_maps:
		if not key.begins_with("%d_" % z):
			continue
		var parts: PackedStringArray = key.split("_")
		if parts.size() >= 2:
			var layer_idx: int = int(parts[1])
			var tml: TileMapLayer = _layer_maps[key]
			if tml.tile_set == tileset or tml.tile_set == null:
				if layer_idx > best_idx:
					# Check if this layer has a cell at this position
					if tml.get_cell_source_id(Vector2i(x, y)) != -1 or layer_idx > best_idx:
						best_idx = layer_idx
						best_key = key

	if best_key.is_empty():
		return
	var tml: TileMapLayer = _layer_maps[best_key]
	if tml.tile_set != tileset:
		return
	tml.set_cell(Vector2i(x, y), source_id, atlas_coords, alt)

## Returns true if any tile data exists at the given world position.
func has_tile(pos: Vector3i) -> bool:
	return _tile_stacks.has(pos)

## Frees all tile data, TileMapLayer nodes, and floor nodes.
func clear() -> void:
	_tile_stacks.clear()
	_chunks_received = 0
	_rendered_chunks.clear()
	for key in _layer_maps:
		if is_instance_valid(_layer_maps[key]):
			_layer_maps[key].queue_free()
	_layer_maps.clear()
	for z in _floor_nodes:
		if is_instance_valid(_floor_nodes[z]):
			_floor_nodes[z].queue_free()
	_floor_nodes.clear()
	_last_vis_tile = Vector2i(-9999, -9999)
	_last_vis_z = -1
