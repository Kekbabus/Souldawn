
@tool
extends Node
class_name TileDefExporter


#  CONSTANTS

const MAP_ROOT_PATH := "Main/World/Map"

## Default values for missing TileSet custom data fields
const DEFAULT_WALKABLE := true
const DEFAULT_BLOCKS_PROJECTILES := false
const DEFAULT_SPEED_MODIFIER := 0
const DEFAULT_GROUND_SPEED := 150.0


#  EXPORTED PROPERTIES (Inspector)

@export var output_path: String = "res://datapacks/tiles/terrain_tiles.json"

@export var export_now: bool = false:
	set(value):
		if value and Engine.is_editor_hint():
			export_now = false
			_run_export()


#  EXPORT ENTRY POINT

## Executes the full export pipeline: finds map root, scans TileSet atlases,
## builds terrain Item_Definitions, and writes the JSON output file.
func _run_export() -> void:
	# Step 1: Find map root
	var map_root := _find_map_root()
	if map_root == null:
		return

	# Step 2: Collect all TileMapLayers under the map root
	var layers := _collect_tilemaplayers(map_root)
	if layers.is_empty():
		printerr("TileDefExporter: No TileMapLayers found under map root. Aborting export.")
		return

	# Step 3: Scan all TileSet atlases for unique tile_ids and their custom data
	var definitions := _scan_atlases(layers)
	if definitions.is_empty():
		printerr("TileDefExporter: No tile definitions found in TileSet atlases. Aborting export.")
		return

	# Step 4: Sort definitions by tile_id for deterministic output
	definitions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["tile_id"] < b["tile_id"]
	)

	# Step 5: Ensure output directory exists
	var dir_path := output_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var err := DirAccess.make_dir_recursive_absolute(dir_path)
		if err != OK:
			printerr("TileDefExporter: Failed to create output directory '%s'." % dir_path)
			return

	# Step 6: Write JSON array to output file
	if not _write_json(definitions, output_path):
		return

	# Step 7: Log summary
	print("TileDefExporter: Exported %d terrain tile definition%s to '%s'." % [
		definitions.size(),
		"s" if definitions.size() != 1 else "",
		output_path,
	])


#  SCENE TREE SCANNING

## Locates the Map node in the scene tree.
## Tries multiple strategies (same as BakeScript):
##   1. Sibling "Map" node (TileDefExporter is child of World, Map is sibling)
##   2. Absolute path Main/World/Map (running from server_main)
##   3. Absolute path World/Map (world scene opened directly)
## Returns null and prints an error if none found.
func _find_map_root() -> Node:
	# Strategy 1: Map is a sibling (most common when attached to World scene)
	var parent := get_parent()
	if parent:
		var sibling := parent.get_node_or_null("Map")
		if sibling:
			return sibling

	# Strategy 2: Absolute path from scene root (server_main context)
	var tree_root := get_tree().root
	var absolute := tree_root.get_node_or_null(MAP_ROOT_PATH)
	if absolute:
		return absolute

	# Strategy 3: World/Map (world scene opened directly in editor)
	var fallback := tree_root.get_node_or_null("World/Map")
	if fallback:
		return fallback

	printerr("TileDefExporter: Map root node not found. Tried sibling 'Map', '%s', and 'World/Map'. Aborting export." % MAP_ROOT_PATH)
	return null


## Recursively collects all TileMapLayer descendants under the given node
## in scene-tree child order (depth-first, index 0 first).
func _collect_tilemaplayers(node: Node) -> Array[TileMapLayer]:
	var result: Array[TileMapLayer] = []
	_gather_tilemaplayers(node, result)
	return result


## Internal recursive helper for _collect_tilemaplayers().
func _gather_tilemaplayers(node: Node, result: Array[TileMapLayer]) -> void:
	for child in node.get_children():
		if child is TileMapLayer:
			result.append(child)
		_gather_tilemaplayers(child, result)


#  TILESET ATLAS SCANNING

## Checks whether a TileSet has a custom data layer with the given name.
func _tileset_has_custom_data(tileset: TileSet, layer_name: String) -> bool:
	if tileset == null:
		return false
	for i in range(tileset.get_custom_data_layers_count()):
		if tileset.get_custom_data_layer_name(i) == layer_name:
			return true
	return false


## Scans all TileSet atlases across the given TileMapLayers and builds
## an array of terrain Item_Definition dictionaries — one per unique tile_id.
## Reads custom data fields (walkable, blocks_projectiles, speed_modifier,
## ground_speed) from TileData, using defaults for missing fields.
func _scan_atlases(layers: Array[TileMapLayer]) -> Array[Dictionary]:
	var seen_tile_ids: Dictionary = {}  # tile_id (int) → Item_Definition (Dictionary)
	var seen_tilesets: Array = []

	for layer in layers:
		var tileset: TileSet = layer.tile_set
		if tileset == null or tileset in seen_tilesets:
			continue
		seen_tilesets.append(tileset)

		# Check which custom data layers exist on this TileSet
		var has_walkable := _tileset_has_custom_data(tileset, "walkable")
		var has_blocks_proj := _tileset_has_custom_data(tileset, "blocks_projectiles")
		var has_speed_mod := _tileset_has_custom_data(tileset, "speed_modifier")
		var has_ground_speed := _tileset_has_custom_data(tileset, "ground_speed")

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
					var td := atlas.get_tile_data(coords, 0)
					if td == null:
						continue

					# Read tile_id — skip tiles without a valid tile_id
					var raw_tile_id = td.get_custom_data("tile_id")
					if not (raw_tile_id is int) or raw_tile_id <= 0:
						continue

					var tile_id: int = raw_tile_id

					# Skip if we already processed this tile_id
					if seen_tile_ids.has(tile_id):
						continue

					# Read custom data with defaults for missing fields
					var walkable: bool = DEFAULT_WALKABLE
					if has_walkable:
						var raw = td.get_custom_data("walkable")
						if raw is bool:
							walkable = raw

					var blocks_projectile: bool = DEFAULT_BLOCKS_PROJECTILES
					if has_blocks_proj:
						var raw = td.get_custom_data("blocks_projectiles")
						if raw is bool:
							blocks_projectile = raw

					var speed_modifier: int = DEFAULT_SPEED_MODIFIER
					if has_speed_mod:
						var raw = td.get_custom_data("speed_modifier")
						if raw is int:
							speed_modifier = raw

					var ground_speed: float = DEFAULT_GROUND_SPEED
					if has_ground_speed:
						var raw = td.get_custom_data("ground_speed")
						if raw is float or raw is int:
							ground_speed = float(raw)

					# Build Item_Definition
					var definition := {
						"definition_id": "terrain_%d" % tile_id,
						"display_name": "Terrain %d" % tile_id,
						"tile_id": tile_id,
						"terrain": true,
						"walkable": walkable,
						"blocks_projectile": blocks_projectile,
						"speed_modifier": speed_modifier,
						"ground_speed": ground_speed,
						"moveable": false,
						"pickupable": false,
					}

					seen_tile_ids[tile_id] = definition

	# Convert to array
	var result: Array[Dictionary] = []
	for tid in seen_tile_ids:
		result.append(seen_tile_ids[tid])
	return result


#  FILE WRITING

## Writes the given Array of Dictionaries as indented JSON to the specified path.
## Returns true on success, false on failure.
func _write_json(data: Array[Dictionary], path: String) -> bool:
	var json_string := JSON.stringify(data, "\t")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		var err := FileAccess.get_open_error()
		printerr("TileDefExporter: Failed to write '%s' — error code %d." % [path, err])
		return false
	file.store_string(json_string)
	file.close()
	return true
