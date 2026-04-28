#  server_inventory.gd -- Player inventory, equipment, ground items, and loot
#
#  Manages backpack contents, equipment slots, ground item stacks,
#  pickup/drop logic, drag-drop reordering, and weight/capacity checks.
extends Node

const BACKPACK_SIZE := 10  # Fallback if no backpack equipped
const PICKUP_RANGE := 1
const EQUIPMENT_SLOTS := ["head", "neck", "armor", "legs", "boots", "ring", "weapon", "shield", "arrow", "backpack"]

var server: Node = null  # server_main.gd


## Returns the item definition dictionary for the given item_id.
func _def(item_id: String) -> Dictionary:
	return server.datapacks.get_item(item_id) if server != null and server.datapacks != null else {}

var _ground_items: Dictionary = {}    # Vector3i -> Array of {item_id, count}


func get_backpack_capacity(peer_id: int) -> int:
	## Returns the number of slots in the player's equipped backpack, or 0 if none.
	if not server._sessions.has(peer_id):
		return 0
	var s: Dictionary = server._sessions[peer_id]
	var bp_id: String = str(s["equipment"].get("backpack", ""))
	if bp_id.is_empty():
		return 0
	return server.datapacks.get_container_slots(bp_id)


## Returns true if the player has a container-type backpack equipped.
func has_backpack(peer_id: int) -> bool:
	if not server._sessions.has(peer_id):
		return false
	var bp_id: String = str(server._sessions[peer_id]["equipment"].get("backpack", ""))
	return not bp_id.is_empty() and server.datapacks.is_container(bp_id)


#  INVENTORY MANAGEMENT

## Sends the full inventory contents to the client, including sprite and tooltip data.
func send_inventory(peer_id: int) -> void:
	if not server._sessions.has(peer_id):
		return
	var inv: Array = server._sessions[peer_id]["inventory"]
	var items: Array = []
	for slot in inv:
		var iid: String = str(slot["item_id"])
		var idef: Dictionary = _def(iid)
		var sprite: String = server.datapacks.get_sprite_for_count(iid, int(slot["count"]))
		items.append([iid, int(slot["count"]),
			str(idef.get("display_name", iid)),
			server.datapacks.get_item_color(iid),
			sprite])
	server.rpc_id(peer_id, "rpc_inventory_update", items)
	# Also refresh the backpack container window if open
	server.containers.broadcast_container_update(-peer_id)
	# Update weight display
	send_combat_stats(peer_id)


## Gives items to a player. Tries inventory first; if full or over weight, drops at player's feet.
## Returns the total count given (inventory + ground). Always succeeds -- items are never lost.
func give_item(peer_id: int, item_id: String, count: int) -> int:
	var added := _add_to_inventory(peer_id, item_id, count)
	if added >= count:
		return added
	# Some or all items couldn't fit -- drop the remainder on the ground
	var remainder: int = count - maxi(added, 0)
	if remainder > 0 and server._sessions.has(peer_id):
		var pos: Vector3i = server._sessions[peer_id]["position"]
		_add_ground_item(pos, item_id, remainder)
		var item_name: String = server.datapacks.get_item_name(item_id)
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
			"%d %s dropped at your feet." % [remainder, item_name])
	return count


## Counts the player's total gold across all denominations (gold, platinum, crystal coins).
## 1 platinum = 100 gold, 1 crystal = 10000 gold.
func count_total_gold(peer_id: int) -> int:
	if not server._sessions.has(peer_id):
		return 0
	var inv: Array = server._sessions[peer_id]["inventory"]
	var total := 0
	for slot in inv:
		var iid: String = str(slot["item_id"])
		var cnt: int = int(slot["count"])
		match iid:
			"gold_coin": total += cnt
			"platinum_coin": total += cnt * 100
			"crystal_coin": total += cnt * 10000
	return total


