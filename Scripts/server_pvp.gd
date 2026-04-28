# server_pvp.gd -- PVP skull system, frag tracking, and PVP damage scaling
#
# Implements Tibia 7.6 skull system:
#   White skull: attacking/killing an unskulled player (15min on kill, logout block on attack)
#   Yellow skull: per-player self-defense marker (only visible to the skulled attacker)
#   Red skull: 3+ unjustified kills in 24h, 5+ in 7d, 10+ in 30d (30-day penalty)
#   PVP damage: 50% of PVE damage
#   Red skull death: drop ALL items
extends Node

const WHITE_SKULL_DURATION_MS := 1 * 60 * 1000  # 1 minute (for testing; Tibia uses 15 minutes)
const PVP_DAMAGE_FACTOR := 0.5
const RED_SKULL_DURATION_MS := 30 * 24 * 60 * 60 * 1000  # 30 days

# Frag thresholds for red skull
const FRAGS_DAY := 3
const FRAGS_WEEK := 5
const FRAGS_MONTH := 10

var server: Node = null

# PVP targets: attacker_peer_id -> victim_peer_id (player attacking player)
var _pvp_targets: Dictionary = {}


## Returns the skull type visible to all players for the given peer.
## "none", "white", "red"
func get_skull(peer_id: int) -> String:
	if not server._sessions.has(peer_id):
		return "none"
	return str(server._sessions[peer_id].get("skull", "none"))


## Returns the skull type that [param viewer_peer_id] sees on [param target_peer_id].
## Yellow skulls are per-viewer (self-defense marker).
func get_skull_for_viewer(viewer_peer_id: int, target_peer_id: int) -> String:
	# Check if target has a yellow skull visible only to this viewer
	if server._sessions.has(target_peer_id):
		var s: Dictionary = server._sessions[target_peer_id]
		var yellow_for: Dictionary = s.get("_yellow_skull_for", {})
		if yellow_for.has(viewer_peer_id):
			var expires: float = float(yellow_for[viewer_peer_id])
			if Time.get_ticks_msec() < expires:
				return "yellow"
			else:
				yellow_for.erase(viewer_peer_id)
	# Otherwise return the global skull
	return get_skull(target_peer_id)


## Called when a player attacks another player. Handles skull assignment.
func on_pvp_attack(attacker_id: int, victim_id: int) -> void:
	if not server._sessions.has(attacker_id) or not server._sessions.has(victim_id):
		return
	var attacker: Dictionary = server._sessions[attacker_id]
	var victim: Dictionary = server._sessions[victim_id]
	var victim_skull: String = get_skull(victim_id)

	# If victim is unskulled, attacker gets white skull (unjustified attack)
	if victim_skull == "none":
		_set_white_skull(attacker_id)
		# Victim sees yellow skull on attacker (self-defense)
		_set_yellow_skull(attacker_id, victim_id)
	elif victim_skull == "white" or victim_skull == "red":
		# Attacking a skulled player: attacker gets yellow skull visible to victim
		_set_yellow_skull(attacker_id, victim_id)
	# Track PVP target
	_pvp_targets[attacker_id] = victim_id


## Called when a player kills another player. Handles frag counting and skull escalation.
func on_pvp_kill(killer_id: int, victim_id: int) -> void:
	if not server._sessions.has(killer_id) or not server._sessions.has(victim_id):
		return
	var victim_skull: String = get_skull(victim_id)
	# Check if this is a justified kill (victim had white/red skull or yellow for killer)
	var justified := false
	if victim_skull == "white" or victim_skull == "red":
		justified = true
	elif get_skull_for_viewer(killer_id, victim_id) == "yellow":
		justified = true

	if not justified:
		# Unjustified kill -- add frag
		_add_frag(killer_id)
		_set_white_skull(killer_id)
	# Justified kill -- no skull penalty for killing a skulled player

	# Clear PVP target
	_pvp_targets.erase(killer_id)
	# Clear victim's skull on death and broadcast the change
	var vs: Dictionary = server._sessions[victim_id]
	vs["skull"] = "none"
	vs["skull_expires_ms"] = 0
	# Clear all yellow skull entries for the victim (both directions)
	vs["_yellow_skull_for"] = {}
	# Also clear any yellow skull the killer has toward the victim
	if server._sessions.has(killer_id):
		var ks: Dictionary = server._sessions[killer_id]
		var killer_yellow: Dictionary = ks.get("_yellow_skull_for", {})
		killer_yellow.erase(victim_id)
	_broadcast_skull(victim_id)
	_broadcast_skull(killer_id)
	vs.erase("_yellow_skull_for")
	_broadcast_skull(victim_id)


## Returns true if the kill of victim_id should drop ALL items (red skull penalty).
func should_drop_all_items(peer_id: int) -> bool:
	return get_skull(peer_id) == "red"


## Applies PVP damage scaling (50% reduction).
func scale_pvp_damage(damage: int) -> int:
	return maxi(int(float(damage) * PVP_DAMAGE_FACTOR), 0)


