#  server_containers.gd -- Container system (corpses, bags, nested containers)
#
#  Clean rewrite: server is single source of truth.
#  _viewer_registry tracks cid -> Array[peer_id] for who has what open.
#  Handles open/close, item transfers, decay, and unified move_item logic.
extends Node

const CORPSE_DECAY_TIME := 60.0  # seconds before corpse disappears
const CONTAINER_RANGE := 1       # must be adjacent to interact with ground containers

var server: Node = null

var _containers: Dictionary = {}       # int container_id -> container Dictionary (ground corpses/bags)
var _next_container_id: int = 1

# Viewer registry: cid -> Array[peer_id] -- who has each container open
var _viewer_registry: Dictionary = {}

# Nested container items: cid -> {items_ref: Array, capacity: int, display_name: String}
var _nested_items: Dictionary = {}
var _next_nested_cid: int = 100000


#  HELPERS

## Builds an array of item display data (id, count, name, color, tooltip, sprite) for RPC.
func _build_items_data(items_array: Array) -> Array:
	var result: Array = []
	for item in items_array:
		var iid: String = str(item["item_id"])
		var count: int = int(item["count"])
		var item_name: String = server.datapacks.get_item_name(iid)
		var color: String = server.datapacks.get_item_color(iid)
		var tooltip: String = server.datapacks.build_item_tooltip(iid, item)
		var sprite: String = server.datapacks.get_sprite_for_count(iid, count)
		result.append([iid, count, item_name, color, server.datapacks.is_container(iid), tooltip, sprite])
	return result


## Sends an rpc_container_open to a single peer with the container's contents.
func _send_open(peer_id: int, cid: int, display_name: String, items_array: Array, capacity: int, sprite_path: String = "") -> void:
	var items_data: Array = _build_items_data(items_array)
	server.rpc_id(peer_id, "rpc_container_open", cid, display_name, items_data, capacity, sprite_path)


func broadcast_container_update(cid: int) -> void:
	## Re-sends contents to all viewers of a container.
	if not _viewer_registry.has(cid):
		return
	var viewers: Array = _viewer_registry[cid]
	if viewers.is_empty():
		return
	# Resolve items, name, capacity, sprite
	var items_array: Array = []
	var display_name: String = ""
	var capacity: int = 0
	var sprite_path: String = ""
	if _nested_items.has(cid):
		var ni: Dictionary = _nested_items[cid]
		items_array = ni["items_ref"]
		display_name = ni["display_name"]
		capacity = ni["capacity"]
		sprite_path = server.datapacks.get_sprite_path(str(ni.get("item_id", "")))
	elif _containers.has(cid):
		var c: Dictionary = _containers[cid]
		items_array = c["items"]
		display_name = str(c["display_name"])
		capacity = int(c.get("capacity", items_array.size()))
		sprite_path = server.datapacks.get_sprite_path(str(c.get("item_id", "")))
	else:
		# Backpack: cid is negative peer_id
		for pid in viewers:
			if cid == -pid and server._sessions.has(pid):
				var s: Dictionary = server._sessions[pid]
				var equip: Dictionary = s["equipment"]
				var bp_item_id: String = str(equip.get("backpack", ""))
				if bp_item_id.is_empty():
					continue
				items_array = s["inventory"]
				display_name = server.datapacks.get_item_name(bp_item_id)
				capacity = server.datapacks.get_container_slots(bp_item_id)
				var bp_sprite: String = server.datapacks.get_sprite_path(bp_item_id)
				_send_open(pid, cid, display_name, items_array, capacity, bp_sprite)
			return
	var items_data: Array = _build_items_data(items_array)
	for pid in viewers:
		server.rpc_id(pid, "rpc_container_open", cid, display_name, items_data, capacity, sprite_path)


func _add_ground_item_full(pos: Vector3i, item: Dictionary) -> void:
	## Adds a full item dict to the ground. For container items, also registers as openable container.
	var item_id: String = str(item["item_id"])
	var count: int = int(item["count"])

	# Add to ground items array
	if not server.inventory._ground_items.has(pos):
		server.inventory._ground_items[pos] = []
	var items: Array = server.inventory._ground_items[pos]

	# Stackable non-container items merge
	if server.datapacks.is_stackable(item_id) and not server.datapacks.is_container(item_id):
		for existing in items:
			if existing["item_id"] == item_id:
				existing["count"] = int(existing["count"]) + count
				server.inventory._broadcast_ground_item(pos, item_id, int(existing["count"]), true)
				return
	items.append(item)

	# If it's a container, register it and ONLY show container marker (no ground item dot)
	if server.datapacks.is_container(item_id):
		var gcid := _next_container_id
		_next_container_id += 1
		if not item.has("children"):
			item["children"] = []
		item["_ground_cid"] = gcid
		var display_name: String = server.datapacks.get_item_name(item_id)
		_containers[gcid] = {
			"id": gcid,
			"type": "ground_container",
			"definition_id": item_id,
			"display_name": display_name,
			"position": pos,
			"items": item["children"],
			"capacity": server.datapacks.get_container_slots(item_id),
			"decay_timer": 600.0,
			"created_at": Time.get_ticks_msec(),
			"_ground_item_ref": item,
		}
		for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
			var container_sprite: String = server.datapacks.get_sprite_path(item_id)
			server.rpc_id(pid, "rpc_container_spawn", gcid, pos.x, pos.y, pos.z, display_name, container_sprite)
	else:
		server.inventory._broadcast_ground_item(pos, item_id, count, true)


