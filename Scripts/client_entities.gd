#  client_entities.gd -- Monster/NPC rendering, movement animation, damage
#  numbers, targeting outlines, and z-level visibility
extends Node

const TILE_SIZE := 32
const DEFAULT_GROUND_SPEED := 150.0
const ANIM_SPEEDUP := 1.0
const DAMAGE_FLOAT_DURATION := 1.5
const DAMAGE_FLOAT_DISTANCE := 40.0  # Pixels to float up in screen space

var client: Node2D = null  # client_main.gd

var _entities: Dictionary = {}  # entity_id → entity data Dictionary
var _npcs: Dictionary = {}      # npc_id → {node, z_level}
var _target_entity_id: int = -1

# HUD-layer damage numbers: Array of { "label": Label, "world_pos": Vector2, "start_y": float }
var _floating_numbers: Array = []
var _damage_number_scene: PackedScene = null
var _xp_number_scene: PackedScene = null


## Frees all entity and NPC nodes, overlays, and resets targeting.
func cleanup_all() -> void:
	for eid in _entities:
		var data: Dictionary = _entities[eid]
		if data.has("node") and is_instance_valid(data["node"]):
			data["node"].queue_free()
		client.ui.unregister_entity_overlay("entity_%d" % eid)
	_entities.clear()
	for nid in _npcs:
		var npc: Dictionary = _npcs[nid]
		if npc.has("node") and is_instance_valid(npc["node"]):
			npc["node"].queue_free()
		client.ui.unregister_entity_overlay("npc_%d" % nid)
	_npcs.clear()
	_target_entity_id = -1
	_floating_numbers.clear()


## Spawns a monster/entity Node2D with sprites, health bar overlay, and animation data.
func handle_entity_spawn(eid: int, _definition_id: String, display_name: String,
		x: int, y: int, z: int, health: int, max_health: int, speed: int, sprites_json: String = "") -> void:
	if _entities.has(eid):
		return
	var node := Node2D.new()
	node.name = "Entity_%d" % eid
	node.position = Vector2(x * TILE_SIZE, y * TILE_SIZE)
	node.z_index = 4

	# Parse sprites data and preload textures
	var sprite_textures: Dictionary = {}
	var has_sprites := false
	var idle_animated := false
	if not sprites_json.is_empty():
		var json := JSON.new()
		if json.parse(sprites_json) == OK and json.data is Dictionary:
			var sprites_data: Dictionary = json.data
			# Load idle textures — supports single path or array of frames
			var idle: Dictionary = sprites_data.get("idle", {})
			for dir_name in idle:
				var val = idle[dir_name]
				if val is Array:
					# Animated idle — multiple frames
					for i in range(val.size()):
						var path: String = str(val[i])
						if not path.is_empty() and ResourceLoader.exists(path):
							sprite_textures["idle_%s_%d" % [dir_name, i]] = load(path)
							has_sprites = true
							idle_animated = true
				else:
					var path: String = str(val)
					if not path.is_empty() and ResourceLoader.exists(path):
						sprite_textures["idle_" + dir_name] = load(path)
						has_sprites = true
			# Load walk textures
			var walk: Dictionary = sprites_data.get("walk", {})
			for dir_name in walk:
				var frames = walk[dir_name]
				if frames is Array:
					for i in range(frames.size()):
						var path: String = str(frames[i])
						if not path.is_empty() and ResourceLoader.exists(path):
							sprite_textures["walk_%s_%d" % [dir_name, i]] = load(path)

	# Create the sprite node
	if has_sprites:
		var sprite := Sprite2D.new()
		sprite.name = "Sprite"
		sprite.centered = false
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		var default_tex: Texture2D = sprite_textures.get("idle_south", sprite_textures.get("idle_south_0", null))
		if default_tex == null:
			for key in sprite_textures:
				default_tex = sprite_textures[key]
				break
		if default_tex:
			sprite.texture = default_tex
			# Don't scale — keep native size. Offset so bottom-right aligns with tile.
			var tex_size := default_tex.get_size()
			sprite.position = Vector2(TILE_SIZE - tex_size.x, TILE_SIZE - tex_size.y)
		node.add_child(sprite)
	else:
		var sprite := ColorRect.new()
		sprite.name = "Sprite"
		sprite.size = Vector2(TILE_SIZE, TILE_SIZE)
		sprite.color = Color.INDIAN_RED
		node.add_child(sprite)

	var label_placeholder := Node2D.new()
	label_placeholder.name = "NameLabel"
	node.add_child(label_placeholder)

	client._world.add_child(node)

	# Register HUD overlay for name + health bar (crisp rendering)
	var overlay_key := "entity_%d" % eid
	client.ui.register_entity_overlay(overlay_key, node, display_name, Color(0.8, 0, 0))
	# Set initial health bar state
	client.ui.update_entity_overlay_health(overlay_key, health, max_health)

	var ent_speed := maxf(float(speed), 10.0)
	var step_duration_ms := ceilf(1000.0 * DEFAULT_GROUND_SPEED / ent_speed)
	var anim_duration_sec := (step_duration_ms / 1000.0) * ANIM_SPEEDUP
	var anim_speed := float(TILE_SIZE) / maxf(anim_duration_sec, 0.05)

	var mhp := max_health if max_health > 0 else 1
	_entities[eid] = {
		"node": node,
		"target_pos": node.position,
		"moving": false,
		"move_queue": [],
		"anim_speed": anim_speed,
		"display_name": display_name,
		"health": health,
		"max_health": mhp,
		"z_level": z,
		"sprite_textures": sprite_textures,
		"has_sprites": has_sprites,
		"idle_animated": idle_animated if has_sprites else false,
		"idle_frame": 0,
		"idle_timer": 0.0,
		"facing": "south",
		"walk_frame": 0,
		"walk_timer": 0.0,
	}
	_update_entity_health_bar(_entities[eid])
	# Visibility will be set by update_z_visibility called from client_main


