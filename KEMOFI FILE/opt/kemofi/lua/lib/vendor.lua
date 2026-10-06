--- KemoFi Vendor Phone-Home Client
-- Periodically validates the license with the vendor platform (kemofi.com)
-- and syncs daily earnings data.
--
-- Called from timer.lua every ~6 hours (every 2160th tick of the 10s timer).
-- Also called on first boot and after license activation.
--
-- Usage: require("lib.vendor").phone_home()

local db = require("lib.db")
local json = require("lib.json")
local util = require("lib.util")

local M = {}

-- ─── Configuration ─────────────────────────────────────────────────────────────

-- KemoFi backend uses /router-api/<action>/<bind_code> GET requests
-- authenticated by X-License-Key header. Keep this aligned with the
-- reference PisoWifi router client; the retired legacy license routes are not
-- part of the KemoFi license-manager protocol.
local ROUTER_API_BASE = "https://kemofi.com"
local LICENSE_MANAGER_URL_FILE = os.getenv("KEMOFI_LICENSE_MANAGER_URL_FILE") or
  "/etc/pisowifi/license_manager_url"
local BIND_CODE_FILE = os.getenv("KEMOFI_BIND_CODE_FILE") or
  "/etc/pisowifi/data/bindcode"
local EDITION_FILE = os.getenv("KEMOFI_EDITION_FILE") or "/etc/pisowifi/edition"
local LEGACY_LICENSE_MANAGER_URL_FILE = "/etc/kemofi/license_manager_url"
local LEGACY_BIND_CODE_FILE = "/etc/kemofi/bindcode"
local LEGACY_EDITION_FILE = "/etc/kemofi/edition"
-- Retain the legacy URL identifiers used by the existing call sites. The
-- request adapter below maps these identifiers to the configured KemoFi API.
local VENDOR_URL = "license_status"
local TRIAL_URL = "license_status"
local FETCH_URL = "license_activate"
local RECOVER_URL = "license_status"
local DEVICE_TREE_SERIAL_PATH = os.getenv("KEMOFI_DEVICE_TREE_SERIAL_PATH") or
  "/proc/device-tree/serial-number"
local CPUINFO_PATH = os.getenv("KEMOFI_CPUINFO_PATH") or "/proc/cpuinfo"
local ETH0_MAC_PATH = os.getenv("KEMOFI_ETH0_MAC_PATH") or
  "/sys/class/net/eth0/address"
local BR_LAN_MAC_PATH = os.getenv("KEMOFI_BR_LAN_MAC_PATH") or
  "/sys/class/net/br-lan/address"
local DEVICE_ID_PATH = os.getenv("KEMOFI_DEVICE_ID_PATH") or
  "/etc/kemofi/device_id"
local PROC_MTD_PATH = os.getenv("KEMOFI_PROC_MTD_PATH") or "/proc/mtd"
local MTD_BLOCK_PREFIX = os.getenv("KEMOFI_MTD_BLOCK_PREFIX") or "/dev/mtdblock"
local MAC_RETRY_ATTEMPTS = tonumber(os.getenv("KEMOFI_MAC_RETRY_ATTEMPTS") or "5") or 5
MAC_RETRY_ATTEMPTS = math.max(1, math.min(10, math.floor(MAC_RETRY_ATTEMPTS)))
local GRACE_PERIOD_SECONDS = 7 * 24 * 3600  -- 7 days offline grace

local function trim_text(value)
  if type(value) ~= "string" then return "" end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.trial_is_expired(settings)
  settings = settings or {}
  local license_status = trim_text(settings.license_status or db.setting("license_status") or "trial")
  if license_status == "trial_expired" or license_status == "expired" then return true end
  if license_status ~= "trial" then return false end

  local expires_at = trim_text(settings._trial_expires_at or db.setting("_trial_expires_at") or "")
  local numeric_expires_at = tonumber(expires_at)
  if numeric_expires_at and numeric_expires_at > 0 then
    return os.time() >= numeric_expires_at
  end

  expires_at = expires_at:gsub("(%d%d:%d%d:%d%d)%.%d+Z$", "%1Z")
  if expires_at:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") then
    return expires_at <= os.date("!%Y-%m-%dT%H:%M:%SZ")
  end

  local trial_started_at = tonumber(
    settings.trial_started_at or db.setting("trial_started_at") or "0"
  ) or 0
  return trial_started_at > 0 and (os.time() - trial_started_at) >= 86400
end

--- Customer internet is available only to a full active license or a live trial.
--- Every other state is intentionally fail-closed.
function M.customer_access_allowed(settings)
  settings = settings or {}
  local license_status = trim_text(settings.license_status or db.setting("license_status") or "trial")
  if license_status == "active" then return true, license_status end
  if license_status == "trial" and not M.trial_is_expired(settings) then
    return true, license_status
  end
  return false, license_status
end

local function read_trimmed_file(path)
  local file = io.open(path, "r")
  if not file then return "" end
  local value = trim_text(file:read("*l") or "")
  file:close()
  return value
end

local function normalize_board_model(value)
  local model = trim_text(value):lower():gsub(",", "-"):gsub("_", "-"):gsub("%s+", "-")
  model = model:gsub("[^a-z0-9._-]", "-"):gsub("-+", "-")
    :gsub("^-+", ""):gsub("-+$", "")
  return model
end