## Registers a peer as a viewer of a container (no-op if already viewing).
func _add_viewer(cid: int, peer_id: int) -> void:
	if not _viewer_registry.has(cid):
		_viewer_registry[cid] = []
	if peer_id not in _viewer_registry[cid]:
		_viewer_registry[cid].append(peer_id)


## Removes a peer from a container's viewer list. Cleans up nested tracking if empty.
func _remove_viewer(cid: int, peer_id: int) -> void:
	if _viewer_registry.has(cid):
		_viewer_registry[cid].erase(peer_id)
		if _viewer_registry[cid].is_empty():
			_viewer_registry.erase(cid)
			# Clean up nested item tracking if no viewers left
			_nested_items.erase(cid)


## Returns true if the peer is currently viewing the given container.
func _is_viewer(cid: int, peer_id: int) -> bool:
	return _viewer_registry.has(cid) and peer_id in _viewer_registry[cid]


#  CORPSE CREATION

## Creates a corpse container at pos with the given loot. Returns the container id.
func create_corpse(definition_id: String, display_name: String, pos: Vector3i, loot: Array) -> int:
	var cid := _next_container_id
	_next_container_id += 1
	# Get corpse decay sprites from monster definition
	var corpse_sprites: Array = []
	var monster_def: Dictionary = server.datapacks.get_monster(definition_id)
	if not monster_def.is_empty():
		corpse_sprites = monster_def.get("corpse_sprites", [])
		if corpse_sprites.is_empty():
			var single: String = str(monster_def.get("corpse_sprite", ""))
			if not single.is_empty():
				corpse_sprites = [single]
	_containers[cid] = {
		"id": cid,
		"type": "corpse",
		"definition_id": definition_id,
		"display_name": display_name + "'s corpse",
		"position": pos,
		"items": loot,
		"capacity": maxi(loot.size(), 10),
		"decay_timer": CORPSE_DECAY_TIME,
		"created_at": Time.get_ticks_msec(),
		"corpse_sprites": corpse_sprites,
		"decay_stage": 0,
	}
	var initial_sprite: String = corpse_sprites[0] if not corpse_sprites.is_empty() else ""
	for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
		server.rpc_id(pid, "rpc_container_spawn", cid, pos.x, pos.y, pos.z, display_name + "'s corpse", initial_sprite, true)
	return cid


#  OPEN / CLOSE -- Toggle logic

## Toggles a ground container open/closed for a player (range-checked).
func handle_open_container(peer_id: int, container_id: int) -> void:
	if not _containers.has(container_id):
		return
	if not server._sessions.has(peer_id):
		return
	var container: Dictionary = _containers[container_id]
	var pos: Vector3i = container["position"]
	var pp: Vector3i = server._sessions[peer_id]["position"]
	if pp.z != pos.z or absi(pp.x - pos.x) > CONTAINER_RANGE or absi(pp.y - pos.y) > CONTAINER_RANGE:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Too far away.")
		return

	# Toggle: if peer is already viewing, close it
	if _is_viewer(container_id, peer_id):
		_remove_viewer(container_id, peer_id)
		server.rpc_id(peer_id, "rpc_container_close", container_id)
		return

	# Open: add viewer and send contents
	_add_viewer(container_id, peer_id)
	var container_sprite: String = server.datapacks.get_sprite_path(str(container.get("item_id", "")))
	_send_open(peer_id, container_id, str(container["display_name"]),
		container["items"], int(container.get("capacity", container["items"].size())), container_sprite)


## Toggles the player's equipped backpack open/closed as a container window.
func handle_open_backpack(peer_id: int) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	var equip: Dictionary = s["equipment"]
	var bp_item_id: String = str(equip.get("backpack", ""))
	if bp_item_id.is_empty():
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "You don't have a backpack equipped.")
		return
	if not server.datapacks.is_container(bp_item_id):
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "That item is not a container.")
		return

	var cid := -peer_id

	# Toggle: if already viewing, close
	if _is_viewer(cid, peer_id):
		_remove_viewer(cid, peer_id)
		server.rpc_id(peer_id, "rpc_container_close", cid)
		return

	# Open
	_add_viewer(cid, peer_id)
	var capacity: int = server.datapacks.get_container_slots(bp_item_id)
	var bp_name: String = server.datapacks.get_item_name(bp_item_id)
	var bp_sprite: String = server.datapacks.get_sprite_path(bp_item_id)
	_send_open(peer_id, cid, bp_name, s["inventory"], capacity, bp_sprite)


