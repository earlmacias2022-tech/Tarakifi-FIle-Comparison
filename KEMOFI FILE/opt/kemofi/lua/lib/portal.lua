--- KemoFi Portal API
-- Handles portal status, coin insertion, voucher redemption, pause/resume,
-- free time, and multi-layer device fingerprint identity resolution.
local db = require("lib.db")
local session = require("lib.session")
local json = require("lib.json")
local util = require("lib.util")
local vendor = require("lib.vendor")
local rate_config = require("lib.rates")
local capabilities = require("lib.capabilities")
local M = {}

-- The ESP normally reports every 30 seconds. Allow one delayed/retried
-- heartbeat before showing the coinslot as offline to customers.
local COINSLOT_ONLINE_WINDOW_SECONDS = 90

--- GET /api/portal/branding
--- Public, minimal branding data used before admin authentication.
function M.branding(env)
  local settings = db.settings({
    "business_name", "portal_name", "portal_footer_text", "portal_footer_link",
    "portal_logo_file", "portal_logo_filename", "portal_logo_version", "portal_icon_set"
  })
  local logo = settings.portal_logo_file or settings.portal_logo_filename or ""
  if type(logo) ~= "string" or not logo:match("^logo%.[%w]+$") then
    logo = ""
  end
  return 200, json.encode({
    business_name = settings.business_name or "KemoFi LiteV2",
    portal_name = settings.portal_name or "KemoFi LiteV2 WiFi",
    portal_footer_text = settings.portal_footer_text or "",
    portal_footer_link = settings.portal_footer_link or "https://kemofi.com/",
    portal_logo_file = logo,
    portal_logo_version = settings.portal_logo_version or "",
    portal_icon_set = settings.portal_icon_set or "classic"
  })
end

local TMP_DIR = os.getenv("KEMOFI_TMP_DIR") or "/tmp/kemofi"
local PORTAL_STATUS_SETTING_KEYS = {
  "portal_hide_device_info",
  "license_status",
  "trial_started_at",
  "_trial_expires_at",
  "portal_show_voucher",
  "portal_show_coin",
  "business_name",
  "portal_show_business_name",
  "portal_name",
  "portal_footer_text",
  "portal_footer_link",
  "portal_theme",
  "portal_icon_set",
  "free_time_enabled",
  "free_time_minutes",
  "portal_coin_sound_enabled",
  "portal_tick_sound_enabled",
  "portal_coin_sound_file",
  "portal_tick_sound_file",
  "portal_logo_filename",
  "portal_logo_file",
  "portal_logo_version",
  "portal_hero_file",
  "portal_hero_version",
  "coinslot_busy_lock",
  "auto_resume_on_reconnect",
}

-- Immutable firmware defaults. Admin uploads may override these filenames.
local DEFAULT_COIN_SOUND_FILE = "coin_sound.mp3"
local DEFAULT_TICK_SOUND_FILE = "tick_sound.mp3"
local PORTAL_ICON_SETS = {
  classic = true, outline = true, solid = true, minimal = true,
  rounded = true, duotone = true, neon = true, pixel = true
}
local function portal_icon_set(value)
  local icon_set = tostring(value or "")
  return PORTAL_ICON_SETS[icon_set] and icon_set or "classic"
end
local function sound_file_setting(value, fallback)
  if type(value) == "string" and value ~= "" then return value end
  return fallback
end

local function safe_identity(value)
  if type(value) ~= "string" or value == "" or #value > 128 then return "" end
  if not value:match("^[%w_%-]+$") then return "" end
  return value
end

local function same_mac(left, right)
  left = tostring(left or ""):lower()
  right = tostring(right or ""):lower()
  return left ~= "" and left == right
end

local function coin_wait_state(mac, busy_lock)
  local waiting = session.get_waiting_mac()
  if not waiting or waiting == "" then return false, false end
  if same_mac(waiting, mac) then
    return false, session.is_waiting_ready(mac)
  end
  return busy_lock, false
end

local function waiting_flag_path(mac)
  return TMP_DIR .. "/was_waiting_" .. tostring(mac or ""):gsub(":", "")
end

local function license_required()
  local allowed, license_status = vendor.customer_access_allowed()
  if allowed then return nil end
  return 403, json.encode({
    error = "license_required",
    license_status = license_status,
    message = "Activate a license to provide customer internet access."
  })
end

