--- KemoFi Session Manager
-- Manages WiFi sessions, firewall rules, coin slot locking, abuse prevention,
-- pause penalty, auto-pause on disconnect, bandwidth, vouchers, free time.
-- Now includes multi-layer fingerprint support for MAC randomization recovery.
local db = require("lib.db")
local clients = require("lib.clients")
local M = {}

local AUTO_PAUSE_GRACE_SECONDS = 10

local function session_link_key(mac)
  return "_session_link_" .. tostring(mac or "")
end

local function remember_session_link(mac, kind)
  if kind == "wifi" or kind == "wifi_stale" then
    db.set_runtime_setting(session_link_key(mac), "wifi")
  elseif kind == "bridge" then
    db.set_runtime_setting(session_link_key(mac), "bridge")
  end
end

local function bind_session_identity(token, mac, device_id)
  db.token_bind(token, "mac", mac)
  if device_id and device_id ~= "" then
    -- A device ID already owned by another active session is rejected by the
    -- database uniqueness guard instead of moving that session implicitly.
    db.token_bind_unique(token, "device_id", device_id)
  end
end

local function normalize_mac(value)
  local mac = tostring(value or ""):lower()
  if mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then return mac end
  return nil
end

local function flush_captive_flows(ip)
  -- Only remove intercepted web probes. Deleting every flow here also kills
  -- the port 8888 API response that carries the new roaming cookie.
  os.execute("conntrack -D -s " .. ip .. " -p tcp --dport 80 2>/dev/null")
  os.execute("conntrack -D -s " .. ip .. " -p tcp --dport 443 2>/dev/null")
end

--- Allow a MAC through the firewall (nftables)
function M.allow_mac(mac)
  mac = normalize_mac(mac)
  if not mac then return false end
  -- Add-Time is the common path for an already connected client. Avoid
  -- repeating nft/conntrack work when the firewall already allows it.
  if M.is_mac_allowed(mac) then return true end
  os.execute("nft add element inet kemofi allowed_macs { " .. mac .. " } 2>/dev/null")
  -- Flush stale conntrack NAT entries so the OS captive-portal re-probe
  -- creates a NEW connection that hits the allowed_macs return rule.
  -- Without this, old conntrack entries (port 80/443 → 2080 redirect)
  -- keep intercepting probes and the CNA never dismisses.
  local ip = M.get_ip_for_mac(mac)
  if ip then
    flush_captive_flows(ip)
  end
  return M.is_mac_allowed(mac)
end

function M.is_mac_allowed(mac)
  mac = normalize_mac(mac)
  if not mac then return false end
  local handle = io.popen("nft list set inet kemofi allowed_macs 2>/dev/null")
  if not handle then return false end
  local output = handle:read("*a") or ""
  handle:close()
  return output:lower():find(mac, 1, true) ~= nil
end

function M.ensure_active_access(mac)
  local status = M.get_status(mac)
  if not status.connected then return false end
  if M.is_mac_allowed(mac) then return true end
  return M.allow_mac(mac)
end

function M.is_member(mac)
  mac = normalize_mac(mac)
  if not mac then return false end
  mac = mac:upper()
  local device = db.row(
    "SELECT member, blocked FROM known_devices WHERE mac = ?", mac
  )
  return device ~= nil and tonumber(device.member) == 1 and tonumber(device.blocked) ~= 1
end

function M.restore_member_access()
  local members = db.query(
    "SELECT mac FROM known_devices WHERE member = 1 AND blocked = 0"
  )
  for _, member in ipairs(members) do M.allow_mac(member.mac) end
  return true
end

--- Deny a MAC (remove from firewall + flush conntrack)
function M.deny_mac(mac)
  mac = normalize_mac(mac)
  if not mac then return false end
  os.execute("nft delete element inet kemofi allowed_macs { " .. mac .. " } 2>/dev/null")
  -- Flush conntrack entries so existing connections die immediately
  -- (otherwise ct state established bypasses the MAC check)
  local ip = M.get_ip_for_mac(mac)
  if ip then
    os.execute("conntrack -D -s " .. ip .. " 2>/dev/null")
    os.execute("conntrack -D -d " .. ip .. " 2>/dev/null")
  end
  return true
end

--- Get IP for a MAC from live network state.
function M.get_ip_for_mac(mac)
  local wanted = tostring(mac or ""):lower()
  if not wanted:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then return nil end

  local arp = io.open("/proc/net/arp", "r")
  if arp then
    for line in arp:lines() do
      local ip, found_mac = line:match("^(%d+%.%d+%.%d+%.%d+)%s+%S+%s+%S+%s+(%S+)")
      if found_mac and found_mac:lower() == wanted then
        arp:close()
        return ip
      end
    end
    arp:close()
  end

  -- A newly associated client may have a DHCP lease before it appears in ARP.
  local leases = io.open("/tmp/dhcp.leases", "r")
  if leases then
    for line in leases:lines() do
      local found_mac, ip = line:match("^%S+%s+(%S+)%s+(%d+%.%d+%.%d+%.%d+)")
      if found_mac and found_mac:lower() == wanted then
        leases:close()
        return ip
      end
    end
    leases:close()
  end

  local neighbors = io.popen("ip neigh show dev br-lan 2>/dev/null")
  if neighbors then
    for line in neighbors:lines() do
      local ip, found_mac = line:match("^(%d+%.%d+%.%d+%.%d+).-%slladdr%s+(%S+)")
      if found_mac and found_mac:lower() == wanted then
        neighbors:close()
        return ip
      end
    end
    neighbors:close()
  end
  return nil
