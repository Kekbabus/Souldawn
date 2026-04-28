#  server_combat.gd -- Player-vs-entity combat loop, damage/defense formulas,
#  death/respawn, XP/leveling, vocation system, and Tibia 7.4 skill advancement
extends Node

const COMBAT_TICK_INTERVAL := 2.0
const ATTACK_RANGE := 1
const ENTITY_NEARBY_RANGE := 20

# Skill names -- matches Tibia 7.4
const SKILL_FIST := "fist"
const SKILL_CLUB := "club"
const SKILL_SWORD := "sword"
const SKILL_AXE := "axe"
const SKILL_DISTANCE := "distance"
const SKILL_SHIELDING := "shielding"
const SKILL_MAGIC := "magic_level"

const ALL_SKILLS := [SKILL_FIST, SKILL_CLUB, SKILL_SWORD, SKILL_AXE,
	SKILL_DISTANCE, SKILL_SHIELDING, SKILL_MAGIC]

# Weapon type -> skill mapping (from item datapacks "weapon_type" field)
const WEAPON_SKILL_MAP := {
	"sword": SKILL_SWORD,
	"club": SKILL_CLUB,
	"axe": SKILL_AXE,
	"distance": SKILL_DISTANCE,
}

var server: Node = null  # server_main.gd

var _combat_targets: Dictionary = {}  # peer_id -> entity_id
var _combat_acc: float = 0.0

# Condition system: peer_id -> { condition_name -> { expires_ms, tick_ms, damage, ... } }
var _conditions: Dictionary = {}
var _condition_tick_acc: float = 0.0
const CONDITION_TICK_INTERVAL := 2.0  # Seconds between condition damage ticks

# Condition definitions (TFS 7.6 values)
const CONDITION_DEFS := {
	"burning": {"duration_ms": 8000, "tick_damage": 10, "element": "fire", "decreasing": false},
	"poisoned": {"duration_ms": 16000, "tick_damage": 5, "element": "earth", "decreasing": true},
	"electrified": {"duration_ms": 6000, "tick_damage": 15, "element": "energy", "decreasing": false},
	"paralysed": {"duration_ms": 10000, "tick_damage": 0, "element": "physical", "decreasing": false, "speed_factor": 0.5},
}


#  VOCATION & SKILL SYSTEM (Tibia 7.4 formulas)

# Vocation definitions -- HP/Mana/Cap per level, skill multipliers
# Format: {hp_per_level, mana_per_level, cap_per_level, skill_multipliers}
const VOCATIONS := {
	"none": {
		"display_name": "None",
		"hp_per_level": 5, "mana_per_level": 5, "cap_per_level": 10,
		"base_hp": 150, "base_mana": 50, "base_cap": 400,
		"attack_factor": 1.0, "defense_factor": 1.0, "defense_multiplier": 1.0,
		"skill_mult": {
			"fist": 1.5, "club": 2.0, "sword": 2.0, "axe": 2.0,
			"distance": 2.0, "shielding": 1.5, "magic_level": 3.0,
		},
	},
	"knight": {
		"display_name": "Knight",
		"hp_per_level": 15, "mana_per_level": 5, "cap_per_level": 25,
		"base_hp": 185, "base_mana": 35, "base_cap": 470,
		"attack_factor": 1.0, "defense_factor": 1.0, "defense_multiplier": 1.0,
		"skill_mult": {
			"fist": 1.1, "club": 1.1, "sword": 1.1, "axe": 1.1,
			"distance": 1.4, "shielding": 1.1, "magic_level": 3.0,
		},
	},
	"paladin": {
		"display_name": "Paladin",
		"hp_per_level": 10, "mana_per_level": 15, "cap_per_level": 20,
		"base_hp": 165, "base_mana": 70, "base_cap": 440,
		"attack_factor": 1.0, "defense_factor": 1.0, "defense_multiplier": 1.0,
		"skill_mult": {
			"fist": 1.2, "club": 1.2, "sword": 1.2, "axe": 1.2,
			"distance": 1.1, "shielding": 1.1, "magic_level": 1.4,
		},
	},
	"sorcerer": {
		"display_name": "Sorcerer",
		"hp_per_level": 5, "mana_per_level": 30, "cap_per_level": 10,
		"base_hp": 145, "base_mana": 110, "base_cap": 400,
		"attack_factor": 1.0, "defense_factor": 1.0, "defense_multiplier": 1.0,
		"skill_mult": {
			"fist": 1.5, "club": 2.0, "sword": 2.0, "axe": 2.0,
			"distance": 2.0, "shielding": 1.5, "magic_level": 1.1,
		},
	},
	"druid": {
		"display_name": "Druid",
		"hp_per_level": 5, "mana_per_level": 30, "cap_per_level": 10,
		"base_hp": 145, "base_mana": 110, "base_cap": 400,
		"attack_factor": 1.0, "defense_factor": 1.0, "defense_multiplier": 1.0,
		"skill_mult": {
			"fist": 1.5, "club": 1.8, "sword": 1.8, "axe": 1.8,
			"distance": 1.8, "shielding": 1.5, "magic_level": 1.1,
		},
	},
}

# Skill constants (A) -- base tries before vocation multiplier
const SKILL_CONSTANTS := {
	"fist": 50, "club": 50, "sword": 50, "axe": 50,
	"distance": 30, "shielding": 100, "magic_level": 1600,
}

# Skill offsets (c) -- starting skill level
const SKILL_OFFSETS := {
	"fist": 10, "club": 10, "sword": 10, "axe": 10,
	"distance": 10, "shielding": 10, "magic_level": 0,
}


## Returns the vocation definition dict for a session, defaulting to "none".
func get_vocation(session: Dictionary) -> Dictionary:
	var voc_id: String = str(session.get("vocation", "none"))
	return VOCATIONS.get(voc_id, VOCATIONS["none"])


func init_skills(session: Dictionary) -> void:
	## Ensures all skills exist with defaults. Called on enter_game.
	var skills: Dictionary = session.get("skills", {})
	for skill_name in ALL_SKILLS:
		if not skills.has(skill_name):
			var offset: int = SKILL_OFFSETS.get(skill_name, 10)
			skills[skill_name] = {"level": offset, "tries": 0}
		else:
			if not skills[skill_name].has("level"):
				skills[skill_name]["level"] = SKILL_OFFSETS.get(skill_name, 10)
			if not skills[skill_name].has("tries"):
				skills[skill_name]["tries"] = 0
	session["skills"] = skills


