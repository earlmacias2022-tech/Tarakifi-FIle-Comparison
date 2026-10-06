--- TarakiFi Admin API Handler
-- Full admin panel with session management, vouchers, bandwidth, scheduling,
-- backup/restore, OTA, asset upload, license activation, system info.
local db = require("lib.db")
local session = require("lib.session")
local clients = require("lib.clients")
local json = require("lib.json")
local util = require("lib.util")
local M = {}

local CRON_FILE = os.getenv("TARAKIFI_CRON_FILE") or "/etc/crontabs/root"
local CRON_RESTART_COMMAND = os.getenv("TARAKIFI_CRON_RESTART_COMMAND") or
  "/etc/init.d/cron restart >/dev/null 2>&1"
local NFT_BIN = os.getenv("TARAKIFI_NFT_BIN") or "/usr/sbin/nft"
local DNSMASQ_BIN = os.getenv("TARAKIFI_DNSMASQ_BIN") or "/usr/sbin/dnsmasq"
local DNSMASQ_RESTART_COMMAND = os.getenv("TARAKIFI_DNSMASQ_RESTART_COMMAND") or
  "/etc/init.d/dnsmasq restart >/dev/null 2>&1"
local DHCP_CONFIG_FILE = os.getenv("TARAKIFI_DHCP_CONFIG_FILE") or
  "/etc/config/dhcp"
local DHCP_LEASES_FILE = os.getenv("TARAKIFI_DHCP_LEASES_FILE") or
  "/tmp/dhcp.leases"
local DNSMASQ_BLOCK_FILE = os.getenv("TARAKIFI_DNSMASQ_BLOCK_FILE") or
  "/etc/dnsmasq.d/blocked.conf"
local BW_RULES_FILE = os.getenv("TARAKIFI_BW_RULES_FILE") or "/tmp/tarakifi_bw.nft"
local UPSTREAM_RULES_FILE = os.getenv("TARAKIFI_UPSTREAM_RULES_FILE") or
  "/tmp/tarakifi_upstream.nft"
local ANTI_TETHERING_RULES_FILE = os.getenv("TARAKIFI_ANTI_TETHERING_RULES_FILE") or
  "/tmp/tarakifi_anti_tethering.nft"
local WAN_ACCESS_RULES_FILE = os.getenv("TARAKIFI_WAN_ACCESS_RULES_FILE") or
  "/tmp/tarakifi_wan_access.nft"
local UCI_BIN = os.getenv("TARAKIFI_UCI_BIN") or "/sbin/uci"
local UBUS_BIN = os.getenv("TARAKIFI_UBUS_BIN") or "/bin/ubus"
local JSONFILTER_BIN = os.getenv("TARAKIFI_JSONFILTER_BIN") or "/usr/bin/jsonfilter"
local NETWORK_RELOAD_COMMAND = os.getenv("TARAKIFI_NETWORK_RELOAD_COMMAND") or
  "/etc/init.d/network reload >/dev/null 2>&1"
local WAN_IFUP_COMMAND = os.getenv("TARAKIFI_WAN_IFUP_COMMAND") or
  "/sbin/ifup wan >/dev/null 2>&1"
local FIREWALL_RECOVERY_COMMAND = os.getenv("TARAKIFI_FIREWALL_RECOVERY_COMMAND") or
  "/etc/init.d/tarakifi recover_firewall >/dev/null 2>&1"
local PPPOE_SUPPORT_FILE = os.getenv("TARAKIFI_PPPOE_SUPPORT_FILE") or
  "/etc/tarakifi/pppoe-supported"
local WIFI_RELOAD_COMMAND = os.getenv("TARAKIFI_WIFI_RELOAD_COMMAND") or
  "/sbin/wifi reload"
local WIFI_RELOAD_DELAY_SECONDS = tonumber(
  os.getenv("TARAKIFI_WIFI_RELOAD_DELAY_SECONDS")
) or 2
if WIFI_RELOAD_DELAY_SECONDS < 0 or WIFI_RELOAD_DELAY_SECONDS > 10 then
  WIFI_RELOAD_DELAY_SECONDS = 2
end
local WIFI_RELOAD_SYNC = os.getenv("TARAKIFI_WIFI_RELOAD_SYNC") == "1"
local SSH_AUTHORIZED_KEYS_FILE = os.getenv("TARAKIFI_SSH_AUTHORIZED_KEYS_FILE") or
  "/etc/dropbear/authorized_keys"
local DROPBEAR_RESTART_COMMAND = os.getenv("TARAKIFI_DROPBEAR_RESTART_COMMAND") or
  "/etc/init.d/dropbear restart >/dev/null 2>&1"
local OTA_MANIFEST_URL = os.getenv("TARAKIFI_OTA_MANIFEST_URL") or
  "https://pisowifi.taraki.vip/api/releases/openwrt/latest"
local OTA_PROXY_URL = os.getenv("TARAKIFI_OTA_PROXY_URL") or
  "https://pisowifi.taraki.vip/api/releases/openwrt/download"
local OTA_MANIFEST_PATH = os.getenv("TARAKIFI_OTA_MANIFEST_PATH") or
  "/tmp/ota_manifest.json"
local OTA_CHECK_PATH = os.getenv("TARAKIFI_OTA_CHECK_PATH") or
  "/tmp/ota_check.json"
local OTA_FIRMWARE_PATH = os.getenv("TARAKIFI_OTA_FIRMWARE_PATH") or
  "/tmp/firmware.bin"
local MANUAL_FIRMWARE_PATH = os.getenv("TARAKIFI_MANUAL_FIRMWARE_PATH") or
  "/tmp/tarakifi-manual-firmware.bin"
local MANUAL_FIRMWARE_PART_PATH = os.getenv("TARAKIFI_MANUAL_FIRMWARE_PART_PATH") or
  "/tmp/tarakifi-manual-firmware.bin.part"
local MANUAL_FIRMWARE_STATE_PATH = os.getenv("TARAKIFI_MANUAL_FIRMWARE_STATE_PATH") or
  "/tmp/tarakifi-manual-firmware.state"
local MANUAL_CONFIG_BACKUP_PATH = os.getenv("TARAKIFI_MANUAL_CONFIG_BACKUP_PATH") or
  "/tmp/tarakifi-manual-upgrade-backup.tgz"
local UCLIENT_BIN = os.getenv("TARAKIFI_UCLIENT_BIN") or "/bin/uclient-fetch"
local SYSUPGRADE_BIN = os.getenv("TARAKIFI_SYSUPGRADE_BIN") or "/sbin/sysupgrade"
local SHA256_BIN = os.getenv("TARAKIFI_SHA256_BIN") or "/usr/bin/sha256sum"
local SYNC_COMMAND = os.getenv("TARAKIFI_SYNC_COMMAND") or "/bin/sync"
local VERSION_FILE = os.getenv("TARAKIFI_VERSION_FILE") or "/etc/tarakifi/version"
local BOARD_NAME_FILE = os.getenv("TARAKIFI_BOARD_NAME_FILE") or "/tmp/sysinfo/board_name"
local E314N_BOARD_NAME = "comfast,cf-e314n-v2"
local SYSUPGRADE_SYNC = os.getenv("TARAKIFI_SYSUPGRADE_SYNC") == "1"
local MAX_MANUAL_FIRMWARE_BYTES = tonumber(
  os.getenv("TARAKIFI_MAX_MANUAL_FIRMWARE_BYTES")
) or 16 * 1024 * 1024
local MIN_OTA_TMP_FREE_KB = tonumber(
  os.getenv("TARAKIFI_OTA_MIN_TMP_FREE_KB")
) or 12 * 1024
local ROUTER_MODEL_FILE = os.getenv("TARAKIFI_ROUTER_MODEL_FILE") or
  "/etc/tarakifi/router-model"
local MANUAL_UPLOAD_CHUNK_BYTES = tonumber(
  os.getenv("TARAKIFI_MANUAL_UPLOAD_CHUNK_BYTES")
) or 64 * 1024
if MANUAL_UPLOAD_CHUNK_BYTES < 4096 or MANUAL_UPLOAD_CHUNK_BYTES > 262144 then
  MANUAL_UPLOAD_CHUNK_BYTES = 64 * 1024
end
local MAX_MANUAL_UPLOAD_CHUNK_BYTES = tonumber(
  os.getenv("TARAKIFI_MAX_MANUAL_UPLOAD_CHUNK_BYTES")
) or 512 * 1024
if MAX_MANUAL_UPLOAD_CHUNK_BYTES < 64 * 1024
    or MAX_MANUAL_UPLOAD_CHUNK_BYTES > 1024 * 1024 then
  MAX_MANUAL_UPLOAD_CHUNK_BYTES = 512 * 1024
end

-- Only settings required by the operator console may cross the API boundary.
local SETTINGS_FIELDS = {
  "business_name", "portal_show_business_name", "portal_name", "portal_footer_text",
  "portal_show_rates", "portal_rates", "coin_min_per_php",
  "coinslot_timeout_seconds", "coinslot_busy_lock",
  "coinslot_max_empty_opens", "coinslot_empty_open_window_seconds",
  "coinslot_empty_open_cooldown_seconds",
  "site_blocking_enabled", "blocked_sites",
  "upstream_ip_blocking_enabled", "blocked_upstream_ips",
  "anti_tethering_enabled",
  "bw_mode", "bw_per_client_down_kbps", "bw_per_client_up_kbps",
  "bw_total_down_kbps", "bw_total_up_kbps", "bw_exempt_macs",
  "pause_rules", "pause_penalty_minutes", "auto_pause_on_disconnect",
  "free_time_enabled", "free_time_minutes", "free_time_daily_limit",
  "free_time_schedule_days", "free_time_schedule_start", "free_time_schedule_end",
  "portal_hide_device_info", "portal_hide_pause_button",
  "portal_show_voucher", "portal_show_coin",
  "portal_logo_filename", "portal_logo_file", "portal_hero_file",
  "portal_coin_sound_file", "portal_tick_sound_file",
  "portal_asset_version",
  "portal_coin_sound_enabled", "portal_tick_sound_enabled",
  "portal_theme", "cloud_backup_enabled"
}
local EDITABLE_SETTINGS = {}
for _, key in ipairs(SETTINGS_FIELDS) do EDITABLE_SETTINGS[key] = true end

local function with_cloud_backup(callback)
  local ok, cloud = pcall(require, "lib.cloud_backup")
  if not ok or type(cloud) ~= "table" then return false, nil, "unavailable" end
  local called, result, detail = pcall(callback, cloud)
  if not called then return false, nil, "failed" end
  return true, result, detail
end

local function schedule_cloud_backup(reason, options)
  with_cloud_backup(function(cloud)
    return cloud.schedule(reason, options)
  end)
end

local function valid_mac(value)
  local mac = tostring(value or ""):upper()
  if mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then return mac end
  return nil
end

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local PUBLIC_LICENSE_ERRORS = {
  ["Unable to contact the license service. Check the router's internet connection and try again."] = true,
  ["License expired."] = true,
  ["License revoked."] = true,
  ["This license is already active on another device."] = true,
  ["License not found."] = true,
  ["License service is unavailable. Please try again later."] = true,
  ["This license cannot be activated on this router."] = true,
  ["License service is temporarily unavailable. Please try again later."] = true,
  ["Activation failed. Check the license key and try again."] = true,
  ["Activation could not be verified. Please try again."] = true,
}

local function public_license_error(message)
  message = trim(message)
  if PUBLIC_LICENSE_ERRORS[message] then return message end
  return "Unable to activate the license. Please try again."
end

local function mask_license_key(value)
  local key = trim(value)
  if key == "" then return "" end
  if #key <= 12 then return key end
  return key:sub(1, 8) .. "..." .. key:sub(-4)
end

local function read_board_name()
  local file = io.open(BOARD_NAME_FILE, "r")
  if not file then return nil end
  local board_name = trim(file:read("*l") or "")
  file:close()
  if board_name == "" or #board_name > 128 or
      not board_name:match("^[%w%._,%-]+$") then
    return nil
  end
  return board_name
end

local function persistent_media_uploads_supported()
  return read_board_name() ~= E314N_BOARD_NAME
end

M._persistent_media_uploads_supported = persistent_media_uploads_supported

local function append_board_param(url, board_name)
  if not board_name then return url end
  if url:find("[?&]board=") then return url end
  local separator = url:find("?", 1, true) and "&" or "?"
  return url .. separator .. "board=" .. board_name
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function command_ok(command)
  local result = os.execute(command)
  return result == true or result == 0
end

local function fetch_file(url, path, timeout)
  os.remove(path)
  local command = table.concat({
    shell_quote(UCLIENT_BIN),
    "--timeout=" .. tostring(timeout),
    "-q -O", shell_quote(path), shell_quote(url),
    ">/dev/null 2>&1"
  }, " ")
  if command_ok(command) then return true end
  os.remove(path)
  return false
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
  local wrote, write_err = file:write(content)
  file:close()
  if not wrote then return false, write_err or "cannot write file" end
  return true
end