--- Parse kemofi_session cookie value from cookie string
local function get_cookie(cookie_str, name)
  if not cookie_str then return nil end
  local val = cookie_str:match(name .. "=([^;]+)")
  return val
end

--- Build extra_headers table with Set-Cookie for session token
local function make_cookie_headers(token)
  if not token or token == '' then return nil end
  return {['Set-Cookie'] = 'kemofi_token=' .. token .. '; Path=/; Max-Age=2592000; HttpOnly; SameSite=Lax'}
end

--- Resolve the effective MAC using ownership-bearing secrets and the live MAC.
--- Returns: effective_mac, token, is_rebind (bool)
local function resolve_mac(env, params)
  local current_mac = env.client_mac
  local cookie_token = get_cookie(env.headers and env.headers['cookie'] or '', 'kemofi_token')
  local browser_fp = ''
  local device_id = (params and params.device_id) or (env.device_id) or ''
  if device_id == '' then
    device_id = get_cookie(env.headers and env.headers['cookie'] or '', 'kemofi_device_id') or ''
  end
  device_id = safe_identity(device_id)
  local roam_fp = ''

  -- Also check cookie from env directly (set by handler)
  if not cookie_token or cookie_token == '' then
    cookie_token = env.session_token or ''
  end

  -- Stored identity cannot grant network access without a live request MAC.
  if not current_mac or current_mac == "" then
    return nil, nil, false, browser_fp, device_id, roam_fp, true
  end

  local resolved_mac, token, match_type = db.resolve_identity(cookie_token, '', device_id, current_mac)
  local access_allowed = vendor.customer_access_allowed()

  -- A valid KemoFi HttpOnly token is the primary roaming proof. iPhone CNA
  -- storage and canvas fingerprints can change between SSIDs, so those values
  -- are retained as supporting bindings but never block a token-backed move.
  local is_rebind = false
  if access_allowed and resolved_mac and current_mac and resolved_mac ~= current_mac then
    local resolved_status = session.get_status(resolved_mac)
    local trusted_identity = match_type == "cookie" or match_type == "device_id"
    if trusted_identity and (resolved_status.connected or resolved_status.paused) then
      local ok, new_token = session.rebind_mac(
        resolved_mac, current_mac, "", device_id, ""
      )
      resolved_mac = current_mac
      if ok then
        token = new_token or token
        is_rebind = true
      else
        -- Never overwrite an independent paid/blocked target. MAC-based status
        -- still lets that device use its own session without receiving a token.
        token = nil
      end
    else
      resolved_mac = current_mac
      token = nil
    end
  end

  -- Passive browser, canvas, hostname, and roaming fingerprints never grant
  -- access. Only the server token or the unique random device ID may rebind a
  -- paid session to a new live MAC.
  return resolved_mac, token, is_rebind, browser_fp, device_id, roam_fp, false
end

