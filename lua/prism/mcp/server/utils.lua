--- prism.nvim MCP Server Utilities
--- Helper functions for WebSocket protocol implementation
--- @module prism.mcp.server.utils

local sha1 = require("prism.mcp.server.sha1")

local M = {}

--- Base64 encode a string (delegated to sha1 module)
--- @param data string Data to encode
--- @return string Encoded string
function M.base64_encode(data)
  return sha1.base64_encode(data)
end

--- Generate WebSocket accept key from client key (delegated to sha1 module)
--- @param client_key string Client's Sec-WebSocket-Key header value
--- @return string Accept key
function M.generate_accept_key(client_key)
  return sha1.websocket_accept(client_key)
end

--- Parse HTTP headers from request string
--- @param request string HTTP request string
--- @return table<string, string> Headers table (lowercase keys)
function M.parse_http_headers(request)
  local headers = {}
  local lines = {}

  for line in request:gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end

  for i = 2, #lines do
    local line = lines[i]
    local name, value = line:match("^([^:]+):%s*(.+)$")
    if name and value then
      headers[name:lower()] = value
    end
  end

  return headers
end

--- Check if a string contains valid UTF-8
--- @param str string String to check
--- @return boolean Valid if true
function M.is_valid_utf8(str)
  local i = 1
  while i <= #str do
    local byte = str:byte(i)
    local char_len = 1

    if byte >= 0x80 then
      if byte >= 0xF0 then
        char_len = 4
      elseif byte >= 0xE0 then
        char_len = 3
      elseif byte >= 0xC0 then
        char_len = 2
      else
        return false
      end

      for j = 1, char_len - 1 do
        if i + j > #str then
          return false
        end
        local cont_byte = str:byte(i + j)
        if cont_byte < 0x80 or cont_byte >= 0xC0 then
          return false
        end
      end
    end

    i = i + char_len
  end

  return true
end

--- Convert a 16-bit number to big-endian bytes
--- @param num number Number to convert
--- @return string Big-endian byte string
function M.uint16_to_bytes(num)
  return string.char(math.floor(num / 256), num % 256)
end

--- Convert a 64-bit number to big-endian bytes
--- @param num number Number to convert
--- @return string Big-endian byte string
function M.uint64_to_bytes(num)
  local bytes = {}
  for i = 8, 1, -1 do
    bytes[i] = num % 256
    num = math.floor(num / 256)
  end
  return string.char(unpack(bytes))
end

--- Convert big-endian bytes to a 16-bit number
--- @param bytes string Byte string (2 bytes)
--- @return number Converted number
function M.bytes_to_uint16(bytes)
  if #bytes < 2 then
    return 0
  end
  return bytes:byte(1) * 256 + bytes:byte(2)
end

--- Convert big-endian bytes to a 64-bit number
--- @param bytes string Byte string (8 bytes)
--- @return number Converted number
function M.bytes_to_uint64(bytes)
  if #bytes < 8 then
    return 0
  end

  local num = 0
  for i = 1, 8 do
    num = num * 256 + bytes:byte(i)
  end
  return num
end

-- XOR lookup table for faster operations
local xor_table = {}
for i = 0, 255 do
  xor_table[i] = {}
  for j = 0, 255 do
    local result = 0
    local a, b = i, j
    local bit_val = 1

    while a > 0 or b > 0 do
      local a_bit = a % 2
      local b_bit = b % 2

      if a_bit ~= b_bit then
        result = result + bit_val
      end

      a = math.floor(a / 2)
      b = math.floor(b / 2)
      bit_val = bit_val * 2
    end

    xor_table[i][j] = result
  end
end

--- Apply XOR mask to payload data
--- @param data string Data to mask/unmask
--- @param mask string 4-byte mask
--- @return string Masked/unmasked data
function M.apply_mask(data, mask)
  local result = {}
  local mask_bytes = { mask:byte(1, 4) }

  for i = 1, #data do
    local mask_idx = ((i - 1) % 4) + 1
    local data_byte = data:byte(i)
    result[i] = string.char(xor_table[data_byte][mask_bytes[mask_idx]])
  end

  return table.concat(result)
end

--- Shuffle an array in place using Fisher-Yates algorithm
--- @param tbl table Array to shuffle
function M.shuffle_array(tbl)
  math.randomseed(os.time())
  for i = #tbl, 2, -1 do
    local j = math.random(i)
    tbl[i], tbl[j] = tbl[j], tbl[i]
  end
end

--- Generate a random WebSocket key
--- @return string Base64 encoded 16-byte random nonce
function M.generate_websocket_key()
  local random_bytes = {}
  for _ = 1, 16 do
    random_bytes[#random_bytes + 1] = string.char(math.random(0, 255))
  end
  return M.base64_encode(table.concat(random_bytes))
end

return M
