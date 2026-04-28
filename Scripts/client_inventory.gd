#  client_inventory.gd -- Inventory, equipment, and ground-item UI with
#  full drag-and-drop support (inventory <-> equipment <-> ground <-> containers).
extends Node

const TILE_SIZE := 32
const SLOT_SIZE := 36
const SLOT_COLS := 5

var client: Node2D = null  # client_main.gd

var _inventory_panel: PanelContainer = null
var _inventory_layer: CanvasLayer = null
var _inventory_vbox: VBoxContainer = null
var _inventory_visible: bool = false
var _local_inventory: Array = []
var _ground_items: Dictionary = {}  # Vector3i -> Array of {item_id, count}
var _equipment_vbox: VBoxContainer = null
var _local_equipment: Array = []

var _dragging: bool = false
var _drag_source_type: String = ""
var _drag_source_index: int = -1
var _drag_source_slot: String = ""
var _drag_preview: Control = null
var _drag_color: Color = Color.MAGENTA
var _drag_ground_pos: Vector3i = Vector3i.ZERO
var _drag_ground_item_id: String = ""
var _drag_container_id: int = -1
var _drag_count: int = 0  # 0 = all, >0 = specific count
var _drag_max_count: int = 1  # Max count of the dragged item
var _drag_pending_slider: bool = false  # True if we need to show slider on drop
var _slider_open: bool = false  # True while count slider popup is visible
var _count_slider_scene: PackedScene = null


## Builds the inventory and equipment panels on a dedicated CanvasLayer.
func setup_inventory_ui() -> void:
	_count_slider_scene = load("res://Scenes/ui_count_slider.tscn")
	_inventory_layer = CanvasLayer.new()
	_inventory_layer.name = "InventoryLayer"
	_inventory_layer.layer = 15
	_inventory_layer.visible = false
	client.add_child(_inventory_layer)

	_inventory_panel = PanelContainer.new()
	_inventory_panel.name = "InventoryPanel"
	_inventory_panel.position = Vector2(820, 30)
	_inventory_layer.add_child(_inventory_panel)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)
	_inventory_panel.add_child(outer)

	var equip_title := Label.new()
	equip_title.text = "Equipment"
	equip_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	equip_title.add_theme_font_size_override("font_size", 12)
	outer.add_child(equip_title)

	_equipment_vbox = VBoxContainer.new()
	_equipment_vbox.name = "EquipGrid"
	_equipment_vbox.add_theme_constant_override("separation", 2)
	outer.add_child(_equipment_vbox)

	outer.add_child(HSeparator.new())

	var bp_title := Label.new()
	bp_title.text = "Backpack (I)"
	bp_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bp_title.add_theme_font_size_override("font_size", 12)
	outer.add_child(bp_title)

	_inventory_vbox = VBoxContainer.new()
	_inventory_vbox.name = "InvGrid"
	_inventory_vbox.add_theme_constant_override("separation", 2)
	outer.add_child(_inventory_vbox)


## Toggles the inventory panel visibility.
func toggle_inventory() -> void:
	_inventory_visible = not _inventory_visible
	if _inventory_layer != null:
		_inventory_layer.visible = _inventory_visible


## Creates a styled item slot panel with optional color swatch, count badge, and label.
func _create_slot(color: Color, label_text: String, count: int, tooltip: String) -> Control:
	var slot := Panel.new()
	slot.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
	slot.tooltip_text = tooltip
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.15, 0.15, 0.15)
	bg.border_color = Color(0.4, 0.4, 0.4)
	bg.set_border_width_all(1)
	bg.set_corner_radius_all(2)
	slot.add_theme_stylebox_override("panel", bg)
	if color != Color.TRANSPARENT:
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
		cnt_lbl.add_theme_color_override("font_outline_color", Color.BLACK)
		cnt_lbl.add_theme_constant_override("outline_size", 1)
		cnt_lbl.position = Vector2(SLOT_SIZE - 18, SLOT_SIZE - 16)
		cnt_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(cnt_lbl)
	if not label_text.is_empty():
		var lbl := Label.new()
		lbl.text = label_text
		lbl.add_theme_font_size_override("font_size", 7)
		lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		lbl.position = Vector2(2, 1)
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(lbl)
	return slot


