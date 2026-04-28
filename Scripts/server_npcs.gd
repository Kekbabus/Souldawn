#  server_npcs.gd -- NPC spawning, wandering, dialogue, and shop system
#
#  Spawns NPCs from map spawn_points using NPC datapacks.
#  Handles greeting, keyword-driven dialogue trees, vocation assignment,
#  and buy/sell shop interactions.
extends Node

const GREETING_RANGE := 3  # tiles -- must be within range to greet
const DIALOGUE_TIMEOUT := 60.0  # seconds before dialogue auto-closes
const NPC_ID_OFFSET := 100000  # NPC IDs start here to avoid collision with entity IDs
const NPC_WANDER_INTERVAL := 2.0  # seconds between wander steps

var server: Node = null

var _npcs: Dictionary = {}          # npc_id -> {def_id, display_name, position, stationary, spawn_pos, wander_radius, speed}
var _next_npc_id: int = NPC_ID_OFFSET
var _wander_acc: float = 0.0

var _dialogues: Dictionary = {}  # peer_id -> {npc_id, npc_def_id, timer}

var _pending_responses: Array = []  # [{peer_id, npc_name, text, delay}]
const NPC_RESPONSE_DELAY := 0.1


## Queues a delayed NPC chat message to the player (sent after NPC_RESPONSE_DELAY).
func _npc_say(peer_id: int, npc_name: String, text: String) -> void:
	_pending_responses.append({"peer_id": peer_id, "npc_name": npc_name, "text": text, "delay": NPC_RESPONSE_DELAY})


## Spawns all NPCs defined in the map's spawn_points that have matching NPC datapacks.
func spawn_npcs_from_map() -> void:
	var spawn_points: Array = server.map.get_spawn_points()
	var spawned := 0
	for sp in spawn_points:
		if not sp is Dictionary:
			continue
		var def_id: String = str(sp.get("definition_id", ""))
		if def_id.is_empty():
			continue
		var npc_def: Dictionary = server.datapacks.get_npc(def_id)
		if npc_def.is_empty():
			continue  # Not an NPC
		var x: int = int(sp.get("x", 0))
		var y: int = int(sp.get("y", 0))
		var z: int = int(sp.get("z", 7))
		var display_name: String = str(sp.get("display_name", npc_def.get("display_name", def_id)))
		var pos := Vector3i(x, y, z)
		var is_stationary: bool = bool(npc_def.get("stationary", true))
		var wander_radius: int = int(npc_def.get("wander_radius", 3))
		var speed: int = int(npc_def.get("speed", 200))
		var outfit_id: String = str(npc_def.get("outfit_id", ""))
		var npc_id := _next_npc_id
		_next_npc_id += 1
		_npcs[npc_id] = {
			"def_id": def_id,
			"display_name": display_name,
			"position": pos,
			"spawn_pos": pos,
			"stationary": is_stationary,
			"wander_radius": wander_radius,
			"speed": speed,
			"outfit_id": outfit_id,
			"facing": 2,  # south
		}
		spawned += 1
	print("server_npcs: spawned %d NPCs" % spawned)


## Returns true if the given entity_id belongs to an NPC.
func is_npc(entity_id: int) -> bool:
	return _npcs.has(entity_id)


## Returns true if any NPC occupies the given tile position.
func is_npc_at(pos: Vector3i) -> bool:
	for npc_id in _npcs:
		if _npcs[npc_id]["position"] == pos:
			return true
	return false


func send_npcs_to_player(peer_id: int, player_pos: Vector3i) -> void:
	## Sends all nearby NPCs to a player on login.
	for npc_id in _npcs:
		var npc: Dictionary = _npcs[npc_id]
		var np: Vector3i = npc["position"]
		if np.z == player_pos.z and absi(np.x - player_pos.x) <= 20 and absi(np.y - player_pos.y) <= 20:
			var outfit_sprites: String = ""
			var outfit_id: String = str(npc.get("outfit_id", ""))
			if not outfit_id.is_empty():
				outfit_sprites = server.datapacks.get_outfit_sprites_json(outfit_id)
			server.rpc_id(peer_id, "rpc_npc_spawn", npc_id, npc["display_name"],
				np.x, np.y, np.z, outfit_sprites)