## Opens a container item nested inside another container (e.g. bag inside a corpse).
func handle_open_nested_container(peer_id: int, parent_cid: int, slot_index: int) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]

	# Resolve the parent container's item list
	var parent_items: Array = []
	if parent_cid == -peer_id:
		parent_items = s["inventory"]
	elif _nested_items.has(parent_cid):
		parent_items = _nested_items[parent_cid]["items_ref"]
	elif _containers.has(parent_cid):
		parent_items = _containers[parent_cid]["items"]
	else:
		return

	if slot_index < 0 or slot_index >= parent_items.size():
		return

	var item: Dictionary = parent_items[slot_index]
	var item_id: String = str(item["item_id"])

	if not server.datapacks.is_container(item_id):
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "That is not a container.")
		return

	if not item.has("children"):
		item["children"] = []

	# Assign _cid if not already assigned
	if not item.has("_cid"):
		item["_cid"] = _next_nested_cid
		_next_nested_cid += 1

	var cid: int = int(item["_cid"])

	# Register in _nested_items if not already
	if not _nested_items.has(cid):
		_nested_items[cid] = {
			"items_ref": item["children"],
			"capacity": server.datapacks.get_container_slots(item_id),
			"display_name": server.datapacks.get_item_name(item_id),
			"item_id": item_id,
		}

	# Toggle: if peer is already viewing, close
	if _is_viewer(cid, peer_id):
		_remove_viewer(cid, peer_id)
		server.rpc_id(peer_id, "rpc_container_close", cid)
		return

	# Open
	_add_viewer(cid, peer_id)
	var ni: Dictionary = _nested_items[cid]
	var nested_sprite: String = server.datapacks.get_sprite_path(item_id)
	_send_open(peer_id, cid, ni["display_name"], ni["items_ref"], ni["capacity"], nested_sprite)


## Closes a container for a peer and removes them from the viewer list.
func handle_close_container(peer_id: int, container_id: int) -> void:
	_remove_viewer(container_id, peer_id)
	server.rpc_id(peer_id, "rpc_container_close", container_id)


#  LEGACY ITEM OPERATIONS (kept for compatibility)

## Takes an item from a ground container into the player's backpack (legacy path).
func handle_take_item(peer_id: int, container_id: int, item_index: int) -> void:
	if not _containers.has(container_id):
		return
	if not server._sessions.has(peer_id):
		return
	var container: Dictionary = _containers[container_id]
	var items: Array = container["items"]
	if item_index < 0 or item_index >= items.size():
		return
	var pos: Vector3i = container["position"]
	var pp: Vector3i = server._sessions[peer_id]["position"]
	if pp.z != pos.z or absi(pp.x - pos.x) > CONTAINER_RANGE or absi(pp.y - pos.y) > CONTAINER_RANGE:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Too far away.")
		return
	var item: Dictionary = items[item_index]
	var item_id: String = str(item["item_id"])
	var count: int = int(item["count"])
	var added: int = server.inventory._add_to_inventory(peer_id, item_id, count)
	if added <= 0:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Your backpack is full.")
		return
	if added >= count:
		items.remove_at(item_index)
	else:
		item["count"] = count - added
	var item_name: String = server.datapacks.get_item_name(item_id)
	server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "You took %d %s." % [added, item_name])
	broadcast_container_update(container_id)


## Puts an item from the player's inventory into a ground container (legacy path).
func handle_put_item(peer_id: int, container_id: int, inv_slot_index: int) -> void:
	if not _containers.has(container_id):
		return
	if not server._sessions.has(peer_id):
		return
	var container: Dictionary = _containers[container_id]
	var pos: Vector3i = container["position"]
	var pp: Vector3i = server._sessions[peer_id]["position"]
	if pp.z != pos.z or absi(pp.x - pos.x) > CONTAINER_RANGE or absi(pp.y - pos.y) > CONTAINER_RANGE:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Too far away.")
		return
	var s: Dictionary = server._sessions[peer_id]
	var inv: Array = s["inventory"]
	if inv_slot_index < 0 or inv_slot_index >= inv.size():
		return
	var slot: Dictionary = inv[inv_slot_index]
	var item_id: String = str(slot["item_id"])
	var count: int = int(slot["count"])
	inv.remove_at(inv_slot_index)
	container["items"].append({"item_id": item_id, "count": count})
	var item_name: String = server.datapacks.get_item_name(item_id)
	server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
		"You put %d %s in the container." % [count, item_name])
	server.inventory.send_inventory(peer_id)
	broadcast_container_update(container_id)


## Moves a ground item into a container (legacy path).
func handle_ground_to_container(peer_id: int, container_id: int, x: int, y: int, z: int, item_id: String) -> void:
	if not _containers.has(container_id):
		return
	if not server._sessions.has(peer_id):
		return
	var container: Dictionary = _containers[container_id]
	var cp: Vector3i = container["position"]
	var pp: Vector3i = server._sessions[peer_id]["position"]
	if pp.z != cp.z or absi(pp.x - cp.x) > CONTAINER_RANGE or absi(pp.y - cp.y) > CONTAINER_RANGE:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Too far away from container.")
		return
	if pp.z != z or absi(pp.x - x) > 1 or absi(pp.y - y) > 1:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Too far away from item.")
		return
	var gpos := Vector3i(x, y, z)
	var removed: int = server.inventory._remove_ground_item(gpos, item_id, 9999)
	if removed <= 0:
		return
	container["items"].append({"item_id": item_id, "count": removed})
	var item_name: String = server.datapacks.get_item_name(item_id)
	server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
		"You put %d %s in the container." % [removed, item_name])
	broadcast_container_update(container_id)


