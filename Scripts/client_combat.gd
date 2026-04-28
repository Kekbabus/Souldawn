#  client_combat.gd -- Spell effects, projectiles, hit/blood effects, death
#  overlay, respawn handling, and stats HUD
extends Node

const TILE_SIZE := 32

var client: Node2D = null  # client_main.gd

var _stats_label: Label = null
var _death_dialog: Node = null  # Scene-based death dialog

# Effect texture cache: effect_name → Array[Texture2D] (frames)
var _effect_cache: Dictionary = {}

# Loaded from datapacks/sprite_config.json
var _sprite_config: Dictionary = {}
var _effect_defs: Dictionary = {}
var _creature_hit_effects: Dictionary = {}
var _projectile_defs: Dictionary = {}
var _spell_effects: Dictionary = {}
var _projectile_size: int = 16
var _blood_spill_duration: float = 60.0
var _spawn_effect: String = "blueshimmer"

# Persistent blood spills on tiles
var _blood_spills: Array = []

# Cache: "type_direction" → Texture2D
var _projectile_cache: Dictionary = {}


## Call once at startup to load sprite_config.json.
func load_sprite_config() -> void:
	var file := FileAccess.open("res://datapacks/sprite_config.json", FileAccess.READ)
	if file == null:
		push_warning("client_combat: sprite_config.json not found, using defaults")
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) == OK and json.data is Dictionary:
		_sprite_config = json.data
	file.close()
	_effect_defs = _sprite_config.get("effects", {})
	_creature_hit_effects = _sprite_config.get("creature_hit_effects", {})
	_projectile_defs = _sprite_config.get("projectiles", {})
	_spell_effects = _sprite_config.get("spell_effects", {})
	_projectile_size = int(_sprite_config.get("projectile_size", 16))
	_blood_spill_duration = float(_sprite_config.get("blood_spill_duration_seconds", 60.0))
	_spawn_effect = str(_sprite_config.get("spawn_effect", "blueshimmer"))
	print("client_combat: loaded sprite_config — %d effects, %d projectiles" % [
		_effect_defs.size(), _projectile_defs.size()])


## Creates the legacy stats HUD label on a CanvasLayer (replaced by sidebar).
func setup_stats_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "StatsLayer"
	layer.layer = 10
	layer.visible = false
	client.add_child(layer)
	_stats_label = Label.new()
	_stats_label.name = "StatsLabel"
	_stats_label.text = "HP: --/--  |  MP: --/--  |  Lv: 1  |  XP: 0/200  |  F1:Heal F2:Exori"
	_stats_label.position = Vector2(8, 8)
	_stats_label.add_theme_font_size_override("font_size", 14)
	_stats_label.add_theme_color_override("font_color", Color.WHITE)
	_stats_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_stats_label.add_theme_constant_override("outline_size", 2)
	layer.add_child(_stats_label)


## No-op — death dialog is created on demand when the player dies.
func setup_death_overlay() -> void:
	# Death dialog is created on demand when player dies
	pass


## Processes incoming damage to a player: updates health, plays hit effect, shows number.
func handle_player_damage(eid: int, damage: int, damage_type: String, health: int, max_health: int) -> void:
	if client.players._players.has(eid):
		var data: Dictionary = client.players._players[eid]
		var mhp := max_health if max_health > 0 else 1
		data["health"] = health
		data["max_health"] = mhp
		client.players.update_player_health_bar(data)
		var world_pos: Vector2 = data["node"].position
		if damage_type == "mana_shield":
			# Mana shield absorbed all damage -- show mana shield effect
			play_effect_at_tile("mana_shield_effect",
				int(world_pos.x / TILE_SIZE), int(world_pos.y / TILE_SIZE))
			# Show "absorbed" as a blue damage number even though damage is 0
			client.entities._show_damage_number(data["node"], 0, "mana_shield")
		else:
			# Normal hit -- blood effect
			play_hit_effect_on_entity(world_pos, damage, "blood")
			if damage > 0 and damage_type != "physical":
				play_element_hit_effect(world_pos, damage_type)
			if damage > 0:
				client.entities._show_damage_number(data["node"], damage, damage_type)


## Marks the local player as dead, hides their sprite, and shows the death dialog.
func handle_player_death(xp_loss: int) -> void:
	client._is_dead = true
	# Hide local player sprite
	if client.players._players.has(client._local_entity_id):
		var data: Dictionary = client.players._players[client._local_entity_id]
		data["node"].visible = false
	# Show scene-based death dialog
	_show_death_dialog(xp_loss)


