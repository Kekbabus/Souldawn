#  client_ui.gd -- scene-based UI manager
#
#  Loads ui_hud.tscn, resolves node references, wires data from RPCs.
#  Replaces programmatic UI in client_combat, client_inventory,
#  client_chat, client_containers.
extends Node

const SLOT_SIZE := 36
const SLOT_COLS := 5
const MAX_CONTAINER_SLOTS := 20

var client: Node2D = null  # client_main.gd

# Texture cache for item sprites
var _texture_cache: Dictionary = {}  # sprite_path → Texture2D

var _hud: Control = null
var _hud_layer: CanvasLayer = null
var _game_viewport: SubViewport = null

# Sidebar
var _health_bar_fill: ColorRect = null
var _health_value_label: Label = null
var _health_bar_bg: ColorRect = null
var _mana_bar_fill: ColorRect = null
var _mana_value_label: Label = null
var _mana_bar_bg: ColorRect = null
var _mana_bar_label: Label = null

# Equipment grid — slot_name → Panel node
var _equip_slots: Dictionary = {}
var _cap_label: Label = null

# Stats panel labels
var _stats_attack_label: Label = null
var _stats_defense_label: Label = null
var _stats_armor_label: Label = null
var _stats_level_label: Label = null
var _stats_xp_label: Label = null
var _stats_speed_label: Label = null
var _stats_food_label: Label = null

# Skills panel labels
var _skills_labels: Dictionary = {}  # skill_name → Label
var _stats_panel: PanelContainer = null
var _skills_panel: PanelContainer = null
var _status_icons: Dictionary = {}  # status_name -> PanelContainer

# Preloaded sidebar sub-scenes
var _stats_scene: PackedScene = null
var _skills_scene: PackedScene = null
var _status_bar_scene: PackedScene = null
var _sidebar_buttons_scene: PackedScene = null
var _open_chat_popup_scene: PackedScene = null

# Container stack (right sidebar)
var _container_stack: VBoxContainer = null

# Chat — dynamic tab system
var _chat_history: RichTextLabel = null
var _chat_input: LineEdit = null
var _tab_row: HBoxContainer = null
var _open_chat_btn: Button = null
# Each tab: {id: String, label: String, button: Button, messages: Array}
var _chat_tab_data: Array = []
var _active_tab_index: int = 0
# Open chat popup
var _open_chat_popup: PanelContainer = null
# Right-click context menu for player names in chat
var _chat_context_menu: PopupMenu = null
var _chat_context_target_name: String = ""
# Tab flash tracking
var _flash_timers: Dictionary = {}  # tab_index → Timer
# PM notification banner (top of game viewport)
var _pm_banner: PanelContainer = null
var _pm_banner_tween: Tween = null
var _pm_banner_scene: PackedScene = null
const PM_BANNER_DURATION := 5.0  # Seconds before fade

# Death is handled by client_combat.gd scene-based dialog
var _death_overlay = null  # Legacy — unused
var _death_label = null    # Legacy — unused

# Container window tracking
var _container_windows: Dictionary = {}  # container_id → {instance, slot_grid, ...}
var _container_scene: PackedScene = null
var _item_slot_scene: PackedScene = null
var _outfit_scene: PackedScene = null
var _outfit_window: PanelContainer = null
var _hotkey_scene: PackedScene = null
var _hotkey_window: PanelContainer = null

# Entity overlay system — HUD-layer name labels + health bars
var _entity_overlay_scene: PackedScene = null
# Tracked overlays: key → { "overlay": VBoxContainer, "node": Node2D, "name_label": Label, "hp_bg": ColorRect, "hp_fill": ColorRect }
var _entity_overlays: Dictionary = {}

# Hotkey bar: F1-F12 bindings
# Each entry: { "text": String, "auto_send": bool }
var _hotkeys: Array = []
const HOTKEY_COUNT := 12
const HOTKEY_SAVE_PATH := "user://hotkeys.json"

# Equipment slot mapping: design slot name → server equip_slot value
const EQUIP_SLOT_MAP := {
	"Neck": "neck",
	"Helm": "head",
	"Backpack": "backpack",
	"LeftHand": "shield",
	"Armor": "armor",
	"RightHand": "weapon",
	"Ring": "ring",
	"Legs": "legs",
	"Ammo": "arrow",
	"Boots": "boots",
}

# Placeholder sprites loaded from sprite_config.json at runtime
var _equip_placeholder_sprites: Dictionary = {}

## Loads equipment placeholder sprites from sprite_config.json.
func _load_equip_placeholders() -> void:
	var file := FileAccess.open("res://datapacks/sprite_config.json", FileAccess.READ)
	if file == null:
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) == OK and json.data is Dictionary:
		_equip_placeholder_sprites = json.data.get("equipment_placeholders", {})
	file.close()


## Initializes the HUD scene, resolves node references, and wires sidebar/chat.
func setup_ui() -> void:
	_load_equip_placeholders()
	_stats_scene = load("res://Scenes/ui_stats_panel.tscn")
	_skills_scene = load("res://Scenes/ui_skills_panel.tscn")
	_status_bar_scene = load("res://Scenes/ui_status_bar.tscn")
	_sidebar_buttons_scene = load("res://Scenes/ui_sidebar_buttons.tscn")
	_open_chat_popup_scene = load("res://Scenes/ui_open_chat_popup.tscn")
	_container_scene = load("res://Scenes/ui_container_window.tscn")
	_item_slot_scene = load("res://Scenes/ui_item_slot.tscn")
	_outfit_scene = load("res://Scenes/ui_outfit_window.tscn")
	_hotkey_scene = load("res://Scenes/ui_hotkeys_window.tscn")
	_load_hotkeys()

	var hud_scene := load("res://Scenes/ui_hud.tscn")
	if hud_scene == null:
		push_error("client_ui: failed to load ui_hud.tscn")
		return
	_hud = hud_scene.instantiate()
	_hud.visible = false

	# Add HUD as a CanvasLayer so it renders on top of everything
	_hud_layer = CanvasLayer.new()
	_hud_layer.name = "HUDLayer"
	_hud_layer.layer = 10
	_hud_layer.visible = false
	client.add_child(_hud_layer)
	_hud_layer.add_child(_hud)

	# Resolve the SubViewport for the game world
	_game_viewport = _hud.get_node_or_null("MainHBox/CenterColumn/GameViewportContainer/GameViewport")

	_resolve_sidebar()
	_resolve_chat()
	_setup_mana_bar_color()
	_setup_pm_banner()

	# Disable focus on all UI controls so arrow keys don't cycle through buttons
	_disable_focus_recursive(_hud)
	# Re-enable focus on chat input only
	if _chat_input:
		_chat_input.focus_mode = Control.FOCUS_CLICK


