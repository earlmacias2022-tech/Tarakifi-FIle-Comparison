--- TarakiFi cloud backup coordinator.
local db = require("lib.db")
local json = require("lib.json")

local M = {}

local BOARD_SECRET = "tarakifi-board-secret-2024"
local DEFAULT_CLOUD_URL = "https://pisowifi.taraki.vip"
local BACKUP_SCRIPT = os.getenv("TARAKIFI_CLOUD_BACKUP_SCRIPT") or
  "/usr/lib/tarakifi/cloud-backup.sh"
local RESTORE_SCRIPT = os.getenv("TARAKIFI_CLOUD_RESTORE_SCRIPT") or
  "/usr/lib/tarakifi/cloud-restore.sh"
local UCLIENT_BIN = os.getenv("TARAKIFI_UCLIENT_BIN") or "/bin/uclient-fetch"
local UCI_BIN = os.getenv("TARAKIFI_UCI_BIN") or "/sbin/uci"
local VERSION_FILE = os.getenv("TARAKIFI_VERSION_FILE") or "/etc/tarakifi/version"
local ROUTER_MODEL_FILE = os.getenv("TARAKIFI_ROUTER_MODEL_FILE") or
  "/etc/tarakifi/router-model"
local WAN_STATUS_PATH = os.getenv("TARAKIFI_WAN_STATUS_PATH") or
  "/tmp/tarakifi/wan.status"
local DEBOUNCE_SECONDS = tonumber(os.getenv("TARAKIFI_CLOUD_BACKUP_DEBOUNCE")) or
  300
local MAX_BACKUP_BYTES = tonumber(os.getenv("TARAKIFI_CLOUD_BACKUP_MAX_BYTES")) or
  2 * 1024 * 1024
local TRANSACTION_BACKUP_SECONDS = tonumber(os.getenv("TARAKIFI_CLOUD_TRANSACTION_BACKUP_SECONDS")) or
  30 * 86400

local ALLOWED_REASONS = {
  voucher_change = true,
  settings_change = true,
  license_activation = true,
  coin_node_change = true,
  scheduled = true,
  pre_ota = true,
  manual = true,
}

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function shell_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function command_ok(command)
  local status, _, code = os.execute(command)
  if type(status) == "number" then return status == 0 end
  return status == true and (code == nil or code == 0)
end

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local content = file:read("*a")
  file:close()
  return content
end

local function write_file(path, content)
  local file, open_err = io.open(path, "wb")
  if not file then return false, open_err or "cannot open file" end
  local ok, write_err = file:write(content or "")
  file:close()
  if not ok then return false, write_err or "cannot write file" end
  return true
end

local function ensure_dir(path)
  return command_ok("mkdir -p " .. shell_quote(path))
end

local function read_json(path)
  local raw = read_file(path)
  if not raw or raw == "" then return nil, "empty" end
  local data, err = json.decode(raw)
  if type(data) ~= "table" then return nil, err or "invalid_json" end
  return data
end

local function write_json(path, value)
  return write_file(path, json.encode(value))
end