## Restores the local player after respawn: repositions, restores health, hides death dialog.
func handle_respawn_result(x: int, y: int, _z: int, health: int, max_health: int) -> void:
	client._is_dead = false
	_hide_death_dialog()
	if client.players._players.has(client._local_entity_id):
		var data: Dictionary = client.players._players[client._local_entity_id]
		data["node"].visible = true
		var new_pixel := Vector2(x * TILE_SIZE, y * TILE_SIZE)
		data["node"].position = new_pixel
		data["target_pos"] = new_pixel
		data["moving"] = false
		data["move_queue"] = []
		data["health"] = health
		data["max_health"] = max_health
		client.players.update_player_health_bar(data)


## Instantiates and shows the death dialog scene with respawn/logout buttons.
func _show_death_dialog(xp_loss: int) -> void:
	_hide_death_dialog()
	var scene := load("res://Scenes/ui_death_dialog.tscn")
	if scene == null:
		push_warning("client_combat: could not load death dialog scene")
		return
	_death_dialog = scene.instantiate()
	client.add_child(_death_dialog)
	# Set message text
	var msg_label: Label = _death_dialog.get_node_or_null("Overlay/Panel/VBox/Message")
	if msg_label:
		msg_label.text = "You lost %d experience points." % xp_loss
	# Wire Ok button → respawn
	var ok_btn: Button = _death_dialog.get_node_or_null("Overlay/Panel/VBox/ButtonRow/OkButton")
	if ok_btn:
		ok_btn.pressed.connect(func():
			client.rpc_id(1, "rpc_request_respawn")
		)
	# Wire Cancel button → back to character select (logout)
	var cancel_btn: Button = _death_dialog.get_node_or_null("Overlay/Panel/VBox/ButtonRow/CancelButton")
	if cancel_btn:
		cancel_btn.pressed.connect(func():
			client.rpc_id(1, "rpc_logout")
		)


## Frees the death dialog if it exists.
func _hide_death_dialog() -> void:
	if _death_dialog != null and is_instance_valid(_death_dialog):
		_death_dialog.queue_free()
		_death_dialog = null


## Updates the legacy stats label and local player health bar from server data.
func handle_stats_update(health: int, max_health: int, mana: int, max_mana: int, level: int, xp: int, xp_next: int) -> void:
	if _stats_label != null:
		_stats_label.text = "HP: %d/%d  |  MP: %d/%d  |  Lv: %d  |  XP: %d/%d" % [
			health, max_health, mana, max_mana, level, xp, xp_next]
	if client.players._players.has(client._local_entity_id):
		var data: Dictionary = client.players._players[client._local_entity_id]
		data["health"] = health
		data["max_health"] = max_health
		client.players.update_player_health_bar(data)


## Plays an exhaust poof effect on the caster when a spell fails.
func handle_spell_fail(caster_peer_id: int) -> void:
	var eid := -caster_peer_id
	if client.players._players.has(eid):
		var node: Node2D = client.players._players[eid]["node"]
		_play_effect_at(node.position, "exhaust")