## Drops an item from a container onto the ground at a target position.
func handle_drop_to_ground(peer_id: int, container_id: int, item_index: int, x: int, y: int, z: int) -> void:
	if not _containers.has(container_id):
		return
	if not server._sessions.has(peer_id):
		return
	var container: Dictionary = _containers[container_id]
	var items: Array = container["items"]
	if item_index < 0 or item_index >= items.size():
		return
	var pos: Vector3i = container["position"]
	var pp: Vector3i = server._sessions[peer_id]["position"]
	if pp.z != pos.z or absi(pp.x - pos.x) > CONTAINER_RANGE or absi(pp.y - pos.y) > CONTAINER_RANGE:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Too far away.")
		return
	if pp.z != z or absi(pp.x - x) > 7 or absi(pp.y - y) > 7:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Too far away.")
		return
	var item: Dictionary = items[item_index]
	var item_id: String = str(item["item_id"])
	var count: int = int(item["count"])
	items.remove_at(item_index)
	server.inventory._add_ground_item(Vector3i(x, y, z), item_id, count)
	var item_name: String = server.datapacks.get_item_name(item_id)
	server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
		"You dropped %d %s." % [count, item_name])
	broadcast_container_update(container_id)


#  CONTAINER MOVE

## Moves a ground container to a new position, broadcasting to nearby players.
func handle_move_container(peer_id: int, container_id: int, x: int, y: int, z: int) -> void:
	if not _containers.has(container_id):
		return
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	var pp: Vector3i = s["position"]
	var container: Dictionary = _containers[container_id]
	var old_pos: Vector3i = container["position"]
	if pp.z != old_pos.z or absi(pp.x - old_pos.x) > CONTAINER_RANGE or absi(pp.y - old_pos.y) > CONTAINER_RANGE:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Too far away.")
		return
	var dest := Vector3i(x, y, z)
	if pp.z != z or absi(pp.x - x) > 7 or absi(pp.y - y) > 7:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Too far away.")
		return
	container["position"] = dest
	for pid in server.get_players_in_range(old_pos, server.NEARBY_RANGE):
		server.rpc_id(pid, "rpc_container_move", container_id, x, y, z)
	for pid in server.get_players_in_range(dest, server.NEARBY_RANGE):
		if not pid in server.get_players_in_range(old_pos, server.NEARBY_RANGE):
			var move_sprite: String = server.datapacks.get_sprite_path(str(container.get("definition_id", "")))
			var move_is_corpse: bool = (container.get("type", "") == "corpse")
			server.rpc_id(pid, "rpc_container_spawn", container_id, x, y, z,
				str(container["display_name"]), move_sprite, move_is_corpse)


## Removes a disconnected peer from all container viewer lists.
func on_peer_disconnect(peer_id: int) -> void:
	# Remove this peer from all viewer lists
	for cid in _viewer_registry.keys():
		_viewer_registry[cid].erase(peer_id)
		if _viewer_registry[cid].is_empty():
			_viewer_registry.erase(cid)
			_nested_items.erase(cid)


#  DECAY & CLEANUP

## Ticks decay timers for all containers. Removes expired ones and updates corpse sprites.
func process_decay(delta: float) -> void:
	var to_remove: Array = []
	for cid in _containers:
		var c: Dictionary = _containers[cid]
		c["decay_timer"] = float(c["decay_timer"]) - delta
		if float(c["decay_timer"]) <= 0.0:
			to_remove.append(cid)
			continue
		# Check corpse decay stage transitions
		if c.get("type", "") != "corpse":
			continue
		var sprites: Array = c.get("corpse_sprites", [])
		if sprites.size() <= 1:
			continue
		var total_time: float = CORPSE_DECAY_TIME
		var remaining: float = float(c["decay_timer"])
		var elapsed_pct: float = 1.0 - (remaining / total_time)
		# Divide decay time evenly among stages
		var stage_count: int = sprites.size()
		var new_stage: int = mini(int(elapsed_pct * float(stage_count)), stage_count - 1)
		var old_stage: int = int(c.get("decay_stage", 0))
		if new_stage != old_stage:
			c["decay_stage"] = new_stage
			var new_sprite: String = str(sprites[new_stage])
			var pos: Vector3i = c["position"]
			for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
				server.rpc_id(pid, "rpc_container_sprite", cid, new_sprite)
	for cid in to_remove:
		_remove_container(cid)


