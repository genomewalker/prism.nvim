--- prism.nvim MCP Server Orchestrator
--- Main entry point for the Model Context Protocol server
--- @module prism.mcp

local tcp = require("prism.mcp.server.tcp")
local client = require("prism.mcp.server.client")
local lockfile = require("prism.mcp.lockfile")
local tools = require("prism.mcp.tools")
local config = require("prism.config")
local event = require("prism.event")
local util = require("prism.util")

local M = {}

--- Server state
--- @type table|nil
local server = nil

--- Connected WebSocket clients
--- @type table<string, WebSocketClient>
local clients = {}

--- Authentication token for this session
--- @type string|nil
local auth_token = nil

--- Heartbeat timer handle
--- @type userdata|nil
local heartbeat_timer = nil

--- MCP Protocol version
local MCP_VERSION = "2024-11-05"

--- Generate a session-specific auth token
--- @return string token
local function generate_auth_token()
  return util.uuid_v4()
end

--- Send JSON-RPC message to a client
--- @param ws_client table WebSocket client
--- @param message table JSON-RPC message
local function send_jsonrpc(ws_client, message)
  local json = vim.json.encode(message)
  if not json then
    util.log.error("Failed to encode JSON-RPC message")
    return
  end

  client.send(ws_client, json, function(err)
    if err then
      util.log.error("Failed to send message to client " .. ws_client.id .. ": " .. err)
    end
  end)
end

--- Handle JSON-RPC request
--- @param ws_client table WebSocket client
--- @param request table JSON-RPC request
local function handle_request(ws_client, request)
  local method = request.method
  local params = request.params or {}
  local id = request.id

  util.log.debug("MCP request: " .. method, { id = id })

  local response = {
    jsonrpc = "2.0",
    id = id,
  }

  if method == "initialize" then
    -- MCP initialization handshake
    response.result = {
      protocolVersion = MCP_VERSION,
      capabilities = {
        tools = {
          listChanged = true,
        },
        resources = {
          subscribe = false,
          listChanged = false,
        },
        prompts = {
          listChanged = false,
        },
        logging = {},
      },
      serverInfo = {
        name = "prism.nvim",
        version = "1.0.0",
      },
    }

    event.emit(event.events.MCP_CONNECTED, {
      client_id = ws_client.id,
    })

  elseif method == "initialized" then
    -- Client acknowledges initialization - no response needed for notification
    util.log.debug("Client initialized: " .. ws_client.id)
    return

  elseif method == "ping" then
    response.result = {}

  elseif method == "tools/list" then
    response.result = {
      tools = tools.list(),
    }

  elseif method == "tools/call" then
    local tool_name = params.name
    local tool_params = params.arguments or {}

    local result = tools.execute(tool_name, tool_params, tostring(id))

    if result.isError then
      response.error = {
        code = -32000,
        message = result.content[1] and result.content[1].text or "Tool execution failed",
      }
    else
      response.result = result
    end

  elseif method == "resources/list" then
    -- We don't expose resources currently
    response.result = {
      resources = {},
    }

  elseif method == "resources/read" then
    response.error = {
      code = -32601,
      message = "Resources not supported",
    }

  elseif method == "prompts/list" then
    -- We don't expose prompts currently
    response.result = {
      prompts = {},
    }

  elseif method == "prompts/get" then
    response.error = {
      code = -32601,
      message = "Prompts not supported",
    }

  elseif method == "completion/complete" then
    -- Autocomplete not supported
    response.result = {
      completion = {
        values = {},
        hasMore = false,
      },
    }

  elseif method == "logging/setLevel" then
    local level = params.level
    if level then
      util.log.debug("Setting log level to: " .. level)
    end
    response.result = {}

  else
    response.error = {
      code = -32601,
      message = "Method not found: " .. method,
    }
  end

  send_jsonrpc(ws_client, response)
end

--- Handle JSON-RPC notification (no response expected)
--- @param ws_client table WebSocket client
--- @param notification table JSON-RPC notification
local function handle_notification(ws_client, notification)
  local method = notification.method
  local params = notification.params or {}

  util.log.debug("MCP notification: " .. method)

  if method == "notifications/cancelled" then
    local request_id = params.requestId
    if request_id then
      tools.reject(tostring(request_id), "Cancelled by client")
    end

  elseif method == "notifications/progress" then
    -- Progress notifications from client
    local progress_token = params.progressToken
    local progress = params.progress
    local total = params.total

    event.emit("mcp:progress", {
      token = progress_token,
      progress = progress,
      total = total,
    })
  end