## Dispatches spell visual effects based on spell_id (heals, strikes, beams, areas).
func handle_spell_effect(caster_peer_id: int, spell_id: String, x: int, y: int, _z: int, value: int) -> void:
	var effect_name: String = _spell_effects.get(spell_id, "")
	var world_pos := Vector2(x * TILE_SIZE, y * TILE_SIZE)

	match spell_id:
		"exura", "exura ico", "exura san", "exura gran", "exura vita":
			# Heal — play effect on caster + floating heal number
			var eid := -caster_peer_id
			if client.players._players.has(eid):
				var node: Node2D = client.players._players[eid]["node"]
				_play_effect_at(node.position, effect_name)
				# Floating heal number (uses HUD-layer floating number system)
				if value > 0:
					client.entities._show_damage_number(node, value, "heal")

		"exori", "exori gran":
			# Melee area — play effect on adjacent tiles around caster
			_play_effect_at(world_pos, "hit_physical")
			# Also play on the 1-tile-deep area in front
			var facing: int = value
			for offset in range(-1, 2):
				var tx := 0; var ty := 0
				match facing:
					0: tx = offset; ty = -1
					1: tx = 1; ty = offset
					2: tx = offset; ty = 1
					3: tx = -1; ty = offset
				_play_effect_at(world_pos + Vector2(tx * TILE_SIZE, ty * TILE_SIZE), "hit_physical")

		"exori vis", "exori flam", "exori tera", "exori frigo", "exori san":
			# Strike — play effect on the 1 tile in front of caster
			var facing: int = value
			var dx := 0; var dy := 0
			match facing:
				0: dy = -1
				1: dx = 1
				2: dy = 1
				3: dx = -1
			_play_effect_at(world_pos + Vector2(dx * TILE_SIZE, dy * TILE_SIZE), effect_name if not effect_name.is_empty() else "energy_effect")

		"exevo vis lux", "exevo vis hur", "exevo tera hur":
			# Beam/wave — play effect on each tile in the line
			var facing: int = value
			var length := 5
			for step in range(1, length + 1):
				var tx := 0; var ty := 0
				match facing:
					0: ty = -step
					1: tx = step
					2: ty = step
					3: tx = -step
				_play_effect_at(world_pos + Vector2(tx * TILE_SIZE, ty * TILE_SIZE), effect_name if not effect_name.is_empty() else "energy_effect")

		"exevo gran mas flam":
			# Area — play fire effect on tiles around caster
			for dx in range(-3, 4):
				for dy in range(-3, 4):
					if dx == 0 and dy == 0:
						continue
					_play_effect_at(world_pos + Vector2(dx * TILE_SIZE, dy * TILE_SIZE), "fire_effect")

		"utani hur":
			# Haste — text label on caster
			var eid := -caster_peer_id
			if client.players._players.has(eid):
				var node: Node2D = client.players._players[eid]["node"]
				_play_effect_at(node.position, "blueshimmer")
				var lbl := Label.new()
				lbl.text = "Haste!"
				lbl.z_index = 25
				lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				lbl.position = node.position + Vector2(0, -30)
				lbl.add_theme_font_size_override("font_size", 12)
				lbl.add_theme_color_override("font_color", Color.CYAN)
				lbl.add_theme_color_override("font_outline_color", Color.BLACK)
				lbl.add_theme_constant_override("outline_size", 1)
				client._world.add_child(lbl)
				var tw := lbl.create_tween()
				tw.tween_property(lbl, "position:y", lbl.position.y - 25, 1.2)
				tw.parallel().tween_property(lbl, "modulate:a", 0.0, 1.2)
				tw.tween_callback(lbl.queue_free)

		"exura gran mas res":
			# Mass heal — play effect on caster and nearby area
			_play_effect_at(world_pos, "blueshimmer")
			for dx in range(-2, 3):
				for dy in range(-2, 3):
					if dx == 0 and dy == 0:
						continue
					_play_effect_at(world_pos + Vector2(dx * TILE_SIZE, dy * TILE_SIZE), "blueshimmer")


## Loads and caches frame textures for an effect. Returns Array[Texture2D].
func _load_effect_frames(effect_name: String) -> Array:
	if _effect_cache.has(effect_name):
		return _effect_cache[effect_name]
	var frames: Array = []
	var def: Dictionary = _effect_defs.get(effect_name, {})
	if def.is_empty():
		_effect_cache[effect_name] = frames
		return frames
	var folder: String = def["folder"]
	var prefix: String = def["prefix"]
	var count: int = int(def["count"])
	# Auto-detect frame count if 0
	if count == 0:
		for i in range(1, 30):
			var path := "%s/%s (%d).png" % [folder, prefix, i]
			if ResourceLoader.exists(path):
				count = i
			else:
				break
	for i in range(1, count + 1):
		var path := "%s/%s (%d).png" % [folder, prefix, i]
		if ResourceLoader.exists(path):
			frames.append(load(path))
	_effect_cache[effect_name] = frames
	return frames


## Plays a frame-animated effect at the given tile coordinates (called by rpc_tile_effect).
func play_effect_at_tile(effect_name: String, tile_x: int, tile_y: int) -> void:
	_play_effect_at(Vector2(tile_x * TILE_SIZE, tile_y * TILE_SIZE), effect_name)