## Removes [param amount] gold value from the player's inventory, breaking higher
## denominations as needed and giving change via give_item (drops at feet if full).
## Returns true if the player had enough gold.
func remove_gold(peer_id: int, amount: int) -> bool:
	if not server._sessions.has(peer_id):
		return false
	if count_total_gold(peer_id) < amount:
		return false
	var inv: Array = server._sessions[peer_id]["inventory"]
	var remaining := amount

	# Remove from gold coins first, then platinum, then crystal
	for denom in [["gold_coin", 1], ["platinum_coin", 100], ["crystal_coin", 10000]]:
		if remaining <= 0:
			break
		var coin_id: String = denom[0]
		var coin_value: int = denom[1]
		for slot in inv:
			if remaining <= 0:
				break
			if str(slot["item_id"]) != coin_id:
				continue
			var have: int = int(slot["count"])
			var coins_needed: int = ceili(float(remaining) / float(coin_value))
			var take: int = mini(coins_needed, have)
			var value_taken: int = take * coin_value
			slot["count"] = have - take
			remaining -= value_taken

	# Clean up empty slots
	var i := inv.size() - 1
	while i >= 0:
		if int(inv[i]["count"]) <= 0:
			inv.remove_at(i)
		i -= 1

	# If we overpaid (broke a larger coin), give change
	if remaining < 0:
		var change: int = -remaining
		# Give change in the largest denominations possible
		if change >= 10000:
			@warning_ignore("integer_division")
			var crystals: int = change / 10000
			give_item(peer_id, "crystal_coin", crystals)
			change -= crystals * 10000
		if change >= 100:
			@warning_ignore("integer_division")
			var platinums: int = change / 100
			give_item(peer_id, "platinum_coin", platinums)
			change -= platinums * 100
		if change > 0:
			give_item(peer_id, "gold_coin", change)

	send_inventory(peer_id)
	send_combat_stats(peer_id)
	return true


## Adds items to a player's backpack. Returns count added, 0 if full, or -1 if over weight.
## NOTE: For giving items that must not be lost, use give_item() instead.
func _add_to_inventory(peer_id: int, item_id: String, count: int) -> int:
	if not server._sessions.has(peer_id):
		return 0
	var capacity := get_backpack_capacity(peer_id)
	if capacity <= 0:
		return 0  # No backpack equipped -- can't carry items
	var s: Dictionary = server._sessions[peer_id]
	var inv: Array = s["inventory"]
	var item_def: Dictionary = _def(item_id)

	# Weight check -- reject if would exceed max capacity
	var item_weight: float = server.datapacks.get_weight(item_id) * count
	var current_weight: float = get_current_weight(peer_id)
	var max_cap: float = get_max_capacity(peer_id)
	if current_weight + item_weight > max_cap:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
			"This object is too heavy for you to carry.")
		return -1  # Weight rejection (message already sent)

	var stackable: bool = bool(item_def.get("stackable", false))
	var added := 0
	if stackable:
		for slot in inv:
			if slot["item_id"] == item_id:
				slot["count"] = int(slot["count"]) + count
				added = count
				send_inventory(peer_id)
				return added
	if stackable:
		if inv.size() < capacity:
			inv.append({"item_id": item_id, "count": count})
			added = count
	else:
		var to_add := mini(count, capacity - inv.size())
		for i in range(to_add):
			var new_item := {"item_id": item_id, "count": 1}
			# Container items get a children array
			if server.datapacks.is_container(item_id):
				new_item["children"] = []
			inv.append(new_item)
		added = to_add
	if added > 0:
		send_inventory(peer_id)
	return added


#  LOOT & GROUND ITEMS

## Rolls loot from a monster definition and drops it on the ground at pos.
func drop_loot(definition_id: String, pos: Vector3i) -> void:
	var loot: Array = server.datapacks.roll_loot(definition_id)
	for entry in loot:
		_add_ground_item(pos, str(entry["item_id"]), int(entry["count"]))


## Places an item on the ground at pos, merging into existing stacks if stackable.
func _add_ground_item(pos: Vector3i, item_id: String, count: int) -> void:
	if not _ground_items.has(pos):
		_ground_items[pos] = []
	var items: Array = _ground_items[pos]
	var item_def: Dictionary = _def(item_id)
	if item_def.get("stackable", false):
		for existing in items:
			if existing["item_id"] == item_id:
				existing["count"] = int(existing["count"]) + count
				_broadcast_ground_item(pos, item_id, int(existing["count"]), true)
				return
	items.append({"item_id": item_id, "count": count})
	_broadcast_ground_item(pos, item_id, count, true)


