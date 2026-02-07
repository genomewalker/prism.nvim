"""
Socket Registry - Tracks Neovim instances and their sockets.

Robust approach:
1. Neovim writes its socket to registry when terminal opens
2. MCP server finds its parent Neovim by walking process tree
3. Works with multiple concurrent Neovim instances
"""

import json
import os
import time
from pathlib import Path
from typing import Optional

REGISTRY_PATH = Path("/tmp/prism-socket-registry.json")


def get_process_ancestors() -> list[int]:
    """Get list of ancestor PIDs (self, parent, grandparent, ...)."""
    ancestors = []
    pid = os.getpid()

    while pid > 1:
        ancestors.append(pid)
        try:
            # Read parent PID from /proc or use ps
            if os.path.exists(f"/proc/{pid}/stat"):
                with open(f"/proc/{pid}/stat") as f:
                    parts = f.read().split()
                    pid = int(parts[3])  # ppid is 4th field
            else:
                # macOS fallback
                import subprocess

                result = subprocess.run(
                    ["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True
                )
                if result.returncode == 0 and result.stdout.strip():
                    pid = int(result.stdout.strip())
                else:
                    break
        except (FileNotFoundError, ValueError, IndexError):
            break

    return ancestors


def register_socket(nvim_pid: int, socket_path: str) -> None:
    """Register a Neovim socket in the registry."""
    registry = load_registry()

    registry[str(nvim_pid)] = {
        "socket": socket_path,
        "registered_at": time.time(),
    }

    # Clean up stale entries (older than 24h or dead processes)
    clean_registry(registry)

    save_registry(registry)


def unregister_socket(nvim_pid: int) -> None:
    """Remove a Neovim socket from the registry."""
    registry = load_registry()
    registry.pop(str(nvim_pid), None)
    save_registry(registry)


def find_socket() -> Optional[str]:
    """Find the socket for the Neovim instance that spawned us.

    Walks up the process tree to find a registered Neovim PID.
    """
    # First check NVIM env (most direct)
    nvim_env = os.environ.get("NVIM")
    if nvim_env and os.path.exists(nvim_env):
        return nvim_env

    # Walk process tree to find parent Neovim
    registry = load_registry()
    ancestors = get_process_ancestors()

    for pid in ancestors:
        if str(pid) in registry:
            socket_path = registry[str(pid)]["socket"]
            if os.path.exists(socket_path):
                return socket_path

    # Fallback: try most recently registered socket
    if registry:
        sorted_entries = sorted(
            registry.items(), key=lambda x: x[1].get("registered_at", 0), reverse=True
        )
        for pid, info in sorted_entries:
            socket_path = info["socket"]
            if os.path.exists(socket_path):
                return socket_path

    # Last resort: common socket paths
    for path in ["/tmp/nvim.sock", f"/tmp/nvim-{os.getppid()}.sock"]:
        if os.path.exists(path):
            return path

    return None


def load_registry() -> dict:
    """Load the socket registry."""
    if REGISTRY_PATH.exists():
        try:
            with open(REGISTRY_PATH) as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            return {}
    return {}


def save_registry(registry: dict) -> None:
    """Save the socket registry."""
    try:
        with open(REGISTRY_PATH, "w") as f:
            json.dump(registry, f, indent=2)
    except IOError:
        pass


def clean_registry(registry: dict) -> None:
    """Remove stale entries from registry."""
    stale = []
    now = time.time()

    for pid, info in registry.items():
        # Remove if older than 24 hours
        if now - info.get("registered_at", 0) > 86400:
            stale.append(pid)
            continue

        # Remove if socket doesn't exist
        if not os.path.exists(info["socket"]):
            stale.append(pid)
            continue

        # Remove if process is dead
        try:
            os.kill(int(pid), 0)
        except (ProcessLookupError, ValueError):
            stale.append(pid)

    for pid in stale:
        registry.pop(pid, None)
