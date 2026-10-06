--- TarakiFi Utility Functions
local M = {}

--- Normalize a voucher code for storage and redemption.
--- Spaces and hyphens are presentation separators, not part of the code.
function M.normalize_voucher_code(value)
  local code = tostring(value or ""):upper():gsub("[%s%-]", "")
  if code == "" then return nil, "empty_code" end
  if not code:match("^[A-Z0-9]+$") then return nil, "invalid_code" end
  return code
end

--- Generate an unbiased random string from /dev/urandom.
function M.random_string(alphabet, length)
  alphabet = tostring(alphabet or "")
  length = math.floor(tonumber(length) or 0)
  if #alphabet < 2 or #alphabet > 256 or length < 1 then
    return nil, "invalid_random_string_options"
  end

  local random = io.open("/dev/urandom", "rb")
  if not random then return nil, "secure_random_unavailable" end

  local output = {}
  local accepted_limit = 256 - (256 % #alphabet)
  while #output < length do
    local needed = length - #output
    local bytes = random:read(math.max(16, needed * 2))
    if not bytes or #bytes == 0 then break end
    for i = 1, #bytes do
      local byte = bytes:byte(i)
      if byte < accepted_limit then
        local index = (byte % #alphabet) + 1
        output[#output + 1] = alphabet:sub(index, index)
        if #output == length then break end
      end
    end
  end
  random:close()

  if #output ~= length then return nil, "secure_random_read_failed" end
  return table.concat(output)
end

--- Simple hash function (for tokens, not cryptographic)
function M.sha256(input)
  -- Use OpenSSL if available, otherwise fallback to simple hash
  local h = io.popen("echo -n '" .. input:gsub("'", "'\\''") .. "' | sha256sum 2>/dev/null | cut -d' ' -f1")
  if h then
    local result = (h:read("*a") or ""):gsub("%s+", "")
    h:close()
    if result ~= "" then return result end
  end
  -- Fallback: simple hash
  local hash = 0
  for i = 1, #input do
    hash = ((hash * 31) + input:byte(i)) % 0xFFFFFFFF
  end
  return string.format("%08x%08x%08x%08x", hash, hash * 7, hash * 13, hash * 17)
end

--- Generate a random token
function M.random_token(length)
  length = length or 32
  local chars = "abcdefghijklmnopqrstuvwxyz0123456789"
  local token = ""
  local f = io.open("/dev/urandom", "rb")
  if f then
    local bytes = f:read(length)
    f:close()
    for i = 1, #bytes do
      local idx = (bytes:byte(i) % #chars) + 1
      token = token .. chars:sub(idx, idx)
    end
  else
    math.randomseed(os.time() + os.clock() * 1000)
    for i = 1, length do
      local idx = math.random(1, #chars)
      token = token .. chars:sub(idx, idx)
    end
  end
  return token
end

--- Read the canonical WAN result maintained by the supervised timer.
function M.read_wan_status(now)
  local path = os.getenv("TARAKIFI_WAN_STATUS_PATH") or "/tmp/tarakifi/wan.status"
  local max_age = tonumber(os.getenv("TARAKIFI_WAN_STATUS_MAX_AGE")) or 75
  local file = io.open(path, "r")
  if not file then return false end
  local value = file:read("*l") or ""
  file:close()
  local checked_at, result = value:match("^(%d+)|([01])$")
  checked_at = tonumber(checked_at) or 0
  local age = (now or os.time()) - checked_at
  return result == "1" and age >= 0 and age <= max_age
end

return M