local function license_result(resp)
  if type(resp) ~= "table" then return "" end
  if resp.valid == true or resp.ok == true or resp.success == true or resp.active == true then
    return "ok"
  end
  local result = trim_text(tostring(
    resp.result or resp.reason or resp.error or resp.status or ""
  )):lower()
  if result == "" then
    if resp.valid == true or resp.ok == true or resp.success == true or resp.active == true then
      result = "ok"
    elseif resp.valid == false or resp.ok == false or resp.success == false or resp.active == false then
      result = trim_text(tostring(resp.reason or resp.error or resp.message or "failed"))
    end
  end
  if result == "valid" or result == "active" or result == "success" then
    return "ok"
  end
  local aliases = {
    license_expired = "expired",
    license_revoked = "revoked",
    license_not_found = "not_found",
    already_trialed = "trial_expired",
    device_already_trialed = "trial_expired",
  }
  return aliases[result] or result
end

local function response_license_key(resp)
  if type(resp) ~= "table" then return "" end
  local nested = type(resp.license) == "table" and resp.license or {}
  local signed = M.signed_payload_data(resp) or {}
  return trim_text(tostring(
    resp.license_key or resp.license_id or resp.key or
    nested.license_key or nested.license_id or nested.key or
    signed.license_key or signed.license_id or signed.key or ""
  ))
end

local function response_trial_expires_at(resp)
  if type(resp) ~= "table" then return "" end
  local nested = type(resp.license) == "table" and resp.license or {}
  local signed = M.signed_payload_data(resp) or {}
  return trim_text(tostring(
    resp.expires_at or resp.trial_expires_at or
    nested.expires_at or nested.trial_expires_at or
    signed.expires_at or signed.trial_expires_at or ""
  ))
end

local function is_trial_response(resp, _license_key)
  if type(resp) ~= "table" then return false end
  if resp.is_trial == true or resp.trial == true then return true end

  local flag = trim_text(tostring(resp.is_trial or resp.trial or resp.license_type or resp.type or ""))
    :lower()
  if flag == "true" or flag == "1" or flag == "trial" then return true end

  local signed = M.signed_payload_data(resp)
  if type(signed) == "table" then
    if signed.is_trial == true or signed.trial == true then return true end
    if signed.is_trial == false or signed.trial == false then return false end
    local signed_flag = trim_text(tostring(
      signed.is_trial or signed.trial or signed.license_type or signed.type or ""
    )):lower()
    if signed_flag == "true" or signed_flag == "1" or signed_flag == "trial" then
      return true
    end
  end

  if resp.is_trial == false or resp.trial == false then return false end

  if response_trial_expires_at(resp) ~= "" then return true end

  local key = trim_text(_license_key or "")
  local trial_key = trim_text(db.setting("_trial_license_key") or "")
  if key ~= "" and trial_key ~= "" and key == trial_key then return true end
  return false
end

local function result_message(result, resp, fallback)
  if result == "expired" then return "License expired." end
  if result == "revoked" then return "License revoked." end
  if result == "device_mismatch" then
    return "This license is already active on another device."
  end
  if result == "not_found" then return "License not found." end
  if type(resp) == "table" then
    local message = trim_text(tostring(resp.message or resp.error or ""))
    if message ~= "" and #message <= 200 and not message:find("[%z\1-\31]") then
      return message
    end
  end
  return fallback or "Activation failed. Check the license key and try again."
end

local function vendor_http_message(status)
  if status == 404 then
    return "License service is unavailable. Please try again later."
  end
  if status == 403 then
    return "This license cannot be activated on this router."
  end
  if status and status >= 500 then
    return "License service is temporarily unavailable. Please try again later."
  end
  return "Activation failed. Check the license key and try again."
end

local function activation_network_error(stage, detail)
  local private_detail = trim_text(tostring(detail or "unknown error"):gsub("%s+", " "))
  io.write(os.date("[%H:%M:%S] ") .. "Vendor: activation " .. stage ..
    " failed: " .. private_detail .. "\n")
  return "Unable to contact the license service. Check the router's internet connection and try again."
end

local function base64_decode(value)
  value = trim_text(value or "")
  if value == "" then return "" end
  local ok, nixio = pcall(require, "nixio")
  if ok and nixio and nixio.bin and nixio.bin.b64decode then
    local decoded_ok, decoded = pcall(nixio.bin.b64decode, value)
    if decoded_ok and decoded then return decoded end
  end
  if not value:match("^[A-Za-z0-9+/=]+$") then return "" end
  local handle = io.popen("printf '%s' '" .. value .. "' | base64 -d 2>/dev/null")
  if not handle then return "" end
  local decoded = handle:read("*a") or ""
  handle:close()
  return decoded
end

function M.signed_payload_data(resp)
  if type(resp) ~= "table" then return nil end
  local signed = type(resp.signed_payload) == "table" and resp.signed_payload or {}
  local payload_b64 = trim_text(tostring(resp.payload_b64 or signed.payload_b64 or ""))
  if payload_b64 == "" then return nil end
  local decoded = base64_decode(payload_b64)
  if decoded == "" then return nil end
  local ok, payload = pcall(json.decode, decoded)
  if ok and type(payload) == "table" then return payload end
  return nil
end

local function is_valid_response(resp)
  if type(resp) ~= "table" then return false end
  if resp.valid == true or resp.ok == true or resp.success == true or resp.active == true then return true end
  local signed = M.signed_payload_data(resp)
  return type(signed) == "table" and signed.valid == true
end

local function add_id(set, value)
  value = trim_text(tostring(value or "")):lower()
  if value ~= "" then set[value] = true end
end

local function collect_bound_ids_from(fields, source, output)
  if type(source) ~= "table" then return end
  for _, field in ipairs(fields) do
    add_id(output, source[field])
  end
end

local TOP_LEVEL_BOUND_DEVICE_FIELDS = {
  "bound_device_id",
  "bound_instance_device_id",
  "assigned_device_id",
  "assigned_instance_device_id",
  "registered_device_id",
  "registered_instance_device_id",
  "license_device_id",
  "license_instance_device_id",
}