## Returns the current level of a skill, defaulting to 10.
func get_skill_level(session: Dictionary, skill_name: String) -> int:
	return int(session.get("skills", {}).get(skill_name, {}).get("level", 10))


func _tries_to_advance(session: Dictionary, skill_name: String) -> int:
	## Tibia exponential formula: A * b^(skill - c)
	## A = skill constant, b = vocation multiplier, c = skill offset
	var skill_level: int = get_skill_level(session, skill_name)
	var a: float = float(SKILL_CONSTANTS.get(skill_name, 50))
	var c: int = SKILL_OFFSETS.get(skill_name, 10)
	var voc: Dictionary = get_vocation(session)
	var b: float = float(voc.get("skill_mult", {}).get(skill_name, 1.5))
	return int(ceilf(a * pow(b, float(skill_level - c))))


## Adds skill tries and levels up if the threshold is reached.
## For melee skills, tries=1 per hit. For magic level, tries=mana_spent.
func advance_skill(peer_id: int, skill_name: String, tries: int = 1) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	var skills: Dictionary = s.get("skills", {})
	if not skills.has(skill_name):
		return
	var skill: Dictionary = skills[skill_name]
	skill["tries"] = int(skill["tries"]) + tries
	var needed := _tries_to_advance(s, skill_name)
	while int(skill["tries"]) >= needed and needed > 0:
		skill["tries"] = int(skill["tries"]) - needed
		skill["level"] = int(skill["level"]) + 1
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
			"You advanced to %s level %d." % [_skill_display_name(skill_name), int(skill["level"])])
		needed = _tries_to_advance(s, skill_name)
	# Always send skills update so progress bar fills visually
	_send_skills(peer_id)


## Converts an internal skill key (e.g. "fist") to a human-readable name.
func _skill_display_name(skill_name: String) -> String:
	match skill_name:
		"fist": return "Fist Fighting"
		"club": return "Club Fighting"
		"sword": return "Sword Fighting"
		"axe": return "Axe Fighting"
		"distance": return "Distance Fighting"
		"shielding": return "Shielding"
		"magic_level": return "Magic Level"
		_: return skill_name.capitalize()


func _get_weapon_skill(peer_id: int) -> String:
	## Returns the skill name for the currently equipped weapon, or "fist" if none.
	if not server._sessions.has(peer_id):
		return SKILL_FIST
	var equip: Dictionary = server._sessions[peer_id]["equipment"]
	var weapon_id: String = equip.get("weapon", "")
	if weapon_id.is_empty():
		return SKILL_FIST
	var item_def: Dictionary = server.datapacks.get_item(weapon_id)
	var weapon_type: String = str(item_def.get("weapon_type", ""))
	return WEAPON_SKILL_MAP.get(weapon_type, SKILL_FIST)


func _get_ammo_attack(peer_id: int) -> int:
	## Returns the attack value of equipped ammunition (arrow slot), or 0 if none.
	if not server._sessions.has(peer_id):
		return 0
	var equip: Dictionary = server._sessions[peer_id]["equipment"]
	var ammo_id: String = equip.get("arrow", "")
	if ammo_id.is_empty():
		return 0
	var item_def: Dictionary = server.datapacks.get_item(ammo_id)
	var mods: Dictionary = item_def.get("stat_modifiers", {})
	return int(mods.get("attack", int(item_def.get("attack", 0))))


func _consume_ammo(peer_id: int) -> void:
	## Removes 1 ammo from the arrow equipment slot.
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	var equip: Dictionary = s["equipment"]
	var ammo_id: String = equip.get("arrow", "")
	if ammo_id.is_empty():
		return
	var counts: Dictionary = s.get("equip_counts", {})
	var current_count: int = int(counts.get("arrow", 0))
	if current_count <= 1:
		# Last arrow -- clear the slot
		equip["arrow"] = ""
		counts["arrow"] = 0
		server.inventory.send_equipment(peer_id)
	else:
		counts["arrow"] = current_count - 1
		# Send equipment update to refresh the count display
		server.inventory.send_equipment(peer_id)


## Sends the full skill list with levels and progress percentages to the client.
func _send_skills(peer_id: int) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	var skills: Dictionary = s.get("skills", {})
	var data: Array = []
	for skill_name in ALL_SKILLS:
		var skill: Dictionary = skills.get(skill_name, {"level": SKILL_OFFSETS.get(skill_name, 10), "tries": 0})
		var needed := _tries_to_advance(s, skill_name)
		var pct: int = int(float(skill["tries"]) / float(maxi(needed, 1)) * 100.0)
		data.append([skill_name, int(skill["level"]), pct])
	server.rpc_id(peer_id, "rpc_skills_update", data)


## Public wrapper for _send_skills.
func send_skills(peer_id: int) -> void:
	_send_skills(peer_id)


const COMBAT_LOCK_DURATION_MS := 60000  # 60 seconds -- Tibia standard


func set_combat_lock(peer_id: int) -> void:
	## Sets the combat lock (logout block) on a player for 60 seconds.
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	var was_locked: bool = float(s.get("combat_lock_until", 0.0)) > float(Time.get_ticks_msec())
	s["combat_lock_until"] = float(Time.get_ticks_msec() + COMBAT_LOCK_DURATION_MS)
	if not was_locked:
		_send_status(peer_id)


func _send_status(peer_id: int) -> void:
	## Sends active status conditions to the client.
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	var now_ms := Time.get_ticks_msec()
	var statuses: Array = []
	# Combat lock (swords icon)
	if float(s.get("combat_lock_until", 0.0)) > float(now_ms):
		statuses.append("combat")
	# Haste buff
	if server.spells._active_buffs.has(peer_id):
		if server.spells._active_buffs[peer_id].has("haste"):
			statuses.append("haste")
		if server.spells._active_buffs[peer_id].has("magic_shield"):
			statuses.append("magic_shield")
	# Energy ring also gives mana shield status
	var equip: Dictionary = s.get("equipment", {})
	if str(equip.get("ring", "")) == "energy_ring":
		if not statuses.has("magic_shield"):
			statuses.append("magic_shield")
	# Active conditions (burning, poisoned, paralysed, electrocuted)
	if _conditions.has(peer_id):
		for cond_name in _conditions[peer_id]:
			if not statuses.has(cond_name):
				statuses.append(cond_name)
	server.rpc_id(peer_id, "rpc_status_update", statuses)


