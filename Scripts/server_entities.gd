#  server_entities.gd -- Monster spawning/despawning, AI state machine
#  (idle/chase/flee), A* pathfinding, respawn queue, and entity spatial grid
extends Node

const ENTITY_NEARBY_RANGE := 20
const AI_TICK_INTERVAL := 0.15
const MONSTER_RESPAWN_TIME := 10.0
const MONSTER_CHASE_RANGE := 5
const MONSTER_LEASH_RANGE := 8
const DEFAULT_GROUND_SPEED := 150.0

var server: Node = null  # server_main.gd

var _entities: Dictionary = {}        # entity_id -> entity Dictionary
var _next_entity_id: int = 1
var _entity_grid: Dictionary = {}     # "cx_cy" -> Array[entity_id]
var _entity_cells: Dictionary = {}    # entity_id -> "cx_cy"
var _respawn_queue: Array = []


## Creates a new entity from a monster definition and broadcasts it to nearby players.
func spawn_entity(definition_id: String, display_name: String, pos: Vector3i,
		health: int = 100, speed: int = 200,
		experience_reward: int = 0) -> int:
	var eid := _next_entity_id
	_next_entity_id += 1
	# Resolve sprite from monster definition
	var sprite_path: String = ""
	var sprites_json: String = ""
	var monster_def: Dictionary = server.datapacks.get_monster(definition_id)
	var sprites: Dictionary = monster_def.get("sprites", {})
	if not sprites.is_empty():
		sprites_json = JSON.stringify(sprites)
	var idle: Dictionary = sprites.get("idle", {})
	sprite_path = str(idle.get("south", ""))
	var entity := {
		"entity_id": eid,
		"definition_id": definition_id,
		"display_name": display_name,
		"position": pos,
		"spawn_position": pos,
		"health": health,
		"max_health": health,
		"speed": speed,
		"experience_reward": experience_reward,
		"last_move_time": 0.0,
		"ai_state": "idle",
		"ai_target": -1,
		"ai_wait_timer": randf_range(1.0, 4.0),
		"sprite_path": sprite_path,
		"sprites_json": sprites_json,
		# AI data from monster definition
		"ai_behavior": str(monster_def.get("ai_behavior", "aggressive")),
		"detection_range": int(monster_def.get("detection_range", MONSTER_CHASE_RANGE)),
		"run_on_health": int(monster_def.get("run_on_health", 0)),
		"self_healing": monster_def.get("self_healing", {}),
		"abilities": server.datapacks.resolve_monster_abilities(monster_def),
		"melee_skill": int(monster_def.get("melee_skill", 0)),
		"melee_attack": int(monster_def.get("melee_attack", 0)),
		"spawn_radius": 3,
		"last_heal_time": 0.0,
		"_targetchange_interval": float(monster_def.get("targetchange_interval", 4000)),
		"_targetchange_chance": float(monster_def.get("targetchange_chance", 10)),
		"_last_targetchange": 0.0,
	}
	_entities[eid] = entity
	_entity_grid_add(eid, pos)
	for pid in server.get_players_in_range(pos, ENTITY_NEARBY_RANGE):
		server.rpc_id(pid, "rpc_entity_spawn", eid, definition_id, display_name,
			pos.x, pos.y, pos.z, health, health, speed, sprites_json)
	return eid


## Removes an entity from the world and clears any players targeting it.
func despawn_entity(entity_id: int) -> void:
	if not _entities.has(entity_id):
		return
	var ent: Dictionary = _entities[entity_id]
	var pos: Vector3i = ent["position"]
	for pid in server.get_players_in_range(pos, ENTITY_NEARBY_RANGE):
		server.rpc_id(pid, "rpc_entity_despawn", entity_id)
	_entity_grid_remove(entity_id)
	_entities.erase(entity_id)
	for pid in server.combat._combat_targets.keys():
		if server.combat._combat_targets[pid] == entity_id:
			server.combat._combat_targets.erase(pid)
			if server.is_peer_active(pid):
				server.rpc_id(pid, "rpc_combat_clear")


