#  server_auth.gd -- Account registration, login, logout, enter-game
#  Now uses SQLite database for persistent accounts/characters.
extends Node

const BACKPACK_SIZE := 10
const EQUIPMENT_SLOTS := ["head", "neck", "armor", "legs", "boots", "ring", "weapon", "shield", "arrow", "backpack"]
const ENTITY_NEARBY_RANGE := 20

var server: Node = null

var _authenticated_peers: Dictionary = {} # peer_id -> {account_id, char_id}


## Returns the SHA-256 hash of a password string.
func _hash_password(password: String) -> String:
	return password.sha256_text()


## Validates input, creates an account, and sends the (empty) character list.
func handle_register(peer_id: int, username: String, password: String) -> void:
	username = username.strip_edges().to_lower()
	password = password.strip_edges()
	if username.length() < 5 or username.length() > 15:
		server.rpc_id(peer_id, "rpc_login_result", false, "Username must be 5-15 characters.")
		return
	if password.length() < 5 or password.length() > 15:
		server.rpc_id(peer_id, "rpc_login_result", false, "Password must be 5-15 characters.")
		return
	if server.db.account_exists(username):
		server.rpc_id(peer_id, "rpc_login_result", false, "Account already exists.")
		return

	var pw_hash := _hash_password(password)
	var account_id: int = server.db.create_account(username, pw_hash)
	if account_id < 0:
		server.rpc_id(peer_id, "rpc_login_result", false, "Failed to create account.")
		return

	print("server: account registered -- %s" % username)
	_authenticated_peers[peer_id] = {"account_id": account_id, "char_id": -1}
	server.rpc_id(peer_id, "rpc_login_result", true, "Account created!")
	_send_character_list(peer_id, account_id)


## Verifies credentials and sends the character list on success.
func handle_login(peer_id: int, username: String, password: String) -> void:
	username = username.strip_edges().to_lower()
	password = password.strip_edges()
	var pw_hash := _hash_password(password)
	var account_id: int = server.db.verify_account(username, pw_hash)
	if account_id < 0:
		server.rpc_id(peer_id, "rpc_login_result", false, "Invalid username or password.")
		return
	# Check if already logged in
	for pid in _authenticated_peers:
		if _authenticated_peers[pid].get("account_id", -1) == account_id:
			server.rpc_id(peer_id, "rpc_login_result", false, "Account already logged in.")
			return

	_authenticated_peers[peer_id] = {"account_id": account_id, "char_id": -1}
	server.rpc_id(peer_id, "rpc_login_result", true, "Login successful!")
	_send_character_list(peer_id, account_id)


## Sends the list of characters for an account to the client.
func _send_character_list(peer_id: int, account_id: int) -> void:
	var chars: Array = server.db.get_characters_by_account(account_id)
	var char_list: Array = []
	for c in chars:
		char_list.append([int(c["id"]), str(c["name"]), int(c["level"])])
	server.rpc_id(peer_id, "rpc_character_list", char_list)


## Loads the selected character and enters the game world.
func handle_select_character(peer_id: int, char_id: int) -> void:
	if not _authenticated_peers.has(peer_id):
		server.rpc_id(peer_id, "rpc_login_result", false, "Not authenticated.")
		return
	var account_id: int = _authenticated_peers[peer_id]["account_id"]
	# Check if this character is already in-game on another peer
	for pid in _authenticated_peers:
		if pid != peer_id and _authenticated_peers[pid].get("char_id", -1) == char_id:
			server.rpc_id(peer_id, "rpc_login_result", false, "Character already in use.")
			return
	# Check for orphan session with this character (x-logged player reconnecting)
	for pid in server._sessions.keys():
		var s: Dictionary = server._sessions[pid]
		if int(s.get("char_id", 0)) == char_id and s.get("_orphan", false):
			# Clean up the orphan session before allowing re-login
			print("server: cleaning up orphan session for char_id %d (old peer %d)" % [char_id, pid])
			server.combat._combat_targets.erase(pid)
			server.combat.clear_conditions(pid)
			server.spells.clear_buffs(pid)
			_save_and_remove(pid)
			break
	var char_data: Dictionary = server.db.get_character_by_id(char_id, account_id)
	if char_data.is_empty():
		server.rpc_id(peer_id, "rpc_login_result", false, "Character not found.")
		return
	_authenticated_peers[peer_id]["char_id"] = char_id
	_enter_game(peer_id, char_data)