## Removes a container: closes it for all viewers and broadcasts despawn.
func _remove_container(container_id: int) -> void:
	if not _containers.has(container_id):
		return
	var c: Dictionary = _containers[container_id]
	var pos: Vector3i = c["position"]
	# Close for all viewers
	if _viewer_registry.has(container_id):
		for pid in _viewer_registry[container_id]:
			if server.is_peer_active(pid):
				server.rpc_id(pid, "rpc_container_close", container_id)
		_viewer_registry.erase(container_id)
	# Broadcast despawn
	for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
		server.rpc_id(pid, "rpc_container_despawn", container_id)
	_containers.erase(container_id)


## Returns the highest container_id at a position, or -1 if none.
func get_container_at(pos: Vector3i) -> int:
	var best_cid: int = -1
	for cid in _containers:
		if _containers[cid]["position"] == pos:
			if cid > best_cid:
				best_cid = cid
	return best_cid


#  NETWORK HELPERS

## Sends rpc_container_spawn for all containers near a player's position.
func send_nearby_containers(peer_id: int, pos: Vector3i) -> void:
	for cid in _containers:
		var c: Dictionary = _containers[cid]
		var cp: Vector3i = c["position"]
		if cp.z == pos.z and absi(cp.x - pos.x) <= server.NEARBY_RANGE and absi(cp.y - pos.y) <= server.NEARBY_RANGE:
			var nearby_sprite: String = server.datapacks.get_sprite_path(str(c.get("definition_id", "")))
			if nearby_sprite.is_empty() and c.get("type", "") == "corpse":
				var mdef: Dictionary = server.datapacks.get_monster(str(c.get("definition_id", "")))
				nearby_sprite = str(mdef.get("corpse_sprite", ""))
			var is_corpse: bool = (c.get("type", "") == "corpse")
			server.rpc_id(peer_id, "rpc_container_spawn", cid, cp.x, cp.y, cp.z,
				str(c["display_name"]), nearby_sprite, is_corpse)


func check_open_container_proximity() -> void:
	## Closes ground containers for players who moved too far away.
	## Backpacks and nested containers don't need proximity checks.
	for cid in _viewer_registry.keys():
		if not _containers.has(cid):
			continue  # Skip backpacks and nested containers
		var cp: Vector3i = _containers[cid]["position"]
		var to_remove: Array = []
		for pid in _viewer_registry[cid]:
			if not server._sessions.has(pid):
				to_remove.append(pid)
				continue
			var pp: Vector3i = server._sessions[pid]["position"]
			if pp.z != cp.z or absi(pp.x - cp.x) > CONTAINER_RANGE or absi(pp.y - cp.y) > CONTAINER_RANGE:
				to_remove.append(pid)
		for pid in to_remove:
			_viewer_registry[cid].erase(pid)
			if server.is_peer_active(pid):
				server.rpc_id(pid, "rpc_container_close", cid)
		if _viewer_registry[cid].is_empty():
			_viewer_registry.erase(cid)


#  UNIFIED MOVE ITEM
#  Handles all item transfers between containers, backpack, equipment, ground.
#
#  Container UIDs:
#    -(peer_id) = player's equipped backpack
#    positive   = ground container (corpse, bag) or nested container (>=100000)
#    0          = ground tile (uses x,y,z)
#    -1         = equipment slot (uses slot_name)

## Returns true if the container_id refers to a nested (in-item) container.
func _is_nested_container(uid: int) -> bool:
	return _nested_items.has(uid)


