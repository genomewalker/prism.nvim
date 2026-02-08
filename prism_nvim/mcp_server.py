"""
Prism MCP Server - Exposes Neovim control to Claude Code

This server implements the Model Context Protocol (MCP) to allow Claude
to fully control a Neovim instance as an IDE.
"""

import asyncio
import json
import logging
import os
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable, Optional

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
                        "description": "Number of commits to show (default: 10)",
                        "default": 10,
                    }
                },
            },
            handler=self._handle_git_log,
        )

        # =====================================================================
        # Symbol Navigation (LSP)
        # =====================================================================

        self._register_tool(
            name="list_symbols",
            description="""List all symbols in the file.

Use this when the user says:
- "show functions" / "what's in this file?" / "document symbols"
- "list classes" / "show methods" / "outline"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_list_symbols,
        )

        self._register_tool(
            name="goto_symbol",
            description="""Jump to a symbol by name.

Use this when the user says:
- "go to function X" / "find class Y" / "jump to method Z"
- "where is X defined?" / "take me to X"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Symbol name to find and jump to",
                    }
                },
                "required": ["name"],
            },
            handler=self._handle_goto_symbol,
        )

        # =====================================================================
        # Terminal
        # =====================================================================

        self._register_tool(
            name="open_terminal",
            description="""Open a terminal in Neovim.

Use this when the user says:
- "open terminal" / "new terminal" / "start a shell"
- "run X in terminal" / "terminal window"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "Command to run in terminal"}
                },
            },
            handler=self._handle_open_terminal,
        )

        self._register_tool(
            name="run_command",
            description="""Execute a Neovim command (ex command).

Use this when the user says:
- "run vim command X" / "execute :X" / "do :X"
- For specific commands like "%s/old/new/g" for substitution
""",
            input_schema={
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "Neovim command to execute"}
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
            description="""Show a notification message to the user in Neovim.

Use this when the user says:
- "tell me X" / "notify me" / "show a message"
- Or when you need to communicate something to the user visually
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
        # Configuration
        # =====================================================================

        self._register_tool(
            name="get_config",
            description="""Get current prism-nvim configuration.

Use this when the user says:
- "what are my settings?" / "show config" / "current configuration"
- "is narrated mode on?" / "what's my prism config?"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_get_config,
        )

        self._register_tool(
            name="set_config",
            description="""Set prism config. narrated=true shows vim commands.

Use this when the user says:
- "turn on narrated mode" / "teach me vim" / "show vim commands"
- "enable auto-save" / "change settings" / "configure prism"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "auto_save": {
                        "type": "boolean",
                        "description": "Auto-save after all buffer edits (default: false)",
                    },
                    "keep_focus": {
                        "type": "boolean",
                        "description": "Return focus to terminal (default: true)",
                    },
                    "narrated": {
                        "type": "boolean",
                        "description": "Show vim commands as they execute (default: false)",
                    },
                },
            },
            handler=self._handle_set_config,
        )

        self._register_tool(
            name="diff_preview",
            description="""Show diff preview. Original vs proposed changes side by side.

Use this when the user says:
- "show me the diff" / "preview changes" / "compare before/after"
- "what would change?" / "show side by side"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Path to the file to diff"},
                    "new_content": {
                        "type": "string",
                        "description": "Proposed new content for the file",
                    },
                },
                "required": ["path", "new_content"],
            },
            handler=self._handle_diff_preview,
        )

        # =====================================================================
        # Undo/Redo
        # =====================================================================

        self._register_tool(
            name="undo",
            description="""Undo the last change in the current buffer.

Use this when the user says:
- "undo" / "undo that" / "revert" / "go back"
- "undo the last change" / "take that back"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "count": {
                        "type": "integer",
                        "description": "Number of changes to undo (default: 1)",
                        "default": 1,
                    }
                },
            },
            handler=self._handle_undo,
        )

        self._register_tool(
            name="redo",
            description="""Redo the last undone change in the current buffer.

Use this when the user says:
- "redo" / "redo that" / "bring it back"
- "redo the last change" / "go forward"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "count": {
                        "type": "integer",
                        "description": "Number of changes to redo (default: 1)",
                        "default": 1,
                    }
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
- "who calls this?" / "find all uses"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_get_references,
        )

        self._register_tool(
            name="rename_symbol",
            description="""Rename the symbol under cursor across all files.

Use this when the user says:
- "rename this to X" / "refactor name to X" / "change name to X"
- "rename symbol" / "rename across files"
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
            description="""Get available code actions (quick fixes, refactors) for current position.

Use this when the user says:
- "fix this" / "quick fix" / "code actions"
- "what can I do here?" / "suggest fixes" / "auto-fix"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "apply_first": {
                        "type": "boolean",
                        "description": "Automatically apply the first available action",
                        "default": False,
                    }
                },
            },
            handler=self._handle_code_actions,
        )

        self._register_tool(
            name="fix_diagnostic",
            description="""Fix the diagnostic (error/warning) at the current position.

Use this when the user says:
- "fix this error" / "fix the warning" / "resolve this issue"
- "fix it" / "auto-fix" / "quick fix this"
- "what's wrong here?" (returns diagnostic if no auto-fix available)

This tool:
1. Finds the diagnostic at cursor (or specified line)
2. If a code action is available, applies the first fix
3. If no code action, returns the diagnostic message so you can generate a fix
""",
            input_schema={
                "type": "object",
                "properties": {
                    "line": {
                        "type": "integer",
                        "description": "Line number (defaults to current cursor line)",
                    },
                    "apply_first": {
                        "type": "boolean",
                        "description": "Auto-apply first code action if available (default: true)",
                        "default": True,
                    },
                },
            },
            handler=self._handle_fix_diagnostic,
        )

        # =====================================================================
        # Folding
        # =====================================================================

        self._register_tool(
            name="fold",
            description="""Fold code at current cursor position or specified line.

Use this when the user says:
- "fold this" / "collapse this" / "hide this section"
- "fold all" / "collapse all functions"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "line": {
                        "type": "integer",
                        "description": "Line number to fold at (current line if not specified)",
                    },
                    "all": {
                        "type": "boolean",
                        "description": "Fold all foldable regions in the buffer",
                        "default": False,
                    },
                },
            },
            handler=self._handle_fold,
        )

        self._register_tool(
            name="unfold",
            description="""Unfold code at current cursor position or specified line.

Use this when the user says:
- "unfold this" / "expand this" / "show this section"
- "unfold all" / "expand everything"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "line": {
                        "type": "integer",
                        "description": "Line number to unfold at (current line if not specified)",
                    },
                    "all": {
                        "type": "boolean",
                        "description": "Unfold all regions in the buffer",
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
            description="""Create a named bookmark at the current position.

Use this when the user says:
- "bookmark this" / "mark this spot" / "remember this location"
- "save this position as X" / "create bookmark X"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Name for the bookmark"},
                    "description": {
                        "type": "string",
                        "description": "Optional description of what's at this location",
                    },
                },
                "required": ["name"],
            },
            handler=self._handle_bookmark,
        )

        self._register_tool(
            name="goto_bookmark",
            description="""Jump to a named bookmark.

Use this when the user says:
- "go to bookmark X" / "jump to X" / "take me to bookmark X"
- "back to X" / "return to the X bookmark"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Name of the bookmark to jump to"}
                },
                "required": ["name"],
            },
            handler=self._handle_goto_bookmark,
        )

        self._register_tool(
            name="list_bookmarks",
            description="""List all current bookmarks.

Use this when the user says:
- "show bookmarks" / "list bookmarks" / "what bookmarks do I have?"
- "my saved locations" / "all bookmarks"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_list_bookmarks,
        )

        self._register_tool(
            name="delete_bookmark",
            description="""Delete a named bookmark.

Use this when the user says:
- "delete bookmark X" / "remove bookmark X" / "clear bookmark X"
- "forget bookmark X" / "get rid of bookmark X"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Name of the bookmark to delete"}
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
            description="""Toggle comment on line(s). Works with any language.

Use this when the user says:
- "comment this" / "uncomment this" / "toggle comment"
- "comment out this line" / "comment lines X to Y"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "start_line": {
                        "type": "integer",
                        "description": "Start line (1-indexed, current line if not specified)",
                    },
                    "end_line": {
                        "type": "integer",
                        "description": "End line (inclusive, same as start if not specified)",
                    },
                },
            },
            handler=self._handle_comment,
        )

        self._register_tool(
            name="duplicate_line",
            description="""Duplicate the current line below.

Use this when the user says:
- "duplicate this line" / "copy this line" / "clone this line"
- "duplicate line X" / "make a copy of this line"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "line": {
                        "type": "integer",
                        "description": "Line to duplicate (current line if not specified)",
                    },
                    "count": {
                        "type": "integer",
                        "description": "Number of copies (default: 1)",
                        "default": 1,
                    },
                },
            },
            handler=self._handle_duplicate_line,
        )

        self._register_tool(
            name="move_line",
            description="""Move line(s) up or down.

Use this when the user says:
- "move this line up" / "move this line down"
- "move line X up/down" / "shift this line up/down"
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
                    "end_line": {
                        "type": "integer",
                        "description": "End line (same as start if not specified)",
                    },
                },
                "required": ["direction"],
            },
            handler=self._handle_move_line,
        )

        self._register_tool(
            name="delete_line",
            description="""Delete line(s) from the buffer.

Use this when the user says:
- "delete this line" / "remove this line" / "delete line X"
- "delete lines X to Y" / "remove these lines"
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
            description="""Join the current line with the next line(s).

Use this when the user says:
- "join lines" / "merge lines" / "combine these lines"
- "put these on one line" / "join with next line"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "count": {
                        "type": "integer",
                        "description": "Number of lines to join (default: 2)",
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
            description="""Select the word under the cursor.

Use this when the user says:
- "select this word" / "highlight word" / "grab this word"
- "select word under cursor"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_select_word,
        )

        self._register_tool(
            name="select_line",
            description="""Select entire line(s).

Use this when the user says:
- "select this line" / "highlight line" / "select line X"
- "select lines X to Y" / "grab these lines"
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
            description="""Select a code block (braces, parens, paragraph).

Use this when the user says:
- "select this block" / "select inside braces" / "select paragraph"
- "grab this function body" / "select everything in parens"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "type": {
                        "type": "string",
                        "enum": ["paragraph", "brace", "paren", "bracket"],
                        "description": "Block type to select",
                        "default": "paragraph",
                    },
                    "around": {
                        "type": "boolean",
                        "description": "Include delimiters (default: false)",
                        "default": False,
                    },
                },
            },
            handler=self._handle_select_block,
        )

        self._register_tool(
            name="select_all",
            description="""Select the entire buffer content.

Use this when the user says:
- "select all" / "select everything" / "highlight all"
- "grab everything" / "select the whole file"
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
- "indent this" / "indent line X" / "add indent"
- "indent lines X to Y" / "move this right"
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
                    "count": {
                        "type": "integer",
                        "description": "Indent levels (default: 1)",
                        "default": 1,
                    },
                },
            },
            handler=self._handle_indent,
        )

        self._register_tool(
            name="dedent",
            description="""Decrease indentation of line(s).

Use this when the user says:
- "dedent this" / "unindent" / "remove indent"
- "dedent lines X to Y" / "move this left"
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
                    "count": {
                        "type": "integer",
                        "description": "Dedent levels (default: 1)",
                        "default": 1,
                    },
                },
            },
            handler=self._handle_dedent,
        )

        # =====================================================================
        # Navigation
        # =====================================================================

        self._register_tool(
            name="goto_line",
            description="""Jump to a specific line number.

Use this when the user says:
- "go to line N" / "jump to line N" / "take me to line N"
- "line N" / "show me line N"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "line": {"type": "integer", "description": "Line number to jump to"}
                },
                "required": ["line"],
            },
            handler=self._handle_goto_line,
        )

        self._register_tool(
            name="goto_matching",
            description="""Jump to the matching bracket/paren/brace.

Use this when the user says:
- "go to matching bracket" / "jump to matching" / "find the closing brace"
- "go to the other bracket" / "match bracket"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_goto_matching,
        )

        self._register_tool(
            name="next_error",
            description="""Jump to the next diagnostic error/warning.

Use this when the user says:
- "next error" / "go to next error" / "next problem"
- "next warning" / "jump to next issue"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "severity": {
                        "type": "string",
                        "enum": ["error", "warning", "info", "hint"],
                        "description": "Minimum severity (default: error)",
                        "default": "error",
                    }
                },
            },
            handler=self._handle_next_error,
        )

        self._register_tool(
            name="prev_error",
            description="""Jump to the previous diagnostic error/warning.

Use this when the user says:
- "previous error" / "go to previous error" / "last problem"
- "previous warning" / "jump to previous issue"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "severity": {
                        "type": "string",
                        "enum": ["error", "warning", "info", "hint"],
                        "description": "Minimum severity (default: error)",
                        "default": "error",
                    }
                },
            },
            handler=self._handle_prev_error,
        )

        self._register_tool(
            name="jump_back",
            description="""Jump to previous position in jump list (like browser back).

Use this when the user says:
- "go back" / "jump back" / "previous location"
- "back to where I was" / "return to previous spot"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "count": {
                        "type": "integer",
                        "description": "Positions to jump back (default: 1)",
                        "default": 1,
                    }
                },
            },
            handler=self._handle_jump_back,
        )

        self._register_tool(
            name="jump_forward",
            description="""Jump to next position in jump list (like browser forward).

Use this when the user says:
- "go forward" / "jump forward" / "next location"
- "forward in jump list"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "count": {
                        "type": "integer",
                        "description": "Positions to jump forward (default: 1)",
                        "default": 1,
                    }
                },
            },
            handler=self._handle_jump_forward,
        )

        # =====================================================================
        # Learning / Help
        # =====================================================================

        self._register_tool(
            name="explain_command",
            description="""Explain what a vim command does in plain English.

Use this when the user says:
- "what does X do?" / "explain X" / "how does X work?"
- "what's the command for X?" / "explain vim command X"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "command": {
                        "type": "string",
                        "description": "Vim command to explain (e.g. 'dd', 'ciw', ':wq')",
                    }
                },
                "required": ["command"],
            },
            handler=self._handle_explain_command,
        )

        self._register_tool(
            name="vim_cheatsheet",
            description="""Show a categorized cheatsheet of common vim commands.

Use this when the user says:
- "vim cheatsheet" / "show vim commands" / "vim help"
- "list vim commands" / "how to use vim"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "category": {
                        "type": "string",
                        "enum": ["movement", "editing", "search", "visual", "files", "all"],
                        "description": "Category to show (default: all)",
                        "default": "all",
                    }
                },
            },
            handler=self._handle_vim_cheatsheet,
        )

        self._register_tool(
            name="suggest_command",
            description="""Given a task, suggest the best vim command(s).

Use this when the user says:
- "how do I X in vim?" / "what's the vim way to X?"
- "suggest a command for X" / "vim command to X"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "task": {
                        "type": "string",
                        "description": "What you want to do (e.g. 'delete inside quotes')",
                    }
                },
                "required": ["task"],
            },
            handler=self._handle_suggest_command,
        )

        # =====================================================================
        # Trust Mode (Natural Language Control)
        # =====================================================================

        self._register_tool(
            name="set_trust_mode",
            description="""Change how the user wants to review your edits.

Use this when the user says things like:
- "be more careful" / "slow down" / "I want to review" → guardian
- "that's fine" / "I trust you" → companion
- "just do it" / "full speed" / "autopilot" → autopilot

Modes:
- guardian: User reviews every edit before it's applied (safest)
- companion: Edits auto-apply with visual overlay, easy undo (recommended)
- autopilot: Edits auto-apply with minimal UI (fastest)""",
            input_schema={
                "type": "object",
                "properties": {
                    "mode": {
                        "type": "string",
                        "enum": ["guardian", "companion", "autopilot"],
                        "description": "The trust mode to set",
                    }
                },
                "required": ["mode"],
            },
            handler=self._handle_set_trust_mode,
        )

        # =====================================================================
        # Productivity Plugins (Harpoon, Trouble, Todos, Spectre)
        # =====================================================================

        self._register_tool(
            name="harpoon_add",
            description="""Add current file to harpoon list for quick access.

Use this when the user says:
- "mark this file" / "add to harpoon" / "pin this file"
- "remember this file" / "bookmark with harpoon"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_harpoon_add,
        )

        self._register_tool(
            name="harpoon_list",
            description="""Show the harpoon quick access list.

Use this when the user says:
- "show harpoon" / "harpoon list" / "show marked files"
- "what files are pinned?" / "show bookmarked files"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_harpoon_list,
        )

        self._register_tool(
            name="harpoon_goto",
            description="""Jump to a file in the harpoon list by index.

Use this when the user says:
- "go to harpoon 1" / "jump to file 2" / "harpoon file 3"
- "open pinned file 1" / "switch to marked file 2"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "index": {
                        "type": "integer",
                        "description": "1-indexed position in harpoon list",
                    }
                },
                "required": ["index"],
            },
            handler=self._handle_harpoon_goto,
        )

        self._register_tool(
            name="harpoon_remove",
            description="""Remove current file from harpoon list.

Use this when the user says:
- "unmark this file" / "remove from harpoon" / "unpin this"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_harpoon_remove,
        )

        self._register_tool(
            name="trouble_toggle",
            description="""Toggle the Trouble diagnostics panel.

Use this when the user says:
- "show trouble" / "open trouble" / "diagnostics panel"
- "show all errors" / "list all problems" / "trouble window"
- "hide trouble" / "close trouble"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "mode": {
                        "type": "string",
                        "enum": ["diagnostics", "todo", "quickfix", "loclist", "lsp_references"],
                        "description": "Trouble mode (default: diagnostics)",
                        "default": "diagnostics",
                    }
                },
            },
            handler=self._handle_trouble_toggle,
        )

        self._register_tool(
            name="search_todos",
            description="""Search for TODO/FIXME/HACK comments in the project.

Use this when the user says:
- "find todos" / "search todos" / "show all TODOs"
- "what needs to be done?" / "find FIXMEs" / "list HACKs"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "keywords": {
                        "type": "string",
                        "description": "Keywords to search (default: TODO,FIXME,HACK)",
                    }
                },
            },
            handler=self._handle_search_todos,
        )

        self._register_tool(
            name="next_todo",
            description="""Jump to the next TODO comment.

Use this when the user says:
- "next todo" / "go to next TODO" / "find next FIXME"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_next_todo,
        )

        self._register_tool(
            name="prev_todo",
            description="""Jump to the previous TODO comment.

Use this when the user says:
- "previous todo" / "go to prev TODO" / "last FIXME"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_prev_todo,
        )

        self._register_tool(
            name="spectre_open",
            description="""Open Spectre for project-wide search and replace.

Use this when the user says:
- "search and replace in project" / "find and replace everywhere"
- "project-wide replace" / "open spectre" / "bulk replace"
""",
            input_schema={
                "type": "object",
                "properties": {
                    "search": {
                        "type": "string",
                        "description": "Initial search pattern (optional)",
                    },
                    "replace": {
                        "type": "string",
                        "description": "Initial replacement text (optional)",
                    },
                },
            },
            handler=self._handle_spectre_open,
        )

        self._register_tool(
            name="spectre_word",
            description="""Open Spectre with the word under cursor.

Use this when the user says:
- "replace this word everywhere" / "find and replace this"
- "rename this across project" / "spectre this word"
""",
            input_schema={"type": "object", "properties": {}},
            handler=self._handle_spectre_word,
        )

    def _register_tool(self, name: str, description: str, input_schema: dict, handler: Callable):
        """Register an MCP tool."""
        self.tools[name] = Tool(
            name=name, description=description, input_schema=input_schema, handler=handler
        )

    # =========================================================================
    # Tool Handlers
    # =========================================================================

    def _handle_open_file(
        self,
        path: str,
        line: Optional[int] = None,
        column: Optional[int] = None,
        keep_focus: Optional[bool] = None,
    ) -> dict:
        """Open a file in the editor area (not the terminal)."""
        if keep_focus is None:
            keep_focus = self.config.get("keep_focus", True)
        elif isinstance(keep_focus, str):
            keep_focus = keep_focus.lower() == "true"

        buf = self.nvim.open_file(path, keep_focus=False)  # Don't return focus yet

        # Jump to line/column if specified
        if line is not None:
            line = int(line)
            col = int(column) - 1 if column else 0
            editor_win = self.nvim._find_editor_window()
            if editor_win:
                self.nvim.call("nvim_win_set_cursor", editor_win, [line, col])
                # Center the line
                current_win = self.nvim.call("nvim_get_current_win")
                self.nvim.call("nvim_set_current_win", editor_win)
                self.nvim.command("normal! zz")
                self.nvim.call("nvim_set_current_win", current_win)

        # Return focus to terminal if requested
        if keep_focus:
            self.nvim._return_to_terminal()

        self._narrate(f"Opening file (:e {path})")
        return {"success": True, "buffer_id": buf.id, "path": buf.name, "filetype": buf.filetype}

    def _handle_save_file(self, path: Optional[str] = None) -> dict:
        """Save current file."""
        success = self.nvim.save_file(path)
        if not success:
            return {"success": False, "error": f"Buffer not found: {path}"}
        self._narrate("Saving file (:w)")
        return {"success": True}

    def _handle_close_file(self, path: Optional[str] = None, force: bool = False) -> dict:
        """Close a file."""
        cmd = ":bd!" if force else ":bd"
        if path:
            # Find buffer by path
            for buf in self.nvim.get_buffers():
                if _path_matches(buf.name, path):
                    self.nvim.close_buffer(buf.id, force)
                    self._narrate(f"Closing buffer ({cmd})")
                    return {"success": True}
            return {"success": False, "error": "File not found"}
        else:
            self.nvim.close_buffer(force=force)
            self._narrate(f"Closing buffer ({cmd})")
            return {"success": True}

    def _handle_create_file(self, path: str, content: str = "") -> dict:
        """Create a new file."""
        # Create parent directories
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        # Write content
        Path(path).write_text(content)
        # Open in editor
        buf = self.nvim.open_file(path)
        return {"success": True, "path": path, "buffer_id": buf.id}

    def _handle_get_buffer_content(self, path: Optional[str] = None) -> dict:
        """Get buffer content. If path specified but not in buffer, reads from disk."""
        if path:
            # First try to find in open buffers
            for buf in self.nvim.get_buffers():
                if _path_matches(buf.name, path):
                    content = self.nvim.get_buffer_content(buf.id)
                    return {"content": content}

            # Not in buffer - read from disk
            try:
                filepath = Path(path)
                if not filepath.is_absolute():
                    filepath = Path(self.nvim.call("nvim_call_function", "getcwd", [])) / path
                if filepath.exists():
                    content = filepath.read_text()
                    return {"content": content}
                else:
                    return {"error": f"File not found: {path}"}
            except Exception as e:
                return {"error": f"Failed to read file: {e}"}

        # No path - read current buffer
        content = self.nvim.get_buffer_content()
        return {"content": content}

    def _handle_get_buffer_lines(
        self, path: Optional[str] = None, start_line: int = 1, end_line: int = -1
    ) -> dict:
        """Get specific lines. If path specified but not in buffer, reads from disk."""
        start_line = int(start_line) if start_line is not None else 1
        end_line = int(end_line) if end_line is not None else -1

        if path:
            # First try to find in open buffers
            for buf in self.nvim.get_buffers():
                if _path_matches(buf.name, path):
                    start = start_line - 1
                    end_idx = end_line if end_line == -1 else end_line
                    lines = self.nvim.get_buffer_lines(start, end_idx, buf.id)
                    return {"lines": lines, "start_line": start_line, "count": len(lines)}

            # Not in buffer - read from disk
            try:
                filepath = Path(path)
                if not filepath.is_absolute():
                    filepath = Path(self.nvim.call("nvim_call_function", "getcwd", [])) / path
                if filepath.exists():
                    all_lines = filepath.read_text().splitlines()
                    start = start_line - 1
                    end_idx = end_line if end_line == -1 else end_line
                    lines = all_lines[start:end_idx] if end_idx != -1 else all_lines[start:]
                    return {"lines": lines, "start_line": start_line, "count": len(lines)}
                else:
                    return {"error": f"File not found: {path}"}
            except Exception as e:
                return {"error": f"Failed to read file: {e}"}

        # No path - read current buffer
        start = start_line - 1
        end_idx = end_line if end_line == -1 else end_line
        lines = self.nvim.get_buffer_lines(start, end_idx)
        return {"lines": lines, "start_line": start_line, "count": len(lines)}

    def _handle_set_buffer_content(
        self, content: str, path: Optional[str] = None, auto_save: Optional[bool] = None
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
                if _path_matches(buf.name, path):
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
        auto_save: Optional[bool] = None,
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
                if _path_matches(buf.name, path):
                    buf_id = buf.id
                    break

        # Convert to 0-indexed
        start = start_line - 1
        end_idx = end_line

        self.nvim.set_buffer_lines(new_lines, start, end_idx, buf_id)
        self._narrate(f"Editing lines {start_line}-{end_line} (nvim_buf_set_lines)")

        # Auto-save if enabled (via param or global config)
        if auto_save:
            if buf_id:
                # Save specific buffer
                self.nvim.command(f"buffer {buf_id} | write")
            else:
                self.nvim.save_file()

        return {"success": True, "lines_changed": len(new_lines), "saved": auto_save}

    def _handle_insert_text(
        self, line: int, column: int, text: str, path: Optional[str] = None
    ) -> dict:
        """Insert text at position."""
        # Ensure integer types
        line = int(line)
        column = int(column)

        buf_id = None
        if path:
            for buf in self.nvim.get_buffers():
                if _path_matches(buf.name, path):
                    buf_id = buf.id
                    break

        self.nvim.insert_text(text, line - 1, column, buf_id)
        self._narrate(f"Inserting text at L{line}:C{column}")
        return {"success": True}

    def _handle_get_open_files(self) -> dict:
        """Get all open files."""
        buffers = self.nvim.get_buffers()
        return {
            "files": [
                {"id": buf.id, "path": buf.name, "filetype": buf.filetype, "modified": buf.modified}
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
            "cursor": {"line": cursor[0], "column": cursor[1]},
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
        self._narrate(f"Moving cursor to L{line}:C{column} (:{line} then |)")
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
                "mode": sel.mode,
            }
        return {"text": None, "message": "No selection active"}

    def _handle_split_window(self, vertical: bool = False, path: Optional[str] = None) -> dict:
        """Create window split."""
        win = self.nvim.split(vertical, path)
        return {"success": True, "window_id": win.id, "buffer_id": win.buffer_id}

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
                    "height": win.height,
                }
                for win in windows
            ]
        }

    def _handle_get_diagnostics(self, path: Optional[str] = None) -> dict:
        """Get LSP diagnostics."""
        buf_id = None
        if path:
            for buf in self.nvim.get_buffers():
                if _path_matches(buf.name, path):
                    buf_id = buf.id
                    break

        diagnostics = self.nvim.get_diagnostics(buf_id)
        return {"diagnostics": diagnostics}

    def _handle_goto_definition(self) -> dict:
        """Go to definition."""
        success = self.nvim.goto_definition()
        self._narrate("Go to definition (gd or vim.lsp.buf.definition())")
        if success:
            buf = self.nvim.get_current_buffer()
            cursor = self.nvim.get_cursor()
            return {"success": True, "path": buf.name, "line": cursor[0], "column": cursor[1]}
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
        return {"matches": [{"line": r[0], "column": r[1]} for r in results], "count": len(results)}

    def _handle_search_and_replace(self, pattern: str, replacement: str, flags: str = "g") -> dict:
        """Search and replace."""
        count = self.nvim.replace(pattern, replacement, flags)
        self._narrate(f"Search/replace (:%s/{pattern}/{replacement}/{flags})")
        return {"success": True, "replacements": count}

    def _handle_git_status(self) -> dict:
        """Get git status."""
        return self.nvim.git_status()

    def _handle_git_diff(self, staged: bool = False) -> dict:
        """Get git diff."""
        diff = self.nvim.git_diff(staged)
        return {"diff": diff}

    def _handle_git_stage(self, path: Optional[str] = None, all: bool = False) -> dict:
        """Stage files for commit."""
        if all:
            cmd = "git add -A"
        else:
            if path is None:
                buf = self.nvim.get_current_buffer()
                path = buf.name
            cmd = f"git add {path}"

        result = self.nvim.lua(
            f"""
            local output = vim.fn.system('{cmd}')
            local code = vim.v.shell_error
            return {{ output = output, code = code }}
        """
        )

        if result.get("code", 0) != 0:
            return {"success": False, "error": result.get("output", "Failed to stage")}

        staged_target = "all changes" if all else (path or "current file")
        return {"success": True, "message": f"Staged {staged_target}"}

    def _handle_git_commit(self, message: str) -> dict:
        """Commit staged changes."""
        escaped_message = message.replace("'", "'\\''")
        cmd = f"git commit -m '{escaped_message}'"

        result = self.nvim.lua(
            f"""
            local output = vim.fn.system([[{cmd}]])
            local code = vim.v.shell_error
            return {{ output = output, code = code }}
        """
        )

        if result.get("code", 0) != 0:
            error_msg = result.get("output", "Failed to commit")
            return {"success": False, "error": error_msg.strip()}

        return {"success": True, "message": message}

    def _handle_git_blame(self, line: Optional[int] = None) -> dict:
        """Show who last modified a line."""
        buf = self.nvim.get_current_buffer()
        path = buf.name

        if line is None:
            cursor = self.nvim.get_cursor()
            line = cursor[0]

        result = self.nvim.lua(
            f"""
            local output = vim.fn.system('git blame -L {line},{line} {path} 2>/dev/null')
            local code = vim.v.shell_error
            return {{ output = output, code = code }}
        """
        )

        if result.get("code", 0) != 0:
            return {"success": False, "error": "Not in a git repository or file not tracked"}

        blame_line = result.get("output", "").strip()
        return {"success": True, "line": line, "blame": blame_line}

    def _handle_git_log(self, count: int = 10) -> dict:
        """Show commit history."""
        result = self.nvim.lua(
            f"""
            local output = vim.fn.system('git log --oneline -n {count} 2>/dev/null')
            local code = vim.v.shell_error
            return {{ output = output, code = code }}
        """
        )

        if result.get("code", 0) != 0:
            return {"success": False, "error": "Not in a git repository"}

        log = result.get("output", "").strip()
        commits = [line for line in log.split("\n") if line]
        return {"success": True, "commits": commits, "count": len(commits)}

    def _handle_list_symbols(self) -> dict:
        """List all symbols in the current file using LSP."""
        result = self.nvim.lua(
            """
            local symbols = {}
            local params = { textDocument = vim.lsp.util.make_text_document_params() }

            local results = vim.lsp.buf_request_sync(0, 'textDocument/documentSymbol', params, 2000)
            if not results then
                return { success = false, error = "No LSP response" }
            end

            local function extract_symbols(items, prefix)
                prefix = prefix or ""
                for _, item in ipairs(items or {}) do
                    local kind_map = {
                        [1] = "File", [2] = "Module", [3] = "Namespace", [4] = "Package",
                        [5] = "Class", [6] = "Method", [7] = "Property", [8] = "Field",
                        [9] = "Constructor", [10] = "Enum", [11] = "Interface", [12] = "Function",
                        [13] = "Variable", [14] = "Constant", [15] = "String", [16] = "Number",
                        [17] = "Boolean", [18] = "Array", [19] = "Object", [20] = "Key",
                        [21] = "Null", [22] = "EnumMember", [23] = "Struct", [24] = "Event",
                        [25] = "Operator", [26] = "TypeParameter"
                    }
                    local kind = kind_map[item.kind] or "Unknown"
                    local name = item.name
                    local range = item.range or (item.location and item.location.range)
                    local line = range and (range.start.line + 1) or 0

                    table.insert(symbols, {
                        name = prefix .. name,
                        kind = kind,
                        line = line
                    })

                    if item.children then
                        extract_symbols(item.children, prefix .. name .. ".")
                    end
                end
            end

            for _, res in pairs(results) do
                if res.result then
                    extract_symbols(res.result)
                end
            end

            return { success = true, symbols = symbols }
        """
        )

        if not result.get("success"):
            return {"success": False, "error": result.get("error", "Failed to get symbols")}

        return {"success": True, "symbols": result.get("symbols", [])}

    def _handle_goto_symbol(self, name: str) -> dict:
        """Jump to a symbol by name."""
        symbols_result = self._handle_list_symbols()
        if not symbols_result.get("success"):
            return symbols_result

        symbols = symbols_result.get("symbols", [])
        name_lower = name.lower()
        matches = [s for s in symbols if name_lower in s.get("name", "").lower()]

        if not matches:
            return {"success": False, "error": f"No symbol matching '{name}' found"}

        target = matches[0]
        line = target.get("line", 1)
        self.nvim.goto_line(line)
        self._narrate(f"Jump to symbol ({target.get('kind', 'symbol')} at line {line})")

        return {
            "success": True,
            "symbol": target.get("name"),
            "kind": target.get("kind"),
            "line": line,
            "matches": len(matches),
        }

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
                "edit",
                "e ",
                "e!",
                "buffer",
                "b ",
                "bnext",
                "bprev",
                "split",
                "sp ",
                "vsplit",
                "vs ",
                "new",
                "vnew",
                "enew",
                "tabnew",
                "tabedit",
                "tabe ",
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
                        win_buftype = self.nvim.call(
                            "nvim_get_option_value", "buftype", {"buf": win_buf}
                        )
                        if win_buftype != "terminal":
                            self.nvim.call("nvim_set_current_win", win)
                            break

                    # Run command in editor window
                    self.nvim.command(command)

                    # Return focus to terminal
                    try:
                        self.nvim.call("nvim_set_current_win", current_win)
                    except Exception:
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
        keep_focus: Optional[bool] = None,
        narrated: Optional[bool] = None,
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
        if narrated is not None:
            self.config["narrated"] = parse_bool(narrated)

        # Notify user of config change
        mode_parts = []
        if self.config["auto_save"]:
            mode_parts.append("auto-save")
        if self.config["narrated"]:
            mode_parts.append("narrated")
        mode_str = ", ".join(mode_parts) if mode_parts else "default"
        self.nvim.notify(f"Prism mode: {mode_str}", "info")

        return {"success": True, "config": self.config}

    def _handle_diff_preview(self, path: str, new_content: str) -> dict:
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
            "message": "Diff preview opened. Use :diffoff and :bd to close.",
        }

    def _handle_undo(self, count: int = 1) -> dict:
        """Undo changes."""
        count = int(count) if count else 1
        vim_cmd = "u" if count == 1 else f"{count}u"
        self.nvim.command(f"normal! {vim_cmd}")
        self._narrate(f"Undo ({vim_cmd})")
        return {"success": True, "count": count, "vim_cmd": vim_cmd}

    def _handle_redo(self, count: int = 1) -> dict:
        """Redo changes."""
        count = int(count) if count else 1
        for _ in range(count):
            self.nvim.command("normal! \\<C-r>")
        self._narrate(f"Redo (Ctrl+R ×{count})")
        return {"success": True, "count": count, "vim_cmd": f"Ctrl+R ×{count}"}

    def _handle_get_references(self) -> dict:
        """Find all references to symbol under cursor."""
        try:
            # Use LSP references
            self.nvim.command("lua vim.lsp.buf.references()")
            self._narrate("Finding references (vim.lsp.buf.references())")
            return {"success": True, "message": "References shown in quickfix list"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_rename_symbol(self, new_name: str) -> dict:
        """Rename symbol using LSP."""
        try:
            self.nvim.command(f"lua vim.lsp.buf.rename('{new_name}')")
            self._narrate(f"Renaming symbol to '{new_name}' (vim.lsp.buf.rename())")
            return {"success": True, "new_name": new_name}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_code_actions(self, apply_first: bool = False) -> dict:
        """Get or apply code actions."""
        try:
            if apply_first:
                # Apply first available action
                self.nvim.command("lua vim.lsp.buf.code_action()")
                self._narrate("Showing code actions (vim.lsp.buf.code_action())")
                return {"success": True, "message": "Code action menu shown"}
            else:
                # Just show available actions
                self.nvim.command("lua vim.lsp.buf.code_action()")
                self._narrate("Showing code actions (vim.lsp.buf.code_action())")
                return {"success": True, "message": "Code action menu shown"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_fix_diagnostic(self, line: Optional[int] = None, apply_first: bool = True) -> dict:
        """Fix diagnostic at current position."""
        try:
            # Get cursor position if line not specified
            if line is None:
                cursor = self.nvim.get_cursor()
                line = cursor[0]

            # Get diagnostics for current buffer
            buf_id = self.nvim.call("nvim_get_current_buf")
            all_diagnostics = self.nvim.get_diagnostics(buf_id)

            # Find diagnostic at or near the specified line
            line_diagnostics = [d for d in all_diagnostics if d.get("lnum") == line]

            if not line_diagnostics:
                # Look for diagnostics within 2 lines
                nearby = [d for d in all_diagnostics if abs(d.get("lnum", 0) - line) <= 2]
                if nearby:
                    line_diagnostics = [min(nearby, key=lambda d: abs(d.get("lnum", 0) - line))]

            if not line_diagnostics:
                return {
                    "success": False,
                    "error": "No diagnostic found at or near line " + str(line),
                    "all_diagnostics": len(all_diagnostics),
                }

            diagnostic = line_diagnostics[0]

            if apply_first:
                # Move cursor to diagnostic location and try code action
                self.nvim.set_cursor(diagnostic.get("lnum", line), diagnostic.get("col", 0))
                self.nvim.command("lua vim.lsp.buf.code_action()")
                self._narrate("Applying code action for diagnostic (vim.lsp.buf.code_action())")
                return {
                    "success": True,
                    "action": "code_action_shown",
                    "diagnostic": diagnostic,
                    "message": "Code action menu shown for: "
                    + diagnostic.get("message", "unknown"),
                }
            else:
                # Just return the diagnostic for Claude to fix manually
                return {
                    "success": True,
                    "action": "diagnostic_returned",
                    "diagnostic": diagnostic,
                    "message": "Diagnostic found, no auto-fix applied",
                }

        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_fold(self, line: Optional[int] = None, all: bool = False) -> dict:
        """Fold code."""
        if all:
            self.nvim.command("normal! zM")
            self._narrate("Folding all (zM)")
            return {"success": True, "vim_cmd": "zM", "message": "All folds closed"}

        if line:
            self.nvim.set_cursor(int(line), 0)

        self.nvim.command("normal! zc")
        self._narrate("Folding at cursor (zc)")
        return {"success": True, "vim_cmd": "zc"}

    def _handle_unfold(self, line: Optional[int] = None, all: bool = False) -> dict:
        """Unfold code."""
        if all:
            self.nvim.command("normal! zR")
            self._narrate("Unfolding all (zR)")
            return {"success": True, "vim_cmd": "zR", "message": "All folds opened"}

        if line:
            self.nvim.set_cursor(int(line), 0)

        self.nvim.command("normal! zo")
        self._narrate("Unfolding at cursor (zo)")
        return {"success": True, "vim_cmd": "zo"}

    def _handle_bookmark(self, name: str, description: str = "") -> dict:
        """Create a bookmark."""
        buf = self.nvim.get_current_buffer()
        cursor = self.nvim.get_cursor()

        self.bookmarks[name] = {
            "path": buf.name,
            "line": cursor[0],
            "column": cursor[1],
            "description": description,
        }

        self._narrate(f"Bookmark '{name}' created (like :mark but named)")
        return {"success": True, "name": name, "path": buf.name, "line": cursor[0]}

    def _handle_goto_bookmark(self, name: str) -> dict:
        """Jump to a bookmark."""
        if name not in self.bookmarks:
            return {"success": False, "error": f"Bookmark '{name}' not found"}

        bm = self.bookmarks[name]
        self.nvim.open_file(bm["path"])
        self.nvim.set_cursor(bm["line"], bm["column"])

        self._narrate(f"Jumping to bookmark '{name}' (like `a but named)")
        return {"success": True, "name": name, "path": bm["path"], "line": bm["line"]}

    def _handle_list_bookmarks(self) -> dict:
        """List all bookmarks."""
        return {"bookmarks": self.bookmarks}

    def _handle_delete_bookmark(self, name: str) -> dict:
        """Delete a bookmark."""
        if name not in self.bookmarks:
            return {"success": False, "error": f"Bookmark '{name}' not found"}

        del self.bookmarks[name]
        return {"success": True, "name": name}

    # =========================================================================
    # Line Operations Handlers
    # =========================================================================

    def _handle_comment(
        self, start_line: Optional[int] = None, end_line: Optional[int] = None
    ) -> dict:
        """Toggle comment on line(s)."""
        try:
            if start_line is not None and end_line is not None:
                start_line, end_line = int(start_line), int(end_line)
                self.nvim.command(f"{start_line},{end_line}normal gcc")
                count = end_line - start_line + 1
                vim_cmd = f"{start_line},{end_line}normal gcc"
            elif start_line is not None:
                self.nvim.set_cursor(int(start_line), 0)
                self.nvim.command("normal gcc")
                count = 1
                vim_cmd = "gcc"
            else:
                self.nvim.command("normal gcc")
                count = 1
                vim_cmd = "gcc"

            self._narrate(f"Toggle comment ({vim_cmd})")
            return {"success": True, "lines": count, "vim_cmd": vim_cmd}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_duplicate_line(self, line: Optional[int] = None, count: int = 1) -> dict:
        """Duplicate a line below."""
        count = int(count) if count else 1

        if line is not None:
            self.nvim.set_cursor(int(line), 0)

        # Copy current line and paste below
        self.nvim.command("normal! yy")
        for _ in range(count):
            self.nvim.command("normal! p")

        vim_cmd = "yyp" if count == 1 else f"yy{count}p"
        self._narrate(f"Duplicate line ({vim_cmd})")
        return {"success": True, "copies": count, "vim_cmd": vim_cmd}

    def _handle_move_line(
        self, direction: str, start_line: Optional[int] = None, end_line: Optional[int] = None
    ) -> dict:
        """Move line(s) up or down."""
        try:
            if start_line is not None and end_line is not None:
                start_line, end_line = int(start_line), int(end_line)
                if direction == "up":
                    target = start_line - 2
                    self.nvim.command(f"{start_line},{end_line}move {target}")
                else:
                    target = end_line + 1
                    self.nvim.command(f"{start_line},{end_line}move {target}")
                vim_cmd = f":{start_line},{end_line}m {target}"
            else:
                if direction == "up":
                    self.nvim.command("move .-2")
                    vim_cmd = ":m .-2"
                else:
                    self.nvim.command("move .+1")
                    vim_cmd = ":m .+1"

            self._narrate(f"Move line {direction} ({vim_cmd})")
            return {"success": True, "direction": direction, "vim_cmd": vim_cmd}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _handle_delete_line(
        self, start_line: Optional[int] = None, end_line: Optional[int] = None
    ) -> dict:
        """Delete line(s)."""
        if start_line is not None and end_line is not None:
            start_line, end_line = int(start_line), int(end_line)
            count = end_line - start_line + 1
            self.nvim.command(f"{start_line},{end_line}delete")
            vim_cmd = f":{start_line},{end_line}d"
        elif start_line is not None:
            count = 1
            self.nvim.set_cursor(int(start_line), 0)
            self.nvim.command("delete")
            vim_cmd = f":{start_line}d"
        else:
            count = 1
            self.nvim.command("normal! dd")
            vim_cmd = "dd"

        self._narrate(f"Delete {count} line(s) ({vim_cmd})")
        return {"success": True, "deleted": count, "vim_cmd": vim_cmd}

    def _handle_join_lines(self, count: int = 2) -> dict:
        """Join lines together."""
        count = int(count) if count else 2
        vim_cmd = f"{count}J" if count > 2 else "J"
        self.nvim.command(f"normal! {vim_cmd}")
        self._narrate(f"Join {count} lines ({vim_cmd})")
        return {"success": True, "joined": count, "vim_cmd": vim_cmd}

    # =========================================================================
    # Selection Helpers Handlers
    # =========================================================================

    def _handle_select_word(self) -> dict:
        """Select word under cursor."""
        word = self.nvim.eval("expand('<cword>')")
        self.nvim.command("normal! viw")
        self._narrate("Select word (viw)")
        return {"success": True, "word": word or "", "vim_cmd": "viw"}

    def _handle_select_line(
        self, start_line: Optional[int] = None, end_line: Optional[int] = None
    ) -> dict:
        """Select entire line(s)."""
        if start_line is not None and end_line is not None:
            start_line, end_line = int(start_line), int(end_line)
            self.nvim.set_cursor(start_line, 0)
            self.nvim.command("normal! V")
            if end_line > start_line:
                self.nvim.command(f"normal! {end_line - start_line}j")
            count = end_line - start_line + 1
        elif start_line is not None:
            self.nvim.set_cursor(int(start_line), 0)
            self.nvim.command("normal! V")
            count = 1
        else:
            self.nvim.command("normal! V")
            count = 1

        self._narrate(f"Select {count} line(s) (V)")
        return {"success": True, "lines": count, "vim_cmd": "V"}

    def _handle_select_block(self, type: str = "paragraph", around: bool = False) -> dict:
        """Select a code block."""
        modifier = "a" if around else "i"
        block_map = {
            "paragraph": "p",
            "brace": "{",
            "paren": "(",
            "bracket": "[",
        }

        if type not in block_map:
            return {"success": False, "error": f"Unknown block type: {type}"}

        char = block_map[type]
        vim_cmd = f"v{modifier}{char}"
        self.nvim.command(f"normal! v{modifier}{char}")
        desc = "around" if around else "inside"
        self._narrate(f"Select {desc} {type} ({vim_cmd})")
        return {"success": True, "type": type, "around": around, "vim_cmd": vim_cmd}

    def _handle_select_all(self) -> dict:
        """Select entire buffer."""
        self.nvim.command("normal! ggVG")
        line_count = self.nvim.eval("line('$')")
        self._narrate("Select all (ggVG)")
        return {"success": True, "lines": line_count, "vim_cmd": "ggVG"}

    # =========================================================================
    # Indentation Handlers
    # =========================================================================

    def _handle_indent(
        self, start_line: Optional[int] = None, end_line: Optional[int] = None, count: int = 1
    ) -> dict:
        """Increase indentation."""
        count = int(count) if count else 1

        if start_line is not None and end_line is not None:
            start_line, end_line = int(start_line), int(end_line)
            for _ in range(count):
                self.nvim.command(f"{start_line},{end_line}>")
            lines = end_line - start_line + 1
            vim_cmd = f":{start_line},{end_line}>"
        else:
            for _ in range(count):
                self.nvim.command("normal! >>")
            lines = 1
            vim_cmd = ">>"

        self._narrate(f"Indent {lines} line(s) ({vim_cmd})")
        return {"success": True, "lines": lines, "levels": count, "vim_cmd": vim_cmd}

    def _handle_dedent(
        self, start_line: Optional[int] = None, end_line: Optional[int] = None, count: int = 1
    ) -> dict:
        """Decrease indentation."""
        count = int(count) if count else 1

        if start_line is not None and end_line is not None:
            start_line, end_line = int(start_line), int(end_line)
            for _ in range(count):
                self.nvim.command(f"{start_line},{end_line}<")
            lines = end_line - start_line + 1
            vim_cmd = f":{start_line},{end_line}<"
        else:
            for _ in range(count):
                self.nvim.command("normal! <<")
            lines = 1
            vim_cmd = "<<"

        self._narrate(f"Dedent {lines} line(s) ({vim_cmd})")
        return {"success": True, "lines": lines, "levels": count, "vim_cmd": vim_cmd}

    # =========================================================================
    # Navigation Handlers
    # =========================================================================

    def _handle_goto_line(self, line: int) -> dict:
        """Jump to a specific line in the editor window."""
        line = int(line)

        # Switch to editor window first (avoid terminal mode issues)
        editor_win = self.nvim._find_editor_window()
        if not editor_win:
            return {"success": False, "error": "No editor window found"}

        current_win = self.nvim.call("nvim_get_current_win")
        self.nvim.call("nvim_set_current_win", editor_win)

        self.nvim.set_cursor(line, 0)
        self.nvim.command("normal! ^zz")

        # Return to terminal
        self.nvim.call("nvim_set_current_win", current_win)

        self._narrate(f"Go to line {line} (:{line} or {line}G)")
        return {"success": True, "line": line, "column": 0, "vim_cmd": f":{line}"}

    def _handle_goto_matching(self) -> dict:
        """Jump to matching bracket."""
        before = self.nvim.get_cursor()
        self.nvim.command("normal! %")
        after = self.nvim.get_cursor()
        moved = before != after
        self._narrate("Jump to matching bracket (%)")
        return {
            "success": moved,
            "from": {"line": before[0], "column": before[1]},
            "to": {"line": after[0], "column": after[1]},
            "vim_cmd": "%",
        }

    def _handle_next_error(self, severity: str = "error") -> dict:
        """Jump to next diagnostic."""
        severity_map = {"error": "ERROR", "warning": "WARN", "info": "INFO", "hint": "HINT"}
        vim_severity = severity_map.get(severity, "ERROR")

        lua_cmd = (
            f"vim.diagnostic.goto_next({{severity={{min="
            f"vim.diagnostic.severity.{vim_severity}}}}})"
        )
        self.nvim.command(f"lua {lua_cmd}")
        cursor = self.nvim.get_cursor()
        self._narrate(f"Jump to next {severity}")
        return {
            "success": True,
            "line": cursor[0],
            "column": cursor[1],
            "severity": severity,
            "vim_cmd": "]d",
        }

    def _handle_prev_error(self, severity: str = "error") -> dict:
        """Jump to previous diagnostic."""
        severity_map = {"error": "ERROR", "warning": "WARN", "info": "INFO", "hint": "HINT"}
        vim_severity = severity_map.get(severity, "ERROR")

        lua_cmd = (
            f"vim.diagnostic.goto_prev({{severity={{min="
            f"vim.diagnostic.severity.{vim_severity}}}}})"
        )
        self.nvim.command(f"lua {lua_cmd}")
        cursor = self.nvim.get_cursor()
        self._narrate(f"Jump to previous {severity}")
        return {
            "success": True,
            "line": cursor[0],
            "column": cursor[1],
            "severity": severity,
            "vim_cmd": "[d",
        }

    def _handle_jump_back(self, count: int = 1) -> dict:
        """Jump back in jump list."""
        count = int(count) if count else 1
        self.nvim.command(f"normal! {count}\\<C-o>")
        cursor = self.nvim.get_cursor()
        buf = self.nvim.get_current_buffer()
        self._narrate("Jump back (Ctrl+O)")
        return {
            "success": True,
            "path": buf.name,
            "line": cursor[0],
            "column": cursor[1],
            "vim_cmd": "Ctrl+O",
        }

    def _handle_jump_forward(self, count: int = 1) -> dict:
        """Jump forward in jump list."""
        count = int(count) if count else 1
        self.nvim.command(f"normal! {count}\\<C-i>")
        cursor = self.nvim.get_cursor()
        buf = self.nvim.get_current_buffer()
        self._narrate("Jump forward (Ctrl+I)")
        return {
            "success": True,
            "path": buf.name,
            "line": cursor[0],
            "column": cursor[1],
            "vim_cmd": "Ctrl+I",
        }

    # =========================================================================
    # Learning / Help Handlers
    # =========================================================================

    def _handle_explain_command(self, command: str) -> dict:
        """Explain a vim command."""
        explanations = {
            # Movement
            "h": "Move cursor left",
            "j": "Move cursor down",
            "k": "Move cursor up",
            "l": "Move cursor right",
            "w": "Move to next word",
            "b": "Move to previous word",
            "e": "Move to end of word",
            "0": "Move to start of line",
            "$": "Move to end of line",
            "^": "Move to first non-blank char",
            "gg": "Go to first line",
            "G": "Go to last line",
            "%": "Jump to matching bracket",
            # Editing
            "i": "Insert before cursor",
            "a": "Insert after cursor",
            "I": "Insert at line start",
            "A": "Insert at line end",
            "o": "New line below",
            "O": "New line above",
            "x": "Delete character",
            "dd": "Delete line",
            "dw": "Delete word",
            "d$": "Delete to end of line",
            "D": "Delete to end of line",
            "cc": "Change entire line",
            "cw": "Change word",
            "ciw": "Change inner word",
            'ci"': "Change inside quotes",
            "ci(": "Change inside parens",
            "ci{": "Change inside braces",
            "yy": "Copy line",
            "yw": "Copy word",
            "p": "Paste after cursor",
            "P": "Paste before cursor",
            "u": "Undo",
            "U": "Undo line changes",
            # Visual
            "v": "Visual mode (char)",
            "V": "Visual mode (line)",
            # Search
            "/": "Search forward",
            "?": "Search backward",
            "n": "Next match",
            "N": "Previous match",
            "*": "Search word forward",
            "#": "Search word backward",
            # Files
            ":w": "Save file",
            ":q": "Quit",
            ":wq": "Save and quit",
            ":q!": "Force quit",
            ":e": "Open file",
            # Other
            ".": "Repeat last change",
            "J": "Join lines",
            ">>": "Indent line",
            "<<": "Dedent line",
            "gcc": "Toggle comment",
            "gd": "Go to definition",
            "zc": "Fold at cursor",
            "zo": "Unfold at cursor",
            "zM": "Fold all",
            "zR": "Unfold all",
        }

        cmd = command.strip()
        if cmd in explanations:
            explanation = explanations[cmd]
        elif cmd.startswith("d"):
            explanation = f"Delete with motion '{cmd[1:]}'"
        elif cmd.startswith("c"):
            explanation = f"Change with motion '{cmd[1:]}'"
        elif cmd.startswith("y"):
            explanation = f"Yank (copy) with motion '{cmd[1:]}'"
        elif cmd.startswith(":"):
            explanation = f"Ex command - try ':help {cmd[1:]}' in Neovim"
        else:
            explanation = f"Try ':help {cmd}' in Neovim for details"

        return {"command": cmd, "explanation": explanation}

    def _handle_vim_cheatsheet(self, category: str = "all") -> dict:
        """Show vim cheatsheet."""
        cheatsheet = {
            "movement": {
                "title": "Movement",
                "commands": {
                    "h/j/k/l": "Left/Down/Up/Right",
                    "w / b": "Next / Previous word",
                    "0 / $": "Start / End of line",
                    "gg / G": "Top / Bottom of file",
                    "Ctrl+d/u": "Half page down/up",
                    "%": "Matching bracket",
                },
            },
            "editing": {
                "title": "Editing",
                "commands": {
                    "i / a": "Insert before/after",
                    "o / O": "New line below/above",
                    "dd": "Delete line",
                    "cc": "Change line",
                    "yy / p": "Copy / Paste",
                    "u / Ctrl+R": "Undo / Redo",
                    "ciw": "Change inner word",
                    ">>": "Indent line",
                },
            },
            "search": {
                "title": "Search",
                "commands": {
                    "/pattern": "Search forward",
                    "n / N": "Next / Previous match",
                    "*": "Search word under cursor",
                    ":%s/old/new/g": "Replace all",
                },
            },
            "visual": {
                "title": "Visual Mode",
                "commands": {
                    "v": "Character selection",
                    "V": "Line selection",
                    "viw": "Select word",
                    "vi{": "Select inside braces",
                },
            },
            "files": {
                "title": "Files",
                "commands": {
                    ":w": "Save",
                    ":q": "Quit",
                    ":wq": "Save & quit",
                    ":e path": "Open file",
                },
            },
        }

        if category == "all":
            result_cats = cheatsheet
        elif category in cheatsheet:
            result_cats = {category: cheatsheet[category]}
        else:
            return {"success": False, "error": f"Unknown category: {category}"}

        return {"success": True, "categories": result_cats}

    def _handle_suggest_command(self, task: str) -> dict:
        """Suggest vim commands for a task."""
        task_lower = task.lower()
        suggestions = []

        patterns = [
            (
                ["delete", "remove"],
                [
                    ("dd", "Delete line"),
                    ("dw", "Delete word"),
                    ("diw", "Delete inner word"),
                    ('di"', "Delete inside quotes"),
                ],
            ),
            (
                ["copy", "yank", "duplicate"],
                [
                    ("yy", "Copy line"),
                    ("yw", "Copy word"),
                    ("yyp", "Duplicate line"),
                ],
            ),
            (
                ["paste"],
                [
                    ("p", "Paste after"),
                    ("P", "Paste before"),
                ],
            ),
            (
                ["replace", "change"],
                [
                    ("ciw", "Change word"),
                    ("cc", "Change line"),
                    ('ci"', "Change inside quotes"),
                    (":%s/old/new/g", "Replace all"),
                ],
            ),
            (["undo"], [("u", "Undo"), ("Ctrl+R", "Redo")]),
            (
                ["search", "find"],
                [
                    ("/pattern", "Search forward"),
                    ("*", "Search word under cursor"),
                ],
            ),
            (
                ["select"],
                [
                    ("viw", "Select word"),
                    ("V", "Select line"),
                    ("ggVG", "Select all"),
                ],
            ),
            (["indent"], [(">>", "Indent"), ("<<", "Dedent")]),
            (["save"], [(":w", "Save"), (":wq", "Save & quit")]),
            (["quit", "exit"], [(":q", "Quit"), (":q!", "Force quit")]),
            (["comment"], [("gcc", "Toggle comment")]),
            (["move line"], [(":m .+1", "Move down"), (":m .-2", "Move up")]),
            (
                ["go to", "jump"],
                [
                    (":{n}", "Go to line n"),
                    ("gg", "Go to top"),
                    ("G", "Go to bottom"),
                    ("gd", "Go to definition"),
                ],
            ),
        ]

        for keywords, cmds in patterns:
            if any(kw in task_lower for kw in keywords):
                suggestions.extend(cmds)

        if not suggestions:
            suggestions = [("(no match)", "Try describing differently")]

        return {
            "task": task,
            "suggestions": [{"command": c, "description": d} for c, d in suggestions],
        }

    def _handle_set_trust_mode(self, mode: str) -> dict:
        """Set the trust mode for edit handling."""
        valid_modes = {"guardian", "companion", "autopilot"}
        if mode not in valid_modes:
            return {
                "success": False,
                "error": f"Invalid mode: {mode}. Use: {', '.join(valid_modes)}",
            }

        # Call the Lua function to set the mode
        result = self.nvim.exec_lua(
            """
            local ok, companion = pcall(require, 'prism.companion')
            if ok then
                local success, err = companion.set_mode(...)
                return { success = success, error = err }
            else
                return { success = false, error = 'Companion module not available' }
            end
            """,
            mode,
        )

        if result and result.get("success"):
            icons = {"guardian": "🛡️", "companion": "🤝", "autopilot": "🚀"}
            return {
                "success": True,
                "mode": mode,
                "message": f"{icons.get(mode, '')} Trust mode set to {mode}",
            }
        else:
            return {"success": False, "error": result.get("error", "Unknown error")}

    # =========================================================================
    # Productivity Plugin Handlers (Harpoon, Trouble, Todos, Spectre)
    # =========================================================================

    def _handle_harpoon_add(self) -> dict:
        """Add current file to harpoon list."""
        result = self.nvim.exec_lua(
            """
            local ok, harpoon = pcall(require, 'harpoon')
            if not ok then
                return { success = false, error = 'Harpoon not installed' }
            end
            local list = harpoon:list()
            list:add()
            return { success = true, message = 'File added to harpoon' }
            """
        )
        self._narrate("Add to harpoon (leader+a or :lua require('harpoon'):list():add())")
        return result or {"success": True}

    def _handle_harpoon_list(self) -> dict:
        """Show harpoon file list."""
        result = self.nvim.exec_lua(
            """
            local ok, harpoon = pcall(require, 'harpoon')
            if not ok then
                return { success = false, error = 'Harpoon not installed', files = {} }
            end
            local list = harpoon:list()
            local files = {}
            for i, item in ipairs(list.items) do
                table.insert(files, { index = i, path = item.value })
            end
            return { success = true, files = files }
            """
        )
        self._narrate("Show harpoon (Ctrl+e or :lua require('harpoon').ui:toggle_quick_menu())")
        # Also toggle the UI
        self.nvim.exec_lua(
            """
            local ok, harpoon = pcall(require, 'harpoon')
            if ok then harpoon.ui:toggle_quick_menu(harpoon:list()) end
            """
        )
        return result or {"success": True, "files": []}

    def _handle_harpoon_goto(self, index: int) -> dict:
        """Jump to harpoon file by index."""
        result = self.nvim.exec_lua(
            """
            local ok, harpoon = pcall(require, 'harpoon')
            if not ok then
                return { success = false, error = 'Harpoon not installed' }
            end
            local list = harpoon:list()
            list:select(...)
            return { success = true }
            """,
            index,
        )
        self._narrate(f"Jump to harpoon {index} (leader+{index})")
        return result or {"success": True}

    def _handle_harpoon_remove(self) -> dict:
        """Remove current file from harpoon list."""
        result = self.nvim.exec_lua(
            """
            local ok, harpoon = pcall(require, 'harpoon')
            if not ok then
                return { success = false, error = 'Harpoon not installed' }
            end
            local list = harpoon:list()
            list:remove()
            return { success = true, message = 'File removed from harpoon' }
            """
        )
        self._narrate("Remove from harpoon")
        return result or {"success": True}

    def _handle_trouble_toggle(self, mode: str = "diagnostics") -> dict:
        """Toggle Trouble diagnostics panel."""
        result = self.nvim.exec_lua(
            """
            local ok, trouble = pcall(require, 'trouble')
            if not ok then
                return { success = false, error = 'Trouble not installed' }
            end
            trouble.toggle(...)
            return { success = true }
            """,
            mode,
        )
        self._narrate(f"Toggle Trouble {mode} (<leader>xx or :Trouble {mode})")
        return result or {"success": True}

    def _handle_search_todos(self, keywords: str = "TODO,FIXME,HACK") -> dict:
        """Search for TODO comments in project."""
        result = self.nvim.exec_lua(
            """
            local ok, trouble = pcall(require, 'trouble')
            if not ok then
                vim.cmd('TodoTelescope')
                return { success = true, method = 'telescope' }
            end
            trouble.toggle('todo')
            return { success = true, method = 'trouble' }
            """
        )
        self._narrate("Search TODOs (<leader>st or :TodoTelescope)")
        return result or {"success": True}

    def _handle_next_todo(self) -> dict:
        """Jump to next TODO comment."""
        result = self.nvim.exec_lua(
            """
            local ok, todo = pcall(require, 'todo-comments')
            if not ok then
                return { success = false, error = 'todo-comments not installed' }
            end
            todo.jump_next()
            return { success = true }
            """
        )
        self._narrate("Next TODO (]t)")
        return result or {"success": True}

    def _handle_prev_todo(self) -> dict:
        """Jump to previous TODO comment."""
        result = self.nvim.exec_lua(
            """
            local ok, todo = pcall(require, 'todo-comments')
            if not ok then
                return { success = false, error = 'todo-comments not installed' }
            end
            todo.jump_prev()
            return { success = true }
            """
        )
        self._narrate("Previous TODO ([t)")
        return result or {"success": True}

    def _handle_spectre_open(
        self, search: Optional[str] = None, replace: Optional[str] = None
    ) -> dict:
        """Open Spectre for project-wide search and replace."""
        if search:
            result = self.nvim.exec_lua(
                """
                local ok, spectre = pcall(require, 'spectre')
                if not ok then
                    return { success = false, error = 'Spectre not installed' }
                end
                spectre.open({ search_text = ... })
                return { success = true }
                """,
                search,
            )
        else:
            result = self.nvim.exec_lua(
                """
                local ok, spectre = pcall(require, 'spectre')
                if not ok then
                    return { success = false, error = 'Spectre not installed' }
                end
                spectre.open()
                return { success = true }
                """
            )
        self._narrate("Open Spectre (<leader>sr or :lua require('spectre').open())")
        return result or {"success": True}

    def _handle_spectre_word(self) -> dict:
        """Open Spectre with word under cursor."""
        result = self.nvim.exec_lua(
            """
            local ok, spectre = pcall(require, 'spectre')
            if not ok then
                return { success = false, error = 'Spectre not installed' }
            end
            spectre.open_visual({ select_word = true })
            return { success = true }
            """
        )
        self._narrate("Spectre word (<leader>sw)")
        return result or {"success": True}

    def _narrate(self, message: str):
        """Show vim tip if narrated mode is enabled."""
        if self.config.get("narrated", False):
            self.nvim.notify(f"📚 {message}", "info")

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
                "serverInfo": {"name": "prism-nvim", "version": "0.1.0"},
                "capabilities": {"tools": {"listChanged": False}},
            },
        }

    def _handle_list_tools(self, msg_id: int) -> dict:
        """Handle tools/list request."""
        tools_list = [
            {"name": tool.name, "description": tool.description, "inputSchema": tool.input_schema}
            for tool in self.tools.values()
        ]

        return {"jsonrpc": "2.0", "id": msg_id, "result": {"tools": tools_list}}

    def _format_result(self, tool_name: str, result: dict) -> str:
        """Format tool result as human-readable text."""
        # Check for errors first
        if result.get("success") is False:
            error = result.get("error", "Unknown error")
            return f"✗ {error}"

        # Simple success cases
        if result == {"success": True}:
            return "✓ Done"

        # Handle specific tool outputs
        if tool_name == "run_command":
            if result.get("protected"):
                return "✓ Done (terminal protected)"
            return "✓ Done"

        if tool_name == "save_file":
            return "✓ Saved"

        if tool_name == "open_file":
            path = result.get("path", "")
            name = path.split("/")[-1] if "/" in path else path
            return f"✓ Opened: {name}"

        if tool_name == "create_file":
            path = result.get("path", "")
            return f"✓ Created: {path}"

        if tool_name == "close_file":
            return "✓ Closed"

        if tool_name in ("edit_buffer", "set_buffer_content"):
            parts = []
            if "lines_changed" in result:
                parts.append(f"{result['lines_changed']} lines")
            if result.get("saved"):
                parts.append("saved")
            if parts:
                return f"✓ {', '.join(parts)}"
            return "✓ Updated"

        if tool_name == "insert_text":
            return "✓ Inserted"

        if tool_name == "search_and_replace":
            count = result.get("replacements", 0)
            return f"✓ {count} replacement{'s' if count != 1 else ''}"

        if tool_name == "notify":
            return "✓ Notified"

        if tool_name == "set_config":
            cfg = result.get("config", {})
            parts = []
            if cfg.get("auto_save"):
                parts.append("auto-save")
            if cfg.get("narrated"):
                parts.append("narrated")
            mode = ", ".join(parts) if parts else "default"
            return f"✓ Mode: {mode}"

        if tool_name == "format_file":
            return "✓ Formatted"

        if tool_name == "split_window":
            return "✓ Split created"

        if tool_name == "close_window":
            return "✓ Window closed"

        if tool_name == "set_cursor_position":
            return "✓ Cursor moved"

        if tool_name == "diff_preview":
            return result.get("message", "✓ Diff preview opened")

        # Data-returning tools - format nicely
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
            modified = "●" if result.get("modified") else ""
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
                mod = " ●" if f.get("modified") else ""
                lines.append(f"  {name}{mod}")
            return "\n".join(lines)

        if tool_name == "get_windows":
            windows = result.get("windows", [])
            return f"{len(windows)} window{'s' if len(windows) != 1 else ''}"

        if tool_name == "get_selection":
            text = result.get("text")
            if not text:
                return "(no selection)"
            return f"Selected:\n{text}"

        if tool_name == "get_diagnostics":
            diags = result.get("diagnostics", [])
            if not diags:
                return "✓ No diagnostics"
            lines = []
            for d in diags[:10]:  # Limit to 10
                severity = d.get("severity", "info")
                msg = d.get("message", "")
                line = d.get("line", 0)
                lines.append(f"  {severity}: L{line} {msg}")
            if len(diags) > 10:
                lines.append(f"  ... and {len(diags) - 10} more")
            return "\n".join(lines)

        if tool_name == "get_hover_info":
            info = result.get("info", "")
            return info if info else "(no hover info)"

        if tool_name == "goto_definition":
            if result.get("success"):
                path = result.get("path", "").split("/")[-1]
                line = result.get("line", 1)
                return f"→ {path}:{line}"
            return "✗ No definition found"

        if tool_name == "search_in_file":
            matches = result.get("matches", [])
            count = result.get("count", 0)
            if count == 0:
                return "(no matches)"
            lines = [f"{count} match{'es' if count != 1 else ''}:"]
            for m in matches[:5]:
                lines.append(f"  L{m.get('line', 0)}:{m.get('column', 0)}")
            if count > 5:
                lines.append(f"  ... and {count - 5} more")
            return "\n".join(lines)

        if tool_name == "git_status":
            return json.dumps(result, indent=2, cls=BytesEncoder)

        if tool_name == "git_diff":
            diff = result.get("diff", "")
            return diff if diff else "(no changes)"

        if tool_name == "git_stage":
            if result.get("success"):
                return f"+ Staged: {result.get('message', 'files')}"
            return f"x {result.get('error', 'Failed to stage')}"

        if tool_name == "git_commit":
            if result.get("success"):
                msg = result.get("message", "")
                return f"+ Committed: {msg[:50]}{'...' if len(msg) > 50 else ''}"
            return f"x {result.get('error', 'Failed to commit')}"

        if tool_name == "git_blame":
            if result.get("success"):
                line = result.get("line", 0)
                blame = result.get("blame", "")
                return f"L{line}: {blame}"
            return f"x {result.get('error', 'Blame failed')}"

        if tool_name == "git_log":
            if result.get("success"):
                commits = result.get("commits", [])
                if not commits:
                    return "(no commits)"
                lines = [f"{len(commits)} commits:"]
                for c in commits[:10]:
                    lines.append(f"  {c}")
                if len(commits) > 10:
                    lines.append(f"  ... and {len(commits) - 10} more")
                return "\n".join(lines)
            return f"x {result.get('error', 'Log failed')}"

        if tool_name == "list_symbols":
            if result.get("success"):
                symbols = result.get("symbols", [])
                if not symbols:
                    return "(no symbols found)"
                lines = [f"{len(symbols)} symbols:"]
                for s in symbols[:15]:
                    lines.append(
                        f"  L{s.get('line', 0):4} {s.get('kind', ''):12} {s.get('name', '')}"
                    )
                if len(symbols) > 15:
                    lines.append(f"  ... and {len(symbols) - 15} more")
                return "\n".join(lines)
            return f"x {result.get('error', 'Failed to get symbols')}"

        if tool_name == "goto_symbol":
            if result.get("success"):
                name = result.get("symbol", "")
                kind = result.get("kind", "symbol")
                line = result.get("line", 0)
                matches = result.get("matches", 1)
                extra = f" ({matches} matches)" if matches > 1 else ""
                return f"-> {kind} '{name}' at L{line}{extra}"
            return f"x {result.get('error', 'Symbol not found')}"

        if tool_name == "get_config":
            cfg = result.get("config", {})
            lines = [
                f"auto_save: {cfg.get('auto_save', False)}",
                f"keep_focus: {cfg.get('keep_focus', True)}",
                f"narrated: {cfg.get('narrated', False)}",
            ]
            return "\n".join(lines)

        if tool_name == "open_terminal":
            return "✓ Terminal opened"

        # Undo/Redo
        if tool_name == "undo":
            count = result.get("count", 1)
            vim_cmd = result.get("vim_cmd", "u")
            return f"↶ Undid {count} change{'s' if count != 1 else ''} ({vim_cmd})"

        if tool_name == "redo":
            count = result.get("count", 1)
            return f"↷ Redid {count} change{'s' if count != 1 else ''} (Ctrl+R)"

        # LSP Advanced
        if tool_name == "get_references":
            return result.get("message", "✓ References found")

        if tool_name == "rename_symbol":
            new_name = result.get("new_name", "")
            return f"✓ Renamed to '{new_name}'"

        if tool_name == "code_actions":
            return result.get("message", "✓ Code actions shown")

        # Folding
        if tool_name == "fold":
            vim_cmd = result.get("vim_cmd", "zc")
            msg = result.get("message", "")
            return f"▼ Folded ({vim_cmd})" + (f" - {msg}" if msg else "")

        if tool_name == "unfold":
            vim_cmd = result.get("vim_cmd", "zo")
            msg = result.get("message", "")
            return f"▶ Unfolded ({vim_cmd})" + (f" - {msg}" if msg else "")

        # Bookmarks
        if tool_name == "bookmark":
            name = result.get("name", "")
            line = result.get("line", 0)
            return f"🔖 Bookmark '{name}' at L{line}"

        if tool_name == "goto_bookmark":
            name = result.get("name", "")
            path = result.get("path", "").split("/")[-1]
            line = result.get("line", 0)
            return f"→ {path}:{line} (bookmark '{name}')"

        if tool_name == "list_bookmarks":
            bookmarks = result.get("bookmarks", {})
            if not bookmarks:
                return "(no bookmarks)"
            lines = []
            for name, bm in bookmarks.items():
                path = bm.get("path", "").split("/")[-1]
                line = bm.get("line", 0)
                desc = bm.get("description", "")
                lines.append(f"  🔖 {name}: {path}:{line}" + (f" - {desc}" if desc else ""))
            return "\n".join(lines)

        if tool_name == "delete_bookmark":
            name = result.get("name", "")
            return f"✓ Deleted bookmark '{name}'"

        # Line Operations
        if tool_name == "comment":
            count = result.get("lines", 1)
            vim_cmd = result.get("vim_cmd", "gcc")
            return f"# Toggled comment on {count} line{'s' if count != 1 else ''} ({vim_cmd})"

        if tool_name == "duplicate_line":
            copies = result.get("copies", 1)
            vim_cmd = result.get("vim_cmd", "yyp")
            return f"= Duplicated {copies} time{'s' if copies != 1 else ''} ({vim_cmd})"

        if tool_name == "move_line":
            direction = result.get("direction", "")
            vim_cmd = result.get("vim_cmd", "")
            arrow = "↑" if direction == "up" else "↓"
            return f"{arrow} Moved line {direction} ({vim_cmd})"

        if tool_name == "delete_line":
            deleted = result.get("deleted", 1)
            vim_cmd = result.get("vim_cmd", "dd")
            return f"✗ Deleted {deleted} line{'s' if deleted != 1 else ''} ({vim_cmd})"

        if tool_name == "join_lines":
            joined = result.get("joined", 2)
            vim_cmd = result.get("vim_cmd", "J")
            return f"~ Joined {joined} lines ({vim_cmd})"

        # Selection Helpers
        if tool_name == "select_word":
            word = result.get("word", "")
            return f"['{word}'] selected (viw)"

        if tool_name == "select_line":
            count = result.get("lines", 1)
            return f"[{count} line{'s' if count != 1 else ''}] selected (V)"

        if tool_name == "select_block":
            block_type = result.get("type", "")
            vim_cmd = result.get("vim_cmd", "")
            return f"[{block_type}] selected ({vim_cmd})"

        if tool_name == "select_all":
            lines = result.get("lines", 0)
            return f"[all {lines} lines] selected (ggVG)"

        # Indentation
        if tool_name == "indent":
            lines = result.get("lines", 1)
            return f"→ Indented {lines} line{'s' if lines != 1 else ''} (>>)"

        if tool_name == "dedent":
            lines = result.get("lines", 1)
            return f"← Dedented {lines} line{'s' if lines != 1 else ''} (<<)"

        # Navigation
        if tool_name == "goto_line":
            line = result.get("line", 1)
            return f"→ Line {line}"

        if tool_name == "goto_matching":
            if result.get("success"):
                to = result.get("to", {})
                return f"→ Matching bracket at L{to.get('line', 0)}:C{to.get('column', 0)} (%)"
            return "(no matching bracket)"

        if tool_name in ("next_error", "prev_error"):
            direction = "Next" if tool_name == "next_error" else "Previous"
            severity = result.get("severity", "error")
            line = result.get("line", 0)
            return f"⚠ {direction} {severity} at L{line}"

        if tool_name in ("jump_back", "jump_forward"):
            direction = "Back" if tool_name == "jump_back" else "Forward"
            path = result.get("path", "").split("/")[-1]
            line = result.get("line", 0)
            vim_cmd = result.get("vim_cmd", "")
            return f"← {direction} to {path}:{line} ({vim_cmd})"

        # Learning/Help
        if tool_name == "explain_command":
            cmd = result.get("command", "")
            explanation = result.get("explanation", "")
            return f"'{cmd}' → {explanation}"

        if tool_name == "vim_cheatsheet":
            cats = result.get("categories", {})
            lines = []
            for cat_key, cat in cats.items():
                lines.append(f"\n─── {cat.get('title', cat_key)} ───")
                for cmd, desc in cat.get("commands", {}).items():
                    lines.append(f"  {cmd:15s} {desc}")
            return "\n".join(lines).strip()

        if tool_name == "suggest_command":
            task = result.get("task", "")
            suggestions = result.get("suggestions", [])
            lines = [f"For: {task}"]
            for s in suggestions:
                lines.append(f"  {s.get('command', ''):15s} {s.get('description', '')}")
            return "\n".join(lines)

        if tool_name == "set_trust_mode":
            if result.get("success"):
                return result.get("message", f"Mode set to {result.get('mode')}")
            else:
                return f"Error: {result.get('error', 'Unknown error')}"

        # Fallback: return JSON for unknown structures
        return json.dumps(result, indent=2, cls=BytesEncoder)

    def _handle_tool_call_sync(self, msg_id: int, params: dict) -> dict:
        """Handle tools/call request (synchronous)."""
        tool_name = params.get("name")
        arguments = params.get("arguments", {})

        logger.info(f"Tool call: {tool_name} with args: {arguments}")

        if tool_name not in self.tools:
            return {
                "jsonrpc": "2.0",
                "id": msg_id,
                "error": {"code": -32601, "message": f"Unknown tool: {tool_name}"},
            }

        tool = self.tools[tool_name]

        try:
            result = tool.handler(**arguments)
            formatted = self._format_result(tool_name, result)
            return {
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {"content": [{"type": "text", "text": formatted}]},
            }
        except Exception as e:
            logger.error(f"Tool error: {e}")
            import traceback

            logger.error(traceback.format_exc())
            return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32000, "message": str(e)}}

    async def _handle_tool_call(self, msg_id: int, params: dict) -> dict:
        """Handle tools/call request (async wrapper)."""
        return self._handle_tool_call_sync(msg_id, params)


def main():
    """Main entry point."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[logging.FileHandler("/tmp/prism-mcp.log")],
    )

    server = PrismMCPServer()
    asyncio.run(server.run())


if __name__ == "__main__":
    main()
