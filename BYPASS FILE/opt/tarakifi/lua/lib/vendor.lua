--- TarakiFi Vendor Phone-Home Client
-- Periodically validates the license with the vendor platform (pisowifi.taraki.vip)
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

local HARD_DENIAL = {
  revoked=true, suspended=true, expired=true, trial_expired=true,
  device_mismatch=true, already_bound=true, not_found=true,
  activation_required=true, verification_failed=true,
}
local license_access
local license_operation_depth = 0
local LICENSE_FIELDS = {"license_status", "license_key", "_license_policy",
  "_vendor_last_success", "_vendor_last_result", "_vendor_verified_device_id",
  "_vendor_verified_hardware", "_vendor_verified_license_key", "_vendor_lifetime",
  "_vendor_paid_expires_at", "_trial_license_key", "_trial_expires_at"}

local function license_snapshot()
  if db.settings then return db.settings(LICENSE_FIELDS) end
  local values = {}
  for _, key in ipairs(LICENSE_FIELDS) do values[key] = db.setting(key) end
  return values
end

-- Backups restore business settings, never activation or identity evidence.
function M.license_setting_restorable(key)
  if type(key) ~= "string" or key == "" or key:sub(1, 1) == "_" then return false end
  return not key:match("^license") and not key:match("^trial") and
    key ~= "device_id" and key ~= "instance_device_id" and
    key ~= "hardware_device_id" and key ~= "hashed_device_id"
end
-- ─── Configuration ─────────────────────────────────────────────────────────────

local VENDOR_URL = "https://pisowifi.taraki.vip/api/license/validate"
local TRIAL_URL = "https://pisowifi.taraki.vip/api/trials/request"
local FETCH_URL = "https://pisowifi.taraki.vip/api/license/fetch"
local RECOVER_URL = "https://pisowifi.taraki.vip/api/license/recover"
local BOARD_SECRET = "tarakifi-board-secret-2024"
local ROUTER_SLUG_FILE = os.getenv("TARAKIFI_ROUTER_SLUG_FILE") or
  "/etc/tarakifi/router-slug"
local DEVICE_TREE_SERIAL_PATH = os.getenv("TARAKIFI_DEVICE_TREE_SERIAL_PATH") or
  "/proc/device-tree/serial-number"
local CPUINFO_PATH = os.getenv("TARAKIFI_CPUINFO_PATH") or "/proc/cpuinfo"
local ETH0_MAC_PATH = os.getenv("TARAKIFI_ETH0_MAC_PATH") or
  "/sys/class/net/eth0/address"
local BR_LAN_MAC_PATH = os.getenv("TARAKIFI_BR_LAN_MAC_PATH") or
  "/sys/class/net/br-lan/address"
local BOARD_NAME_PATH = os.getenv("TARAKIFI_BOARD_NAME_PATH") or
  "/tmp/sysinfo/board_name"
local DEVICE_ID_PATH = os.getenv("TARAKIFI_DEVICE_ID_PATH") or
  "/etc/tarakifi/device_id"
local PROC_MTD_PATH = os.getenv("TARAKIFI_PROC_MTD_PATH") or "/proc/mtd"
local MTD_SYS_CLASS_PATH = os.getenv("TARAKIFI_MTD_SYS_CLASS_PATH") or
  "/sys/class/mtd"
local MTD_BLOCK_PREFIX = os.getenv("TARAKIFI_MTD_BLOCK_PREFIX") or "/dev/mtdblock"
local MAC_RETRY_ATTEMPTS = tonumber(os.getenv("TARAKIFI_MAC_RETRY_ATTEMPTS") or "5") or 5
MAC_RETRY_ATTEMPTS = math.max(1, math.min(10, math.floor(MAC_RETRY_ATTEMPTS)))
local GRACE_PERIOD_SECONDS = 7 * 24 * 3600  -- 7 days offline grace

local function store_cloud_url(resp)
  if type(resp) ~= "table" then return end
  local url = tostring(resp.cloud_backup_url or resp.cloud_url or "")
  if url:sub(1, 8) ~= "https://" then return end
  db.set_setting("cloud_backup_url", url:gsub("/+$", ""))
end

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

--- Customer service does not require license activation.
function M.customer_access_allowed(settings)
  settings = settings or {}
  local license_status = trim_text(settings.license_status or db.setting("license_status") or "trial")
  return true, license_status
end

local function read_trimmed_file(path)
  local file = io.open(path, "r")
  if not file then return "" end
  local value = trim_text(file:read("*l") or "")
  file:close()
  return value
end