## Resolves sidebar node references: health/mana bars, equipment grid, stats/skills panels.
func _resolve_sidebar() -> void:
	var sidebar := _hud.get_node_or_null("MainHBox/RightSidebar")
	if sidebar == null:
		push_warning("client_ui: RightSidebar not found")
		return

	# Health bar
	var hb := sidebar.get_node_or_null("VBox/HealthBar")
	if hb:
		_health_bar_bg = hb.get_node_or_null("BarBG")
		_health_bar_fill = hb.get_node_or_null("BarBG/Fill")
		_health_value_label = hb.get_node_or_null("BarBG/ValueLabel")
		var bar_label: Label = hb.get_node_or_null("BarLabel")
		if bar_label:
			bar_label.text = "health"

	# Mana bar
	var mb := sidebar.get_node_or_null("VBox/ManaBar")
	if mb:
		_mana_bar_bg = mb.get_node_or_null("BarBG")
		_mana_bar_fill = mb.get_node_or_null("BarBG/Fill")
		_mana_value_label = mb.get_node_or_null("BarBG/ValueLabel")
		_mana_bar_label = mb.get_node_or_null("BarLabel")
		if _mana_bar_label:
			_mana_bar_label.text = "mana"

	# Equipment grid
	var eg := sidebar.get_node_or_null("VBox/EquipmentGrid/VBox")
	if eg:
		# Row1: Neck, Helm, Backpack
		_equip_slots["Neck"] = eg.get_node_or_null("Row1/Neck")
		_equip_slots["Helm"] = eg.get_node_or_null("Row1/Helm")
		_equip_slots["Backpack"] = eg.get_node_or_null("Row1/Backpack")
		# Row2: LeftHand, Armor, RightHand
		_equip_slots["LeftHand"] = eg.get_node_or_null("Row2/LeftHand")
		_equip_slots["Armor"] = eg.get_node_or_null("Row2/Armor")
		_equip_slots["RightHand"] = eg.get_node_or_null("Row2/RightHand")
		# Row3: Ring, Legs, Ammo
		_equip_slots["Ring"] = eg.get_node_or_null("Row3/Ring")
		_equip_slots["Legs"] = eg.get_node_or_null("Row3/Legs")
		_equip_slots["Ammo"] = eg.get_node_or_null("Row3/Ammo")
		# Row4: Boots, Cap
		_equip_slots["Boots"] = eg.get_node_or_null("Row4/Boots")
		var cap_panel: Panel = eg.get_node_or_null("Row4/Cap")
		if cap_panel:
			_cap_label = cap_panel.get_node_or_null("Label")

	# Stats panel — scene-based sidebar panels below equipment grid
	var sidebar_vbox := sidebar.get_node_or_null("VBox")
	if sidebar_vbox:
		var scroll_ref: Node = sidebar_vbox.get_node_or_null("ContainerScroll")

		if _status_bar_scene:
			var status_bar: HBoxContainer = _status_bar_scene.instantiate()
			if scroll_ref:
				sidebar_vbox.add_child(status_bar)
				sidebar_vbox.move_child(status_bar, scroll_ref.get_index())
			for status_name in ["combat", "haste", "burning", "poisoned", "paralysed", "electrocuted", "magic_shield"]:
				var icon: PanelContainer = status_bar.get_node_or_null(status_name)
				if icon:
					_status_icons[status_name] = icon

		if _sidebar_buttons_scene:
			var btn_row: HBoxContainer = _sidebar_buttons_scene.instantiate()
			if scroll_ref:
				sidebar_vbox.add_child(btn_row)
				sidebar_vbox.move_child(btn_row, scroll_ref.get_index())
			var stats_btn: Button = btn_row.get_node_or_null("%StatsBtn")
			if stats_btn: stats_btn.pressed.connect(func(): _toggle_stats_panel())
			var skills_btn: Button = btn_row.get_node_or_null("%SkillsBtn")
			if skills_btn: skills_btn.pressed.connect(func(): _toggle_skills_panel())
			var keys_btn: Button = btn_row.get_node_or_null("%KeysBtn")
			if keys_btn: keys_btn.pressed.connect(func(): toggle_hotkey_window())
			var outfit_btn: Button = btn_row.get_node_or_null("%OutfitBtn")
			if outfit_btn: outfit_btn.pressed.connect(func(): toggle_outfit_window())
			var logout_btn: Button = btn_row.get_node_or_null("%LogoutBtn")
			if logout_btn: logout_btn.pressed.connect(func():
				if client: client.rpc_id(1, "rpc_logout")
			)

		if _stats_scene:
			_stats_panel = _stats_scene.instantiate()
			_stats_level_label = _stats_panel.get_node_or_null("%LevelLabel")
			_stats_xp_label = _stats_panel.get_node_or_null("%XPLabel")
			_stats_attack_label = _stats_panel.get_node_or_null("%AttackLabel")
			_stats_defense_label = _stats_panel.get_node_or_null("%DefenseLabel")
			_stats_armor_label = _stats_panel.get_node_or_null("%ArmorLabel")
			_stats_speed_label = _stats_panel.get_node_or_null("%SpeedLabel")
			_stats_food_label = _stats_panel.get_node_or_null("%FoodLabel")
			if scroll_ref:
				sidebar_vbox.add_child(_stats_panel)
				sidebar_vbox.move_child(_stats_panel, scroll_ref.get_index())

		if _skills_scene:
			_skills_panel = _skills_scene.instantiate()
			var skill_row_map := {
				"fist": "FistRow", "club": "ClubRow", "sword": "SwordRow",
				"axe": "AxeRow", "distance": "DistRow", "shielding": "ShieldRow",
				"magic_level": "MagicRow",
			}
			for skill_name in skill_row_map:
				var row_name: String = skill_row_map[skill_name]
				var row: HBoxContainer = _skills_panel.get_node_or_null("VBox/" + row_name)
				if row:
					var val_lbl: Label = row.get_node_or_null("Value")
					var bar_bg: ColorRect = row.get_node_or_null("BarBG")
					var bar_fill: ColorRect = row.get_node_or_null("BarBG/Fill") if bar_bg else null
					_skills_labels[skill_name] = {"value": val_lbl, "bar_bg": bar_bg, "bar_fill": bar_fill}
			if scroll_ref:
				sidebar_vbox.add_child(_skills_panel)
				sidebar_vbox.move_child(_skills_panel, scroll_ref.get_index())

	# Container stack
	_container_stack = sidebar.get_node_or_null("VBox/ContainerScroll/ContainerStack")


## Resolves chat panel node references and creates default tabs (local, server log, global).
func _resolve_chat() -> void:
	var cp := _hud.get_node_or_null("MainHBox/CenterColumn/ChatPanel")
	if cp == null:
		push_warning("client_ui: ChatPanel not found")
		return

	_chat_history = cp.get_node_or_null("VBox/History")
	_chat_input = cp.get_node_or_null("VBox/InputBox")
	_tab_row = cp.get_node_or_null("VBox/TabRow")

	if _tab_row:
		# Remove the placeholder tabs from the scene
		for child in _tab_row.get_children():
			child.queue_free()

		# Create default tabs
		_add_chat_tab("local", "local")
		_add_chat_tab("server_log", "server log")
		_add_chat_tab("global", "global chat")

		# Spacer
		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_tab_row.add_child(spacer)

		# Open Chat button
		_open_chat_btn = Button.new()
		_open_chat_btn.text = "open chat"
		_open_chat_btn.custom_minimum_size = Vector2(80, 24)
		_open_chat_btn.add_theme_font_size_override("font_size", 10)
		_open_chat_btn.pressed.connect(_show_open_chat_popup)
		_tab_row.add_child(_open_chat_btn)

		# Select local tab by default
		_switch_tab(0)

	if _chat_input:
		_chat_input.text_submitted.connect(_on_chat_submitted)
		_chat_input.focus_mode = Control.FOCUS_ALL
		# Block arrow/movement keys from moving the text cursor
		_chat_input.gui_input.connect(_on_chat_gui_input)

	# Right-click context menu on chat history (player names)
	if _chat_history:
		_chat_history.gui_input.connect(_on_chat_history_gui_input)


## Sets initial colors for the mana (blue) and health (green) bars.
func _setup_mana_bar_color() -> void:
	if _mana_bar_fill:
		_mana_bar_fill.color = Color(0.2, 0.2, 0.9, 1)
	if _health_bar_fill:
		_health_bar_fill.color = Color(0, 0.8, 0, 1)


#  ENTITY OVERLAYS — HUD-layer name labels + health bars for all entities

## Lazily loads and caches the entity overlay scene.
func _get_entity_overlay_scene() -> PackedScene:
	if _entity_overlay_scene == null:
		_entity_overlay_scene = load("res://Scenes/ui_entity_overlay.tscn")
	return _entity_overlay_scene


## Creates a HUD overlay for an entity (player, monster, NPC).
func register_entity_overlay(key: String, world_node: Node2D, display_name: String, name_color: Color = Color(0, 0.8, 0), show_health_bar: bool = true) -> void:
	if _entity_overlays.has(key):
		unregister_entity_overlay(key)
	var scene := _get_entity_overlay_scene()
	if scene == null or _hud_layer == null:
		return
	var overlay: VBoxContainer = scene.instantiate()
	var name_label: Label = overlay.get_node_or_null("NameLabel")
	var hp_bg: ColorRect = overlay.get_node_or_null("HealthBarBG")
	var hp_fill: ColorRect = hp_bg.get_node_or_null("Fill") if hp_bg else null
	if name_label:
		name_label.text = display_name
		name_label.add_theme_color_override("font_color", name_color)
	if not show_health_bar and hp_bg:
		hp_bg.visible = false
	_hud_layer.add_child(overlay)
	_entity_overlays[key] = {
		"overlay": overlay,
		"node": world_node,
		"name_label": name_label,
		"hp_bg": hp_bg,
		"hp_fill": hp_fill,
	}


## Removes a HUD overlay for the given entity key and frees the node.
func unregister_entity_overlay(key: String) -> void:
	if _entity_overlays.has(key):
		var data: Dictionary = _entity_overlays[key]
		var overlay = data.get("overlay")
		if overlay != null and is_instance_valid(overlay):
			overlay.queue_free()
		_entity_overlays.erase(key)


## Updates the health bar fill and color for an entity overlay.
func update_entity_overlay_health(key: String, health: int, max_health: int) -> void:
	if not _entity_overlays.has(key):
		return
	var data: Dictionary = _entity_overlays[key]
	var hp_bg: ColorRect = data.get("hp_bg")
	var hp_fill: ColorRect = data.get("hp_fill")
	if hp_bg == null or hp_fill == null:
		return
	var mhp := maxi(max_health, 1)
	var pct := clampf(float(health) / float(mhp), 0.0, 1.0)
	# Use custom_minimum_size.x (always 40) since size.x may be 0 before first layout
	var bar_width: float = maxf(hp_bg.size.x, hp_bg.custom_minimum_size.x)
	hp_fill.size.x = bar_width * pct
	# Color gradient: green → yellow → red
	if pct > 0.5:
		hp_fill.color = Color(0, 0.8, 0)
	elif pct > 0.25:
		hp_fill.color = Color(0.9, 0.9, 0)
	else:
		hp_fill.color = Color(0.9, 0, 0)


