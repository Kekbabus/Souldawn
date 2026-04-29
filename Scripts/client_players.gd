#  client_players.gd -- Player entity spawning, movement animation, outfit
#  colorization, speech bubbles, and health bar updates
extends Node

const TILE_SIZE := 32
const DEFAULT_GROUND_SPEED := 150.0
const ANIM_SPEEDUP := 1.0

var client: Node2D = null  # client_main.gd
var _players: Dictionary = {}  # entity_id → player data Dictionary


## Frees all player nodes, speech bubbles, and HUD overlays.
func cleanup_all() -> void:
	for eid in _players:
		var data: Dictionary = _players[eid]
		if data.has("node") and is_instance_valid(data["node"]):
			data["node"].queue_free()
		client.ui.unregister_entity_overlay("player_%d" % eid)
	_players.clear()
	# Clear speech bubbles
	for eid in _speech_bubbles.keys():
		_remove_speech_bubble(eid)
	_speech_bubbles.clear()


const WALK_FRAME_INTERVAL := 0.15


## Loads all base and color mask images from an outfit sprites JSON dict.
## Returns { "base_images": {key→Image}, "mask_images": {key→Image}, "has_outfit": bool }
## Both base AND mask are loaded via Image.load_from_file() to bypass Godot's
## import pipeline — this guarantees pixel-perfect 1:1 alignment between them.
static func _load_outfit_images(sprites_data: Dictionary) -> Dictionary:
	var base_images: Dictionary = {}   # key → Image (raw PNG)
	var mask_images: Dictionary = {}   # key → Image (raw PNG)
	var has_outfit := false

	var idle: Dictionary = sprites_data.get("idle", {})
	for dir_name in idle:
		var path: String = str(idle[dir_name])
		if not path.is_empty() and FileAccess.file_exists(path):
			var img := Image.load_from_file(path)
			if img:
				base_images["idle_" + dir_name] = img
				has_outfit = true

	var walk: Dictionary = sprites_data.get("walk", {})
	for dir_name in walk:
		var frames = walk[dir_name]
		if frames is Array:
			for i in range(frames.size()):
				var path: String = str(frames[i])
				if not path.is_empty() and FileAccess.file_exists(path):
					var img := Image.load_from_file(path)
					if img:
						base_images["walk_%s_%d" % [dir_name, i]] = img

	var color_idle: Dictionary = sprites_data.get("color_idle", {})
	for dir_name in color_idle:
		var path: String = str(color_idle[dir_name])
		if not path.is_empty() and FileAccess.file_exists(path):
			var img := Image.load_from_file(path)
			if img:
				mask_images["idle_" + dir_name] = img

	var color_walk: Dictionary = sprites_data.get("color_walk", {})
	for dir_name in color_walk:
		var frames = color_walk[dir_name]
		if frames is Array:
			for i in range(frames.size()):
				var path: String = str(frames[i])
				if not path.is_empty() and FileAccess.file_exists(path):
					var img := Image.load_from_file(path)
					if img:
						mask_images["walk_%s_%d" % [dir_name, i]] = img

	return {"base_images": base_images, "mask_images": mask_images, "has_outfit": has_outfit}


## Colorizes all base images that have a matching mask and returns a dict of key → ImageTexture.
## Keys without a mask get a plain ImageTexture from the base image.
static func _build_colorized_textures(base_images: Dictionary, mask_images: Dictionary,
		head_col: Color, body_col: Color, legs_col: Color, feet_col: Color) -> Dictionary:
	var textures: Dictionary = {}
	for key in base_images:
		var base_img: Image = base_images[key]
		if mask_images.has(key):
			textures[key] = colorize_outfit(base_img, mask_images[key],
				head_col, body_col, legs_col, feet_col)
		else:
			textures[key] = ImageTexture.create_from_image(base_img)
	return textures


