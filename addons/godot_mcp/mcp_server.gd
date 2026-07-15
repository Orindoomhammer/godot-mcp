@tool
extends Node

## Godot MCP — TCP command server.
##
## Listens on 127.0.0.1 and speaks newline-delimited JSON. Each request is a
## single JSON object terminated by "\n":
##
##     {"id": 1, "command": "create_node", "params": {...}}
##
## Each response is a single JSON object terminated by "\n":
##
##     {"id": 1, "ok": true, "result": {...}}
##     {"id": 1, "ok": false, "error": "message"}
##
## To add a tool: add a `case` in `_dispatch()` and a matching `_cmd_*` method.
## The Python MCP server in ../../server relays tool calls here.

var _tcp_server: TCPServer
var _clients: Array[StreamPeerTCP] = []
## Per-client receive buffers so partial reads accumulate until a newline.
var _buffers: Dictionary = {}


func start(port: int) -> int:
	_tcp_server = TCPServer.new()
	return _tcp_server.listen(port, "127.0.0.1")


func stop() -> void:
	for client in _clients:
		client.disconnect_from_host()
	_clients.clear()
	_buffers.clear()
	if _tcp_server:
		_tcp_server.stop()
		_tcp_server = null


func _process(_delta: float) -> void:
	if _tcp_server == null:
		return

	# Accept any pending connections.
	while _tcp_server.is_connection_available():
		var client := _tcp_server.take_connection()
		_clients.append(client)
		_buffers[client] = PackedByteArray()

	# Service each connected client.
	var still_connected: Array[StreamPeerTCP] = []
	for client in _clients:
		client.poll()
		if client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_buffers.erase(client)
			continue
		_read_client(client)
		still_connected.append(client)
	_clients = still_connected


func _read_client(client: StreamPeerTCP) -> void:
	var available := client.get_available_bytes()
	if available > 0:
		var chunk: Array = client.get_data(available)
		# get_data returns [error, PackedByteArray].
		if chunk[0] == OK:
			var buffer: PackedByteArray = _buffers[client]
			buffer.append_array(chunk[1])
			_buffers[client] = buffer

	# Extract and handle every complete newline-terminated message.
	var buffer: PackedByteArray = _buffers[client]
	var newline := buffer.find(10)  # ASCII "\n"
	while newline != -1:
		var line := buffer.slice(0, newline)
		buffer = buffer.slice(newline + 1)
		_handle_line(client, line.get_string_from_utf8())
		newline = buffer.find(10)
	_buffers[client] = buffer


func _handle_line(client: StreamPeerTCP, line: String) -> void:
	line = line.strip_edges()
	if line.is_empty():
		return

	var json := JSON.new()
	var parse_err := json.parse(line)
	if parse_err != OK:
		_send(client, {"ok": false, "error": "Invalid JSON: %s" % json.get_error_message()})
		return

	var request = json.data
	if typeof(request) != TYPE_DICTIONARY:
		_send(client, {"ok": false, "error": "Request must be a JSON object."})
		return

	var id = request.get("id", null)
	var command: String = request.get("command", "")
	var params: Dictionary = request.get("params", {})

	var response := {"id": id}
	# Dispatch inside a guard so a malformed command can't crash the editor loop.
	var result = _dispatch(command, params)
	if result is Dictionary and result.get("__error__", false):
		response["ok"] = false
		response["error"] = result.get("message", "Unknown error")
	else:
		response["ok"] = true
		response["result"] = result
	_send(client, response)


func _send(client: StreamPeerTCP, obj: Dictionary) -> void:
	var text := JSON.stringify(obj) + "\n"
	client.put_data(text.to_utf8_buffer())


## Builds a standard error result understood by _handle_line.
func _err(message: String) -> Dictionary:
	return {"__error__": true, "message": message}


# ---------------------------------------------------------------------------
# Command dispatch
# ---------------------------------------------------------------------------