## Creates a new character on the authenticated account and refreshes the list.
func handle_create_character(peer_id: int, character_name: String, vocation: String = "none", gender: String = "male") -> void:
	if not _authenticated_peers.has(peer_id):
		server.rpc_id(peer_id, "rpc_login_result", false, "Not authenticated.")
		return
	character_name = character_name.strip_edges()
	if character_name.length() < 4 or character_name.length() > 20:
		server.rpc_id(peer_id, "rpc_login_result", false, "Character name must be 4-20 characters.")
		return
	if server.db.character_name_exists(character_name):
		server.rpc_id(peer_id, "rpc_login_result", false, "Character name already taken.")
		return
	# Validate vocation
	vocation = vocation.strip_edges().to_lower()
	if not server.combat.VOCATIONS.has(vocation):
		vocation = "none"
	# Validate gender
	gender = gender.strip_edges().to_lower()
	if gender != "male" and gender != "female":
		gender = "male"
	var account_id: int = _authenticated_peers[peer_id]["account_id"]
	var char_id: int = server.db.create_character(account_id, character_name, vocation, gender)
	if char_id < 0:
		server.rpc_id(peer_id, "rpc_login_result", false, "Failed to create character.")
		return
	_send_character_list(peer_id, account_id)


## Logs the player out if not combat-locked, saving their session first.
func handle_logout(peer_id: int) -> void:
	if server._sessions.has(peer_id):
		var s: Dictionary = server._sessions[peer_id]
		# Dead players can always logout (no combat lock check)
		if not s.get("is_dead", false):
			var now_ms := Time.get_ticks_msec()
			var combat_until: float = float(s.get("combat_lock_until", 0.0))
			if now_ms < combat_until:
				server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
					"You may not logout during or shortly after a fight.")
				return
	_save_and_remove(peer_id)
	_authenticated_peers.erase(peer_id)
	server.rpc_id(peer_id, "rpc_logout_result")


## Persists the player's session to DB, removes them from the world, and notifies others.
func _save_and_remove(peer_id: int) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	var display_name: String = s.get("display_name", "")
	# If player is dead, auto-respawn before saving (so they don't load with 0 HP)
	if s.get("is_dead", false):
		s["health"] = s["max_health"]
		s["mana"] = s["max_mana"]
		s["position"] = Vector3i(server._next_spawn_x, server._next_spawn_y, 7)
		s["is_dead"] = false
	# Save to DB
	var char_id: int = s.get("char_id", 0)
	if char_id > 0:
		var pos: Vector3i = s["position"]
		server.db.save_character(char_id, {
			"level": s["level"],
			"experience": s["experience"],
			"health": s["health"],
			"max_health": s["max_health"],
			"mana": s["mana"],
			"max_mana": s["max_mana"],
			"pos_x": pos.x,
			"pos_y": pos.y,
			"pos_z": pos.z,
			"speed": s["speed"],
			"inventory": s["inventory"],
			"equipment": s["equipment"],
			"outfit_id": s.get("outfit_id", "citizen_male"),
			"outfit_head": s.get("outfit_head", "#ffff00"),
			"outfit_body": s.get("outfit_body", "#4d80ff"),
			"outfit_legs": s.get("outfit_legs", "#4d80ff"),
			"outfit_feet": s.get("outfit_feet", "#996633"),
			"skills": s.get("skills", {}),
			"vocation": s.get("vocation", "none"),
			"food_timer": s.get("food_timer", 0.0),
			"equip_counts": s.get("equip_counts", {}),
			"gender": s.get("gender", "male"),
		})
	server.combat._combat_targets.erase(peer_id)
	server._grid_remove(peer_id)
	server._sessions.erase(peer_id)
	for other_id in server._sessions:
		server.rpc_id(other_id, "rpc_player_despawn", peer_id)
		if not display_name.is_empty():
			server.rpc_id(other_id, "rpc_receive_chat", "system", "", "%s has logged out." % display_name)


