# Godot MCP

An [MCP](https://modelcontextprotocol.io) server that lets an AI assistant drive a
**running Godot editor** — read the scene tree, create/edit/delete nodes, open and
play scenes, and save — all against the live editor session.

```
AI client  ──stdio──►  server/godot_mcp_server.py  ──TCP 127.0.0.1:9080──►  Godot editor
(MCP host)              (Python MCP server)                (addons/godot_mcp EditorPlugin)
```

Two halves:

- **`addons/godot_mcp/`** — a Godot 4 `EditorPlugin` that opens a local,
  newline-delimited JSON command server on `127.0.0.1:9080` inside the editor
  and executes commands against the live scene tree via `EditorInterface`.
- **`server/`** — a Python MCP (stdio) server that relays each tool call to the
  plugin over a short-lived TCP socket.

## Tools

| Tool | Description |
| --- | --- |
| `ping` | Confirm the editor is reachable; report Godot version |
| `get_editor_state` | Whether a scene is open, its path, play state |
| `get_scene_tree` | Full node hierarchy of the edited scene |
| `list_project_files` | Resource paths under `res://`, filterable by extension |
| `open_scene` | Open a `.tscn` into an editor tab |
| `get_node_properties` | Editor-visible properties of one node |
| `create_node` | Instantiate a node and add it to the scene |
| `delete_node` | Remove a node (and its children) |
| `set_node_property` | Set a property (supports Godot literals like `Vector2(1,2)`) |
| `save_scene` | Save the edited scene to its `.tscn` |
| `run_project` | Play the currently edited scene |
| `play_scene` | Play a specific scene by path |
| `stop_project` | Stop the running scene |

## Setup

1. **Copy `addons/godot_mcp/` into your Godot 4.3+ project** and enable it in
   *Project → Project Settings → Plugins*. The Output panel should print
   `[Godot MCP] Command server listening on 127.0.0.1:9080`.

2. **Install the Python server** (from `server/`):

   ```sh
   uv sync
   ```

3. **Smoke-test** while the editor is open:

   ```sh
   uv run python godot_mcp_server.py --selftest
   ```

4. **Register with your MCP client.** For Claude Code:

   ```sh
   claude mcp add godot -- uv --directory /path/to/server run python godot_mcp_server.py
   ```

   See [`server/README.md`](server/README.md) for a raw config example and
   configuration environment variables.

## Adding a tool

1. In `addons/godot_mcp/mcp_server.gd`: add a `case` in `_dispatch()` and a
   `_cmd_*` method returning a `Dictionary` (or `_err("...")`).
2. In `server/godot_mcp_server.py`: add an `@mcp.tool()` function that calls
   `send_command("your_command", {...})`.

## Security

The command server binds to `127.0.0.1` only and has no authentication — it is
intended for local development. Do not expose port `9080` to a network.

## License

MIT — see [LICENSE](LICENSE).
