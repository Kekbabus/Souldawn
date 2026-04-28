#  server_main.gd -- authoritative game server entry point & orchestrator
#
#  Creates the ENet server, manages the main _process game loop, and
#  dispatches all client->server RPCs to the appropriate subsystem.
#  Owns the spatial grid, player movement pipeline, Tibia speed formula,
#  tile-blocking checks, broadcast helpers, and orphan (x-log) session
#  management.
#
#  Subsystems managed (instantiated as child nodes in _ready):
#    auth, chat, entities, combat, inventory, spells, map, chunks,
#    tile_actions, db, datapacks, containers, npcs
#
#  Also declares all server->client RPC stubs required by Godot's
#  multiplayer signature registration.
extends Node

const SERVER_PORT_DEFAULT := 8080
const TILE_SIZE := 32

var _server_port: int = SERVER_PORT_DEFAULT
var _server_name: String = "Souldawn"
var _max_players: int = 100
const NEARBY_RANGE := 15
const GRID_CELL_SIZE := 20
const DEFAULT_GROUND_SPEED := 150.0
const DEFAULT_PLAYER_SPEED := 220.0

var auth: Node = null
var chat: Node = null
var entities: Node = null
var combat: Node = null
var inventory: Node = null
var spells: Node = null
var pvp: Node = null
var console: Node = null
var fields: Node = null
var map: Node = null
var chunks: Node = null
var tile_actions: Node = null
var db: Node = null
var datapacks: Node = null
var containers: Node = null
var npcs: Node = null
var ratelimit: Node = null

var _peer: ENetMultiplayerPeer = null
var _sessions: Dictionary = {}        # peer_id -> session Dictionary
var _spatial_grid: Dictionary = {}    # "cx_cy" -> Array[peer_id]
var _player_cells: Dictionary = {}    # peer_id -> "cx_cy"
var _next_spawn_x: int = 0
var _next_spawn_y: int = 0

#  LIFECYCLE

## Loads server configuration from server_config.json.
## Checks the executable's directory first (for deployed builds), then res:// (for editor).
func _load_server_config() -> void:
	var data: Dictionary = {}
	var exe_dir := OS.get_executable_path().get_base_dir()
	var paths := [
		exe_dir + "/server_config.json",
		"res://server_config.json",
	]
	for path in paths:
		var file := FileAccess.open(path, FileAccess.READ)
		if file != null:
			var json := JSON.new()
			if json.parse(file.get_as_text()) == OK and json.data is Dictionary:
				data = json.data
			file.close()
			print("server: loaded config from %s" % path)
			break
	if data.is_empty():
		print("server: no config found, using defaults")
		return
	_server_port = int(data.get("port", SERVER_PORT_DEFAULT))
	_server_name = str(data.get("server_name", "Souldawn"))
	_max_players = int(data.get("max_players", 100))
	print("server: %s on port %d (max %d players)" % [_server_name, _server_port, _max_players])


## Instantiates all subsystem child nodes, wires cross-references, opens the
## database, loads datapacks/map data, starts the ENet server, and spawns monsters.
func _ready() -> void:
	_load_server_config()
	# Instantiate subsystems
	map = preload("res://Scripts/server_map.gd").new()
	map.name = "ServerMap"
	add_child(map)

	chunks = preload("res://Scripts/server_chunks.gd").new()
	chunks.name = "ServerChunks"
	add_child(chunks)

	tile_actions = preload("res://Scripts/server_tile_actions.gd").new()
	tile_actions.name = "ServerTileActions"
	add_child(tile_actions)

	db = preload("res://Scripts/server_db.gd").new()
	db.name = "ServerDB"
	add_child(db)

	datapacks = preload("res://Scripts/server_datapacks.gd").new()
	datapacks.name = "ServerDatapacks"
	add_child(datapacks)

	containers = preload("res://Scripts/server_containers.gd").new()
	containers.name = "ServerContainers"
	add_child(containers)

	npcs = preload("res://Scripts/server_npcs.gd").new()
	npcs.name = "ServerNPCs"
	add_child(npcs)

	auth = preload("res://Scripts/server_auth.gd").new()
	auth.name = "ServerAuth"
	add_child(auth)

	chat = preload("res://Scripts/server_chat.gd").new()
	chat.name = "ServerChat"
	add_child(chat)

	entities = preload("res://Scripts/server_entities.gd").new()
	entities.name = "ServerEntities"
	add_child(entities)

	combat = preload("res://Scripts/server_combat.gd").new()
	combat.name = "ServerCombat"
	add_child(combat)

	inventory = preload("res://Scripts/server_inventory.gd").new()
	inventory.name = "ServerInventory"
	add_child(inventory)

	spells = preload("res://Scripts/server_spells.gd").new()
	spells.name = "ServerSpells"
	add_child(spells)

	pvp = preload("res://Scripts/server_pvp.gd").new()
	pvp.name = "ServerPVP"
	add_child(pvp)

	console = preload("res://Scripts/server_console.gd").new()
	console.name = "ServerConsole"
	add_child(console)

	fields = preload("res://Scripts/server_fields.gd").new()
	fields.name = "ServerFields"
	add_child(fields)

	ratelimit = preload("res://Scripts/server_ratelimit.gd").new()
	ratelimit.name = "ServerRateLimit"
	add_child(ratelimit)

	# Wire cross-references
	map.server = self
	chunks.server = self
	tile_actions.server = self
	db.server = self
	datapacks.server = self
	containers.server = self
	npcs.server = self
	auth.server = self
	chat.server = self
	entities.server = self
	combat.server = self
	inventory.server = self
	spells.server = self
	pvp.server = self
	console.server = self
	fields.server = self
	ratelimit.server = self

	# Open database
	db.open()

	# Load datapacks
	datapacks.load_all()
	spells._load_area_patterns()
	spells._load_spell_defs()

	# Load map data
	map.load_tile_defs("res://datapacks/tiles/terrain_tiles.json")
	map.load_map("res://Data/Maps/testMap.map.json")
	tile_actions.load_actions()

	# Start network
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(_server_port)
	if err != OK:
		push_error("server: Failed to create server -- %s" % error_string(err))
		return
	multiplayer.multiplayer_peer = _peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("server: listening on port %d" % _server_port)

	# Spawn monsters from map spawn points
	_spawn_from_map()
	npcs.spawn_npcs_from_map()

	# Restore ground items from last backup
	db.restore_ground_items()

	# Start server console (stdin command reader)
	console.start()


