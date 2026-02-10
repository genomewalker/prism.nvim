"""
Prism MCP Server - Exposes Neovim control to Claude Code

This server implements the Model Context Protocol (MCP) to allow Claude
to fully control a Neovim instance as an IDE.

Uses the official MCP SDK for proper protocol handling.
"""

import asyncio
import json
import logging
import os
from dataclasses import asdict, dataclass
from typing import Callable, Optional

from mcp.server import InitializationOptions, Server
from mcp.server.stdio import stdio_server
from mcp.types import ServerCapabilities, TextContent, ToolsCapability
from mcp.types import Tool as MCPTool

from .nvim_client import NeovimClient


def _path_matches(buf_name: str, path: str) -> bool:
    """Check if a buffer name matches a path.

    Avoids false positives from simple endswith() matching.
    For example, "utils.py" should NOT match "/some/other_utils.py".
    """
    if buf_name == path:
        return True
    # Check if path matches the end with a path separator before it
    if buf_name.endswith(path) and buf_name[-len(path) - 1] == os.sep:
        return True
    # Also check basename match for simple filenames
    if os.sep not in path and os.path.basename(buf_name) == path:
        return True
    return False


class BytesEncoder(json.JSONEncoder):
    """Custom JSON encoder that handles bytes and dataclasses."""

    def default(self, obj):
        if isinstance(obj, bytes):
            return obj.decode("utf-8", errors="replace")
        if hasattr(obj, "__dataclass_fields__"):
            return asdict(obj)
        return super().default(obj)


logger = logging.getLogger(__name__)