## Builds the session dict, spawns the player, and syncs world state to the client.
func _enter_game(peer_id: int, char_data: Dictionary) -> void:
	var loaded: Dictionary = server.db.load_character_into_session(char_data)
	var spawn_pos := Vector3i(
		int(loaded.get("pos_x", 0)),
		int(loaded.get("pos_y", 0)),
		int(loaded.get("pos_z", 7)))
	var session := {
		"peer_id": peer_id,
		"char_id": int(loaded.get("char_id", 0)),
		"position": spawn_pos,
		"speed": float(loaded.get("speed", server.DEFAULT_PLAYER_SPEED)),
		"walk_dir": Vector2i.ZERO,
		"walk_dir_time": 0.0,
		"last_move_time": 0.0,
		"last_move_diagonal": false,
		"display_name": str(loaded.get("display_name", "")),
		"facing_direction": 2,
		"health": int(loaded.get("health", 150)),
		"max_health": int(loaded.get("max_health", 150)),
		"is_dead": false,
		"level": int(loaded.get("level", 1)),
		"experience": int(loaded.get("experience", 0)),
		"inventory": loaded.get("inventory", []),
		"equipment": loaded.get("equipment", {"head": "", "neck": "", "armor": "", "legs": "", "boots": "", "ring": "", "weapon": "", "shield": "", "arrow": "", "backpack": ""}),
		"mana": int(loaded.get("mana", 50)),
		"max_mana": int(loaded.get("max_mana", 50)),
		"spell_cooldowns": {},
		"combat_lock_until": 0.0,
		"equip_counts": loaded.get("equip_counts", {}),
		"food_timer": float(loaded.get("food_timer", 0.0)),
		"outfit_id": str(loaded.get("outfit_id", "citizen_male")),
		"outfit_head": str(loaded.get("outfit_head", "#ffff00")),
		"outfit_body": str(loaded.get("outfit_body", "#4d80ff")),
		"outfit_legs": str(loaded.get("outfit_legs", "#4d80ff")),
		"outfit_feet": str(loaded.get("outfit_feet", "#996633")),
		"skills": loaded.get("skills", {}),
		"vocation": str(loaded.get("vocation", "none")),
		"gender": str(loaded.get("gender", "male")),
	}
	server._sessions[peer_id] = session
	# Initialize default skills if empty
	server.combat.init_skills(session)
	# Apply Tibia speed formula: base_speed = 220 + 2*(level-1)
	var level: int = int(session["level"])
	session["base_speed"] = 220 + 2 * (level - 1)
	session["speed"] = session["base_speed"]
	# Resolve outfit sprites JSON
	var outfit_sprites: String = server.datapacks.get_outfit_sprites_json(session["outfit_id"])
	# Patch equipment dict to include any new slots added after DB was created
	var equip: Dictionary = session["equipment"]
	for slot_name in EQUIPMENT_SLOTS:
		if not equip.has(slot_name):
			equip[slot_name] = ""
	server._grid_add(peer_id, spawn_pos)

	server.rpc_id(peer_id, "rpc_enter_world", peer_id, spawn_pos.x, spawn_pos.y, spawn_pos.z,
		session["display_name"], int(session["speed"]), outfit_sprites, session.get("gender", "male"))
	# Send outfit colors to the player themselves
	server.rpc_id(peer_id, "rpc_outfit_update", peer_id, session["outfit_id"], outfit_sprites,
		session["outfit_head"], session["outfit_body"], session["outfit_legs"], session["outfit_feet"])
	server.spells.send_stats(peer_id)
	server.combat.send_skills(peer_id)

	# Tell the new player about every existing player
	for other_id in server._sessions:
		if other_id == peer_id:
			continue
		var other: Dictionary = server._sessions[other_id]
		var op: Vector3i = other["position"]
		var other_outfit: String = server.datapacks.get_outfit_sprites_json(str(other.get("outfit_id", "citizen_male")))
		server.rpc_id(peer_id, "rpc_player_spawn", other_id, op.x, op.y, op.z,
			other["display_name"], int(other["speed"]), other_outfit)
		# Send existing player's outfit colors to the new player
		server.rpc_id(peer_id, "rpc_outfit_update", other_id, str(other.get("outfit_id", "citizen_male")),
			other_outfit, str(other.get("outfit_head", "#ffff00")), str(other.get("outfit_body", "#4d80ff")),
			str(other.get("outfit_legs", "#4d80ff")), str(other.get("outfit_feet", "#996633")))

	# Tell every existing player about the new player
	for other_id in server._sessions:
		if other_id == peer_id:
			continue
		server.rpc_id(other_id, "rpc_player_spawn", peer_id, spawn_pos.x, spawn_pos.y, spawn_pos.z,
			session["display_name"], int(session["speed"]), outfit_sprites)
		server.rpc_id(other_id, "rpc_receive_chat", "system", "", "%s has logged in." % session["display_name"])
		# Send outfit colors to existing players
		server.rpc_id(other_id, "rpc_outfit_update", peer_id, session["outfit_id"], outfit_sprites,
			session["outfit_head"], session["outfit_body"], session["outfit_legs"], session["outfit_feet"])
		# Send new player's health to existing players
		server.rpc_id(other_id, "rpc_player_damage", peer_id, 0, "physical",
			int(session["health"]), int(session["max_health"]))
		# Send existing player's health to the new player
		var other: Dictionary = server._sessions[other_id]
		if not other.get("_orphan", false):
			server.rpc_id(peer_id, "rpc_player_damage", other_id, 0, "physical",
				int(other["health"]), int(other["max_health"]))

	# Tell the new player about nearby entities on the same z-level
	var ents: Dictionary = server.entities._entities
	for eid in ents:
		var ent: Dictionary = ents[eid]
		var ep: Vector3i = ent["position"]
		if ep.z == spawn_pos.z and absi(ep.x - spawn_pos.x) <= ENTITY_NEARBY_RANGE and absi(ep.y - spawn_pos.y) <= ENTITY_NEARBY_RANGE:
			server.rpc_id(peer_id, "rpc_entity_spawn", eid, ent["definition_id"], ent["display_name"],
				ep.x, ep.y, ep.z, int(ent["health"]), int(ent["max_health"]), int(ent["speed"]),
				str(ent.get("sprites_json", "")))

	# Tell the new player about nearby NPCs
	server.npcs.send_npcs_to_player(peer_id, spawn_pos)

	# Tell the new player about nearby ground items on the same z-level
	var ground: Dictionary = server.inventory._ground_items
	for gpos in ground:
		var gp: Vector3i = gpos
		if gp.z != spawn_pos.z:
			continue
		if absi(gp.x - spawn_pos.x) > server.NEARBY_RANGE or absi(gp.y - spawn_pos.y) > server.NEARBY_RANGE:
			continue
		var items: Array = ground[gpos]
		for item in items:
			var item_id: String = str(item["item_id"])
			var count: int = int(item["count"])
			var sprite: String = server.datapacks.get_sprite_for_count(item_id, count)
			server.rpc_id(peer_id, "rpc_ground_item", gp.x, gp.y, gp.z,
				item_id, count, true, sprite)

	# Send initial inventory, equipment, map chunks, and nearby containers
	server.inventory.send_inventory(peer_id)
	server.inventory.send_equipment(peer_id)
	server.chunks.send_initial_chunks(peer_id, spawn_pos)
	server.containers.send_nearby_containers(peer_id, spawn_pos)
	server.fields.send_nearby_fields(peer_id, spawn_pos)


## Updates the player's outfit and broadcasts the change to nearby players.
func handle_change_outfit(peer_id: int, outfit_id: String, head_color: String, body_color: String, legs_color: String, feet_color: String) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	# Validate outfit exists
	if not server.datapacks.get_outfit(outfit_id).is_empty():
		s["outfit_id"] = outfit_id
	s["outfit_head"] = head_color
	s["outfit_body"] = body_color
	s["outfit_legs"] = legs_color
	s["outfit_feet"] = feet_color
	# Broadcast to all nearby players
	var sprites_json: String = server.datapacks.get_outfit_sprites_json(s["outfit_id"])
	var pos: Vector3i = s["position"]
	for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
		server.rpc_id(pid, "rpc_outfit_update", peer_id, s["outfit_id"], sprites_json,
			head_color, body_color, legs_color, feet_color)
