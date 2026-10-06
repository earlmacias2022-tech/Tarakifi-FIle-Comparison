--- TarakiFi Portal API
-- Handles portal status, coin insertion, voucher redemption, pause/resume,
-- free time, and ownership-safe device identity resolution.
local db = require("lib.db")
local session = require("lib.session")
local json = require("lib.json")
local util = require("lib.util")
local vendor = require("lib.vendor")
local M = {}

local TMP_DIR = os.getenv("TARAKIFI_TMP_DIR") or "/tmp/tarakifi"
local PORTAL_STATUS_SETTING_KEYS = {
  "portal_hide_device_info",
  "portal_hide_pause_button",
  "license_status",
  "trial_started_at",
  "_trial_expires_at",
  "portal_show_voucher",
  "portal_show_coin",
  "business_name",
  "portal_show_business_name",
  "portal_name",
  "portal_footer_text",
  "portal_theme",
  "free_time_enabled",
  "free_time_minutes",
  "portal_coin_sound_enabled",
  "portal_tick_sound_enabled",
  "portal_logo_file",
  "portal_hero_file",
  "portal_asset_version",
  "portal_coin_sound_file",
  "portal_tick_sound_file",
  "coinslot_busy_lock",
}

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

--- Parse tarakifi_session cookie value from cookie string
local function get_cookie(cookie_str, name)
  if not cookie_str then return nil end
  local val = cookie_str:match(name .. "=([^;]+)")
  return val
end

--- Build extra_headers table with Set-Cookie for session token
local function make_cookie_headers(token)
  if not token or token == '' then return nil end
  return {['Set-Cookie'] = 'tarakifi_token=' .. token .. '; Path=/; Max-Age=2592000; HttpOnly; SameSite=Lax'}
end

--- Resolve the effective MAC using only ownership-bearing secrets and live MAC.
--- Returns: effective_mac, token, is_rebind (bool)
local function resolve_mac(env, params)
  local current_mac = env.client_mac
  local cookie_header = env.headers and env.headers['cookie'] or ''
  local cookie_token = get_cookie(cookie_header, 'tarakifi_token')
  local requested_device_id = params and params.device_id or ''
  if requested_device_id == '' then requested_device_id = env.device_id or '' end
  if requested_device_id == '' then
    requested_device_id = get_cookie(cookie_header, 'tarakifi_device_id') or ''
  end
  local device_id = safe_identity(requested_device_id)
  local browser_fp = ''
  local roam_fp = ''

  -- Also check cookie from env directly (set by handler)
  if not cookie_token or cookie_token == '' then
    cookie_token = env.session_token or ''
  end

  -- Stored identity cannot grant network access without a live request MAC.
  if not current_mac or current_mac == "" then
    return nil, nil, false, browser_fp, device_id, roam_fp, false
  end

  local resolved_mac, token, match_type = db.resolve_identity(
    cookie_token, "", device_id, current_mac
  )
  local access_allowed = vendor.customer_access_allowed()

  -- A valid server token or random device ID proves ownership across SSIDs.
  -- Passive model, canvas, hostname, and hardware fingerprints never do.
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

  return resolved_mac, token, is_rebind, browser_fp, device_id, roam_fp, false
end

