#  server_spells.gd -- Spell casting (heal/wave/area/buff), cooldown/exhaust
#  system, food-based HP/mana regeneration, buff lifecycle, and stat broadcasting
extends Node

const FOOD_REGEN_INTERVAL := 1.0  # Tick every 1 second while food timer > 0
const FOOD_HP_REGEN := 1          # HP per food tick
const FOOD_MANA_REGEN := 1        # Mana per food tick
const FOOD_TIMER_MAX := 1200.0    # 20 minutes max
const ENTITY_NEARBY_RANGE := 20

var server: Node = null  # server_main.gd

var _regen_acc: float = 0.0

# Active buffs: peer_id -> { buff_id -> { "expires_ms": int, ... } }
var _active_buffs: Dictionary = {}

# Spell area patterns loaded from datapacks/spell_areas.json
# Each pattern is a 2D array: 0=empty, 1=affected, 3=caster position
# Patterns are oriented SOUTH (caster at bottom row). Rotated at runtime.
var _area_patterns: Dictionary = {}


## Loads spell area patterns from the JSON datapack.
func _load_area_patterns() -> void:
	var file := FileAccess.open(server.datapacks._resolve_path("res://datapacks/spell_areas.json"), FileAccess.READ)
	if file == null:
		push_warning("server_spells: spell_areas.json not found")
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) == OK and json.data is Dictionary:
		for key in json.data:
			if key.begins_with("_"):
				continue
			_area_patterns[key] = json.data[key]
	file.close()
	print("server_spells: loaded %d area patterns" % _area_patterns.size())


## Resolves a named area pattern into world tile positions.
## The pattern grid uses 3 as the caster origin. 1 = affected tile, 0 = empty.
## facing: 0=N (default/no rotation), 1=E, 2=S, 3=W
## For non-directional spells (circles, crosses), facing is ignored.
func resolve_area_tiles(pattern_name: String, caster_pos: Vector3i, facing: int = 2) -> Array:
	if not _area_patterns.has(pattern_name):
		return []
	var grid: Array = _area_patterns[pattern_name]
	if grid.is_empty():
		return []

	# Find the caster origin (cell with value 3) in the grid
	var origin_row := -1
	var origin_col := -1
	for r in range(grid.size()):
		var row: Array = grid[r]
		for c in range(row.size()):
			if int(row[c]) == 3:
				origin_row = r
				origin_col = c
				break
		if origin_row >= 0:
			break
	if origin_row < 0:
		return []

	# Collect relative offsets (row, col) for all affected cells (value 1 or 3)
	var offsets: Array = []
	for r in range(grid.size()):
		var row: Array = grid[r]
		for c in range(row.size()):
			if int(row[c]) >= 1:
				# In the grid, row 0 is the top (north/forward), increasing row = south
				# Relative: dr = r - origin_row (positive = south), dc = c - origin_col (positive = east)
				var dr: int = r - origin_row
				var dc: int = c - origin_col
				offsets.append(Vector2i(dc, dr))  # (dx_east, dy_south)

	# Rotate offsets based on facing direction
	# Grid is authored facing NORTH (row 0 = forward, caster at bottom row)
	# So facing=0 (North) needs no rotation, facing=2 (South) is 180°
	var tiles: Array = []
	for off in offsets:
		var dx: int = off.x
		var dy: int = off.y
		var world_dx: int = 0
		var world_dy: int = 0
		match facing:
			0:  # North (default, no rotation -- grid already faces north)
				world_dx = dx
				world_dy = dy
			2:  # South (180° rotation)
				world_dx = -dx
				world_dy = -dy
			1:  # East (90° clockwise)
				world_dx = -dy
				world_dy = dx
			3:  # West (90° counter-clockwise)
				world_dx = dy
				world_dy = -dx
		tiles.append(Vector2i(caster_pos.x + world_dx, caster_pos.y + world_dy))
	return tiles

var _spell_defs: Dictionary = {}


## Loads all player spell definitions from datapacks/spells/ subdirectories.
func _load_spell_defs() -> void:
	var base_path: String = server.datapacks._resolve_dir("res://datapacks/spells")
	for group in ["attack", "healing", "support"]:
		var dir_path: String = base_path + "/" + group
		var dir := DirAccess.open(dir_path)
		if dir == null:
			push_warning("server_spells: spell group directory not found: %s" % dir_path)
			continue
		dir.list_dir_begin()
		var file_name := dir.get_next()
		while file_name != "":
			if file_name.ends_with(".json"):
				var file := FileAccess.open(dir_path + "/" + file_name, FileAccess.READ)
				if file:
					var json := JSON.new()
					if json.parse(file.get_as_text()) == OK and json.data is Dictionary:
						var data: Dictionary = json.data
						var words: String = str(data.get("words", ""))
						if not words.is_empty():
							_spell_defs[words] = data
					file.close()
			file_name = dir.get_next()
	print("server_spells: loaded %d player spells" % _spell_defs.size())


## Sends current HP, mana, level, XP, and food timer to the client.
func send_stats(peer_id: int) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	server.rpc_id(peer_id, "rpc_stats_update", int(s["health"]), int(s["max_health"]),
		int(s["mana"]), int(s["max_mana"]),
		int(s["level"]), int(s["experience"]), _xp_for_level(int(s["level"]) + 1))
	server.rpc_id(peer_id, "rpc_food_timer", float(s.get("food_timer", 0.0)))


func _broadcast_spell_fail(peer_id: int) -> void:
	## Broadcasts spell fail (exhaust poof) to all nearby players including the caster.
	if not server._sessions.has(peer_id):
		return
	var pos: Vector3i = server._sessions[peer_id]["position"]
	for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
		server.rpc_id(pid, "rpc_spell_fail", peer_id)