## Called every frame to position all entity overlays in screen space.
func update_entity_overlays() -> void:
	var game_vp: SubViewport = get_game_viewport()
	if game_vp == null:
		return
	var canvas_xform := game_vp.get_canvas_transform()
	var gvc: Control = _hud.get_node_or_null("MainHBox/CenterColumn/GameViewportContainer") if _hud else null
	var gvc_offset := Vector2.ZERO
	var gvc_rect := Rect2()
	if gvc:
		gvc_offset = gvc.global_position
		gvc_rect = gvc.get_global_rect()

	for key in _entity_overlays:
		var data: Dictionary = _entity_overlays[key]
		var overlay = data.get("overlay")
		var node = data.get("node")
		if overlay == null or not is_instance_valid(overlay):
			continue
		if node == null or not is_instance_valid(node):
			overlay.visible = false
			continue
		if not node.visible:
			overlay.visible = false
			continue
		# Check if overlay is z-hidden (set by update_z_visibility)
		if data.get("z_hidden", false):
			overlay.visible = false
			continue
		# Convert world position to screen
		var world_pos: Vector2 = node.global_position + Vector2(16, -4)
		var screen_pos: Vector2 = canvas_xform * world_pos + gvc_offset
		# Center the overlay horizontally
		var ow: float = overlay.size.x
		var final_pos := Vector2(screen_pos.x - ow / 2.0, screen_pos.y - overlay.size.y)
		overlay.position = final_pos
		# Hide overlays that are outside the game viewport area (behind sidebar/chat panels)
		if gvc_rect.size.x > 0:
			var overlay_center := Vector2(screen_pos.x, screen_pos.y - overlay.size.y / 2.0)
			overlay.visible = gvc_rect.has_point(overlay_center)
		else:
			overlay.visible = true


## Removes all entity overlays and frees their nodes.
func clear_all_entity_overlays() -> void:
	for key in _entity_overlays.keys():
		unregister_entity_overlay(key)
	_entity_overlays.clear()


## Loads the PM banner scene and adds it to the top-center of the game viewport.
func _setup_pm_banner() -> void:
	_pm_banner_scene = load("res://Scenes/ui_pm_banner.tscn")
	var gvc := _hud.get_node_or_null("MainHBox/CenterColumn/GameViewportContainer")
	if gvc == null or _pm_banner_scene == null:
		return
	_pm_banner = _pm_banner_scene.instantiate()
	_pm_banner.visible = false
	_pm_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_pm_banner.offset_top = 6
	_pm_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	gvc.add_child(_pm_banner)


## Shows (or replaces) the PM notification banner at the top of the game screen.
func _show_pm_banner(sender: String, message: String) -> void:
	if _pm_banner == null or not is_instance_valid(_pm_banner):
		return

	# Kill any running fade tween
	if _pm_banner_tween != null and _pm_banner_tween.is_valid():
		_pm_banner_tween.kill()

	# Truncate long messages
	var preview := message
	if preview.length() > 50:
		preview = preview.left(47) + "..."

	var label: Label = _pm_banner.get_node_or_null("Label")
	if label:
		label.text = "%s: %s" % [sender, preview]

	_pm_banner.modulate.a = 1.0
	_pm_banner.visible = true
	_pm_banner.reset_size()

	# Fade out and hide after duration
	_pm_banner_tween = _pm_banner.create_tween()
	_pm_banner_tween.tween_interval(PM_BANNER_DURATION - 1.0)
	_pm_banner_tween.tween_property(_pm_banner, "modulate:a", 0.0, 1.0)
	_pm_banner_tween.tween_callback(func():
		if is_instance_valid(_pm_banner):
			_pm_banner.visible = false
	)


## Recursively disables focus on all Control children so arrow keys aren't captured.
func _disable_focus_recursive(node: Node) -> void:
	if node is Control:
		node.focus_mode = Control.FOCUS_NONE
	for child in node.get_children():
		_disable_focus_recursive(child)


#  SHOW / HIDE

## Makes the HUD layer and HUD root visible.
func show_hud() -> void:
	if _hud_layer:
		_hud_layer.visible = true
	if _hud:
		_hud.visible = true

## Hides the HUD layer and HUD root.
func hide_hud() -> void:
	if _hud_layer:
		_hud_layer.visible = false
	if _hud:
		_hud.visible = false

## Returns the game world SubViewport for coordinate transforms.
func get_game_viewport() -> SubViewport:
	return _game_viewport

## Returns the chat LineEdit for focus management.
func get_chat_input() -> LineEdit:
	return _chat_input


#  HEALTH / MANA / STATS

## Updates the sidebar health bar fill, color gradient, and value label.
func update_health(current: int, max_hp: int) -> void:
	var mhp := maxi(max_hp, 1)
	var pct := clampf(float(current) / float(mhp), 0.0, 1.0)
	if _health_bar_fill and _health_bar_bg:
		_health_bar_fill.size.x = _health_bar_bg.size.x * pct
		# Green → yellow → red gradient
		if pct > 0.5:
			_health_bar_fill.color = Color(0, 0.8, 0, 1)
		elif pct > 0.25:
			_health_bar_fill.color = Color(0.9, 0.9, 0, 1)
		else:
			_health_bar_fill.color = Color(0.9, 0, 0, 1)
	if _health_value_label:
		_health_value_label.text = "%d/%d" % [current, max_hp]

## Updates the sidebar mana bar fill and value label.
func update_mana(current: int, max_mp: int) -> void:
	var mmp := maxi(max_mp, 1)
	var pct := clampf(float(current) / float(mmp), 0.0, 1.0)
	if _mana_bar_fill and _mana_bar_bg:
		_mana_bar_fill.size.x = _mana_bar_bg.size.x * pct
	if _mana_value_label:
		_mana_value_label.text = "%d/%d" % [current, max_mp]

## Updates the capacity label showing current weight vs max capacity.
func update_capacity(current_weight: float, max_capacity: float) -> void:
	if _cap_label:
		_cap_label.text = "%d/%d" % [int(current_weight), int(max_capacity)]


#  EQUIPMENT

## Refreshes all equipment slots with item sprites, tooltips, and interaction handlers.
func update_equipment(data: Array) -> void:
	# Clear all slots first
	for slot_name in _equip_slots:
		var panel: Panel = _equip_slots[slot_name]
		if panel == null:
			continue
		var label: Label = panel.get_node_or_null("Label")
		if label:
			label.visible = false  # Hide text label, show placeholder instead
		# Remove any item visuals (sprites, color rects, containers)
		for child in panel.get_children():
			if child is Label and child.name == "Label":
				continue
			child.queue_free()
		panel.set_meta("item_id", "")
		panel.set_meta("equip_slot", EQUIP_SLOT_MAP.get(slot_name, ""))
		panel.tooltip_text = slot_name
		# Add grayed-out placeholder sprite for empty slot
		var server_slot_name: String = EQUIP_SLOT_MAP.get(slot_name, "")
		var placeholder_path: String = _equip_placeholder_sprites.get(server_slot_name, "")
		if not placeholder_path.is_empty():
			var ph_tex: Texture2D = _get_item_texture(placeholder_path)
			if ph_tex != null:
				var ph_img := TextureRect.new()
				ph_img.name = "Placeholder"
				ph_img.texture = ph_tex
				ph_img.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
				ph_img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				ph_img.position = Vector2(2, 2)
				ph_img.size = Vector2(SLOT_SIZE - 4, SLOT_SIZE - 4)
				ph_img.modulate = Color(1, 1, 1, 0.25)  # Grayed out
				ph_img.mouse_filter = Control.MOUSE_FILTER_IGNORE
				panel.add_child(ph_img)
		# Disconnect old signals
		if panel.gui_input.get_connections().size() > 0:
			for conn in panel.gui_input.get_connections():
				panel.gui_input.disconnect(conn["callable"])

	# Fill equipped items
	for entry in data:
		if not entry is Array or entry.size() < 2:
			continue
		var server_slot: String = str(entry[0])
		var item_id: String = str(entry[1])
		if item_id.is_empty():
			continue
		var item_name: String = str(entry[2]) if entry.size() > 2 else item_id
		var color_hex: String = str(entry[3]) if entry.size() > 3 else "#FF00FF"
		var sprite_path: String = str(entry[5]) if entry.size() > 5 else ""
		# Find matching UI slot
		for slot_name in EQUIP_SLOT_MAP:
			if EQUIP_SLOT_MAP[slot_name] == server_slot:
				var panel: Panel = _equip_slots.get(slot_name)
				if panel == null:
					continue
				var label: Label = panel.get_node_or_null("Label")
				if label:
					label.visible = false
				var color := Color.from_string(color_hex, Color.MAGENTA)
				_create_item_visual(panel, sprite_path, color, SLOT_SIZE)
				panel.set_meta("item_id", item_id)
				var equip_tooltip: String = str(entry[4]) if entry.size() > 4 else item_name
				panel.tooltip_text = equip_tooltip
				# Show count for stackable equipment (ammo)
				var slot_count: int = int(entry[6]) if entry.size() > 6 else 1
				if slot_count > 1:
					var cnt_lbl := Label.new()
					cnt_lbl.text = str(slot_count)
					cnt_lbl.add_theme_font_size_override("font_size", 9)
					cnt_lbl.add_theme_color_override("font_color", Color.WHITE)
					cnt_lbl.add_theme_color_override("font_outline_color", Color.BLACK)
					cnt_lbl.add_theme_constant_override("outline_size", 1)
					cnt_lbl.position = Vector2(SLOT_SIZE - 18, SLOT_SIZE - 16)
					cnt_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
					panel.add_child(cnt_lbl)
				# Right-click to unequip (except backpack — that opens container), left-click to drag
				var sn: String = server_slot
				var drag_col := color
				var drag_sprite := sprite_path
				var is_bp := (server_slot == "backpack")
				panel.gui_input.connect(func(event: InputEvent):
					if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
						if client and is_bp:
							client.rpc_id(1, "rpc_open_backpack")
					elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
						if client and client.inventory:
							client.inventory.start_drag("equipment", -1, -1, sn, drag_col, 1, drag_sprite)
				)
				break

	# (BP right-click is now handled in the loop above)


