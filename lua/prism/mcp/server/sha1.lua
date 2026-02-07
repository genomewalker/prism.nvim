--- Pure Lua SHA-1 implementation
--- Used for WebSocket handshake Sec-WebSocket-Accept calculation
--- @module prism.mcp.server.sha1

local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift = bit.lshift, bit.rshift

local M = {}

-- Pre-computed constants
local K = {
  0x5A827999,
  0x6ED9EBA1,
  0x8F1BBCDC,
  0xCA62C1D6,
}

--- Rotate left
--- @param x number
--- @param n number
--- @return number
local function rotl(x, n)
  return band(bor(lshift(x, n), rshift(x, 32 - n)), 0xFFFFFFFF)
end

--- Convert string to array of 32-bit big-endian words
--- @param str string
--- @return number[]
local function str_to_words(str)
  local words = {}
  local len = #str

  for i = 1, len, 4 do
    local b1 = str:byte(i) or 0
    local b2 = str:byte(i + 1) or 0
    local b3 = str:byte(i + 2) or 0
    local b4 = str:byte(i + 3) or 0
    words[#words + 1] = bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
  end

  return words
end

--- Convert 32-bit word to 4 bytes (big-endian)
--- @param word number
--- @return string
local function word_to_bytes(word)
  return string.char(
    band(rshift(word, 24), 0xFF),
    band(rshift(word, 16), 0xFF),
    band(rshift(word, 8), 0xFF),
    band(word, 0xFF)
  )
end

--- Pad message according to SHA-1 spec
--- @param msg string
--- @return string
local function pad_message(msg)
  local len = #msg
  local bit_len = len * 8

  -- Append 0x80
  msg = msg .. "\x80"

  -- Pad with zeros until length is 56 mod 64
  local pad_len = (56 - (#msg % 64)) % 64
  msg = msg .. string.rep("\0", pad_len)

  -- Append original length as 64-bit big-endian
  msg = msg .. string.char(
    0, 0, 0, 0, -- High 32 bits (always 0 for messages < 2^32 bits)
    band(rshift(bit_len, 24), 0xFF),
    band(rshift(bit_len, 16), 0xFF),
    band(rshift(bit_len, 8), 0xFF),
    band(bit_len, 0xFF)
  )

  return msg
end

--- Process a 512-bit block
--- @param block string 64-byte block
--- @param h table Current hash state
local function process_block(block, h)
  local w = str_to_words(block)

  -- Extend 16 words to 80 words
  for i = 17, 80 do
    w[i] = rotl(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
  end

  -- Initialize working variables
  local a, b, c, d, e = h[1], h[2], h[3], h[4], h[5]

  -- Main loop
  for i = 1, 80 do
    local f, k

    if i <= 20 then
      f = bor(band(b, c), band(bnot(b), d))
      k = K[1]
    elseif i <= 40 then
      f = bxor(b, c, d)
      k = K[2]
    elseif i <= 60 then
      f = bor(band(b, c), band(b, d), band(c, d))
      k = K[3]
    else
      f = bxor(b, c, d)
      k = K[4]
    end

    local temp = band(rotl(a, 5) + f + e + k + w[i], 0xFFFFFFFF)
    e = d
    d = c
    c = rotl(b, 30)
    b = a
    a = temp
  end

  -- Add to hash
  h[1] = band(h[1] + a, 0xFFFFFFFF)
  h[2] = band(h[2] + b, 0xFFFFFFFF)
  h[3] = band(h[3] + c, 0xFFFFFFFF)
  h[4] = band(h[4] + d, 0xFFFFFFFF)
  h[5] = band(h[5] + e, 0xFFFFFFFF)
end

--- Compute SHA-1 hash
--- @param msg string Input message
--- @return string 20-byte hash (binary)
function M.sha1(msg)
  -- Initial hash values
  local h = {
    0x67452301,
    0xEFCDAB89,
    0x98BADCFE,
    0x10325476,
    0xC3D2E1F0,
  }

  -- Pad message
  msg = pad_message(msg)

  -- Process each 64-byte block
  for i = 1, #msg, 64 do
    process_block(msg:sub(i, i + 63), h)
  end

  -- Produce final hash
  return word_to_bytes(h[1])
    .. word_to_bytes(h[2])
    .. word_to_bytes(h[3])
    .. word_to_bytes(h[4])
    .. word_to_bytes(h[5])
end

--- Compute SHA-1 hash and return as hex string
--- @param msg string Input message
--- @return string 40-character hex string
function M.sha1_hex(msg)
  local hash = M.sha1(msg)
  local hex = {}
  for i = 1, #hash do
    hex[i] = string.format("%02x", hash:byte(i))
  end
  return table.concat(hex)
end

--- Base64 encode
--- @param data string Binary data
--- @return string Base64 encoded string
function M.base64_encode(data)
  local b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local result = {}

  local i = 1
  while i <= #data do
    local b1 = data:byte(i) or 0
    local b2 = data:byte(i + 1) or 0
    local b3 = data:byte(i + 2) or 0

    local n = bor(lshift(b1, 16), lshift(b2, 8), b3)

    result[#result + 1] = b64:sub(band(rshift(n, 18), 63) + 1, band(rshift(n, 18), 63) + 1)
    result[#result + 1] = b64:sub(band(rshift(n, 12), 63) + 1, band(rshift(n, 12), 63) + 1)

    if i + 1 <= #data then
      result[#result + 1] = b64:sub(band(rshift(n, 6), 63) + 1, band(rshift(n, 6), 63) + 1)
    else
      result[#result + 1] = "="
    end

    if i + 2 <= #data then
      result[#result + 1] = b64:sub(band(n, 63) + 1, band(n, 63) + 1)
    else
      result[#result + 1] = "="
    end

    i = i + 3
  end

  return table.concat(result)
end

--- Compute WebSocket accept key from client key
--- @param client_key string The Sec-WebSocket-Key from client
--- @return string The Sec-WebSocket-Accept value
function M.websocket_accept(client_key)
  local GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  local hash = M.sha1(client_key .. GUID)
  return M.base64_encode(hash)
end

return M