--- GET /api/portal/status
function M.status(env, params)
  local mac, token, is_rebind, browser_fp, device_id, roam_fp, roaming_pending =
    resolve_mac(env, params)
  local settings = db.settings(PORTAL_STATUS_SETTING_KEYS)

  if not mac then
    local server_time = os.time()
    local hide = settings.portal_hide_device_info == "1"
    local ls = settings.license_status or "trial"
    local te = vendor.trial_is_expired(settings)
    local coinslot_busy = coin_wait_state(nil, settings.coinslot_busy_lock ~= "0")
    local resp = {
      connected = false,
      show_voucher = settings.portal_show_voucher == "1",
      show_coin = settings.portal_show_coin ~= "0",
      client_ip = env.client_ip,
      server_time = server_time,
      remaining_seconds = 0,
      business_name = settings.business_name or "KemoFi LiteV2",
      show_business_name = settings.portal_show_business_name == "1",
      portal_name = settings.portal_name or "KemoFi LiteV2 WiFi",
      portal_footer_text = settings.portal_footer_text or "",
      portal_footer_link = settings.portal_footer_link or "https://kemofi.com/",
      portal_theme = settings.portal_theme or "dark",
      portal_icon_set = portal_icon_set(settings.portal_icon_set),
      free_time_enabled = settings.free_time_enabled == "1",
      free_time_minutes = tonumber(settings.free_time_minutes) or 5,
      hide_device_info = hide,
      portal_coin_sound_enabled = settings.portal_coin_sound_enabled ~= "0",
      portal_tick_sound_enabled = settings.portal_tick_sound_enabled ~= "0",
      portal_coin_sound_file = sound_file_setting(settings.portal_coin_sound_file, DEFAULT_COIN_SOUND_FILE),
      portal_tick_sound_file = sound_file_setting(settings.portal_tick_sound_file, DEFAULT_TICK_SOUND_FILE),
      portal_logo_file = settings.portal_logo_file or settings.portal_logo_filename or nil,
      portal_logo_version = settings.portal_logo_version or nil,
      portal_hero_file = settings.portal_hero_file or nil,
      portal_hero_version = settings.portal_hero_version or nil,
      roaming_pending = roaming_pending or false,
      error = "no_mac",
      wan_online = M._check_wan(),
      coinslot_online = M._check_coinslot(),
      coinslot_busy = coinslot_busy,
      coinslot_ready = false,
      pause_limit = 0,
      pauses_used = 0,
      valid_until = 0,
      validity_remaining_seconds = 0,
      is_trial = (ls == "trial"),
      trial_expired = te,
      capabilities = capabilities.get()
    }
    return 200, json.encode(resp)
  end

  local status = session.get_status(mac)
  -- A status request is the fastest reliable reconnect signal from a customer
  -- device. Resume only sessions paused by the automatic disconnect handler.
  local auto_resumed = false
  if status.paused and status.auto_paused and settings.auto_resume_on_reconnect == "1" then
    auto_resumed = session.resume_auto_paused(mac, true)
    if auto_resumed then status = session.get_status(mac) end
  end
  local server_time = os.time()
  local remaining_seconds = 0
  if status.connected and not status.member then
    remaining_seconds = math.max(0, math.floor((tonumber(status.expires_at) or server_time) - server_time))
  elseif status.paused then
    remaining_seconds = math.max(0, math.floor((tonumber(status.minutes_remaining) or 0) * 60))
  end
  local hide = settings.portal_hide_device_info == "1"

  local license_status = settings.license_status or "trial"
  local trial_expired = vendor.trial_is_expired(settings)
  local coinslot_busy, coinslot_ready = coin_wait_state(
    mac, settings.coinslot_busy_lock ~= "0"
  )

  local resp = {
    connected = status.connected or false,
    paused = status.paused or false,
    minutes_remaining = status.minutes_remaining or 0,
    expires_at = status.expires_at,
    server_time = server_time,
    remaining_seconds = remaining_seconds,
    member = status.member or false,
    unlimited = status.unlimited or false,
    auto_paused = status.auto_paused or false,
    auto_resume_enabled = settings.auto_resume_on_reconnect == "1",
    auto_resumed = auto_resumed or false,
    pause_limit = tonumber(status.pause_limit) or 0,
    pauses_used = tonumber(status.pauses_used) or 0,
    valid_until = tonumber(status.valid_until) or 0,
    validity_remaining_seconds = tonumber(status.validity_remaining_seconds) or 0,
    identity_rebound = is_rebind or false,
    roaming_pending = roaming_pending or false,
    mac = mac,
    client_ip = env.client_ip,
    business_name = settings.business_name or "KemoFi LiteV2",
    show_business_name = settings.portal_show_business_name == "1",
    portal_name = settings.portal_name or "KemoFi LiteV2 WiFi",
    portal_footer_text = settings.portal_footer_text or "",
    portal_footer_link = settings.portal_footer_link or "https://kemofi.com/",
    portal_theme = settings.portal_theme or "dark",
    portal_icon_set = portal_icon_set(settings.portal_icon_set),
    show_voucher = settings.portal_show_voucher == "1",
    show_coin = settings.portal_show_coin ~= "0",
    free_time_enabled = settings.free_time_enabled == "1",
    free_time_minutes = tonumber(settings.free_time_minutes) or 5,
    hide_device_info = hide,
   portal_coin_sound_enabled = settings.portal_coin_sound_enabled ~= "0",
   portal_tick_sound_enabled = settings.portal_tick_sound_enabled ~= "0",
    portal_coin_sound_file = sound_file_setting(settings.portal_coin_sound_file, DEFAULT_COIN_SOUND_FILE),
    portal_tick_sound_file = sound_file_setting(settings.portal_tick_sound_file, DEFAULT_TICK_SOUND_FILE),
    portal_logo_file = settings.portal_logo_file or settings.portal_logo_filename or nil,
    portal_logo_version = settings.portal_logo_version or nil,
    portal_hero_file = settings.portal_hero_file or nil,
    portal_hero_version = settings.portal_hero_version or nil,
    wan_online = M._check_wan(),
    coinslot_online = M._check_coinslot(),
    coinslot_busy = coinslot_busy,
    coinslot_ready = coinslot_ready,
    is_trial = (license_status == "trial"),
    trial_expired = trial_expired,
    capabilities = capabilities.get()
  }

  return 200, json.encode(resp), make_cookie_headers(token)
