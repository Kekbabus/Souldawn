@tool

extends Marker2D

const TILE_SIZE := 32

## definition_id is exposed via _get_property_list() as a dropdown — do NOT use @export
var definition_id: String = "oracle":
	set(v):
		definition_id = v
		queue_redraw()
@export var display_name: String = "Oracle"
@export var wander_radius: int = 0:
	set(v):
		wander_radius = v
		queue_redraw()
@export var z_level: int = 7

@export_group("Outfit")
## outfit_id is exposed via _get_property_list() as a dropdown — do NOT use @export
var outfit_id: String = "citizen_male"
@export var head_color: Color = Color("#ffff00")
@export var body_color: Color = Color("#4d80ff")
@export var legs_color: Color = Color("#4d80ff")
@export var feet_color: Color = Color("#996633")

func _get_property_list() -> Array:
	var npc_names := _scan_npc_ids()
	var outfit_names := _scan_outfit_ids()
	var props: Array = []
	# Only override definition_id and outfit_id for dropdown hints
	# Other @export properties (colors, etc.) are handled normally
	props.append({
		"name": "definition_id",
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": ",".join(npc_names),
		"usage": PROPERTY_USAGE_DEFAULT | PROPERTY_USAGE_SCRIPT_VARIABLE,
	})
	props.append({
		"name": "outfit_id",
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": ",".join(outfit_names),
		"usage": PROPERTY_USAGE_DEFAULT | PROPERTY_USAGE_SCRIPT_VARIABLE,
	})
	return props

func _scan_npc_ids() -> Array:
	var ids: Array = []
	var dir := DirAccess.open("res://datapacks/npcs")
	if dir == null:
		return ["oracle"]
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			ids.append(fname.get_basename())
		fname = dir.get_next()
	ids.sort()
	return ids

func _scan_outfit_ids() -> Array:
	var ids: Array = []
	var dir := DirAccess.open("res://datapacks/outfits")
	if dir == null:
		return ["citizen_male"]
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
		draw_circle(center, 4, Color(0, 0.5, 1, 0.8))
		if wander_radius > 0:
			var half := float(wander_radius) * TILE_SIZE
			var rect := Rect2(center.x - half, center.y - half, half * 2, half * 2)
			draw_rect(rect, Color(0, 0.5, 1, 0.1), true)
			draw_rect(rect, Color(0, 0.5, 1, 0.4), false, 1.0)
		draw_string(ThemeDB.fallback_font, Vector2(0, -4), display_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0, 0.5, 1))

func to_spawn_dict(tile_size: int = 32) -> Dictionary:
	var color_str := "%s,%s,%s,%s" % [head_color.to_html(false), body_color.to_html(false), legs_color.to_html(false), feet_color.to_html(false)]
	var d: Dictionary = {
		"definition_id": definition_id,
		"display_name": display_name,
		"x": int(floor(position.x / tile_size)),
		"y": int(floor(position.y / tile_size)),
		"z": z_level,
		"respawn_seconds": 10,
		"spawn_radius": 0,
		"spawn_effect": "spawn_default",
		"wander_radius": wander_radius,
	}
	if not outfit_id.is_empty():
		d["outfit_id"] = outfit_id
	d["outfit_color"] = color_str
	return d