#  NPC WANDERING

## Processes random NPC wandering each interval. Skips stationary or in-dialogue NPCs.
func process_npc_wander(delta: float) -> void:
	_wander_acc += delta
	if _wander_acc < NPC_WANDER_INTERVAL:
		return
	_wander_acc -= NPC_WANDER_INTERVAL
	for npc_id in _npcs:
		var npc: Dictionary = _npcs[npc_id]
		if npc["stationary"]:
			continue
		# Don't wander if in dialogue with someone
		var in_dialogue := false
		for pid in _dialogues:
			if _dialogues[pid].get("npc_id", -1) == npc_id:
				in_dialogue = true
				break
		if in_dialogue:
			continue
		# Random chance to stay still
		if randf() < 0.5:
			continue
		# Pick a random cardinal direction
		var dirs := [Vector3i(0, -1, 0), Vector3i(0, 1, 0), Vector3i(-1, 0, 0), Vector3i(1, 0, 0)]
		var dir: Vector3i = dirs[randi() % 4]
		var cur: Vector3i = npc["position"]
		var target := cur + dir
		var spawn: Vector3i = npc["spawn_pos"]
		var radius: int = int(npc["wander_radius"])
		# Stay within wander radius
		if absi(target.x - spawn.x) > radius or absi(target.y - spawn.y) > radius:
			continue
		# Check tile blocking (but exclude NPC's own position)
		if server.map.is_blocking(target):
			continue
		# Don't walk onto players or other NPCs
		if server.is_tile_blocked(target):
			continue
		# Move
		npc["position"] = target
		# Update facing
		if dir.y < 0: npc["facing"] = 0
		elif dir.x > 0: npc["facing"] = 1
		elif dir.y > 0: npc["facing"] = 2
		elif dir.x < 0: npc["facing"] = 3
		# Broadcast move
		var step_ms: int = 500  # NPC walk speed
		if int(npc.get("speed", 200)) > 0:
			step_ms = int(ceilf(1000.0 * 150.0 / float(npc["speed"])))
		for pid in server.get_players_in_range(target, 15):
			server.rpc_id(pid, "rpc_npc_move", npc_id, target.x, target.y, target.z, step_ms)


#  DIALOGUE SYSTEM

func handle_npc_talk(peer_id: int, text: String) -> bool:
	## Called when a player says something. Returns true if handled by NPC dialogue.
	text = text.strip_edges().to_lower()
	if not server._sessions.has(peer_id):
		return false
	var s: Dictionary = server._sessions[peer_id]
	var pp: Vector3i = s["position"]

	# Check if player has an active dialogue
	if _dialogues.has(peer_id):
		var dlg: Dictionary = _dialogues[peer_id]
		# Check if player walked out of range
		var npc_id: int = int(dlg.get("npc_id", -1))
		if _npcs.has(npc_id):
			var np: Vector3i = _npcs[npc_id]["position"]
			if pp.z != np.z or absi(pp.x - np.x) > GREETING_RANGE or absi(pp.y - np.y) > GREETING_RANGE:
				_end_dialogue(peer_id)
				return false
		dlg["timer"] = DIALOGUE_TIMEOUT
		if text == "bye" or text == "farewell":
			_end_dialogue(peer_id)
			return true
		return _process_keyword(peer_id, dlg, text)

	# Check if player said "hi" or "hello" near an NPC
	if text != "hi" and text != "hello" and text != "greetings":
		return false

	# Find nearest NPC within greeting range
	for npc_id in _npcs:
		var npc: Dictionary = _npcs[npc_id]
		var np: Vector3i = npc["position"]
		if np.z != pp.z:
			continue
		if absi(np.x - pp.x) > GREETING_RANGE or absi(np.y - pp.y) > GREETING_RANGE:
			continue
		# Check if another player is already talking to this NPC (old Tibia: 1 at a time)
		var npc_busy := false
		for other_pid in _dialogues:
			if other_pid != peer_id and _dialogues[other_pid]["npc_id"] == npc_id:
				npc_busy = true
				break
		if npc_busy:
			var npc_name: String = str(npc["display_name"])
			_npc_say(peer_id, npc_name, "I am busy right now. Please wait.")
			return true
		# Found an NPC in range -- start dialogue
		var def_id: String = npc["def_id"]
		var npc_def: Dictionary = server.datapacks.get_npc(def_id)
		if npc_def.is_empty():
			continue
		var dialogue: Dictionary = npc_def.get("dialogue_tree", {})
		if dialogue.is_empty():
			continue
		_dialogues[peer_id] = {
			"npc_id": npc_id,
			"npc_def_id": def_id,
			"timer": DIALOGUE_TIMEOUT,
		}
		var greeting: String = str(dialogue.get("greeting", "Hello."))
		var npc_name: String = str(npc["display_name"])
		_npc_say(peer_id, npc_name, greeting)
		return true
	return false