## Rebuilds the backpack grid from _local_inventory (10 slots, 5 columns).
func _refresh_inventory_ui() -> void:
	if _inventory_vbox == null:
		return
	for child in _inventory_vbox.get_children():
		child.queue_free()
	var row: HBoxContainer = null
	for i in range(10):
		if i % SLOT_COLS == 0:
			row = HBoxContainer.new()
			row.add_theme_constant_override("separation", 2)
			_inventory_vbox.add_child(row)
		if i < _local_inventory.size():
			var slot_data: Array = _local_inventory[i]
			var item_id: String = slot_data[0]
			var count: int = slot_data[1]
			var item_name: String = slot_data[2] if slot_data.size() > 2 else item_id
			var item_color_hex: String = slot_data[3] if slot_data.size() > 3 else "#FF00FF"
			var inv_sprite: String = str(slot_data[4]) if slot_data.size() > 4 else ""
			var color := Color.from_string(item_color_hex, Color.MAGENTA)
			var slot := _create_slot(color, "", count, item_name)
			var idx := i
			slot.gui_input.connect(func(event: InputEvent):
				if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
					_show_inv_context(idx, slot.get_global_rect().position + Vector2(SLOT_SIZE, 0))
				elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
					start_drag("inventory", idx, -1, "", color, 1, inv_sprite)
			)
			row.add_child(slot)
		else:
			row.add_child(_create_slot(Color.TRANSPARENT, "", 0, "Empty"))


## Shows a right-click context menu (Equip / Drop) for an inventory slot.
func _show_inv_context(slot_index: int, pos: Vector2) -> void:
	var popup := PopupMenu.new()
	popup.add_item("Equip", 0)
	popup.add_item("Drop", 1)
	popup.id_pressed.connect(func(id: int):
		if id == 0: client.rpc_id(1, "rpc_equip_item", slot_index)
		elif id == 1: client.rpc_id(1, "rpc_drop_item", slot_index)
		popup.queue_free()
	)
	popup.popup_hide.connect(func(): popup.queue_free())
	_inventory_layer.add_child(popup)
	popup.position = Vector2i(int(pos.x), int(pos.y))
	popup.popup()


## Stores the latest inventory data from the server and refreshes the UI.
func handle_inventory_update(items: Array) -> void:
	_local_inventory = items
	_refresh_inventory_ui()


## Stores the latest equipment data from the server and refreshes the UI.
func handle_equipment_update(data: Array) -> void:
	_local_equipment = data
	_refresh_equipment_ui()


## Rebuilds the equipment grid (head/weapon, armor/legs layout).
func _refresh_equipment_ui() -> void:
	if _equipment_vbox == null:
		return
	for child in _equipment_vbox.get_children():
		child.queue_free()
	var layout := [["head", "weapon"], ["armor", "legs"]]
	for row_slots in layout:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 2)
		for slot_name in row_slots:
			var item_id := ""
			var item_name := ""
			var item_color_hex := "#333333"
			var item_sprite := ""
			for entry in _local_equipment:
				if entry[0] == slot_name:
					item_id = entry[1]
					item_name = entry[2] if entry.size() > 2 else item_id
					item_color_hex = entry[3] if entry.size() > 3 else "#333333"
					item_sprite = str(entry[5]) if entry.size() > 5 else ""
					break
			var color := Color.from_string(item_color_hex, Color(0.2, 0.2, 0.2))
			var tooltip := "%s: %s" % [slot_name.capitalize(), item_name] if not item_id.is_empty() else "%s: (empty)" % slot_name.capitalize()
			var slot := _create_slot(color if not item_id.is_empty() else Color.TRANSPARENT, slot_name.left(3).capitalize(), 0, tooltip)
			if not item_id.is_empty():
				var sn: String = slot_name
				var drag_col := color
				var drag_spr := item_sprite
				slot.gui_input.connect(func(event: InputEvent):
					if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
						client.rpc_id(1, "rpc_unequip_item", sn)
					elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
						start_drag("equipment", -1, -1, sn, drag_col, 1, drag_spr)
				)
			row.add_child(slot)
		_equipment_vbox.add_child(row)


#  GROUND ITEMS

## Adds or removes a ground item at the given tile and refreshes its world marker.
func handle_ground_item(x: int, y: int, z: int, item_id: String, count: int, present: bool, sprite: String = "") -> void:
	var pos := Vector3i(x, y, z)
	if present and count > 0:
		if not _ground_items.has(pos):
			_ground_items[pos] = []
		var items: Array = _ground_items[pos]
		# Check if this is a stackable item update (count changed on existing stack)
		# Stackable items only have one entry per item_id -- update its count.
		# Non-stackable items (count=1) always add a new entry.
		var merged := false
		if count > 1:
			# Stackable -- find and update existing entry
			for slot in items:
				if slot["item_id"] == item_id:
					slot["count"] = count
					if not sprite.is_empty():
						slot["sprite"] = sprite
					merged = true
					break
		if not merged:
			var entry := {"item_id": item_id, "count": count}
			if not sprite.is_empty():
				entry["sprite"] = sprite
			items.append(entry)
	else:
		# Remove one entry of this item_id (from the top of the stack)
		if _ground_items.has(pos):
			var items: Array = _ground_items[pos]
			for i in range(items.size() - 1, -1, -1):
				if items[i]["item_id"] == item_id:
					items.remove_at(i)
					break  # Only remove one entry per removal broadcast
			if items.is_empty():
				_ground_items.erase(pos)
	_update_ground_item_display(pos)