## Returns the cumulative XP required to reach the given level.
func _xp_for_level(level: int) -> int:
	return 50 * level * level


func process_mana_regen(delta: float) -> void:
	## Food-based regeneration only -- no free regen (authentic Tibia).
	_regen_acc += delta
	if _regen_acc < FOOD_REGEN_INTERVAL:
		return
	_regen_acc -= FOOD_REGEN_INTERVAL
	for peer_id in server._sessions:
		var s: Dictionary = server._sessions[peer_id]
		if s.get("is_dead", false):
			continue
		# Only regenerate while food timer is active
		var food_timer: float = float(s.get("food_timer", 0.0))
		if food_timer <= 0.0:
			continue
		s["food_timer"] = maxf(food_timer - FOOD_REGEN_INTERVAL, 0.0)
		var changed := false
		var hp: int = int(s["health"])
		var max_hp: int = int(s["max_health"])
		if hp < max_hp:
			s["health"] = mini(hp + FOOD_HP_REGEN, max_hp)
			changed = true
		var mana: int = int(s["mana"])
		var max_mana: int = int(s["max_mana"])
		if mana < max_mana:
			s["mana"] = mini(mana + FOOD_MANA_REGEN, max_mana)
			changed = true
		if changed:
			send_stats(peer_id)


func handle_cast_spell(peer_id: int, spell_id: String) -> bool:
	## Returns true if the spell was successfully cast.
	if not server._sessions.has(peer_id):
		return false
	var s: Dictionary = server._sessions[peer_id]
	if s.get("is_dead", false):
		return false
	spell_id = spell_id.strip_edges().to_lower()
	if not _spell_defs.has(spell_id):
		return false
	var spell: Dictionary = _spell_defs[spell_id]
	# Check vocation requirement
	var vocations: Array = spell.get("vocations", [])
	var player_voc: String = str(s.get("vocation", "none"))
	if not vocations.is_empty() and not vocations.has(player_voc):
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
			"Your vocation cannot cast this spell.")
		_broadcast_spell_fail(peer_id)
		return false
	# Check magic level requirement (7.6 style -- spells require magic level, not player level)
	var min_ml: int = int(spell.get("min_level", 0))
	var player_ml: int = server.combat.get_skill_level(s, "magic_level")
	if player_ml < min_ml:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
			"You need magic level %d to cast this spell. (You have %d)" % [min_ml, player_ml])
		_broadcast_spell_fail(peer_id)
		return false
	var mana_cost: int = int(spell["mana_cost"])
	if int(s["mana"]) < mana_cost:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Not enough mana.")
		_broadcast_spell_fail(peer_id)
		return false
	var now_ms := Time.get_ticks_msec()
	var cooldowns: Dictionary = s["spell_cooldowns"]
	# Global exhaust -- no spell can be cast while exhausted
	var global_exhaust: float = float(cooldowns.get("_global", 0.0))
	if now_ms < global_exhaust:
		_broadcast_spell_fail(peer_id)
		return false
	# Group cooldown -- attack vs heal
	var spell_type: String = spell.get("type", "")
	var is_heal: bool = (spell_type == "heal" or spell_type == "area_heal")
	var group_key: String = "_group_heal" if is_heal else "_group_attack"
	var group_exhaust: float = float(cooldowns.get(group_key, 0.0))
	if now_ms < group_exhaust:
		_broadcast_spell_fail(peer_id)
		return false
	s["mana"] = int(s["mana"]) - mana_cost
	# Set global exhaust (1s for heals, 1.5s for attacks)
	var exhaust_ms: float = 1000.0 if is_heal else 1500.0
	cooldowns["_global"] = float(now_ms) + exhaust_ms
	# Set group cooldown
	var group_cd_ms: float = 1000.0 if is_heal else 1500.0
	cooldowns[group_key] = float(now_ms) + group_cd_ms
	# Per-spell cooldown (from spell definition)
	cooldowns[spell_id] = float(now_ms) + float(spell["cooldown"]) * 1000.0
	# Advance magic level -- each mana point spent = 1 try (Tibia 7.6 formula)
	server.combat.advance_skill(peer_id, "magic_level", mana_cost)
	# Set combat lock only for attack spells (not heals, buffs, or conjures)
	var attack_types := ["wave", "area"]
	if spell_type in attack_types:
		server.combat.set_combat_lock(peer_id)
	var pos: Vector3i = s["position"]
	match spell_type:
		"heal":
			_cast_heal(peer_id, s, spell, spell_id, pos)
		"wave":
			_cast_wave(peer_id, s, spell, spell_id, pos)
		"buff":
			_cast_buff(peer_id, s, spell, spell_id, pos)
		"area_heal":
			_cast_area_heal(peer_id, s, spell, spell_id, pos)
		"area":
			_cast_area_damage(peer_id, s, spell, spell_id, pos)
		"conjure":
			_cast_conjure(peer_id, s, spell, spell_id, pos)
		"heal_friend":
			_cast_heal_friend(peer_id, s, spell, spell_id, pos)
		"find_person":
			_cast_find_person(peer_id, s, spell, spell_id, pos)
		"create_food":
			_cast_create_food(peer_id, s, spell, spell_id, pos)
		"cure_condition":
			_cast_cure_condition(peer_id, s, spell, spell_id, pos)
	send_stats(peer_id)
	return true


