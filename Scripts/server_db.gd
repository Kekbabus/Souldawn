#  server_db.gd -- SQLite persistence for accounts and characters
#
#  Uses the godot-sqlite addon. Stores accounts, character stats,
#  position, inventory, equipment. Auto-creates schema on first run.
extends Node

const DB_PATH := "user://game.db"

var server: Node = null
var db: SQLite = null


## Opens the SQLite database at DB_PATH, creating the schema if needed.
func open() -> bool:
	db = SQLite.new()
	db.path = DB_PATH
	db.foreign_keys = true
	if not db.open_db():
		push_error("server_db: failed to open -- %s" % db.error_message)
		return false
	_init_schema()
	print("server_db: opened at %s" % DB_PATH)
	return true


## Closes the database connection.
func close() -> void:
	if db != null:
		db.close_db()


## Creates accounts/characters tables and runs column migrations for new fields.
func _init_schema() -> void:
	db.query("CREATE TABLE IF NOT EXISTS accounts (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		username TEXT NOT NULL UNIQUE,
		password_hash TEXT NOT NULL,
		created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
	)")
	db.query("CREATE TABLE IF NOT EXISTS characters (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		account_id INTEGER NOT NULL,
		name TEXT NOT NULL UNIQUE,
		level INTEGER NOT NULL DEFAULT 1,
		experience INTEGER NOT NULL DEFAULT 0,
		health INTEGER NOT NULL DEFAULT 150,
		max_health INTEGER NOT NULL DEFAULT 150,
		mana INTEGER NOT NULL DEFAULT 50,
		max_mana INTEGER NOT NULL DEFAULT 50,
		pos_x INTEGER NOT NULL DEFAULT 0,
		pos_y INTEGER NOT NULL DEFAULT 0,
		pos_z INTEGER NOT NULL DEFAULT 7,
		speed REAL NOT NULL DEFAULT 220.0,
		inventory TEXT NOT NULL DEFAULT '[]',
		equipment TEXT NOT NULL DEFAULT '{}',
		outfit_id TEXT NOT NULL DEFAULT 'citizen_male',
		outfit_head TEXT NOT NULL DEFAULT '#ffff00',
		outfit_body TEXT NOT NULL DEFAULT '#4d80ff',
		outfit_legs TEXT NOT NULL DEFAULT '#4d80ff',
		outfit_feet TEXT NOT NULL DEFAULT '#996633',
		skills TEXT NOT NULL DEFAULT '{}',
		vocation TEXT NOT NULL DEFAULT 'none',
		FOREIGN KEY (account_id) REFERENCES accounts(id)
	)")
	# Migration: add columns to existing databases (skip if already present)
	db.query("PRAGMA table_info(characters)")
	var existing_cols: Dictionary = {}
	for row in db.query_result:
		existing_cols[str(row.get("name", ""))] = true
	if not existing_cols.has("outfit_id"):
		db.query("ALTER TABLE characters ADD COLUMN outfit_id TEXT NOT NULL DEFAULT 'citizen_male'")
	if not existing_cols.has("outfit_head"):
		db.query("ALTER TABLE characters ADD COLUMN outfit_head TEXT NOT NULL DEFAULT '#ffff00'")
	if not existing_cols.has("outfit_body"):
		db.query("ALTER TABLE characters ADD COLUMN outfit_body TEXT NOT NULL DEFAULT '#4d80ff'")
	if not existing_cols.has("outfit_legs"):
		db.query("ALTER TABLE characters ADD COLUMN outfit_legs TEXT NOT NULL DEFAULT '#4d80ff'")
	if not existing_cols.has("outfit_feet"):
		db.query("ALTER TABLE characters ADD COLUMN outfit_feet TEXT NOT NULL DEFAULT '#996633'")
		db.query("ALTER TABLE characters ADD COLUMN outfit_feet TEXT NOT NULL DEFAULT '#996633'")
	if not existing_cols.has("skills"):
		db.query("ALTER TABLE characters ADD COLUMN skills TEXT NOT NULL DEFAULT '{}'")
	if not existing_cols.has("vocation"):
		db.query("ALTER TABLE characters ADD COLUMN vocation TEXT NOT NULL DEFAULT 'none'")
	if not existing_cols.has("food_timer"):
		db.query("ALTER TABLE characters ADD COLUMN food_timer REAL NOT NULL DEFAULT 0.0")
	if not existing_cols.has("equip_counts"):
		db.query("ALTER TABLE characters ADD COLUMN equip_counts TEXT NOT NULL DEFAULT '{}'")
	if not existing_cols.has("gender"):
		db.query("ALTER TABLE characters ADD COLUMN gender TEXT NOT NULL DEFAULT 'male'")

