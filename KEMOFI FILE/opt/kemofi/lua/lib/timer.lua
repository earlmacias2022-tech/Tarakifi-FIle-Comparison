#!/usr/bin/env lua
--- KemoFi supervised session timer.
-- Runs one maintenance cycle every 10 seconds. Use --once for diagnostics.

local LUA_ROOT = os.getenv("KEMOFI_LUA_ROOT") or "/opt/kemofi/lua"
package.path = LUA_ROOT .. "/?.lua;" .. LUA_ROOT .. "/lib/?.lua;" .. package.path

local nixio = require("nixio")
local socket = require("socket")
local db = require("lib.db")
local session = require("lib.session")
local admin = require("lib.admin")
local nft = require("lib.nft")
local vendor = require("lib.vendor")
local M = {}

local TICK_SECONDS = tonumber(os.getenv("KEMOFI_TIMER_INTERVAL")) or 10
local LOCK_PATH = os.getenv("KEMOFI_TIMER_LOCK_PATH") or "/tmp/kemofi/timer.lock"
local SYNC_COUNTER_PATH = os.getenv("KEMOFI_SYNC_COUNTER_PATH") or "/tmp/kemofi/sync_counter"
local VENDOR_COUNTER_PATH = os.getenv("KEMOFI_VENDOR_COUNTER_PATH") or "/tmp/kemofi/vendor_counter"
local MAINTENANCE_COUNTER_PATH = os.getenv("KEMOFI_MAINTENANCE_COUNTER_PATH") or
  "/tmp/kemofi/maintenance_counter"
local ROAMING_HEARTBEAT_PATH = os.getenv("KEMOFI_ROAMING_HEARTBEAT_PATH") or "/tmp/kemofi/roaming.heartbeat"
local WAN_STATUS_PATH = os.getenv("KEMOFI_WAN_STATUS_PATH") or "/tmp/kemofi/wan.status"
local WAN_CHECK_COMMAND = os.getenv("KEMOFI_WAN_CHECK_COMMAND") or
  "(ping -c 1 -W 1 8.8.8.8 || ping -c 1 -W 1 1.1.1.1)"
local FIREWALL_RECOVERY_COMMAND = os.getenv("KEMOFI_FIREWALL_RECOVERY_COMMAND") or "/etc/init.d/kemofi recover_firewall"
local UBUS_BIN = os.getenv("KEMOFI_UBUS_BIN") or "ubus"
local WATCHDOG_INTERVAL_SECONDS = 30
local RECONCILE_INTERVAL_SECONDS = 60
local WAN_CHECK_INTERVAL_SECONDS = 30
local MAINTENANCE_INTERVAL_SECONDS = 24 * 60 * 60

local function log(message)
  io.stdout:write(os.date("[%H:%M:%S] ") .. tostring(message) .. "\n")
  io.stdout:flush()
end

local function read_number(path, fallback)
  local file = io.open(path, "r")
  if not file then return fallback end
  local value = tonumber(file:read("*l"))
  file:close()
  return value or fallback
end

local function write_number(path, value)
  local file = io.open(path, "w")
  if not file then return false end
  local ok = file:write(tostring(value))
  file:close()
  return ok ~= nil
end

local function command_succeeded(command)
  local status, _, code = os.execute(command)
  if type(status) == "number" then return status == 0 end
  return status == true and (code == nil or code == 0)
end

local function try_worker_lock()
  os.execute("mkdir -p /tmp/kemofi")
  local lock, open_err = nixio.open(LOCK_PATH, "w", "0600")
  if not lock then return nil, open_err or "cannot open timer lock" end
  local locked, lock_err = lock:lock("tlock")
  if not locked then
    lock:close()
    return nil, lock_err or "timer lock is held"
  end
  return lock
end

function M.heartbeat_is_fresh(path, now, max_age)
  local timestamp = read_number(path or ROAMING_HEARTBEAT_PATH, 0)
  local age = (now or os.time()) - timestamp
  return timestamp > 0 and age >= 0 and age <= (max_age or 45)
end