## Unified item transfer between any two containers, backpack, equipment, or ground.
func handle_move_item(peer_id: int, from_uid: int, from_index: int,
		to_uid: int, to_index: int, to_x: int, to_y: int, to_z: int,
		count: int, slot_name: String) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	if s.get("is_dead", false):
		return

	# Resolve source item
	var src_item: Dictionary = {}
	var src_list: Array = []
	var src_idx: int = from_index

	if from_uid == -peer_id:
		# From player backpack
		src_list = s["inventory"]
		if src_idx < 0 or src_idx >= src_list.size():
			return
		src_item = src_list[src_idx]
	elif from_uid == -1:
		# From equipment slot
		var equip: Dictionary = s["equipment"]
		if not equip.has(slot_name) or equip.get(slot_name, "") == "":
			return
		var eq_counts: Dictionary = s.get("equip_counts", {})
		var eq_count: int = int(eq_counts.get(slot_name, 1))
		if eq_count < 1: eq_count = 1
		src_item = {"item_id": equip[slot_name], "count": eq_count}
		# Special: if dropping the backpack, include inventory as children
		if slot_name == "backpack" and server.datapacks.is_container(str(equip[slot_name])):
			src_item["children"] = s["inventory"].duplicate(true)
	elif from_uid > 0:
		# From ground container or nested container
		if _is_nested_container(from_uid):
			var ni: Dictionary = _nested_items[from_uid]
			src_list = ni["items_ref"]
			if src_idx < 0 or src_idx >= src_list.size():
				return
			src_item = src_list[src_idx]
		elif _containers.has(from_uid):
			var container: Dictionary = _containers[from_uid]
			src_list = container["items"]
			if src_idx < 0 or src_idx >= src_list.size():
				return
			var cp: Vector3i = container["position"]
			var pp: Vector3i = s["position"]
			if pp.z != cp.z or absi(pp.x - cp.x) > CONTAINER_RANGE or absi(pp.y - cp.y) > CONTAINER_RANGE:
				server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Too far away.")
				return
			src_item = src_list[src_idx]
		else:
			return
	elif from_uid == 0:
		# From ground tile
		var ground_item_id: String = slot_name
		var gpos := Vector3i(to_x, to_y, to_z)
		var pp: Vector3i = s["position"]
		if pp.z != gpos.z or absi(pp.x - gpos.x) > 1 or absi(pp.y - gpos.y) > 1:
			server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Too far away.")
			return
		if not server.inventory._ground_items.has(gpos):
			return
		var ground_items: Array = server.inventory._ground_items[gpos]
		for gi in ground_items:
			if str(gi["item_id"]) == ground_item_id:
				src_item = gi
				break
		if src_item.is_empty():
			return
		var g_item_id: String = str(src_item["item_id"])
		var g_count: int = int(src_item["count"])
		var g_move: int = mini(count, g_count) if count > 0 else g_count
		var g_name: String = server.datapacks.get_item_name(g_item_id)
		if to_uid == -peer_id:
			var added: int = server.inventory._add_to_inventory(peer_id, g_item_id, g_move)
			if added > 0:
				server.inventory._remove_ground_item(gpos, g_item_id, added)
				server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "You picked up %d %s." % [added, g_name])
			elif added != -1:
				server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Backpack full.")
		elif to_uid > 0:
			if _is_nested_container(to_uid):
				var ni: Dictionary = _nested_items[to_uid]
				if ni["items_ref"].size() >= ni["capacity"]:
					server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Container is full.")
					return
				var removed: int = server.inventory._remove_ground_item(gpos, g_item_id, g_move)
				if removed > 0:
					ni["items_ref"].append({"item_id": g_item_id, "count": removed})
					broadcast_container_update(to_uid)
					server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "You put %d %s in the container." % [removed, g_name])
			elif _containers.has(to_uid):
				var dest_c: Dictionary = _containers[to_uid]
				var dcp: Vector3i = dest_c["position"]
				if pp.z != dcp.z or absi(pp.x - dcp.x) > CONTAINER_RANGE or absi(pp.y - dcp.y) > CONTAINER_RANGE:
					server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Too far away.")
					return
				var removed: int = server.inventory._remove_ground_item(gpos, g_item_id, g_move)
				if removed > 0:
					dest_c["items"].append({"item_id": g_item_id, "count": removed})
					broadcast_container_update(to_uid)
					server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "You put %d %s in the container." % [removed, g_name])
		return
	else:
		return

	var item_id: String = str(src_item["item_id"])
	var item_count: int = int(src_item["count"])
	var move_count: int = mini(count, item_count) if count > 0 else item_count
	var item_name: String = server.datapacks.get_item_name(item_id)

	# === DESTINATION ===

	# Check if dropping onto a specific slot that is a container -> put item INTO that container
	if to_index >= 0 and (to_uid == -peer_id or to_uid > 0):
		var target_items: Array = []
		if to_uid == -peer_id:
			target_items = s["inventory"]
		elif _is_nested_container(to_uid):
			target_items = _nested_items[to_uid]["items_ref"]
		elif _containers.has(to_uid):
			target_items = _containers[to_uid]["items"]
		if to_index < target_items.size():
			var target_slot: Dictionary = target_items[to_index]
			var target_id: String = str(target_slot["item_id"])
			if server.datapacks.is_container(target_id):
				if not target_slot.has("children"):
					target_slot["children"] = []
				var cap: int = server.datapacks.get_container_slots(target_id)
				if target_slot["children"].size() >= cap:
					server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "That container is full.")
					return
				var moved_item := src_item.duplicate(true)
				moved_item["count"] = move_count
				_remove_from_source(peer_id, from_uid, src_idx, move_count, slot_name)
				target_slot["children"].append(moved_item)
				server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
					"You put %d %s in the %s." % [move_count, item_name, server.datapacks.get_item_name(target_id)])
				# Refresh source and target
				if from_uid == -peer_id:
					server.inventory.send_inventory(peer_id)
					broadcast_container_update(from_uid)
				elif from_uid > 0:
					broadcast_container_update(from_uid)
				elif from_uid == -1:
					server.inventory.send_equipment(peer_id)
				broadcast_container_update(to_uid)
				# Also refresh the nested container if it's open
				if target_slot.has("_cid") and _nested_items.has(int(target_slot["_cid"])):
					broadcast_container_update(int(target_slot["_cid"]))
				return

	if to_uid == -peer_id:
		# Same-container split: if source is also the backpack and it's a partial stack move
		if from_uid == -peer_id and move_count < item_count:
			var inv: Array = s["inventory"]
			# Check if dropping onto an existing stackable slot of the same item
			if to_index >= 0 and to_index < inv.size() and to_index != src_idx:
				var target_slot: Dictionary = inv[to_index]
				if str(target_slot["item_id"]) == item_id and server.datapacks.is_stackable(item_id):
					# Merge into existing stack
					target_slot["count"] = int(target_slot["count"]) + move_count
					inv[src_idx]["count"] = item_count - move_count
					server.inventory.send_inventory(peer_id)
					broadcast_container_update(-peer_id)
					return
			# Check capacity before creating a new slot
			var capacity: int = server.inventory.get_backpack_capacity(peer_id)
			if inv.size() >= capacity:
				server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Backpack full.")
				return
			# Reduce source stack and create new slot
			inv[src_idx]["count"] = item_count - move_count
			inv.append({"item_id": item_id, "count": move_count})
			server.inventory.send_inventory(peer_id)
			broadcast_container_update(-peer_id)
			return
		# Moving full stack or from different container -- try to merge into existing stackable first
		if server.datapacks.is_stackable(item_id) and from_uid != -peer_id:
			var inv: Array = s["inventory"]
			for slot in inv:
				if str(slot["item_id"]) == item_id:
					slot["count"] = int(slot["count"]) + move_count
					_remove_from_source(peer_id, from_uid, src_idx, move_count, slot_name)
					server.inventory.send_inventory(peer_id)
					broadcast_container_update(-peer_id)
					if from_uid > 0:
						broadcast_container_update(from_uid)
					return
		var added: int = server.inventory._add_to_inventory(peer_id, item_id, move_count)
		if added <= 0:
			if added != -1:
				server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Backpack full.")
			return
		_remove_from_source(peer_id, from_uid, src_idx, added, slot_name)
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
			"You took %d %s." % [added, item_name])

	elif to_uid == -1:
		# To equipment slot
		var item_equip_slot: String = server.datapacks.get_equip_slot(item_id)
		if item_equip_slot.is_empty():
			server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "This item cannot be equipped.")
			return
		# Validate: item's equip_slot must match the target slot the player dropped it on
		var target_slot: String = slot_name  # The slot the player dragged to
		if not target_slot.is_empty() and target_slot != item_equip_slot:
			server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
				"You cannot put that item there.")
			return
		if from_uid == -peer_id:
			server.inventory.handle_equip_item(peer_id, src_idx)
		else:
			var equip: Dictionary = s["equipment"]
			var current_equipped: String = equip.get(item_equip_slot, "")
			if not current_equipped.is_empty():
				var bp_capacity: int = server.inventory.get_backpack_capacity(peer_id)
				if s["inventory"].size() >= bp_capacity:
					server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Backpack full -- unequip first.")
					return
				s["inventory"].append({"item_id": current_equipped, "count": 1})
			_remove_from_source(peer_id, from_uid, src_idx, 1, "")
			equip[item_equip_slot] = item_id
			server.inventory.send_inventory(peer_id)
			server.inventory.send_equipment(peer_id)
			broadcast_container_update(from_uid)
			var equip_name: String = server.datapacks.get_item_name(item_id)
			server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "You equipped %s." % equip_name)
		return

	elif to_uid == 0:
		var pp: Vector3i = s["position"]
		if pp.z != to_z or absi(pp.x - to_x) > 7 or absi(pp.y - to_y) > 7:
			server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Too far away.")
			return
		var dest_pos := Vector3i(to_x, to_y, to_z)
		var moved_item := src_item.duplicate(true)
		moved_item["count"] = move_count
		_remove_from_source(peer_id, from_uid, src_idx, move_count, slot_name)
		# Add to ground items (full item data including children)
		_add_ground_item_full(dest_pos, moved_item)
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
			"You dropped %d %s." % [move_count, item_name])

	elif to_uid > 0:
		if _is_nested_container(to_uid):
			var ni: Dictionary = _nested_items[to_uid]
			if ni["items_ref"].size() >= ni["capacity"]:
				server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Container is full.")
				return
			var moved_item := src_item.duplicate(true)
			moved_item["count"] = move_count
			_remove_from_source(peer_id, from_uid, src_idx, move_count, slot_name)
			ni["items_ref"].append(moved_item)
			broadcast_container_update(to_uid)
			server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
				"You put %d %s in the container." % [move_count, item_name])
		elif _containers.has(to_uid):
			var dest_container: Dictionary = _containers[to_uid]
			var cp: Vector3i = dest_container["position"]
			var pp: Vector3i = s["position"]
			if pp.z != cp.z or absi(pp.x - cp.x) > CONTAINER_RANGE or absi(pp.y - cp.y) > CONTAINER_RANGE:
				server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Too far away.")
				return
			var moved_item := src_item.duplicate(true)
			moved_item["count"] = move_count
			_remove_from_source(peer_id, from_uid, src_idx, move_count, slot_name)
			dest_container["items"].append(moved_item)
			broadcast_container_update(to_uid)
			server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
				"You put %d %s in the container." % [move_count, item_name])
		else:
			return

	# Refresh source container
	if from_uid == -peer_id:
		server.inventory.send_inventory(peer_id)
		broadcast_container_update(from_uid)
	elif from_uid > 0:
		broadcast_container_update(from_uid)
	elif from_uid == -1:
		server.inventory.send_equipment(peer_id)