#  ACCOUNT OPERATIONS

## Returns true if an account with the given username exists.
func account_exists(username: String) -> bool:
	db.query_with_bindings("SELECT id FROM accounts WHERE username = ?", [username])
	return db.query_result.size() > 0


func create_account(username: String, password_hash: String) -> int:
	## Returns account_id or -1 on failure.
	db.query_with_bindings(
		"INSERT INTO accounts (username, password_hash) VALUES (?, ?)",
		[username, password_hash])
	if db.query_result.size() > 0:
		return int(db.query_result[0].get("id", -1))
	# Get the last inserted id
	db.query("SELECT last_insert_rowid() as id")
	if db.query_result.size() > 0:
		return int(db.query_result[0].get("id", -1))
	return -1


func verify_account(username: String, password_hash: String) -> int:
	## Returns account_id if credentials match, -1 otherwise.
	db.query_with_bindings(
		"SELECT id FROM accounts WHERE username = ? AND password_hash = ?",
		[username, password_hash])
	if db.query_result.size() > 0:
		return int(db.query_result[0]["id"])
	return -1


## Returns true if a character with the given name exists (case-insensitive).
func character_name_exists(name: String) -> bool:
	db.query_with_bindings("SELECT id FROM characters WHERE LOWER(name) = LOWER(?)", [name])
	return db.query_result.size() > 0


func create_character(account_id: int, name: String, vocation: String = "none", gender: String = "male") -> int:
	## Returns character_id or -1 on failure.
	if gender != "male" and gender != "female":
		gender = "male"
	var outfit := "citizen_female" if gender == "female" else "citizen_male"
	db.query_with_bindings(
		"INSERT INTO characters (account_id, name, vocation, gender, outfit_id) VALUES (?, ?, ?, ?, ?)",
		[account_id, name, vocation, gender, outfit])
	db.query("SELECT last_insert_rowid() as id")
	if db.query_result.size() > 0:
		return int(db.query_result[0].get("id", -1))
	return -1


func get_character_by_account(account_id: int) -> Dictionary:
	## Returns character data or empty dict.
	db.query_with_bindings("SELECT * FROM characters WHERE account_id = ? LIMIT 1", [account_id])
	if db.query_result.size() > 0:
		return db.query_result[0]
	return {}


func get_characters_by_account(account_id: int) -> Array:
	## Returns all characters for an account as Array of Dictionaries.
	db.query_with_bindings("SELECT id, name, level FROM characters WHERE account_id = ? ORDER BY id", [account_id])
	return db.query_result.duplicate()


func get_character_by_id(char_id: int, account_id: int) -> Dictionary:
	## Returns character data if it belongs to the account, or empty dict.
	db.query_with_bindings("SELECT * FROM characters WHERE id = ? AND account_id = ?", [char_id, account_id])
	if db.query_result.size() > 0:
		return db.query_result[0]
	return {}


#  CHARACTER SAVE/LOAD