local NESTED_BOUND_DEVICE_FIELDS = {
  "device_id",
  "instance_device_id",
  "hardware_device_id",
  "hashed_device_id",
  "legacy_device_id",
  "legacy_instance_device_id",
  "bound_device_id",
  "bound_instance_device_id",
  "assigned_device_id",
  "registered_device_id",
  "license_device_id",
  "license_instance_device_id",
}

local function response_bound_device_ids(resp)
  local ids = {}
  collect_bound_ids_from(TOP_LEVEL_BOUND_DEVICE_FIELDS, resp, ids)
  for _, field in ipairs({"license", "binding", "device_binding", "license_binding"}) do
    collect_bound_ids_from(NESTED_BOUND_DEVICE_FIELDS, type(resp) == "table" and resp[field] or nil, ids)
  end

  local signed = M.signed_payload_data(resp)
  collect_bound_ids_from(NESTED_BOUND_DEVICE_FIELDS, signed, ids)
  if type(signed) == "table" then
    for _, field in ipairs({"license", "binding", "device_binding", "license_binding"}) do
      collect_bound_ids_from(NESTED_BOUND_DEVICE_FIELDS, signed[field], ids)
    end
  end
  return ids
end

local function recovery_response_matches_device(resp, device_id, candidate_id)
  local expected = {}
  add_id(expected, device_id)
  add_id(expected, candidate_id)
  add_id(expected, M.get_legacy_device_id())

  local saw_bound_id = false
  for id in pairs(response_bound_device_ids(resp)) do
    saw_bound_id = true
    if expected[id] then return true end
  end
  return not saw_bound_id
end

-- ─── Device ID ─────────────────────────────────────────────────────────────────

local function read_file_all(path)
  local file = io.open(path, "r")
  if not file then return "" end
  local value = file:read("*a") or ""
  file:close()
  return value
end

local function read_identifier_file(path)
  return trim_text(read_file_all(path):gsub("%z", ""):gsub("%s+", " "))
end

local function normalize_mac(value)
  local raw = trim_text(value):lower():gsub("-", ":")
  local compact = raw:gsub(":", "")
  if #compact == 12 and compact:match("^%x+$") then
    raw = table.concat({
      compact:sub(1, 2), compact:sub(3, 4), compact:sub(5, 6),
      compact:sub(7, 8), compact:sub(9, 10), compact:sub(11, 12),
    }, ":")
  end
  if not raw:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then return "" end
  if raw == "00:00:00:00:00:00" or raw == "ff:ff:ff:ff:ff:ff" then return "" end
  return raw
end

local function first_mac(paths)
  for _, path in ipairs(paths) do
    local mac = normalize_mac(read_identifier_file(path))
    if mac ~= "" then return mac end
  end
  return ""
end

local function read_mtd_ascii_mac(partition, key)
  local mtd_index
  for line in read_file_all(PROC_MTD_PATH):gmatch("[^\n]+") do
    local index, label = line:match('^mtd(%d+):.-"([^"]+)"')
    if label == partition then
      mtd_index = index
      break
    end
  end
  if not mtd_index then return "" end

  local data = read_file_all(MTD_BLOCK_PREFIX .. mtd_index):gsub("%z", "\n")
  for line in data:gmatch("[^\r\n]+") do
    local value = line:match(key .. "%s*=%s*([%x:%-]+)")
    local mac = normalize_mac(value or "")
    if mac ~= "" then return mac end
  end
  return ""
end

local function sleep_one_second()
  local ok, nixio = pcall(require, "nixio")
  if ok and nixio and nixio.nanosleep then
    nixio.nanosleep(1)
  else
    os.execute("sleep 1")
  end
end

local function runtime_mac_with_retry()
  for attempt = 1, MAC_RETRY_ATTEMPTS do
    local mac = first_mac({ ETH0_MAC_PATH, BR_LAN_MAC_PATH })
    if mac ~= "" then return mac end
    if attempt < MAC_RETRY_ATTEMPTS then sleep_one_second() end
  end
  return ""
end

local function valid_device_id(value)
  local device_id = trim_text(value):lower()
  if #device_id == 40 and device_id:match("^openwrt%-%x+$") then
    return device_id
  end
  return ""
end

local function persist_device_id(device_id)
  device_id = valid_device_id(device_id)
  if device_id == "" then return false end

  local tmp_path = DEVICE_ID_PATH .. ".tmp"
  local file = io.open(tmp_path, "w")
  if not file then return false end
  local wrote = file:write(device_id, "\n")
  file:close()
  if not wrote then
    os.remove(tmp_path)
    return false
  end

  local renamed = os.rename(tmp_path, DEVICE_ID_PATH)
  if not renamed then os.remove(tmp_path) end
  return renamed and true or false
end

local function read_cpu_serial()
  local cpuinfo = read_file_all(CPUINFO_PATH):gsub("%z", "")
  for line in cpuinfo:gmatch("[^\n]+") do
    local key, value = line:match("^%s*([^:]+):%s*(.-)%s*$")
    key = trim_text(key or ""):lower()
    value = trim_text(value or "")
    if key:find("serial", 1, true) and #value >= 8 and not value:match("^0+$") then
      return value
    end
  end
  return ""
end

local function hashed_openwrt_id(kind, value)
  value = trim_text(value or "")
  if value == "" then return "" end
  local digest = tostring(util.sha256(kind .. ":" .. value) or "")
    :lower():match("^(%x+)")
  if not digest or #digest < 32 then return "" end
  return "openwrt-" .. digest:sub(1, 32)
end