## Removes count items from the source container/backpack/equipment slot.
func _remove_from_source(peer_id: int, from_uid: int, from_index: int, count: int, slot_name: String) -> void:
	var s: Dictionary = server._sessions[peer_id]
	if from_uid == -peer_id:
		var inv: Array = s["inventory"]
		if from_index < 0 or from_index >= inv.size():
			return
		var slot: Dictionary = inv[from_index]
		var have: int = int(slot["count"])
		if count >= have:
			inv.remove_at(from_index)
		else:
			slot["count"] = have - count
	elif from_uid == -1:
		var equip: Dictionary = s["equipment"]
		if equip.has(slot_name):
			# If removing backpack, clear inventory and close backpack window
			if slot_name == "backpack":
				s["inventory"] = []
				var bp_cid := -peer_id
				if _viewer_registry.has(bp_cid):
					for pid in _viewer_registry[bp_cid]:
						server.rpc_id(pid, "rpc_container_close", bp_cid)
					_viewer_registry.erase(bp_cid)
			# Handle partial moves for stackable equipment (ammo)
			var eq_counts: Dictionary = s.get("equip_counts", {})
			var eq_have: int = int(eq_counts.get(slot_name, 1))
			if count >= eq_have:
				equip[slot_name] = ""
				eq_counts[slot_name] = 0
			else:
				eq_counts[slot_name] = eq_have - count
	elif from_uid > 0:
		if _is_nested_container(from_uid):
			var ni: Dictionary = _nested_items[from_uid]
			var items: Array = ni["items_ref"]
			if from_index < 0 or from_index >= items.size():
				return
			var slot: Dictionary = items[from_index]
			var have: int = int(slot["count"])
			if count >= have:
				items.remove_at(from_index)
			else:
				slot["count"] = have - count
		elif _containers.has(from_uid):
			var items: Array = _containers[from_uid]["items"]
			if from_index < 0 or from_index >= items.size():
				return
			var slot: Dictionary = items[from_index]
			var have: int = int(slot["count"])
			if count >= have:
				items.remove_at(from_index)
			else:
				slot["count"] = have - count