## Plays a frame-animated effect at the given world position, then auto-frees.
func _play_effect_at(world_pos: Vector2, effect_name: String) -> void:
	var frames := _load_effect_frames(effect_name)
	if frames.is_empty():
		return
	var def: Dictionary = _effect_defs.get(effect_name, {})
	var fps: float = float(def.get("fps", 10.0))
	var sprite := Sprite2D.new()
	sprite.centered = false
	sprite.texture = frames[0]
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.z_index = 10
	sprite.position = world_pos
	# Scale to tile size
	var tex_size: Vector2 = (frames[0] as Texture2D).get_size()
	if tex_size.x > 0 and tex_size.y > 0:
		sprite.scale = Vector2(float(TILE_SIZE) / tex_size.x, float(TILE_SIZE) / tex_size.y)
	client._world.add_child(sprite)
	# Animate frames using a tween
	var total_time: float = float(frames.size()) / fps
	var frame_dur: float = 1.0 / fps
	var tw := sprite.create_tween()
	for i in range(1, frames.size()):
		var tex: Texture2D = frames[i]
		tw.tween_callback(func(): sprite.texture = tex).set_delay(frame_dur)
	tw.tween_callback(sprite.queue_free).set_delay(frame_dur)


#  HIT EFFECTS & BLOOD SPILLS


# Damage type -> element hit effect name
const ELEMENT_HIT_EFFECTS := {
	"fire": "fire_effect",
	"energy": "energy_effect",
	"earth": "poison_effect",
	"ice": "energy_effect",
	"poison": "poison_effect",
	"death": "death_effect",
	"holy": "energy_effect",
}


## Plays an element-specific hit effect on the target tile (energy sparkle, fire burst, etc.).
func play_element_hit_effect(world_pos: Vector2, damage_type: String) -> void:
	var effect_name: String = ELEMENT_HIT_EFFECTS.get(damage_type, "")
	if not effect_name.is_empty():
		_play_effect_at(world_pos, effect_name)


## Called when an entity/player takes damage. Plays the appropriate effect.
func play_hit_effect_on_entity(world_pos: Vector2, damage: int, creature_type: String) -> void:
	if damage <= 0:
		# Miss — play exhaust poof
		_play_effect_at(world_pos, "exhaust")
		return
	# Damage was dealt — play creature-type hit effect as animated flash
	var hit_effect: String = _creature_hit_effects.get(creature_type, "hit_physical")
	_play_effect_at(world_pos, hit_effect)
	# Blood creatures also leave a persistent blood_red decal on the tile
	if creature_type == "blood":
		_spawn_blood_spill_with_effect(world_pos, "blood_red")


## Called when damage is fully blocked by armor/shield.
func play_blocked_effect(world_pos: Vector2) -> void:
	_play_effect_at(world_pos, "blocked")


## Called when a blood-type creature dies — blood pool under corpse.
func play_death_blood_spill(world_pos: Vector2) -> void:
	_spawn_blood_spill_with_effect(world_pos, "blood_red")


## Creates a persistent blood decal sprite that decays through frames over its lifetime.
func _spawn_blood_spill_with_effect(world_pos: Vector2, effect_name: String) -> void:
	var frames := _load_effect_frames(effect_name)
	if frames.is_empty():
		return
	# Snap to tile grid
	var tile_x: int = int(floor(world_pos.x / TILE_SIZE))
	var tile_y: int = int(floor(world_pos.y / TILE_SIZE))
	var snapped_pos := Vector2(tile_x * TILE_SIZE, tile_y * TILE_SIZE)
	var tex: Texture2D = frames[0]
	var sprite := Sprite2D.new()
	sprite.centered = false
	sprite.texture = tex
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.z_index = 1
	sprite.position = snapped_pos
	var tex_size: Vector2 = tex.get_size()
	if tex_size.x > 0 and tex_size.y > 0:
		sprite.scale = Vector2(float(TILE_SIZE) / tex_size.x, float(TILE_SIZE) / tex_size.y)
	client._world.add_child(sprite)
	var now: float = Time.get_ticks_msec() / 1000.0
	_blood_spills.append({
		"node": sprite,
		"frames": frames,
		"current_frame": 0,
		"spawn_time": now,
		"expire_time": now + _blood_spill_duration,
	})


## Called from client_main._process(). Decays blood spills through frames, then removes.
func process_blood_spills() -> void:
	if _blood_spills.is_empty():
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	var i: int = _blood_spills.size() - 1
	while i >= 0:
		var spill: Dictionary = _blood_spills[i]
		var time_left: float = float(spill["expire_time"]) - now
		if time_left <= 0.0:
			if is_instance_valid(spill["node"]):
				spill["node"].queue_free()
			_blood_spills.remove_at(i)
		else:
			# Advance decay frame based on elapsed time
			var elapsed: float = now - float(spill["spawn_time"])
			var total_dur: float = float(spill["expire_time"]) - float(spill["spawn_time"])
			var frame_count: int = spill["frames"].size()
			var target_frame: int = mini(int(elapsed / total_dur * float(frame_count)), frame_count - 1)
			if target_frame != int(spill["current_frame"]) and is_instance_valid(spill["node"]):
				spill["current_frame"] = target_frame
				spill["node"].texture = spill["frames"][target_frame]
			# Fade out in the last 5 seconds
			if time_left < 5.0 and is_instance_valid(spill["node"]):
				spill["node"].modulate.a = time_left / 5.0
		i -= 1