## Sends a pickup RPC for the top item on the stack at the given tile.
func try_pickup_at(tile_pos: Vector2i) -> void:
	var z := 7
	var pos := Vector3i(tile_pos.x, tile_pos.y, z)
	if not _ground_items.has(pos):
		pos = Vector3i(tile_pos.x, tile_pos.y, client._current_z)
		if not _ground_items.has(pos):
			return
	var items: Array = _ground_items[pos]
	if items.is_empty():
		return
	var top: Dictionary = items[items.size() - 1]  # Top of stack (last added)
	client.rpc_id(1, "rpc_pickup_item", pos.x, pos.y, pos.z, str(top["item_id"]))


## Returns the top ground item dict at the tile, or empty if none.
func get_ground_item_at(tile_pos: Vector2i) -> Dictionary:
	var pos := Vector3i(tile_pos.x, tile_pos.y, client._current_z)
	if _ground_items.has(pos) and not _ground_items[pos].is_empty():
		return _ground_items[pos][_ground_items[pos].size() - 1]  # Top of stack
	return {}


## Updates or creates the world-space sprite/dot marker for ground items at a position.
func _update_ground_item_display(pos: Vector3i) -> void:
	var node_name := "GroundItem_%d_%d_%d" % [pos.x, pos.y, pos.z]
	var existing: Node = client._world.get_node_or_null(node_name)
	if existing != null:
		existing.free()
	if not _ground_items.has(pos) or _ground_items[pos].is_empty():
		return
	var marker := Node2D.new()
	marker.name = node_name
	marker.position = Vector2(pos.x * TILE_SIZE, pos.y * TILE_SIZE)
	marker.z_index = 2
	var items: Array = _ground_items[pos]
	# Render all items on the tile, bottom to top (like Tibia)
	for i in range(items.size()):
		var item: Dictionary = items[i]
		var sprite_path: String = str(item.get("sprite", ""))
		var tex: Texture2D = client.ui._get_item_texture(sprite_path) if client.ui else null
		if tex != null:
			var spr := Sprite2D.new()
			spr.texture = tex
			spr.centered = false
			spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			spr.z_index = i
			var tex_size := tex.get_size()
			if tex_size.x > 0 and tex_size.y > 0:
				var scale_val := minf(float(TILE_SIZE) / tex_size.x, float(TILE_SIZE) / tex_size.y)
				spr.scale = Vector2(scale_val, scale_val)
				spr.position = Vector2(
					(TILE_SIZE - tex_size.x * scale_val) / 2.0,
					(TILE_SIZE - tex_size.y * scale_val) / 2.0)
			marker.add_child(spr)
		else:
			var dot := ColorRect.new()
			dot.size = Vector2(12, 12)
			dot.position = Vector2(10, 10)
			dot.color = Color.GOLD
			dot.z_index = i
			marker.add_child(dot)
	client._world.add_child(marker)


#  DRAG-AND-DROP SYSTEM

## Begins a drag operation from the given source (inventory, equipment, container, or ground).
func start_drag(source_type: String, source_index: int, container_id: int, source_slot: String, color: Color, item_count: int = 1, sprite_path: String = "") -> void:
	_dragging = true
	_drag_source_type = source_type
	_drag_source_index = source_index
	_drag_source_slot = source_slot
	_drag_color = color
	_drag_container_id = container_id
	_drag_max_count = item_count
	# Determine count based on modifiers
	if Input.is_key_pressed(KEY_SHIFT):
		_drag_count = 1  # Take one
		_drag_pending_slider = false
	elif Input.is_key_pressed(KEY_CTRL):
		_drag_count = 0  # Take all
		_drag_pending_slider = false
	elif item_count > 1:
		_drag_count = 0  # Will show slider on drop
		_drag_pending_slider = true
	else:
		_drag_count = 0  # Single item, take all
		_drag_pending_slider = false
	if _drag_preview != null and is_instance_valid(_drag_preview):
		_drag_preview.queue_free()
	# Try to show the item sprite; fall back to a colored rectangle
	var tex: Texture2D = client.ui._get_item_texture(sprite_path) if client and client.ui else null
	if tex != null:
		var img := TextureRect.new()
		img.texture = tex
		img.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		img.size = Vector2(SLOT_SIZE - 4, SLOT_SIZE - 4)
		img.modulate = Color(1, 1, 1, 0.85)
		img.z_index = 100
		img.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_drag_preview = img
	else:
		var rect := ColorRect.new()
		rect.size = Vector2(SLOT_SIZE - 8, SLOT_SIZE - 8)
		rect.color = Color(color.r, color.g, color.b, 0.7)
		rect.z_index = 100
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_drag_preview = rect
	var layer := client.get_node_or_null("DragLayer")
	if layer == null:
		layer = CanvasLayer.new()
		layer.name = "DragLayer"
		layer.layer = 50
		client.add_child(layer)
	layer.add_child(_drag_preview)