## Public wrapper for _send_status.
func send_status(peer_id: int) -> void:
	_send_status(peer_id)


#  CONDITION SYSTEM (burning, poisoned, electrified, paralysed)

## Applies a condition to a player. Overwrites existing condition of the same type.
## damage_override: if > 0, uses this instead of the default tick damage.
func apply_condition(peer_id: int, condition_name: String, damage_override: int = -1, duration_override_ms: int = -1) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	if s.get("is_dead", false):
		return
	if not CONDITION_DEFS.has(condition_name):
		return
	var cdef: Dictionary = CONDITION_DEFS[condition_name]
	var now_ms := Time.get_ticks_msec()
	var duration_ms: int = duration_override_ms if duration_override_ms > 0 else int(cdef["duration_ms"])
	var tick_dmg: int = damage_override if damage_override >= 0 else int(cdef["tick_damage"])

	if not _conditions.has(peer_id):
		_conditions[peer_id] = {}

	_conditions[peer_id][condition_name] = {
		"expires_ms": now_ms + duration_ms,
		"tick_damage": tick_dmg,
		"element": str(cdef["element"]),
		"decreasing": bool(cdef.get("decreasing", false)),
		"speed_factor": float(cdef.get("speed_factor", 1.0)),
	}

	# Apply speed reduction for paralysis immediately
	if condition_name == "paralysed":
		_apply_paralyse_speed(peer_id)

	_send_status(peer_id)
	var cond_display := condition_name.capitalize()
	server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
		"You are %s!" % cond_display)


## Removes a specific condition from a player.
func remove_condition(peer_id: int, condition_name: String) -> void:
	if not _conditions.has(peer_id):
		return
	if not _conditions[peer_id].has(condition_name):
		return
	# Restore speed if removing paralysis
	if condition_name == "paralysed":
		_restore_paralyse_speed(peer_id)
	_conditions[peer_id].erase(condition_name)
	if _conditions[peer_id].is_empty():
		_conditions.erase(peer_id)
	_send_status(peer_id)


## Removes all conditions from a player (called on death).
func clear_conditions(peer_id: int) -> void:
	if not _conditions.has(peer_id):
		return
	# Restore speed if paralysed
	if _conditions[peer_id].has("paralysed"):
		_restore_paralyse_speed(peer_id)
	_conditions.erase(peer_id)


## Returns true if the player has the given condition active.
func has_condition(peer_id: int, condition_name: String) -> bool:
	if not _conditions.has(peer_id):
		return false
	return _conditions[peer_id].has(condition_name)


## Applies paralysis speed reduction (halves speed).
func _apply_paralyse_speed(peer_id: int) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	if not s.has("base_speed"):
		s["base_speed"] = int(s.get("speed", 220))
	var base: int = int(s["base_speed"])
	# Paralysis halves the base speed (before buff bonuses)
	s["speed"] = int(float(base) * 0.5)
	server.inventory.send_combat_stats(peer_id)


## Restores speed after paralysis wears off.
func _restore_paralyse_speed(peer_id: int) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	if s.has("base_speed"):
		var base: int = int(s["base_speed"])
		# Restore base speed, plus any haste buff bonus
		var buff_bonus: int = 0
		if server.spells._active_buffs.has(peer_id):
			var buffs: Dictionary = server.spells._active_buffs[peer_id]
			if buffs.has("haste"):
				buff_bonus = int(buffs["haste"].get("speed_bonus", 0))
		s["speed"] = base + buff_bonus
	server.inventory.send_combat_stats(peer_id)


## Ticks all active conditions: applies DoT damage, expires finished conditions.
## Called from server_main._process() every frame, internally accumulates delta.
func process_conditions(delta: float) -> void:
	# Expire conditions
	var now_ms := Time.get_ticks_msec()
	for peer_id in _conditions.keys():
		if not server._sessions.has(peer_id):
			_conditions.erase(peer_id)
			continue
		var conds: Dictionary = _conditions[peer_id]
		for cond_name in conds.keys():
			if now_ms >= int(conds[cond_name]["expires_ms"]):
				if cond_name == "paralysed":
					_restore_paralyse_speed(peer_id)
				conds.erase(cond_name)
				_send_status(peer_id)
				server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
					"%s has worn off." % cond_name.capitalize())
		if conds.is_empty():
			_conditions.erase(peer_id)

	# Tick damage
	_condition_tick_acc += delta
	if _condition_tick_acc < CONDITION_TICK_INTERVAL:
		return
	_condition_tick_acc -= CONDITION_TICK_INTERVAL

	for peer_id in _conditions.keys():
		if not server._sessions.has(peer_id):
			continue
		var s: Dictionary = server._sessions[peer_id]
		if s.get("is_dead", false):
			continue
		var conds: Dictionary = _conditions[peer_id]
		for cond_name in conds:
			var cond: Dictionary = conds[cond_name]
			var tick_dmg: int = int(cond["tick_damage"])
			if tick_dmg <= 0:
				continue
			# Decreasing damage (poison): reduce tick damage each tick
			if bool(cond.get("decreasing", false)):
				tick_dmg = maxi(tick_dmg - 1, 1)
				cond["tick_damage"] = tick_dmg
			_damage_player(peer_id, tick_dmg, str(cond["element"]))


## Toggles the player's combat target; clears if already targeting the same entity.
func handle_attack_request(peer_id: int, entity_id: int) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	if s.get("is_dead", false):
		return
	if _combat_targets.get(peer_id, -1) == entity_id:
		_combat_targets.erase(peer_id)
		server.rpc_id(peer_id, "rpc_combat_clear")
		return
	if not server.entities._entities.has(entity_id):
		return
	var ent: Dictionary = server.entities._entities[entity_id]
	if int(ent.get("health", 0)) <= 0:
		return
	_combat_targets[peer_id] = entity_id
	# Clear any PVP target when switching to PVE
	server.pvp._pvp_targets.erase(peer_id)
	server.rpc_id(peer_id, "rpc_combat_target", entity_id)


