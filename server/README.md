# Godot MCP Server

An MCP server that lets Claude (or any MCP client) drive a **running Godot editor**.

## How it works

```
Claude  ──stdio──►  godot_mcp_server.py  ──TCP 127.0.0.1:9080──►  Godot editor
 (MCP client)        (this Python server)        (godot_mcp EditorPlugin)
```

- `addons/godot_mcp/` is a Godot **EditorPlugin** that opens a newline-delimited
  JSON command server on `127.0.0.1:9080` inside the running editor.
- `server/godot_mcp_server.py` is an MCP **stdio** server. Each tool call is
  relayed to the editor over a short-lived TCP socket.

The plugin is already enabled in `project.godot`, so it starts automatically the
next time you open this project in Godot 4.7+.

## Tools

| Tool | What it does |
| --- | --- |
| `ping` | Confirm the editor is reachable; report Godot version |
| `get_editor_state` | Whether a scene is open, its path, play state |
| `get_scene_tree` | Full node hierarchy of the edited scene |
| `get_node_properties` | Editor-visible properties of one node |
| `create_node` | Instantiate a node and add it to the scene |
| `delete_node` | Remove a node (and children) |
| `set_node_property` | Set a property (supports Godot literals like `Vector2(1,2)`) |
| `save_scene` | Save the edited scene to its `.tscn` |
| `run_project` | Play the main scene |
| `stop_project` | Stop the running scene |

## Setup

1. **Open the project in Godot** (4.7+). The console should print:
   `[Godot MCP] Command server listening on 127.0.0.1:9080`
   Open a scene so the node tools have something to act on.

2. **Install the Python deps** (from this `server/` directory):

   ```sh
   uv sync
   ```

3. **Smoke-test the bridge** while the editor is open:

   ```sh
   uv run python godot_mcp_server.py --selftest
   ```

   You should see `ping`, editor state, and the scene tree printed.

## Register with an MCP client

### Claude Code

```sh
claude mcp add godot -- uv --directory "E:/Users/waco_/Documents/mcp-plugin-test/server" run python godot_mcp_server.py
```

### Raw MCP config (claude_desktop_config.json, etc.)

```json
{
  "mcpServers": {
    "godot": {
      "command": "uv",
      "args": [
        "--directory",
        "E:/Users/waco_/Documents/mcp-plugin-test/server",
        "run",
        "python",
        "godot_mcp_server.py"
      ]
    }
  }
}
```

## Configuration

Environment variables (all optional):

| Var | Default | Meaning |
| --- | --- | --- |
| `GODOT_MCP_HOST` | `127.0.0.1` | Editor command-server host |
| `GODOT_MCP_PORT` | `9080` | Editor command-server port |
| `GODOT_MCP_TIMEOUT` | `5.0` | Socket timeout in seconds |

The port must match `DEFAULT_PORT` in `addons/godot_mcp/plugin.gd`.

## Adding a tool

1. In `addons/godot_mcp/mcp_server.gd`: add a `case` in `_dispatch()` and a
   `_cmd_*` method that returns a `Dictionary` (or `_err("...")`).
2. In `server/godot_mcp_server.py`: add an `@mcp.tool()` function that calls
   `send_command("your_command", {...})`.