## Creates a player Node2D with outfit sprites and registers a HUD overlay.
func spawn_player_entity(entity_id: int, pos: Vector3i, display_name: String, speed: float, outfit_json: String = "") -> void:
	var node := Node2D.new()
	node.name = "Player_%d" % entity_id
	node.position = Vector2(pos.x * TILE_SIZE, pos.y * TILE_SIZE)
	node.z_index = 4

	# Parse outfit sprites — load raw PNGs for both base and mask
	var base_images: Dictionary = {}
	var mask_images: Dictionary = {}
	var sprite_textures: Dictionary = {}
	var has_outfit := false

	if not outfit_json.is_empty():
		var json := JSON.new()
		if json.parse(outfit_json) == OK and json.data is Dictionary:
			var loaded := _load_outfit_images(json.data)
			base_images = loaded["base_images"]
			mask_images = loaded["mask_images"]
			has_outfit = loaded["has_outfit"]

	if has_outfit:
		# Default colors
		var head_col := Color(1.0, 1.0, 0.0)
		var body_col := Color(0.3, 0.5, 1.0)
		var legs_col := Color(0.3, 0.5, 1.0)
		var feet_col := Color(0.6, 0.4, 0.2)
		sprite_textures = _build_colorized_textures(base_images, mask_images,
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
		sprite.color = Color.CORNFLOWER_BLUE if entity_id == client._local_entity_id else Color.ORANGE_RED
		node.add_child(sprite)

	client._world.add_child(node)

	# Register HUD overlay for name + health bar (crisp rendering)
	var overlay_key := "player_%d" % entity_id
	client.ui.register_entity_overlay(overlay_key, node, display_name, Color(0, 0.8, 0))

	var ent_speed := maxf(speed, 10.0)
	var step_duration_ms := ceilf(1000.0 * DEFAULT_GROUND_SPEED / ent_speed)
	var anim_duration_sec := (step_duration_ms / 1000.0) * ANIM_SPEEDUP
	var anim_speed := float(TILE_SIZE) / maxf(anim_duration_sec, 0.05)

	_players[entity_id] = {
		"node": node,
		"target_pos": node.position,
		"moving": false,
		"move_queue": [],
		"anim_speed": anim_speed,
		"display_name": display_name,
		"health": 150,
		"max_health": 150,
		"z_level": pos.z,
		"sprite_textures": sprite_textures,
		"base_images": base_images,    # Raw Image objects for re-colorization
		"mask_images": mask_images,    # Raw mask Image objects
		"has_outfit": has_outfit,
		"facing": "south",
		"walk_frame": 0,
		"walk_timer": 0.0,
	}


## Queues a smooth tile-to-tile move for a player, updating facing direction.
## For the local player, handles pre-walk confirmation: if the server confirms the
## tile we're already walking toward, just update the speed. If different, snap back.
func handle_player_move(eid: int, x: int, y: int, z: int, step_ms: int = 0) -> void:
	if not _players.has(eid):
		return
	var data: Dictionary = _players[eid]
	data["z_level"] = z
	var new_pixel := Vector2(x * TILE_SIZE, y * TILE_SIZE)

	# Pre-walk confirmation for local player
	var is_local: bool = (eid == client._local_entity_id)
	if is_local and data.get("_prewalk_active", false):
		var target: Vector2 = data["target_pos"]
		if data["moving"] and target == new_pixel:
			# Server confirmed the pre-walk destination -- just update speed
			data["_prewalk_active"] = false
			if step_ms > 0:
				data["anim_speed"] = float(TILE_SIZE) / maxf(float(step_ms) / 1000.0, 0.05)
			return
		else:
			# Server sent a different position -- cancel pre-walk, snap back
			data["_prewalk_active"] = false
			if data.has("_prewalk_from"):
				data["node"].position = data["_prewalk_from"]
			data["moving"] = false
			data["move_queue"] = []

	# Determine facing direction from movement delta
	var cur_pixel: Vector2 = data["node"].position
	if data["moving"]:
		cur_pixel = data["target_pos"]
	var dx: float = new_pixel.x - cur_pixel.x
	var dy: float = new_pixel.y - cur_pixel.y
	var new_facing: String = data["facing"]
	if absf(dy) >= absf(dx):
		new_facing = "north" if dy < 0 else "south"
	else:
		new_facing = "west" if dx < 0 else "east"
	data["_pending_facing"] = new_facing
	# Update animation speed from step duration
	if step_ms > 0:
		var step_sec: float = float(step_ms) / 1000.0
		data["anim_speed"] = float(TILE_SIZE) / maxf(step_sec, 0.05)
	if data["moving"]:
		var queue: Array = data["move_queue"]
		if queue.size() >= 1:
			data["node"].position = data["target_pos"]
			data["moving"] = false
			data["facing"] = new_facing
			queue.clear()
			_start_move(data, new_pixel)
		else:
			queue.append(new_pixel)
	else:
		data["facing"] = new_facing
		_start_move(data, new_pixel)

## Instantly snaps a player to a new position without animation.
func handle_player_teleport(eid: int, x: int, y: int, z: int) -> void:
	if not _players.has(eid):
		return
	var data: Dictionary = _players[eid]
	data["z_level"] = z
	var new_pixel := Vector2(x * TILE_SIZE, y * TILE_SIZE)
	# Instant snap — no animation
	data["node"].position = new_pixel
	data["target_pos"] = new_pixel
	data["moving"] = false
	data["move_queue"] = []


## Removes a player entity, its speech bubble, and HUD overlay.
func handle_player_despawn(eid: int) -> void:
	if _players.has(eid):
		_remove_speech_bubble(eid)
		client.ui.unregister_entity_overlay("player_%d" % eid)
		_players[eid]["node"].queue_free()
		_players.erase(eid)


## Updates a player's facing direction and shows the idle sprite for that direction.
func handle_player_face(eid: int, direction: int) -> void:
	if not _players.has(eid):
		return
	var data: Dictionary = _players[eid]
	# Update facing direction: 0=N, 1=E, 2=S, 3=W
	var dir_names := ["north", "east", "south", "west"]
	if direction >= 0 and direction < 4:
		data["facing"] = dir_names[direction]
	# Show idle sprite for the new facing direction
	_set_player_sprite(data, "idle")


#  SMOOTH TILE MOVEMENT ANIMATION

## Begins a smooth movement step toward a target pixel position.
func _start_move(data: Dictionary, new_pixel: Vector2) -> void:
	data["moving"] = true
	data["start_pos"] = data["node"].position
	data["target_pos"] = new_pixel
	data["step_count"] = int(data.get("step_count", 0)) + 1
	data["walk_frame"] = 0
	_set_player_sprite(data, "walk")


## Advances all player movement animations by delta seconds.
## Tibia 7.6 walk cycle: 2 walk frames per direction, split evenly across the step.
## First half = walk frame 0, second half = walk frame 1.
func process_movement_animation(delta: float) -> void:
	for eid in _players:
		var data: Dictionary = _players[eid]
		if not data["moving"]:
			var queue: Array = data["move_queue"]
			if not queue.is_empty():
				if data.has("_pending_facing"):
					data["facing"] = data["_pending_facing"]
					data.erase("_pending_facing")
				_start_move(data, queue.pop_front())
			else:
				_set_player_sprite(data, "idle")
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
			var queue: Array = data["move_queue"]
			if not queue.is_empty():
				if data.has("_pending_facing"):
					data["facing"] = data["_pending_facing"]
					data.erase("_pending_facing")
				_start_move(data, queue.pop_front())
			else:
				_set_player_sprite(data, "idle")
		else:
			node.position += (target - node.position).normalized() * spd * delta
			var start_pos: Vector2 = data.get("start_pos", node.position)
			var total_dist: float = start_pos.distance_to(target)
			var progress: float = 1.0 - (distance / maxf(total_dist, 1.0))
			# 7.6 style: first half = frame 0, second half = frame 1
			data["walk_frame"] = 0 if progress < 0.5 else 1
			_set_player_sprite(data, "walk")


## Sets the correct idle or walk sprite texture based on facing direction and frame.
func _set_player_sprite(data: Dictionary, mode: String) -> void:
	if not data.get("has_outfit", false):
		return
	var sprite_node: Node = data["node"].get_node_or_null("Sprite")
	if sprite_node == null or not sprite_node is Sprite2D:
		return
	var textures: Dictionary = data["sprite_textures"]
	var facing: String = data["facing"]
	var tex: Texture2D = null
	if mode == "walk":
		var frame: int = int(data["walk_frame"])
		var frame_count := 0
		while textures.has("walk_%s_%d" % [facing, frame_count]):
			frame_count += 1
		if frame_count > 0:
			var key := "walk_%s_%d" % [facing, frame % frame_count]
			tex = textures.get(key, null)
	if tex == null:
		tex = textures.get("idle_" + facing, null)
	if tex == null:
		tex = textures.get("idle_south", null)
	if tex != null and sprite_node.texture != tex:
		sprite_node.texture = tex
		var tex_size := tex.get_size()
		sprite_node.scale = Vector2.ONE
		sprite_node.position = Vector2(TILE_SIZE - tex_size.x, TILE_SIZE - tex_size.y)


## Updates the HUD health bar overlay for a player.
func update_player_health_bar(data: Dictionary) -> void:
	# Find the entity_id for this player data to update the HUD overlay
	for eid in _players:
		if _players[eid] == data:
			var key := "player_%d" % eid
			client.ui.update_entity_overlay_health(key, int(data["health"]), int(data["max_health"]))
			return


## Shows or hides players based on whether they share the local player's z-level.
func update_z_visibility(current_z: int, local_eid: int) -> void:
	for eid in _players:
		if eid == local_eid:
			continue  # Always show local player
		var data: Dictionary = _players[eid]
		var same_floor: bool = (int(data.get("z_level", 7)) == current_z)
		data["node"].visible = same_floor
		if same_floor:
			data["node"].modulate = Color.WHITE
		# Hide/show overlay (name + health bar) based on floor
		var overlay_key := "player_%d" % eid
		if client.ui._entity_overlays.has(overlay_key):
			client.ui._entity_overlays[overlay_key]["z_hidden"] = not same_floor


## Re-colorizes a player's outfit with new colors and optionally new sprite data.
func handle_outfit_update(eid: int, sprites_json: String, head: String, body: String, legs: String, feet: String) -> void:
	if not _players.has(eid):
		return
	var data: Dictionary = _players[eid]
	var head_col := Color.from_string(head, Color.YELLOW) if not head.is_empty() else Color.YELLOW
	var body_col := Color.from_string(body, Color.BLUE) if not body.is_empty() else Color.BLUE
	var legs_col := Color.from_string(legs, Color.GREEN) if not legs.is_empty() else Color.GREEN
	var feet_col := Color.from_string(feet, Color.BROWN) if not feet.is_empty() else Color.BROWN

	# If new sprites_json provided, reload all raw images
	if not sprites_json.is_empty():
		var json := JSON.new()
		if json.parse(sprites_json) == OK and json.data is Dictionary:
			var loaded := _load_outfit_images(json.data)
			if loaded["has_outfit"]:
				data["base_images"] = loaded["base_images"]
				data["mask_images"] = loaded["mask_images"]
				data["has_outfit"] = true
				# Ensure sprite node is Sprite2D
				var old_sprite: Node = data["node"].get_node_or_null("Sprite")
				if old_sprite != null and not old_sprite is Sprite2D:
					old_sprite.queue_free()
					var new_sprite := Sprite2D.new()
					new_sprite.name = "Sprite"
					new_sprite.centered = false
					new_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
					data["node"].add_child(new_sprite)
					data["node"].move_child(new_sprite, 0)

	# Re-colorize from stored raw images
	var base_images: Dictionary = data.get("base_images", {})
	var mask_images: Dictionary = data.get("mask_images", {})
	if base_images.is_empty():
		return
	data["sprite_textures"] = _build_colorized_textures(base_images, mask_images,
		head_col, body_col, legs_col, feet_col)
	_set_player_sprite(data, "idle")


## CPU-side pixel colorization (OTClient approach).
## Mask uses pure YRGB channels: Yellow=Head, Red=Body, Green=Legs, Blue=Feet.
static func colorize_outfit(base_img: Image, mask_img: Image, head_col: Color, body_col: Color, legs_col: Color, feet_col: Color) -> ImageTexture:
	var result := base_img.duplicate() as Image
	var w := mini(result.get_width(), mask_img.get_width())
	var h := mini(result.get_height(), mask_img.get_height())
	for y in range(h):
		for x in range(w):
			var mask_pixel := mask_img.get_pixel(x, y)
			if mask_pixel.a < 0.01:
				continue
			var r := mask_pixel.r
			var g := mask_pixel.g
			var b := mask_pixel.b
			# Strict channel matching — pick the dominant mask color
			var chosen: Color
			if r > 0.5 and g > 0.5 and b < 0.3:
				chosen = head_col    # Yellow = Head
			elif r > 0.5 and g < 0.3 and b < 0.3:
				chosen = body_col    # Red = Body
			elif g > 0.5 and r < 0.3 and b < 0.3:
				chosen = legs_col    # Green = Legs
			elif b > 0.5 and r < 0.3 and g < 0.3:
				chosen = feet_col    # Blue = Feet
			else:
				continue  # Unknown mask color — skip
			# Use base pixel luminance for shading — preserves the white template's gradients
			var base_pixel := result.get_pixel(x, y)
			var lum := base_pixel.r * 0.299 + base_pixel.g * 0.587 + base_pixel.b * 0.114
			result.set_pixel(x, y, Color(
				clampf(chosen.r * lum, 0.0, 1.0),
				clampf(chosen.g * lum, 0.0, 1.0),
				clampf(chosen.b * lum, 0.0, 1.0),
				base_pixel.a
			))
	return ImageTexture.create_from_image(result)


#  SPEECH BUBBLES — Tibia-style text above character heads
#  Rendered in HUD layer for crisp text, position tracked per-frame.
const SPEECH_DURATION := 4.0  # Seconds before fade starts
const SPEECH_FADE := 1.0      # Fade-out duration
const SPEECH_MAX_WIDTH := 200  # Max pixel width in screen space

var _speech_bubble_scene: PackedScene = null
# Active bubbles: entity_id → { "bubble": PanelContainer, "eid": int }
var _speech_bubbles: Dictionary = {}


## Lazily loads and caches the speech bubble scene.
func _get_speech_bubble_scene() -> PackedScene:
	if _speech_bubble_scene == null:
		_speech_bubble_scene = load("res://Scenes/ui_speech_bubble.tscn")
	return _speech_bubble_scene


## Finds the player by display_name and shows a speech bubble in the HUD layer.
## Replaces any existing bubble for that player.
func show_speech_bubble(sender_name: String, text: String, color: Color = Color.YELLOW) -> void:
	var eid := _find_entity_by_name(sender_name)
	if eid == 0:
		return
	# Verify the entity exists (player or NPC)
	var is_npc := eid >= NPC_BUBBLE_OFFSET
	if not is_npc and not _players.has(eid):
		return
	if is_npc:
		var nid: int = eid - NPC_BUBBLE_OFFSET
		if not client.entities._npcs.has(nid):
			return

	# Remove existing bubble for this entity
	if _speech_bubbles.has(eid):
		var old: PanelContainer = _speech_bubbles[eid]["bubble"]
		if is_instance_valid(old):
			old.free()
		_speech_bubbles.erase(eid)

	var scene := _get_speech_bubble_scene()
	if scene == null:
		return
	var bubble: PanelContainer = scene.instantiate()

	var label: Label = bubble.get_node_or_null("Label")
	if label:
		label.text = text
		label.add_theme_color_override("font_color", color)

	# Add to HUD layer for crisp rendering at screen resolution
	var hud_layer: CanvasLayer = client.ui._hud_layer
	if hud_layer == null:
		bubble.queue_free()
		return
	hud_layer.add_child(bubble)

	# Set max width and let it lay out
	bubble.size.x = SPEECH_MAX_WIDTH
	bubble.reset_size()

	_speech_bubbles[eid] = {"bubble": bubble}

	# Position immediately
	_update_single_bubble_position(eid)

	# Fade out and remove
	var tween := bubble.create_tween()
	tween.tween_interval(SPEECH_DURATION)
	tween.tween_property(bubble, "modulate:a", 0.0, SPEECH_FADE)
	var captured_eid := eid
	tween.tween_callback(func():
		_remove_speech_bubble(captured_eid)
	)


## Removes and frees a speech bubble for the given entity.
func _remove_speech_bubble(eid: int) -> void:
	if _speech_bubbles.has(eid):
		var bubble: PanelContainer = _speech_bubbles[eid]["bubble"]
		if is_instance_valid(bubble):
			bubble.queue_free()
		_speech_bubbles.erase(eid)


## Called every frame from client_main._process() to track player positions.
func update_speech_bubble_positions() -> void:
	for eid in _speech_bubbles.keys():
		_update_single_bubble_position(eid)


## Positions a single speech bubble in screen space above its entity.
func _update_single_bubble_position(eid: int) -> void:
	if not _speech_bubbles.has(eid):
		return
	var bubble: PanelContainer = _speech_bubbles[eid]["bubble"]
	if not is_instance_valid(bubble):
		_speech_bubbles.erase(eid)
		return

	# Find the world node — could be a player or an NPC
	var node: Node2D = null
	if eid >= NPC_BUBBLE_OFFSET:
		# NPC bubble
		var nid: int = eid - NPC_BUBBLE_OFFSET
		if client.entities._npcs.has(nid):
			node = client.entities._npcs[nid]["node"]
	elif _players.has(eid):
		node = _players[eid]["node"]

	if node == null or not is_instance_valid(node):
		_remove_speech_bubble(eid)
		return

	# Convert world position (center of tile, above name) to screen position
	var game_vp: SubViewport = client.ui.get_game_viewport()
	if game_vp == null:
		return
	var world_pos := node.global_position + Vector2(TILE_SIZE / 2.0, -8)
	var canvas_xform := game_vp.get_canvas_transform()
	var vp_pos: Vector2 = canvas_xform * world_pos

	# Offset from SubViewport position to screen position
	# The GameViewportContainer's global position gives us the screen offset
	var gvc: Control = client.ui._hud.get_node_or_null("MainHBox/CenterColumn/GameViewportContainer")
	if gvc:
		vp_pos += gvc.global_position

	# Center the bubble horizontally, place above the character
	var bw: float = bubble.size.x
	var bh: float = bubble.size.y
	bubble.position = Vector2(vp_pos.x - bw / 2.0, vp_pos.y - bh - 16)


## Returns an entity key for a player or NPC with the given display_name, or 0 if not found.
## Players use their negative eid. NPCs use npc_id + NPC_BUBBLE_OFFSET to avoid collision.
func _find_entity_by_name(display_name: String) -> int:
	var lower := display_name.to_lower()
	for eid in _players:
		if str(_players[eid]["display_name"]).to_lower() == lower:
			return eid
	# Also search NPCs
	if client and client.entities:
		for nid in client.entities._npcs:
			var npc: Dictionary = client.entities._npcs[nid]
			if str(npc.get("display_name", "")).to_lower() == lower:
				return nid + NPC_BUBBLE_OFFSET
	return 0

const NPC_BUBBLE_OFFSET := 1000000  # Offset to separate NPC bubble keys from player/entity keys