## Handles a player attacking another player (PVP).
func handle_attack_player(attacker_id: int, target_peer_id: int) -> void:
	if not server._sessions.has(attacker_id) or not server._sessions.has(target_peer_id):
		return
	if attacker_id == target_peer_id:
		return
	var s: Dictionary = server._sessions[attacker_id]
	if s.get("is_dead", false):
		return
	var target: Dictionary = server._sessions[target_peer_id]
	if target.get("is_dead", false):
		return
	# Toggle off if already targeting this player
	if server.pvp.get_pvp_target(attacker_id) == target_peer_id:
		server.pvp._pvp_targets.erase(attacker_id)
		server.rpc_id(attacker_id, "rpc_combat_clear")
		return
	# Set PVP target and clear PVE target
	_combat_targets.erase(attacker_id)
	server.pvp._pvp_targets[attacker_id] = target_peer_id
	# Notify skull system
	server.pvp.on_pvp_attack(attacker_id, target_peer_id)
	# Set combat lock on attacker
	set_combat_lock(attacker_id)
	server.rpc_id(attacker_id, "rpc_combat_target", -target_peer_id)  # Negative = player target


## Accumulates delta and fires a combat round every COMBAT_TICK_INTERVAL seconds.
func process_combat_tick(delta: float) -> void:
	_combat_acc += delta
	if _combat_acc < COMBAT_TICK_INTERVAL:
		return
	_combat_acc -= COMBAT_TICK_INTERVAL
	_process_combat()
	_process_pvp_combat()
	_process_monster_retaliation()


## Resolves all player-vs-entity attacks for this combat tick.
func _process_combat() -> void:
	for peer_id in _combat_targets.keys():
		if not server._sessions.has(peer_id):
			_combat_targets.erase(peer_id)
			continue
		var s: Dictionary = server._sessions[peer_id]
		if s.get("is_dead", false):
			_combat_targets.erase(peer_id)
			continue
		var target_eid: int = _combat_targets[peer_id]
		if not server.entities._entities.has(target_eid):
			_combat_targets.erase(peer_id)
			server.rpc_id(peer_id, "rpc_combat_clear")
			continue
		var ent: Dictionary = server.entities._entities[target_eid]
		if int(ent.get("health", 0)) <= 0:
			_combat_targets.erase(peer_id)
			server.rpc_id(peer_id, "rpc_combat_clear")
			continue
		var pp: Vector3i = s["position"]
		var ep: Vector3i = ent["position"]
		# Determine attack type: distance or melee
		var weapon_skill_name := _get_weapon_skill(peer_id)
		var is_distance: bool = (weapon_skill_name == SKILL_DISTANCE)
		var max_range: int = ATTACK_RANGE
		if is_distance:
			# Get range from weapon definition
			var equip: Dictionary = s["equipment"]
			var weapon_id: String = equip.get("weapon", "")
			if not weapon_id.is_empty():
				var weapon_def: Dictionary = server.datapacks.get_item(weapon_id)
				max_range = int(weapon_def.get("range", 5))
		if pp.z != ep.z or absi(pp.x - ep.x) > max_range or absi(pp.y - ep.y) > max_range:
			continue
		var atk_bonus: int = server.inventory.get_attack_bonus(peer_id)
		var weapon_skill_level := get_skill_level(s, weapon_skill_name)
		var level: int = int(s.get("level", 1))
		var attack_factor: float = 1.0  # Full attack mode
		var max_hit: int
		if is_distance:
			# TFS distance formula: maxDamage = 0.09 * damageFactor * distanceSkill * ammoAttack + level/5
			# ammoAttack = arrow/bolt attack value from the arrow slot
			var ammo_atk: int = _get_ammo_attack(peer_id)
			if ammo_atk <= 0:
				# No ammo -- can't shoot
				server.rpc_id(peer_id, "rpc_receive_chat", "system", "", "You are out of ammunition.")
				continue
			max_hit = int(roundf(0.09 * (1.0 / attack_factor) * float(weapon_skill_level) * float(ammo_atk) + float(level) / 5.0))
			# Consume 1 ammo
			_consume_ammo(peer_id)
			# Broadcast projectile visual to nearby players
			for pid in server.get_players_in_range(pp, ENTITY_NEARBY_RANGE):
				server.rpc_id(pid, "rpc_projectile", pp.x, pp.y, ep.x, ep.y, "arrow")
		else:
			# TFS melee formula
			max_hit = int(roundf(float(level) / 5.0 + ((((float(weapon_skill_level) / 4.0) + 1.0) * (float(atk_bonus) / 3.0)) * 1.03) / attack_factor))
		var damage := randi_range(0, maxi(max_hit, 1))
		ent["health"] = maxi(int(ent["health"]) - damage, 0)
		# Track damage for XP split
		if damage > 0:
			if not ent.has("_damage_map"):
				ent["_damage_map"] = {}
			ent["_damage_map"][peer_id] = int(ent["_damage_map"].get(peer_id, 0)) + damage
		# Advance weapon skill on hit
		advance_skill(peer_id, weapon_skill_name)
		# Set combat lock on attacker
		set_combat_lock(peer_id)
		if ent.get("ai_state", "idle") != "chase" and ent.get("ai_state", "idle") != "flee":
			var behavior: String = ent.get("ai_behavior", "aggressive")
			if behavior == "passive":
				ent["ai_state"] = "flee"
				ent["ai_target"] = peer_id
			else:
				ent["ai_state"] = "chase"
				ent["ai_target"] = peer_id
		for pid in server.get_players_in_range(ep, ENTITY_NEARBY_RANGE):
			server.rpc_id(pid, "rpc_entity_damage", target_eid, damage, "physical",
				int(ent["health"]), int(ent["max_health"]))
		if int(ent["health"]) <= 0:
			_on_entity_death(target_eid, peer_id)


