#  server_chat.gd -- Chat system (say, yell, whisper, broadcast) and
#  GM slash-commands (/give, /spawn, /teleport, etc.)
extends Node

const SAY_RANGE := 7
const YELL_RANGE := 30

var server: Node = null  # server_main.gd


## Routes a chat message by channel, checking for spells, NPC dialogue, and GM commands.
func handle_send_chat(peer_id: int, channel: String, text: String) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	if s.get("is_dead", false):
		return
	text = text.strip_edges().left(200)
	if text.is_empty():
		return

	# GM commands -- any account with id 1 is GM (first registered account)
	if text.begins_with("/") and _is_gm(peer_id):
		if _handle_gm_command(peer_id, text):
			return

	# Check if the text is a spell incantation FIRST (say channel only)
	# This allows casting spells even while in NPC dialogue
	if channel == "say":
		var spell_text := text.strip_edges().to_lower()
		# Exact match first (most spells)
		if server.spells._spell_defs.has(spell_text):
			var cast_ok: bool = server.spells.handle_cast_spell(peer_id, spell_text)
			if cast_ok:
				var sender_name2: String = s["display_name"]
				var pos2: Vector3i = s["position"]
				for pid in server.get_players_in_range(pos2, SAY_RANGE):
					server.rpc_id(pid, "rpc_receive_chat", "say", sender_name2, text)
			return
		# Check for spells with parameters (e.g., exiva "player name")
		for spell_words in server.spells._spell_defs:
			if spell_text.begins_with(spell_words + " "):
				var param: String = spell_text.substr(len(spell_words) + 1).strip_edges()
				# Remove surrounding quotes if present
				if param.begins_with("\"") and param.ends_with("\""):
					param = param.substr(1, param.length() - 2)
				s["_spell_param"] = param
				var cast_ok: bool = server.spells.handle_cast_spell(peer_id, spell_words)
				s.erase("_spell_param")
				if cast_ok:
					var sender_name2: String = s["display_name"]
					var pos2: Vector3i = s["position"]
					for pid in server.get_players_in_range(pos2, SAY_RANGE):
						server.rpc_id(pid, "rpc_receive_chat", "say", sender_name2, text)
				return

	# Check NPC dialogue (for "say" channel)
	if channel == "say" and server.npcs.handle_npc_talk(peer_id, text):
		var sender_name: String = s["display_name"]
		var pos: Vector3i = s["position"]
		for pid in server.get_players_in_range(pos, SAY_RANGE):
			server.rpc_id(pid, "rpc_receive_chat", "say", sender_name, text)
		return
	var sender_name: String = s["display_name"]
	var pos: Vector3i = s["position"]
	match channel:
		"say":
			for pid in server.get_players_in_range(pos, SAY_RANGE):
				server.rpc_id(pid, "rpc_receive_chat", "say", sender_name, text)
		"yell":
			for pid in server.get_players_in_range(pos, YELL_RANGE):
				server.rpc_id(pid, "rpc_receive_chat", "yell", sender_name, text.to_upper())
		"global":
			for pid in server._sessions:
				server.rpc_id(pid, "rpc_receive_chat", "global", sender_name, text)
		"trade":
			for pid in server._sessions:
				server.rpc_id(pid, "rpc_receive_chat", "trade", sender_name, text)
		"whisper":
			var space_pos := text.find(" ")
			if space_pos < 0:
				return
			var target_name: String = text.left(space_pos)
			var msg: String = text.substr(space_pos + 1)
			# Validate target exists
			var found := false
			for pid in server._sessions:
				if server._sessions[pid]["display_name"].to_lower() == target_name.to_lower():
					server.rpc_id(pid, "rpc_receive_chat", "whisper", sender_name, msg)
					server.rpc_id(peer_id, "rpc_receive_chat", "whisper_sent", target_name, msg)
					found = true
					break
			if not found:
				server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Player '%s' is not online." % target_name)
		"broadcast":
			# Legacy -- treat as global
			for pid in server._sessions:
				server.rpc_id(pid, "rpc_receive_chat", "global", sender_name, text)


#  GM COMMANDS
#  First registered account (account_id = 1) is automatically GM.
#  Commands:
#    /give <item_id> [count]    -- add item to inventory
#    /equip <item_id> <slot>    -- force equip item to slot
#    /setlevel <level>          -- set player level
#    /heal                      -- full heal + mana
#    /teleport <x> <y> [z]     -- teleport to position
#    /spawn <monster_id>        -- spawn monster at current position
#    /gm                        -- show available commands

## Returns true if the peer's account_id is 1 (first registered account).
func _is_gm(peer_id: int) -> bool:
	if not server.auth._authenticated_peers.has(peer_id):
		return false
	var auth_data: Dictionary = server.auth._authenticated_peers[peer_id]
	return int(auth_data.get("account_id", 0)) == 1


## Sends a system chat message prefixed with [GM] to the peer.
func _gm_msg(peer_id: int, text: String) -> void:
	server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "[GM] %s" % text)


