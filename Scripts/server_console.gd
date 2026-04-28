# server_console.gd -- Headless server command line interface
#
# Reads stdin in a background thread and processes admin commands.
# Commands: save, shutdown, status, broadcast, kick, online
extends Node

var server: Node = null
var _thread: Thread = null
var _running: bool = false
var _command_queue: Array = []  # Thread-safe queue: commands pushed by thread, popped by _process
var _mutex: Mutex = null


func start() -> void:
	_mutex = Mutex.new()
	_running = true
	_thread = Thread.new()
	_thread.start(_read_stdin_loop)
	print("console: server console ready. Type 'help' for commands.")


func stop() -> void:
	_running = false
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()


func _read_stdin_loop() -> void:
	while _running:
		var line := OS.read_string_from_stdin()
		if line.is_empty():
			OS.delay_msec(100)
			continue
		line = line.strip_edges()
		if line.is_empty():
			continue
		_mutex.lock()
		_command_queue.append(line)
		_mutex.unlock()


## Called every frame from server_main._process() to drain the command queue.
func process_commands() -> void:
	_mutex.lock()
	var cmds := _command_queue.duplicate()
	_command_queue.clear()
	_mutex.unlock()
	for cmd in cmds:
		_execute(cmd)


func _execute(input: String) -> void:
	var parts := input.split(" ", true, 1)
	var cmd: String = parts[0].to_lower()
	var args: String = parts[1].strip_edges() if parts.size() > 1 else ""

	match cmd:
		"help":
			print("--- Server Commands ---")
			print("  save        - Save all players and ground items")
			print("  shutdown    - Save and stop the server")
			print("  status      - Show server status")
			print("  online      - List online players")
			print("  broadcast   - Send message to all players")
			print("  kick <name> - Kick a player by character name")
			print("  reload      - Reload datapacks (items, monsters, spells)")
			print("-----------------------")

		"save":
			print("Saving...")
			server.db.save_all_and_backup()
			print("Save complete.")

		"shutdown", "stop", "exit", "quit":
			print("Shutting down server...")
			server.db.save_all_and_backup()
			# Disconnect all players gracefully
			for peer_id in server._sessions.keys():
				if server.is_peer_active(peer_id):
					server.rpc_id(peer_id, "rpc_receive_chat", "system", "",
						"Server is shutting down.")
			# Give a moment for packets to send
			await server.get_tree().create_timer(0.5).timeout
			server.get_tree().quit()

		"status":
			var player_count := 0
			for pid in server._sessions:
				if not server._sessions[pid].get("_orphan", false):
					player_count += 1
			var entity_count: int = server.entities._entities.size()
			var uptime_sec: float = Time.get_ticks_msec() / 1000.0
			var uptime_min: int = int(uptime_sec / 60.0)
			var uptime_hr: int = int(uptime_min / 60)
			print("--- Server Status ---")
			print("  Players online: %d" % player_count)
			print("  Monsters alive: %d" % entity_count)
			print("  Uptime: %dh %dm" % [uptime_hr, uptime_min % 60])
			print("---------------------")

		"online":
			var count := 0
			for pid in server._sessions:
				var s: Dictionary = server._sessions[pid]
				if s.get("_orphan", false):
					continue
				var name: String = str(s.get("display_name", "???"))
				var lvl: int = int(s.get("level", 1))
				var pos: Vector3i = s["position"]
				print("  [%d] %s (Lv.%d) at (%d,%d,%d)" % [pid, name, lvl, pos.x, pos.y, pos.z])
				count += 1
			if count == 0:
				print("  No players online.")

		"broadcast":
			if args.is_empty():
				print("Usage: broadcast <message>")
				return
			for pid in server._sessions:
				if server.is_peer_active(pid):
					server.rpc_id(pid, "rpc_receive_chat", "broadcast", "Server", args)
			print("Broadcast sent: %s" % args)

		"kick":
			if args.is_empty():
				print("Usage: kick <character_name>")
				return
			var target_name := args.to_lower()
			for pid in server._sessions:
				var s: Dictionary = server._sessions[pid]
				if str(s.get("display_name", "")).to_lower() == target_name:
					server.rpc_id(pid, "rpc_receive_chat", "system", "",
						"You have been kicked from the server.")
					server.auth._save_and_remove(pid)
					print("Kicked: %s" % args)
					return
			print("Player '%s' not found." % args)

		"reload":
			print("Reloading datapacks...")
			server.datapacks.load_all()
			server.spells._load_spell_defs()
			server.spells._load_area_patterns()
			print("Datapacks reloaded.")

		_:
			print("Unknown command: '%s'. Type 'help' for available commands." % cmd)
