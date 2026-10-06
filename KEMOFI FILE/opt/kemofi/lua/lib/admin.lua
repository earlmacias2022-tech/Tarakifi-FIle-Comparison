--- KemoFi Admin API Handler
-- Full admin panel with session management, vouchers, bandwidth, scheduling,
-- backup/restore, OTA, asset upload, license activation, system info.
local db = require("lib.db")
local session = require("lib.session")
local clients = require("lib.clients")
local json = require("lib.json")
local util = require("lib.util")
local remote_access = require("lib.remote_access")
local rate_config = require("lib.rates")
local capabilities = require("lib.capabilities")
local M = {}

local function marker_present(path)
  local file = io.open(path, "r")
  if not file then return false end
  file:close()
  return true
end

-- Full images and approved Lite images retain SQM. A marker is still honored
-- so legacy preserve-settings upgrades cannot expose stale SQM controls.
local DEVICE_CAPABILITIES = capabilities.get()
local SQM_AVAILABLE = DEVICE_CAPABILITIES.sqm_available ~= false and
  not marker_present("/etc/kemofi/sqm-disabled")

local CRON_FILE = os.getenv("KEMOFI_CRON_FILE") or "/etc/crontabs/root"
local CRON_RESTART_COMMAND = os.getenv("KEMOFI_CRON_RESTART_COMMAND") or
  "/etc/init.d/cron restart >/dev/null 2>&1"
local NFT_BIN = os.getenv("KEMOFI_NFT_BIN") or "/usr/sbin/nft"
local DNSMASQ_BIN = os.getenv("KEMOFI_DNSMASQ_BIN") or "/usr/sbin/dnsmasq"
local DNSMASQ_RESTART_COMMAND = os.getenv("KEMOFI_DNSMASQ_RESTART_COMMAND") or
  "/etc/init.d/dnsmasq restart >/dev/null 2>&1"
local DHCP_CONFIG_FILE = os.getenv("KEMOFI_DHCP_CONFIG_FILE") or
  "/etc/config/dhcp"
local DHCP_LEASES_FILE = os.getenv("KEMOFI_DHCP_LEASES_FILE") or
  "/tmp/dhcp.leases"
local DNSMASQ_BLOCK_FILE = os.getenv("KEMOFI_DNSMASQ_BLOCK_FILE") or
  "/etc/dnsmasq.d/blocked.conf"
local BW_RULES_FILE = os.getenv("KEMOFI_BW_RULES_FILE") or "/tmp/kemofi_bw.nft"
local GAMING_RULES_FILE = os.getenv("KEMOFI_GAMING_RULES_FILE") or
  "/tmp/kemofi_gaming.nft"
local SQM_CONFIG_FILE = os.getenv("KEMOFI_SQM_CONFIG_FILE") or "/etc/config/sqm"
local SQM_CONFIG_TEMP_FILE = os.getenv("KEMOFI_SQM_CONFIG_TEMP_FILE") or "/tmp/kemofi-sqm.config"
local SQM_SERVICE = os.getenv("KEMOFI_SQM_SERVICE") or "/etc/init.d/sqm"
local UPSTREAM_RULES_FILE = os.getenv("KEMOFI_UPSTREAM_RULES_FILE") or
  "/tmp/kemofi_upstream.nft"
local ANTI_TETHERING_RULES_FILE = os.getenv("KEMOFI_ANTI_TETHERING_RULES_FILE") or
  "/tmp/kemofi_anti_tethering.nft"
local UCI_BIN = os.getenv("KEMOFI_UCI_BIN") or "/sbin/uci"
local NETWORK_CONFIG_FILE = os.getenv("KEMOFI_NETWORK_CONFIG_FILE") or
  "/etc/config/network"
local WAN_PENDING_FILE = os.getenv("KEMOFI_WAN_PENDING_FILE") or
  "/tmp/kemofi-wan-pending"
local WAN_ROLLBACK_FILE = os.getenv("KEMOFI_WAN_ROLLBACK_FILE") or
  "/tmp/kemofi-wan-network.backup"
local WAN_APPLY_LOCK_PATH = os.getenv("KEMOFI_WAN_APPLY_LOCK_PATH") or
  "/tmp/kemofi-wan-apply.lock"
local WAN_ROLLBACK_SCRIPT = os.getenv("KEMOFI_WAN_ROLLBACK_SCRIPT") or
  "/usr/lib/kemofi/wan-rollback.sh"
local WAN_ROLLBACK_SECONDS = tonumber(os.getenv("KEMOFI_WAN_ROLLBACK_SECONDS")) or 45
if WAN_ROLLBACK_SECONDS < 30 or WAN_ROLLBACK_SECONDS > 180 then
  WAN_ROLLBACK_SECONDS = 45
end
local WIFI_RELOAD_COMMAND = os.getenv("KEMOFI_WIFI_RELOAD_COMMAND") or
  "/sbin/wifi reload"
local WIFI_RELOAD_DELAY_SECONDS = tonumber(
  os.getenv("KEMOFI_WIFI_RELOAD_DELAY_SECONDS")
) or 2
if WIFI_RELOAD_DELAY_SECONDS < 0 or WIFI_RELOAD_DELAY_SECONDS > 10 then
  WIFI_RELOAD_DELAY_SECONDS = 2
end
local WIFI_RELOAD_SYNC = os.getenv("KEMOFI_WIFI_RELOAD_SYNC") == "1"
local SSH_AUTHORIZED_KEYS_FILE = os.getenv("KEMOFI_SSH_AUTHORIZED_KEYS_FILE") or
  "/etc/dropbear/authorized_keys"
local DROPBEAR_RESTART_COMMAND = os.getenv("KEMOFI_DROPBEAR_RESTART_COMMAND") or
  "/etc/init.d/dropbear restart >/dev/null 2>&1"
local OTA_MANIFEST_URL = os.getenv("KEMOFI_OTA_MANIFEST_URL") or
  "https://kemofi.com/api/releases/openwrt/latest"
local OTA_PROXY_URL = os.getenv("KEMOFI_OTA_PROXY_URL") or
  "https://kemofi.com/api/releases/openwrt/download"
local OTA_MANIFEST_PATH = os.getenv("KEMOFI_OTA_MANIFEST_PATH") or
  "/tmp/ota_manifest.json"
local OTA_CHECK_PATH = os.getenv("KEMOFI_OTA_CHECK_PATH") or
  "/tmp/ota_check.json"
local OTA_FIRMWARE_PATH = os.getenv("KEMOFI_OTA_FIRMWARE_PATH") or
  "/tmp/firmware.bin"
local MANUAL_FIRMWARE_PATH = os.getenv("KEMOFI_MANUAL_FIRMWARE_PATH") or
  "/tmp/kemofi-manual-firmware.bin"
local URL_FIRMWARE_PATH = os.getenv("KEMOFI_URL_FIRMWARE_PATH") or
  "/tmp/kemofi-url-firmware.bin"
local URL_PROVIDER_PAGE_PATH = os.getenv("KEMOFI_URL_PROVIDER_PAGE_PATH") or
  "/tmp/kemofi-url-provider-page.html"
local MANUAL_FIRMWARE_PART_PATH = os.getenv("KEMOFI_MANUAL_FIRMWARE_PART_PATH") or
  "/tmp/kemofi-manual-firmware.bin.part"
local MANUAL_FIRMWARE_STATE_PATH = os.getenv("KEMOFI_MANUAL_FIRMWARE_STATE_PATH") or
  "/tmp/kemofi-manual-firmware.state"
local MANUAL_CONFIG_BACKUP_PATH = os.getenv("KEMOFI_MANUAL_CONFIG_BACKUP_PATH") or
  "/tmp/kemofi-manual-upgrade-backup.tgz"
local URL_UPGRADE_LOCK_PATH = os.getenv("KEMOFI_URL_UPGRADE_LOCK_PATH") or
  "/tmp/kemofi-url-upgrade.lock"
local URL_UPGRADE_LOCK_MAX_AGE = tonumber(os.getenv("KEMOFI_UPGRADE_LOCK_MAX_AGE")) or
  1800
if URL_UPGRADE_LOCK_MAX_AGE < 60 or URL_UPGRADE_LOCK_MAX_AGE > 86400 then
  URL_UPGRADE_LOCK_MAX_AGE = 1800
end
local UCLIENT_BIN = os.getenv("KEMOFI_UCLIENT_BIN") or "/bin/uclient-fetch"
local CURL_BIN = os.getenv("KEMOFI_CURL_BIN") or "/usr/bin/curl"
local SYSUPGRADE_BIN = os.getenv("KEMOFI_SYSUPGRADE_BIN") or "/sbin/sysupgrade"
local SYSUPGRADE_CONF_FILE = os.getenv("KEMOFI_SYSUPGRADE_CONF_FILE") or "/etc/sysupgrade.conf"
local SHA256_BIN = os.getenv("KEMOFI_SHA256_BIN") or "/usr/bin/sha256sum"
local SYNC_COMMAND = os.getenv("KEMOFI_SYNC_COMMAND") or "/bin/sync"
local VERSION_FILE = os.getenv("KEMOFI_VERSION_FILE") or "/etc/kemofi/version"
local BOARD_NAME_FILE = os.getenv("KEMOFI_BOARD_NAME_FILE") or "/tmp/sysinfo/board_name"
local SYSUPGRADE_SYNC = os.getenv("KEMOFI_SYSUPGRADE_SYNC") == "1"
local MAX_MANUAL_FIRMWARE_BYTES = tonumber(
  os.getenv("KEMOFI_MAX_MANUAL_FIRMWARE_BYTES")
) or 16 * 1024 * 1024
local MIN_OTA_TMP_FREE_KB = tonumber(
  os.getenv("KEMOFI_OTA_MIN_TMP_FREE_KB")
) or 12 * 1024
local MANUAL_UPLOAD_CHUNK_BYTES = tonumber(
  os.getenv("KEMOFI_MANUAL_UPLOAD_CHUNK_BYTES")
) or 64 * 1024
if MANUAL_UPLOAD_CHUNK_BYTES < 4096 or MANUAL_UPLOAD_CHUNK_BYTES > 262144 then
  MANUAL_UPLOAD_CHUNK_BYTES = 64 * 1024
end
local MAX_MANUAL_UPLOAD_CHUNK_BYTES = tonumber(
  os.getenv("KEMOFI_MAX_MANUAL_UPLOAD_CHUNK_BYTES")
) or 512 * 1024
if MAX_MANUAL_UPLOAD_CHUNK_BYTES < 64 * 1024
    or MAX_MANUAL_UPLOAD_CHUNK_BYTES > 1024 * 1024 then
  MAX_MANUAL_UPLOAD_CHUNK_BYTES = 512 * 1024
end