end

--- Credit time to a MAC (from coin, voucher, or free time)
--- Also mints/updates a session token and binds fingerprint identifiers.
function M.credit(mac, minutes, amount_php, source, browser_fp, device_id, roam_fp, pause_limit)
  source = source or "coin"
  pause_limit = math.max(0, math.floor(tonumber(pause_limit) or 0))
  local now = os.time()
  local existing = db.row("SELECT * FROM sessions WHERE mac = ?", mac)

  if existing and existing.expires_at > now and existing.paused == 0 then
    -- Active session: add time
    local new_expires = existing.expires_at + (minutes * 60)
    local valid_until = tonumber(existing.valid_until) or 0
    if valid_until > 0 and new_expires > valid_until then new_expires = valid_until end
    local new_remaining = existing.minutes_remaining + minutes
    db.exec(
      [[UPDATE sessions SET minutes_remaining = ?, expires_at = ?, pause_limit = CASE
          WHEN pause_limit = 0 OR ? = 0 THEN 0
          WHEN ? > pause_limit THEN ?
          ELSE pause_limit
        END WHERE mac = ?]],
      new_remaining, new_expires, pause_limit, pause_limit, pause_limit, mac
    )
  elseif existing and existing.paused == 1 then
    -- Paused session: add to remaining (don't start yet)
    local new_remaining = existing.minutes_remaining + minutes
    db.exec(
      [[UPDATE sessions SET minutes_remaining = ?, pause_limit = CASE
          WHEN pause_limit = 0 OR ? = 0 THEN 0
          WHEN ? > pause_limit THEN ?
          ELSE pause_limit
        END WHERE mac = ?]],
      new_remaining, pause_limit, pause_limit, pause_limit, mac
    )
  else
    -- New session
    local expires_at = now + (minutes * 60)
    db.exec(
      [[INSERT OR REPLACE INTO sessions
        (mac, minutes_remaining, started_at, expires_at, last_seen, paused, auto_paused, pause_limit, pauses_used)
        VALUES (?, ?, ?, ?, ?, 0, 0, ?, 0)]],
      mac, minutes, now, expires_at, now, pause_limit
    )
    M.allow_mac(mac)
  end

  -- Record transaction
  db.exec(
    "INSERT INTO transactions (mac, amount_php, minutes_granted, source, created_at) VALUES (?, ?, ?, ?, ?)",
    mac, amount_php, minutes, source, now
  )

  -- Ensure an existing active session is allowed. New sessions are allowed
  -- once above; avoid doing the firewall lookup twice on that path.
  if existing and existing.paused ~= 1 then
    M.allow_mac(mac)
  end

  -- Update known_devices
  db.exec(
    "INSERT OR IGNORE INTO known_devices (mac, first_seen, last_seen) VALUES (?, ?, ?)",
    mac, now, now
  )
  db.exec("UPDATE known_devices SET last_seen = ? WHERE mac = ?", now, mac)
  remember_session_link(mac, clients.connection_kind(mac))

  -- Mint the session token and bind only ownership-bearing identity. Browser
  -- and roaming fingerprints are intentionally not trusted: identical phones
  -- can produce the same passive fingerprint.
  local token = db.token_mint(mac)
  bind_session_identity(token, mac, device_id)

  return token
end

--- Store physical coin credit without starting or extending live access yet.
function M.add_pending_coin(mac, minutes, amount_php, browser_fp, device_id, roam_fp,
    pause_limit, validity_seconds, rates_value, flat_value)
  if not mac or not tostring(mac):match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
    return false, "invalid_mac"
  end
  return db.pending_coin_add(mac, minutes, amount_php, browser_fp or "", device_id or "",
    roam_fp or "", pause_limit, validity_seconds, rates_value, flat_value)
end

function M.get_pending_coin(mac)
  if not mac then return nil end
  return db.pending_coin_get(mac)
end

--- Consume pending coins once, persist them, then grant network access.
function M.finalize_pending_coin(mac, browser_fp, device_id, roam_fp)
  if not mac then return false, nil, "invalid_mac" end
  local ok, pending, mode_or_err = db.pending_coin_finalize(mac)
  if not ok then return false, nil, mode_or_err end
  if not pending then
    local status = M.get_status(mac)
    if not status.connected and not status.paused then
      return false, nil, "no_pending_credit"
    end
    local token = db.token_mint(mac)
    bind_session_identity(token, mac, device_id)
    local persisted, persist_err = db.sync_on_credit("coin-finalize-retry")
    if not persisted then
      return false, nil, "persistence_failed", token, persist_err
    end
    if status.connected and not M.ensure_active_access(mac) then
      return false, nil, "access_failed", token
    end
    return true, {minutes = 0, coin_count = 0},
      status.paused and "paused" or "already_finalized", token
  end

  local persisted, persist_err = db.sync_on_credit("coin-finalize")
  if not persisted then
    return false, pending, "persistence_failed", pending.token, persist_err
  end

  if mode_or_err ~= "paused" then
    if not M.allow_mac(mac) then
      return false, pending, "access_failed", pending.token
    end
  end
  return true, pending, mode_or_err, pending.token
end

--- Finish durable pending credits left behind by a closed browser or reboot.
function M.finalize_expired_pending_coins()
  local timeout = tonumber(db.setting("coinslot_timeout_seconds") or "") or 60
  local stale = db.pending_coin_stale(os.time() - timeout)
  local finalized = 0
  for _, row in ipairs(stale) do
    local ok = M.finalize_pending_coin(row.mac)
    if ok then
      finalized = finalized + 1
      if M.get_waiting_mac() == row.mac then M.clear_waiting() end
    end
  end
  return finalized
end

--- Rebind a session to a new MAC (when MAC randomization detected)
--- Old MAC loses firewall access; new MAC gets it.
function M.rebind_mac(old_mac, new_mac, browser_fp, device_id, roam_fp)
  if old_mac == new_mac then return true end
  local moved, new_token, move_err = db.rebind_session(
    old_mac, new_mac, browser_fp, device_id, roam_fp
  )
  if not moved then return false, nil, move_err end

  local moved_session = db.row("SELECT expires_at, paused FROM sessions WHERE mac = ?", new_mac)
  M.deny_mac(old_mac)
  if moved_session and moved_session.paused == 0 and moved_session.expires_at > os.time() then
    M.allow_mac(new_mac)
  else
    M.deny_mac(new_mac)
  end

  local persisted = db.persist("session-rebind", true)
  if not persisted then return false, nil, "persistence_failed" end
  return true, new_token
end

--- Restore a session from a previously verified MAC used by the same device.
function M.rebind_known_alias(value)
  local normalized = normalize_mac(value)
  if not normalized then return false, nil, "invalid_alias_mac" end
  local new_mac = normalized:upper()

  local current = M.get_status(new_mac)
  if current.connected then
    if not M.ensure_active_access(new_mac) then
      return false, current, "access_restore_failed"
    end
    return true, current
  end
  if current.paused then return true, current end

  local owner, owner_err = db.active_alias_owner(new_mac)
  if not owner then return false, nil, owner_err end

  local moved, _, move_err = M.rebind_mac(owner.mac, new_mac, nil, nil, nil)
  if not moved then return false, nil, move_err end

  local status = M.get_status(new_mac)
  if status.connected and not M.ensure_active_access(new_mac) then
    return false, status, "access_restore_failed"
  end
  return true, status
end

--- Get session status for a MAC
function M.get_status(mac)
  if M.is_member(mac) then
    M.allow_mac(mac)
    return {
      connected = true,
      paused = false,
      member = true,
      unlimited = true,
      minutes_remaining = 0,
      expires_at = 0
    }
  end
  local sess = db.row("SELECT * FROM sessions WHERE mac = ?", mac)
  if not sess then
    return { connected = false, minutes_remaining = 0 }
  end

  local now = os.time()
  local pause_limit = tonumber(sess.pause_limit) or 0
  local pauses_used = tonumber(sess.pauses_used) or 0
  local valid_until = tonumber(sess.valid_until) or 0
  local validity_remaining_seconds = valid_until > 0 and
    math.max(0, valid_until - now) or 0
  if sess.paused == 1 then
    if valid_until > 0 and valid_until <= now then
      return { connected = false, minutes_remaining = 0, expired = true }
    end
    return {
      connected = false,
      paused = true,
      auto_paused = tonumber(sess.auto_paused) == 1,
      minutes_remaining = sess.minutes_remaining,
      pause_limit = pause_limit,
      pauses_used = pauses_used,
      valid_until = valid_until,
      validity_remaining_seconds = validity_remaining_seconds
    }
  end

  if sess.expires_at > 0 and sess.expires_at > now and
      (valid_until == 0 or valid_until > now) then
    local remaining_secs = sess.expires_at - now
    return {
      connected = true,
      paused = false,
      minutes_remaining = remaining_secs / 60,
      expires_at = sess.expires_at,
      started_at = sess.started_at,
      pause_limit = pause_limit,
      pauses_used = pauses_used,
      valid_until = valid_until,
      validity_remaining_seconds = validity_remaining_seconds
    }
  end

  -- Expired
  return { connected = false, minutes_remaining = 0, expired = true }
end

--- Expire all sessions that have run out of time
function M.expire_sessions()
  local now = os.time()
  local expired = db.query([[SELECT s.mac FROM sessions s
    LEFT JOIN known_devices d ON d.mac = s.mac
    WHERE COALESCE(d.member, 0) = 0 AND
      ((s.expires_at > 0 AND s.expires_at <= ? AND s.paused = 0)
       OR (s.valid_until > 0 AND s.valid_until <= ?))]], now, now)
  local removed = 0
  for _, row in ipairs(expired) do
    M.deny_mac(row.mac)
    local deleted = db.exec([[DELETE FROM sessions WHERE mac = ? AND
      ((expires_at > 0 AND expires_at <= ? AND paused = 0)
       OR (valid_until > 0 AND valid_until <= ?))]], row.mac, now, now)
    if deleted then removed = removed + 1 end
  end
  return removed
end

--- Remove zero-time placeholders left by older releases or interrupted cleanup.
function M.cleanup_zero_time_sessions()
  local stale = db.query([[
    SELECT s.mac FROM sessions s
    LEFT JOIN known_devices d ON d.mac = s.mac
    WHERE COALESCE(d.member, 0) = 0
      AND s.expires_at = 0 AND s.paused = 0 AND s.minutes_remaining <= 0
  ]])
  local removed = 0
  for _, row in ipairs(stale) do
    M.deny_mac(row.mac)
    local deleted = db.exec([[
      DELETE FROM sessions
      WHERE mac = ? AND expires_at = 0 AND paused = 0 AND minutes_remaining <= 0
    ]], row.mac)
    if deleted then removed = removed + 1 end
  end
  return removed
end

--- Forget a device without touching its transaction or earnings history.
function M.forget_device(mac)
  local normalized = normalize_mac(mac)
  if not normalized then return false, "invalid_mac" end
  mac = normalized:upper()

  local sess = db.row(
    "SELECT expires_at, paused, minutes_remaining FROM sessions WHERE mac = ?", mac
  )
  local now = os.time()
  if sess and (tonumber(sess.paused) == 1 or (tonumber(sess.expires_at) or 0) > now) then
    return false, "active_session"
  end
  if db.row("SELECT mac FROM pending_coin_credits WHERE mac = ?", mac) then
    return false, "pending_credit"
  end

  M.deny_mac(mac)
  local bindings_ok = db.exec([[
    DELETE FROM token_bindings
    WHERE token IN (SELECT token FROM session_tokens WHERE mac = ?)
  ]], mac)
  if not bindings_ok then return false, "database_error" end
  if not db.exec("DELETE FROM session_tokens WHERE mac = ?", mac) then
    return false, "database_error"
  end
  if not db.exec("DELETE FROM device_aliases WHERE mac = ?", mac) then
    return false, "database_error"
  end
  if not db.exec("DELETE FROM sessions WHERE mac = ?", mac) then
    return false, "database_error"
  end
  if not db.exec("DELETE FROM known_devices WHERE mac = ?", mac) then
    return false, "database_error"
  end
  return true
end

--- Forget disconnected, unnamed, unblocked devices after the retention window.
function M.cleanup_stale_devices(max_age_seconds)
  local now = os.time()
  local cutoff = now - math.max(86400, tonumber(max_age_seconds) or (30 * 86400))
  local stale = db.query([[
    SELECT d.mac
    FROM known_devices d
    LEFT JOIN sessions s ON s.mac = d.mac
    LEFT JOIN pending_coin_credits p ON p.mac = d.mac
    WHERE d.last_seen > 0 AND d.last_seen < ?
      AND COALESCE(d.blocked, 0) = 0
      AND COALESCE(d.member, 0) = 0
      AND TRIM(COALESCE(d.name, '')) = ''
      AND p.mac IS NULL
      AND (
        s.mac IS NULL OR
        (s.paused = 0 AND s.expires_at <= ? AND COALESCE(s.minutes_remaining, 0) <= 0)
      )
  ]], cutoff, now)

  local removed = 0
  for _, row in ipairs(stale) do
    if not clients.is_recently_connected(row.mac) then
      local forgotten = M.forget_device(row.mac)
      if forgotten then removed = removed + 1 end
    end
  end
  return removed
end

--- Pause a session (stop timer, keep remaining time)
function M.pause(mac, automatic_pause)
  local sess = db.row("SELECT * FROM sessions WHERE mac = ? AND paused = 0 AND expires_at > 0", mac)
  if not sess then return false end

  local pause_limit = tonumber(sess.pause_limit) or 0
  local pauses_used = tonumber(sess.pauses_used) or 0
  if pause_limit > 0 and pauses_used >= pause_limit then
    return false, "pause_limit_reached"
  end

  local now = os.time()
  local remaining_secs = sess.expires_at - now
  if remaining_secs <= 0 then return false end

  local remaining_mins = remaining_secs / 60

  -- Apply pause penalty
  local penalty = tonumber(db.setting("pause_penalty_minutes")) or 0
  if penalty > 0 then
    -- Reject pause if remaining time won't survive the penalty
    if remaining_mins <= penalty then
      return false, "not_enough_time"
    end
    remaining_mins = remaining_mins - penalty
  end

  db.exec(
    "UPDATE sessions SET paused = 1, auto_paused = ?, minutes_remaining = ?, expires_at = 0, pauses_used = ? WHERE mac = ?",
    automatic_pause and 1 or 0, remaining_mins, pauses_used + 1, mac
  )
  M.deny_mac(mac)
  local persisted = db.persist("session-pause", true)
  if not persisted then return false, "persistence_failed" end
  return true
end

--- Resume a paused session
function M.resume(mac)
  local sess = db.row("SELECT * FROM sessions WHERE mac = ? AND paused = 1", mac)
  if not sess then return false end
  if sess.minutes_remaining <= 0 then return false end

  local now = os.time()
  local expires_at = now + (sess.minutes_remaining * 60)
  local valid_until = tonumber(sess.valid_until) or 0
  if valid_until > 0 and valid_until <= now then
    return false, "validity_expired"
  end
  if valid_until > 0 and expires_at > valid_until then expires_at = valid_until end
  db.exec(
    "UPDATE sessions SET paused = 0, auto_paused = 0, expires_at = ?, started_at = ? WHERE mac = ?",
    expires_at, now, mac
  )
  M.allow_mac(mac)
  remember_session_link(mac, clients.connection_kind(mac))

  local persisted = db.persist("session-resume", true)
  if not persisted then return false, "persistence_failed" end
  return true
end

--- Resume a session that was paused automatically as soon as its original
--- client is observable again. Manual pauses are intentionally excluded.
--- `already_enabled` lets the timer reuse its one settings read.
function M.resume_auto_paused(mac, already_enabled)
  if already_enabled ~= true and db.setting("auto_resume_on_reconnect") ~= "1" then
    return false, "disabled"
  end

  local now = os.time()
  local sess = db.row([[SELECT mac FROM sessions
    WHERE mac = ? AND paused = 1 AND auto_paused = 1 AND minutes_remaining > 0
      AND (valid_until = 0 OR valid_until > ?)]], mac, now)
  if not sess then return false, "not_auto_paused" end

  local link_kind = clients.connection_kind(mac)
  if link_kind ~= "wifi" and link_kind ~= "bridge" then
    return false, "not_reconnected"
  end
  return M.resume(mac)
end

--- Kick a MAC (end session immediately)
function M.kick(mac)
  M.deny_mac(mac)
  db.exec("DELETE FROM sessions WHERE mac = ?", mac)
  return true
end

--- Block a device
function M.block_device(mac)
  M.kick(mac)
  db.exec("UPDATE known_devices SET blocked = 1 WHERE mac = ?", mac)
end


function M.promote_member(mac)
  mac = normalize_mac(mac)
  if not mac then return false, "invalid_mac" end
  mac = mac:upper()
  local now = os.time()
  db.exec(
    "INSERT OR IGNORE INTO known_devices (mac, first_seen, last_seen) VALUES (?, ?, ?)",
    mac, now, now
  )
  local device = db.row("SELECT blocked FROM known_devices WHERE mac = ?", mac)
  if device and tonumber(device.blocked) == 1 then return false, "device_blocked" end
  if not db.exec(
      "UPDATE known_devices SET member = 1, member_since = ? WHERE mac = ?", now, mac
    ) then return false, "database_error" end
  M.allow_mac(mac)
  return true
end

function M.remove_member(mac)
  mac = normalize_mac(mac)
  if not mac then return false, "invalid_mac" end
  mac = mac:upper()
  if not db.exec(
      "UPDATE known_devices SET member = 0, member_since = 0 WHERE mac = ?", mac
    ) then return false, "database_error" end
  local paid = M.get_status(mac)
  if not paid.connected then M.deny_mac(mac) end
  return true
end

--- Unblock a device
function M.unblock_device(mac)
  db.exec("UPDATE known_devices SET blocked = 0 WHERE mac = ?", mac)
  if M.is_member(mac) then M.allow_mac(mac) end
end

--- Set device name
function M.set_device_name(mac, name)
  db.exec(
    "INSERT OR IGNORE INTO known_devices (mac, first_seen, last_seen) VALUES (?, ?, ?)",
    mac, os.time(), os.time()
  )
  db.exec("UPDATE known_devices SET name = ? WHERE mac = ?", name, mac)
end

--- Edit session time (add or set minutes)
function M.edit_time(mac, minutes)
  local now = os.time()
  local sess = db.row("SELECT * FROM sessions WHERE mac = ?", mac)
  if sess then
    if sess.paused == 1 then
      db.exec("UPDATE sessions SET minutes_remaining = ? WHERE mac = ?", minutes, mac)
    else
      local expires_at = now + (minutes * 60)
      db.exec("UPDATE sessions SET minutes_remaining = ?, expires_at = ? WHERE mac = ?", minutes, expires_at, mac)
    end
  else
    -- Create new session
    local expires_at = now + (minutes * 60)
    db.exec(
      "INSERT OR REPLACE INTO sessions (mac, minutes_remaining, started_at, expires_at, last_seen, paused) VALUES (?, ?, ?, ?, ?, 0)",
      mac, minutes, now, expires_at, now
    )
    M.allow_mac(mac)
  end
  return true
end

--- Reset device session (delete all session data for a MAC)
function M.reset_device(mac)
  M.deny_mac(mac)
  db.exec("DELETE FROM sessions WHERE mac = ?", mac)
  if M.is_member(mac) then M.allow_mac(mac) end
  return true
end

--- Get all active sessions
function M.list_active()
  local now = os.time()
  return db.query(
    "SELECT s.*, d.name as device_name, d.blocked, d.member, CASE WHEN s.paused = 1 THEN s.minutes_remaining ELSE (s.expires_at - ?) / 60.0 END as time_left FROM sessions s LEFT JOIN known_devices d ON s.mac = d.mac WHERE (s.expires_at > ? AND s.paused = 0) OR s.paused = 1 ORDER BY s.started_at DESC",
    now, now
  )
end

-- Ephemeral coin-insert state lives in /tmp (RAM) for speed.
-- These values do NOT need to survive a reboot.
local TMP_DIR       = os.getenv("KEMOFI_TMP_DIR") or "/tmp/kemofi"
local F_WAITING_MAC = TMP_DIR .. "/waiting_mac"
local F_WAITING_SIN = TMP_DIR .. "/waiting_since"
local F_WAITING_FP  = TMP_DIR .. "/waiting_browser_fp"
local F_WAITING_DID = TMP_DIR .. "/waiting_device_id"
local F_WAITING_ROAM = TMP_DIR .. "/waiting_roam_fp_v2"
local F_WAITING_READY = TMP_DIR .. "/waiting_ready"
local F_WAITING_CLOSING = TMP_DIR .. "/waiting_closing"
local F_LAST_CREDIT = TMP_DIR .. "/last_coin_credited_at"

local function _tmp_read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local v = f:read("*l"); f:close()
  return v
end

local function _tmp_write(path, value)
  os.execute("mkdir -p " .. TMP_DIR)
  local f = io.open(path, "w")
  if f then f:write(tostring(value)); f:close() end
end

local function _tmp_delete(path)
  os.remove(path)
end

local function _safe_identity(value)
  if type(value) ~= "string" or value == "" or #value > 128 then return "" end
  if not value:match("^[%w_%-]+$") then return "" end
  return value
end

--- Get the MAC currently waiting for a coin
function M.get_waiting_mac()
  return _tmp_read(F_WAITING_MAC)
end

--- Get the ownership-bearing identity captured when the customer opened the coin modal.
function M.get_waiting_identity()
  return "", _tmp_read(F_WAITING_DID) or "", ""
end

--- Set a MAC and its authoritative device identity as waiting for coin.
function M.set_waiting(mac, browser_fp, device_id, roam_fp)
  _tmp_delete(F_WAITING_READY)
  _tmp_delete(F_WAITING_CLOSING)
  _tmp_write(F_WAITING_MAC, mac)
  _tmp_write(F_WAITING_SIN, tostring(os.time()))

  device_id = _safe_identity(device_id)
  _tmp_delete(F_WAITING_FP)
  if device_id ~= "" then _tmp_write(F_WAITING_DID, device_id) else _tmp_delete(F_WAITING_DID) end
  _tmp_delete(F_WAITING_ROAM)
end

--- Tell coin nodes to close the relay while retaining the customer identity
--- until durable credit finalization has completed.
function M.close_waiting(mac)
  local waiting = normalize_mac(M.get_waiting_mac())
  mac = normalize_mac(mac)
  if not waiting or not mac or waiting ~= mac then return false end
  _tmp_write(F_WAITING_CLOSING, waiting)
  return true
end

function M.is_waiting_closing(mac)
  local waiting = normalize_mac(M.get_waiting_mac())
  local closing = normalize_mac(_tmp_read(F_WAITING_CLOSING))
  mac = normalize_mac(mac)
  return waiting ~= nil and closing == waiting and mac == waiting
end

--- Mark the waiting slot ready after an authenticated coin node has fetched it.
function M.mark_waiting_ready(mac)
  local waiting = normalize_mac(M.get_waiting_mac())
  mac = normalize_mac(mac)
  if not waiting or not mac or waiting ~= mac then return false end
  if normalize_mac(_tmp_read(F_WAITING_READY)) ~= mac then
    _tmp_write(F_WAITING_READY, mac)
  end
  return true
end

--- Check whether a coin node has acknowledged this waiting customer.
function M.is_waiting_ready(mac)
  local waiting = normalize_mac(M.get_waiting_mac())
  local ready = normalize_mac(_tmp_read(F_WAITING_READY))
  mac = normalize_mac(mac)
  return waiting ~= nil and ready == waiting and mac == waiting
end

--- Clear waiting state
function M.clear_waiting()
  _tmp_delete(F_WAITING_MAC)
  _tmp_delete(F_WAITING_SIN)
  _tmp_delete(F_WAITING_FP)
  _tmp_delete(F_WAITING_DID)
  _tmp_delete(F_WAITING_ROAM)
  _tmp_delete(F_WAITING_READY)
  _tmp_delete(F_WAITING_CLOSING)
  _tmp_delete(F_LAST_CREDIT)
end

--- Record that a coin was just credited while waiting
function M.set_last_coin_credited()
  local now = tostring(os.time())
  _tmp_write(F_LAST_CREDIT, now)
  _tmp_write(F_WAITING_SIN, now)
end

--- Get the timestamp of the last coin credited during this waiting session
function M.get_last_coin_credited()
  return tonumber(_tmp_read(F_LAST_CREDIT) or "0") or 0
end

--- Check if waiting has timed out
function M.check_waiting_timeout()
  local since = tonumber(_tmp_read(F_WAITING_SIN) or "") or 0
  local timeout = tonumber(db.setting("coinslot_timeout_seconds") or "") or 60
  -- Add 10s grace: timer.lua runs every 10s so without grace it can clear
  -- waiting up to 10s before the operator-configured timeout, cutting the
  -- relay while the customer still sees time on the modal countdown.
  local TIMER_GRACE_S = 10
  if since > 0 and (os.time() - since) >= (timeout + TIMER_GRACE_S) then
    local waiting = M.get_waiting_mac()
    if waiting and M.get_pending_coin(waiting) then
      local finalized = M.finalize_pending_coin(waiting)
      if not finalized then return false end
    end
    M.clear_waiting()
    return true
  end
  return false
end

--- Abuse prevention: check if MAC has too many empty opens
function M.check_abuse(mac)
  local max_opens = tonumber(db.setting("coinslot_max_empty_opens")) or 3
  local window = tonumber(db.setting("coinslot_empty_open_window_seconds")) or 300
  local cooldown = tonumber(db.setting("coinslot_empty_open_cooldown_seconds")) or 120

  -- Check cooldown first
  local cooldown_until = tonumber(db.setting("_abuse_cooldown_" .. mac) or "0")
  if cooldown_until > os.time() then
    return false, "cooldown", cooldown_until - os.time()
  end

  -- Count empty opens in window
  local count_key = "_empty_opens_" .. mac
  local first_key = "_empty_opens_first_" .. mac
  local count = tonumber(db.setting(count_key) or "0")
  local first_time = tonumber(db.setting(first_key) or "0")

  -- Reset if window expired
  if first_time > 0 and (os.time() - first_time) > window then
    db.set_runtime_setting(count_key, "0")
    db.set_runtime_setting(first_key, "0")
    return true
  end

  if count >= max_opens then
    -- Set cooldown
    db.set_runtime_setting("_abuse_cooldown_" .. mac, tostring(os.time() + cooldown))
    db.set_runtime_setting(count_key, "0")
    db.set_runtime_setting(first_key, "0")
    return false, "max_reached", cooldown
  end

  return true
end

--- Record an empty open (opened coin modal but didn't insert)
function M.record_empty_open(mac)
  local count_key = "_empty_opens_" .. mac
  local first_key = "_empty_opens_first_" .. mac
  local count = tonumber(db.setting(count_key) or "0")
  if count == 0 then
    db.set_runtime_setting(first_key, tostring(os.time()))
  end
  db.set_runtime_setting(count_key, tostring(count + 1))
end

--- Free time: check eligibility and grant
function M.claim_free_time(mac, browser_fp, device_id, roam_fp)
  local enabled = db.setting("free_time_enabled")
  if enabled ~= "1" then
    return false, "disabled"
  end

  local minutes = tonumber(db.setting("free_time_minutes")) or 0
  if minutes <= 0 then
    return false, "no_minutes_configured"
  end

  local daily_limit = tonumber(db.setting("free_time_daily_limit")) or 1
  local today = os.date("%Y-%m-%d")
  local claim_key = "_free_time_" .. mac .. "_" .. today

  -- Check schedule
  local sched_days = db.setting("free_time_schedule_days") or "all"
  local sched_start = db.setting("free_time_schedule_start") or "00:00"
  local sched_end = db.setting("free_time_schedule_end") or "23:59"

  if sched_days ~= "all" then
    local day_names = {"sun","mon","tue","wed","thu","fri","sat"}
    local today_day = day_names[tonumber(os.date("%w")) + 1]
    if not sched_days:find(today_day) then
      return false, "not_scheduled_day"
    end
  end

  local now_time = os.date("%H:%M")
  if now_time < sched_start or now_time > sched_end then
    return false, "outside_schedule"
  end

  -- Reserve the daily claim atomically before crediting the session. This
  -- prevents two simultaneous requests from both passing the daily limit.
  local reserved, reserve_err = db.reserve_free_time_claim(claim_key, daily_limit)
  if not reserved then
    return false, reserve_err or "persistence_failed"
  end

  -- Grant free time
  local token = M.credit(mac, minutes, 0, "free_time", browser_fp, device_id, roam_fp)
  local persisted = db.sync_on_credit("free-time")
  if not persisted then return false, "persistence_failed" end
  return true, minutes, token
end

--- Voucher: redeem a voucher code for a MAC
function M.redeem_voucher(mac, code, browser_fp, device_id, roam_fp)
  local claimed, voucher, claim_err = db.redeem_voucher_credit(mac, code)
  if not claimed then return false, claim_err end
  local credited_mac = voucher.redeemed_by_mac or mac

  local status = M.get_status(credited_mac)
  if status.connected then
    M.allow_mac(credited_mac)
  end

  local token = db.token_mint(credited_mac)
  bind_session_identity(token, credited_mac, device_id)

  local persisted = db.sync_on_credit("voucher")
  if not persisted then return false, "persistence_failed" end
  return true, voucher.minutes, token
end

--- Auto-pause: check for disconnected clients and pause them
function M.auto_pause_check()
  local auto_pause_enabled = db.setting("auto_pause_on_disconnect") == "1"
  local auto_resume_enabled = db.setting("auto_resume_on_reconnect") == "1"
  local now = os.time()
  local paused_count = 0
  local resumed_count = 0

  -- Get all active (non-paused) sessions
  local active = db.query(
    "SELECT mac FROM sessions WHERE expires_at > ? AND paused = 0", now
  )

  -- Do not interpret a missing/failed wireless interface scan as a customer
  -- disconnect. Wait for the router WiFi subsystem to become observable.
  if not clients.wifi_observation_available() then
    for _, row in ipairs(active) do
      db.set_runtime_setting("_disconnect_grace_" .. row.mac, "0")
    end
    return 0, 0
  end

  -- Only sessions paused by the disconnect handler may be resumed here.
  -- Manual pauses remain paused until the customer explicitly resumes them.
  if auto_resume_enabled then
    local auto_paused = db.query([[
      SELECT mac FROM sessions
      WHERE paused = 1 AND auto_paused = 1 AND minutes_remaining > 0
        AND (valid_until = 0 OR valid_until > ?)
    ]], now)
    for _, row in ipairs(auto_paused) do
      local resumed = M.resume_auto_paused(row.mac, true)
      if resumed then resumed_count = resumed_count + 1 end
    end
  end

  if not auto_pause_enabled then
    for _, row in ipairs(active) do
      db.set_runtime_setting("_disconnect_grace_" .. row.mac, "0")
    end
    return 0, resumed_count
  end

  for _, row in ipairs(active) do
    local mac = row.mac
    local grace_key = "_disconnect_grace_" .. mac
    local link_key = session_link_key(mac)
    local link_kind = clients.connection_kind(mac)
    local remembered_link = db.setting(link_key) or ""
    local confirmed_disconnected = false

    if link_kind == "wifi" or link_kind == "bridge" then
      -- A live station or a live external bridge entry cancels a pending
      -- pause. Remember the route so a missing bridge entry cannot pause a
      -- session that was never confirmed on this router's own WiFi.
      remember_session_link(mac, link_kind)
      db.set_runtime_setting(grace_key, "0")
    elseif link_kind == "wifi_stale" then
      -- The station is absent from iw station dump, and only this router's
      -- own WiFi bridge entry remains. This is a confirmed local disconnect.
      remember_session_link(mac, "wifi")
      confirmed_disconnected = true
    elseif remembered_link == "wifi" then
      -- No station/FDB entry remains after a session previously confirmed on
      -- this router's WiFi. Start/continue the 10-second grace period.
      confirmed_disconnected = true
    else
      -- Unknown or external-AP state: do not auto-pause. A bridge FDB entry
      -- may age out while a client is idle, so absence is not proof here.
      db.set_runtime_setting(grace_key, "0")
    end

    if confirmed_disconnected then
      local grace_start = tonumber(db.setting(grace_key) or "0")

      if grace_start == 0 then
        -- Start the 10-second disconnect grace period.
        db.set_runtime_setting(grace_key, tostring(now))
      elseif (now - grace_start) >= AUTO_PAUSE_GRACE_SECONDS then
        -- Grace period expired; pause only after confirmed local-WiFi loss.
        local paused = M.pause(mac, true)
        if paused then
          db.set_runtime_setting(grace_key, "0")
          paused_count = paused_count + 1
        end
      end
    end
  end

  return paused_count, resumed_count
end

return M