func _dispatch(command: String, params: Dictionary):
	match command:
		"ping":
			return {"pong": true, "godot_version": Engine.get_version_info()}
		"get_editor_state":
			return _cmd_get_editor_state(params)
		"get_scene_tree":
			return _cmd_get_scene_tree(params)
		"list_project_files":
			return _cmd_list_project_files(params)
		"open_scene":
			return _cmd_open_scene(params)
		"get_node_properties":
			return _cmd_get_node_properties(params)
		"create_node":
			return _cmd_create_node(params)
		"delete_node":
			return _cmd_delete_node(params)
		"set_node_property":
			return _cmd_set_node_property(params)
		"save_scene":
			return _cmd_save_scene(params)
		"run_project":
			return _cmd_run_project(params)
		"play_scene":
			return _cmd_play_scene(params)
		"stop_project":
			return _cmd_stop_project(params)
		"list_input_actions":
			return _cmd_list_input_actions(params)
		"add_input_action":
			return _cmd_add_input_action(params)
		"remove_input_action":
			return _cmd_remove_input_action(params)
		_:
			return _err("Unknown command: '%s'" % command)


# ---------------------------------------------------------------------------
# Command implementations
# ---------------------------------------------------------------------------

func _cmd_get_editor_state(_params: Dictionary):
	var root := EditorInterface.get_edited_scene_root()
	return {
		"has_open_scene": root != null,
		"edited_scene_root": root.name if root else null,
		"edited_scene_path": EditorInterface.get_edited_scene_root().scene_file_path if root else "",
		"is_playing": EditorInterface.is_playing_scene(),
	}


func _cmd_get_scene_tree(_params: Dictionary):
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err("No scene is currently open in the editor.")
	return {"tree": _serialize_node(root, root)}


## Recursively describe a node and its children relative to the scene root.
func _serialize_node(node: Node, scene_root: Node) -> Dictionary:
	var path := "." if node == scene_root else str(scene_root.get_path_to(node))
	var children: Array = []
	for child in node.get_children():
		children.append(_serialize_node(child, scene_root))
	return {
		"name": node.name,
		"type": node.get_class(),
		"path": path,
		"child_count": node.get_child_count(),
		"children": children,
	}


func _cmd_open_scene(params: Dictionary):
	var path: String = params.get("path", "")
	if not path.begins_with("res://"):
		return _err("Scene path must start with res:// — got '%s'." % path)
	if not FileAccess.file_exists(path):
		return _err("Scene file does not exist: '%s'" % path)
	EditorInterface.open_scene_from_path(path)
	var root := EditorInterface.get_edited_scene_root()
	return {
		"opened": true,
		"path": path,
		"root": root.name if root else null,
	}


func _cmd_list_project_files(params: Dictionary):
	# Optional list of extensions (without dot) to filter by, e.g. ["tscn","png"].
	var exts: Array = params.get("extensions", [])
	var lowered: Array = []
	for e in exts:
		lowered.append(String(e).to_lower())
	var results: Array = []
	_scan_dir("res://", lowered, results)
	results.sort()
	return {"count": results.size(), "files": results}


## Recursively collect resource paths under `dir`, skipping the hidden .godot
## cache. When `exts` is non-empty, only files with those extensions are kept.
func _scan_dir(dir: String, exts: Array, out: Array) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	da.list_dir_begin()
	var name := da.get_next()
	while name != "":
		if name.begins_with("."):
			name = da.get_next()
			continue
		var full := dir.path_join(name)
		if da.current_is_dir():
			_scan_dir(full, exts, out)
		else:
			if exts.is_empty() or full.get_extension().to_lower() in exts:
				out.append(full)
		name = da.get_next()
	da.list_dir_end()