## Queues a smooth tile-to-tile move for an entity, updating facing direction.
func handle_entity_move(eid: int, x: int, y: int, _z: int, step_ms: int = 0) -> void:
	if not _entities.has(eid):
		return
	var data: Dictionary = _entities[eid]
	var new_pixel := Vector2(x * TILE_SIZE, y * TILE_SIZE)
	# Determine facing direction from movement delta
	var cur_pixel: Vector2 = data["node"].position
	var dx: float = new_pixel.x - cur_pixel.x
	var dy: float = new_pixel.y - cur_pixel.y
	if absf(dy) >= absf(dx):
		data["facing"] = "north" if dy < 0 else "south"
	else:
		data["facing"] = "west" if dx < 0 else "east"
	# Update animation speed from step duration
	if step_ms > 0:
		var step_sec: float = float(step_ms) / 1000.0
		data["anim_speed"] = float(TILE_SIZE) / maxf(step_sec, 0.05)
	if data["moving"]:
		var queue: Array = data["move_queue"]
		if queue.size() >= 1:
			data["node"].position = data["target_pos"]
			data["moving"] = false
			queue.clear()
			_start_move(data, new_pixel)
		else:
			queue.append(new_pixel)
	else:
		_start_move(data, new_pixel)


## Updates an entity's facing direction without movement (e.g. when attacking).
func handle_entity_face(eid: int, direction: int) -> void:
	if not _entities.has(eid):
		return
	var data: Dictionary = _entities[eid]
	var dir_names := ["north", "east", "south", "west"]
	if direction >= 0 and direction < 4:
		data["facing"] = dir_names[direction]
	if not data["moving"]:
		_set_entity_sprite(data, "idle")


## Removes an entity from the world and clears targeting if it was the target.
func handle_entity_despawn(eid: int) -> void:
	if _entities.has(eid):
		client.ui.unregister_entity_overlay("entity_%d" % eid)
		_entities[eid]["node"].queue_free()
		_entities.erase(eid)
	if _target_entity_id == eid:
		_target_entity_id = -1


