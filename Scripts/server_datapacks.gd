#  server_datapacks.gd -- Loads all JSON datapacks (items, loot tables,
#  monster abilities, monsters, NPCs, outfits) and provides lookup APIs
#  for every game system.
extends Node

const ITEM_PATHS := [
	"res://datapacks/items/items.json",
]

var server: Node = null

var items: Dictionary = {}  # String def_id -> full item definition

## Cached exe directory path for external datapack loading.
var _exe_dir: String = ""


## Resolves a res:// path to an external file next to the executable if it exists.
## Falls back to the original res:// path (baked in .pck) if no external file found.
func _resolve_path(res_path: String) -> String:
	if _exe_dir.is_empty():
		_exe_dir = OS.get_executable_path().get_base_dir()
	# Convert "res://datapacks/items/foo.json" -> "<exe_dir>/datapacks/items/foo.json"
	var relative := res_path.replace("res://", "")
	var external := _exe_dir.path_join(relative)
	if FileAccess.file_exists(external):
		return external
	return res_path


## Resolves a res:// directory path to an external directory if it exists.
func _resolve_dir(res_path: String) -> String:
	if _exe_dir.is_empty():
		_exe_dir = OS.get_executable_path().get_base_dir()
	var relative := res_path.replace("res://", "")
	var external := _exe_dir.path_join(relative)
	if DirAccess.dir_exists_absolute(external):
		return external
	return res_path


## Loads every datapack category (items, loot, abilities, monsters, NPCs, outfits).
func load_all() -> void:
	for path in ITEM_PATHS:
		_load_items(path)
	_load_loot_tables()
	_load_monster_abilities()
	_load_monsters()
	_load_npcs()
	_load_outfits()
	print("server_datapacks: loaded %d items, %d loot tables, %d abilities, %d monsters, %d npcs, %d outfits" % [
		items.size(), loot_tables.size(), monster_abilities.size(), monsters.size(), npcs.size(), outfits.size()])


## Parses a single item JSON file and merges entries into the items dictionary.
func _load_items(path: String) -> void:
	var resolved := _resolve_path(path)
	var file := FileAccess.open(resolved, FileAccess.READ)
	if file == null:
		push_warning("server_datapacks: Failed to open '%s'" % path)
		return
	var json := JSON.new()
	var err := json.parse(file.get_as_text())
	file.close()
	if err != OK:
		push_error("server_datapacks: Failed to parse '%s' -- %s" % [path, json.get_error_message()])
		return
	var data = json.data
	if not data is Array:
		push_error("server_datapacks: '%s' root is not an Array" % path)
		return
	for entry in data:
		if not entry is Dictionary:
			continue
		var def_id: String = str(entry.get("definition_id", ""))
		if def_id.is_empty():
			continue
		items[def_id] = entry


#  ITEM QUERIES

## Returns the full item definition dict, or empty if not found.
func get_item(def_id: String) -> Dictionary:
	return items.get(def_id, {})

## Returns the display name for an item, falling back to def_id.
func get_item_name(def_id: String) -> String:
	return str(items.get(def_id, {}).get("display_name", def_id))

## Returns true if the item supports stacking.
func is_stackable(def_id: String) -> bool:
	return bool(items.get(def_id, {}).get("stackable", false))

## Returns the maximum stack size for an item (defaults to 1).
func get_stack_size(def_id: String) -> int:
	return int(items.get(def_id, {}).get("stack_size", 1))

## Returns the normalized equipment slot name for an item.
func get_equip_slot(def_id: String) -> String:
	var raw_slot: String = str(items.get(def_id, {}).get("equip_slot", ""))
	return _normalize_equip_slot(raw_slot)

## Maps datapack slot names (e.g. "main_hand") to engine slot names (e.g. "weapon").
func _normalize_equip_slot(slot: String) -> String:
	match slot:
		"main_hand": return "weapon"
		"off_hand": return "shield"
		"helmet": return "head"
		"necklace": return "neck"
		_: return slot

## Returns the stat_modifiers dict (attack, defense, etc.) for an item.
func get_stat_modifiers(def_id: String) -> Dictionary:
	var item: Dictionary = items.get(def_id, {})
	return item.get("stat_modifiers", {}) if item.has("stat_modifiers") else {}