func save_character(char_id: int, data: Dictionary) -> void:
	## Saves session data back to the database.
	var clean_inv: Array = _clean_inventory_for_save(data.get("inventory", []))
	var inv_json := JSON.stringify(clean_inv)
	var equip_json := JSON.stringify(data.get("equipment", {}))
	db.query_with_bindings(
		"UPDATE characters SET level=?, experience=?, health=?, max_health=?,
		mana=?, max_mana=?, pos_x=?, pos_y=?, pos_z=?, speed=?,
		inventory=?, equipment=?, outfit_id=?, outfit_head=?, outfit_body=?,
		outfit_legs=?, outfit_feet=?, skills=?, vocation=?, food_timer=?, equip_counts=?, gender=? WHERE id=?",
		[
			int(data.get("level", 1)),
			int(data.get("experience", 0)),
			int(data.get("health", 150)),
			int(data.get("max_health", 150)),
			int(data.get("mana", 50)),
			int(data.get("max_mana", 50)),
			int(data.get("pos_x", 0)),
			int(data.get("pos_y", 0)),
			int(data.get("pos_z", 7)),
			float(data.get("speed", 220.0)),
			inv_json,
			equip_json,
			str(data.get("outfit_id", "citizen_male")),
			str(data.get("outfit_head", "#ffff00")),
			str(data.get("outfit_body", "#4d80ff")),
			str(data.get("outfit_legs", "#4d80ff")),
			str(data.get("outfit_feet", "#996633")),
			JSON.stringify(data.get("skills", {})),
			str(data.get("vocation", "none")),
			float(data.get("food_timer", 0.0)),
			JSON.stringify(data.get("equip_counts", {})),
			str(data.get("gender", "male")),
			char_id,
		])


func load_character_into_session(char_data: Dictionary) -> Dictionary:
	## Converts a DB row into a session dictionary.
	var inv: Array = []
	var inv_raw = char_data.get("inventory", "[]")
	if inv_raw is String and not inv_raw.is_empty():
		var json := JSON.new()
		if json.parse(inv_raw) == OK and json.data is Array:
			inv = json.data

	var equip: Dictionary = {"head": "", "armor": "", "legs": "", "weapon": ""}
	var equip_raw = char_data.get("equipment", "{}")
	if equip_raw is String and not equip_raw.is_empty():
		var json := JSON.new()
		if json.parse(equip_raw) == OK and json.data is Dictionary:
			equip = json.data

	var skills: Dictionary = {}
	var skills_raw = char_data.get("skills", "{}")
	if skills_raw is String and not skills_raw.is_empty():
		var json := JSON.new()
		if json.parse(skills_raw) == OK and json.data is Dictionary:
			skills = json.data

	var equip_counts: Dictionary = {}
	var ec_raw = char_data.get("equip_counts", "{}")
	if ec_raw is String and not ec_raw.is_empty():
		var json := JSON.new()
		if json.parse(ec_raw) == OK and json.data is Dictionary:
			equip_counts = json.data

	return {
		"char_id": int(char_data.get("id", 0)),
		"display_name": str(char_data.get("name", "")),
		"level": int(char_data.get("level", 1)),
		"experience": int(char_data.get("experience", 0)),
		"health": int(char_data.get("health", 150)),
		"max_health": int(char_data.get("max_health", 150)),
		"mana": int(char_data.get("mana", 50)),
		"max_mana": int(char_data.get("max_mana", 50)),
		"speed": float(char_data.get("speed", 220.0)),
		"pos_x": int(char_data.get("pos_x", 0)),
		"pos_y": int(char_data.get("pos_y", 0)),
		"pos_z": int(char_data.get("pos_z", 7)),
		"inventory": inv,
		"equipment": equip,
		"outfit_id": str(char_data.get("outfit_id", "citizen_male")),
		"outfit_head": str(char_data.get("outfit_head", "#ffff00")),
		"outfit_body": str(char_data.get("outfit_body", "#4d80ff")),
		"outfit_legs": str(char_data.get("outfit_legs", "#4d80ff")),
		"outfit_feet": str(char_data.get("outfit_feet", "#996633")),
		"skills": skills,
		"vocation": str(char_data.get("vocation", "none")),
		"food_timer": float(char_data.get("food_timer", 0.0)),
		"equip_counts": equip_counts,
		"gender": str(char_data.get("gender", "male")),
	}


func _clean_inventory_for_save(items: Array) -> Array:
	## Removes internal runtime fields (_cid, _ground_cid) from items before saving.
	var result: Array = []
	for item in items:
		var clean := {"item_id": str(item["item_id"]), "count": int(item["count"])}
		if item.has("children") and item["children"] is Array:
			clean["children"] = _clean_inventory_for_save(item["children"])
		result.append(clean)
	return result


#  PERIODIC AUTO-SAVE & BACKUP SYSTEM

