
@tool
extends Node
class_name ItemDefGenerator



#  Constants


## Image extensions recognised during directory scans.
const IMAGE_EXTENSIONS: Array[String] = [".png", ".jpg", ".webp"]



#  Exported properties


@export var scan_directories: Array[String] = ["res://Assets/Items/"]

@export var output_path: String = "res://datapacks/items/generated_items.json"

@export var generate_now: bool = false:
	set(value):
		if value and Engine.is_editor_hint():
			generate_now = false
			_run_generate()


#  Generation

## Executes the full generation pipeline: loads existing definitions,
## scans sprite directories, appends new skeletons, and writes the
## merged result back to output_path.
func _run_generate() -> void:
	# Step 1: Load existing definitions from output file (preserve manual edits)
	var existing_defs: Array[Dictionary] = _load_existing_definitions()
	var existing_ids: Dictionary = {}  # definition_id (String) → true
	for def in existing_defs:
		if def.has("definition_id"):
			existing_ids[def["definition_id"]] = true

	var preserved_count: int = existing_defs.size()

	# Step 2: Scan directories for image files and build new definitions
	var new_defs: Array[Dictionary] = []
	for dir_path in scan_directories:
		var images := _scan_directory_recursive(dir_path)
		for image_path in images:
			var filename := image_path.get_file()
			var def_id := _derive_definition_id(filename)

			# Skip if this definition_id already exists
			if existing_ids.has(def_id):
				continue

			var display := _derive_display_name(filename)
			var skeleton: Dictionary = {
				"definition_id": def_id,
				"display_name": display,
				"sprite_path": image_path,
				"terrain": false,
				"pickupable": true,
				"moveable": true,
				"stackable": false,
				"weight": 1.0,
			}
			new_defs.append(skeleton)
			existing_ids[def_id] = true  # prevent duplicates across directories

	# Step 3: Merge existing + new
	var merged: Array[Dictionary] = existing_defs.duplicate()
	merged.append_array(new_defs)

	# Step 4: Ensure output directory exists
	var dir_path := output_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var err := DirAccess.make_dir_recursive_absolute(dir_path)
		if err != OK:
			printerr("ItemDefGenerator: Failed to create output directory '%s'." % dir_path)
			return

	# Step 5: Write merged JSON array to output file
	if not _write_json(merged, output_path):
		return

	# Step 6: Log summary
	print("ItemDefGenerator: Generated %d new definition%s, preserved %d existing. Output: '%s'." % [
		new_defs.size(),
		"s" if new_defs.size() != 1 else "",
		preserved_count,
		output_path,
	])


#  existing definition loading

## Loads existing Item_Definitions from the output file.
## Returns an empty array if the file doesn't exist or contains invalid JSON.
func _load_existing_definitions() -> Array[Dictionary]:
	if not FileAccess.file_exists(output_path):
		return []

	var file := FileAccess.open(output_path, FileAccess.READ)
	if file == null:
		push_warning("ItemDefGenerator: Could not open existing output file '%s'. Starting fresh." % output_path)
		return []

	var content := file.get_as_text()
	file.close()

	if content.strip_edges().is_empty():
		return []

	var json := JSON.new()
	var err := json.parse(content)
	if err != OK:
		push_warning("ItemDefGenerator: Existing output file '%s' contains invalid JSON (line %d). Starting fresh." % [output_path, json.get_error_line()])
		return []

	var data = json.data
	if not data is Array:
		push_warning("ItemDefGenerator: Existing output file '%s' root is not an Array. Starting fresh." % output_path)
		return []

	var result: Array[Dictionary] = []
	for entry in data:
		if entry is Dictionary:
			result.append(entry)
	return result


#  scan directory

## Recursively scans a directory for image files (.png, .jpg, .webp).
## Returns an array of full resource paths (e.g. "res://Assets/Items/sword.png").
func _scan_directory_recursive(path: String) -> Array[String]:
	var results: Array[String] = []
	var dir := DirAccess.open(path)
	if dir == null:
		push_warning("ItemDefGenerator: Could not open directory '%s'. Skipping." % path)
		return results

	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir():
			if not entry.begins_with("."):
				var sub_path := path.path_join(entry)
				results.append_array(_scan_directory_recursive(sub_path))
		else:
			var ext := entry.get_extension().to_lower()
			if ("." + ext) in IMAGE_EXTENSIONS:
				results.append(path.path_join(entry))
		entry = dir.get_next()
	dir.list_dir_end()
	return results


#   name deriviation

## Derives a definition_id from an image filename.
## Strips extension, lowercases, replaces spaces with underscores.
## Example: "Iron Sword.png" → "iron_sword"
func _derive_definition_id(filename: String) -> String:
	var base := filename.get_basename()  # strip extension
	base = base.to_lower()
	base = base.replace(" ", "_")
	return base


## Derives a display_name from an image filename.
## Strips extension, replaces underscores with spaces, title-cases each word.
## Example: "iron_sword.png" → "Iron Sword"
func _derive_display_name(filename: String) -> String:
	var base := filename.get_basename()  # strip extension
	base = base.replace("_", " ")
	# Title-case: capitalize first letter of each word
	var words := base.split(" ", false)
	var titled: Array[String] = []
	for word in words:
		if word.length() > 0:
			titled.append(word.substr(0, 1).to_upper() + word.substr(1))
	return " ".join(titled)


#  write file

## Writes the given Array of Dictionaries as indented JSON to the specified path.
## Returns true on success, false on failure.
func _write_json(data: Array[Dictionary], path: String) -> bool:
	var json_string := JSON.stringify(data, "\t")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		var err := FileAccess.get_open_error()
		printerr("ItemDefGenerator: Failed to write '%s' — error code %d." % [path, err])
		return false
	file.store_string(json_string)
	file.close()
	return true