## Called when a new ENet peer connects. No-op; authentication happens via rpc_login.
func _on_peer_connected(peer_id: int) -> void:
	pass  # Silent -- login attempt will print if needed


## Handles peer disconnect. If combat-locked, keeps the session as an orphan for
## 60 seconds (x-log protection). Otherwise saves and removes immediately.
func _on_peer_disconnected(peer_id: int) -> void:
	if not _sessions.has(peer_id):
		auth._authenticated_peers.erase(peer_id)
		return
	var s: Dictionary = _sessions[peer_id]
	var now_ms := Time.get_ticks_msec()
	var combat_until: float = float(s.get("combat_lock_until", 0.0))
	if now_ms < combat_until:
		# X-log: combat locked -- keep session alive as orphan for 60 seconds
		print("server: peer %d x-logged (combat locked) -- session stays alive" % peer_id)
		s["_orphan"] = true
		s["_orphan_expire_ms"] = now_ms + 60000  # 60 seconds
		s["_orphan_peer_id"] = peer_id
		# Remove from spatial grid so no RPCs are sent to this peer
		_grid_remove(peer_id)
		auth._authenticated_peers.erase(peer_id)
		chunks.on_peer_disconnect(peer_id)
		containers.on_peer_disconnect(peer_id)
		npcs.on_peer_disconnect(peer_id)
		pvp.on_peer_disconnect(peer_id)
		ratelimit.on_peer_disconnect(peer_id)
		# Clear combat target so melee tick stops attacking
		combat._combat_targets.erase(peer_id)
	else:
		# Clean logout -- save and remove immediately
		print("server: peer %d disconnected" % peer_id)
		spells.clear_buffs(peer_id)
		auth._save_and_remove(peer_id)
		auth._authenticated_peers.erase(peer_id)
		chunks.on_peer_disconnect(peer_id)
		containers.on_peer_disconnect(peer_id)
		npcs.on_peer_disconnect(peer_id)
		ratelimit.on_peer_disconnect(peer_id)
		pvp.on_peer_disconnect(peer_id)


## Reads monster spawn points from the loaded map and spawns entities via the entities subsystem.
func _spawn_from_map() -> void:
	var spawn_points: Array = map.get_spawn_points()
	var spawned := 0
	for sp in spawn_points:
		if not sp is Dictionary:
			continue
		var def_id: String = str(sp.get("definition_id", ""))
		if def_id.is_empty():
			continue
		var monster_def: Dictionary = datapacks.get_monster(def_id)
		if monster_def.is_empty():
			continue  # Skip NPCs and unknown definitions for now
		var x: int = int(sp.get("x", 0))
		var y: int = int(sp.get("y", 0))
		var z: int = int(sp.get("z", 7))
		var spawn_count: int = int(sp.get("spawn_count", 1))
		var spawn_radius: int = int(sp.get("spawn_radius", 0))
		var display_name: String = str(monster_def.get("display_name", def_id))
		var health: int = int(monster_def.get("base_health", 100))
		var speed: int = int(monster_def.get("speed", 200))
		var xp_reward: int = int(monster_def.get("experience_reward", 0))

		for i in range(spawn_count):
			var pos := _find_walkable_spawn(x, y, z, spawn_radius)
			if pos == Vector3i(-9999, -9999, -9999):
				push_warning("server: couldn't find walkable tile for %s near (%d,%d,%d)" % [def_id, x, y, z])
				continue
			entities.spawn_entity(def_id, display_name, pos, health, speed, xp_reward)
			spawned += 1
	print("server: spawned %d monsters from %d spawn points" % [spawned, spawn_points.size()])


func _find_walkable_spawn(cx: int, cy: int, cz: int, radius: int) -> Vector3i:
	## Tries to find a walkable, unoccupied tile within radius. Tries 20 random positions,
	## then spirals outward. Returns Vector3i(-9999,-9999,-9999) if nothing found.
	# Try random positions first
	for _attempt in range(20):
		var sx: int = cx + randi_range(-radius, radius)
		var sy: int = cy + randi_range(-radius, radius)
		var pos := Vector3i(sx, sy, cz)
		if not map.is_blocking(pos) and not is_tile_blocked(pos):
			return pos
	# Fallback: try center
	var center := Vector3i(cx, cy, cz)
	if not map.is_blocking(center) and not is_tile_blocked(center):
		return center
	# Spiral outward
	for r in range(1, radius + 3):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				if absi(dx) != r and absi(dy) != r:
					continue
				var pos := Vector3i(cx + dx, cy + dy, cz)
				if not map.is_blocking(pos) and not is_tile_blocked(pos):
					return pos
	return Vector3i(-9999, -9999, -9999)


