--- KemoFi OTA availability checker for OpenWrt.
-- Background work is intentionally check-only. Firmware is downloaded and
-- installed only through the authenticated admin update endpoint.
local LUA_ROOT = os.getenv("KEMOFI_LUA_ROOT") or "/opt/kemofi/lua"
package.path = LUA_ROOT .. "/?.lua;" .. LUA_ROOT .. "/lib/?.lua;" .. package.path

local db = require("lib.db")
local json = require("lib.json")

local M = {}

local OTA_URL = os.getenv("KEMOFI_OTA_URL") or
  "https://kemofi.com/api/public-download-link"
local UCLIENT_BIN = os.getenv("KEMOFI_UCLIENT_BIN") or "/bin/uclient-fetch"
local CHECK_PATH = os.getenv("KEMOFI_OTA_CHECK_PATH") or
  "/tmp/kemofi_ota_check.json"
local VERSION_FILE = os.getenv("KEMOFI_VERSION_FILE") or "/etc/kemofi/version"
local BOARD_NAME_FILE = os.getenv("KEMOFI_BOARD_NAME_FILE") or
  "/tmp/sysinfo/board_name"

local function log(message)
  io.stdout:write(os.date("[%H:%M:%S] ") .. "OTA: " .. tostring(message) .. "\n")
  io.stdout:flush()
end

local function trim(value)
  local trimmed = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return trimmed
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function read_first_line(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local value = trim(file:read("*l") or "")
  file:close()
  if value == "" then return nil end
  return value
end

local function read_board_name()
  local board_name = read_first_line(BOARD_NAME_FILE)
  if not board_name or #board_name > 128 or
      not board_name:match("^[%w%._,%-]+$") then
    return nil
  end
  return board_name
end

local function append_query(url, key, value)
  local separator = url:find("?", 1, true) and "&" or "?"
  return url .. separator .. key .. "=" .. value
end

function M.get_current_version()
  local version = read_first_line(VERSION_FILE)
  if version and #version <= 64 and
      version:match("^%d+%.%d+%.%d+[%w%.%-]*$") then
    return version
  end
  return "0.0.0"
end

local function parse_version(version)
  local major, minor, patch = tostring(version or ""):match("^(%d+)%.(%d+)%.(%d+)")
  return tonumber(major), tonumber(minor), tonumber(patch)
end

local function is_newer(current, candidate)
  local current_major, current_minor, current_patch = parse_version(current)
  local next_major, next_minor, next_patch = parse_version(candidate)
  if not current_major or not next_major then return false end
  if next_major ~= current_major then return next_major > current_major end
  if next_minor ~= current_minor then return next_minor > current_minor end
  return next_patch > current_patch
end

local function fetch_manifest(url)
  os.remove(CHECK_PATH)
  local command = table.concat({
    shell_quote(UCLIENT_BIN),
    "--timeout=15",
    "-q -O", shell_quote(CHECK_PATH), shell_quote(url),
    "2>/dev/null; printf '%s' $?"
  }, " ")

  local process = io.popen(command)
  if not process then return nil, "cannot start update check" end
  local exit_code = tonumber(trim(process:read("*a") or "")) or 1
  process:close()
  if exit_code ~= 0 then
    os.remove(CHECK_PATH)
    return nil, "update server request failed"
  end

  local file = io.open(CHECK_PATH, "r")
  if not file then return nil, "cannot read update response" end
  local body = file:read("*a") or ""
  file:close()
  os.remove(CHECK_PATH)

  local decoded, manifest = pcall(json.decode, body)
  if not decoded or type(manifest) ~= "table" then
    return nil, "invalid update response"
  end
  return manifest
end

--- Check the board-specific vendor manifest without downloading firmware.
function M.check()
  local current_version = M.get_current_version()
  local check_url = append_query(OTA_URL, "current_version", current_version)
  local board_name = read_board_name()
  if board_name then check_url = append_query(check_url, "board", board_name) end

  local manifest, fetch_error = fetch_manifest(check_url)
  if not manifest then return nil, fetch_error end
  if manifest.update_available ~= true then return nil end

  local version = trim(manifest.version)
  if not is_newer(current_version, version) then return nil end

  return {
    version = version,
    notes = tostring(manifest.notes or ""),
  }
end

local function store_available_update(version, notes)
  return db.set_settings_atomic({
    {key = "_ota_available_version", value = version},
    {key = "_ota_available_notes", value = notes},
  })
end

--- Record update availability for the admin UI. Never downloads or installs.
-- Returns: "available", "up_to_date", or "error".
function M.check_only()
  log("Checking for updates (current: " .. M.get_current_version() .. ")")
  local update, check_error = M.check()
  if not update then
    if check_error then
      log("Check failed: " .. tostring(check_error))
      return "error", check_error
    end
    local saved, save_error = store_available_update("", "")
    if not saved then
      log("Could not store update status: " .. tostring(save_error))
      return "error", save_error
    end
    log("No update available")
    return "up_to_date"
  end

  local saved, save_error = store_available_update(update.version, update.notes)
  if not saved then
    log("Could not store update status: " .. tostring(save_error))
    return "error", save_error
  end

  log("Update available: v" .. update.version .. "; operator approval required")
  return "available", update
end

return M