## Handles entity death: awards XP, creates corpse with loot, queues respawn, and despawns.
## Handles entity death: awards XP proportionally to all players who dealt damage.
func _on_entity_death(entity_id: int, _killer_peer_id: int) -> void:
	if not server.entities._entities.has(entity_id):
		return
	var ent: Dictionary = server.entities._entities[entity_id]
	var pos: Vector3i = ent["position"]
	var xp_reward: int = int(ent.get("experience_reward", 0))

	# Distribute XP proportionally based on damage dealt
	var damage_map: Dictionary = ent.get("_damage_map", {})
	var total_damage: int = 0
	for pid in damage_map:
		total_damage += int(damage_map[pid])

	if xp_reward > 0 and total_damage > 0:
		for pid in damage_map:
			if not server._sessions.has(int(pid)):
				continue
			var player_damage: int = int(damage_map[pid])
			var player_xp: int = int(float(xp_reward) * float(player_damage) / float(total_damage))
			if player_xp <= 0:
				player_xp = 1
			_award_experience(int(pid), player_xp)
			server.rpc_id(int(pid), "rpc_experience_gain", player_xp, pos.x, pos.y, pos.z)
			server.rpc_id(int(pid), "rpc_receive_chat", "system", "",
				"You killed %s. (+%d XP)" % [ent["display_name"], player_xp])
	elif xp_reward > 0 and server._sessions.has(_killer_peer_id):
		# Fallback: no damage tracked, give all to killer
		_award_experience(_killer_peer_id, xp_reward)
		server.rpc_id(_killer_peer_id, "rpc_experience_gain", xp_reward, pos.x, pos.y, pos.z)
		server.rpc_id(_killer_peer_id, "rpc_receive_chat", "system", "",
			"You killed %s. (+%d XP)" % [ent["display_name"], xp_reward])
	# Create corpse container with loot
	var loot: Array = server.datapacks.roll_loot(ent["definition_id"])
	server.containers.create_corpse(ent["definition_id"], ent["display_name"], pos, loot)
	server.entities.queue_respawn(ent)
	# Clear all players targeting this entity
	for pid in _combat_targets.keys():
		if _combat_targets[pid] == entity_id:
			_combat_targets.erase(pid)
			if server._sessions.has(pid):
				server.rpc_id(pid, "rpc_combat_clear")
	# Despawn
	for pid in server.get_players_in_range(pos, ENTITY_NEARBY_RANGE):
		server.rpc_id(pid, "rpc_entity_despawn", entity_id)
	server.entities._entity_grid_remove(entity_id)
	server.entities._entities.erase(entity_id)


## Processes all player-vs-player melee attacks for this combat tick.
func _process_pvp_combat() -> void:
	for attacker_id in server.pvp._pvp_targets.keys():
		if not server._sessions.has(attacker_id):
			server.pvp._pvp_targets.erase(attacker_id)
			continue
		var s: Dictionary = server._sessions[attacker_id]
		if s.get("is_dead", false):
			server.pvp._pvp_targets.erase(attacker_id)
			continue
		var victim_id: int = server.pvp._pvp_targets[attacker_id]
		if not server._sessions.has(victim_id):
			server.pvp._pvp_targets.erase(attacker_id)
			server.rpc_id(attacker_id, "rpc_combat_clear")
			continue
		var vs: Dictionary = server._sessions[victim_id]
		if vs.get("is_dead", false):
			server.pvp._pvp_targets.erase(attacker_id)
			server.rpc_id(attacker_id, "rpc_combat_clear")
			continue
		# Range check (melee = 1 tile)
		var ap: Vector3i = s["position"]
		var vp: Vector3i = vs["position"]
		if ap.z != vp.z or absi(ap.x - vp.x) > 1 or absi(ap.y - vp.y) > 1:
			continue
		# Calculate melee damage (same formula as PVE)
		var weapon_skill: String = _get_weapon_skill(attacker_id)
		var skill_level: int = get_skill_level(s, weapon_skill)
		var attack_value: int = server.inventory.get_attack_bonus(attacker_id)
		var max_hit: int = int(roundf((float(skill_level) / 4.0 + 1.0) * (float(attack_value) / 3.0) * 1.03))
		var damage := randi_range(0, maxi(max_hit, 1))
		# Apply 50% PVP damage reduction
		damage = server.pvp.scale_pvp_damage(damage)
		# Advance weapon skill
		advance_skill(attacker_id, weapon_skill)
		# Refresh skull (every hit refreshes the timer)
		server.pvp.on_pvp_attack(attacker_id, victim_id)
		# Apply damage to victim
		_damage_player(victim_id, damage, "physical")
		# Check if victim died -- handle PVP kill
		if int(vs["health"]) <= 0:
			server.pvp.on_pvp_kill(attacker_id, victim_id)
			server.pvp._pvp_targets.erase(attacker_id)
			server.rpc_id(attacker_id, "rpc_combat_clear")


#  MONSTER RETALIATION

## Processes melee and ability attacks for all monsters currently chasing a player.
func _process_monster_retaliation() -> void:
	var now_ms := Time.get_ticks_msec()
	for eid in server.entities._entities:
		var ent: Dictionary = server.entities._entities[eid]
		if int(ent.get("health", 0)) <= 0:
			continue
		if ent.get("ai_state", "idle") != "chase":
			continue
		var target_pid: int = ent.get("ai_target", -1)
		if target_pid < 0 or not server._sessions.has(target_pid):
			continue
		var s: Dictionary = server._sessions[target_pid]
		if s.get("is_dead", false):
			ent["ai_state"] = "idle"
			ent["ai_target"] = -1
			continue
		# Refresh combat lock while monster is actively chasing
		set_combat_lock(target_pid)
		var ep: Vector3i = ent["position"]
		var pp: Vector3i = s["position"]
		var dist: int = maxi(absi(ep.x - pp.x), absi(ep.y - pp.y))
		if ep.z != pp.z:
			continue

		# Face the target before attacking (TFS behavior)
		_face_entity_toward(eid, ent, ep, pp)

		# Process monster abilities (ranged/spell attacks)
		var abilities: Array = ent.get("abilities", [])
		if not abilities.is_empty():
			if not ent.has("_ability_cooldowns"):
				ent["_ability_cooldowns"] = {}
			var cooldowns: Dictionary = ent["_ability_cooldowns"]
			for ability in abilities:
				var ab_id: String = str(ability.get("id", ability.get("ability_id", "")))
				var ab_range: int = int(ability.get("range", 7))
				if dist > ab_range:
					continue
				var cd_ms: float = float(ability.get("cooldown_seconds", 2.0)) * 1000.0
				if float(now_ms) < float(cooldowns.get(ab_id, 0.0)):
					continue
				var chance: float = float(ability.get("chance_percent", 100))
				if randf() * 100.0 > chance:
					continue
				var min_dmg: int = int(abs(float(ability.get("min_damage", 0))))
				var max_dmg: int = int(abs(float(ability.get("max_damage", 0))))
				var ab_type: String = str(ability.get("ability_type", "physical"))
				cooldowns[ab_id] = float(now_ms) + cd_ms
				# Use area_pattern if defined, otherwise fall back to legacy shape
				var pattern_name: String = str(ability.get("area_pattern", ""))
				var is_targeted: bool = bool(ability.get("target", false))
				var projectile_type: String = str(ability.get("projectile", ""))
				if not pattern_name.is_empty():
					_monster_pattern_attack(eid, ent, ep, pp, min_dmg, max_dmg, ab_type, pattern_name, is_targeted, projectile_type)
				else:
					var shape: String = str(ability.get("shape", "target"))
					match shape:
						"wave":
							var length: int = int(ability.get("length", 5))
							var spread_val: int = int(ability.get("spread", 3))
							_monster_wave_attack(eid, ent, ep, pp, min_dmg, max_dmg, ab_type, length, spread_val)
						"area":
							var radius: int = int(ability.get("radius", 3))
							_monster_area_attack(eid, ent, pp, min_dmg, max_dmg, ab_type, radius)
						_:
							var ab_damage: int = randi_range(min_dmg, maxi(max_dmg, min_dmg + 1))
							_damage_player(target_pid, ab_damage, ab_type)

		# (Self-healing is handled by server_entities._ai_try_self_heal)

		# Melee attack -- only when adjacent
		if dist > 1:
			continue
		var melee_skill: int = int(ent.get("melee_skill", 0))
		var melee_attack: int = int(ent.get("melee_attack", 0))
		if melee_skill <= 0 or melee_attack <= 0:
			continue  # No melee stats -- skip
		var max_hit: int = int(roundf((float(melee_skill) / 4.0 + 1.0) * (float(melee_attack) / 3.0) * 1.03))
		var damage := randi_range(0, maxi(max_hit, 1))
		_damage_player(target_pid, damage, "physical")


