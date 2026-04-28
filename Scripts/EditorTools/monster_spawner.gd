@tool
## Monster Spawner — Place in the world scene to define a monster spawn point.
## Snaps to tile grid. Shows spawn radius as a square.
## Dropdown menu for monster selection from datapacks/monsters/*.json
extends Marker2D

const TILE_SIZE := 32

## definition_id is exposed via _get_property_list() as a dropdown — do NOT use @export
var definition_id: String = "bug":
	set(v):
		definition_id = v
		queue_redraw()
@export var spawn_count: int = 1
@export var spawn_radius: int = 3:
	set(v):
		spawn_radius = v
		queue_redraw()
@export var respawn_seconds: int = 30
@export var leash_distance: int = 10
@export var z_level: int = 7

func _get_property_list() -> Array:
	# Build dropdown hint from monster JSON files
	var monster_names := _scan_monster_ids()
	var hint_string := ",".join(monster_names)
	return [
		{
			"name": "definition_id",
			"type": TYPE_STRING,
			"hint": PROPERTY_HINT_ENUM,
			"hint_string": hint_string,
			"usage": PROPERTY_USAGE_DEFAULT | PROPERTY_USAGE_SCRIPT_VARIABLE,
		}
	]

func _scan_monster_ids() -> Array:
	var ids: Array = []
	var dir := DirAccess.open("res://datapacks/monsters")
	if dir == null:
		return ["bug"]
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			ids.append(fname.get_basename())
		fname = dir.get_next()
	ids.sort()
	return ids

func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(true)
		_snap_to_grid()
		queue_redraw()

func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		_snap_to_grid()

func _snap_to_grid() -> void:
	var half := TILE_SIZE / 2.0
	var grid_pos := Vector2(
		floorf((position.x - half) / TILE_SIZE) * TILE_SIZE + half,
		floorf((position.y - half) / TILE_SIZE) * TILE_SIZE + half)
	if not position.is_equal_approx(grid_pos):
		position = grid_pos

func _draw() -> void:
	if Engine.is_editor_hint():
		var center := Vector2(TILE_SIZE / 2.0, TILE_SIZE / 2.0)
		draw_circle(center, 4, Color(1, 0, 0, 0.8))
		var half := float(spawn_radius) * TILE_SIZE
		var rect := Rect2(center.x - half, center.y - half, half * 2, half * 2)
		draw_rect(rect, Color(1, 0, 0, 0.15), true)
		draw_rect(rect, Color(1, 0, 0, 0.5), false, 1.0)
		draw_string(ThemeDB.fallback_font, Vector2(0, -4), definition_id, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color.RED)

func to_spawn_dict(tile_size: int = 32) -> Dictionary:
	return {
		"definition_id": definition_id,
		"x": int(floor(position.x / tile_size)),
		"y": int(floor(position.y / tile_size)),
		"z": z_level,
		"spawn_count": spawn_count,
		"spawn_radius": spawn_radius,
		"respawn_seconds": respawn_seconds,
		"leash_distance": leash_distance,
		"spawn_effect": "spawn_default",
	}
