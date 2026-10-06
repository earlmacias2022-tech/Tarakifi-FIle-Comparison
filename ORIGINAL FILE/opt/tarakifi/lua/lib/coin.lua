--- TarakiFi authenticated coin controller protocol.
local db      = require("lib.db")
local session = require("lib.session")
local json    = require("lib.json")
local util    = require("lib.util")
local vendor  = require("lib.vendor")
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
    request_header(env, "x-tarakifi-node") ~= "" and
      request_header(env, "x-tarakifi-node") or params.node_id
  )
  local token = request_header(env, "x-tarakifi-token")
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

local function coinslot_limit_error()
  return 409, json.encode({
    status = "coinslot_limit_reached",
    message = "This router already has a bound coinslot. Unbind it before adding another."
  })
end

local function valid_pending_bind(bind_code)
  local pending_code = db.setting("_pending_bind_code") or ""
  local pending_expires = tonumber(db.setting("_pending_bind_expires") or "0") or 0
  return pending_code ~= "" and bind_code ~= "" and
    os.time() <= pending_expires and constant_time_equal(bind_code, pending_code)
end

local function consume_pending_bind()
  db.set_runtime_setting("_pending_bind_code", "")
  db.set_runtime_setting("_pending_bind_expires", "0")
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

local function schedule_cloud_backup(reason)
  local ok, cloud = pcall(require, "lib.cloud_backup")
  if ok and type(cloud) == "table" and type(cloud.schedule) == "function" then
    pcall(cloud.schedule, reason)
  end
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
  local bind_code = clean_text(params.bind_code, 7)
  local supplied_token = request_header(env, "x-tarakifi-token")
  local pending_bind = valid_pending_bind(bind_code)
  local migration_bind = existing and protocol_version >= 2 and
    tostring(existing.auth_token or "") == "" and
    tostring(existing.ip_address or "") == tostring(env.client_ip or "") and
    tostring(existing.bind_code or "") ~= "" and
    constant_time_equal(bind_code, existing.bind_code)
  local legacy_reregister = existing and protocol_version < 2 and
    tostring(existing.auth_token or "") == "" and supplied_token == "" and
    tostring(existing.ip_address or "") == tostring(env.client_ip or "")
  local token_reregister = existing and tostring(existing.auth_token or "") ~= "" and
    supplied_token ~= "" and constant_time_equal(existing.auth_token, supplied_token)

  if not (pending_bind or migration_bind or legacy_reregister or token_reregister) then
    return 403, json.encode({
      status = "bind_rejected",
      message = "Invalid, expired, or already-used bind credentials."
    })
  end

  if not existing and db.row("SELECT node_id FROM coin_nodes LIMIT 1") then
    return coinslot_limit_error()
  end

  local auth_token = existing and tostring(existing.auth_token or "") or ""
  local enrolled_now = false
  local pending_reenrollment = existing and pending_bind and protocol_version >= 2
  if protocol_version >= 2 and (auth_token == "" or pending_reenrollment) then
    auth_token = mint_node_token()
    if not auth_token then
      return 500, json.encode({status = "token_generation_failed"})
    end
    enrolled_now = true
  end

  local name = clean_text(params.node_name, 48)
  if name == "" then name = clean_text(existing and existing.name or node_id, 48) end
  local area_id = math.max(1, math.min(255, math.floor(tonumber(params.area_id) or 1)))
  local coin_dpin = math.max(0, math.min(8, math.floor(tonumber(params.coin_dpin) or 1)))
  local relay_dpin = math.max(0, math.min(8, math.floor(tonumber(params.relay_dpin) or 2)))
  local coin_gpio = math.max(0, math.min(16, math.floor(tonumber(params.coin_gpio) or 5)))
  local relay_gpio = math.max(0, math.min(16, math.floor(tonumber(params.relay_gpio) or 4)))
  local conn_mode = params.conn_mode == "wired" and "wired" or "wifi"
  local rssi = tonumber(params.rssi) or tonumber(existing and existing.rssi) or 0
  local now = os.time()
  local auth_enrolled_at = 0
  if auth_token ~= "" then
    auth_enrolled_at = tonumber(existing and existing.auth_enrolled_at) or 0
    if auth_enrolled_at <= 0 then auth_enrolled_at = now end
  end

  local wrote, write_err = db.exec([[
    INSERT INTO coin_nodes
      (node_id, name, last_heartbeat, ip_address, total_coins,
       area_id, fw_version, coin_dpin, relay_dpin, coin_gpio, relay_gpio,
       rssi, conn_mode, bind_code, auth_token, protocol_version, auth_enrolled_at)
    VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
      rssi = excluded.rssi,
      conn_mode = excluded.conn_mode,
      bind_code = excluded.bind_code,
      auth_token = excluded.auth_token,
      protocol_version = excluded.protocol_version,
      auth_enrolled_at = excluded.auth_enrolled_at
  ]], node_id, name, now, env.client_ip or "", area_id,
    clean_text(params.fw_version, 24), coin_dpin, relay_dpin, coin_gpio, relay_gpio,
    rssi, conn_mode, bind_code, auth_token, protocol_version,
    auth_enrolled_at)
  if not wrote then
    if tostring(write_err):find("coinslot_limit_reached", 1, true) then
      return coinslot_limit_error()
    end
    return 500, json.encode({status = "registration_error", detail = tostring(write_err)})
  end

  -- A new binding or token enrollment must be durable before it is accepted.
  -- Routine authenticated reconnects are already marked dirty by db.exec and
  -- can use the supervised periodic sync without blocking the node response.
  local requires_immediate_persist = not existing or enrolled_now
  if requires_immediate_persist then
    local persisted, persist_err = db.persist("coin-node-register", true)
    if not persisted then
      return 500, json.encode({
        status = "persistence_error",
        message = "Coin node registration was not saved permanently.",
        detail = tostring(persist_err)
      })
    end
  end
  if pending_bind then consume_pending_bind() end
  if requires_immediate_persist or pending_bind then
    schedule_cloud_backup("coin_node_change")
  end

  local response = {
    status = "registered",
    node_id = node_id,
    protocol_version = protocol_version,
    timestamp = now
  }
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
  local amount_php = tonumber(params.amount_php) or 0
  if pulses < 1 or pulses > 100 or amount_php <= 0 or amount_php > 1000 then
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

  local rate_settings = db.settings({"coin_min_per_php", "portal_rates"})
  local flat_rate = rate_settings.coin_min_per_php
  local rates = rate_settings.portal_rates
  local minutes = M._calculate_minutes(amount_php, flat_rate, rates)
  if minutes <= 0 then
    return 400, json.encode({status = "invalid_rate"})
  end

  if auth_mode == "token" then
    local browser_fp, device_id, roam_fp = "", "", ""
    if normalize_mac(session.get_waiting_mac()) == waiting_mac then
      browser_fp, device_id, roam_fp = session.get_waiting_identity()
    end
    local credited, result, credit_err = db.coin_event_credit({
      event_id = event_id,
      node_id = node.node_id,
      target_mac = waiting_mac,
      pulses = pulses,
      amount_php = amount_php,
      minutes = minutes,
      browser_fp = browser_fp,
      device_id = device_id,
      roam_fp = roam_fp,
      ip_address = env.client_ip or "",
      calculate_cumulative_minutes = function(total_amount_php)
        return M._calculate_minutes(total_amount_php, flat_rate, rates)
      end
    })
    if not credited then
      return 500, json.encode({status = "credit_error", detail = tostring(credit_err)})
    end
    local persisted, persist_err = db.sync_on_credit("coin-event")
    if not persisted then
      return 500, json.encode({status = "persistence_error", detail = tostring(persist_err)})
    end
    session.set_last_coin_credited()
    return 200, json.encode({
      status = result.duplicate and "duplicate" or "pending",
      event_id = result.event.event_id,
      mac = result.event.target_mac,
      minutes = tonumber(result.event.minutes_granted) or minutes,
      amount_php = tonumber(result.event.amount_php) or amount_php,
      pending_minutes = result.pending and tonumber(result.pending.minutes) or nil,
      pending_coin_count = result.pending and tonumber(result.pending.coin_count) or nil
    })
  end

  local browser_fp, device_id, roam_fp = session.get_waiting_identity()
  local pending_ok, pending = session.add_pending_coin(
    waiting_mac, minutes, amount_php, browser_fp, device_id, roam_fp
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
  local name = clean_text(params.node_name, 48)
  if name == "" then name = clean_text(node.name, 48) end
  local fw_version = clean_text(params.fw_version, 24)
  if fw_version == "" then fw_version = clean_text(node.fw_version, 24) end
  local conn_mode = params.conn_mode == "wired" and "wired" or
    (params.conn_mode == "wifi" and "wifi" or node.conn_mode or "wifi")
  local wrote, write_err = db.exec_runtime([[
    UPDATE coin_nodes SET
      name = ?, last_heartbeat = ?, ip_address = ?, area_id = ?, fw_version = ?,
      coin_dpin = ?, relay_dpin = ?, rssi = ?, conn_mode = ?, protocol_version = ?
    WHERE node_id = ?
  ]], name,
    os.time(), env.client_ip or "", tonumber(params.area_id) or node.area_id or 1,
    fw_version,
    tonumber(params.coin_dpin) or node.coin_dpin or 1,
    tonumber(params.relay_dpin) or node.relay_dpin or 2,
    tonumber(params.rssi) or tonumber(node.rssi) or 0,
    conn_mode,
    auth_mode == "token" and 2 or 1, node.node_id)
  if not wrote then
    return 500, json.encode({status = "heartbeat_error", detail = tostring(write_err)})
  end
  return 200, json.encode({status = "ok", timestamp = os.time()})
end

--- Calculate minutes from configured PHP rates.
function M._calculate_minutes(amount_php, flat_rate_value, rates_str_value)
  local flat_rate = tonumber(flat_rate_value)
  if flat_rate_value == nil then
    flat_rate = tonumber(db.setting("coin_min_per_php") or "")
  end
  if flat_rate and flat_rate > 0 then return amount_php * flat_rate end

  local rates_str = rates_str_value
  if rates_str == nil then rates_str = db.setting("portal_rates") end
  rates_str = rates_str or "1:12"
  local tiers = {}
  for line in rates_str:gmatch("[^\n]+") do
    local php, mins = line:match("(%d+):(%d+)")
    if php and mins then
      php = tonumber(php)
      mins = tonumber(mins)
      if php > 0 and mins > 0 then
        tiers[#tiers + 1] = {php = php, minutes = mins}
      end
    end
  end

  table.sort(tiers, function(a, b) return a.php > b.php end)
  local remaining = tonumber(amount_php) or 0
  local total_minutes = 0
  for _, tier in ipairs(tiers) do
    local packages = math.floor(remaining / tier.php)
    if packages > 0 then
      total_minutes = total_minutes + packages * tier.minutes
      remaining = remaining - packages * tier.php
    end
  end

  -- Preserve the legacy default for a remainder below the smallest tier.
  return math.floor(total_minutes + remaining * 12)
end

--- GET /api/coin/waiting
function M.get_waiting(env, params)
  local node, auth_mode = authenticate_node(env, params or {})
  if not node then return auth_error(auth_mode) end
  local access_allowed, license_status = vendor.customer_access_allowed()
  if not access_allowed then
    if session.get_waiting_mac() then session.clear_waiting() end
    return 200, json.encode({
      waiting = false,
      status = "license_required",
      license_status = license_status
    })
  end
  local waiting_mac = normalize_mac(session.get_waiting_mac())
  local closing = waiting_mac and session.is_waiting_closing(waiting_mac)
  local response = {waiting = waiting_mac ~= nil and not closing}
  if response.waiting then
    session.mark_waiting_ready(waiting_mac)
    if auth_mode == "token" then response.target_mac = waiting_mac end
  elseif closing then
    response.status = "closing"
  end
  return 200, json.encode(response)
end

return M
