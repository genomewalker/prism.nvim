--- prism.nvim WebSocket Frame Encoding/Decoding (RFC 6455)
--- @module prism.mcp.server.frame

local utils = require("prism.mcp.server.utils")
local bit = require("bit")

local M = {}

-- WebSocket opcodes
M.OPCODE = {
  CONTINUATION = 0x0,
  TEXT = 0x1,
  BINARY = 0x2,
  CLOSE = 0x8,
  PING = 0x9,
  PONG = 0xA,
}

--- @class WebSocketFrame
--- @field fin boolean Final fragment flag
--- @field opcode number Frame opcode
--- @field masked boolean Mask flag
--- @field payload_length number Length of payload data
--- @field mask string|nil 4-byte mask (if masked)
--- @field payload string Frame payload data

--- Parse a WebSocket frame from binary data
--- @param data string Binary frame data
--- @return WebSocketFrame|nil frame Parsed frame, or nil if incomplete/invalid
--- @return number bytes_consumed Number of bytes consumed from input
function M.parse(data)
  if type(data) ~= "string" then
    return nil, 0
  end

  if #data < 2 then
    return nil, 0 -- Need at least 2 bytes for basic header
  end

  local pos = 1
  local byte1 = data:byte(pos)
  local byte2 = data:byte(pos + 1)

  if not byte1 or not byte2 then
    return nil, 0
  end

  pos = pos + 2

  local fin = bit.band(byte1, 0x80) ~= 0
  local rsv1 = bit.band(byte1, 0x40) ~= 0
  local rsv2 = bit.band(byte1, 0x20) ~= 0
  local rsv3 = bit.band(byte1, 0x10) ~= 0
  local opcode = bit.band(byte1, 0x0F)

  local masked = bit.band(byte2, 0x80) ~= 0
  local payload_len = bit.band(byte2, 0x7F)

  -- Validate opcode
  local valid_opcodes = {
    [M.OPCODE.CONTINUATION] = true,
    [M.OPCODE.TEXT] = true,
    [M.OPCODE.BINARY] = true,
    [M.OPCODE.CLOSE] = true,
    [M.OPCODE.PING] = true,
    [M.OPCODE.PONG] = true,
  }

  if not valid_opcodes[opcode] then
    return nil, 0 -- Invalid opcode
  end

  -- Check for reserved bits (must be 0)
  if rsv1 or rsv2 or rsv3 then
    return nil, 0 -- Protocol error
  end

  -- Control frames must have fin=1 and payload <= 125
  if opcode >= M.OPCODE.CLOSE then
    if not fin or payload_len > 125 then
      return nil, 0 -- Protocol violation
    end
  end

  -- Determine actual payload length
  local actual_payload_len = payload_len
  if payload_len == 126 then
    if #data < pos + 1 then
      return nil, 0 -- Need 2 more bytes
    end
    actual_payload_len = utils.bytes_to_uint16(data:sub(pos, pos + 1))
    pos = pos + 2
  elseif payload_len == 127 then
    if #data < pos + 7 then
      return nil, 0 -- Need 8 more bytes
    end
    actual_payload_len = utils.bytes_to_uint64(data:sub(pos, pos + 7))
    pos = pos + 8

    -- Prevent extremely large payloads (DOS protection)
    if actual_payload_len > 100 * 1024 * 1024 then -- 100MB limit
      return nil, 0
    end
  end

  if actual_payload_len < 0 then
    return nil, 0 -- Invalid negative length
  end

  -- Read mask if present
  local mask = nil
  if masked then
    if #data < pos + 3 then
      return nil, 0 -- Need 4 mask bytes
    end
    mask = data:sub(pos, pos + 3)
    pos = pos + 4
  end

  -- Check if we have enough data for payload
  if #data < pos + actual_payload_len - 1 then
    return nil, 0 -- Incomplete frame
  end

  -- Read payload
  local payload = data:sub(pos, pos + actual_payload_len - 1)
  pos = pos + actual_payload_len

  -- Unmask payload if needed
  if masked and mask then
    payload = utils.apply_mask(payload, mask)
  end

  -- Validate text frame payload is valid UTF-8
  if opcode == M.OPCODE.TEXT and not utils.is_valid_utf8(payload) then
    return nil, 0 -- Invalid UTF-8 in text frame
  end

  -- Basic validation for close frame payload
  if opcode == M.OPCODE.CLOSE and actual_payload_len > 0 then
    if actual_payload_len == 1 then
      return nil, 0 -- Close frame with 1 byte payload is invalid
    end
    if actual_payload_len > 2 then
      local reason = payload:sub(3)
      if not utils.is_valid_utf8(reason) then
        return nil, 0 -- Invalid UTF-8 in close reason
      end
    end
  end

  local frame = {
    fin = fin,
    opcode = opcode,
    masked = masked,
    payload_length = actual_payload_len,
    mask = mask,
    payload = payload,
  }

  return frame, pos - 1