## Removes up to count of item_id from the ground at pos. Returns the amount actually removed.
func _remove_ground_item(pos: Vector3i, item_id: String, count: int) -> int:
	if not _ground_items.has(pos):
		return 0
	var items: Array = _ground_items[pos]
	# Remove from the end (top of stack) first
	for i in range(items.size() - 1, -1, -1):
		if items[i]["item_id"] == item_id:
			var available: int = int(items[i]["count"])
			var take := mini(count, available)
			items[i]["count"] = available - take
			if int(items[i]["count"]) <= 0:
				items.remove_at(i)
				if items.is_empty():
					_ground_items.erase(pos)
				_broadcast_ground_item(pos, item_id, 0, false)
			else:
				_broadcast_ground_item(pos, item_id, int(items[i]["count"]), true)
			return take
	return 0


## Notifies all nearby players about a ground item change (added or removed).
func _broadcast_ground_item(pos: Vector3i, item_id: String, count: int, present: bool) -> void:
	var sprite: String = server.datapacks.get_sprite_for_count(item_id, count)
	for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
		server.rpc_id(pid, "rpc_ground_item", pos.x, pos.y, pos.z, item_id, count, present, sprite)


#  PICKUP / DROP RPCs

## Handles a player picking up an item from the ground. Auto-equips backpacks if slot is empty.
func handle_pickup_item(peer_id: int, x: int, y: int, z: int, item_id: String) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	if s.get("is_dead", false):
		return
	var pos := Vector3i(x, y, z)
	var pp: Vector3i = s["position"]
	if pp.z != z or absi(pp.x - x) > PICKUP_RANGE or absi(pp.y - y) > PICKUP_RANGE:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Too far away.")
		return
	if not _ground_items.has(pos):
		return
	var items: Array = _ground_items[pos]
	# Search from the end (top of stack) for the requested item
	for i in range(items.size() - 1, -1, -1):
		var slot: Dictionary = items[i]
		if slot["item_id"] == item_id:
			var count: int = int(slot["count"])
			var item_name: String = _def(item_id).get("display_name", item_id)

			# Special case: picking up a backpack when no backpack is equipped -> equip it
			var equip_slot: String = server.datapacks.get_equip_slot(item_id)
			if equip_slot == "backpack" and str(s["equipment"].get("backpack", "")).is_empty():
				# Equip the backpack directly
				s["equipment"]["backpack"] = item_id
				# Transfer children to inventory
				if slot.has("children"):
					s["inventory"] = slot["children"].duplicate(true)
				# Remove ground container if registered
				if slot.has("_ground_cid"):
					var gcid: int = int(slot["_ground_cid"])
					server.containers._remove_container(gcid)
				# Remove from ground items
				items.remove_at(i)
				if items.is_empty():
					_ground_items.erase(pos)
				_broadcast_ground_item(pos, item_id, 0, false)
				send_inventory(peer_id)
				send_equipment(peer_id)
				server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
					"You equipped %s." % item_name)
				return

			# Normal pickup: add to inventory
			var added := _add_to_inventory(peer_id, item_id, count)
			if added > 0:
				# If it's a container item, preserve children in the inventory slot
				if slot.has("children") and not slot["children"].is_empty():
					# Find the slot we just added and give it the children
					var inv: Array = s["inventory"]
					for inv_slot in inv:
						if inv_slot["item_id"] == item_id and not inv_slot.has("children"):
							inv_slot["children"] = slot.get("children", []).duplicate(true)
							break
				# Remove ground container if registered
				if slot.has("_ground_cid"):
					var gcid: int = int(slot["_ground_cid"])
					server.containers._remove_container(gcid)
				# Remove from ground items
				items.remove_at(i)
				if items.is_empty():
					_ground_items.erase(pos)
				_broadcast_ground_item(pos, item_id, 0, false)
				send_inventory(peer_id)
				server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
					"You picked up %d %s." % [added, item_name])
			else:
				if added != -1:  # -1 means weight message already sent
					server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Your backpack is full.")
			return


## Drops an inventory item at the player's current position.
func handle_drop_item(peer_id: int, slot_index: int) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	if s.get("is_dead", false):
		return
	var inv: Array = s["inventory"]
	if slot_index < 0 or slot_index >= inv.size():
		return
	var slot: Dictionary = inv[slot_index]
	var item_id: String = slot["item_id"]
	var count: int = int(slot["count"])
	inv.remove_at(slot_index)
	_add_ground_item(s["position"], item_id, count)
	send_inventory(peer_id)
	var item_name: String = _def(item_id).get("display_name", item_id)
	server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
		"You dropped %d %s." % [count, item_name])