## Processes incoming damage: updates health bar, plays hit effect, shows floating number.
func handle_entity_damage(eid: int, damage: int, damage_type: String, health: int, max_health: int) -> void:
	if not _entities.has(eid):
		return
	var data: Dictionary = _entities[eid]
	var mhp := max_health if max_health > 0 else 1
	data["health"] = health
	data["max_health"] = mhp
	_update_entity_health_bar(data)
	# Don't show floating number for heals — just update the health bar
	if damage_type == "heal":
		return
	var world_pos: Vector2 = data["node"].position
	var creature_type: String = str(data.get("creature_type", "blood"))
	# Play hit/miss/blocked effect
	client.combat.play_hit_effect_on_entity(world_pos, damage, creature_type)
	# Play element-specific hit effect on the target (energy sparkle, fire burst, etc.)
	if damage > 0 and damage_type != "physical":
		client.combat.play_element_hit_effect(world_pos, damage_type)
	# Show floating damage number (only for actual hits, not misses)
	if damage > 0:
		_show_damage_number(data["node"], damage, damage_type)


## Sets the combat target and adds a red outline to the targeted entity.
func handle_combat_target(eid: int) -> void:
	_clear_target_outline()
	_target_entity_id = eid
	# Positive eid = entity (monster), negative eid = player
	var target_node: Node2D = null
	if eid > 0 and _entities.has(eid):
		target_node = _entities[eid]["node"]
	elif eid < 0 and client.players._players.has(eid):
		target_node = client.players._players[eid]["node"]
	if target_node != null:
		var outline := _create_target_outline()
		outline.name = "TargetOutline"
		target_node.add_child(outline)


## Clears the combat target and removes the red outline.
func handle_combat_clear() -> void:
	_clear_target_outline()
	_target_entity_id = -1


## Removes the target outline from the currently targeted entity or player.
func _clear_target_outline() -> void:
	if _target_entity_id > 0 and _entities.has(_target_entity_id):
		var old: Node = _entities[_target_entity_id]["node"].get_node_or_null("TargetOutline")
		if old != null:
			old.queue_free()
	elif _target_entity_id < 0 and client.players._players.has(_target_entity_id):
		var old: Node = client.players._players[_target_entity_id]["node"].get_node_or_null("TargetOutline")
		if old != null:
			old.queue_free()


## Creates a red border outline Node2D for the combat target indicator.
func _create_target_outline() -> Node2D:
	var outline := Node2D.new()
	outline.z_index = 19
	var thickness := 2
	var sz := TILE_SIZE
	for rect_data in [
		[Vector2(0, 0), Vector2(sz, thickness)],
		[Vector2(0, sz - thickness), Vector2(sz, thickness)],
		[Vector2(0, thickness), Vector2(thickness, sz - thickness * 2)],
		[Vector2(sz - thickness, thickness), Vector2(thickness, sz - thickness * 2)],
	]:
		var r := ColorRect.new()
		r.position = rect_data[0]
		r.size = rect_data[1]
		r.color = Color.RED
		outline.add_child(r)
	return outline


#  ENTITY ANIMATION

## Begins a smooth movement step toward a target pixel position.
func _start_move(data: Dictionary, new_pixel: Vector2) -> void:
	data["start_pos"] = data["node"].position
	data["target_pos"] = new_pixel
	data["moving"] = true
	data["step_count"] = int(data.get("step_count", 0)) + 1
	data["walk_frame"] = 0


const WALK_FRAME_INTERVAL := 0.15  # seconds between walk frame changes