#  BACKPACK (inventory shown as container in sidebar)
#  CONTAINER WINDOWS

## Opens or updates a container window in the sidebar with the given items.
func open_container(container_id: int, display_name: String, items: Array, capacity: int = -1, sprite: String = "") -> void:
	# If window already exists for this cid, just update its contents
	if _container_windows.has(container_id):
		var data: Dictionary = _container_windows[container_id]
		var slot_grid: GridContainer = data["slot_grid"]
		var slot_count: int = capacity if capacity > 0 else int(data.get("capacity", maxi(items.size(), 1)))
		data["capacity"] = slot_count
		if slot_grid:
			for child in slot_grid.get_children():
				child.queue_free()
			_populate_container_slots(slot_grid, items, container_id, slot_count)
		return

	if _container_scene == null:
		return
	_create_container_window(container_id, display_name, items, capacity, sprite)


## Instantiates a new container window scene and adds it to the sidebar stack.
func _create_container_window(container_id: int, display_name: String, items: Array, capacity: int, sprite: String = "") -> void:
	var instance: PanelContainer = _container_scene.instantiate()
	var title_label: Label = instance.get_node_or_null("VBox/TitleBar/TitleLabel")
	if title_label:
		title_label.text = display_name
	# Add container icon next to title
	var title_bar: HBoxContainer = instance.get_node_or_null("VBox/TitleBar")
	if title_bar and not sprite.is_empty():
		var tex: Texture2D = _get_item_texture(sprite)
		if tex != null:
			var icon := TextureRect.new()
			icon.texture = tex
			icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
			icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon.custom_minimum_size = Vector2(18, 18)
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			title_bar.add_child(icon)
			title_bar.move_child(icon, 0)
	var close_btn: Button = instance.get_node_or_null("VBox/TitleBar/CloseBtn")
	var min_btn: Button = instance.get_node_or_null("VBox/TitleBar/MinBtn")
	var content_scroll: ScrollContainer = instance.get_node_or_null("VBox/ContentScroll")
	var content: VBoxContainer = instance.get_node_or_null("VBox/ContentScroll/Content")
	var slot_grid: GridContainer = instance.get_node_or_null("VBox/ContentScroll/Content/SlotGrid")
	var resize_handle: ColorRect = instance.get_node_or_null("VBox/ResizeHandle")

	var cid := container_id
	if close_btn:
		close_btn.pressed.connect(func(): _on_container_close(cid))
	if min_btn and content_scroll:
		min_btn.pressed.connect(func():
			content_scroll.visible = not content_scroll.visible
			if resize_handle:
				resize_handle.visible = content_scroll.visible
			min_btn.text = "+" if not content_scroll.visible else "-"
		)

	# Set initial scroll height based on slot count (rows of 5, each 38px)
	var slot_count: int = capacity if capacity > 0 else maxi(items.size(), 1)
	var row_count: int = ceili(float(slot_count) / 5.0)
	var initial_height: float = float(row_count) * 38.0
	if content_scroll:
		content_scroll.custom_minimum_size.y = initial_height

	# Resize handle — drag to change content height
	if resize_handle and content_scroll:
		var _resize_dragging := [false]  # Array wrapper for closure
		var _resize_start := [0.0, 0.0]  # [start_y, start_height]
		resize_handle.gui_input.connect(func(event: InputEvent):
			if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
				if event.pressed:
					_resize_dragging[0] = true
					_resize_start[0] = event.global_position.y
					_resize_start[1] = content_scroll.custom_minimum_size.y
				else:
					_resize_dragging[0] = false
			elif event is InputEventMouseMotion and _resize_dragging[0]:
				var delta_y: float = event.global_position.y - _resize_start[0]
				var new_height: float = clampf(_resize_start[1] + delta_y, 40.0, initial_height)
				content_scroll.custom_minimum_size.y = new_height
		)

	_populate_container_slots(slot_grid, items, container_id, slot_count)

	if _container_stack:
		_container_stack.add_child(instance)
		_disable_focus_recursive(instance)

	_container_windows[container_id] = {
		"instance": instance,
		"slot_grid": slot_grid,
		"title_label": title_label,
		"content_scroll": content_scroll,
		"capacity": slot_count,
	}


## Closes and frees a container window by ID.
func close_container(container_id: int) -> void:
	if not _container_windows.has(container_id):
		return
	var data: Dictionary = _container_windows[container_id]
	var instance: PanelContainer = data["instance"]
	_container_windows.erase(container_id)
	if is_instance_valid(instance):
		instance.queue_free()


## Closes all open container windows.
func close_all_containers() -> void:
	for cid in _container_windows.keys():
		close_container(cid)


## Closes a container window and notifies the server.
func _on_container_close(container_id: int) -> void:
	close_container(container_id)
	if client:
		client.rpc_id(1, "rpc_container_close_request", container_id)


## Fills a GridContainer with item slot panels, wiring drag and right-click handlers.
func _populate_container_slots(grid: GridContainer, items: Array, container_id: int, slot_count: int = -1) -> void:
	if grid == null:
		return
	var total_slots: int = slot_count if slot_count > 0 else items.size()
	for i in range(total_slots):
		var slot := Panel.new()
		slot.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
		var bg := StyleBoxFlat.new()
		bg.bg_color = Color(0.15, 0.15, 0.15)
		bg.border_color = Color(0.4, 0.4, 0.4)
		bg.set_border_width_all(1)
		bg.set_corner_radius_all(2)
		slot.add_theme_stylebox_override("panel", bg)
		slot.set_meta("slot_index", i)
		slot.set_meta("item_id", "")
		slot.set_meta("item_count", 0)

		if i < items.size():
			var item: Array = items[i]
			var item_id: String = str(item[0])
			var count: int = int(item[1])
			var item_name: String = str(item[2]) if item.size() > 2 else item_id
			var color_hex: String = str(item[3]) if item.size() > 3 else "#FFD700"
			var color := Color.from_string(color_hex, Color.GOLD)
			var sprite_path: String = str(item[6]) if item.size() > 6 else ""

			_create_item_visual(slot, sprite_path, color, SLOT_SIZE)

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

			var tooltip_text: String = str(item[5]) if item.size() > 5 else item_name
			if count > 1:
				tooltip_text += "\nCount: %d" % count
			slot.tooltip_text = tooltip_text
			slot.set_meta("item_id", item_id)
			slot.set_meta("item_count", count)

			# Drag from container slot, right-click opens container items
			var idx := i
			var drag_col := color
			var drag_spr := sprite_path
			var cid := container_id
			var is_container_item: bool = bool(item[4]) if item.size() > 4 else false
			slot.gui_input.connect(func(event: InputEvent):
				if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
					if is_container_item and client:
						client.rpc_id(1, "rpc_open_item_in_container", cid, idx)
					elif client and cid < 0:
						# Right-click in backpack on non-container item — use item (food, potions)
						# Check if it's a rune - enter crosshair targeting mode
						if str(item[0]).ends_with("_rune") or str(item[0]) == "blankrune":
							client.enter_crosshair_mode(idx, cid)
						else:
							client.rpc_id(1, "rpc_use_item", idx)
				elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
					if client and client.inventory:
						client.inventory.start_drag("container", idx, cid, "", drag_col, count, drag_spr)
			)
		else:
			slot.tooltip_text = "Empty"

		grid.add_child(slot)


#  CHAT — Dynamic tab system

## Adds a new chat tab. Returns the tab index. If tab already exists, returns existing index.
func _add_chat_tab(tab_id: String, label_text: String) -> int:
	for i in range(_chat_tab_data.size()):
		if _chat_tab_data[i]["id"] == tab_id:
			return i
	var btn := Button.new()
	btn.text = label_text
	btn.custom_minimum_size = Vector2(80, 24)
	btn.add_theme_font_size_override("font_size", 10)
	btn.toggle_mode = true
	btn.focus_mode = Control.FOCUS_ALL
	var idx := _chat_tab_data.size()
	btn.pressed.connect(func(): _switch_tab(idx))
	# Right-click on PM tabs to close them
	btn.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			if tab_id.begins_with("pm_") or tab_id == "trade":
				_remove_chat_tab(tab_id)
	)
	# Insert before the spacer (which is at the end before open_chat_btn)
	if _tab_row:
		# Find spacer position — insert before it
		var insert_pos := _tab_row.get_child_count()
		for i in range(_tab_row.get_child_count()):
			var child := _tab_row.get_child(i)
			if child is Control and not child is Button:
				insert_pos = i
				break
		_tab_row.add_child(btn)
		_tab_row.move_child(btn, insert_pos)
	_chat_tab_data.append({
		"id": tab_id,
		"label": label_text,
		"button": btn,
		"messages": [],
	})
	return _chat_tab_data.size() - 1


## Removes a chat tab by ID and switches to the nearest remaining tab.
func _remove_chat_tab(tab_id: String) -> void:
	for i in range(_chat_tab_data.size()):
		if _chat_tab_data[i]["id"] == tab_id:
			var btn: Button = _chat_tab_data[i]["button"]
			if is_instance_valid(btn):
				btn.queue_free()
			_chat_tab_data.remove_at(i)
			if _active_tab_index >= _chat_tab_data.size():
				_active_tab_index = maxi(_chat_tab_data.size() - 1, 0)
			_switch_tab(_active_tab_index)
			return