## Faces an entity toward a target position and broadcasts the direction change.
## Uses the same direction convention as players: 0=N, 1=E, 2=S, 3=W.
func _face_entity_toward(eid: int, ent: Dictionary, from: Vector3i, to: Vector3i) -> void:
	var dx: int = to.x - from.x
	var dy: int = to.y - from.y
	var direction: int = 2  # default south
	if absi(dy) >= absi(dx):
		direction = 0 if dy < 0 else 2
	else:
		direction = 1 if dx > 0 else 3
	var old_dir: int = int(ent.get("facing_direction", -1))
	if direction == old_dir:
		return
	ent["facing_direction"] = direction
	for pid in server.get_players_in_range(from, server.NEARBY_RANGE):
		server.rpc_id(pid, "rpc_entity_face", eid, direction)


## Maps a damage type to its visual effect name for tile effects.
func _get_element_effect(dmg_type: String) -> String:
	match dmg_type:
		"fire": return "fire_effect"
		"energy": return "energy_effect"
		"earth", "poison": return "poison_effect"
		"ice": return "energy_effect"
		"death": return "death_effect"
		"holy": return "energy_effect"
		_: return "hit_physical"


func _monster_wave_attack(eid: int, ent: Dictionary, ep: Vector3i, target_pos: Vector3i,
		min_dmg: int, max_dmg: int, dmg_type: String, length: int, spread: int) -> void:
	## Monster directional wave/breath attack -- hits all players in a cone toward target.
	var dx: int = signi(target_pos.x - ep.x)
	var dy: int = signi(target_pos.y - ep.y)
	# Determine primary direction
	if dx == 0 and dy == 0:
		dy = 1  # Default south
	var wave_tiles: Array = []
	for step in range(1, length + 1):
		@warning_ignore("integer_division")
		var half_spread: int = (spread * step) / length
		for offset in range(-half_spread, half_spread + 1):
			var tx: int = ep.x
			var ty: int = ep.y
			if absi(dx) >= absi(dy):
				tx += dx * step
				ty += offset
			else:
				ty += dy * step
				tx += offset
			wave_tiles.append(Vector3i(tx, ty, ep.z))
	# Broadcast visual effect on wave tiles to nearby players
	var effect_name: String = _get_element_effect(dmg_type)
	for wt in wave_tiles:
		for pid in server.get_players_in_range(ep, ENTITY_NEARBY_RANGE):
			server.rpc_id(pid, "rpc_tile_effect", effect_name, wt.x, wt.y, wt.z)
	# Hit all players in the wave area
	for pid in server._sessions:
		var s: Dictionary = server._sessions[pid]
		if s.get("is_dead", false):
			continue
		var pp: Vector3i = s["position"]
		for wt in wave_tiles:
			if pp == wt:
				var damage: int = randi_range(min_dmg, maxi(max_dmg, min_dmg + 1))
				_damage_player(pid, damage, dmg_type)
				break


func _monster_area_attack(_eid: int, _ent: Dictionary, center: Vector3i,
		min_dmg: int, max_dmg: int, dmg_type: String, radius: int) -> void:
	## Monster AoE attack -- hits all players within radius of the target position.
	# Broadcast visual effect on area tiles
	var effect_name: String = _get_element_effect(dmg_type)
	for dx_off in range(-radius, radius + 1):
		for dy_off in range(-radius, radius + 1):
			for pid in server.get_players_in_range(center, ENTITY_NEARBY_RANGE):
				server.rpc_id(pid, "rpc_tile_effect", effect_name, center.x + dx_off, center.y + dy_off, center.z)
	for pid in server._sessions:
		var s: Dictionary = server._sessions[pid]
		if s.get("is_dead", false):
			continue
		var pp: Vector3i = s["position"]
		if pp.z != center.z:
			continue
		if absi(pp.x - center.x) <= radius and absi(pp.y - center.y) <= radius:
			var damage: int = randi_range(min_dmg, maxi(max_dmg, min_dmg + 1))
			_damage_player(pid, damage, dmg_type)


