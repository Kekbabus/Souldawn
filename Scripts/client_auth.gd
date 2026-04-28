#  client_auth.gd -- Authentication flow: login/register UI, character
#  selection, and deferred connection handling.
#
#  Connection is deferred -- client only connects when player clicks
#  Login or Register. Handles disconnect gracefully.
extends Node

var client: Node2D = null

var _login_layer: CanvasLayer = null
var _login_panel: PanelContainer = null
var _login_username: LineEdit = null
var _login_password: LineEdit = null
var _login_status: Label = null

# Character select UI
var _charselect_panel: PanelContainer = null
var _charselect_list: VBoxContainer = null
var _charselect_status: Label = null
var _charselect_name_input: LineEdit = null
var _charselect_vocation: OptionButton = null
var _charselect_gender: OptionButton = null

# Pending request -- stored while connecting, sent once connected
var _pending_action: String = ""  # "login" or "register"
var _pending_username: String = ""
var _pending_password: String = ""


## Loads the login and character-select scene panels and wires signals.
func setup_login_ui() -> void:
	_login_layer = CanvasLayer.new()
	_login_layer.name = "LoginLayer"
	_login_layer.layer = 30
	client.add_child(_login_layer)

	var login_scene := load("res://Scenes/ui_login_panel.tscn")
	if login_scene == null:
		push_error("client_auth: failed to load ui_login_panel.tscn")
		return
	_login_panel = login_scene.instantiate()
	_login_layer.add_child(_login_panel)

	_login_username = _login_panel.get_node_or_null("%UsernameInput")
	_login_password = _login_panel.get_node_or_null("%PasswordInput")
	_login_status = _login_panel.get_node_or_null("%StatusLabel")

	var btn_login: Button = _login_panel.get_node_or_null("%LoginBtn")
	if btn_login:
		btn_login.pressed.connect(_on_login_pressed)
	var btn_register: Button = _login_panel.get_node_or_null("%RegisterBtn")
	if btn_register:
		btn_register.pressed.connect(_on_register_pressed)
	var btn_exit: Button = _login_panel.get_node_or_null("%ExitBtn")
	if btn_exit:
		btn_exit.pressed.connect(func(): client.get_tree().quit())

	var cs_scene := load("res://Scenes/ui_charselect_panel.tscn")
	if cs_scene == null:
		push_error("client_auth: failed to load ui_charselect_panel.tscn")
		return
	_charselect_panel = cs_scene.instantiate()
	_login_layer.add_child(_charselect_panel)

	_charselect_list = _charselect_panel.get_node_or_null("%CharList")
	_charselect_name_input = _charselect_panel.get_node_or_null("%NameInput")
	_charselect_status = _charselect_panel.get_node_or_null("%StatusLabel")
	_charselect_gender = _charselect_panel.get_node_or_null("%GenderSelect")

	var create_btn: Button = _charselect_panel.get_node_or_null("%CreateBtn")
	if create_btn:
		create_btn.pressed.connect(_on_create_character_pressed)
	var back_btn: Button = _charselect_panel.get_node_or_null("%BackBtn")
	if back_btn:
		back_btn.pressed.connect(_on_back_to_login)


## Validates credentials and initiates a login connection to the server.
func _on_login_pressed() -> void:
	var username := _login_username.text.strip_edges()
	var password := _login_password.text.strip_edges()
	if username.is_empty() or password.is_empty():
		_login_status.text = "Enter username and password."
		return
	if username.length() < 5 or username.length() > 15:
		_login_status.text = "Username must be 5-15 characters."
		return
	if password.length() < 5 or password.length() > 15:
		_login_status.text = "Password must be 5-15 characters."
		return
	_login_status.text = "Connecting…"
	_pending_action = "login"
	_pending_username = username
	_pending_password = password
	if not client.connect_to_server():
		_login_status.text = "Failed to connect."
		return


## Validates all fields and initiates a registration connection to the server.
func _on_register_pressed() -> void:
	var username := _login_username.text.strip_edges()
	var password := _login_password.text.strip_edges()
	if username.is_empty() or password.is_empty():
		_login_status.text = "Fill in username and password to register."
		return
	if username.length() < 5 or username.length() > 15:
		_login_status.text = "Username must be 5-15 characters."
		return
	if password.length() < 5 or password.length() > 15:
		_login_status.text = "Password must be 5-15 characters."
		return
	_login_status.text = "Connecting…"
	_pending_action = "register"
	_pending_username = username
	_pending_password = password
	if not client.connect_to_server():
		_login_status.text = "Failed to connect."
		return