--- Generate the stable hardware-bound OpenWrt device ID.
--- Format: "openwrt-<sha256 first 32 chars>"
function M.get_device_id()
  local persisted = valid_device_id(read_identifier_file(DEVICE_ID_PATH))
  if persisted ~= "" then return persisted end

  local generated = ""
  local serial = read_identifier_file(DEVICE_TREE_SERIAL_PATH)
  if #serial >= 8 and not serial:match("^0+$") then
    generated = hashed_openwrt_id("serial", serial)
  end

  if generated == "" then
    local cpu_serial = read_cpu_serial()
    if cpu_serial ~= "" then
      generated = hashed_openwrt_id("cpu", cpu_serial)
    end
  end

  if generated == "" then
    local license_status = trim_text(db.setting("license_status") or "")
    local mac = ""
    if license_status == "active" then
      -- Preserve the pre-migration eth0/br-lan identity for licensed routers.
      mac = runtime_mac_with_retry()
      if mac == "" then mac = read_mtd_ascii_mac("product_info", "ethaddr") end
    else
      -- Ruijie's permanent LAN MAC is stored as ethaddr in product_info.
      mac = read_mtd_ascii_mac("product_info", "ethaddr")
      if mac == "" then mac = runtime_mac_with_retry() end
    end
    if mac ~= "" then generated = hashed_openwrt_id("mac", mac) end
  end

  if generated == "" then return nil end
  if not persist_device_id(generated) then
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: failed to persist device_id\n")
  end
  return generated
end

--- Legacy OpenWrt ID used by existing license bindings before hashed IDs.
--- Keep sending this during migration so already-activated routers survive.
function M.get_legacy_device_id()
  local mac = first_mac({ BR_LAN_MAC_PATH, ETH0_MAC_PATH })
  if mac == "" then return nil end
  return "openwrt-" .. mac
end

--- Get the router hostname
function M.get_hostname()
  local f = io.popen("uci get system.@system[0].hostname 2>/dev/null")
  if not f then return "KemoFi-LiteV2-Router" end
  local name = (f:read("*l") or ""):gsub("%s+", "")
  f:close()
  return name ~= "" and name or "KemoFi-LiteV2-Router"
end

--- Get the firmware version
function M.get_version()
  local f = io.open("/etc/kemofi/version", "r")
  if f then
    local v = (f:read("*l") or ""):gsub("%s+", "")
    f:close()
    if v ~= "" then return v end
  end
  return "unknown"
end

function M.get_router_model()
  local board = read_trimmed_file("/tmp/sysinfo/board_name")
  if board ~= "" then return board end
  return "ruijie,rg-ew1200g-pro-v1.1"
end

function M.get_board_model()
  local board = normalize_board_model(read_trimmed_file("/tmp/sysinfo/board_name"))
  if board ~= "" then return board end
  board = normalize_board_model(M.get_router_model())
  if board ~= "" then return board end
  return "ruijie-rg-ew1200g-pro-v1.1"
end

local function apply_device_identity(payload, device_id, options)
  local hardware_device_id = trim_text((options and options.hardware_device_id) or
    M.get_device_id() or device_id or "")
  local primary_device_id = trim_text(device_id or hardware_device_id)
  local legacy_device_id = trim_text(M.get_legacy_device_id() or "")

  payload.board_model = M.get_board_model()
  payload.instance_device_id = primary_device_id
  payload.device_id = primary_device_id
  payload.hardware_device_id = hardware_device_id
  payload.hashed_device_id = hardware_device_id

  if legacy_device_id ~= "" and legacy_device_id ~= primary_device_id then
    payload.legacy_device_id = legacy_device_id
    payload.legacy_instance_device_id = legacy_device_id
  end

  return payload
end

local function build_license_payload(license_key, device_id, earnings, options)
  local hostname = M.get_hostname()
  local version = M.get_version()
  return apply_device_identity({
    license_id = license_key,
    license_key = license_key,
    key = license_key,
    instance_hostname = hostname,
    hostname = hostname,
    instance_version = version,
    firmware_version = version,
    board_type = "openwrt",
    router_model = M.get_router_model(),
    wifi_earnings = earnings or {},
  }, device_id, options)
end

local function build_recover_payload(device_id, options)
  local hostname = M.get_hostname()
  local version = M.get_version()
  return apply_device_identity({
    hostname = hostname,
    instance_hostname = hostname,
    instance_version = version,
    firmware_version = version,
    board_type = "openwrt",
    router_model = M.get_router_model(),
  }, device_id, options)
end

-- ─── Earnings Collection ───────────────────────────────────────────────────────