#  GAME LOOP

## Saves all players and ground items on server shutdown (Ctrl+C, window close).
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		print("server: shutting down -- saving all data...")
		if console: console.stop()
		db.save_all_and_backup()
		print("server: save complete, exiting.")


## Main game loop. Ticks player movement, orphan cleanup, status updates,
## entity AI/respawns, combat, spell buffs, container decay, NPC wander, and auto-save.
func _process(delta: float) -> void:
	_process_player_movement()
	_process_orphan_sessions()
	_process_status_updates()
	entities.process_respawns(delta)
	spells.process_mana_regen(delta)
	spells.process_buffs(delta)
	entities.process_entity_ai(delta)
	combat.process_combat_tick(delta)
	combat.process_conditions(delta)
	containers.process_decay(delta)
	containers.check_open_container_proximity()
	npcs.process_dialogue_timeouts(delta)
	npcs.process_npc_wander(delta)
	pvp.process_skulls(delta)
	console.process_commands()
	fields.process_fields(delta)
	db.process_auto_save(delta)
	ratelimit.process_kicks()


## Processes walk_dir for every active session. Applies cooldown, blocking checks,
## speed formula, spatial grid update, chunk streaming, and step-on tile actions.
func _process_player_movement() -> void:
	var now_ms := Time.get_ticks_msec()
	for peer_id in _sessions:
		var s: Dictionary = _sessions[peer_id]
		if s.get("is_dead", false):
			continue
		var walk_dir: Vector2i = s["walk_dir"]
		if walk_dir == Vector2i.ZERO:
			continue
		# Expire direction if client stopped sending (500ms grace period)
		if (now_ms - float(s["walk_dir_time"])) > 500.0:
			s["walk_dir"] = Vector2i.ZERO
			continue
		# Cooldown is based on the PREVIOUS step's duration, not the new direction
		var last_step_duration: float = float(s.get("last_step_duration", 0.0))
		if (now_ms - float(s["last_move_time"])) < last_step_duration:
			continue
		var cur: Vector3i = s["position"]
		var target := Vector3i(cur.x + walk_dir.x, cur.y + walk_dir.y, cur.z)
		if is_tile_blocked(target, peer_id):
			s["walk_dir"] = Vector2i.ZERO
			continue
		# Calculate THIS step's duration (used as cooldown for the NEXT step)
		var this_step_duration := _get_step_duration(s, walk_dir)
		s["position"] = target
		s["last_move_time"] = float(now_ms)
		s["last_step_duration"] = this_step_duration
		s["last_move_diagonal"] = (walk_dir.x != 0 and walk_dir.y != 0)
		# Clear direction after move -- client re-sends while key is held
		s["walk_dir"] = Vector2i.ZERO
		_grid_update(peer_id, target)
		_broadcast_player_move(peer_id, target, this_step_duration)
		# Stream new chunks if player crossed chunk boundary
		chunks.on_player_move(peer_id, cur, target)
		# Check step-on tile actions (stairs, teleports)
		tile_actions.check_step_on(peer_id, target)
		# Update speed/ground speed display only when ground speed changes
		var old_gs: float = float(s.get("_last_ground_speed", -1.0))
		var new_gs: float = map.get_ground_speed(target)
		if new_gs != old_gs:
			s["_last_ground_speed"] = new_gs
			inventory.send_combat_stats(peer_id)


var _status_check_acc: float = 0.0


func _process_status_updates() -> void:
	## Check for expired combat locks and send status updates.
	_status_check_acc += get_process_delta_time()
	if _status_check_acc < 1.0:  # Check every 1 second
		return
	_status_check_acc -= 1.0
	var now_ms := Time.get_ticks_msec()
	for peer_id in _sessions:
		var s: Dictionary = _sessions[peer_id]
		if s.get("_orphan", false):
			continue
		# Check if combat lock just expired
		var lock_until: float = float(s.get("combat_lock_until", 0.0))
		var was_locked: bool = s.get("_was_combat_locked", false)
		var is_locked: bool = float(now_ms) < lock_until
		if was_locked and not is_locked:
			combat.send_status(peer_id)
		s["_was_combat_locked"] = is_locked
		s["_was_combat_locked"] = is_locked


func _process_orphan_sessions() -> void:
	## Clean up orphaned sessions (x-logged players with combat lock).
	var now_ms := Time.get_ticks_msec()
	var to_remove: Array = []
	for peer_id in _sessions:
		var s: Dictionary = _sessions[peer_id]
		if not s.get("_orphan", false):
			continue
		# Check if orphan timer expired
		if now_ms >= int(s.get("_orphan_expire_ms", 0)):
			to_remove.append(peer_id)
		# Check if player died while orphaned
		elif s.get("is_dead", false):
			to_remove.append(peer_id)
	for peer_id in to_remove:
		print("server: orphan session %d expired -- removing" % peer_id)
		spells.clear_buffs(peer_id)
		auth._save_and_remove(peer_id)


