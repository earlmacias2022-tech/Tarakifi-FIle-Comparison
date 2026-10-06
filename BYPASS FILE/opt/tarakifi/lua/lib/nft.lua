--- TarakiFi nftables Helper
-- Wrapper around the tarakifi-nft C binary for fast MAC set operations.
-- Falls back to nft CLI if binary is not available.

local M = {}

local NFT_BIN = "/opt/tarakifi/bin/tarakifi-nft"
local USE_BINARY = true

local function command_succeeded(command)
  local status, _, code = os.execute(command)
  if type(status) == "number" then return status == 0 end
  return status == true and (code == nil or code == 0)
end

-- Check if binary exists on first load
local f = io.open(NFT_BIN, "r")
if f then
  f:close()
else
  USE_BINARY = false
end

--- Add MAC to allowed set
function M.allow(mac)
  mac = mac:lower()
  if USE_BINARY then
    os.execute(NFT_BIN .. " add " .. mac)
  else
    os.execute("nft add element inet tarakifi allowed_macs { " .. mac .. " }")
  end
end

--- Remove MAC from allowed set
function M.deny(mac)
  mac = mac:lower()
  if USE_BINARY then
    os.execute(NFT_BIN .. " del " .. mac)
  else
    os.execute("nft delete element inet tarakifi allowed_macs { " .. mac .. " }")
  end
end

--- Check if MAC is in allowed set
function M.check(mac)
  mac = mac:lower()
  if USE_BINARY then
    local handle = io.popen(NFT_BIN .. " check " .. mac)
    local result = handle:read("*a")
    handle:close()
    return result:match("allowed") ~= nil
  else
    local handle = io.popen("nft list set inet tarakifi allowed_macs 2>/dev/null")
    local result = handle:read("*a")
    handle:close()
    return result:lower():find(mac) ~= nil
  end
end

--- Add MAC to rental set
function M.allow_rental(mac)
  mac = mac:lower()
  os.execute("nft add element inet tarakifi rental_macs { " .. mac .. " }")
end

--- Remove MAC from rental set
function M.deny_rental(mac)
  mac = mac:lower()
  os.execute("nft delete element inet tarakifi rental_macs { " .. mac .. " }")
end

--- Flush all allowed MACs (emergency)
function M.flush_allowed()
  os.execute("nft flush set inet tarakifi allowed_macs")
end

--- Flush all rental MACs
function M.flush_rental()
  os.execute("nft flush set inet tarakifi rental_macs")
end

function M.session_set_ready()
  return command_succeeded("nft list set inet tarakifi allowed_macs >/dev/null 2>&1")
end

--- List all currently allowed MACs
function M.list_allowed()
  local handle = io.popen("nft list set inet tarakifi allowed_macs 2>/dev/null")
  local result = handle:read("*a")
  handle:close()
  
  local macs = {}
  for mac in result:gmatch("(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)") do
    macs[#macs + 1] = mac:upper()
  end
  return macs
end

return M
