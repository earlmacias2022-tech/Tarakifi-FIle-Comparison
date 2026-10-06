#!/usr/bin/env lua
--- TarakiFi Remote Management Worker (HTTP Long-Polling)
-- Polls the vendor platform for pending admin requests, executes them locally,
-- and sends responses back. Enables remote admin panel access without WebSocket.
--
-- Runs as a supervised procd instance. Polls every 3s when idle, immediately
-- when requests are pending. Reconnects with exponential backoff on failure.
--
-- Usage: lua /opt/tarakifi/lua/lib/remote.lua
local LUA_ROOT = os.getenv("TARAKIFI_LUA_ROOT") or "/opt/tarakifi/lua"
package.path = LUA_ROOT .. "/?.lua;" .. LUA_ROOT .. "/lib/?.lua;" .. package.path

local nixio = require("nixio")
local socket = require("socket")
local db = require("lib.db")
local json = require("lib.json")

local M = {}

-- ─── Configuration ─────────────────────────────────────────────────────────────

local POLL_URL = "https://pisowifi.taraki.vip/api/tunnel/poll"
local RESPOND_URL = "https://pisowifi.taraki.vip/api/tunnel/respond"
local BOARD_SECRET = "tarakifi-board-secret-2024"
local LOCK_PATH = "/tmp/tarakifi/remote.lock"
local POLL_INTERVAL = 3        -- seconds between polls when idle
local BUSY_INTERVAL = 1        -- seconds between polls when requests are pending
local MAX_BACKOFF = 300        -- max seconds between retries on failure
local UNLICENSED_INTERVAL = 120 -- quiet license recheck interval before activation
local LOCAL_ADMIN_PORT = 8080  -- local admin panel port
local WATCHDOG_INTERVAL = 30   -- feed procd watchdog every 30s (timeout is 90s)
local UBUS_BIN = "/bin/ubus"

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
  os.execute(UBUS_BIN .. ' call service watchdog \'{"name":"tarakifi","instance":"remote"}\' >/dev/null 2>&1')
end

-- ─── HTTP Helpers ──────────────────────────────────────────────────────────────

--- POST JSON to the vendor platform using uclient-fetch (has TLS via mbedtls)
local function vendor_post(url, payload_table)
  local payload_json = json.encode(payload_table)
  local tmp_file = "/tmp/tarakifi_remote_req.json"
  local tmp_resp = "/tmp/tarakifi_remote_resp.json"

  local f = io.open(tmp_file, "w")
  if not f then return nil, "cannot write temp file" end
  f:write(payload_json)
  f:close()

  local cmd = string.format(
    "uclient-fetch --timeout=30 "..
    "--header='Content-Type: application/json' "..
    "--header='X-Board-Secret: %s' "..
    "--post-file=%s "..
    "-O %s '%s' 2>/dev/null; echo $?",
    BOARD_SECRET, tmp_file, tmp_resp, url
  )

  local h = io.popen(cmd)
  if not h then
    os.remove(tmp_file)
    return nil, "popen failed"
  end
  local exit_str = (h:read("*a") or ""):gsub("%s+", "")
  h:close()
  local exit_code = tonumber(exit_str) or 1

  local rf = io.open(tmp_resp, "r")
  local body = ""
  if rf then
    body = rf:read("*a") or ""
    rf:close()
  end

  os.remove(tmp_file)
  os.remove(tmp_resp)

  if exit_code ~= 0 then
    return nil, "fetch failed (exit " .. tostring(exit_code) .. ")"
  end

  local ok, decoded = pcall(json.decode, body)
  if not ok then return nil, "invalid JSON response" end
  return decoded
end

--- Execute an HTTP request against the local admin panel
local REQUEST_HEADERS_TO_REBUILD = {
  ["host"] = true,
  ["connection"] = true,
  ["content-length"] = true,
  ["transfer-encoding"] = true,
  ["expect"] = true,
  ["keep-alive"] = true,
  ["proxy-connection"] = true,
  ["proxy-authenticate"] = true,
  ["proxy-authorization"] = true,
  ["te"] = true,
  ["trailer"] = true,
  ["upgrade"] = true,
}