@dataclass
class ToolDef:
    """Internal tool definition."""

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
        self.tools: dict[str, ToolDef] = {}

        # Global config - can be changed via set_config tool
        self.config = {
            "auto_save": False,  # Auto-save after edits
            "keep_focus": True,  # Return focus to terminal after opening files
            "narrated": False,  # Explain vim commands as they happen
        }

        # Bookmarks storage
        self.bookmarks: dict[str, dict] = {}

        self._setup_tools()

    def _setup_tools(self):
        """Register all MCP tools."""

        # =====================================================================
        # File Operations
        # =====================================================================

        self._register_tool(
            name="open_file",
            description="""Open a file in the editor area (left side). Terminal stays focused.

Use this when the user says:
- "open X" / "show me X" / "pull up X"
- "let me see X" / "display X" / "view X"
- "open that file" / "show the file"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Path to the file to open (absolute or relative to cwd)",
                    },
                    "line": {
                        "type": "integer",
                        "description": "Line number to jump to after opening (1-indexed)",
                    },
                    "column": {
                        "type": "integer",
                        "description": "Column number to jump to after opening (1-indexed)",
                    },
                    "keep_focus": {
                        "type": "boolean",
                        "description": "Return focus to terminal after opening (default: true)",
                        "default": True,
                    },
                },
                "required": ["path"],
            },
            handler=self._handle_open_file,
        )

        self._register_tool(
            name="save_file",
            description="""Save the current buffer to disk. Optionally save to a new path.

Use this when the user says:
- "save" / "save this" / "save the file"
- "write it" / "commit changes" / "persist"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Optional new path to save to (save as)",
                    }
                },
            },
            handler=self._handle_save_file,
        )

        self._register_tool(
            name="close_file",
            description="""Close a buffer/file. Can force close without saving.

Use this when the user says:
- "close this" / "close the file" / "close X"
- "done with this file" / "I'm finished with X"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Path of file to close (current buffer if not specified)",
                    },
                    "force": {
                        "type": "boolean",
                        "description": "Force close without saving changes",
                        "default": False,
                    },
                },
            },
            handler=self._handle_close_file,
        )

        self._register_tool(
            name="create_file",
            description="""Create a new file with the given content.

Use this when the user says:
- "create X" / "make a new file" / "new file called X"
- "create a file for X" / "start a new X file"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Path for the new file"},
                    "content": {
                        "type": "string",
                        "description": "Initial content for the file",
                        "default": "",
                    },
                },
                "required": ["path"],
            },
            handler=self._handle_create_file,
        )

        # =====================================================================
        # Buffer Operations
        # =====================================================================

        self._register_tool(
            name="get_buffer_content",
            description="""Read the entire content of a buffer/file.

Use this when the user says:
- "read X" / "show me what's in X" / "get the contents of X"
- "what's in this file?" / "read the whole file"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Path of file to read (current buffer if not specified)",
                    }
                },
            },
            handler=self._handle_get_buffer_content,
        )

        self._register_tool(
            name="get_buffer_lines",
            description="""Read specific lines from a buffer.

Use this when the user says:
- "show lines X to Y" / "read lines X-Y" / "get lines X through Y"
- "show me line X" / "what's on line X?"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Path of file (current buffer if not specified)",
                    },
                    "start_line": {
                        "type": "integer",
                        "description": "Start line (1-indexed)",
                        "default": 1,
                    },
                    "end_line": {
                        "type": "integer",
                        "description": "End line (inclusive, -1 for end of file)",
                        "default": -1,
                    },
                },
            },
            handler=self._handle_get_buffer_lines,
        )

        self._register_tool(
            name="set_buffer_content",
            description="""Replace entire buffer content. Use auto_save=true to save.

Use this when the user says:
- "replace the whole file with X" / "rewrite this file"
- "set the content to X" / "overwrite everything with X"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "content": {"type": "string", "description": "New content for the buffer"},
                    "path": {
                        "type": "string",
                        "description": "Path of file (current buffer if not specified)",
                    },
                    "auto_save": {
                        "type": "boolean",
                        "description": "Automatically save after edit (default: false)",
                        "default": False,
                    },
                },
                "required": ["content"],
            },
            handler=self._handle_set_buffer_content,
        )

        self._register_tool(
            name="edit_buffer",
            description="""Edit specific lines. Replaces start to end with new lines.

Use this when the user says:
- "change lines X to Y" / "edit lines X-Y" / "modify lines X through Y"
- "replace lines X to Y with Z" / "update those lines"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "start_line": {
                        "type": "integer",
                        "description": "Start line to replace (1-indexed)",
                    },
                    "end_line": {
                        "type": "integer",
                        "description": "End line to replace (inclusive)",
                    },
                    "new_lines": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "New lines to insert",
                    },
                    "path": {
                        "type": "string",
                        "description": "Path of file (current buffer if not specified)",
                    },
                    "auto_save": {
                        "type": "boolean",
                        "description": "Automatically save after edit (default: false)",
                        "default": False,
                    },
                },
                "required": ["start_line", "end_line", "new_lines"],
            },
            handler=self._handle_edit_buffer,
        )

        self._register_tool(
            name="insert_text",
            description="""Insert text at a specific position in the buffer.

Use this when the user says:
- "insert X at line Y" / "add X on line Y" / "put X at line Y"
- "insert X here" / "add this text"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "line": {"type": "integer", "description": "Line number (1-indexed)"},
                    "column": {"type": "integer", "description": "Column number (0-indexed)"},
                    "text": {"type": "string", "description": "Text to insert"},
                    "path": {
                        "type": "string",
                        "description": "Path of file (current buffer if not specified)",
                    },
                },
                "required": ["line", "column", "text"],
            },
            handler=self._handle_insert_text,
        )

        # =====================================================================
        # Editor State
        # =====================================================================

        self._register_tool(
            name="get_open_files",
            description="""Get a list of all open files/buffers in Neovim.

Use this when the user says:
- "what files are open?" / "show open files" / "list buffers"
- "what do I have open?" / "show my buffers"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_get_open_files,
        )

        self._register_tool(
            name="get_current_file",
            description="""Get information about the currently focused file/buffer.

Use this when the user says:
- "what file is this?" / "which file am I in?" / "current file"
- "where am I?" / "what's the current buffer?"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_get_current_file,
        )

        self._register_tool(
            name="get_cursor_position",
            description="""Get the current cursor position.

Use this when the user says:
- "where's the cursor?" / "cursor position" / "what line am I on?"
- "where am I in the file?"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_get_cursor_position,
        )

        self._register_tool(
            name="set_cursor_position",
            description="""Move the cursor to a specific position.

Use this when the user says:
- "move cursor to line X column Y" / "put cursor at X,Y"
- "position at line X, column Y"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "line": {"type": "integer", "description": "Line number (1-indexed)"},
                    "column": {"type": "integer", "description": "Column number (0-indexed)"},
                },
                "required": ["line", "column"],
            },
            handler=self._handle_set_cursor_position,
        )

        self._register_tool(
            name="get_selection",
            description="""Get the currently selected text (if in visual mode).

Use this when the user says:
- "what's selected?" / "get the selection" / "show selected text"
- "what did I highlight?"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_get_selection,
        )

        # =====================================================================
        # Window Management
        # =====================================================================

        self._register_tool(
            name="split_window",
            description="""Create a new window split.

Use this when the user says:
- "split the window" / "create a split" / "open in split"
- "side by side" / "vertical split" / "horizontal split"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "vertical": {
                        "type": "boolean",
                        "description": "Create vertical split (side by side)",
                        "default": False,
                    },
                    "path": {"type": "string", "description": "File to open in new split"},
                },
            },
            handler=self._handle_split_window,
        )

        self._register_tool(
            name="close_window",
            description="""Close the current window.

Use this when the user says:
- "close this window" / "close the split" / "close pane"
- "get rid of this window"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "force": {"type": "boolean", "description": "Force close", "default": False}
                },
            },
            handler=self._handle_close_window,
        )

        self._register_tool(
            name="get_windows",
            description="""Get information about all open windows.

Use this when the user says:
- "what windows are open?" / "show windows" / "list splits"
- "how many windows?" / "window layout"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_get_windows,
        )

        # =====================================================================
        # LSP Integration
        # =====================================================================

        self._register_tool(
            name="get_diagnostics",
            description="""Get LSP diagnostics (errors, warnings) for a file.

Use this when the user says:
- "show errors" / "any problems?" / "what's wrong?"
- "list warnings" / "check for issues" / "diagnostics"
- "are there any errors?" / "find problems"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Path of file (current buffer if not specified)",
                    }
                },
            },
            handler=self._handle_get_diagnostics,
        )

        self._register_tool(
            name="goto_definition",
            description="""Go to the definition of the symbol under cursor.

Use this when the user says:
- "go to definition" / "where is this defined?" / "jump to definition"
- "show me the definition" / "take me to where this is defined"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_goto_definition,
        )

        self._register_tool(
            name="get_hover_info",
            description="""Get hover information (documentation) for symbol under cursor.

Use this when the user says:
- "what is this?" / "hover info" / "show documentation"
- "explain this symbol" / "what does this do?"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_get_hover_info,
        )

        self._register_tool(
            name="format_file",
            description="""Format the current file using LSP formatter.

Use this when the user says:
- "format this" / "prettify" / "auto-format"
- "fix formatting" / "clean up the code" / "make it pretty"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_format_file,
        )

        # =====================================================================
        # Search & Replace
        # =====================================================================

        self._register_tool(
            name="search_in_file",
            description="""Search for a pattern in the current file.

Use this when the user says:
- "find X" / "search for X" / "look for X"
- "where is X?" / "locate X in this file"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "pattern": {"type": "string", "description": "Search pattern (Lua pattern)"}
                },
                "required": ["pattern"],
            },
            handler=self._handle_search_in_file,
        )

        self._register_tool(
            name="search_and_replace",
            description="""Search and replace in the current file.

Use this when the user says:
- "replace X with Y" / "change X to Y" / "substitute X for Y"
- "find and replace" / "swap X for Y" / "rename X to Y"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "pattern": {"type": "string", "description": "Search pattern"},
                    "replacement": {"type": "string", "description": "Replacement text"},
                    "flags": {
                        "type": "string",
                        "description": "Flags: g (global), i (ignore case), c (confirm)",
                        "default": "g",
                    },
                },
                "required": ["pattern", "replacement"],
            },
            handler=self._handle_search_and_replace,
        )

        # =====================================================================
        # Git Integration
        # =====================================================================

        self._register_tool(
            name="git_status",
            description="""Get git status for the current project.

Use this when the user says:
- "git status" / "what's changed?" / "show changes"
- "any uncommitted changes?" / "what's modified?"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_git_status,
        )

        self._register_tool(
            name="git_diff",
            description="""Get git diff for the current project.

Use this when the user says:
- "show diff" / "what changed?" / "git diff"
- "show me the changes" / "what did I modify?"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "staged": {
                        "type": "boolean",
                        "description": "Show staged changes only",
                        "default": False,
                    }
                },
            },
            handler=self._handle_git_diff,
        )

        self._register_tool(
            name="git_stage",
            description="""Stage files for commit.

Use this when the user says:
- "stage this file" / "add to commit" / "git add"
- "stage all changes" / "add everything"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "File path to stage (current file if not specified)",
                    },
                    "all": {
                        "type": "boolean",
                        "description": "Stage all changes (git add -A)",
                        "default": False,
                    },
                },
            },
            handler=self._handle_git_stage,
        )

        self._register_tool(
            name="git_commit",
            description="""Commit staged changes.

Use this when the user says:
- "commit this" / "commit with message X" / "save changes to git"
- "make a commit" / "commit changes"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "message": {
                        "type": "string",
                        "description": "Commit message (required)",
                    }
                },
                "required": ["message"],
            },
            handler=self._handle_git_commit,
        )

        self._register_tool(
            name="git_blame",
            description="""Show who last modified a line.

Use this when the user says:
- "who wrote this?" / "blame" / "git blame"
- "who changed this line?" / "author of this code"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "line": {
                        "type": "integer",
                        "description": "Line number (current line if not specified)",
                    }
                },
            },
            handler=self._handle_git_blame,
        )

        self._register_tool(
            name="git_log",
            description="""Show commit history.

Use this when the user says:
- "show commits" / "git log" / "commit history"
- "recent changes" / "what was committed?"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "count": {
                        "type": "integer",
                        "description": "Number of commits to show",
                        "default": 10,
                    },
                    "path": {
                        "type": "string",
                        "description": "Filter to commits affecting this path",
                    },
                },
            },
            handler=self._handle_git_log,
        )

        # =====================================================================
        # Navigation
        # =====================================================================

        self._register_tool(
            name="goto_line",
            description="""Jump to a specific line number.

Use this when the user says:
- "go to line X" / "jump to line X" / "line X"
- "take me to line X"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "line": {"type": "integer", "description": "Line number (1-indexed)"},
                    "path": {
                        "type": "string",
                        "description": "Target file path (uses current editor buffer if not specified)",
                    },
                },
                "required": ["line"],
            },
            handler=self._handle_goto_line,
        )

        self._register_tool(
            name="goto_matching",
            description="""Jump to matching bracket/parenthesis/brace.

Use this when the user says:
- "go to matching bracket" / "jump to pair" / "matching paren"
- "find the closing bracket"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Target file path (uses current editor buffer if not specified)",
                    },
                },
            },
            handler=self._handle_goto_matching,
        )

        self._register_tool(
            name="next_error",
            description="""Jump to the next diagnostic error/warning.

Use this when the user says:
- "next error" / "go to next problem" / "next issue"
- "jump to next warning"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "severity": {
                        "type": "string",
                        "description": "Filter by severity: error, warning, info, hint",
                    },
                    "path": {
                        "type": "string",
                        "description": "Target file path (uses current editor buffer if not specified)",
                    },
                },
            },
            handler=self._handle_next_error,
        )

        self._register_tool(
            name="prev_error",
            description="""Jump to the previous diagnostic error/warning.

Use this when the user says:
- "previous error" / "go to previous problem" / "last error"
- "jump to previous warning"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "severity": {
                        "type": "string",
                        "description": "Filter by severity: error, warning, info, hint",
                    },
                    "path": {
                        "type": "string",
                        "description": "Target file path (uses current editor buffer if not specified)",
                    },
                },
            },
            handler=self._handle_prev_error,
        )

        self._register_tool(
            name="jump_back",
            description="""Jump back in the jump list (like browser back).

Use this when the user says:
- "go back" / "previous location" / "jump back"
- "where was I before?"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "count": {
                        "type": "integer",
                        "description": "Number of jumps back",
                        "default": 1,
                    }
                },
            },
            handler=self._handle_jump_back,
        )

        self._register_tool(
            name="jump_forward",
            description="""Jump forward in the jump list (like browser forward).

Use this when the user says:
- "go forward" / "next location" / "jump forward"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "count": {
                        "type": "integer",
                        "description": "Number of jumps forward",
                        "default": 1,
                    }
                },
            },
            handler=self._handle_jump_forward,
        )

        # =====================================================================
        # Undo/Redo
        # =====================================================================

        self._register_tool(
            name="undo",
            description="""Undo the last change.

Use this when the user says:
- "undo" / "undo that" / "go back"
- "reverse that" / "ctrl+z"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "count": {
                        "type": "integer",
                        "description": "Number of changes to undo",
                        "default": 1,
                    },
                    "path": {
                        "type": "string",
                        "description": "Target file path (uses current editor buffer if not specified)",
                    },
                },
            },
            handler=self._handle_undo,
        )

        self._register_tool(
            name="redo",
            description="""Redo a previously undone change.

Use this when the user says:
- "redo" / "redo that" / "bring it back"
- "ctrl+y"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "count": {
                        "type": "integer",
                        "description": "Number of changes to redo",
                        "default": 1,
                    },
                    "path": {
                        "type": "string",
                        "description": "Target file path (uses current editor buffer if not specified)",
                    },
                },
            },
            handler=self._handle_redo,
        )

        # =====================================================================
        # LSP Advanced
        # =====================================================================

        self._register_tool(
            name="get_references",
            description="""Find all references to the symbol under cursor.

Use this when the user says:
- "find references" / "where is this used?" / "show usages"
- "who uses this?" / "find all occurrences"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_get_references,
        )

        self._register_tool(
            name="rename_symbol",
            description="""Rename a symbol across all files using LSP.

Use this when the user says:
- "rename X to Y" / "refactor name" / "change name"
- "rename this symbol"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "new_name": {"type": "string", "description": "New name for the symbol"}
                },
                "required": ["new_name"],
            },
            handler=self._handle_rename_symbol,
        )

        self._register_tool(
            name="code_actions",
            description="""Get available code actions (quick fixes) at cursor.

Use this when the user says:
- "fix this" / "quick fix" / "code actions"
- "what can I do here?" / "auto-fix"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "apply_first": {
                        "type": "boolean",
                        "description": "Automatically apply the first action",
                        "default": False,
                    }
                },
            },
            handler=self._handle_code_actions,
        )

        self._register_tool(
            name="list_symbols",
            description="""List all symbols (functions, classes, etc.) in current file.

Use this when the user says:
- "show functions" / "list symbols" / "outline"
- "what functions are in this file?" / "document symbols"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_list_symbols,
        )

        self._register_tool(
            name="goto_symbol",
            description="""Go to a symbol by name in the current file.

Use this when the user says:
- "go to function X" / "jump to class X" / "find method X"
- "take me to the X function"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Symbol name to find"},
                    "kind": {
                        "type": "string",
                        "description": "Symbol kind filter (function, class, method, etc.)",
                    },
                },
                "required": ["name"],
            },
            handler=self._handle_goto_symbol,
        )

        # =====================================================================
        # Folding
        # =====================================================================

        self._register_tool(
            name="fold",
            description="""Fold code at cursor or specified line.

Use this when the user says:
- "fold this" / "collapse this" / "hide this block"
- "fold all" / "collapse everything"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "line": {
                        "type": "integer",
                        "description": "Line to fold (cursor if not specified)",
                    },
                    "all": {
                        "type": "boolean",
                        "description": "Fold all foldable regions",
                        "default": False,
                    },
                },
            },
            handler=self._handle_fold,
        )

        self._register_tool(
            name="unfold",
            description="""Unfold code at cursor or specified line.

Use this when the user says:
- "unfold this" / "expand this" / "show this block"
- "unfold all" / "expand everything"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "line": {
                        "type": "integer",
                        "description": "Line to unfold (cursor if not specified)",
                    },
                    "all": {
                        "type": "boolean",
                        "description": "Unfold all regions",
                        "default": False,
                    },
                },
            },
            handler=self._handle_unfold,
        )

        # =====================================================================
        # Bookmarks
        # =====================================================================

        self._register_tool(
            name="bookmark",
            description="""Create a named bookmark at current position.

Use this when the user says:
- "bookmark this" / "mark this spot" / "save this location"
- "create bookmark X"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Name for the bookmark"},
                    "description": {"type": "string", "description": "Optional description"},
                },
                "required": ["name"],
            },
            handler=self._handle_bookmark,
        )

        self._register_tool(
            name="goto_bookmark",
            description="""Jump to a named bookmark.

Use this when the user says:
- "go to bookmark X" / "jump to X" / "open bookmark X"
""",
            input_schema={
                "type": "object",
                "properties": {"name": {"type": "string", "description": "Bookmark name"}},
                "required": ["name"],
            },
            handler=self._handle_goto_bookmark,
        )

        self._register_tool(
            name="list_bookmarks",
            description="""List all bookmarks.

Use this when the user says:
- "show bookmarks" / "list bookmarks" / "my bookmarks"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_list_bookmarks,
        )

        self._register_tool(
            name="delete_bookmark",
            description="""Delete a bookmark.

Use this when the user says:
- "delete bookmark X" / "remove bookmark X"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Bookmark name to delete"}
                },
                "required": ["name"],
            },
            handler=self._handle_delete_bookmark,
        )

        # =====================================================================
        # Line Operations
        # =====================================================================

        self._register_tool(
            name="comment",
            description="""Toggle comment on current line or selection.

Use this when the user says:
- "comment this" / "toggle comment" / "comment out"
- "uncomment this" / "remove comment"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "start_line": {
                        "type": "integer",
                        "description": "Start line (current if not specified)",
                    },
                    "end_line": {
                        "type": "integer",
                        "description": "End line (same as start if not specified)",
                    },
                },
            },
            handler=self._handle_comment,
        )

        self._register_tool(
            name="duplicate_line",
            description="""Duplicate the current line.

Use this when the user says:
- "duplicate this line" / "copy line down" / "dup line"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "line": {
                        "type": "integer",
                        "description": "Line to duplicate (current if not specified)",
                    },
                    "count": {"type": "integer", "description": "Number of copies", "default": 1},
                },
            },
            handler=self._handle_duplicate_line,
        )

        self._register_tool(
            name="move_line",
            description="""Move the current line up or down.

Use this when the user says:
- "move line up" / "move line down" / "move this up"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "direction": {
                        "type": "string",
                        "enum": ["up", "down"],
                        "description": "Direction to move",
                    },
                    "start_line": {
                        "type": "integer",
                        "description": "Start line (current if not specified)",
                    },
                    "end_line": {"type": "integer", "description": "End line for range move"},
                },
                "required": ["direction"],
            },
            handler=self._handle_move_line,
        )

        self._register_tool(
            name="delete_line",
            description="""Delete the current line or a range of lines.

Use this when the user says:
- "delete this line" / "remove line" / "kill line"
- "delete lines X to Y"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "start_line": {
                        "type": "integer",
                        "description": "Start line (current if not specified)",
                    },
                    "end_line": {
                        "type": "integer",
                        "description": "End line (same as start if not specified)",
                    },
                },
            },
            handler=self._handle_delete_line,
        )

        self._register_tool(
            name="join_lines",
            description="""Join the current line with the next line.

Use this when the user says:
- "join lines" / "merge lines" / "combine lines"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "count": {
                        "type": "integer",
                        "description": "Number of lines to join",
                        "default": 2,
                    }
                },
            },
            handler=self._handle_join_lines,
        )

        # =====================================================================
        # Selection Helpers
        # =====================================================================

        self._register_tool(
            name="select_word",
            description="""Select the word under cursor.

Use this when the user says:
- "select this word" / "select word" / "highlight word"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_select_word,
        )

        self._register_tool(
            name="select_line",
            description="""Select entire line(s).

Use this when the user says:
- "select this line" / "select line" / "highlight line"
- "select lines X to Y"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "start_line": {
                        "type": "integer",
                        "description": "Start line (current if not specified)",
                    },
                    "end_line": {
                        "type": "integer",
                        "description": "End line (same as start if not specified)",
                    },
                },
            },
            handler=self._handle_select_line,
        )

        self._register_tool(
            name="select_block",
            description="""Select a code block (inside braces, parentheses, etc.).

Use this when the user says:
- "select this block" / "select inside braces" / "select function body"
- "select inside parentheses"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "type": {
                        "type": "string",
                        "description": "Block type: braces, brackets, parens, quotes",
                        "default": "braces",
                    },
                    "around": {
                        "type": "boolean",
                        "description": "Include the delimiters",
                        "default": False,
                    },
                },
            },
            handler=self._handle_select_block,
        )

        self._register_tool(
            name="select_all",
            description="""Select all content in the buffer.

Use this when the user says:
- "select all" / "select everything" / "highlight all"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_select_all,
        )

        # =====================================================================
        # Indentation
        # =====================================================================

        self._register_tool(
            name="indent",
            description="""Increase indentation of line(s).

Use this when the user says:
- "indent this" / "add indent" / "tab in"
- "indent lines X to Y"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "start_line": {
                        "type": "integer",
                        "description": "Start line (current if not specified)",
                    },
                    "end_line": {
                        "type": "integer",
                        "description": "End line (same as start if not specified)",
                    },
                    "count": {"type": "integer", "description": "Indent levels", "default": 1},
                },
            },
            handler=self._handle_indent,
        )

        self._register_tool(
            name="dedent",
            description="""Decrease indentation of line(s).

Use this when the user says:
- "dedent this" / "remove indent" / "tab out"
- "unindent" / "shift left"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "start_line": {
                        "type": "integer",
                        "description": "Start line (current if not specified)",
                    },
                    "end_line": {
                        "type": "integer",
                        "description": "End line (same as start if not specified)",
                    },
                    "count": {"type": "integer", "description": "Dedent levels", "default": 1},
                },
            },
            handler=self._handle_dedent,
        )

        # =====================================================================
        # Terminal
        # =====================================================================

        self._register_tool(
            name="open_terminal",
            description="""Open a terminal in Neovim.

Use this when the user says:
- "open terminal" / "new terminal" / "shell"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "split": {
                        "type": "string",
                        "enum": ["horizontal", "vertical", "tab"],
                        "description": "How to open the terminal",
                        "default": "horizontal",
                    }
                },
            },
            handler=self._handle_open_terminal,
        )

        # =====================================================================
        # Vim Command Execution
        # =====================================================================

        self._register_tool(
            name="run_command",
            description="""Execute a Neovim ex command directly.

Use this when the user says:
- "run vim command X" / "execute :X" / "do :X"
- Or for advanced operations not covered by other tools
""",
            input_schema={
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "The ex command to execute"}
                },
                "required": ["command"],
            },
            handler=self._handle_run_command,
        )

        # =====================================================================
        # Notifications
        # =====================================================================

        self._register_tool(
            name="notify",
            description="""Show a notification to the user in Neovim.

Use this when the user says:
- "tell me X" / "notify me" / "show message"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "message": {"type": "string", "description": "Message to display"},
                    "level": {
                        "type": "string",
                        "enum": ["info", "warn", "error"],
                        "description": "Notification level",
                        "default": "info",
                    },
                },
                "required": ["message"],
            },
            handler=self._handle_notify,
        )

        # =====================================================================
        # Diff Preview
        # =====================================================================

        self._register_tool(
            name="diff_preview",
            description="""Show a diff preview of proposed changes.

Use this when the user says:
- "show me the diff" / "preview changes" / "what will change?"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Path to file"},
                    "new_content": {"type": "string", "description": "Proposed new content"},
                },
                "required": ["path", "new_content"],
            },
            handler=self._handle_diff_preview,
        )

        # =====================================================================
        # Configuration
        # =====================================================================

        self._register_tool(
            name="get_config",
            description="""Get the current Prism configuration.

Use this when the user says:
- "show config" / "what are the settings?" / "current config"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_get_config,
        )

        self._register_tool(
            name="set_config",
            description="""Update Prism configuration.

Use this when the user says:
- "turn on auto-save" / "enable narrated mode" / "change config"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "auto_save": {
                        "type": "boolean",
                        "description": "Auto-save after edits",
                    },
                    "keep_focus": {
                        "type": "boolean",
                        "description": "Return focus to terminal after opening files",
                    },
                    "narrated": {
                        "type": "boolean",
                        "description": "Show vim commands as they execute (learning mode)",
                    },
                },
            },
            handler=self._handle_set_config,
        )

        # =====================================================================
        # Learning/Help Tools
        # =====================================================================

        self._register_tool(
            name="explain_command",
            description="""Explain what a vim command does.

Use this when the user says:
- "what does X do?" / "explain vim command X" / "what is X?"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "Vim command to explain"}
                },
                "required": ["command"],
            },
            handler=self._handle_explain_command,
        )

        self._register_tool(
            name="suggest_command",
            description="""Suggest vim commands for a task.

Use this when the user says:
- "how do I X in vim?" / "vim way to X" / "what command does X?"
""",
            input_schema={
                "type": "object",
                "properties": {"task": {"type": "string", "description": "Task to accomplish"}},
                "required": ["task"],
            },
            handler=self._handle_suggest_command,
        )

        self._register_tool(
            name="vim_cheatsheet",
            description="""Show vim command cheatsheet.

Use this when the user says:
- "vim cheatsheet" / "show vim commands" / "vim help"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "category": {
                        "type": "string",
                        "description": "Category: movement, editing, search, etc.",
                    }
                },
            },
            handler=self._handle_vim_cheatsheet,
        )

        # =====================================================================
        # Trust Mode (Editing Style)
        # =====================================================================

        self._register_tool(
            name="set_trust_mode",
            description="""Set the editing trust level.

Modes:
- guardian: User reviews every edit before applying (safest)
- companion: Edits auto-apply with visual overlay, easy undo (recommended)
- autopilot: Edits auto-apply with minimal UI (fastest)

Use this when the user says:
- "be more careful" / "slow down" / "I want to review" -> guardian
- "that's fine" / "I trust you" -> companion
- "just do it" / "full speed" / "autopilot" -> autopilot
""",
            input_schema={
                "type": "object",
                "properties": {
                    "mode": {
                        "type": "string",
                        "enum": ["guardian", "companion", "autopilot"],
                        "description": "Trust level for edits",
                    }
                },
                "required": ["mode"],
            },
            handler=self._handle_set_trust_mode,
        )

        # =====================================================================
        # Harpoon (Quick File Switching)
        # =====================================================================

        self._register_tool(
            name="harpoon_add",
            description="""Add current file to harpoon quick list.

Use this when the user says:
- "mark this file" / "add to harpoon" / "pin this"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_harpoon_add,
        )

        self._register_tool(
            name="harpoon_list",
            description="""Show harpoon file list.

Use this when the user says:
- "show harpoon" / "pinned files" / "harpoon list"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_harpoon_list,
        )

        self._register_tool(
            name="harpoon_goto",
            description="""Jump to file by harpoon index.

Use this when the user says:
- "go to harpoon 1" / "jump to file 2" / "harpoon 3"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "index": {"type": "integer", "description": "Index in harpoon list (1-indexed)"}
                },
                "required": ["index"],
            },
            handler=self._handle_harpoon_goto,
        )

        self._register_tool(
            name="harpoon_remove",
            description="""Remove current file from harpoon.

Use this when the user says:
- "unpin this" / "remove from harpoon"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_harpoon_remove,
        )

        # =====================================================================
        # Trouble & Todos
        # =====================================================================

        self._register_tool(
            name="trouble_toggle",
            description="""Toggle Trouble panel for diagnostics/todos.

Use this when the user says:
- "show trouble" / "diagnostics panel" / "all errors"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "mode": {
                        "type": "string",
                        "enum": ["diagnostics", "todo", "quickfix", "loclist"],
                        "description": "Trouble mode",
                        "default": "diagnostics",
                    }
                },
            },
            handler=self._handle_trouble_toggle,
        )

        self._register_tool(
            name="search_todos",
            description="""Search for TODO/FIXME/HACK comments.

Use this when the user says:
- "show todos" / "find todos" / "list TODOs"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "keywords": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Keywords to search for (default: TODO, FIXME, HACK)",
                    }
                },
            },
            handler=self._handle_search_todos,
        )

        self._register_tool(
            name="next_todo",
            description="""Jump to next TODO comment.

Use this when the user says:
- "next todo" / "go to next TODO"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_next_todo,
        )

        self._register_tool(
            name="prev_todo",
            description="""Jump to previous TODO comment.

Use this when the user says:
- "previous todo"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_prev_todo,
        )

        # =====================================================================
        # Spectre (Project Search/Replace)
        # =====================================================================

        self._register_tool(
            name="spectre_open",
            description="""Open Spectre for project-wide search/replace.

Use this when the user says:
- "search and replace in project" / "bulk replace"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "search": {"type": "string", "description": "Initial search pattern"},
                    "replace": {"type": "string", "description": "Initial replacement"},
                },
            },
            handler=self._handle_spectre_open,
        )

        self._register_tool(
            name="spectre_word",
            description="""Open Spectre with word under cursor.

Use this when the user says:
- "replace this word everywhere"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_spectre_word,
        )

    def _register_tool(self, name: str, description: str, input_schema: dict, handler: Callable):
        """Register a tool with the server."""
        self.tools[name] = ToolDef(
            name=name, description=description, input_schema=input_schema, handler=handler
        )

    def get_mcp_tools(self) -> list[MCPTool]:
        """Return tools in MCP SDK format."""
        return [
            MCPTool(name=t.name, description=t.description, inputSchema=t.input_schema)
            for t in self.tools.values()
        ]

    def call_tool(self, name: str, arguments: dict) -> str:
        """Call a tool and return formatted result."""
        if name not in self.tools:
            return f"Unknown tool: {name}"

        tool = self.tools[name]
        try:
            result = tool.handler(**arguments)
            return self._format_result(name, result)
        except Exception as e:
            logger.error(f"Tool error: {e}")
            import traceback

            logger.error(traceback.format_exc())
            return f"Error: {e}"

    # =========================================================================
    # Tool Handlers
    # =========================================================================

    def _handle_open_file(
        self, path: str, line: int = None, column: int = None, keep_focus: bool = True
    ) -> dict:
        """Open a file in the editor."""
        try:
            # Resolve absolute path
            if not os.path.isabs(path):
                cwd = self.nvim.func("getcwd")
                path = os.path.join(cwd, path)

            # Use nvim_client's open_file which finds editor window first
            self.nvim.open_file(path, keep_focus=keep_focus)

            # Jump to line/column if specified
            if line:
                # Need to switch to editor window for cursor positioning
                editor_win = self.nvim._find_editor_window()
                if editor_win:
                    current_win = self.nvim.call("nvim_get_current_win")
                    self.nvim.call("nvim_set_current_win", editor_win)
                    self.nvim.func("cursor", line, column or 1)
                    if keep_focus:
                        self.nvim.call("nvim_set_current_win", current_win)

            self._narrate(f"Open file (:e {path})")
            return {"success": True, "path": path}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_save_file(self, path: str = None) -> dict:
        """Save the current buffer."""
        try:
            if path:
                self.nvim.command(f"write {path}")
            else:
                self.nvim.command("write")
            self._narrate("Save file (:w)")
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_close_file(self, path: str = None, force: bool = False) -> dict:
        """Close a buffer."""
        try:
            cmd = "bdelete!" if force else "bdelete"
            if path:
                # Find buffer by path
                bufs = self.nvim.func("getbufinfo", {"buflisted": 1})
                for buf in bufs:
                    if _path_matches(buf.get("name", ""), path):
                        self.nvim.command(f"{cmd} {buf['bufnr']}")
                        return {"success": True}
                return {"success": False, "error": f"Buffer not found: {path}"}
            else:
                self.nvim.command(cmd)
            self._narrate(f"Close buffer (:{cmd})")
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_create_file(self, path: str, content: str = "") -> dict:
        """Create a new file."""
        try:
            # Create parent directories if needed
            parent = os.path.dirname(path)
            if parent and not os.path.exists(parent):
                os.makedirs(parent)

            # Write content
            with open(path, "w") as f:
                f.write(content)

            # Open in editor
            self.nvim.command(f"edit {path}")
            self._narrate(f"Create file: {path}")
            return {"success": True, "path": path}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_get_buffer_content(self, path: str = None) -> dict:
        """Get buffer content."""
        try:
            buf = self._get_buffer(path)
            lines = self.nvim.call("nvim_buf_get_lines", buf, 0, -1, False)
            return {"content": "\n".join(lines)}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_get_buffer_lines(
        self, path: str = None, start_line: int = 1, end_line: int = -1
    ) -> dict:
        """Get specific lines from buffer."""
        try:
            buf = self._get_buffer(path)
            # Convert to 0-indexed
            start = max(0, start_line - 1)
            end = end_line if end_line == -1 else end_line
            lines = self.nvim.call("nvim_buf_get_lines", buf, start, end, False)
            return {"lines": lines, "start_line": start_line}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_set_buffer_content(
        self, content: str, path: str = None, auto_save: bool = False
    ) -> dict:
        """Set buffer content."""
        try:
            buf = self._get_buffer(path)
            lines = content.split("\n")
            self.nvim.call("nvim_buf_set_lines", buf, 0, -1, False, lines)

            if auto_save or self.config.get("auto_save", False):
                self.nvim.command("write")
                return {"success": True, "lines_changed": len(lines), "saved": True}

            return {"success": True, "lines_changed": len(lines)}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_edit_buffer(
        self,
        start_line: int,
        end_line: int,
        new_lines: list,
        path: str = None,
        auto_save: bool = False,
    ) -> dict:
        """Edit specific lines in buffer."""
        try:
            buf = self._get_buffer(path)
            # Convert to 0-indexed
            start = max(0, start_line - 1)
            self.nvim.call("nvim_buf_set_lines", buf, start, end_line, False, new_lines)

            if auto_save or self.config.get("auto_save", False):
                self.nvim.command("write")
                return {"success": True, "lines_changed": len(new_lines), "saved": True}

            return {"success": True, "lines_changed": len(new_lines)}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_insert_text(self, line: int, column: int, text: str, path: str = None) -> dict:
        """Insert text at position."""
        try:
            buf = self._get_buffer(path)
            # Get current line content
            lines = self.nvim.call("nvim_buf_get_lines", buf, line - 1, line, False)
            if lines:
                current = lines[0]
                new_content = current[:column] + text + current[column:]
                # Handle newlines in inserted text
                new_lines = new_content.split("\n")
                self.nvim.call("nvim_buf_set_lines", buf, line - 1, line, False, new_lines)
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_get_open_files(self) -> dict:
        """Get list of open files."""
        try:
            bufs = self.nvim.func("getbufinfo", {"buflisted": 1})
            files = []
            for buf in bufs:
                files.append(
                    {
                        "path": buf.get("name", ""),
                        "modified": buf.get("changed", 0) == 1,
                        "bufnr": buf.get("bufnr"),
                    }
                )
            return {"files": files}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_get_current_file(self) -> dict:
        """Get current file info."""
        try:
            path = self.nvim.func("expand", "%:p")
            line, col = self.nvim.func("getpos", ".")[1:3]
            modified = self.nvim.func("getbufvar", "%", "&modified") == 1
            return {
                "path": path,
                "cursor": {"line": line, "column": col},
                "modified": modified,
            }
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_get_cursor_position(self) -> dict:
        """Get cursor position."""
        try:
            pos = self.nvim.func("getpos", ".")
            return {"line": pos[1], "column": pos[2]}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_set_cursor_position(self, line: int, column: int) -> dict:
        """Set cursor position."""
        try:
            self.nvim.func("cursor", line, column)
            self._narrate(f"Move cursor ({line}G{column}|)")
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_get_selection(self) -> dict:
        """Get selected text."""
        try:
            # Get visual selection marks
            start = self.nvim.func("getpos", "'<")
            end = self.nvim.func("getpos", "'>")

            if start[1] == 0 and end[1] == 0:
                return {"text": None}

            # Get lines in selection
            lines = self.nvim.func("getline", start[1], end[1])
            if isinstance(lines, str):
                lines = [lines]

            # Trim to selection columns
            if len(lines) == 1:
                lines[0] = lines[0][start[2] - 1 : end[2]]
            else:
                lines[0] = lines[0][start[2] - 1 :]
                lines[-1] = lines[-1][: end[2]]

            return {"text": "\n".join(lines)}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_split_window(self, vertical: bool = False, path: str = None) -> dict:
        """Create a window split."""
        try:
            cmd = "vsplit" if vertical else "split"
            if path:
                self.nvim.command(f"{cmd} {path}")
            else:
                self.nvim.command(cmd)
            self._narrate(f"Split window (:{cmd})")
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_close_window(self, force: bool = False) -> dict:
        """Close current window."""
        try:
            cmd = "close!" if force else "close"
            self.nvim.command(cmd)
            self._narrate(f"Close window (:{cmd})")
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_get_windows(self) -> dict:
        """Get window information."""
        try:
            wins = self.nvim.func("getwininfo")
            windows = []
            for win in wins:
                buf = self.nvim.call("nvim_win_get_buf", win["winid"])
                path = self.nvim.call("nvim_buf_get_name", buf)
                windows.append(
                    {
                        "id": win["winid"],
                        "path": path,
                        "width": win.get("width", 0),
                        "height": win.get("height", 0),
                    }
                )
            return {"windows": windows}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_get_diagnostics(self, path: str = None) -> dict:
        """Get LSP diagnostics."""
        try:
            buf = self._get_buffer(path)
            # Use Lua to get diagnostics (vim.diagnostic.get is not an RPC method)
            diags = self.nvim.lua(
                """
                local buf = ...
                local diags = vim.diagnostic.get(buf)
                local result = {}
                for _, d in ipairs(diags) do
                    table.insert(result, {
                        lnum = d.lnum,
                        col = d.col,
                        message = d.message,
                        severity = d.severity
                    })
                end
                return result
                """,
                buf,
            )
            result = []
            for d in diags or []:
                severity_map = {1: "error", 2: "warning", 3: "info", 4: "hint"}
                result.append(
                    {
                        "line": d.get("lnum", 0) + 1,
                        "column": d.get("col", 0),
                        "message": d.get("message", ""),
                        "severity": severity_map.get(d.get("severity", 4), "info"),
                    }
                )
            return {"diagnostics": result}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_goto_definition(self) -> dict:
        """Go to definition."""
        try:
            self.nvim.command("lua vim.lsp.buf.definition()")
            self._narrate("Go to definition (gd)")
            # Wait a bit and get new position
            import time

            time.sleep(0.1)
            path = self.nvim.func("expand", "%:p")
            pos = self.nvim.func("getpos", ".")
            return {"success": True, "path": path, "line": pos[1]}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_get_hover_info(self) -> dict:
        """Get hover information."""
        try:
            # Use LSP hover
            self.nvim.command("lua vim.lsp.buf.hover()")
            self._narrate("Show hover info (K)")
            return {"success": True, "info": "Hover window opened"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_format_file(self) -> dict:
        """Format file with LSP."""
        try:
            self.nvim.command("lua vim.lsp.buf.format()")
            self._narrate("Format file (LSP)")
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_search_in_file(self, pattern: str) -> dict:
        """Search for pattern in file."""
        try:
            buf = self.nvim.call("nvim_get_current_buf")
            lines = self.nvim.call("nvim_buf_get_lines", buf, 0, -1, False)

            matches = []
            import re

            for i, line in enumerate(lines):
                for m in re.finditer(pattern, line):
                    matches.append({"line": i + 1, "column": m.start(), "text": m.group()})

            # Highlight first match
            if matches:
                self.nvim.command(f"/{pattern}")
                self._narrate(f"Search (/{pattern})")

            return {"matches": matches, "count": len(matches)}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_search_and_replace(self, pattern: str, replacement: str, flags: str = "g") -> dict:
        """Search and replace in file."""
        try:
            # Escape special characters
            pattern_escaped = pattern.replace("/", "\\/")
            replacement_escaped = replacement.replace("/", "\\/")
            cmd = f"%s/{pattern_escaped}/{replacement_escaped}/{flags}"

            def do_replace():
                self.nvim.command(cmd)

            self._in_editor_window(do_replace)
            self._narrate(f"Replace (:{cmd})")

            # Count replacements (approximate)
            return {"success": True, "replacements": "multiple"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_git_status(self) -> dict:
        """Get git status."""
        try:
            import subprocess

            cwd = self.nvim.func("getcwd")
            result = subprocess.run(
                ["git", "status", "--porcelain"],
                cwd=cwd,
                capture_output=True,
                text=True,
            )
            files = []
            for line in result.stdout.strip().split("\n"):
                if line:
                    status = line[:2].strip()
                    path = line[3:]
                    files.append({"status": status, "path": path})
            return {"files": files, "clean": len(files) == 0}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_git_diff(self, staged: bool = False) -> dict:
        """Get git diff."""
        try:
            import subprocess

            cwd = self.nvim.func("getcwd")
            cmd = ["git", "diff"]
            if staged:
                cmd.append("--staged")
            result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
            return {"diff": result.stdout}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_git_stage(self, path: str = None, all: bool = False) -> dict:
        """Stage files for commit."""
        try:
            import subprocess

            cwd = self.nvim.func("getcwd")
            if all:
                cmd = ["git", "add", "-A"]
            elif path:
                cmd = ["git", "add", path]
            else:
                current = self.nvim.func("expand", "%:p")
                cmd = ["git", "add", current]
            subprocess.run(cmd, cwd=cwd, check=True)
            return {"success": True, "message": "Staged"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_git_commit(self, message: str) -> dict:
        """Commit staged changes."""
        try:
            import subprocess

            cwd = self.nvim.func("getcwd")
            subprocess.run(["git", "commit", "-m", message], cwd=cwd, check=True)
            return {"success": True, "message": message}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_git_blame(self, line: int = None) -> dict:
        """Git blame for a line."""
        try:
            import subprocess

            cwd = self.nvim.func("getcwd")
            path = self.nvim.func("expand", "%:p")
            if line is None:
                line = self.nvim.func("line", ".")
            result = subprocess.run(
                ["git", "blame", "-L", f"{line},{line}", path],
                cwd=cwd,
                capture_output=True,
                text=True,
            )
            return {"success": True, "line": line, "blame": result.stdout.strip()}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_git_log(self, count: int = 10, path: str = None) -> dict:
        """Show git log."""
        try:
            import subprocess

            cwd = self.nvim.func("getcwd")
            cmd = ["git", "log", f"-{count}", "--oneline"]
            if path:
                cmd.extend(["--", path])
            result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
            commits = result.stdout.strip().split("\n")
            return {"success": True, "commits": commits}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_goto_line(self, line: int, path: str = None) -> dict:
        """Go to a specific line."""
        try:
            self._in_editor_window(lambda: self.nvim.func("cursor", line, 1), path)
            self._narrate(f"Go to line ({line}G)")
            return {"success": True, "line": line, "path": path}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_goto_matching(self, path: str = None) -> dict:
        """Go to matching bracket."""
        try:

            def do_match():
                start_pos = self.nvim.func("getpos", ".")
                self.nvim.command("normal! %")
                end_pos = self.nvim.func("getpos", ".")
                return start_pos, end_pos

            start_pos, end_pos = self._in_editor_window(do_match, path)
            self._narrate("Go to matching (%)")
            return {
                "success": True,
                "from": {"line": start_pos[1], "column": start_pos[2]},
                "to": {"line": end_pos[1], "column": end_pos[2]},
            }
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_next_error(self, severity: str = None, path: str = None) -> dict:
        """Jump to next diagnostic."""
        try:

            def do_next():
                self.nvim.command("lua vim.diagnostic.goto_next()")
                return self.nvim.func("getpos", ".")

            pos = self._in_editor_window(do_next, path)
            self._narrate("Next diagnostic (]d)")
            return {"success": True, "line": pos[1], "severity": severity or "any"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_prev_error(self, severity: str = None, path: str = None) -> dict:
        """Jump to previous diagnostic."""
        try:

            def do_prev():
                self.nvim.command("lua vim.diagnostic.goto_prev()")
                return self.nvim.func("getpos", ".")

            pos = self._in_editor_window(do_prev, path)
            self._narrate("Previous diagnostic ([d)")
            return {"success": True, "line": pos[1], "severity": severity or "any"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_jump_back(self, count: int = 1) -> dict:
        """Jump back in jump list."""
        try:

            def do_jump():
                self.nvim.command(f"normal! {count}\x0f")  # Ctrl-O
                path = self.nvim.func("expand", "%:p")
                pos = self.nvim.func("getpos", ".")
                return path, pos

            path, pos = self._in_editor_window(do_jump)
            self._narrate(f"Jump back ({count}<C-o>)")
            return {"success": True, "path": path, "line": pos[1], "vim_cmd": "<C-o>"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_jump_forward(self, count: int = 1) -> dict:
        """Jump forward in jump list."""
        try:

            def do_jump():
                self.nvim.command(f"normal! {count}\x09")  # Ctrl-I
                path = self.nvim.func("expand", "%:p")
                pos = self.nvim.func("getpos", ".")
                return path, pos

            path, pos = self._in_editor_window(do_jump)
            self._narrate(f"Jump forward ({count}<C-i>)")
            return {"success": True, "path": path, "line": pos[1], "vim_cmd": "<C-i>"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_undo(self, count: int = 1, path: str = None) -> dict:
        """Undo changes."""
        try:

            def do_undo():
                for _ in range(count):
                    self.nvim.command("undo")

            self._in_editor_window(do_undo, path)
            self._narrate(f"Undo ({count}u)")
            return {"success": True, "count": count, "vim_cmd": "u"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_redo(self, count: int = 1, path: str = None) -> dict:
        """Redo changes."""
        try:

            def do_redo():
                for _ in range(count):
                    self.nvim.command("redo")

            self._in_editor_window(do_redo, path)
            self._narrate(f"Redo ({count}<C-r>)")
            return {"success": True, "count": count}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_get_references(self) -> dict:
        """Find references."""
        try:
            self.nvim.command("lua vim.lsp.buf.references()")
            self._narrate("Find references (gr)")
            return {"success": True, "message": "References shown in quickfix"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_rename_symbol(self, new_name: str) -> dict:
        """Rename symbol."""
        try:
            self.nvim.command(f"lua vim.lsp.buf.rename('{new_name}')")
            self._narrate(f"Rename symbol to {new_name}")
            return {"success": True, "new_name": new_name}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_code_actions(self, apply_first: bool = False) -> dict:
        """Get code actions."""
        try:
            if apply_first:
                self.nvim.command("lua vim.lsp.buf.code_action()")
            else:
                self.nvim.command("lua vim.lsp.buf.code_action()")
            self._narrate("Code actions (ga)")
            return {"success": True, "message": "Code actions shown"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_list_symbols(self) -> dict:
        """List document symbols."""
        try:
            self.nvim.command("lua vim.lsp.buf.document_symbol()")
            return {"success": True, "symbols": []}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_goto_symbol(self, name: str, kind: str = None) -> dict:
        """Go to a symbol by name."""
        try:
            # Search for the symbol
            self.nvim.command(f"/{name}")
            self.nvim.command("normal! n")
            pos = self.nvim.func("getpos", ".")
            return {"success": True, "symbol": name, "kind": kind or "symbol", "line": pos[1]}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_fold(self, line: int = None, all: bool = False) -> dict:
        """Fold code."""
        try:
            if all:
                self.nvim.command("normal! zM")
                self._narrate("Fold all (zM)")
                return {"success": True, "message": "All folded", "vim_cmd": "zM"}
            if line:
                self.nvim.func("cursor", line, 1)
            self.nvim.command("normal! zc")
            self._narrate("Fold (zc)")
            return {"success": True, "vim_cmd": "zc"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_unfold(self, line: int = None, all: bool = False) -> dict:
        """Unfold code."""
        try:
            if all:
                self.nvim.command("normal! zR")
                self._narrate("Unfold all (zR)")
                return {"success": True, "message": "All unfolded", "vim_cmd": "zR"}
            if line:
                self.nvim.func("cursor", line, 1)
            self.nvim.command("normal! zo")
            self._narrate("Unfold (zo)")
            return {"success": True, "vim_cmd": "zo"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_bookmark(self, name: str, description: str = None) -> dict:
        """Create a bookmark."""
        try:
            path = self.nvim.func("expand", "%:p")
            pos = self.nvim.func("getpos", ".")
            self.bookmarks[name] = {
                "path": path,
                "line": pos[1],
                "column": pos[2],
                "description": description,
            }
            return {"success": True, "name": name, "line": pos[1]}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_goto_bookmark(self, name: str) -> dict:
        """Go to a bookmark."""
        try:
            if name not in self.bookmarks:
                return {"success": False, "error": f"Bookmark not found: {name}"}
            bm = self.bookmarks[name]
            self.nvim.command(f"edit {bm['path']}")
            self.nvim.func("cursor", bm["line"], bm["column"])
            return {"success": True, "name": name, "path": bm["path"], "line": bm["line"]}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_list_bookmarks(self) -> dict:
        """List all bookmarks."""
        return {"bookmarks": self.bookmarks}

    def _handle_delete_bookmark(self, name: str) -> dict:
        """Delete a bookmark."""
        if name in self.bookmarks:
            del self.bookmarks[name]
            return {"success": True, "name": name}
        return {"success": False, "error": f"Bookmark not found: {name}"}

    def _handle_comment(self, start_line: int = None, end_line: int = None) -> dict:
        """Toggle comment."""
        try:
            if start_line and end_line:
                self.nvim.command(f"{start_line},{end_line}Commentary")
                lines = end_line - start_line + 1
            else:
                self.nvim.command("Commentary")
                lines = 1
            self._narrate("Toggle comment (gcc)")
            return {"success": True, "lines": lines, "vim_cmd": "gcc"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_duplicate_line(self, line: int = None, count: int = 1) -> dict:
        """Duplicate a line."""
        try:
            if line:
                self.nvim.func("cursor", line, 1)
            for _ in range(count):
                self.nvim.command("normal! yyp")
            self._narrate(f"Duplicate line (yyp x{count})")
            return {"success": True, "copies": count, "vim_cmd": "yyp"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_move_line(
        self, direction: str, start_line: int = None, end_line: int = None
    ) -> dict:
        """Move line(s) up or down."""
        try:
            if direction == "up":
                self.nvim.command("move -2")
                vim_cmd = ":move -2"
            else:
                self.nvim.command("move +1")
                vim_cmd = ":move +1"
            self._narrate(f"Move line {direction} ({vim_cmd})")
            return {"success": True, "direction": direction, "vim_cmd": vim_cmd}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_delete_line(self, start_line: int = None, end_line: int = None) -> dict:
        """Delete line(s)."""
        try:
            if start_line and end_line:
                self.nvim.command(f"{start_line},{end_line}delete")
                deleted = end_line - start_line + 1
            else:
                self.nvim.command("delete")
                deleted = 1
            self._narrate("Delete line (dd)")
            return {"success": True, "deleted": deleted, "vim_cmd": "dd"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_join_lines(self, count: int = 2) -> dict:
        """Join lines."""
        try:
            self.nvim.command(f"normal! {count - 1}J")
            self._narrate(f"Join {count} lines (J)")
            return {"success": True, "joined": count, "vim_cmd": "J"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_select_word(self) -> dict:
        """Select word under cursor."""
        try:
            self.nvim.command("normal! viw")
            word = self.nvim.func("expand", "<cword>")
            return {"success": True, "word": word}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_select_line(self, start_line: int = None, end_line: int = None) -> dict:
        """Select line(s)."""
        try:
            if start_line and end_line:
                self.nvim.func("cursor", start_line, 1)
                self.nvim.command(f"normal! V{end_line - start_line}j")
                lines = end_line - start_line + 1
            else:
                self.nvim.command("normal! V")
                lines = 1
            return {"success": True, "lines": lines}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_select_block(self, type: str = "braces", around: bool = False) -> dict:
        """Select a code block."""
        try:
            char_map = {"braces": "B", "brackets": "[", "parens": "b", "quotes": '"'}
            char = char_map.get(type, "B")
            prefix = "a" if around else "i"
            self.nvim.command(f"normal! v{prefix}{char}")
            self._narrate(f"Select {type} (v{prefix}{char})")
            return {"success": True, "type": type, "vim_cmd": f"v{prefix}{char}"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_select_all(self) -> dict:
        """Select all content."""
        try:
            self.nvim.command("normal! ggVG")
            line_count = self.nvim.func("line", "$")
            self._narrate("Select all (ggVG)")
            return {"success": True, "lines": line_count}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_indent(self, start_line: int = None, end_line: int = None, count: int = 1) -> dict:
        """Increase indentation."""
        try:
            if start_line and end_line:
                for _ in range(count):
                    self.nvim.command(f"{start_line},{end_line}>")
                lines = end_line - start_line + 1
            else:
                for _ in range(count):
                    self.nvim.command("normal! >>")
                lines = 1
            self._narrate("Indent (>>)")
            return {"success": True, "lines": lines}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_dedent(self, start_line: int = None, end_line: int = None, count: int = 1) -> dict:
        """Decrease indentation."""
        try:
            if start_line and end_line:
                for _ in range(count):
                    self.nvim.command(f"{start_line},{end_line}<")
                lines = end_line - start_line + 1
            else:
                for _ in range(count):
                    self.nvim.command("normal! <<")
                lines = 1
            self._narrate("Dedent (<<)")
            return {"success": True, "lines": lines}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_open_terminal(self, split: str = "horizontal") -> dict:
        """Open terminal."""
        try:
            if split == "vertical":
                self.nvim.command("vsplit | terminal")
            elif split == "tab":
                self.nvim.command("tabnew | terminal")
            else:
                self.nvim.command("split | terminal")
            self._narrate(f"Open terminal ({split} split)")
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_run_command(self, command: str) -> dict:
        """Run a vim command."""
        try:
            # Protect terminal window
            win_type = self.nvim.func("win_gettype")
            if win_type == "terminal":
                self.nvim.command("wincmd p")

            self.nvim.command(command)
            self._narrate(f"Run command (:{command})")
            return {"success": True, "protected": win_type == "terminal"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_notify(self, message: str, level: str = "info") -> dict:
        """Show notification."""
        try:
            level_map = {"info": "INFO", "warn": "WARN", "error": "ERROR"}
            vim_level = level_map.get(level, "INFO")
            self.nvim.command(f'lua vim.notify("{message}", vim.log.levels.{vim_level})')
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_diff_preview(self, path: str, new_content: str) -> dict:
        """Show diff preview."""
        try:
            # This is a simplified implementation
            self.nvim.notify(f"Diff preview for {path}", "info")
            return {"success": True, "message": "Diff preview shown"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_get_config(self) -> dict:
        """Get current config."""
        return {"config": self.config}

    def _handle_set_config(
        self, auto_save: bool = None, keep_focus: bool = None, narrated: bool = None
    ) -> dict:
        """Update config."""
        if auto_save is not None:
            self.config["auto_save"] = auto_save
        if keep_focus is not None:
            self.config["keep_focus"] = keep_focus
        if narrated is not None:
            self.config["narrated"] = narrated
        return {"success": True, "config": self.config}

    def _handle_explain_command(self, command: str) -> dict:
        """Explain a vim command."""
        explanations = {
            "dd": "Delete the current line",
            "yy": "Yank (copy) the current line",
            "p": "Paste after cursor",
            "P": "Paste before cursor",
            "u": "Undo last change",
            "w": "Move to next word",
            "b": "Move to previous word",
            "gg": "Go to first line",
            "G": "Go to last line",
            "%": "Go to matching bracket",
            "zc": "Close fold",
            "zo": "Open fold",
            "gcc": "Toggle comment on line",
        }
        explanation = explanations.get(
            command, f"Command '{command}' - use :help {command} for details"
        )
        return {"command": command, "explanation": explanation}

    def _handle_suggest_command(self, task: str) -> dict:
        """Suggest vim commands for a task."""
        suggestions = {
            "delete": [{"command": "dd", "description": "Delete line"}],
            "copy": [{"command": "yy", "description": "Copy line"}],
            "paste": [{"command": "p", "description": "Paste after"}],
            "undo": [{"command": "u", "description": "Undo"}],
            "save": [{"command": ":w", "description": "Write file"}],
            "quit": [{"command": ":q", "description": "Quit"}],
        }
        # Simple keyword matching
        for key, sugg in suggestions.items():
            if key in task.lower():
                return {"task": task, "suggestions": sugg}
        return {"task": task, "suggestions": [{"command": ":help", "description": "Open vim help"}]}

    def _handle_vim_cheatsheet(self, category: str = None) -> dict:
        """Show vim cheatsheet."""
        categories = {
            "movement": {
                "title": "Movement",
                "commands": {
                    "h/j/k/l": "Left/Down/Up/Right",
                    "w/b": "Next/Previous word",
                    "0/$": "Start/End of line",
                    "gg/G": "First/Last line",
                    "%": "Matching bracket",
                },
            },
            "editing": {
                "title": "Editing",
                "commands": {
                    "i/a": "Insert before/after cursor",
                    "o/O": "New line below/above",
                    "dd": "Delete line",
                    "yy": "Yank line",
                    "p/P": "Paste after/before",
                    "u/<C-r>": "Undo/Redo",
                },
            },
        }
        if category and category in categories:
            return {"categories": {category: categories[category]}}
        return {"categories": categories}

    def _handle_set_trust_mode(self, mode: str) -> dict:
        """Set trust mode."""
        valid_modes = ["guardian", "companion", "autopilot"]
        if mode not in valid_modes:
            return {"success": False, "error": f"Invalid mode: {mode}. Use: {valid_modes}"}
        self.config["trust_mode"] = mode
        messages = {
            "guardian": "Guardian mode: I'll ask before making changes",
            "companion": "Companion mode: Changes auto-apply with visual feedback",
            "autopilot": "Autopilot mode: Maximum speed, minimal UI",
        }
        self.nvim.notify(messages[mode], "info")
        return {"success": True, "mode": mode, "message": messages[mode]}

    def _handle_harpoon_add(self) -> dict:
        """Add file to harpoon."""
        try:
            self.nvim.command("lua require('harpoon'):list():add()")
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_harpoon_list(self) -> dict:
        """Show harpoon list."""
        try:
            self.nvim.command(
                "lua require('harpoon').ui:toggle_quick_menu(require('harpoon'):list())"
            )
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_harpoon_goto(self, index: int) -> dict:
        """Go to harpoon item."""
        try:
            self.nvim.command(f"lua require('harpoon'):list():select({index})")
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_harpoon_remove(self) -> dict:
        """Remove from harpoon."""
        try:
            self.nvim.command("lua require('harpoon'):list():remove()")
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_trouble_toggle(self, mode: str = "diagnostics") -> dict:
        """Toggle trouble panel."""
        try:
            self.nvim.command(f"Trouble {mode}")
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_search_todos(self, keywords: list = None) -> dict:
        """Search for TODOs."""
        try:
            self.nvim.command("TodoTelescope")
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_next_todo(self) -> dict:
        """Jump to next TODO."""
        try:
            self.nvim.command("lua require('todo-comments').jump_next()")
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_prev_todo(self) -> dict:
        """Jump to previous TODO."""
        try:
            self.nvim.command("lua require('todo-comments').jump_prev()")
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_spectre_open(self, search: str = None, replace: str = None) -> dict:
        """Open Spectre."""
        try:
            if search:
                self.nvim.command(f"lua require('spectre').open({{search_text = '{search}'}})")
            else:
                self.nvim.command("lua require('spectre').open()")
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_spectre_word(self) -> dict:
        """Open Spectre with current word."""
        try:
            self.nvim.command("lua require('spectre').open_visual({select_word=true})")
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    # =========================================================================
    # Helper Methods
    # =========================================================================

    def _get_buffer(self, path: str = None) -> int:
        """Get buffer number for path (or current buffer)."""
        if path is None:
            return self.nvim.call("nvim_get_current_buf")

        bufs = self.nvim.func("getbufinfo", {"buflisted": 1})
        for buf in bufs:
            if _path_matches(buf.get("name", ""), path):
                return buf["bufnr"]

        # Not found, try to open it
        self.nvim.command(f"edit {path}")
        return self.nvim.call("nvim_get_current_buf")

    def _in_editor_window(self, func, path: str = None):
        """Run a function in the editor window, then return to current window.

        If path is specified, switches to that buffer before executing.
        """
        editor_win = self.nvim._find_editor_window()
        if editor_win:
            current_win = self.nvim.call("nvim_get_current_win")
            self.nvim.call("nvim_set_current_win", editor_win)
            try:
                # Switch to specific buffer if path provided
                if path:
                    bufnr = self._get_buffer(path)
                    self.nvim.call("nvim_set_current_buf", bufnr)
                return func()
            finally:
                self.nvim.call("nvim_set_current_win", current_win)
        else:
            if path:
                bufnr = self._get_buffer(path)
                self.nvim.call("nvim_set_current_buf", bufnr)
            return func()

    def _narrate(self, message: str):
        """Show vim tip if narrated mode is enabled."""
        if self.config.get("narrated", False):
            self.nvim.notify(f"📚 {message}", "info")

    def _format_result(self, tool_name: str, result: dict) -> str:
        """Format tool result as human-readable text."""
        # Check for errors first
        if result.get("success") is False:
            error = result.get("error", "Unknown error")
            return f"Error: {error}"

        # Simple success cases
        if result == {"success": True}:
            return "Done"

        # Handle specific tool outputs
        if tool_name == "run_command":
            if result.get("protected"):
                return "Done (terminal protected)"
            return "Done"

        if tool_name == "save_file":
            return "Saved"

        if tool_name == "open_file":
            path = result.get("path", "")
            name = path.split("/")[-1] if "/" in path else path
            return f"Opened: {name}"

        if tool_name == "create_file":
            path = result.get("path", "")
            return f"Created: {path}"

        if tool_name == "close_file":
            return "Closed"

        if tool_name in ("edit_buffer", "set_buffer_content"):
            parts = []
            if "lines_changed" in result:
                parts.append(f"{result['lines_changed']} lines")
            if result.get("saved"):
                parts.append("saved")
            if parts:
                return f"{', '.join(parts)}"
            return "Updated"

        if tool_name == "get_buffer_content":
            content = result.get("content", "")
            lines = content.count("\n") + 1 if content else 0
            return f"{lines} lines\n\n{content}"

        if tool_name == "get_buffer_lines":
            lines = result.get("lines", [])
            start = result.get("start_line", 1)
            formatted = "\n".join(f"{start + i}: {line}" for i, line in enumerate(lines))
            return formatted if formatted else "(empty)"

        if tool_name == "get_current_file":
            path = result.get("path", "")
            cursor = result.get("cursor", {})
            modified = "*" if result.get("modified") else ""
            return f"{path} {modified}\nLine {cursor.get('line', 1)}, Col {cursor.get('column', 0)}"

        if tool_name == "get_cursor_position":
            return f"Line {result.get('line', 1)}, Col {result.get('column', 0)}"

        if tool_name == "get_open_files":
            files = result.get("files", [])
            if not files:
                return "(no files open)"
            lines = []
            for f in files:
                name = f.get("path", "").split("/")[-1]
                mod = " *" if f.get("modified") else ""
                lines.append(f"  {name}{mod}")
            return "\n".join(lines)

        if tool_name == "get_diagnostics":
            diags = result.get("diagnostics", [])
            if not diags:
                return "No diagnostics"
            lines = []
            for d in diags[:10]:
                severity = d.get("severity", "info")
                msg = d.get("message", "")
                line = d.get("line", 0)
                lines.append(f"  {severity}: L{line} {msg}")
            if len(diags) > 10:
                lines.append(f"  ... and {len(diags) - 10} more")
            return "\n".join(lines)

        if tool_name == "git_status":
            return json.dumps(result, indent=2, cls=BytesEncoder)

        if tool_name == "git_diff":
            diff = result.get("diff", "")
            return diff if diff else "(no changes)"

        # Fallback: return JSON for unknown structures
        return json.dumps(result, indent=2, cls=BytesEncoder)


# Global server instance
_server_instance: Optional[PrismMCPServer] = None
_nvim_connected: bool = False


def get_server() -> PrismMCPServer:
    """Get or create the server instance."""
    global _server_instance
    if _server_instance is None:
        _server_instance = PrismMCPServer()
    return _server_instance


def ensure_nvim_connected():
    """Lazily connect to Neovim on first tool call."""
    global _nvim_connected
    if not _nvim_connected:
        server = get_server()
        server.nvim.connect()
        logger.info("Connected to Neovim (lazy)")
        _nvim_connected = True


# Create MCP server using the SDK
mcp_server = Server("prism-nvim")


@mcp_server.list_tools()
async def list_tools():
    """Return available tools."""
    server = get_server()
    return server.get_mcp_tools()


@mcp_server.call_tool()
async def call_tool(name: str, arguments: dict):
    """Handle tool calls."""
    ensure_nvim_connected()
    server = get_server()
    result = server.call_tool(name, arguments)
    return [TextContent(type="text", text=result)]


def main():
    """Main entry point using MCP SDK."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[logging.FileHandler("/tmp/prism-mcp.log")],
    )

    logger.info("Starting Prism MCP Server (SDK mode)...")

    # Don't connect to Neovim at startup - connect lazily on first tool call
    # This allows the MCP server to start even if Neovim isn't running yet

    async def run():
        init_options = InitializationOptions(
            server_name="prism-nvim",
            server_version="0.1.0",
            capabilities=ServerCapabilities(tools=ToolsCapability()),
        )
        async with stdio_server() as (read_stream, write_stream):
            await mcp_server.run(read_stream, write_stream, init_options)

    asyncio.run(run())


if __name__ == "__main__":
    main()