## Drops an inventory item at a specific world position (within throw range).
func handle_drop_item_at(peer_id: int, slot_index: int, x: int, y: int, z: int) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	if s.get("is_dead", false):
		return
	var inv: Array = s["inventory"]
	if slot_index < 0 or slot_index >= inv.size():
		return
	var pp: Vector3i = s["position"]
	if absi(pp.z - z) > 1 or absi(pp.x - x) > 7 or absi(pp.y - y) > 7:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Too far away.")
		return
	var slot: Dictionary = inv[slot_index]
	var item_id: String = slot["item_id"]
	var count: int = int(slot["count"])
	inv.remove_at(slot_index)
	_add_ground_item(Vector3i(x, y, z), item_id, count)
	send_inventory(peer_id)
	var item_name: String = _def(item_id).get("display_name", item_id)
	server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
		"You dropped %d %s." % [count, item_name])


## Moves a ground item from one tile to another within range.
func handle_move_ground_item(peer_id: int, sx: int, sy: int, sz: int, item_id: String, dx: int, dy: int, dz: int, move_count: int = 0) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	if s.get("is_dead", false):
		return
	var src := Vector3i(sx, sy, sz)
	var dest := Vector3i(dx, dy, dz)
	var pp: Vector3i = s["position"]
	if absi(pp.z - sz) > 1 or absi(pp.x - sx) > 7 or absi(pp.y - sy) > 7:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Too far away.")
		return
	if absi(pp.z - dz) > 1 or absi(pp.x - dx) > 7 or absi(pp.y - dy) > 7:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Too far away.")
		return
	if not _ground_items.has(src):
		return
	var items: Array = _ground_items[src]
	for slot in items:
		if slot["item_id"] == item_id:
			var gcount: int = int(slot["count"])
			var to_move: int = gcount if (move_count <= 0 or move_count >= gcount) else move_count
			var removed := _remove_ground_item(src, item_id, to_move)
			if removed > 0:
				_add_ground_item(dest, item_id, removed)
			return


#  EQUIPMENT SYSTEM

## Sends the full equipment state (all slots with sprites, tooltips, counts) to the client.
func send_equipment(peer_id: int) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	var equip: Dictionary = s["equipment"]
	var counts: Dictionary = s.get("equip_counts", {})
	var data: Array = []
	for slot_name in EQUIPMENT_SLOTS:
		var iid: String = str(equip.get(slot_name, ""))
		var idef: Dictionary = _def(iid)
		var iname: String = str(idef.get("display_name", "")) if not iid.is_empty() else ""
		var icolor: String = server.datapacks.get_item_color(iid) if not iid.is_empty() else "#333333"
		# Use count-based sprite for stackable equipment (ammo)
		var slot_count: int = int(counts.get(slot_name, 1)) if not iid.is_empty() else 0
		var isprite: String = ""
		if not iid.is_empty():
			isprite = server.datapacks.get_sprite_for_count(iid, slot_count)
		var itooltip: String = ""
		if not iid.is_empty():
			if slot_name == "backpack" and server.datapacks.is_container(iid):
				var fake_item := {"item_id": iid, "count": 1, "children": s["inventory"]}
				itooltip = server.datapacks.build_item_tooltip(iid, fake_item)
			else:
				itooltip = server.datapacks.build_item_tooltip(iid)
			if slot_count > 1:
				itooltip += "\nCount: %d" % slot_count
		data.append([slot_name, iid, iname, icolor, itooltip, isprite, slot_count])
	server.rpc_id(peer_id, "rpc_equipment_update", data)
	send_combat_stats(peer_id)


## Returns the total attack bonus from the player's equipped weapon.
func get_attack_bonus(peer_id: int) -> int:
	if not server._sessions.has(peer_id):
		return 0
	var equip: Dictionary = server._sessions[peer_id]["equipment"]
	var weapon_id: String = equip.get("weapon", "")
	if weapon_id.is_empty():
		return 0
	var mods: Dictionary = server.datapacks.get_stat_modifiers(weapon_id)
	return int(mods.get("attack", 0))