func _cmd_get_node_properties(params: Dictionary):
	var node := _resolve_node(params.get("path", ""))
	if node == null:
		return _err("Node not found at path: '%s'" % params.get("path", ""))
	var props: Dictionary = {}
	for entry in node.get_property_list():
		# Only surface storage/editor properties that are actually usable.
		if entry.usage & PROPERTY_USAGE_EDITOR:
			var value = node.get(entry.name)
			props[entry.name] = var_to_str(value)
	return {"type": node.get_class(), "properties": props}


func _cmd_create_node(params: Dictionary):
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err("No scene is currently open in the editor.")

	var type: String = params.get("type", "")
	if not ClassDB.class_exists(type) or not ClassDB.can_instantiate(type):
		return _err("Cannot instantiate node type: '%s'" % type)

	var parent_path: String = params.get("parent", ".")
	var parent := _resolve_node(parent_path)
	if parent == null:
		return _err("Parent node not found at path: '%s'" % parent_path)

	var node: Node = ClassDB.instantiate(type)
	var desired_name: String = params.get("name", "")
	if not desired_name.is_empty():
		node.name = desired_name
	parent.add_child(node)
	# owner must be the scene root for the node to be saved with the scene.
	node.owner = root

	return {
		"created": true,
		"name": node.name,
		"path": str(root.get_path_to(node)),
	}


func _cmd_delete_node(params: Dictionary):
	var node := _resolve_node(params.get("path", ""))
	if node == null:
		return _err("Node not found at path: '%s'" % params.get("path", ""))
	if node == EditorInterface.get_edited_scene_root():
		return _err("Refusing to delete the scene root node.")
	var name := node.name
	node.get_parent().remove_child(node)
	node.queue_free()
	return {"deleted": true, "name": name}


func _cmd_set_node_property(params: Dictionary):
	var node := _resolve_node(params.get("path", ""))
	if node == null:
		return _err("Node not found at path: '%s'" % params.get("path", ""))
	var property: String = params.get("property", "")
	if not property in node:
		return _err("Node '%s' has no property '%s'." % [node.name, property])

	# Values may arrive as a Godot literal string (e.g. "Vector2(1, 2)") so we
	# can round-trip complex types; fall back to the raw JSON value otherwise.
	var raw = params.get("value", null)
	var value = raw
	if typeof(raw) == TYPE_STRING:
		var parsed = str_to_var(raw)
		if parsed != null:
			value = parsed
	node.set(property, value)
	return {"updated": true, "property": property, "value": var_to_str(node.get(property))}


func _cmd_save_scene(_params: Dictionary):
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err("No scene is currently open in the editor.")
	if root.scene_file_path.is_empty():
		return _err("Scene has never been saved; save it once from the editor to give it a path.")
	var err := EditorInterface.save_scene()
	if err != OK:
		return _err("save_scene failed with error %d." % err)
	return {"saved": true, "path": root.scene_file_path}


func _cmd_run_project(_params: Dictionary):
	# Play the currently edited scene so a project without a configured main
	# scene still runs. Falls back to the main scene if no scene is open.
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		EditorInterface.play_main_scene()
		return {"running": true, "mode": "main_scene"}
	EditorInterface.play_current_scene()
	return {"running": true, "mode": "current_scene", "scene": root.scene_file_path}


func _cmd_play_scene(params: Dictionary):
	var path: String = params.get("path", "")
	if not path.begins_with("res://"):
		return _err("Scene path must start with res:// — got '%s'." % path)
	if not FileAccess.file_exists(path):
		return _err("Scene file does not exist: '%s'" % path)
	EditorInterface.play_custom_scene(path)
	return {"running": true, "mode": "custom_scene", "scene": path}


func _cmd_stop_project(_params: Dictionary):
	EditorInterface.stop_playing_scene()
	return {"stopped": true}


# ---------------------------------------------------------------------------
# Input Map editing
# ---------------------------------------------------------------------------