## Heals the caster based on spell values plus a magic-level bonus.
## Calculates spell min/max values using TFS formula: (level/5) + (maglevel * factor) + base.
## If the spell has formula fields, uses those. Otherwise falls back to static heal_min/heal_max
## or damage_min/damage_max for backward compatibility.
func _calc_formula(spell: Dictionary, level: int, ml: int, is_heal: bool) -> Array:
	var has_formula: bool = spell.has("formula_ml_min") or spell.has("formula_ml_max")
	if has_formula:
		var lvl_factor: float = float(spell.get("formula_lvl", 0.2))  # default level/5
		var ml_min: float = float(spell.get("formula_ml_min", 1.0))
		var ml_max: float = float(spell.get("formula_ml_max", 2.0))
		var base_min: float = float(spell.get("formula_base_min", 0))
		var base_max: float = float(spell.get("formula_base_max", 0))
		var calc_min: int = int(float(level) * lvl_factor + float(ml) * ml_min + base_min)
		var calc_max: int = int(float(level) * lvl_factor + float(ml) * ml_max + base_max)
		return [calc_min, maxi(calc_max, calc_min + 1)]
	# Fallback to static values
	if is_heal:
		return [int(spell.get("heal_min", 10)), int(spell.get("heal_max", 20))]
	return [int(spell.get("damage_min", 10)), int(spell.get("damage_max", 20))]


func _cast_heal(peer_id: int, s: Dictionary, spell: Dictionary, spell_id: String, pos: Vector3i) -> void:
	var ml: int = server.combat.get_skill_level(s, "magic_level")
	var level: int = int(s.get("level", 1))
	var vals: Array = _calc_formula(spell, level, ml, true)
	var heal := randi_range(vals[0], vals[1])
	s["health"] = mini(int(s["health"]) + heal, int(s["max_health"]))
	server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
		"You healed for %d HP." % heal)
	for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
		server.rpc_id(pid, "rpc_spell_effect", peer_id, spell_id, pos.x, pos.y, pos.z, heal)
		# Broadcast updated HP so other players' health bar overlays update
		server.rpc_id(pid, "rpc_player_damage", peer_id, 0, "heal",
			int(s["health"]), int(s["max_health"]))


## Fires a directional wave/area that damages all entities in the pattern.
func _cast_wave(peer_id: int, _s: Dictionary, spell: Dictionary, spell_id: String, pos: Vector3i) -> void:
	var facing: int = _s.get("facing_direction", 2)  # 0=N, 1=E, 2=S, 3=W
	var ml: int = server.combat.get_skill_level(_s, "magic_level")
	var level: int = int(_s.get("level", 1))
	var vals: Array = _calc_formula(spell, level, ml, false)
	var dmg_min: int = vals[0]
	var dmg_max: int = vals[1]
	var element: String = str(spell.get("damage_element", "physical"))

	# Resolve affected tiles from area pattern
	var pattern_name: String = str(spell.get("area_pattern", ""))
	var wave_tiles: Array = []
	if not pattern_name.is_empty():
		wave_tiles = resolve_area_tiles(pattern_name, pos, facing)
	else:
		# Legacy fallback: simple cone expansion
		var length: int = int(spell.get("length", 5))
		var half_w: int = int(spell.get("width", 3)) / 2
		for step in range(1, length + 1):
			@warning_ignore("integer_division")
			var spread: int = (half_w * step) / length
			for offset in range(-spread, spread + 1):
				var tx: int = pos.x
				var ty: int = pos.y
				match facing:
					0: tx += offset; ty -= step
					1: tx += step; ty += offset
					2: tx += offset; ty += step
					3: tx -= step; ty += offset
				wave_tiles.append(Vector2i(tx, ty))

	# Damage entities in wave area
	for eid in server.entities._entities.keys():
		if not server.entities._entities.has(eid):
			continue
		var ent: Dictionary = server.entities._entities[eid]
		if int(ent.get("health", 0)) <= 0:
			continue
		var ep: Vector3i = ent["position"]
		if ep.z != pos.z:
			continue
		if not wave_tiles.has(Vector2i(ep.x, ep.y)):
			continue
		var damage := randi_range(dmg_min, dmg_max)
		ent["health"] = maxi(int(ent["health"]) - damage, 0)
		# Track damage for XP split
		if damage > 0:
			if not ent.has("_damage_map"):
				ent["_damage_map"] = {}
			ent["_damage_map"][peer_id] = int(ent["_damage_map"].get(peer_id, 0)) + damage
		if ent.get("ai_state", "idle") != "chase" and ent.get("ai_state", "idle") != "flee":
			var behavior: String = ent.get("ai_behavior", "aggressive")
			if behavior == "passive":
				ent["ai_state"] = "flee"
				ent["ai_target"] = peer_id
			else:
				ent["ai_state"] = "chase"
				ent["ai_target"] = peer_id
		for pid in server.get_players_in_range(ep, ENTITY_NEARBY_RANGE):
			server.rpc_id(pid, "rpc_entity_damage", eid, damage, element,
				int(ent["health"]), int(ent["max_health"]))
		if int(ent["health"]) <= 0:
			server.combat._on_entity_death(eid, peer_id)

	# Damage players in wave area (PvP)
	for pid in server._sessions:
		if pid == peer_id:
			continue  # Don't hit yourself
		var ps: Dictionary = server._sessions[pid]
		if ps.get("is_dead", false) or ps.get("_orphan", false):
			continue
		var pp: Vector3i = ps["position"]
		if pp.z != pos.z:
			continue
		if not wave_tiles.has(Vector2i(pp.x, pp.y)):
			continue
		var damage := randi_range(dmg_min, dmg_max)
		damage = server.pvp.scale_pvp_damage(damage)
		server.pvp.on_pvp_attack(peer_id, pid)
		server.combat.set_combat_lock(peer_id)
		server.combat.damage_player(pid, damage, element)

	# Send projectile if spell has one (strike spells)
	var proj_type: String = str(spell.get("projectile", ""))
	if not proj_type.is_empty() and not wave_tiles.is_empty():
		# Projectile flies from caster to the first affected tile
		var target_tile: Vector2i = wave_tiles[0]
		for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
			server.rpc_id(pid, "rpc_projectile", pos.x, pos.y, int(target_tile.x), int(target_tile.y), proj_type)
	# Send per-tile visual effects for the wave pattern
	# Use spell-defined tile_effect if available, otherwise fall back to element mapping
	var tile_effect: String = str(spell.get("tile_effect", ""))
	if tile_effect.is_empty():
		var effect_map := {"fire": "fire_effect", "energy": "energy_effect", "earth": "poison_effect",
			"ice": "energy_effect", "death": "death_effect", "holy": "energy_effect", "physical": "hit_physical"}
		tile_effect = effect_map.get(element, "hit_physical")
	for tile in wave_tiles:
		# Skip the caster's own tile -- don't show damage effect where the caster stands
		if int(tile.x) == pos.x and int(tile.y) == pos.y:
			continue
		for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
			server.rpc_id(pid, "rpc_tile_effect", tile_effect, int(tile.x), int(tile.y), pos.z)
	# Send spell cast notification
	for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
		server.rpc_id(pid, "rpc_spell_effect", peer_id, spell_id, pos.x, pos.y, pos.z, facing)
	server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
		"You cast %s!" % spell["name"])