## Advances all entity movement and idle animations per frame.
## Tibia 7.6 walk cycle: 2 walk frames, first half = frame 0, second half = frame 1.
func process_entity_animation(delta: float) -> void:
	for eid in _entities:
		var data: Dictionary = _entities[eid]
		if not data["moving"]:
			var queue: Array = data["move_queue"]
			if not queue.is_empty():
				_start_move(data, queue.pop_front())
			else:
				if data.get("idle_animated", false):
					data["idle_timer"] = float(data.get("idle_timer", 0.0)) + delta
					if float(data["idle_timer"]) >= 0.5:
						data["idle_timer"] = 0.0
						data["idle_frame"] = int(data.get("idle_frame", 0)) + 1
				_set_entity_sprite(data, "idle")
			continue
		var node: Node2D = data["node"]
		var target: Vector2 = data["target_pos"]
		var spd: float = data["anim_speed"]
		var distance := node.position.distance_to(target)
		if distance < spd * delta:
			node.position = Vector2(
				round(target.x / TILE_SIZE) * TILE_SIZE,
				round(target.y / TILE_SIZE) * TILE_SIZE)
			data["moving"] = false
			_set_entity_sprite(data, "idle")
			var queue: Array = data["move_queue"]
			if not queue.is_empty():
				_start_move(data, queue.pop_front())
		else:
			node.position += (target - node.position).normalized() * spd * delta
			var start_pos: Vector2 = data.get("start_pos", node.position)
			var total_dist: float = start_pos.distance_to(target)
			var progress: float = 1.0 - (distance / maxf(total_dist, 1.0))
			data["walk_frame"] = 0 if progress < 0.5 else 1
			_set_entity_sprite(data, "walk")


## Sets the correct idle or walk sprite texture based on facing direction and frame.
func _set_entity_sprite(data: Dictionary, mode: String) -> void:
	if not data.get("has_sprites", false):
		return
	var sprite_node: Node = data["node"].get_node_or_null("Sprite")
	if sprite_node == null or not sprite_node is Sprite2D:
		return
	var textures: Dictionary = data["sprite_textures"]
	var facing: String = data["facing"]
	var tex: Texture2D = null
	if mode == "walk":
		var frame: int = int(data["walk_frame"])
		# Count available walk frames for this direction
		var frame_count := 0
		while textures.has("walk_%s_%d" % [facing, frame_count]):
			frame_count += 1
		if frame_count > 0:
			tex = textures.get("walk_%s_%d" % [facing, frame % frame_count], null)
	if tex == null:
		# Check for animated idle frames (idle_south_0, idle_south_1, etc.)
		if data.get("idle_animated", false):
			var idle_frame: int = int(data.get("idle_frame", 0))
			var idle_count := 0
			while textures.has("idle_%s_%d" % [facing, idle_count]):
				idle_count += 1
			if idle_count > 0:
				tex = textures.get("idle_%s_%d" % [facing, idle_frame % idle_count], null)
		if tex == null:
			tex = textures.get("idle_" + facing, null)
	if tex == null:
		tex = textures.get("idle_south", textures.get("idle_south_0", null))
	if tex != null and sprite_node.texture != tex:
		sprite_node.texture = tex
		var tex_size := tex.get_size()
		sprite_node.scale = Vector2.ONE
		sprite_node.position = Vector2(TILE_SIZE - tex_size.x, TILE_SIZE - tex_size.y)


## Updates the HUD health bar overlay for an entity.
func _update_entity_health_bar(data: Dictionary) -> void:
	# Find the entity_id for this data to update the HUD overlay
	for eid in _entities:
		if _entities[eid] == data:
			var key := "entity_%d" % eid
			client.ui.update_entity_overlay_health(key, int(data["health"]), int(data["max_health"]))
			return