## Processes a keyword spoken during an active dialogue. Returns true if handled.
func _process_keyword(peer_id: int, dlg: Dictionary, text: String) -> bool:
	var def_id: String = dlg["npc_def_id"]
	var npc_def: Dictionary = server.datapacks.get_npc(def_id)
	var dialogue: Dictionary = npc_def.get("dialogue_tree", {})
	var keywords: Dictionary = dialogue.get("keywords", {})
	var npc_id: int = int(dlg.get("npc_id", -1))
	var npc_name: String = str(_npcs[npc_id]["display_name"]) if _npcs.has(npc_id) else str(npc_def.get("display_name", def_id))

	if keywords.has(text):
		var kw: Dictionary = keywords[text]
		var action: String = str(kw.get("action", ""))
		if action == "confirm_vocation":
			var voc_id: String = str(kw.get("action_data", ""))
			dlg["pending_vocation"] = voc_id
			_npc_say(peer_id, npc_name, str(kw.get("text", "")))
			return true
		if action == "apply_vocation":
			return _apply_vocation(peer_id, dlg, npc_name)
		var response: String = str(kw.get("text", ""))
		_npc_say(peer_id, npc_name, response)
		if action == "open_shop":
			_open_shop(peer_id, npc_def)
		return true
	return false


## Applies the pending vocation choice to the player if eligible (level 8+, no existing vocation).
func _apply_vocation(peer_id: int, dlg: Dictionary, npc_name: String) -> bool:
	var pending: String = str(dlg.get("pending_vocation", ""))
	if pending.is_empty():
		_npc_say(peer_id, npc_name, "You haven't chosen a vocation yet. Say {knight}, {paladin}, {sorcerer}, or {druid}.")
		return true
	if not server._sessions.has(peer_id):
		return true
	var s: Dictionary = server._sessions[peer_id]
	var current_voc: String = str(s.get("vocation", "none"))
	if current_voc != "none":
		_npc_say(peer_id, npc_name, "You are already a %s. Your path has been chosen." % server.combat.get_vocation(s).get("display_name", current_voc))
		dlg.erase("pending_vocation")
		return true
	var level: int = int(s.get("level", 1))
	if level < 8:
		_npc_say(peer_id, npc_name, "You must reach level 8 before choosing a vocation. You are only level %d." % level)
		dlg.erase("pending_vocation")
		return true
	if not server.combat.VOCATIONS.has(pending):
		_npc_say(peer_id, npc_name, "That is not a valid vocation.")
		dlg.erase("pending_vocation")
		return true
	s["vocation"] = pending
	var voc: Dictionary = server.combat.get_vocation(s)
	var voc_name: String = str(voc.get("display_name", pending))
	s["max_health"] = int(voc["base_hp"]) + (int(s["level"]) - 1) * int(voc["hp_per_level"])
	s["max_mana"] = int(voc["base_mana"]) + (int(s["level"]) - 1) * int(voc["mana_per_level"])
	s["health"] = s["max_health"]
	s["mana"] = s["max_mana"]
	_npc_say(peer_id, npc_name, "You are now a %s! Your health and mana have been adjusted. Go forth and be brave!" % voc_name)
	server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "You have become a %s!" % voc_name)
	server.spells.send_stats(peer_id)
	server.inventory.send_combat_stats(peer_id)
	server.combat.send_skills(peer_id)
	dlg.erase("pending_vocation")
	return true