## Returns the total armor bonus from all equipped items.
func get_armor_bonus(peer_id: int) -> int:
	if not server._sessions.has(peer_id):
		return 0
	var equip: Dictionary = server._sessions[peer_id]["equipment"]
	var total := 0
	for slot_name in EQUIPMENT_SLOTS:
		var item_id: String = equip.get(slot_name, "")
		if not item_id.is_empty():
			var mods: Dictionary = server.datapacks.get_stat_modifiers(item_id)
			total += int(mods.get("armor", 0))
	return total


func handle_use_item(peer_id: int, slot_index: int) -> void:
	## Right-click use item from inventory -- handles food, potions, etc.
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	if s.get("is_dead", false):
		return
	var inv: Array = s["inventory"]
	if slot_index < 0 or slot_index >= inv.size():
		return
	var slot: Dictionary = inv[slot_index]
	var item_id: String = str(slot["item_id"])
	var item_def: Dictionary = _def(item_id)
	# Check if it's food
	var food_time: int = int(item_def.get("food_time", 0))
	if food_time > 0:
		var current_timer: float = float(s.get("food_timer", 0.0))
		if current_timer + float(food_time) > server.spells.FOOD_TIMER_MAX:
			server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "You are full.")
			return
		s["food_timer"] = current_timer + float(food_time)
		# Consume 1 food item
		var count: int = int(slot["count"])
		if count <= 1:
			inv.remove_at(slot_index)
		else:
			slot["count"] = count - 1
		var eat_msg: String = str(item_def.get("eat_message", "Munch."))
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", eat_msg)
		send_inventory(peer_id)
		server.spells.send_stats(peer_id)
		return
	server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "You cannot use this item.")


## Equips an item from inventory, swapping with any currently equipped item in that slot.
func handle_equip_item(peer_id: int, slot_index: int) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	var inv: Array = s["inventory"]
	if slot_index < 0 or slot_index >= inv.size():
		return
	var slot: Dictionary = inv[slot_index]
	var item_id: String = slot["item_id"]
	var item_def: Dictionary = _def(item_id)
	var equip_slot: String = server.datapacks.get_equip_slot(item_id)
	if equip_slot.is_empty():
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "This item cannot be equipped.")
		return
	var equip: Dictionary = s["equipment"]
	var current_id: String = equip.get(equip_slot, "")

	# Two-handed weapon check
	var is_two_handed: bool = bool(item_def.get("two_handed", false))
	if is_two_handed and equip_slot == "weapon":
		# Equipping a two-handed weapon -- must unequip shield first
		var shield_id: String = equip.get("shield", "")
		if not shield_id.is_empty():
			var capacity := get_backpack_capacity(peer_id)
			if capacity <= 0 or inv.size() >= capacity - (1 if current_id.is_empty() else 0):
				server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Backpack full -- unequip shield first.")
				return
			inv.append({"item_id": shield_id, "count": 1})
			equip["shield"] = ""
	elif equip_slot == "shield":
		# Equipping a shield -- check if current weapon is two-handed
		var weapon_id: String = equip.get("weapon", "")
		if not weapon_id.is_empty():
			var weapon_def: Dictionary = _def(weapon_id)
			if bool(weapon_def.get("two_handed", false)):
				server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "You cannot use a shield with a two-handed weapon.")
				return

	if not current_id.is_empty():
		var capacity := get_backpack_capacity(peer_id)
		if capacity <= 0 or inv.size() >= capacity:
			server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Backpack full -- unequip first.")
			return
		# Return current equipped item to inventory (with count for stackables)
		var return_count: int = 1
		var counts: Dictionary = s.get("equip_counts", {})
		if counts.has(equip_slot) and int(counts[equip_slot]) > 0:
			return_count = int(counts[equip_slot])
		inv.append({"item_id": current_id, "count": return_count})
		counts[equip_slot] = 0
	# Track count for stackable equipment (ammo)
	var item_count: int = int(slot["count"]) if slot.has("count") else 1
	var counts: Dictionary = s.get("equip_counts", {})
	if not s.has("equip_counts"):
		s["equip_counts"] = counts
	counts[equip_slot] = item_count
	inv.remove_at(slot_index)
	equip[equip_slot] = item_id
	send_inventory(peer_id)
	send_equipment(peer_id)
	var item_name: String = item_def.get("display_name", item_id)
	server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "You equipped %s." % item_name)


