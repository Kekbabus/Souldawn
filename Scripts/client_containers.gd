#  client_containers.gd -- Container UI and world markers for corpses/bags.
#
#  Manages container open/close windows, corpse sprite markers on the
#  world map, drag-to-take items, and proximity-based auto-close.
extends Node

const TILE_SIZE := 32
const SLOT_SIZE := 36

var client: Node2D = null

var _container_layer: CanvasLayer = null
var _container_panel: PanelContainer = null
var _container_vbox: VBoxContainer = null
var _current_container_id: int = -1
var _current_items: Array = []
# Ground markers for corpses
var _corpse_markers: Dictionary = {}  # container_id -> Node2D
var _corpse_z: Dictionary = {}       # container_id -> int z_level


## Builds the container panel UI with title bar, close button, and item list.
func setup_ui() -> void:
	_container_layer = CanvasLayer.new()
	_container_layer.name = "ContainerLayer"
	_container_layer.layer = 16
	_container_layer.visible = false
	client.add_child(_container_layer)

	_container_panel = PanelContainer.new()
	_container_panel.position = Vector2(600, 30)
	_container_layer.add_child(_container_panel)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 4)
	_container_panel.add_child(outer)

	var title_row := HBoxContainer.new()
	outer.add_child(title_row)
	var title := Label.new()
	title.name = "Title"
	title.text = "Container"
	title.add_theme_font_size_override("font_size", 12)
	title_row.add_child(title)
	title_row.add_spacer(false)
	var close_btn := Button.new()
	close_btn.text = "X"
	close_btn.pressed.connect(_on_close_pressed)
	title_row.add_child(close_btn)

	_container_vbox = VBoxContainer.new()
	_container_vbox.name = "Items"
	_container_vbox.add_theme_constant_override("separation", 2)
	outer.add_child(_container_vbox)


## Creates a world marker (sprite or fallback dot) for a new corpse/bag container.
func handle_container_spawn(cid: int, x: int, y: int, z: int, display_name: String, sprite_path: String = "", is_corpse: bool = false) -> void:
	var marker := Node2D.new()
	marker.name = "Corpse_%d" % cid
	marker.position = Vector2(x * TILE_SIZE, y * TILE_SIZE)
	marker.z_index = 3  # Above ground items (z_index 2) so containers render on top
	marker.visible = (z == client._current_z)
	# Render sprite if available, otherwise fallback to colored dot
	if not sprite_path.is_empty() and ResourceLoader.exists(sprite_path):
		var tex: Texture2D = load(sprite_path)
		if tex != null:
			var img := TextureRect.new()
			img.texture = tex
			img.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
			img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			img.position = Vector2(0, 0)
			img.size = Vector2(TILE_SIZE, TILE_SIZE)
			img.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			img.mouse_filter = Control.MOUSE_FILTER_IGNORE
			marker.add_child(img)
		else:
			var dot := ColorRect.new()
			dot.size = Vector2(16, 16)
			dot.position = Vector2(8, 8)
			dot.color = Color(0.5, 0.3, 0.1, 0.8)
			marker.add_child(dot)
	else:
		var dot := ColorRect.new()
		dot.size = Vector2(16, 16)
		dot.position = Vector2(8, 8)
		dot.color = Color(0.5, 0.3, 0.1, 0.8)
		marker.add_child(dot)
	var lbl := Label.new()
	lbl.text = display_name
	lbl.add_theme_font_size_override("font_size", 8)
	lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	lbl.position = Vector2(0, -10)
	marker.add_child(lbl)
	client._world.add_child(marker)
	client._world.move_child(marker, -1)
	_corpse_markers[cid] = marker
	_corpse_z[cid] = z
	# Spawn blood pool only under corpses, not bags/backpacks
	if is_corpse:
		client.combat._spawn_blood_spill_with_effect(Vector2(x * TILE_SIZE, y * TILE_SIZE), "blood_spill")


## Moves an existing corpse marker to a new tile position and z-level.
func handle_container_move(cid: int, x: int, y: int, z: int) -> void:
	if _corpse_markers.has(cid):
		_corpse_markers[cid].position = Vector2(x * TILE_SIZE, y * TILE_SIZE)
		_corpse_z[cid] = z
		_corpse_markers[cid].visible = (z == client._current_z)


## Removes a corpse marker from the world and closes its panel if open.
func handle_container_despawn(cid: int) -> void:
	if _corpse_markers.has(cid):
		_corpse_markers[cid].queue_free()
		_corpse_markers.erase(cid)
	_corpse_z.erase(cid)
	if _current_container_id == cid:
		_close_container()


## Replaces the visual sprite on an existing corpse marker.
func handle_container_sprite_update(cid: int, sprite_path: String) -> void:
	if not _corpse_markers.has(cid):
		return
	var marker: Node2D = _corpse_markers[cid]
	# Remove old visual (first child that's a TextureRect or ColorRect)
	for child in marker.get_children():
		if child is TextureRect or (child is ColorRect and child.name != "NameLabel"):
			child.queue_free()
			break
	# Add new sprite
	if not sprite_path.is_empty() and ResourceLoader.exists(sprite_path):
		var tex: Texture2D = load(sprite_path)
		if tex != null:
			var img := TextureRect.new()
			img.texture = tex
			img.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
			img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			img.position = Vector2(0, 0)
			img.size = Vector2(TILE_SIZE, TILE_SIZE)
			img.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			img.mouse_filter = Control.MOUSE_FILTER_IGNORE
			marker.add_child(img)
			marker.move_child(img, 0)
			return
	# Fallback -- small brown dot
	var dot := ColorRect.new()
	dot.size = Vector2(12, 12)
	dot.position = Vector2(10, 10)
	dot.color = Color(0.4, 0.25, 0.1, 0.6)
	marker.add_child(dot)
	marker.move_child(dot, 0)