## Returns the item weight in ounces (defaults to 1.0).
func get_weight(def_id: String) -> float:
	return float(items.get(def_id, {}).get("weight", 1.0))

## Returns the gold value of an item (defaults to 0).
func get_value(def_id: String) -> int:
	return int(items.get(def_id, {}).get("value", 0))

## Returns the default sprite resource path for an item.
func get_sprite_path(def_id: String) -> String:
	return str(items.get(def_id, {}).get("sprite", ""))


func get_sprite_for_count(def_id: String, count: int) -> String:
	## Returns the sprite path appropriate for the given stack count.
	## Falls back to the default sprite if no sprite_by_count data.
	var item: Dictionary = items.get(def_id, {})
	var by_count: Array = item.get("sprite_by_count", [])
	if not by_count.is_empty():
		for entry in by_count:
			if count >= int(entry.get("min", 0)) and count <= int(entry.get("max", 0)):
				return str(entry.get("path", ""))
		# If count exceeds all ranges, use the last entry
		var last: Dictionary = by_count[by_count.size() - 1]
		return str(last.get("path", ""))
	return str(item.get("sprite", ""))

func get_item_color(def_id: String) -> String:
	## Returns a hex color for UI display. Falls back to item_type-based colors.
	var item: Dictionary = items.get(def_id, {})
	var item_type: String = str(item.get("item_type", "resource"))
	match item_type:
		"equipment": return "#C0C0C0"
		"rune": return "#6666FF"
		"food": return "#8B4513"
		"container": return "#8B6914"
		_: return "#FFD700"

## Returns true if the item's type is "container".
func is_container(def_id: String) -> bool:
	return str(items.get(def_id, {}).get("item_type", "")) == "container"

## Returns the number of inventory slots a container item provides.
func get_container_slots(def_id: String) -> int:
	return int(items.get(def_id, {}).get("container_slots", 0))


#  LOOT TABLES

var loot_tables: Dictionary = {}  # String table_id -> Array of entries


## Scans the loot_tables directory and loads all JSON loot table files.
func _load_loot_tables() -> void:
	var dir := DirAccess.open(_resolve_dir("res://datapacks/loot_tables"))
	if dir == null:
		push_warning("server_datapacks: loot_tables directory not found")
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.ends_with(".json"):
			_load_loot_table(_resolve_dir("res://datapacks/loot_tables").path_join(file_name))
		file_name = dir.get_next()
	dir.list_dir_end()
	print("server_datapacks: loaded %d loot tables" % loot_tables.size())