## Unequips an item from the given equipment slot back into the backpack.
func handle_unequip_item(peer_id: int, slot_name: String) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	var equip: Dictionary = s["equipment"]
	slot_name = slot_name.strip_edges()
	if not equip.has(slot_name):
		return
	var item_id: String = equip.get(slot_name, "")
	if item_id.is_empty():
		return
	var inv: Array = s["inventory"]
	var capacity := get_backpack_capacity(peer_id)
	if capacity <= 0 or inv.size() >= capacity:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Backpack full.")
		return
	# Use equip_counts for stackable equipment (ammo)
	var counts: Dictionary = s.get("equip_counts", {})
	var unequip_count: int = int(counts.get(slot_name, 1))
	if unequip_count < 1:
		unequip_count = 1
	inv.append({"item_id": item_id, "count": unequip_count})
	equip[slot_name] = ""
	counts[slot_name] = 0
	send_inventory(peer_id)
	send_equipment(peer_id)
	var item_name: String = _def(item_id).get("display_name", item_id)
	server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "You unequipped %s." % item_name)


## Handles inventory slot reordering via drag-and-drop (swaps two slots).
func handle_drag_drop(peer_id: int, source_type: String, source_index: int,
		dest_type: String, dest_index: int) -> void:
	if not server._sessions.has(peer_id):
		return
	var inv: Array = server._sessions[peer_id]["inventory"]
	if source_type == "inventory" and dest_type == "inventory":
		if source_index < 0 or source_index >= inv.size():
			return
		if dest_index < 0 or dest_index >= inv.size():
			return
		if source_index == dest_index:
			return
		var temp: Dictionary = inv[source_index]
		inv[source_index] = inv[dest_index]
		inv[dest_index] = temp
		send_inventory(peer_id)


## Returns the total defense bonus from all equipped items.
func get_defense_bonus(peer_id: int) -> int:
	if not server._sessions.has(peer_id):
		return 0
	var equip: Dictionary = server._sessions[peer_id]["equipment"]
	var total := 0
	for slot_name in EQUIPMENT_SLOTS:
		var item_id: String = equip.get(slot_name, "")
		if not item_id.is_empty():
			var mods: Dictionary = server.datapacks.get_stat_modifiers(item_id)
			total += int(mods.get("defense", 0))
	return total


## Sends attack, defense, armor, weight, capacity, and speed stats to the client.
func send_combat_stats(peer_id: int) -> void:
	var atk := get_attack_bonus(peer_id)
	var def := get_defense_bonus(peer_id)
	var arm := get_armor_bonus(peer_id)
	var cur_weight := get_current_weight(peer_id)
	var max_cap := get_max_capacity(peer_id)
	var speed: int = 0
	var ground_speed: float = server.DEFAULT_GROUND_SPEED
	if server._sessions.has(peer_id):
		var s: Dictionary = server._sessions[peer_id]
		speed = int(s.get("speed", server.DEFAULT_PLAYER_SPEED))
		ground_speed = server.map.get_ground_speed(s["position"])
	server.rpc_id(peer_id, "rpc_combat_stats", atk, def, arm, cur_weight, max_cap, speed, ground_speed)


## Calculates the player's total carried weight (equipment + inventory, recursive).
func get_current_weight(peer_id: int) -> float:
	if not server._sessions.has(peer_id):
		return 0.0
	var s: Dictionary = server._sessions[peer_id]
	var total := 0.0
	# Equipment weight
	var equip: Dictionary = s["equipment"]
	for slot_name in EQUIPMENT_SLOTS:
		var item_id: String = equip.get(slot_name, "")
		if not item_id.is_empty():
			total += server.datapacks.get_weight(item_id)
	# Inventory weight (recursive -- includes nested container contents)
	for slot in s["inventory"]:
		total += _get_item_weight_recursive(slot)
	return total


## Returns the weight of an item including all nested children (for containers).
func _get_item_weight_recursive(item: Dictionary) -> float:
	var item_id: String = str(item["item_id"])
	var count: int = int(item["count"])
	var weight: float = server.datapacks.get_weight(item_id) * count
	# Add children weight if this is a container
	if item.has("children"):
		for child in item["children"]:
			weight += _get_item_weight_recursive(child)
	return weight


## Returns the player's maximum carry weight based on level.
func get_max_capacity(peer_id: int) -> float:
	if not server._sessions.has(peer_id):
		return 0.0
	var level: int = int(server._sessions[peer_id].get("level", 1))
	return 300.0 + float(level) * 10.0