const SAVE_INTERVAL := 600.0  # 10 minutes between auto-saves
const BACKUP_RETENTION_DAYS := 7
const BACKUP_DIR := "user://backup/db"
const GROUND_BACKUP_DIR := "user://backup/ground"


## Restores ground items from the most recent backup file on server startup.
func restore_ground_items() -> void:
	if server == null or server.inventory == null:
		return
	var abs_dir := ProjectSettings.globalize_path(GROUND_BACKUP_DIR)
	var dir := DirAccess.open(abs_dir)
	if dir == null:
		print("server_db: no ground backup directory found, skipping restore")
		return
	# Find the newest .json file
	var newest_file := ""
	var newest_time := ""
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json") and fname > newest_time:
			newest_time = fname
			newest_file = fname
		fname = dir.get_next()
	if newest_file.is_empty():
		print("server_db: no ground backup files found")
		return
	var file_path := abs_dir.path_join(newest_file)
	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		push_warning("server_db: failed to open ground backup: %s" % file_path)
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK or not json.data is Dictionary:
		file.close()
		push_warning("server_db: failed to parse ground backup")
		return
	file.close()
	var data: Dictionary = json.data
	var ground_count := 0
	var ground_items: Array = data.get("ground_items", [])
	for entry in ground_items:
		if not entry is Dictionary:
			continue
		var pos := Vector3i(int(entry.get("x", 0)), int(entry.get("y", 0)), int(entry.get("z", 7)))
		var items: Array = entry.get("items", [])
		for item in items:
			var item_id: String = str(item.get("item_id", ""))
			var count: int = int(item.get("count", 1))
			if not item_id.is_empty() and count > 0:
				server.inventory._add_ground_item(pos, item_id, count)
				ground_count += 1
	print("server_db: restored %d ground item stacks from %s" % [ground_count, newest_file])

var _save_acc: float = 0.0


func process_auto_save(delta: float) -> void:
	## Called from server_main._process(). Triggers save + backup every hour.
	_save_acc += delta
	if _save_acc < SAVE_INTERVAL:
		return
	_save_acc -= SAVE_INTERVAL
	save_all_and_backup()


func save_all_players() -> void:
	## Saves all online player sessions to the database.
	if server == null:
		return
	var count := 0
	for peer_id in server._sessions:
		var s: Dictionary = server._sessions[peer_id]
		if s.get("_orphan", false):
			continue
		var char_id: int = int(s.get("char_id", 0))
		if char_id <= 0:
			continue
		var pos: Vector3i = s["position"]
		save_character(char_id, {
			"level": s["level"],
			"experience": s["experience"],
			"health": s["health"],
			"max_health": s["max_health"],
			"mana": s["mana"],
			"max_mana": s["max_mana"],
			"pos_x": pos.x,
			"pos_y": pos.y,
			"pos_z": pos.z,
			"speed": s["speed"],
			"inventory": s["inventory"],
			"equipment": s["equipment"],
			"outfit_id": s.get("outfit_id", "citizen_male"),
			"outfit_head": s.get("outfit_head", "#ffff00"),
			"outfit_body": s.get("outfit_body", "#4d80ff"),
			"outfit_legs": s.get("outfit_legs", "#4d80ff"),
			"outfit_feet": s.get("outfit_feet", "#996633"),
			"skills": s.get("skills", {}),
			"vocation": s.get("vocation", "none"),
			"food_timer": s.get("food_timer", 0.0),
			"equip_counts": s.get("equip_counts", {}),
		})
		count += 1
	print("server_db: saved %d player sessions" % count)


func save_all_and_backup() -> void:
	## Full save: save all players, backup DB, backup ground items.
	save_all_players()
	_backup_database()
	_backup_ground_items()
	_cleanup_old_backups()


func force_save_and_backup() -> void:
	## Manual trigger (GM command). Resets the auto-save timer.
	_save_acc = 0.0
	save_all_and_backup()
	print("server_db: forced save + backup complete")


func _backup_database() -> void:
	## Copies the current DB file to backup/db/YYYY-MM-DD_HH-MM-SS.db
	var timestamp := _get_timestamp_string()
	var backup_path := BACKUP_DIR.path_join(timestamp + ".db")
	# Ensure backup directory exists
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BACKUP_DIR))
	# Copy the DB file
	var src_path := ProjectSettings.globalize_path(DB_PATH)
	var dst_path := ProjectSettings.globalize_path(backup_path)
	var err := DirAccess.copy_absolute(src_path, dst_path)
	if err == OK:
		print("server_db: DB backup -> %s" % backup_path)
	else:
		push_warning("server_db: DB backup failed -- %s" % error_string(err))


