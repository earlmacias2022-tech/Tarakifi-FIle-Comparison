--- Captive portal redirect handler (port 2080)
--- Checks if the requesting device has an active session.
--- If yes: returns OS-specific "Success" response to dismiss the CNA.
--- If no: redirects to the portal page.

package.path = "/opt/kemofi/lua/?.lua;/opt/kemofi/lua/lib/?.lua;" .. package.path

local clients = require("lib.clients")
local vendor = require("lib.vendor")

local function send_health()
  local body = '{"status":"ok","service":"kemofi-captive"}'
  uhttpd.send("Status: 200 OK\r\n")
  uhttpd.send("Content-Type: application/json\r\n")
  uhttpd.send("Cache-Control: no-store\r\n")
  uhttpd.send("Content-Length: " .. #body .. "\r\n\r\n")
  uhttpd.send(body)
end

local function is_mac_allowed(mac)
  if not mac then return false end
  -- Check nftables set directly
  local handle = io.popen("nft list set inet kemofi allowed_macs 2>/dev/null")
  local output = handle:read("*a")
  handle:close()
  return output:lower():find(mac:lower(), 1, true) ~= nil
end

function handle_request(env)
  local request_path = env.PATH_INFO or env.REQUEST_URI or "/"
  request_path = request_path:match("^[^?]+") or request_path
  if env.REQUEST_METHOD == "GET"
      and (request_path == "/healthz" or request_path == "/api/healthz") then
    send_health()
    return
  end
  local client_ip = env.REMOTE_ADDR or env.REMOTE_HOST
  local mac = clients.mac_for_ip(client_ip)
  local uri = env.REQUEST_URI or "/"
  local host = tostring(env.HTTP_HOST or ""):lower()

  -- CNA success requires both an active session and licensed customer access.
  local access_allowed = vendor.customer_access_allowed()
  if access_allowed and mac and is_mac_allowed(mac) then
    -- Apple CNA expects exactly this response
    -- Android expects 204 on /generate_204 or "OK" body
    -- Windows expects "Microsoft NCSI" on /ncsi.txt
    if uri:find("generate_204") then
      -- Android/Chrome connectivity check
      uhttpd.send("Status: 204 No Content\r\n")
      uhttpd.send("Content-Length: 0\r\n\r\n")
    elseif uri:find("ncsi.txt") then
      -- Windows NCSI
      uhttpd.send("Status: 200 OK\r\n")
      uhttpd.send("Content-Type: text/plain\r\n\r\n")
      uhttpd.send("Microsoft NCSI")
    elseif uri:find("connecttest.txt") then
      -- Windows 10+ connectivity test
      uhttpd.send("Status: 200 OK\r\n")
      uhttpd.send("Content-Type: text/plain\r\n\r\n")
      uhttpd.send("Microsoft Connect Test")
    else
      -- Apple CNA (hotspot-detect.html, /library/test/success.html, etc.)
      -- Also handles any other captive portal detection
      uhttpd.send("Status: 200 OK\r\n")
      uhttpd.send("Content-Type: text/html\r\n")
      uhttpd.send("Cache-Control: no-cache, no-store\r\n\r\n")
      uhttpd.send("<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>")
    end
    return
  end

  -- Device not allowed — redirect to portal
  local cna = ""
  if host:find("captive.apple.com", 1, true)
      or uri:find("hotspot%-detect") or uri:find("hotspotdetect")
      or uri:find("library/test/success", 1, true) then
    cna = "?cna=apple"
  elseif host:find("connectivitycheck", 1, true)
      or uri:find("generate_204", 1, true) or uri:find("gen_204", 1, true) then
    cna = "?cna=android"
  elseif host:find("msftconnecttest", 1, true)
      or uri:find("connecttest", 1, true) or uri:find("ncsi", 1, true) then
    cna = "?cna=windows"
  end
  local portal_url = "http://10.0.0.1/" .. cna
  uhttpd.send("Status: 302 Found\r\n")
  uhttpd.send("Location: " .. portal_url .. "\r\n")
  uhttpd.send("Content-Type: text/html\r\n")
  uhttpd.send("Cache-Control: no-cache, no-store\r\n\r\n")
  uhttpd.send("<html><body><a href='" .. portal_url .. "'>Open portal</a></body></html>")
end