## Spawns a floating damage number label in the HUD layer above an entity.
func _show_damage_number(entity_node: Node2D, damage: int, damage_type: String) -> void:
	if _damage_number_scene == null:
		_damage_number_scene = load("res://Scenes/ui_damage_number.tscn")
	if _damage_number_scene == null:
		return

	var label: Label = _damage_number_scene.instantiate()
	label.text = str(damage)
	match damage_type:
		"fire":         label.add_theme_color_override("font_color", Color.ORANGE_RED)
		"poison":       label.add_theme_color_override("font_color", Color.GREEN)
		"energy":       label.add_theme_color_override("font_color", Color.CYAN)
		"heal":         label.add_theme_color_override("font_color", Color(0.2, 1.0, 0.2))
		"mana_shield":  label.add_theme_color_override("font_color", Color(0.3, 0.5, 1.0))
		_:              label.add_theme_color_override("font_color", Color.RED)
	if damage_type == "heal":
		label.text = "+%d" % damage
	elif damage_type == "mana_shield":
		label.text = "absorbed"

	# Add to HUD layer for crisp rendering
	var hud_layer: CanvasLayer = client.ui._hud_layer
	if hud_layer == null:
		label.queue_free()
		return
	hud_layer.add_child(label)

	# Store world position for per-frame tracking
	var world_pos: Vector2 = entity_node.position + Vector2(TILE_SIZE / 2.0, 0)
	var now: float = Time.get_ticks_msec() / 1000.0
	_floating_numbers.append({
		"label": label,
		"world_pos": world_pos,
		"offset_y": 0.0,
		"spawn_time": now,
		"expire_time": now + DAMAGE_FLOAT_DURATION,
	})


## Shows a floating white "+XP" number at the given world position.
func show_xp_number(world_pos: Vector2, amount: int) -> void:
	if _xp_number_scene == null:
		_xp_number_scene = load("res://Scenes/ui_xp_number.tscn")
	if _xp_number_scene == null:
		return
	var label: Label = _xp_number_scene.instantiate()
	label.text = "%d" % amount
	var hud_layer: CanvasLayer = client.ui._hud_layer
	if hud_layer == null:
		label.queue_free()
		return
	hud_layer.add_child(label)
	var now: float = Time.get_ticks_msec() / 1000.0
	_floating_numbers.append({
		"label": label,
		"world_pos": world_pos,
		"offset_y": -8.0,
		"spawn_time": now,
		"expire_time": now + DAMAGE_FLOAT_DURATION,
	})


## Called every frame from client_main._process() to update HUD positions.
func update_floating_numbers(delta: float) -> void:
	var game_vp: SubViewport = client.ui.get_game_viewport()
	if game_vp == null:
		return
	var canvas_xform := game_vp.get_canvas_transform()
	var gvc: Control = client.ui._hud.get_node_or_null("MainHBox/CenterColumn/GameViewportContainer")
	var gvc_offset := Vector2.ZERO
	if gvc:
		gvc_offset = gvc.global_position

	var now: float = Time.get_ticks_msec() / 1000.0
	var i: int = _floating_numbers.size() - 1
	while i >= 0:
		var entry: Dictionary = _floating_numbers[i]
		var label = entry.get("label")
		if label == null or not is_instance_valid(label):
			_floating_numbers.remove_at(i)
			i -= 1
			continue

		var expire: float = entry["expire_time"]
		if now >= expire:
			label.queue_free()
			_floating_numbers.remove_at(i)
			i -= 1
			continue

		# Float upward over time
		entry["offset_y"] -= DAMAGE_FLOAT_DISTANCE * delta / DAMAGE_FLOAT_DURATION
		# Fade based on remaining time
		var remaining: float = expire - now
		label.modulate.a = clampf(remaining / DAMAGE_FLOAT_DURATION, 0.0, 1.0)

		var world_pos: Vector2 = entry["world_pos"]
		var screen_pos: Vector2 = canvas_xform * world_pos + gvc_offset
		screen_pos.y += entry["offset_y"]
		label.position = Vector2(screen_pos.x - label.size.x / 2.0, screen_pos.y - label.size.y)
		i -= 1


## Returns the entity ID at the given tile position, or -1 if none found.
func get_entity_at_tile(tile_pos: Vector2i) -> int:
	for eid in _entities:
		var data: Dictionary = _entities[eid]
		var node: Node2D = data["node"]
		var cur_tile := Vector2i(
			int(round(node.position.x / TILE_SIZE)),
			int(round(node.position.y / TILE_SIZE)))
		if cur_tile == tile_pos:
			return eid
		var target: Vector2 = data.get("target_pos", node.position)
		var tgt_tile := Vector2i(
			int(round(target.x / TILE_SIZE)),
			int(round(target.y / TILE_SIZE)))
		if tgt_tile == tile_pos:
			return eid
	return -1


