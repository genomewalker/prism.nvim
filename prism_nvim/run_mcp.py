#!/usr/bin/env python3
"""
Wrapper script to run the MCP server with proper stdio handling.
This ensures unbuffered I/O and clean startup.
"""
import sys
import os

# Force unbuffered stdout/stderr
os.environ["PYTHONUNBUFFERED"] = "1"

# Ensure we're in the right directory
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Import and run
from prism_nvim.mcp_server import main

main()
