"""MCP server bridging Claude to a running Godot editor.

The companion `godot_mcp` EditorPlugin opens a newline-delimited JSON command
server on 127.0.0.1:9080. This process is an MCP stdio server: each MCP tool
call is translated into one JSON command, sent over a short-lived TCP socket,
and the response is returned to the model.

Run standalone for a smoke test:

    python godot_mcp_server.py --selftest

Or register with an MCP client (see README).
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
from typing import Any

from mcp.server.fastmcp import FastMCP

GODOT_HOST = os.environ.get("GODOT_MCP_HOST", "127.0.0.1")
GODOT_PORT = int(os.environ.get("GODOT_MCP_PORT", "9080"))
# Editor operations are near-instant; keep the timeout tight so a closed editor
# fails fast with a clear message instead of hanging the tool call.
TIMEOUT_SECONDS = float(os.environ.get("GODOT_MCP_TIMEOUT", "5.0"))

mcp = FastMCP("godot-mcp")


class GodotError(RuntimeError):
    """Raised when the editor reports a command failure or is unreachable."""


def send_command(command: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    """Send one command to the Godot plugin and return its `result` dict.

    Raises GodotError with a human-readable message if the editor is not
    reachable or the command fails, so FastMCP surfaces it to the model.
    """
    request = json.dumps({"id": 1, "command": command, "params": params or {}}) + "\n"

    try:
        with socket.create_connection((GODOT_HOST, GODOT_PORT), timeout=TIMEOUT_SECONDS) as sock:
            sock.sendall(request.encode("utf-8"))
            sock.settimeout(TIMEOUT_SECONDS)
            buffer = bytearray()
            while b"\n" not in buffer:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                buffer.extend(chunk)
    except (ConnectionRefusedError, OSError) as exc:
        raise GodotError(
            f"Could not reach the Godot editor at {GODOT_HOST}:{GODOT_PORT} "
            f"({exc}). Make sure Godot is open with the 'Godot MCP' plugin enabled."
        ) from exc

    line = bytes(buffer).split(b"\n", 1)[0].decode("utf-8").strip()
    if not line:
        raise GodotError("Editor closed the connection without responding.")

    response = json.loads(line)
    if not response.get("ok", False):
        raise GodotError(response.get("error", "Unknown error from Godot editor."))
    return response.get("result", {})


def _fmt(result: dict[str, Any]) -> str:
    """Render a result dict as pretty JSON for the model to read."""
    return json.dumps(result, indent=2)


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------

@mcp.tool()
def ping() -> str:
    """Check that the Godot editor is reachable and report its version."""
    return _fmt(send_command("ping"))


@mcp.tool()
def get_editor_state() -> str:
    """Report editor status: whether a scene is open, its path, and play state."""
    return _fmt(send_command("get_editor_state"))


@mcp.tool()
def get_scene_tree() -> str:
    """Return the full node hierarchy of the currently edited scene.

    Paths in the returned tree are relative to the scene root ("." is the root)
    and can be passed to the node-editing tools.
    """
    return _fmt(send_command("get_scene_tree"))


@mcp.tool()
def list_project_files(extensions: list[str] | None = None) -> str:
    """List resource files under res://, optionally filtered by extension.

    Args:
        extensions: Extensions without the dot, e.g. ["tscn", "png"]. Omit for all files.
    """
    return _fmt(send_command("list_project_files", {"extensions": extensions or []}))


@mcp.tool()
def open_scene(path: str) -> str:
    """Open a scene file into an editor tab so the node tools can act on it.

    Args:
        path: res:// path to a .tscn file, e.g. "res://scenes/village.tscn".
    """
    return _fmt(send_command("open_scene", {"path": path}))


@mcp.tool()
def get_node_properties(path: str) -> str:
    """List the editor-visible properties of a node.

    Args:
        path: Node path relative to the scene root, e.g. "." or "Player/Sprite2D".
    """
    return _fmt(send_command("get_node_properties", {"path": path}))


@mcp.tool()
def create_node(type: str, name: str = "", parent: str = ".") -> str:
    """Create a node and add it to the currently edited scene.

    Args:
        type: Godot class name to instantiate, e.g. "Node2D", "Sprite2D", "Label".
        name: Optional name for the new node; Godot auto-names if empty.
        parent: Path of the parent node relative to the scene root; "." is the root.
    """
    return _fmt(send_command("create_node", {"type": type, "name": name, "parent": parent}))


@mcp.tool()
def delete_node(path: str) -> str:
    """Delete a node (and its children) from the currently edited scene.

    Args:
        path: Node path relative to the scene root. The scene root cannot be deleted.
    """
    return _fmt(send_command("delete_node", {"path": path}))


@mcp.tool()
def set_node_property(path: str, property: str, value: Any) -> str:
    """Set a property on a node in the currently edited scene.

    For complex Godot types pass a Godot literal string, e.g.
    value="Vector2(100, 50)" or value="Color(1, 0, 0, 1)". Plain numbers,
    strings, and booleans are passed through as-is.

    Args:
        path: Node path relative to the scene root.
        property: Property name, e.g. "position", "text", "visible".
        value: New value (see note above on complex types).
    """
    return _fmt(send_command("set_node_property", {"path": path, "property": property, "value": value}))


@mcp.tool()
def save_scene() -> str:
    """Save the currently edited scene to its .tscn file on disk."""
    return _fmt(send_command("save_scene"))


@mcp.tool()
def run_project() -> str:
    """Run the currently edited scene from the editor.

    Plays the open scene directly, so it works even when the project has no
    main scene configured. Falls back to the main scene if nothing is open.
    """
    return _fmt(send_command("run_project"))


@mcp.tool()
def play_scene(path: str) -> str:
    """Run a specific scene by path, without changing the project's main scene.

    Args:
        path: res:// path to a .tscn file, e.g. "res://scenes/village.tscn".
    """
    return _fmt(send_command("play_scene", {"path": path}))


@mcp.tool()
def stop_project() -> str:
    """Stop the currently running scene."""
    return _fmt(send_command("stop_project"))


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def _selftest() -> int:
    """Ping the editor and dump the scene tree; used for manual verification."""
    try:
        print("ping ->", send_command("ping"))
        print("editor_state ->", send_command("get_editor_state"))
        print("scene_tree ->", json.dumps(send_command("get_scene_tree"), indent=2))
    except GodotError as exc:
        print(f"SELFTEST FAILED: {exc}", file=sys.stderr)
        return 1
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description="Godot MCP server")
    parser.add_argument(
        "--selftest",
        action="store_true",
        help="Connect to the editor and print a few commands instead of starting the MCP server.",
    )
    args = parser.parse_args()

    if args.selftest:
        raise SystemExit(_selftest())

    mcp.run()


if __name__ == "__main__":
    main()