## Applies a timed buff (e.g. haste) to the caster.
func _cast_buff(peer_id: int, s: Dictionary, spell: Dictionary, spell_id: String, pos: Vector3i) -> void:
	var buff_id: String = spell.get("buff_id", "")
	var duration_ms: int = int(spell.get("duration_ms", 10000))
	var now_ms := Time.get_ticks_msec()

	if not _active_buffs.has(peer_id):
		_active_buffs[peer_id] = {}

	# Apply buff
	_active_buffs[peer_id][buff_id] = {
		"expires_ms": now_ms + duration_ms,
		"speed_bonus": int(spell.get("speed_bonus", 0)),
	}

	# Apply speed bonus immediately
	if buff_id == "haste":
		var base_speed: int = int(s.get("base_speed", s.get("speed", 220)))
		if not s.has("base_speed"):
			s["base_speed"] = int(s["speed"])
		s["speed"] = int(s["base_speed"]) + int(spell.get("speed_bonus", 0))

	server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
		"You cast %s! (%.0fs)" % [spell["name"], duration_ms / 1000.0])
	server.inventory.send_combat_stats(peer_id)
	server.combat.send_status(peer_id)

	# Send effect to nearby players
	for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
		server.rpc_id(pid, "rpc_spell_effect", peer_id, spell_id, pos.x, pos.y, pos.z, 0)


## Damages all entities within an area pattern or radius around the caster.
func _cast_area_damage(peer_id: int, _s: Dictionary, spell: Dictionary, spell_id: String, pos: Vector3i) -> void:
	var ml: int = server.combat.get_skill_level(_s, "magic_level")
	var level: int = int(_s.get("level", 1))
	var vals: Array = _calc_formula(spell, level, ml, false)
	var dmg_min: int = vals[0]
	var dmg_max: int = vals[1]
	var element: String = str(spell.get("damage_element", "fire"))

	# Resolve affected tiles from area pattern or radius fallback
	var pattern_name: String = str(spell.get("area_pattern", ""))
	var use_pattern := not pattern_name.is_empty()
	var area_tiles: Array = []
	if use_pattern:
		area_tiles = resolve_area_tiles(pattern_name, pos, _s.get("facing_direction", 2))

	# Hit all entities in area
	for eid in server.entities._entities.keys():
		if not server.entities._entities.has(eid):
			continue
		var ent: Dictionary = server.entities._entities[eid]
		if int(ent.get("health", 0)) <= 0:
			continue
		var ep: Vector3i = ent["position"]
		if ep.z != pos.z:
			continue
		if use_pattern:
			if not area_tiles.has(Vector2i(ep.x, ep.y)):
				continue
		else:
			var area_range: int = int(spell.get("range", 3))
			if absi(ep.x - pos.x) > area_range or absi(ep.y - pos.y) > area_range:
				continue
		var damage := randi_range(dmg_min, dmg_max)
		ent["health"] = maxi(int(ent["health"]) - damage, 0)
		# Track damage for XP split
		if damage > 0:
			if not ent.has("_damage_map"):
				ent["_damage_map"] = {}
			ent["_damage_map"][peer_id] = int(ent["_damage_map"].get(peer_id, 0)) + damage
		if ent.get("ai_state", "idle") != "chase" and ent.get("ai_state", "idle") != "flee":
			var behavior: String = ent.get("ai_behavior", "aggressive")
			if behavior == "passive":
				ent["ai_state"] = "flee"
				ent["ai_target"] = peer_id
			else:
				ent["ai_state"] = "chase"
				ent["ai_target"] = peer_id
		for pid in server.get_players_in_range(ep, ENTITY_NEARBY_RANGE):
			server.rpc_id(pid, "rpc_entity_damage", eid, damage, element,
				int(ent["health"]), int(ent["max_health"]))
		if int(ent["health"]) <= 0:
			server.combat._on_entity_death(eid, peer_id)

	# Hit players in area (PvP)
	for pid in server._sessions:
		if pid == peer_id:
			continue
		var ps: Dictionary = server._sessions[pid]
		if ps.get("is_dead", false) or ps.get("_orphan", false):
			continue
		var pp: Vector3i = ps["position"]
		if pp.z != pos.z:
			continue
		if use_pattern:
			if not area_tiles.has(Vector2i(pp.x, pp.y)):
				continue
		else:
			var area_range: int = int(spell.get("range", 3))
			if absi(pp.x - pos.x) > area_range or absi(pp.y - pos.y) > area_range:
				continue
		var damage := randi_range(dmg_min, dmg_max)
		damage = server.pvp.scale_pvp_damage(damage)
		server.pvp.on_pvp_attack(peer_id, pid)
		server.combat.set_combat_lock(peer_id)
		server.combat.damage_player(pid, damage, element)

	# Send effect
	for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
		server.rpc_id(pid, "rpc_spell_effect", peer_id, spell_id, pos.x, pos.y, pos.z, 0)
	server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
		"You cast %s!" % spell["name"])