function M.http_healthy(port, path, timeout)
  local client = socket.tcp()
  if not client then return false end
  client:settimeout(timeout or 1)
  if not client:connect("127.0.0.1", tonumber(port)) then
    client:close()
    return false
  end
  local request_path = path or "/api/healthz"
  local sent = client:send("GET " .. request_path .. " HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
  if not sent then
    client:close()
    return false
  end
  local status_line = client:receive("*l")
  client:close()
  return status_line ~= nil and status_line:match("^HTTP/%d%.%d 200") ~= nil
end

function M.feed_watchdog(instance)
  local command = string.format(
    "%s call service watchdog '{\"name\":\"kemofi\",\"instance\":\"%s\"}' >/dev/null 2>&1",
    UBUS_BIN, instance
  )
  return command_succeeded(command)
end

function M.refresh_wan_status(now)
  local checked_at = now or os.time()
  local online = command_succeeded(WAN_CHECK_COMMAND .. " >/dev/null 2>&1")
  local temp_path = WAN_STATUS_PATH .. ".tmp"
  local file = io.open(temp_path, "w")
  if not file then return false, "cannot write WAN status" end
  local written = file:write(tostring(checked_at), "|", online and "1" or "0", "\n")
  file:close()
  if not written then
    os.remove(temp_path)
    return false, "cannot write WAN status"
  end
  local renamed, rename_err = os.rename(temp_path, WAN_STATUS_PATH)
  if not renamed then
    os.remove(temp_path)
    return false, rename_err or "cannot activate WAN status"
  end
  return true, online
end

function M.next_wan_check_in(online)
  local interval = online and WAN_CHECK_INTERVAL_SECONDS or TICK_SECONDS
  return math.max(1, math.ceil(interval / TICK_SECONDS)) - 1
end

local last_health = {}
local function record_health(instance, healthy)
  if last_health[instance] == healthy then return end
  last_health[instance] = healthy
  log(instance .. (healthy and " watchdog healthy" or " watchdog waiting for recovery"))
end

function M.supervise_services(timer_healthy)
  local health = {
    portal = M.http_healthy(8888),
    admin = M.http_healthy(8080),
    captive = M.http_healthy(2080),
    roaming = M.heartbeat_is_fresh(),
    timer = timer_healthy == true,
  }
  for _, instance in ipairs({"portal", "admin", "captive", "roaming", "timer"}) do
    local healthy = health[instance]
    if healthy and not M.feed_watchdog(instance) then healthy = false end
    record_health(instance, healthy)
  end
  return health
end

function M.reconcile_active_sessions()
  if not nft.session_set_ready() then
    log("Session firewall unavailable; rebuilding KemoFi rules")
    if not command_succeeded(FIREWALL_RECOVERY_COMMAND .. " >/dev/null 2>&1")
        or not nft.session_set_ready() then
      return false, "firewall_recovery_failed"
    end
  end

  local desired = {}
  local access_allowed = vendor.customer_access_allowed()
  if access_allowed then
    local active = db.query("SELECT mac FROM sessions WHERE expires_at > ? AND paused = 0", os.time())
    for _, row in ipairs(active) do
      local mac = tostring(row.mac or ""):upper()
      if mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then desired[mac] = true end
    end
    -- Member devices are unlimited and do not have a paid session row.
    -- Keep them in the desired firewall set so reconciliation does not
    -- remove their access (and flush their conntrack) every minute.
    local members = db.query(
      "SELECT mac FROM known_devices WHERE COALESCE(member, 0) = 1 AND COALESCE(blocked, 0) = 0"
    )
    for _, row in ipairs(members) do
      local mac = tostring(row.mac or ""):upper()
      if mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then desired[mac] = true end
    end
  end
  local current = {}
  for _, mac in ipairs(nft.list_allowed()) do current[mac:upper()] = true end

  local added, removed = 0, 0
  for mac in pairs(desired) do
    if not current[mac] and session.allow_mac(mac) then added = added + 1 end
  end
  for mac in pairs(current) do
    if not desired[mac] then
      session.deny_mac(mac)
      removed = removed + 1
    end
  end
  return true, added, removed
end

local function sync_database_if_due()
  local counter = read_number(SYNC_COUNTER_PATH, 0) + 1
  if counter >= 6 then
    local ok, detail = db.sync_to_flash()
    if not ok then log("Database sync failed: " .. tostring(detail or "unknown error")) end
    counter = 0
  end
  write_number(SYNC_COUNTER_PATH, counter)
end

local function cleanup_database_if_due()
  local interval = math.max(1, math.ceil(MAINTENANCE_INTERVAL_SECONDS / TICK_SECONDS))
  local counter = read_number(MAINTENANCE_COUNTER_PATH, interval - 1) + 1
  if counter < interval then
    write_number(MAINTENANCE_COUNTER_PATH, counter)
    return
  end

  local sessions_removed = session.cleanup_zero_time_sessions()
  local tokens_ok, tokens_removed, token_err = db.cleanup_tokens()
  if not tokens_ok then
    log("Session token cleanup failed: " .. tostring(token_err or "unknown error"))
  elseif sessions_removed > 0 or tokens_removed > 0 then
    log("Session maintenance: expired=" .. sessions_removed .. ", tokens=" .. tokens_removed)
  end
  write_number(MAINTENANCE_COUNTER_PATH, 0)
end

local function phone_home_if_due(wan_online)
  -- Keep the first validation due until WAN is ready instead of consuming it at boot.
  if not wan_online then
    write_number(VENDOR_COUNTER_PATH, 29)
    return
  end

  -- A missing client is retried on the normal five-minute schedule, not every tick.
  local counter = read_number(VENDOR_COUNTER_PATH, 29) + 1
  if counter < 30 then
    write_number(VENDOR_COUNTER_PATH, counter)
    return
  end

  local loaded, vendor = pcall(require, "lib.vendor")
  if not loaded then
    log("Vendor phone-home client is unavailable")
  else
    local called, result = pcall(vendor.phone_home)
    if called then
      log("Vendor phone-home: " .. tostring(result))
    else
      log("Vendor phone-home failed")
    end
  end
  -- OTA check (piggybacks on the phone-home schedule)
  local ota_loaded, ota = pcall(require, "lib.ota")
  if ota_loaded then
    local ota_ok, ota_result, ota_detail = pcall(ota.check_only)
    if not ota_ok then
      log("OTA check failed: " .. tostring(ota_result))
    elseif ota_result == "available" then
      log("OTA update available: v" .. tostring(ota_detail and ota_detail.version or "?") ..
        "; waiting for operator approval")
    elseif ota_result == "error" then
      log("OTA check failed: " .. tostring(ota_detail))
    end
  else
    log("OTA checker is unavailable")
  end

  write_number(VENDOR_COUNTER_PATH, 0)
end

local function run_cycle(state)
  local recovered, recovery_detail = db.fast_lane_recover()
  if not recovered and recovery_detail ~= "empty" then
    log("Fast Lane recovery deferred: " .. tostring(recovery_detail))
  end

  if state.wan_check_in <= 0 then
    local refreshed, detail = M.refresh_wan_status()
    if not refreshed then log("WAN status refresh failed: " .. tostring(detail)) end
    if refreshed then state.wan_online = detail == true end
    state.wan_check_in = M.next_wan_check_in(refreshed and detail == true)
  else
    state.wan_check_in = state.wan_check_in - 1
  end

  if state.reconcile_in <= 0 then
    local reconciled, added, removed = M.reconcile_active_sessions()
    if not reconciled then
      log("Session firewall reconciliation failed: " .. tostring(added))
    elseif (added or 0) > 0 or (removed or 0) > 0 then
      log("Session firewall reconciled: added=" .. tostring(added) .. ", removed=" .. tostring(removed))
    end
    state.reconcile_in = math.max(1, math.ceil(RECONCILE_INTERVAL_SECONDS / TICK_SECONDS)) - 1
  else
    state.reconcile_in = state.reconcile_in - 1
  end

  local expired = session.expire_sessions()
  if expired > 0 then log("Expired " .. expired .. " session(s)") end

  local auto_paused, auto_resumed = session.auto_pause_check()
  if auto_paused > 0 then log("Auto-paused " .. auto_paused .. " disconnected session(s)") end
  if (auto_resumed or 0) > 0 then log("Auto-resumed " .. auto_resumed .. " reconnected session(s)") end

  local access_allowed = vendor.customer_access_allowed()
  if access_allowed then
    local finalized = session.finalize_expired_pending_coins()
    if finalized > 0 then log("Finalized " .. finalized .. " pending coin session(s)") end
  elseif session.get_waiting_mac() then
    session.clear_waiting()
  end

  session.check_waiting_timeout()
  cleanup_database_if_due()
  sync_database_if_due()
  phone_home_if_due(state.wan_online)
end

local function main()
  local once = arg and arg[1] == "--once"
  local lock, lock_err = try_worker_lock()
  if not lock and once then
    error(lock_err or "timer worker is already running")
  end
  if not lock then
    log("Another timer worker is active; waiting for ownership")
    repeat
      nixio.nanosleep(TICK_SECONDS, 0)
      lock, lock_err = try_worker_lock()
    until lock
    log("Timer worker ownership recovered")
  end

  db.init()
  local state = {
    reconcile_in = 0,
    wan_check_in = 0,
    wan_online = false,
    watchdog_in = math.max(1, math.ceil(WATCHDOG_INTERVAL_SECONDS / TICK_SECONDS)),
  }
  repeat
    local ok, cycle_err = pcall(run_cycle, state)
    if not ok then log("Timer cycle failed: " .. tostring(cycle_err)) end
    state.watchdog_in = state.watchdog_in - 1
    if state.watchdog_in <= 0 then
      M.supervise_services(ok)
      state.watchdog_in = math.max(1, math.ceil(WATCHDOG_INTERVAL_SECONDS / TICK_SECONDS))
    end
    if once then break end
    nixio.nanosleep(TICK_SECONDS, 0)
  until false

  lock:lock("ulock")
  lock:close()
end

M.main = main

if ... ~= "lib.timer" then
  local ok, err = pcall(main)
  if not ok then
    log("Timer worker stopped: " .. tostring(err))
    os.exit(1)
  end
end

return M