end

--- Read the WAN result maintained by the supervised timer.
function M._check_wan()
  return util.read_wan_status()
end
function M._check_coinslot()
  local now = os.time()
  local count = db.scalar("SELECT COUNT(*) FROM coin_nodes WHERE last_heartbeat > ?", now - COINSLOT_ONLINE_WINDOW_SECONDS) or 0
  return count > 0
end

local function rate_duration_label(minutes)
  local total = math.max(0, math.floor(tonumber(minutes) or 0))
  local days = math.floor(total / 1440)
  local hours = math.floor((total % 1440) / 60)
  local remaining = total % 60
  local parts = {}
  if days > 0 then parts[#parts + 1] = days .. " day" .. (days == 1 and "" or "s") end
  if hours > 0 then parts[#parts + 1] = hours .. " hour" .. (hours == 1 and "" or "s") end
  if remaining > 0 or #parts == 0 then
    parts[#parts + 1] = remaining .. " minute" .. (remaining == 1 and "" or "s")
  end
  return table.concat(parts, " ")
end

local function rate_validity_label(value, unit)
  value = math.max(0, math.floor(tonumber(value) or 0))
  if value == 0 then return "Unlimited" end
  local names = {D = "day", H = "hour", M = "minute"}
  local name = names[tostring(unit or "D"):upper()] or "day"
  return value .. " " .. name .. (value == 1 and "" or "s")
end

local function rate_pause_label(value)
  value = math.max(0, math.floor(tonumber(value) or 0))
  if value == 0 then return "Unlimited" end
  return "Up to " .. value .. " pause" .. (value == 1 and "" or "s")
end

--- GET /api/portal/rates
function M.rates(env)
  local rates = {}
  local settings = db.settings({
    "business_name",
    "portal_show_business_name",
    "portal_name",
    "portal_footer_text",
    "portal_footer_link",
    "portal_rates",
    "portal_show_rates",
    "portal_icon_set",
    "coinslot_timeout_seconds",
    "coin_min_per_php"
  })
  local rates_str = settings.portal_rates or ""
  local show_rates = settings.portal_show_rates or "1"
  local flat_rate = rate_config.flat_rate(settings.coin_min_per_php)

  if show_rates == "1" then
    if flat_rate > 0 then
      -- The flat override is the effective coin policy. Do not show the
      -- configured tiers at the same time because that would mislead a
      -- customer about the minutes, pause limit, and validity they receive.
      rates[1] = {
        php = 1,
        minutes = flat_rate,
        amount_label = "Every ₱1",
        time_label = rate_duration_label(flat_rate),
        pause_limit = 0,
        pause_limit_label = "Unlimited",
        validity_value = 0,
        validity_unit = "D",
        validity_label = "Unlimited",
        flat_rate = true,
        label = "Every ₱1 = " .. rate_duration_label(flat_rate)
      }
    else
      local configured_rates = rate_config.parse(rates_str) or {}
      for _, row in ipairs(configured_rates) do
        rates[#rates + 1] = {
          php = row.php,
          minutes = row.minutes,
          amount_label = "₱" .. row.php,
          time_label = rate_duration_label(row.minutes),
          pause_limit = row.pause_limit,
          pause_limit_label = rate_pause_label(row.pause_limit),
          validity_value = row.validity_value,
          validity_unit = row.validity_unit,
          validity_label = rate_validity_label(row.validity_value, row.validity_unit),
          label = row.php .. " PHP = " .. rate_duration_label(row.minutes)
        }
      end
    end
  end
  return 200, json.encode({
    rates = rates,
    show_rates = show_rates == "1",
    flat_rate_override = flat_rate > 0 and flat_rate or 0,
    business_name = settings.business_name or "KemoFi LiteV2",
    show_business_name = settings.portal_show_business_name == "1",
    portal_name = settings.portal_name or "KemoFi LiteV2 WiFi",
    portal_footer_text = settings.portal_footer_text or "",
    portal_footer_link = settings.portal_footer_link or "https://kemofi.com/",
    timeout_seconds = tonumber(settings.coinslot_timeout_seconds) or 60,
    portal_icon_set = portal_icon_set(settings.portal_icon_set)
  })
end

--- POST /api/portal/insert-coin
function M.insert_coin(env, params)
  local denied_status, denied_body = license_required()
  if denied_status then return denied_status, denied_body end
  local mac, token, _, browser_fp, device_id, roam_fp = resolve_mac(env, params)
  if not mac then
    return 400, json.encode({error = "no_mac"})
  end
  if not M._check_wan() then
    return 503, json.encode({
      error = "wan_offline",
      message = "Internet is temporarily unavailable. Please try again later."
    })
  end

  -- Check if device is blocked
  local device = db.row("SELECT * FROM known_devices WHERE mac = ?", mac)
  if device and device.blocked == 1 then
    return 403, json.encode({error = "blocked", message = "This device has been blocked."})
  end

  -- Abuse prevention: check empty opens
  local allowed, reason, remaining = session.check_abuse(mac)
  if not allowed then
    if reason == "cooldown" then
      return 429, json.encode({
        error = "cooldown",
        message = "Too many attempts. Please wait " .. remaining .. " seconds.",
        cooldown_seconds = remaining
      })
    else
      return 429, json.encode({
        error = "abuse_limit",
        message = "Too many empty attempts. You are temporarily blocked.",
        cooldown_seconds = remaining or 120
      })
    end
  end

  -- Coin slot busy lock: check if someone else is already waiting
  local busy_lock = db.setting("coinslot_busy_lock") ~= "0"
  if busy_lock then
    local current_waiting = session.get_waiting_mac()
    if current_waiting and current_waiting ~= "" and not same_mac(current_waiting, mac) then
      if not session.check_waiting_timeout() then
        return 409, json.encode({
          error = "another_customer_waiting",
          message = "Another customer is currently inserting a coin. Please wait."
        })
      end
    end
  end

  -- Keep the browser identity with the waiting MAC so a physical coin event can
  -- bind the paid session across different SSIDs and randomized MAC addresses.
  session.set_waiting(mac, browser_fp, device_id, roam_fp)

  return 200, json.encode({
    status = "waiting",
    mac = mac,
    timeout_seconds = tonumber(db.setting("coinslot_timeout_seconds")) or 60
  }), make_cookie_headers(token)
end

--- POST /api/portal/cancel-insert
function M.cancel_insert(env, params)
  local denied_status, denied_body = license_required()
  local mac, token, _, browser_fp, device_id, roam_fp = resolve_mac(env, params)
  local waiting = session.get_waiting_mac()
  if denied_status then
    if mac and same_mac(waiting, mac) then
      session.clear_waiting()
      os.remove(waiting_flag_path(mac))
    end
    return denied_status, denied_body
  end
  if mac and same_mac(waiting, mac) then
    local was_ready = session.is_waiting_ready(mac)
    local pending = session.get_pending_coin(mac)
    if pending then
      session.close_waiting(mac)
      local ok, finalized, mode, new_token = session.finalize_pending_coin(
        mac, browser_fp, device_id, roam_fp
      )
      if not ok then
        return 500, json.encode({
          error = "activation_pending",
          message = "Your coin credit is saved. Activation will retry automatically."
        })
      end
      session.clear_waiting()
      os.remove(waiting_flag_path(mac))
      return 200, json.encode({
        status = mode == "paused" and "paused" or "activated",
        minutes_added = tonumber(finalized.minutes) or 0,
        coin_count = tonumber(finalized.coin_count) or 0
      }), make_cookie_headers(new_token or token)
    end
    session.clear_waiting()
    -- Record as empty open for abuse prevention
    if was_ready then session.record_empty_open(mac) end
  end
  return 200, json.encode({status = "cancelled"}), make_cookie_headers(token)
end

--- POST /api/portal/finish-coin
function M.finish_coin(env, params)
  local denied_status, denied_body = license_required()
  if denied_status then return denied_status, denied_body end
  local mac, token, _, browser_fp, device_id, roam_fp = resolve_mac(env, params)
  if not mac then return 400, json.encode({error = "no_mac"}) end

  local waiting_for_mac = same_mac(session.get_waiting_mac(), mac)
  local waiting_was_ready = waiting_for_mac and session.is_waiting_ready(mac)
  if waiting_for_mac then
    session.close_waiting(mac)
  end

  local ok, pending, mode, new_token = session.finalize_pending_coin(
    mac, browser_fp, device_id, roam_fp
  )
  if not ok then
    if mode == "no_pending_credit" then
      if waiting_for_mac then
        session.clear_waiting()
        if waiting_was_ready then session.record_empty_open(mac) end
      end
      os.remove(waiting_flag_path(mac))
      return 200, json.encode({
        status = "empty",
        error = "no_pending_credit",
        message = "Insert a coin before going online."
      }), make_cookie_headers(token)
    end
    return 500, json.encode({
      error = "activation_pending",
      message = "Your coin credit is saved. Activation will retry automatically."
    })
  end

  if same_mac(session.get_waiting_mac(), mac) then session.clear_waiting() end
  os.remove(waiting_flag_path(mac))
  return 200, json.encode({
    status = mode == "paused" and "paused" or "activated",
    minutes_added = tonumber(pending.minutes) or 0,
    coin_count = tonumber(pending.coin_count) or 0
  }), make_cookie_headers(new_token or token)
end

--- POST /api/portal/pause
function M.pause(env, params)
  local mac, token = resolve_mac(env, params)
  if not mac then
    return 400, json.encode({error = "no_mac"})
  end
  local penalty = tonumber(db.setting("pause_penalty_minutes")) or 0
  local ok, err = session.pause(mac)
  if ok then
    local resp = {status = "paused"}
    if penalty > 0 then
      resp.penalty_applied = penalty
      resp.message = penalty .. " minute(s) deducted as pause penalty."
    end
    return 200, json.encode(resp), make_cookie_headers(token)
  elseif err == "not_enough_time" then
    return 400, json.encode({error = "not_enough_time", message = "Not enough time remaining to pause. Need more than " .. penalty .. " minute(s)."})
  elseif err == "pause_limit_reached" then
    return 400, json.encode({error = "pause_limit_reached", message = "This rate has reached its pause limit."})
  elseif err == "persistence_failed" then
    return 500, json.encode({error = err, message = "The paused session was not saved permanently."})
  else
    return 400, json.encode({error = "cannot_pause", message = "No active session to pause"})
  end
end

--- POST /api/portal/resume
function M.resume(env, params)
  local denied_status, denied_body = license_required()
  if denied_status then return denied_status, denied_body end
  local mac, token = resolve_mac(env, params)
  if not mac then
    return 400, json.encode({error = "no_mac"})
  end
  local resumed, resume_err = session.resume(mac)
  if resumed then
    return 200, json.encode({status = "resumed"}), make_cookie_headers(token)
  elseif resume_err == "validity_expired" then
    return 400, json.encode({error = "validity_expired", message = "This rate's validity period has expired."})
  elseif resume_err == "persistence_failed" then
    return 500, json.encode({error = resume_err, message = "The resumed session was not saved permanently."})
  else
    return 400, json.encode({error = "cannot_resume", message = "No paused session to resume"})
  end
end

--- GET /api/portal/coin-status
function M.coin_status(env, params)
  local mac, token = resolve_mac(env, params)
  if not mac then
    return 200, json.encode({waiting = false})
  end
  local waiting = session.get_waiting_mac()
  if not same_mac(waiting, mac) then
    -- waiting_mac is not set for this device.
    -- Only return timeout=true if we previously set a was_waiting flag for this MAC,
    -- meaning the modal was actually opened and the server cleared it (timeout/cancel).
    -- If no flag exists, this is just an early poll before insert-coin completes — return neutral.
    local flag_file = waiting_flag_path(mac)
    local flag_fh = io.open(flag_file, "r")
    if flag_fh then
      flag_fh:close()
      -- Flag exists: waiting was previously set for this MAC and has now been cleared
      os.remove(flag_file)
      local status = session.get_status(mac)
      return 200, json.encode({
        waiting = false,
        received = false,
        finalized = status.connected or status.paused,
        connected = status.connected,
        paused = status.paused,
        pause_limit = tonumber(status.pause_limit) or 0,
        pauses_used = tonumber(status.pauses_used) or 0,
        valid_until = tonumber(status.valid_until) or 0,
        validity_remaining_seconds = tonumber(status.validity_remaining_seconds) or 0,
        timeout = not status.connected and not status.paused
      }), make_cookie_headers(token)
    else
      return 200, json.encode({
        waiting = false,
        received = false,
        coinslot_busy = waiting ~= nil and
          db.setting("coinslot_busy_lock") ~= "0"
      })
    end
  end
  -- waiting == mac: write was_waiting flag so we can detect timeout later
  local flag_file = waiting_flag_path(mac)
  local flag_fh = io.open(flag_file, "w")
  if flag_fh then flag_fh:write("1"); flag_fh:close() end
  -- Still waiting: report the durable pending total. It is not an active
  -- session and does not grant network access until finalization.
  local pending = session.get_pending_coin(mac)
  if pending then
    return 200, json.encode({
      waiting = true,
      received = true,
      last_credited_at = tonumber(pending.updated_at) or 0,
      pending_minutes = tonumber(pending.minutes) or 0,
      pending_amount_php = tonumber(pending.amount_php) or 0,
      pending_coin_count = tonumber(pending.coin_count) or 0,
      pending_pause_limit = tonumber(pending.pause_limit) or 0,
      pending_valid_until = tonumber(pending.valid_until) or 0,
      pending_validity_remaining_seconds = (tonumber(pending.valid_until) or 0) > 0 and
        math.max(0, (tonumber(pending.valid_until) or 0) - os.time()) or 0,
      coinslot_ready = session.is_waiting_ready(mac)
    }), make_cookie_headers(token)
  end
  return 200, json.encode({
    waiting = true,
    received = false,
    coinslot_ready = session.is_waiting_ready(mac)
  })
end

--- POST /api/portal/free-time
function M.free_time(env, params)
  local denied_status, denied_body = license_required()
  if denied_status then return denied_status, denied_body end
  local mac, token, _, browser_fp, device_id, roam_fp = resolve_mac(env, params)
  if not mac then
    return 400, json.encode({error = "no_mac"})
  end
  local ok, result, new_token = session.claim_free_time(
    mac, browser_fp, device_id, roam_fp
  )
  if ok then
    return 200, json.encode({status = "ok", success = true, minutes = result}), make_cookie_headers(new_token or token)
  elseif result == "daily_limit_reached" then
    return 200, json.encode({
      status = "already_claimed",
      already_claimed = true,
      message = "You have already claimed your free time today."
    }), make_cookie_headers(token)
  elseif result == "persistence_failed" then
    return 500, json.encode({error = result, message = "Free time could not be saved permanently."})
  else
    local messages = {
      disabled = "Free WiFi is not available.",
      no_minutes_configured = "Free WiFi is not configured.",
      daily_limit_reached = "You have already claimed your free time today.",
      not_scheduled_day = "Free WiFi is not available today.",
      outside_schedule = "Free WiFi is only available during scheduled hours."
    }
    return 400, json.encode({error = result, message = messages[result] or "Cannot claim free time."})
  end
end

--- POST /api/portal/redeem-voucher
function M.redeem_voucher(env, params)
  local denied_status, denied_body = license_required()
  if denied_status then return denied_status, denied_body end
  local mac, token, _, browser_fp, device_id, roam_fp = resolve_mac(env, params)
  if not mac then
    return 400, json.encode({error = "no_mac"})
  end
  if not M._check_wan() then
    return 503, json.encode({
      error = "wan_offline",
      message = "Internet is temporarily unavailable. Please try again later."
    })
  end
  local code = params.code
  if not code or code == "" then
    return 400, json.encode({error = "no_code", message = "Please enter a voucher code."})
  end
  local ok, result, new_token = session.redeem_voucher(
    mac, code, browser_fp, device_id, roam_fp
  )
  if ok then
    return 200, json.encode({status = "ok", success = true, minutes = result}), make_cookie_headers(new_token or token)
  elseif result == "persistence_failed" then
    return 500, json.encode({error = result, message = "Voucher redemption could not be saved permanently."})
  else
    local messages = {
      empty_code = "Please enter a voucher code.",
      invalid_or_used = "Invalid or already used voucher code.",
      expired = "This voucher has expired."
    }
    return 400, json.encode({error = result, message = messages[result] or "Cannot redeem voucher."})
  end
end

return M