#  AI PROCESSING -- Tibia 7.6/8.0 style
#
#  States: idle, chase, flee
#  - No leash -- monsters chase indefinitely
#  - Hostile monsters auto-aggro players in detection_range
#  - Flee when HP <= run_on_health (run away but still retaliate)
#  - If target unreachable/gone, find new target or go idle
#  - Passive monsters (chicken etc) only flee when attacked, never aggro

const LOSE_INTEREST_RANGE := 15  # Chebyshev distance to lose target

func process_entity_ai(delta: float) -> void:
	## Process AI for all entities -- each entity has its own movement cooldown based on speed.
	var now_ms := Time.get_ticks_msec()
	for eid in _entities:
		var ent: Dictionary = _entities[eid]
		if int(ent.get("health", 0)) <= 0:
			continue

		var ai_state: String = ent.get("ai_state", "idle")

		# Per-entity movement cooldown -- don't move if still in step cooldown
		var last_move: float = float(ent.get("last_move_time", 0.0))
		var last_diag: bool = bool(ent.get("last_move_diagonal", false))
		var spd := maxf(float(ent.get("speed", 200)), 1.0)
		var diag_cost: float = 2.0 if bool(ent.get("last_move_diagonal", false)) else 1.0
		var step_cooldown_ms: float = ceilf(DEFAULT_GROUND_SPEED / spd * diag_cost * 1000.0 / 50.0) * 50.0
		step_cooldown_ms = maxf(step_cooldown_ms, 50.0)
		var can_move: bool = (float(now_ms) - last_move) >= step_cooldown_ms

		var cur: Vector3i = ent["position"]

		# Sleep idle monsters when no player is nearby (same z-level)
		if ai_state == "idle":
			var any_nearby := false
			for pid in server._sessions:
				var s: Dictionary = server._sessions[pid]
				if s.get("is_dead", false):
					continue
				var pp: Vector3i = s["position"]
				if pp.z == cur.z and absi(pp.x - cur.x) <= ENTITY_NEARBY_RANGE and absi(pp.y - cur.y) <= ENTITY_NEARBY_RANGE:
					any_nearby = true
					break
			if not any_nearby:
				continue

		# Skip if still in movement cooldown
		if not can_move:
			continue
		# Store cooldown for use in AI functions
		ent["_step_cooldown_sec"] = step_cooldown_ms / 1000.0

		var spawn: Vector3i = ent["spawn_position"]

		match ai_state:
			"chase":
				_ai_chase(eid, ent, cur, now_ms)
			"flee":
				_ai_flee(eid, ent, cur, now_ms)
			_:
				_ai_idle(eid, ent, cur, spawn, now_ms)

		# Self-healing (any state)
		_ai_try_self_heal(ent, now_ms)


func _ai_idle(eid: int, ent: Dictionary, cur: Vector3i, spawn: Vector3i, now_ms: int) -> void:
	## Idle: hostile monsters scan for targets, then wander.
	var behavior: String = ent.get("ai_behavior", "aggressive")
	# Hostile monsters look for players to aggro
	if behavior != "passive":
		var detection: int = int(ent.get("detection_range", MONSTER_CHASE_RANGE))
		var target_pid: int = _find_nearest_player(cur, detection)
		if target_pid >= 0:
			ent["ai_state"] = "chase"
			ent["ai_target"] = target_pid
			# Set combat lock on the player being chased
			server.combat.set_combat_lock(target_pid)
			return
	# Wander -- cardinal directions only (like Tibia)
	ent["ai_wait_timer"] = float(ent.get("ai_wait_timer", 0.0)) - float(ent.get("_step_cooldown_sec", 0.15))
	if ent["ai_wait_timer"] > 0.0:
		return
	var cardinal := [Vector2i(0,-1), Vector2i(1,0), Vector2i(0,1), Vector2i(-1,0)]
	var dir: Vector2i = cardinal[randi() % 4]
	var target := Vector3i(cur.x + dir.x, cur.y + dir.y, cur.z)
	var wander_range: int = int(ent.get("spawn_radius", 3))
	if absi(target.x - spawn.x) > wander_range or absi(target.y - spawn.y) > wander_range:
		ent["ai_wait_timer"] = randf_range(0.5, 2.0)
		return
	if server.is_tile_blocked_for_entity(target):
		ent["ai_wait_timer"] = randf_range(0.5, 1.5)
		return
	_move_entity(eid, ent, target, now_ms)
	ent["ai_wait_timer"] = randf_range(1.0, 4.0)