## Conjures runes: consumes a blank rune from inventory and creates charged rune items.
## Requires a "blankrune" in the player's backpack. Creates conjure_id x conjure_count.
func _cast_conjure(peer_id: int, s: Dictionary, spell: Dictionary, _spell_id: String, pos: Vector3i) -> void:
	var conjure_id: String = str(spell.get("conjure_id", ""))
	var conjure_count: int = int(spell.get("conjure_count", 1))
	var reagent_id: String = str(spell.get("reagent_id", "blankrune"))

	if conjure_id.is_empty():
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Spell has no conjure target.")
		return

	# Check for reagent (blank rune) in inventory
	var inv: Array = s["inventory"]
	var reagent_index: int = -1
	if not reagent_id.is_empty():
		for i in range(inv.size()):
			if str(inv[i]["item_id"]) == reagent_id:
				reagent_index = i
				break
		if reagent_index < 0:
			var reagent_name: String = server.datapacks.get_item_name(reagent_id)
			server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
				"You need a %s to conjure this." % reagent_name)
			_broadcast_spell_fail(peer_id)
			# Refund mana since we already deducted it
			s["mana"] = int(s["mana"]) + int(spell["mana_cost"])
			return

	# Consume the reagent
	if reagent_index >= 0:
		var slot: Dictionary = inv[reagent_index]
		if int(slot["count"]) <= 1:
			inv.remove_at(reagent_index)
		else:
			slot["count"] = int(slot["count"]) - 1

	# Add conjured items to inventory (drops at feet if full)
	var added: int = server.inventory.give_item(peer_id, conjure_id, conjure_count)

	server.inventory.send_inventory(peer_id)
	var item_name: String = server.datapacks.get_item_name(conjure_id)
	server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
		"You conjured %d %s." % [added, item_name])

	# Play effect on caster
	for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
		server.rpc_id(pid, "rpc_spell_effect", peer_id, _spell_id, pos.x, pos.y, pos.z, 0)


## Heals another player within range. Target is the nearest player in the caster's facing direction.
func _cast_heal_friend(peer_id: int, s: Dictionary, spell: Dictionary, spell_id: String, pos: Vector3i) -> void:
	var ml: int = server.combat.get_skill_level(s, "magic_level")
	var level: int = int(s.get("level", 1))
	var vals: Array = _calc_formula(spell, level, ml, true)
	var heal_range: int = int(spell.get("range", 7))

	# Find the nearest other player within range
	var best_pid: int = -1
	var best_dist: int = 999
	for pid in server._sessions:
		if pid == peer_id:
			continue
		var ps: Dictionary = server._sessions[pid]
		if ps.get("is_dead", false) or ps.get("_orphan", false):
			continue
		var pp: Vector3i = ps["position"]
		if pp.z != pos.z:
			continue
		var dist: int = maxi(absi(pp.x - pos.x), absi(pp.y - pos.y))
		if dist <= heal_range and dist < best_dist:
			best_dist = dist
			best_pid = pid

	if best_pid < 0:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "No player in range to heal.")
		# Refund mana
		s["mana"] = int(s["mana"]) + int(spell["mana_cost"])
		_broadcast_spell_fail(peer_id)
		return

	var ts: Dictionary = server._sessions[best_pid]
	var heal := randi_range(vals[0], vals[1])
	ts["health"] = mini(int(ts["health"]) + heal, int(ts["max_health"]))
	send_stats(best_pid)

	server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
		"You healed %s for %d HP." % [ts["display_name"], heal])
	server.rpc_id(best_pid, "rpc_receive_chat", "system", "",
		"%s healed you for %d HP." % [s["display_name"], heal])

	var tp: Vector3i = ts["position"]
	for pid in server.get_players_in_range(tp, server.NEARBY_RANGE):
		server.rpc_id(pid, "rpc_spell_effect", peer_id, spell_id, tp.x, tp.y, tp.z, heal)