func _backup_ground_items() -> void:
	## Saves ground items + container contents to a JSON backup file.
	## Excludes transient items (fire_field, energy_field, etc.)
	if server == null or server.inventory == null:
		return
	var timestamp := _get_timestamp_string()
	var backup_path := GROUND_BACKUP_DIR.path_join(timestamp + ".json")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(GROUND_BACKUP_DIR))

	var transient_types := ["fire_field", "energy_field", "poison_field", "magic_wall"]
	var ground_data: Array = []
	for pos in server.inventory._ground_items:
		var items: Array = server.inventory._ground_items[pos]
		var clean_items: Array = []
		for item in items:
			var item_id: String = str(item.get("item_id", ""))
			if item_id in transient_types:
				continue
			clean_items.append({
				"item_id": item_id,
				"count": int(item.get("count", 1)),
			})
		if not clean_items.is_empty():
			ground_data.append({
				"x": pos.x, "y": pos.y, "z": pos.z,
				"items": clean_items,
			})

	# Also save non-corpse container contents
	var container_data: Array = []
	if server.containers != null:
		for cid in server.containers._containers:
			var c: Dictionary = server.containers._containers[cid]
			# Skip corpses (they decay) and player backpacks (negative cids)
			if int(cid) < 0:
				continue
			if c.get("is_corpse", false):
				continue
			var c_items: Array = c.get("items", [])
			if c_items.is_empty():
				continue
			var c_pos = c.get("position", Vector3i.ZERO)
			container_data.append({
				"container_id": int(cid),
				"name": str(c.get("display_name", "")),
				"x": c_pos.x, "y": c_pos.y, "z": c_pos.z,
				"items": _clean_inventory_for_save(c_items),
			})

	var backup := {"ground_items": ground_data, "containers": container_data}
	var json_str := JSON.stringify(backup, "  ")
	var abs_path := ProjectSettings.globalize_path(backup_path)
	var file := FileAccess.open(abs_path, FileAccess.WRITE)
	if file:
		file.store_string(json_str)
		file.close()
		print("server_db: ground backup -> %s (%d ground stacks, %d containers)" % [
			backup_path, ground_data.size(), container_data.size()])
	else:
		push_warning("server_db: ground backup failed -- could not write %s" % abs_path)


func _cleanup_old_backups() -> void:
	## Removes backup files older than BACKUP_RETENTION_DAYS.
	var cutoff_unix := Time.get_unix_time_from_system() - (BACKUP_RETENTION_DAYS * 86400)
	_cleanup_dir(BACKUP_DIR, cutoff_unix)
	_cleanup_dir(GROUND_BACKUP_DIR, cutoff_unix)


## Deletes files in dir_path with timestamps older than cutoff_unix.
func _cleanup_dir(dir_path: String, cutoff_unix: float) -> void:
	var abs_dir := ProjectSettings.globalize_path(dir_path)
	var dir := DirAccess.open(abs_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir():
			# Parse timestamp from filename: YYYY-MM-DD_HH-MM-SS.ext
			var base := file_name.get_basename()
			var parts := base.split("_")
			if parts.size() >= 2:
				var date_str := parts[0]  # YYYY-MM-DD
				var time_str := parts[1].replace("-", ":")  # HH:MM:SS
				var dt := Time.get_unix_time_from_datetime_string("%sT%s" % [date_str, time_str])
				if dt > 0 and dt < cutoff_unix:
					dir.remove(file_name)
					print("server_db: removed old backup %s" % file_name)
		file_name = dir.get_next()
	dir.list_dir_end()


## Returns the current system time as "YYYY-MM-DD_HH-MM-SS" for backup filenames.
func _get_timestamp_string() -> String:
	var dt := Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02d_%02d-%02d-%02d" % [
		dt["year"], dt["month"], dt["day"],
		dt["hour"], dt["minute"], dt["second"]]
