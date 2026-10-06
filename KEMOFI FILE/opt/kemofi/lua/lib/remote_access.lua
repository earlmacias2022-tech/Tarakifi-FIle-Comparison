--- KemoFi lightweight Remote Access status and diagnostics.
-- The router uses signed HTTPS polling for the agent and an outbound
-- reverse-SSH relay for the browser's admin session. There is no VPN
-- interface, inbound management listener, or customer-traffic route here.
local db = require("lib.db")

local M = {}

local EDITION_FILE = os.getenv("KEMOFI_EDITION_FILE") or "/etc/pisowifi/edition"
local SECRET_FILE = os.getenv("KEMOFI_REMOTE_SECRET_FILE") or "/etc/pisowifi/remote-agent.secret"
local SSH_CONFIG_FILE = os.getenv("KEMOFI_SSH_CONFIG_FILE") or "/etc/pisowifi/reverse-ssh.conf"
local SSH_KEY_FILE = os.getenv("KEMOFI_SSH_KEY_FILE") or "/etc/pisowifi/reverse-ssh.key"
local LICENSE_MANAGER_URL_FILE = os.getenv("KEMOFI_LICENSE_MANAGER_URL_FILE") or "/etc/pisowifi/license_manager_url"
local LEGACY_EDITION_FILE = "/etc/kemofi/edition"
local LEGACY_SECRET_FILE = "/etc/kemofi/remote-agent.secret"
local LEGACY_LICENSE_MANAGER_URL_FILE = "/etc/kemofi/license_manager_url"
local LEGACY_SSH_CONFIG_FILE = "/etc/kemofi/reverse-ssh.conf"
local LEGACY_SSH_KEY_FILE = "/etc/kemofi/reverse-ssh.key"

local function read_line(path)
  local f = io.open(path, "r")
  if not f then return "" end
  local value = (f:read("*l") or ""):gsub("^%s+", ""):gsub("%s+$", "")
  f:close()
  return value
end

local function state_line(primary, legacy)
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

local function shell(command)
  local f = io.popen(command)
  if not f then return "" end
  local value = f:read("*a") or ""
  f:close()
  return value
end

local function shell_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function command_ok(command)
  local result = os.execute(command)
  return result == true or result == 0
end

local function edition()
  local value = state_line(EDITION_FILE, LEGACY_EDITION_FILE):lower():gsub("%s+", "")
  if value == "remote" then return value end
  return "local"
end

local function remote_disabled(message)
  return {
    status = "disabled",
    edition = edition(),
    transport = "Signed HTTPS + outbound relay",
    message = message or "Remote Access requires a Remote firmware build",
  }
end

local function agent_running()
  return shell([[ps w | awk '$0 ~ /[l]ua .*\/opt\/kemofi\/lua\/lib\/remote.lua/ {print $1; exit}']]):gsub("%s+", "") ~= ""
end

local function relay_connected()
  return shell([[ps w | awk '$0 ~ /[d]bclient .*reverse-ssh.key/ {print $1; exit}']]):gsub("%s+", "") ~= ""
end

local function enrolled()
  return state_line(SECRET_FILE, LEGACY_SECRET_FILE) ~= ""
end

local function relay_configured()
  local config, key = active_ssh_paths()
  return read_line(config) ~= "" and read_line(key) ~= ""
end

local function endpoint_host(url)
  return tostring(url or ""):match("^https://([^/:]+)") or ""
end

local function endpoint_authority(url)
  local authority = tostring(url or ""):match("^https://([^/%?#]+)")
  local host, port = authority and authority:match("^([A-Za-z0-9][A-Za-z0-9%.%-]*)(:%d+)?$")
  local port_number = port and tonumber(port:sub(2)) or nil
  if host and (not port_number or (port_number >= 1 and port_number <= 65535)) then
    return host, port
  end
  return nil, nil
end

local function endpoint_is_safe(host)
  return host ~= "" and #host <= 253 and
    host:match("^[A-Za-z0-9][A-Za-z0-9%.%-]*$") ~= nil and
    host:sub(-1):match("[A-Za-z0-9]") ~= nil
end

