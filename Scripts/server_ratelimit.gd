#  server_ratelimit.gd -- Per-peer RPC rate limiting and flood protection
#
#  Tracks call counts per peer per RPC category. Kicks peers that exceed
#  thresholds. Prevents login spam, spell spam, movement injection, and
#  general packet flooding.
extends Node

var server: Node = null

# Rate limit buckets: peer_id -> { category -> { "count": int, "window_start_ms": int } }
var _buckets: Dictionary = {}

# Peers flagged for kick at end of frame (avoids modifying dict during iteration)
var _kick_queue: Array = []

# Warnings before kick (soft limit)
var _warnings: Dictionary = {}  # peer_id -> int

const MAX_WARNINGS := 3

# Rate limit definitions: category -> { max_calls, window_ms }
# These are generous enough for legitimate play but catch automated spam.
const LIMITS := {
	"login":       {"max_calls": 5,   "window_ms": 10000},  # 5 login attempts per 10s
	"register":    {"max_calls": 3,   "window_ms": 30000},  # 3 registrations per 30s
	"movement":    {"max_calls": 20,  "window_ms": 1000},   # 20 move packets per second
	"spell":       {"max_calls": 6,   "window_ms": 1000},   # 6 spell casts per second
	"rune":        {"max_calls": 4,   "window_ms": 1000},   # 4 rune uses per second
	"chat":        {"max_calls": 10,  "window_ms": 5000},   # 10 messages per 5s
	"item":        {"max_calls": 20,  "window_ms": 1000},   # 20 item operations per second
	"container":   {"max_calls": 15,  "window_ms": 1000},   # 15 container ops per second
	"combat":      {"max_calls": 10,  "window_ms": 1000},   # 10 attack requests per second
	"general":     {"max_calls": 60,  "window_ms": 1000},   # 60 total RPCs per second (catch-all)
}


## Returns true if the call is allowed. Returns false if rate-limited (caller should drop the RPC).
func check(peer_id: int, category: String) -> bool:
	if not LIMITS.has(category):
		category = "general"
	var limit: Dictionary = LIMITS[category]
	var now_ms := Time.get_ticks_msec()

	if not _buckets.has(peer_id):
		_buckets[peer_id] = {}
	var peer_buckets: Dictionary = _buckets[peer_id]

	if not peer_buckets.has(category):
		peer_buckets[category] = {"count": 0, "window_start_ms": now_ms}

	var bucket: Dictionary = peer_buckets[category]

	# Reset window if expired
	if now_ms - int(bucket["window_start_ms"]) >= int(limit["window_ms"]):
		bucket["count"] = 0
		bucket["window_start_ms"] = now_ms

	bucket["count"] = int(bucket["count"]) + 1

	if int(bucket["count"]) > int(limit["max_calls"]):
		_on_rate_exceeded(peer_id, category)
		return false

	# Also check global rate (catch-all)
	if category != "general":
		return check(peer_id, "general")

	return true


## Called when a peer exceeds a rate limit. Issues warnings, then kicks.
func _on_rate_exceeded(peer_id: int, category: String) -> void:
	if not _warnings.has(peer_id):
		_warnings[peer_id] = 0
	_warnings[peer_id] = int(_warnings[peer_id]) + 1

	if int(_warnings[peer_id]) >= MAX_WARNINGS:
		print("ratelimit: KICKING peer %d -- exceeded %s limit (%d warnings)" % [peer_id, category, int(_warnings[peer_id])])
		if not _kick_queue.has(peer_id):
			_kick_queue.append(peer_id)
	else:
		print("ratelimit: WARNING peer %d -- %s rate exceeded (%d/%d)" % [peer_id, category, int(_warnings[peer_id]), MAX_WARNINGS])


## Processes the kick queue. Called from server_main._process().
func process_kicks() -> void:
	for peer_id in _kick_queue:
		# Send a message before kicking if possible
		if server.is_peer_active(peer_id):
			server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
				"You have been disconnected for flooding the server.")
		# Force disconnect
		if server._peer != null:
			server._peer.disconnect_peer(peer_id)
		# Clean up
		on_peer_disconnect(peer_id)
	_kick_queue.clear()


## Cleans up rate limit data for a disconnected peer.
func on_peer_disconnect(peer_id: int) -> void:
	_buckets.erase(peer_id)
	_warnings.erase(peer_id)
