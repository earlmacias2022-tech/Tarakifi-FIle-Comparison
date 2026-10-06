#!/usr/bin/env lua
--- KemoFi Remote Management Worker (HTTP Long-Polling)
-- Polls the vendor platform for pending admin requests, executes them locally,
-- and sends responses back. Enables remote admin panel access without WebSocket.
--
-- Runs as a supervised procd instance. Polls every 3s when idle, immediately
-- when requests are pending. Reconnects with exponential backoff on failure.
--
-- Usage: lua /opt/kemofi/lua/lib/remote.lua
local LUA_ROOT = os.getenv("KEMOFI_LUA_ROOT") or "/opt/kemofi/lua"
package.path = LUA_ROOT .. "/?.lua;" .. LUA_ROOT .. "/lib/?.lua;" .. package.path

local nixio  = require("nixio")
local socket = require("socket")
local db     = require("lib.db")
local json   = require("lib.json")

local M = {}

-- ─── Configuration ─────────────────────────────────────────────────────────────

-- KemoFi backend: GET /router-api/remote/<action>/<bind_code>
-- authenticated by HMAC-signed X-KemoFi-* headers (not /api/tunnel/poll+respond).
local SECRET_FILE         = os.getenv("KEMOFI_REMOTE_SECRET_FILE") or "/etc/pisowifi/remote-agent.secret"
local LICENSE_MANAGER_URL = os.getenv("KEMOFI_LICENSE_MANAGER_URL_FILE") or "/etc/pisowifi/license_manager_url"
local EDITION_FILE        = os.getenv("KEMOFI_EDITION_FILE") or "/etc/pisowifi/edition"
local LOCK_PATH           = "/tmp/kemofi/remote.lock"
local IDLE_POLL_SECONDS   = 10     -- seconds between polls when idle
local ACTIVE_POLL_SECONDS = 4      -- seconds between polls during active delivery
local MAX_BACKOFF         = 300    -- max seconds on failure back-off
local UNLICENSED_INTERVAL = 30     -- retry interval when no active license
local LOCAL_ADMIN_PORT    = 8080   -- local admin panel port
local WATCHDOG_INTERVAL   = 30     -- feed procd watchdog every 30 s
local UBUS_BIN            = "/bin/ubus"
-- Remote transport is outbound HTTPS polling plus a reverse-SSH admin relay.
-- It never creates a virtual interface or changes the WAN/customer route.
local SSH_KEY_FILE        = os.getenv("KEMOFI_SSH_KEY_FILE") or "/etc/pisowifi/reverse-ssh.key"
local SSH_CONFIG_FILE     = os.getenv("KEMOFI_SSH_CONFIG_FILE") or "/etc/pisowifi/reverse-ssh.conf"
local LEGACY_SECRET_FILE  = "/etc/kemofi/remote-agent.secret"
local LEGACY_LICENSE_MANAGER_URL = "/etc/kemofi/license_manager_url"
local LEGACY_EDITION_FILE = "/etc/kemofi/edition"
local LEGACY_SSH_KEY_FILE = "/etc/kemofi/reverse-ssh.key"
local LEGACY_SSH_CONFIG_FILE = "/etc/kemofi/reverse-ssh.conf"
local SSH_RETRY_MAX       = 300
local ssh_retry_after     = 0
local ssh_retry_delay     = IDLE_POLL_SECONDS

--- Safe sleep that handles nixio.nanosleep's integer requirement
local function safe_sleep(seconds)
  local secs = math.floor(seconds)
  local nsecs = math.floor((seconds - secs) * 1000000000)
  nixio.nanosleep(secs, nsecs)
end

-- ─── Logging ───────────────────────────────────────────────────────────────────

local function log(msg)
  io.stdout:write(os.date("[%H:%M:%S] ") .. "Remote: " .. tostring(msg) .. "\n")
  io.stdout:flush()
end

local function feed_watchdog()
  os.execute(UBUS_BIN .. ' call service watchdog \'{"name":"kemofi","instance":"remote"}\' >/dev/null 2>&1')
end

-- ─── HTTP Helpers ──────────────────────────────────────────────────────────────

-- ─── HTTP Helpers ──────────────────────────────────────────────────────────────

local function shell(cmd)
  local f = io.popen(cmd); if not f then return "" end
  local r = f:read("*a") or ""; f:close(); return r
end

local function shell_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function ensure_ssh_directories()
  local key_dir = SSH_KEY_FILE:match("^(.*)/[^/]+$")
  local config_dir = SSH_CONFIG_FILE:match("^(.*)/[^/]+$")
  if key_dir and key_dir ~= "" then
    os.execute("mkdir -p " .. shell_quote(key_dir) .. " 2>/dev/null")
  end
  if config_dir and config_dir ~= "" and config_dir ~= key_dir then
    os.execute("mkdir -p " .. shell_quote(config_dir) .. " 2>/dev/null")
  end
end

local function ensure_state_directory()
  os.execute("mkdir -p /etc/pisowifi 2>/dev/null")
end

local function sha256(value)
  local path = "/tmp/kemofi/remote-hash"
  os.execute("mkdir -p /tmp/kemofi && chmod 700 /tmp/kemofi")
  local f = io.open(path, "wb")
  if not f then return "" end
  f:write(tostring(value or "")); f:close()
  local digest = shell("sha256sum " .. shell_quote(path) .. " 2>/dev/null"):match("^(%x+)") or ""
  os.remove(path)
  return digest