## Parses and executes a slash command. Returns true if the command was handled.
func _handle_gm_command(peer_id: int, text: String) -> bool:
	var parts := text.split(" ", false)
	if parts.is_empty():
		return false
	var cmd: String = parts[0].to_lower()

	match cmd:
		"/gm":
			_gm_msg(peer_id, "GM Commands: /give, /equip, /setlevel, /setskill, /heal, /teleport, /spawn, /save")
			return true

		"/save":
			server.db.force_save_and_backup()
			_gm_msg(peer_id, "All players saved + backup created.")
			return true

		"/give":
			if parts.size() < 2:
				_gm_msg(peer_id, "Usage: /give <item_id> [count]")
				return true
			var item_id: String = parts[1]
			var count: int = int(parts[2]) if parts.size() > 2 else 1
			count = clampi(count, 1, 100)
			if server.datapacks.get_item(item_id).is_empty():
				_gm_msg(peer_id, "Unknown item: %s" % item_id)
				return true
			if not server.inventory.has_backpack(peer_id):
				_gm_msg(peer_id, "No backpack equipped. Use /equip brown_backpack backpack first.")
				return true
			var added: int = server.inventory.give_item(peer_id, item_id, count)
			server.inventory.send_inventory(peer_id)
			server.containers.broadcast_container_update(-peer_id)
			var name: String = server.datapacks.get_item_name(item_id)
			_gm_msg(peer_id, "Gave %d %s" % [added, name])
			return true

		"/equip":
			if parts.size() < 3:
				_gm_msg(peer_id, "Usage: /equip <item_id> <slot> (slots: head, armor, legs, weapon, backpack)")
				return true
			var item_id: String = parts[1]
			var slot_name: String = parts[2].to_lower()
			if server.datapacks.get_item(item_id).is_empty():
				_gm_msg(peer_id, "Unknown item: %s" % item_id)
				return true
			var s: Dictionary = server._sessions[peer_id]
			var equip: Dictionary = s["equipment"]
			# Ensure slot exists (handles old sessions missing new slots)
			if not equip.has(slot_name):
				if slot_name in server.inventory.EQUIPMENT_SLOTS:
					equip[slot_name] = ""
				else:
					_gm_msg(peer_id, "Invalid slot: %s" % slot_name)
					return true
			equip[slot_name] = item_id
			server.inventory.send_equipment(peer_id)
			var name: String = server.datapacks.get_item_name(item_id)
			_gm_msg(peer_id, "Equipped %s to %s" % [name, slot_name])
			return true

		"/setlevel":
			if parts.size() < 2:
				_gm_msg(peer_id, "Usage: /setlevel <level>")
				return true
			var level: int = clampi(int(parts[1]), 1, 1000)
			var s: Dictionary = server._sessions[peer_id]
			var voc: Dictionary = server.combat.get_vocation(s)
			s["level"] = level
			s["max_health"] = int(voc["base_hp"]) + (level - 1) * int(voc["hp_per_level"])
			s["max_mana"] = int(voc["base_mana"]) + (level - 1) * int(voc["mana_per_level"])
			s["health"] = s["max_health"]
			s["mana"] = s["max_mana"]
			s["experience"] = server.combat._xp_for_level(level)
			server.combat.recalculate_speed(s)
			server.spells.send_stats(peer_id)
			server.inventory.send_combat_stats(peer_id)
			_gm_msg(peer_id, "Set level to %d (speed: %d)" % [level, int(s["speed"])])
			return true

		"/heal":
			var s: Dictionary = server._sessions[peer_id]
			s["health"] = s["max_health"]
			s["mana"] = s["max_mana"]
			server.spells.send_stats(peer_id)
			_gm_msg(peer_id, "Fully healed.")
			return true

		"/teleport":
			if parts.size() < 3:
				_gm_msg(peer_id, "Usage: /teleport <x> <y> [z]")
				return true
			var tx: int = int(parts[1])
			var ty: int = int(parts[2])
			var tz: int = int(parts[3]) if parts.size() > 3 else 7
			var s: Dictionary = server._sessions[peer_id]
			s["position"] = Vector3i(tx, ty, tz)
			server.grid_update(peer_id, Vector3i(tx, ty, tz))
			server.rpc_id(peer_id, "rpc_player_teleport", peer_id, tx, ty, tz)
			_gm_msg(peer_id, "Teleported to (%d, %d, %d)" % [tx, ty, tz])
			return true

		"/spawn":
			if parts.size() < 2:
				_gm_msg(peer_id, "Usage: /spawn <monster_id>")
				return true
			var monster_id: String = parts[1]
			var mdef: Dictionary = server.datapacks.get_monster(monster_id)
			if mdef.is_empty():
				_gm_msg(peer_id, "Unknown monster: %s" % monster_id)
				return true
			var s: Dictionary = server._sessions[peer_id]
			var pos: Vector3i = s["position"]
			var spawn_pos := Vector3i(pos.x + 1, pos.y, pos.z)
			var display_name: String = str(mdef.get("display_name", monster_id))
			var health: int = int(mdef.get("base_health", 100))
			var speed: int = int(mdef.get("speed", 200))
			var xp: int = int(mdef.get("experience_reward", 0))
			server.entities.spawn_entity(monster_id, display_name, spawn_pos, health, speed, xp)
			_gm_msg(peer_id, "Spawned %s at (%d, %d)" % [display_name, spawn_pos.x, spawn_pos.y])
			return true

		"/setskill":
			if parts.size() < 3:
				_gm_msg(peer_id, "Usage: /setskill <skill_name> <level>")
				_gm_msg(peer_id, "Skills: fist, club, sword, axe, distance, shielding, magic_level")
				return true
			var skill_name: String = parts[1].to_lower()
			var skill_level: int = clampi(int(parts[2]), 0, 200)
			if not server.combat.ALL_SKILLS.has(skill_name):
				_gm_msg(peer_id, "Unknown skill: %s" % skill_name)
				return true
			var s: Dictionary = server._sessions[peer_id]
			var skills: Dictionary = s.get("skills", {})
			if skills.has(skill_name):
				skills[skill_name]["level"] = skill_level
				skills[skill_name]["tries"] = 0
				server.combat.send_skills(peer_id)
				_gm_msg(peer_id, "Set %s to level %d" % [skill_name, skill_level])
			return true

	return false