## Sets white skull on a player. Resets the 15-minute timer on each offense.
func _set_white_skull(peer_id: int) -> void:
	if not server._sessions.has(peer_id):
		return
	var s: Dictionary = server._sessions[peer_id]
	# Don't downgrade red skull to white
	if get_skull(peer_id) == "red":
		return
	s["skull"] = "white"
	s["skull_expires_ms"] = Time.get_ticks_msec() + WHITE_SKULL_DURATION_MS
	_broadcast_skull(peer_id)


## Sets a yellow skull on [param target_id] visible only to [param viewer_id].
func _set_yellow_skull(target_id: int, viewer_id: int) -> void:
	if not server._sessions.has(target_id):
		return
	var s: Dictionary = server._sessions[target_id]
	if not s.has("_yellow_skull_for"):
		s["_yellow_skull_for"] = {}
	s["_yellow_skull_for"][viewer_id] = Time.get_ticks_msec() + WHITE_SKULL_DURATION_MS
	# Send skull update only to the viewer
	_send_skull_to_peer(viewer_id, target_id)


## Adds an unjustified kill (frag) to the killer's record and checks red skull threshold.
func _add_frag(killer_id: int) -> void:
	if not server._sessions.has(killer_id):
		return
	var s: Dictionary = server._sessions[killer_id]
	if not s.has("_frags"):
		s["_frags"] = []
	var now_ms := Time.get_ticks_msec()
	s["_frags"].append(now_ms)
	# Check red skull thresholds
	var day_ago: float = now_ms - 24.0 * 60 * 60 * 1000
	var week_ago: float = now_ms - 7.0 * 24 * 60 * 60 * 1000
	var month_ago: float = now_ms - 30.0 * 24 * 60 * 60 * 1000
	var day_count := 0
	var week_count := 0
	var month_count := 0
	for frag_ms in s["_frags"]:
		if float(frag_ms) >= day_ago: day_count += 1
		if float(frag_ms) >= week_ago: week_count += 1
		if float(frag_ms) >= month_ago: month_count += 1
	if day_count >= FRAGS_DAY or week_count >= FRAGS_WEEK or month_count >= FRAGS_MONTH:
		s["skull"] = "red"
		s["skull_expires_ms"] = now_ms + RED_SKULL_DURATION_MS
		_broadcast_skull(killer_id)
		server.rpc_id(killer_id, "rpc_receive_chat", "system", "",
			"You have received a red skull for excessive unjustified killing.")


## Broadcasts a player's skull to all nearby players.
func _broadcast_skull(peer_id: int) -> void:
	if not server._sessions.has(peer_id):
		return
	var pos: Vector3i = server._sessions[peer_id]["position"]
	var skull: String = get_skull(peer_id)
	for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
		# Each viewer may see a different skull (yellow is per-viewer)
		var viewer_skull: String = get_skull_for_viewer(pid, peer_id)
		server.rpc_id(pid, "rpc_player_skull", peer_id, viewer_skull)


## Sends the skull of [param target_id] to a specific viewer.
func _send_skull_to_peer(viewer_id: int, target_id: int) -> void:
	if not server.is_peer_active(viewer_id):
		return
	var skull: String = get_skull_for_viewer(viewer_id, target_id)
	server.rpc_id(viewer_id, "rpc_player_skull", target_id, skull)


## Ticks skull expiry timers. Called from server_main._process().
func process_skulls(_delta: float) -> void:
	var now_ms := Time.get_ticks_msec()
	for peer_id in server._sessions:
		var s: Dictionary = server._sessions[peer_id]
		if s.get("_orphan", false):
			continue
		var skull: String = str(s.get("skull", "none"))
		if skull == "none":
			continue
		var expires: float = float(s.get("skull_expires_ms", 0))
		if expires > 0 and now_ms >= expires:
			s["skull"] = "none"
			s["skull_expires_ms"] = 0
			_broadcast_skull(peer_id)
		# Clean expired yellow skulls
		if s.has("_yellow_skull_for"):
			var yellow: Dictionary = s["_yellow_skull_for"]
			for vid in yellow.keys():
				if now_ms >= float(yellow[vid]):
					yellow.erase(vid)
					if server.is_peer_active(vid):
						_send_skull_to_peer(vid, peer_id)
	# Clean old frags (older than 30 days)
	var month_ago: float = now_ms - 30.0 * 24 * 60 * 60 * 1000
	for peer_id in server._sessions:
		var s: Dictionary = server._sessions[peer_id]
		if s.has("_frags"):
			var frags: Array = s["_frags"]
			while not frags.is_empty() and float(frags[0]) < month_ago:
				frags.pop_front()


## Returns true if the attacker is in a PVP fight (has a PVP target).
func is_pvp_target(peer_id: int) -> bool:
	return _pvp_targets.has(peer_id)


## Returns the PVP victim peer_id for the given attacker, or -1.
func get_pvp_target(attacker_id: int) -> int:
	return int(_pvp_targets.get(attacker_id, -1))


## Clears PVP state for a disconnecting player.
func on_peer_disconnect(peer_id: int) -> void:
	_pvp_targets.erase(peer_id)
	# Remove this peer from all yellow skull lists
	for pid in server._sessions:
		var s: Dictionary = server._sessions[pid]
		if s.has("_yellow_skull_for"):
			s["_yellow_skull_for"].erase(peer_id)
