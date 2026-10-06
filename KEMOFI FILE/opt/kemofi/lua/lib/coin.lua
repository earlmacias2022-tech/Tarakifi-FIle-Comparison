--- KemoFi authenticated coin controller protocol.
local db      = require("lib.db")
local session = require("lib.session")
local json    = require("lib.json")
local util    = require("lib.util")
local vendor  = require("lib.vendor")
local rate_config = require("lib.rates")
local M = {}

local function clean_text(value, max_length)
  local text = tostring(value or ""):gsub("[%z\r\n]", "")
  if #text > max_length then text = text:sub(1, max_length) end
  return text
end

local function normalize_node_id(value)
  local node_id = clean_text(value, 32):upper()
  if node_id:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then return node_id end
  return nil
end

local function normalize_mac(value)
  local mac = clean_text(value, 17):upper()
  if mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then return mac end
  return nil
end

local function constant_time_equal(left, right)
  left = tostring(left or "")
  right = tostring(right or "")
  local length = math.max(#left, #right)
  local mismatch = (#left == #right) and 0 or 1
  for index = 1, length do
    local a = left:byte(index) or 0
    local b = right:byte(index) or 0
    if a ~= b then mismatch = 1 end
  end
  return mismatch == 0
end

local function request_header(env, name)
  return clean_text(env and env.headers and env.headers[name] or "", 96)
end

local function node_by_id(node_id)
  if not node_id then return nil end
  return db.row("SELECT * FROM coin_nodes WHERE node_id = ?", node_id)
end

--- Authenticate an already registered node. Token-enrolled nodes never fall
--- back to source-IP authentication. Legacy access is limited to the exact IP
--- recorded before enrollment so the currently installed v1 firmware survives
--- the router-side migration.
local function authenticate_node(env, params)
  params = params or {}
  local node_id = normalize_node_id(
    request_header(env, "x-kemofi-node") ~= "" and
      request_header(env, "x-kemofi-node") or params.node_id
  )
  local token = request_header(env, "x-kemofi-token")
  local node = node_by_id(node_id)

  if not node and not node_id and token == "" then
    local rows = db.query([[
      SELECT * FROM coin_nodes
      WHERE ip_address = ? AND COALESCE(auth_token, '') = ''
      ORDER BY last_heartbeat DESC LIMIT 2
    ]], env.client_ip or "")
    if #rows == 1 then
      node = rows[1]
      node_id = node.node_id
    end
  end

  if not node then return nil, "unknown_node" end
  local stored_token = tostring(node.auth_token or "")
  if stored_token ~= "" then
    if token == "" or not constant_time_equal(stored_token, token) then
      return nil, "invalid_node_token"
    end
    return node, "token"
  end
  if token ~= "" then return nil, "node_not_enrolled" end
  if tostring(node.ip_address or "") ~= tostring(env.client_ip or "") then
    return nil, "legacy_ip_mismatch"
  end
  return node, "legacy"
end

local function auth_error(reason)
  return 401, json.encode({status = "unauthorized", reason = reason})
end

local function coinslot_already_bound_response()
  return 409, json.encode({
    status = "coinslot_already_bound",
    error = "coinslot_already_bound",
    message = "Only one ESP coinslot can be bound to this router. Unbind the existing coinslot before binding another."
  })
end

local function clamp_integer(value, fallback, minimum, maximum)
  local number = math.floor(tonumber(value) or fallback)
  if number < minimum then number = minimum end
  if number > maximum then number = maximum end
  return number
end

local function d_pin_for_gpio(gpio)
  local pins = {
    [16] = 0, [5] = 1, [4] = 2, [0] = 3, [2] = 4,
    [14] = 5, [12] = 6, [13] = 7, [15] = 8
  }
  return pins[gpio] or 8
end

local function append_node_settings(response, node)
  if not node then return response end
  response.node_name = tostring(node.name or "")
  response.coin_gpio = clamp_integer(node.coin_gpio, 2, 0, 16)
  response.relay_gpio = clamp_integer(node.relay_gpio, 15, 0, 16)
  response.amount_php_per_pulse = 1
  -- amount_php is retained as a compatibility alias for older ESP builds.
  response.amount_php = response.amount_php_per_pulse
  response.coin_dpin = clamp_integer(node.coin_dpin, d_pin_for_gpio(response.coin_gpio), 0, 8)
  response.relay_dpin = clamp_integer(node.relay_dpin, d_pin_for_gpio(response.relay_gpio), 0, 8)
  return response
end

-- Coinslot enrollment is intentionally limited to private LAN addresses.
-- The ESP has no user-entered bind code anymore, so never accept a brand-new
-- node registration from a public/WAN source address.
local function is_private_client_ip(value)
  local a, b, c, d = tostring(value or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if not a or not b or not c or not d or a > 255 or b > 255 or c > 255 or d > 255 then
    return false
  end
  return a == 10 or (a == 192 and b == 168) or (a == 172 and b >= 16 and b <= 31)
end

local function mint_node_token()
  for _ = 1, 8 do
    local token = util.random_token(40)
    if token and #token == 40 and
        not db.row("SELECT node_id FROM coin_nodes WHERE auth_token = ?", token) then
      return token
    end
  end
  return nil
end

--- POST /api/coin/register
function M.handle_register(env, params)
  params = params or {}
  local node_id = normalize_node_id(params.node_id)
  if not node_id then
    return 400, json.encode({status = "invalid_node_id"})
  end

  local existing = node_by_id(node_id)
  local protocol_version = math.floor(tonumber(params.protocol_version) or 1)
  if protocol_version < 1 then protocol_version = 1 end
  if protocol_version > 2 then protocol_version = 2 end
  local supplied_token = request_header(env, "x-kemofi-token")
  local migration_bind = existing and protocol_version >= 2 and
    tostring(existing.auth_token or "") == "" and
    tostring(existing.ip_address or "") == tostring(env.client_ip or "") and
    is_private_client_ip(env.client_ip)
  local legacy_reregister = existing and protocol_version < 2 and
    tostring(existing.auth_token or "") == "" and supplied_token == "" and
    tostring(existing.ip_address or "") == tostring(env.client_ip or "")
  local token_reregister = existing and tostring(existing.auth_token or "") ~= "" and
    supplied_token ~= "" and constant_time_equal(existing.auth_token, supplied_token)
  -- A freshly reset v2 ESP has lost its token, but keeps the same hardware
  -- node ID. Allow that node to re-enroll only from the router's private LAN.
  -- This preserves the no-bind-code workflow without allowing remote claims.
  local local_rebind = existing and protocol_version >= 2 and
    supplied_token == "" and is_private_client_ip(env.client_ip)
  local local_auto_bind = not existing and protocol_version >= 2 and
    is_private_client_ip(env.client_ip)

  if not (local_auto_bind or migration_bind or legacy_reregister or token_reregister or local_rebind) then
    return 403, json.encode({
      status = "local_enrollment_required",
      message = "Coinslot enrollment is only available from the router's local network."
    })
  end

  -- A router owns one physical ESP. Keep re-registration/recovery for the
  -- same node above, but reject a different node before minting a token.
  -- SQLite also enforces this below so concurrent bind requests cannot race.
  if not existing and db.row("SELECT node_id FROM coin_nodes LIMIT 1") then
    return coinslot_already_bound_response()
  end

  local auth_token = existing and tostring(existing.auth_token or "") or ""
  local enrolled_now = false
  if protocol_version >= 2 and (auth_token == "" or local_rebind) then
    auth_token = mint_node_token()
    if not auth_token then
      return 500, json.encode({status = "token_generation_failed"})
    end
    enrolled_now = true
  end

  -- Hardware and pulse settings are router-owned. Never trust the ESP's
  -- setup form to overwrite them. New nodes receive safe defaults and can
  -- be configured from the router Coinslot page after enrollment.
  local name = clean_text(existing and existing.name or "KemoFi Coinslot", 48)
  local area_id = clamp_integer(existing and existing.area_id, 1, 1, 255)
  local coin_gpio = clamp_integer(existing and existing.coin_gpio, 2, 0, 16)
  local relay_gpio = clamp_integer(existing and existing.relay_gpio, 15, 0, 16)
  local amount_php_per_pulse = 1
  if coin_gpio == relay_gpio then
    return 400, json.encode({status = "invalid_coin_settings", message = "Coin and relay GPIO must differ."})
  end
  local coin_dpin = d_pin_for_gpio(coin_gpio)
  local relay_dpin = d_pin_for_gpio(relay_gpio)
  local conn_mode = params.conn_mode == "wired" and "wired" or "wifi"
  local rssi = tonumber(params.rssi) or tonumber(existing and existing.rssi) or 0
  local now = os.time()
  -- The former coin-node bind code is deliberately cleared. The database
  -- column remains only for backup/schema compatibility with older releases.
  local stored_bind_code = ""
  local auth_enrolled_at = 0
  if auth_token ~= "" then
    auth_enrolled_at = tonumber(existing and existing.auth_enrolled_at) or 0
    if local_rebind or auth_enrolled_at <= 0 then auth_enrolled_at = now end
  end

  local wrote, write_err = db.exec([[
    INSERT INTO coin_nodes
      (node_id, name, last_heartbeat, ip_address, total_coins,
       area_id, fw_version, coin_dpin, relay_dpin, coin_gpio, relay_gpio,
       amount_php_per_pulse, rssi, conn_mode, bind_code, auth_token,
       protocol_version, auth_enrolled_at)
    VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(node_id) DO UPDATE SET
      name = excluded.name,
      last_heartbeat = excluded.last_heartbeat,
      ip_address = excluded.ip_address,
      area_id = excluded.area_id,
      fw_version = excluded.fw_version,
      coin_dpin = excluded.coin_dpin,
      relay_dpin = excluded.relay_dpin,
      coin_gpio = excluded.coin_gpio,
      relay_gpio = excluded.relay_gpio,
      amount_php_per_pulse = excluded.amount_php_per_pulse,
      rssi = excluded.rssi,
      conn_mode = excluded.conn_mode,
      bind_code = excluded.bind_code,
      auth_token = excluded.auth_token,
      protocol_version = excluded.protocol_version,
      auth_enrolled_at = excluded.auth_enrolled_at
  ]], node_id, name, now, env.client_ip or "", area_id,
    clean_text(params.fw_version, 24), coin_dpin, relay_dpin, coin_gpio, relay_gpio,
    amount_php_per_pulse, rssi, conn_mode, stored_bind_code, auth_token, protocol_version,
    auth_enrolled_at)
  if not wrote then
    if tostring(write_err or ""):find("only one coinslot can be bound", 1, true) then
      return coinslot_already_bound_response()
    end
    return 500, json.encode({status = "registration_error", detail = tostring(write_err)})
  end

  local persisted, persist_err = db.persist("coin-node-register", true)
  if not persisted then
    return 500, json.encode({
      status = "persistence_error",
      message = "Coin node registration was not saved permanently.",
      detail = tostring(persist_err)
    })
  end
  local response = {
    status = "registered",
    node_id = node_id,
    protocol_version = protocol_version,
    timestamp = now
  }
  append_node_settings(response, {
    name = name,
    coin_gpio = coin_gpio,
    relay_gpio = relay_gpio,
    amount_php_per_pulse = amount_php_per_pulse,
    coin_dpin = coin_dpin,
    relay_dpin = relay_dpin
  })
  if enrolled_now then response.auth_token = auth_token end
  return 200, json.encode(response)
end

--- POST /api/coin/event
function M.handle_event(env, params)
  params = params or {}
  local node, auth_mode = authenticate_node(env, params)
  if not node then return auth_error(auth_mode) end
  local access_allowed, license_status = vendor.customer_access_allowed()
  if not access_allowed then
    return 403, json.encode({status = "license_required", license_status = license_status})
  end

  local pulses = math.floor(tonumber(params.pulses) or 0)
  -- The router is authoritative: every hardware pulse is exactly PHP 1.
  -- Ignore the amount supplied by legacy or modified ESP firmware.
  local amount_php = pulses
  if pulses < 1 or pulses > 100 then
    return 400, json.encode({status = "invalid_coin_value"})
  end

  local waiting_mac = normalize_mac(params.target_mac)
  local event_id = clean_text(params.event_id, 80)
  if auth_mode == "token" then
    if not waiting_mac or #event_id < 12 or
        not event_id:match("^[%w:_%-]+$") then
      return 400, json.encode({status = "invalid_event_identity"})
    end
  else
    waiting_mac = normalize_mac(session.get_waiting_mac())
  end
  if not waiting_mac then
    return 200, json.encode({
      status = "no_waiting_client",
      message = "Coin received but no client is waiting."
    })
  end

  local rates_value, flat_value = M._rate_policy()
  local minutes, pause_limit, validity_seconds =
    M._calculate_rate(amount_php, rates_value, flat_value)
  if minutes <= 0 then
    return 400, json.encode({status = "invalid_rate"})
  end

  if auth_mode == "token" then
    local browser_fp, device_id, roam_fp = "", "", ""
    if normalize_mac(session.get_waiting_mac()) == waiting_mac then
      browser_fp, device_id, roam_fp = session.get_waiting_identity()
    end
    local credited, result, credit_err = db.fast_lane_coin_event({
      event_id = event_id,
      node_id = node.node_id,
      target_mac = waiting_mac,
      pulses = pulses,
      amount_php = amount_php,
      minutes = minutes,
      pause_limit = pause_limit,
      validity_seconds = validity_seconds,
      rates_value = rates_value,
      flat_value = flat_value,
      browser_fp = browser_fp,
      device_id = device_id,
      roam_fp = roam_fp,
      ip_address = env.client_ip or ""
    })
    if not credited then
      return 500, json.encode({status = "credit_error", detail = tostring(credit_err)})
    end
    session.set_last_coin_credited()
    return 200, json.encode({
      status = result.duplicate and "duplicate" or "pending",
      fast_lane = true,
      event_id = result.event.event_id,
      mac = result.event.target_mac,
      minutes = tonumber(result.event.minutes_granted) or minutes,
      amount_php = tonumber(result.event.amount_php) or amount_php,
      pending_minutes = result.pending and tonumber(result.pending.minutes) or nil,
      pause_limit = result.event.pause_limit ~= nil and tonumber(result.event.pause_limit) or pause_limit,
      validity_seconds = result.event.validity_seconds ~= nil and tonumber(result.event.validity_seconds) or validity_seconds,
      pending_coin_count = result.pending and tonumber(result.pending.coin_count) or nil
    })
  end

  local browser_fp, device_id, roam_fp = session.get_waiting_identity()
  local pending_ok, pending = session.add_pending_coin(
    waiting_mac, minutes, amount_php, browser_fp, device_id, roam_fp, pause_limit,
    validity_seconds, rates_value, flat_value
  )
  if not pending_ok then
    return 500, json.encode({status = "credit_error"})
  end
  db.exec([[
    UPDATE coin_nodes SET last_heartbeat = ?, ip_address = ?, total_coins = total_coins + 1
    WHERE node_id = ?
  ]], os.time(), env.client_ip or "", node.node_id)
  local persisted, persist_err = db.sync_on_credit("legacy-coin")
  if not persisted then
    return 500, json.encode({status = "persistence_error", detail = tostring(persist_err)})
  end
  session.set_last_coin_credited()
  return 200, json.encode({
    status = "pending",
    mac = waiting_mac,
    minutes = minutes,
    amount_php = amount_php,
    pause_limit = pause_limit,
    validity_seconds = validity_seconds,
    pending_minutes = tonumber(pending.minutes) or minutes,
    pending_coin_count = tonumber(pending.coin_count) or 1,
    legacy = true
  })
end

--- POST /api/coin/heartbeat
function M.handle_heartbeat(env, params)
  params = params or {}
  local node, auth_mode = authenticate_node(env, params)
  if not node then return auth_error(auth_mode) end
  local fw_version = clean_text(params.fw_version, 24)
  if fw_version == "" then fw_version = clean_text(node.fw_version, 24) end
  local conn_mode = params.conn_mode == "wired" and "wired" or
    (params.conn_mode == "wifi" and "wifi" or node.conn_mode or "wifi")
  local wrote, write_err = db.exec_runtime([[
    UPDATE coin_nodes SET
      last_heartbeat = ?, ip_address = ?, fw_version = ?, rssi = ?,
      conn_mode = ?, protocol_version = ?
    WHERE node_id = ?
  ]], os.time(), env.client_ip or "", fw_version,
    tonumber(params.rssi) or tonumber(node.rssi) or 0,
    conn_mode,
    auth_mode == "token" and 2 or 1, node.node_id)
  if not wrote then
    return 500, json.encode({status = "heartbeat_error", detail = tostring(write_err)})
  end
  local response = {status = "ok", timestamp = os.time()}
  append_node_settings(response, node)
  return 200, json.encode(response)
end

--- Calculate minutes, pause limit, and validity window from configured PHP rates.
--- A pause limit or validity of 0 means unlimited. Legacy php:minutes rows remain valid.
function M._rate_policy()
  return db.setting("portal_rates") or "1:12", db.setting("coin_min_per_php") or ""
end

function M._calculate_rate(amount_php, rates_value, flat_value)
  return rate_config.resolve(
    amount_php,
    rates_value or db.setting("portal_rates") or "1:12",
    flat_value ~= nil and flat_value or db.setting("coin_min_per_php")
  )
end

function M._calculate_minutes(amount_php)
  local minutes = M._calculate_rate(amount_php)
  return minutes
end

--- GET /api/coin/waiting
function M.get_waiting(env, params)
  local node, auth_mode = authenticate_node(env, params or {})
  if not node then return auth_error(auth_mode) end
  local access_allowed, license_status = vendor.customer_access_allowed()
  if not access_allowed then
    if session.get_waiting_mac() then session.clear_waiting() end
    local response = {
      waiting = false,
      status = "license_required",
      license_status = license_status
    }
    append_node_settings(response, node)
    return 200, json.encode(response)
  end
  local waiting_mac = normalize_mac(session.get_waiting_mac())
  local closing = waiting_mac and session.is_waiting_closing(waiting_mac)
  local response = {waiting = waiting_mac ~= nil and not closing}
  append_node_settings(response, node)
  if response.waiting then
    session.mark_waiting_ready(waiting_mac)
    if auth_mode == "token" then response.target_mac = waiting_mac end
  elseif closing then
    response.status = "closing"
  end
  return 200, json.encode(response)
end

return M