#  TIBIA SPEED FORMULA

## Calculates step duration in milliseconds using the Tibia 7.4 speed formula.
## Accounts for creature speed, terrain ground speed, and diagonal movement factor.
## Result is rounded up to the nearest 50ms, minimum 50ms.
func _get_step_duration(session: Dictionary, walk_dir: Vector2i) -> float:
	var creature_speed := maxf(float(session.get("speed", DEFAULT_PLAYER_SPEED)), 1.0)
	# Use per-tile ground speed from map if available (terrain factor)
	var ground_speed := DEFAULT_GROUND_SPEED
	if map != null:
		var pos: Vector3i = session["position"]
		var target := Vector3i(pos.x + walk_dir.x, pos.y + walk_dir.y, pos.z)
		ground_speed = map.get_ground_speed(target)
	# TFS formula: StepTime = ceil(groundSpeed / creatureSpeed * 1000, 50ms)
	# Diagonal steps cost 2x (lastStepCost from TFS -- diagonal covers more distance)
	var diagonal_factor: float = 2.0 if (walk_dir.x != 0 and walk_dir.y != 0) else 1.0
	var step_seconds: float = ground_speed / creature_speed * diagonal_factor
	# Round up to nearest 50ms
	var step_ms: float = ceilf(step_seconds * 1000.0 / 50.0) * 50.0
	return maxf(step_ms, 50.0)


#  BROADCAST

## Broadcasts a player movement RPC to all players within NEARBY_RANGE of [param pos].
func _broadcast_player_move(peer_id: int, pos: Vector3i, step_ms: float = 0.0) -> void:
	var recipients := get_players_in_range(pos, NEARBY_RANGE)
	var s_mover: Dictionary = _sessions[peer_id] if _sessions.has(peer_id) else {}
	for pid in recipients:
		# Check if this recipient has seen the mover recently
		var s_recv: Dictionary = _sessions[pid] if _sessions.has(pid) else {}
		var seen_key := "_seen_%d" % peer_id
		if not s_recv.get(seen_key, false):
			# First time seeing this player — send teleport to snap position
			rpc_id(pid, "rpc_player_teleport", peer_id, pos.x, pos.y, pos.z)
			s_recv[seen_key] = true
		else:
			rpc_id(pid, "rpc_player_move", peer_id, pos.x, pos.y, pos.z, int(step_ms))

		# Also check: has the mover seen this recipient?
		# If not, send the recipient's current position and facing to the mover
		var mover_seen_key := "_seen_%d" % pid
		if not s_mover.get(mover_seen_key, false):
			var other_s: Dictionary = _sessions[pid]
			var other_pos: Vector3i = other_s["position"]
			rpc_id(peer_id, "rpc_player_teleport", pid, other_pos.x, other_pos.y, other_pos.z)
			rpc_id(peer_id, "rpc_player_face", pid, int(other_s.get("facing_direction", 2)))
			s_mover[mover_seen_key] = true

	# Clear "seen" flags for players no longer in range
	for pid in _sessions:
		if pid == peer_id:
			continue
		var s: Dictionary = _sessions[pid]
		var seen_key := "_seen_%d" % peer_id
		if s.get(seen_key, false) and pid not in recipients:
			s[seen_key] = false
		# Also clear mover's seen flag for this player
		var mover_key := "_seen_%d" % pid
		if s_mover.get(mover_key, false) and pid not in recipients:
			s_mover[mover_key] = false


func is_peer_active(peer_id: int) -> bool:
	## Returns true if the peer has an active session and is NOT an orphan (disconnected x-logger).
	if not _sessions.has(peer_id):
		return false
	return not _sessions[peer_id].get("_orphan", false)


func safe_rpc(peer_id: int, method: String, args: Array = []) -> void:
	## Sends an RPC only if the peer is still actively connected (not orphaned).
	if not is_peer_active(peer_id):
		return
	match args.size():
		0: rpc_id(peer_id, method)
		1: rpc_id(peer_id, method, args[0])
		2: rpc_id(peer_id, method, args[0], args[1])
		3: rpc_id(peer_id, method, args[0], args[1], args[2])
		4: rpc_id(peer_id, method, args[0], args[1], args[2], args[3])
		5: rpc_id(peer_id, method, args[0], args[1], args[2], args[3], args[4])
		6: rpc_id(peer_id, method, args[0], args[1], args[2], args[3], args[4], args[5])
		7: rpc_id(peer_id, method, args[0], args[1], args[2], args[3], args[4], args[5], args[6])
		_: push_warning("safe_rpc: too many args for %s" % method)


## Returns all active (non-orphan) peer IDs whose position is within [param range_tiles] of [param pos] on the same floor.
func get_players_in_range(pos: Vector3i, range_tiles: int) -> Array:
	var result: Array = []
	@warning_ignore("integer_division")
	var cx := pos.x / GRID_CELL_SIZE
	@warning_ignore("integer_division")
	var cy := pos.y / GRID_CELL_SIZE
	@warning_ignore("integer_division")
	var cell_range := (range_tiles / GRID_CELL_SIZE) + 1
	for gx in range(cx - cell_range, cx + cell_range + 1):
		for gy in range(cy - cell_range, cy + cell_range + 1):
			var key := "%d_%d" % [gx, gy]
			if _spatial_grid.has(key):
				for pid in _spatial_grid[key]:
					if _sessions.has(pid):
						# Skip orphan sessions (disconnected peers kept alive for x-log)
						if _sessions[pid].get("_orphan", false):
							continue
						var sp: Vector3i = _sessions[pid]["position"]
						if sp.z == pos.z and absi(sp.x - pos.x) <= range_tiles and absi(sp.y - pos.y) <= range_tiles:
							result.append(pid)
	return result