end

local function hmac_sha256(key, value)
  local function unhex(hex)
    return (hex:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
  end
  local function byte_xor(a, b)
    local result, bit = 0, 1
    while a > 0 or b > 0 do
      if (a % 2) ~= (b % 2) then result = result + bit end
      a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
    end
    return result
  end
  key = tostring(key or "")
  if #key > 64 then key = unhex(sha256(key)) end
  key = key .. string.rep("\0", 64 - #key)
  local inner, outer = {}, {}
  for i = 1, 64 do
    local byte = key:byte(i)
    inner[i] = string.char(byte_xor(byte, 0x36))
    outer[i] = string.char(byte_xor(byte, 0x5c))
  end
  local inner_digest = unhex(sha256(table.concat(inner) .. tostring(value or "")))
  return sha256(table.concat(outer) .. inner_digest)
end

local function url_segment(value)
  return tostring(value or ""):gsub("[^%w%._~%-]", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
end

local function read_line(path)
  local f = io.open(path, "r"); if not f then return "" end
  local v = (f:read("*l") or ""):gsub("^%s+", ""):gsub("%s+$", ""); f:close(); return v
end

-- New images store firmware identity under /etc/kemofi. Keep the old
-- web-root read only as a migration fallback so remote inventory reports the
-- same value as the admin system page and OTA checker.
local function firmware_version()
  local version = read_line("/etc/kemofi/version")
  if version ~= "" then return version end
  return read_line("/www/version.txt")
end

local function read_state_line(primary, legacy)
  local value = read_line(primary)
  if value ~= "" then return value end
  return read_line(legacy)
end

local function active_ssh_paths()
  if read_line(SSH_CONFIG_FILE) ~= "" and read_line(SSH_KEY_FILE) ~= "" then
    return SSH_CONFIG_FILE, SSH_KEY_FILE
  end
  if read_line(LEGACY_SSH_CONFIG_FILE) ~= "" and read_line(LEGACY_SSH_KEY_FILE) ~= "" then
    return LEGACY_SSH_CONFIG_FILE, LEGACY_SSH_KEY_FILE
  end
  return SSH_CONFIG_FILE, SSH_KEY_FILE
end

local function trim_text(value)
  if type(value) ~= "string" then return "" end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function firmware_edition()
  local edition = read_state_line(EDITION_FILE, LEGACY_EDITION_FILE):lower():gsub("%s+", "")
  if edition == "remote" then return edition end
  return "local"
end

local function read_base()
  local v = read_state_line(LICENSE_MANAGER_URL, LEGACY_LICENSE_MANAGER_URL)
  local authority = v:match("^https://([^/%?#]+)")
  local host, port = authority and authority:match("^([A-Za-z0-9][A-Za-z0-9%.%-]*)(:%d+)?$")
  local port_number = port and tonumber(port:sub(2)) or nil
  if host and (not port_number or (port_number >= 1 and port_number <= 65535)) then
    return "https://" .. host .. (port or "")
  end
  return "https://kemofi.com"
end

local function read_secret()
  return read_state_line(SECRET_FILE, LEGACY_SECRET_FILE)
end

-- KemoFi signed_headers list (must match the server's canonical order exactly).
local SIGNED_HEADERS = {
  "X-KemoFi-Firmware-Version", "X-KemoFi-Router-Model",
  "X-KemoFi-Command-Id", "X-KemoFi-Command-Result", "X-KemoFi-Command-Summary",
  "X-KemoFi-Voucher-Delivery-Id", "X-KemoFi-Session-Token", "X-KemoFi-Request-Id",
  "X-KemoFi-Remaining-Seconds", "X-KemoFi-Remaining-Data-Mb", "X-KemoFi-Paused",
  "X-KemoFi-Session-Batch-Hash", "X-KemoFi-Rates-Scope", "X-KemoFi-Rates-Version",
  "X-KemoFi-SSH-Public-Key", "X-KemoFi-SSH-Connected",
  "X-KemoFi-Portal-Update-Id", "X-KemoFi-Portal-Update-Result", "X-KemoFi-Portal-Update-Summary",
}

local function header_value(extra, name)
  local prefix = name .. ":"
  for _, h in ipairs(extra or {}) do
    if h:sub(1, #prefix):lower() == prefix:lower() then
      return h:sub(#prefix + 1):gsub("^%s+", "")
    end
  end
  return ""
end

--- Perform a signed GET /router-api/remote/<action>/<bind_code>.
-- Preserve JSON error bodies so an explicit 401 recovery_required response
-- can rotate the local agent secret without treating it as a network outage.
local function signed_request(base, bind, secret, action, extra)
  local timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local nonce = sha256(tostring(os.time()) .. tostring(math.random()) .. secret):sub(1, 32)
  local canonical = {action, bind, timestamp, nonce}
  for _, name in ipairs(SIGNED_HEADERS) do
    canonical[#canonical + 1] = sha256(header_value(extra, name))
  end
  local signature = hmac_sha256(secret, table.concat(canonical, "|"))
  local endpoint = base .. "/router-api/remote/" .. url_segment(action:gsub("^remote_", "")) .. "/" .. url_segment(bind)
  local cmd = "curl -sS --connect-timeout 8 --max-time 20"
    .. " --header='X-KemoFi-Firmware-Edition: " .. firmware_edition() .. "'"
    .. " --header='X-KemoFi-Timestamp: " .. timestamp .. "'"
    .. " --header='X-KemoFi-Nonce: " .. nonce .. "'"
    .. " --header='X-KemoFi-Signature: " .. signature .. "'"
  local device_id = read_line("/etc/kemofi/device_id")
  if device_id:match("^openwrt%-%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") then
    cmd = cmd .. " --header='X-KemoFi-Device-Id: " .. device_id .. "'"
  end
  for _, h in ipairs(extra or {}) do
    cmd = cmd .. " --header='" .. h:gsub("'", "'\\''") .. "'"
  end
  local raw = shell(cmd .. " --write-out '\\n__KEMOFI_HTTP_STATUS:%{http_code}' '" .. endpoint:gsub("'", "'\\''") .. "' 2>/dev/null")
  local body, status = raw:match("^(.*)\n__KEMOFI_HTTP_STATUS:(%d%d%d)%s*$")
  status = tonumber(status or "0")
  return body or ""
end

--- Enroll with the KemoFi remote-agent endpoint using the router license key.
-- On success writes the agent secret to SECRET_FILE and returns true.
local function enroll(base, bind, license_key)
  local cmd = "curl -sS --connect-timeout 8 --max-time 20"
    .. " --header='X-License-Key: " .. license_key:gsub("'", "'\\''") .. "'"
    .. " --header='X-KemoFi-Firmware-Edition: " .. firmware_edition() .. "'"
  local device_id = read_line("/etc/kemofi/device_id")
  if device_id:match("^openwrt%-%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") then
    cmd = cmd .. " --header='X-KemoFi-Device-Id: " .. device_id .. "'"
  end
  cmd = cmd .. " --header='X-KemoFi-Agent-Reenroll: 1'"
    .. " '" .. (base .. "/router-api/remote/enroll/" .. url_segment(bind)):gsub("'", "'\\''") .. "' 2>/dev/null"
  local raw = shell(cmd .. " --write-out '\\n__KEMOFI_HTTP_STATUS:%{http_code}'")
  local body, status = raw:match("^(.*)\n__KEMOFI_HTTP_STATUS:(%d%d%d)%s*$")
  raw = (tonumber(status or "0") >= 200 and tonumber(status or "0") < 300) and (body or "") or ""
  local ok, resp = pcall(json.decode, raw)
  if ok and resp and resp.success and type(resp.agent_secret) == "string" then
    ensure_state_directory()
    local f = io.open(SECRET_FILE, "w")
    if f then f:write(resp.agent_secret .. "\n"); f:close() end
    return true
  end
  return false
end

local function valid_endpoint(value)
  value = tostring(value or "")
  return #value > 0 and #value <= 253 and
    value:match("^[A-Za-z0-9][A-Za-z0-9%.%-]*$") ~= nil and
    value:sub(-1):match("[A-Za-z0-9]") ~= nil
end

-- Generate one router-local key for the outbound reverse-SSH relay. The
-- private key is never sent; only its public half is enrolled over HTTPS.
local function ssh_public_key()
  ensure_ssh_directories()
  local _, key_file = active_ssh_paths()
  if read_line(key_file) == "" then
    ensure_ssh_directories()
    os.execute("umask 077; dropbearkey -t ed25519 -f " .. shell_quote(key_file) .. " >/dev/null 2>&1")
  end
  os.execute("chmod 600 " .. shell_quote(key_file) .. " 2>/dev/null")
  return shell("dropbearkey -y -f " .. shell_quote(key_file) ..
    " 2>/dev/null | awk '/^ssh-ed25519 / {print $1 \" \" $2; exit}'"):gsub("%s+$", "")
end

local function valid_ssh_assignment(response)
  local host = tostring(response.ssh_host or "")
  local user = tostring(response.ssh_user or "")
  local host_key = tostring(response.ssh_host_key or "")
  local ssh_port, remote_port = tonumber(response.ssh_port), tonumber(response.remote_port)
  return valid_endpoint(host) and user:match("^[a-z_][a-z0-9_%-]*$") and #user <= 32 and
    host_key:match("^ssh%-ed25519 [A-Za-z0-9+/]+=?=?$") and
    ssh_port and ssh_port >= 1 and ssh_port <= 65535 and
    remote_port and remote_port >= 20000 and remote_port <= 39999
end

local function save_ssh_assignment(response)
  if not valid_ssh_assignment(response) then return false end
  ensure_ssh_directories()
  local config_file = active_ssh_paths()
  local algorithm, key = tostring(response.ssh_host_key):match("^(ssh%-ed25519) ([A-Za-z0-9+/]+=?=?)$")
  local out = io.open(config_file .. ".tmp", "w")
  if not out then return false end
  out:write("ssh_host=" .. response.ssh_host .. "\n")
  out:write("ssh_port=" .. tostring(math.floor(tonumber(response.ssh_port))) .. "\n")
  out:write("ssh_user=" .. response.ssh_user .. "\n")
  out:write("remote_port=" .. tostring(math.floor(tonumber(response.remote_port))) .. "\n")
  out:write("host_key_algorithm=" .. algorithm .. "\n")
  out:write("host_key=" .. key .. "\n")
  out:close()
  os.execute("chmod 600 " .. shell_quote(config_file .. ".tmp") .. " 2>/dev/null")
  return os.rename(config_file .. ".tmp", config_file) ~= nil
end

local function enroll_ssh(base, bind, secret)
  local public = ssh_public_key()
  if not public:match("^ssh%-ed25519 [A-Za-z0-9+/]+=?=?$") then return false end
  local reply = signed_request(base, bind, secret, "remote_ssh_enroll", {
    "X-KemoFi-SSH-Public-Key: " .. public,
  })
  local ok, response = pcall(json.decode, reply)
  return ok and response and response.success == true and save_ssh_assignment(response)
end

local function ssh_tunnel_connected()
  -- procd may supervise the script while it waits for an assignment.
  -- BusyBox `ps` truncates command lines unless `w` is supplied.  Use the
  -- full-width form so the status heartbeat reflects the active relay.
  return shell([[ps w | awk '$0 ~ /[d]bclient .*reverse-ssh.key/ {print $1; exit}']]):gsub("%s+", "") ~= ""
end

local function ssh_assignment_valid()
  local values = {}
  local config_file, key_file = active_ssh_paths()
  if read_line(key_file) == "" then return false end
  local f = io.open(config_file, "r")
  if not f then return false end
  for line in f:lines() do
    local key, value = line:match("^([%w_]+)=(.*)$")
    if key then values[key] = trim_text(value) end
  end
  f:close()
  local ssh_port, remote_port = tonumber(values.ssh_port), tonumber(values.remote_port)
  return valid_endpoint(values.ssh_host) and values.ssh_user:match("^[a-z_][a-z0-9_%-]*$") and
    ssh_port and ssh_port >= 1 and ssh_port <= 65535 and
    remote_port and remote_port >= 20000 and remote_port <= 39999 and
    values.host_key_algorithm == "ssh-ed25519" and
    values.host_key:match("^[A-Za-z0-9+/]+=?=?$") ~= nil
end

local function saved_ssh_value(name)
  local config_file = active_ssh_paths()
  local f = io.open(config_file, "r")
  if not f then return "" end
  local value = ""
  for line in f:lines() do
    local key, candidate = line:match("^([A-Za-z0-9_]+)=(.*)$")
    if key == name then value = candidate; break end
  end
  f:close()
  return value
end

local function restart_ssh_relay()
  -- Restart only the relay process. The portal, WAN, customer sessions, and
  -- speed-control path continue running while procd respawns dbclient.
  for pid in shell("ps w | awk '$0 ~ /[d]bclient .*reverse-ssh.key/ {print $1}'"):gmatch("%d+") do
    os.execute("kill " .. pid .. " >/dev/null 2>&1")
  end
end

local function reconcile_ssh_assignment(raw)
  local ok, response = pcall(json.decode, raw or "")
  if not ok or type(response) ~= "table" or response.success ~= true or not response.remote_port then
    return false
  end
  local current_host_key = saved_ssh_value("host_key_algorithm") .. " " .. saved_ssh_value("host_key")
  local unchanged = saved_ssh_value("ssh_host") == tostring(response.ssh_host or "") and
    saved_ssh_value("ssh_port") == tostring(response.ssh_port or "") and
    saved_ssh_value("ssh_user") == tostring(response.ssh_user or "") and
    saved_ssh_value("remote_port") == tostring(response.remote_port or "") and
    current_host_key == tostring(response.ssh_host_key or "")
  if unchanged then return false end
  if save_ssh_assignment(response) then
    ssh_retry_delay, ssh_retry_after = IDLE_POLL_SECONDS, 0
    restart_ssh_relay()
    return true
  end
  return false
end

local function heartbeat_has_relay_assignment(raw)
  local ok, response = pcall(json.decode, raw or "")
  return ok and type(response) == "table" and response.success == true,
    ok and type(response) == "table" and response.success == true and response.remote_port ~= nil
end

local function retry_ssh_enrollment(base, bind, secret)
  if os.time() < ssh_retry_after then return false end
  if enroll_ssh(base, bind, secret) then
    ssh_retry_delay, ssh_retry_after = IDLE_POLL_SECONDS, 0
    return true
  end
  ssh_retry_after = os.time() + ssh_retry_delay
  ssh_retry_delay = math.min(SSH_RETRY_MAX, ssh_retry_delay * 2)
  return false
end

local function recovery_required(raw)
  local ok, response = pcall(json.decode, raw or "")
  return ok and type(response) == "table" and response.recovery_required == true
end

-- Map the vendor's /admin namespace to the local uhttpd admin instance.
-- Keep the trailing-slash form and static assets working: a browser that
-- receives /admin/ resolves app.js as /admin/app.js, while local uhttpd
-- serves that file from /. API calls still belong under /api/admin/.
local ADMIN_STATIC_ASSETS = {
  ["app.js"] = true,
  ["style.css"] = true,
  ["index.html"] = true,
  ["logo.png"] = true,
  ["kemofi-logo.webp"] = true,
  ["favicon.ico"] = true,
}

local function map_admin_path(path)
  if path == "/admin" or path == "/admin/" or path == "/admin/index.html" then
    return "/"
  end

  local asset = path:match("^/admin/([^/]+)$")
  if asset and ADMIN_STATIC_ASSETS[asset] then
    return "/" .. asset
  end

  if path:sub(1, 7) == "/admin/" then
    return "/api" .. path
  end
  return path
end

--- Execute an HTTP request against the local admin panel
local function execute_local_request(request)
  local method = (request.method or "GET"):upper()
  local full_path = request.path or "/"
  -- Separate path from query string for comparison
  local qmark = full_path:find("?", 1, true)
  local path = qmark and full_path:sub(1, qmark - 1) or full_path
  local query = qmark and full_path:sub(qmark) or ""
  -- The vendor platform sends paths prefixed with /admin.
  -- OpenWrt uhttpd admin instance (port 8080) layout:
  --   Static files served at root: / -> index.html, /app.js, /style.css
  --   Lua API handler at /api prefix: /api/admin/*, /api/portal/*
  -- So /admin and /admin/ both serve the panel, /admin/app.js serves the
  -- static asset, and /admin/system/ping becomes /api/admin/system/ping.
  path = map_admin_path(path)
  -- Reattach query string
  path = path .. query
  local headers = request.headers or {}
  local body_b64 = request.body or ""

  -- Decode base64 body if present
  local body = ""
  if body_b64 ~= "" then
    -- Use nixio for base64 decode
    local ok, decoded = pcall(nixio.bin.b64decode, body_b64)
    if ok and decoded then
      body = decoded
    else
      body = body_b64  -- fallback: use raw
    end
  end

  -- Build raw HTTP request
  local req_lines = {
    method .. " " .. path .. " HTTP/1.1",
    "Host: 127.0.0.1:" .. LOCAL_ADMIN_PORT,
    "Connection: close",
  }

  -- Forward headers (skip host/connection)
  for k, v in pairs(headers) do
    local lk = k:lower()
    if lk ~= "host" and lk ~= "connection" then
      table.insert(req_lines, k .. ": " .. v)
    end
  end

  if #body > 0 then
    table.insert(req_lines, "Content-Length: " .. #body)
  end

  table.insert(req_lines, "")
  table.insert(req_lines, body)

  local raw_request = table.concat(req_lines, "\r\n")

  -- Connect to local admin
  local client = socket.tcp()
  if not client then
    return { status = 502, headers = {}, body = "" }
  end

  client:settimeout(15)
  local ok, err = client:connect("127.0.0.1", LOCAL_ADMIN_PORT)
  if not ok then
    client:close()
    return { status = 502, headers = {}, body = "" }
  end

  client:send(raw_request)

  -- Read response
  local response_data = {}
  while true do
    local chunk, status, partial = client:receive(4096)
    if chunk then
      table.insert(response_data, chunk)
    else
      -- LuaSocket returns partial data in 3rd value on close/timeout
      if partial and #partial > 0 then
        table.insert(response_data, partial)
      end
      break
    end
  end
  client:close()

  local raw_response = table.concat(response_data)

  -- Parse HTTP response
  local header_end = raw_response:find("\r\n\r\n")
  if not header_end then
    return { status = 502, headers = {}, body = "" }
  end

  local header_section = raw_response:sub(1, header_end - 1)
  local resp_body = raw_response:sub(header_end + 4)

  -- Parse status line
  local status_code = 200
  local status_match = header_section:match("HTTP/%d%.%d (%d+)")
  if status_match then
    status_code = tonumber(status_match) or 200
  end

  -- Parse headers
  local resp_headers = {}
  for line in header_section:gmatch("[^\r\n]+") do
    local k, v = line:match("^([^:]+):%s*(.+)$")
    if k then
      resp_headers[k] = v
    end
  end

  -- Decode chunked transfer encoding if present
  local te = resp_headers["Transfer-Encoding"] or resp_headers["transfer-encoding"] or ""
  if te:lower():find("chunked") then
    local decoded_parts = {}
    local pos = 1
    while pos <= #resp_body do
      -- Read chunk size (hex) terminated by \r\n
      local line_end = resp_body:find("\r\n", pos, true)
      if not line_end then break end
      local size_hex = resp_body:sub(pos, line_end - 1):match("^%s*(%x+)")
      if not size_hex then break end
      local chunk_size = tonumber(size_hex, 16)
      if not chunk_size or chunk_size == 0 then break end  -- 0 = final chunk
      local chunk_start = line_end + 2
      local chunk_data = resp_body:sub(chunk_start, chunk_start + chunk_size - 1)
      table.insert(decoded_parts, chunk_data)
      pos = chunk_start + chunk_size + 2  -- skip trailing \r\n
    end
    resp_body = table.concat(decoded_parts)
    -- Remove Transfer-Encoding header and add Content-Length
    resp_headers["Transfer-Encoding"] = nil
    resp_headers["transfer-encoding"] = nil
    resp_headers["Content-Length"] = tostring(#resp_body)
  end

  -- Inline app.js into HTML responses to avoid a second round-trip.
  -- The remote tunnel processes one request at a time; if app.js is a separate
  -- request it may time out before the board polls again. Inlining keeps the
  -- combined payload well within the gzip+base64 budget (~41KB).
  local ct = resp_headers["Content-Type"] or resp_headers["content-type"] or ""
  if ct:find("text/html") and resp_body:find('src="app%.js') then
    local app_path = "/opt/kemofi/www/admin/app.js"
    local af = io.open(app_path, "r")
    if af then
      local app_js = af:read("*a")
      af:close()
      -- Replace <script src="app.js..."></script> with inline <script>...</script>
      -- Escape % in replacement string (special in Lua gsub)
      local safe_js = app_js:gsub('%%', '%%%%')
      resp_body = resp_body:gsub('<script src="app%.js[^"]*"></script>', '<script>' .. safe_js .. '</script>')
    end
  end

  -- Compress and base64 encode the response body.
  -- uclient-fetch has a ~64KB TLS POST limit, so we gzip large bodies
  -- before base64-encoding to keep the JSON payload small.
  local MAX_PAYLOAD_B64 = 60000  -- ~60KB max base64 payload for uclient-fetch
  local body_encoded = ""
  local compressed = false
  if #resp_body > 0 then
    -- Try gzip compression for bodies > 4KB
    if #resp_body > 4096 then
      local gz_ok, gz_data = pcall(function()
        local tmp_in = "/tmp/kemofi_gz_in"
        local tmp_out = "/tmp/kemofi_gz_out.gz"
        local fi = io.open(tmp_in, "wb")
        if not fi then error("cannot open tmp_in") end
        fi:write(resp_body)
        fi:close()
        os.execute("gzip -9 -c " .. tmp_in .. " > " .. tmp_out .. " 2>/dev/null")
        local fo = io.open(tmp_out, "rb")
        if not fo then os.remove(tmp_in); error("cannot open tmp_out") end
        local gz_bytes = fo:read("*a")
        fo:close()
        os.remove(tmp_in)
        os.remove(tmp_out)
        if not gz_bytes or #gz_bytes == 0 then error("gzip produced empty output") end
        return gz_bytes
      end)
      if gz_ok and gz_data and #gz_data > 0 and #gz_data < #resp_body then
        local ok_enc, encoded = pcall(nixio.bin.b64encode, gz_data)
        if ok_enc and encoded then
          body_encoded = encoded
          compressed = true
        end
      end
    end
    -- Fallback: no compression (small body or compression failed)
    if not compressed then
      local ok_enc, encoded = pcall(nixio.bin.b64encode, resp_body)
      if ok_enc and encoded then
        body_encoded = encoded
      end
    end
  end

  -- Safety: if payload is still too large for uclient-fetch, return 413
  if #body_encoded > MAX_PAYLOAD_B64 then
    log("Response too large (" .. #body_encoded .. " b64 bytes) for path: " .. path .. " — returning 413")
    return {
      status = 413,
      headers = { ["Content-Type"] = "text/plain" },
      body = nixio.bin.b64encode("Response too large for remote tunnel"),
      compressed = nil,
    }
  end

  return {
    status = status_code,
    headers = resp_headers,
    body = body_encoded,
    compressed = compressed or nil,  -- only set when true
  }
end

-- ─── Credentials ───────────────────────────────────────────────────────────────

local PORTAL_UPDATE_SCHEMA = "kemofi-portal-theme"
local PORTAL_UPDATE_MAX_PACKAGE_BYTES = 96 * 1024
local PORTAL_UPDATE_MAX_CSS_BYTES = 64 * 1024

local function portal_update_css_safe(css)
  if type(css) ~= "string" or #css > PORTAL_UPDATE_MAX_CSS_BYTES then return false end
  for i = 1, #css do
    local byte = css:byte(i)
    if byte < 9 or (byte > 13 and byte < 32) or byte == 127 then return false end
  end
  local lowered = css:lower()
  for _, token in ipairs({"<script", "</style", "@import", "expression(", "javascript:"}) do
    if lowered:find(token, 1, true) then return false end
  end
  local without_data_image = lowered:gsub('url%(%s*"data:image/webp;base64,[A-Za-z0-9+/=]+"%s*%)', "")
  if without_data_image:find("url%(") then return false end
  return true
end

local function portal_update_signature(update, secret)
  local canonical = table.concat({
    tostring(update.id or ""), "portal_update", tostring(update.package_hash or update.payload_hash or ""),
    tostring(update.idempotency_key or ""), tostring(update.expires_at or "")
  }, "|")
  return hmac_sha256(secret, canonical)
end

local function ack_portal_update(base, bind, secret, update_id, result, summary)
  return signed_request(base, bind, secret, "remote_portal_update_ack", {
    "X-KemoFi-Portal-Update-Id: " .. tostring(update_id or ""),
    "X-KemoFi-Portal-Update-Result: " .. tostring(result or "error"),
    "X-KemoFi-Portal-Update-Summary: " .. tostring(summary or ""):gsub("[^A-Za-z0-9 .,:;_/-]", ""),
  })
end

local function poll_portal_updates(base, bind, secret)
  if bind == "" or secret == "" then return 0 end
  local raw = signed_request(base, bind, secret, "remote_portal_update_poll", {})
  if not raw or raw == "" or recovery_required(raw) then return 0 end
  local ok, result = pcall(json.decode, raw)
  if not ok or type(result) ~= "table" or result.success == false then return 0 end

  local updates = result.updates or {}
  local applied = 0
  for _, update in ipairs(updates) do
    local update_id = tostring(update.id or "")
    local package_json = update.package_json
    local package_hash = tostring(update.package_hash or update.payload_hash or "")
    local signature = tostring(update.signature or "")
    local valid_envelope = update_id:match("^[A-Za-z0-9_-]+$") and #update_id >= 16 and #update_id <= 128
      and type(package_json) == "string" and #package_json <= PORTAL_UPDATE_MAX_PACKAGE_BYTES
      and #package_hash == 64 and package_hash:match("^[a-fA-F0-9]+$") ~= nil
      and tostring(update.idempotency_key or ""):match("^[A-Za-z0-9._:-]+$")
      and tostring(update.expires_at or "") ~= ""
      and signature == portal_update_signature(update, secret)
    if valid_envelope and sha256(package_json) == package_hash then
      local package_ok, package = pcall(json.decode, package_json)
      local package_valid = package_ok and type(package) == "table"
        and package.schema == PORTAL_UPDATE_SCHEMA
        and (package.schemaVersion == 1 or package.schemaVersion == 2)
        and ((package.restore_defaults == true and #package_json < 1024)
          or (portal_update_css_safe(package.css)
            and (type(package.settings) == "table" or package.settings == nil)))
      if package_valid then
        local encoded_ok, encoded = pcall(nixio.bin.b64encode, package_json)
        if encoded_ok and encoded then
          local response = execute_local_request({
            method = "POST",
            path = "/admin/portal/update",
            headers = {
              ["Content-Type"] = "application/json",
              ["X-Remote-Access"] = "true",
            },
            body = encoded,
          })
          local status = tonumber(response.status or 502) or 502
          local result_name = status >= 200 and status < 300 and "ok" or "error"
          ack_portal_update(base, bind, secret, update_id, result_name, "HTTP " .. tostring(status))
          if result_name == "ok" then applied = applied + 1 end
        else
          ack_portal_update(base, bind, secret, update_id, "error", "Portal package encoding failed")
        end
      else
        ack_portal_update(base, bind, secret, update_id, "error", "Portal package validation failed")
      end
    end
  end
  return applied
end
local function get_credentials()
  local vendor = require("lib.vendor")
  local license_key = db.setting("license_key") or ""
  local device_id = vendor.get_device_id() or ""
  local version = vendor.get_version()
  local hostname = vendor.get_hostname()
  return {
    license_id = license_key,
    instance_device_id = device_id,
    bind_code = vendor.get_bind_code(),
    version = version,
    hostname = hostname,
  }
end

local function remote_enabled()
  return firmware_edition() == "remote" and
    (db.setting("license_status") or "") == "active" and
    (db.setting("license_key") or "") ~= ""
end

-- A clean flash intentionally starts with a new runtime database. Recover an
-- already-bound paid license before the worker goes idle so Remote enrollment
-- does not depend on an operator opening the License page or waiting for the
-- timer's periodic validation. This path never requests a trial license.
local function bootstrap_remote_activation()
  if firmware_edition() ~= "remote" or remote_enabled() then return remote_enabled() end

  local loaded, vendor = pcall(require, "lib.vendor")
  if not loaded or type(vendor) ~= "table" then
    log("Remote license bootstrap unavailable")
    return false
  end

  local license_key = trim_text(tostring(db.setting("license_key") or ""))
  local ok, result
  if license_key == "" then
    -- Recovery is hardware-bound and safe to retry after a clean flash.
    local device_id = vendor.get_device_id and vendor.get_device_id() or nil
    if not device_id or device_id == "" then
      log("Remote license bootstrap waiting for device identity")
      return false
    end
    ok, result = pcall(vendor.recover_license, device_id)
  else
    -- A configured key may only need validation after the image is replaced.
    ok, result = pcall(vendor.phone_home)
  end

  if not ok then
    log("Remote license bootstrap failed")
    return false
  end
  log("Remote license bootstrap: " .. tostring(result))
  return remote_enabled()
end

-- ─── Lock ──────────────────────────────────────────────────────────────────────

local function try_worker_lock()
  os.execute("mkdir -p /tmp/kemofi")
  local lock, open_err = nixio.open(LOCK_PATH, "w", "0600")
  if not lock then return nil, open_err or "cannot open remote lock" end
  local locked, lock_err = lock:lock("tlock")
  if not locked then
    lock:close()
    return nil, lock_err or "remote lock is held"
  end
  return lock
end

-- ─── Main Loop ─────────────────────────────────────────────────────────────────

function M.main()
  log("Starting remote management worker")

  -- Wait for DB to be ready
  local retries = 0
  while retries < 30 do
    local ok = pcall(function() db.init() end)
    if ok then break end
    retries = retries + 1
    safe_sleep(2)
  end

  -- Acquire lock
  local lock, lock_err = try_worker_lock()
  local backoff = IDLE_POLL_SECONDS
  local consecutive_errors = 0
  local last_watchdog = 0

  local function maybe_feed_watchdog()
    local now = os.time()
    if now - last_watchdog >= WATCHDOG_INTERVAL then
      feed_watchdog()
      last_watchdog = now
    end
  end

  local function worker_sleep(seconds)
    local remaining = math.max(0, tonumber(seconds) or 0)
    repeat
      local chunk = math.min(remaining, WATCHDOG_INTERVAL)
      safe_sleep(chunk)
      maybe_feed_watchdog()
      remaining = remaining - chunk
    until remaining <= 0
  end

  if not lock then
    log("Cannot acquire lock: " .. tostring(lock_err) .. " — another instance running?")
    -- Wait and retry
    repeat
      maybe_feed_watchdog()
      worker_sleep(IDLE_POLL_SECONDS)
      lock, lock_err = try_worker_lock()
    until lock
    log("Lock acquired after wait")
  end

  -- Trial/unlicensed routers keep the supervised worker quiet until full
  -- activation, without polling the tunnel. A paid license that was already
  -- bound to this hardware is recovered automatically on a clean flash.
  if not remote_enabled() then
    log("Remote tunnel waiting for automatic license recovery")
    while not remote_enabled() do
      maybe_feed_watchdog()
      bootstrap_remote_activation()
      if not remote_enabled() then worker_sleep(UNLICENSED_INTERVAL) end
    end
    log("Active license detected, starting polling")
  end

  -- Main polling loop
  while true do
    -- Feed procd watchdog to prevent being killed
    maybe_feed_watchdog()
    local creds = get_credentials()

    -- Skip unless this board has a full active license.
    if not remote_enabled() or (creds.license_id or "") == "" then
      worker_sleep(UNLICENSED_INTERVAL)
    else
      -- Poll for pending work using signed /router-api/remote/ack/<bind_code>
      local base   = read_base()
      local bind   = trim_text(tostring(creds.bind_code or ""))
      local secret = read_secret()

      local should_poll = true
      if bind == "" or secret == "" then
        -- Not yet enrolled — attempt enrollment with the license key
        local license_key = trim_text(tostring(creds.license_id or ""))
        if license_key ~= "" and enroll(base, bind ~= "" and bind or license_key, license_key) then
          log("Remote agent enrolled successfully")
          secret = read_secret()
        else
          worker_sleep(UNLICENSED_INTERVAL)
          should_poll = false
        end
      end

      if should_poll then
        -- Enroll the lightweight outbound relay independently of polling.
        -- A relay failure only affects remote administration; local portal,
        -- customer traffic, and the normal WAN route continue unchanged.
        -- A complete local assignment is not enough by itself: the VPS is
        -- authoritative and may have lost or changed the tunnel after a
        -- restore. Retry enrollment without touching the portal or WAN.
        if not ssh_assignment_valid() then retry_ssh_enrollment(base, bind, secret) end

        local ssh_connected = ssh_tunnel_connected()

        local heartbeat = signed_request(base, bind, secret, "remote_heartbeat", {
          "X-KemoFi-Firmware-Version: " .. firmware_version(),
          "X-KemoFi-Router-Model: " .. read_line("/tmp/sysinfo/model"),
          "X-KemoFi-SSH-Connected: " .. (ssh_connected and "1" or "0"),
        })
        if recovery_required(heartbeat) then
          os.remove(SECRET_FILE)
          os.remove(LEGACY_SECRET_FILE)
          if enroll(base, bind, tostring(creds.license_id or "")) then
            secret = read_secret()
          end
        end

        -- Reconcile a changed host, port, user, or pinned key and restart
        -- only the dbclient relay. A successful heartbeat without an
        -- assignment repairs a missing VPS tunnel row idempotently.
        reconcile_ssh_assignment(heartbeat)
        local heartbeat_ok, relay_assigned = heartbeat_has_relay_assignment(heartbeat)
        if heartbeat_ok and not relay_assigned then retry_ssh_enrollment(base, bind, secret) end

        -- Portal themes use their own signed delivery ledger. A failed
        -- portal update never changes the existing admin command/relay loop.
        local portal_updates_applied = poll_portal_updates(base, bind, secret)

        local raw = signed_request(base, bind, secret, "remote_ack", {})
        local result, parse_err = nil, nil
        if raw and raw ~= "" then
          local ok_parse, decoded = pcall(json.decode, raw)
          if ok_parse and type(decoded) == "table" then
            result = decoded
          else
            parse_err = "invalid JSON"
          end
        else
          parse_err = "empty response"
        end

        if result and result.success ~= false and not result.error then
          consecutive_errors = 0
          backoff = IDLE_POLL_SECONDS

          local requests = result.requests or {}
          if #requests > 0 or portal_updates_applied > 0 then
            log("Received " .. #requests .. " pending request(s)")

            -- Send ack for each completed command via signed request
            for _, req in ipairs(requests) do
              local resp = execute_local_request(req)
              resp.id  = req.id
              resp.type = "http_response"
              local result_str = tostring(resp.status or 200):sub(1, 1) == "2" and "ok" or "error"
              signed_request(base, bind, secret, "remote_ack", {
                "X-KemoFi-Command-Id: " .. tostring(req.id or ""),
                "X-KemoFi-Command-Result: " .. result_str,
                "X-KemoFi-Command-Summary: HTTP " .. tostring(resp.status or 200),
              })
            end
            log("Acked " .. #requests .. " request(s)")
            worker_sleep(ACTIVE_POLL_SECONDS)
          else
            worker_sleep(portal_updates_applied > 0 and ACTIVE_POLL_SECONDS or IDLE_POLL_SECONDS)
          end
        else
          consecutive_errors = consecutive_errors + 1
          if consecutive_errors <= 3 then
            log("Poll failed: " .. tostring(parse_err) .. " (attempt " .. consecutive_errors .. ")")
          elseif consecutive_errors == 4 then
            log("Poll failing repeatedly, suppressing further logs until recovery")
          end
          backoff = math.min(backoff * 2, MAX_BACKOFF)
          worker_sleep(backoff)
        end
      end
    end
  end

  -- Cleanup (unreachable in normal operation)
  lock:lock("ulock")
  lock:close()
end

M.main_loop = M.main

-- Run if executed directly (not required as module)
if ... ~= "lib.remote" then
  local ok, err = pcall(M.main)
  if not ok then
    log("Remote worker stopped: " .. tostring(err))
    os.exit(1)
  end
end

return M