## Shows or hides entities and NPCs based on whether they share the current z-level.
func update_z_visibility(current_z: int) -> void:
	for eid in _entities:
		var data: Dictionary = _entities[eid]
		var same_floor: bool = (int(data.get("z_level", 7)) == current_z)
		data["node"].visible = same_floor
		if same_floor:
			data["node"].modulate = Color.WHITE
		# Hide/show overlay (name + health bar) based on floor
		var overlay_key := "entity_%d" % eid
		if client.ui._entity_overlays.has(overlay_key):
			client.ui._entity_overlays[overlay_key]["z_hidden"] = not same_floor
	for nid in _npcs:
		var npc: Dictionary = _npcs[nid]
		var same_floor: bool = (int(npc.get("z_level", 7)) == current_z)
		npc["node"].visible = same_floor
		if same_floor:
			npc["node"].modulate = Color.WHITE
		var overlay_key := "npc_%d" % nid
		if client.ui._entity_overlays.has(overlay_key):
			client.ui._entity_overlays[overlay_key]["z_hidden"] = not same_floor


#  NPC RENDERING (separate from monsters — no health bar, no targeting)

## Spawns an NPC Node2D with outfit sprites and a name-only HUD overlay (no health bar).
func handle_npc_spawn(npc_id: int, display_name: String, x: int, y: int, z: int, outfit_json: String = "") -> void:
	if _npcs.has(npc_id):
		return
	var node := Node2D.new()
	node.name = "NPC_%d" % npc_id
	node.position = Vector2(x * TILE_SIZE, y * TILE_SIZE)
	node.z_index = 4

	# Parse outfit sprites (same as players — raw PNG loading)
	var base_images: Dictionary = {}
	var mask_images: Dictionary = {}
	var sprite_textures: Dictionary = {}
	var has_outfit := false

	if not outfit_json.is_empty():
		var json := JSON.new()
		if json.parse(outfit_json) == OK and json.data is Dictionary:
			var loaded: Dictionary = client.players._load_outfit_images(json.data)
			base_images = loaded["base_images"]
			mask_images = loaded["mask_images"]
			has_outfit = loaded["has_outfit"]

	if has_outfit:
		var head_col := Color(1.0, 1.0, 0.0)
		var body_col := Color(0.3, 0.5, 1.0)
		var legs_col := Color(0.3, 0.5, 1.0)
		var feet_col := Color(0.6, 0.4, 0.2)
		sprite_textures = client.players._build_colorized_textures(base_images, mask_images,
			head_col, body_col, legs_col, feet_col)
		var sprite := Sprite2D.new()
		sprite.name = "Sprite"
		sprite.centered = false
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		var default_tex: Texture2D = sprite_textures.get("idle_south", null)
		if default_tex:
			sprite.texture = default_tex
			var tex_size := default_tex.get_size()
			sprite.position = Vector2(TILE_SIZE - tex_size.x, TILE_SIZE - tex_size.y)
		node.add_child(sprite)
	else:
		var sprite := ColorRect.new()
		sprite.name = "Sprite"
		sprite.size = Vector2(TILE_SIZE, TILE_SIZE)
		sprite.color = Color(0.2, 0.6, 1.0, 0.8)
		node.add_child(sprite)

	# Name label — handled by HUD overlay for crisp rendering
	client._world.add_child(node)

	# Register HUD overlay for NPC name (no health bar needed)
	var overlay_key := "npc_%d" % npc_id
	client.ui.register_entity_overlay(overlay_key, node, display_name, Color(0.4, 0.8, 1.0), false)
	_npcs[npc_id] = {
		"node": node,
		"display_name": display_name,
		"z_level": z,
		"target_pos": node.position,
		"moving": false,
		"anim_speed": float(TILE_SIZE) / 0.5,
		"sprite_textures": sprite_textures,
		"has_outfit": has_outfit,
		"facing": "south",
		"walk_frame": 0,
		"step_count": 0,
	}


