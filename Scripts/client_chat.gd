#  client_chat.gd -- Chat system: UI setup, message sending with channel
#  commands (/y, /w, /b), and formatted message display.
extends Node

var client: Node2D = null  # client_main.gd

var _chat_log: RichTextLabel = null
var _chat_input: LineEdit = null


## Creates the chat log and input field on a dedicated CanvasLayer.
func setup_chat_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "ChatLayer"
	layer.layer = 10
	layer.visible = false
	client.add_child(layer)

	_chat_log = RichTextLabel.new()
	_chat_log.name = "ChatLog"
	_chat_log.bbcode_enabled = true
	_chat_log.scroll_following = true
	_chat_log.position = Vector2(8, 400)
	_chat_log.size = Vector2(400, 150)
	_chat_log.add_theme_font_size_override("normal_font_size", 11)
	_chat_log.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_chat_log)

	_chat_input = LineEdit.new()
	_chat_input.name = "ChatInput"
	_chat_input.position = Vector2(8, 555)
	_chat_input.size = Vector2(400, 24)
	_chat_input.placeholder_text = "Press Enter to chat…"
	_chat_input.text_submitted.connect(_on_chat_submitted)
	layer.add_child(_chat_input)


## Parses chat input for slash-commands and sends the appropriate RPC.
func _on_chat_submitted(text: String) -> void:
	if _chat_input == null:
		return
	_chat_input.clear()
	_chat_input.release_focus()
	text = text.strip_edges()
	if text.is_empty():
		return
	if text == "/logout":
		client.rpc_id(1, "rpc_logout")
		return
	if text == "/inv":
		client.inventory.toggle_inventory()
		return
	if text.begins_with("/buy "):
		var parts := text.substr(5).strip_edges().rsplit(" ", true, 1)
		var item_id: String = parts[0] if parts.size() > 0 else ""
		var count: int = int(parts[1]) if parts.size() > 1 else 1
		if not item_id.is_empty() and count > 0:
			client.rpc_id(1, "rpc_shop_buy", item_id, count)
		return
	if text.begins_with("/sell "):
		var parts := text.substr(6).strip_edges().rsplit(" ", true, 1)
		var item_id: String = parts[0] if parts.size() > 0 else ""
		var count: int = int(parts[1]) if parts.size() > 1 else 1
		if not item_id.is_empty() and count > 0:
			client.rpc_id(1, "rpc_shop_sell", item_id, count)
		return
	if text.begins_with("/y "):
		client.rpc_id(1, "rpc_send_chat", "yell", text.substr(3))
	elif text.begins_with("/w "):
		client.rpc_id(1, "rpc_send_chat", "whisper", text.substr(3))
	elif text.begins_with("/b "):
		client.rpc_id(1, "rpc_send_chat", "broadcast", text.substr(3))
	else:
		client.rpc_id(1, "rpc_send_chat", "say", text)


## Appends a color-formatted chat message to the log based on channel type.
func handle_receive_chat(channel: String, sender: String, text: String) -> void:
	if _chat_log == null:
		return
	var line := ""
	match channel:
		"say":
			line = "[color=yellow]%s says:[/color] %s" % [sender, text]
		"yell":
			line = "[color=yellow]%s yells:[/color] [b]%s[/b]" % [sender, text]
		"whisper":
			line = "[color=cyan]%s whispers:[/color] %s" % [sender, text]
		"whisper_sent":
			line = "[color=cyan]You whisper to %s:[/color] %s" % [sender, text]
		"broadcast":
			line = "[color=red]%s broadcasts:[/color] %s" % [sender, text]
		"system":
			line = "[color=gray]%s[/color]" % text
		"npc":
			line = "[color=orange]%s says:[/color] %s" % [sender, text]
		_:
			line = "[%s] %s: %s" % [channel, sender, text]
	_chat_log.append_text(line + "\n")
