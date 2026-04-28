#  server_chunks.gd -- Chunk streaming: sends map tile data to clients
#
#  Chunks are 16×16 tile regions. When a player connects or moves into
#  a new chunk area, unsent chunks within view range are streamed.
extends Node

const CHUNK_SIZE := 16
const VIEW_RANGE_CHUNKS := 2  # send chunks within 2 chunks of player (48 tiles)

var server: Node = null  # server_main.gd

var _sent_chunks: Dictionary = {}  # peer_id -> Dictionary of "cx_cy_cz" -> true
var _peer_z: Dictionary = {}       # peer_id -> current z-level


## Call when a player enters the game -- send all chunks around spawn.
func send_initial_chunks(peer_id: int, pos: Vector3i) -> void:
	_ensure_peer(peer_id)
	_peer_z[peer_id] = pos.z
	_send_chunks_around(peer_id, pos)


## Call when a player moves -- check if they crossed into a new chunk region.
func on_player_move(peer_id: int, old_pos: Vector3i, new_pos: Vector3i) -> void:
	var old_cx: int = _chunk_coord(old_pos.x)
	var old_cy: int = _chunk_coord(old_pos.y)
	var new_cx: int = _chunk_coord(new_pos.x)
	var new_cy: int = _chunk_coord(new_pos.y)
	if old_cx != new_cx or old_cy != new_cy or old_pos.z != new_pos.z:
		if old_pos.z != new_pos.z:
			_peer_z[peer_id] = new_pos.z
		_send_chunks_around(peer_id, new_pos)


## Clean up when a peer disconnects.
func on_peer_disconnect(peer_id: int) -> void:
	_sent_chunks.erase(peer_id)
	_peer_z.erase(peer_id)


## Initializes tracking for a peer if not already present.
func _ensure_peer(peer_id: int) -> void:
	if not _sent_chunks.has(peer_id):
		_sent_chunks[peer_id] = {}


## Converts a tile coordinate to its chunk coordinate.
func _chunk_coord(tile: int) -> int:
	if tile >= 0:
		@warning_ignore("integer_division")
		return tile / CHUNK_SIZE
	@warning_ignore("integer_division")
	return (tile - CHUNK_SIZE + 1) / CHUNK_SIZE


## Returns a unique string key for a chunk at (cx, cy, cz).
func _chunk_key(cx: int, cy: int, cz: int) -> String:
	return "%d_%d_%d" % [cx, cy, cz]


## Sends all unsent chunks within VIEW_RANGE_CHUNKS of the player's position.
func _send_chunks_around(peer_id: int, pos: Vector3i) -> void:
	var center_cx: int = _chunk_coord(pos.x)
	var center_cy: int = _chunk_coord(pos.y)
	var z: int = pos.z
	var sent: Dictionary = _sent_chunks.get(peer_id, {})

	# Send chunks for the player's z-level and floors above (for roof rendering)
	# Also send one floor below for see-through
	var z_min: int = maxi(z - 1, 0)
	var z_max: int = mini(z + 3, 15)  # up to 3 floors above
	for cz in range(z_min, z_max + 1):
		for cx in range(center_cx - VIEW_RANGE_CHUNKS, center_cx + VIEW_RANGE_CHUNKS + 1):
			for cy in range(center_cy - VIEW_RANGE_CHUNKS, center_cy + VIEW_RANGE_CHUNKS + 1):
				var key: String = _chunk_key(cx, cy, cz)
				if sent.has(key):
					continue
				var chunk_data: Array = _build_chunk(cx, cy, cz)
				if chunk_data.is_empty():
					sent[key] = true
					continue
				sent[key] = true
				server.rpc_id(peer_id, "rpc_map_chunk", cx, cy, cz, chunk_data)


## Builds the chunk data array for a 16×16 region.
## Returns Array of [local_x, local_y, [tile_id, ...]] for non-empty positions.
func _build_chunk(cx: int, cy: int, z: int) -> Array:
	var result: Array = []
	var map_node: Node = server.map
	var origin_x: int = cx * CHUNK_SIZE
	var origin_y: int = cy * CHUNK_SIZE

	for lx in range(CHUNK_SIZE):
		for ly in range(CHUNK_SIZE):
			var world_pos := Vector3i(origin_x + lx, origin_y + ly, z)
			var stack: Array = map_node.get_tile_stack(world_pos)
			if stack.is_empty():
				continue
			result.append([lx, ly, stack])
	return result