## Returns the index of a chat tab by its ID, or -1 if not found.
func _get_tab_index(tab_id: String) -> int:
	for i in range(_chat_tab_data.size()):
		if _chat_tab_data[i]["id"] == tab_id:
			return i
	return -1


## Activates a chat tab, updates button states, and refreshes the history view.
func _switch_tab(tab_index: int) -> void:
	if tab_index < 0 or tab_index >= _chat_tab_data.size():
		return
	_active_tab_index = tab_index
	_clear_tab_flash(tab_index)
	for i in range(_chat_tab_data.size()):
		var btn: Button = _chat_tab_data[i]["button"]
		if is_instance_valid(btn):
			btn.button_pressed = (i == tab_index)
	_refresh_chat_history()


## Removes the flash highlight and timer from a tab button.
func _clear_tab_flash(tab_index: int) -> void:
	if tab_index < 0 or tab_index >= _chat_tab_data.size():
		return
	var btn: Button = _chat_tab_data[tab_index]["button"]
	if is_instance_valid(btn):
		btn.remove_theme_color_override("font_color")
	if _flash_timers.has(tab_index):
		var timer: Timer = _flash_timers[tab_index]
		if is_instance_valid(timer):
			timer.queue_free()
		_flash_timers.erase(tab_index)


## Redraws the chat history RichTextLabel with the active tab's messages.
func _refresh_chat_history() -> void:
	if _chat_history == null:
		return
	_chat_history.clear()
	if _active_tab_index < _chat_tab_data.size():
		var msgs: Array = _chat_tab_data[_active_tab_index]["messages"]
		for msg in msgs:
			_chat_history.append_text(str(msg) + "\n")


## Appends a BBCode line to a tab's message buffer and updates the view if active.
func _route_message_to_tab(tab_id: String, line: String) -> void:
	var idx := _get_tab_index(tab_id)
	if idx < 0:
		return
	_chat_tab_data[idx]["messages"].append(line)
	# If this is the active tab, append directly to the history
	if idx == _active_tab_index and _chat_history:
		_chat_history.append_text(line + "\n")


## Briefly highlights a tab button to indicate new messages.
func _flash_tab(tab_index: int) -> void:
	if tab_index < 0 or tab_index >= _chat_tab_data.size():
		return
	var btn: Button = _chat_tab_data[tab_index]["button"]
	if not is_instance_valid(btn):
		return
	# Set highlight color
	btn.add_theme_color_override("font_color", Color(0.0, 1.0, 1.0))  # Cyan flash
	# Clear after 2 seconds (or when tab is clicked)
	if _flash_timers.has(tab_index):
		var old_timer: Timer = _flash_timers[tab_index]
		if is_instance_valid(old_timer):
			old_timer.queue_free()
	var timer := Timer.new()
	timer.wait_time = 2.0
	timer.one_shot = true
	var tidx := tab_index
	timer.timeout.connect(func():
		_clear_tab_flash(tidx)
		timer.queue_free()
	)
	btn.add_child(timer)
	timer.start()
	_flash_timers[tab_index] = timer


## Routes an incoming chat message to the appropriate tab(s) and triggers speech bubbles.
func receive_chat(channel: String, sender: String, text: String) -> void:
	var line := ""
	match channel:
		"say":
			line = "[color=yellow]%s says:[/color] %s" % [sender, text]
		"yell":
			line = "[color=yellow]%s yells:[/color] [b]%s[/b]" % [sender, text]
		"whisper":
			line = "[color=cyan]%s whispers:[/color] %s" % [sender, text]
		"whisper_sent":
			line = "[color=cyan]You whisper to %s:[/color] %s" % [sender, text]
		"global":
			line = "[color=lime]%s:[/color] %s" % [sender, text]
		"broadcast":
			line = "[color=red]%s broadcasts:[/color] %s" % [sender, text]
		"trade":
			line = "[color=orange]%s:[/color] %s" % [sender, text]
		"system":
			line = "[color=gray]%s[/color]" % text
		"npc":
			line = "[color=orange]%s says:[/color] %s" % [sender, text]
		_:
			line = "[%s] %s: %s" % [channel, sender, text]

	# Route to appropriate tabs
	match channel:
		"say", "yell", "npc":
			_route_message_to_tab("local", line)
			# Speech bubble above character
			var bubble_color := Color.YELLOW
			if channel == "yell":
				bubble_color = Color.YELLOW
			elif channel == "npc":
				bubble_color = Color.ORANGE
			if client and client.players:
				client.players.show_speech_bubble(sender, text, bubble_color)
		"whisper", "whisper_sent":
			# Route to local tab AND to PM tab (auto-create if needed)
			_route_message_to_tab("local", line)
			var pm_name: String = sender  # sender = who whispered us / who we whispered to
			var pm_tab_id := "pm_%s" % pm_name.to_lower()
			# Auto-create PM tab on incoming whisper
			if _get_tab_index(pm_tab_id) < 0:
				_add_chat_tab(pm_tab_id, pm_name)
			_route_message_to_tab(pm_tab_id, line)
			# Flash the tab if it's not active
			var pm_idx := _get_tab_index(pm_tab_id)
			if pm_idx >= 0 and pm_idx != _active_tab_index:
				_flash_tab(pm_idx)
			# Show top-of-screen banner for incoming PMs
			if channel == "whisper":
				_show_pm_banner(sender, text)
		"system":
			# System messages go to server log
			_route_message_to_tab("server_log", line)
		"global", "broadcast":
			_route_message_to_tab("global", line)
		"trade":
			var trade_idx := _get_tab_index("trade")
			if trade_idx >= 0:
				_route_message_to_tab("trade", line)
			else:
				# If trade tab not open, show in server log
				_route_message_to_tab("server_log", line)
		_:
			# Unknown channels go to server log
			_route_message_to_tab("server_log", line)


## Consume arrow/movement keys so the LineEdit doesn't move the cursor.
## The game movement system reads keys via Input.is_key_pressed() which still works.
func _on_chat_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, \
			KEY_KP_1, KEY_KP_2, KEY_KP_3, KEY_KP_4, KEY_KP_6, KEY_KP_7, KEY_KP_8, KEY_KP_9, \
			KEY_HOME, KEY_END, KEY_PAGEUP, KEY_PAGEDOWN:
				_chat_input.accept_event()


## Right-click on chat history → extract player name from line, show context menu.
func _on_chat_history_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		var name := _extract_player_name_from_chat_line()
		if name.is_empty():
			return
		_chat_context_target_name = name
		_show_chat_context_menu(event.global_position)


## Extracts the player name from the chat line under the cursor.
## Parses patterns like "Name says:", "Name yells:", "Name whispers:",
## "You whisper to Name:", "Name:" (global/trade).
func _extract_player_name_from_chat_line() -> String:
	if _chat_history == null:
		return ""
	# Get the visible text of the active tab's messages near the click
	# RichTextLabel doesn't expose per-line hit testing easily,
	# so we use the selected text if any, otherwise parse the last hovered line.
	var selected := _chat_history.get_selected_text()
	if not selected.is_empty():
		# If user selected text, treat it as the name
		return selected.strip_edges()

	# Fallback: find the line at the mouse position by checking visible lines
	# We'll parse the plain text version of messages for the active tab
	if _active_tab_index >= _chat_tab_data.size():
		return ""
	var msgs: Array = _chat_tab_data[_active_tab_index]["messages"]
	if msgs.is_empty():
		return ""

	# Approximate which line was clicked based on mouse Y position
	var local_pos := _chat_history.get_local_mouse_position()
	var scroll_offset := 0.0
	var vscroll: VScrollBar = _chat_history.get_v_scroll_bar()
	if vscroll:
		scroll_offset = vscroll.value
	# Each line is roughly 16px tall (font_size 12 + spacing)
	var line_height := 16.0
	var approx_line := int(floor((local_pos.y + scroll_offset) / line_height))
	approx_line = clampi(approx_line, 0, msgs.size() - 1)

	var raw_line: String = str(msgs[approx_line])
	return _parse_name_from_bbcode_line(raw_line)


## Parses a player name from a BBCode chat line.
## Handles: "Name says:", "Name yells:", "Name whispers:",
## "You whisper to Name:", "Name:" (global/trade), "Name broadcasts:"
func _parse_name_from_bbcode_line(line: String) -> String:
	# Strip BBCode tags for parsing
	var plain := line
	var regex := RegEx.new()
	regex.compile("\\[.*?\\]")
	plain = regex.sub(plain, "", true).strip_edges()

	# "You whisper to Name:" → extract Name
	if plain.begins_with("You whisper to "):
		var rest := plain.substr(15)  # after "You whisper to "
		var colon_pos := rest.find(":")
		if colon_pos > 0:
			return rest.left(colon_pos).strip_edges()

	# "Name says:", "Name yells:", "Name whispers:", "Name broadcasts:"
	for keyword in [" says:", " yells:", " whispers:", " broadcasts:"]:
		var kw_pos := plain.find(keyword)
		if kw_pos > 0:
			return plain.left(kw_pos).strip_edges()

	# "Name:" (global/trade format)
	var colon_pos := plain.find(":")
	if colon_pos > 0 and colon_pos < 30:
		var candidate := plain.left(colon_pos).strip_edges()
		# Sanity check — names don't have spaces typically, but Tibia names can
		# Reject if it looks like a system message
		if not candidate.is_empty() and candidate != "GM" and not candidate.begins_with("["):
			return candidate

	return ""