local function normalize_router_slug(value)
  local slug = trim_text(value):lower():gsub(",", "-"):gsub("_", "-")
  if slug:match("^comfast%-[a-z0-9%-]+$") then return slug end
  return ""
end

local function normalize_board_model(value)
  local model = trim_text(value):lower():gsub(",", "-"):gsub("_", "-"):gsub("%s+", "-")
  model = model:gsub("[^a-z0-9._-]", "-"):gsub("-+", "-")
    :gsub("^-+", ""):gsub("-+$", "")
  return model
end

local function license_result(resp)
  if type(resp) ~= "table" then return "" end
  for _, field in ipairs({"result", "reason", "error", "status", "code"}) do
    local value = trim_text(resp[field]):lower():gsub("^license_", "")
    if HARD_DENIAL[value] then return value end
  end
  local result = trim_text(tostring(
    resp.result or resp.reason or resp.error or resp.status or ""
  )):lower()
  if result == "" then
    if resp.valid == true or resp.ok == true then
      result = "ok"
    elseif resp.valid == false or resp.ok == false then
      result = trim_text(tostring(resp.reason or resp.error or "failed"))
    end
  end
  if result == "valid" or result == "active" or result == "success" then
    return "ok"
  end
  local aliases = {
    license_expired = "expired",
    license_revoked = "revoked",
    license_suspended = "suspended",
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
  if result == "suspended" then return "License suspended." end
  if result == "device_mismatch" then
    return "This license is already active on another device."
  end
  if result == "not_found" then return "License not found." end
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
  if resp.valid == false then return false end
  if resp.valid == true then return true end
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

local function recovery_response_matches_device(resp, device_id, candidate_id, license_key)
  if license_key then
    for _, source in ipairs({resp, type(resp.license) == "table" and resp.license or {},
        M.signed_payload_data(resp) or {}}) do
      local returned_key = source.license_key
      if returned_key ~= nil and returned_key ~= json.null and
          returned_key ~= license_key then return false end
    end
  end
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

local function current_board_name()
  return read_identifier_file(BOARD_NAME_PATH):lower()
end

local function mtd_partition_index(partition)
  for line in read_file_all(PROC_MTD_PATH):gmatch("[^\n]+") do
    local index, label = line:match('^mtd(%d+):.-"([^"]+)"')
    if label == partition then return index end
  end

  -- Newer OpenWrt kernels can expose MTD only through sysfs. Scan the small,
  -- fixed index space instead of invoking a shell command during phone-home.
  for index = 0, 63 do
    local label = read_identifier_file(
      MTD_SYS_CLASS_PATH .. "/mtd" .. tostring(index) .. "/name"
    )
    if label == partition then return tostring(index) end
  end
  return nil
end

local function read_mtd_binary_mac(partition, offset)
  local mtd_index = mtd_partition_index(partition)
  if not mtd_index then return "" end

  local file = io.open(MTD_BLOCK_PREFIX .. mtd_index, "rb")
  if not file then return "" end
  local positioned = file:seek("set", offset)
  local data = positioned and file:read(6) or nil
  file:close()
  if not data or #data ~= 6 then return "" end

  return normalize_mac(string.format(
    "%02x:%02x:%02x:%02x:%02x:%02x", data:byte(1, 6)
  ))
end

local function sleep_one_second()
  local ok, nixio = pcall(require, "nixio")
  if ok and nixio and nixio.nanosleep then
    nixio.nanosleep(1)
  else
    os.execute("sleep 1")
  end
end

local function runtime_mac_with_retry(paths)
  paths = paths or { ETH0_MAC_PATH, BR_LAN_MAC_PATH }
  for attempt = 1, MAC_RETRY_ATTEMPTS do
    local mac = first_mac(paths)
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

local function factory_mac_for_board(board_name)
  if board_name == "comfast,cf-ew72-v2" then
    return read_mtd_binary_mac("factory", 0xe000)
  end
  if board_name == "comfast,cf-e314n-v2" or
      board_name == "comfast,cf-ew71-v2" then
    return read_mtd_binary_mac("art", 0)
  end
  return ""
end

local function runtime_paths_for_board(board_name)
  if board_name == "comfast,cf-e314n-v2" or
      board_name == "comfast,cf-ew71-v2" then
    -- br-lan is the base MAC on these boards; eth0 is commonly base + 2.
    return { BR_LAN_MAC_PATH, ETH0_MAC_PATH }
  end
  return { ETH0_MAC_PATH, BR_LAN_MAC_PATH }
end

--- Generate the stable hardware-bound OpenWrt device ID.
--- Format: "openwrt-<sha256 first 32 chars>"
function M.get_device_id()
  local board_name = current_board_name()
  local ew72 = board_name == "comfast,cf-ew72-v2"
  local e314n = board_name == "comfast,cf-e314n-v2"
  local ew71 = board_name == "comfast,cf-ew71-v2"
  local art_base_mac_board = e314n or ew71
  local persistent_device_id = ew72 or art_base_mac_board
  if persistent_device_id then
    local persisted = valid_device_id(read_identifier_file(DEVICE_ID_PATH))
    if persisted ~= "" then return persisted end
  end

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
    local mac = factory_mac_for_board(board_name)
    if mac == "" then
      mac = runtime_mac_with_retry(runtime_paths_for_board(board_name))
    end
    if mac ~= "" then generated = hashed_openwrt_id("mac", mac) end
  end

  if generated == "" then return nil end
  if persistent_device_id and not persist_device_id(generated) then
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: failed to persist device_id\n")
  end
  return generated
end

--- Legacy OpenWrt ID used by existing license bindings before v1.1.19.
--- Keep sending this during migration so already-activated routers survive.
function M.get_legacy_device_id()
  local mac = first_mac({ BR_LAN_MAC_PATH, ETH0_MAC_PATH })
  if mac == "" then return nil end
  return "openwrt-" .. mac
end

local function append_unique(values, seen, value)
  value = trim_text(value or ""):lower()
  if value == "" or seen[value] then return end
  seen[value] = true
  values[#values + 1] = value
end

--- Return every historical hardware identity that this router may have used.
--- Recovery checks these before a first-trial request, preventing a clean flash
--- from bypassing an expired trial or hiding a paid binding created by old code.
function M.get_device_id_candidates(device_id)
  local candidates, seen = {}, {}
  local primary_device_id = trim_text(device_id or "")
  if primary_device_id == "" then primary_device_id = M.get_device_id() or "" end
  append_unique(candidates, seen, primary_device_id)
  append_unique(candidates, seen, valid_device_id(read_identifier_file(DEVICE_ID_PATH)))

  local board_name = current_board_name()
  local factory_mac = factory_mac_for_board(board_name)
  if factory_mac ~= "" then
    append_unique(candidates, seen, hashed_openwrt_id("mac", factory_mac))
  end

  local br_lan_mac = normalize_mac(read_identifier_file(BR_LAN_MAC_PATH))
  local eth0_mac = normalize_mac(read_identifier_file(ETH0_MAC_PATH))
  for _, mac in ipairs({ br_lan_mac, eth0_mac }) do
    if mac ~= "" then
      append_unique(candidates, seen, hashed_openwrt_id("mac", mac))
    end
  end
  for _, mac in ipairs({ br_lan_mac, eth0_mac }) do
    if mac ~= "" then append_unique(candidates, seen, "openwrt-" .. mac) end
  end
  return candidates
end

--- Get the router hostname
function M.get_hostname()
  local f = io.popen("uci get system.@system[0].hostname 2>/dev/null")
  if not f then return "TarakiFi-Router" end
  local name = (f:read("*l") or ""):gsub("%s+", "")
  f:close()
  return name ~= "" and name or "TarakiFi-Router"
end

--- Get the firmware version
function M.get_version()
  local f = io.open("/etc/tarakifi/version", "r")
  if f then
    local v = (f:read("*l") or ""):gsub("%s+", "")
    f:close()
    if v ~= "" then return v end
  end
  return "1.0.0"
end

function M.get_router_slug()
  local slug = normalize_router_slug(read_trimmed_file(ROUTER_SLUG_FILE))
  if slug ~= "" then return slug end
  slug = normalize_router_slug(read_trimmed_file("/tmp/sysinfo/board_name"))
  if slug ~= "" then return slug end
  return "comfast-cf-e314n-v2"
end

function M.get_board_model()
  local board = normalize_board_model(read_trimmed_file("/tmp/sysinfo/board_name"))
  if board ~= "" then return board end
  return M.get_router_slug()
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
    router_model = M.get_router_slug(),
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
    router_model = M.get_router_slug(),
  }, device_id, options)