## Validates the chase target and moves one step toward it; switches to flee if low HP.
func _ai_chase(eid: int, ent: Dictionary, cur: Vector3i, now_ms: int) -> void:
	var target_pid: int = ent.get("ai_target", -1)

	# Target switching (TFS targetchange: interval + chance)
	# Every few seconds, there's a chance to switch to a different nearby player
	var tc_interval: float = float(ent.get("_targetchange_interval", 4000.0))
	var tc_chance: float = float(ent.get("_targetchange_chance", 10.0))
	var last_tc: float = float(ent.get("_last_targetchange", 0.0))
	if (float(now_ms) - last_tc) >= tc_interval:
		ent["_last_targetchange"] = float(now_ms)
		if randf() * 100.0 < tc_chance:
			var detection: int = int(ent.get("detection_range", MONSTER_CHASE_RANGE))
			var new_target: int = _find_nearest_player(cur, detection)
			if new_target >= 0 and new_target != target_pid:
				ent["ai_target"] = new_target
				target_pid = new_target

	# Validate target (also reject orphan/disconnected sessions)
	if target_pid < 0 or not server._sessions.has(target_pid) or server._sessions[target_pid].get("is_dead", false) or server._sessions[target_pid].get("_orphan", false):
		# Target gone -- try to find a new one
		var detection: int = int(ent.get("detection_range", MONSTER_CHASE_RANGE))
		var new_target: int = _find_nearest_player(cur, detection)
		if new_target >= 0:
			ent["ai_target"] = new_target
			target_pid = new_target
		else:
			ent["ai_state"] = "idle"
			ent["ai_target"] = -1
			ent["ai_wait_timer"] = randf_range(1.0, 3.0)
			return

	var pp: Vector3i = server._sessions[target_pid]["position"]
	var dist := maxi(absi(pp.x - cur.x), absi(pp.y - cur.y))

	# Lose interest if target is too far away
	if dist > LOSE_INTEREST_RANGE or pp.z != cur.z:
		# Try to find a closer target first
		var detection: int = int(ent.get("detection_range", MONSTER_CHASE_RANGE))
		var new_target: int = _find_nearest_player(cur, detection)
		if new_target >= 0:
			ent["ai_target"] = new_target
			return
		ent["ai_state"] = "idle"
		ent["ai_target"] = -1
		ent["ai_wait_timer"] = randf_range(1.0, 3.0)
		return

	# Check flee threshold
	var run_hp: int = int(ent.get("run_on_health", 0))
	if run_hp > 0 and int(ent["health"]) <= run_hp:
		ent["ai_state"] = "flee"
		return

	# Adjacent to target -- Tibia "dance" (shuffle around target)
	# TFS uses targetchange: interval (default 4000ms) and chance (default 10%).
	# The dance timer ticks independently from the AI tick rate.
	if dist <= 1:
		var dance_interval: float = float(ent.get("_targetchange_interval", 4000.0))
		var dance_chance: float = float(ent.get("_targetchange_chance", 10.0)) / 100.0
		var last_dance_check: float = float(ent.get("_last_dance_check_ms", 0.0))
		if (float(now_ms) - last_dance_check) < dance_interval:
			return  # Not time to roll yet -- just stand and attack
		ent["_last_dance_check_ms"] = float(now_ms)
		if randf() > dance_chance:
			return  # Failed the roll -- stay put
		var dance_dirs := [Vector2i(0,-1), Vector2i(1,0), Vector2i(0,1), Vector2i(-1,0)]
		dance_dirs.shuffle()
		for d in dance_dirs:
			var candidate := Vector3i(cur.x + d.x, cur.y + d.y, cur.z)
			var new_dist := maxi(absi(pp.x - candidate.x), absi(pp.y - candidate.y))
			if new_dist <= 1 and not server.is_tile_blocked_for_entity(candidate):
				_move_entity(eid, ent, candidate, now_ms)
				return
		return

	# Move toward target
	_move_toward(eid, ent, cur, pp, now_ms)