## Shows a right-click context menu for a player name in chat.
func _show_chat_context_menu(screen_pos: Vector2) -> void:
	_close_chat_context_menu()

	_chat_context_menu = PopupMenu.new()
	_chat_context_menu.add_item("Open Private Chat", 0)
	_chat_context_menu.add_item("Copy Name", 1)
	_chat_context_menu.id_pressed.connect(_on_chat_context_menu_selected)

	if _hud_layer:
		_hud_layer.add_child(_chat_context_menu)
	_chat_context_menu.position = Vector2i(int(screen_pos.x), int(screen_pos.y))
	_chat_context_menu.popup()


## Closes the chat context menu popup if open.
func _close_chat_context_menu() -> void:
	if _chat_context_menu != null and is_instance_valid(_chat_context_menu):
		_chat_context_menu.queue_free()
		_chat_context_menu = null


## Handles context menu selection: open PM tab or copy player name.
func _on_chat_context_menu_selected(id: int) -> void:
	match id:
		0:  # Open Private Chat
			if not _chat_context_target_name.is_empty():
				var pm_tab_id := "pm_%s" % _chat_context_target_name.to_lower()
				var idx := _add_chat_tab(pm_tab_id, _chat_context_target_name)
				_switch_tab(idx)
		1:  # Copy Name
			if not _chat_context_target_name.is_empty():
				DisplayServer.clipboard_set(_chat_context_target_name)
	_close_chat_context_menu()


## Call this from client_main._process to keep chat always focused.
## Skip if a popup is open or user is interacting with UI buttons.
func process_chat_focus() -> void:
	if client.inventory._slider_open:
		return
	if _open_chat_popup != null and is_instance_valid(_open_chat_popup):
		return
	if _outfit_window != null and is_instance_valid(_outfit_window):
		return
	if _hotkey_window != null and is_instance_valid(_hotkey_window):
		return
	if _chat_context_menu != null and is_instance_valid(_chat_context_menu) and _chat_context_menu.visible:
		return
	# Don't steal focus while mouse button is held (user clicking a button)
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return
	if _chat_input and _chat_input.is_visible_in_tree() and not _chat_input.has_focus():
		_chat_input.grab_focus()


## Processes submitted chat text: slash commands, channel routing, and RPC dispatch.
func _on_chat_submitted(text: String) -> void:
	if _chat_input == null:
		return
	_chat_input.clear()
	_chat_input.release_focus()
	text = text.strip_edges()
	if text.is_empty():
		return
	if client == null:
		return
	if text == "/logout":
		client.rpc_id(1, "rpc_logout")
		return
	if text == "/inv":
		client.inventory.toggle_inventory()
		return
	if text.begins_with("/buy "):
		var parts := text.substr(5).strip_edges().rsplit(" ", true, 1)
		var item_id: String = parts[0] if parts.size() > 0 else ""
		var count: int = int(parts[1]) if parts.size() > 1 else 1
		if not item_id.is_empty() and count > 0:
			client.rpc_id(1, "rpc_shop_buy", item_id, count)
		return
	if text.begins_with("/sell "):
		var parts := text.substr(6).strip_edges().rsplit(" ", true, 1)
		var item_id: String = parts[0] if parts.size() > 0 else ""
		var count: int = int(parts[1]) if parts.size() > 1 else 1
		if not item_id.is_empty() and count > 0:
			client.rpc_id(1, "rpc_shop_sell", item_id, count)
		return

	# Determine channel based on active tab
	var active_tab_id := ""
	if _active_tab_index < _chat_tab_data.size():
		active_tab_id = _chat_tab_data[_active_tab_index]["id"]

	# Slash commands override tab context
	if text.begins_with("/y "):
		client.rpc_id(1, "rpc_send_chat", "yell", text.substr(3))
	elif text.begins_with("/w "):
		client.rpc_id(1, "rpc_send_chat", "whisper", text.substr(3))
	elif text.begins_with("/g "):
		client.rpc_id(1, "rpc_send_chat", "global", text.substr(3))
	elif text.begins_with("/t "):
		client.rpc_id(1, "rpc_send_chat", "trade", text.substr(3))
	elif active_tab_id == "global":
		client.rpc_id(1, "rpc_send_chat", "global", text)
	elif active_tab_id == "trade":
		client.rpc_id(1, "rpc_send_chat", "trade", text)
	elif active_tab_id.begins_with("pm_"):
		# PM tab — send whisper to that player
		var target_name := active_tab_id.substr(3)
		client.rpc_id(1, "rpc_send_chat", "whisper", "%s %s" % [target_name, text])
	else:
		# Default: local say
		client.rpc_id(1, "rpc_send_chat", "say", text)


#  OPEN CHAT POPUP

## Toggles the "Open Chat Channel" popup for global, trade, and PM tabs.
func _show_open_chat_popup() -> void:
	if _open_chat_popup != null and is_instance_valid(_open_chat_popup):
		_open_chat_popup.queue_free()
		_open_chat_popup = null
		return

	if _open_chat_popup_scene == null:
		return
	_open_chat_popup = _open_chat_popup_scene.instantiate()

	var global_btn: Button = _open_chat_popup.get_node_or_null("%GlobalBtn")
	if global_btn:
		global_btn.pressed.connect(func():
			var idx := _add_chat_tab("global", "global chat")
			_switch_tab(idx)
			_close_open_chat_popup()
		)
	var trade_btn: Button = _open_chat_popup.get_node_or_null("%TradeBtn")
	if trade_btn:
		trade_btn.pressed.connect(func():
			var idx := _add_chat_tab("trade", "trade")
			_switch_tab(idx)
			_close_open_chat_popup()
		)
	var pm_input: LineEdit = _open_chat_popup.get_node_or_null("%PMInput")
	var pm_btn: Button = _open_chat_popup.get_node_or_null("%PMOpenBtn")
	if pm_btn and pm_input:
		pm_btn.pressed.connect(func():
			var name_text := pm_input.text.strip_edges()
			if name_text.is_empty():
				return
			var pm_tab_id := "pm_%s" % name_text.to_lower()
			var idx := _add_chat_tab(pm_tab_id, name_text)
			_switch_tab(idx)
			_close_open_chat_popup()
		)
	var close_btn: Button = _open_chat_popup.get_node_or_null("%CloseBtn")
	if close_btn:
		close_btn.pressed.connect(_close_open_chat_popup)

	if _hud_layer:
		_hud_layer.add_child(_open_chat_popup)
	if _open_chat_btn and is_instance_valid(_open_chat_btn):
		var btn_rect := _open_chat_btn.get_global_rect()
		_open_chat_popup.position = Vector2(btn_rect.position.x - 120, btn_rect.position.y - 220)


func _close_open_chat_popup() -> void:
	if _open_chat_popup != null and is_instance_valid(_open_chat_popup):
		_open_chat_popup.queue_free()
		_open_chat_popup = null


#  DEATH OVERLAY

## Stub — death dialog is handled by client_combat.gd.
func show_death(xp_loss: int) -> void:
	# Death dialog is handled by client_combat.gd scene-based dialog
	pass

## Stub — death dialog is handled by client_combat.gd.
func hide_death() -> void:
	pass


#  STATS (combined update from rpc_stats_update)

## Updates sidebar health, mana, level, and XP labels from a combined stats RPC.
func update_stats(health: int, max_health: int, mana: int, max_mana: int,
		level: int, xp: int, xp_next: int) -> void:
	update_health(health, max_health)
	update_mana(mana, max_mana)
	if _stats_level_label:
		_stats_level_label.text = "Level: %d" % level
	if _stats_xp_label:
		_stats_xp_label.text = "XP: %d/%d" % [xp, xp_next]


## skills_data = Array of [skill_name, level, percent_to_next]
func update_skills(skills_data: Array) -> void:
	for entry in skills_data:
		if not entry is Array or entry.size() < 3:
			continue
		var skill_name: String = str(entry[0])
		var level: int = int(entry[1])
		var pct: int = int(entry[2])
		if _skills_labels.has(skill_name):
			var info: Dictionary = _skills_labels[skill_name]
			var val_lbl: Label = info["value"]
			var bar_bg: ColorRect = info["bar_bg"]
			var bar_fill: ColorRect = info["bar_fill"]
			if val_lbl:
				val_lbl.text = str(level)
			if bar_fill and bar_bg:
				bar_fill.size.x = bar_bg.size.x * clampf(float(pct) / 100.0, 0.0, 1.0)


## Updates sidebar combat stats labels and syncs local player animation speed.
func update_combat_stats(attack: int, defense: int, armor: int, weight: float, max_cap: float, speed: int = 0, ground_speed: float = 150.0) -> void:
	if _stats_attack_label:
		_stats_attack_label.text = "Attack: %d" % attack
	if _stats_defense_label:
		_stats_defense_label.text = "Defense: %d" % defense
	if _stats_armor_label:
		_stats_armor_label.text = "Armor: %d" % armor
	if _cap_label:
		_cap_label.text = "%d/%d" % [int(weight), int(max_cap)]
	if _stats_speed_label:
		_stats_speed_label.text = "Speed: %d (Tile: %d)" % [speed, int(ground_speed)]
	# Update local player animation speed to match actual speed
	if speed > 0 and client.players._players.has(client._local_entity_id):
		var data: Dictionary = client.players._players[client._local_entity_id]
		var step_ms: float = ceilf(1000.0 * ground_speed / maxf(float(speed), 1.0))
		var anim_sec: float = (step_ms / 1000.0) * client.players.ANIM_SPEEDUP
		data["anim_speed"] = float(client.players.TILE_SIZE) / maxf(anim_sec, 0.05)


