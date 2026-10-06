--- TarakiFi Main HTTP Handler
-- This is the uhttpd Lua handler entry point.
-- Routes requests to the appropriate module.
--
-- uhttpd config: option lua_prefix '/api'
--                option lua_handler '/opt/tarakifi/lua/handler.lua'

-- Add our lib path
package.path = "/opt/tarakifi/lua/?.lua;/opt/tarakifi/lua/lib/?.lua;" .. package.path

local db = require("lib.db")
local json = require("lib.json")
local portal = require("lib.portal")
local session = require("lib.session")
local admin = require("lib.admin")
local coin = require("lib.coin")
local clients = require("lib.clients")
local multipart = require("lib.multipart")
local vendor = require("lib.vendor")

-- Initialize database on first request
local initialized = false
local function ensure_init()
  if not initialized then
    db.init()
    initialized = true
  end
end

local function send_health()
  local body = '{"status":"ok","service":"tarakifi"}'
  uhttpd.send("Status: 200 OK\r\n")
  uhttpd.send("Content-Type: application/json\r\n")
  uhttpd.send("Cache-Control: no-store\r\n")
  uhttpd.send("Content-Length: " .. #body .. "\r\n\r\n")
  uhttpd.send(body)
end

--- Parse request body (JSON or multipart)
local function parse_body(env)
  local len = tonumber(env.CONTENT_LENGTH) or 0
  if len == 0 then return {} end
  
  local _, body = uhttpd.recv(len)
  if not body or body == "" then return {} end
  
  -- Check if multipart/form-data
  local ct = env.CONTENT_TYPE or ""
  if ct:find("multipart/form%-data") then
    local boundary = multipart.get_boundary(ct)
    if boundary then
      return multipart.parse(body, boundary)
    end
  end
  
  local ok, data = pcall(json.decode, body)
  if ok and type(data) == "table" then return data end
  return {}
end

--- Parse query string
local function parse_query(qs)
  local params = {}
  if not qs then return params end
  for key, val in qs:gmatch("([^&=]+)=([^&]*)") do
    params[key] = val
  end
  return params
end

--- Build environment context
local function build_env(env)
  local client_ip = env.REMOTE_ADDR
  -- uhttpd passes all request headers in env.headers table with lowercase keys
  local h = (type(env.headers) == "table") and env.headers or {}
  return {
    method = env.REQUEST_METHOD,
    path = env.PATH_INFO or env.REQUEST_URI or "/",
    query = parse_query(env.QUERY_STRING),
    client_ip = client_ip,
    client_mac = clients.mac_for_ip(client_ip),
    headers = {
      ["content-type"] = h["content-type"] or env.CONTENT_TYPE,
      ["cookie"] = h["cookie"] or env.HTTP_COOKIE,
      ["host"] = h["host"] or env.HTTP_HOST,
      ["x-remote-access"] = h["x-remote-access"] or env.HTTP_X_REMOTE_ACCESS,
      ["x-tarakifi-node"] = h["x-tarakifi-node"] or env.HTTP_X_TARAKIFI_NODE,
      ["x-tarakifi-token"] = h["x-tarakifi-token"] or env.HTTP_X_TARAKIFI_TOKEN,
      ["x-tarakifi-firmware-name"] =
        h["x-tarakifi-firmware-name"] or env.HTTP_X_TARAKIFI_FIRMWARE_NAME,
    }
  }
end

--- Route table
local routes = {
  -- Portal API
  ["GET /portal/status"] = portal.status,
  ["GET /portal/rates"] = portal.rates,
  ["POST /portal/insert-coin"] = portal.insert_coin,
  ["POST /portal/finish-coin"] = portal.finish_coin,
  ["POST /portal/cancel-insert"] = portal.cancel_insert,
  ["POST /portal/pause"] = portal.pause,
  ["POST /portal/resume"] = portal.resume,
  ["GET /portal/coin-status"] = portal.coin_status,
  ["POST /portal/free-time"] = portal.free_time,
  ["POST /portal/redeem-voucher"] = portal.redeem_voucher,
  
  -- Coin API (from ESP)
  ["POST /coin/register"]   = coin.handle_register,
  ["POST /coin/event"]      = coin.handle_event,
  ["POST /coin/heartbeat"]  = coin.handle_heartbeat,
  ["GET /coin/waiting"]     = coin.get_waiting,
  ["POST /coin/events"]     = coin.handle_event,
  
  -- Admin API
  ["POST /admin/login"] = admin.login,
  ["POST /admin/forgot-password"] = admin.forgot_password,
  ["POST /admin/logout"] = admin.logout,
  ["GET /admin/dashboard"] = admin.dashboard,
  ["POST /admin/earnings/reset"] = admin.reset_earnings,
  ["GET /admin/sessions"] = admin.sessions,
  ["POST /admin/sessions/kick"] = admin.kick_session,
  ["POST /admin/sessions/set-name"] = admin.set_name,
  ["POST /admin/sessions/edit-time"] = admin.edit_time,
  ["POST /admin/sessions/block"] = admin.block_device,
  ["POST /admin/sessions/unblock"] = admin.unblock_device,
  ["POST /admin/sessions/reset"] = admin.reset_device,
  ["POST /admin/sessions/forget"] = admin.forget_device,
  ["POST /admin/sessions/clear-expired"] = admin.clear_expired_sessions,
  ["POST /admin/sessions/forget-stale"] = admin.forget_stale_devices,
  ["GET /admin/settings"] = admin.get_settings,
  ["POST /admin/settings"] = admin.save_settings,
  ["GET /admin/cloud-backup/status"] = admin.cloud_backup_status,
  ["POST /admin/cloud-backup/settings"] = admin.cloud_backup_settings,
  ["POST /admin/cloud-backup/backup"] = admin.cloud_backup_now,
  ["POST /admin/cloud-backup/restore"] = admin.cloud_restore_now,
  ["GET /admin/backup"] = admin.backup,
  ["POST /admin/restore"] = admin.restore,
  ["GET /admin/rates"] = admin.get_rates,
  ["POST /admin/rates"] = admin.save_rates,
  ["GET /admin/devices"] = admin.devices,
  ["POST /admin/system/reboot"] = admin.reboot,
  ["POST /admin/system/shutdown"] = admin.shutdown,
  ["GET /admin/system/info"] = admin.system_info,
  ["GET /admin/system/ping"] = admin.ping,
  ["GET /admin/system/wifi"] = admin.get_wifi_config,
  ["POST /admin/system/wifi"] = admin.save_wifi_config,
  ["GET /admin/system/wan"] = admin.get_wan_config,
  ["POST /admin/system/wan"] = admin.save_wan_config,
  ["GET /admin/system/wan-access"] = admin.get_wan_access,
  ["POST /admin/system/wan-access"] = admin.save_wan_access,
  ["GET /admin/reboot-schedule"] = admin.get_reboot_schedule,
  ["POST /admin/reboot-schedule"] = admin.save_reboot_schedule,
  ["POST /admin/password"]              = admin.change_password,
  ["GET /admin/coin-nodes"]             = admin.list_coin_nodes,
  ["POST /admin/coin-nodes/rename"]     = admin.rename_coin_node,
  ["POST /admin/coin-nodes/setup"]      = admin.request_coin_node_setup,
  ["POST /admin/coin-nodes/delete"]     = admin.delete_coin_node,
  ["POST /admin/coin-nodes/set-static-ip"] = admin.set_coin_node_static_ip,
  ["POST /admin/coin-nodes/generate-bind"] = admin.generate_bind_code,

  -- OTA Firmware Update
  ["GET /admin/system/check-update"] = admin.check_update,
  ["POST /admin/system/update"] = admin.system_update,
  ["POST /admin/system/manual-update"] = admin.manual_update,
  ["POST /admin/system/manual-update/chunk"] = admin.manual_update_chunk,

  -- File uploads
  ["POST /admin/upload"] = admin.upload_asset,
  ["POST /admin/upload/delete"] = admin.delete_asset,

  -- License
  ["POST /admin/activate-license"] = admin.activate_license,

  -- Vouchers
  ["GET /admin/vouchers"]           = admin.list_vouchers,
  ["POST /admin/vouchers/generate"] = admin.generate_vouchers,
  ["POST /admin/vouchers/delete"]   = admin.delete_voucher,
}

--- Check if a MAC is in the nftables allowed_macs set
local function is_mac_allowed(mac)
  if not mac then return false end
  local h = io.popen("nft list set inet tarakifi allowed_macs 2>/dev/null")
  local out = h:read("*a")
  h:close()
  return out:lower():find(mac:lower()) ~= nil
end

local function trace_apple_cna_identity(ctx)
  local cookie = tostring((ctx.headers and ctx.headers["cookie"]) or "")
  local has_token = cookie:find("tarakifi_token=", 1, true) ~= nil
  local has_fp = cookie:find("tarakifi_fp=", 1, true) ~= nil
  io.stderr:write(string.format(
    "tarakifi-cna: apple-root mac=%s token-cookie=%s fp-cookie=%s\n",
    tostring(ctx.client_mac or "unknown"),
    has_token and "yes" or "no",
    has_fp and "yes" or "no"
  ))
end

local function restore_apple_access(mac)
  if not vendor.customer_access_allowed() then return false end
  if is_mac_allowed(mac) then return true end
  local restored, status = session.rebind_known_alias(mac)
  if not restored or not status or not status.connected then return false end
  return is_mac_allowed(mac)
end

--- Captive portal detection handler
-- Returns proper responses for OS captive portal probes.
-- Unconnected: 302 redirect to portal. Connected: success response.
local function captive_probe(ctx, params, probe_type)
  local mac = ctx.client_mac
  local access_allowed = vendor.customer_access_allowed()
  local connected = access_allowed and is_mac_allowed(mac)
  if access_allowed and not connected and probe_type == "apple" then
    connected = restore_apple_access(mac)
  end
  if connected then
    -- Device has internet access — tell OS everything is fine
    if probe_type == "apple" then
      -- Apple expects exactly this body with 200
      uhttpd.send("Status: 200 OK\r\n")
      uhttpd.send("Content-Type: text/html\r\n")
      uhttpd.send("Cache-Control: no-store\r\n\r\n")
      uhttpd.send("<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>")
    elseif probe_type == "android" then
      -- Android expects 204 No Content
      uhttpd.send("Status: 204 No Content\r\n")
      uhttpd.send("Cache-Control: no-store\r\n\r\n")
    else
      -- Windows NCSI expects 200 with body "Microsoft Connect Test"
      uhttpd.send("Status: 200 OK\r\n")
      uhttpd.send("Content-Type: text/plain\r\n")
      uhttpd.send("Cache-Control: no-store\r\n\r\n")
      uhttpd.send("Microsoft Connect Test")
    end
  else
    -- Device not connected — redirect to portal.
    -- Use port 80 (not :8888) so the OS captive portal popup opens automatically.
    -- nftables rule "ip daddr 10.0.0.1 tcp dport 80 redirect to :8888" handles
    -- the transparent forwarding to the portal uhttpd instance.
    uhttpd.send("Status: 302 Found\r\n")
    local cna = probe_type == "apple" and "?cna=apple"
      or probe_type == "android" and "?cna=android"
      or "?cna=windows"
    uhttpd.send("Location: http://10.0.0.1/" .. cna .. "\r\n")
    uhttpd.send("Cache-Control: no-store\r\n\r\n")
  end
  return nil  -- signal that response already sent
end

--- Serve a static file from the portal www directory
local PORTAL_WWW = "/opt/tarakifi/www/portal"
local MIME_TYPES = {
  html = "text/html; charset=utf-8",
  css  = "text/css",
  js   = "application/javascript",
  png  = "image/png",
  jpg  = "image/jpeg",
  jpeg = "image/jpeg",
  gif  = "image/gif",
  ico  = "image/x-icon",
  svg  = "image/svg+xml",
  webp = "image/webp",
  woff = "font/woff",
  woff2= "font/woff2",
  txt  = "text/plain",
  mp3  = "audio/mpeg",
  wav  = "audio/wav",
  ogg  = "audio/ogg",
}
local function serve_static(path)
  -- Only allow safe paths (no .., no absolute)
  if path:find("..", 1, true) then
    uhttpd.send("Status: 403 Forbidden\r\n\r\n")
    return
  end
  local filepath = PORTAL_WWW .. path
  local f = io.open(filepath, "rb")
  if not f then
    uhttpd.send("Status: 404 Not Found\r\n\r\n")
    return
  end
  local data = f:read("*a")
  f:close()
  local ext = path:match("%.([^.]+)$") or "html"
  local mime = MIME_TYPES[ext] or "application/octet-stream"
  uhttpd.send("Status: 200 OK\r\n")
  uhttpd.send("Content-Type: " .. mime .. "\r\n")
  uhttpd.send("Content-Length: " .. #data .. "\r\n")
  uhttpd.send("Cache-Control: no-cache\r\n\r\n")
  uhttpd.send(data)
end

local DYNAMIC_GET_PATHS = {
  ["/hotspot-detect.html"] = true,
  ["/library/test/success.html"] = true,
  ["/bag/bag.html"] = true,
  ["/hotspotdetect.html"] = true,
  ["/generate_204"] = true,
  ["/gen_204"] = true,
  ["/connecttest.txt"] = true,
  ["/ncsi.txt"] = true,
  ["/redirect"] = true,
}

local RAW_UPLOAD_ROUTES = {
  ["POST /admin/system/manual-update"] = true,
  ["POST /admin/system/manual-update/chunk"] = true,
}

local function is_api_path(path)
  path = tostring(path or ""):match("^[^?]+") or ""
  return path == "/api" or path:sub(1, 5) == "/api/"
end

local function is_fast_static_request(env, request_path)
  if env.REQUEST_METHOD ~= "GET" then return false end
  -- With uhttpd's `-l /api`, PATH_INFO is stripped to `/admin/...` while
  -- REQUEST_URI and SCRIPT_NAME retain the API mount. Check all forms so
  -- admin GET endpoints never fall through to the portal static-file path.
  if is_api_path(request_path)
      or is_api_path(env.REQUEST_URI)
      or is_api_path(env.SCRIPT_NAME) then
    return false
  end
  if DYNAMIC_GET_PATHS[request_path] then return false end
  local query = tostring(env.QUERY_STRING or "")
  if request_path == "/" and ("&" .. query):find("&cna=", 1, true) then return false end
  return true
end

--- Main handler function (called by uhttpd)
function handle_request(env)
  local request_path = env.PATH_INFO or env.REQUEST_URI or "/"
  request_path = request_path:match("^[^?]+") or request_path
  if env.REQUEST_METHOD == "GET"
      and (request_path == "/healthz" or request_path == "/api/healthz") then
    send_health()
    return
  end

  -- Static requests bypass database initialization and client discovery. CNA
  -- probes and API calls retain the existing dynamic behavior below.
  if is_fast_static_request(env, request_path) then
    if request_path == "/" or request_path == "" or request_path == "/index.html" then
      serve_static("/index.html")
    else
      serve_static(request_path)
    end
    return
  end

  ensure_init()

  local ctx = build_env(env)

  if ctx.path == "/" and ctx.query and ctx.query.cna == "apple" then
    trace_apple_cna_identity(ctx)
    if restore_apple_access(ctx.client_mac) then
      captive_probe(ctx, {}, "apple")
      return
    end
  end

  -- Handle captive portal detection probes BEFORE normal routing
  -- These paths are served as static files by uhttpd but we need to intercept them
  local path = ctx.path
  -- Apple captive portal probes
  if path == "/hotspot-detect.html" or path == "/library/test/success.html"
    or path == "/bag/bag.html" or path == "/hotspotdetect.html" then
    captive_probe(ctx, {}, "apple")
    return
  end
  -- Android / Google captive portal probes
  if path == "/generate_204" or path == "/gen_204"
    or path == "/connecttest.txt" then
    captive_probe(ctx, {}, "android")
    return
  end
  -- Windows NCSI
  if path == "/ncsi.txt" or path == "/redirect" then
    captive_probe(ctx, {}, "windows")
    return
  end

  -- Strip /api prefix if present (when running with lua_prefix=/ instead of /api)
  local route_path = ctx.path
  if route_path:sub(1, 4) == "/api" then
    route_path = route_path:sub(5)  -- strip /api, keep rest (e.g. /portal/status)
    if route_path == "" then route_path = "/" end
  end

  local route_key = ctx.method .. " " .. route_path
  local handler = routes[route_key]
  
  if not handler then
    -- Serve portal root and static assets (when lua_prefix is /)
    if ctx.method == "GET" then
      local spath = ctx.path
      if spath == "/" or spath == "" or spath == "/index.html" then
        serve_static("/index.html")
      else
        serve_static(spath)
      end
      return
    end
    -- 404 for non-GET or unknown API routes
    uhttpd.send("Status: 404 Not Found\r\n")
    uhttpd.send("Content-Type: application/json\r\n\r\n")
    uhttpd.send(json.encode({error = "not_found", path = ctx.path}))
    return
  end
  
  -- Parse body for POST requests
  local params = {}
  if ctx.method == "POST" then
    if RAW_UPLOAD_ROUTES[route_key] then
      local ct = ctx.headers["content-type"] or ""
      params = ctx.query or {}
      if ct:find("multipart/form%-data", 1, false) then
        params._manual_multipart_rejected = true
      else
        params._raw_upload = {
          content_length = tonumber(env.CONTENT_LENGTH) or 0,
          content_type = ct,
          recv = function(size)
            return uhttpd.recv(size)
          end
        }
      end
    else
      params = parse_body(env)
    end
  else
    params = ctx.query
  end
  
  -- Call handler
  local ok, status, body, extra_headers = pcall(handler, ctx, params)
  
  if not ok then
    -- Handler threw an error
    uhttpd.send("Status: 500 Internal Server Error\r\n")
    uhttpd.send("Content-Type: application/json\r\n\r\n")
    uhttpd.send(json.encode({error = "internal_error", message = tostring(status)}))
    return
  end
  
  -- Map numeric status to full status line
  local status_text = {
    [200] = "200 OK",
    [201] = "201 Created",
    [204] = "204 No Content",
    [301] = "301 Moved Permanently",
    [302] = "302 Found",
    [400] = "400 Bad Request",
    [401] = "401 Unauthorized",
    [403] = "403 Forbidden",
    [404] = "404 Not Found",
    [409] = "409 Conflict",
    [413] = "413 Payload Too Large",
    [500] = "500 Internal Server Error",
    [503] = "503 Service Unavailable",
    [507] = "507 Insufficient Storage",
  }
  local status_line = status_text[tonumber(status)] or (tostring(status) .. " Unknown")

  local response_body = type(body) == "string" and body or tostring(body or "")

  -- Send response
  uhttpd.send("Status: " .. status_line .. "\r\n")
  uhttpd.send("Content-Type: application/json\r\n")
  uhttpd.send("Cache-Control: no-cache\r\n")
  uhttpd.send("Content-Length: " .. #response_body .. "\r\n")
  
  if extra_headers then
    for k, v in pairs(extra_headers) do
      uhttpd.send(k .. ": " .. v .. "\r\n")
    end
  end
  
  uhttpd.send("\r\n")
  uhttpd.send(response_body)
end