## Removes an NPC from the world and frees its HUD overlay.
func handle_npc_despawn(npc_id: int) -> void:
	if _npcs.has(npc_id):
		client.ui.unregister_entity_overlay("npc_%d" % npc_id)
		_npcs[npc_id]["node"].queue_free()
		_npcs.erase(npc_id)


## Queues a smooth tile-to-tile move for an NPC, updating facing direction.
func handle_npc_move(npc_id: int, x: int, y: int, step_ms: int) -> void:
	if not _npcs.has(npc_id):
		return
	var npc: Dictionary = _npcs[npc_id]
	var new_pixel := Vector2(x * TILE_SIZE, y * TILE_SIZE)
	var cur_pixel: Vector2 = npc["node"].position
	var dx: float = new_pixel.x - cur_pixel.x
	var dy: float = new_pixel.y - cur_pixel.y
	if absf(dy) >= absf(dx):
		npc["facing"] = "north" if dy < 0 else "south"
	else:
		npc["facing"] = "west" if dx < 0 else "east"
	if step_ms > 0:
		npc["anim_speed"] = float(TILE_SIZE) / maxf(float(step_ms) / 1000.0, 0.05)
	npc["start_pos"] = npc["node"].position
	npc["target_pos"] = new_pixel
	npc["moving"] = true
	npc["step_count"] = int(npc.get("step_count", 0)) + 1
	npc["walk_frame"] = 0


## Advances all NPC movement animations per frame.
## Tibia walk cycle: walk_frame ? idle ? walk_frame per step.
func process_npc_animation(delta: float) -> void:
	for nid in _npcs:
		var npc: Dictionary = _npcs[nid]
		if not npc.get("moving", false):
			_set_npc_sprite(npc, "idle")
			continue
		var node: Node2D = npc["node"]
		var target: Vector2 = npc["target_pos"]
		var spd: float = npc.get("anim_speed", float(TILE_SIZE) / 0.5)
		var distance := node.position.distance_to(target)
		if distance < spd * delta:
			node.position = Vector2(
				round(target.x / TILE_SIZE) * TILE_SIZE,
				round(target.y / TILE_SIZE) * TILE_SIZE)
			npc["moving"] = false
			_set_npc_sprite(npc, "idle")
		else:
			node.position += (target - node.position).normalized() * spd * delta
			var start_pos: Vector2 = npc.get("start_pos", node.position)
			var total_dist: float = start_pos.distance_to(target)
			var progress: float = 1.0 - (distance / maxf(total_dist, 1.0))
			npc["walk_frame"] = 0 if progress < 0.5 else 1
			_set_npc_sprite(npc, "walk")


## Sets the correct idle or walk sprite texture for an NPC based on facing and frame.
func _set_npc_sprite(npc: Dictionary, mode: String) -> void:
	if not npc.get("has_outfit", false):
		return
	var sprite_node: Node = npc["node"].get_node_or_null("Sprite")
	if sprite_node == null or not sprite_node is Sprite2D:
		return
	var textures: Dictionary = npc["sprite_textures"]
	var facing: String = npc["facing"]
	var tex: Texture2D = null
	if mode == "walk":
		var frame: int = int(npc["walk_frame"])
		var frame_count := 0
		while textures.has("walk_%s_%d" % [facing, frame_count]):
			frame_count += 1
		if frame_count > 0:
			tex = textures.get("walk_%s_%d" % [facing, frame % frame_count], null)
	if tex == null:
		tex = textures.get("idle_" + facing, null)
	if tex == null:
		tex = textures.get("idle_south", null)
	if tex != null and sprite_node.texture != tex:
		sprite_node.texture = tex
		var tex_size := tex.get_size()
		sprite_node.scale = Vector2.ONE
		sprite_node.position = Vector2(TILE_SIZE - tex_size.x, TILE_SIZE - tex_size.y)