-- Only settings required by the operator console may cross the API boundary.
local SETTINGS_FIELDS = {
  "business_name", "portal_name", "portal_footer_text", "portal_footer_link",
  "portal_show_rates", "portal_rates", "coin_min_per_php",
  "coinslot_timeout_seconds", "coinslot_busy_lock",
  "coinslot_max_empty_opens", "coinslot_empty_open_window_seconds",
  "coinslot_empty_open_cooldown_seconds",
  "site_blocking_enabled", "blocked_sites",
  "bw_mode", "bw_per_client_down_kbps", "bw_per_client_up_kbps",
  "bw_total_down_kbps", "bw_total_up_kbps", "bw_exempt_macs",
  "pause_penalty_minutes", "auto_pause_on_disconnect", "auto_resume_on_reconnect",
  "free_time_enabled", "free_time_minutes", "free_time_daily_limit",
  "free_time_schedule_days", "free_time_schedule_start", "free_time_schedule_end",
  "portal_hide_device_info", "portal_show_voucher", "portal_show_coin", "portal_icon_set",
  "portal_logo_filename", "portal_coin_sound_enabled", "portal_tick_sound_enabled"
}
if SQM_AVAILABLE then
  SETTINGS_FIELDS[#SETTINGS_FIELDS + 1] = "sqm_enabled"
  SETTINGS_FIELDS[#SETTINGS_FIELDS + 1] = "sqm_download_kbps"
  SETTINGS_FIELDS[#SETTINGS_FIELDS + 1] = "sqm_upload_kbps"
  SETTINGS_FIELDS[#SETTINGS_FIELDS + 1] = "sqm_linklayer"
  SETTINGS_FIELDS[#SETTINGS_FIELDS + 1] = "sqm_overhead"
  SETTINGS_FIELDS[#SETTINGS_FIELDS + 1] = "sqm_host_fairness"
end
local EDITABLE_SETTINGS = {}
for _, key in ipairs(SETTINGS_FIELDS) do EDITABLE_SETTINGS[key] = true end

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

local function fetch_file(url, path, timeout, max_bytes)
  os.remove(path)
  local limit = tonumber(max_bytes) or MAX_MANUAL_FIRMWARE_BYTES
  if limit < 1 then return false end
  -- Keep only one byte beyond the limit so a remote server cannot fill /tmp.
  local command = table.concat({
    shell_quote(UCLIENT_BIN),
    "--timeout=" .. tostring(timeout),
    "-q -O -", shell_quote(url),
    "2>/dev/null | head -c " .. tostring(limit + 1) .. " >", shell_quote(path),
    "2>/dev/null"
  }, " ")
  if command_ok(command) then return true end
  os.remove(path)
  return false
end

local function private_ipv4(ip)
  local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if not a or a > 255 or b > 255 or c > 255 or d > 255 then return false end
  return a == 0 or a == 10 or a == 127 or (a == 169 and b == 254) or
    (a == 192 and b == 168) or (a == 172 and b >= 16 and b <= 31)
end

local function private_ipv6(ip)
  ip = ip:lower():gsub("%%[a-z0-9_.%-]+$", "")
  if ip == "::" or ip == "::1" or ip:match("^fc") or ip:match("^fd") or
      ip:match("^fe[89ab]") then return true end
  local mapped = ip:match("^::ffff:(%d+%.%d+%.%d+%.%d+)$")
  return mapped and private_ipv4(mapped) or false
end

local function host_resolves_publicly(host)
  if private_ipv4(host) or host:match("^%d+$") then return false end
  local resolver = io.popen("nslookup -timeout=5 -retry=1 " .. shell_quote(host) .. " 2>/dev/null")
  if not resolver then return false end
  local raw = resolver:read("*a") or ""
  resolver:close()
  local resolved_address = nil
  local in_answer = false
  for line in raw:gmatch("[^\r\n]+") do
    if line:match("^%s*Name:") then in_answer = true end
    local address = line:match("^%s*Address[^:]*:%s*(%S+)")
    if in_answer and address then
      if private_ipv4(address) or private_ipv6(address) then return false end
      if resolved_address == nil then resolved_address = address end
    end
  end
  return resolved_address
end

local function valid_remote_firmware_url(url)
  url = trim(tostring(url or ""))
  if #url < 12 or #url > 2048 or not url:match("^https://") then return false end
  local host = url:match("^https://([^/%?#]+)")
  if not host then return false end
  host = host:lower()
  local host_without_port, port = host:match("^([^:]+):(%d+)$")
  if host_without_port then
    if tonumber(port) < 1 or tonumber(port) > 65535 then return false end
    host = host_without_port
  end
  if host == "localhost" or host:match("%.local$") or host:match("^127%.") or host:match("^10%.") or host:match("^192%.168%.") or host:match("^169%.254%.") or host:match("^172%.(1[6-9]|2%d|3[0-1])%.") or host == "0.0.0.0" or host == "::1" or not host:match("^[%w%.%-]+$") then return false end
  local resolved_ip = host_resolves_publicly(host)
  if not resolved_ip or private_ipv4(resolved_ip) or private_ipv6(resolved_ip) then return false end
  return url, host, port or "443", resolved_ip
end

local function acquire_url_upgrade_lock()
  if command_ok("mkdir " .. shell_quote(URL_UPGRADE_LOCK_PATH) .. " 2>/dev/null") then return true end
  local stat = io.popen("stat -c %Y " .. shell_quote(URL_UPGRADE_LOCK_PATH) .. " 2>/dev/null")
  local raw_age = stat and stat:read("*l") or nil
  if stat then stat:close() end
  local lock_age = raw_age and (os.time() - (tonumber(raw_age) or os.time())) or 0
  if lock_age < URL_UPGRADE_LOCK_MAX_AGE then return false end
  -- The lock directory is intentionally empty, so rmdir is safe and cannot
  -- recursively remove an attacker-controlled tree.
  if not command_ok("rmdir " .. shell_quote(URL_UPGRADE_LOCK_PATH) .. " 2>/dev/null") then return false end
  return command_ok("mkdir " .. shell_quote(URL_UPGRADE_LOCK_PATH) .. " 2>/dev/null")
end

local function release_url_upgrade_lock()
  os.execute("rmdir " .. shell_quote(URL_UPGRADE_LOCK_PATH) .. " 2>/dev/null")
end

local function fetch_remote_firmware(url, path, timeout, host, port, resolved_ip, max_bytes)
  os.remove(path)
  local limit = tonumber(max_bytes) or MAX_MANUAL_FIRMWARE_BYTES
  local pinned = tostring(host) .. ":" .. tostring(port) .. ":" .. tostring(resolved_ip)
  -- curl does not follow redirects unless --location is supplied. --resolve
  -- also prevents a DNS rebinding after the preflight address check.
  local command = table.concat({
    shell_quote(CURL_BIN), "--fail --silent --show-error",
    "--connect-timeout 15 --max-time " .. tostring(timeout),
    "--noproxy '*' --max-filesize " .. tostring(limit + 1),
    "--proto", shell_quote("=https"), "--resolve", shell_quote(pinned),
    "--output -", shell_quote(url),
    "2>/dev/null | head -c " .. tostring(limit + 1) .. " >", shell_quote(path),
    "2>/dev/null"
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

local function remote_url_host(url)
  return (tostring(url or ""):match("^https://([^/%?#]+)") or ""):lower()
end

local function remote_url_query_value(url, wanted_key)
  local query = tostring(url or ""):match("%?([^#]*)") or ""
  for pair in query:gmatch("[^&]+") do
    local key, value = pair:match("^([^=]+)=?(.*)$")
    if key == wanted_key then return value end
  end
  return nil
end

-- Google Drive share pages are HTML, not firmware files. Convert only the
-- supported file-id form to Google's download endpoint; never follow an
-- arbitrary redirect supplied by the user.
local function google_drive_download_url(url)
  local host = remote_url_host(url)
  if host ~= "drive.google.com" and host ~= "drive.usercontent.google.com" then
    return nil
  end
  local path = tostring(url or ""):match("^https://[^/%?#]+([^?#]*)") or ""
  if path:match("^/drive/folders/") then return nil, "folder" end
  local file_id = path:match("^/file/d/([%w_-]+)") or
    remote_url_query_value(url, "id")
  if not file_id or #file_id < 10 or #file_id > 200 or
      not file_id:match("^[%w_-]+$") then
    return nil, "invalid"
  end
  local download_url = "https://drive.usercontent.google.com/download?id=" ..
    file_id .. "&export=download&confirm=t"
  local resource_key = remote_url_query_value(url, "resourcekey")
  if resource_key and resource_key:match("^[%w_-]+$") then
    download_url = download_url .. "&resourcekey=" .. resource_key
  end
  return download_url, "file"
end

local function firmware_url_has_bin(url)
  local lower = tostring(url or ""):lower()
  return lower:match("%.bin$") ~= nil or lower:match("%.bin[%?#]") ~= nil
end

local function is_mediafire_page(url)
  local host = remote_url_host(url)
  return host == "mediafire.com" or host == "www.mediafire.com"
end

-- MediaFire's /file/.../file URL is a web page. Resolve its provider-owned
-- direct URL, then validate and pin that host before downloading the image.
local function resolve_mediafire_download(url, page_host, page_port, page_ip)
  if not fetch_remote_firmware(url, URL_PROVIDER_PAGE_PATH, 30, page_host,
      page_port, page_ip, 1024 * 1024) then
    os.remove(URL_PROVIDER_PAGE_PATH)
    return nil
  end
  local page = read_file(URL_PROVIDER_PAGE_PATH) or ""
  os.remove(URL_PROVIDER_PAGE_PATH)
  for candidate in page:gmatch("https://download[%w%-]+%.mediafire%.com/[^%s<>]+") do
    candidate = candidate:gsub("\\/", "/"):gsub("&amp;", "&")
    candidate = candidate:gsub("[\"']", ""):gsub("[,;]+$", "")
    local host = remote_url_host(candidate)
    if host:match("^download%d+%.mediafire%.com$") and
        firmware_url_has_bin(candidate) then
      local direct, direct_host, direct_port, direct_ip =
        valid_remote_firmware_url(candidate)
      if direct then return direct, direct_host, direct_port, direct_ip end
    end
  end
  return nil
end

local function normalize_remote_firmware_url(raw_url)
  raw_url = trim(tostring(raw_url or ""))
  local host = remote_url_host(raw_url)
  if host == "drive.google.com" or host == "drive.usercontent.google.com" then
    local google_url, reason = google_drive_download_url(raw_url)
    if google_url then return google_url, "google_drive" end
    return nil, reason or "invalid"
  end
  if is_mediafire_page(raw_url) then return raw_url, "mediafire_page" end
  return raw_url, "direct"
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
  local name = tostring(headers["x-kemofi-firmware-name"] or (params or {}).filename or "")
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

local function cleanup_staged_firmware(path)
  os.remove(path)
  if path == MANUAL_FIRMWARE_PATH then
    os.remove(MANUAL_FIRMWARE_PART_PATH)
    os.remove(MANUAL_FIRMWARE_STATE_PATH)
  end
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

local CUSTOMER_STATE_PATHS = {
  "/etc/kemofi/sessions.db",
  "/etc/kemofi/sessions.db.bak",
  "/etc/kemofi/fastlane/"
}

-- Older installed images may not yet have the new customer-state entries in
-- /etc/sysupgrade.conf. Add them before invoking sysupgrade so a preserve
-- upgrade is safe even when upgrading directly from one of those images.
local function ensure_customer_state_preserved()
  local file = io.open(SYSUPGRADE_CONF_FILE, "r")
  if not file then return false, "cannot read sysupgrade preservation list" end
  local raw = file:read("*a") or ""
  file:close()

  local missing = {}
  for _, path in ipairs(CUSTOMER_STATE_PATHS) do
    local found = false
    for line in raw:gmatch("[^\r\n]+") do
      if trim(line) == path then
        found = true
        break
      end
    end
    if not found then missing[#missing + 1] = path end
  end
  if #missing == 0 then return true end

  local append, append_err = io.open(SYSUPGRADE_CONF_FILE, "a")
  if not append then
    return false, "cannot update sysupgrade preservation list: " .. tostring(append_err)
  end
  if raw ~= "" and raw:sub(-1) ~= "\n" then append:write("\n") end
  local wrote, write_err = append:write(table.concat(missing, "\n") .. "\n")
  append:close()
  if not wrote then
    return false, "cannot update sysupgrade preservation list: " .. tostring(write_err)
  end
  if not command_ok(SYNC_COMMAND) then
    return false, "sysupgrade preservation list could not be synced"
  end
  return true
end

local function validate_manual_update_mode(params)
  -- Preserve is the safe default for old clients that do not send mode.
  local mode = trim(tostring(form_part_value((params or {}).mode, "preserve") or "preserve"))
  if mode == "" then mode = "preserve" end
  if mode ~= "fresh" and mode ~= "preserve" and mode ~= "check" then return nil end
  return mode
end

local function apply_manual_firmware(size, mode, firmware_path, lock_held)
  firmware_path = firmware_path or MANUAL_FIRMWARE_PATH
  local owns_lock = false
  if not lock_held then
    if not acquire_url_upgrade_lock() then
      cleanup_staged_firmware(firmware_path)
      return 409, json.encode({error = "upgrade_in_progress", message = "Another firmware upgrade is already in progress."})
    end
    owns_lock = true
  end
  local function fail(status, body)
    cleanup_staged_firmware(firmware_path)
    if owns_lock then release_url_upgrade_lock() end
    return status, body
  end

  local staged_size = file_size(firmware_path) or 0
  if staged_size ~= size then
    return fail(500, json.encode({error = "write_failed", message = "Firmware staging did not complete."}))
  end

  local actual_sha256 = sha256_file(firmware_path)
  if not actual_sha256 or #actual_sha256 ~= 64 then
    return fail(500, json.encode({error = "checksum_failed", message = "Firmware checksum could not be calculated."}))
  end

  local test_command = shell_quote(SYSUPGRADE_BIN) .. " -T " .. shell_quote(firmware_path) ..
    " >/dev/null 2>&1"
  if not command_ok(test_command) then
    return fail(500, json.encode({error = "invalid_firmware", message = "Firmware is not compatible with this router."}))
  end

  -- Check mode deliberately stops after sysupgrade -T. It exercises the same
  -- staging, checksum, and board-compatibility path as an install without
  -- writing flash, changing settings, or rebooting the router.
  if mode == "check" then
    cleanup_staged_firmware(firmware_path)
    release_url_upgrade_lock()
    return 200, json.encode({
      status = "ok",
      mode = mode,
      size = size,
      sha256 = actual_sha256,
      message = "Firmware downloaded, SHA-256 calculated, and validated. No flash was performed."
    })
  end

  if mode == "preserve" then
    local state_ready, state_err = ensure_customer_state_preserved()
    if not state_ready then
      return fail(500, json.encode({
        error = "preserve_check_failed",
        message = "Customer data could not be prepared safely.",
        detail = tostring(state_err or "preservation list update failed")
      }))
    end
    os.remove(MANUAL_CONFIG_BACKUP_PATH)
    if not command_ok(shell_quote(SYSUPGRADE_BIN) .. " -b " .. shell_quote(MANUAL_CONFIG_BACKUP_PATH) ..
        " >/dev/null 2>&1") then
      return fail(500, json.encode({error = "preserve_check_failed", message = "Settings could not be prepared safely."}))
    end
    local backup_size = file_size(MANUAL_CONFIG_BACKUP_PATH) or 0
    local overlay_free_kb = fs_available_kb("/overlay")
    os.remove(MANUAL_CONFIG_BACKUP_PATH)
    if overlay_free_kb > 0 and math.ceil(backup_size / 1024) + 32 > overlay_free_kb then
      return fail(409, json.encode({
        error = "preserve_too_large",
        message = "Settings are too large to preserve safely. Use Fresh Install."
      }))
    end

    local persisted, persist_detail = db.persist("manual-firmware-upgrade", true)
    if not persisted or not command_ok(SYNC_COMMAND) then
      return fail(500, json.encode({
        error = "settings_save_failed",
        message = "Firmware is valid but current settings could not be saved.",
        detail = tostring(persist_detail or "sync failed")
      }))
    end
  end

  local apply_command = shell_quote(SYSUPGRADE_BIN) .. " "
  if mode == "fresh" then apply_command = apply_command .. "-n " end
  apply_command = apply_command .. shell_quote(firmware_path)
  if not SYSUPGRADE_SYNC then apply_command = apply_command .. " >/dev/null 2>&1 &" end
  if not command_ok(apply_command) then
    return fail(500, json.encode({error = "upgrade_start_failed", message = "Firmware is valid but upgrade could not start."}))
  end

  if firmware_path == MANUAL_FIRMWARE_PATH then os.remove(MANUAL_FIRMWARE_STATE_PATH) end
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

local function normalize_gaming_rules(value)
  local input = value
  if type(value) == "string" then
    local decoded = json.decode(value)
    if type(decoded) ~= "table" then
      return nil, "Gaming rules must be a valid JSON array."
    end
    input = decoded
  end
  if type(input) ~= "table" then
    return nil, "Gaming rules must be an array."
  end

  local count = 0
  for key in pairs(input) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
      return nil, "Gaming rules must be an array."
    end
    count = count + 1
  end
  if count > 64 then return nil, "A maximum of 64 gaming rules is allowed." end

  local rules, seen = {}, {}
  for index = 1, count do
    local raw = input[index]
    if type(raw) ~= "table" then
      return nil, "Each gaming rule must be an object."
    end
    if type(raw.name) ~= "string" then
      return nil, "Enter a game or application name."
    end
    local name = trim(raw.name)
    if name == "" or #name > 64 or name:find("[%c]") then
      return nil, "Game names must be 1 to 64 characters on one line."
    end

    local protocol = tostring(raw.protocol or ""):upper()
    if protocol ~= "TCP" and protocol ~= "UDP" and protocol ~= "TCP/UDP" then
      return nil, "Choose TCP, UDP, or TCP/UDP."
    end

    local start_port = tonumber(raw.startPort or raw.start_port)
    local end_port = tonumber(raw.endPort or raw.end_port)
    if not start_port or start_port ~= math.floor(start_port) or
        start_port < 1 or start_port > 65535 then
      return nil, "Enter a start port from 1 to 65535."
    end
    if not end_port or end_port ~= math.floor(end_port) or
        end_port < 1 or end_port > 65535 then
      return nil, "Enter an end port from 1 to 65535."
    end
    if end_port < start_port then
      return nil, "The end port cannot be lower than the start port."
    end

    local priority = tostring(raw.priority or "")
    if priority ~= "High" and priority ~= "Medium" and priority ~= "Low" then
      return nil, "Choose High, Medium, or Low priority."
    end

    local signature = protocol .. ":" .. start_port .. ":" .. end_port
    if seen[signature] then
      return nil, "Duplicate port ranges are not allowed."
    end
    seen[signature] = true
    rules[#rules + 1] = {
      name = name,
      protocol = protocol,
      startPort = start_port,
      endPort = end_port,
      priority = priority
    }
  end
  return rules
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

local function detect_network()
  local forced_iface = trim(os.getenv("KEMOFI_WAN_IFACE") or "")
  local forced_gateway = trim(os.getenv("KEMOFI_UPSTREAM_GATEWAY") or "")
  if forced_iface ~= "" then return forced_iface, forced_gateway end

  local configured = io.popen(shell_quote(UCI_BIN) ..
    " -q get network.wan.device 2>/dev/null")
  if configured then
    local interface = trim(configured:read("*l") or "")
    configured:close()
    if interface ~= "" and interface:match("^[%w_.:%-]+$") then
      if forced_gateway ~= "" then return interface, forced_gateway end
      local route = io.popen("ip -4 route show default 2>/dev/null")
      if route then
        local line = route:read("*l") or ""
        route:close()
        return interface, line:match("%svia%s+(%d+%.%d+%.%d+%.%d+)")
      end
      return interface, nil
    end
  end

  local route = io.popen("ip -4 route show default 2>/dev/null")
  if not route then return nil, nil end
  local line = route:read("*l") or ""
  route:close()
  return line:match("%sdev%s+(%S+)"), line:match("%svia%s+(%d+%.%d+%.%d+%.%d+)")
end

local function valid_interface(value)
  local interface = trim(value)
  if interface ~= "" and interface:match("^[%w_.:%-]+$") then return interface end
  return nil
end

-- Return the customer-facing interfaces used for MAC exemptions. The OPI
-- profile supplies all routed/VLAN domains through lib.network; older router
-- profiles intentionally fall back to their single br-lan interface.
local function customer_interface_elements()
  local candidates = {}
  local loaded, topology = pcall(require, "lib.network")
  if loaded and topology and type(topology.interfaces) == "function" then
    candidates = topology.interfaces()
  else
    candidates = {os.getenv("KEMOFI_LAN_IFACE") or "br-lan"}
  end
  local elements, seen = {}, {}
  for _, candidate in ipairs(candidates or {}) do
    local interface = valid_interface(candidate)
    if interface and not seen[interface] then
      seen[interface] = true
      elements[#elements + 1] = '"' .. interface .. '"'
    end
  end
  if #elements == 0 then return nil, "The customer network could not be detected." end
  return table.concat(elements, ", ")
end

local function uci_get(key)
  local handle = io.popen(shell_quote(UCI_BIN) .. " -q get " .. shell_quote(key) ..
    " 2>/dev/null")
  if not handle then return "" end
  local value = trim(handle:read("*a") or "")
  handle:close()
  return value
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
    local band = device ~= "" and uci_get("wireless." .. device .. ".band") or ""
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

-- WAN configuration is deliberately isolated from SQM and customer traffic
-- policy. This page writes only network.wan and uses a scoped WAN ifup/ifdown.
local WAN_DYNAMIC_OPTIONS = {
  "ipaddr", "netmask", "gateway", "dns", "username", "password",
  "hostname", "peerdns"
}

local function file_exists(path)
  local file = io.open(path, "rb")
  if not file then return false end
  file:close()
  return true
end

local function wan_ipv4_on(interface)
  interface = valid_interface(interface)
  if not interface then return "" end
  local handle = io.popen("ip -4 addr show dev " .. shell_quote(interface) ..
    " 2>/dev/null | awk '/inet / {print $2; exit}' | cut -d/ -f1")
  if not handle then return "" end
  local address = trim(handle:read("*a") or "")
  handle:close()
  return ipv4_parts(address) and address or ""
end

local function wan_runtime_interface()
  return valid_interface(uci_get("network.wan.device")) or
    valid_interface(uci_get("network.wan.ifname")) or
    valid_interface((detect_network()))
end

local function wan_default_gateway(interface)
  local handle = io.popen("ip -4 route show default 2>/dev/null")
  if not handle then return "" end
  local gateway = ""
  for line in handle:lines() do
    local matches_interface = not interface or line:find(" dev " .. interface, 1, true)
    if matches_interface then
      gateway = line:match("%svia%s+([%d%.]+)") or ""
      if gateway ~= "" or interface then break end
    end
  end
  handle:close()
  return ipv4_parts(gateway) and gateway or ""
end

local function wan_runtime_status()
  local interface = wan_runtime_interface()
  local address = wan_ipv4_on(interface)
  local gateway = wan_default_gateway(interface)
  local online = address ~= "" and command_ok("ip -4 route show default 2>/dev/null | grep -q .")
  return {
    online = online,
    interface = interface or "",
    ip = address,
    gateway = gateway
  }
end

local function wan_dns_value()
  local raw = uci_get("network.wan.dns")
  local values, seen = {}, {}
  for value in raw:gmatch("%S+") do
    if not seen[value] then
      seen[value] = true
      values[#values + 1] = value
    end
  end
  return table.concat(values, " ")
end

local function wan_ipv4_number(parts)
  return ((parts[1] * 256 + parts[2]) * 256 + parts[3]) * 256 + parts[4]
end

local function wan_prefix_netmask(prefix)
  local number = prefix == 0 and 0 or (2 ^ 32 - 2 ^ (32 - prefix))
  local d = number % 256
  number = math.floor(number / 256)
  local c = number % 256
  number = math.floor(number / 256)
  local b = number % 256
  local a = math.floor(number / 256) % 256
  return table.concat({a, b, c, d}, ".")
end

local function normalize_wan_netmask(value)
  local token = trim(value)
  local prefix_text = token:match("^/?(%d+)$")
  if prefix_text then
    local prefix = tonumber(prefix_text)
    if prefix and prefix >= 1 and prefix <= 32 then
      return prefix, wan_prefix_netmask(prefix)
    end
  end
  local parts = ipv4_parts(token)
  if not parts then return nil, "Enter a valid IPv4 netmask or prefix." end
  local number = wan_ipv4_number(parts)
  for prefix = 1, 32 do
    if number == (2 ^ 32 - 2 ^ (32 - prefix)) then
      return prefix, wan_prefix_netmask(prefix)
    end
  end
  return nil, "Enter a contiguous IPv4 netmask such as 255.255.255.0."
end

local function normalize_wan_dns(value)
  if value == nil then return "" end
  if type(value) ~= "string" then return nil, "DNS servers must be IPv4 addresses." end
  local input = trim(value):gsub(",", " ")
  if #input > 256 then return nil, "The DNS server list is too long." end
  local values, seen = {}, {}
  for address in input:gmatch("%S+") do
    if not ipv4_parts(address) then
      return nil, "Enter valid IPv4 DNS servers separated by spaces or commas."
    end
    if not seen[address] then
      seen[address] = true
      values[#values + 1] = address
      if #values > 4 then return nil, "Use no more than four DNS servers." end
    end
  end
  return table.concat(values, " ")
end

local function normalize_wan_hostname(value)
  if value == nil then return "" end
  if type(value) ~= "string" then return nil, "The DHCP hostname is invalid." end
  local hostname = trim(value)
  if hostname == "" then return "" end
  if #hostname > 63 or not hostname:match("^[%w][%w%._%-]*$") or
      hostname:match("[%.%-]$") or hostname:find("%.%.", 1, true) then
    return nil, "Enter a valid DHCP hostname up to 63 characters."
  end
  return hostname
end

local function normalize_wan_request(params)
  params = params or {}
  local proto = trim(params.proto):lower()
  if proto ~= "dhcp" and proto ~= "static" then
    return nil, "Choose DHCP or Static IPv4.", "proto"
  end

  local device = valid_interface(uci_get("network.wan.device"))
  local device_option = device and "device" or nil
  if not device then
    device = valid_interface(uci_get("network.wan.ifname"))
    device_option = device and "ifname" or nil
  end
  if not device then
    device = valid_interface((detect_network()))
    device_option = device and "device" or nil
  end
  if not device then
    return nil, "The configured WAN device could not be detected.", "device"
  end

  local config = {proto = proto, device = device, device_option = device_option}
  if proto == "dhcp" then
    local hostname, hostname_err = normalize_wan_hostname(params.hostname)
    if not hostname then return nil, hostname_err, "hostname" end
    config.hostname = hostname
    return config
  end

  if proto == "static" then
    local address = trim(params.ipaddr)
    local address_parts = ipv4_parts(address)
    if not address_parts then return nil, "Enter a valid static IPv4 address.", "ipaddr" end
    local prefix, netmask_or_err = normalize_wan_netmask(params.netmask)
    if not prefix then return nil, netmask_or_err, "netmask" end
    local gateway = trim(params.gateway)
    local gateway_parts = ipv4_parts(gateway)
    if not gateway_parts then return nil, "Enter a valid IPv4 gateway.", "gateway" end
    if prefix < 32 and math.floor(wan_ipv4_number(address_parts) / (2 ^ (32 - prefix))) ~=
        math.floor(wan_ipv4_number(gateway_parts) / (2 ^ (32 - prefix))) then
      return nil, "The static gateway must be in the same subnet as the address.", "gateway"
    end
    local dns, dns_err = normalize_wan_dns(params.dns)
    if not dns then return nil, dns_err, "dns" end
    config.ipaddr = address
    config.netmask = netmask_or_err
    config.gateway = gateway
    config.dns = dns ~= "" and dns or "1.1.1.1 8.8.8.8"
    return config
  end
end

local function wan_uci_delete(option)
  return shell_quote(UCI_BIN) .. " -q delete " .. shell_quote("network.wan." .. option) ..
    " >/dev/null 2>&1 || true"
end

local function wan_uci_set(option, value)
  return shell_quote(UCI_BIN) .. " -q set " ..
    shell_quote("network.wan." .. option .. "=" .. tostring(value or ""))
end

local function apply_wan_uci(config)
  local commands = {
    shell_quote(UCI_BIN) .. " -q get network.wan >/dev/null 2>&1 || " ..
      shell_quote(UCI_BIN) .. " -q set network.wan=interface"
  }
  for _, option in ipairs(WAN_DYNAMIC_OPTIONS) do
    commands[#commands + 1] = wan_uci_delete(option)
  end
  commands[#commands + 1] = wan_uci_set("proto", config.proto)
  commands[#commands + 1] = wan_uci_set(config.device_option, config.device)
  if config.proto == "dhcp" then
    commands[#commands + 1] = wan_uci_set("peerdns", "1")
    if config.hostname ~= "" then commands[#commands + 1] = wan_uci_set("hostname", config.hostname) end
  elseif config.proto == "static" then
    commands[#commands + 1] = wan_uci_set("ipaddr", config.ipaddr)
    commands[#commands + 1] = wan_uci_set("netmask", config.netmask)
    commands[#commands + 1] = wan_uci_set("gateway", config.gateway)
    commands[#commands + 1] = wan_uci_set("peerdns", "0")
    for dns in config.dns:gmatch("%S+") do
      commands[#commands + 1] = shell_quote(UCI_BIN) .. " -q add_list " ..
        shell_quote("network.wan.dns=" .. dns)
    end
  end
  commands[#commands + 1] = shell_quote(UCI_BIN) .. " -q commit network"
  return command_ok(table.concat(commands, " && "))
end

local function reload_wan_only()
  return command_ok("/sbin/ifdown wan >/dev/null 2>&1; /sbin/ifup wan >/dev/null 2>&1")
end

local function remove_wan_lock()
  os.execute("rmdir " .. shell_quote(WAN_APPLY_LOCK_PATH) .. " >/dev/null 2>&1 || true")
end

local function cleanup_wan_files(remove_backup)
  os.remove(WAN_PENDING_FILE)
  if remove_backup then os.remove(WAN_ROLLBACK_FILE) end
  remove_wan_lock()
end

local function restore_wan_backup()
  if not file_exists(WAN_ROLLBACK_FILE) then return false end
  local restored = command_ok("cp -f " .. shell_quote(WAN_ROLLBACK_FILE) .. " " ..
    shell_quote(NETWORK_CONFIG_FILE))
  if not restored then return false end
  command_ok(shell_quote(UCI_BIN) .. " -q revert network >/dev/null 2>&1")
  return reload_wan_only()
end

local function wan_pending_state()
  local file = io.open(WAN_PENDING_FILE, "r")
  if not file then return nil end
  local deadline = tonumber(trim(file:read("*l") or "")) or 0
  file:close()
  return {deadline = deadline}
end

local function nft_delete_table(table_name)
  local exists = command_ok(shell_quote(NFT_BIN) .. " list table inet " ..
    table_name .. " >/dev/null 2>&1")
  if not exists then return true end
  -- Flushing removes every marking rule immediately without waiting for a
  -- second nft transaction to destroy the table.  An empty table is harmless;
  -- the next non-empty apply replaces it in one atomic nft batch.
  return command_ok(shell_quote(NFT_BIN) .. " flush table inet " .. table_name ..
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
  local table_exists = command_ok(shell_quote(NFT_BIN) .. " list table inet " ..
    table_name .. " >/dev/null 2>&1")
  local apply_path = path .. ".apply"
  local apply_rules = live_rules
  if table_exists then
    apply_rules = "destroy table inet " .. table_name .. "\n" .. live_rules
  end
  os.remove(apply_path)
  wrote, write_err = write_file(apply_path, apply_rules)
  if not wrote then return false, tostring(write_err) end
  if not command_ok(shell_quote(NFT_BIN) .. " -f " .. shell_quote(apply_path) ..
      " >/dev/null 2>&1") then
    os.remove(apply_path)
    return false, "The network rules could not be activated."
  end
  os.remove(apply_path)
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

-- Applying nftables is the latency-sensitive part of Gaming Priority.  The
-- database is already updated in RAM before this is called; defer the durable
-- flash snapshot so the admin request can return without waiting on SQLite,
-- fsync, and flash I/O.  The normal persistence timer remains a fallback.
local function schedule_gaming_persist()
  local command =
    "(sleep 1; /usr/bin/lua -e 'package.path=\"/opt/kemofi/lua/?.lua;/opt/kemofi/lua/?/init.lua;\" .. package.path; local db=require(\"lib.db\"); db.init(); db.persist(\"gaming-priority\", true)') </dev/null >/dev/null 2>&1 &"
  os.execute(command)
end

--- Verify admin authentication
local function check_auth(env)
  env = env or {}
  local headers = env.headers or {}
  local client_ip = tostring(env.client_ip or "")
  -- The VPS reverse-SSH proxy reaches the admin service through loopback.
  -- Requiring both signals prevents a LAN client from spoofing this header.
  if (headers["x-remote-access"] or "") == "true" and
      (client_ip == "127.0.0.1" or client_ip == "::1") then
    return true
  end
  local cookie = headers["cookie"] or ""
  local token = cookie:match("kemofi_admin=([^;]+)")
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
  local token = require("lib.util").sha256(password .. "kemofi_salt" .. tostring(os.time()))
  db.set_runtime_setting("_admin_token", token)
  return 200, json.encode({status = "ok"}), {
    ["Set-Cookie"] = "kemofi_admin=" .. token .. "; Path=/; HttpOnly; SameSite=Lax"
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
  return 200, json.encode({status = "ok", message = "Password reset successfully."}), {
    ["Set-Cookie"] = "kemofi_admin=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
  }
end

--- POST /api/admin/logout
function M.logout(env, params)
  db.set_runtime_setting("_admin_token", "")
  return 200, json.encode({status = "ok"}), {
    ["Set-Cookie"] = "kemofi_admin=; Path=/; HttpOnly; Max-Age=0"
  }
end

--- GET /api/admin/dashboard
function M.dashboard(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local now = os.time()
  local today_start = now - ((now + 8*3600) % 86400)
  local earnings_settings = db.settings({
    "earnings_reset_transaction_id", "earnings_reset_at"
  })
  local earnings_reset_id = math.max(
    0, tonumber(earnings_settings.earnings_reset_transaction_id) or 0
  )

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
  local today_transactions = db.scalar(
    "SELECT COUNT(*) FROM transactions WHERE id > ? AND created_at >= ?",
    earnings_reset_id, today_start
  ) or 0
  local total_devices = db.scalar("SELECT COUNT(*) FROM known_devices") or 0

  -- Coin nodes
  local nodes = db.query([[
    SELECT node_id, name, last_heartbeat, ip_address, total_coins, area_id,
           fw_version, coin_dpin, relay_dpin, coin_gpio, relay_gpio,
           1 AS amount_php_per_pulse, rssi,
           conn_mode, protocol_version, auth_enrolled_at
    FROM coin_nodes ORDER BY last_heartbeat DESC
  ]])
  for _, node in ipairs(nodes) do
    node.online = (now - (node.last_heartbeat or 0)) < 90
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
  h = io.popen("df /overlay 2>/dev/null | tail -1")
  if h then
    local line = h:read("*a") or ""
    h:close()
    local t, u, a = line:match("%S+%s+(%d+)%s+(%d+)%s+(%d+)")
    disk_total = math.floor((tonumber(t) or 0) / 1024)
    disk_used = math.floor((tonumber(u) or 0) / 1024)
    disk_avail = math.floor((tonumber(a) or 0) / 1024)
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
  local saved, save_err = db.set_settings_atomic({
    {key = "earnings_reset_transaction_id", value = tostring(reset_id)},
    {key = "earnings_reset_at", value = tostring(reset_at)}
  })
  if not saved then
    return 500, json.encode({
      error = "database_write_failed",
      message = tostring(save_err or "The earnings reset could not be saved.")
    })
  end

  local err = persist_error("earnings-reset")
  if err then return 500, err end
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
  local members = db.query("SELECT * FROM known_devices WHERE member = 1 ORDER BY member_since DESC, name ASC")
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
      member = paid.member or 0,
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
        member = device.member or 0,
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
    devices = devices,
    members = members
  })
end

--- POST /api/admin/sessions/promote-member
function M.promote_member(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local mac = valid_mac(params.mac)
  if not mac then return 400, json.encode({error = "invalid_mac"}) end
  local ok, promote_err = session.promote_member(mac)
  if not ok then return 409, json.encode({error = promote_err}) end
  local err = persist_error("member-promote")
  if err then return 500, err end
  return 200, json.encode({status = "ok", mac = mac, member = true})
end

--- POST /api/admin/sessions/remove-member
function M.remove_member(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local mac = valid_mac(params.mac)
  if not mac then return 400, json.encode({error = "invalid_mac"}) end
  local ok, remove_err = session.remove_member(mac)
  if not ok then return 409, json.encode({error = remove_err}) end
  local err = persist_error("member-remove")
  if err then return 500, err end
  return 200, json.encode({status = "ok", mac = mac, member = false})
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
  local known = db.row("SELECT member FROM known_devices WHERE mac = ?", mac)
  if known and tonumber(known.member) == 1 then
    return 409, json.encode({
      error = "member_device",
      message = "Remove membership before forgetting this device."
    })
  end
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
    if key == "portal_rates" then
      value = rate_config.normalize(value) or ""
    elseif key == "coin_min_per_php" then
      value = rate_config.normalize_flat_rate(value) or ""
    end
    if value ~= nil then settings[key] = value end
  end
  settings.sqm_available = SQM_AVAILABLE
  settings.capabilities = DEVICE_CAPABILITIES
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

local function is_sqm_setting(key)
  return key == "sqm_enabled" or key == "sqm_download_kbps" or
    key == "sqm_upload_kbps" or key == "sqm_linklayer" or
    key == "sqm_overhead" or key == "sqm_host_fairness"
end

local function normalize_operator_setting(key, value)
  if key == "portal_rates" then
    local normalized = rate_config.normalize(value)
    if normalized == nil then
      return nil, "Set positive PHP amounts and whole-minute times. Do not reuse the same PHP amount in multiple tiers."
    end
    return normalized
  end
  if key == "coin_min_per_php" then
    local normalized = rate_config.normalize_flat_rate(value)
    if normalized == nil then
      return nil, "Minutes per peso must be a whole number, or blank to use rate tiers."
    end
    return normalized
  end
  if key == "business_name" then
    return normalize_brand_text(value, 64, true)
  end
  if key == "portal_name" then
    return normalize_brand_text(value, 80, false)
  end
  if key == "portal_footer_text" then
    return normalize_brand_text(value, 120, false)
  end
  if key == "portal_footer_link" then
    local link = trim(value)
    if link == "" then return "https://kemofi.com/" end
    if #link > 240 then return nil, "Keep the footer redirect URL within 240 characters." end
    if link:find("[%c%s]") or not link:lower():match("^https?://[^%s]+$") then
      return nil, "Footer redirect URL must begin with http:// or https:// and contain no spaces."
    end
    return link
  end
  if key == "portal_icon_set" then
    local icon_set = trim(value)
    if icon_set ~= "classic" and icon_set ~= "outline" and icon_set ~= "solid" and icon_set ~= "minimal" and icon_set ~= "rounded" and icon_set ~= "duotone" and icon_set ~= "neon" and icon_set ~= "pixel" then
      return nil, "Choose a supported portal icon set."
    end
    return icon_set
  end
  if key == "auto_pause_on_disconnect" or key == "auto_resume_on_reconnect" then
    local normalized = normalize_boolean(value)
    if not normalized then return nil, "Choose Enabled or Disabled." end
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
  if key == "sqm_enabled" or key == "sqm_host_fairness" then
    local normalized = normalize_boolean(value)
    if not normalized then return nil, "Choose Enabled or Disabled." end
    return normalized
  end
  if key == "sqm_download_kbps" or key == "sqm_upload_kbps" then
    local normalized = normalize_nonnegative_integer(value, 10000000)
    if not normalized then return nil, "Enter an SQM bandwidth value from 0 to 10000000 kbps." end
    return normalized
  end
  if key == "sqm_linklayer" then
    local layer = tostring(value or "")
    if layer ~= "none" and layer ~= "ethernet" and layer ~= "atm" then
      return nil, "Choose a valid SQM link layer."
    end
    return layer
  end
  if key == "sqm_overhead" then
    local normalized = normalize_nonnegative_integer(value, 256)
    if not normalized then return nil, "Enter an SQM overhead from 0 to 256 bytes." end
    return normalized
  end
  if key == "site_blocking_enabled" or key == "upstream_ip_blocking_enabled" or
      key == "anti_tethering_enabled" then
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
  return math.max(1, math.min(1024, math.ceil(rate / 10)))
end

local function gaming_priority_rules(table_name, overrides)
  local enabled = normalize_boolean(
    setting_from(overrides, "gaming_priority_enabled") or "1"
  )
  if not enabled then return nil, "The saved Gaming Priority state is invalid." end

  local rules, rules_err = normalize_gaming_rules(
    setting_from(overrides, "gaming_priority_rules") or "[]"
  )
  if not rules then return nil, rules_err end
  if enabled == "0" or #rules == 0 then return "", enabled, rules end

  local lan = valid_interface(os.getenv("KEMOFI_LAN_IFACE") or "br-lan")
  if not lan then return nil, "The customer network could not be detected." end

  local dscp_by_priority = {High = "cs5", Medium = "af41", Low = "cs1"}
  local mark_by_priority = {High = "0x400", Medium = "0x200", Low = "0x100"}
  local lines = {
    "table inet " .. table_name .. " {",
    "  chain mark_gaming {",
    "    type filter hook forward priority mangle; policy accept;"
  }

  for _, rule in ipairs(rules) do
    local port = rule.startPort == rule.endPort and
      tostring(rule.startPort) or (rule.startPort .. "-" .. rule.endPort)
    local dscp = dscp_by_priority[rule.priority]
    local mark = mark_by_priority[rule.priority]
    local protocols = rule.protocol == "TCP/UDP" and {"tcp", "udp"} or
      {rule.protocol:lower()}
    for _, protocol in ipairs(protocols) do
      lines[#lines + 1] = "    iifname \"" .. lan .. "\" " .. protocol ..
        " dport " .. port .. " ct mark set " .. mark
      lines[#lines + 1] = "    oifname \"" .. lan .. "\" " .. protocol ..
        " sport " .. port .. " ct mark set " .. mark
    end
    lines[#lines + 1] = "    ct mark " .. mark .. " ip dscp set " .. dscp
    lines[#lines + 1] = "    ct mark " .. mark .. " ip6 dscp set " .. dscp
  end
  lines[#lines + 1] = "  }"
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n") .. "\n", enabled, rules
end

--- Apply validated DSCP marks for Gaming Priority flows.
--- SQM-capable images use CAKE/SQM to consume these marks; no bandwidth limit
--- is changed here.
function M.apply_gaming_priority(overrides)
  if not SQM_AVAILABLE then
    nft_delete_table("kemofi_gaming")
    os.remove(GAMING_RULES_FILE)
    return true
  end
  local live_rules, enabled_or_err = gaming_priority_rules("kemofi_gaming", overrides)
  if not live_rules then return false, enabled_or_err end
  if live_rules == "" then
    nft_delete_table("kemofi_gaming")
    os.remove(GAMING_RULES_FILE)
    return true
  end
  local check_rules, check_err = gaming_priority_rules("kemofi_gaming_check", overrides)
  if not check_rules then return false, check_err end
  return nft_apply_checked(
    GAMING_RULES_FILE, check_rules, live_rules, "kemofi_gaming"
  )
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
  local customer_ifaces, customer_ifaces_err
  if #exempt > 0 then
    customer_ifaces, customer_ifaces_err = customer_interface_elements()
    if not customer_ifaces then return nil, customer_ifaces_err end
  end

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
    lines[#lines + 1] = "  set customer_ifaces {"
    lines[#lines + 1] = "    type ifname"
    lines[#lines + 1] = "    elements = { " .. customer_ifaces .. " }"
    lines[#lines + 1] = "  }"
    lines[#lines + 1] = "  set exempt_macs {"
    lines[#lines + 1] = "    type ether_addr"
    lines[#lines + 1] = "    elements = { " .. table.concat(exempt, ", ") .. " }"
    lines[#lines + 1] = "  }"
  end
  lines[#lines + 1] = "  chain forward_bw {"
  lines[#lines + 1] = "    type filter hook forward priority filter + 10; policy accept;"
  if #exempt > 0 and down > 0 then
    lines[#lines + 1] = "    oifname @customer_ifaces ether daddr @exempt_macs return"
  end
  if #exempt > 0 and up > 0 then
    lines[#lines + 1] = "    iifname @customer_ifaces ether saddr @exempt_macs return"
  end
  if mode == "per_client" then
    if down > 0 then
      lines[#lines + 1] = "    iifname \"" .. wan ..
        "\" meter per_client_down { ip daddr timeout 1m limit rate over " .. down ..
        " kbytes/second burst " .. rate_burst(down) .. " kbytes } drop"
      lines[#lines + 1] = "    iifname \"" .. wan ..
        "\" meter per_client_down6 { ip6 daddr timeout 1m limit rate over " .. down ..
        " kbytes/second burst " .. rate_burst(down) .. " kbytes } drop"
    end
    if up > 0 then
      lines[#lines + 1] = "    oifname \"" .. wan ..
        "\" meter per_client_up { ip saddr timeout 1m limit rate over " .. up ..
        " kbytes/second burst " .. rate_burst(up) .. " kbytes } drop"
      lines[#lines + 1] = "    oifname \"" .. wan ..
        "\" meter per_client_up6 { ip6 saddr timeout 1m limit rate over " .. up ..
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
  local live_rules, mode_or_err = bandwidth_rules("kemofi_bw", overrides)
  if not live_rules then return false, mode_or_err end
  if live_rules == "" then
    nft_delete_table("kemofi_bw")
    os.remove(BW_RULES_FILE)
    return true
  end
  local check_rules, check_err = bandwidth_rules("kemofi_bw_check", overrides)
  if not check_rules then return false, check_err end
  return nft_apply_checked(BW_RULES_FILE, check_rules, live_rules, "kemofi_bw")
end

local function sqm_config_text(overrides)
  local enabled = setting_from(overrides, "sqm_enabled") or "0"
  if enabled ~= "0" and enabled ~= "1" then
    return nil, "The saved SQM enabled state is invalid."
  end

  local lines = {
    "config queue 'wan'",
    "    option interface 'wan'",
    "    option enabled '" .. enabled .. "'",
    "    option qdisc 'cake'",
    "    option script 'piece_of_cake.qos'",
    "    option qdisc_advanced '1'",
    "    option qdisc_really_really_advanced '1'",
    "    option linklayer 'ethernet'",
    "    option overhead '0'",
    "    option squash_dscp '0'",
    "    option squash_ingress '0'",
    "    option ingress_ecn 'ECN'",
    "    option egress_ecn 'ECN'",
    "    option debug_logging '0'",
    "    option verbosity '1'"
  }

  if enabled == "0" then
    return table.concat(lines, "\n") .. "\n"
  end

  local down = normalize_nonnegative_integer(
    setting_from(overrides, "sqm_download_kbps") or "0", 10000000
  )
  local up = normalize_nonnegative_integer(
    setting_from(overrides, "sqm_upload_kbps") or "0", 10000000
  )
  if not down or not up or tonumber(down) <= 0 or tonumber(up) <= 0 then
    return nil, "Enter both download and upload SQM rates before enabling SQM."
  end

  local linklayer = tostring(setting_from(overrides, "sqm_linklayer") or "ethernet")
  if linklayer ~= "none" and linklayer ~= "ethernet" and linklayer ~= "atm" then
    return nil, "The saved SQM link layer is invalid."
  end
  local overhead = normalize_nonnegative_integer(
    setting_from(overrides, "sqm_overhead") or "0", 256
  )
  if not overhead then return nil, "The saved SQM overhead is invalid." end

  local fairness = setting_from(overrides, "sqm_host_fairness") or "1"
  if fairness ~= "0" and fairness ~= "1" then
    return nil, "The saved SQM fairness state is invalid."
  end

  local ingress_opts = fairness == "1" and "nat dual-dsthost" or "nat"
  local egress_opts = fairness == "1" and "nat dual-srchost" or "nat"
  lines[#lines + 1] = "    option download '" .. tostring(down) .. "'"
  lines[#lines + 1] = "    option upload '" .. tostring(up) .. "'"
  lines[8] = "    option linklayer '" .. linklayer .. "'"
  lines[9] = "    option overhead '" .. tostring(overhead) .. "'"
  lines[#lines + 1] = "    option iqdisc_opts '" .. ingress_opts .. "'"
  lines[#lines + 1] = "    option eqdisc_opts '" .. egress_opts .. "'"
  return table.concat(lines, "\n") .. "\n"
end

--- Apply CAKE SQM on the WAN, including IFB ingress shaping.
-- Full images use OpenWrt sqm-scripts; normal Lite images use the compact
-- KemoFi service.
function M.apply_sqm(overrides)
  if not SQM_AVAILABLE then
    os.remove(SQM_CONFIG_TEMP_FILE)
    return false, "SQM is not available in this firmware profile."
  end
  local enabled = setting_from(overrides, "sqm_enabled") or "0"
  local config, config_err = sqm_config_text(overrides)
  if not config then return false, config_err end

  local service_available = command_ok("test -x " .. shell_quote(SQM_SERVICE))
  if not service_available then
    if enabled == "0" then return true end
    return false, "The SQM package is not installed in this router image."
  end

  -- During early boot the WAN device may not exist yet. Keep the valid UCI
  -- configuration in place and let the SQM service/netifd apply it when WAN
  -- is created; removing it here would make an enabled SQM policy disappear
  -- after a normal boot with a delayed WAN link.
  if enabled == "1" then
    local interface = valid_interface((detect_network()))
    if not interface or not command_ok("test -e /sys/class/net/" ..
        shell_quote(interface)) then
      return true
    end
  end

  local previous = read_file(SQM_CONFIG_FILE)
  local wrote, write_err = write_file(SQM_CONFIG_TEMP_FILE, config)
  if not wrote then return false, tostring(write_err) end
  if not command_ok("mv " .. shell_quote(SQM_CONFIG_TEMP_FILE) .. " " ..
      shell_quote(SQM_CONFIG_FILE)) then
    os.remove(SQM_CONFIG_TEMP_FILE)
    return false, "The SQM configuration could not be installed."
  end

  local restarted = command_ok(shell_quote(SQM_SERVICE) .. " restart >/dev/null 2>&1")
  if restarted then return true end

  -- Never leave a broken qdisc/config behind after a failed live apply.
  if previous then
    write_file(SQM_CONFIG_TEMP_FILE, previous)
    command_ok("mv " .. shell_quote(SQM_CONFIG_TEMP_FILE) .. " " ..
      shell_quote(SQM_CONFIG_FILE))
    command_ok(shell_quote(SQM_SERVICE) .. " restart >/dev/null 2>&1")
  else
    os.remove(SQM_CONFIG_FILE)
    command_ok(shell_quote(SQM_SERVICE) .. " stop >/dev/null 2>&1")
  end
  return false, "SQM could not be activated on the WAN interface."
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
  if changed.sqm and SQM_AVAILABLE then
    local ok, err = M.apply_sqm(values)
    if not ok then return false, "sqm_apply_failed", err end
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
    sqm = false,
    filtering = false,
    upstream = false,
    anti_tethering = false
  }

  for key, value in pairs(params) do
    if not SQM_AVAILABLE and is_sqm_setting(key) then
      return 400, json.encode({
        error = "feature_unavailable",
        feature = "sqm",
        field = key,
        message = "SQM is not available in this firmware profile."
      })
    end
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
        if key:match("^sqm_") then changed.sqm = true end
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
  return 200, json.encode({status = "ok", updated = #changes})
end

--- GET /api/admin/rates
local function normalize_portal_rates(value)
  local normalized = rate_config.normalize(value)
  if not normalized then
    return nil, "Set positive PHP amounts and whole-minute times. Do not reuse the same PHP amount in multiple tiers."
  end
  return normalized
end

function M.get_rates(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local raw_rates = db.setting("portal_rates")
  local normalized_rates = rate_config.normalize(raw_rates == nil and "1:12" or raw_rates) or ""
  local normalized_flat = rate_config.normalize_flat_rate(db.setting("coin_min_per_php")) or ""
  return 200, json.encode({
    rates = normalized_rates,
    coin_min_per_php = normalized_flat
  })
end

--- POST /api/admin/rates
function M.save_rates(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local normalized_rates
  if params.rates ~= nil then
    local rates, rates_err = normalize_portal_rates(params.rates)
    if not rates then return 400, json.encode({error = "invalid_rates", message = rates_err}) end
    normalized_rates = rates
  end
  local normalized_flat
  if params.coin_min_per_php ~= nil then
    normalized_flat = rate_config.normalize_flat_rate(params.coin_min_per_php)
    if normalized_flat == nil then
      return 400, json.encode({
        error = "invalid_flat_rate",
        message = "Minutes per peso must be a whole number, or blank to use rate tiers."
      })
    end
  end
  if normalized_rates ~= nil then db.set_setting("portal_rates", normalized_rates) end
  if normalized_flat ~= nil then db.set_setting("coin_min_per_php", normalized_flat) end
  local err = persist_error("rates")
  if err then return 500, err end
  return 200, json.encode({status = "ok"})
end

--- GET /api/admin/gaming-priority
function M.get_gaming_priority(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  if not SQM_AVAILABLE then
    return 404, json.encode({
      error = "feature_unavailable",
      feature = "sqm",
      message = "Gaming Priority is unavailable because SQM is removed from this firmware profile."
    })
  end
  local enabled = normalize_boolean(db.setting("gaming_priority_enabled") or "1")
  if not enabled then
    return 500, json.encode({
      error = "invalid_config",
      message = "The saved Gaming Priority state is invalid."
    })
  end
  local rules, rules_err = normalize_gaming_rules(
    db.setting("gaming_priority_rules") or "[]"
  )
  if not rules then
    return 500, json.encode({error = "invalid_config", message = rules_err})
  end
  return 200, json.encode({
    enabled = enabled == "1",
    rules = rules,
    sqm_enabled = db.setting("sqm_enabled") == "1",
    active = enabled == "1" and #rules > 0
  })
end

--- POST /api/admin/gaming-priority
function M.save_gaming_priority(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  if not SQM_AVAILABLE then
    return 404, json.encode({
      error = "feature_unavailable",
      feature = "sqm",
      message = "Gaming Priority is unavailable because SQM is removed from this firmware profile."
    })
  end
  params = params or {}
  local enabled = normalize_boolean(params.enabled)
  if not enabled then
    return 400, json.encode({
      error = "invalid_enabled",
      message = "Choose Enabled or Disabled."
    })
  end
  if params.rules == nil then
    return 400, json.encode({
      error = "missing_rules",
      message = "Gaming rules are required."
    })
  end
  local rules, rules_err = normalize_gaming_rules(params.rules)
  if not rules then
    return 400, json.encode({error = "invalid_rules", message = rules_err})
  end

  local rules_json = json.encode(rules)
  local old_enabled = db.setting("gaming_priority_enabled")
  local old_rules = db.setting("gaming_priority_rules")
  local changes, previous = {}, {}
  if old_enabled ~= enabled then
    changes[#changes + 1] = {key = "gaming_priority_enabled", value = enabled}
    previous[#previous + 1] = {
      key = "gaming_priority_enabled", value = old_enabled,
      delete = old_enabled == nil
    }
  end
  if old_rules ~= rules_json then
    changes[#changes + 1] = {key = "gaming_priority_rules", value = rules_json}
    previous[#previous + 1] = {
      key = "gaming_priority_rules", value = old_rules,
      delete = old_rules == nil
    }
  end

  local saved, save_err = true, nil
  if #changes > 0 then
    saved, save_err = db.set_settings_atomic(changes)
  end
  if not saved then
    return 500, json.encode({
      error = "database_write_failed",
      message = tostring(save_err)
    })
  end

  local applied, apply_err = M.apply_gaming_priority()
  if not applied then
    if #changes > 0 then db.set_settings_atomic(previous) end
    M.apply_gaming_priority()
    db.persist("gaming-priority-rollback", true)
    return 500, json.encode({
      error = "gaming_priority_apply_failed",
      message = tostring(apply_err)
    })
  end

  if #changes > 0 then
    schedule_gaming_persist()
  end

  return 200, json.encode({
    status = "ok",
    enabled = enabled == "1",
    rules = rules,
    active = enabled == "1" and #rules > 0
  })
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

  local fw_version = "unknown"
  local vf = io.open("/etc/kemofi/version", "r")
  if vf then fw_version = vf:read("*l") or fw_version; vf:close() end
  local build_commit = "unknown"
  local cf = io.open("/etc/kemofi/commit", "r")
  if cf then build_commit = cf:read("*l") or build_commit; cf:close() end

  local model = "Ruijie RG-EW1200G Pro"
  local mf = io.open("/tmp/sysinfo/model", "r")
  if mf then model = mf:read("*l") or model; mf:close() end

  -- Disk usage
  local disk_total, disk_used, disk_avail = 0, 0, 0
  h = io.popen("df /overlay 2>/dev/null | tail -1")
  if h then
    local line = h:read("*a") or ""
    h:close()
    -- Skip filesystem column (may end in a digit e.g. mtdblock8)
    local t, u, a = line:match("%S+%s+(%d+)%s+(%d+)%s+(%d+)")
    disk_total = math.floor((tonumber(t) or 0) / 1024)
    disk_used = math.floor((tonumber(u) or 0) / 1024)
    disk_avail = math.floor((tonumber(a) or 0) / 1024)
  end

  -- WAN IP: try multiple interface names used by different Ruijie firmware versions
  local wan_ip = ""
  local wan_ifaces = {"eth0.2", "eth1", "wan"}
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
  local hostname = "KemoFi-LiteV2"
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
    wan_ip = wan_ip,
    lan_ip = lan_ip,
    license_status = license_status,
    license_configured = license_key ~= "",
    license_key_masked = mask_license_key(license_key),
    trial_started_at = trial_started_at > 0 and trial_started_at or nil,
    trial_expires_at = trial_expires_at ~= 0 and trial_expires_at or nil,
    profile = DEVICE_CAPABILITIES.profile,
    resource_tier = DEVICE_CAPABILITIES.resource_tier,
    radio_bands = DEVICE_CAPABILITIES.radio_bands,
    capabilities = DEVICE_CAPABILITIES
  })
end

--- GET /api/admin/system/ping
function M.ping(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  return 200, json.encode({status = "ok"})
end

--- GET /api/admin/remote/status
function M.remote_status(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  return 200, json.encode(remote_access.status())
end

--- GET /api/admin/remote/license
function M.remote_license(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  return 200, json.encode(remote_access.license())
end

--- POST /api/admin/remote/reconnect
function M.remote_reconnect(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local result = remote_access.reconnect()
  return result.status == "error" and 500 or 200, json.encode(result)
end

--- POST /api/admin/remote/diagnostics
function M.remote_diagnostics(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local result = remote_access.diagnostics()
  return result.status == "error" and 500 or 200, json.encode(result)
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
  return 200, json.encode({
    status = "ok",
    updated = 1,
    reconnect_required = true,
    reload_delay_seconds = WIFI_RELOAD_DELAY_SECONDS
  })
end

--- GET /api/admin/system/wan
function M.get_wan_config(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local proto = uci_get("network.wan.proto")
  if proto ~= "dhcp" and proto ~= "static" then proto = "dhcp" end
  local runtime = wan_runtime_status()
  local pending = wan_pending_state()
  return 200, json.encode({
    status = "ok",
    config = {
      proto = proto,
      device = uci_get("network.wan.device") ~= "" and uci_get("network.wan.device") or
        uci_get("network.wan.ifname"),
      ipaddr = uci_get("network.wan.ipaddr"),
      netmask = uci_get("network.wan.netmask"),
      gateway = uci_get("network.wan.gateway"),
      dns = wan_dns_value(),
      hostname = uci_get("network.wan.hostname"),
    },
    runtime = runtime,
    pending = pending and true or false,
    deadline = pending and pending.deadline or 0,
    rollback_seconds = WAN_ROLLBACK_SECONDS
  })
end

--- GET /api/admin/system/wan/test
function M.test_wan_config(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local runtime = wan_runtime_status()
  return 200, json.encode({status = "ok", runtime = runtime, online = runtime.online})
end

--- POST /api/admin/system/wan
function M.save_wan_config(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  if wan_pending_state() then
    return 409, json.encode({error = "wan_change_pending", message =
      "Confirm or restore the current WAN change before starting another one."})
  end
  local config, validation_error, field = normalize_wan_request(params)
  if not config then
    return 400, json.encode({error = "invalid_wan_config", field = field, message = validation_error})
  end
  if not file_exists(WAN_ROLLBACK_SCRIPT) then
    return 500, json.encode({error = "wan_safety_unavailable", message =
      "The WAN rollback safety helper is not installed on this firmware."})
  end
  if not command_ok("mkdir " .. shell_quote(WAN_APPLY_LOCK_PATH) .. " >/dev/null 2>&1") then
    return 409, json.encode({error = "wan_change_busy", message =
      "Another WAN change is already in progress."})
  end
  if not command_ok("cp -f " .. shell_quote(NETWORK_CONFIG_FILE) .. " " ..
      shell_quote(WAN_ROLLBACK_FILE)) then
    cleanup_wan_files(true)
    return 500, json.encode({error = "wan_backup_failed", message =
      "The current WAN configuration could not be backed up."})
  end
  command_ok("chmod 600 " .. shell_quote(WAN_ROLLBACK_FILE))
  local deadline = os.time() + WAN_ROLLBACK_SECONDS
  local wrote = write_file(WAN_PENDING_FILE, tostring(deadline) .. "\n")
  if not wrote then
    cleanup_wan_files(true)
    return 500, json.encode({error = "wan_transaction_failed", message =
      "The WAN safety timer could not be started."})
  end
  command_ok("chmod 600 " .. shell_quote(WAN_PENDING_FILE))
  if not command_ok("sh " .. shell_quote(WAN_ROLLBACK_SCRIPT) .. " >/dev/null 2>&1 &") then
    cleanup_wan_files(true)
    return 500, json.encode({error = "wan_transaction_failed", message =
      "The WAN rollback safety timer could not be started."})
  end
  if not apply_wan_uci(config) then
    restore_wan_backup()
    cleanup_wan_files(true)
    return 500, json.encode({error = "wan_save_failed", message =
      "The WAN configuration could not be saved; the previous configuration was restored."})
  end
  if not reload_wan_only() then
    restore_wan_backup()
    cleanup_wan_files(true)
    return 500, json.encode({error = "wan_reload_failed", message =
      "The WAN interface could not restart; the previous configuration was restored."})
  end
  return 200, json.encode({status = "pending_confirmation", pending = true,
    deadline = deadline, rollback_seconds = WAN_ROLLBACK_SECONDS})
end

--- POST /api/admin/system/wan/confirm
function M.confirm_wan_config(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  if not wan_pending_state() then
    return 409, json.encode({error = "no_wan_change_pending", message = "There is no WAN change to confirm."})
  end
  cleanup_wan_files(true)
  return 200, json.encode({status = "ok", message = "The new WAN configuration was kept."})
end

--- POST /api/admin/system/wan/rollback
function M.rollback_wan_config(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  if not file_exists(WAN_ROLLBACK_FILE) then
    cleanup_wan_files(false)
    return 200, json.encode({status = "ok", message = "There is no previous WAN configuration to restore."})
  end
  if not restore_wan_backup() then
    return 500, json.encode({error = "wan_rollback_failed", message =
      "The previous WAN configuration could not be restored."})
  end
  cleanup_wan_files(true)
  return 200, json.encode({status = "ok", message = "The previous WAN configuration was restored."})
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
  return 200, json.encode({status = "ok"}), {
    ["Set-Cookie"] = "kemofi_admin=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
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
  return 200, json.encode({status = "ok", message = msg})
end

--- GET /api/admin/backup
function M.backup(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  -- Sync to flash first
  local err = persist_error("operator-backup")
  if err then return 500, err end
  -- Read the database file and encode as base64
  local f = io.open("/etc/kemofi/sessions.db", "rb")
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
      if not line:find("# kemofi_reboot", 1, true) then lines[#lines + 1] = line end
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
    lines[#lines + 1] = min .. " " .. hour .. " * * " .. days .. " /sbin/reboot # kemofi_reboot"
  end
  local tmp = CRON_FILE .. ".kemofi.tmp"
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

  local tmp = DNSMASQ_BLOCK_FILE .. ".kemofi.tmp"
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
  -- Upstream management access is protected by policy and is not operator-toggleable.
  local enabled = "1"

  local normalized, addresses = normalize_upstream_list(
    setting_from(overrides, "blocked_upstream_ips") or ""
  )
  if not normalized then return nil, addresses end
  local wan, gateway = detect_network()
  wan = valid_interface(wan)
  local lan = valid_interface(os.getenv("KEMOFI_LAN_IFACE") or "br-lan")
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
  local live_rules, rules_err = upstream_rules("kemofi_upstream", overrides)
  if not live_rules then return false, rules_err end
  if live_rules == "" then
    nft_delete_table("kemofi_upstream")
    os.remove(UPSTREAM_RULES_FILE)
    return true
  end
  local check_rules, check_err = upstream_rules("kemofi_upstream_check", overrides)
  if not check_rules then return false, check_err end
  return nft_apply_checked(
    UPSTREAM_RULES_FILE, check_rules, live_rules, "kemofi_upstream"
  )
end

local function anti_tethering_rules(table_name, overrides)
  -- Connection-sharing protection is always enabled and is not operator-toggleable.
  local enabled = "1"

  local lan = valid_interface(os.getenv("KEMOFI_LAN_IFACE") or "br-lan")
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
  local live_rules, rules_err = anti_tethering_rules("kemofi_anti_tethering", overrides)
  if not live_rules then return false, rules_err end
  if live_rules == "" then
    nft_delete_table("kemofi_anti_tethering")
    os.remove(ANTI_TETHERING_RULES_FILE)
    return true
  end
  local check_rules, check_err = anti_tethering_rules(
    "kemofi_anti_tethering_check", overrides
  )
  if not check_rules then return false, check_err end
  return nft_apply_checked(
    ANTI_TETHERING_RULES_FILE,
    check_rules,
    live_rules,
    "kemofi_anti_tethering"
  )
end

--- Reconcile generated policies after the base firewall and database are restored.
function M.apply_runtime_policies()
  session.restore_member_access()
  local ok, err = M.apply_bandwidth()
  if not ok then return false, "bandwidth: " .. tostring(err) end
  if SQM_AVAILABLE then
    ok, err = M.apply_sqm()
    if not ok then return false, "sqm: " .. tostring(err) end
    ok, err = M.apply_gaming_priority()
    if not ok then return false, "gaming priority: " .. tostring(err) end
  else
    -- Remove stale artifacts when a full image is upgraded to Lite while
    -- settings are preserved. No Lite process may recreate them.
    os.remove(SQM_CONFIG_FILE)
    os.remove(SQM_CONFIG_TEMP_FILE)
    nft_delete_table("kemofi_gaming")
    os.remove(GAMING_RULES_FILE)
  end
  ok, err = M.apply_site_blocking()
  if not ok then return false, "filtering: " .. tostring(err) end
  ok, err = M.apply_upstream_protection()
  if not ok then return false, "upstream protection: " .. tostring(err) end
  ok, err = M.apply_anti_tethering()
  if not ok then return false, "connection sharing: " .. tostring(err) end
  return true
end

--- GET /api/admin/coin-nodes
local function normalize_coin_settings(params, fallback)
  params = params or {}
  fallback = fallback or {}
  local name = trim(params.name or params.node_name)
  if name == "" then name = trim(fallback.name or "KemoFi Coinslot") end
  name = name:gsub("[%z\r\n]", ""):sub(1, 48)
  if name == "" then name = "KemoFi Coinslot" end

  local coin_gpio = math.floor(tonumber(params.coin_gpio) or tonumber(fallback.coin_gpio) or 2)
  local relay_gpio = math.floor(tonumber(params.relay_gpio) or tonumber(fallback.relay_gpio) or 15)
  -- A pulse is permanently worth exactly PHP 1. Keep the legacy database
  -- column and API aliases for compatibility, but never accept a caller's
  -- value for them.
  local amount_php = 1
  if coin_gpio < 0 or coin_gpio > 16 or relay_gpio < 0 or relay_gpio > 16 then
    return nil, "GPIO must be between 0 and 16."
  end
  if coin_gpio == relay_gpio then
    return nil, "Coin and relay GPIO must be different."
  end
  return {
    name = name,
    coin_gpio = coin_gpio,
    relay_gpio = relay_gpio,
    amount_php_per_pulse = amount_php
  }
end

local function coin_settings_json(settings)
  return {
    name = settings.name,
    node_name = settings.name,
    coin_gpio = settings.coin_gpio,
    relay_gpio = settings.relay_gpio,
    amount_php_per_pulse = 1,
    amount_php = 1
  }
end

function M.list_coin_nodes(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local now = os.time()
  local nodes = db.query([[
    SELECT node_id, name, last_heartbeat, ip_address, total_coins, area_id,
           fw_version, coin_dpin, relay_dpin, coin_gpio, relay_gpio,
           1 AS amount_php_per_pulse, rssi,
           conn_mode, protocol_version, auth_enrolled_at
    FROM coin_nodes ORDER BY last_heartbeat DESC
  ]]) or {}
  for _, node in ipairs(nodes) do
    node.online = (now - (node.last_heartbeat or 0)) < 90
  end
  return 200, json.encode({nodes = nodes})
end

--- POST /api/admin/coin-nodes/settings
-- Router-owned hardware and pulse settings for one Coinslot.
function M.save_coin_node_settings(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local node_id = valid_mac(params.node_id)
  if not node_id then return 400, json.encode({error = "invalid_node_id"}) end
  local node = db.row("SELECT name, coin_gpio, relay_gpio, amount_php_per_pulse FROM coin_nodes WHERE node_id = ?", node_id)
  if not node then return 404, json.encode({error = "node_not_found"}) end
  local settings, validation_error = normalize_coin_settings(params, node)
  if not settings then
    return 400, json.encode({error = "invalid_coin_settings", message = validation_error})
  end
  local wrote, write_err = db.exec([[UPDATE coin_nodes SET
      name = ?, coin_gpio = ?, relay_gpio = ?, amount_php_per_pulse = ?
    WHERE node_id = ?]], settings.name, settings.coin_gpio, settings.relay_gpio,
    settings.amount_php_per_pulse, node_id)
  if not wrote then return 500, json.encode({error = "coin_settings_save_failed", detail = tostring(write_err)}) end
  local err = persist_error("coin-node-settings")
  if err then return 500, err end
  local response = coin_settings_json(settings)
  response.status = "ok"
  response.node_id = node_id
  return 200, json.encode(response)
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
  return 200, json.encode({status = "ok"})
end

local function coin_node_dhcp_section(node_id)
  local mac = valid_mac(node_id)
  if not mac then return nil end
  return "kemofi_coin_" .. mac:gsub(":", ""):lower()
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
  local tmp = DHCP_CONFIG_FILE .. ".kemofi.tmp"
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
  local name    = params.name or "kemofi-vendo"
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
  local safe_name = (name ~= "" and name or "kemofi-vendo"):gsub("'", "")
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
  return 200, json.encode({status = "ok", ip = ip, mac = mac or ""})
end

-- Persists code in DB settings so coin.lua can validate it across requests
-- (uhttpd reloads Lua state per-request; in-memory tables don't survive).
--- POST /admin/upload — Handle file uploads (sounds, logo, hero)
-- Accepts multipart/form-data with fields:
--   type: "coin_sound" | "tick_sound" | "logo" | "hero"
--   file: the binary file data
local UPLOAD_LIMITS = {
  coin_sound = { max_bytes = 819200, exts = { mp3=1, wav=1, ogg=1 }, target = "coin_sound" },
  tick_sound = { max_bytes = 204800, exts = { mp3=1, wav=1, ogg=1 }, target = "tick_sound" },
  logo       = { max_bytes = 512000, exts = { png=1, jpg=1, jpeg=1, webp=1, svg=1 }, target = "logo" },
  hero       = { max_bytes = 512000, exts = { png=1, jpg=1, jpeg=1, webp=1 }, target = "hero" },
}
local PORTAL_ASSETS = "/opt/kemofi/www/portal"
local PORTAL_ASSET_MIME = {
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  webp = "image/webp",
  svg = "image/svg+xml"
}
local PORTAL_CUSTOM_CSS = PORTAL_ASSETS .. "/custom-portal.css"
local PORTAL_CUSTOM_CSS_TMP = PORTAL_ASSETS .. "/custom-portal.css.tmp"
local MAX_PORTAL_CSS_BYTES = 64 * 1024
local PORTAL_UPDATE_SCHEMA = "kemofi-portal-theme"

local function read_portal_custom_css()
  local file = io.open(PORTAL_CUSTOM_CSS, "rb")
  if not file then return nil, false end
  local data = file:read("*a") or ""
  file:close()
  return data, true
end

local function write_portal_custom_css(css)
  local file = io.open(PORTAL_CUSTOM_CSS_TMP, "wb")
  if not file then return false, "Cannot stage the portal style file." end
  file:write(css)
  file:flush()
  file:close()
  if not os.rename(PORTAL_CUSTOM_CSS_TMP, PORTAL_CUSTOM_CSS) then
    os.remove(PORTAL_CUSTOM_CSS_TMP)
    return false, "Cannot activate the portal style file."
  end
  return true
end

local function restore_portal_custom_css(previous, existed)
  if existed then
    return write_portal_custom_css(previous or "")
  end
  os.remove(PORTAL_CUSTOM_CSS)
  os.remove(PORTAL_CUSTOM_CSS_TMP)
  return true
end

local function validate_portal_css(css)
  if type(css) ~= "string" then
    return nil, "The package must contain a CSS string."
  end
  if #css > MAX_PORTAL_CSS_BYTES then
    return nil, "The portal CSS is too large."
  end
  if css:find("[%z\1-\8\11\12\14-\31\127]") then
    return nil, "The portal CSS contains unsupported control characters."
  end
  local lower = css:lower()
  local blocked = {"<script", "</style", "@import", "expression(", "javascript:"}
  for _, token in ipairs(blocked) do
    if lower:find(token, 1, true) then
      return nil, "The portal CSS contains a blocked external or executable rule."
    end
  end
  local without_data_image = lower:gsub('url%(%s*"data:image/webp;base64,[A-Za-z0-9+/=]+"%s*%)', "")
  if without_data_image:find("url%(") then
    return nil, "The portal CSS contains a blocked external asset."
  end
  return css
end


local PORTAL_TEMPLATE_SCHEMA = "kemofi-portal-template"
local PORTAL_TEMPLATE_VERSION = 1
local PORTAL_TEMPLATE_ROOT = PORTAL_ASSETS .. "/templates"
local PORTAL_TEMPLATE_ACTIVE = PORTAL_TEMPLATE_ROOT .. "/active.html"
local PORTAL_TEMPLATE_TMP = PORTAL_TEMPLATE_ROOT .. "/active.html.tmp"
local PORTAL_TEMPLATE_BACKUP = PORTAL_TEMPLATE_ROOT .. "/active.html.bak"
local MAX_PORTAL_TEMPLATE_BODY_BYTES = 32 * 1024
local MAX_PORTAL_TEMPLATE_CSS_BYTES = 48 * 1024
local MAX_PORTAL_TEMPLATE_PACKAGE_BYTES = 96 * 1024
local PORTAL_TEMPLATE_IDS = {
  ["kingfi-luxury"] = true,
  ["kingfi-cyber"] = true,
  ["kingfi-gaming"] = true,
  ["kingfi-glass"] = true,
  ["kingfi-crown"] = true,
  ["kingfi-premium"] = true
}
local PORTAL_TEMPLATE_FIELDS = {
  schema = true,
  schemaVersion = true,
  template_id = true,
  body = true,
  css = true,
  visibility = true,
  settings = true
}
local PORTAL_TEMPLATE_VISIBILITY = {
  status = true,
  device = true,
  coin = true,
  rates = true,
  voucher = true,
  free = true,
  footer = true,
  pause = true,
  extend = true,
  actions = true
}

local function read_portal_template()
  local file = io.open(PORTAL_TEMPLATE_ACTIVE, "rb")
  if not file then return nil, false end
  local data = file:read("*a") or ""
  file:close()
  return data, true
end

local function write_portal_template_file(path, data)
  local file, open_err = io.open(path, "wb")
  if not file then return false, open_err or "Cannot open the portal template file." end
  local ok, write_err = pcall(function ()
    file:write(data)
    file:flush()
    file:close()
  end)
  if not ok then
    pcall(function () file:close() end)
    os.remove(path)
    return false, tostring(write_err)
  end
  return true
end

local function restore_portal_template_file(previous, existed)
  os.remove(PORTAL_TEMPLATE_TMP)
  if existed then
    local ok = write_portal_template_file(PORTAL_TEMPLATE_TMP, previous or "")
    if ok then
      os.rename(PORTAL_TEMPLATE_TMP, PORTAL_TEMPLATE_ACTIVE)
      return true
    end
    return false
  end
  os.remove(PORTAL_TEMPLATE_ACTIVE)
  return true
end

local function validate_portal_template(params)
  if type(params) ~= "table" then return nil, "Portal template package must be an object." end
  for key, _ in pairs(params) do
    if not PORTAL_TEMPLATE_FIELDS[key] then return nil, "Unsupported portal template field: " .. tostring(key) end
  end
  if params.schema ~= PORTAL_TEMPLATE_SCHEMA then return nil, "Unsupported portal template package." end
  if tonumber(params.schemaVersion) ~= PORTAL_TEMPLATE_VERSION then return nil, "Unsupported portal template version." end
  local template_id = tostring(params.template_id or "")
  if not PORTAL_TEMPLATE_IDS[template_id] or not template_id:match("^[a-z0-9][a-z0-9%-]+$") then
    return nil, "Unsupported portal template id."
  end
  local body = params.body
  local css = params.css
  if type(body) ~= "string" or #body > MAX_PORTAL_TEMPLATE_BODY_BYTES then return nil, "Portal template HTML is missing or too large." end
  if type(css) ~= "string" or #css > MAX_PORTAL_TEMPLATE_CSS_BYTES then return nil, "Portal template CSS is missing or too large." end
  if #body + #css > MAX_PORTAL_TEMPLATE_PACKAGE_BYTES then return nil, "Portal template package is too large." end
  if body:find("[%z\1-\8\11\12\14-\31\127]") then return nil, "Portal template HTML contains unsupported control characters." end
  local lower_body = body:lower()
  local blocked_html = {"<script", "</script", "<iframe", "<object", "<embed", "<base", "<form", "<style", "javascript:", "data:text/html"}
  for _, token in ipairs(blocked_html) do
    if lower_body:find(token, 1, true) then return nil, "Portal template HTML contains a blocked construct." end
  end
  if lower_body:find("%son[%a%d_%-]+%s*=") then return nil, "Portal template HTML contains an inline event handler." end
  if lower_body:find("[%s]src%s*=%s*[\"']https?://") or lower_body:find("[%s]href%s*=%s*[\"']https?://") or lower_body:find("[%s]src%s*=%s*[\"']//") or lower_body:find("[%s]href%s*=%s*[\"']//") then
    return nil, "Portal template HTML contains an external asset reference."
  end
  local checked_css, css_err = validate_portal_css(css)
  if not checked_css then return nil, css_err end
  if params.settings ~= nil and type(params.settings) ~= "table" then return nil, "Portal template settings must be an object." end
  for key, _ in pairs(params.settings or {}) do
    if not EDITABLE_SETTINGS[key] then return nil, "Unsupported portal setting: " .. tostring(key) end
  end
  if params.visibility ~= nil and type(params.visibility) ~= "table" then return nil, "Portal template visibility must be an object." end
  local visibility = {}
  for key, value in pairs(params.visibility or {}) do
    if not PORTAL_TEMPLATE_VISIBILITY[key] then return nil, "Unsupported portal visibility field: " .. tostring(key) end
    if type(value) ~= "boolean" then return nil, "Portal visibility values must be boolean." end
    visibility[key] = value
  end
  return {
    schema = PORTAL_TEMPLATE_SCHEMA,
    schemaVersion = PORTAL_TEMPLATE_VERSION,
    template_id = template_id,
    body = body,
    css = checked_css,
    visibility = visibility,
    settings = params.settings or {}
  }
end

--- GET /api/admin/portal/template/status
function M.portal_template_status(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local html, exists = read_portal_template()
  local template_id = ""
  if html then template_id = html:match('data%-kemofi%-template="([a-z0-9%-]+)"') or "" end
  return 200, json.encode({
    active = exists and #html > 0,
    template_id = template_id,
    bytes = exists and #html or 0,
    no_flash = true
  })
end

--- POST /api/admin/portal/template
--- Installs one validated presentation template without flashing or restarting services.
function M.apply_portal_template(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  params = params or {}
  if params.restore_defaults == true or tostring(params.restore_defaults or "") == "1" then
    local setting_status, setting_body = M.save_settings(env, {
      business_name = "KemoFi LiteV2",
      portal_name = "KemoFi LiteV2 WiFi",
      portal_footer_text = "",
      portal_footer_link = "https://kemofi.com/",
      portal_show_rates = "1",
      portal_show_voucher = "1",
      portal_show_coin = "1",
      free_time_enabled = "0",
      portal_hide_device_info = "0",
      portal_icon_set = "classic"
    })
    if setting_status < 200 or setting_status >= 300 then
      return setting_status, setting_body or json.encode({error = "settings_restore_failed"})
    end
    os.remove(PORTAL_TEMPLATE_ACTIVE)
    os.remove(PORTAL_TEMPLATE_TMP)
    os.remove(PORTAL_TEMPLATE_BACKUP)
    return 200, json.encode({status = "ok", restored = true, no_flash = true})
  end

  local package, package_err = validate_portal_template(params)
  if not package then return 400, json.encode({error = "invalid_template", message = package_err}) end
  local visibility = package.visibility or {}
  local function visibility_flag(key)
    return visibility[key] == false and "0" or "1"
  end
  local combined = "<!doctype html><html><head><meta charset=\"utf-8\"></head><body data-kemofi-template=\"" ..
    package.template_id .. "\" data-kemofi-show-status=\"" .. visibility_flag("status") ..
    "\" data-kemofi-show-footer=\"" .. visibility_flag("footer") ..
    "\" data-kemofi-show-pause=\"" .. visibility_flag("pause") ..
    "\" data-kemofi-show-extend=\"" .. visibility_flag("extend") ..
    "\" data-kemofi-show-actions=\"" .. visibility_flag("actions") ..
    "\" data-kemofi-show-rates=\"" .. tostring(package.settings.portal_show_rates or (visibility.rates == false and "0" or "1")) ..
    "\" data-kemofi-show-voucher=\"" .. tostring(package.settings.portal_show_voucher or (visibility.voucher == false and "0" or "1")) ..
    "\" data-kemofi-show-coin=\"" .. tostring(package.settings.portal_show_coin or (visibility.coin == false and "0" or "1")) ..
    "\" data-kemofi-show-free-time=\"" .. tostring(package.settings.free_time_enabled or (visibility.free == false and "0" or "1")) ..
    "\" data-kemofi-show-device=\"" .. tostring(package.settings.portal_hide_device_info == "1" and "0" or (visibility.device == false and "0" or "1")) ..
    "\">" .. package.body .. "</body></html>"
  combined = combined:gsub("</head>", function ()
    return "<style id=\"kemofi-active-template-style\">" .. package.css .. "</style></head>"
  end, 1)
  if #combined > MAX_PORTAL_TEMPLATE_PACKAGE_BYTES then return 400, json.encode({error = "template_too_large"}) end
  local available_kb = fs_available_kb(PORTAL_ASSETS)
  if available_kb > 0 and available_kb * 1024 < #combined + 8192 then
    return 507, json.encode({error = "insufficient_storage", message = "Not enough router overlay storage for this portal template."})
  end
  if not command_ok("mkdir -p " .. shell_quote(PORTAL_TEMPLATE_ROOT) .. " >/dev/null 2>&1") then
    return 500, json.encode({error = "template_directory_failed"})
  end

  local previous, previous_exists = read_portal_template()
  if previous_exists then
    local backed_up, backup_err = write_portal_template_file(PORTAL_TEMPLATE_BACKUP, previous)
    if not backed_up then return 500, json.encode({error = "template_backup_failed", message = backup_err}) end
  end
  local staged, stage_err = write_portal_template_file(PORTAL_TEMPLATE_TMP, combined)
  if not staged then return 507, json.encode({error = "template_write_failed", message = stage_err}) end
  if not os.rename(PORTAL_TEMPLATE_TMP, PORTAL_TEMPLATE_ACTIVE) then
    os.remove(PORTAL_TEMPLATE_TMP)
    return 500, json.encode({error = "template_activate_failed"})
  end

  local setting_status, setting_body = 200, nil
  if next(package.settings) ~= nil then setting_status, setting_body = M.save_settings(env, package.settings) end
  if setting_status < 200 or setting_status >= 300 then
    restore_portal_template_file(previous, previous_exists)
    return setting_status, setting_body or json.encode({error = "settings_update_failed"})
  end
  os.remove(PORTAL_TEMPLATE_BACKUP)
  return 200, json.encode({
    status = "ok",
    template_id = package.template_id,
    html_bytes = #package.body,
    css_bytes = #package.css,
    no_flash = true,
    message = "Portal template applied without flashing firmware."
  })
end

--- GET /api/admin/portal/update/status
--- Reports the runtime-managed presentation override without exposing its contents.
function M.portal_update_status(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  local css, exists = read_portal_custom_css()
  return 200, json.encode({
    installed = exists and #css > 0,
    size = exists and #css or 0,
    no_flash = true
  })
end

--- POST /api/admin/portal/update
--- Applies a KemoFi theme package without flashing firmware or restarting services.
function M.apply_portal_update(env, params)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  params = params or {}

  if params.restore_defaults == true or tostring(params.restore_defaults or "") == "1" then
    local setting_status, setting_body = M.save_settings(env, {
      business_name = "KemoFi LiteV2",
      portal_name = "KemoFi LiteV2 WiFi",
      portal_footer_text = "",
      portal_footer_link = "https://kemofi.com/",
      portal_show_rates = "1",
      portal_show_voucher = "1",
      portal_show_coin = "1",
      free_time_enabled = "0",
      portal_hide_device_info = "0",
      portal_icon_set = "classic"
    })
    if setting_status < 200 or setting_status >= 300 then
      return setting_status, setting_body or json.encode({error = "settings_restore_failed"})
    end
    os.remove(PORTAL_CUSTOM_CSS)
    os.remove(PORTAL_CUSTOM_CSS_TMP)
    return 200, json.encode({status = "ok", restored = true, updated_settings = true, no_flash = true})
  end

  if params.schema ~= PORTAL_UPDATE_SCHEMA then
    return 400, json.encode({error = "invalid_package", message = "This is not a KemoFi portal theme package."})
  end
  local schema_version = tonumber(params.schemaVersion)
  if schema_version ~= 1 and schema_version ~= 2 then
    return 400, json.encode({error = "invalid_package", message = "Unsupported portal package version."})
  end

  local css, css_err = validate_portal_css(params.css or "")
  if not css then return 400, json.encode({error = "invalid_css", message = css_err}) end
  if params.settings ~= nil and type(params.settings) ~= "table" then
    return 400, json.encode({error = "invalid_settings", message = "Package settings must be an object."})
  end
  for key, _ in pairs(params.settings or {}) do
    if not EDITABLE_SETTINGS[key] then
      return 400, json.encode({error = "unsupported_setting", field = key})
    end
  end

  local previous_css, previous_exists = read_portal_custom_css()
  local staged, stage_err = write_portal_custom_css(css)
  if not staged then return 500, json.encode({error = "css_write_failed", message = stage_err}) end

  local setting_status, setting_body = 200, nil
  if next(params.settings or {}) ~= nil then
    setting_status, setting_body = M.save_settings(env, params.settings)
  end
  if setting_status < 200 or setting_status >= 300 then
    restore_portal_custom_css(previous_css, previous_exists)
    return setting_status, setting_body or json.encode({error = "settings_update_failed"})
  end

  return 200, json.encode({
    status = "ok",
    updated_settings = next(params.settings or {}) and true or false,
    css_bytes = #css,
    no_flash = true,
    message = "Portal update applied without flashing firmware."
  })
end

--- GET /api/admin/portal-asset?type=logo
--- Public, read-only access for the admin shell favicon and logo.
function M.portal_asset(env, params)
  local asset_type = (params and params.type) or (env.query and env.query.type)
  if asset_type ~= "logo" then
    return 404, json.encode({error = "not_found"})
  end

  local settings = db.settings({"portal_logo_file", "portal_logo_filename"})
  local filename = settings.portal_logo_file or settings.portal_logo_filename or ""
  if type(filename) ~= "string" or not filename:match("^logo%.[%w]+$") then
    return 404, json.encode({error = "not_found"})
  end

  local ext = filename:match("%.([^.]+)$")
  ext = ext and ext:lower() or ""
  local content_type = PORTAL_ASSET_MIME[ext]
  if not content_type then
    return 404, json.encode({error = "not_found"})
  end

  local file = io.open(PORTAL_ASSETS .. "/" .. filename, "rb")
  if not file then
    return 404, json.encode({error = "not_found"})
  end
  local data = file:read("*a") or ""
  file:close()
  return 200, data, {
    ["Content-Type"] = content_type,
    ["Content-Length"] = tostring(#data),
    ["Cache-Control"] = "no-cache"
  }
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

  local limits = UPLOAD_LIMITS[upload_type]
  local file_part = params.file
  if not file_part or not file_part.value or file_part.value == "" then
    return 400, json.encode({error = "no_file", message = "No file uploaded"})
  end

  -- Check file size
  local data = file_part.value
  if #data > limits.max_bytes then
    return 400, json.encode({error = "file_too_large", message = "Max size: " .. math.floor(limits.max_bytes/1024) .. "KB"})
  end

  -- Get file extension
  local filename = file_part.filename or ""
  local ext = filename:match("%.([^.]+)$")
  if ext then ext = ext:lower() end
  if not ext or not limits.exts[ext] then
    local allowed = {}
    for k, _ in pairs(limits.exts) do allowed[#allowed+1] = "." .. k end
    return 400, json.encode({error = "invalid_format", message = "Allowed: " .. table.concat(allowed, ", ")})
  end

  -- Save file (overwrite existing)
  local target_name = limits.target .. "." .. ext
  local target_path = PORTAL_ASSETS .. "/" .. target_name

  -- Remove old files with different extensions
  for old_ext, _ in pairs(limits.exts) do
    local old_path = PORTAL_ASSETS .. "/" .. limits.target .. "." .. old_ext
    os.remove(old_path)
  end

  -- Write new file
  local f = io.open(target_path, "wb")
  if not f then
    return 500, json.encode({error = "write_failed", message = "Cannot write to flash"})
  end
  f:write(data)
  f:close()

  -- Store filename in settings for the portal to reference
  db.set_setting("portal_" .. upload_type .. "_file", target_name)
  db.set_setting("portal_" .. upload_type .. "_version", tostring(os.time()) .. "-" .. tostring(#data))
  local err = persist_error("portal-asset-upload")
  if err then return 500, err end
  return 200, json.encode({ok = true, file = target_name, size = #data})
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
  -- Remove all possible files
  for ext, _ in pairs(limits.exts) do
    os.remove(PORTAL_ASSETS .. "/" .. limits.target .. "." .. ext)
  end
  db.set_setting("portal_" .. upload_type .. "_file", "")
  db.set_setting("portal_" .. upload_type .. "_version", "")
  local err = persist_error("portal-asset-delete")
  if err then return 500, err end
  return 200, json.encode({ok = true})
end

--- GET /api/admin/system/check-update
-- Fetches the latest release manifest from the vendor platform and compares versions.
-- SECURITY: Only returns version/notes/update_available to the browser.
-- download_url and sha256 are kept server-side only.
function M.check_update(env)
  if not check_auth(env) then return 401, json.encode({error = "unauthorized"}) end
  -- Get current version
  -- 0.0.0 is an explicit legacy/unversioned marker for OTA comparison;
  -- current images always receive VERSION during build preparation.
  local current_ver = "0.0.0"
  local vf = io.open(VERSION_FILE, "r")
  if vf then current_ver = vf:read("*l") or current_ver; vf:close() end
  current_ver = trim(current_ver)
  if #current_ver > 64 or not current_ver:match("^%d+%.%d+%.%d+[%w%.%-]*$") then
    current_ver = "0.0.0"
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
  -- Fetch latest release from vendor platform (OpenWrt-specific endpoint, direct JSON)
  local separator = OTA_MANIFEST_URL:find("?", 1, true) and "&" or "?"
  local check_url = OTA_MANIFEST_URL .. separator .. "current_version=" .. current_ver
  check_url = append_board_param(check_url, board_name)
  if not fetch_file(check_url, OTA_CHECK_PATH, 15) then
    return 200, json.encode({error = "Failed to reach update server", version = current_ver, update_available = false})
  end
  -- Read and parse the response (direct JSON from /api/releases/openwrt/latest)
  local f = io.open(OTA_CHECK_PATH, "r")
  if not f then
    return 200, json.encode({error = "Failed to read response", version = current_ver, update_available = false})
  end
  local raw = f:read("*a")
  f:close()
  os.remove(OTA_CHECK_PATH)
  local manifest = json.decode(raw)
  if not manifest then
    return 200, json.encode({error = "Invalid response format", version = current_ver, update_available = false})
  end
  -- SECURITY: Only expose safe fields to the browser — no download_url, no token
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
    return 400, json.encode({error = "invalid_mode", message = "Choose Fresh Install, Preserve Settings, or Validate only."})
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
    return 400, json.encode({error = "invalid_mode", message = "Choose Fresh Install, Preserve Settings, or Validate only."})
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

function M.url_update(env, params)
  if not check_auth(env) then return 401, json.encode({error="unauthorized"}) end
  params = params or {}
  local normalized_url, source_kind = normalize_remote_firmware_url(params.url)
  if not normalized_url then
    if source_kind == "folder" then
      return 400, json.encode({error="google_drive_folder",message="Google Drive folder links are not firmware files. Open the folder and paste the exact .bin file link for this router."})
    end
    return 400, json.encode({error="invalid_url",message="Enter a valid HTTPS firmware URL. Direct links must end in .bin; Google Drive file links are supported."})
  end
  local url, host, port, resolved_ip = valid_remote_firmware_url(normalized_url)
  if not url or (source_kind == "direct" and not firmware_url_has_bin(url)) then
    return 400, json.encode({error="invalid_url",message="Enter a valid HTTPS firmware URL. Direct links must end in .bin; Google Drive file links are supported."})
  end
  local mode = validate_manual_update_mode(params); if not mode then return 400, json.encode({error="invalid_mode",message="Choose Fresh Install, Preserve Settings, or Validate only."}) end
  local sum = trim(tostring(params.sha256 or "")):lower()
  if sum ~= "" and (#sum ~= 64 or not sum:match("^%x+$")) then return 400, json.encode({error="invalid_checksum",message="The SHA-256 checksum is invalid."}) end
  if not acquire_url_upgrade_lock() then return 409, json.encode({error="upgrade_in_progress",message="Another firmware upgrade is already in progress."}) end
  cleanup_staged_firmware(URL_FIRMWARE_PATH)
  local required_kb = math.ceil(MAX_MANUAL_FIRMWARE_BYTES / 1024) + 2048
  local tmp_free_kb = fs_available_kb("/tmp")
  if tmp_free_kb > 0 and tmp_free_kb < required_kb then
    cleanup_staged_firmware(URL_FIRMWARE_PATH); release_url_upgrade_lock()
    return 507, json.encode({error="not_enough_space",message="Not enough temporary space for this firmware download."})
  end
  if source_kind == "mediafire_page" then
    local direct, direct_host, direct_port, direct_ip =
      resolve_mediafire_download(url, host, port, resolved_ip)
    if not direct then
      cleanup_staged_firmware(URL_FIRMWARE_PATH); release_url_upgrade_lock()
      return 502, json.encode({error="provider_resolution_failed",message="Could not resolve the MediaFire download link. Confirm the page contains the firmware .bin file and try again."})
    end
    url, host, port, resolved_ip = direct, direct_host, direct_port, direct_ip
  end
  if not fetch_remote_firmware(url, URL_FIRMWARE_PATH, 60, host, port, resolved_ip, MAX_MANUAL_FIRMWARE_BYTES) then cleanup_staged_firmware(URL_FIRMWARE_PATH); release_url_upgrade_lock(); return 502, json.encode({error="download_failed",message="Could not download the firmware image."}) end
  local size = file_size(URL_FIRMWARE_PATH) or 0
  if size < 1048576 then cleanup_staged_firmware(URL_FIRMWARE_PATH); release_url_upgrade_lock(); return 400, json.encode({error="file_too_small",message="Firmware file is too small."}) end
  if size > MAX_MANUAL_FIRMWARE_BYTES then cleanup_staged_firmware(URL_FIRMWARE_PATH); release_url_upgrade_lock(); return 413, json.encode({error="file_too_large",message="Firmware file is too large."}) end
  if sum ~= "" and sha256_file(URL_FIRMWARE_PATH) ~= sum then cleanup_staged_firmware(URL_FIRMWARE_PATH); release_url_upgrade_lock(); return 422, json.encode({error="checksum_mismatch",message="Firmware checksum does not match."}) end
  local status, body = apply_manual_firmware(size, mode, URL_FIRMWARE_PATH, true)
  if status ~= 200 then release_url_upgrade_lock() end
  return status, body
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
  local sha_h = io.popen(shell_quote(SHA256_BIN) .. " " .. shell_quote(fw_path) .. " 2>/dev/null")
  local sha_out = (sha_h and sha_h:read("*a") or "")
  if sha_h then sha_h:close() end
  local actual_sha256 = sha_out:match("^(%x+)")
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
  local state_ready, state_err = ensure_customer_state_preserved()
  if not state_ready then
    os.remove(fw_path)
    return 500, json.encode({
      error = "preserve_check_failed",
      message = "Customer data could not be prepared safely.",
      detail = tostring(state_err or "preservation list update failed")
    })
  end
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
  if not acquire_url_upgrade_lock() then
    os.remove(fw_path)
    return 409, json.encode({error = "upgrade_in_progress", message = "Another firmware upgrade is already in progress."})
  end
  -- Step 6: Apply sysupgrade without -n so keep.d and OpenWrt configuration
  -- are preserved. Tests run synchronously; production detaches before reboot.
  local apply_command = shell_quote(SYSUPGRADE_BIN) .. " " .. shell_quote(fw_path)
  if not SYSUPGRADE_SYNC then apply_command = apply_command .. " >/dev/null 2>&1 &" end
  if not command_ok(apply_command) then
    os.remove(fw_path)
    release_url_upgrade_lock()
    return 500, json.encode({error = "Firmware validation passed, but sysupgrade could not start."})
  end
  return 200, json.encode({status = "ok", message = "Firmware update started. Settings will be preserved. Router will reboot."})
end

return M