## Tells the caster the direction and approximate distance to another player.
func _cast_find_person(peer_id: int, s: Dictionary, spell: Dictionary, spell_id: String, pos: Vector3i) -> void:
	# Get target name from spell parameter (e.g., exiva "GM Kebs")
	var target_name: String = str(s.get("_spell_param", "")).strip_edges()

	if target_name.is_empty():
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
			"Usage: exiva \"player name\"")
		# Refund mana
		s["mana"] = int(s["mana"]) + int(spell["mana_cost"])
		_broadcast_spell_fail(peer_id)
		return

	# Find the player by name (case-insensitive)
	var best_pid: int = -1
	for pid in server._sessions:
		if pid == peer_id:
			continue
		var ps: Dictionary = server._sessions[pid]
		if ps.get("_orphan", false):
			continue
		if str(ps.get("display_name", "")).to_lower() == target_name.to_lower():
			best_pid = pid
			break

	if best_pid < 0:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
			"%s is not online." % target_name)
		return

	var ts: Dictionary = server._sessions[best_pid]
	var tp: Vector3i = ts["position"]
	var dx: int = tp.x - pos.x
	var dy: int = tp.y - pos.y

	# Determine direction
	var direction: String = ""
	if absi(dy) > 2:
		direction += "north" if dy < 0 else "south"
	if absi(dx) > 2:
		if not direction.is_empty():
			direction += "-"
		direction += "east" if dx > 0 else "west"
	if direction.is_empty():
		direction = "right here"

	# Determine distance description
	var dist: float = sqrt(float(dx * dx + dy * dy))
	var dist_desc: String
	if dist < 5:
		dist_desc = "is standing next to you"
	elif dist < 30:
		dist_desc = "is to the %s" % direction
	elif dist < 100:
		dist_desc = "is far to the %s" % direction
	else:
		dist_desc = "is very far to the %s" % direction

	# Different floor
	if tp.z != pos.z:
		if tp.z < pos.z:
			dist_desc += " (higher floor)"
		else:
			dist_desc += " (lower floor)"

	server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
		"%s %s." % [ts["display_name"], dist_desc])

	for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
		server.rpc_id(pid, "rpc_spell_effect", peer_id, spell_id, pos.x, pos.y, pos.z, 0)


## Creates food items in the caster's inventory.
func _cast_create_food(peer_id: int, s: Dictionary, spell: Dictionary, spell_id: String, pos: Vector3i) -> void:
	var food_items: Array = ["meat", "ham", "bread", "cheese", "apple"]
	var food_id: String = food_items[randi() % food_items.size()]
	var count: int = int(spell.get("conjure_count", 1))

	var added: int = server.inventory.give_item(peer_id, food_id, count)
	server.inventory.send_inventory(peer_id)

	var item_name: String = server.datapacks.get_item_name(food_id)
	server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
		"You conjured %d %s." % [added, item_name])

	for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
		server.rpc_id(pid, "rpc_spell_effect", peer_id, spell_id, pos.x, pos.y, pos.z, 0)


## Cures a specific condition (poison, burning, etc.) from the caster.
func _cast_cure_condition(peer_id: int, s: Dictionary, spell: Dictionary, spell_id: String, pos: Vector3i) -> void:
	var cure_target: String = str(spell.get("cure_condition", "poisoned"))
	if server.combat.has_condition(peer_id, cure_target):
		server.combat.remove_condition(peer_id, cure_target)
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
			"You have been cured of %s." % cure_target)
	else:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
			"You are not %s." % cure_target)

	for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
		server.rpc_id(pid, "rpc_spell_effect", peer_id, spell_id, pos.x, pos.y, pos.z, 0)