func _send_pending_request() -> void:
	## Called by client_main once the connection is established.
	if _pending_action == "login":
		_login_status.text = "Logging in…"
		client.rpc_id(1, "rpc_login", _pending_username, _pending_password)
	elif _pending_action == "register":
		_login_status.text = "Registering…"
		client.rpc_id(1, "rpc_register", _pending_username, _pending_password)
	_pending_action = ""
	_pending_username = ""
	_pending_password = ""


## Displays the server's login/register response to the player.
func handle_login_result(success: bool, message: String) -> void:
	if _login_status != null:
		_login_status.text = message
	if _charselect_status != null:
		_charselect_status.text = message
	if not success:
		print("client: login failed -- %s" % message)


## Populates the character-select panel with the account's characters.
## characters: Array of [char_id, name, level] entries from the server.
func handle_character_list(characters: Array) -> void:
	# Hide login panel, show character select
	if _login_panel:
		_login_panel.visible = false
	if _charselect_panel:
		_charselect_panel.visible = true
	if _charselect_status:
		_charselect_status.text = ""
	# Populate character list
	if _charselect_list:
		for child in _charselect_list.get_children():
			child.queue_free()
		if characters.is_empty():
			var empty_lbl := Label.new()
			empty_lbl.text = "No characters yet. Create one below."
			empty_lbl.add_theme_font_size_override("font_size", 11)
			_charselect_list.add_child(empty_lbl)
		else:
			for entry in characters:
				if not entry is Array or entry.size() < 3:
					continue
				var char_id: int = int(entry[0])
				var char_name: String = str(entry[1])
				var char_level: int = int(entry[2])
				var row := HBoxContainer.new()
				row.add_theme_constant_override("separation", 8)
				var lbl := Label.new()
				lbl.text = "%s (Lv %d)" % [char_name, char_level]
				lbl.add_theme_font_size_override("font_size", 13)
				lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				row.add_child(lbl)
				var play_btn := Button.new()
				play_btn.text = "Play"
				var cid := char_id
				play_btn.pressed.connect(func():
					if _charselect_status:
						_charselect_status.text = "Entering game…"
					client.rpc_id(1, "rpc_select_character", cid)
				)
				row.add_child(play_btn)
				_charselect_list.add_child(row)


## Sends a character creation request with the name and gender from the input fields.
func _on_create_character_pressed() -> void:
	if _charselect_name_input == null:
		return
	var char_name := _charselect_name_input.text.strip_edges()
	if char_name.length() < 4:
		if _charselect_status:
			_charselect_status.text = "Name must be at least 4 characters."
		return
	if char_name.length() > 20:
		if _charselect_status:
			_charselect_status.text = "Name must be 20 characters or less."
		return
	# Only allow letters, apostrophe, and space
	var valid := true
	var space_count := 0
	for ch in char_name:
		if ch == " ":
			space_count += 1
		elif ch == "'":
			pass
		elif not (ch >= "a" and ch <= "z") and not (ch >= "A" and ch <= "Z"):
			valid = false
			break
	if not valid:
		if _charselect_status:
			_charselect_status.text = "Name can only contain letters, ' and spaces."
		return
	if space_count > 2:
		if _charselect_status:
			_charselect_status.text = "Name can have at most 2 spaces."
		return
	# Gender must be selected (index 0 is the placeholder)
	if _charselect_gender == null or _charselect_gender.selected <= 0:
		if _charselect_status:
			_charselect_status.text = "Please select a gender."
		return
	if _charselect_status:
		_charselect_status.text = "Creating…"
	var gender := "male"
	if _charselect_gender.selected == 2:
		gender = "female"
	client.rpc_id(1, "rpc_create_character", char_name, "none", gender)
	_charselect_name_input.clear()


## Returns to the login panel and disconnects the current peer.
func _on_back_to_login() -> void:
	if _charselect_panel:
		_charselect_panel.visible = false
	if _login_panel:
		_login_panel.visible = true
	if _login_status:
		_login_status.text = ""
	client._disconnect_peer()


## Hides the entire login/character-select layer.
func hide_login() -> void:
	if _login_layer != null:
		_login_layer.visible = false


## Shows the login panel and resets to the login view.
func show_login() -> void:
	if _login_layer != null:
		_login_layer.visible = true
	if _charselect_panel:
		_charselect_panel.visible = false
	if _login_panel:
		_login_panel.visible = true


## Displays an error message on the login status label.
func show_error(message: String) -> void:
	if _login_status != null:
		_login_status.text = message


## Handles a successful logout by returning to the login screen.
func handle_logout_result() -> void:
	client._return_to_login("Logged out.")
