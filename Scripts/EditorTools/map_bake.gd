@tool

extends Node2D

@export var output_path: String = "res://Data/Maps/testMap.map.json"
@export var map_name: String = "Souldawn"
@export var author: String = "Kebabus"
@export var tile_size: int = 32

@export var bake_now: bool = false:
	set(value):
		if value and Engine.is_editor_hint():
			_run_bake()
		bake_now = false


func _run_bake() -> void:
	print("map_bake: starting bake...")

	var layers_data: Array = []
	var all_spawn_points: Array = []
	var action_id_to_tile_id: Dictionary = {}

	# Iterate through Floor_X containers
	for floor_node in get_children():
		# Collect spawn points from any node with to_spawn_dict
		if floor_node.has_method("to_spawn_dict"):
			all_spawn_points.append(floor_node.to_spawn_dict())
			continue

		if not floor_node is Node2D:
			continue

		var z_level: int = _extract_z_from_name(floor_node.name)

		# Merge all TileMapLayer children of this floor into one sparse tile set
		# Key: "x,y" -> Array of tile_ids (stack, bottom to top)
		var action_id_layer: Dictionary = {}

		# Collect tiles from each layer, preserving layer order
		# Each layer gets a fixed index: Ground=0, misc=1, misc2=2, Notwalkable=3, Walls=4, Trees=5
		var layer_tiles: Dictionary = {}  # layer_idx -> Dictionary of "x,y" -> stack_entry
		var layer_idx := 0

		for child in floor_node.get_children():
			# Check for spawner nodes inside floor containers
			if child.has_method("to_spawn_dict"):
				var sp: Dictionary = child.to_spawn_dict()
				sp["z"] = z_level
				all_spawn_points.append(sp)
				continue

			if not child is TileMapLayer:
				print("map_bake: skipping '%s' (class: %s) — not TileMapLayer" % [child.name, child.get_class()])
				continue

			var layer: TileMapLayer = child as TileMapLayer
			var used_cells: Array = layer.get_used_cells()
			print("map_bake: processing layer '%s' (idx=%d) — %d cells" % [layer.name, layer_idx, used_cells.size()])

			var this_layer: Dictionary = {}

			for cell in used_cells:
				var cell_v: Vector2i = cell
				var source_id: int = layer.get_cell_source_id(cell_v)
				if source_id < 0:
					continue

				var alt_tile: int = layer.get_cell_alternative_tile(cell_v)

				var tile_data: TileData = layer.get_cell_tile_data(cell_v)
				if tile_data == null:
					continue

				var tile_id = tile_data.get_custom_data("tile_id")
				if not (tile_id is int) or tile_id <= 0:
					continue

				var tileset: TileSet = layer.tile_set
				if tileset != null:
					for i in range(tileset.get_custom_data_layers_count()):
						if tileset.get_custom_data_layer_name(i) == "action_id":
							var action_val = tile_data.get_custom_data("action_id")
							if action_val is int and action_val > 0:
								var key := "%d,%d" % [cell_v.x, cell_v.y]
								action_id_layer[key] = action_val
								action_id_to_tile_id[str(action_val)] = tile_id
							break

				var stack_entry = tile_id
				if alt_tile > 0:
					stack_entry = [tile_id, alt_tile]

				var pos_key := "%d,%d" % [cell_v.x, cell_v.y]
				this_layer[pos_key] = {"x": cell_v.x, "y": cell_v.y, "entry": stack_entry}

			layer_tiles[layer_idx] = this_layer
			layer_idx += 1

		# Merge all layers into stacks, preserving layer order
		# Collect all unique positions
		var all_positions: Dictionary = {}
		for lidx in layer_tiles:
			for pos_key in layer_tiles[lidx]:
				if not all_positions.has(pos_key):
					all_positions[pos_key] = layer_tiles[lidx][pos_key]

		var sparse_tiles: Array = []
		for pos_key in all_positions:
			var ref = all_positions[pos_key]
			var stack: Array = []
			for lidx in range(layer_idx):
				if layer_tiles.has(lidx) and layer_tiles[lidx].has(pos_key):
					stack.append(layer_tiles[lidx][pos_key]["entry"])
			if not stack.is_empty():
				sparse_tiles.append({"x": ref["x"], "y": ref["y"], "stack": stack})

		if sparse_tiles.is_empty():
			print("map_bake: floor '%s' (z=%d) — no tiles, skipping" % [floor_node.name, z_level])
			continue

		var layer_dict: Dictionary = {
			"z_level": z_level,
			"format": "sparse",
			"width": 0,
			"height": 0,
			"sparse_tiles": sparse_tiles,
		}
		if not action_id_layer.is_empty():
			layer_dict["action_id_layer"] = action_id_layer

		layers_data.append(layer_dict)
		print("map_bake: floor '%s' (z=%d) — %d tiles, %d actions" % [
			floor_node.name, z_level, sparse_tiles.size(), action_id_layer.size()])

	# Build final map data
	var map_data: Dictionary = {
		"name": map_name,
		"author": author,
		"layers": layers_data,
		"spawn_points": all_spawn_points,
		"action_id_to_tile_id": action_id_to_tile_id,
	}

	# Write to file
	var json_str := JSON.stringify(map_data, "\t")
	var file := FileAccess.open(output_path, FileAccess.WRITE)
	if file:
		file.store_string(json_str)
		file.close()
		var total_tiles: int = 0
		for l in layers_data:
			total_tiles += l["sparse_tiles"].size()
		print("map_bake: DONE — saved to %s (%d layers, %d tiles, %d spawns)" % [
			output_path, layers_data.size(), total_tiles, all_spawn_points.size()])
	else:
		push_error("map_bake: failed to write to %s" % output_path)


func _extract_z_from_name(node_name: String) -> int:
	var regex := RegEx.new()
	regex.compile("(\\d+)")
	var result := regex.search(node_name)
	if result:
		return int(result.get_string())
	return 7