#  SPATIAL GRID

## Returns the spatial grid cell key string ("cx_cy") for a world position.
func cell_key(pos: Vector3i) -> String:
	@warning_ignore("integer_division")
	return "%d_%d" % [pos.x / GRID_CELL_SIZE, pos.y / GRID_CELL_SIZE]

## Inserts a peer into the spatial grid at [param pos].
func _grid_add(peer_id: int, pos: Vector3i) -> void:
	var key := cell_key(pos)
	if not _spatial_grid.has(key):
		_spatial_grid[key] = []
	_spatial_grid[key].append(peer_id)
	_player_cells[peer_id] = key

## Removes a peer from the spatial grid entirely.
func _grid_remove(peer_id: int) -> void:
	if _player_cells.has(peer_id):
		var key: String = _player_cells[peer_id]
		if _spatial_grid.has(key):
			_spatial_grid[key].erase(peer_id)
		_player_cells.erase(peer_id)

## Moves a peer to a new spatial grid cell if the cell changed. Public API.
func grid_update(peer_id: int, new_pos: Vector3i) -> void:
	var new_key := cell_key(new_pos)
	var old_key: String = _player_cells.get(peer_id, "")
	if new_key == old_key:
		return
	_grid_remove(peer_id)
	_grid_add(peer_id, new_pos)

## Internal alias for [method grid_update].
func _grid_update(peer_id: int, new_pos: Vector3i) -> void:
	grid_update(peer_id, new_pos)


#  TILE BLOCKING

## Returns true if [param pos] is blocked by map terrain, a living entity, a living
## player (other than [param exclude_peer_id]), or an NPC.
func is_tile_blocked(pos: Vector3i, exclude_peer_id: int = -1) -> bool:
	# Check map walkability first
	if map != null and map.is_blocking(pos):
		return true
	# Check magic wall fields
	if fields != null and fields.is_wall_at(pos):
		return true
	# Check entities using spatial grid (only nearby cell)
	var key: String = cell_key(pos)
	if entities._entity_grid.has(key):
		for eid in entities._entity_grid[key]:
			if entities._entities.has(eid):
				var ent: Dictionary = entities._entities[eid]
				if int(ent.get("health", 0)) <= 0:
					continue
				if ent["position"] == pos:
					return true
	# Check players using spatial grid
	if _spatial_grid.has(key):
		for pid in _spatial_grid[key]:
			if pid == exclude_peer_id:
				continue
			if _sessions.has(pid):
				var s: Dictionary = _sessions[pid]
				if s.get("is_dead", false):
					continue
				if s["position"] == pos:
					return true
	# Check NPCs
	if npcs.is_npc_at(pos):
		return true
	return false


## Returns true if a tile is blocked for monsters/entities.
## Same as is_tile_blocked but also blocks tiles with floor-change tiles
## (stairs, holes, ramps) so monsters don't walk onto them.
const ENTITY_BLOCKED_TILE_IDS := [
	801, 802, 803, 804, 805,           # holes/pitfalls
	9001, 9002, 9003, 9004, 9005,      # floor change tiles
	20648, 20649, 20650, 20651, 20652, 20653,  # ramps/slopes
	20656, 20657, 20658, 20659, 20660, 20661,  # stairs
]

func is_tile_blocked_for_entity(pos: Vector3i) -> bool:
	if is_tile_blocked(pos):
		return true
	if map != null:
		var stack: Array = map.get_tile_stack(pos)
		for entry in stack:
			var tid: int = int(entry[0]) if entry is Array else int(entry)
			if tid in ENTITY_BLOCKED_TILE_IDS:
				return true
	return false


#  CLIENT -> SERVER RPCs (thin dispatchers)

## Sets the player's walk direction and facing. Movement is applied in [method _process_player_movement].
@rpc("any_peer")
func rpc_move_direction(dx: int, dy: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "movement"):
		return
	if not _sessions.has(peer_id):
		return
	dx = clampi(dx, -1, 1)
	dy = clampi(dy, -1, 1)
	var s: Dictionary = _sessions[peer_id]
	s["walk_dir"] = Vector2i(dx, dy)
	s["walk_dir_time"] = Time.get_ticks_msec()
	# Update facing direction based on walk direction
	# 0=N, 1=E, 2=S, 3=W -- for diagonals, prefer vertical
	var new_facing: int = -1
	if dy < 0: new_facing = 0      # North
	elif dy > 0: new_facing = 2    # South
	elif dx > 0: new_facing = 1    # East
	elif dx < 0: new_facing = 3    # West
	if new_facing >= 0 and new_facing != s.get("facing_direction", 2):
		s["facing_direction"] = new_facing