func _ai_flee(eid: int, ent: Dictionary, cur: Vector3i, now_ms: int) -> void:
	## Run away from target. Stop fleeing if health recovers or target is gone.
	var target_pid: int = ent.get("ai_target", -1)
	var run_hp: int = int(ent.get("run_on_health", 0))

	# Stop fleeing if health recovered above threshold
	if run_hp > 0 and int(ent["health"]) > run_hp:
		ent["ai_state"] = "chase" if target_pid >= 0 else "idle"
		return

	# No target -- go idle
	if target_pid < 0 or not server._sessions.has(target_pid) or server._sessions[target_pid].get("is_dead", false) or server._sessions[target_pid].get("_orphan", false):
		ent["ai_state"] = "idle"
		ent["ai_target"] = -1
		ent["ai_wait_timer"] = randf_range(1.0, 3.0)
		return

	var pp: Vector3i = server._sessions[target_pid]["position"]
	# Move away from target
	var dx := signi(cur.x - pp.x)
	var dy := signi(cur.y - pp.y)
	if dx == 0 and dy == 0:
		dx = randi_range(-1, 1)
		dy = randi_range(-1, 1)
	var target := Vector3i(cur.x + dx, cur.y + dy, cur.z)
	if not server.is_tile_blocked_for_entity(target):
		_move_entity(eid, ent, target, now_ms)
	else:
		# Try perpendicular directions
		var alt1 := Vector3i(cur.x + dy, cur.y - dx, cur.z)
		var alt2 := Vector3i(cur.x - dy, cur.y + dx, cur.z)
		if not server.is_tile_blocked_for_entity(alt1):
			_move_entity(eid, ent, alt1, now_ms)
		elif not server.is_tile_blocked_for_entity(alt2):
			_move_entity(eid, ent, alt2, now_ms)


func _find_nearest_player(pos: Vector3i, max_range: int) -> int:
	## Returns the peer_id of the nearest alive player within range, or -1.
	var best_pid: int = -1
	var best_dist: int = max_range + 1
	for pid in server._sessions:
		var s: Dictionary = server._sessions[pid]
		if s.get("is_dead", false):
			continue
		var pp: Vector3i = s["position"]
		if pp.z != pos.z:
			continue
		var dist := maxi(absi(pp.x - pos.x), absi(pp.y - pos.y))
		if dist <= max_range and dist < best_dist:
			best_dist = dist
			best_pid = pid
	return best_pid


const PATHFIND_MAX_DEPTH := 10  # Max A* search distance

