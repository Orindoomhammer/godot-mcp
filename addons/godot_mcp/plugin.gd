@tool
extends EditorPlugin

## Godot MCP — EditorPlugin entry point.
##
## Owns the lifecycle of the local TCP command server. The heavy lifting
## (accepting connections, parsing requests, dispatching commands) lives in
## mcp_server.gd so this file stays a thin lifecycle wrapper.

const McpServer := preload("res://addons/godot_mcp/mcp_server.gd")

const DEFAULT_PORT := 9080

var _server: McpServer


func _enter_tree() -> void:
	_server = McpServer.new()
	_server.name = "GodotMcpServer"
	# Parent the server to the editor plugin so it receives _process ticks.
	add_child(_server)
	var err := _server.start(DEFAULT_PORT)
	if err == OK:
		print("[Godot MCP] Command server listening on 127.0.0.1:%d" % DEFAULT_PORT)
	else:
		push_error("[Godot MCP] Failed to start command server on port %d (error %d)" % [DEFAULT_PORT, err])


func _exit_tree() -> void:
	if _server:
		_server.stop()
		_server.queue_free()
		_server = null
	print("[Godot MCP] Command server stopped.")