## Turns the player to face [param direction] (0=N,1=E,2=S,3=W) without moving.
## Blocked while mid-step animation.
@rpc("any_peer")
func rpc_turn_direction(direction: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "movement"):
		return
	if not _sessions.has(peer_id):
		return
	var s: Dictionary = _sessions[peer_id]
	if s.get("is_dead", false):
		return
	# Block facing change while mid-step animation
	if s["walk_dir"] != Vector2i.ZERO:
		return
	var now_ms := Time.get_ticks_msec()
	var last_step_dur: float = float(s.get("last_step_duration", 0.0))
	var last_move_time: float = float(s.get("last_move_time", 0.0))
	# Use 80% of step duration -- animation finishes before the full cooldown
	if (now_ms - last_move_time) < last_step_dur * 0.8:
		return
	direction = clampi(direction, 0, 3)
	s["facing_direction"] = direction
	var pos: Vector3i = s["position"]
	for pid in get_players_in_range(pos, NEARBY_RANGE):
		rpc_id(pid, "rpc_player_face", peer_id, direction)

## Dispatches account registration to the auth subsystem.
@rpc("any_peer")
func rpc_register(username: String, password: String) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "register"):
		return
	auth.handle_register(peer_id, username, password)

## Dispatches login to the auth subsystem.
@rpc("any_peer")
func rpc_login(username: String, password: String) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "login"):
		return
	auth.handle_login(peer_id, username, password)

## Dispatches logout to the auth subsystem.
@rpc("any_peer")
func rpc_logout() -> void:
	auth.handle_logout(multiplayer.get_remote_sender_id())

## Dispatches character selection to the auth subsystem.
@rpc("any_peer")
func rpc_select_character(char_id: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "login"):
		return
	auth.handle_select_character(peer_id, char_id)

## Dispatches character creation to the auth subsystem.
@rpc("any_peer")
func rpc_create_character(character_name: String, vocation: String = "none", gender: String = "male") -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "register"):
		return
	auth.handle_create_character(peer_id, character_name, vocation, gender)

## Dispatches a chat message to the chat subsystem.
@rpc("any_peer")
func rpc_send_chat(channel: String, text: String) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "chat"):
		return
	chat.handle_send_chat(peer_id, channel, text)

## Dispatches a melee attack request to the combat subsystem.
@rpc("any_peer")
func rpc_attack_request(entity_id: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "combat"):
		return
	combat.handle_attack_request(peer_id, entity_id)

## Dispatches a PVP attack request (player targeting another player).
@rpc("any_peer")
func rpc_attack_player(target_peer_id: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "combat"):
		return
	combat.handle_attack_player(peer_id, target_peer_id)

## Handles tile use: range-checks the position, checks for a container first,
## then falls through to tile_actions for doors/levers/etc.
@rpc("any_peer")
func rpc_use_tile(x: int, y: int, z: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "item"):
		return
	if not _sessions.has(peer_id):
		return
	var s: Dictionary = _sessions[peer_id]
	if s.get("is_dead", false):
		return
	var pos := Vector3i(x, y, z)
	var pp: Vector3i = s["position"]
	# Range check -- must be adjacent (1 tile)
	if pp.z != z or absi(pp.x - x) > 1 or absi(pp.y - y) > 1:
		rpc_id(peer_id, "rpc_receive_chat", "system", "", "Too far away to use.")
		return
	# Check for container at this position first
	var cid: int = containers.get_container_at(pos)
	if cid >= 0:
		containers.handle_open_container(peer_id, cid)
		return
	tile_actions.check_use_action(peer_id, pos)

## Takes an item from a container into the player's inventory.
@rpc("any_peer")
func rpc_container_take(container_id: int, item_index: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "container"):
		return
	containers.handle_take_item(peer_id, container_id, item_index)

## Drops an item from a container onto the ground at the given position.
@rpc("any_peer")
func rpc_container_drop_to_ground(container_id: int, item_index: int, x: int, y: int, z: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "container"):
		return
	containers.handle_drop_to_ground(peer_id, container_id, item_index, x, y, z)

## Puts an item from the player's inventory into a container.
@rpc("any_peer")
func rpc_container_put(container_id: int, inv_slot_index: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "container"):
		return
	containers.handle_put_item(peer_id, container_id, inv_slot_index)

## Moves a ground item into a container.
@rpc("any_peer")
func rpc_ground_to_container(container_id: int, x: int, y: int, z: int, item_id: String) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "container"):
		return
	containers.handle_ground_to_container(peer_id, container_id, x, y, z, item_id)

## Moves a container to a new ground position.
@rpc("any_peer")
func rpc_move_container(container_id: int, x: int, y: int, z: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "container"):
		return
	containers.handle_move_container(peer_id, container_id, x, y, z)

## Picks up a ground container into the player's inventory.
@rpc("any_peer")
func rpc_pickup_ground_container(container_id: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "container"):
		return
	containers.handle_pickup_ground_container(peer_id, container_id)

## Requests closing a container window on the client.
@rpc("any_peer")
func rpc_container_close_request(container_id: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "container"):
		return
	containers.handle_close_container(peer_id, container_id)

## Opens the player's equipped backpack container.
@rpc("any_peer")
func rpc_open_backpack() -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "container"):
		return
	containers.handle_open_backpack(peer_id)

## Opens a container item nested inside another container.
@rpc("any_peer")
func rpc_open_item_in_container(parent_cid: int, slot_index: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "container"):
		return
	containers.handle_open_nested_container(peer_id, parent_cid, slot_index)