func _move_toward(eid: int, ent: Dictionary, cur: Vector3i, goal: Vector3i, now_ms: int) -> void:
	## Move one step toward goal. Prioritizes closing the largest axis gap first.
	## Uses greedy approach for short distances, A* for longer paths.
	var dist := maxi(absi(goal.x - cur.x), absi(goal.y - cur.y))
	var dx := signi(goal.x - cur.x)
	var dy := signi(goal.y - cur.y)
	var abs_dx := absi(goal.x - cur.x)
	var abs_dy := absi(goal.y - cur.y)

	# Short distance (≤3): greedy approach
	if dist <= 3:
		if dx != 0 and dy != 0:
			# Diagonal needed -- prioritize the axis with the LARGER gap
			# This prevents mirroring the player's lateral movement
			var first_dir: Vector3i
			var second_dir: Vector3i
			if abs_dy >= abs_dx:
				# Y gap is larger -- close Y first, then X
				first_dir = Vector3i(cur.x, cur.y + dy, cur.z)
				second_dir = Vector3i(cur.x + dx, cur.y, cur.z)
			else:
				# X gap is larger -- close X first, then Y
				first_dir = Vector3i(cur.x + dx, cur.y, cur.z)
				second_dir = Vector3i(cur.x, cur.y + dy, cur.z)
			if not server.is_tile_blocked_for_entity(first_dir):
				_move_entity(eid, ent, first_dir, now_ms)
				return
			elif not server.is_tile_blocked_for_entity(second_dir):
				_move_entity(eid, ent, second_dir, now_ms)
				return
			# Both cardinal blocked -- try diagonal
			var diag := Vector3i(cur.x + dx, cur.y + dy, cur.z)
			if not server.is_tile_blocked_for_entity(diag):
				_move_entity(eid, ent, diag, now_ms)
				return
		else:
			var target := Vector3i(cur.x + dx, cur.y + dy, cur.z)
			if not server.is_tile_blocked_for_entity(target):
				_move_entity(eid, ent, target, now_ms)
				return
			# Blocked -- try perpendicular
			if dy == 0:
				for py in [-1, 1]:
					var alt := Vector3i(cur.x, cur.y + py, cur.z)
					if not server.is_tile_blocked_for_entity(alt):
						_move_entity(eid, ent, alt, now_ms)
						return
			else:
				for px in [-1, 1]:
					var alt := Vector3i(cur.x + px, cur.y, cur.z)
					if not server.is_tile_blocked_for_entity(alt):
						_move_entity(eid, ent, alt, now_ms)
						return
		return

	# Longer distance: use A*
	var path: Array = _astar_find_path(cur, goal, PATHFIND_MAX_DEPTH)
	if path.size() >= 2:
		var next: Vector3i = path[1]
		if not server.is_tile_blocked_for_entity(next):
			_move_entity(eid, ent, next, now_ms)
			return
	# No path -- try a random cardinal step to unstick
	var dirs := [Vector2i(0,-1), Vector2i(1,0), Vector2i(0,1), Vector2i(-1,0)]
	dirs.shuffle()
	for d in dirs:
		var alt := Vector3i(cur.x + d.x, cur.y + d.y, cur.z)
		if not server.is_tile_blocked_for_entity(alt):
			_move_entity(eid, ent, alt, now_ms)
			return