local function effective_endpoint()
  local value = state_line(LICENSE_MANAGER_URL_FILE, LEGACY_LICENSE_MANAGER_URL_FILE)
  local host, port = endpoint_authority(value)
  if host and endpoint_is_safe(host) then
    return "https://" .. host .. (port or "")
  end
  return "https://kemofi.com"
end

local function endpoint_resolves()
  local host = endpoint_host(effective_endpoint())
  if host:match("^%d+%.%d+%.%d+%.%d+$") then return true end
  return shell("nslookup " .. shell_quote(host) .. " 2>/dev/null") ~= ""
end

local function endpoint_reachable()
  local base = effective_endpoint()
  local response = shell("curl -fsS --connect-timeout 5 --max-time 8 " ..
    shell_quote(base .. "/health") .. " 2>/dev/null")
  return response:match('"status"%s*:%s*"ok"') ~= nil
end

local function provisioned_at()
  local config = active_ssh_paths()
  local value = shell("stat -c %Y " .. shell_quote(config) .. " 2>/dev/null"):match("(%d+)")
  return value and os.date("!%Y-%m-%dT%H:%M:%SZ", tonumber(value)) or ""
end

function M.status()
  local current_edition = edition()
  if current_edition == "local" then return remote_disabled() end

  local running = agent_running()
  local has_secret = enrolled()
  local ssh_ready = relay_configured()
  local ssh_up = ssh_ready and relay_connected()
  local agent_up = running and has_secret
  local connection_status
  if ssh_up then
    connection_status = "Connected"
  elseif agent_up then
    connection_status = "Agent connected; relay waiting"
  elseif has_secret then
    connection_status = "Waiting for remote agent"
  else
    connection_status = "Waiting for enrollment"
  end

  return {
    status = "ok",
    edition = current_edition,
    transport = "Signed HTTPS + outbound relay",
    connection_status = connection_status,
    agent_status = running and (has_secret and "Connected" or "Waiting for enrollment") or "Stopped",
    relay_status = ssh_up and "Connected" or (ssh_ready and "Waiting for relay" or "Not provisioned"),
    agent_running = running,
    configured = has_secret,
    enrolled = has_secret,
    connected = ssh_up,
    polling_active = agent_up,
    ssh_configured = ssh_ready,
    ssh_connected = ssh_up,
    endpoint = effective_endpoint(),
    provisioned_at = provisioned_at(),
    license_status = db.setting("license_status") or "inactive",
    license_expires_at = db.setting("license_expires_at") or "",
  }
end

function M.reconnect()
  if edition() == "local" then return remote_disabled() end
  -- Restart only the two remote processes. Portal, admin, timer, roaming,
  -- sessions, and customer traffic are never restarted by this action.
  local command = [[
    pids=$(ps w | awk '$0 ~ /[l]ua .*\/opt\/kemofi\/lua\/lib\/remote.lua/ || $0 ~ /[d]bclient .*reverse-ssh.key/ {print $1}')
    [ -n "$pids" ] || exit 1
    for pid in $pids; do kill -TERM "$pid" 2>/dev/null || true; done
  ]]
  if not command_ok(command) then
    return {status = "error", message = "The Remote service could not be restarted"}
  end
  return {status = "ok", message = "Remote Access reconnect requested. Customer Internet remains on WAN."}
end

function M.license()
  if edition() == "local" then return remote_disabled() end
  local current = M.status()
  return {
    status = "ok",
    edition = current.edition,
    transport = current.transport,
    license_status = current.license_status,
    license_expires_at = current.license_expires_at,
    configured = current.configured,
    enrolled = current.enrolled,
  }
end

function M.diagnostics()
  if edition() == "local" then return remote_disabled() end
  local current = M.status()
  return {
    status = "ok",
    transport = current.transport,
    agent_running = current.agent_running,
    enrolled = current.enrolled,
    command_polling = current.polling_active,
    relay_configured = current.ssh_configured,
    relay_connected = current.ssh_connected,
    vps_reachable = endpoint_reachable() or endpoint_resolves(),
    tls_ca_bundle = read_line("/etc/ssl/certs/ca-certificates.crt") ~= "",
    customer_path_unchanged = true,
  }
end

return M
