#!/usr/bin/env python3
"""
Debug wrapper that logs all MCP I/O to see what Claude Code sends.
"""
import sys
import os
import subprocess
import threading
import time

LOG_FILE = "/tmp/prism-mcp-debug.log"

def log(msg):
    with open(LOG_FILE, "a") as f:
        f.write(f"{time.strftime('%H:%M:%S.%f')} {msg}\n")
        f.flush()

def main():
    log("=== DEBUG MCP WRAPPER STARTED ===")
    log(f"NVIM={os.environ.get('NVIM', 'not set')}")

    # Start the real MCP server
    proc = subprocess.Popen(
        [sys.executable, "-u", "-m", "prism_nvim.mcp_server"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    def forward_stdin():
        """Forward stdin to the subprocess, logging everything."""
        try:
            while True:
                data = sys.stdin.buffer.read(1)
                if not data:
                    log("STDIN: EOF")
                    proc.stdin.close()
                    break
                log(f"STDIN: {repr(data)}")
                proc.stdin.write(data)
                proc.stdin.flush()
        except Exception as e:
            log(f"STDIN ERROR: {e}")

    def forward_stdout():
        """Forward subprocess stdout to our stdout, logging everything."""
        try:
            while True:
                data = proc.stdout.read(1)
                if not data:
                    log("STDOUT: EOF from server")
                    break
                log(f"STDOUT: {repr(data)}")
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
        except Exception as e:
            log(f"STDOUT ERROR: {e}")

    def forward_stderr():
        """Log stderr from subprocess."""
        try:
            for line in proc.stderr:
                log(f"STDERR: {line}")
        except Exception as e:
            log(f"STDERR ERROR: {e}")

    # Start forwarding threads
    stdin_thread = threading.Thread(target=forward_stdin, daemon=True)
    stdout_thread = threading.Thread(target=forward_stdout, daemon=True)
    stderr_thread = threading.Thread(target=forward_stderr, daemon=True)

    stdin_thread.start()
    stdout_thread.start()
    stderr_thread.start()

    # Wait for process to finish
    proc.wait()
    log(f"Server exited with code {proc.returncode}")

if __name__ == "__main__":
    main()