func _cmd_list_input_actions(_params: Dictionary):
	var actions: Dictionary = {}
	for prop in ProjectSettings.get_property_list():
		var pname: String = prop.name
		if pname.begins_with("input/"):
			var action := pname.substr("input/".length())
			var setting = ProjectSettings.get_setting(pname)
			var events: Array = []
			if setting is Dictionary and setting.has("events"):
				for e in setting["events"]:
					events.append(_describe_event(e))
			actions[action] = events
	return {"actions": actions}


func _cmd_add_input_action(params: Dictionary):
	var action: String = params.get("action", "")
	if action.is_empty():
		return _err("An 'action' name is required.")

	var events: Array = []
	for spec in params.get("events", []):
		var ev := _build_event(spec)
		if ev == null:
			return _err("Could not build input event from: %s" % str(spec))
		events.append(ev)

	var setting := {
		"deadzone": float(params.get("deadzone", 0.5)),
		"events": events,
	}
	ProjectSettings.set_setting("input/" + action, setting)
	var err := ProjectSettings.save()
	if err != OK:
		return _err("ProjectSettings.save() failed with error %d." % err)
	return {"added": action, "event_count": events.size()}


func _cmd_remove_input_action(params: Dictionary):
	var action: String = params.get("action", "")
	var key := "input/" + action
	if not ProjectSettings.has_setting(key):
		return _err("No input action named '%s'." % action)
	ProjectSettings.clear(key)
	var err := ProjectSettings.save()
	if err != OK:
		return _err("ProjectSettings.save() failed with error %d." % err)
	return {"removed": action}


func _describe_event(e) -> String:
	if e is InputEventKey:
		var k := e as InputEventKey
		var code: int = k.physical_keycode if k.physical_keycode != 0 else k.keycode
		return "key:%d" % code
	elif e is InputEventMouseButton:
		var m := e as InputEventMouseButton
		return "mouse_button:%d" % m.button_index
	elif e is InputEventJoypadButton:
		var j := e as InputEventJoypadButton
		return "joy_button:%d" % j.button_index
	return e.get_class()


## Build an InputEvent from a spec dict:
##   {"type": "key", "keycode": "H"}  or  {"type": "mouse_button", "button": "left"}
func _build_event(spec: Dictionary) -> InputEvent:
	match String(spec.get("type", "")):
		"key":
			var ev := InputEventKey.new()
			ev.keycode = _keycode_from(spec.get("keycode", 0))
			return ev
		"mouse_button":
			var ev := InputEventMouseButton.new()
			ev.button_index = _mouse_button_index(spec.get("button", "left"))
			return ev
	return null


## Named keys we support by name; single characters map by their code point
## (KEY_A == 'A' == 65). Anything else should be passed as an int keycode.
const _NAMED_KEYS := {
	"escape": KEY_ESCAPE, "space": KEY_SPACE, "enter": KEY_ENTER,
	"tab": KEY_TAB, "shift": KEY_SHIFT, "ctrl": KEY_CTRL, "alt": KEY_ALT,
	"up": KEY_UP, "down": KEY_DOWN, "left": KEY_LEFT, "right": KEY_RIGHT,
}


func _keycode_from(v) -> int:
	if v is int or v is float:
		return int(v)
	var s := String(v)
	if s.length() == 1:
		return s.to_upper().unicode_at(0)  # KEY_A == 'A' (65), etc.
	return _NAMED_KEYS.get(s.to_lower(), 0)


func _mouse_button_index(name) -> int:
	match String(name).to_lower():
		"right":
			return MOUSE_BUTTON_RIGHT
		"middle":
			return MOUSE_BUTTON_MIDDLE
		"wheel_up":
			return MOUSE_BUTTON_WHEEL_UP
		"wheel_down":
			return MOUSE_BUTTON_WHEEL_DOWN
		_:
			return MOUSE_BUTTON_LEFT


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Resolve a node path relative to the edited scene root. "." / "" => root.
func _resolve_node(path: String) -> Node:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return null
	if path.is_empty() or path == ".":
		return root
	if root.has_node(NodePath(path)):
		return root.get_node(NodePath(path))
	return null