## Parses a single loot table JSON file and stores it by table_id.
func _load_loot_table(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		return
	file.close()
	var data = json.data
	if not data is Dictionary:
		return
	var table_id: String = str(data.get("table_id", ""))
	if table_id.is_empty():
		return
	var entries = data.get("entries", [])
	if not entries is Array:
		return
	loot_tables[table_id] = entries


func get_loot_table(monster_id: String) -> Array:
	## Returns loot entries for a monster. Tries "<monster_id>_loot" first.
	var table_id := monster_id + "_loot"
	if loot_tables.has(table_id):
		return loot_tables[table_id]
	if loot_tables.has(monster_id):
		return loot_tables[monster_id]
	return []


func roll_loot(monster_id: String) -> Array:
	## Rolls loot for a monster. Returns Array of {item_id, count}.
	var entries: Array = get_loot_table(monster_id)
	var result: Array = []
	for entry in entries:
		var chance: float = float(entry.get("chance", 0.0))
		if randf() * 100.0 > chance:
			continue
		var item_id: String = str(entry.get("item_definition_id", ""))
		if item_id.is_empty():
			continue
		var min_qty: int = int(entry.get("min_quantity", 1))
		var max_qty: int = int(entry.get("max_quantity", 1))
		var count: int = randi_range(min_qty, max_qty)
		if count > 0:
			result.append({"item_id": item_id, "count": count})
	return result


#  MONSTER ABILITIES (shared library)

var monster_abilities: Dictionary = {}  # ability_id -> Dictionary


## Scans the monster_abilities directory and loads all shared ability templates.
func _load_monster_abilities() -> void:
	var dir := DirAccess.open(_resolve_dir("res://datapacks/monster_abilities"))
	if dir == null:
		push_warning("server_datapacks: monster_abilities directory not found")
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.ends_with(".json"):
			var file := FileAccess.open(_resolve_dir("res://datapacks/monster_abilities").path_join(file_name), FileAccess.READ)
			if file:
				var json := JSON.new()
				if json.parse(file.get_as_text()) == OK and json.data is Dictionary:
					var ab_id: String = str(json.data.get("ability_id", ""))
					if not ab_id.is_empty():
						monster_abilities[ab_id] = json.data
				file.close()
		file_name = dir.get_next()
	dir.list_dir_end()


## Returns a shared monster ability template, or empty if not found.
func get_monster_ability(ability_id: String) -> Dictionary:
	return monster_abilities.get(ability_id, {})


func resolve_monster_abilities(monster_def: Dictionary) -> Array:
	## Resolves a monster's abilities -- supports:
	##   - String: reference to shared template (uses template defaults)
	##   - Dict with "id": reference + damage/chance overrides merged on top
	##   - Dict without "id": inline ability definition (used as-is)
	var raw: Array = monster_def.get("abilities", [])
	var resolved: Array = []
	for entry in raw:
		if entry is String:
			var ab: Dictionary = get_monster_ability(entry)
			if not ab.is_empty():
				resolved.append(ab.duplicate())
		elif entry is Dictionary:
			var ref_id: String = str(entry.get("id", ""))
			if not ref_id.is_empty():
				# Template reference with overrides
				var base: Dictionary = get_monster_ability(ref_id)
				if not base.is_empty():
					var merged: Dictionary = base.duplicate()
					# Override with monster-specific values
					for key in entry:
						if key != "id":
							merged[key] = entry[key]
					resolved.append(merged)
			else:
				# Inline ability
				resolved.append(entry)
	return resolved


#  MONSTER DEFINITIONS

var monsters: Dictionary = {}  # String def_id -> Dictionary


## Scans the monsters directory and loads all monster definition JSON files.
func _load_monsters() -> void:
	var dir := DirAccess.open(_resolve_dir("res://datapacks/monsters"))
	if dir == null:
		push_warning("server_datapacks: monsters directory not found")
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.ends_with(".json"):
			_load_monster(_resolve_dir("res://datapacks/monsters").path_join(file_name))
		file_name = dir.get_next()
	dir.list_dir_end()
	print("server_datapacks: loaded %d monster definitions" % monsters.size())


## Parses a single monster JSON file and stores it by definition_id.
func _load_monster(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		return
	file.close()
	var data = json.data
	if not data is Dictionary:
		return
	var def_id: String = str(data.get("definition_id", ""))
	if def_id.is_empty():
		return
	monsters[def_id] = data


## Returns a monster definition dict, or empty if not found.
func get_monster(def_id: String) -> Dictionary:
	return monsters.get(def_id, {})


#  NPC DEFINITIONS

var npcs: Dictionary = {}  # String def_id -> Dictionary


## Scans the npcs directory and loads all NPC definition JSON files.
func _load_npcs() -> void:
	var dir := DirAccess.open(_resolve_dir("res://datapacks/npcs"))
	if dir == null:
		push_warning("server_datapacks: npcs directory not found")
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.ends_with(".json"):
			_load_npc(_resolve_dir("res://datapacks/npcs").path_join(file_name))
		file_name = dir.get_next()
	dir.list_dir_end()
	print("server_datapacks: loaded %d NPC definitions" % npcs.size())


## Parses a single NPC JSON file and stores it by definition_id.
func _load_npc(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		return
	file.close()
	var data = json.data
	if not data is Dictionary:
		return
	var def_id: String = str(data.get("definition_id", ""))
	if def_id.is_empty():
		return
	npcs[def_id] = data


## Returns an NPC definition dict, or empty if not found.
func get_npc(def_id: String) -> Dictionary:
	return npcs.get(def_id, {})


## Builds a multi-line tooltip string for an item, including stats and weight.
func build_item_tooltip(def_id: String, item_instance: Dictionary = {}) -> String:
	var item: Dictionary = items.get(def_id, {})
	if item.is_empty():
		return def_id
	var lines: Array = []
	lines.append(str(item.get("display_name", def_id)))
	var item_type: String = str(item.get("item_type", ""))
	if not item_type.is_empty():
		lines.append("Type: %s" % item_type.capitalize())
	var equip_slot: String = str(item.get("equip_slot", ""))
	if not equip_slot.is_empty():
		lines.append("Slot: %s" % _normalize_equip_slot(equip_slot).capitalize())
	var mods: Dictionary = item.get("stat_modifiers", {})
	if mods.has("attack"):
		lines.append("Attack: +%d" % int(mods["attack"]))
	if mods.has("defense"):
		lines.append("Defense: +%d" % int(mods["defense"]))
	if mods.has("extra_defense"):
		lines.append("Extra Def: +%d" % int(mods["extra_defense"]))
	if mods.has("armor"):
		lines.append("Armor: +%d" % int(mods["armor"]))
	# Weight: show total weight including contents for containers
	var base_weight: float = float(item.get("weight", 0))
	if not item_instance.is_empty() and item_instance.has("children"):
		var total_weight: float = base_weight + _calc_children_weight(item_instance["children"])
		lines.append("Weight: %.1f oz (%.1f + contents)" % [total_weight, base_weight])
	elif base_weight > 0:
		lines.append("Weight: %.1f oz" % base_weight)
	var value: int = int(item.get("value", 0))
	if value > 0:
		lines.append("Value: %d gp" % value)
	if is_container(def_id):
		var slots: int = get_container_slots(def_id)
		var used: int = item_instance["children"].size() if not item_instance.is_empty() and item_instance.has("children") else 0
		lines.append("Volume: %d/%d slots" % [used, slots])
	return "\n".join(lines)


## Recursively sums the weight of all nested child items in a container.
func _calc_children_weight(children: Array) -> float:
	var total := 0.0
	for child in children:
		var cid: String = str(child["item_id"])
		total += float(items.get(cid, {}).get("weight", 0)) * int(child["count"])
		if child.has("children"):
			total += _calc_children_weight(child["children"])
	return total


#  OUTFIT DEFINITIONS

var outfits: Dictionary = {}  # String outfit_id -> Dictionary


## Scans the outfits directory and loads all outfit definition JSON files.
func _load_outfits() -> void:
	var dir := DirAccess.open(_resolve_dir("res://datapacks/outfits"))
	if dir == null:
		push_warning("server_datapacks: outfits directory not found")
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.ends_with(".json"):
			_load_outfit(_resolve_dir("res://datapacks/outfits").path_join(file_name))
		file_name = dir.get_next()
	dir.list_dir_end()


## Parses a single outfit JSON file and stores it by outfit_id.
func _load_outfit(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		return
	file.close()
	var data = json.data
	if not data is Dictionary:
		return
	var outfit_id: String = str(data.get("outfit_id", ""))
	if outfit_id.is_empty():
		return
	outfits[outfit_id] = data


## Returns an outfit definition dict, or empty if not found.
func get_outfit(outfit_id: String) -> Dictionary:
	return outfits.get(outfit_id, {})


## Returns a JSON string of idle/walk sprite paths for the client to render.
func get_outfit_sprites_json(outfit_id: String) -> String:
	var outfit: Dictionary = outfits.get(outfit_id, {})
	if outfit.is_empty():
		return ""
	var base: Dictionary = outfit.get("base_sprites", {})
	if base.is_empty():
		return ""
	var color: Dictionary = outfit.get("color_sprites", {})
	# Build sprites dict with both base and color for client
	var sprites := {"idle": {}, "walk": {}, "color_idle": {}, "color_walk": {}}
	for dir_name in base:
		var dir_data: Dictionary = base[dir_name]
		sprites["idle"][dir_name] = str(dir_data.get("idle", ""))
		sprites["walk"][dir_name] = dir_data.get("walk", [])
	for dir_name in color:
		var dir_data: Dictionary = color[dir_name]
		sprites["color_idle"][dir_name] = str(dir_data.get("idle", ""))
		sprites["color_walk"][dir_name] = dir_data.get("walk", [])
	return JSON.stringify(sprites)
