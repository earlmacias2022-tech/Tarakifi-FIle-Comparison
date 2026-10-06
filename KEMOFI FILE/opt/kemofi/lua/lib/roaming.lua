#!/usr/bin/env lua
--- KemoFi association-triggered roaming worker.
-- Detects newly authorized stations and restores verified alias sessions.

local LUA_ROOT = os.getenv("KEMOFI_LUA_ROOT") or "/opt/kemofi/lua"
package.path = LUA_ROOT .. "/?.lua;" .. LUA_ROOT .. "/lib/?.lua;" .. package.path

local nixio = require("nixio")
local ubus = require("ubus")
local session = require("lib.session")
local vendor = require("lib.vendor")
local M = {}

local TICK_SECONDS = tonumber(os.getenv("KEMOFI_ROAMING_INTERVAL")) or 1
local LOCK_PATH = os.getenv("KEMOFI_ROAMING_LOCK_PATH") or "/tmp/kemofi/roaming.lock"
local HEARTBEAT_PATH = os.getenv("KEMOFI_ROAMING_HEARTBEAT_PATH") or "/tmp/kemofi/roaming.heartbeat"
local OBJECT_REFRESH_TICKS = 5
local HEARTBEAT_SECONDS = 5

local QUIET_REJECTIONS = {
  alias_unknown = true,
  alias_inactive = true,
  alias_group_conflict = true,
  target_blocked = true,
  target_has_active_session = true,
}

local function log(message)
  io.stdout:write(os.date("[%H:%M:%S] ") .. tostring(message) .. "\n")
  io.stdout:flush()
end

local function normalize_mac(value)
  local mac = tostring(value or ""):upper()
  if mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then return mac end
  return nil
end

function M.associated_clients(response)
  local associated = {}
  if type(response) ~= "table" or type(response.clients) ~= "table" then
    return associated
  end

  for value, client in pairs(response.clients) do
    local mac = normalize_mac(value)
    if mac and type(client) == "table" and client.assoc == true and client.authorized == true then
      associated[mac] = true
    end
  end
  return associated
end

function M.should_log_rejection(reason)
  return reason ~= nil and not QUIET_REJECTIONS[reason]
end

function M.update_radio(previous_by_radio, object_name, current, callback, attempted)
  if type(current) ~= "table" then return 0 end
  local previous = previous_by_radio[object_name]
  previous_by_radio[object_name] = current
  if previous == nil then return 0 end

  attempted = attempted or {}
  local count = 0
  for mac in pairs(current) do
    if not previous[mac] and not attempted[mac] then
      attempted[mac] = true
      callback(mac, object_name)
      count = count + 1
    end
  end
  return count
end

local function try_worker_lock()
  os.execute("mkdir -p /tmp/kemofi")
  local lock, open_err = nixio.open(LOCK_PATH, "w", "0600")
  if not lock then return nil, open_err or "cannot open roaming lock" end
  local locked, lock_err = lock:lock("tlock")
  if not locked then
    lock:close()
    return nil, lock_err or "roaming lock is held"
  end
  return lock
end

function M.write_heartbeat(path, timestamp)
  local file = io.open(path or HEARTBEAT_PATH, "w")
  if not file then return false end
  local ok = file:write(tostring(timestamp or os.time()))
  file:close()
  return ok ~= nil
end

local function discover_objects(connection)
  local called, objects = pcall(connection.objects, connection)
  if not called or type(objects) ~= "table" then return nil end

  local names = {}
  for _, name in pairs(objects) do
    if type(name) == "string" and name:match("^hostapd%.") then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

local function scan_object(connection, object_name)
  local called, response = pcall(connection.call, connection, object_name, "get_clients", {})
  if not called or type(response) ~= "table" then return nil end
  return M.associated_clients(response)
end

local function restore_verified_alias(mac)
  if not vendor.customer_access_allowed() then return end
  local called, restored, _, reason = pcall(session.rebind_known_alias, mac)
  if not called then
    log("Roaming handoff failed for " .. mac)
    return
  end
  if restored then
    log("Association access ready for " .. mac)
  elseif M.should_log_rejection(reason) then
    log("Roaming handoff deferred for " .. mac .. ": " .. tostring(reason))
  end
end

local function connect(state)
  if state.connection then return true end
  local called, connection = pcall(ubus.connect)
  if not called or not connection then return false end
  state.connection = connection
  state.refresh_in = 0
  return true
end

function M.run_cycle(state)
  if not connect(state) then return false, "ubus unavailable" end

  if state.refresh_in <= 0 then
    local objects = discover_objects(state.connection)
    if not objects then
      pcall(state.connection.close, state.connection)
      state.connection = nil
      return false, "hostapd discovery failed"
    end
    state.objects = objects
    state.refresh_in = #objects > 0 and OBJECT_REFRESH_TICKS or 1
  else
    state.refresh_in = state.refresh_in - 1
  end

  local attempted = {}
  for _, object_name in ipairs(state.objects) do
    local current = scan_object(state.connection, object_name)
    M.update_radio(state.previous, object_name, current, restore_verified_alias, attempted)
  end
  return true
end

local function main()
  local lock = try_worker_lock()
  if not lock then
    log("Another roaming worker is active; waiting for ownership")
    repeat
      nixio.nanosleep(TICK_SECONDS, 0)
      lock = try_worker_lock()
    until lock
    log("Roaming worker ownership recovered")
  end

  local state = {
    connection = nil,
    objects = {},
    previous = {},
    refresh_in = 0,
    next_heartbeat_at = 0,
  }

  repeat
    local called, ok, cycle_err = pcall(M.run_cycle, state)
    if not called then
      log("Roaming cycle failed: " .. tostring(ok))
    elseif not ok and cycle_err then
      log("Roaming cycle waiting: " .. tostring(cycle_err))
    end
    if called and ok and os.time() >= state.next_heartbeat_at then
      if M.write_heartbeat() then state.next_heartbeat_at = os.time() + HEARTBEAT_SECONDS end
    end
    nixio.nanosleep(TICK_SECONDS, 0)
  until false
end

if ... ~= "lib.roaming" then
  local ok, err = pcall(main)
  if not ok then
    log("Roaming worker stopped: " .. tostring(err))
    os.exit(1)
  end
end

return M