--- Collect daily WiFi earnings from the transactions table (last 60 days).
--- Returns array of {date = "YYYY-MM-DD", php_amount = N}
function M.collect_earnings()
  local now = os.time()
  local cutoff = now - (60 * 24 * 3600)  -- 60 days ago
  local pht_offset = 8 * 3600
  local rows = db.query(
    "SELECT created_at, amount_php FROM transactions WHERE created_at > ?",
    cutoff
  )
  local by_date = {}
  for _, row in ipairs(rows) do
    local ts = tonumber(row.created_at) or 0
    local pht_time = ts + pht_offset
    local date_str = os.date("!%Y-%m-%d", pht_time)
    by_date[date_str] = (by_date[date_str] or 0) + (tonumber(row.amount_php) or 0)
  end
  local result = {}
  for date, amount in pairs(by_date) do
    result[#result + 1] = { date = date, php_amount = amount }
  end
  return result
end

-- ─── HTTP Helper ───────────────────────────────────────────────────────────────

--- Read the configured license manager base URL from disk (set by setup.sh).
-- Falls back to the compile-time default so tests without a file still work.
local function read_line(path)
  local f = io.open(path, "r")
  if not f then return "" end
  local value = trim_text(f:read("*l") or "")
  f:close()
  return value
end

local function state_line(primary, legacy)
  local value = read_line(primary)
  if value ~= "" then return value end
  return read_line(legacy)
end

local function license_manager_base()
  local value = state_line(LICENSE_MANAGER_URL_FILE, LEGACY_LICENSE_MANAGER_URL_FILE)
  if value:sub(1, 8) == "https://" then return value:gsub("/+$", "") end
  return ROUTER_API_BASE
end

local function firmware_edition()
  local value = state_line(EDITION_FILE, LEGACY_EDITION_FILE):lower():gsub("%s+", "")
  if value == "remote" then return value end
  return "local"
end

local function valid_bind_code(value)
  value = trim_text(value)
  return #value == 33 and value:sub(17, 17) == "-" and
    value:sub(1, 16):match("^[0-9A-Fa-f]+$") ~= nil and
    value:sub(18):match("^[0-9A-Fa-f]+$") ~= nil
end

local function random_hex(length)
  local bytes = math.ceil(length / 2)
  local p = io.popen("openssl rand -hex " .. tostring(bytes) .. " 2>/dev/null")
  local value = p and trim_text(p:read("*a") or "") or ""
  if p then p:close() end
  return value:sub(1, length)
end

local function persist_bind_code(value)
  if not valid_bind_code(value) then return false end
  os.execute("mkdir -p /etc/pisowifi/data")
  local f = io.open(BIND_CODE_FILE, "w")
  if not f then return false end
  f:write(value, "\n")
  f:close()
  os.execute("chmod 600 " .. BIND_CODE_FILE .. " 2>/dev/null")
  return true
end

--- Return the stable router bind code used by /router-api/<action>/<bind_code>.
--- It is generated once and retained across normal sysupgrades.
function M.get_bind_code()
  local stored = state_line(BIND_CODE_FILE, LEGACY_BIND_CODE_FILE)
  if valid_bind_code(stored) then return stored end

  local first = random_hex(16)
  local second = random_hex(16)
  if #first ~= 16 or #second ~= 16 then
    local fallback = util.sha256(tostring(os.time()) .. tostring(math.random()))
    first, second = fallback:sub(1, 16), fallback:sub(17, 32)
  end
  local generated = first .. "-" .. second
  persist_bind_code(generated)
  return generated
end

function M.set_bind_code(value)
  value = trim_text(value)
  if valid_bind_code(value) then return persist_bind_code(value) end
  return false
end

--- URL-encode a single path segment value.
local function url_segment(value)
  return tostring(value or ""):gsub("[^%w%._~%-]", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
end

--- GET /router-api/<action>/<bind_code> authenticated by X-License-Key.
-- Returns: http_status (number or nil), response_body (string), error (string).
-- Keep the HTTP status separate from the JSON body so the admin UI can show
-- the service's actual 4xx message. TLS verification remains enabled.
function M.http_get_router_api(action, bind_code, license_key, extra_headers)
  local base = license_manager_base()
  local endpoint = base .. "/router-api/" .. url_segment(action) .. "/" ..
    url_segment(bind_code)
  local function shell_quote(value)
    return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
  end

  local cmd = "curl -sS --connect-timeout 8 --max-time 20"
  if license_key and license_key ~= "" then
    cmd = cmd .. " --header=" .. shell_quote("X-License-Key: " .. license_key)
  end
  cmd = cmd .. " --header=" .. shell_quote("X-KemoFi-Firmware-Edition: " .. firmware_edition())
  for _, h in ipairs(extra_headers or {}) do
    cmd = cmd .. " --header=" .. shell_quote(h)
  end
  cmd = cmd .. " --write-out=" .. shell_quote(
    "\n__KEMOFI_HTTP_STATUS__:%{http_code}"
  ) .. " " .. shell_quote(endpoint) .. " 2>/dev/null"

  local handle = io.popen(cmd)
  if not handle then return nil, "", "process_unavailable" end
  local raw = handle:read("*a") or ""
  local close_ok, close_reason, close_code = handle:close()
  local status_text = raw:match("\n__KEMOFI_HTTP_STATUS__:(%d%d%d)%s*$")
  local status = tonumber(status_text)
  if status_text then
    raw = raw:gsub("\n__KEMOFI_HTTP_STATUS__:%d%d%d%s*$", "")
  end
  if close_ok == false and not status then
    return nil, "", "curl_" .. tostring(close_reason or "failed") ..
      "_" .. tostring(close_code or "unknown")
  end
  if not status then return nil, raw, "empty_http_status" end
  return status, raw, nil
end

--- Legacy POST helper kept for any callers that still use it internally.
-- Re-implemented to POST a JSON body to /router-api (action in X-License-Action header).
function M.http_post(url, payload_json)
  -- url is ignored; we always call the configured license manager.
  -- Extract action from payload JSON for the header.
  local action = (payload_json or ""):match('"action"%s*:%s*"([^"]+)"') or "license_status"
  local license_key = (payload_json or ""):match('"license_key"%s*:%s*"([^"]+)"') or ""
  local bind_code   = (payload_json or ""):match('"bind_code"%s*:%s*"([^"]+)"') or M.get_bind_code()
  local status, body, err = M.http_get_router_api(action, bind_code, license_key)
  if not status then return nil, err end
  return status, body
end

local function post_and_decode(action, payload)
  payload = payload or {}
  local license_key = trim_text(tostring(payload.license_key or payload.key or ""))
  local bind_code = trim_text(tostring(payload.bind_code or M.get_bind_code()))
  local device_id = trim_text(tostring(payload.hardware_device_id or payload.device_id or ""))
  local extra_headers = {}
  if device_id ~= "" then
    extra_headers[#extra_headers + 1] = "X-KemoFi-Device-Id: " .. device_id
  end
  local status, body, err = M.http_get_router_api(action, bind_code, license_key, extra_headers)
  if not status then return nil, nil, err end
  local ok_parse, resp = pcall(json.decode, body)
  if not ok_parse or type(resp) ~= "table" then
    return status, nil, "invalid response"
  end
  return status, resp, nil
end


local function validate_recovered_license(recovered_key, candidate_id, device_id)
  local payload = build_license_payload(
    recovered_key, candidate_id, {}, { hardware_device_id = device_id }
  )
  local status, resp, err = post_and_decode(VENDOR_URL, payload)
  if not status then
    local detail = trim_text(tostring(err or "unknown error"):gsub("%s+", " "))
    io.write(os.date("[%H:%M:%S] ") ..
      "Vendor: recovered license validation failed: " .. detail .. "\n")
    return nil, "validation_unavailable"
  end
  if type(resp) ~= "table" then
    io.write(os.date("[%H:%M:%S] ") ..
      "Vendor: recovered license validation returned invalid response\n")
    return nil, "invalid_response"
  end

  local result = license_result(resp)
  if status >= 400 or result ~= "ok" then
    local reason = result ~= "" and result or tostring(status)
    io.write(os.date("[%H:%M:%S] ") ..
      "Vendor: recovered license validation rejected (" .. reason .. ")\n")
    return nil, result ~= "" and result or vendor_http_message(status)
  end

  if is_trial_response(resp, recovered_key) or is_valid_response(resp) then
    return resp, nil
  end

  io.write(os.date("[%H:%M:%S] ") ..
    "Vendor: recovered license validation missing valid=true\n")
  return nil, "invalid_response"
end

local RECOVERY_LOCK_STATUS = {
  trial_expired = "trial_expired",
  expired = "expired",
  revoked = "revoked",
  device_mismatch = "device_mismatch",
}

local STORED_LOCK_STATUS = {
  trial_expired = true,
  expired = true,
  revoked = true,
  device_mismatch = true,
  not_found = true,
  offline_expired = true,
}

local function recovery_lock_status(reason)
  return RECOVERY_LOCK_STATUS[trim_text(tostring(reason or "")):lower()]
end

local function persist_license_state(reason)
  local persisted, persist_err = db.persist(reason, true)
  if not persisted then
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: failed to persist license state: " ..
      tostring(persist_err) .. "\n")
  end
  return persisted
end

local function store_recovery_failure(reason)
  local locked_status = recovery_lock_status(reason)
  if locked_status then
    db.set_setting("license_status", locked_status)
    persist_license_state("license-recovery-" .. locked_status)
    return locked_status
  end

  db.set_setting("license_status", "unknown")
  persist_license_state("license-recovery-pending")
  return "unknown"
end

-- ─── Phone Home ────────────────────────────────────────────────────────────────

--- Main phone-home function. Validates license with vendor platform.
--- Returns: "ok", "trial", "expired", "revoked", "offline_grace", "offline_dead"
function M.phone_home()
  local device_id = M.get_device_id()
  if not device_id then
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: cannot determine device_id\n")
    return "error"
  end

  local license_key = db.setting("license_key") or ""
  local license_status = trim_text(db.setting("license_status") or "trial")
  local trial_key = trim_text(db.setting("_trial_license_key") or "")
  if license_status == "trial" and license_key ~= "" and
      trial_key == "" then
    db.set_setting("_trial_license_key", license_key)
    trial_key = license_key
  end

  -- A stored trial must never hide a paid license bound to this hardware.
  local stored_trial = license_key ~= "" and (
    license_status == "trial" or license_status == "trial_expired" or
    (trial_key ~= "" and trial_key == license_key)
  )
  if license_key == "" or stored_trial then
    local recovered, recover_error = M.recover_license(device_id)
    if recovered then return recovered end

    local locked_status = recovery_lock_status(recover_error)
    if locked_status then
      return store_recovery_failure(locked_status)
    end

    if license_key == "" then
      if STORED_LOCK_STATUS[license_status] then
        persist_license_state("license-recovery-still-" .. license_status)
        return license_status
      end
      local trial_permitted = license_status == "" or license_status == "trial" or
        license_status == "unknown"
      if recover_error == "not_found" and trial_permitted then
        return M.request_trial(device_id)
      end
      io.write(os.date("[%H:%M:%S] ") ..
        "Vendor: recovery unresolved; trial request suppressed (" ..
        tostring(recover_error or "unknown") .. ")\n")
      return store_recovery_failure(recover_error)
    end

    if recover_error ~= "not_found" then
      io.write(os.date("[%H:%M:%S] ") ..
        "Vendor: paid recovery unresolved; stored trial validation suppressed (" ..
        tostring(recover_error or "unknown") .. ")\n")
      return store_recovery_failure(recover_error)
    end
    if license_status == "trial_expired" then return "trial_expired" end
    -- Existing live trials still validate normally after paid recovery misses.
  end

  local earnings = M.collect_earnings()
  local payload = build_license_payload(license_key, device_id, earnings)
  local status, resp, decode_err = post_and_decode(VENDOR_URL, payload)

  if not status then
    return M.handle_offline(decode_err)
  end
  if type(resp) ~= "table" then
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: invalid response\n")
    return M.handle_offline("invalid response")
  end

  local result = license_result(resp)
  if result == "device_mismatch" then
    local legacy_device_id = M.get_legacy_device_id()
    if legacy_device_id and legacy_device_id ~= "" and legacy_device_id ~= device_id then
      local retry_payload = build_license_payload(
        license_key, legacy_device_id, earnings, { hardware_device_id = device_id }
      )
      local retry_status, retry_resp = post_and_decode(VENDOR_URL, retry_payload)
      if retry_status and type(retry_resp) == "table" then
        status = retry_status
        resp = retry_resp
        result = license_result(resp)
      end
    end
  end

  db.set_setting("_vendor_last_success", tostring(os.time()))

  if result == "ok" then
    if is_trial_response(resp, license_key) then
      local expires_at = response_trial_expires_at(resp)
      db.set_setting("license_status", "trial")
      db.set_setting("_trial_license_key", license_key)
      db.set_setting("_trial_expires_at", expires_at ~= "" and expires_at or db.setting("_trial_expires_at") or "")
      io.write(os.date("[%H:%M:%S] ") .. "Vendor: trial valid (" .. license_key:sub(1,8) .. "...)\n")
      return "trial"
    elseif is_valid_response(resp) then
      db.set_setting("license_status", "active")
      db.set_setting("_trial_expires_at", "")
      db.set_setting("_trial_license_key", "")
    else
      db.set_setting("license_status", "unknown")
      io.write(os.date("[%H:%M:%S] ") .. "Vendor: active license was not explicitly validated\n")
      return "unknown"
    end
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: license valid (" .. license_key:sub(1,8) .. "...)\n")
    return "ok"
  elseif result == "expired" then
    db.set_setting("license_status", "expired")
    persist_license_state("license-validation-expired")
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: license expired\n")
    return "expired"
  elseif result == "revoked" then
    db.set_setting("license_status", "revoked")
    persist_license_state("license-validation-revoked")
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: license revoked\n")
    return "revoked"
  elseif result == "device_mismatch" then
    db.set_setting("license_status", "device_mismatch")
    persist_license_state("license-validation-device-mismatch")
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: device mismatch (key bound to another device)\n")
    return "device_mismatch"
  elseif result == "trial_expired" then
    db.set_setting("license_status", "trial_expired")
    persist_license_state("license-validation-trial-expired")
    return "trial_expired"
  elseif result == "not_found" then
    db.set_setting("license_status", "not_found")
    persist_license_state("license-validation-not-found")
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: license not found\n")
    return "not_found"
  else
    db.set_setting("license_status", "unknown")
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: unknown status — " .. tostring(result) .. "\n")
    return "unknown"
  end
end

-- ─── Trial Request ─────────────────────────────────────────────────────────────

--- Request a 24-hour trial from the vendor platform.
function M.request_trial(device_id)
  local payload = build_recover_payload(device_id)
  local status, resp = post_and_decode(TRIAL_URL, payload)

  if not status then
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: trial request failed (offline)\n")
    db.set_setting("license_status", "unknown")
    persist_license_state("trial-request-pending")
    return "unknown"
  end

  if type(resp) ~= "table" then
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: trial response invalid\n")
    db.set_setting("license_status", "unknown")
    persist_license_state("trial-request-invalid")
    return "unknown"
  end

  local trial_key = response_license_key(resp)
  local expires_at = response_trial_expires_at(resp)
  if resp.ok ~= false and trial_key ~= "" and
      is_trial_response(resp, trial_key) and expires_at ~= "" then
    db.set_setting("license_key", trial_key)
    db.set_setting("_trial_license_key", trial_key)
    db.set_setting("_trial_expires_at", expires_at)
    if M.trial_is_expired({
      license_status = "trial",
      _trial_expires_at = expires_at,
    }) then
      db.set_setting("license_status", "trial_expired")
      persist_license_state("trial-already-expired")
      io.write(os.date("[%H:%M:%S] ") .. "Vendor: returned trial is already expired\n")
      return "trial_expired"
    end
    db.set_setting("license_status", "trial")
    db.set_setting("_vendor_last_success", tostring(os.time()))
    local persisted, persist_err = db.persist("trial-license", true)
    if not persisted then
      io.write(os.date("[%H:%M:%S] ") .. "Vendor: failed to persist trial license: " .. tostring(persist_err) .. "\n")
      return "persistence_error"
    end
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: trial granted (" .. trial_key:sub(1,8) .. "...) expires " .. (expires_at ~= "" and expires_at or "24h") .. "\n")
    return "trial"
  end

  local result = license_result(resp)
  if result == "trial_expired" or resp.already_trialed == true then
    db.set_setting("license_status", "trial_expired")
    persist_license_state("trial-already-used")
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: device already trialed\n")
    return "trial_expired"
  end

  local locked_status = recovery_lock_status(result)
  if locked_status then
    db.set_setting("license_status", locked_status)
    persist_license_state("trial-request-" .. locked_status)
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: trial denied (" .. locked_status .. ")\n")
    return locked_status
  end

  db.set_setting("license_status", "unknown")
  persist_license_state("trial-request-denied")
  io.write(os.date("[%H:%M:%S] ") .. "Vendor: trial request denied\n")
  return "unknown"
end

-- ─── License Recovery ─────────────────────────────────────────────────────────

--- Recover an already-bound license after a clean flash.
--- Returns a normal phone-home status when recovered, or nil with a reason.
local function recover_candidate(candidate_id, device_id)
  local payload = build_recover_payload(candidate_id, { hardware_device_id = device_id })
  local status, resp = post_and_decode(RECOVER_URL, payload)
  if not status then
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: license recovery unavailable\n")
    return nil, "recovery_unavailable"
  end
  if type(resp) ~= "table" then
    io.write(os.date("[%H:%M:%S] ") ..
      "Vendor: license recovery returned invalid response\n")
    return nil, "invalid_response"
  end

  local result = license_result(resp)
  if result == "not_found" or result == "device_mismatch" then
    return nil, result
  end

  local locked_status = recovery_lock_status(result)
  if locked_status then return nil, locked_status end
  if status >= 500 then return nil, "recovery_unavailable" end

  local recovered_key = response_license_key(resp)
  if status >= 400 or recovered_key == "" then
    return nil, result ~= "" and result or "invalid_response"
  end

  if not recovery_response_matches_device(resp, device_id, candidate_id) then
    io.write(os.date("[%H:%M:%S] ") ..
      "Vendor: recovery rejected due to mismatched device binding\n")
    return nil, "device_mismatch"
  end

  -- A clean reflash generates a new local bind code. The VPS response is
  -- authoritative; persist it before caching the recovered license so the
  -- remote agent enrolls against the existing fleet record.
  if resp.bind_code then M.set_bind_code(resp.bind_code) end

  local expires_at = response_trial_expires_at(resp)
  local recovered_trial = is_trial_response(resp, recovered_key)
  if not recovered_trial and not is_valid_response(resp) then
    local validated_resp, validation_error =
      validate_recovered_license(recovered_key, candidate_id, device_id)
    if not validated_resp then
      return nil, recovery_lock_status(validation_error) or validation_error or
        "validation_unavailable"
    end
    resp = validated_resp
    expires_at = response_trial_expires_at(resp)
    recovered_trial = is_trial_response(resp, recovered_key)
  end

  if recovered_trial and (expires_at == "" or M.trial_is_expired({
      license_status = "trial",
      _trial_expires_at = expires_at,
    })) then
    db.set_setting("license_key", recovered_key)
    db.set_setting("_trial_license_key", recovered_key)
    db.set_setting("_trial_expires_at", expires_at)
    return nil, "trial_expired"
  end

  if not recovered_trial and not is_valid_response(resp) then
    return nil, "invalid_response"
  end

  db.set_setting("license_key", recovered_key)
  if recovered_trial then
    db.set_setting("license_status", "trial")
    db.set_setting("_trial_license_key", recovered_key)
    db.set_setting("_trial_expires_at", expires_at)
  else
    db.set_setting("license_status", "active")
    db.set_setting("_trial_license_key", "")
    db.set_setting("_trial_expires_at", "")
  end
  db.set_setting("_vendor_last_success", tostring(os.time()))
  local persisted, persist_err = db.persist("license-recover", true)
  if not persisted then
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: failed to persist recovered license: " ..
      tostring(persist_err) .. "\n")
    return "persistence_error"
  end
  io.write(os.date("[%H:%M:%S] ") .. "Vendor: license recovered (" ..
    recovered_key:sub(1, 8) .. "...)\n")
  return recovered_trial and "trial" or "ok"
end

function M.recover_license(device_id)
  local candidates = { device_id }
  local legacy_device_id = M.get_legacy_device_id()
  if legacy_device_id and legacy_device_id ~= "" and legacy_device_id ~= device_id then
    candidates[#candidates + 1] = legacy_device_id
  end

  local saw_device_mismatch = false
  for _, candidate_id in ipairs(candidates) do
    local recovered, recover_error = recover_candidate(candidate_id, device_id)
    if recovered then return recovered end
    if recover_error == "device_mismatch" then
      saw_device_mismatch = true
    elseif recover_error ~= "not_found" then
      return nil, recover_error
    end
  end

  if saw_device_mismatch then return nil, "device_mismatch" end
  return nil, "not_found"
end

-- ─── Offline Grace Period ──────────────────────────────────────────────────────

--- Handle offline scenario with grace period.
function M.handle_offline(reason)
  local last_success = tonumber(db.setting("_vendor_last_success") or "0") or 0
  local now = os.time()
  local elapsed = now - last_success

  if last_success == 0 then
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: offline, never validated (trial mode)\n")
    return "trial"
  end

  if elapsed <= GRACE_PERIOD_SECONDS then
    local days_left = math.floor((GRACE_PERIOD_SECONDS - elapsed) / 86400)
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: offline (" .. tostring(reason) .. "), grace " .. days_left .. " days left\n")
    return "offline_grace"
  else
    db.set_setting("license_status", "offline_expired")
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: offline grace expired! Locking out.\n")
    return "offline_dead"
  end
end

-- ─── License Activation ───────────────────────────────────────────────────────

--- Activate a license key through the KemoFi license service.
--- Called from admin.lua when operator pastes a key.
function M.activate_key(key)
  local device_id = M.get_device_id()
  if not device_id then
    return false, "Cannot determine device ID"
  end

  local payload = build_license_payload(
    key, device_id, {}, { hardware_device_id = device_id }
  )
  payload.bind_code = M.get_bind_code()
  payload.firmware_edition = firmware_edition()
  local status, resp, decode_err = post_and_decode(FETCH_URL, payload)

  if not status then
    return false, activation_network_error("activation", decode_err)
  end

  if type(resp) ~= "table" then
    return false, status >= 400 and vendor_http_message(status) or
      "Activation could not be verified. Please try again."
  end
  local result = license_result(resp)
  if status >= 400 or resp.success == false or result ~= "ok" then
    return false, result_message(
      result, resp, "Activation failed. Check the license key and try again."
    )
  end

  if resp.bind_code then M.set_bind_code(resp.bind_code) end
  local activated_key = response_license_key(resp)
  if activated_key == "" then activated_key = key end
  local trial_response = is_trial_response(resp, activated_key)
  if not trial_response and not is_valid_response(resp) then
    return false, "Activation could not be verified. Please try again."
  end

  db.set_setting("license_key", activated_key)
  if trial_response then
    local expires_at = response_trial_expires_at(resp)
    db.set_setting("license_status", "trial")
    db.set_setting("_trial_license_key", activated_key)
    db.set_setting("_trial_expires_at", expires_at ~= "" and expires_at or db.setting("_trial_expires_at") or "")
  else
    db.set_setting("license_status", "active")
    db.set_setting("_trial_license_key", "")
    db.set_setting("_trial_expires_at", "")
  end
  db.set_setting("_vendor_last_success", tostring(os.time()))
  io.write(os.date("[%H:%M:%S] ") .. "Vendor: license activated — " .. activated_key:sub(1,8) .. "...\n")
  return true, "License activated successfully"
end

return M