local function build_local_request(request)
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
  -- So:
  --   /admin (page load) -> / (serves index.html)
  --   /admin/system/ping (API) -> /api/admin/system/ping (Lua handler)
  --   /app.js (static asset) -> /app.js (unchanged)
  if path == "/admin" then
    path = "/"
  elseif path:sub(1, 7) == "/admin/" then
    -- API call: prepend /api to route through Lua handler
    path = "/api" .. path
  end
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

  -- The tunnel decodes and rebuilds the request body, so transport framing
  -- must be generated locally instead of forwarded from the browser request.
  for k, v in pairs(headers) do
    local lk = k:lower()
    if not REQUEST_HEADERS_TO_REBUILD[lk] then
      table.insert(req_lines, k .. ": " .. v)
    end
  end

  if #body > 0 or method == "POST" or method == "PUT" or method == "PATCH" then
    table.insert(req_lines, "Content-Length: " .. #body)
  end

  table.insert(req_lines, "")
  table.insert(req_lines, body)

  return table.concat(req_lines, "\r\n"), path
end

M._build_local_request = build_local_request

local function execute_local_request(request)
  local raw_request, path = build_local_request(request)

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
    local app_path = "/opt/tarakifi/www/admin/app.js"
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
        local tmp_in = "/tmp/tarakifi_gz_in"
        local tmp_out = "/tmp/tarakifi_gz_out.gz"
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

local function get_credentials()
  local vendor = require("lib.vendor")
  local license_key = db.setting("license_key") or ""
  local device_id = vendor.get_device_id() or ""
  local version = vendor.get_version()
  local hostname = vendor.get_hostname()
  return {
    license_id = license_key,
    instance_device_id = device_id,
    secret = BOARD_SECRET,
    version = version,
    hostname = hostname,
  }
end

local function remote_enabled()
  return (db.setting("license_status") or "") == "active" and
    (db.setting("license_key") or "") ~= ""
end

-- ─── Lock ──────────────────────────────────────────────────────────────────────

local function try_worker_lock()
  os.execute("mkdir -p /tmp/tarakifi")
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
  local backoff = POLL_INTERVAL
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
      worker_sleep(POLL_INTERVAL)
      lock, lock_err = try_worker_lock()
    until lock
    log("Lock acquired after wait")
  end

  -- Trial/unlicensed routers keep the supervised worker quiet until full
  -- activation, without polling the tunnel.
  if not remote_enabled() then
    log("Remote tunnel idle until full license activation")
    while not remote_enabled() do
      maybe_feed_watchdog()
      worker_sleep(UNLICENSED_INTERVAL)
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
      -- Poll for pending requests
      local result, err = vendor_post(POLL_URL, creds)

      if result then
        consecutive_errors = 0
        backoff = POLL_INTERVAL

        local requests = result.requests or {}
        if #requests > 0 then
          log("Received " .. #requests .. " pending request(s)")

          -- Execute each request locally and collect responses
          local responses = {}
          for _, req in ipairs(requests) do
            local resp = execute_local_request(req)
            resp.id = req.id
            resp.type = "http_response"
            table.insert(responses, resp)
          end

          -- Send responses back to vendor
          local respond_payload = {
            license_id = creds.license_id,
            instance_device_id = creds.instance_device_id,
            secret = creds.secret,
            responses = responses,
          }

          local resp_result, resp_err = vendor_post(RESPOND_URL, respond_payload)
          if resp_result then
            log("Sent " .. #responses .. " response(s) back")
          else
            log("Failed to send responses: " .. tostring(resp_err))
          end

          -- Poll again quickly in case more requests are queued
          worker_sleep(BUSY_INTERVAL)
        else
          -- No pending requests, wait normal interval
          worker_sleep(POLL_INTERVAL)
        end
      else
        -- Error polling
        consecutive_errors = consecutive_errors + 1
        if consecutive_errors <= 3 then
          log("Poll failed: " .. tostring(err) .. " (attempt " .. consecutive_errors .. ")")
        elseif consecutive_errors == 4 then
          log("Poll failing repeatedly, suppressing further logs until recovery")
        end

        -- Exponential backoff
        backoff = math.min(backoff * 2, MAX_BACKOFF)
        worker_sleep(backoff)
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