## Opens the container panel, sets its title, and populates the item list.
func handle_container_open(cid: int, display_name: String, items: Array) -> void:
	_current_container_id = cid
	_current_items = items
	_container_layer.visible = true
	var title: Label = _container_panel.get_node("VBoxContainer/HBoxContainer/Title") if _container_panel.has_node("VBoxContainer/HBoxContainer/Title") else null
	# Update title via the first Label child
	for child in _container_panel.get_children():
		if child is VBoxContainer:
			for sub in child.get_children():
				if sub is HBoxContainer:
					for btn_child in sub.get_children():
						if btn_child is Label:
							btn_child.text = display_name
							break
	_refresh_items()


## Closes the container panel if it matches the given container id.
func handle_container_close(cid: int) -> void:
	if _current_container_id == cid:
		_close_container()


## Hides the container layer and sends a close request to the server.
func _close_container() -> void:
	if _container_layer != null and is_instance_valid(_container_layer):
		_container_layer.visible = false
	if _current_container_id >= 0:
		client.rpc_id(1, "rpc_container_close_request", _current_container_id)
	_current_container_id = -1
	_current_items = []


## Close button callback -- delegates to _close_container.
func _on_close_pressed() -> void:
	_close_container()


## Rebuilds the item rows inside the container panel from _current_items.
func _refresh_items() -> void:
	if _container_vbox == null:
		return
	for child in _container_vbox.get_children():
		child.queue_free()
	if _current_items.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "(empty)"
		empty_lbl.add_theme_font_size_override("font_size", 10)
		_container_vbox.add_child(empty_lbl)
		return
	for i in range(_current_items.size()):
		var item: Array = _current_items[i]
		var item_id: String = str(item[0])
		var count: int = int(item[1])
		var item_name: String = str(item[2]) if item.size() > 2 else item_id
		var color_hex: String = str(item[3]) if item.size() > 3 else "#FFD700"
		var color := Color.from_string(color_hex, Color.GOLD)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		# Draggable color slot
		var slot := Panel.new()
		slot.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
		slot.tooltip_text = item_name
		var bg := StyleBoxFlat.new()
		bg.bg_color = Color(0.15, 0.15, 0.15)
		bg.border_color = Color(0.4, 0.4, 0.4)
		bg.set_border_width_all(1)
		bg.set_corner_radius_all(2)
		slot.add_theme_stylebox_override("panel", bg)
		var item_rect := ColorRect.new()
		item_rect.color = color
		item_rect.position = Vector2(4, 4)
		item_rect.size = Vector2(SLOT_SIZE - 8, SLOT_SIZE - 8)
		item_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(item_rect)
		if count > 1:
			var cnt_lbl := Label.new()
			cnt_lbl.text = str(count)
			cnt_lbl.add_theme_font_size_override("font_size", 9)
			cnt_lbl.add_theme_color_override("font_color", Color.WHITE)
			cnt_lbl.position = Vector2(SLOT_SIZE - 18, SLOT_SIZE - 16)
			cnt_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			slot.add_child(cnt_lbl)
		var idx := i
		var drag_col := color
		slot.gui_input.connect(func(event: InputEvent):
			if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
				client.inventory.start_drag("container", idx, _current_container_id, "", drag_col)
		)
		row.add_child(slot)
		var lbl := Label.new()
		lbl.text = item_name
		lbl.add_theme_font_size_override("font_size", 10)
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(lbl)
		_container_vbox.add_child(row)


## Sends an RPC to take an item at the given slot index from the open container.
func _take_item(index: int) -> void:
	if _current_container_id < 0:
		return
	client.rpc_id(1, "rpc_container_take", _current_container_id, index)


func get_corpse_at_tile(tile_pos: Vector2i) -> int:
	## Returns container_id of a corpse at the tile, or -1.
	for cid in _corpse_markers:
		var marker: Node2D = _corpse_markers[cid]
		if not is_instance_valid(marker) or not marker.visible:
			continue
		var corpse_tile := Vector2i(
			int(floor(marker.position.x / TILE_SIZE)),
			int(floor(marker.position.y / TILE_SIZE)))
		if corpse_tile == tile_pos:
			return cid
	return -1


## Shows or hides corpse markers based on the active z-level.
func update_z_visibility(current_z: int) -> void:
	for cid in _corpse_markers:
		var marker: Node2D = _corpse_markers[cid]
		var cz: int = _corpse_z.get(cid, 7)
		marker.visible = (cz == current_z)


func check_proximity(player_tile: Vector2i) -> void:
	## Close container if player moved too far away.
	if _current_container_id < 0:
		return
	for cid in _corpse_markers:
		if cid == _current_container_id:
			var marker: Node2D = _corpse_markers[cid]
			var corpse_tile := Vector2i(
				int(floor(marker.position.x / TILE_SIZE)),
				int(floor(marker.position.y / TILE_SIZE)))
			if absi(player_tile.x - corpse_tile.x) > 2 or absi(player_tile.y - corpse_tile.y) > 2:
				_close_container()
			return


## Frees all corpse markers and closes any open container panel.
func cleanup() -> void:
	for cid in _corpse_markers:
		if is_instance_valid(_corpse_markers[cid]):
			_corpse_markers[cid].queue_free()
	_corpse_markers.clear()
	_corpse_z.clear()
	_close_container()
