"""
Prism MCP Server - Exposes Neovim control to Claude Code

This server implements the Model Context Protocol (MCP) to allow Claude
to fully control a Neovim instance as an IDE.
"""

import asyncio
import json
import os
import sys
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any, Optional, Callable
import logging


class BytesEncoder(json.JSONEncoder):
    """Custom JSON encoder that handles bytes and dataclasses."""
    def default(self, obj):
        if isinstance(obj, bytes):
            return obj.decode('utf-8', errors='replace')
        if hasattr(obj, '__dataclass_fields__'):
            return asdict(obj)
        return super().default(obj)

from .nvim_client import NeovimClient

logger = logging.getLogger(__name__)


@dataclass
class Tool:
    """MCP Tool definition."""
    name: str
    description: str
    input_schema: dict
    handler: Callable


class PrismMCPServer:
    """
    MCP Server that provides Neovim IDE control to Claude.

    Implements the MCP protocol over stdio, exposing tools for:
    - File operations (open, save, close, create)
    - Buffer operations (read, write, edit)
    - Window management (split, close, navigate)
    - Selection and cursor control
    - LSP integration (diagnostics, go to definition, code actions)
    - Git integration (status, diff, stage, commit)
    - Terminal control
    - Search and replace
    """

    def __init__(self, nvim_address: Optional[str] = None):
        """
        Initialize the MCP server.

        Args:
            nvim_address: Neovim socket address (auto-detect if None)
        """
        self.nvim = NeovimClient(nvim_address)
        self.tools: dict[str, Tool] = {}

        # Global config - can be changed via set_config tool
        self.config = {
            "auto_save": False,  # Auto-save after edits
            "keep_focus": True,  # Return focus to terminal after opening files
        }

        self._setup_tools()

    def _setup_tools(self):
        """Register all MCP tools."""

        # =====================================================================
        # File Operations
        # =====================================================================

        self._register_tool(
            name="open_file",
            description="Open a file in the editor area (left side). Terminal stays focused.",
            input_schema={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Path to the file to open (absolute or relative to cwd)"
                    },
                    "keep_focus": {
                        "type": "boolean",
                        "description": "Return focus to terminal after opening (default: true)",
                        "default": True
                    }
                },
                "required": ["path"]
            },
            handler=self._handle_open_file
        )

        self._register_tool(
            name="save_file",
            description="Save the current buffer to disk. Optionally save to a new path.",
            input_schema={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Optional new path to save to (save as)"
                    }
                }
            },
            handler=self._handle_save_file
        )

        self._register_tool(
            name="close_file",
            description="Close a buffer/file. Can force close without saving.",
            input_schema={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Path of file to close (current buffer if not specified)"
                    },
                    "force": {
                        "type": "boolean",
                        "description": "Force close without saving changes",
                        "default": False
                    }
                }
            },
            handler=self._handle_close_file
        )

        self._register_tool(
            name="create_file",
            description="Create a new file with the given content.",
            input_schema={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Path for the new file"
                    },
                    "content": {
                        "type": "string",
                        "description": "Initial content for the file",
                        "default": ""
                    }
                },
                "required": ["path"]
            },
            handler=self._handle_create_file
        )

        # =====================================================================
        # Buffer Operations
        # =====================================================================

        self._register_tool(
            name="get_buffer_content",
            description="Read the entire content of a buffer/file.",
            input_schema={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Path of file to read (current buffer if not specified)"
                    }
                }
            },
            handler=self._handle_get_buffer_content
        )

        self._register_tool(
            name="get_buffer_lines",
            description="Read specific lines from a buffer.",
            input_schema={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Path of file (current buffer if not specified)"
                    },
                    "start_line": {
                        "type": "integer",
                        "description": "Start line (1-indexed)",
                        "default": 1
                    },
                    "end_line": {
                        "type": "integer",
                        "description": "End line (inclusive, -1 for end of file)",
                        "default": -1
                    }
                }
            },
            handler=self._handle_get_buffer_lines
        )

        self._register_tool(
            name="set_buffer_content",
            description="Replace the entire content of a buffer. Use auto_save=true for automatic mode.",
            input_schema={
                "type": "object",
                "properties": {
                    "content": {
                        "type": "string",
                        "description": "New content for the buffer"
                    },
                    "path": {
                        "type": "string",
                        "description": "Path of file (current buffer if not specified)"
                    },
                    "auto_save": {
                        "type": "boolean",
                        "description": "Automatically save after edit (default: false)",
                        "default": False
                    }
                },
                "required": ["content"]
            },
            handler=self._handle_set_buffer_content
        )

        self._register_tool(
            name="edit_buffer",
            description="Edit specific lines in a buffer. Replaces lines from start to end with new lines. Use auto_save=true for automatic mode.",
            input_schema={
                "type": "object",
                "properties": {
                    "start_line": {
                        "type": "integer",
                        "description": "Start line to replace (1-indexed)"
                    },
                    "end_line": {
                        "type": "integer",
                        "description": "End line to replace (inclusive)"
                    },
                    "new_lines": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "New lines to insert"
                    },
                    "path": {
                        "type": "string",
                        "description": "Path of file (current buffer if not specified)"
                    },
                    "auto_save": {
                        "type": "boolean",
                        "description": "Automatically save after edit (default: false)",
                        "default": False
                    }
                },
                "required": ["start_line", "end_line", "new_lines"]
            },
            handler=self._handle_edit_buffer
        )

        self._register_tool(
            name="insert_text",
            description="Insert text at a specific position in the buffer.",
            input_schema={
                "type": "object",
                "properties": {
                    "line": {
                        "type": "integer",
                        "description": "Line number (1-indexed)"
                    },
                    "column": {
                        "type": "integer",
                        "description": "Column number (0-indexed)"
                    },
                    "text": {
                        "type": "string",
                        "description": "Text to insert"
                    },
                    "path": {
                        "type": "string",
                        "description": "Path of file (current buffer if not specified)"
                    }
                },
                "required": ["line", "column", "text"]
            },
            handler=self._handle_insert_text
        )

        # =====================================================================
        # Editor State
        # =====================================================================

        self._register_tool(
            name="get_open_files",
            description="Get a list of all open files/buffers in Neovim.",
            input_schema={
                "type": "object",
                "properties": {}
            },
            handler=self._handle_get_open_files
        )

        self._register_tool(
            name="get_current_file",
            description="Get information about the currently focused file/buffer.",
            input_schema={
                "type": "object",
                "properties": {}
            },
            handler=self._handle_get_current_file
        )

        self._register_tool(
            name="get_cursor_position",
            description="Get the current cursor position.",
            input_schema={
                "type": "object",
                "properties": {}
            },
            handler=self._handle_get_cursor_position
        )

        self._register_tool(
            name="set_cursor_position",
            description="Move the cursor to a specific position.",
            input_schema={
                "type": "object",
                "properties": {
                    "line": {
                        "type": "integer",
                        "description": "Line number (1-indexed)"
                    },
                    "column": {
                        "type": "integer",
                        "description": "Column number (0-indexed)"
                    }
                },
                "required": ["line", "column"]
            },
            handler=self._handle_set_cursor_position
        )

        self._register_tool(
            name="get_selection",
            description="Get the currently selected text (if in visual mode).",
            input_schema={
                "type": "object",
                "properties": {}
            },
            handler=self._handle_get_selection
        )

        # =====================================================================
        # Window Management
        # =====================================================================

        self._register_tool(
            name="split_window",
            description="Create a new window split.",
            input_schema={
                "type": "object",
                "properties": {
                    "vertical": {
                        "type": "boolean",
                        "description": "Create vertical split (side by side)",
                        "default": False
                    },
                    "path": {
                        "type": "string",
                        "description": "File to open in new split"
                    }
                }
            },
            handler=self._handle_split_window
        )

        self._register_tool(
            name="close_window",
            description="Close the current window.",
            input_schema={
                "type": "object",
                "properties": {
                    "force": {
                        "type": "boolean",
                        "description": "Force close",
                        "default": False
                    }
                }
            },
            handler=self._handle_close_window
        )

        self._register_tool(
            name="get_windows",
            description="Get information about all open windows.",
            input_schema={
                "type": "object",
                "properties": {}
            },
            handler=self._handle_get_windows
        )

        # =====================================================================
        # LSP Integration
        # =====================================================================

        self._register_tool(
            name="get_diagnostics",
            description="Get LSP diagnostics (errors, warnings) for a file.",
            input_schema={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Path of file (current buffer if not specified)"
                    }
                }
            },
            handler=self._handle_get_diagnostics
        )

        self._register_tool(
            name="goto_definition",
            description="Go to the definition of the symbol under cursor.",
            input_schema={
                "type": "object",
                "properties": {}
            },
            handler=self._handle_goto_definition
        )

        self._register_tool(
            name="get_hover_info",
            description="Get hover information (documentation) for symbol under cursor.",
            input_schema={
                "type": "object",
                "properties": {}
            },
            handler=self._handle_get_hover_info
        )

        self._register_tool(
            name="format_file",
            description="Format the current file using LSP formatter.",
            input_schema={
                "type": "object",
                "properties": {}
            },
            handler=self._handle_format_file
        )

        # =====================================================================
        # Search & Replace
        # =====================================================================

        self._register_tool(
            name="search_in_file",
            description="Search for a pattern in the current file.",
            input_schema={
                "type": "object",
                "properties": {
                    "pattern": {
                        "type": "string",
                        "description": "Search pattern (Lua pattern)"
                    }
                },
                "required": ["pattern"]
            },
            handler=self._handle_search_in_file
        )

        self._register_tool(
            name="search_and_replace",
            description="Search and replace in the current file.",
            input_schema={
                "type": "object",
                "properties": {
                    "pattern": {
                        "type": "string",
                        "description": "Search pattern"
                    },
                    "replacement": {
                        "type": "string",
                        "description": "Replacement text"
                    },
                    "flags": {
                        "type": "string",
                        "description": "Flags: g (global), i (ignore case), c (confirm)",
                        "default": "g"
                    }
                },
                "required": ["pattern", "replacement"]
            },
            handler=self._handle_search_and_replace
        )

        # =====================================================================
        # Git Integration
        # =====================================================================

        self._register_tool(
            name="git_status",
            description="Get git status for the current project.",
            input_schema={
                "type": "object",
                "properties": {}
            },
            handler=self._handle_git_status
        )

        self._register_tool(
            name="git_diff",
            description="Get git diff for the current project.",
            input_schema={
                "type": "object",
                "properties": {
                    "staged": {
                        "type": "boolean",
                        "description": "Show staged changes only",
                        "default": False
                    }
                }
            },
            handler=self._handle_git_diff
        )

        # =====================================================================
        # Terminal
        # =====================================================================

        self._register_tool(
            name="open_terminal",
            description="Open a terminal in Neovim.",
            input_schema={
                "type": "object",
                "properties": {
                    "command": {
                        "type": "string",
                        "description": "Command to run in terminal"
                    }
                }
            },
            handler=self._handle_open_terminal
        )

        self._register_tool(
            name="run_command",
            description="Execute a Neovim command (ex command).",
            input_schema={
                "type": "object",
                "properties": {
                    "command": {
                        "type": "string",
                        "description": "Neovim command to execute"
                    }
                },
                "required": ["command"]
            },
            handler=self._handle_run_command
        )

        # =====================================================================
        # Notifications
        # =====================================================================

        self._register_tool(
            name="notify",
            description="Show a notification message to the user in Neovim.",
            input_schema={
                "type": "object",
                "properties": {
                    "message": {
                        "type": "string",
                        "description": "Message to display"
                    },
                    "level": {
                        "type": "string",
                        "enum": ["info", "warn", "error"],
                        "description": "Notification level",
                        "default": "info"
                    }
                },
                "required": ["message"]
            },
            handler=self._handle_notify
        )

        # =====================================================================
        # Configuration
        # =====================================================================

        self._register_tool(
            name="get_config",
            description="Get current prism-nvim configuration.",
            input_schema={
                "type": "object",
                "properties": {}
            },
            handler=self._handle_get_config
        )

        self._register_tool(
            name="set_config",
            description="Set prism-nvim configuration. Use auto_save=true for automatic mode where all edits are saved immediately.",
            input_schema={
                "type": "object",
                "properties": {
                    "auto_save": {
                        "type": "boolean",
                        "description": "Auto-save after all buffer edits (default: false)"
                    },
                    "keep_focus": {
                        "type": "boolean",
                        "description": "Return focus to terminal after opening files (default: true)"
                    }
                }
            },
            handler=self._handle_set_config
        )

        self._register_tool(
            name="diff_preview",
            description="Show diff preview in editor area. Terminal stays focused. Shows original vs proposed changes side by side.",
            input_schema={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Path to the file to diff"
                    },
                    "new_content": {
                        "type": "string",
                        "description": "Proposed new content for the file"
                    }
                },
                "required": ["path", "new_content"]
            },
            handler=self._handle_diff_preview
        )

    def _register_tool(
        self,
        name: str,
        description: str,
        input_schema: dict,
        handler: Callable
    ):
        """Register an MCP tool."""
        self.tools[name] = Tool(
            name=name,
            description=description,
            input_schema=input_schema,
            handler=handler
        )

    # =========================================================================
    # Tool Handlers
    # =========================================================================

    def _handle_open_file(
        self,
        path: str,
        keep_focus: Optional[bool] = None
    ) -> dict:
        """Open a file in the editor area (not the terminal)."""
        if keep_focus is None:
            keep_focus = self.config.get("keep_focus", True)
        elif isinstance(keep_focus, str):
            keep_focus = keep_focus.lower() == "true"

        buf = self.nvim.open_file(path, keep_focus=keep_focus)
        return {
            "success": True,
            "buffer_id": buf.id,
            "path": buf.name,
            "filetype": buf.filetype
        }

    def _handle_save_file(self, path: Optional[str] = None) -> dict:
        """Save current file."""
        self.nvim.save_file(path)
        return {"success": True}

    def _handle_close_file(
        self,
        path: Optional[str] = None,
        force: bool = False
    ) -> dict:
        """Close a file."""
        if path:
            # Find buffer by path
            for buf in self.nvim.get_buffers():
                if buf.name.endswith(path) or buf.name == path:
                    self.nvim.close_buffer(buf.id, force)
                    return {"success": True}
            return {"success": False, "error": "File not found"}
        else:
            self.nvim.close_buffer(force=force)
            return {"success": True}

    def _handle_create_file(self, path: str, content: str = "") -> dict:
        """Create a new file."""
        # Create parent directories
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        # Write content
        Path(path).write_text(content)
        # Open in editor
        buf = self.nvim.open_file(path)
        return {
            "success": True,
            "path": path,
            "buffer_id": buf.id
        }

    def _handle_get_buffer_content(self, path: Optional[str] = None) -> dict:
        """Get buffer content."""
        buf_id = None
        if path:
            for buf in self.nvim.get_buffers():
                if buf.name.endswith(path) or buf.name == path:
                    buf_id = buf.id
                    break

        content = self.nvim.get_buffer_content(buf_id)
        return {"content": content}

    def _handle_get_buffer_lines(
        self,
        path: Optional[str] = None,
        start_line: int = 1,
        end_line: int = -1
    ) -> dict:
        """Get specific lines."""
        # Ensure integer types (JSON might send strings)
        start_line = int(start_line) if start_line is not None else 1
        end_line = int(end_line) if end_line is not None else -1

        buf_id = None
        if path:
            for buf in self.nvim.get_buffers():
                if buf.name.endswith(path) or buf.name == path:
                    buf_id = buf.id
                    break

        # Convert to 0-indexed
        start = start_line - 1
        end_idx = end_line if end_line == -1 else end_line

        lines = self.nvim.get_buffer_lines(start, end_idx, buf_id)
        return {"lines": lines, "start_line": start_line, "count": len(lines)}

    def _handle_set_buffer_content(
        self,
        content: str,
        path: Optional[str] = None,
        auto_save: Optional[bool] = None
    ) -> dict:
        """Set buffer content."""
        # Use global config if not explicitly passed
        if auto_save is None:
            auto_save = self.config.get("auto_save", False)
        elif isinstance(auto_save, str):
            auto_save = auto_save.lower() == "true"

        buf_id = None
        if path:
            for buf in self.nvim.get_buffers():
                if buf.name.endswith(path) or buf.name == path:
                    buf_id = buf.id
                    break

        self.nvim.set_buffer_content(content, buf_id)

        # Auto-save if enabled (via param or global config)
        if auto_save:
            if buf_id:
                self.nvim.command(f"buffer {buf_id} | write")
            else:
                self.nvim.save_file()

        return {"success": True, "saved": auto_save}

    def _handle_edit_buffer(
        self,
        start_line: int,
        end_line: int,
        new_lines: list[str],
        path: Optional[str] = None,
        auto_save: Optional[bool] = None
    ) -> dict:
        """Edit specific lines."""
        # Ensure integer types (JSON might send strings)
        start_line = int(start_line)
        end_line = int(end_line)

        # Use global config if not explicitly passed
        if auto_save is None:
            auto_save = self.config.get("auto_save", False)
        elif isinstance(auto_save, str):
            auto_save = auto_save.lower() == "true"

        # Handle new_lines as string (Claude Code sometimes serializes arrays as strings)
        if isinstance(new_lines, str):
            new_lines = json.loads(new_lines)

        buf_id = None
        if path:
            for buf in self.nvim.get_buffers():
                if buf.name.endswith(path) or buf.name == path:
                    buf_id = buf.id
                    break

        # Convert to 0-indexed
        start = start_line - 1
        end_idx = end_line

        self.nvim.set_buffer_lines(new_lines, start, end_idx, buf_id)

        # Auto-save if enabled (via param or global config)
        if auto_save:
            if buf_id:
                # Save specific buffer
                self.nvim.command(f"buffer {buf_id} | write")
            else:
                self.nvim.save_file()

        return {"success": True, "lines_changed": len(new_lines), "saved": auto_save}

    def _handle_insert_text(
        self,
        line: int,
        column: int,
        text: str,
        path: Optional[str] = None
    ) -> dict:
        """Insert text at position."""
        # Ensure integer types
        line = int(line)
        column = int(column)

        buf_id = None
        if path:
            for buf in self.nvim.get_buffers():
                if buf.name.endswith(path) or buf.name == path:
                    buf_id = buf.id
                    break

        self.nvim.insert_text(text, line - 1, column, buf_id)
        return {"success": True}

    def _handle_get_open_files(self) -> dict:
        """Get all open files."""
        buffers = self.nvim.get_buffers()
        return {
            "files": [
                {
                    "id": buf.id,
                    "path": buf.name,
                    "filetype": buf.filetype,
                    "modified": buf.modified
                }
                for buf in buffers
            ]
        }

    def _handle_get_current_file(self) -> dict:
        """Get current file info."""
        buf = self.nvim.get_current_buffer()
        cursor = self.nvim.get_cursor()
        return {
            "id": buf.id,
            "path": buf.name,
            "filetype": buf.filetype,
            "modified": buf.modified,
            "cursor": {"line": cursor[0], "column": cursor[1]}
        }

    def _handle_get_cursor_position(self) -> dict:
        """Get cursor position."""
        line, col = self.nvim.get_cursor()
        return {"line": line, "column": col}

    def _handle_set_cursor_position(self, line: int, column: int) -> dict:
        """Set cursor position."""
        line = int(line)
        column = int(column)
        self.nvim.set_cursor(line, column)
        return {"success": True}

    def _handle_get_selection(self) -> dict:
        """Get current selection."""
        sel = self.nvim.get_selection()
        if sel:
            return {
                "text": sel.text,
                "start_line": sel.start_line,
                "start_column": sel.start_col,
                "end_line": sel.end_line,
                "end_column": sel.end_col,
                "mode": sel.mode
            }
        return {"text": None, "message": "No selection active"}

    def _handle_split_window(
        self,
        vertical: bool = False,
        path: Optional[str] = None
    ) -> dict:
        """Create window split."""
        win = self.nvim.split(vertical, path)
        return {
            "success": True,
            "window_id": win.id,
            "buffer_id": win.buffer_id
        }

    def _handle_close_window(self, force: bool = False) -> dict:
        """Close current window."""
        self.nvim.close_window(force=force)
        return {"success": True}

    def _handle_get_windows(self) -> dict:
        """Get all windows."""
        windows = self.nvim.get_windows()
        return {
            "windows": [
                {
                    "id": win.id,
                    "buffer_id": win.buffer_id,
                    "cursor": {"line": win.cursor[0], "column": win.cursor[1]},
                    "width": win.width,
                    "height": win.height
                }
                for win in windows
            ]
        }

    def _handle_get_diagnostics(self, path: Optional[str] = None) -> dict:
        """Get LSP diagnostics."""
        buf_id = None
        if path:
            for buf in self.nvim.get_buffers():
                if buf.name.endswith(path) or buf.name == path:
                    buf_id = buf.id
                    break

        diagnostics = self.nvim.get_diagnostics(buf_id)
        return {"diagnostics": diagnostics}

    def _handle_goto_definition(self) -> dict:
        """Go to definition."""
        success = self.nvim.goto_definition()
        if success:
            buf = self.nvim.get_current_buffer()
            cursor = self.nvim.get_cursor()
            return {
                "success": True,
                "path": buf.name,
                "line": cursor[0],
                "column": cursor[1]
            }
        return {"success": False, "error": "No definition found"}

    def _handle_get_hover_info(self) -> dict:
        """Get hover info."""
        info = self.nvim.get_hover_info()
        return {"info": info}

    def _handle_format_file(self) -> dict:
        """Format current file."""
        self.nvim.format_buffer()
        return {"success": True}

    def _handle_search_in_file(self, pattern: str) -> dict:
        """Search in file."""
        results = self.nvim.search(pattern)
        return {
            "matches": [
                {"line": r[0], "column": r[1]}
                for r in results
            ],
            "count": len(results)
        }

    def _handle_search_and_replace(
        self,
        pattern: str,
        replacement: str,
        flags: str = "g"
    ) -> dict:
        """Search and replace."""
        count = self.nvim.replace(pattern, replacement, flags)
        return {"success": True, "replacements": count}

    def _handle_git_status(self) -> dict:
        """Get git status."""
        return self.nvim.git_status()

    def _handle_git_diff(self, staged: bool = False) -> dict:
        """Get git diff."""
        diff = self.nvim.git_diff(staged)
        return {"diff": diff}

    def _handle_open_terminal(self, command: Optional[str] = None) -> dict:
        """Open terminal."""
        buf_id = self.nvim.open_terminal(command)
        return {"success": True, "buffer_id": buf_id}

    def _handle_run_command(self, command: str) -> dict:
        """Run Neovim command.

        Protects the terminal window by switching to editor window first
        for commands that open/edit files.
        """
        try:
            # Commands that could replace the current buffer (terminal)
            buffer_changing_commands = [
                'edit', 'e ', 'e!', 'buffer', 'b ', 'bnext', 'bprev',
                'split', 'sp ', 'vsplit', 'vs ', 'new', 'vnew', 'enew',
                'tabnew', 'tabedit', 'tabe '
            ]

            cmd_lower = command.lower().strip()
            needs_editor_window = any(
                cmd_lower.startswith(cmd) or cmd_lower == cmd.strip()
                for cmd in buffer_changing_commands
            )

            if needs_editor_window:
                # Find a non-terminal window and switch to it first
                current_win = self.nvim.call("nvim_get_current_win")
                current_buf = self.nvim.call("nvim_get_current_buf")
                buftype = self.nvim.call("nvim_get_option_value", "buftype", {"buf": current_buf})
                is_terminal = buftype == "terminal"

                if is_terminal:
                    # Find editor window
                    for win in self.nvim.call("nvim_list_wins"):
                        win_buf = self.nvim.call("nvim_win_get_buf", win)
                        win_buftype = self.nvim.call("nvim_get_option_value", "buftype", {"buf": win_buf})
                        if win_buftype != "terminal":
                            self.nvim.call("nvim_set_current_win", win)
                            break

                    # Run command in editor window
                    self.nvim.command(command)

                    # Return focus to terminal
                    try:
                        self.nvim.call("nvim_set_current_win", current_win)
                    except:
                        pass  # Window may be invalid
                    return {"success": True, "protected": True}

            # Run command normally
            self.nvim.command(command)
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_notify(self, message: str, level: str = "info") -> dict:
        """Show notification."""
        self.nvim.notify(message, level)
        return {"success": True}

    def _handle_get_config(self) -> dict:
        """Get current configuration."""
        return {"config": self.config}

    def _handle_set_config(
        self,
        auto_save: Optional[bool] = None,
        keep_focus: Optional[bool] = None
    ) -> dict:
        """Set configuration options."""
        # Handle string booleans from JSON
        def parse_bool(val):
            if val is None:
                return None
            if isinstance(val, str):
                return val.lower() == "true"
            return bool(val)

        if auto_save is not None:
            self.config["auto_save"] = parse_bool(auto_save)
        if keep_focus is not None:
            self.config["keep_focus"] = parse_bool(keep_focus)

        # Notify user of config change
        self.nvim.notify(f"Prism config: auto_save={self.config['auto_save']}", "info")

        return {"success": True, "config": self.config}

    def _handle_diff_preview(
        self,
        path: str,
        new_content: str
    ) -> dict:
        """Show diff preview before applying changes. Opens a diff view in editor area."""
        # Remember current window (terminal)
        current_win = self.nvim.call("nvim_get_current_win")

        # Find editor window (non-terminal)
        windows = self.nvim.call("nvim_list_wins")
        editor_win = None
        for win in windows:
            buf = self.nvim.call("nvim_win_get_buf", win)
            buftype = self.nvim.call("nvim_get_option_value", "buftype", {"buf": buf})
            if buftype != "terminal":
                editor_win = win
                break

        if editor_win:
            self.nvim.call("nvim_set_current_win", editor_win)
        else:
            # Create editor window on left
            self.nvim.command("topleft vnew")

        # Open original file
        self.nvim.command(f"edit {path}")
        self.nvim.command("diffthis")

        # Create horizontal split below for proposed changes
        self.nvim.command("belowright new")
        self.nvim.command("setlocal buftype=nofile bufhidden=wipe noswapfile")
        self.nvim.command("file prism://proposed-changes")
        self.nvim.set_buffer_content(new_content)
        self.nvim.command("diffthis")

        # Return focus to terminal
        self.nvim.call("nvim_set_current_win", current_win)

        return {
            "success": True,
            "message": "Diff preview opened in editor area. Use :diffoff and :bd to close when done."
        }

    # =========================================================================
    # MCP Protocol Implementation
    # =========================================================================

    def run_sync(self):
        """Run the MCP server over stdio using NDJSON (newline-delimited JSON)."""
        logger.info("Starting Prism MCP Server...")

        # Connect to Neovim
        try:
            self.nvim.connect()
            logger.info("Connected to Neovim")
        except Exception as e:
            logger.error(f"Failed to connect to Neovim: {e}")
            sys.exit(1)

        # Use text mode for NDJSON - Claude Code sends one JSON per line
        import sys

        while True:
            try:
                # Read one line (one JSON message)
                line = sys.stdin.readline()
                if not line:
                    logger.info("EOF on stdin")
                    return

                line = line.strip()
                if not line:
                    continue  # Skip empty lines

                logger.info(f"Received: {line[:200]}")
                message = json.loads(line)
                response = self._handle_message_sync(message)

                if response:
                    # Send response as single line JSON + newline
                    response_json = json.dumps(response)
                    sys.stdout.write(response_json + "\n")
                    sys.stdout.flush()
                    logger.info(f"Sent response for {message.get('method')}")

            except json.JSONDecodeError as e:
                logger.error(f"Invalid JSON: {e}")
            except Exception as e:
                logger.error(f"Error handling message: {e}")
                import traceback
                logger.error(traceback.format_exc())

    async def run(self):
        """Async wrapper for compatibility."""
        self.run_sync()

    def _handle_message_sync(self, message: dict) -> Optional[dict]:
        """Handle an MCP JSON-RPC message (synchronous)."""
        method = message.get("method")
        msg_id = message.get("id")
        params = message.get("params", {})

        logger.info(f"Handling method: {method}")

        if method == "initialize":
            return self._handle_initialize(msg_id, params)
        elif method == "tools/list":
            return self._handle_list_tools(msg_id)
        elif method == "tools/call":
            return self._handle_tool_call_sync(msg_id, params)
        elif method == "notifications/initialized":
            return None  # No response needed
        else:
            logger.warning(f"Unknown method: {method}")
            return None

    async def _handle_message(self, message: dict) -> Optional[dict]:
        """Handle an MCP JSON-RPC message (async wrapper)."""
        return self._handle_message_sync(message)

    def _handle_initialize(self, msg_id: int, params: dict) -> dict:
        """Handle initialize request."""
        return {
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "serverInfo": {
                    "name": "prism-nvim",
                    "version": "0.1.0"
                },
                "capabilities": {
                    "tools": {
                        "listChanged": False
                    }
                }
            }
        }

    def _handle_list_tools(self, msg_id: int) -> dict:
        """Handle tools/list request."""
        tools_list = [
            {
                "name": tool.name,
                "description": tool.description,
                "inputSchema": tool.input_schema
            }
            for tool in self.tools.values()
        ]

        return {
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {"tools": tools_list}
        }

    def _handle_tool_call_sync(self, msg_id: int, params: dict) -> dict:
        """Handle tools/call request (synchronous)."""
        tool_name = params.get("name")
        arguments = params.get("arguments", {})

        logger.info(f"Tool call: {tool_name} with args: {arguments}")

        if tool_name not in self.tools:
            return {
                "jsonrpc": "2.0",
                "id": msg_id,
                "error": {
                    "code": -32601,
                    "message": f"Unknown tool: {tool_name}"
                }
            }

        tool = self.tools[tool_name]

        try:
            result = tool.handler(**arguments)
            return {
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "content": [
                        {
                            "type": "text",
                            "text": json.dumps(result, indent=2, cls=BytesEncoder)
                        }
                    ]
                }
            }
        except Exception as e:
            logger.error(f"Tool error: {e}")
            import traceback
            logger.error(traceback.format_exc())
            return {
                "jsonrpc": "2.0",
                "id": msg_id,
                "error": {
                    "code": -32000,
                    "message": str(e)
                }
            }

    async def _handle_tool_call(self, msg_id: int, params: dict) -> dict:
        """Handle tools/call request (async wrapper)."""
        return self._handle_tool_call_sync(msg_id, params)


def main():
    """Main entry point."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[logging.FileHandler("/tmp/prism-mcp.log")]
    )

    server = PrismMCPServer()
    asyncio.run(server.run())


if __name__ == "__main__":
    main()