func _astar_find_path(start: Vector3i, goal: Vector3i, max_depth: int) -> Array:
	## A* pathfinding on the tile grid. Returns Array of Vector3i positions from start to goal.
	## Returns empty array if no path found within max_depth.
	## Allows 8-directional movement (cardinal + diagonal).

	# Quick check: if already adjacent, return direct path
	var direct_dist := maxi(absi(goal.x - start.x), absi(goal.y - start.y))
	if direct_dist <= 1:
		return [start, goal]

	# Open set: priority queue as array of [f_score, g_score, Vector3i pos]
	# Using a simple sorted insert since max_depth keeps the set small
	var open: Array = []
	var closed: Dictionary = {}  # "x_y" -> true
	var came_from: Dictionary = {}  # "x_y" -> Vector3i parent
	var g_scores: Dictionary = {}  # "x_y" -> int

	var start_key := "%d_%d" % [start.x, start.y]
	g_scores[start_key] = 0
	var h: int = _heuristic(start, goal)
	open.append([h, 0, start])

	# Cardinal directions first (preferred), then diagonal (only when necessary)
	var directions := [
		Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0),
		Vector2i(1, -1), Vector2i(1, 1), Vector2i(-1, 1), Vector2i(-1, -1),
	]

	while not open.is_empty():
		# Pop lowest f_score
		var current_entry: Array = open[0]
		open.remove_at(0)
		var current_g: int = int(current_entry[1])
		var current: Vector3i = current_entry[2]
		var current_key := "%d_%d" % [current.x, current.y]

		if closed.has(current_key):
			continue
		closed[current_key] = true

		# Reached goal (or adjacent to goal -- good enough for melee)
		if maxi(absi(current.x - goal.x), absi(current.y - goal.y)) <= 1:
			return _reconstruct_path(came_from, start, current)

		# Depth limit
		if current_g >= max_depth:
			continue

		for dir in directions:
			var nx: int = current.x + dir.x
			var ny: int = current.y + dir.y
			var neighbor := Vector3i(nx, ny, start.z)
			var neighbor_key := "%d_%d" % [nx, ny]

			if closed.has(neighbor_key):
				continue

			# Check if tile is walkable (skip the goal tile itself -- we want to get adjacent)
			if neighbor != goal and server.is_tile_blocked_for_entity(neighbor):
				continue

			# Diagonal movement cost: 3 for diagonal, 1 for cardinal
			# Higher diagonal cost strongly prefers cardinal paths (Tibia-like behavior)
			var move_cost: int = 3 if (dir.x != 0 and dir.y != 0) else 1
			var tentative_g: int = current_g + move_cost

			if g_scores.has(neighbor_key) and tentative_g >= int(g_scores[neighbor_key]):
				continue

			g_scores[neighbor_key] = tentative_g
			came_from[neighbor_key] = current
			var f: int = tentative_g + _heuristic(neighbor, goal)

			# Sorted insert by f_score
			var inserted := false
			for i in range(open.size()):
				if f < int(open[i][0]):
					open.insert(i, [f, tentative_g, neighbor])
					inserted = true
					break
			if not inserted:
				open.append([f, tentative_g, neighbor])

	# No path found
	return []


func _heuristic(a: Vector3i, b: Vector3i) -> int:
	## Chebyshev distance -- matches 8-directional movement
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


## Rebuilds the A* path from came_from map into an ordered Array of positions.
func _reconstruct_path(came_from: Dictionary, start: Vector3i, end: Vector3i) -> Array:
	var path: Array = [end]
	var current := end
	var start_key := "%d_%d" % [start.x, start.y]
	for _i in range(100):  # Safety limit
		var key := "%d_%d" % [current.x, current.y]
		if key == start_key:
			break
		if not came_from.has(key):
			break
		current = came_from[key]
		path.insert(0, current)
	return path


func _ai_try_self_heal(ent: Dictionary, now_ms: int) -> void:
	## Attempt self-healing if the monster has the ability and is damaged.
	var heal_data: Dictionary = ent.get("self_healing", {})
	if heal_data.is_empty():
		return
	if int(ent["health"]) >= int(ent["max_health"]):
		return
	var cd_ms: float = float(heal_data.get("cooldown_seconds", 5.0)) * 1000.0
	var last_heal: float = float(ent.get("last_heal_time", 0.0))
	if (now_ms - last_heal) < cd_ms:
		return
	var chance: float = float(heal_data.get("chance_percent", 10))
	if randf() * 100.0 > chance:
		return
	var heal_min: int = int(heal_data.get("min", 10))
	var heal_max: int = int(heal_data.get("max", 30))
	var heal := randi_range(heal_min, heal_max)
	ent["health"] = mini(int(ent["health"]) + heal, int(ent["max_health"]))
	ent["last_heal_time"] = float(now_ms)
	# Update health bar for nearby players (no floating damage number)
	var pos: Vector3i = ent["position"]
	var eid: int = int(ent["entity_id"])
	for pid in server.get_players_in_range(pos, ENTITY_NEARBY_RANGE):
		server.rpc_id(pid, "rpc_entity_damage", eid, 0, "heal",
			int(ent["health"]), int(ent["max_health"]))