func handle_pickup_ground_container(peer_id: int, container_id: int) -> void:
	## Picks up a ground container (backpack on ground) and equips it if possible.
	if not _containers.has(container_id):
		return
	if not server._sessions.has(peer_id):
		return
	var container: Dictionary = _containers[container_id]
	if container.get("type", "") != "ground_container":
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "You can't pick that up.")
		return
	var pos: Vector3i = container["position"]
	var pp: Vector3i = server._sessions[peer_id]["position"]
	if pp.z != pos.z or absi(pp.x - pos.x) > 1 or absi(pp.y - pos.y) > 1:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Too far away.")
		return
	var s: Dictionary = server._sessions[peer_id]
	var item_id: String = str(container["definition_id"])
	var equip_slot: String = server.datapacks.get_equip_slot(item_id)
	var children: Array = container.get("items", [])

	# If it's a backpack and no backpack equipped -> equip directly
	if equip_slot == "backpack" and str(s["equipment"].get("backpack", "")).is_empty():
		s["equipment"]["backpack"] = item_id
		s["inventory"] = children.duplicate(true)
		# Remove from ground
		_remove_ground_container(container_id)
		server.inventory.send_inventory(peer_id)
		server.inventory.send_equipment(peer_id)
		var item_name: String = server.datapacks.get_item_name(item_id)
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "You equipped %s." % item_name)
		return

	# Otherwise try to add to inventory
	if not server.inventory.has_backpack(peer_id):
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "You need a backpack to carry items.")
		return
	var added: int = server.inventory._add_to_inventory(peer_id, item_id, 1)
	if added <= 0:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Backpack full.")
		return
	# Transfer children to the inventory slot
	var inv: Array = s["inventory"]
	for inv_slot in inv:
		if inv_slot["item_id"] == item_id and not inv_slot.has("children"):
			inv_slot["children"] = children.duplicate(true)
			break
	_remove_ground_container(container_id)
	server.inventory.send_inventory(peer_id)
	var item_name: String = server.datapacks.get_item_name(item_id)
	server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "You picked up %s." % item_name)


func _remove_ground_container(container_id: int) -> void:
	## Removes a ground container from both _containers and _ground_items.
	if not _containers.has(container_id):
		return
	var container: Dictionary = _containers[container_id]
	var pos: Vector3i = container["position"]
	# Remove from ground items array
	if server.inventory._ground_items.has(pos):
		var items: Array = server.inventory._ground_items[pos]
		for i in range(items.size() - 1, -1, -1):
			if items[i].has("_ground_cid") and int(items[i]["_ground_cid"]) == container_id:
				items.remove_at(i)
				break
		if items.is_empty():
			server.inventory._ground_items.erase(pos)
	# Remove container and broadcast
	_remove_container(container_id)