end

--- Create a WebSocket frame
--- @param opcode number Frame opcode
--- @param payload string Frame payload
--- @param fin boolean|nil Final fragment flag (default: true)
--- @param masked boolean|nil Whether to mask the frame (default: false for server)
--- @return string frame_data Encoded frame data
function M.encode(opcode, payload, fin, masked)
  fin = fin ~= false -- Default to true
  masked = masked == true -- Default to false

  local frame_data = {}

  -- First byte: FIN + RSV + Opcode
  local byte1 = opcode
  if fin then
    byte1 = bit.bor(byte1, 0x80) -- Set FIN bit
  end
  table.insert(frame_data, string.char(byte1))

  -- Payload length and mask bit
  local payload_len = #payload
  local byte2 = 0
  if masked then
    byte2 = bit.bor(byte2, 0x80) -- Set MASK bit
  end

  if payload_len < 126 then
    byte2 = byte2 + payload_len
    table.insert(frame_data, string.char(byte2))
  elseif payload_len < 65536 then
    byte2 = byte2 + 126
    table.insert(frame_data, string.char(byte2))
    table.insert(frame_data, utils.uint16_to_bytes(payload_len))
  else
    byte2 = byte2 + 127
    table.insert(frame_data, string.char(byte2))
    table.insert(frame_data, utils.uint64_to_bytes(payload_len))
  end

  -- Add mask if needed
  local mask = nil
  if masked then
    mask = string.char(math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255))
    table.insert(frame_data, mask)
  end

  -- Add payload (masked if needed)
  if masked and mask then
    payload = utils.apply_mask(payload, mask)
  end
  table.insert(frame_data, payload)

  return table.concat(frame_data)
end

--- Create a text frame
--- @param text string Text to send
--- @param fin boolean|nil Final fragment flag (default: true)
--- @return string frame_data Encoded frame data
function M.create_text_frame(text, fin)
  return M.encode(M.OPCODE.TEXT, text, fin, false)
end

--- Create a binary frame
--- @param data string Binary data to send
--- @param fin boolean|nil Final fragment flag (default: true)
--- @return string frame_data Encoded frame data
function M.create_binary_frame(data, fin)
  return M.encode(M.OPCODE.BINARY, data, fin, false)
end

--- Create a close frame
--- @param code number|nil Close code (default: 1000)
--- @param reason string|nil Close reason (default: empty)
--- @return string frame_data Encoded frame data
function M.create_close_frame(code, reason)
  code = code or 1000
  reason = reason or ""

  local payload = utils.uint16_to_bytes(code) .. reason
  return M.encode(M.OPCODE.CLOSE, payload, true, false)
end

--- Create a ping frame
--- @param data string|nil Ping data (default: empty)
--- @return string frame_data Encoded frame data
function M.create_ping_frame(data)
  data = data or ""
  return M.encode(M.OPCODE.PING, data, true, false)
end

--- Create a pong frame
--- @param data string|nil Pong data (should match ping data)
--- @return string frame_data Encoded frame data
function M.create_pong_frame(data)
  data = data or ""
  return M.encode(M.OPCODE.PONG, data, true, false)
end

--- Check if an opcode is a control frame
--- @param opcode number Opcode to check
--- @return boolean is_control True if it's a control frame
function M.is_control_frame(opcode)
  return opcode >= 0x8
end

--- Validate a WebSocket frame
--- @param frame WebSocketFrame Frame to validate
--- @return boolean valid True if the frame is valid
--- @return string|nil error Error message if invalid
function M.validate(frame)
  -- Control frames must not be fragmented
  if M.is_control_frame(frame.opcode) and not frame.fin then
    return false, "Control frames must not be fragmented"
  end

  -- Control frames must have payload <= 125 bytes
  if M.is_control_frame(frame.opcode) and frame.payload_length > 125 then
    return false, "Control frame payload too large"
  end

  -- Check for valid opcodes
  local valid_opcodes = {
    [M.OPCODE.CONTINUATION] = true,
    [M.OPCODE.TEXT] = true,
    [M.OPCODE.BINARY] = true,
    [M.OPCODE.CLOSE] = true,
    [M.OPCODE.PING] = true,
    [M.OPCODE.PONG] = true,
  }

  if not valid_opcodes[frame.opcode] then
    return false, "Invalid opcode: " .. frame.opcode
  end

  -- Text frames must contain valid UTF-8
  if frame.opcode == M.OPCODE.TEXT and not utils.is_valid_utf8(frame.payload) then
    return false, "Text frame contains invalid UTF-8"
  end

  return true
end

return M