## Moves the drag preview ColorRect to follow the mouse cursor.
func update_drag_preview() -> void:
	if not _dragging or _drag_preview == null:
		return
	var mouse_pos := client.get_viewport().get_mouse_position()
	_drag_preview.position = mouse_pos - Vector2(SLOT_SIZE / 2.0, SLOT_SIZE / 2.0)


## Completes a drag: determines the drop target and issues the appropriate move RPC.
func end_drag(screen_pos: Vector2) -> void:
	if not _dragging:
		return
	_dragging = false
	if _drag_preview != null and is_instance_valid(_drag_preview):
		_drag_preview.queue_free()
		_drag_preview = null

	var bp_uid: int = -client._local_peer_id
	var move_count: int = _drag_count  # 0 = all

	# Determine source UID and index
	var from_uid: int = 0
	var from_index: int = _drag_source_index
	var from_slot: String = _drag_source_slot
	match _drag_source_type:
		"inventory":
			from_uid = bp_uid
		"equipment":
			from_uid = -1
			from_slot = _drag_source_slot
		"container":
			from_uid = _drag_container_id
		"ground":
			from_uid = 0
		"corpse_move":
			# Check if dropped on equipment slot -- pick up and equip
			var equip_check: String = client.ui.get_equip_slot_at(screen_pos)
			if not equip_check.is_empty():
				client.rpc_id(1, "rpc_pickup_ground_container", _drag_container_id)
				return
			# Otherwise move the container on the ground
			var world_pos: Vector2 = client.get_world_mouse_position()
			var tile_pos := Vector2i(int(floor(world_pos.x / TILE_SIZE)), int(floor(world_pos.y / TILE_SIZE)))
			var container_drop_z: int = client.map.resolve_drop_z(tile_pos.x, tile_pos.y, client._current_z)
			client.rpc_id(1, "rpc_move_container", _drag_container_id,
				tile_pos.x, tile_pos.y, container_drop_z)
			return

	# Build the move parameters for potential slider callback
	var drop_world_pos: Vector2 = client.get_world_mouse_position()
	var drop_tile := Vector2i(int(floor(drop_world_pos.x / TILE_SIZE)), int(floor(drop_world_pos.y / TILE_SIZE)))
	var move_params := {
		"from_uid": from_uid, "from_index": from_index,
		"from_slot": from_slot, "screen_pos": screen_pos,
		"drop_tile": drop_tile,
	}

	# If pending slider (stackable item, no modifier held), show slider popup
	if _drag_pending_slider and _drag_max_count > 1:
		_show_count_slider(move_params, _drag_max_count)
		return

	_execute_move(move_params, move_count)


## Shows a slider popup so the player can choose how many items to move.
func _show_count_slider(params: Dictionary, max_count: int) -> void:
	_slider_open = true

	var layer := client.get_node_or_null("DragLayer")
	if layer == null:
		layer = CanvasLayer.new()
		layer.name = "DragLayer"
		layer.layer = 50
		client.add_child(layer)

	# Full-screen transparent blocker to prevent clicks reaching the game world
	var blocker := ColorRect.new()
	blocker.name = "SliderBlocker"
	blocker.color = Color(0, 0, 0, 0.0)
	blocker.set_anchors_preset(Control.PRESET_FULL_RECT)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(blocker)

	if _count_slider_scene == null:
		_slider_open = false
		blocker.queue_free()
		return
	var popup: PanelContainer = _count_slider_scene.instantiate()

	var slider: HSlider = popup.get_node_or_null("%Slider")
	var count_label: Label = popup.get_node_or_null("%CountLabel")
	var ok_btn: Button = popup.get_node_or_null("%OkBtn")
	var cancel_btn: Button = popup.get_node_or_null("%CancelBtn")

	if slider:
		slider.min_value = 1
		slider.max_value = max_count
		slider.value = max_count
	if count_label:
		count_label.text = str(max_count)
	if slider and count_label:
		slider.value_changed.connect(func(val: float): count_label.text = str(int(val)))

	if ok_btn and slider:
		ok_btn.pressed.connect(func():
			var chosen: int = int(slider.value)
			_slider_open = false
			blocker.queue_free()
			popup.queue_free()
			_execute_move(params, chosen)
		)
	if cancel_btn:
		cancel_btn.pressed.connect(func():
			_slider_open = false
			blocker.queue_free()
			popup.queue_free()
		)

	layer.add_child(popup)
	var mouse_pos := client.get_viewport().get_mouse_position()
	popup.position = Vector2(mouse_pos.x - 80, mouse_pos.y - 60)


