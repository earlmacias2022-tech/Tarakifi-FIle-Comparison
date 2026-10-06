--- Minimal JSON encoder/decoder for TarakiFi
-- Pure Lua implementation — no external dependencies.
-- Handles: strings, numbers, booleans, nil, tables (arrays and objects).

local M = {}

-- ─── Encoder ────────────────────────────────────────────────────────────────

local encode_value  -- forward declaration

local escape_chars = {
  ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n",
  ["\r"] = "\\r", ["\t"] = "\\t", ["\b"] = "\\b", ["\f"] = "\\f"
}

local function encode_string(s)
  return '"' .. s:gsub('[\\"\n\r\t\b\f]', escape_chars) .. '"'
end

local function is_array(t)
  local i = 0
  for _ in pairs(t) do
    i = i + 1
    if t[i] == nil then return false end
  end
  return true
end

local function encode_table(t)
  if is_array(t) then
    local parts = {}
    for i, v in ipairs(t) do
      parts[i] = encode_value(v)
    end
    return "[" .. table.concat(parts, ",") .. "]"
  else
    local parts = {}
    for k, v in pairs(t) do
      if type(k) == "string" then
        parts[#parts + 1] = encode_string(k) .. ":" .. encode_value(v)
      end
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
end

encode_value = function(v)
  local t = type(v)
  if t == "string" then return encode_string(v)
  elseif t == "number" then
    if v ~= v then return "null" end  -- NaN
    if v == math.huge or v == -math.huge then return "null" end
    if v == math.floor(v) and v >= -2^53 and v <= 2^53 then
      return string.format("%d", v)
    end
    return string.format("%.14g", v)
  elseif t == "boolean" then return v and "true" or "false"
  elseif t == "table" then return encode_table(v)
  else return "null"
  end
end

function M.encode(value)
  return encode_value(value)
end

-- ─── Decoder ────────────────────────────────────────────────────────────────

local decode_value  -- forward declaration

local function skip_whitespace(s, pos)
  return s:find("[^ \t\r\n]", pos) or #s + 1
end

local escape_map = {
  ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
  ['b'] = '\b', ['f'] = '\f', ['n'] = '\n', ['r'] = '\r', ['t'] = '\t'
}

local function decode_string(s, pos)
  local start = pos + 1  -- skip opening quote
  local parts = {}
  local i = start
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then
      parts[#parts + 1] = s:sub(start, i - 1)
      return table.concat(parts), i + 1
    elseif c == '\\' then
      parts[#parts + 1] = s:sub(start, i - 1)
      i = i + 1
      local esc = s:sub(i, i)
      if esc == 'u' then
        local hex = s:sub(i + 1, i + 4)
        local code = tonumber(hex, 16)
        if code then
          if code < 128 then
            parts[#parts + 1] = string.char(code)
          else
            parts[#parts + 1] = "?"  -- simplified UTF-8
          end
        end
        i = i + 5
      else
        parts[#parts + 1] = escape_map[esc] or esc
        i = i + 1
      end
      start = i
    else
      i = i + 1
    end
  end
  error("unterminated string")
end

local function decode_number(s, pos)
  local num_str = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
  return tonumber(num_str), pos + #num_str
end

local function decode_array(s, pos)
  local arr = {}
  pos = skip_whitespace(s, pos + 1)  -- skip [
  if s:sub(pos, pos) == ']' then return arr, pos + 1 end
  
  while true do
    local val
    val, pos = decode_value(s, pos)
    arr[#arr + 1] = val
    pos = skip_whitespace(s, pos)
    local c = s:sub(pos, pos)
    if c == ']' then return arr, pos + 1 end
    if c ~= ',' then error("expected ',' or ']' at pos " .. pos) end
    pos = skip_whitespace(s, pos + 1)
  end
end

local function decode_object(s, pos)
  local obj = {}
  pos = skip_whitespace(s, pos + 1)  -- skip {
  if s:sub(pos, pos) == '}' then return obj, pos + 1 end
  
  while true do
    -- Key
    if s:sub(pos, pos) ~= '"' then error("expected string key at pos " .. pos) end
    local key
    key, pos = decode_string(s, pos)
    pos = skip_whitespace(s, pos)
    if s:sub(pos, pos) ~= ':' then error("expected ':' at pos " .. pos) end
    pos = skip_whitespace(s, pos + 1)
    -- Value
    local val
    val, pos = decode_value(s, pos)
    obj[key] = val
    pos = skip_whitespace(s, pos)
    local c = s:sub(pos, pos)
    if c == '}' then return obj, pos + 1 end
    if c ~= ',' then error("expected ',' or '}' at pos " .. pos) end
    pos = skip_whitespace(s, pos + 1)
  end
end

decode_value = function(s, pos)
  pos = skip_whitespace(s, pos)
  local c = s:sub(pos, pos)
  
  if c == '"' then return decode_string(s, pos)
  elseif c == '{' then return decode_object(s, pos)
  elseif c == '[' then return decode_array(s, pos)
  elseif c == 't' then return true, pos + 4
  elseif c == 'f' then return false, pos + 5
  elseif c == 'n' then return nil, pos + 4
  elseif c == '-' or (c >= '0' and c <= '9') then return decode_number(s, pos)
  else error("unexpected character '" .. c .. "' at pos " .. pos)
  end
end

function M.decode(s)
  if type(s) ~= "string" then return nil end
  local ok, result, pos = pcall(decode_value, s, 1)
  if ok then return result end
  return nil, result  -- return nil + error message
end

return M