## Ends the active dialogue with an NPC, sending the farewell message.
func _end_dialogue(peer_id: int) -> void:
	if not _dialogues.has(peer_id):
		return
	var dlg: Dictionary = _dialogues[peer_id]
	var npc_def: Dictionary = server.datapacks.get_npc(dlg["npc_def_id"])
	var dialogue: Dictionary = npc_def.get("dialogue_tree", {})
	var farewell: String = str(dialogue.get("farewell", "Goodbye."))
	var npc_name: String = str(_npcs[int(dlg.get("npc_id", -1))]["display_name"]) if _npcs.has(int(dlg.get("npc_id", -1))) else str(npc_def.get("display_name", dlg["npc_def_id"]))
	_npc_say(peer_id, npc_name, farewell)
	_dialogues.erase(peer_id)


## Ticks dialogue timers, sends pending NPC responses, and ends timed-out or out-of-range dialogues.
func process_dialogue_timeouts(delta: float) -> void:
	# Process pending delayed responses
	var i := _pending_responses.size() - 1
	while i >= 0:
		_pending_responses[i]["delay"] -= delta
		if _pending_responses[i]["delay"] <= 0.0:
			var r: Dictionary = _pending_responses[i]
			var npc_name: String = str(r["npc_name"])
			var text: String = str(r["text"])
			var target_pid: int = int(r["peer_id"])
			# Broadcast NPC speech to all nearby players (visible to everyone in range)
			var npc_pos: Vector3i = Vector3i.ZERO
			# Find the NPC position from the active dialogue
			if _dialogues.has(target_pid):
				var npc_id: int = int(_dialogues[target_pid].get("npc_id", -1))
				if _npcs.has(npc_id):
					npc_pos = _npcs[npc_id]["position"]
			if npc_pos != Vector3i.ZERO:
				for pid in server.get_players_in_range(npc_pos, server.NEARBY_RANGE):
					server.rpc_id(pid, "rpc_npc_dialogue", npc_name, text)
			else:
				# Fallback: send only to the target player
				server.rpc_id(target_pid, "rpc_npc_dialogue", npc_name, text)
			_pending_responses.remove_at(i)
		i -= 1
	var expired: Array = []
	for pid in _dialogues:
		_dialogues[pid]["timer"] = float(_dialogues[pid]["timer"]) - delta
		if float(_dialogues[pid]["timer"]) <= 0.0:
			expired.append(pid)
			continue
		# Check range -- end dialogue if player walked away
		if server._sessions.has(pid):
			var pp: Vector3i = server._sessions[pid]["position"]
			var npc_id: int = int(_dialogues[pid].get("npc_id", -1))
			if _npcs.has(npc_id):
				var np: Vector3i = _npcs[npc_id]["position"]
				if pp.z != np.z or absi(pp.x - np.x) > GREETING_RANGE or absi(pp.y - np.y) > GREETING_RANGE:
					expired.append(pid)
	for pid in expired:
		_end_dialogue(pid)


## Cleans up any active dialogue when a peer disconnects.
func on_peer_disconnect(peer_id: int) -> void:
	_dialogues.erase(peer_id)


#  SHOP SYSTEM