--- GET /api/portal/status
function M.status(env, params)
  local mac, token, is_rebind, browser_fp, device_id, roam_fp, roaming_pending =
    resolve_mac(env, params)
  local settings = db.settings(PORTAL_STATUS_SETTING_KEYS)

  if not mac then
    local hide = settings.portal_hide_device_info == "1"
    local ls = settings.license_status or "trial"
    local te = vendor.trial_is_expired(settings)
    local coinslot_busy = coin_wait_state(nil, settings.coinslot_busy_lock ~= "0")
    local resp = {
      connected = false,
      show_voucher = settings.portal_show_voucher == "1",
      show_coin = settings.portal_show_coin ~= "0",
      client_ip = env.client_ip,
      business_name = settings.business_name or "TarakiFi",
      show_business_name = settings.portal_show_business_name == "1",
      portal_name = settings.portal_name or "TarakiFi WiFi",
      portal_footer_text = settings.portal_footer_text or "",
      portal_theme = settings.portal_theme or "dark",
      free_time_enabled = settings.free_time_enabled == "1",
      free_time_minutes = tonumber(settings.free_time_minutes) or 5,
      hide_device_info = hide,
      hide_pause_button = settings.portal_hide_pause_button == "1",
      portal_coin_sound_enabled = settings.portal_coin_sound_enabled ~= "0",
      portal_tick_sound_enabled = settings.portal_tick_sound_enabled ~= "0",
      portal_logo_file = settings.portal_logo_file or nil,
      portal_hero_file = settings.portal_hero_file or nil,
      portal_asset_version = tonumber(settings.portal_asset_version) or 0,
      portal_coin_sound_file = settings.portal_coin_sound_file or nil,
      portal_tick_sound_file = settings.portal_tick_sound_file or nil,
      roaming_pending = roaming_pending or false,
      error = "no_mac",
      wan_online = M._check_wan(),
      coinslot_online = M._check_coinslot(),
      coinslot_busy = coinslot_busy,
      coinslot_ready = false,
      is_trial = (ls == "trial"),
      trial_expired = te
    }
    return 200, json.encode(resp)
  end

  local status = session.get_status(mac)
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
    validity_expires_at = status.validity_expires_at or 0,
    identity_rebound = is_rebind or false,
    roaming_pending = roaming_pending or false,
    mac = mac,
    client_ip = env.client_ip,
    business_name = settings.business_name or "TarakiFi",
    show_business_name = settings.portal_show_business_name == "1",
    portal_name = settings.portal_name or "TarakiFi WiFi",
    portal_footer_text = settings.portal_footer_text or "",
    portal_theme = settings.portal_theme or "dark",
    show_voucher = settings.portal_show_voucher == "1",
    show_coin = settings.portal_show_coin ~= "0",
    free_time_enabled = settings.free_time_enabled == "1",
    free_time_minutes = tonumber(settings.free_time_minutes) or 5,
    hide_device_info = hide,
    hide_pause_button = settings.portal_hide_pause_button == "1",
    portal_coin_sound_enabled = settings.portal_coin_sound_enabled ~= "0",
    portal_tick_sound_enabled = settings.portal_tick_sound_enabled ~= "0",
    portal_logo_file = settings.portal_logo_file or nil,
    portal_hero_file = settings.portal_hero_file or nil,
    portal_asset_version = tonumber(settings.portal_asset_version) or 0,
    portal_coin_sound_file = settings.portal_coin_sound_file or nil,
    portal_tick_sound_file = settings.portal_tick_sound_file or nil,
    wan_online = M._check_wan(),
    coinslot_online = M._check_coinslot(),
    coinslot_busy = coinslot_busy,
    coinslot_ready = coinslot_ready,
    is_trial = (license_status == "trial"),
    trial_expired = trial_expired
  }

  return 200, json.encode(resp), make_cookie_headers(token)
end

--- Read the WAN result maintained by the supervised timer.
function M._check_wan()
  return util.read_wan_status()
end
function M._check_coinslot()
  local now = os.time()
  local count = db.scalar("SELECT COUNT(*) FROM coin_nodes WHERE last_heartbeat > ?", now - 60) or 0
  return count > 0
end

--- GET /api/portal/rates
function M.rates(env)
  local rates = {}
  local settings = db.settings({
    "business_name",
    "portal_show_business_name",
    "portal_name",
    "portal_footer_text",
    "portal_rates",
    "portal_show_rates",
    "coinslot_timeout_seconds"
  })
  local rates_str = settings.portal_rates or ""
  local show_rates = settings.portal_show_rates or "1"

  if show_rates == "1" then
    for line in (rates_str .. "\n"):gmatch("([^\n]*)\n") do
      local php, mins = line:match("(%d+):(%d+)")
      if php and mins then
        rates[#rates + 1] = {
          php = tonumber(php),
          minutes = tonumber(mins),
          label = php .. " PHP = " .. mins .. " min"
        }
      end
    end
  end
  return 200, json.encode({
    rates = rates,
    show_rates = show_rates == "1",
    business_name = settings.business_name or "TarakiFi",
    show_business_name = settings.portal_show_business_name == "1",
    portal_name = settings.portal_name or "TarakiFi WiFi",
    portal_footer_text = settings.portal_footer_text or "",
    timeout_seconds = tonumber(settings.coinslot_timeout_seconds) or 60
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

  if same_mac(session.get_waiting_mac(), mac) then
    session.close_waiting(mac)
  end

  local ok, pending, mode, new_token = session.finalize_pending_coin(
    mac, browser_fp, device_id, roam_fp
  )
  if not ok then
    if mode == "no_pending_credit" then
      if same_mac(session.get_waiting_mac(), mac) then
        session.clear_waiting()
        session.record_empty_open(mac)
      end
      os.remove(waiting_flag_path(mac))
      return 200, json.encode({status = "empty"}), make_cookie_headers(token)
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
    return 200, json.encode({status = "ok", minutes = result}), make_cookie_headers(new_token or token)
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
  local ok, result, new_token, validity_expires_at = session.redeem_voucher(
    mac, code, browser_fp, device_id, roam_fp
  )
  if ok then
    return 200, json.encode({
      status = "ok",
      success = true,
      minutes = result,
      validity_expires_at = validity_expires_at or 0
    }), make_cookie_headers(new_token or token)
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