func _monster_pattern_attack(_eid: int, ent: Dictionary, ep: Vector3i, target_pos: Vector3i,
		min_dmg: int, max_dmg: int, dmg_type: String, pattern_name: String,
		is_targeted: bool = false, projectile_type: String = "") -> void:
	## Monster area attack using a named pattern from spell_areas.json.
	## If is_targeted, the pattern is centered on the target position (fireball-style).
	## Otherwise, centered on the monster with facing toward target (wave/breath-style).
	var center: Vector3i = target_pos if is_targeted else ep
	# For targeted abilities (fireballs), face toward target
	# For non-targeted (waves/breaths), use the entity's current facing direction
	var facing: int = 2
	if is_targeted:
		var dx: int = target_pos.x - ep.x
		var dy: int = target_pos.y - ep.y
		if absi(dy) >= absi(dx):
			facing = 0 if dy < 0 else 2
		else:
			facing = 3 if dx < 0 else 1
	else:
		facing = int(ent.get("facing_direction", 2))

	# Send projectile from monster to target if specified
	if not projectile_type.is_empty() and is_targeted:
		for pid in server.get_players_in_range(ep, ENTITY_NEARBY_RANGE):
			server.rpc_id(pid, "rpc_projectile", ep.x, ep.y, target_pos.x, target_pos.y, projectile_type)

	var tiles: Array = server.spells.resolve_area_tiles(pattern_name, center, facing)
	# Broadcast visual effect on each affected tile to nearby players
	var effect_name: String = _get_element_effect(dmg_type)
	for tile in tiles:
		for pid in server.get_players_in_range(ep, ENTITY_NEARBY_RANGE):
			server.rpc_id(pid, "rpc_tile_effect", effect_name, int(tile.x), int(tile.y), ep.z)
	for pid in server._sessions:
		var s: Dictionary = server._sessions[pid]
		if s.get("is_dead", false):
			continue
		var pp: Vector3i = s["position"]
		if pp.z != ep.z:
			continue
		if tiles.has(Vector2i(pp.x, pp.y)):
			var damage: int = randi_range(min_dmg, maxi(max_dmg, min_dmg + 1))
			_damage_player(pid, damage, dmg_type)


#  PLAYER HEALTH / DEATH / RESPAWN

## Applies damage to a player after shield blocking and armor reduction (TFS formulas).
func _damage_player(peer_id: int, damage: int, damage_type: String) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	if s.get("is_dead", false):
		return

	var raw_damage: int = damage
	var armor: int = server.inventory.get_armor_bonus(peer_id)
	var defense: int = server.inventory.get_defense_bonus(peer_id)
	var shielding_level := get_skill_level(s, SKILL_SHIELDING)

	# TFS defense formula: defenseValue = (shielding/4 + 2.23) * shieldDef * 0.15 * defenseFactor
	var blocked: int = 0
	if defense > 0:
		var defense_factor: float = 1.0  # Balanced mode (offensive=0.5, defensive=2.0 -- future)
		var defense_value: float = (float(shielding_level) / 4.0 + 2.23) * float(defense) * 0.15 * defense_factor
		blocked = randi_range(0, int(roundf(defense_value)))
		damage = maxi(damage - blocked, 0)
		# Advance shielding on block attempt (TFS advances on every hit, not just successful blocks)
		advance_skill(peer_id, SKILL_SHIELDING)

	# TFS armor formula: reduction = randi(floor(armor/2), floor(armor/2)*2-1)
	var armor_reduced: int = 0
	if armor > 0 and damage > 0:
		@warning_ignore("integer_division")
		var min_armor: int = armor / 2
		var max_armor: int = maxi(min_armor * 2 - 1, min_armor)
		armor_reduced = randi_range(min_armor, max_armor)
		armor_reduced = mini(armor_reduced, damage)
		damage = maxi(damage - armor_reduced, 0)

	# Send combat log (skip if peer is orphaned/disconnected)
	if not s.get("_orphan", false):
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
			"Hit for %d (raw: %d, blocked: %d, armor: -%d)" % [damage, raw_damage, blocked, armor_reduced])

	# Mana shield: redirect damage to mana if magic_shield buff is active or energy ring equipped
	var has_mana_shield: bool = false
	var mana_absorbed_all: bool = false
	if server.spells._active_buffs.has(peer_id):
		if server.spells._active_buffs[peer_id].has("magic_shield"):
			has_mana_shield = true
	if not has_mana_shield:
		var equip: Dictionary = s.get("equipment", {})
		if str(equip.get("ring", "")) == "energy_ring":
			has_mana_shield = true

	if has_mana_shield and damage > 0:
		var mana: int = int(s["mana"])
		if mana >= damage:
			s["mana"] = mana - damage
			mana_absorbed_all = true
			damage = 0
		else:
			damage -= mana
			s["mana"] = 0
		server.spells.send_stats(peer_id)

	s["health"] = maxi(int(s["health"]) - damage, 0)
	# Set combat lock on the player being hit
	set_combat_lock(peer_id)
	var pos: Vector3i = s["position"]
	# If mana shield absorbed all damage, send "mana_shield" type so client shows blue effect instead of blood
	var broadcast_type: String = "mana_shield" if mana_absorbed_all else damage_type
	for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
		server.rpc_id(pid, "rpc_player_damage", peer_id, damage, broadcast_type,
			int(s["health"]), int(s["max_health"]))
	if int(s["health"]) <= 0:
		_on_player_death(peer_id)


## Public wrapper for _damage_player.
func damage_player(peer_id: int, damage: int, damage_type: String) -> void:
	_damage_player(peer_id, damage, damage_type)