## Opens the NPC's shop window for the player, sending all buy/sell offers.
func _open_shop(peer_id: int, npc_def: Dictionary) -> void:
	var offers = npc_def.get("shop_offers", [])
	if not offers is Array or offers.is_empty():
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "This NPC has nothing to sell.")
		return
	var shop_data: Array = []
	for offer in offers:
		var item_id: String = str(offer.get("item_id", ""))
		var buy_price: int = int(offer.get("buy_price", 0))
		var sell_price: int = int(offer.get("sell_price", 0))
		var item_name: String = server.datapacks.get_item_name(item_id)
		shop_data.append([item_id, item_name, buy_price, sell_price])
	var npc_name: String = str(npc_def.get("display_name", ""))
	server.rpc_id(peer_id, "rpc_shop_open", npc_name, shop_data)


## Handles a player buying items from an NPC shop. Deducts gold and adds items.
func handle_shop_buy(peer_id: int, item_id: String, count: int) -> void:
	if not server._sessions.has(peer_id):
		return
	if not _dialogues.has(peer_id):
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "You're not talking to an NPC.")
		return
	var dlg: Dictionary = _dialogues[peer_id]
	var npc_def: Dictionary = server.datapacks.get_npc(dlg["npc_def_id"])
	var offers = npc_def.get("shop_offers", [])
	# Find the offer
	var buy_price: int = 0
	for offer in offers:
		if str(offer.get("item_id", "")) == item_id:
			buy_price = int(offer.get("buy_price", 0))
			break
	if buy_price <= 0:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Item not available.")
		return
	var total_cost: int = buy_price * count
	# Check if player has enough gold (any denomination)
	var gold_total: int = server.inventory.count_total_gold(peer_id)
	if gold_total < total_cost:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "You need %d gold coins." % total_cost)
		return
	# Remove gold (breaks larger coins, gives change via give_item)
	server.inventory.remove_gold(peer_id, total_cost)
	var added: int = server.inventory.give_item(peer_id, item_id, count)
	var item_name: String = server.datapacks.get_item_name(item_id)
	server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
		"You bought %d %s for %d gold." % [added, item_name, total_cost])
	server.inventory.send_inventory(peer_id)


## Handles a player selling items to an NPC shop. Removes items and adds gold.
func handle_shop_sell(peer_id: int, item_id: String, count: int) -> void:
	if not server._sessions.has(peer_id):
		return
	if not _dialogues.has(peer_id):
		return
	var dlg: Dictionary = _dialogues[peer_id]
	var npc_def: Dictionary = server.datapacks.get_npc(dlg["npc_def_id"])
	var offers = npc_def.get("shop_offers", [])
	var sell_price: int = 0
	for offer in offers:
		if str(offer.get("item_id", "")) == item_id:
			sell_price = int(offer.get("sell_price", 0))
			break
	if sell_price <= 0:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "I don't buy that.")
		return
	var have: int = _count_item(peer_id, item_id)
	if have < count:
		count = have
	if count <= 0:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "You don't have that item.")
		return
	var total_gold: int = sell_price * count
	_remove_item(peer_id, item_id, count)
	server.inventory.give_item(peer_id, "gold_coin", total_gold)
	var item_name: String = server.datapacks.get_item_name(item_id)
	server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
		"You sold %d %s for %d gold." % [count, item_name, total_gold])
	server.inventory.send_inventory(peer_id)


## Returns the total count of a specific item in the player's inventory.
func _count_item(peer_id: int, item_id: String) -> int:
	if not server._sessions.has(peer_id):
		return 0
	var inv: Array = server._sessions[peer_id]["inventory"]
	var total := 0
	for slot in inv:
		if str(slot["item_id"]) == item_id:
			total += int(slot["count"])
	return total


## Removes up to count of item_id from the player's inventory.
func _remove_item(peer_id: int, item_id: String, count: int) -> void:
	if not server._sessions.has(peer_id):
		return
	var inv: Array = server._sessions[peer_id]["inventory"]
	var remaining := count
	var i := inv.size() - 1
	while i >= 0 and remaining > 0:
		if str(inv[i]["item_id"]) == item_id:
			var have: int = int(inv[i]["count"])
			if have <= remaining:
				remaining -= have
				inv.remove_at(i)
			else:
				inv[i]["count"] = have - remaining
				remaining = 0
		i -= 1