## Handles using a rune item on a target tile. Consumes 1 charge and applies the effect.
func handle_use_rune(peer_id: int, slot_index: int, tx: int, ty: int, tz: int) -> void:
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
	var item_def: Dictionary = server.datapacks.get_item(item_id)
	if str(item_def.get("item_type", "")) != "rune":
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "That's not a rune.")
		return

	# Check range (max 7 tiles like in Tibia)
	var pos: Vector3i = s["position"]
	var target := Vector3i(tx, ty, tz)
	if absi(tx - pos.x) > 7 or absi(ty - pos.y) > 7 or tz != pos.z:
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Too far away.")
		return

	# Check cooldown (global exhaust)
	var now_ms := Time.get_ticks_msec()
	var cooldowns: Dictionary = s["spell_cooldowns"]
	var global_exhaust: float = float(cooldowns.get("_global", 0.0))
	if now_ms < global_exhaust:
		return

	# Consume 1 rune charge
	var count: int = int(slot["count"])
	if count <= 1:
		inv.remove_at(slot_index)
	else:
		slot["count"] = count - 1

	# Set exhaust
	cooldowns["_global"] = float(now_ms) + 1500.0
	cooldowns["_group_attack"] = float(now_ms) + 1500.0

	# Resolve rune effect based on item_id
	var rune_effect: Dictionary = item_def.get("rune_effect", {})
	var effect_type: String = str(rune_effect.get("type", "damage"))
	var element: String = str(rune_effect.get("element", "physical"))
	var pattern_name: String = str(rune_effect.get("area_pattern", ""))
	var is_targeted: bool = bool(rune_effect.get("target", true))

	# Calculate rune damage using TFS formula if available, otherwise static values
	var ml: int = server.combat.get_skill_level(s, "magic_level")
	var level: int = int(s.get("level", 1))
	var min_dmg: int
	var max_dmg: int
	if rune_effect.has("formula_ml_min"):
		var vals: Array = _calc_formula(rune_effect, level, ml, false)
		min_dmg = vals[0]
		max_dmg = vals[1]
	else:
		min_dmg = int(rune_effect.get("min_damage", 10))
		max_dmg = int(rune_effect.get("max_damage", 50))
		@warning_ignore("integer_division")
		var ml_bonus: int = ml / 5
		min_dmg += ml_bonus
		max_dmg += ml_bonus

	match effect_type:
		"damage":
			# Resolve affected tiles
			var tiles: Array = []
			if not pattern_name.is_empty():
				var facing: int = s.get("facing_direction", 2)
				tiles = resolve_area_tiles(pattern_name, target, facing)
			else:
				tiles = [Vector2i(tx, ty)]

			# Send projectile from caster to target
			var proj_type: String = str(rune_effect.get("projectile", element))
			if not proj_type.is_empty():
				for pid in server.get_players_in_range(pos, ENTITY_NEARBY_RANGE):
					server.rpc_id(pid, "rpc_projectile", pos.x, pos.y, tx, ty, proj_type)

			# Show tile effects
			var tile_effect: String = str(rune_effect.get("area_effect", "fire_effect"))
			for tile in tiles:
				for pid in server.get_players_in_range(target, ENTITY_NEARBY_RANGE):
					server.rpc_id(pid, "rpc_tile_effect", tile_effect, int(tile.x), int(tile.y), tz)

			# Damage entities in area
			for eid in server.entities._entities.keys():
				if not server.entities._entities.has(eid):
					continue
				var ent: Dictionary = server.entities._entities[eid]
				if int(ent.get("health", 0)) <= 0:
					continue
				var ep: Vector3i = ent["position"]
				if ep.z != tz:
					continue
				if not tiles.has(Vector2i(ep.x, ep.y)):
					continue
				var damage := randi_range(min_dmg, max_dmg)
				ent["health"] = maxi(int(ent["health"]) - damage, 0)
				# Track damage for XP split
				if damage > 0:
					if not ent.has("_damage_map"):
						ent["_damage_map"] = {}
					ent["_damage_map"][peer_id] = int(ent["_damage_map"].get(peer_id, 0)) + damage
				for pid in server.get_players_in_range(ep, ENTITY_NEARBY_RANGE):
					server.rpc_id(pid, "rpc_entity_damage", eid, damage, element,
						int(ent["health"]), int(ent["max_health"]))
				if int(ent["health"]) <= 0:
					server.combat._on_entity_death(eid, peer_id)

		"heal":
			# Heal runes target a player (self or other)
			var heal_min: int
			var heal_max: int
			if rune_effect.has("formula_ml_min"):
				var hvals: Array = _calc_formula(rune_effect, level, ml, true)
				heal_min = hvals[0]
				heal_max = hvals[1]
			else:
				heal_min = int(rune_effect.get("min_heal", 50))
				heal_max = int(rune_effect.get("max_heal", 100))
				@warning_ignore("integer_division")
				heal_min += ml / 5
				@warning_ignore("integer_division")
				heal_max += ml / 5
			# Find player at target tile (or self if on own tile)
			var heal_target: int = -1
			for pid in server._sessions:
				var ps: Dictionary = server._sessions[pid]
				if ps["position"] == target and not ps.get("is_dead", false):
					heal_target = pid
					break
			if heal_target >= 0:
				var ts: Dictionary = server._sessions[heal_target]
				var heal := randi_range(heal_min, heal_max)
				ts["health"] = mini(int(ts["health"]) + heal, int(ts["max_health"]))
				server.spells.send_stats(heal_target)
				for pid in server.get_players_in_range(target, ENTITY_NEARBY_RANGE):
					server.rpc_id(pid, "rpc_spell_effect", peer_id, "exura", tx, ty, tz, heal)

		"field":
			# Place a field tile (fire/poison/energy field, wall, bomb)
			var field_type: String = str(rune_effect.get("field_type", item_id))
			var field_element: String = str(rune_effect.get("element", "fire"))
			var field_damage: int = int(rune_effect.get("field_damage", 20))
			var field_duration: float = float(rune_effect.get("field_duration", 45.0))
			var field_pattern: String = str(rune_effect.get("area_pattern", ""))
			var is_wall: bool = (field_type == "magic_wall")
			if is_wall:
				field_damage = 0
				field_duration = 20.0
			if not field_pattern.is_empty():
				# Bomb or pattern placement
				server.fields.place_field_pattern(target, field_pattern, field_type,
					field_element, field_damage, field_duration, peer_id, s.get("facing_direction", 2))
			elif field_type.ends_with("_wall") or field_type == "magic_wall":
				# Wall placement (line perpendicular to facing)
				server.fields.place_wall(target, field_type, field_element,
					field_damage, field_duration, peer_id, s.get("facing_direction", 2), 5)
			else:
				# Single field
				server.fields.place_field(target, field_type, field_element,
					field_damage, field_duration, peer_id)

		"condition":
			# Apply a condition (burning, poisoned, electrified, paralysed) to target
			var cond_name: String = str(rune_effect.get("condition", ""))
			var tick_dmg: int = int(rune_effect.get("tick_damage", 0))
			var cond_duration: int = int(rune_effect.get("duration_ms", 8000))
			var proj_type: String = str(rune_effect.get("projectile", ""))
			var cond_effect: String = str(rune_effect.get("area_effect", ""))

			# Send projectile from caster to target
			if not proj_type.is_empty():
				for pid in server.get_players_in_range(pos, ENTITY_NEARBY_RANGE):
					server.rpc_id(pid, "rpc_projectile", pos.x, pos.y, tx, ty, proj_type)

			# Show tile effect at target
			if not cond_effect.is_empty():
				for pid in server.get_players_in_range(target, ENTITY_NEARBY_RANGE):
					server.rpc_id(pid, "rpc_tile_effect", cond_effect, tx, ty, tz)

			if cond_name.is_empty():
				return

			# Apply condition to player at target tile
			var hit_player := false
			for pid in server._sessions:
				var ps: Dictionary = server._sessions[pid]
				if ps.get("is_dead", false):
					continue
				if ps["position"] == target:
					server.combat.apply_condition(pid, cond_name, tick_dmg, cond_duration)
					hit_player = true
					break

			# Apply condition to entity at target tile (as direct damage since entities don't have conditions)
			if not hit_player:
				for eid in server.entities._entities.keys():
					if not server.entities._entities.has(eid):
						continue
					var ent: Dictionary = server.entities._entities[eid]
					if int(ent.get("health", 0)) <= 0:
						continue
					var ep: Vector3i = ent["position"]
					if ep != target:
						continue
					# Check immunity
					var immunities: Dictionary = ent.get("immunities", {})
					if immunities.get(cond_name, false) or immunities.get("paralyze", false) and cond_name == "paralysed":
						server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "The creature is immune.")
						break
					# Deal initial burst damage for DoT conditions on entities
					if tick_dmg > 0:
						var burst_dmg := tick_dmg * 3
						ent["health"] = maxi(int(ent["health"]) - burst_dmg, 0)
						if not ent.has("_damage_map"):
							ent["_damage_map"] = {}
						ent["_damage_map"][peer_id] = int(ent["_damage_map"].get(peer_id, 0)) + burst_dmg
						for pid in server.get_players_in_range(ep, ENTITY_NEARBY_RANGE):
							server.rpc_id(pid, "rpc_entity_damage", eid, burst_dmg, str(rune_effect.get("element", "physical")),
								int(ent["health"]), int(ent["max_health"]))
						if int(ent["health"]) <= 0:
							server.combat._on_entity_death(eid, peer_id)
					break

		"destroy_field":
			# Remove a field tile at the target position
			var df_effect: String = str(rune_effect.get("area_effect", "blueshimmer"))
			if server.fields.has_field_at(target):
				server.fields.remove_field(target)
				server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Field destroyed.")
			else:
				server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "There is no field there.")
			if not df_effect.is_empty():
				for pid in server.get_players_in_range(target, ENTITY_NEARBY_RANGE):
					server.rpc_id(pid, "rpc_tile_effect", df_effect, tx, ty, tz)

		"disintegrate":
			# Destroy ground items and corpses at the target position
			var di_effect: String = str(rune_effect.get("area_effect", "death_effect"))
			var destroyed_something := false

			# Remove corpse containers at target
			for cid in server.containers._containers.keys():
				var c: Dictionary = server.containers._containers[cid]
				if c.get("type", "") == "corpse" and c.get("position", Vector3i.ZERO) == target:
					server.containers._remove_container(cid)
					destroyed_something = true
					break  # One corpse per use

			# Remove all ground items at target if no corpse was found
			if not destroyed_something and server.inventory._ground_items.has(target):
				var items: Array = server.inventory._ground_items[target].duplicate()
				for item in items:
					server.inventory._remove_ground_item(target, str(item["item_id"]), int(item["count"]))
				destroyed_something = true

			if destroyed_something:
				server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Poof!")
			else:
				server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Nothing to disintegrate there.")

			if not di_effect.is_empty():
				for pid in server.get_players_in_range(target, ENTITY_NEARBY_RANGE):
					server.rpc_id(pid, "rpc_tile_effect", di_effect, tx, ty, tz)

	# Advance magic level
	server.combat.advance_skill(peer_id, "magic_level", 1)
	server.inventory.send_inventory(peer_id)
	send_stats(peer_id)


