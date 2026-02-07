--- prism.nvim TCP Server using vim.uv
--- Creates a TCP listener for WebSocket connections
--- @module prism.mcp.server.tcp

local M = {}

--- Server state
--- @type table|nil
local server_state = nil

--- Create and start a TCP server
--- @param host string Host address (e.g., "127.0.0.1")
--- @param port number Port number
--- @param callbacks table Callback functions { on_connection, on_error }
--- @return table|nil server Server handle or nil on error
--- @return string|nil error Error message
function M.listen(host, port, callbacks)
  if server_state and server_state.handle then
    return nil, "Server already running"
  end

  local uv = vim.uv or vim.loop

  -- Create TCP handle
  local server = uv.new_tcp()
  if not server then
    return nil, "Failed to create TCP handle"
  end

  -- Bind to address
  local ok, bind_err = pcall(function()
    server:bind(host, port)
  end)

  if not ok then
    server:close()
    return nil, "Failed to bind to " .. host .. ":" .. port .. " - " .. tostring(bind_err)
  end

  -- Start listening
  local listen_err = server:listen(128, function(err)
    if err then
      if callbacks.on_error then
        callbacks.on_error("Listen error: " .. tostring(err))
      end
      return
    end

    -- Accept connection
    local client = uv.new_tcp()
    if not client then
      if callbacks.on_error then
        callbacks.on_error("Failed to create client handle")
      end
      return
    end

    local accept_ok = server:accept(client)
    if not accept_ok then
      client:close()
      if callbacks.on_error then
        callbacks.on_error("Failed to accept connection")
      end
      return
    end

    -- Get peer info
    local peer = client:getpeername()
    local peer_info = peer and (peer.ip .. ":" .. peer.port) or "unknown"

    -- Create connection wrapper
    local connection = M.wrap_connection(client, peer_info, callbacks)

    if callbacks.on_connection then
      callbacks.on_connection(connection)
    end
  end)

  if listen_err then
    server:close()
    return nil, "Failed to listen: " .. tostring(listen_err)
  end

  -- Store state
  server_state = {
    handle = server,
    host = host,
    port = port,
    connections = {},
  }

  return server_state, nil
end

--- Wrap a client TCP handle with helper methods
--- @param handle userdata libuv TCP handle
--- @param peer_info string Peer address info
--- @param server_callbacks table Server callback functions
--- @return table connection Connection wrapper
function M.wrap_connection(handle, peer_info, server_callbacks)
  local connection = {
    handle = handle,
    peer = peer_info,
    buffer = "",
    state = "new", -- new, handshake, open, closing, closed
    callbacks = {},
  }

  --- Start reading data
  --- @param on_data function Callback for data: function(data)
  --- @param on_close function Callback for close: function(reason)
  --- @param on_error function Callback for error: function(err)
  function connection:start_read(on_data, on_close, on_error)
    self.callbacks.on_data = on_data
    self.callbacks.on_close = on_close
    self.callbacks.on_error = on_error

    handle:read_start(function(err, chunk)
      if err then
        if on_error then
          vim.schedule(function()
            on_error(err)
          end)
        end
        self:close("read error: " .. tostring(err))
        return
      end

      if chunk then
        if on_data then
          vim.schedule(function()
            on_data(chunk)
          end)
        end
      else
        -- EOF
        self:close("connection closed by peer")
      end
    end)
  end

  --- Stop reading data
  function connection:stop_read()
    if handle and not handle:is_closing() then
      handle:read_stop()
    end
  end

  --- Write data
  --- @param data string Data to write
  --- @param callback function|nil Optional callback on completion
  function connection:write(data, callback)
    if not handle or handle:is_closing() then
      if callback then
        callback("connection closed")
      end
      return
    end

    handle:write(data, function(err)
      if err and self.callbacks.on_error then
        vim.schedule(function()
          self.callbacks.on_error("write error: " .. tostring(err))
        end)
      end
      if callback then
        vim.schedule(function()
          callback(err)
        end)
      end
    end)
  end

  --- Close connection
  --- @param reason string|nil Close reason
  function connection:close(reason)
    if self.state == "closed" then
      return
    end

    self.state = "closed"

    if handle and not handle:is_closing() then
      handle:read_stop()
      handle:close()
    end

    if self.callbacks.on_close then
      vim.schedule(function()
        self.callbacks.on_close(reason or "closed")
      end)
    end

    -- Remove from server connections
    if server_state and server_state.connections then
      for i, conn in ipairs(server_state.connections) do
        if conn == self then
          table.remove(server_state.connections, i)
          break
        end
      end
    end
  end

  --- Check if connection is open
  --- @return boolean
  function connection:is_open()
    return self.state ~= "closed" and handle and not handle:is_closing()
  end

  -- Track connection
  if server_state and server_state.connections then
    table.insert(server_state.connections, connection)
  end

  return connection
end

--- Stop the server
function M.stop()
  if not server_state then
    return
  end

  -- Close all connections
  if server_state.connections then
    for _, conn in ipairs(server_state.connections) do
      conn:close("server shutdown")
    end
    server_state.connections = {}
  end

  -- Close server handle
  if server_state.handle and not server_state.handle:is_closing() then
    server_state.handle:close()
  end

  server_state = nil
end

--- Get server info
--- @return table|nil info Server info or nil if not running
function M.info()
  if not server_state then
    return nil
  end

  return {
    host = server_state.host,
    port = server_state.port,
    connections = #(server_state.connections or {}),
    running = server_state.handle and not server_state.handle:is_closing(),
  }
end

--- Check if server is running
--- @return boolean
function M.is_running()
  return server_state ~= nil
    and server_state.handle ~= nil
    and not server_state.handle:is_closing()
end

--- Get connection count
--- @return number
function M.connection_count()
  if not server_state or not server_state.connections then
    return 0
  end
  return #server_state.connections
end

--- Find an available port in range
--- @param host string Host address
--- @param min_port number Minimum port
--- @param max_port number Maximum port
--- @return number|nil port Available port or nil
function M.find_available_port(host, min_port, max_port)
  local uv = vim.uv or vim.loop

  for port = min_port, max_port do
    local test = uv.new_tcp()
    if test then
      local ok = pcall(function()
        test:bind(host, port)
      end)
      test:close()
      if ok then
        return port
      end
    end
  end

  return nil
end

return M