func _execute_move(params: Dictionary, count: int) -> void:
	var from_uid: int = params["from_uid"]
	var from_index: int = params["from_index"]
	var from_slot: String = params["from_slot"]
	var screen_pos: Vector2 = params["screen_pos"]
	var bp_uid: int = -client._local_peer_id

	# Check if dropped on a sidebar container slot
	var container_hit: Dictionary = client.ui.get_container_slot_at(screen_pos)
	if not container_hit.is_empty():
		var to_uid: int = int(container_hit["container_uid"])
		var to_slot: int = int(container_hit["slot_index"])
		if _drag_source_type == "ground":
			client.rpc_id(1, "rpc_move_item", 0, 0, to_uid, to_slot,
				_drag_ground_pos.x, _drag_ground_pos.y, _drag_ground_pos.z, count, _drag_ground_item_id)
		else:
			client.rpc_id(1, "rpc_move_item", from_uid, from_index, to_uid, to_slot,
				0, 0, 0, count, from_slot)
		return

	# Check if dropped on an equipment slot
	var equip_hit: String = client.ui.get_equip_slot_at(screen_pos)
	if not equip_hit.is_empty():
		if _drag_source_type == "inventory":
			client.rpc_id(1, "rpc_equip_item", _drag_source_index)
		elif _drag_source_type == "container":
			client.rpc_id(1, "rpc_move_item", from_uid, from_index, -1, -1,
				0, 0, 0, count, equip_hit)
		elif _drag_source_type == "ground":
			client.rpc_id(1, "rpc_pickup_item", _drag_ground_pos.x, _drag_ground_pos.y,
				_drag_ground_pos.z, _drag_ground_item_id)
		return

	# Dropped on the game world -- drop to ground
	var tile_pos: Vector2i = params.get("drop_tile", Vector2i.ZERO)
	# Resolve z-level: if there's a roof tile above, drop on the roof instead
	var drop_z: int = client.map.resolve_drop_z(tile_pos.x, tile_pos.y, client._current_z)

	if _drag_source_type == "ground":
		var dest := Vector3i(tile_pos.x, tile_pos.y, drop_z)
		if dest != _drag_ground_pos:
			client.rpc_id(1, "rpc_move_ground_item", _drag_ground_pos.x, _drag_ground_pos.y, _drag_ground_pos.z,
				_drag_ground_item_id, dest.x, dest.y, dest.z, count)
	else:
		client.rpc_id(1, "rpc_move_item", from_uid, from_index, 0, -1,
			tile_pos.x, tile_pos.y, drop_z, count, from_slot)


## Returns the inventory slot index under the given screen position, or -1.
func _get_inv_slot_at_screen(screen_pos: Vector2) -> int:
	if _inventory_vbox == null or not _inventory_visible:
		return -1
	var slot_idx := 0
	for row in _inventory_vbox.get_children():
		if not row is HBoxContainer:
			continue
		for child in row.get_children():
			var rect: Rect2 = child.get_global_rect()
			if rect.has_point(screen_pos):
				return slot_idx
			slot_idx += 1
	return -1


## Returns the equipment slot name (e.g. "head") under the screen position, or "".
func _get_equip_slot_at_screen(screen_pos: Vector2) -> String:
	if _equipment_vbox == null or not _inventory_visible:
		return ""
	var layout := [["head", "weapon"], ["armor", "legs"]]
	var row_idx := 0
	for row in _equipment_vbox.get_children():
		if not row is HBoxContainer:
			row_idx += 1
			continue
		var col_idx := 0
		for child in row.get_children():
			var rect: Rect2 = child.get_global_rect()
			if rect.has_point(screen_pos):
				if row_idx < layout.size() and col_idx < layout[row_idx].size():
					return layout[row_idx][col_idx]
			col_idx += 1
		row_idx += 1
	return ""