## Handles player death: XP penalty, equipment/inventory drop, corpse creation, and despawn.
func _on_player_death(peer_id: int) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	s["is_dead"] = true
	s["walk_dir"] = Vector2i.ZERO
	_combat_targets.erase(peer_id)
	# Clear target on client
	if server.is_peer_active(peer_id):
		server.rpc_id(peer_id, "rpc_combat_clear")
	# Clear active buffs
	server.spells.clear_buffs(peer_id)
	# Clear active conditions (burning, poison, etc.)
	clear_conditions(peer_id)
	# Reset food timer
	s["food_timer"] = 0.0
	# Reset combat lock
	s["combat_lock_until"] = 0.0
	# Send cleared status icons (no combat, no haste, no conditions)
	if server.is_peer_active(peer_id):
		server.rpc_id(peer_id, "rpc_status_update", [])

	# 10% experience loss
	var xp_loss := int(s.get("experience", 0)) / 10
	s["experience"] = maxi(int(s["experience"]) - xp_loss, 0)

	# Deduct levels if XP dropped below thresholds
	var voc: Dictionary = get_vocation(s)
	while int(s["level"]) > 1 and int(s["experience"]) < _xp_for_level(int(s["level"])):
		s["level"] = int(s["level"]) - 1
		s["max_health"] = int(voc["base_hp"]) + (int(s["level"]) - 1) * int(voc["hp_per_level"])
		s["max_mana"] = int(voc["base_mana"]) + (int(s["level"]) - 1) * int(voc["mana_per_level"])
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
			"You were demoted to level %d." % int(s["level"]))

	var pos: Vector3i = s["position"]
	var display_name: String = str(s["display_name"])

	# Build corpse loot from equipment + inventory
	var corpse_loot: Array = []
	var equip: Dictionary = s["equipment"]
	var slots_to_clear: Array = []

	# Backpack ALWAYS drops (100%)
	var bp_id: String = str(equip.get("backpack", ""))
	if not bp_id.is_empty():
		var bp_item := {"item_id": bp_id, "count": 1, "children": s["inventory"].duplicate(true)}
		corpse_loot.append(bp_item)
		slots_to_clear.append("backpack")

	# Red skull: drop ALL equipment. Normal: 10% drop chance each.
	var drop_all: bool = server.pvp.should_drop_all_items(peer_id)
	for slot_name in server.inventory.EQUIPMENT_SLOTS:
		if slot_name == "backpack":
			continue
		var item_id: String = str(equip.get(slot_name, ""))
		if item_id.is_empty():
			continue
		if drop_all or randf() < 0.10:
			corpse_loot.append({"item_id": item_id, "count": 1})
			slots_to_clear.append(slot_name)

	# Clear dropped equipment
	for slot_name in slots_to_clear:
		equip[slot_name] = ""

	# Clear inventory (it went into the backpack in the corpse)
	s["inventory"] = []

	# Close backpack window if open
	var bp_cid := -peer_id
	if server.containers._viewer_registry.has(bp_cid):
		for pid in server.containers._viewer_registry[bp_cid]:
			if server.is_peer_active(pid):
				server.rpc_id(pid, "rpc_container_close", bp_cid)
		server.containers._viewer_registry.erase(bp_cid)

	# Create player corpse with loot
	server.containers.create_corpse("player", display_name, pos, corpse_loot)

	# Send updates to the dead player
	if server.is_peer_active(peer_id):
		server.rpc_id(peer_id, "rpc_player_death", xp_loss)
		server.inventory.send_equipment(peer_id)
		server.inventory.send_inventory(peer_id)
		server.spells.send_stats(peer_id)

	# Despawn the dead player for all other nearby players
	for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
		if pid != peer_id:
			server.rpc_id(pid, "rpc_player_despawn", peer_id)
			server.rpc_id(pid, "rpc_receive_chat", "system", "",
				"%s has died." % display_name)
	for eid in server.entities._entities:
		var ent: Dictionary = server.entities._entities[eid]
		if ent.get("ai_target", -1) == peer_id:
			ent["ai_state"] = "idle"
			ent["ai_target"] = -1


## Respawns a dead player at the server spawn point with full HP/mana.
func handle_request_respawn(peer_id: int) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	if not s.get("is_dead", false):
		return
	var spawn_pos := Vector3i(server._next_spawn_x, server._next_spawn_y, 7)
	s["position"] = spawn_pos
	s["health"] = s["max_health"]
	s["mana"] = s["max_mana"]
	s["is_dead"] = false
	_combat_targets.erase(peer_id)
	server.grid_update(peer_id, spawn_pos)
	server.rpc_id(peer_id, "rpc_combat_clear")
	server.rpc_id(peer_id, "rpc_respawn_result", spawn_pos.x, spawn_pos.y, spawn_pos.z,
		int(s["health"]), int(s["max_health"]))
	server.spells.send_stats(peer_id)
	# Re-spawn the player for nearby players (was despawned on death)
	var outfit_sprites: String = server.datapacks.get_outfit_sprites_json(str(s.get("outfit_id", "citizen_male")))
	for pid in server.get_players_in_range(spawn_pos, server.NEARBY_RANGE):
		if pid != peer_id:
			server.rpc_id(pid, "rpc_player_spawn", peer_id, spawn_pos.x, spawn_pos.y, spawn_pos.z,
				s["display_name"], int(s["speed"]), outfit_sprites)
			# Also send outfit colors so the respawned player renders correctly
			server.rpc_id(pid, "rpc_outfit_update", peer_id, str(s.get("outfit_id", "citizen_male")),
				outfit_sprites, str(s.get("outfit_head", "#ffff00")),
				str(s.get("outfit_body", "#4d80ff")), str(s.get("outfit_legs", "#4d80ff")),
				str(s.get("outfit_feet", "#996633")))


#  EXPERIENCE & LEVEL SYSTEM

## Returns the cumulative XP required to reach the given level.
func _xp_for_level(level: int) -> int:
	return 50 * level * level

## Recalculates a player's speed based on their level (Tibia: 220 + 2*(level-1)).
## Preserves any active buff bonus on top of base speed.
func recalculate_speed(session: Dictionary) -> void:
	var level: int = int(session.get("level", 1))
	session["base_speed"] = 220 + 2 * (level - 1)
	var old_speed: int = int(session.get("speed", 220))
	var old_base: int = int(session.get("base_speed", old_speed))
	var buff_bonus: int = maxi(old_speed - old_base, 0)
	session["speed"] = int(session["base_speed"]) + buff_bonus


## Awards XP to a player and handles any resulting level-ups.
func _award_experience(peer_id: int, amount: int) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	var voc: Dictionary = get_vocation(s)
	s["experience"] = int(s["experience"]) + amount
	while int(s["experience"]) >= _xp_for_level(int(s["level"]) + 1):
		s["level"] = int(s["level"]) + 1
		s["max_health"] = int(voc["base_hp"]) + (int(s["level"]) - 1) * int(voc["hp_per_level"])
		s["max_mana"] = int(voc["base_mana"]) + (int(s["level"]) - 1) * int(voc["mana_per_level"])
		s["health"] = s["max_health"]
		s["mana"] = s["max_mana"]
		recalculate_speed(s)
		server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
			"You advanced to level %d!" % int(s["level"]))
	server.spells.send_stats(peer_id)
	server.inventory.send_combat_stats(peer_id)