end

--- Process incoming WebSocket message
--- @param ws_client table WebSocket client
--- @param message_text string Message text (JSON)
local function on_message(ws_client, message_text)
  local ok, message = pcall(vim.json.decode, message_text)
  if not ok then
    util.log.error("Failed to parse JSON-RPC message: " .. message_text:sub(1, 100))
    return
  end

  -- Check if it's a request (has id) or notification (no id)
  if message.id ~= nil then
    handle_request(ws_client, message)
  else
    handle_notification(ws_client, message)
  end
end

--- Handle client close
--- @param ws_client table WebSocket client
--- @param code number Close code
--- @param reason string Close reason
local function on_close(ws_client, code, reason)
  util.log.debug("Client disconnected: " .. ws_client.id, { code = code, reason = reason })

  clients[ws_client.id] = nil

  event.emit(event.events.MCP_DISCONNECTED, {
    client_id = ws_client.id,
    code = code,
    reason = reason,
  })
end

--- Handle client error
--- @param ws_client table WebSocket client
--- @param error_msg string Error message
local function on_error(ws_client, error_msg)
  util.log.error("Client error: " .. ws_client.id .. " - " .. error_msg)

  event.emit(event.events.MCP_ERROR, {
    client_id = ws_client.id,
    error = error_msg,
  })
end

--- Handle new TCP connection (upgrade to WebSocket)
--- @param tcp_connection table TCP connection wrapper
local function on_connection(tcp_connection)
  util.log.debug("New connection from: " .. tcp_connection.peer)

  -- Create WebSocket client wrapper
  local ws_client = client.new(tcp_connection.handle)

  -- Store connection
  clients[ws_client.id] = ws_client

  -- Start reading and processing WebSocket data
  client.read_start(
    ws_client,
    on_message,
    on_close,
    on_error,
    auth_token
  )
end

--- Start heartbeat timer to ping clients
local function start_heartbeat()
  if heartbeat_timer then
    return
  end

  local uv = vim.uv or vim.loop
  heartbeat_timer = uv.new_timer()

  if heartbeat_timer then
    heartbeat_timer:start(30000, 30000, vim.schedule_wrap(function()
      for id, ws_client in pairs(clients) do
        if client.is_alive(ws_client, 60000) then
          client.send_ping(ws_client)
        else
          util.log.debug("Client timeout: " .. id)
          client.close(ws_client, 1001, "Timeout")
        end
      end
    end))
  end
end

--- Stop heartbeat timer
local function stop_heartbeat()
  if heartbeat_timer then
    heartbeat_timer:stop()
    heartbeat_timer:close()
    heartbeat_timer = nil
  end
end

--- Start the MCP server
--- @param opts table|nil Options { host, port, port_range }
--- @return boolean success
--- @return string|nil error
function M.start(opts)
  -- Clean up stale lockfiles from crashed Neovim instances
  lockfile.cleanup()

  if server then
    return false, "Server already running"
  end

  opts = opts or {}
  local cfg = config.get("mcp") or {}

  local host = opts.host or "127.0.0.1"
  local port = opts.port
  local port_range = opts.port_range or cfg.port_range or { 9100, 9199 }

  -- Find available port if not specified
  if not port then
    port = tcp.find_available_port(host, port_range[1], port_range[2])
    if not port then
      return false, "No available port in range " .. port_range[1] .. "-" .. port_range[2]
    end
  end

  -- Generate auth token
  auth_token = generate_auth_token()

  -- Load built-in tools
  tools.load_builtins()

  -- Start TCP server
  local srv, err = tcp.listen(host, port, {
    on_connection = on_connection,
    on_error = function(error_msg)
      util.log.error("Server error: " .. error_msg)
      event.emit(event.events.MCP_ERROR, { error = error_msg })
    end,
  })

  if not srv then
    return false, err
  end

  server = {
    host = host,
    port = port,
    token = auth_token,
    started_at = os.time(),
  }

  -- Write lockfile for Claude CLI discovery
  local lock_ok, lock_err = lockfile.create(port, auth_token)
  if not lock_ok then
    util.log.warn("Failed to create lockfile: " .. tostring(lock_err))
  end

  -- Start heartbeat
  start_heartbeat()

  util.log.info("MCP server started on " .. host .. ":" .. port)

  event.emit("mcp:server_started", {
    host = host,
    port = port,
  })

  return true, nil