local function write_env(path, values)
  local lines = {}
  for _, key in ipairs({
    "LICENSE_KEY", "DEVICE_ID", "BOARD_SECRET", "CLOUD_URL",
    "ROUTER_MODEL", "FIRMWARE_VERSION"
  }) do
    lines[#lines + 1] = key .. "=" .. shell_quote(values[key] or "")
  end
  return write_file(path, table.concat(lines, "\n") .. "\n")
end

local function safe_reason(reason)
  reason = tostring(reason or "scheduled")
  if not ALLOWED_REASONS[reason] then return "manual" end
  return reason
end

local function get_vendor()
  local ok, vendor = pcall(require, "lib.vendor")
  if ok and type(vendor) == "table" then return vendor end
  return nil
end

local function read_uci(path)
  local handle = io.popen(shell_quote(UCI_BIN) .. " -q get " ..
    shell_quote(path) .. " 2>/dev/null")
  if not handle then return "" end
  local value = trim(handle:read("*l") or "")
  handle:close()
  return value
end

local function read_version()
  local version = trim(read_file(VERSION_FILE) or "")
  return version ~= "" and version or "0.0.0"
end

local function read_model()
  local model = trim(read_file("/tmp/sysinfo/model") or "")
  if model == "" then model = trim(read_file("/proc/device-tree/model") or "") end
  if model == "" then model = trim(read_file(ROUTER_MODEL_FILE) or "") end
  return model ~= "" and model or "COMFAST Router"
end

local function configured_cloud_url()
  local value = trim(db.setting("cloud_backup_url") or "")
  if value == "" or value:sub(1, 8) ~= "https://" then value = DEFAULT_CLOUD_URL end
  return value:gsub("/+$", "")
end

local function identity()
  db.init()
  local vendor = get_vendor()
  local device_id = vendor and vendor.get_device_id and vendor.get_device_id() or ""
  return {
    license_key = trim(db.setting("license_key") or ""),
    license_status = trim(db.setting("license_status") or ""),
    device_id = trim(device_id or ""),
    board_secret = BOARD_SECRET,
    cloud_url = configured_cloud_url(),
    router_model = read_model(),
    firmware_version = read_version(),
  }
end

local function has_active_license(id)
  return id.license_key ~= "" and id.device_id ~= "" and id.license_status == "active"
end

local function url_encode(value)
  value = tostring(value or "")
  return (value:gsub("([^A-Za-z0-9_%.%-%~])", function(char)
    return string.format("%%%02X", string.byte(char))
  end))
end

function M.is_enabled()
  db.init()
  return db.setting("cloud_backup_enabled") == "1"
end

function M.set_enabled(enabled)
  local value = (enabled == true or enabled == 1 or enabled == "1") and "1" or "0"
  local cloud_url = trim(db.setting("cloud_backup_url") or "")
  if cloud_url == "" or cloud_url:sub(1, 8) ~= "https://" then
    cloud_url = DEFAULT_CLOUD_URL
  end
  local saved, err = db.set_settings_atomic({
    {key = "cloud_backup_enabled", value = value},
    {key = "cloud_backup_url", value = cloud_url:gsub("/+$", "")},
  })
  if not saved then return false, err end
  return db.persist("cloud-backup-toggle", true)
end

function M.schedule(reason, options)
  options = options or {}
  reason = safe_reason(reason)
  if not M.is_enabled() then return false, "disabled" end
  if not has_active_license(identity()) then return false, "not_activated" end

  local now = os.time()
  local last = tonumber(db.setting("_cloud_backup_last_trigger_at") or "0") or 0
  if not options.force and last > 0 and now - last < DEBOUNCE_SECONDS then
    return false, "debounced"
  end
  db.set_runtime_setting("_cloud_backup_last_trigger_at", tostring(now))
  command_ok("sh " .. shell_quote(BACKUP_SCRIPT) .. " " .. shell_quote(reason) ..
    " >/dev/null 2>&1 &")
  return true, "scheduled"
end

function M.run_now(reason)
  reason = safe_reason(reason)
  if not M.is_enabled() then return false, "disabled" end
  if not has_active_license(identity()) then return false, "not_activated" end
  command_ok("sh " .. shell_quote(BACKUP_SCRIPT) .. " " .. shell_quote(reason) ..
    " >/dev/null 2>&1")
  return true, "finished"
end

function M.restore_now(backup_id)
  if not has_active_license(identity()) then return false, "not_activated" end
  local arg = ""
  if backup_id ~= nil and tostring(backup_id) ~= "" then
    arg = " " .. shell_quote(tostring(backup_id))
  end
  command_ok("sh " .. shell_quote(RESTORE_SCRIPT) .. arg .. " >/dev/null 2>&1 &")
  return true, "restore_started"
end

local function fetch_cloud_json(endpoint)
  local id = identity()
  if not has_active_license(id) then return nil, "not_activated" end
  local sep = endpoint:find("?", 1, true) and "&" or "?"
  local url = id.cloud_url .. endpoint .. sep .. "license_key=" ..
    url_encode(id.license_key) .. "&device_id=" .. url_encode(id.device_id)
  local path = "/tmp/tarakifi-cloud-" .. tostring(os.time()) .. "-" ..
    tostring(math.floor(os.clock() * 1000000)) .. ".json"
  local command = table.concat({
    shell_quote(UCLIENT_BIN),
    "--timeout=15",
    "--header=" .. shell_quote("X-Board-Secret: " .. BOARD_SECRET),
    "-q -O", shell_quote(path),
    shell_quote(url),
    ">/dev/null 2>&1"
  }, " ")
  if not command_ok(command) then
    os.remove(path)
    return nil, "fetch_failed"
  end
  local data, err = read_json(path)
  os.remove(path)
  return data, err
end

function M.status()
  local id = identity()
  local response = {
    enabled = M.is_enabled(),
    configured = has_active_license(id),
    last_backup_at = tonumber(db.setting("_cloud_backup_last_success_at") or "0") or 0,
    last_backup_reason = db.setting("_cloud_backup_last_reason") or "",
    last_backup_version = tonumber(db.setting("_cloud_backup_last_version") or "0") or 0,
    last_error_at = tonumber(db.setting("_cloud_backup_last_error_at") or "0") or 0,
  }

  if response.enabled and response.configured then
    local list = fetch_cloud_json("/api/router/backup/list")
    if list and type(list.backups) == "table" then
      response.total_backups = #list.backups
      response.backups = list.backups
      response.latest = list.backups[1]
    end
  end
  return response
end

local function metadata_table(id, reason)
  return {
    license_key = id.license_key,
    device_id = id.device_id,
    board_secret = id.board_secret,
    cloud_url = id.cloud_url,
    router_model = id.router_model,
    firmware_version = id.firmware_version,
    reason = reason,
    created_at = os.time(),
    backup_schema = 1,
  }
end

function M.export_payload(workdir, reason)
  reason = safe_reason(reason)
  workdir = tostring(workdir or "")
  if workdir == "" then return false, "missing_workdir" end
  if not M.is_enabled() then return false, "disabled" end

  local id = identity()
  if not has_active_license(id) then return false, "not_activated" end
  local payload_dir = workdir .. "/payload"
  if not ensure_dir(payload_dir) then return false, "cannot_create_payload_dir" end

  local meta = metadata_table(id, reason)
  write_env(workdir .. "/meta.env", {
    LICENSE_KEY = id.license_key,
    DEVICE_ID = id.device_id,
    BOARD_SECRET = id.board_secret,
    CLOUD_URL = id.cloud_url,
    ROUTER_MODEL = id.router_model,
    FIRMWARE_VERSION = id.firmware_version,
  })
  write_json(workdir .. "/metadata.json", meta)

  local now = os.time()
  write_json(payload_dir .. "/settings.json", {
    settings = db.query([[
      SELECT key, value FROM settings
      WHERE key NOT LIKE '\_%' ESCAPE '\' AND key <> 'admin_password'
        AND key NOT LIKE 'license%' AND key NOT LIKE 'trial%'
        AND key NOT IN ('device_id', 'instance_device_id', 'hardware_device_id', 'hashed_device_id')
      ORDER BY key
    ]])
  })
  write_json(payload_dir .. "/vouchers.db", {
    vouchers = db.query([[
      SELECT id, code, minutes, price_php, status, batch_label, created_at,
             validity_seconds, activated_at, valid_until, redeemed_at,
             redeemed_by_mac, archived
      FROM vouchers WHERE archived = 0 ORDER BY id
    ]])
  })
  write_json(payload_dir .. "/coin_nodes.json", {
    coin_nodes = db.query([[
      SELECT node_id, name, last_heartbeat, ip_address, total_coins, area_id,
             fw_version, coin_dpin, relay_dpin, coin_gpio, relay_gpio, rssi,
             conn_mode, bind_code, auth_token, protocol_version, auth_enrolled_at
      FROM coin_nodes ORDER BY node_id
    ]])
  })
  write_json(payload_dir .. "/identity.json", meta)
  write_json(payload_dir .. "/wifi_branding.json", {
    ssid_2g = read_uci("wireless.default_radio0.ssid"),
    ssid_5g = read_uci("wireless.default_radio1.ssid"),
    business_name = db.setting("business_name") or "",
    portal_name = db.setting("portal_name") or "",
    portal_footer_text = db.setting("portal_footer_text") or "",
    portal_theme = db.setting("portal_theme") or "dark",
  })
  write_json(payload_dir .. "/active_sessions.json", {
    sessions = db.query([[
      SELECT mac, minutes_remaining, started_at, expires_at, last_seen, paused
      FROM sessions
      WHERE paused = 1 OR (paused = 0 AND expires_at > ?)
      ORDER BY last_seen DESC
    ]], now)
  })
  write_json(payload_dir .. "/transactions_recent.json", {
    transactions = db.query([[
      SELECT id, mac, amount_php, minutes_granted, source, created_at
      FROM transactions
      WHERE created_at >= ?
      ORDER BY created_at DESC
    ]], now - TRANSACTION_BACKUP_SECONDS)
  })
  return true
end

function M.write_upload_request(workdir, data_file, sha256, output_file)
  local meta, meta_err = read_json(tostring(workdir or "") .. "/metadata.json")
  if not meta then return false, meta_err end
  local backup_data = read_file(data_file)
  if not backup_data or backup_data == "" then return false, "empty_backup_data" end
  local payload = {
    license_key = meta.license_key,
    device_id = meta.device_id,
    router_model = meta.router_model,
    firmware_version = meta.firmware_version,
    reason = safe_reason(meta.reason),
    sha256 = tostring(sha256 or ""),
    backup_data = backup_data:gsub("%s+", ""),
  }
  if #payload.backup_data > MAX_BACKUP_BYTES * 2 then return false, "backup_too_large" end
  return write_json(output_file, payload)
end

function M.record_upload_result(response_file, reason)
  db.init()
  reason = safe_reason(reason)
  local data = read_json(response_file)
  if data and data.ok == true then
    db.set_runtime_setting("_cloud_backup_last_success_at", tostring(os.time()))
    db.set_runtime_setting("_cloud_backup_last_reason", reason)
    db.set_runtime_setting("_cloud_backup_last_version", tostring(data.backup_version or 0))
    db.set_runtime_setting("_cloud_backup_last_error_at", "0")
    return true
  end
  db.set_runtime_setting("_cloud_backup_last_error_at", tostring(os.time()))
  return false, "upload_failed"
end

function M.prepare_restore_request(workdir, backup_id)
  workdir = tostring(workdir or "")
  if workdir == "" then return false, "missing_workdir" end
  if not ensure_dir(workdir) then return false, "cannot_create_workdir" end
  local id = identity()
  if not has_active_license(id) then return false, "not_activated" end
  write_env(workdir .. "/meta.env", {
    LICENSE_KEY = id.license_key,
    DEVICE_ID = id.device_id,
    BOARD_SECRET = id.board_secret,
    CLOUD_URL = id.cloud_url,
    ROUTER_MODEL = id.router_model,
    FIRMWARE_VERSION = id.firmware_version,
  })
  local backup_json = "null"
  if backup_id ~= nil and tostring(backup_id) ~= "" then
    local numeric = tonumber(backup_id)
    if numeric and numeric > 0 then backup_json = tostring(math.floor(numeric)) end
  end
  local body = "{" ..
    "\"license_key\":" .. json.encode(id.license_key) .. "," ..
    "\"device_id\":" .. json.encode(id.device_id) .. "," ..
    "\"backup_id\":" .. backup_json ..
    "}"
  return write_file(workdir .. "/restore-token-request.json", body)
end

function M.print_restore_token(response_file)
  local data = read_json(response_file)
  local token = data and trim(data.restore_token or "") or ""
  if token == "" or #token > 128 or not token:match("^[A-Fa-f0-9]+$") then
    return false, "missing_token"
  end
  io.write(token)
  return true
end

function M.write_download_env(response_file, output_file)
  local data = read_json(response_file)
  if not data or data.ok ~= true then return false, "download_unavailable" end
  local download_url = trim(data.download_url or "")
  local sha256 = trim(data.sha256 or ""):lower()
  if download_url:sub(1, 8) ~= "https://" then return false, "invalid_download_url" end
  if #sha256 ~= 64 or not sha256:match("^%x+$") then return false, "invalid_sha256" end
  return write_file(output_file,
    "DOWNLOAD_URL=" .. shell_quote(download_url) ..
    "\nEXPECTED_SHA=" .. shell_quote(sha256) .. "\n")
end

local function load_array(path, key)
  local data = read_json(path)
  if not data or type(data[key]) ~= "table" then return {} end
  return data[key]
end

local function restore_settings(path)
  local entries = {}
  local license = require("lib.vendor")
  for _, row in ipairs(load_array(path, "settings")) do
    local key = tostring(row.key or "")
    if key ~= "admin_password" and license.license_setting_restorable(key) then
      entries[#entries + 1] = {key = key, value = tostring(row.value or "")}
    end
  end
  if #entries == 0 then return true end
  return db.set_settings_atomic(entries)
end

local function restore_vouchers(path)
  for _, row in ipairs(load_array(path, "vouchers")) do
    if row.code and tostring(row.code) ~= "" then
      db.exec([[
        INSERT INTO vouchers
          (code, minutes, price_php, status, batch_label, created_at,
           validity_seconds, activated_at, valid_until, redeemed_at,
           redeemed_by_mac, archived)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(code) DO UPDATE SET
          minutes = excluded.minutes,
          price_php = excluded.price_php,
          status = excluded.status,
          batch_label = excluded.batch_label,
          created_at = excluded.created_at,
          validity_seconds = excluded.validity_seconds,
          activated_at = excluded.activated_at,
          valid_until = excluded.valid_until,
          redeemed_at = excluded.redeemed_at,
          redeemed_by_mac = excluded.redeemed_by_mac,
          archived = excluded.archived
      ]], row.code, tonumber(row.minutes) or 0, tonumber(row.price_php) or 0,
        tostring(row.status or "unused"), tostring(row.batch_label or ""),
        tonumber(row.created_at) or 0, tonumber(row.validity_seconds) or 0,
        tonumber(row.activated_at) or 0, tonumber(row.valid_until) or 0,
        tonumber(row.redeemed_at) or 0, tostring(row.redeemed_by_mac or ""),
        tonumber(row.archived) or 0)
    end
  end
  return true
end

local function restore_coin_nodes(path)
  for _, row in ipairs(load_array(path, "coin_nodes")) do
    if row.node_id and tostring(row.node_id) ~= "" then
      db.exec([[
        INSERT INTO coin_nodes
          (node_id, name, last_heartbeat, ip_address, total_coins, area_id,
           fw_version, coin_dpin, relay_dpin, coin_gpio, relay_gpio, rssi,
           conn_mode, bind_code, auth_token, protocol_version, auth_enrolled_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(node_id) DO UPDATE SET
          name = excluded.name,
          ip_address = excluded.ip_address,
          total_coins = excluded.total_coins,
          area_id = excluded.area_id,
          fw_version = excluded.fw_version,
          coin_dpin = excluded.coin_dpin,
          relay_dpin = excluded.relay_dpin,
          coin_gpio = excluded.coin_gpio,
          relay_gpio = excluded.relay_gpio,
          rssi = excluded.rssi,
          conn_mode = excluded.conn_mode,
          bind_code = excluded.bind_code,
          auth_token = excluded.auth_token,
          protocol_version = excluded.protocol_version,
          auth_enrolled_at = excluded.auth_enrolled_at
      ]], row.node_id, tostring(row.name or row.node_id),
        tonumber(row.last_heartbeat) or 0, tostring(row.ip_address or ""),
        tonumber(row.total_coins) or 0, tonumber(row.area_id) or 1,
        tostring(row.fw_version or ""), tonumber(row.coin_dpin) or 1,
        tonumber(row.relay_dpin) or 2, tonumber(row.coin_gpio) or 5,
        tonumber(row.relay_gpio) or 4, tonumber(row.rssi) or 0,
        tostring(row.conn_mode or "wifi"), tostring(row.bind_code or ""),
        tostring(row.auth_token or ""), tonumber(row.protocol_version) or 1,
        tonumber(row.auth_enrolled_at) or 0)
    end
  end
  return true
end

local function restore_sessions(path)
  local now = os.time()
  for _, row in ipairs(load_array(path, "sessions")) do
    local mac = tostring(row.mac or ""):upper()
    local paused = tonumber(row.paused) or 0
    local expires_at = tonumber(row.expires_at) or 0
    if mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") and
        (paused == 1 or expires_at > now) then
      db.exec([[
        INSERT OR REPLACE INTO sessions
          (mac, minutes_remaining, started_at, expires_at, last_seen, paused)
        VALUES (?, ?, ?, ?, ?, ?)
      ]], mac, tonumber(row.minutes_remaining) or 0,
        tonumber(row.started_at) or 0, expires_at,
        tonumber(row.last_seen) or now, paused)
    end
  end
  return true
end

local function restore_recent_transactions(path)
  for _, row in ipairs(load_array(path, "transactions")) do
    local id = tonumber(row.id)
    if id and id > 0 then
      db.exec([[
        INSERT OR IGNORE INTO transactions
          (id, mac, amount_php, minutes_granted, source, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
      ]], id, tostring(row.mac or ""), tonumber(row.amount_php) or 0,
        tonumber(row.minutes_granted) or 0, tostring(row.source or "coin"),
        tonumber(row.created_at) or 0)
    end
  end
  return true
end

local function restore_wifi(path)
  local data = read_json(path)
  if not data then return true end
  local changed = false
  if trim(data.ssid_2g or "") ~= "" then
    command_ok(shell_quote(UCI_BIN) .. " -q set wireless.default_radio0.ssid=" ..
      shell_quote(trim(data.ssid_2g)))
    changed = true
  end
  if trim(data.ssid_5g or "") ~= "" then
    command_ok(shell_quote(UCI_BIN) .. " -q set wireless.default_radio1.ssid=" ..
      shell_quote(trim(data.ssid_5g)))
    changed = true
  end
  if changed then
    command_ok(shell_quote(UCI_BIN) .. " -q commit wireless >/dev/null 2>&1")
  end
  return true
end

function M.restore_payload(payload_dir)
  payload_dir = tostring(payload_dir or "")
  if payload_dir == "" then return false, "missing_payload_dir" end
  db.init()
  local current = identity()
  if not has_active_license(current) then return false, "not_activated" end

  for _, name in ipairs({"settings.json", "vouchers.db", "coin_nodes.json", "identity.json"}) do
    if not read_file(payload_dir .. "/" .. name) then
      return false, "missing_" .. name
    end
  end

  local id = read_json(payload_dir .. "/identity.json")
  if id and id.license_key and tostring(id.license_key) ~= current.license_key then
    return false, "license_mismatch"
  end

  local ok, err = restore_settings(payload_dir .. "/settings.json")
  if not ok then return false, err end
  db.exec("DELETE FROM vouchers")
  db.exec("DELETE FROM coin_nodes")
  db.exec("DELETE FROM sessions")
  restore_vouchers(payload_dir .. "/vouchers.db")
  restore_coin_nodes(payload_dir .. "/coin_nodes.json")
  restore_sessions(payload_dir .. "/active_sessions.json")
  restore_recent_transactions(payload_dir .. "/transactions_recent.json")
  restore_wifi(payload_dir .. "/wifi_branding.json")

  local persisted, persist_err = db.persist("cloud-restore", true)
  if not persisted then return false, persist_err end
  db.set_runtime_setting("_cloud_restore_last_success_at", tostring(os.time()))
  return true
end

function M.claim_scheduled_day()
  if not M.is_enabled() then return false, "disabled" end
  if not has_active_license(identity()) then return false, "not_activated" end
  local day = os.date("!%Y-%m-%d", os.time() + 8 * 3600)
  if db.setting("_cloud_backup_last_scheduled_day") == day then
    return false, "not_due"
  end
  db.set_runtime_setting("_cloud_backup_last_scheduled_day", day)
  return true
end

function M.wan_status_online(path, now)
  path = path or WAN_STATUS_PATH
  local raw = read_file(path) or ""
  local checked_at, result = raw:match("^(%d+)|([01])")
  checked_at = tonumber(checked_at) or 0
  local age = (now or os.time()) - checked_at
  return result == "1" and age >= 0 and age <= 120
end

return M
