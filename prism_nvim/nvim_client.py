"""
Neovim RPC Client - Communicates with Neovim via msgpack-rpc

This module provides a clean interface to control Neovim programmatically.
"""

import socket
import struct
import os
import subprocess
import time
from pathlib import Path
from typing import Any, Optional, Union
from dataclasses import dataclass, field

# Try to import msgpack, fall back to pure Python implementation
try:
    import msgpack

    HAS_MSGPACK = True
except ImportError:
    HAS_MSGPACK = False


@dataclass
class Buffer:
    """Represents a Neovim buffer."""

    id: int
    name: str
    filetype: str
    modified: bool
    lines: list[str] = field(default_factory=list)


@dataclass
class Window:
    """Represents a Neovim window."""

    id: int
    buffer_id: int
    cursor: tuple[int, int]  # (line, col)
    width: int
    height: int


@dataclass
class Selection:
    """Represents a visual selection."""

    text: str
    start_line: int
    start_col: int
    end_line: int
    end_col: int
    mode: str  # 'v', 'V', or '<C-v>'


class NeovimClient:
    """
    Client for communicating with Neovim via RPC.

    Supports both Unix sockets and TCP connections.
    """

    def __init__(self, address: Optional[str] = None):
        """
        Initialize the Neovim client.

        Args:
            address: Socket address. Can be:
                - Unix socket path: /tmp/nvim.sock
                - TCP address: localhost:6666
                - None: Auto-detect from $NVIM environment variable
        """
        self.address = address
        self.socket: Optional[socket.socket] = None
        self.msgid = 0
        self._connected = False

        if not HAS_MSGPACK:
            raise ImportError(
                "msgpack is required for Neovim RPC. " "Install it with: pip install msgpack"
            )

    def connect(self) -> bool:
        """Connect to Neovim."""
        address = self.address

        if not address:
            # Use socket registry (robust multi-instance support)
            try:
                from .socket_registry import find_socket

                address = find_socket()
            except ImportError:
                address = os.environ.get("NVIM")

        if not address:
            # Fallback: try to find a running Neovim instance
            address = self._find_nvim_socket()

        if not address:
            raise ConnectionError(
                "Could not find Neovim instance. " "Start Neovim with: nvim --listen /tmp/nvim.sock"
            )

        try:
            if address.startswith("/") or address.startswith("\\"):
                # Unix socket
                self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.socket.connect(address)
            elif ":" in address:
                # TCP socket
                host, port = address.rsplit(":", 1)
                self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                self.socket.connect((host, int(port)))
            else:
                # Assume Unix socket
                self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.socket.connect(address)

            self._connected = True
            return True

        except Exception as e:
            raise ConnectionError(f"Failed to connect to Neovim at {address}: {e}")

    def _find_nvim_socket(self) -> Optional[str]:
        """Try to find a running Neovim socket."""
        # Check common locations
        candidates = [
            "/tmp/nvim.sock",
            "/tmp/nvimsocket",
            os.path.expanduser("~/.cache/nvim/server.sock"),
        ]

        # Check for PID-based sockets (nvim-<pid>.sock)
        import glob

        pid_sockets = sorted(glob.glob("/tmp/nvim-*.sock"), key=os.path.getmtime, reverse=True)
        candidates = pid_sockets + candidates

        # Check XDG runtime dir
        xdg_runtime = os.environ.get("XDG_RUNTIME_DIR")
        if xdg_runtime:
            nvim_dir = Path(xdg_runtime) / "nvim"
            if nvim_dir.exists():
                for sock in nvim_dir.glob("*.sock"):
                    candidates.insert(0, str(sock))

        for candidate in candidates:
            if os.path.exists(candidate):
                # Verify socket is actually usable
                try:
                    test_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    test_sock.settimeout(0.5)
                    test_sock.connect(candidate)
                    test_sock.close()
                    return candidate
                except Exception:
                    continue

        return None

    def disconnect(self):
        """Disconnect from Neovim."""
        if self.socket:
            self.socket.close()
            self.socket = None
        self._connected = False

    def is_connected(self) -> bool:
        """Check if connected to Neovim."""
        return self._connected and self.socket is not None

    def _decode_bytes(self, obj: Any) -> Any:
        """Recursively decode bytes to strings in nested structures."""
        if isinstance(obj, bytes):
            return obj.decode("utf-8", errors="replace")
        elif isinstance(obj, list):
            return [self._decode_bytes(item) for item in obj]
        elif isinstance(obj, dict):
            return {self._decode_bytes(k): self._decode_bytes(v) for k, v in obj.items()}
        return obj

    def _send(self, msg_type: int, method: str, args: list) -> Any:
        """Send an RPC message and get response."""
        if not self.is_connected():
            self.connect()

        self.msgid += 1
        msg = [msg_type, self.msgid, method, args]

        packed = msgpack.packb(msg)
        self.socket.sendall(packed)

        # Read response
        # Use raw=True and decode manually to handle all edge cases
        unpacker = msgpack.Unpacker(raw=True)
        while True:
            data = self.socket.recv(4096)
            if not data:
                raise ConnectionError("Connection closed by Neovim")
            unpacker.feed(data)
            for response in unpacker:
                if response[0] == 1 and response[1] == self.msgid:
                    error, result = response[2], response[3]
                    if error:
                        error = self._decode_bytes(error)
                        raise RuntimeError(f"Neovim error: {error}")
                    return self._decode_bytes(result)

    def call(self, method: str, *args) -> Any:
        """Call a Neovim API method."""
        return self._send(0, method, list(args))

    def command(self, cmd: str) -> None:
        """Execute a Neovim command."""
        self.call("nvim_command", cmd)

    def eval(self, expr: str) -> Any:
        """Evaluate a Vim expression."""
        return self.call("nvim_eval", expr)

    def lua(self, code: str, *args) -> Any:
        """Execute Lua code in Neovim."""
        return self.call("nvim_exec_lua", code, list(args))

    # =========================================================================
    # Buffer Operations
    # =========================================================================

    def get_current_buffer(self) -> Buffer:
        """Get the current buffer."""
        buf_id = self.call("nvim_get_current_buf")
        return self._get_buffer_info(buf_id)

    def get_buffers(self) -> list[Buffer]:
        """Get all listed buffers."""
        buf_ids = self.call("nvim_list_bufs")
        buffers = []
        for buf_id in buf_ids:
            if self.call("nvim_buf_get_option", buf_id, "buflisted"):
                buffers.append(self._get_buffer_info(buf_id))
        return buffers

    def _get_buffer_info(self, buf_id: int) -> Buffer:
        """Get buffer information."""
        name = self.call("nvim_buf_get_name", buf_id)
        filetype = self.call("nvim_buf_get_option", buf_id, "filetype")
        modified = self.call("nvim_buf_get_option", buf_id, "modified")
        return Buffer(
            id=buf_id,
            name=name,
            filetype=filetype,
            modified=modified,
        )

    def get_buffer_content(self, buf_id: Optional[int] = None) -> str:
        """Get the content of a buffer."""
        if buf_id is None:
            buf_id = self.call("nvim_get_current_buf")
        lines = self.call("nvim_buf_get_lines", buf_id, 0, -1, False)
        return "\n".join(lines)

    def set_buffer_content(self, content: str, buf_id: Optional[int] = None) -> None:
        """Set the content of a buffer."""
        if buf_id is None:
            buf_id = self.call("nvim_get_current_buf")
        lines = content.split("\n")
        self.call("nvim_buf_set_lines", buf_id, 0, -1, False, lines)

    def get_buffer_lines(
        self, start: int = 0, end: int = -1, buf_id: Optional[int] = None
    ) -> list[str]:
        """Get lines from a buffer."""
        if buf_id is None:
            buf_id = self.call("nvim_get_current_buf")
        return self.call("nvim_buf_get_lines", buf_id, start, end, False)

    def set_buffer_lines(
        self, lines: list[str], start: int = 0, end: int = -1, buf_id: Optional[int] = None
    ) -> None:
        """Set lines in a buffer."""
        if buf_id is None:
            buf_id = self.call("nvim_get_current_buf")
        self.call("nvim_buf_set_lines", buf_id, start, end, False, lines)

    def insert_text(self, text: str, line: int, col: int, buf_id: Optional[int] = None) -> None:
        """Insert text at a specific position."""
        if buf_id is None:
            buf_id = self.call("nvim_get_current_buf")
        self.call("nvim_buf_set_text", buf_id, line, col, line, col, text.split("\n"))

    # =========================================================================
    # File Operations
    # =========================================================================

    def open_file(self, filepath: str, keep_focus: bool = True) -> Buffer:
        """Open a file in the editor area (non-terminal window).

        Args:
            filepath: Path to the file to open
            keep_focus: If True, return focus to terminal after opening.
        """
        # Remember current window (likely terminal)
        current_win = self.call("nvim_get_current_win")

        # Find a non-terminal window to open the file in
        windows = self.call("nvim_list_wins")
        editor_win = None
        for win in windows:
            buf = self.call("nvim_win_get_buf", win)
            buftype = self.call("nvim_get_option_value", "buftype", {"buf": buf})
            bufname = self.call("nvim_buf_get_name", buf)
            # Skip terminal buffers and prism:// buffers
            if buftype != "terminal" and not bufname.startswith("prism://"):
                editor_win = win
                break

        if editor_win:
            # Switch to editor window and open file
            self.call("nvim_set_current_win", editor_win)
            self.command(f"edit {filepath}")
        else:
            # No editor window, create split on left
            self.command(f"topleft vsplit {filepath}")

        buf = self.get_current_buffer()

        # Return focus to original window (terminal)
        if keep_focus:
            self.call("nvim_set_current_win", current_win)

        return buf

    def save_file(self, filepath: Optional[str] = None) -> None:
        """Save the current buffer."""
        if filepath:
            self.command(f"saveas {filepath}")
        else:
            self.command("write")

    def close_buffer(self, buf_id: Optional[int] = None, force: bool = False) -> None:
        """Close a buffer."""
        if buf_id is None:
            buf_id = self.call("nvim_get_current_buf")
        cmd = "bdelete!" if force else "bdelete"
        self.command(f"{cmd} {buf_id}")

    # =========================================================================
    # Window Operations
    # =========================================================================

    def get_current_window(self) -> Window:
        """Get the current window."""
        win_id = self.call("nvim_get_current_win")
        return self._get_window_info(win_id)

    def get_windows(self) -> list[Window]:
        """Get all windows."""
        win_ids = self.call("nvim_list_wins")
        return [self._get_window_info(wid) for wid in win_ids]

    def _get_window_info(self, win_id: int) -> Window:
        """Get window information."""
        buf_id = self.call("nvim_win_get_buf", win_id)
        cursor = self.call("nvim_win_get_cursor", win_id)
        width = self.call("nvim_win_get_width", win_id)
        height = self.call("nvim_win_get_height", win_id)
        return Window(
            id=win_id,
            buffer_id=buf_id,
            cursor=tuple(cursor),
            width=width,
            height=height,
        )

    def split(self, vertical: bool = False, filepath: Optional[str] = None) -> Window:
        """Create a new split."""
        cmd = "vsplit" if vertical else "split"
        if filepath:
            cmd += f" {filepath}"
        self.command(cmd)
        return self.get_current_window()

    def close_window(self, win_id: Optional[int] = None, force: bool = False) -> None:
        """Close a window. Never closes terminal windows."""
        if win_id:
            # Check if it's a terminal - never close terminals
            buf = self.call("nvim_win_get_buf", win_id)
            buftype = self.call("nvim_get_option_value", "buftype", {"buf": buf})
            if buftype == "terminal":
                return  # Refuse to close terminal
            self.call("nvim_win_close", win_id, force)
        else:
            # Check current window
            buf = self.call("nvim_get_current_buf")
            buftype = self.call("nvim_get_option_value", "buftype", {"buf": buf})
            if buftype == "terminal":
                return  # Refuse to close terminal
            self.command("close!" if force else "close")

    def get_terminal_window(self) -> Optional[int]:
        """Find the terminal window. Returns window ID or None."""
        for win in self.call("nvim_list_wins"):
            buf = self.call("nvim_win_get_buf", win)
            buftype = self.call("nvim_get_option_value", "buftype", {"buf": buf})
            if buftype == "terminal":
                return win
        return None

    def ensure_terminal_visible(self) -> None:
        """Ensure terminal window exists and is visible."""
        terminal_win = self.get_terminal_window()
        if not terminal_win:
            # Terminal was somehow closed - this shouldn't happen
            self.notify("Warning: Terminal window not found", "warn")

    # =========================================================================
    # Cursor & Selection
    # =========================================================================

    def get_cursor(self) -> tuple[int, int]:
        """Get cursor position (1-indexed line, 0-indexed col)."""
        win_id = self.call("nvim_get_current_win")
        return tuple(self.call("nvim_win_get_cursor", win_id))

    def set_cursor(self, line: int, col: int) -> None:
        """Set cursor position."""
        win_id = self.call("nvim_get_current_win")
        self.call("nvim_win_set_cursor", win_id, [line, col])

    def get_selection(self) -> Optional[Selection]:
        """Get the current visual selection."""
        mode = self.call("nvim_get_mode")["mode"]

        if mode not in ("v", "V", "\x16"):  # visual, visual line, visual block
            return None

        # Get selection marks
        start = self.call("nvim_buf_get_mark", 0, "<")
        end = self.call("nvim_buf_get_mark", 0, ">")

        if not start or not end:
            return None

        # Get selected text
        buf_id = self.call("nvim_get_current_buf")

        if mode == "V":  # Visual line mode
            lines = self.call("nvim_buf_get_lines", buf_id, start[0] - 1, end[0], False)
            text = "\n".join(lines)
        else:
            # Get text between marks
            lines = self.call("nvim_buf_get_lines", buf_id, start[0] - 1, end[0], False)
            if len(lines) == 1:
                text = lines[0][start[1] : end[1] + 1]
            else:
                lines[0] = lines[0][start[1] :]
                lines[-1] = lines[-1][: end[1] + 1]
                text = "\n".join(lines)

        return Selection(
            text=text,
            start_line=start[0],
            start_col=start[1],
            end_line=end[0],
            end_col=end[1],
            mode=mode,
        )

    def select_range(self, start_line: int, start_col: int, end_line: int, end_col: int) -> None:
        """Select a range of text."""
        self.set_cursor(start_line, start_col)
        self.command("normal! v")
        self.set_cursor(end_line, end_col)

    # =========================================================================
    # LSP & Diagnostics
    # =========================================================================

    def get_diagnostics(self, buf_id: Optional[int] = None) -> list[dict]:
        """Get LSP diagnostics for a buffer."""
        if buf_id is None:
            buf_id = self.call("nvim_get_current_buf")

        diagnostics = self.lua(
            """
            local buf = ...
            local diagnostics = vim.diagnostic.get(buf)
            local result = {}
            for _, d in ipairs(diagnostics) do
                table.insert(result, {
                    message = d.message,
                    severity = d.severity,
                    lnum = d.lnum + 1,
                    col = d.col,
                    source = d.source,
                    code = d.code,
                })
            end
            return result
        """,
            buf_id,
        )

        return diagnostics or []

    def goto_definition(self) -> bool:
        """Go to LSP definition."""
        try:
            self.lua("vim.lsp.buf.definition()")
            return True
        except:
            return False

    def get_hover_info(self) -> Optional[str]:
        """Get LSP hover information."""
        try:
            result = self.lua(
                """
                local params = vim.lsp.util.make_position_params()
                local result = vim.lsp.buf_request_sync(0, 'textDocument/hover', params, 1000)
                if result and result[1] and result[1].result and result[1].result.contents then
                    local contents = result[1].result.contents
                    if type(contents) == 'string' then
                        return contents
                    elseif contents.value then
                        return contents.value
                    end
                end
                return nil
            """
            )
            return result
        except:
            return None

    def code_action(self) -> None:
        """Trigger code actions menu."""
        self.lua("vim.lsp.buf.code_action()")

    def format_buffer(self) -> None:
        """Format the current buffer using LSP."""
        self.lua("vim.lsp.buf.format()")

    # =========================================================================
    # Search & Replace
    # =========================================================================

    def search(self, pattern: str, flags: str = "") -> list[tuple[int, int]]:
        """Search for a pattern in the current buffer."""
        results = self.lua(
            f"""
            local pattern = ...
            local results = {{}}
            local buf = vim.api.nvim_get_current_buf()
            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            for i, line in ipairs(lines) do
                local start = 1
                while true do
                    local s, e = line:find(pattern, start)
                    if not s then break end
                    table.insert(results, {{i, s - 1}})
                    start = e + 1
                end
            end
            return results
        """,
            pattern,
        )
        return [tuple(r) for r in (results or [])]

    def replace(self, pattern: str, replacement: str, flags: str = "g") -> int:
        """Replace pattern in current buffer. Returns count of replacements."""
        count = self.lua(
            f"""
            local pattern, replacement, flags = ...
            vim.cmd(string.format('%%s/%s/%s/%s', pattern, replacement, flags))
            return vim.v.searchcount.total or 0
        """,
            pattern,
            replacement,
            flags,
        )
        return count or 0

    # =========================================================================
    # Git Integration
    # =========================================================================

    def git_status(self) -> dict:
        """Get git status for the current project."""
        return (
            self.lua(
                """
            local result = {
                branch = '',
                staged = {},
                unstaged = {},
                untracked = {},
            }

            -- Get branch
            local branch = vim.fn.system('git branch --show-current 2>/dev/null')
            result.branch = vim.trim(branch)

            -- Get status
            local status = vim.fn.system('git status --porcelain 2>/dev/null')
            for line in status:gmatch('[^\\n]+') do
                local xy, file = line:match('^(..)%s+(.+)$')
                if xy then
                    local x, y = xy:sub(1,1), xy:sub(2,2)
                    if x == '?' then
                        table.insert(result.untracked, file)
                    elseif x ~= ' ' then
                        table.insert(result.staged, file)
                    end
                    if y ~= ' ' and y ~= '?' then
                        table.insert(result.unstaged, file)
                    end
                end
            end

            return result
        """
            )
            or {}
        )

    def git_diff(self, staged: bool = False) -> str:
        """Get git diff."""
        cmd = "git diff --staged" if staged else "git diff"
        return self.eval(f"system('{cmd}')")

    # =========================================================================
    # Terminal
    # =========================================================================

    def open_terminal(self, cmd: Optional[str] = None) -> int:
        """Open a terminal buffer. Returns buffer id."""
        if cmd:
            self.command(f"terminal {cmd}")
        else:
            self.command("terminal")
        return self.call("nvim_get_current_buf")

    def send_to_terminal(self, text: str, buf_id: int) -> None:
        """Send text to a terminal buffer."""
        # Get the terminal channel
        channel = self.call("nvim_buf_get_option", buf_id, "channel")
        self.call("nvim_chan_send", channel, text)

    # =========================================================================
    # Notifications & UI
    # =========================================================================

    def notify(self, message: str, level: str = "info") -> None:
        """Show a notification in Neovim."""
        levels = {
            "error": "vim.log.levels.ERROR",
            "warn": "vim.log.levels.WARN",
            "info": "vim.log.levels.INFO",
            "debug": "vim.log.levels.DEBUG",
        }
        vim_level = levels.get(level, "vim.log.levels.INFO")
        self.lua(f"vim.notify(..., {vim_level})", message)

    def echo(self, message: str) -> None:
        """Echo a message in the command line."""
        self.command(f'echo "{message}"')

    def input(self, prompt: str) -> str:
        """Get input from the user."""
        return self.eval(f'input("{prompt}")')

    def confirm(self, message: str, choices: str = "&Yes\n&No") -> int:
        """Show a confirmation dialog. Returns choice number (1-indexed)."""
        return self.eval(f'confirm("{message}", "{choices}")')