## Moves an entity to a new tile, calculates step duration, and broadcasts the move.
func _move_entity(eid: int, ent: Dictionary, target: Vector3i, now_ms: int) -> void:
	var old_pos: Vector3i = ent["position"]
	var dx: int = absi(target.x - old_pos.x)
	var dy: int = absi(target.y - old_pos.y)
	var is_diag: bool = (dx > 0 and dy > 0)
	ent["last_move_diagonal"] = is_diag
	# Update facing direction based on movement (like players)
	var move_dx: int = target.x - old_pos.x
	var move_dy: int = target.y - old_pos.y
	if absi(move_dy) >= absi(move_dx):
		ent["facing_direction"] = 0 if move_dy < 0 else 2
	else:
		ent["facing_direction"] = 3 if move_dx < 0 else 1
	# Calculate step duration for this move (same formula as players)
	var spd := maxf(float(ent.get("speed", 200)), 1.0)
	var ground_speed: float = DEFAULT_GROUND_SPEED
	if server.map != null:
		ground_speed = server.map.get_ground_speed(target)
	var diag_factor: float = 2.0 if is_diag else 1.0
	var step_sec: float = ground_speed / spd * diag_factor
	var step_ms: float = ceilf(step_sec * 1000.0 / 50.0) * 50.0
	step_ms = maxf(step_ms, 50.0)
	ent["position"] = target
	ent["last_move_time"] = float(now_ms)
	_entity_grid_update(eid, target)
	for pid in server.get_players_in_range(target, ENTITY_NEARBY_RANGE):
		server.rpc_id(pid, "rpc_entity_move", eid, target.x, target.y, target.z, int(step_ms))


#  RESPAWN SYSTEM

## Ticks down respawn timers and re-spawns entities when ready.
func process_respawns(delta: float) -> void:
	var i := _respawn_queue.size() - 1
	while i >= 0:
		_respawn_queue[i]["timer"] -= delta
		if _respawn_queue[i]["timer"] <= 0.0:
			var r: Dictionary = _respawn_queue[i]
			spawn_entity(r["definition_id"], r["display_name"], r["pos"],
				int(r["health"]), int(r["speed"]),
				int(r.get("experience_reward", 0)))
			_respawn_queue.remove_at(i)
		i -= 1


## Enqueues a dead entity for respawn at its original spawn position.
func queue_respawn(ent: Dictionary) -> void:
	_respawn_queue.append({
		"timer": MONSTER_RESPAWN_TIME,
		"definition_id": ent["definition_id"],
		"display_name": ent["display_name"],
		"pos": ent["spawn_position"],
		"health": int(ent["max_health"]),
		"speed": int(ent["speed"]),
		"experience_reward": int(ent.get("experience_reward", 0)),
	})


#  ENTITY SPATIAL GRID

## Registers an entity in the spatial grid at the given position.
func _entity_grid_add(eid: int, pos: Vector3i) -> void:
	var key: String = server.cell_key(pos)
	if not _entity_grid.has(key):
		_entity_grid[key] = []
	_entity_grid[key].append(eid)
	_entity_cells[eid] = key

## Removes an entity from the spatial grid.
func _entity_grid_remove(eid: int) -> void:
	if _entity_cells.has(eid):
		var key: String = _entity_cells[eid]
		if _entity_grid.has(key):
			_entity_grid[key].erase(eid)
		_entity_cells.erase(eid)

## Moves an entity between spatial grid cells if the cell key changed.
func _entity_grid_update(eid: int, new_pos: Vector3i) -> void:
	var new_key: String = server.cell_key(new_pos)
	var old_key: String = _entity_cells.get(eid, "")
	if new_key == old_key:
		return
	_entity_grid_remove(eid)
	_entity_grid_add(eid, new_pos)


func send_entities_on_z(peer_id: int, z: int) -> void:
	## Sends all entities on a z-level to a player.
	for eid in _entities:
		var ent: Dictionary = _entities[eid]
		var ep: Vector3i = ent["position"]
		if ep.z == z:
			server.rpc_id(peer_id, "rpc_entity_spawn", eid, ent["definition_id"], ent["display_name"],
				ep.x, ep.y, ep.z, int(ent["health"]), int(ent["max_health"]), int(ent["speed"]),
				str(ent.get("sprites_json", "")))