#  PROJECTILE SYSTEM

const PROJECTILE_SPEED := 24.0  # tiles per second (fast, Tibia-like)


## Spawns a projectile sprite that flies from (sx,sy) to (dx,dy) then auto-frees.
func handle_projectile(sx: int, sy: int, dx: int, dy: int, proj_type: String) -> void:
	var start_pos := Vector2(sx * TILE_SIZE + TILE_SIZE / 2.0, sy * TILE_SIZE + TILE_SIZE / 2.0)
	var end_pos := Vector2(dx * TILE_SIZE + TILE_SIZE / 2.0, dy * TILE_SIZE + TILE_SIZE / 2.0)
	var delta_x: int = dx - sx
	var delta_y: int = dy - sy
	# Determine 8-direction name from delta
	var dir_name: String = _get_direction_name(delta_x, delta_y)
	# Load the directional texture
	var tex: Texture2D = _load_projectile_texture(proj_type, dir_name)
	if tex == null:
		return
	var sprite := Sprite2D.new()
	sprite.texture = tex
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.z_index = 15  # Above entities
	sprite.position = start_pos
	# Scale to 16x16
	var tex_size := tex.get_size()
	if tex_size.x > 0 and tex_size.y > 0:
		sprite.scale = Vector2(float(_projectile_size) / tex_size.x, float(_projectile_size) / tex_size.y)
	client._world.add_child(sprite)
	# Calculate flight duration based on distance
	var dist_tiles: float = start_pos.distance_to(end_pos) / float(TILE_SIZE)
	var duration: float = maxf(dist_tiles / PROJECTILE_SPEED, 0.1)
	# Tween from start to end, then free
	var tw := sprite.create_tween()
	tw.tween_property(sprite, "position", end_pos, duration)
	tw.tween_callback(sprite.queue_free)


## Returns one of 8 direction names from tile delta.
func _get_direction_name(dx: int, dy: int) -> String:
	if dx == 0 and dy < 0: return "north"
	if dx > 0 and dy < 0: return "north_east"
	if dx > 0 and dy == 0: return "east"
	if dx > 0 and dy > 0: return "south_east"
	if dx == 0 and dy > 0: return "south"
	if dx < 0 and dy > 0: return "south_west"
	if dx < 0 and dy == 0: return "west"
	if dx < 0 and dy < 0: return "north_west"
	return "south"  # fallback


## Loads and caches a directional projectile texture from sprite_config definitions.
func _load_projectile_texture(proj_type: String, direction: String) -> Texture2D:
	var cache_key := "%s_%s" % [proj_type, direction]
	if _projectile_cache.has(cache_key):
		return _projectile_cache[cache_key]
	var def: Dictionary = _projectile_defs.get(proj_type, {})
	if def.is_empty():
		return null
	var folder: String = def["folder"]
	var prefix: String = def["prefix"]
	# Try directional naming first: prefix_direction.png
	var paths: Array = []
	if not prefix.is_empty():
		paths.append("%s/%s_%s.png" % [folder, prefix, direction])
	paths.append("%s/%s.png" % [folder, direction])
	for path in paths:
		if ResourceLoader.exists(path):
			var tex: Texture2D = load(path)
			_projectile_cache[cache_key] = tex
			return tex
	# Fallback: try loading any single PNG in the folder (non-directional projectile)
	var fallback_key := "%s_fallback" % proj_type
	if _projectile_cache.has(fallback_key):
		_projectile_cache[cache_key] = _projectile_cache[fallback_key]
		return _projectile_cache[fallback_key]
	var dir := DirAccess.open(folder)
	if dir != null:
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			if fname.ends_with(".png") and not fname.ends_with(".import"):
				var fallback_path := "%s/%s" % [folder, fname]
				if ResourceLoader.exists(fallback_path):
					var tex: Texture2D = load(fallback_path)
					_projectile_cache[fallback_key] = tex
					_projectile_cache[cache_key] = tex
					return tex
			fname = dir.get_next()
	_projectile_cache[cache_key] = null
	return null