## Heals the caster and all nearby players within the spell's range.
func _cast_area_heal(peer_id: int, s: Dictionary, spell: Dictionary, spell_id: String, pos: Vector3i) -> void:
	var ml: int = server.combat.get_skill_level(s, "magic_level")
	var level: int = int(s.get("level", 1))
	var vals: Array = _calc_formula(spell, level, ml, true)
	var heal_range: int = int(spell.get("range", 3))
	# Heal self
	var self_heal := randi_range(vals[0], vals[1])
	s["health"] = mini(int(s["health"]) + self_heal, int(s["max_health"]))
	server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
		"You healed for %d HP." % self_heal)
	# Heal nearby players
	for pid in server.get_players_in_range(pos, heal_range):
		if pid == peer_id:
			continue
		if not server._sessions.has(pid):
			continue
		var other: Dictionary = server._sessions[pid]
		if other.get("is_dead", false):
			continue
		var heal := randi_range(vals[0], vals[1])
		other["health"] = mini(int(other["health"]) + heal, int(other["max_health"]))
		server.rpc_id(pid, "rpc_receive_chat", "system", "",
			"%s healed you for %d HP." % [s["display_name"], heal])
		server.spells.send_stats(pid)
	for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
		server.rpc_id(pid, "rpc_spell_effect", peer_id, spell_id, pos.x, pos.y, pos.z, self_heal)
	server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
		"You cast %s!" % spell["name"])


## Expires finished buffs each tick and removes their effects.
func process_buffs(_delta: float) -> void:
	var now_ms := Time.get_ticks_msec()
	for peer_id in _active_buffs.keys():
		if not server._sessions.has(peer_id):
			_active_buffs.erase(peer_id)
			continue
		var buffs: Dictionary = _active_buffs[peer_id]
		for buff_id in buffs.keys():
			var buff: Dictionary = buffs[buff_id]
			if now_ms >= int(buff["expires_ms"]):
				_remove_buff(peer_id, buff_id)
				buffs.erase(buff_id)
		if buffs.is_empty():
			_active_buffs.erase(peer_id)


## Reverses the effects of a specific buff (e.g. restores base speed for haste).
func _remove_buff(peer_id: int, buff_id: String) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	if buff_id == "haste":
		if s.has("base_speed"):
			s["speed"] = int(s["base_speed"])
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "Haste has worn off.")
		server.inventory.send_combat_stats(peer_id)
	server.combat.send_status(peer_id)


func clear_buffs(peer_id: int) -> void:
	## Called on death/disconnect to remove all active buffs
	if _active_buffs.has(peer_id):
		for buff_id in _active_buffs[peer_id].keys():
			_remove_buff(peer_id, buff_id)
		_active_buffs.erase(peer_id)
