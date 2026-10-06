--- TarakiFi OTA stub for low-flash Comfast routers.
-- This router has extremely limited writable flash, so firmware self-updates
-- are intentionally disabled. Support-assisted sysupgrade remains available
-- outside the router UI.
local M = {}

local VERSION_FILE = os.getenv("TARAKIFI_VERSION_FILE") or "/etc/tarakifi/version"
local DISABLED_REASON = "disabled_on_comfast"

function M.get_current_version()
  local file = io.open(VERSION_FILE, "r")
  if file then
    local version = (file:read("*l") or ""):gsub("%s+", "")
    file:close()
    if version ~= "" then return version end
  end
  return "0.0.0"
end

function M.check()
  return nil, DISABLED_REASON
end

function M.check_only()
  return nil, DISABLED_REASON
end

function M.check_and_apply()
  return DISABLED_REASON
end

return M