## Generic item move between any two locations (inventory, container, equipment, ground).
@rpc("any_peer")
func rpc_move_item(from_uid: int, from_index: int, to_uid: int, to_index: int,
		to_x: int, to_y: int, to_z: int, count: int, slot_name: String) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "item"):
		return
	containers.handle_move_item(peer_id,
		from_uid, from_index, to_uid, to_index, to_x, to_y, to_z, count, slot_name)

## Buys an item from the currently open NPC shop.
@rpc("any_peer")
func rpc_shop_buy(item_id: String, count: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "item"):
		return
	npcs.handle_shop_buy(peer_id, item_id, count)

## Sells an item to the currently open NPC shop.
@rpc("any_peer")
func rpc_shop_sell(item_id: String, count: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "item"):
		return
	npcs.handle_shop_sell(peer_id, item_id, count)

## Dispatches respawn request to the combat subsystem.
@rpc("any_peer")
func rpc_request_respawn() -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "general"):
		return
	combat.handle_request_respawn(peer_id)

## Picks up a ground item into the player's inventory.
@rpc("any_peer")
func rpc_pickup_item(x: int, y: int, z: int, item_id: String) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "item"):
		return
	inventory.handle_pickup_item(peer_id, x, y, z, item_id)

## Drops an inventory item at the player's feet.
@rpc("any_peer")
func rpc_drop_item(slot_index: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "item"):
		return
	inventory.handle_drop_item(peer_id, slot_index)

## Drops an inventory item at a specific ground position.
@rpc("any_peer")
func rpc_drop_item_at(slot_index: int, x: int, y: int, z: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "item"):
		return
	inventory.handle_drop_item_at(peer_id, slot_index, x, y, z)

## Moves a ground item from one tile to another.
@rpc("any_peer")
func rpc_move_ground_item(sx: int, sy: int, sz: int, item_id: String, dx: int, dy: int, dz: int, count: int = 0) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "item"):
		return
	inventory.handle_move_ground_item(peer_id, sx, sy, sz, item_id, dx, dy, dz, count)

## Equips an inventory item into the appropriate equipment slot.
@rpc("any_peer")
func rpc_equip_item(slot_index: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "item"):
		return
	inventory.handle_equip_item(peer_id, slot_index)

## Unequips an item from the named equipment slot back to inventory.
@rpc("any_peer")
func rpc_unequip_item(slot_name: String) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "item"):
		return
	inventory.handle_unequip_item(peer_id, slot_name)

## Casts a spell by ID via the spells subsystem.
@rpc("any_peer")
func rpc_cast_spell(spell_id: String) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "spell"):
		return
	spells.handle_cast_spell(peer_id, spell_id)

## Uses a consumable/usable item from the player's inventory.
@rpc("any_peer")
func rpc_use_item(slot_index: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "item"):
		return
	inventory.handle_use_item(peer_id, slot_index)

## Uses a rune from inventory on a target tile position.
@rpc("any_peer")
func rpc_use_rune(slot_index: int, target_x: int, target_y: int, target_z: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "rune"):
		return
	spells.handle_use_rune(peer_id, slot_index, target_x, target_y, target_z)

## Changes the player's outfit and colors via the auth subsystem.
@rpc("any_peer")
func rpc_change_outfit(outfit_id: String, head_color: String, body_color: String, legs_color: String, feet_color: String) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "general"):
		return
	auth.handle_change_outfit(peer_id, outfit_id, head_color, body_color, legs_color, feet_color)