#  ITEM SPRITE HELPERS

## Loads and caches an item texture by sprite path, returning null if not found.
func _get_item_texture(sprite_path: String) -> Texture2D:
	if sprite_path.is_empty():
		return null
	if _texture_cache.has(sprite_path):
		return _texture_cache[sprite_path]
	if ResourceLoader.exists(sprite_path):
		var tex: Texture2D = load(sprite_path)
		_texture_cache[sprite_path] = tex
		return tex
	_texture_cache[sprite_path] = null
	return null


## Adds either a TextureRect (if sprite exists) or ColorRect fallback to the parent.
func _create_item_visual(parent: Control, sprite_path: String, color: Color, slot_size: float) -> void:
	var tex: Texture2D = _get_item_texture(sprite_path)
	if tex != null:
		var img := TextureRect.new()
		img.texture = tex
		img.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		img.position = Vector2(2, 2)
		img.size = Vector2(slot_size - 4, slot_size - 4)
		img.mouse_filter = Control.MOUSE_FILTER_IGNORE
		parent.add_child(img)
	else:
		var rect := ColorRect.new()
		rect.color = color
		rect.position = Vector2(4, 4)
		rect.size = Vector2(slot_size - 8, slot_size - 8)
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		parent.add_child(rect)


#  HIT TESTING — for drag-drop targeting

## Returns the container_uid if it has a window, or -1.
func _find_window_uid_for_container(container_uid: int) -> int:
	if _container_windows.has(container_uid):
		return container_uid
	return -1

## Returns {container_uid, slot_index} if screen_pos hits a container slot, or {}.
func get_container_slot_at(screen_pos: Vector2) -> Dictionary:
	for cid in _container_windows:
		var data: Dictionary = _container_windows[cid]
		var grid: GridContainer = data["slot_grid"]
		if grid == null or not grid.is_visible_in_tree():
			continue
		var idx := 0
		for child in grid.get_children():
			if child is Panel and child.get_global_rect().has_point(screen_pos):
				return {"container_uid": cid, "slot_index": idx}
			idx += 1
	return {}


## Returns the server equip_slot name if screen_pos hits an equipment slot, or "".
func get_equip_slot_at(screen_pos: Vector2) -> String:
	for slot_name in _equip_slots:
		var panel: Panel = _equip_slots[slot_name]
		if panel == null or not panel.is_visible_in_tree():
			continue
		if panel.get_global_rect().has_point(screen_pos):
			return EQUIP_SLOT_MAP.get(slot_name, "")
	return ""


#  SIDEBAR PANEL TOGGLES

## Toggles visibility of the stats panel in the sidebar.
func _toggle_stats_panel() -> void:
	if _stats_panel:
		_stats_panel.visible = not _stats_panel.visible

## Toggles visibility of the skills panel in the sidebar.
func _toggle_skills_panel() -> void:
	if _skills_panel:
		_skills_panel.visible = not _skills_panel.visible


## Updates the food timer label in MM:SS format, or "--:--" if expired.
func update_food_timer(seconds: float) -> void:
	if _stats_food_label:
		if seconds <= 0.0:
			_stats_food_label.text = "Food: --:--"
		else:
			var mins: int = int(seconds) / 60
			var secs: int = int(seconds) % 60
			_stats_food_label.text = "Food: %02d:%02d" % [mins, secs]


## statuses = Array of active status name strings, e.g. ["combat", "haste"]
func update_status_icons(statuses: Array) -> void:
	for status_name in _status_icons:
		_status_icons[status_name].visible = statuses.has(status_name)


#  HOTKEY BAR (F1-F12)

## Loads hotkey bindings from the user save file, or initializes defaults.
func _load_hotkeys() -> void:
	_hotkeys.clear()
	for i in range(HOTKEY_COUNT):
		_hotkeys.append({"text": "", "auto_send": true})
	# Load from file if exists
	if FileAccess.file_exists(HOTKEY_SAVE_PATH):
		var file := FileAccess.open(HOTKEY_SAVE_PATH, FileAccess.READ)
		if file:
			var json := JSON.new()
			if json.parse(file.get_as_text()) == OK and json.data is Array:
				var data: Array = json.data
				for i in range(mini(data.size(), HOTKEY_COUNT)):
					if data[i] is Dictionary:
						_hotkeys[i]["text"] = str(data[i].get("text", ""))
						_hotkeys[i]["auto_send"] = bool(data[i].get("auto_send", true))
			file.close()


## Persists hotkey bindings to the user save file.
func _save_hotkeys() -> void:
	var file := FileAccess.open(HOTKEY_SAVE_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(_hotkeys))
		file.close()


## Called when F1-F12 is pressed. index is 0-based (F1=0, F12=11).
## Returns true if the hotkey was handled.
func handle_hotkey(index: int) -> bool:
	if index < 0 or index >= HOTKEY_COUNT:
		return false
	var hk: Dictionary = _hotkeys[index]
	var text: String = hk.get("text", "")
	if text.is_empty():
		return false
	if hk.get("auto_send", true):
		# Send as chat (server will process spells via /cast or direct spell words)
		if _chat_input:
			_on_chat_submitted(text)
		return true
	else:
		# Put text in chat input for editing
		if _chat_input:
			_chat_input.text = text
			_chat_input.caret_column = text.length()
		return true


## Toggles the hotkey configuration window (F1-F12 bindings editor).
func toggle_hotkey_window() -> void:
	if _hotkey_window != null and is_instance_valid(_hotkey_window):
		_hotkey_window.queue_free()
		_hotkey_window = null
		return
	if _hotkey_scene == null:
		return
	_hotkey_window = _hotkey_scene.instantiate()
	_hotkey_window.mouse_filter = Control.MOUSE_FILTER_STOP
	var close_btn: Button = _hotkey_window.get_node_or_null("VBox/TitleBar/CloseBtn")
	if close_btn:
		close_btn.pressed.connect(func(): toggle_hotkey_window())
	var hotkey_list: VBoxContainer = _hotkey_window.get_node_or_null("VBox/Scroll/HotkeyList")
	var _edit_fields: Array = []  # [{"input": LineEdit, "check": CheckBox}]
	if hotkey_list:
		for i in range(HOTKEY_COUNT):
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 4)
			var label := Label.new()
			label.text = "F%d:" % (i + 1)
			label.add_theme_font_size_override("font_size", 11)
			label.custom_minimum_size.x = 30
			row.add_child(label)
			var input := LineEdit.new()
			input.text = _hotkeys[i].get("text", "")
			input.placeholder_text = "spell or text..."
			input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			input.add_theme_font_size_override("font_size", 10)
			row.add_child(input)
			var check := CheckBox.new()
			check.text = "Auto"
			check.button_pressed = bool(_hotkeys[i].get("auto_send", true))
			check.add_theme_font_size_override("font_size", 9)
			row.add_child(check)
			hotkey_list.add_child(row)
			_edit_fields.append({"input": input, "check": check})
	# Save / Cancel
	var save_btn: Button = _hotkey_window.get_node_or_null("VBox/ButtonRow/SaveBtn")
	var cancel_btn: Button = _hotkey_window.get_node_or_null("VBox/ButtonRow/CancelBtn")
	if save_btn:
		save_btn.focus_mode = Control.FOCUS_ALL
		var fields := _edit_fields
		save_btn.pressed.connect(func():
			for idx in range(fields.size()):
				_hotkeys[idx]["text"] = fields[idx]["input"].text
				_hotkeys[idx]["auto_send"] = fields[idx]["check"].button_pressed
			_save_hotkeys()
			toggle_hotkey_window()
		)
	if cancel_btn:
		cancel_btn.focus_mode = Control.FOCUS_ALL
		cancel_btn.pressed.connect(func(): toggle_hotkey_window())
	if _hud_layer:
		_hud_layer.add_child(_hotkey_window)
	_hotkey_window.position = Vector2(150, 80)


#  OUTFIT WINDOW

