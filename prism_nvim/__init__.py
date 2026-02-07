"""
Prism.nvim - The Ultimate Claude Code Integration for Neovim

A Python MCP server that gives Claude full control over Neovim as an IDE.
"""

__version__ = "0.1.0"
__author__ = "Antonio"


# Lazy imports to avoid RuntimeWarning when running as module
def __getattr__(name):
    if name == "NeovimClient":
        from .nvim_client import NeovimClient

        return NeovimClient
    if name == "PrismMCPServer":
        from .mcp_server import PrismMCPServer

        return PrismMCPServer
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


__all__ = ["NeovimClient", "PrismMCPServer", "__version__"]