end

-- ─── Earnings Collection ───────────────────────────────────────────────────────

--- Collect daily WiFi earnings from the transactions table (last 60 days).
--- Returns array of {date = "YYYY-MM-DD", php_amount = N}
function M.collect_earnings()
  local now = os.time()
  local cutoff = now - (60 * 24 * 3600)  -- 60 days ago
  -- PHT offset: +8 hours
  local pht_offset = 8 * 3600
  local rows = db.query(
    "SELECT created_at, amount_php FROM transactions WHERE created_at > ?",
    cutoff
  )
  -- Aggregate by date (PHT)
  local by_date = {}
  for _, row in ipairs(rows) do
    local ts = tonumber(row.created_at) or 0
    local pht_time = ts + pht_offset
    local date_str = os.date("!%Y-%m-%d", pht_time)
    by_date[date_str] = (by_date[date_str] or 0) + (tonumber(row.amount_php) or 0)
  end
  -- Convert to array
  local result = {}
  for date, amount in pairs(by_date) do
    result[#result + 1] = { date = date, php_amount = amount }
  end
  return result
end

-- ─── HTTP Helper ───────────────────────────────────────────────────────────────

--- POST JSON to a URL using uclient-fetch. Returns status_code, response_body.
function M.http_post(url, payload_json)
  -- Write payload to temp file
  local tmp_file = os.tmpname()
  local tmp_resp = tmp_file .. ".response"
  local tmp_err = tmp_file .. ".error"
  local f = io.open(tmp_file, "w")
  if not f then return nil, "cannot write temp file" end
  f:write(payload_json)
  f:close()
  -- Use uclient-fetch with POST
  local cmd = string.format(
    "uclient-fetch --timeout=30 "..
    "--header='Content-Type: application/json' "..
    "--header='X-Board-Secret: %s' "..
    "--post-file=%s "..
    "-O %s '%s' >%s 2>&1; echo $?",
    BOARD_SECRET, tmp_file, tmp_resp, url, tmp_err
  )
  local h = io.popen(cmd)
  if not h then
    os.remove(tmp_file)
    os.remove(tmp_resp)
    os.remove(tmp_err)
    return nil, "popen failed"
  end
  local exit_str = (h:read("*a") or ""):gsub("%s+", "")
  h:close()
  local exit_code = tonumber(exit_str) or 1
  -- Read response
  local rf = io.open(tmp_resp, "r")
  local body = ""
  if rf then
    body = rf:read("*a") or ""
    rf:close()
  end
  local ef = io.open(tmp_err, "r")
  local err = ""
  if ef then
    err = ef:read("*a") or ""
    ef:close()
  end
  -- Clean up
  os.remove(tmp_file)
  os.remove(tmp_resp)
  os.remove(tmp_err)
  if exit_code ~= 0 then
    local http_status = tonumber(err:match("HTTP error%s+(%d+)"))
    if http_status then
      return http_status, body
    end
    local detail = trim_text(err:gsub("%s+", " "))
    if detail == "" then detail = "fetch failed" end
    return nil, detail .. " (exit " .. tostring(exit_code) .. ")"
  end
  return 200, body
end

local function post_and_decode(url, payload)
  local status, body = M.http_post(url, json.encode(payload))
  if not status then return nil, nil, body end
  if status == 408 or status == 429 or status >= 500 then
    return nil, nil, "temporary license service failure"
  end
  local ok_parse, resp = pcall(json.decode, body)
  if not ok_parse or type(resp) ~= "table" then
    return status, nil, "invalid response"
  end
  local result = license_result(resp)
  if (status < 200 or status >= 300) and not HARD_DENIAL[result] then
    return nil, nil, "unrecognized license service response"
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
    return nil, "invalid response"
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
  return nil, "invalid response"
end

local RECOVERY_LOCK_STATUS = {
  already_bound = "already_bound",
  activation_required = "activation_required",
  verification_failed = "verification_failed",
  trial_expired = "trial_expired",
  expired = "expired",
  revoked = "revoked",
  suspended = "suspended",
  device_mismatch = "device_mismatch",
}

local STORED_LOCK_STATUS = {
  already_bound = true,
  activation_required = true,
  verification_failed = true,
  trial_expired = true,
  expired = true,
  revoked = true,
  suspended = true,
  device_mismatch = true,
  not_found = true,
  offline_expired = true,
}

local function recovery_lock_status(reason)
  return RECOVERY_LOCK_STATUS[trim_text(tostring(reason or "")):lower()]
end

local function persist_license_state(reason)
  local status = db.setting("license_status")
  if HARD_DENIAL[status] then
    db.set_setting("_license_policy", "1")
    db.set_setting("_vendor_lifetime", "0")
    db.set_setting("_vendor_last_result", status)
  end
  local persisted, persist_err = db.persist(reason, true)
  if not persisted then
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: failed to persist license state: " ..
      tostring(persist_err) .. "\n")
  end
  return persisted