# Tibia's 133 color palette (7x19 grid)
const TIBIA_COLORS := [
	"#ffffff", "#ffd4bf", "#ffe9bf", "#ffffbf", "#e9ffbf", "#d4ffbf", "#bfffbf",
	"#bfffd4", "#bfffe9", "#bfffff", "#bfe9ff", "#bfd4ff", "#bfbfff", "#d4bfff",
	"#e9bfff", "#ffbfff", "#ffbfe9", "#ffbfd4", "#ffbfbf",
	"#b6b6b6", "#bf9f7f", "#bfaf7f", "#bfbf7f", "#afbf7f", "#9fbf7f", "#7fbf7f",
	"#7fbf9f", "#7fbfaf", "#7fbfbf", "#7fafbf", "#7f9fbf", "#7f7fbf", "#9f7fbf",
	"#af7fbf", "#bf7fbf", "#bf7faf", "#bf7f9f", "#bf7f7f",
	"#969696", "#9f7f5f", "#9f8f5f", "#9f9f5f", "#8f9f5f", "#7f9f5f", "#5f9f5f",
	"#5f9f7f", "#5f9f8f", "#5f9f9f", "#5f8f9f", "#5f7f9f", "#5f5f9f", "#7f5f9f",
	"#8f5f9f", "#9f5f9f", "#9f5f8f", "#9f5f7f", "#9f5f5f",
	"#787878", "#7f5f3f", "#7f6f3f", "#7f7f3f", "#6f7f3f", "#5f7f3f", "#3f7f3f",
	"#3f7f5f", "#3f7f6f", "#3f7f7f", "#3f6f7f", "#3f5f7f", "#3f3f7f", "#5f3f7f",
	"#6f3f7f", "#7f3f7f", "#7f3f6f", "#7f3f5f", "#7f3f3f",
	"#5a5a5a", "#5f3f1f", "#5f4f1f", "#5f5f1f", "#4f5f1f", "#3f5f1f", "#1f5f1f",
	"#1f5f3f", "#1f5f4f", "#1f5f5f", "#1f4f5f", "#1f3f5f", "#1f1f5f", "#3f1f5f",
	"#4f1f5f", "#5f1f5f", "#5f1f4f", "#5f1f3f", "#5f1f1f",
	"#3c3c3c", "#3f2f0f", "#3f370f", "#3f3f0f", "#373f0f", "#2f3f0f", "#0f3f0f",
	"#0f3f2f", "#0f3f37", "#0f3f3f", "#0f373f", "#0f2f3f", "#0f0f3f", "#2f0f3f",
	"#370f3f", "#3f0f3f", "#3f0f37", "#3f0f2f", "#3f0f0f",
	"#1e1e1e", "#1f1700", "#1f1b00", "#1f1f00", "#1b1f00", "#171f00", "#001f00",
	"#001f17", "#001f1b", "#001f1f", "#001b1f", "#00171f", "#00001f", "#17001f",
	"#1b001f", "#1f001f", "#1f001b", "#1f0017", "#1f0000",
]

var _outfit_selected_part: String = "head"
var _outfit_colors: Dictionary = {"head": "#ffff00", "body": "#4d80ff", "legs": "#4d80ff", "feet": "#996633"}
var _outfit_list: Array = []
var _outfit_index: int = 0


## Toggles the outfit customization window with color palette and preview.
func toggle_outfit_window() -> void:
	if _outfit_window != null and is_instance_valid(_outfit_window):
		_outfit_window.queue_free()
		_outfit_window = null
		return
	if _outfit_scene == null:
		return
	# Get available outfits filtered by player gender
	var gender: String = client._local_gender if client else "male"
	var suffix := "_female" if gender == "female" else "_male"
	var all_outfits := ["citizen", "knight", "mage", "hunter", "noble", "summoner", "warrior"]
	_outfit_list = []
	for base in all_outfits:
		_outfit_list.append(base + suffix)
	_outfit_index = 0
	# Load current colors from local player if available
	_outfit_window = _outfit_scene.instantiate()
	_outfit_window.mouse_filter = Control.MOUSE_FILTER_STOP
	# Wire buttons
	var close_btn: Button = _outfit_window.get_node_or_null("VBox/TitleBar/CloseBtn")
	if close_btn:
		close_btn.pressed.connect(func(): toggle_outfit_window())
	var prev_btn: Button = _outfit_window.get_node_or_null("VBox/Content/RightSide/OutfitRow/PrevOutfit")
	var next_btn: Button = _outfit_window.get_node_or_null("VBox/Content/RightSide/OutfitRow/NextOutfit")
	if prev_btn:
		prev_btn.pressed.connect(func():
			_outfit_index = (_outfit_index - 1) % _outfit_list.size()
			if _outfit_index < 0: _outfit_index += _outfit_list.size()
			_update_outfit_preview()
		)
	if next_btn:
		next_btn.pressed.connect(func():
			_outfit_index = (_outfit_index + 1) % _outfit_list.size()
			_update_outfit_preview()
		)
	# Part selection buttons
	var head_btn: Button = _outfit_window.get_node_or_null("VBox/Content/RightSide/PartRow/HeadBtn")
	var body_btn: Button = _outfit_window.get_node_or_null("VBox/Content/RightSide/PartRow/BodyBtn")
	var legs_btn: Button = _outfit_window.get_node_or_null("VBox/Content/RightSide/PartRow/LegsBtn")
	var feet_btn: Button = _outfit_window.get_node_or_null("VBox/Content/RightSide/PartRow/FeetBtn")
	var part_btns := [head_btn, body_btn, legs_btn, feet_btn]
	var part_names := ["head", "body", "legs", "feet"]
	for i in range(4):
		if part_btns[i]:
			var pname: String = str(part_names[i])
			var btn: Button = part_btns[i] as Button
			btn.focus_mode = Control.FOCUS_ALL
			btn.pressed.connect(func():
				_outfit_selected_part = pname
				for b in part_btns:
					if b: b.button_pressed = false
				btn.button_pressed = true
				var part_label: Label = _outfit_window.get_node_or_null("VBox/Content/RightSide/PartLabel")
				if part_label: part_label.text = pname.capitalize()
			)
	# Populate color grid
	var color_grid: GridContainer = _outfit_window.get_node_or_null("VBox/ColorGrid")
	if color_grid:
		for hex in TIBIA_COLORS:
			var btn := Button.new()
			btn.custom_minimum_size = Vector2(14, 14)
			btn.focus_mode = Control.FOCUS_NONE
			var style := StyleBoxFlat.new()
			style.bg_color = Color.from_string(hex, Color.WHITE)
			style.set_border_width_all(1)
			style.border_color = Color(0.3, 0.3, 0.3)
			btn.add_theme_stylebox_override("normal", style)
			btn.add_theme_stylebox_override("hover", style)
			btn.add_theme_stylebox_override("pressed", style)
			var color_hex: String = str(hex)
			btn.pressed.connect(func():
				_outfit_colors[_outfit_selected_part] = color_hex
				_update_outfit_preview()
			)
			color_grid.add_child(btn)
	# OK / Cancel
	var ok_btn: Button = _outfit_window.get_node_or_null("VBox/ButtonRow/OkBtn")
	var cancel_btn: Button = _outfit_window.get_node_or_null("VBox/ButtonRow/CancelBtn")
	if ok_btn:
		ok_btn.focus_mode = Control.FOCUS_ALL
		ok_btn.pressed.connect(func():
			var oid: String = _outfit_list[_outfit_index]
			client.rpc_id(1, "rpc_change_outfit", oid,
				_outfit_colors["head"], _outfit_colors["body"],
				_outfit_colors["legs"], _outfit_colors["feet"])
			toggle_outfit_window()
		)
	if cancel_btn:
		cancel_btn.focus_mode = Control.FOCUS_ALL
		cancel_btn.pressed.connect(func(): toggle_outfit_window())
	if _hud_layer:
		_hud_layer.add_child(_outfit_window)
	_outfit_window.position = Vector2(200, 100)
	_update_outfit_preview()


## Reloads and re-colorizes the outfit preview sprite in the outfit window.
func _update_outfit_preview() -> void:
	if _outfit_window == null:
		return
	var name_label: Label = _outfit_window.get_node_or_null("VBox/Content/RightSide/OutfitRow/OutfitName")
	if name_label and _outfit_index < _outfit_list.size():
		name_label.text = _outfit_list[_outfit_index].replace("_", " ").capitalize()
	var preview: TextureRect = _outfit_window.get_node_or_null("VBox/Content/PreviewPanel/PreviewSprite")
	if preview == null or _outfit_index >= _outfit_list.size():
		return
	# Load outfit data
	var outfit_id: String = _outfit_list[_outfit_index]
	var outfit_path := "res://datapacks/outfits/%s.json" % outfit_id
	if not FileAccess.file_exists(outfit_path):
		preview.texture = null
		return
	var file := FileAccess.open(outfit_path, FileAccess.READ)
	if file == null:
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK or not json.data is Dictionary:
		file.close()
		return
	var data: Dictionary = json.data
	file.close()
	var base_dict: Dictionary = data.get("base_sprites", {})
	var color_dict: Dictionary = data.get("color_sprites", {})
	var south: Dictionary = base_dict.get("south", {})
	var idle_path: String = str(south.get("idle", ""))
	if idle_path.is_empty():
		preview.texture = null
		return
	# CPU colorize the preview
	var base_img := Image.load_from_file(idle_path)
	if base_img == null:
		preview.texture = null
		return
	var color_south: Dictionary = color_dict.get("south", {})
	var color_path: String = str(color_south.get("idle", ""))
	if not color_path.is_empty() and FileAccess.file_exists(color_path):
		var mask_img := Image.load_from_file(color_path)
		if mask_img:
			var head_col := Color.from_string(_outfit_colors["head"], Color.YELLOW)
			var body_col := Color.from_string(_outfit_colors["body"], Color.BLUE)
			var legs_col := Color.from_string(_outfit_colors["legs"], Color.GREEN)
			var feet_col := Color.from_string(_outfit_colors["feet"], Color.BROWN)
			preview.texture = client.players.colorize_outfit(base_img, mask_img, head_col, body_col, legs_col, feet_col)
			preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			preview.material = null
			return
	preview.texture = ImageTexture.create_from_image(base_img)
	preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	preview.material = null