local function file_size(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local size = file:seek("end")
  file:close()
  return size
end

local function sha256_file(path)
  local handle = io.popen(shell_quote(SHA256_BIN) .. " " .. shell_quote(path) .. " 2>/dev/null")
  local output = (handle and handle:read("*a") or "")
  if handle then handle:close() end
  return output:match("^(%x+)")
end

local function fs_available_kb(path)
  local command = "df -k " .. shell_quote(path) .. " 2>/dev/null | awk 'NR==2 {print $4}'"
  local handle = io.popen(command)
  local output = (handle and handle:read("*l") or "")
  if handle then handle:close() end
  return tonumber(output) or 0
end

local function form_part_value(part, default)
  if type(part) == "table" then return part.value or default end
  if part ~= nil then return part end
  return default
end

local function manual_filename(env, params)
  local headers = (env and type(env.headers) == "table") and env.headers or {}
  local name = tostring(headers["x-tarakifi-firmware-name"] or (params or {}).filename or "")
  name = name:gsub("\\", "/"):match("([^/]+)$") or name
  name = trim(name)
  if name == "" or #name > 160 then return nil end
  return name
end

local function upload_chunk(upload, size)
  local first, second = upload.recv(size)
  if type(second) == "string" then return second end
  if type(first) == "string" then return first end
  return nil
end

local function stage_manual_firmware(upload, expected_size)
  os.remove(MANUAL_FIRMWARE_PATH)
  local file, open_err = io.open(MANUAL_FIRMWARE_PATH, "wb")
  if not file then return false, open_err or "Cannot stage firmware." end

  local remaining = expected_size
  local written = 0
  while remaining > 0 do
    local chunk = upload_chunk(upload, math.min(MANUAL_UPLOAD_CHUNK_BYTES, remaining))
    if not chunk or chunk == "" then
      file:close()
      os.remove(MANUAL_FIRMWARE_PATH)
      return false, "Firmware upload stopped before completion."
    end
    if #chunk > remaining then chunk = chunk:sub(1, remaining) end
    local ok, write_err = file:write(chunk)
    if not ok then
      file:close()
      os.remove(MANUAL_FIRMWARE_PATH)
      return false, write_err or "Cannot stage firmware."
    end
    written = written + #chunk
    remaining = remaining - #chunk
    if written % (1024 * 1024) == 0 then collectgarbage("collect") end
  end

  file:close()
  collectgarbage("collect")
  return true, nil, written
end

local function cleanup_manual_firmware_upload()
  os.remove(MANUAL_FIRMWARE_PATH)
  os.remove(MANUAL_FIRMWARE_PART_PATH)
  os.remove(MANUAL_FIRMWARE_STATE_PATH)
  os.remove(MANUAL_CONFIG_BACKUP_PATH)
end

local function manual_upload_id(value)
  value = trim(value or "")
  if value == "" or #value > 80 then return nil end
  if not value:match("^[A-Za-z0-9._-]+$") then return nil end
  return value
end

local function read_manual_upload_state()
  local raw = read_file(MANUAL_FIRMWARE_STATE_PATH)
  if not raw or raw == "" then return nil end
  local state = {}
  for line in raw:gmatch("[^\r\n]+") do
    local key, value = line:match("^([A-Za-z0-9_]+)=(.*)$")
    if key then state[key] = value end
  end
  return state
end

local function write_manual_upload_state(state)
  local lines = {
    "upload_id=" .. tostring(state.upload_id or ""),
    "filename=" .. tostring(state.filename or ""),
    "mode=" .. tostring(state.mode or ""),
    "total=" .. tostring(state.total or ""),
    "created_at=" .. tostring(state.created_at or os.time()),
  }
  return write_file(MANUAL_FIRMWARE_STATE_PATH, table.concat(lines, "\n") .. "\n")
end

local function manual_state_matches(state, upload_id, filename, mode, total)
  if type(state) ~= "table" then return false end
  return state.upload_id == upload_id
    and state.filename == filename
    and state.mode == mode
    and tonumber(state.total or "") == total
end

local function stage_manual_chunk(upload, expected_size)
  local file, open_err = io.open(MANUAL_FIRMWARE_PART_PATH, "ab")
  if not file then return false, open_err or "Cannot stage firmware chunk." end

  local remaining = expected_size
  local written = 0
  while remaining > 0 do
    local chunk = upload_chunk(upload, math.min(MANUAL_UPLOAD_CHUNK_BYTES, remaining))
    if not chunk or chunk == "" then
      file:close()
      cleanup_manual_firmware_upload()
      return false, "Firmware upload stopped before completion."
    end
    if #chunk > remaining then chunk = chunk:sub(1, remaining) end
    local ok, write_err = file:write(chunk)
    if not ok then
      file:close()
      cleanup_manual_firmware_upload()
      return false, write_err or "Cannot stage firmware chunk."
    end
    written = written + #chunk
    remaining = remaining - #chunk
    if written % (256 * 1024) == 0 then collectgarbage("collect") end
  end

  file:close()
  collectgarbage("collect")
  return true, nil, written
end

local function validate_manual_update_mode(params)
  local mode = trim(tostring(form_part_value((params or {}).mode, "fresh") or "fresh"))
  if mode == "" then mode = "fresh" end
  if mode ~= "fresh" and mode ~= "preserve" then return nil end
  return mode
end

local function apply_manual_firmware(size, mode)
  local staged_size = file_size(MANUAL_FIRMWARE_PATH) or 0
  if staged_size ~= size then
    cleanup_manual_firmware_upload()
    return 500, json.encode({error = "write_failed", message = "Firmware staging did not complete."})
  end

  local actual_sha256 = sha256_file(MANUAL_FIRMWARE_PATH)
  if not actual_sha256 or #actual_sha256 ~= 64 then
    cleanup_manual_firmware_upload()
    return 500, json.encode({error = "checksum_failed", message = "Firmware checksum could not be calculated."})
  end

  local test_command = shell_quote(SYSUPGRADE_BIN) .. " -T " .. shell_quote(MANUAL_FIRMWARE_PATH) ..
    " >/dev/null 2>&1"
  if not command_ok(test_command) then
    cleanup_manual_firmware_upload()
    return 500, json.encode({error = "invalid_firmware", message = "Firmware is not compatible with this router."})
  end

  if mode == "preserve" then
    os.remove(MANUAL_CONFIG_BACKUP_PATH)
    if not command_ok(shell_quote(SYSUPGRADE_BIN) .. " -b " .. shell_quote(MANUAL_CONFIG_BACKUP_PATH) ..
        " >/dev/null 2>&1") then
      cleanup_manual_firmware_upload()
      return 500, json.encode({error = "preserve_check_failed", message = "Settings could not be prepared safely."})
    end
    local backup_size = file_size(MANUAL_CONFIG_BACKUP_PATH) or 0
    local overlay_free_kb = fs_available_kb("/overlay")
    os.remove(MANUAL_CONFIG_BACKUP_PATH)
    if overlay_free_kb > 0 and math.ceil(backup_size / 1024) + 32 > overlay_free_kb then
      cleanup_manual_firmware_upload()
      return 409, json.encode({
        error = "preserve_too_large",
        message = "Settings are too large to preserve safely. Use Fresh Install."
      })
    end

    local persisted, persist_detail = db.persist("manual-firmware-upgrade", true)
    if not persisted or not command_ok(SYNC_COMMAND) then
      cleanup_manual_firmware_upload()
      return 500, json.encode({
        error = "settings_save_failed",
        message = "Firmware is valid but current settings could not be saved.",
        detail = tostring(persist_detail or "sync failed")
      })
    end
  end

  with_cloud_backup(function(cloud)
    return cloud.run_now("pre_ota")
  end)

  local apply_command = shell_quote(SYSUPGRADE_BIN) .. " "
  if mode == "fresh" then apply_command = apply_command .. "-n " end
  apply_command = apply_command .. shell_quote(MANUAL_FIRMWARE_PATH)
  if not SYSUPGRADE_SYNC then apply_command = apply_command .. " >/dev/null 2>&1 &" end
  if not command_ok(apply_command) then
    cleanup_manual_firmware_upload()
    return 500, json.encode({error = "upgrade_start_failed", message = "Firmware is valid but upgrade could not start."})
  end

  os.remove(MANUAL_FIRMWARE_STATE_PATH)
  return 200, json.encode({
    status = "ok",
    mode = mode,
    size = size,
    sha256 = actual_sha256,
    message = mode == "fresh"
      and "Fresh firmware update started. Router will reboot."
      or "Firmware update started. Settings will be preserved. Router will reboot."
  })
end

local function ensure_key_only_ssh()
  local keys = read_file(SSH_AUTHORIZED_KEYS_FILE) or ""
  if not keys:match("%S") then
    return false, "Add an authorized SSH key before opening WAN SSH access."
  end

  local password_auth = "dropbear.@dropbear[0].PasswordAuth=off"
  local root_password_auth = "dropbear.@dropbear[0].RootPasswordAuth=off"
  if not command_ok(shell_quote(UCI_BIN) .. " -q set " .. shell_quote(password_auth)) or
      not command_ok(shell_quote(UCI_BIN) .. " -q set " .. shell_quote(root_password_auth)) or
      not command_ok(shell_quote(UCI_BIN) .. " -q commit dropbear") or
      not command_ok(DROPBEAR_RESTART_COMMAND) then
    return false, "SSH could not be switched to key-only access."
  end
  return true
end

local function normalize_boolean(value)
  if value == true or value == 1 or value == "1" then return "1" end
  if value == false or value == 0 or value == "0" then return "0" end
  return nil
end

local function normalize_nonnegative_integer(value, maximum)
  local text = trim(value)
  if text == "" then text = "0" end
  if not text:match("^%d+$") then return nil end
  local number = tonumber(text)
  if not number or number < 0 or number > maximum then return nil end
  return tostring(math.floor(number))
end

local function normalize_mac_list(value)
  local normalized, seen = {}, {}
  local input = tostring(value or "")
  if #input > 4096 then return nil, "Too many exempt devices." end
  input = input:gsub(",", "\n")
  for item in input:gmatch("[^\r\n]+") do
    local mac = valid_mac(trim(item))
    if not mac then return nil, "Enter valid MAC addresses only." end
    mac = mac:lower()
    if not seen[mac] then
      seen[mac] = true
      normalized[#normalized + 1] = mac
      if #normalized > 64 then return nil, "A maximum of 64 exempt devices is allowed." end
    end
  end
  table.sort(normalized)
  return table.concat(normalized, "\n"), normalized
end

local function normalize_domain_list(value)
  local normalized, seen = {}, {}
  local input = tostring(value or "")
  if #input > 16384 then return nil, "The blocked-domain list is too large." end
  for item in input:gmatch("[^\r\n]+") do
    local domain = trim(item):lower():gsub("%.$", "")
    if #domain == 0 or #domain > 253 or not domain:find(".", 1, true) or
        not domain:match("^[a-z0-9%.%-]+$") or domain:find("..", 1, true) then
      return nil, "Enter domain names such as example.com."
    end
    for label in domain:gmatch("[^%.]+") do
      if #label > 63 or label:sub(1, 1) == "-" or label:sub(-1) == "-" then
        return nil, "Enter domain names such as example.com."
      end
    end
    if not seen[domain] then
      seen[domain] = true
      normalized[#normalized + 1] = domain
      if #normalized > 200 then return nil, "A maximum of 200 domains is allowed." end
    end
  end
  table.sort(normalized)
  return table.concat(normalized, "\n"), normalized
end

local function ipv4_parts(value)
  local a, b, c, d = tostring(value):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if not a or not b or not c or not d or
      a > 255 or b > 255 or c > 255 or d > 255 then return nil end
  return {a, b, c, d}
end

local function canonical_ipv4_network(address, prefix)
  local parts = ipv4_parts(address)
  if not parts then return nil end
  prefix = prefix and tonumber(prefix) or 32
  if not prefix or prefix < 8 or prefix > 32 then return nil end
  local number = ((parts[1] * 256 + parts[2]) * 256 + parts[3]) * 256 + parts[4]
  local block = 2 ^ (32 - prefix)
  number = math.floor(number / block) * block
  local d = number % 256
  number = math.floor(number / 256)
  local c = number % 256
  number = math.floor(number / 256)
  local b = number % 256
  local a = math.floor(number / 256) % 256
  local result = table.concat({a, b, c, d}, ".")
  if prefix < 32 then result = result .. "/" .. prefix end
  return result
end

local function normalize_upstream_list(value)
  local normalized, seen = {}, {}
  local input = tostring(value or "")
  if #input > 4096 then return nil, "The upstream-address list is too large." end
  input = input:gsub(",", "\n")
  for item in input:gmatch("[^\r\n]+") do
    local token = trim(item)
    local address, prefix = token:match("^([^/]+)/(%d+)$")
    if not address then address = token end
    local canonical = canonical_ipv4_network(address, prefix)
    if not canonical then
      return nil, "Enter a valid IPv4 address or a network no broader than /8."
    end
    if not seen[canonical] then
      seen[canonical] = true
      normalized[#normalized + 1] = canonical
      if #normalized > 64 then return nil, "A maximum of 64 upstream addresses is allowed." end
    end
  end
  table.sort(normalized)
  return table.concat(normalized, "\n"), normalized
end

local function normalize_wan_source(value)
  local token = trim(value)
  local address, prefix_text = token:match("^([^/]+)/(%d+)$")
  if not address then address = token end
  local parts = ipv4_parts(address)
  local prefix = tonumber(prefix_text) or 32
  if not parts or prefix < 24 or prefix > 32 or parts[1] == 0 or
      parts[1] == 127 or parts[1] >= 224 then
    return nil, "Enter a trusted IPv4 address or a /24 to /32 network."
  end
  local canonical = canonical_ipv4_network(address, prefix)
  if not canonical then
    return nil, "Enter a trusted IPv4 address or a /24 to /32 network."
  end
  return canonical
end

local function setting_from(overrides, key)
  if overrides and overrides[key] ~= nil then return overrides[key] end
  return db.setting(key)
end

local function valid_interface(value)
  local interface = trim(value)
  if interface ~= "" and interface:match("^[%w_.:%-]+$") then return interface end
  return nil
end

local function uci_get_raw(key)
  local handle = io.popen(shell_quote(UCI_BIN) .. " -q get " .. shell_quote(key) ..
    " 2>/dev/null")
  if not handle then return "" end
  local value = (handle:read("*a") or ""):gsub("[\r\n]+$", "")
  handle:close()
  return value
end

local function uci_get(key)
  return trim(uci_get_raw(key))
end

local function wan_status_value(expression)
  local command = shell_quote(UBUS_BIN) ..
    " -S call network.interface.wan status 2>/dev/null | " ..
    shell_quote(JSONFILTER_BIN) .. " -e " .. shell_quote(expression) ..
    " 2>/dev/null"
  local handle = io.popen(command)
  if not handle then return "" end
  local value = trim(handle:read("*a") or "")
  handle:close()
  return value
end

local function wan_physical_interface()
  local forced = valid_interface(os.getenv("TARAKIFI_WAN_DEVICE") or "")
  if forced then return forced end
  return valid_interface(uci_get("network.wan.device"))
end

local function detect_wan_l3_interface()
  local forced = valid_interface(os.getenv("TARAKIFI_WAN_L3_IFACE") or "") or
    valid_interface(os.getenv("TARAKIFI_WAN_IFACE") or "")
  if forced then return forced end

  local proto = uci_get("network.wan.proto")
  local runtime = valid_interface(wan_status_value("@.l3_device"))
  if proto == "pppoe" then
    if runtime and runtime:match("^pppoe%-") then return runtime end
    return "pppoe-wan"
  end
  if runtime then return runtime end

  local configured = wan_physical_interface()
  if configured then return configured end

  local route = io.popen("ip -4 route show default 2>/dev/null")
  if not route then return nil end
  local line = route:read("*l") or ""
  route:close()
  return valid_interface(line:match("%sdev%s+(%S+)"))
end

local function detect_network()
  local forced_gateway = trim(os.getenv("TARAKIFI_UPSTREAM_GATEWAY") or "")
  local interface = detect_wan_l3_interface()
  if forced_gateway ~= "" then return interface, forced_gateway end

  local route = io.popen("ip -4 route show default 2>/dev/null")
  if not route then return interface, nil end
  local line = route:read("*l") or ""
  route:close()
  return interface or valid_interface(line:match("%sdev%s+(%S+)")),
    line:match("%svia%s+(%d+%.%d+%.%d+%.%d+)")
end

local function infer_wifi_band(device)
  if device == "" then return "" end
  local band = uci_get("wireless." .. device .. ".band")
  if band == "2g" or band == "5g" then return band end

  local hwmode = uci_get("wireless." .. device .. ".hwmode"):lower()
  if hwmode:find("11a", 1, true) or hwmode:find("11ac", 1, true) then
    return "5g"
  end
  if hwmode:find("11b", 1, true) or hwmode:find("11g", 1, true) then
    return "2g"
  end
  return ""
end

local function wifi_radios()
  local handle = io.popen(shell_quote(UCI_BIN) .. " -q show wireless 2>/dev/null")
  if not handle then return nil, "WiFi configuration could not be read." end
  local sections = {}
  for line in handle:lines() do
    local section = line:match("^wireless%.([^=]+)=wifi%-iface$")
    if section then sections[#sections + 1] = section end
  end
  handle:close()

  local radios = {}
  for _, section in ipairs(sections) do
    local prefix = "wireless." .. section .. "."
    local mode = uci_get(prefix .. "mode")
    local network = uci_get(prefix .. "network")
    local device = uci_get(prefix .. "device")
    local band = infer_wifi_band(device)
    if mode == "ap" and (" " .. network .. " "):find(" lan ", 1, true) and
        (band == "2g" or band == "5g") and not radios[band] then
      radios[band] = {
        band = band,
        section = section,
        device = device,
        ssid = uci_get(prefix .. "ssid")
      }
    end
  end
  return radios
end

local function normalize_ssid(value)
  if type(value) ~= "string" then
    return nil, "Enter a WiFi name from 1 to 32 bytes."
  end
  local ssid = trim(value)
  if ssid == "" or #ssid > 32 or ssid:find("[%c]") then
    return nil, "Enter a WiFi name from 1 to 32 bytes."
  end
  return ssid
end

local function wifi_write_command(radios, values)
  local commands = {}
  for _, band in ipairs({"2g", "5g"}) do
    local radio = radios[band]
    if radio and values[band] ~= nil then
      commands[#commands + 1] = shell_quote(UCI_BIN) .. " -q set " ..
        shell_quote("wireless." .. radio.section .. ".ssid=" .. values[band])
    end
  end
  commands[#commands + 1] = shell_quote(UCI_BIN) .. " -q commit wireless"
  return table.concat(commands, " && ")
end

local function write_wifi_ssids(radios, values)
  return command_ok(wifi_write_command(radios, values))
end

local function schedule_wifi_reload(radios, previous)
  local rollback = wifi_write_command(radios, previous)
  local action = WIFI_RELOAD_COMMAND .. " || { " .. rollback .. " && " ..
    WIFI_RELOAD_COMMAND .. "; false; }"
  if WIFI_RELOAD_SYNC then return command_ok(action) end
  return command_ok("(sleep " .. tostring(WIFI_RELOAD_DELAY_SECONDS) .. "; " ..
    action .. ") >/dev/null 2>&1 &")
end

local function wan_ipv4()
  local interface = valid_interface((detect_network()))
  if not interface then return "" end
  local handle = io.popen("ip -4 addr show dev " .. shell_quote(interface) ..
    " 2>/dev/null | awk '/inet / {print $2; exit}' | cut -d/ -f1")
  if not handle then return "" end
  local address = trim(handle:read("*a") or "")
  handle:close()
  return ipv4_parts(address) and address or ""
end

local function nft_delete_table(table_name)
  os.execute(shell_quote(NFT_BIN) .. " delete table inet " .. table_name ..
    " >/dev/null 2>&1")
end

local function nft_apply_checked(path, check_rules, live_rules, table_name)
  local check_path = path .. ".check"
  local wrote, write_err = write_file(check_path, check_rules)
  if not wrote then return false, tostring(write_err) end
  local checked = command_ok(shell_quote(NFT_BIN) .. " -c -f " .. shell_quote(check_path) ..
    " >/dev/null 2>&1")
  os.remove(check_path)
  if not checked then return false, "The network rules could not be validated." end

  wrote, write_err = write_file(path, live_rules)
  if not wrote then return false, tostring(write_err) end
  nft_delete_table(table_name)
  if not command_ok(shell_quote(NFT_BIN) .. " -f " .. shell_quote(path) ..
      " >/dev/null 2>&1") then
    return false, "The network rules could not be activated."
  end
  return true
end

local function nft_apply_set_commands(path, commands)
  local wrote, write_err = write_file(path, commands)
  if not wrote then return false, tostring(write_err) end
  if not command_ok(shell_quote(NFT_BIN) .. " -c -f " .. shell_quote(path) ..
      " >/dev/null 2>&1") then
    return false, "The access rules could not be validated."
  end
  if not command_ok(shell_quote(NFT_BIN) .. " -f " .. shell_quote(path) ..
      " >/dev/null 2>&1") then
    return false, "The access rules could not be activated."
  end
  return true
end

local function save_setting(key, value)
  local ok, err = db.set_setting(key, tostring(value))
  if ok then return true end
  return false, tostring(err or "database write failed")
end

local function persist_error(reason)
  local ok, err = db.persist(reason, true)
  if ok then return nil end
  return json.encode({
    error = "persistence_failed",
    message = "The change was not saved to permanent storage.",
    detail = tostring(err)
  })
end

--- Verify admin authentication
local function check_auth(env)
  env = env or {}
  local headers = env.headers or {}
  local client_ip = tostring(env.client_ip or "")
  -- The supervised remote worker reaches uhttpd through loopback. Requiring
  -- both signals prevents a LAN client from spoofing this trusted header.
  if (headers["x-remote-access"] or "") == "true" and
      (client_ip == "127.0.0.1" or client_ip == "::1") then
    return true
  end
  local cookie = headers["cookie"] or ""
  local token = cookie:match("tarakifi_admin=([^;]+)")
  if not token then return false end
  local expected = db.setting("_admin_token")
  return token == expected
end

--- POST /api/admin/login
function M.login(env, params)
  local password = params.password
  local stored = db.setting("admin_password") or "admin"
  if password ~= stored then
    return 401, json.encode({error = "invalid_password"})
  end
  local token = require("lib.util").sha256(password .. "tarakifi_salt" .. tostring(os.time()))
  db.set_runtime_setting("_admin_token", token)
  return 200, json.encode({status = "ok"}), {
    ["Set-Cookie"] = "tarakifi_admin=" .. token .. "; Path=/; HttpOnly; SameSite=Lax"
  }
end

--- POST /api/admin/forgot-password
function M.forgot_password(env, params)
  local license_key = params.license_key
  local new_pass = params.new_password
  if not license_key or license_key == "" then
    return 400, json.encode({error = "missing_license_key"})
  end
  if type(new_pass) ~= "string" or #new_pass < 4 or #new_pass > 128 then
    return 400, json.encode({error = "invalid_password"})
  end
  local stored_license = db.setting("license_key") or ""
  if stored_license == "" then
    return 400, json.encode({error = "no_license", message = "No license activated on this board."})
  end
  if license_key ~= stored_license then
    return 401, json.encode({error = "invalid_license", message = "License key does not match."})
  end
  local saved, save_err = save_setting("admin_password", new_pass)
  if not saved then
    return 500, json.encode({error = "database_write_failed", message = save_err})
  end
  db.set_runtime_setting("_admin_token", "")
  local err = persist_error("password-reset")
  if err then return 500, err end
  schedule_cloud_backup("settings_change")
  return 200, json.encode({status = "ok", message = "Password reset successfully."}), {
    ["Set-Cookie"] = "tarakifi_admin=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
  }
end

--- POST /api/admin/logout
function M.logout(env, params)
  db.set_runtime_setting("_admin_token", "")
  return 200, json.encode({status = "ok"}), {
    ["Set-Cookie"] = "tarakifi_admin=; Path=/; HttpOnly; Max-Age=0"
  }
end

--- GET /api/admin/dashboard
function M.dashboard(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local now = os.time()
  local today_start = now - ((now + 8*3600) % 86400)
  local earnings_settings = db.settings({
    "earnings_reset_transaction_id", "earnings_reset_at",
    "earnings_reset_archive_total_php", "sales_archive_total_php"
  })
  local earnings_reset_id = math.max(
    0, tonumber(earnings_settings.earnings_reset_transaction_id) or 0
  )
  local archived_total = tonumber(earnings_settings.sales_archive_total_php) or 0
  local archived_reset_total =
    tonumber(earnings_settings.earnings_reset_archive_total_php) or 0
  local displayed_archive_total = math.max(0, archived_total - archived_reset_total)

  local active_count = db.scalar("SELECT COUNT(*) FROM sessions WHERE expires_at > ? AND paused = 0", now) or 0
  local paused_count = db.scalar("SELECT COUNT(*) FROM sessions WHERE paused = 1") or 0
  local today_earnings = db.scalar(
    "SELECT COALESCE(SUM(amount_php), 0) FROM transactions " ..
      "WHERE id > ? AND created_at >= ? AND source IN ('coin', 'voucher')",
    earnings_reset_id, today_start
  ) or 0
  local total_earnings = db.scalar(
    "SELECT COALESCE(SUM(amount_php), 0) FROM transactions " ..
      "WHERE id > ? AND source IN ('coin', 'voucher')",
    earnings_reset_id
  ) or 0
  total_earnings = total_earnings + displayed_archive_total
  local today_transactions = db.scalar(
    "SELECT COUNT(*) FROM transactions WHERE id > ? AND created_at >= ?",
    earnings_reset_id, today_start
  ) or 0
  local total_devices = db.scalar("SELECT COUNT(*) FROM known_devices") or 0

  -- Coin nodes
  local nodes = db.query([[
    SELECT node_id, name, last_heartbeat, ip_address, total_coins, area_id,
           fw_version, coin_dpin, relay_dpin, coin_gpio, relay_gpio, rssi,
           conn_mode, protocol_version, auth_enrolled_at
    FROM coin_nodes ORDER BY last_heartbeat DESC
  ]])
  for _, node in ipairs(nodes) do
    node.online = (now - (node.last_heartbeat or 0)) < 60
  end

  -- System info
  local uptime_secs = 0
  local h = io.popen("cat /proc/uptime 2>/dev/null")
  if h then
    local s = h:read("*a") or ""
    uptime_secs = tonumber(s:match("([%d%.]+)")) or 0
    h:close()
  end

  local mem_total, mem_used, mem_free = 0, 0, 0
  local mem_available, swap_total, swap_used = 0, 0, 0
  h = io.popen("cat /proc/meminfo 2>/dev/null")
  if h then
    local meminfo = h:read("*a") or ""
    h:close()
    mem_total = tonumber(meminfo:match("MemTotal:%s+(%d+)")) or 0
    mem_free = tonumber(meminfo:match("MemFree:%s+(%d+)")) or 0
    mem_available = tonumber(meminfo:match("MemAvailable:%s+(%d+)")) or mem_free
    local buffers = tonumber(meminfo:match("Buffers:%s+(%d+)")) or 0
    local cached = tonumber(meminfo:match("Cached:%s+(%d+)")) or 0
    swap_total = tonumber(meminfo:match("SwapTotal:%s+(%d+)")) or 0
    local swap_free = tonumber(meminfo:match("SwapFree:%s+(%d+)")) or 0
    mem_used = mem_total - mem_free - buffers - cached
    swap_used = math.max(0, swap_total - swap_free)
    -- Convert kB to MB
    mem_total = math.floor(mem_total / 1024)
    mem_used = math.floor(mem_used / 1024)
    mem_available = math.floor(mem_available / 1024)
    swap_total = math.floor(swap_total / 1024)
    swap_used = math.floor(swap_used / 1024)
  end

  -- Reuse the supervised WAN result so every UI reports one stable state.
  local wan_online = util.read_wan_status()

  -- Disk usage for health card
  local disk_total, disk_used, disk_avail = 0, 0, 0
  local disk_total_kb, disk_used_kb, disk_avail_kb = 0, 0, 0
  h = io.popen("df /overlay 2>/dev/null | tail -1")
  if h then
    local line = h:read("*a") or ""
    h:close()
    local t, u, a = line:match("%S+%s+(%d+)%s+(%d+)%s+(%d+)")
    disk_total_kb = tonumber(t) or 0
    disk_used_kb = tonumber(u) or 0
    disk_avail_kb = tonumber(a) or 0
    disk_total = math.floor(disk_total_kb / 1024)
    disk_used = math.floor(disk_used_kb / 1024)
    disk_avail = math.floor(disk_avail_kb / 1024)
  end

  -- DHCP clients for health card
  local dhcp_clients = 0
  h = io.popen("cat /tmp/dhcp.leases 2>/dev/null | wc -l")
  if h then
    dhcp_clients = tonumber(h:read("*a")) or 0
    h:close()
  end

  -- Recent transactions (last 10)
  local recent_tx = db.query(
    "SELECT t.mac, t.amount_php as amount, t.minutes_granted as minutes, " ..
      "t.source, t.created_at, COALESCE(t.coin_count, 1) as coin_count " ..
      "FROM transactions t WHERE t.id > ? ORDER BY t.created_at DESC, t.id DESC LIMIT 10",
    earnings_reset_id
  )

  return 200, json.encode({
    active_sessions = active_count,
    paused_sessions = paused_count,
    today_earnings = today_earnings,
    total_earnings = total_earnings,
    today_transactions = today_transactions,
    earnings_reset_at = tonumber(earnings_settings.earnings_reset_at) or 0,
    total_devices = total_devices,
    coin_nodes = nodes,
    wan_online = wan_online,
    recent_transactions = recent_tx,
    system = (function()
      local la = ""
      local f = io.open("/proc/loadavg", "r")
      if f then
        local s = f:read("*l") or ""; f:close()
        local a2, b2, c2 = s:match("([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)")
        if a2 then la = a2 end  -- 1-minute load average only
      end
      return {
        uptime_seconds = math.floor(uptime_secs),
        ram_total_mb = mem_total,
        ram_used_mb = mem_used,
        ram_available_mb = mem_available,
        zram_total_mb = swap_total,
        zram_used_mb = swap_used,
        load_avg = la,
        disk_total_mb = disk_total,
        disk_used_mb = disk_used,
        disk_avail_mb = disk_avail,
        disk_total_kb = disk_total_kb,
        disk_used_kb = disk_used_kb,
        disk_avail_kb = disk_avail_kb,
        dhcp_clients = dhcp_clients,
        wifi_clients = (function()
          local wc = 0
          for _, iface in ipairs({"phy0-ap0", "phy1-ap0"}) do
            local hw = io.popen("iw dev " .. iface .. " station dump 2>/dev/null | grep -c '^Station'")
            if hw then
              local raw2 = hw:read("*a") or "0"
              wc = wc + (tonumber(raw2:match("%d+") or "0") or 0)
              hw:close()
            end
          end
          return wc
        end)()
      }
    end)()
  })
end

--- POST /api/admin/earnings/reset
function M.reset_earnings(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  params = params or {}
  if tostring(params.confirmation or "") ~= "RESET" then
    return 400, json.encode({
      error = "confirmation_required",
      message = "Type RESET to confirm."
    })
  end

  local reset_id = tonumber(db.scalar(
    "SELECT COALESCE(MAX(id), 0) FROM transactions"
  )) or 0
  local reset_at = os.time()
  local archive_total = tonumber(db.setting("sales_archive_total_php") or "0") or 0
  local saved, save_err = db.set_settings_atomic({
    {key = "earnings_reset_transaction_id", value = tostring(reset_id)},
    {key = "earnings_reset_at", value = tostring(reset_at)},
    {key = "earnings_reset_archive_total_php", value = string.format("%.2f", archive_total)}
  })
  if not saved then
    return 500, json.encode({
      error = "database_write_failed",
      message = tostring(save_err or "The earnings reset could not be saved.")
    })
  end

  local err = persist_error("earnings-reset")
  if err then return 500, err end
  schedule_cloud_backup("settings_change")
  return 200, json.encode({
    status = "ok",
    reset_at = reset_at,
    reset_transaction_id = reset_id
  })
end

--- GET /api/admin/sessions
function M.sessions(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local now = os.time()
  local paid_sessions = session.list_active()
  local connected_clients, connected_by_mac = clients.list_connected()

  -- DHCP leases still provide useful IPs for paid sessions that briefly left
  -- WiFi and therefore are not in the current association snapshot.
  local leases = {}
  local f = io.open("/tmp/dhcp.leases", "r")
  if f then
    for line in f:lines() do
      local mac_l, ip, hostname = line:match("%S+ (%S+) (%S+) (%S+)")
      if mac_l then
        leases[mac_l:upper()] = {
          ip = ip or "",
          hostname = hostname ~= "*" and (hostname or "") or ""
        }
      end
    end
    f:close()
  end

  local devices = db.query("SELECT d.*, COALESCE(t.cnt, 0) as total_sessions FROM known_devices d LEFT JOIN (SELECT mac, COUNT(*) as cnt FROM transactions GROUP BY mac) t ON d.mac = t.mac ORDER BY d.last_seen DESC")
  local devices_by_mac = {}
  for _, device in ipairs(devices) do devices_by_mac[device.mac] = device end

  local rows = {}
  local rows_by_mac = {}
  for _, paid in ipairs(paid_sessions) do
    local connected = connected_by_mac[paid.mac]
    local lease = leases[paid.mac] or {}
    local paid_name = paid.device_name or ""
    if paid_name == "" then paid_name = lease.hostname or "" end
    local remaining_seconds
    local status
    if paid.paused == 1 then
      status = "paused"
      remaining_seconds = math.max(0, math.floor((paid.minutes_remaining or 0) * 60))
    else
      status = "active"
      remaining_seconds = math.max(0, (paid.expires_at or now) - now)
    end
    local row = {
      mac = paid.mac,
      device_name = paid_name,
      blocked = paid.blocked or 0,
      ip = (connected and connected.ip) or lease.ip or "",
      status = status,
      paused = status == "paused",
      connected = connected ~= nil,
      remaining_seconds = remaining_seconds,
      minutes_remaining = remaining_seconds / 60,
      expires_at = paid.expires_at,
      started_at = paid.started_at,
      last_seen = paid.last_seen,
      interface = connected and connected.interface or "",
      ssid = connected and connected.ssid or "",
      connection = connected and connected.connection or ""
    }
    rows[#rows + 1] = row
    rows_by_mac[row.mac] = row
  end

  for _, connected in ipairs(connected_clients) do
    if not rows_by_mac[connected.mac] then
      local device = devices_by_mac[connected.mac] or {}
      local idle_name = device.name or ""
      if idle_name == "" then idle_name = connected.hostname or "" end
      local row = {
        mac = connected.mac,
        device_name = idle_name,
        blocked = device.blocked or 0,
        ip = connected.ip or "",
        status = "idle",
        paused = false,
        connected = true,
        remaining_seconds = 0,
        minutes_remaining = 0,
        expires_at = 0,
        started_at = 0,
        last_seen = device.last_seen or now,
        interface = connected.interface or "",
        ssid = connected.ssid or "",
        connection = connected.connection or ""
      }
      rows[#rows + 1] = row
      rows_by_mac[row.mac] = row
    end
  end

  local status_order = {active = 1, paused = 2, idle = 3}
  table.sort(rows, function(a, b)
    local left = status_order[a.status] or 9
    local right = status_order[b.status] or 9
    if left == right then return a.mac < b.mac end
    return left < right
  end)

  return 200, json.encode({
    server_time = now,
    sessions = rows,
    devices = devices
  })
end

--- POST /api/admin/sessions/kick
function M.kick_session(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local mac = valid_mac(params.mac)
  if not mac then return 400, json.encode({error = "invalid_mac"}) end
  session.kick(mac)
  local err = persist_error("session-kick")
  if err then return 500, err end
  return 200, json.encode({status = "ok", mac = mac})
end

--- POST /api/admin/sessions/set-name
function M.set_name(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local mac = valid_mac(params.mac)
  local name = trim(params.name)
  if not mac then return 400, json.encode({error = "invalid_mac"}) end
  if #name > 64 or name:find("[%c]") then
    return 400, json.encode({error = "invalid_name"})
  end
  session.set_device_name(mac, name)
  local err = persist_error("device-name")
  if err then return 500, err end
  return 200, json.encode({status = "ok"})
end

--- POST /api/admin/sessions/edit-time
function M.edit_time(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local mac = valid_mac(params.mac)
  local minutes = tonumber(params.minutes)
  if not mac then return 400, json.encode({error = "invalid_mac"}) end
  if not minutes or minutes ~= math.floor(minutes) or minutes < 1 or minutes > 525600 then
    return 400, json.encode({error = "invalid_minutes"})
  end
  session.edit_time(mac, minutes)
  local err = persist_error("session-edit-time")
  if err then return 500, err end
  return 200, json.encode({status = "ok"})
end

--- POST /api/admin/sessions/block
function M.block_device(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local mac = valid_mac(params.mac)
  if not mac then return 400, json.encode({error = "invalid_mac"}) end
  session.block_device(mac)
  local err = persist_error("device-block")
  if err then return 500, err end
  return 200, json.encode({status = "ok"})
end

--- POST /api/admin/sessions/unblock
function M.unblock_device(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local mac = valid_mac(params.mac)
  if not mac then return 400, json.encode({error = "invalid_mac"}) end
  session.unblock_device(mac)
  local err = persist_error("device-unblock")
  if err then return 500, err end
  return 200, json.encode({status = "ok"})
end

--- POST /api/admin/sessions/reset
function M.reset_device(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local mac = valid_mac(params.mac)
  if not mac then return 400, json.encode({error = "invalid_mac"}) end
  session.reset_device(mac)
  local err = persist_error("device-reset")
  if err then return 500, err end
  return 200, json.encode({status = "ok"})
end

--- POST /api/admin/sessions/forget
function M.forget_device(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local mac = valid_mac(params.mac)
  if not mac then return 400, json.encode({error = "invalid_mac"}) end
  local forgotten, forget_err = session.forget_device(mac)
  if not forgotten then
    if forget_err == "active_session" then
      return 409, json.encode({
        error = forget_err,
        message = "Reset or finish the paid session before forgetting this device."
      })
    end
    if forget_err == "pending_credit" then
      return 409, json.encode({
        error = forget_err,
        message = "Finish the pending coin transaction before forgetting this device."
      })
    end
    if forget_err == "database_error" then
      return 500, json.encode({
        error = forget_err,
        message = "The device could not be forgotten. Please try again."
      })
    end
    return 400, json.encode({error = forget_err or "forget_failed"})
  end
  local err = persist_error("device-forget")
  if err then return 500, err end
  return 200, json.encode({status = "ok", mac = mac})
end

--- POST /api/admin/sessions/clear-expired
function M.clear_expired_sessions(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local removed = session.expire_sessions() + session.cleanup_zero_time_sessions()
  if removed > 0 then
    local err = persist_error("sessions-clear-expired")
    if err then return 500, err end
  end
  return 200, json.encode({status = "ok", removed = removed})
end

--- POST /api/admin/sessions/forget-stale
function M.forget_stale_devices(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local expired_removed = session.cleanup_zero_time_sessions()
  local devices_removed = session.cleanup_stale_devices(30 * 86400)
  if expired_removed > 0 or devices_removed > 0 then
    local err = persist_error("devices-forget-stale")
    if err then return 500, err end
  end
  return 200, json.encode({
    status = "ok",
    removed = devices_removed,
    expired_removed = expired_removed,
    retention_days = 30
  })
end

--- GET /api/admin/settings
function M.get_settings(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local settings = {}
  for _, key in ipairs(SETTINGS_FIELDS) do
    local value = db.setting(key)
    if value ~= nil then settings[key] = value end
  end
  return 200, json.encode(settings)
end

--- POST /api/admin/settings
local function normalize_brand_text(value, max_length, required)
  local normalized = trim(value)
  if required and normalized == "" then
    return nil, "Enter a business name."
  end
  if normalized:find("[%c]") then
    return nil, "Use a single line of text."
  end
  if #normalized > max_length then
    return nil, "Keep this text within " .. max_length .. " characters."
  end
  return normalized
end

local function normalize_operator_setting(key, value)
  if key == "business_name" then
    return normalize_brand_text(value, 64, true)
  end
  if key == "portal_name" then
    return normalize_brand_text(value, 80, false)
  end
  if key == "portal_footer_text" then
    return normalize_brand_text(value, 120, false)
  end
  if key == "portal_show_business_name" then
    local normalized = normalize_boolean(value)
    if not normalized then return nil, "Choose Yes or No." end
    return normalized
  end
  if key == "bw_mode" then
    local mode = tostring(value or "")
    if mode ~= "off" and mode ~= "per_client" and mode ~= "shared" then
      return nil, "Choose a valid bandwidth mode."
    end
    return mode
  end
  if key == "bw_per_client_down_kbps" or key == "bw_per_client_up_kbps" or
      key == "bw_total_down_kbps" or key == "bw_total_up_kbps" then
    local normalized = normalize_nonnegative_integer(value, 10000000)
    if not normalized then return nil, "Enter a bandwidth value from 0 to 10000000 kbps." end
    return normalized
  end
  if key == "bw_exempt_macs" then return normalize_mac_list(value) end
  if key == "site_blocking_enabled" or key == "upstream_ip_blocking_enabled" or
      key == "anti_tethering_enabled" then
    local normalized = normalize_boolean(value)
    if not normalized then return nil, "Choose Enabled or Disabled." end
    return normalized
  end
  if key == "cloud_backup_enabled" then
    local normalized = normalize_boolean(value)
    if not normalized then return nil, "Choose Enabled or Disabled." end
    return normalized
  end
  if key == "blocked_sites" then return normalize_domain_list(value) end
  if key == "blocked_upstream_ips" then return normalize_upstream_list(value) end
  return tostring(value or "")
end

local function kbps_to_kbytes(value)
  local rate = tonumber(value) or 0
  if rate <= 0 then return 0 end
  return math.max(1, math.ceil(rate / 8))
end

local function rate_burst(rate)
  return math.max(64, math.min(1024, math.ceil(rate / 10)))
end

local function bandwidth_rules(table_name, overrides)
  local mode = setting_from(overrides, "bw_mode") or "off"
  if mode ~= "off" and mode ~= "per_client" and mode ~= "shared" then
    return nil, "The saved bandwidth mode is invalid."
  end
  if mode == "off" then return "", mode end

  local wan = valid_interface((detect_network()))
  if not wan then return nil, "The WAN interface could not be detected." end
  local exempt_text, exempt = normalize_mac_list(setting_from(overrides, "bw_exempt_macs") or "")
  if not exempt_text then return nil, exempt end

  local down_key = mode == "per_client" and "bw_per_client_down_kbps" or
    "bw_total_down_kbps"
  local up_key = mode == "per_client" and "bw_per_client_up_kbps" or
    "bw_total_up_kbps"
  local down = normalize_nonnegative_integer(setting_from(overrides, down_key) or "0", 10000000)
  local up = normalize_nonnegative_integer(setting_from(overrides, up_key) or "0", 10000000)
  if not down or not up then return nil, "A saved bandwidth value is invalid." end
  down, up = kbps_to_kbytes(down), kbps_to_kbytes(up)
  if down == 0 and up == 0 then return "", mode end

  local lines = {"table inet " .. table_name .. " {"}
  if #exempt > 0 then
    lines[#lines + 1] = "  set exempt_macs {"
    lines[#lines + 1] = "    type ether_addr"
    lines[#lines + 1] = "    elements = { " .. table.concat(exempt, ", ") .. " }"
    lines[#lines + 1] = "  }"
  end
  lines[#lines + 1] = "  chain forward_bw {"
  lines[#lines + 1] = "    type filter hook forward priority filter + 10; policy accept;"
  if #exempt > 0 and down > 0 then
    lines[#lines + 1] = "    iifname \"" .. wan .. "\" ether daddr @exempt_macs return"
  end
  if #exempt > 0 and up > 0 then
    lines[#lines + 1] = "    oifname \"" .. wan .. "\" ether saddr @exempt_macs return"
  end
  if mode == "per_client" then
    if down > 0 then
      lines[#lines + 1] = "    iifname \"" .. wan ..
        "\" meter per_client_down { ip daddr timeout 1m limit rate over " .. down ..
        " kbytes/second burst " .. rate_burst(down) .. " kbytes } drop"
    end
    if up > 0 then
      lines[#lines + 1] = "    oifname \"" .. wan ..
        "\" meter per_client_up { ip saddr timeout 1m limit rate over " .. up ..
        " kbytes/second burst " .. rate_burst(up) .. " kbytes } drop"
    end
  else
    if down > 0 then
      lines[#lines + 1] = "    iifname \"" .. wan .. "\" limit rate over " .. down ..
        " kbytes/second burst " .. rate_burst(down) .. " kbytes drop"
    end
    if up > 0 then
      lines[#lines + 1] = "    oifname \"" .. wan .. "\" limit rate over " .. up ..
        " kbytes/second burst " .. rate_burst(up) .. " kbytes drop"
    end
  end
  lines[#lines + 1] = "  }"
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n") .. "\n", mode
end

--- Apply the canonical bandwidth policy for all active customer sessions.
function M.apply_bandwidth(overrides)
  local live_rules, mode_or_err = bandwidth_rules("tarakifi_bw", overrides)
  if not live_rules then return false, mode_or_err end
  if live_rules == "" then
    nft_delete_table("tarakifi_bw")
    os.remove(BW_RULES_FILE)
    return true
  end
  local check_rules, check_err = bandwidth_rules("tarakifi_bw_check", overrides)
  if not check_rules then return false, check_err end
  return nft_apply_checked(BW_RULES_FILE, check_rules, live_rules, "tarakifi_bw")
end

local function current_settings_with(overrides)
  local values = {}
  for _, key in ipairs(SETTINGS_FIELDS) do
    if overrides and overrides[key] ~= nil then
      values[key] = overrides[key]
    else
      values[key] = db.setting(key)
    end
  end
  return values
end

local function apply_selected_policies(changed, values)
  if changed.bandwidth then
    local ok, err = M.apply_bandwidth(values)
    if not ok then return false, "bandwidth_apply_failed", err end
  end
  if changed.filtering then
    local ok, err = M.apply_site_blocking(values)
    if not ok then return false, "filtering_apply_failed", err end
  end
  if changed.upstream then
    local ok, err = M.apply_upstream_protection(values)
    if not ok then return false, "upstream_apply_failed", err end
  end
  if changed.anti_tethering then
    local ok, err = M.apply_anti_tethering(values)
    if not ok then return false, "anti_tethering_apply_failed", err end
  end
  return true
end

local function restore_settings(previous, changed)
  db.set_settings_atomic(previous)
  apply_selected_policies(changed, current_settings_with())
  db.persist("settings-rollback", true)
end

function M.save_settings(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local changes, previous, overrides = {}, {}, {}
  local changed = {
    bandwidth = false,
    filtering = false,
    upstream = false,
    anti_tethering = false
  }

  for key, value in pairs(params) do
    if EDITABLE_SETTINGS[key] then
      local normalized, normalize_err = normalize_operator_setting(key, value)
      if normalized == nil then
        return 400, json.encode({error = "invalid_setting", field = key, message = normalize_err})
      end
      local old_value = db.setting(key)
      if old_value ~= normalized then
        changes[#changes + 1] = {key = key, value = normalized}
        previous[#previous + 1] = {key = key, value = old_value, delete = old_value == nil}
        overrides[key] = normalized
        if key:match("^bw_") then changed.bandwidth = true end
        if key == "site_blocking_enabled" or key == "blocked_sites" then
          changed.filtering = true
        end
        if key == "upstream_ip_blocking_enabled" or key == "blocked_upstream_ips" then
          changed.upstream = true
        end
        if key == "anti_tethering_enabled" then changed.anti_tethering = true end
      end
    end
  end

  if #changes == 0 then return 200, json.encode({status = "ok", updated = 0}) end
  local values = current_settings_with(overrides)
  local saved, save_err = db.set_settings_atomic(changes)
  if not saved then
    return 500, json.encode({error = "database_write_failed", message = tostring(save_err)})
  end

  local applied, apply_code, apply_err = apply_selected_policies(changed, values)
  if not applied then
    restore_settings(previous, changed)
    return 500, json.encode({error = apply_code, message = tostring(apply_err)})
  end

  local persisted, persist_err = db.persist("settings", true)
  if not persisted then
    restore_settings(previous, changed)
    return 500, json.encode({
      error = "persistence_failed",
      message = "The change was not saved to permanent storage.",
      detail = tostring(persist_err)
    })
  end
  schedule_cloud_backup("settings_change")
  return 200, json.encode({status = "ok", updated = #changes})
end

--- GET /api/admin/rates
function M.get_rates(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  return 200, json.encode({
    rates = db.setting("portal_rates") or "1:12",
    coin_min_per_php = db.setting("coin_min_per_php") or ""
  })
end

--- POST /api/admin/rates
function M.save_rates(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  if params.rates then db.set_setting("portal_rates", params.rates) end
  if params.coin_min_per_php ~= nil then db.set_setting("coin_min_per_php", params.coin_min_per_php) end
  local err = persist_error("rates")
  if err then return 500, err end
  schedule_cloud_backup("settings_change")
  return 200, json.encode({status = "ok"})
end

--- GET /api/admin/devices
function M.devices(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local devices = db.query("SELECT d.*, COALESCE(t.cnt, 0) as total_sessions FROM known_devices d LEFT JOIN (SELECT mac, COUNT(*) as cnt FROM transactions GROUP BY mac) t ON d.mac = t.mac ORDER BY d.last_seen DESC")
  return 200, json.encode({devices = devices})
end

--- GET /api/admin/vouchers
function M.list_vouchers(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local vouchers = db.query(
    "SELECT * FROM vouchers WHERE archived = 0 ORDER BY rowid DESC LIMIT 500"
  )
  local now = os.time()
  local unused = 0
  local redeemed = 0
  local expired = 0
  for _, v in ipairs(vouchers) do
    -- Add convenience aliases for frontend
    v.price = v.price_php
    v.used = (v.status == "redeemed" or v.status == "used")
    v.expired = v.used and (tonumber(v.valid_until) or 0) > 0 and
      (tonumber(v.valid_until) or 0) <= now
    v.batch = v.batch_label
    if v.expired then expired = expired + 1
    elseif v.status == "unused" then unused = unused + 1
    elseif v.used then redeemed = redeemed + 1 end
  end
  return 200, json.encode({
    vouchers = vouchers,
    total = #vouchers,
    unused = unused,
    redeemed = redeemed,
    expired = expired
  })
end

--- POST /api/admin/vouchers/generate
function M.generate_vouchers(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local count = math.floor(tonumber(params.count) or tonumber(params.quantity) or 0)
  local minutes = tonumber(params.minutes) or 0
  local price_php = tonumber(params.price_php) or tonumber(params.price) or 0
  local batch_label = params.batch_label or params.label or ""
  local validity_seconds = math.floor(tonumber(params.validity_seconds) or 0)
  local code_type = tostring(params.code_type or "mixed"):lower()
  local code_length = math.floor(tonumber(params.code_length) or 8)
  local alphabets = {
    numbers = "0123456789",
    letters = "ABCDEFGHJKLMNPQRSTUVWXYZ",
    mixed = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  }

  if count <= 0 or count > 500 then
    return 400, json.encode({error = "count must be 1-500"})
  end
  if minutes <= 0 then
    return 400, json.encode({error = "minutes must be positive"})
  end
  if validity_seconds < 0 or validity_seconds > (10 * 365 * 86400) then
    return 400, json.encode({error = "validity must be between 0 and 10 years"})
  end
  if not alphabets[code_type] then
    return 400, json.encode({error = "code type must be numbers, letters, or mixed"})
  end
  if code_length < 4 or code_length > 8 then
    return 400, json.encode({error = "code length must be between 4 and 8"})
  end

  local generated_ok, generated, generate_err = db.generate_voucher_batch({
    count = count,
    minutes = minutes,
    price_php = price_php,
    batch_label = batch_label,
    validity_seconds = validity_seconds,
    code_length = code_length,
    alphabet = alphabets[code_type]
  })
  if not generated_ok then
    if generate_err == "voucher_code_space_exhausted" then
      return 409, json.encode({
        error = "Could not create enough unique codes. Use a longer code length."
      })
    end
    return 500, json.encode({error = "Voucher generation failed. Please try again."})
  end
  local err = persist_error("voucher-generate")
  if err then return 500, err end
  schedule_cloud_backup("voucher_change")
  return 200, json.encode({
    status = "ok",
    count = #generated,
    code_type = code_type,
    code_length = code_length,
    vouchers = generated
  })
end

--- POST /api/admin/vouchers/delete
function M.delete_voucher(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local deleted = 0

  if params.delete_used == true or params.delete_used == "1" then
    deleted = tonumber(db.scalar(
      "SELECT COUNT(*) FROM vouchers WHERE archived = 0 AND status IN ('redeemed', 'used')"
    )) or 0
    db.exec(
      "UPDATE vouchers SET archived = 1 WHERE archived = 0 AND status IN ('redeemed', 'used')"
    )
  elseif type(params.ids) == "table" then
    local seen = {}
    for _, value in ipairs(params.ids) do
      local id = tonumber(value)
      if id and not seen[id] then
        seen[id] = true
        local row = db.row("SELECT id FROM vouchers WHERE id = ? AND status = 'unused'", id)
        if row then
          db.exec("DELETE FROM vouchers WHERE id = ? AND status = 'unused'", id)
          deleted = deleted + 1
        end
      end
    end
  else
    local id = tonumber(params.id)
    if not id then return 400, json.encode({error = "missing id"}) end
    local row = db.row("SELECT id FROM vouchers WHERE id = ? AND status = 'unused'", id)
    if row then
      db.exec("DELETE FROM vouchers WHERE id = ? AND status = 'unused'", id)
      deleted = 1
    end
  end

  local err = persist_error("voucher-delete")
  if err then return 500, err end
  if deleted > 0 then schedule_cloud_backup("voucher_change") end
  return 200, json.encode({status = "ok", deleted = deleted})
end

--- POST /api/admin/system/reboot
function M.reboot(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local err = persist_error("reboot")
  if err then return 500, err end
  os.execute("sleep 2 && reboot &")
  return 200, json.encode({status = "rebooting"})
end

--- POST /api/admin/system/shutdown
function M.shutdown(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local err = persist_error("shutdown")
  if err then return 500, err end
  os.execute("sleep 2 && poweroff &")
  return 200, json.encode({status = "shutting_down"})
end

--- GET /api/admin/system/info
function M.system_info(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end

  local uptime_secs = 0
  local h = io.popen("cat /proc/uptime 2>/dev/null")
  if h then
    uptime_secs = tonumber((h:read("*a") or ""):match("([%d%.]+)")) or 0
    h:close()
  end

  local mem_total, mem_used = 0, 0
  h = io.popen("cat /proc/meminfo 2>/dev/null")
  if h then
    local meminfo = h:read("*a") or ""
    h:close()
    local total_kb = tonumber(meminfo:match("MemTotal:%s+(%d+)")) or 0
    local free_kb = tonumber(meminfo:match("MemFree:%s+(%d+)")) or 0
    local buffers = tonumber(meminfo:match("Buffers:%s+(%d+)")) or 0
    local cached = tonumber(meminfo:match("Cached:%s+(%d+)")) or 0
    mem_total = math.floor(total_kb / 1024)
    mem_used = math.floor((total_kb - free_kb - buffers - cached) / 1024)
  end

  local dhcp_clients = 0
  h = io.popen("cat /tmp/dhcp.leases 2>/dev/null | wc -l")
  if h then
    dhcp_clients = tonumber(h:read("*a")) or 0
    h:close()
  end

  local fw_version = "1.0.0"
  local vf = io.open("/etc/tarakifi/version", "r")
  if vf then fw_version = vf:read("*l") or fw_version; vf:close() end
  local build_commit = "unknown"
  local cf = io.open("/etc/tarakifi/commit", "r")
  if cf then build_commit = cf:read("*l") or build_commit; cf:close() end

  local model = trim(read_file(ROUTER_MODEL_FILE) or "")
  local mf = io.open("/tmp/sysinfo/model", "r")
  if mf then model = trim(mf:read("*l") or model); mf:close() end
  if model == "" then model = "COMFAST Router" end

  -- Disk usage
  local disk_total, disk_used, disk_avail = 0, 0, 0
  local disk_total_kb, disk_used_kb, disk_avail_kb = 0, 0, 0
  h = io.popen("df /overlay 2>/dev/null | tail -1")
  if h then
    local line = h:read("*a") or ""
    h:close()
    -- Skip filesystem column (may end in a digit e.g. mtdblock8)
    local t, u, a = line:match("%S+%s+(%d+)%s+(%d+)%s+(%d+)")
    disk_total_kb = tonumber(t) or 0
    disk_used_kb = tonumber(u) or 0
    disk_avail_kb = tonumber(a) or 0
    disk_total = math.floor(disk_total_kb / 1024)
    disk_used = math.floor(disk_used_kb / 1024)
    disk_avail = math.floor(disk_avail_kb / 1024)
  end

  -- WAN IP: try multiple interface names used by supported Comfast images.
  local wan_ip = ""
  local wan_ifaces = {"eth0.2", "eth1", "pppoe-wan", "wan"}
  for _, iface in ipairs(wan_ifaces) do
    h = io.popen("ip addr show " .. iface .. " 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1")
    if h then
      local ip = (h:read("*a") or ""):gsub("%s+", "")
      h:close()
      if ip ~= "" then wan_ip = ip; break end
    end
  end
  -- Fallback: get default route IP
  if wan_ip == "" then
    h = io.popen("ip route get 8.8.8.8 2>/dev/null | grep -o 'src [0-9.]*' | awk '{print $2}'")
    if h then
      wan_ip = (h:read("*a") or ""):gsub("%s+", "")
      h:close()
    end
  end

  -- Kernel version
  local kernel = ""
  h = io.popen("uname -r 2>/dev/null")
  if h then
    kernel = (h:read("*a") or ""):gsub("%s+", "")
    h:close()
  end

  -- CPU load average
  local load_avg = ""
  local lf = io.open("/proc/loadavg", "r")
  if lf then
    local line = lf:read("*l") or ""
    lf:close()
    local a, b, c = line:match("([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)")
    if a then load_avg = a .. " " .. b .. " " .. c end
  end

  -- WiFi clients: count associated stations across all AP interfaces
  local wifi_clients = 0
  for _, iface in ipairs({"phy0-ap0", "phy1-ap0"}) do
    h = io.popen("iw dev " .. iface .. " station dump 2>/dev/null | grep -c '^Station'")
    if h then
      local raw = h:read("*a") or "0"
      local n = tonumber(raw:match("%d+") or "0") or 0
      wifi_clients = wifi_clients + n
      h:close()
    end
  end

  -- LAN IP
  local lan_ip = "10.0.0.1"
  h = io.popen("ip addr show br-lan 2>/dev/null")
  if h then
    local raw = h:read("*a") or ""
    h:close()
    local lip = raw:match("inet%s+([%d%.]+)/")
    if lip and lip ~= "" then lan_ip = lip end
  end

  -- Hostname
  local hostname = "TarakiFi"
  h = io.popen("uci get system.@system[0].hostname 2>/dev/null")
  if h then
    local hn = (h:read("*a") or ""):gsub("%s+", "")
    h:close()
    if hn ~= "" then hostname = hn end
  end

  -- License status
  local license_status = db.setting("license_status") or "trial"
  local license_key = db.setting("license_key") or ""
  local trial_started_at = tonumber(db.setting("trial_started_at")) or 0
  local vendor_trial_expires_at = trim(db.setting("_trial_expires_at") or "")
  local trial_expires_at = vendor_trial_expires_at ~= "" and vendor_trial_expires_at
    or (trial_started_at > 0 and (trial_started_at + 86400) or 0)

  -- Auto-start trial on first system info load if not started yet
  if license_status == "trial" and trial_started_at == 0 then
    trial_started_at = os.time()
    db.set_setting("trial_started_at", tostring(trial_started_at))
    local err = persist_error("trial-start")
    if err then return 500, err end
    trial_expires_at = trial_started_at + 86400
  end

  return 200, json.encode({
    fw_version = fw_version,
    build_commit = build_commit,
    model = model,
    hostname = hostname,
    kernel = kernel,
    load_avg = load_avg,
    uptime_seconds = math.floor(uptime_secs),
    ram_total_mb = mem_total,
    ram_used_mb = mem_used,
    dhcp_clients = dhcp_clients,
    wifi_clients = wifi_clients,
    disk_total_mb = disk_total,
    disk_used_mb = disk_used,
    disk_avail_mb = disk_avail,
    disk_total_kb = disk_total_kb,
    disk_used_kb = disk_used_kb,
    disk_avail_kb = disk_avail_kb,
    wan_ip = wan_ip,
    lan_ip = lan_ip,
    license_status = license_status,
    license_configured = license_key ~= "",
    license_key_masked = mask_license_key(license_key),
    custom_media_uploads_supported = persistent_media_uploads_supported(),
    trial_started_at = trial_started_at > 0 and trial_started_at or nil,
    trial_expires_at = trial_expires_at ~= 0 and trial_expires_at or nil
  })
end

--- GET /api/admin/system/ping
function M.ping(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  return 200, json.encode({status = "ok"})
end

--- GET /api/admin/system/wifi
function M.get_wifi_config(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local radios, read_err = wifi_radios()
  if not radios then
    return 500, json.encode({error = "wifi_read_failed", message = read_err})
  end
  return 200, json.encode({
    radios = {
      ["2g"] = radios["2g"] and {available = true, ssid = radios["2g"].ssid} or
        {available = false, ssid = ""},
      ["5g"] = radios["5g"] and {available = true, ssid = radios["5g"].ssid} or
        {available = false, ssid = ""}
    }
  })
end

--- POST /api/admin/system/wifi
function M.save_wifi_config(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local radios, read_err = wifi_radios()
  if not radios then
    return 500, json.encode({error = "wifi_read_failed", message = read_err})
  end

  local previous, requested = {}, {}
  local changed = false
  for _, band in ipairs({"2g", "5g"}) do
    local radio = radios[band]
    local key = band == "2g" and "ssid_2g" or "ssid_5g"
    if radio then
      previous[band] = radio.ssid
      local value = params[key]
      if value == nil then value = radio.ssid end
      local normalized, normalize_err = normalize_ssid(value)
      if not normalized then
        return 400, json.encode({
          error = "invalid_ssid", field = key, message = normalize_err
        })
      end
      requested[band] = normalized
      if normalized ~= radio.ssid then changed = true end
    elseif trim(params[key] or "") ~= "" then
      return 409, json.encode({
        error = "radio_unavailable",
        field = key,
        message = "That WiFi band is not available on this router."
      })
    end
  end

  if not changed then
    return 200, json.encode({status = "ok", updated = 0, reconnect_required = false})
  end
  if not write_wifi_ssids(radios, requested) then
    write_wifi_ssids(radios, previous)
    return 500, json.encode({
      error = "wifi_save_failed", message = "The WiFi names could not be saved."
    })
  end
  if not schedule_wifi_reload(radios, previous) then
    write_wifi_ssids(radios, previous)
    return 500, json.encode({
      error = "wifi_reload_failed",
      message = "The WiFi names were restored because the network could not restart."
    })
  end
  schedule_cloud_backup("settings_change")
  return 200, json.encode({
    status = "ok",
    updated = 1,
    reconnect_required = true,
    reload_delay_seconds = WIFI_RELOAD_DELAY_SECONDS
  })
end

local function pppoe_supported()
  local file = io.open(PPPOE_SUPPORT_FILE, "rb")
  if not file then return false end
  local value = trim(file:read("*a") or "")
  file:close()
  return value == "1"
end

local function wan_uci_state()
  return {
    proto = uci_get("network.wan.proto"),
    username = uci_get("network.wan.username"),
    password = uci_get_raw("network.wan.password")
  }
end

local function wan_uci_set(key, value)
  return command_ok(shell_quote(UCI_BIN) .. " -q set " ..
    shell_quote(key .. "=" .. tostring(value or "")))
end

local function wan_uci_delete(key)
  if uci_get_raw(key) == "" then return true end
  return command_ok(shell_quote(UCI_BIN) .. " -q delete " .. shell_quote(key) ..
    " >/dev/null 2>&1")
end

local function write_wan_uci(values)
  if trim(values.proto or "") == "" or
      not wan_uci_set("network.wan.proto", values.proto) then
    return false
  end
  if values.username and values.username ~= "" then
    if not wan_uci_set("network.wan.username", values.username) then return false end
  elseif not wan_uci_delete("network.wan.username") then
    return false
  end
  if values.password and values.password ~= "" then
    if not wan_uci_set("network.wan.password", values.password) then return false end
  elseif not wan_uci_delete("network.wan.password") then
    return false
  end
  return command_ok(shell_quote(UCI_BIN) .. " -q commit network")
end

local function restore_wan_config(previous)
  write_wan_uci(previous)
  command_ok(NETWORK_RELOAD_COMMAND)
  command_ok(WAN_IFUP_COMMAND)
  command_ok(FIREWALL_RECOVERY_COMMAND)
end

local function normalize_wan_username(value)
  if type(value) ~= "string" then
    return nil, "Enter the PPPoE username supplied by your internet provider."
  end
  local username = trim(value)
  if username == "" or #username > 128 or username:find("[%c]") then
    return nil, "Enter a valid PPPoE username (maximum 128 characters)."
  end
  return username
end

local function normalize_wan_password(value, required)
  if value == nil then value = "" end
  if type(value) ~= "string" or #value > 256 or value:find("[%c]") then
    return nil, "Enter a valid PPPoE password (maximum 256 characters)."
  end
  if required and value == "" then
    return nil, "Enter the PPPoE password supplied by your internet provider."
  end
  return value
end

local function wan_config_response()
  local state = wan_uci_state()
  local can_pppoe = pppoe_supported()
  local runtime_up = wan_status_value("@.up")
  local pending = wan_status_value("@.pending")
  local runtime_l3 = valid_interface(wan_status_value("@.l3_device")) or ""
  local l3_interface = detect_wan_l3_interface() or ""
  local transitioning = state.proto == "pppoe" and
    not runtime_l3:match("^pppoe%-")
  local up = not transitioning and (runtime_up == "true" or runtime_up == "1")
  return {
    mode = state.proto,
    supported = state.proto == "dhcp" or (state.proto == "pppoe" and can_pppoe),
    pppoe_supported = can_pppoe,
    username = state.username,
    password_configured = state.password ~= "",
    physical_interface = wan_physical_interface() or "",
    l3_interface = l3_interface,
    wan_ip = wan_ipv4(),
    connected = up,
    connecting = not up and (transitioning or pending == "true" or pending == "1")
  }
end

--- GET /api/admin/system/wan
function M.get_wan_config(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  return 200, json.encode(wan_config_response())
end

--- POST /api/admin/system/wan
function M.save_wan_config(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  params = params or {}
  local mode = trim(params.mode or "")
  if mode ~= "dhcp" and mode ~= "pppoe" then
    return 400, json.encode({
      error = "invalid_wan_mode",
      message = "Choose DHCP or PPPoE for the internet connection."
    })
  end
  if mode == "pppoe" and not pppoe_supported() then
    return 409, json.encode({
      error = "pppoe_unsupported",
      message = "PPPoE is not available on this router model."
    })
  end

  local previous = wan_uci_state()
  local requested = {proto = mode, username = "", password = ""}
  if mode == "pppoe" then
    local username, username_err = normalize_wan_username(params.username)
    if not username then
      return 400, json.encode({error = "invalid_pppoe_username", message = username_err})
    end
    local supplied_password = params.password
    local preserve_password = supplied_password == nil or supplied_password == ""
    local password, password_err = normalize_wan_password(
      preserve_password and previous.password or supplied_password,
      previous.password == "" and preserve_password
    )
    if not password then
      return 400, json.encode({error = "invalid_pppoe_password", message = password_err})
    end
    requested.username = username
    requested.password = password
  end

  if not write_wan_uci(requested) then
    restore_wan_config(previous)
    return 500, json.encode({
      error = "wan_save_failed",
      message = "The internet connection settings could not be saved."
    })
  end

  if not command_ok(NETWORK_RELOAD_COMMAND) or
      not command_ok(WAN_IFUP_COMMAND) or
      not command_ok(FIREWALL_RECOVERY_COMMAND) then
    restore_wan_config(previous)
    return 500, json.encode({
      error = "wan_apply_failed",
      message = "The previous internet connection settings were restored."
    })
  end

  local response = wan_config_response()
  response.status = "ok"
  response.updated = 1
  return 200, json.encode(response)
end

--- POST /api/admin/password
function M.change_password(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local current = params.current_password
  local new_pass = params.new_password
  local stored = db.setting("admin_password") or "admin"
  if current ~= stored then
    return 401, json.encode({error = "wrong_current_password"})
  end
  if type(new_pass) ~= "string" or #new_pass < 4 or #new_pass > 128 then
    return 400, json.encode({error = "invalid_password"})
  end
  local saved, save_err = save_setting("admin_password", new_pass)
  if not saved then
    return 500, json.encode({error = "database_write_failed", message = save_err})
  end
  db.set_runtime_setting("_admin_token", "")
  local err = persist_error("password-change")
  if err then return 500, err end
  schedule_cloud_backup("settings_change")
  return 200, json.encode({status = "ok"}), {
    ["Set-Cookie"] = "tarakifi_admin=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
  }
end

--- POST /api/admin/license/activate
function M.activate_license(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local key = params.license_key
  if type(key) ~= "string" or key == "" then
    return 400, json.encode({error = "missing_key"})
  end
  key = trim(key)
  if #key > 128 or key:find("*", 1, true) then
    return 400, json.encode({error = "invalid_key"})
  end
  -- Validate with vendor platform before activating
  local ok_vendor, vendor = pcall(require, "lib.vendor")
  if not ok_vendor or type(vendor) ~= "table" or type(vendor.activate_key) ~= "function" then
    return 500, json.encode({error = "activation_unavailable", message = "License validation is unavailable."})
  end
  local called, success, msg = pcall(vendor.activate_key, key)
  if not called then
    return 500, json.encode({error = "activation_unavailable", message = "License validation is unavailable."})
  end
  if not success then
    return 400, json.encode({error = "activation_failed", message = public_license_error(msg)})
  end
  local err = persist_error("license-activate")
  if err then return 500, err end
  schedule_cloud_backup("license_activation", {force = true})
  return 200, json.encode({status = "ok", message = msg})
end

--- GET /api/admin/cloud-backup/status
function M.cloud_backup_status(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local available, ok, status = with_cloud_backup(function(cloud)
    return true, cloud.status()
  end)
  if not available or not ok then return 500, json.encode({error = "cloud_backup_unavailable"}) end
  return 200, json.encode(status)
end

--- POST /api/admin/cloud-backup/settings
function M.cloud_backup_settings(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local enabled = normalize_boolean((params or {}).enabled)
  if not enabled then return 400, json.encode({error = "invalid_setting"}) end
  if enabled == "1" and trim(db.setting("license_status") or "") ~= "active" then
    return 409, json.encode({
      error = "license_required",
      message = "Activate license first."
    })
  end
  local available, saved, detail = with_cloud_backup(function(cloud)
    return cloud.set_enabled(enabled)
  end)
  if not available then return 500, json.encode({error = "cloud_backup_unavailable"}) end
  if not saved then return 500, json.encode({error = "cloud_backup_save_failed", detail = tostring(detail)}) end
  if enabled == "1" then schedule_cloud_backup("manual", {force = true}) end
  return 200, json.encode({status = "ok", enabled = enabled == "1"})
end

--- POST /api/admin/cloud-backup/backup
function M.cloud_backup_now(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local available, scheduled = with_cloud_backup(function(cloud)
    return cloud.schedule("manual", {force = true})
  end)
  if not available then return 500, json.encode({error = "cloud_backup_unavailable"}) end
  if not scheduled then return 409, json.encode({error = "cloud_backup_disabled"}) end
  return 200, json.encode({status = "ok"})
end

--- POST /api/admin/cloud-backup/restore
function M.cloud_restore_now(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local available, started = with_cloud_backup(function(cloud)
    return cloud.restore_now((params or {}).backup_id)
  end)
  if not available then return 500, json.encode({error = "cloud_backup_unavailable"}) end
  if not started then return 409, json.encode({error = "license_required"}) end
  return 200, json.encode({status = "ok"})
end

--- GET /api/admin/backup
function M.backup(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  -- Sync to flash first
  local err = persist_error("operator-backup")
  if err then return 500, err end
  -- Read the database file and encode as base64
  local f = io.open("/etc/tarakifi/sessions.db", "rb")
  if not f then
    return 500, json.encode({error = "backup_failed", message = "Cannot read database."})
  end
  local content = f:read("*a")
  f:close()
  -- Also include settings
  local settings = db.query("SELECT key, value FROM settings WHERE key NOT LIKE '\\_%' ESCAPE '\\'")
  return 200, json.encode({
    status = "ok",
    timestamp = os.time(),
    settings = settings,
    db_size = #content
  })
end

--- POST /api/admin/restore
function M.restore(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local settings = params.settings
  if not settings or type(settings) ~= "table" then
    return 400, json.encode({error = "invalid_backup"})
  end
  -- Restore settings
  for _, kv in ipairs(settings) do
    if kv.key and kv.value then
      db.set_setting(kv.key, kv.value)
    end
  end
  local err = persist_error("operator-restore")
  if err then return 500, err end
  return 200, json.encode({status = "ok", message = "Settings restored. Reboot recommended."})
end

--- GET /api/admin/reboot-schedule
function M.get_reboot_schedule(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  return 200, json.encode({
    enabled = db.setting("auto_reboot_enabled") == "1",
    time = db.setting("auto_reboot_time") or "03:00",
    days = db.setting("auto_reboot_days") or "daily"
  })
end

--- POST /api/admin/reboot-schedule
function M.save_reboot_schedule(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local enabled
  if params.enabled == true or params.enabled == 1 or params.enabled == "1" then
    enabled = true
  elseif params.enabled == false or params.enabled == 0 or params.enabled == "0" then
    enabled = false
  else
    return 400, json.encode({error = "invalid_enabled"})
  end
  local hour, minute = tostring(params.time or ""):match("^(%d%d):(%d%d)$")
  if not hour or tonumber(hour) > 23 or tonumber(minute) > 59 then
    return 400, json.encode({error = "invalid_time"})
  end
  local days = tostring(params.days or "")
  if days ~= "daily" and days ~= "weekdays" and days ~= "weekends" then
    return 400, json.encode({error = "invalid_days"})
  end
  for key, value in pairs({
    auto_reboot_enabled = enabled and "1" or "0",
    auto_reboot_time = hour .. ":" .. minute,
    auto_reboot_days = days
  }) do
    local saved, save_err = save_setting(key, value)
    if not saved then
      return 500, json.encode({error = "database_write_failed", message = save_err})
    end
  end
  local err = persist_error("reboot-schedule")
  if err then return 500, err end
  local applied, apply_err = M._update_reboot_cron()
  if not applied then
    return 500, json.encode({error = "schedule_apply_failed", message = tostring(apply_err)})
  end
  return 200, json.encode({status = "ok"})
end

--- Update cron for auto-reboot
function M._update_reboot_cron()
  local enabled = db.setting("auto_reboot_enabled") == "1"
  local lines = {}
  local existing = io.open(CRON_FILE, "r")
  if existing then
    for line in existing:lines() do
      if not line:find("# tarakifi_reboot", 1, true) then lines[#lines + 1] = line end
    end
    existing:close()
  end
  if enabled then
    local time = db.setting("auto_reboot_time") or "03:00"
    local hour, min = time:match("(%d+):(%d+)")
    hour = hour or "3"
    min = min or "0"
    local day_fields = {daily = "*", weekdays = "1-5", weekends = "0,6"}
    local days = day_fields[db.setting("auto_reboot_days") or "daily"] or "*"
    lines[#lines + 1] = min .. " " .. hour .. " * * " .. days .. " /sbin/reboot # tarakifi_reboot"
  end
  local tmp = CRON_FILE .. ".tarakifi.tmp"
  local output, open_err = io.open(tmp, "w")
  if not output then return false, open_err or "cannot write cron file" end
  if #lines > 0 then output:write(table.concat(lines, "\n"), "\n") end
  output:close()
  local renamed, rename_err = os.rename(tmp, CRON_FILE)
  if not renamed then
    os.remove(tmp)
    return false, rename_err or "cannot replace cron file"
  end
  local restart_result = os.execute(CRON_RESTART_COMMAND)
  if restart_result ~= true and restart_result ~= 0 then
    return false, "cron restart failed"
  end
  return true
end

local function domain_config(overrides)
  local enabled = normalize_boolean(setting_from(overrides, "site_blocking_enabled") or "0")
  if not enabled then return nil, "The saved filtering state is invalid." end
  local normalized, domains = normalize_domain_list(setting_from(overrides, "blocked_sites") or "")
  if not normalized then return nil, domains end
  if enabled == "0" or #domains == 0 then return "" end
  local lines = {}
  for _, domain in ipairs(domains) do
    lines[#lines + 1] = "address=/" .. domain .. "/0.0.0.0"
  end
  return table.concat(lines, "\n") .. "\n"
end

local function restore_file(path, content)
  if content == nil then
    os.remove(path)
    return true
  end
  local tmp = path .. ".restore"
  local wrote = write_file(tmp, content)
  if not wrote then return false end
  local renamed = os.rename(tmp, path)
  if not renamed then os.remove(tmp) end
  return renamed and true or false
end

--- Apply domain filtering with validated, atomically replaced configuration.
function M.apply_site_blocking(overrides)
  local content, config_err = domain_config(overrides)
  if content == nil then return false, config_err end
  local existing = read_file(DNSMASQ_BLOCK_FILE)
  if (existing or "") == content then return true end

  local tmp = DNSMASQ_BLOCK_FILE .. ".tarakifi.tmp"
  os.remove(tmp)
  if content ~= "" then
    local wrote, write_err = write_file(tmp, content)
    if not wrote then return false, tostring(write_err) end
    if not command_ok(shell_quote(DNSMASQ_BIN) .. " --test --conf-file=" ..
        shell_quote(tmp) .. " >/dev/null 2>&1") then
      os.remove(tmp)
      return false, "The domain rules could not be validated."
    end
    local renamed, rename_err = os.rename(tmp, DNSMASQ_BLOCK_FILE)
    if not renamed then
      os.remove(tmp)
      return false, tostring(rename_err or "cannot replace domain rules")
    end
  else
    os.remove(DNSMASQ_BLOCK_FILE)
  end

  if not command_ok(DNSMASQ_RESTART_COMMAND) then
    restore_file(DNSMASQ_BLOCK_FILE, existing)
    command_ok(DNSMASQ_RESTART_COMMAND)
    return false, "The domain-filtering service could not be restarted."
  end
  return true
end

-- Kept for callers from older images while using the canonical implementation.
M._apply_site_blocking = M.apply_site_blocking

local function upstream_rules(table_name, overrides)
  local enabled = normalize_boolean(
    setting_from(overrides, "upstream_ip_blocking_enabled") or "1"
  )
  if not enabled then return nil, "The saved upstream-protection state is invalid." end
  if enabled == "0" then return "" end

  local normalized, addresses = normalize_upstream_list(
    setting_from(overrides, "blocked_upstream_ips") or ""
  )
  if not normalized then return nil, addresses end
  local wan, gateway = detect_network()
  wan = valid_interface(wan)
  local lan = valid_interface(os.getenv("TARAKIFI_LAN_IFACE") or "br-lan")
  if not wan or not lan then return nil, "The customer network could not be detected." end

  local seen = {}
  for _, address in ipairs(addresses) do seen[address] = true end
  if gateway and gateway ~= "" then
    gateway = canonical_ipv4_network(gateway, 32)
    if not gateway then return nil, "The upstream gateway address is invalid." end
    if not seen[gateway] then
      seen[gateway] = true
      addresses[#addresses + 1] = gateway
    end
  end
  if #addresses == 0 then return "" end
  table.sort(addresses)

  local lines = {
    "table inet " .. table_name .. " {",
    "  set protected_upstream_ipv4 {",
    "    type ipv4_addr",
    "    flags interval",
    "    auto-merge",
    "    elements = { " .. table.concat(addresses, ", ") .. " }",
    "  }",
    "  chain protect_upstream {",
    "    type filter hook forward priority filter + 5; policy accept;",
    "    iifname \"" .. lan .. "\" oifname \"" .. wan ..
      "\" ip daddr @protected_upstream_ipv4 drop",
    "  }",
    "}"
  }
  return table.concat(lines, "\n") .. "\n"
end

--- Keep customer devices away from upstream modem and router management IPs.
function M.apply_upstream_protection(overrides)
  local live_rules, rules_err = upstream_rules("tarakifi_upstream", overrides)
  if not live_rules then return false, rules_err end
  if live_rules == "" then
    nft_delete_table("tarakifi_upstream")
    os.remove(UPSTREAM_RULES_FILE)
    return true
  end
  local check_rules, check_err = upstream_rules("tarakifi_upstream_check", overrides)
  if not check_rules then return false, check_err end
  return nft_apply_checked(
    UPSTREAM_RULES_FILE, check_rules, live_rules, "tarakifi_upstream"
  )
end

local function anti_tethering_rules(table_name, overrides)
  local enabled = normalize_boolean(
    setting_from(overrides, "anti_tethering_enabled") or "0"
  )
  if not enabled then return nil, "The saved connection-sharing state is invalid." end
  if enabled == "0" then return "" end

  local lan = valid_interface(os.getenv("TARAKIFI_LAN_IFACE") or "br-lan")
  if not lan then return nil, "The customer network could not be detected." end
  local lines = {
    "table inet " .. table_name .. " {",
    "  chain customer_ingress {",
    "    type filter hook prerouting priority filter - 5; policy accept;",
    "    iifname \"" .. lan .. "\" ip ttl 63 drop",
    "    iifname \"" .. lan .. "\" ip ttl 127 drop",
    "  }",
    "}"
  }
  return table.concat(lines, "\n") .. "\n"
end

--- Prevent downstream devices from reusing a customer's active WiFi session.
function M.apply_anti_tethering(overrides)
  local live_rules, rules_err = anti_tethering_rules("tarakifi_anti_tethering", overrides)
  if not live_rules then return false, rules_err end
  if live_rules == "" then
    nft_delete_table("tarakifi_anti_tethering")
    os.remove(ANTI_TETHERING_RULES_FILE)
    return true
  end
  local check_rules, check_err = anti_tethering_rules(
    "tarakifi_anti_tethering_check", overrides
  )
  if not check_rules then return false, check_err end
  return nft_apply_checked(
    ANTI_TETHERING_RULES_FILE,
    check_rules,
    live_rules,
    "tarakifi_anti_tethering"
  )
end

local WAN_ACCESS_KEYS = {
  mode = "wan_troubleshooting_mode",
  source = "wan_troubleshooting_source",
  expires_at = "wan_troubleshooting_expires_at"
}

local function wan_access_values(overrides)
  overrides = overrides or {}
  return {
    mode = overrides.mode ~= nil and tostring(overrides.mode) or
      (db.setting(WAN_ACCESS_KEYS.mode) or ""),
    source = overrides.source ~= nil and tostring(overrides.source) or
      (db.setting(WAN_ACCESS_KEYS.source) or ""),
    expires_at = tonumber(overrides.expires_at ~= nil and overrides.expires_at or
      db.setting(WAN_ACCESS_KEYS.expires_at)) or 0
  }
end

local function wan_access_active(values, now)
  if values.mode ~= "admin" and values.mode ~= "admin_ssh" then return false end
  if not normalize_wan_source(values.source) then return false end
  return values.expires_at > (now or os.time())
end

local function save_wan_access_values(values)
  return db.set_settings_atomic({
    {key = WAN_ACCESS_KEYS.mode, value = values.mode or ""},
    {key = WAN_ACCESS_KEYS.source, value = values.source or ""},
    {key = WAN_ACCESS_KEYS.expires_at, value = tostring(values.expires_at or 0)}
  })
end

function M.apply_wan_access(overrides, now)
  local values = wan_access_values(overrides)
  now = now or os.time()
  local commands = {
    "flush set inet tarakifi wan_admin_sources",
    "flush set inet tarakifi wan_ssh_sources"
  }
  if wan_access_active(values, now) then
    local source = assert(normalize_wan_source(values.source))
    commands[#commands + 1] =
      "add element inet tarakifi wan_admin_sources { " .. source .. " }"
    if values.mode == "admin_ssh" then
      commands[#commands + 1] =
        "add element inet tarakifi wan_ssh_sources { " .. source .. " }"
    end
  end
  return nft_apply_set_commands(WAN_ACCESS_RULES_FILE, table.concat(commands, "\n") .. "\n")
end

function M.expire_wan_access(now)
  now = now or os.time()
  local current = wan_access_values()
  if current.expires_at <= 0 or current.expires_at > now then return true, false end

  local disabled = {mode = "", source = "", expires_at = 0}
  local applied, apply_err = M.apply_wan_access(disabled, now)
  if not applied then return false, apply_err end
  local saved, save_err = save_wan_access_values(disabled)
  if not saved then return false, tostring(save_err) end
  local persisted, persist_detail = db.persist("wan-access-expired", true)
  if not persisted then return false, tostring(persist_detail) end
  return true, true
end

local function wan_access_response(now)
  now = now or os.time()
  local values = wan_access_values()
  local active = wan_access_active(values, now)
  local address = wan_ipv4()
  return {
    active = active,
    mode = active and values.mode or "off",
    source = active and values.source or "",
    expires_at = active and values.expires_at or 0,
    remaining_seconds = active and math.max(0, values.expires_at - now) or 0,
    wan_ip = address,
    admin_url = address ~= "" and ("http://" .. address .. ":8080") or ""
  }
end

function M.get_wan_access(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local ok, expire_err = M.expire_wan_access()
  if not ok then
    return 500, json.encode({error = "access_status_failed", message = tostring(expire_err)})
  end
  return 200, json.encode(wan_access_response())
end

function M.save_wan_access(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  params = params or {}
  local previous = wan_access_values()
  local disabled = params.enabled == false or params.enabled == 0 or
    params.enabled == "0" or params.mode == "off"
  local next_values

  if disabled then
    next_values = {mode = "", source = "", expires_at = 0}
  else
    local mode = tostring(params.mode or "")
    if mode ~= "admin" and mode ~= "admin_ssh" then
      return 400, json.encode({error = "invalid_mode", message = "Choose an access mode."})
    end
    local source, source_err = normalize_wan_source(params.source)
    if not source then
      return 400, json.encode({error = "invalid_source", message = source_err})
    end
    local duration = tonumber(params.duration_seconds)
    if duration ~= 900 and duration ~= 3600 and duration ~= 14400 then
      return 400, json.encode({error = "invalid_duration", message = "Choose a valid duration."})
    end
    if mode == "admin_ssh" then
      local secured, secure_err = ensure_key_only_ssh()
      if not secured then
        return 409, json.encode({error = "ssh_key_required", message = secure_err})
      end
    end
    next_values = {
      mode = mode,
      source = source,
      expires_at = os.time() + duration
    }
  end

  local saved, save_err = save_wan_access_values(next_values)
  if not saved then
    return 500, json.encode({error = "database_write_failed", message = tostring(save_err)})
  end
  local applied, apply_err = M.apply_wan_access(next_values)
  if not applied then
    save_wan_access_values(previous)
    M.apply_wan_access(previous)
    return 500, json.encode({error = "access_apply_failed", message = tostring(apply_err)})
  end
  local persisted, persist_detail = db.persist("wan-access", true)
  if not persisted then
    save_wan_access_values(previous)
    M.apply_wan_access(previous)
    db.persist("wan-access-rollback", true)
    return 500, json.encode({
      error = "persistence_failed",
      message = "The change was not saved to permanent storage.",
      detail = tostring(persist_detail)
    })
  end
  return 200, json.encode(wan_access_response())
end

--- Reconcile generated policies after the base firewall and database are restored.
function M.apply_runtime_policies()
  local ok, err = M.apply_bandwidth()
  if not ok then return false, "bandwidth: " .. tostring(err) end
  ok, err = M.apply_site_blocking()
  if not ok then return false, "filtering: " .. tostring(err) end
  ok, err = M.apply_upstream_protection()
  if not ok then return false, "upstream protection: " .. tostring(err) end
  ok, err = M.apply_anti_tethering()
  if not ok then return false, "connection sharing: " .. tostring(err) end
  local values = wan_access_values()
  if values.expires_at > 0 and values.expires_at <= os.time() then
    ok, err = M.expire_wan_access()
  else
    ok, err = M.apply_wan_access(values)
  end
  if not ok then return false, "WAN troubleshooting access: " .. tostring(err) end
  return true
end

--- GET /api/admin/coin-nodes
function M.list_coin_nodes(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local now = os.time()
  local nodes = db.query([[
    SELECT node_id, name, last_heartbeat, ip_address, total_coins, area_id,
           fw_version, coin_dpin, relay_dpin, coin_gpio, relay_gpio, rssi,
           conn_mode, protocol_version, auth_enrolled_at
    FROM coin_nodes ORDER BY last_heartbeat DESC
  ]]) or {}
  for _, node in ipairs(nodes) do
    node.online = (now - (node.last_heartbeat or 0)) < 90
  end
  return 200, json.encode({nodes = nodes})
end

--- POST /api/admin/coin-nodes/rename
function M.rename_coin_node(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local node_id = params.node_id
  local name = params.name
  if not node_id or not name or name == "" then
    return 400, json.encode({error = "missing_params"})
  end
  db.exec("UPDATE coin_nodes SET name = ? WHERE node_id = ?", name, node_id)
  local err = persist_error("coin-node-rename")
  if err then return 500, err end
  schedule_cloud_backup("coin_node_change")
  return 200, json.encode({status = "ok"})
end

local function coin_node_dhcp_section(node_id)
  local mac = valid_mac(node_id)
  if not mac then return nil end
  return "tarakifi_coin_" .. mac:gsub(":", ""):lower()
end

local function remove_coin_node_dhcp_hosts(node_id, legacy_ip, legacy_name)
  local section_name = coin_node_dhcp_section(node_id)
  if not section_name then return false, "invalid_node_id" end

  local cf = io.open(DHCP_CONFIG_FILE, "r")
  if not cf then return true, false end
  local content = cf:read("*a")
  cf:close()

  local output = {}
  local block = {}
  local in_host = false
  local current_section = nil
  local host_ip = nil
  local host_name = nil
  local removed = false

  local function flush_section()
    if #block == 0 then return end
    local remove = in_host and current_section == section_name
    if in_host and legacy_ip and legacy_name then
      remove = remove or (host_ip == legacy_ip and host_name == legacy_name)
    end
    if remove then
      removed = true
    else
      for _, block_line in ipairs(block) do
        output[#output + 1] = block_line
      end
    end
    block = {}
    in_host = false
    current_section = nil
    host_ip = nil
    host_name = nil
  end

  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^%s*config%s+") then
      flush_section()
      local kind = line:match("^%s*config%s+(%S+)")
      in_host = kind == "host"
      if in_host then
        current_section = line:match("^%s*config%s+host%s+['\"]([^'\"]+)['\"]")
      end
    elseif in_host then
      host_ip = host_ip or line:match("^%s*option%s+ip%s+['\"]([^'\"]+)['\"]")
      host_name = host_name or line:match("^%s*option%s+name%s+['\"]([^'\"]+)['\"]")
    end
    block[#block + 1] = line
  end
  flush_section()

  if not removed then return true, false end
  local tmp = DHCP_CONFIG_FILE .. ".tarakifi.tmp"
  local wf, open_err = io.open(tmp, "w")
  if not wf then return false, open_err or "dhcp_config_write_failed" end
  wf:write(table.concat(output, "\n"))
  wf:close()
  local renamed, rename_err = os.rename(tmp, DHCP_CONFIG_FILE)
  if not renamed then
    os.remove(tmp)
    return false, rename_err or "dhcp_config_replace_failed"
  end
  return true, true
end

--- POST /api/admin/coin-nodes/delete
function M.delete_coin_node(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local node_id = valid_mac(params.node_id)
  if not node_id then return 400, json.encode({error = "invalid_node_id"}) end
  local node = db.row("SELECT node_id FROM coin_nodes WHERE node_id = ?", node_id)
  if not node then return 404, json.encode({error = "node_not_found"}) end
  db.exec("DELETE FROM coin_nodes WHERE node_id = ?", node_id)
  local err = persist_error("coin-node-delete")
  if err then return 500, err end
  local cleanup_ok, cleanup_result = remove_coin_node_dhcp_hosts(node_id)
  schedule_cloud_backup("coin_node_change")
  return 200, json.encode({
    status = "ok",
    unbound = true,
    history_preserved = true,
    dhcp_reservation_removed = cleanup_ok and cleanup_result == true,
    dhcp_cleanup_warning = cleanup_ok and nil or tostring(cleanup_result)
  })
end

--- POST /api/admin/coin-nodes/set-static-ip
-- Creates a DHCP reservation so the NodeMCU always gets the same IP.
-- Uses node_id (hostname) to identify the device; looks up MAC from DHCP leases.
function M.set_coin_node_static_ip(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local ip      = params.ip
  local name    = params.name or "tarakifi-vendo"
  local node_id = valid_mac(params.node_id)
  if not ip then return 400, json.encode({error = "missing_params"}) end
  if not node_id then return 400, json.encode({error = "invalid_node_id"}) end
  if not db.row("SELECT node_id FROM coin_nodes WHERE node_id = ?", node_id) then
    return 404, json.encode({error = "node_not_found"})
  end
  if not ip:match("^10%.0%.0%.%d+$") then
    return 400, json.encode({error = "invalid_ip", message = "IP must be in 10.0.0.x range"})
  end
  -- Look up MAC from DHCP leases file (pure Lua, no shell pipe)
  local mac = nil
  local lf = io.open(DHCP_LEASES_FILE, "r")
  if lf then
    for line in lf:lines() do
      local lmac, lip, lname = line:match("^%S+%s+(%S+)%s+(%S+)%s+(%S+)")
      if lmac and node_id and (lname == node_id) then
        mac = lmac; break
      end
    end
    lf:close()
  end
  local cleaned, clean_err = remove_coin_node_dhcp_hosts(node_id, ip, name)
  if not cleaned then
    return 500, json.encode({error = "dhcp_config_update_failed", detail = clean_err})
  end
  -- Named sections let unbind remove only the reservation owned by this node.
  local safe_name = (name ~= "" and name or "tarakifi-vendo"):gsub("'", "")
  local safe_ip   = ip:gsub("'", "")
  local section_name = coin_node_dhcp_section(node_id)
  local entry = "\nconfig host '" .. section_name .. "'\n"
  if mac and mac ~= "" then
    entry = entry .. "\toption mac '" .. mac:gsub("'","") .. "'\n"
  end
  entry = entry .. "\toption ip '" .. safe_ip .. "'\n"
  entry = entry .. "\toption name '" .. safe_name .. "'\n"
  local af, append_err = io.open(DHCP_CONFIG_FILE, "a")
  if not af then
    return 500, json.encode({error = "dhcp_config_update_failed", detail = append_err})
  end
  af:write(entry)
  af:close()
  -- DHCP reservation takes effect on next NodeMCU DHCP renewal or reboot.
  schedule_cloud_backup("coin_node_change")
  return 200, json.encode({status = "ok", ip = ip, mac = mac or ""})
end

--- POST /api/admin/coin-nodes/generate-bind
-- Generates a 6-digit bind code valid for 10 minutes.
-- Persists code in DB settings so coin.lua can validate it across requests
-- (uhttpd reloads Lua state per-request; in-memory tables don't survive).
function M.generate_bind_code(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  if db.row("SELECT node_id FROM coin_nodes LIMIT 1") then
    return 409, json.encode({
      error = "coinslot_limit_reached",
      message = "This router already has a bound coinslot. Unbind it before adding another."
    })
  end
  local code, random_err = util.random_string("0123456789", 6)
  if not code then
    return 500, json.encode({error = "secure_random_unavailable", detail = random_err})
  end
  local expires = os.time() + 600
  db.set_runtime_setting("_pending_bind_code",    code)
  db.set_runtime_setting("_pending_bind_expires", tostring(expires))
  return 200, json.encode({ status = "ok", code = code, expires = expires })
end

--- POST /admin/upload — Handle file uploads (sounds, logo, hero)
-- Accepts multipart/form-data with fields:
--   type: "coin_sound" | "tick_sound" | "logo" | "hero"
--   file: the binary file data
local UPLOAD_LIMITS = {
  coin_sound = {
    max_bytes = 921600, exts = { mp3=1, wav=1, ogg=1 },
    allowed = ".mp3, .wav, .ogg", target = "coin_sound", kind = "audio"
  },
  tick_sound = {
    max_bytes = 204800, exts = { mp3=1, wav=1, ogg=1 },
    allowed = ".mp3, .wav, .ogg", target = "tick_sound", kind = "audio"
  },
  logo = {
    max_bytes = 512000, exts = { png=1, jpg=1, jpeg=1, webp=1 },
    allowed = ".png, .jpg, .jpeg, .webp", target = "logo_custom", kind = "logo",
    fallback = "logo.png"
  },
  hero = {
    max_bytes = 921600, exts = { png=1, jpg=1, jpeg=1, webp=1 },
    allowed = ".png, .jpg, .jpeg, .webp", target = "hero_custom", kind = "hero",
    fallback = "hero.jpg"
  },
}
local PORTAL_ASSETS = os.getenv("TARAKIFI_PORTAL_ASSETS") or
  "/opt/tarakifi/www/portal"

local function u16be(data, pos)
  local a, b = data:byte(pos, pos + 1)
  if not a or not b then return nil end
  return (a * 256) + b
end

local function u16le(data, pos)
  local a, b = data:byte(pos, pos + 1)
  if not a or not b then return nil end
  return a + (b * 256)
end

local function u24le(data, pos)
  local a, b, c = data:byte(pos, pos + 2)
  if not a or not b or not c then return nil end
  return a + (b * 256) + (c * 65536)
end

local function u32be(data, pos)
  local a, b, c, d = data:byte(pos, pos + 3)
  if not a or not b or not c or not d then return nil end
  return (a * 16777216) + (b * 65536) + (c * 256) + d
end

local JPEG_SOF = {
  [0xC0]=true, [0xC1]=true, [0xC2]=true, [0xC3]=true,
  [0xC5]=true, [0xC6]=true, [0xC7]=true,
  [0xC9]=true, [0xCA]=true, [0xCB]=true,
  [0xCD]=true, [0xCE]=true, [0xCF]=true,
}

local function jpeg_dimensions(data)
  if #data < 12 or data:sub(1, 3) ~= "\255\216\255" or
      data:sub(-2) ~= "\255\217" then return nil end
  local pos = 3
  while pos <= #data - 8 do
    if data:byte(pos) ~= 0xFF then
      pos = pos + 1
    else
      while data:byte(pos) == 0xFF do pos = pos + 1 end
      local marker = data:byte(pos)
      pos = pos + 1
      if not marker or marker == 0xD9 or marker == 0xDA then break end
      if marker == 0x01 or (marker >= 0xD0 and marker <= 0xD8) then
        -- Standalone marker; no segment length.
      else
        local length = u16be(data, pos)
        if not length or length < 2 or pos + length - 1 > #data then return nil end
        if JPEG_SOF[marker] then
          local height = u16be(data, pos + 3)
          local width = u16be(data, pos + 5)
          if width and height and width > 0 and height > 0 then
            return width, height
          end
          return nil
        end
        pos = pos + length
      end
    end
  end
  return nil
end

local function webp_dimensions(data)
  if #data < 30 or data:sub(1, 4) ~= "RIFF" or
      data:sub(9, 12) ~= "WEBP" then return nil end
  local chunk = data:sub(13, 16)
  if chunk == "VP8X" then
    local width = u24le(data, 25)
    local height = u24le(data, 28)
    if width and height then return width + 1, height + 1 end
  elseif chunk == "VP8L" and data:byte(21) == 0x2F then
    local b1, b2, b3, b4 = data:byte(22, 25)
    if b1 and b2 and b3 and b4 then
      local width = 1 + b1 + ((b2 % 64) * 256)
      local height = 1 + math.floor(b2 / 64) + (b3 * 4) + ((b4 % 16) * 1024)
      return width, height
    end
  elseif chunk == "VP8 " and data:sub(24, 26) == "\157\001\042" then
    local raw_width = u16le(data, 27)
    local raw_height = u16le(data, 29)
    if raw_width and raw_height then
      return raw_width % 16384, raw_height % 16384
    end
  end
  return nil
end

local function image_details(data)
  if #data >= 33 and data:sub(1, 8) == "\137PNG\r\n\026\n" and
      data:sub(13, 16) == "IHDR" and data:find("IEND", 25, true) then
    local width, height = u32be(data, 17), u32be(data, 21)
    if width and height and width > 0 and height > 0 then
      return "png", width, height
    end
  end
  local width, height = jpeg_dimensions(data)
  if width then return "jpeg", width, height end
  width, height = webp_dimensions(data)
  if width and width > 0 and height and height > 0 then
    return "webp", width, height
  end
  return nil
end

local function audio_format(data)
  if #data >= 44 and data:sub(1, 4) == "RIFF" and
      data:sub(9, 12) == "WAVE" and data:find("fmt ", 13, true) and
      data:find("data", 13, true) then return "wav" end
  if #data >= 28 and data:sub(1, 4) == "OggS" then return "ogg" end
  local function has_mp3_frame(pos)
    local first, second, third = data:byte(pos, pos + 2)
    if first ~= 0xFF or not second or second < 0xE0 or not third then return false end
    local version = math.floor(second / 8) % 4
    local layer = math.floor(second / 2) % 4
    local bitrate = math.floor(third / 16)
    local sample_rate = math.floor(third / 4) % 4
    return version ~= 1 and layer ~= 0 and bitrate ~= 0 and bitrate ~= 15 and
      sample_rate ~= 3
  end
  local frame_pos = 1
  if data:sub(1, 3) == "ID3" and #data >= 10 then
    local a, b, c, d = data:byte(7, 10)
    if not a or a >= 128 or b >= 128 or c >= 128 or d >= 128 then return nil end
    local tag_size = (a * 2097152) + (b * 16384) + (c * 128) + d
    frame_pos = 11 + tag_size
    local flags = data:byte(6) or 0
    if math.floor(flags / 16) % 2 == 1 then frame_pos = frame_pos + 10 end
  end
  local frame_limit = math.min(#data - 3, frame_pos + 64)
  for pos = frame_pos, frame_limit do
    if has_mp3_frame(pos) then return "mp3" end
  end
  return nil
end

local function normalized_image_ext(ext)
  return (ext == "jpg" or ext == "jpeg") and "jpeg" or ext
end

local function validate_upload_data(upload_type, ext, data)
  local limits = UPLOAD_LIMITS[upload_type]
  if not limits then return false, "invalid_type", "Unknown upload type." end
  if type(data) ~= "string" or data == "" then
    return false, "empty_file", "The selected file is empty."
  end
  if #data > limits.max_bytes then
    return false, "file_too_large",
      "File is too large. Maximum: " .. math.floor(limits.max_bytes / 1024) .. " KB."
  end
  if not ext or not limits.exts[ext] then
    return false, "invalid_format", "Allowed formats: " .. limits.allowed .. "."
  end

  if limits.kind == "audio" then
    local detected = audio_format(data)
    if not detected then
      return false, "invalid_audio", "This is not a valid MP3, WAV, or OGG audio file."
    end
    if detected ~= ext then
      return false, "format_mismatch",
        "The file content does not match its ." .. ext .. " extension."
    end
    return true, {format = detected}
  end

  local detected, width, height = image_details(data)
  if not detected then
    return false, "invalid_image", "This is not a valid PNG, JPEG, or WebP image."
  end
  if detected ~= normalized_image_ext(ext) then
    return false, "format_mismatch",
      "The file content does not match its ." .. ext .. " extension."
  end

  if limits.kind == "hero" then
    local ratio = width / height
    if width < 640 or height < 320 or width > 1920 or height > 1080 or
        ratio < 1.5 or ratio > 2.0 then
      return false, "invalid_dimensions",
        "Hero must be 640x320 to 1920x1080 with a 1.5:1 to 2:1 aspect ratio. " ..
        "Selected: " .. width .. "x" .. height .. "."
    end
  elseif width < 64 or height < 64 or width > 1024 or height > 1024 then
    return false, "invalid_dimensions",
      "Logo must be 64x64 to 1024x1024. Selected: " .. width .. "x" .. height .. "."
  end
  return true, {format = detected, width = width, height = height}
end

M._validate_upload_data = validate_upload_data

local DEFAULT_ASSETS = { ["hero.jpg"] = true, ["logo.png"] = true }

local function next_asset_version()
  local current = math.floor(tonumber(db.setting("portal_asset_version")) or 0)
  return math.max(os.time(), current + 1)
end

local function remove_custom_asset(filename)
  filename = tostring(filename or "")
  if filename == "" or DEFAULT_ASSETS[filename] or
      not filename:match("^[%w_.%-]+$") then return end
  os.remove(PORTAL_ASSETS .. "/" .. filename)
end

function M.upload_asset(env, params)
  if not check_auth(env) then
    return 401, json.encode({error = "unauthorized"})
  end

  -- Get upload type from multipart field or query
  local upload_type
  if params.type and params.type.value then
    upload_type = params.type.value
  elseif env.query and env.query.type then
    upload_type = env.query.type
  end

  if not upload_type or not UPLOAD_LIMITS[upload_type] then
    return 400, json.encode({error = "invalid_type", message = "type must be: coin_sound, tick_sound, logo, or hero"})
  end

  if not persistent_media_uploads_supported() then
    return 507, json.encode({
      error = "storage_unsupported",
      message = "Custom media uploads are unavailable on COMFAST CF-E314N v2. Built-in firmware media is used instead."
    })
  end

  local limits = UPLOAD_LIMITS[upload_type]
  local file_part = params.file
  if not file_part or not file_part.value or file_part.value == "" then
    return 400, json.encode({error = "no_file", message = "No file uploaded"})
  end

  local data = file_part.value
  local filename = file_part.filename or ""
  local ext = filename:match("%.([^.]+)$")
  if ext then ext = ext:lower() end
  local valid, details_or_error, validation_message =
    validate_upload_data(upload_type, ext, data)
  if not valid then
    return 400, json.encode({
      error = details_or_error,
      message = validation_message
    })
  end
  local details = details_or_error

  local target_name = limits.target .. "." .. ext
  local target_path = PORTAL_ASSETS .. "/" .. target_name
  local staged_path = target_path .. ".upload.tmp"

  local f = io.open(staged_path, "wb")
  if not f then
    return 500, json.encode({error = "write_failed", message = "Cannot write to flash"})
  end
  local wrote = f:write(data)
  f:close()
  if not wrote then
    os.remove(staged_path)
    return 500, json.encode({error = "write_failed", message = "Cannot write to flash"})
  end
  local renamed, rename_err = os.rename(staged_path, target_path)
  if not renamed then
    os.remove(staged_path)
    return 500, json.encode({
      error = "write_failed",
      message = "Cannot finalize upload: " .. tostring(rename_err or "unknown error")
    })
  end

  local setting_key = "portal_" .. upload_type .. "_file"
  local previous_name = db.setting(setting_key)
  if previous_name ~= target_name then remove_custom_asset(previous_name) end
  for old_ext, _ in pairs(limits.exts) do
    local old_name = limits.target .. "." .. old_ext
    if old_name ~= target_name then remove_custom_asset(old_name) end
  end

  local asset_version = next_asset_version()
  db.set_setting(setting_key, target_name)
  db.set_setting("portal_asset_version", tostring(asset_version))
  local err = persist_error("portal-asset-upload")
  if err then return 500, err end
  schedule_cloud_backup("settings_change")

  return 200, json.encode({
    ok = true,
    file = target_name,
    size = #data,
    width = details.width,
    height = details.height,
    asset_version = asset_version
  })
end

--- DELETE /admin/upload — Remove an uploaded asset
function M.delete_asset(env, params)
  if not check_auth(env) then
    return 401, json.encode({error = "unauthorized"})
  end
  local upload_type = params.type
  if not upload_type or not UPLOAD_LIMITS[upload_type] then
    return 400, json.encode({error = "invalid_type"})
  end
  local limits = UPLOAD_LIMITS[upload_type]
  local setting_key = "portal_" .. upload_type .. "_file"
  remove_custom_asset(db.setting(setting_key))
  for ext, _ in pairs(limits.exts) do
    remove_custom_asset(limits.target .. "." .. ext)
  end
  db.set_setting(setting_key, "")
  db.set_setting("portal_asset_version", tostring(next_asset_version()))
  local err = persist_error("portal-asset-delete")
  if err then return 500, err end
  schedule_cloud_backup("settings_change")
  return 200, json.encode({ok = true})
end

--- GET /api/admin/system/check-update
-- Fetches the latest release manifest from the vendor platform and compares versions.
-- SECURITY: Only returns version/notes/update_available to the browser.
-- download_url and sha256 are kept server-side only.
function M.check_update(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local current_ver = "1.0.0"
  local vf = io.open(VERSION_FILE, "r")
  if vf then current_ver = vf:read("*l") or current_ver; vf:close() end
  current_ver = trim(current_ver)
  if #current_ver > 64 or not current_ver:match("^%d+%.%d+%.%d+[%w%.%-]*$") then
    current_ver = "1.0.0"
  end
  local board_name = read_board_name()
  if not board_name then
    return 200, json.encode({
      error = "Router board identity unavailable",
      version = current_ver,
      current_version = current_ver,
      update_available = false,
    })
  end
  local separator = OTA_MANIFEST_URL:find("?", 1, true) and "&" or "?"
  local check_url = OTA_MANIFEST_URL .. separator .. "current_version=" .. current_ver
  check_url = append_board_param(check_url, board_name)
  if not fetch_file(check_url, OTA_CHECK_PATH, 15) then
    return 200, json.encode({
      error = "Failed to reach update server",
      version = current_ver,
      current_version = current_ver,
      update_available = false,
    })
  end
  local file = io.open(OTA_CHECK_PATH, "r")
  if not file then
    return 200, json.encode({
      error = "Failed to read response",
      version = current_ver,
      current_version = current_ver,
      update_available = false,
    })
  end
  local raw = file:read("*a")
  file:close()
  os.remove(OTA_CHECK_PATH)
  local manifest = json.decode(raw)
  if not manifest then
    return 200, json.encode({
      error = "Invalid response format",
      version = current_ver,
      current_version = current_ver,
      update_available = false,
    })
  end
  return 200, json.encode({
    version = manifest.version or current_ver,
    current_version = current_ver,
    update_available = manifest.update_available or false,
    notes = manifest.notes or "",
    released_at = "",
  })
end

--- POST /api/admin/system/manual-update
function M.manual_update(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  params = params or {}

  if params._manual_multipart_rejected then
    return 400, json.encode({
      error = "unsupported_upload",
      message = "Reload the admin page and try the firmware upload again."
    })
  end

  local upload = params._raw_upload
  if type(upload) ~= "table" or type(upload.recv) ~= "function" then
    return 400, json.encode({error = "no_file", message = "Choose a firmware .bin file first."})
  end

  local content_type = tostring(upload.content_type or ""):lower()
  if content_type ~= "" and not content_type:find("application/octet%-stream", 1, false) then
    return 400, json.encode({error = "invalid_format", message = "Firmware file must be a .bin file."})
  end

  local filename = manual_filename(env, params)
  if not filename then
    return 400, json.encode({error = "invalid_format", message = "Firmware file must be a .bin file."})
  end
  if not filename:lower():match("%.bin$") then
    return 400, json.encode({error = "invalid_format", message = "Firmware file must be a .bin file."})
  end

  local size = tonumber(upload.content_length or params.size) or 0
  if size < 1048576 then
    return 400, json.encode({error = "file_too_small", message = "Firmware file is too small."})
  end
  if size > MAX_MANUAL_FIRMWARE_BYTES then
    return 413, json.encode({error = "file_too_large", message = "Firmware file is too large."})
  end

  local mode = validate_manual_update_mode(params)
  if not mode then
    return 400, json.encode({error = "invalid_mode", message = "Choose Fresh Install or Preserve Settings."})
  end

  cleanup_manual_firmware_upload()
  collectgarbage("collect")

  local required_kb = math.ceil(size / 1024) + 2048
  local tmp_free_kb = fs_available_kb("/tmp")
  if tmp_free_kb > 0 and tmp_free_kb < required_kb then
    return 507, json.encode({error = "not_enough_space", message = "Not enough temporary space for this firmware."})
  end

  local wrote, write_err, streamed_size = stage_manual_firmware(upload, size)
  if not wrote then
    return 500, json.encode({error = "write_failed", message = tostring(write_err or "Cannot stage firmware.")})
  end
  if streamed_size ~= size then
    cleanup_manual_firmware_upload()
    return 500, json.encode({error = "write_failed", message = "Firmware staging did not complete."})
  end

  return apply_manual_firmware(size, mode)
end

--- POST /api/admin/system/manual-update/chunk
function M.manual_update_chunk(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  params = params or {}

  if params._manual_multipart_rejected then
    return 400, json.encode({
      error = "unsupported_upload",
      message = "Reload the admin page and try the firmware upload again."
    })
  end

  local upload = params._raw_upload
  if type(upload) ~= "table" or type(upload.recv) ~= "function" then
    return 400, json.encode({error = "no_file", message = "Choose a firmware .bin file first."})
  end

  local content_type = tostring(upload.content_type or ""):lower()
  if content_type ~= "" and not content_type:find("application/octet%-stream", 1, false) then
    return 400, json.encode({error = "invalid_format", message = "Firmware file must be a .bin file."})
  end

  local filename = manual_filename(env, params)
  if not filename or not filename:lower():match("%.bin$") then
    return 400, json.encode({error = "invalid_format", message = "Firmware file must be a .bin file."})
  end

  local mode = validate_manual_update_mode(params)
  if not mode then
    return 400, json.encode({error = "invalid_mode", message = "Choose Fresh Install or Preserve Settings."})
  end

  local upload_id = manual_upload_id(params.upload_id or "")
  if not upload_id then
    return 400, json.encode({error = "invalid_upload", message = "Reload the admin page and try the firmware upload again."})
  end

  local total = tonumber(params.total) or 0
  local offset = tonumber(params.offset) or -1
  local chunk_size = tonumber(upload.content_length or params.size) or 0
  local final_chunk = tostring(params.final or "") == "1"
  if total < 1048576 then
    cleanup_manual_firmware_upload()
    return 400, json.encode({error = "file_too_small", message = "Firmware file is too small."})
  end
  if total > MAX_MANUAL_FIRMWARE_BYTES then
    cleanup_manual_firmware_upload()
    return 413, json.encode({error = "file_too_large", message = "Firmware file is too large."})
  end
  if offset < 0 or offset > total then
    cleanup_manual_firmware_upload()
    return 409, json.encode({error = "offset_mismatch", message = "Firmware upload lost sync. Please try again."})
  end
  if chunk_size <= 0 or chunk_size > MAX_MANUAL_UPLOAD_CHUNK_BYTES then
    cleanup_manual_firmware_upload()
    return 413, json.encode({error = "chunk_too_large", message = "Firmware upload chunk is too large. Please try again."})
  end
  if offset + chunk_size > total then
    cleanup_manual_firmware_upload()
    return 409, json.encode({error = "offset_mismatch", message = "Firmware upload lost sync. Please try again."})
  end

  if offset == 0 then
    cleanup_manual_firmware_upload()
    if not write_manual_upload_state({
        upload_id = upload_id,
        filename = filename,
        mode = mode,
        total = total,
      }) then
      cleanup_manual_firmware_upload()
      return 500, json.encode({error = "write_failed", message = "Cannot prepare firmware upload."})
    end
  else
    local state = read_manual_upload_state()
    if not manual_state_matches(state, upload_id, filename, mode, total) then
      cleanup_manual_firmware_upload()
      return 409, json.encode({error = "offset_mismatch", message = "Firmware upload lost sync. Please try again."})
    end
    local existing_size = file_size(MANUAL_FIRMWARE_PART_PATH) or 0
    if existing_size ~= offset then
      cleanup_manual_firmware_upload()
      return 409, json.encode({error = "offset_mismatch", message = "Firmware upload lost sync. Please try again."})
    end
  end

  local remaining_kb = math.ceil((total - offset) / 1024) + 2048
  local tmp_free_kb = fs_available_kb("/tmp")
  if tmp_free_kb > 0 and tmp_free_kb < remaining_kb then
    cleanup_manual_firmware_upload()
    return 507, json.encode({error = "not_enough_space", message = "Not enough temporary space for this firmware."})
  end

  local wrote, write_err, streamed_size = stage_manual_chunk(upload, chunk_size)
  if not wrote or streamed_size ~= chunk_size then
    cleanup_manual_firmware_upload()
    return 500, json.encode({error = "write_failed", message = tostring(write_err or "Cannot stage firmware chunk.")})
  end

  local received = file_size(MANUAL_FIRMWARE_PART_PATH) or 0
  if received ~= offset + chunk_size then
    cleanup_manual_firmware_upload()
    return 409, json.encode({error = "offset_mismatch", message = "Firmware upload lost sync. Please try again."})
  end

  if received < total then
    if final_chunk then
      cleanup_manual_firmware_upload()
      return 500, json.encode({error = "write_failed", message = "Firmware staging did not complete."})
    end
    return 200, json.encode({
      status = "chunk_received",
      complete = false,
      received = received,
      total = total,
    })
  end

  if received ~= total then
    cleanup_manual_firmware_upload()
    return 500, json.encode({error = "write_failed", message = "Firmware staging did not complete."})
  end

  os.remove(MANUAL_FIRMWARE_PATH)
  local renamed, rename_err = os.rename(MANUAL_FIRMWARE_PART_PATH, MANUAL_FIRMWARE_PATH)
  if not renamed then
    cleanup_manual_firmware_upload()
    return 500, json.encode({error = "write_failed", message = tostring(rename_err or "Cannot finalize firmware upload.")})
  end

  return apply_manual_firmware(total, mode)
end

--- POST /api/admin/system/update
-- Downloads firmware and applies sysupgrade with full safety checks:
-- 1. Re-fetches manifest server-side (never trusts client-provided URLs)
-- 2. Downloads from vendor proxy (no GitHub token on device)
-- 3. Verifies SHA-256 integrity after download
-- 4. Runs sysupgrade -T to validate image compatibility
-- 5. Uses sysupgrade WITHOUT -n to preserve /etc/ settings and customer data
function M.system_update(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local version = tostring((params or {}).version or "")
  if version == "" or #version > 64 or not version:match("^%d+%.%d+%.%d+[%w%.%-]*$") then
    return 400, json.encode({error = "Missing version"})
  end
  -- Step 1: Fetch manifest server-side to get download_url (proxy) + sha256
  -- SECURITY: Never accept download_url from the browser. The vendor server
  -- proxies the firmware download — no GitHub token needed on this device.
  local board_name = read_board_name()
  if not board_name then
    return 409, json.encode({
      error = "board_identity_unavailable",
      message = "Router board identity is unavailable. Firmware update was not started."
    })
  end
  local manifest_url = append_board_param(OTA_MANIFEST_URL, board_name)
  if not fetch_file(manifest_url, OTA_MANIFEST_PATH, 15) then
    return 500, json.encode({error = "Cannot reach update server"})
  end
  local mf = io.open(OTA_MANIFEST_PATH, "r")
  if not mf then
    return 500, json.encode({error = "Cannot read manifest"})
  end
  local raw = mf:read("*a")
  mf:close()
  os.remove(OTA_MANIFEST_PATH)
  local manifest = json.decode(raw)
  if not manifest then
    return 500, json.encode({error = "Invalid manifest from server"})
  end
  -- Verify the manifest version matches what the admin requested
  if manifest.version ~= version then
    return 409, json.encode({error = "Version mismatch: server has v" .. (manifest.version or "?") .. " but requested v" .. version .. ". Try checking for updates again."})
  end
  local download_url = manifest.download_url or ""
  local expected_sha256 = tostring(manifest.sha256 or ""):lower()
  local proxy_prefix = OTA_PROXY_URL .. "?"
  if download_url ~= OTA_PROXY_URL and download_url:sub(1, #proxy_prefix) ~= proxy_prefix then
    return 500, json.encode({error = "Invalid firmware proxy URL in manifest"})
  end
  if #expected_sha256 ~= 64 or not expected_sha256:match("^%x+$") then
    return 500, json.encode({error = "Manifest is missing a valid SHA-256 checksum"})
  end
  download_url = append_board_param(download_url, board_name)
  local tmp_free_kb = fs_available_kb("/tmp")
  if tmp_free_kb > 0 and tmp_free_kb < MIN_OTA_TMP_FREE_KB then
    return 507, json.encode({
      error = "not_enough_space",
      message = "Not enough temporary memory for a safe firmware update."
    })
  end
  -- Step 2: Download firmware from vendor proxy (no auth headers needed)
  -- The vendor server handles GitHub authentication internally
  local fw_path = OTA_FIRMWARE_PATH
  if not fetch_file(download_url, fw_path, 300) then
    return 500, json.encode({error = "Firmware download failed"})
  end
  -- Check if download succeeded
  local f = io.open(fw_path, "r")
  if not f then
    return 500, json.encode({error = "Firmware download is unavailable"})
  end
  local size = f:seek("end")
  f:close()
  if size < 1048576 then  -- firmware should be at least 1MB
    os.remove(fw_path)
    return 500, json.encode({error = "Downloaded file too small (" .. size .. " bytes), likely an error page"})
  end
  if size > MAX_MANUAL_FIRMWARE_BYTES then
    os.remove(fw_path)
    return 500, json.encode({error = "Downloaded firmware is larger than the supported image limit"})
  end
  -- Step 3: Verify SHA-256 integrity
  local actual_sha256 = sha256_file(fw_path)
  if not actual_sha256 or actual_sha256:lower() ~= expected_sha256 then
    os.remove(fw_path)
    return 500, json.encode({
      error = "SHA-256 verification failed. Firmware may be corrupted or tampered with.",
      expected = expected_sha256,
      actual = actual_sha256 or "unknown",
    })
  end
  -- Step 4: Validate firmware image with sysupgrade -T (dry-run board check)
  local test_command = shell_quote(SYSUPGRADE_BIN) .. " -T " .. shell_quote(fw_path) ..
    " >/dev/null 2>&1"
  if not command_ok(test_command) then
    os.remove(fw_path)
    return 500, json.encode({error = "Firmware image validation failed. The image is not compatible with this board."})
  end
  with_cloud_backup(function(cloud)
    return cloud.run_now("pre_ota")
  end)
  -- Step 5: Flush the current RAM database before sysupgrade collects its
  -- preservation archive. The image supplies the new version file on boot.
  local persisted, persist_detail = db.persist("firmware-upgrade", true)
  if not persisted or not command_ok(SYNC_COMMAND) then
    os.remove(fw_path)
    return 500, json.encode({
      error = "Firmware is valid but customer data could not be saved.",
      detail = tostring(persist_detail or "sync failed")
    })
  end
  -- Step 6: Apply sysupgrade without -n so keep.d and OpenWrt configuration
  -- are preserved. Tests run synchronously; production detaches before reboot.
  local apply_command = shell_quote(SYSUPGRADE_BIN) .. " " .. shell_quote(fw_path)
  if not SYSUPGRADE_SYNC then apply_command = apply_command .. " >/dev/null 2>&1 &" end
  if not command_ok(apply_command) then
    os.remove(fw_path)
    return 500, json.encode({error = "Firmware validation passed, but sysupgrade could not start."})
  end
  return 200, json.encode({status = "ok", message = "Firmware update started. Settings will be preserved. Router will reboot."})
end

return M