## Handles generic drag-and-drop between inventory/equipment slots.
@rpc("any_peer")
func rpc_drag_drop(source_type: String, source_index: int, _source_slot: String,
		dest_type: String, dest_index: int, _dest_slot: String,
		_dest_x: int, _dest_y: int, _dest_z: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not ratelimit.check(peer_id, "item"):
		return
	inventory.handle_drag_drop(peer_id, source_type, source_index, dest_type, dest_index)


#  SERVER -> CLIENT RPC STUBS
#  Empty bodies required by Godot for multiplayer signature registration.
#  The actual calls are made via rpc_id() from subsystem scripts.

@rpc("any_peer")
func rpc_enter_world(_peer_id: int, _x: int, _y: int, _z: int, _name: String, _speed: int, _outfit: String = "", _gender: String = "male") -> void:
	pass

@rpc("any_peer")
func rpc_player_spawn(_peer_id: int, _x: int, _y: int, _z: int, _name: String, _speed: int, _outfit: String = "") -> void:
	pass

@rpc("any_peer")
func rpc_player_move(_peer_id: int, _x: int, _y: int, _z: int, _step_ms: int = 0) -> void:
	pass

@rpc("any_peer")
func rpc_player_teleport(_peer_id: int, _x: int, _y: int, _z: int) -> void:
	pass

@rpc("any_peer")
func rpc_player_despawn(_peer_id: int) -> void:
	pass

@rpc("any_peer")
func rpc_player_face(_peer_id: int, _direction: int) -> void:
	pass

@rpc("any_peer")
func rpc_receive_chat(_channel: String, _sender: String, _text: String) -> void:
	pass

@rpc("any_peer")
func rpc_entity_spawn(_eid: int, _def_id: String, _name: String, _x: int, _y: int, _z: int, _hp: int, _max_hp: int, _speed: int, _sprite: String = "") -> void:
	pass

@rpc("any_peer")
func rpc_entity_move(_eid: int, _x: int, _y: int, _z: int, _step_ms: int = 0) -> void:
	pass

@rpc("any_peer")
func rpc_entity_face(_eid: int, _direction: int) -> void:
	pass

@rpc("any_peer")
func rpc_entity_despawn(_eid: int) -> void:
	pass

@rpc("any_peer")
func rpc_entity_damage(_eid: int, _damage: int, _type: String, _hp: int, _max_hp: int) -> void:
	pass

@rpc("any_peer")
func rpc_combat_target(_eid: int) -> void:
	pass

@rpc("any_peer")
func rpc_combat_clear() -> void:
	pass

@rpc("any_peer")
func rpc_experience_gain(_amount: int, _x: int, _y: int, _z: int) -> void:
	pass

@rpc("any_peer")
func rpc_player_damage(_peer_id: int, _damage: int, _type: String, _hp: int, _max_hp: int) -> void:
	pass

@rpc("any_peer")
func rpc_player_skull(_peer_id: int, _skull: String) -> void:
	pass

@rpc("any_peer")
func rpc_field_spawn(_x: int, _y: int, _z: int, _field_type: String, _duration: float = 45.0) -> void:
	pass

@rpc("any_peer")
func rpc_field_despawn(_x: int, _y: int, _z: int) -> void:
	pass

@rpc("any_peer")
func rpc_player_death(_xp_loss: int) -> void:
	pass

@rpc("any_peer")
func rpc_respawn_result(_x: int, _y: int, _z: int, _hp: int, _max_hp: int) -> void:
	pass

@rpc("any_peer")
func rpc_stats_update(_hp: int, _max_hp: int, _mana: int, _max_mana: int, _level: int, _xp: int, _xp_next: int) -> void:
	pass

@rpc("any_peer")
func rpc_combat_stats(_attack: int, _defense: int, _armor: int, _weight: float, _max_cap: float, _speed: int = 0, _ground_speed: float = 150.0) -> void:
	pass

@rpc("any_peer")
func rpc_spell_effect(_caster_peer_id: int, _spell_id: String, _x: int, _y: int, _z: int, _value: int) -> void:
	pass

@rpc("any_peer")
func rpc_area_effect(_effect_name: String, _x: int, _y: int, _z: int, _pattern: String, _facing: int) -> void:
	pass

@rpc("any_peer")
func rpc_tile_effect(_effect_name: String, _x: int, _y: int, _z: int) -> void:
	pass

@rpc("any_peer")
func rpc_projectile(_sx: int, _sy: int, _dx: int, _dy: int, _proj_type: String) -> void:
	pass

@rpc("any_peer")
func rpc_login_result(_success: bool, _message: String) -> void:
	pass

@rpc("any_peer")
func rpc_logout_result() -> void:
	pass

@rpc("any_peer")
func rpc_character_list(_characters: Array) -> void:
	pass

@rpc("any_peer")
func rpc_outfit_update(_peer_id: int, _outfit_id: String, _sprites_json: String, _head: String, _body: String, _legs: String, _feet: String) -> void:
	pass

@rpc("any_peer")
func rpc_skills_update(_skills: Array) -> void:
	pass

@rpc("any_peer")
func rpc_spell_fail(_peer_id: int) -> void:
	pass

@rpc("any_peer")
func rpc_status_update(_statuses: Array) -> void:
	pass

@rpc("any_peer")
func rpc_food_timer(_seconds: float) -> void:
	pass

@rpc("any_peer")
func rpc_inventory_update(_items: Array) -> void:
	pass

@rpc("any_peer")
func rpc_ground_item(_x: int, _y: int, _z: int, _item_id: String, _count: int, _present: bool, _sprite: String = "") -> void:
	pass

@rpc("any_peer")
func rpc_equipment_update(_data: Array) -> void:
	pass

@rpc("any_peer")
func rpc_map_chunk(_cx: int, _cy: int, _cz: int, _tiles: Array) -> void:
	pass

@rpc("any_peer")
func rpc_tile_update(_x: int, _y: int, _z: int, _tile_id: int) -> void:
	pass

@rpc("any_peer")
func rpc_container_spawn(_cid: int, _x: int, _y: int, _z: int, _name: String, _sprite: String = "", _is_corpse: bool = false) -> void:
	pass

@rpc("any_peer")
func rpc_container_despawn(_cid: int) -> void:
	pass

@rpc("any_peer")
func rpc_container_sprite(_cid: int, _sprite: String) -> void:
	pass

@rpc("any_peer")
func rpc_container_open(_cid: int, _name: String, _items: Array, _capacity: int = -1, _sprite: String = "") -> void:
	pass

@rpc("any_peer")
func rpc_container_close(_cid: int) -> void:
	pass

@rpc("any_peer")
func rpc_container_move(_cid: int, _x: int, _y: int, _z: int) -> void:
	pass

@rpc("any_peer")
func rpc_npc_dialogue(_npc_name: String, _text: String) -> void:
	pass

@rpc("any_peer")
func rpc_npc_spawn(_npc_id: int, _name: String, _x: int, _y: int, _z: int, _sprite: String = "") -> void:
	pass

@rpc("any_peer")
func rpc_npc_despawn(_npc_id: int) -> void:
	pass

@rpc("any_peer")
func rpc_npc_move(_npc_id: int, _x: int, _y: int, _z: int, _step_ms: int) -> void:
	pass

@rpc("any_peer")
func rpc_shop_open(_npc_name: String, _offers: Array) -> void:
	pass