end

--- Stop the MCP server
function M.stop()
  if not server then
    return
  end

  util.log.info("Stopping MCP server")

  -- Stop heartbeat
  stop_heartbeat()

  -- Close all clients
  for id, ws_client in pairs(clients) do
    client.close(ws_client, 1001, "Server shutdown")
  end
  clients = {}

  -- Stop TCP server
  tcp.stop()

  -- Remove lockfile
  if server and server.port then
    lockfile.remove(server.port)
  end

  server = nil
  auth_token = nil

  event.emit("mcp:server_stopped", {})
end

--- Restart the MCP server
--- @return boolean success
--- @return string|nil error
function M.restart()
  local old_server = server
  M.stop()

  if old_server then
    return M.start({
      host = old_server.host,
      port = old_server.port,
    })
  end

  return M.start()
end

--- Get server status
--- @return table|nil status Server status or nil if not running
function M.status()
  if not server then
    return nil
  end

  local client_count = 0
  local connected_clients = {}
  for id, ws_client in pairs(clients) do
    client_count = client_count + 1
    table.insert(connected_clients, {
      id = id,
      state = ws_client.state,
    })
  end

  return {
    running = true,
    host = server.host,
    port = server.port,
    url = "ws://" .. server.host .. ":" .. server.port,
    token = server.token,
    uptime = os.time() - server.started_at,
    clients = client_count,
    client_list = connected_clients,
  }
end

--- Check if server is running
--- @return boolean
function M.is_running()
  return server ~= nil and tcp.is_running()
end

--- Check if any clients are connected
--- @return boolean
function M.is_connected()
  if not server then
    return false
  end
  for _, ws_client in pairs(clients) do
    if ws_client.state == "connected" then
      return true
    end
  end
  return false
end

--- Send message to a specific client
--- @param client_id string Client ID
--- @param message table|string JSON-RPC message or raw string
--- @return boolean success
function M.send(client_id, message)
  local ws_client = clients[client_id]
  if not ws_client or ws_client.state ~= "connected" then
    return false
  end

  if type(message) == "table" then
    send_jsonrpc(ws_client, message)
  else
    client.send(ws_client, message)
  end
  return true
end

--- Get connection URL for Claude CLI
--- @return string|nil url WebSocket URL or nil if not running
function M.get_url()
  if not server then
    return nil
  end
  return "ws://" .. server.host .. ":" .. server.port
end

--- Get auth token
--- @return string|nil token Auth token or nil if not running
function M.get_token()
  return auth_token
end

--- Get connection info for Claude CLI MCP config
--- @return table|nil info Connection info for .claude.json
function M.get_connection_info()
  if not server then
    return nil
  end

  return {
    transport = "websocket",
    url = M.get_url(),
    token = auth_token,
  }
end

--- Send notification to all connected clients
--- @param method string Notification method
--- @param params table|nil Notification params
function M.broadcast(method, params)
  local notification = {
    jsonrpc = "2.0",
    method = method,
    params = params or {},
  }

  for _, ws_client in pairs(clients) do
    if ws_client.state == "connected" then
      send_jsonrpc(ws_client, notification)
    end
  end
end

--- Notify clients that tools list has changed
function M.notify_tools_changed()
  M.broadcast("notifications/tools/list_changed", {})
end

--- Get list of connected client IDs
--- @return string[] client_ids
function M.get_clients()
  local ids = {}
  for id, _ in pairs(clients) do
    table.insert(ids, id)
  end
  return ids
end

--- Setup MCP module
function M.setup()
  local cfg = config.get("mcp") or {}

  if cfg.auto_start then
    -- Defer startup slightly to ensure Neovim is fully initialized
    vim.defer_fn(function()
      local ok, err = M.start()
      if not ok then
        util.log.error("Failed to auto-start MCP server: " .. tostring(err))
      end
    end, 100)
  end
end

return M