end

local function state_write(values)
  if db.set_settings_atomic then
    local entries = {}
    for key, value in pairs(values) do entries[#entries + 1] = {key=key, value=value} end
    return db.set_settings_atomic(entries)
  end
  for key, value in pairs(values) do db.set_setting(key, value) end
  return true
end

local function identity_matches(id, hardware)
  if not id or hardware == "" then return false end
  if id == hardware then return true end
  for _, path in ipairs({ETH0_MAC_PATH, BR_LAN_MAC_PATH}) do
    local mac = normalize_mac(read_identifier_file(path))
    if mac ~= "" and id == hashed_openwrt_id("mac", mac) then return true end
  end
  return false
end

local function proof_matches(snapshot)
  local function setting(key) return snapshot[key] end
  local id = M.license_saved_identity()
  local hardware = M.license_hardware_id()
  local key = setting("license_key") or ""
  local lifetime = setting("_vendor_lifetime") == "1"
  if not lifetime then
    local expiry = setting("_vendor_paid_expires_at") or ""
    local numeric = tonumber(expiry)
    local unexpired = numeric and numeric > os.time() or
      (expiry:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") and
       expiry > os.date("!%Y-%m-%dT%H:%M:%SZ"))
    local age = os.time() - (tonumber(setting("_vendor_last_success")) or 0)
    if not unexpired or age < 0 or age > GRACE_PERIOD_SECONDS then return false end
  end
  return id ~= nil and id ~= "" and hardware ~= "" and key ~= "" and
    (tonumber(setting("_vendor_last_success")) or 0) > 0 and
    setting("_vendor_verified_device_id") == id and
    setting("_vendor_verified_hardware") == hardware and
    setting("_vendor_verified_license_key") == key and
    (setting("_vendor_last_result") == "ok" or setting("_vendor_last_result") == "soft_error")
end

local function migrate_paid_license(read_only, snapshot)
  snapshot = snapshot or license_snapshot()
  local function setting(key) return snapshot[key] end
  if setting("_license_policy") then return false end
  local status = setting("license_status")
  local key = setting("license_key") or ""
  local result = setting("_vendor_last_result")
  if (status ~= "active" and status ~= "offline_expired") or key == "" or
      key == setting("_trial_license_key") or key:match("^TRIAL") or
      (tonumber(setting("_vendor_last_success")) or 0) <= 0 or
      (result and result ~= "ok" and result ~= "soft_error") then return false end
  local id = M.license_saved_identity()
  local hardware = M.license_hardware_id()
  if not id or hardware == "" then return false end
  -- Older releases had no verification cache. Only adopt an existing paid
  -- success whose saved identity can be derived from this router's hardware.
  if not identity_matches(id, hardware) then return false end
  for field, expected in pairs({
      _vendor_verified_device_id=id, _vendor_verified_license_key=key,
      _vendor_verified_hardware=hardware}) do
    local previous = setting(field)
    if previous and previous ~= "" and previous ~= expected then return false end
  end
  if read_only then return true end
  if not state_write({_license_policy="1", _vendor_verified_device_id=id,
      _vendor_verified_license_key=key, _vendor_verified_hardware=hardware,
      _vendor_lifetime="1", _vendor_last_result="ok", license_status="active"}) then
    return false
  end
  return persist_license_state("license-policy-migration")
end

license_access = function()
  local snapshot = license_snapshot()
  if migrate_paid_license(true, snapshot) then return true end
  return snapshot.license_status == "active" and proof_matches(snapshot)
end

local function remember_verified(resp, key, status)
  local id = M.get_device_id()
  local hardware = M.license_hardware_id()
  if not id or hardware == "" then return false end
  key = key or db.setting("license_key") or ""
  status = status or db.setting("license_status")
  local signed = M.signed_payload_data(resp) or {}
  local nested = type(resp.license) == "table" and resp.license or {}
  local expiry = signed.expires_at or nested.expires_at or resp.expires_at
  local lifetime = status == "active" and
    (expiry == nil or expiry == json.null or expiry == "")
  local trial_expiry = response_trial_expires_at(resp)
  return state_write({license_key=key, license_status=status,
    _trial_license_key=status == "trial" and key or "",
    _trial_expires_at=status == "trial" and
      (trial_expiry ~= "" and trial_expiry or db.setting("_trial_expires_at") or "") or "",
    _vendor_last_success=tostring(os.time()),
    _license_policy="1", _vendor_verified_device_id=id,
    _vendor_verified_hardware=hardware,
    _vendor_verified_license_key=key,
    _vendor_paid_expires_at=lifetime and "" or tostring(expiry or ""),
    _vendor_lifetime=lifetime and "1" or "0", _vendor_last_result="ok"})
end

local function temporary_validation_failure(status, result)
  status = tonumber(status) or 0
  return status == 408 or status == 429 or (status >= 500 and status <= 599)
end

local function activation_denial(key, result)
  if key == db.setting("license_key") and HARD_DENIAL[result] then
    db.set_setting("license_status", result)
    persist_license_state("license-validation-" .. result)
  end
end

local function record_validation_success(previous_status, current_status, resp)
  local previous_success = tonumber(db.setting("_vendor_last_success") or "0") or 0
  local previous = license_snapshot()
  if not remember_verified(resp, nil, current_status) then return false end
  local current = license_snapshot()
  local changed = false
  for _, field in ipairs(LICENSE_FIELDS) do
    if field ~= "_vendor_last_success" and previous[field] ~= current[field] then
      changed = true
    end
  end
  -- Persist transitions immediately; routine timestamp refreshes keep using
  -- the existing periodic DB sync instead of adding flash writes every poll.
  if previous_status ~= current_status or previous_success <= 0 or changed then
    return persist_license_state("license-validation-" .. current_status)
  end
  return true
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
--- Returns: "ok", "trial", "expired", "revoked", "suspended", "offline_grace", "offline_dead"
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

  -- Hardware recovery takes priority on a clean flash and while a trial is
  -- stored. A trial key must never hide a paid license bound to this router.
  local stored_trial = license_key ~= "" and (
    license_status == "trial" or license_status == "trial_expired" or
    (trial_key ~= "" and trial_key == license_key)
  )
  local known_expired_trial = trial_key ~= "" and trial_key == license_key and
    M.trial_is_expired({
      license_status = "trial",
      _trial_expires_at = db.setting("_trial_expires_at") or "",
      trial_started_at = db.setting("trial_started_at") or "0",
    })
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
    -- A previously issued trial may still validate normally, but paid
    -- recovery will be retried before it on every phone-home.
  end

  -- Build phone-home payload
  local earnings = M.collect_earnings()
  local payload = build_license_payload(license_key, device_id, earnings)

  local status, resp, body = post_and_decode(VENDOR_URL, payload)

  if not status then
    -- Network failure — check grace period
    return M.handle_offline(body)
  end

  -- Parse response
  if type(resp) ~= "table" then
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: invalid response\n")
    return M.handle_offline("invalid response")
  end

  local result = license_result(resp)
  if temporary_validation_failure(status, result) then
    return M.handle_offline("temporary license service failure (HTTP " .. tostring(status) .. ")")
  end
  if result == "device_mismatch" then
    local legacy_device_id = M.get_legacy_device_id()
    if legacy_device_id and legacy_device_id ~= "" and legacy_device_id ~= device_id then
      local retry_payload = build_license_payload(
        license_key, legacy_device_id, earnings, { hardware_device_id = device_id }
      )
      local retry_status, retry_resp = post_and_decode(VENDOR_URL, retry_payload)
      if retry_status then
        if type(retry_resp) == "table" and
            not temporary_validation_failure(retry_status, license_result(retry_resp)) then
          status = retry_status
          resp = retry_resp
          result = license_result(resp)
        end
      end
    end
  end

  if result == "ok" and not recovery_response_matches_device(resp, device_id, device_id, license_key) then
    result = "device_mismatch"
  end
  if result == "ok" then
    if is_trial_response(resp, license_key) then
      store_cloud_url(resp)
      if not record_validation_success(license_status, "trial", resp) then
        return "persistence_error"
      end
      io.write(os.date("[%H:%M:%S] ") .. "Vendor: trial valid (" .. license_key:sub(1,8) .. "...)\n")
      return "trial"
    elseif is_valid_response(resp) then
    else
      io.write(os.date("[%H:%M:%S] ") .. "Vendor: active license was not explicitly validated\n")
      return M.handle_offline("unrecognized validation response")
    end
    store_cloud_url(resp)
    if not record_validation_success(license_status, "active", resp) then
      return "persistence_error"
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
  elseif result == "suspended" then
    db.set_setting("license_status", "suspended")
    persist_license_state("license-validation-suspended")
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: license suspended\n")
    return "suspended"
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
    if known_expired_trial then
      db.set_setting("license_status", "trial_expired")
      persist_license_state("license-validation-trial-expired")
      io.write(os.date("[%H:%M:%S] ") ..
        "Vendor: expired trial not found; preserving trial-expired state\n")
      return "trial_expired"
    end
    db.set_setting("license_status", "not_found")
    persist_license_state("license-validation-not-found")
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: license not found\n")
    return "not_found"
  else
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: unknown status — " .. tostring(result) .. "\n")
    if HARD_DENIAL[result] then
      db.set_setting("license_status", result)
      persist_license_state("license-validation-" .. result)
      return result
    end
    return M.handle_offline("unrecognized validation response")
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
    -- Trial granted — store the key
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
    store_cloud_url(resp)
    db.set_setting("_vendor_last_success", tostring(os.time()))
    if not remember_verified(resp) then return "persistence_error" end
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
--- Returns a normal phone-home status when recovered, or nil when no binding exists.
local function recover_candidate(candidate_id, device_id)
  local payload = build_recover_payload(candidate_id, { hardware_device_id = device_id })
  local status, resp = post_and_decode(RECOVER_URL, payload)
  if not status then
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: license recovery unavailable\n")
    return nil, "recovery_unavailable"
  end

  if type(resp) ~= "table" then
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: license recovery returned invalid response\n")
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

  if not recovery_response_matches_device(resp, device_id, candidate_id, recovered_key) then
    io.write(os.date("[%H:%M:%S] ") ..
      "Vendor: recovery rejected due to mismatched device binding\n")
    return nil, "device_mismatch"
  end

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

  local recovered_device_id = valid_device_id(candidate_id)
  if recovered_device_id ~= "" and recovered_device_id ~= valid_device_id(device_id) and
      not persist_device_id(recovered_device_id) then
    return nil, "persistence_error"
  end
  if not remember_verified(resp, recovered_key, recovered_trial and "trial" or "active") then
    return "persistence_error"
  end
  store_cloud_url(resp)
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
  local candidates = M.get_device_id_candidates(device_id)
  if #candidates == 0 then candidates = { device_id } end

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
  local status = db.setting("license_status")
  if HARD_DENIAL[status] then return status end
  if HARD_DENIAL[db.setting("_vendor_last_result")] then
    return db.setting("_vendor_last_result")
  end
  if license_access() then return "offline_grace" end
  if status == "active" then
    db.set_setting("license_status", "unknown")
    return "unknown"
  end
  if status ~= "trial" then return status or "unknown" end
  local last_success = tonumber(db.setting("_vendor_last_success") or "0") or 0
  local now = os.time()
  local elapsed = now - last_success

  if last_success == 0 then
    -- Never successfully phoned home — allow as trial
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: offline, never validated (trial mode)\n")
    return "trial"
  end

  if elapsed <= GRACE_PERIOD_SECONDS then
    -- Within grace period — keep current status
    local days_left = math.floor((GRACE_PERIOD_SECONDS - elapsed) / 86400)
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: offline (" .. tostring(reason) .. "), grace " .. days_left .. " days left\n")
    return "offline_grace"
  else
    -- Grace period expired — lock out
    db.set_setting("license_status", "offline_expired")
    io.write(os.date("[%H:%M:%S] ") .. "Vendor: offline grace expired! Locking out.\n")
    return "offline_dead"
  end
end

-- ─── License Activation ───────────────────────────────────────────────────────

--- Activate a license key by fetching its binding, then validating it.
--- Called from admin.lua when operator pastes a key.
function M.activate_key(key)
  local device_id = M.get_device_id()
  if not device_id then
    return false, "Cannot determine device ID"
  end

  local activation_device_id = device_id
  local fetch_payload = build_license_payload(key, activation_device_id, {})
  local fetch_status, fetch_resp, fetch_err = post_and_decode(FETCH_URL, fetch_payload)

  if not fetch_status then
    return false, activation_network_error("fetch", fetch_err)
  end

  local fetch_result = type(fetch_resp) == "table" and license_result(fetch_resp) or ""
  activation_denial(key, fetch_result)

  if type(fetch_resp) ~= "table" then
    return false, fetch_status >= 400 and vendor_http_message(fetch_status) or
      "Activation could not be verified. Please try again."
  end
  if fetch_status >= 400 then
    return false, result_message(fetch_result, fetch_resp, vendor_http_message(fetch_status))
  end
  if fetch_result ~= "" and fetch_result ~= "ok" then
    return false, result_message(
      fetch_result, fetch_resp, "Activation failed. Check the license key and try again."
    )
  end

  local payload = build_license_payload(
    key, activation_device_id, {}, { hardware_device_id = device_id }
  )
  local status, resp, decode_err = post_and_decode(VENDOR_URL, payload)

  if not status then
    return false, activation_network_error("validation", decode_err)
  end

  local result = type(resp) == "table" and license_result(resp) or ""
  if result == "device_mismatch" then
    local legacy_device_id = M.get_legacy_device_id()
    if legacy_device_id and legacy_device_id ~= "" and legacy_device_id ~= device_id then
      local retry_payload = build_license_payload(
        key, legacy_device_id, {}, { hardware_device_id = device_id }
      )
      local retry_status, retry_resp = post_and_decode(VENDOR_URL, retry_payload)
      if retry_status and type(retry_resp) == "table" then
        status = retry_status
        resp = retry_resp
        result = license_result(resp)
      end
    end
  end
  if type(resp) ~= "table" then
    return false, status >= 400 and vendor_http_message(status) or
      "Activation could not be verified. Please try again."
  end
  if status >= 400 and result == "" then
    return false, vendor_http_message(status)
  end
  if result == "ok" and not recovery_response_matches_device(resp, device_id, activation_device_id, key) then
    result = "device_mismatch"
  end
  if result ~= "ok" then
    activation_denial(key, result)
    return false, result_message(
      result, resp, "Activation failed. Check the license key and try again."
    )
  end

  local trial_response = is_trial_response(resp, key)
  if not trial_response and not is_valid_response(resp) then
    return false, "Activation could not be verified. Please try again."
  end

  if not remember_verified(resp, key, trial_response and "trial" or "active") then
    return false, "Activation could not be verified. Please try again."
  end
  store_cloud_url(resp)
  if not persist_license_state("license-activate") then
    return false, "Activation could not be verified. Please try again."
  end
  io.write(os.date("[%H:%M:%S] ") .. "Vendor: license activated — " .. key:sub(1,8) .. "...\n")
  return true, "License activated successfully"
end

-- Read the same factory identifiers used by initial provisioning, without
-- creating or replacing the installed Device ID.
function M.license_hardware_id()
  local serial = read_identifier_file(DEVICE_TREE_SERIAL_PATH)
  if #serial >= 8 and not serial:match("^0+$") then
    return hashed_openwrt_id("serial", serial)
  end
  serial = read_cpu_serial()
  if serial ~= "" then return hashed_openwrt_id("cpu", serial) end
  local board = current_board_name()
  local mac = factory_mac_for_board(board)
  if mac == "" then mac = runtime_mac_with_retry(runtime_paths_for_board(board)) end
  return hashed_openwrt_id("mac", mac)
end

function M.license_saved_identity()
  local id = valid_device_id(read_identifier_file(DEVICE_ID_PATH))
  return id ~= "" and id or nil
end

-- A kernel lock serializes activation and background validation across Lua
-- processes. Nested recovery uses the same lock; customer reads never wait.
local function serialized(name)
  local original = M[name]
  M[name] = function(...)
    if license_operation_depth > 0 then return original(...) end
    local loaded, nixio = pcall(require, "nixio")
    local lock = loaded and nixio.open(
      os.getenv("TARAKIFI_LICENSE_LOCK_PATH") or "/tmp/tarakifi_license.lock", "w", "0600")
    if not lock or not lock:lock("tlock") then
      if lock then lock:close() end
      if name == "activate_key" then
        return false, "Activation could not be verified. Please try again."
      end
      if name == "recover_license" then return nil, "recovery_unavailable" end
      return "busy"
    end
    license_operation_depth = 1
    local args = {...}
    local ok, first, second = pcall(function()
      if (db.setting("license_key") or "") ~= "" and not M.license_saved_identity() then
        if name == "activate_key" then return false, "Cannot determine device ID" end
        if name == "recover_license" then return nil, "verification_required" end
        return "verification_required"
      end
      local id, hardware = M.get_device_id(), M.license_hardware_id()
      local previous_hardware = db.setting("_vendor_verified_hardware")
      if (previous_hardware and previous_hardware ~= "" and previous_hardware ~= hardware) or
          ((not previous_hardware or previous_hardware == "") and not identity_matches(id, hardware)) then
        db.set_setting("license_status", "device_mismatch")
        persist_license_state("license-hardware-mismatch")
        if name == "activate_key" then
          return false, "This license is already active on another device."
        end
        if name == "recover_license" then return nil, "device_mismatch" end
        return "device_mismatch"
      end
      migrate_paid_license()
      return original((unpack or table.unpack)(args))
    end)
    license_operation_depth = 0
    lock:close()
    if not ok then error(first, 0) end
    return first, second
  end
end
for _, name in ipairs({"phone_home", "activate_key", "recover_license", "request_trial"}) do
  serialized(name)
end

return M
