--- KemoFi Database Layer (SQLite3 — RAM with flash sync)
-- DB lives at /tmp/kemofi.db (fast RAM). Synced to /etc/kemofi/sessions.db
-- every 60s by timer and immediately on credit events.
-- IMPORTANT: DB is opened and closed per-request to avoid locking between
-- multiple uhttpd processes (portal, admin, captive).
local sqlite3 = require("lsqlite3")
local util = require("lib.util")
local rate_config = require("lib.rates")
local has_nixio, nixio = pcall(require, "nixio")
local has_nixio_fs, nixio_fs = pcall(require, "nixio.fs")
local M = {}

local DB_PATH = os.getenv("KEMOFI_DB_PATH") or "/tmp/kemofi.db"
local FLASH_PATH = os.getenv("KEMOFI_FLASH_DB_PATH") or "/etc/kemofi/sessions.db"
local BACKUP_PATH = os.getenv("KEMOFI_BACKUP_DB_PATH") or "/etc/kemofi/sessions.db.bak"
local SNAPSHOT_PATH = os.getenv("KEMOFI_SNAPSHOT_DB_PATH") or "/etc/kemofi/sessions.db.tmp"
local DIRTY_PATH = os.getenv("KEMOFI_DB_DIRTY_PATH") or "/tmp/kemofi/db_dirty"
local LOCK_PATH = os.getenv("KEMOFI_DB_LOCK_PATH") or "/tmp/kemofi/db_persist.lock"
local STATUS_PATH = os.getenv("KEMOFI_DB_STATUS_PATH") or "/tmp/kemofi/db_persist_status"
local SCHEMA_READY_PATH = os.getenv("KEMOFI_SCHEMA_READY_PATH") or (DB_PATH .. ".schema-ready")
-- Fast Lane keeps a small, independently synced intent record for every
-- authenticated v2 coin event. That lets the API acknowledge a credit as
-- soon as it is safe from power loss, while the larger SQLite snapshot is
-- written by the maintenance worker instead of the request path.
local FAST_LANE_DIR = os.getenv("KEMOFI_FAST_LANE_DIR") or "/etc/kemofi/fastlane"
local FAST_LANE_LOCK_PATH = os.getenv("KEMOFI_FAST_LANE_LOCK_PATH") or
  "/tmp/kemofi/fastlane.lock"
local SCHEMA_VERSION = "coin-r8"
local IDENTITY_BINDING_VERSION = "authoritative-device-v1"
local FLASH_DIR = FLASH_PATH:match("^(.*)/[^/]+$") or "/etc/kemofi"
local _initialized = false
local TOKEN_TOUCH_INTERVAL_SECONDS = tonumber(os.getenv("KEMOFI_TOKEN_TOUCH_INTERVAL")) or 60
local STORAGE_CLEANUP_INTERVAL_SECONDS = tonumber(
  os.getenv("KEMOFI_STORAGE_CLEANUP_INTERVAL")
) or 3600
local COIN_EVENT_RETENTION_SECONDS = tonumber(
  os.getenv("KEMOFI_COIN_EVENT_RETENTION_SECONDS")
) or (7 * 86400)

local function normalize_mac(value)
  local mac = tostring(value or ""):upper()
  if mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then return mac end
  return nil
end

local function session_is_active(row, now)
  if not row then return false end
  now = now or os.time()
  local valid_until = tonumber(row.valid_until) or 0
  if valid_until > 0 and valid_until <= now then return false end
  return tonumber(row.paused) == 1 or (tonumber(row.expires_at) or 0) > now
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local value = f:read("*a")
  f:close()
  return value
end

local function write_file(path, value)
  local f = io.open(path, "w")
  if not f then return false end
  local ok = f:write(value)
  f:close()
  return ok ~= nil
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if not f then return false end
  f:close()
  return true
end

local function process_id()
  local stat = read_file("/proc/self/stat") or ""
  return stat:match("^(%d+)") or "0"
end

local function mark_dirty()
  os.execute("mkdir -p /tmp/kemofi")
  local token = table.concat({tostring(os.time()), process_id(), tostring(os.clock())}, ":")
  write_file(DIRTY_PATH, token)
end

local function write_status(status, reason, detail)
  local clean_detail = tostring(detail or ""):gsub("[\r\n|]", " ")
  write_file(STATUS_PATH, table.concat({status, tostring(os.time()), reason or "unknown", clean_detail}, "|"))
end

local function acquire_persist_lock()
  if not has_nixio then
    return nil, "nixio is required for safe database persistence"
  end
  local lock, err = nixio.open(LOCK_PATH, "w", "0600")
  if not lock then return nil, "cannot open persistence lock: " .. tostring(err) end
  local ok, lock_err = lock:lock("lock")
  if not ok then
    lock:close()
    return nil, "cannot acquire persistence lock: " .. tostring(lock_err)
  end
  return lock
end

local function release_persist_lock(lock)
  if not lock then return end
  lock:lock("ulock")
  lock:close()
end

local function sync_path(path)
  if not has_nixio then return false end
  local fd = nixio.open(path, "r")
  if not fd then return false end
  local ok = fd:sync(false)
  fd:close()
  return ok and true or false
end

local function quick_check(db)
  local stmt = db:prepare("PRAGMA quick_check")
  if not stmt then return false, db:errmsg() end
  local rc = stmt:step()
  local result = rc == sqlite3.ROW and stmt:get_value(0) or nil
  stmt:finalize()
  if result ~= "ok" then return false, result or "quick_check failed" end
  return true
end

local function copy_file(source, target)
  local input = io.open(source, "rb")
  if not input then return false, "cannot open " .. source end
  local output = io.open(target, "wb")
  if not output then
    input:close()
    return false, "cannot open " .. target
  end
  while true do
    local chunk = input:read(65536)
    if not chunk then break end
    if not output:write(chunk) then
      input:close()
      output:close()
      return false, "cannot write " .. target
    end
  end
  input:close()
  output:close()
  sync_path(target)
  return true
end

-- Pending coin credit is one package, not a sum of independently priced
-- coins. Re-resolve the complete amount so an exact tier (for example PHP25)
-- wins even when that amount arrived as several physical coin events.
local function resolve_pending_rate(amount_php, rates_value, flat_value)
  return rate_config.resolve(amount_php, rates_value or "1:12", flat_value)
end

local FAST_LANE_FIELDS = {
  "event_id", "node_id", "target_mac", "pulses", "amount_php", "minutes",
  "pause_limit", "validity_seconds",
  "browser_fp", "device_id", "roam_fp", "ip_address", "created_at",
  "rates_value", "flat_value"
}

local function hex_encode(value)
  return (tostring(value or ""):gsub(".", function(character)
    return string.format("%02x", string.byte(character))
  end))
end

local function hex_decode(value)
  if type(value) ~= "string" or #value % 2 ~= 0 or not value:match("^[0-9a-fA-F]*$") then
    return nil
  end
  return (value:gsub("..", function(pair)
    return string.char(tonumber(pair, 16))
  end))
end

local function valid_fast_lane_path(path)
  return type(path) == "string" and path:match("^/[A-Za-z0-9._%-%/]+$") ~= nil
end

local function ensure_fast_lane_dir()
  if not valid_fast_lane_path(FAST_LANE_DIR) then
    return false, "invalid fast lane directory"
  end
  os.execute("mkdir -p " .. FAST_LANE_DIR)
  return true
end

local function acquire_fast_lane_lock()
  if not has_nixio then
    return nil, "nixio is required for Fast Lane persistence"
  end
  local ready, ready_err = ensure_fast_lane_dir()
  if not ready then return nil, ready_err end
  local lock, err = nixio.open(FAST_LANE_LOCK_PATH, "w", "0600")
  if not lock then return nil, "cannot open Fast Lane lock: " .. tostring(err) end
  local ok, lock_err = lock:lock("lock")
  if not ok then
    lock:close()
    return nil, "cannot acquire Fast Lane lock: " .. tostring(lock_err)
  end
  return lock
end

local function release_fast_lane_lock(lock)
  if not lock then return end
  lock:lock("ulock")
  lock:close()
end

local function fast_lane_event_path(event_id)
  -- The validated id is hex encoded so it cannot affect the directory path.
  return FAST_LANE_DIR .. "/" .. hex_encode(event_id) .. ".event"
end

local function fast_lane_payload(options)
  local values = {
    event_id = options.event_id,
    node_id = options.node_id,
    target_mac = options.target_mac,
    pulses = options.pulses,
    amount_php = options.amount_php,
    minutes = options.minutes,
    pause_limit = options.pause_limit,
    validity_seconds = options.validity_seconds,
    browser_fp = options.browser_fp,
    device_id = options.device_id,
    roam_fp = options.roam_fp,
    ip_address = options.ip_address,
    created_at = options.created_at,
    rates_value = options.rates_value,
    flat_value = options.flat_value
  }
  local lines = {"format=1"}
  for _, name in ipairs(FAST_LANE_FIELDS) do
    lines[#lines + 1] = name .. "=" .. hex_encode(values[name])
  end
  return table.concat(lines, "\n") .. "\n"
end

local function read_fast_lane_record(path)
  local payload = read_file(path)
  if not payload or payload == "" then return nil, "empty Fast Lane record" end
  local encoded, format = {}, nil
  for line in payload:gmatch("[^\r\n]+") do
    local name, value = line:match("^([a-z_]+)=([0-9a-fA-F]*)$")
    if not name then return nil, "invalid Fast Lane record" end
    if name == "format" then
      format = value
    elseif encoded[name] ~= nil then
      return nil, "duplicate Fast Lane record field"
    else
      encoded[name] = value
    end
  end
  if format ~= "1" then return nil, "unsupported Fast Lane record format" end

  local values = {}
  for _, name in ipairs(FAST_LANE_FIELDS) do
    local decoded
    if encoded[name] == nil and (name == "pause_limit" or name == "validity_seconds" or
        name == "rates_value" or name == "flat_value") then
      -- Records written before per-rate controls remain replayable.
      decoded = "0"
    else
      decoded = hex_decode(encoded[name])
      if decoded == nil then return nil, "invalid Fast Lane record field: " .. name end
    end
    values[name] = decoded
  end
  return {
    event_id = values.event_id,
    node_id = values.node_id,
    target_mac = values.target_mac,
    pulses = tonumber(values.pulses),
    amount_php = tonumber(values.amount_php),
    minutes = tonumber(values.minutes),
    pause_limit = tonumber(values.pause_limit) or 0,
    validity_seconds = tonumber(values.validity_seconds) or 0,
    browser_fp = values.browser_fp,
    device_id = values.device_id,
    roam_fp = values.roam_fp,
    ip_address = values.ip_address,
    created_at = tonumber(values.created_at),
    rates_value = values.rates_value ~= "0" and values.rates_value or "",
    flat_value = values.flat_value ~= "0" and values.flat_value or ""
  }
end

local function write_fast_lane_record(options)
  local ready, ready_err = ensure_fast_lane_dir()
  if not ready then return false, ready_err end
  local destination = fast_lane_event_path(options.event_id)
  if file_exists(destination) then return true, "existing" end

  local temporary = destination .. ".tmp." .. process_id() .. "." ..
    tostring(math.floor(os.clock() * 1000000))
  local file, open_err = io.open(temporary, "wb")
  if not file then return false, "cannot create Fast Lane record: " .. tostring(open_err) end
  local wrote = file:write(fast_lane_payload(options))
  file:close()
  if not wrote or not sync_path(temporary) then
    os.remove(temporary)
    return false, "cannot sync Fast Lane record"
  end
  local renamed, rename_err = os.rename(temporary, destination)
  if not renamed then
    os.remove(temporary)
    return false, "cannot activate Fast Lane record: " .. tostring(rename_err)
  end
  -- The event file itself is already synced. Some OpenWrt overlay filesystems
  -- do not allow opening a directory through nixio for fsync; that must not
  -- turn a successfully recorded coin into an HTTP failure.
  if not sync_path(FAST_LANE_DIR) then
    return true, "written-directory-sync-unavailable"
  end
  return true, "written"
end

local function list_fast_lane_records()
  local ready, ready_err = ensure_fast_lane_dir()
  if not ready then return nil, ready_err end
  if not has_nixio_fs or not nixio_fs.dir then
    return nil, "nixio.fs is required for Fast Lane recovery"
  end
  local ok, iterator = pcall(nixio_fs.dir, FAST_LANE_DIR)
  if not ok or type(iterator) ~= "function" then
    return nil, "cannot read Fast Lane directory"
  end
  local paths = {}
  for entry in iterator do
    if entry:match("^[0-9a-f]+%.event$") then
      paths[#paths + 1] = FAST_LANE_DIR .. "/" .. entry
    end
  end
  table.sort(paths)
  return paths
end

--- Open DB, set pragmas, return handle. Caller MUST close after use.
local function open_db()
  local db = sqlite3.open(DB_PATH)
  db:exec("PRAGMA busy_timeout=5000")
  db:exec("PRAGMA synchronous=NORMAL")
  return db
end

local function bind_params(stmt, ...)
  for index = 1, select("#", ...) do
    stmt:bind(index, select(index, ...))
  end
end

local function table_has_column(database, table_name, column_name)
  local stmt = database:prepare("PRAGMA table_info(" .. table_name .. ")")
  if not stmt then return false end
  local found = false
  while stmt:step() == sqlite3.ROW do
    if stmt:get_value(1) == column_name then
      found = true
      break
    end
  end
  stmt:finalize()
  return found
end

local function ensure_table_column(database, table_name, column_name, definition)
  if table_has_column(database, table_name, column_name) then return false end
  local rc = database:exec(
    "ALTER TABLE " .. table_name .. " ADD COLUMN " .. column_name .. " " .. definition
  )
  if rc ~= sqlite3.OK then
    -- Another supervised process may have completed the same migration.
    if table_has_column(database, table_name, column_name) then return false end
    return nil, database:errmsg()
  end
  return true
end

local function database_setting(database, key)
  local stmt = database:prepare("SELECT value FROM settings WHERE key = ?")
  if not stmt then return nil end
  stmt:bind(1, key)
  local value
  if stmt:step() == sqlite3.ROW then value = stmt:get_value(0) end
  stmt:finalize()
  return value
end

--- Initialize the database (schema only — opens, creates tables, closes)
function M.init()
  if _initialized then return end
  if file_exists(DB_PATH) and read_file(SCHEMA_READY_PATH) == SCHEMA_VERSION then
    local ready_db = sqlite3.open(DB_PATH)
    local identity_ready = ready_db and database_setting(ready_db, "_identity_binding_version")
    if ready_db then ready_db:close() end
    if identity_ready == IDENTITY_BINDING_VERSION then
      _initialized = true
      return
    end
  end
  os.execute("mkdir -p /tmp/kemofi /etc/kemofi")
  local db = open_db()
  db:exec("PRAGMA journal_mode=DELETE")
  local schema_before = 0
  local schema_stmt = db:prepare("PRAGMA schema_version")
  if schema_stmt and schema_stmt:step() == sqlite3.ROW then
    schema_before = tonumber(schema_stmt:get_value(0)) or 0
  end
  if schema_stmt then schema_stmt:finalize() end

  -- Core schema
  db:exec([[
    CREATE TABLE IF NOT EXISTS sessions (
      mac TEXT PRIMARY KEY,
      minutes_remaining REAL DEFAULT 0,
      started_at INTEGER DEFAULT 0,
      expires_at INTEGER DEFAULT 0,
      last_seen INTEGER DEFAULT 0,
      paused INTEGER DEFAULT 0,
      auto_paused INTEGER DEFAULT 0,
      pause_limit INTEGER DEFAULT 0,
      pauses_used INTEGER DEFAULT 0,
      valid_until INTEGER DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS transactions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      mac TEXT,
      amount_php REAL DEFAULT 0,
      minutes_granted REAL DEFAULT 0,
      source TEXT DEFAULT 'coin',
      created_at INTEGER DEFAULT 0,
      coin_count INTEGER DEFAULT 1
    );
    CREATE TABLE IF NOT EXISTS pending_coin_credits (
      mac TEXT PRIMARY KEY,
      minutes REAL DEFAULT 0,
      amount_php REAL DEFAULT 0,
      coin_count INTEGER DEFAULT 0,
      pause_limit INTEGER DEFAULT 0,
      valid_until INTEGER DEFAULT 0,
      browser_fp TEXT DEFAULT '',
      device_id TEXT DEFAULT '',
      roam_fp TEXT DEFAULT '',
      created_at INTEGER DEFAULT 0,
      updated_at INTEGER DEFAULT 0,
      transaction_id INTEGER DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS settings (
      key TEXT PRIMARY KEY,
      value TEXT DEFAULT ''
    );
    CREATE TABLE IF NOT EXISTS known_devices (
      mac TEXT PRIMARY KEY,
      name TEXT DEFAULT '',
      first_seen INTEGER DEFAULT 0,
      last_seen INTEGER DEFAULT 0,
      blocked INTEGER DEFAULT 0,
      member INTEGER DEFAULT 0,
      member_since INTEGER DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS coin_nodes (
      node_id TEXT PRIMARY KEY,
      name TEXT DEFAULT '',
      last_heartbeat INTEGER DEFAULT 0,
      ip_address TEXT DEFAULT '',
      total_coins INTEGER DEFAULT 0,
      area_id INTEGER DEFAULT 1,
      fw_version TEXT DEFAULT '',
      coin_dpin INTEGER DEFAULT 1,
      relay_dpin INTEGER DEFAULT 2,
      coin_gpio INTEGER DEFAULT 5,
      relay_gpio INTEGER DEFAULT 4,
      amount_php_per_pulse INTEGER DEFAULT 1,
      rssi INTEGER,
      conn_mode TEXT DEFAULT 'wifi',
      bind_code TEXT DEFAULT '',
      auth_token TEXT DEFAULT '',
      protocol_version INTEGER DEFAULT 1,
      auth_enrolled_at INTEGER DEFAULT 0
    );
    -- A router owns one physical coinslot. Same-node upserts remain allowed;
    -- different node IDs are rejected atomically by SQLite.
    CREATE TRIGGER IF NOT EXISTS coin_nodes_singleton_insert
    BEFORE INSERT ON coin_nodes
    WHEN EXISTS (SELECT 1 FROM coin_nodes WHERE node_id <> NEW.node_id)
    BEGIN
      SELECT RAISE(ABORT, 'only one coinslot can be bound');
    END;
    CREATE TABLE IF NOT EXISTS coin_events (
      event_id TEXT PRIMARY KEY,
      node_id TEXT NOT NULL,
      target_mac TEXT NOT NULL,
      pulses INTEGER DEFAULT 0,
      amount_php REAL DEFAULT 0,
      minutes_granted REAL DEFAULT 0,
      pause_limit INTEGER DEFAULT 0,
      validity_seconds INTEGER DEFAULT 0,
      created_at INTEGER DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS vouchers (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      code TEXT UNIQUE NOT NULL,
      minutes REAL DEFAULT 0,
      price_php REAL DEFAULT 0,
      status TEXT DEFAULT 'unused',
      batch_label TEXT DEFAULT '',
      created_at INTEGER DEFAULT 0,
      validity_seconds INTEGER DEFAULT 0,
      activated_at INTEGER DEFAULT 0,
      valid_until INTEGER DEFAULT 0,
      redeemed_at INTEGER DEFAULT 0,
      redeemed_by_mac TEXT DEFAULT '',
      archived INTEGER DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS session_tokens (
      token TEXT PRIMARY KEY,
      mac TEXT NOT NULL,
      created_at INTEGER DEFAULT 0,
      last_seen INTEGER DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS token_bindings (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      token TEXT NOT NULL,
      kind TEXT NOT NULL,
      value TEXT NOT NULL,
      UNIQUE(kind, value)
    );
    CREATE TABLE IF NOT EXISTS device_aliases (
      mac TEXT PRIMARY KEY,
      group_id TEXT NOT NULL,
      verified_at INTEGER DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_vouchers_code ON vouchers(code);
    CREATE INDEX IF NOT EXISTS idx_vouchers_status ON vouchers(status);
    CREATE INDEX IF NOT EXISTS idx_transactions_created ON transactions(created_at);
    CREATE INDEX IF NOT EXISTS idx_pending_coin_updated ON pending_coin_credits(updated_at);
    CREATE INDEX IF NOT EXISTS idx_coin_events_node_created ON coin_events(node_id, created_at);
    CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at);
    CREATE INDEX IF NOT EXISTS idx_token_bindings_token ON token_bindings(token);
    CREATE INDEX IF NOT EXISTS idx_token_bindings_kind_value ON token_bindings(kind, value);
    CREATE INDEX IF NOT EXISTS idx_session_tokens_mac ON session_tokens(mac);
    CREATE INDEX IF NOT EXISTS idx_device_aliases_group ON device_aliases(group_id);
  ]])

  -- Browser and roaming fingerprints are not ownership proofs: identical
  -- phones can produce the same values. Keep only the random per-device ID as
  -- an optional identity supplement, while preserving paid sessions, credit,
  -- transactions, and MAC token bindings.
  local identity_cleanup_applied = false
  if database_setting(db, "_identity_binding_version") ~= IDENTITY_BINDING_VERSION then
    if db:exec("BEGIN IMMEDIATE") ~= sqlite3.OK then
      local migration_err = db:errmsg()
      db:close()
      error("identity migration lock failed: " .. tostring(migration_err), 0)
    end

    if database_setting(db, "_identity_binding_version") ~= IDENTITY_BINDING_VERSION then
      local cleanup_rc = db:exec([[
        DELETE FROM token_bindings WHERE kind IN ('browser_fp', 'roam_fp_v2');
        DELETE FROM device_aliases;
        UPDATE pending_coin_credits SET browser_fp = '', roam_fp = '';
      ]])
      if cleanup_rc ~= sqlite3.OK then
        local migration_err = db:errmsg()
        db:exec("ROLLBACK")
        db:close()
        error("identity migration cleanup failed: " .. tostring(migration_err), 0)
      end

      local marker = db:prepare(
        "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)"
      )
      if not marker then
        local migration_err = db:errmsg()
        db:exec("ROLLBACK")
        db:close()
        error("identity migration marker failed: " .. tostring(migration_err), 0)
      end
      marker:bind(1, "_identity_binding_version")
      marker:bind(2, IDENTITY_BINDING_VERSION)
      local marker_rc = marker:step()
      marker:finalize()
      if marker_rc ~= sqlite3.DONE then
        local migration_err = db:errmsg()
        db:exec("ROLLBACK")
        db:close()
        error("identity migration marker failed: " .. tostring(migration_err), 0)
      end
      identity_cleanup_applied = true
    end

    if db:exec("COMMIT") ~= sqlite3.OK then
      local migration_err = db:errmsg()
      db:close()
      error("identity migration commit failed: " .. tostring(migration_err), 0)
    end
  end

  local coin_node_columns = {
    {name = "area_id", definition = "INTEGER DEFAULT 1"},
    {name = "fw_version", definition = "TEXT DEFAULT ''"},
    {name = "coin_dpin", definition = "INTEGER DEFAULT 1"},
    {name = "relay_dpin", definition = "INTEGER DEFAULT 2"},
    {name = "coin_gpio", definition = "INTEGER DEFAULT 5"},
    {name = "relay_gpio", definition = "INTEGER DEFAULT 4"},
    {name = "amount_php_per_pulse", definition = "INTEGER DEFAULT 1"},
    {name = "rssi", definition = "INTEGER"},
    {name = "conn_mode", definition = "TEXT DEFAULT 'wifi'"},
    {name = "bind_code", definition = "TEXT DEFAULT ''"},
    {name = "auth_token", definition = "TEXT DEFAULT ''"},
    {name = "protocol_version", definition = "INTEGER DEFAULT 1"},
    {name = "auth_enrolled_at", definition = "INTEGER DEFAULT 0"}
  }
  for _, column in ipairs(coin_node_columns) do
    local added, migration_err = ensure_table_column(
      db, "coin_nodes", column.name, column.definition
    )
    if added == nil then
      db:close()
      error("coin node migration failed: " .. tostring(migration_err), 0)
    end
  end

  -- Pulse value is fixed by product policy. Normalize existing installations
  -- during the schema migration so legacy values cannot survive a restart.
  local pulse_values_normalized = false
  if db:exec([[UPDATE coin_nodes
               SET amount_php_per_pulse = 1
               WHERE amount_php_per_pulse IS NULL OR amount_php_per_pulse <> 1]]) ~= sqlite3.OK then
    local migration_err = db:errmsg()
    db:close()
    error("coin pulse migration failed: " .. tostring(migration_err), 0)
  end
  pulse_values_normalized = true

  local transaction_columns = {
    {name = "coin_count", definition = "INTEGER DEFAULT 1"}
  }
  for _, column in ipairs(transaction_columns) do
    local added, migration_err = ensure_table_column(
      db, "transactions", column.name, column.definition
    )
    if added == nil then
      db:close()
      error("transaction migration failed: " .. tostring(migration_err), 0)
    end
  end

  local pending_coin_columns = {
    {name = "transaction_id", definition = "INTEGER DEFAULT 0"},
    {name = "pause_limit", definition = "INTEGER DEFAULT 0"},
    {name = "valid_until", definition = "INTEGER DEFAULT 0"}
  }
  for _, column in ipairs(pending_coin_columns) do
    local added, migration_err = ensure_table_column(
      db, "pending_coin_credits", column.name, column.definition
    )
    if added == nil then
      db:close()
      error("pending coin migration failed: " .. tostring(migration_err), 0)
    end
  end

  local session_columns = {
    {name = "auto_paused", definition = "INTEGER DEFAULT 0"},
    {name = "pause_limit", definition = "INTEGER DEFAULT 0"},
    {name = "pauses_used", definition = "INTEGER DEFAULT 0"},
    {name = "valid_until", definition = "INTEGER DEFAULT 0"}
  }
  for _, column in ipairs(session_columns) do
    local added, migration_err = ensure_table_column(
      db, "sessions", column.name, column.definition
    )
    if added == nil then
      db:close()
      error("session migration failed: " .. tostring(migration_err), 0)
    end
  end

  local known_device_columns = {
    {name = "member", definition = "INTEGER DEFAULT 0"},
    {name = "member_since", definition = "INTEGER DEFAULT 0"}
  }
  for _, column in ipairs(known_device_columns) do
    local added, migration_err = ensure_table_column(
      db, "known_devices", column.name, column.definition
    )
    if added == nil then
      db:close()
      error("known device migration failed: " .. tostring(migration_err), 0)
    end
  end

  local coin_event_columns = {
    {name = "pause_limit", definition = "INTEGER DEFAULT 0"},
    {name = "validity_seconds", definition = "INTEGER DEFAULT 0"}
  }
  for _, column in ipairs(coin_event_columns) do
    local added, migration_err = ensure_table_column(
      db, "coin_events", column.name, column.definition
    )
    if added == nil then
      db:close()
      error("coin event migration failed: " .. tostring(migration_err), 0)
    end
  end

  local voucher_columns = {
    {name = "valid_until", definition = "INTEGER DEFAULT 0"},
    {name = "validity_seconds", definition = "INTEGER DEFAULT 0"},
    {name = "activated_at", definition = "INTEGER DEFAULT 0"},
    {name = "archived", definition = "INTEGER DEFAULT 0"}
  }
  local added_columns = {}
  for _, column in ipairs(voucher_columns) do
    local added, migration_err = ensure_table_column(
      db, "vouchers", column.name, column.definition
    )
    if added == nil then
      db:close()
      error("voucher migration failed: " .. tostring(migration_err), 0)
    end
    added_columns[column.name] = added
  end

  -- Existing validity values were generation-based. Preserve the configured
  -- duration, then make every unused voucher start its clock on redemption.
  if added_columns.validity_seconds then
    if db:exec([[
      UPDATE vouchers
      SET validity_seconds = CASE
        WHEN valid_until > created_at THEN valid_until - created_at
        ELSE 0
      END
    ]]) ~= sqlite3.OK then
      local migration_err = db:errmsg()
      db:close()
      error("voucher validity migration failed: " .. tostring(migration_err), 0)
    end
    if db:exec([[
      UPDATE vouchers
      SET activated_at = CASE
            WHEN status IN ('redeemed', 'used') THEN redeemed_at
            ELSE 0
          END,
          valid_until = CASE
            WHEN status = 'unused' THEN 0
            WHEN validity_seconds > 0 AND redeemed_at > 0
              THEN redeemed_at + validity_seconds
            ELSE 0
          END
    ]]) ~= sqlite3.OK then
      local migration_err = db:errmsg()
      db:close()
      error("voucher activation migration failed: " .. tostring(migration_err), 0)
    end
  end
  if db:exec(
      "CREATE INDEX IF NOT EXISTS idx_vouchers_valid_until ON vouchers(valid_until)"
    ) ~= sqlite3.OK then
    local index_err = db:errmsg()
    db:close()
    error("voucher validity index failed: " .. tostring(index_err), 0)
  end
  if db:exec(
      "CREATE INDEX IF NOT EXISTS idx_vouchers_archived_status ON vouchers(archived, status)"
    ) ~= sqlite3.OK then
    local index_err = db:errmsg()
    db:close()
    error("voucher archive index failed: " .. tostring(index_err), 0)
  end

  local schema_after = schema_before
  schema_stmt = db:prepare("PRAGMA schema_version")
  if schema_stmt and schema_stmt:step() == sqlite3.ROW then
    schema_after = tonumber(schema_stmt:get_value(0)) or schema_before
  end
  if schema_stmt then schema_stmt:finalize() end
  db:close()

  -- Now open again briefly to set defaults. Preserved settings from an older
  -- full or SQM-capable Lite image may still exist in the generic settings
  -- table, so the runtime keeps the capability marker authoritative.
  local sqm_disabled = false
  local sqm_marker = io.open("/etc/kemofi/sqm-disabled", "r")
  if sqm_marker then
    sqm_disabled = true
    sqm_marker:close()
  end
  local db2 = open_db()
  -- Load defaults (only sets keys that don't already exist)
  local defaults = {
    business_name = "KemoFi LiteV2",
    portal_show_business_name = "0",
    portal_name = "KemoFi LiteV2 WiFi",
    portal_footer_text = "",
    portal_footer_link = "https://kemofi.com/",
    portal_rates = "1:12\n5:60\n10:120",
    portal_show_rates = "1",
    portal_show_voucher = "1",
    portal_show_coin = "1",
    portal_hide_device_info = "0",
    coin_min_per_php = "",
    coinslot_timeout_seconds = "60",
    coinslot_busy_lock = "1",
    coinslot_max_empty_opens = "3",
    coinslot_empty_open_window_seconds = "300",
    coinslot_empty_open_cooldown_seconds = "120",
    admin_password = "admin",
    site_blocking_enabled = "0",
    blocked_sites = "",
    upstream_ip_blocking_enabled = "1",
    blocked_upstream_ips = "",
    anti_tethering_enabled = "1",
    gaming_priority_enabled = "1",
    gaming_priority_rules = "[]",
    bw_mode = "off",
    bw_per_client_down_kbps = "0",
    bw_per_client_up_kbps = "0",
    bw_total_down_kbps = "0",
    bw_total_up_kbps = "0",
    bw_exempt_macs = "",
    pause_penalty_minutes = "0",
    auto_pause_on_disconnect = "1",
    auto_resume_on_reconnect = "1",
    free_time_enabled = "0",
    free_time_minutes = "5",
    free_time_daily_limit = "1",
    free_time_schedule_days = "all",
    free_time_schedule_start = "00:00",
    free_time_schedule_end = "23:59",
    auto_reboot_enabled = "0",
    auto_reboot_time = "03:00",
    auto_reboot_days = "daily",
    portal_logo_filename = "",
    portal_coin_sound_enabled = "1",
    portal_tick_sound_enabled = "1",
    portal_coin_sound_file = "coin_sound.mp3",
    portal_tick_sound_file = "tick_sound.mp3",
    license_key = "",
    license_status = "trial"
  }
  if not sqm_disabled then
    defaults.sqm_enabled = "1"
    defaults.sqm_download_kbps = "10240"
    defaults.sqm_upload_kbps = "10240"
    defaults.sqm_linklayer = "ethernet"
    defaults.sqm_overhead = "0"
    defaults.sqm_host_fairness = "1"
  end
  local defaults_added = false
  for key, value in pairs(defaults) do
    local stmt = db2:prepare("SELECT value FROM settings WHERE key = ?")
    if stmt then
      stmt:bind(1, key)
      if stmt:step() ~= sqlite3.ROW then
        local ins = db2:prepare("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)")
        if ins then
          ins:bind(1, key)
          ins:bind(2, value)
          ins:step()
          ins:finalize()
          defaults_added = true
        end
      end
      stmt:finalize()
    end
  end
  db2:close()

  if schema_after ~= schema_before or defaults_added or identity_cleanup_applied or pulse_values_normalized then
    mark_dirty()
  end

  write_file(SCHEMA_READY_PATH, SCHEMA_VERSION)
  _initialized = true
end

--- Create a verified SQLite snapshot and atomically replace the flash copy.
--- Returns true on success, or false plus an error message.
function M.persist(reason, force)
  if not _initialized then M.init() end
  reason = reason or "periodic"
  -- Credit operations are latency-sensitive. Their snapshot is still fully
  -- synced and atomically installed below, but rotating a second copy of the
  -- old database can wait on flash for no benefit to the active transaction.
  -- Periodic/admin persistence continues rotating the recovery backup.
  local credit_persist = tostring(reason):match("coin") ~= nil
  M.cleanup_storage(false)
  if not force and not file_exists(DIRTY_PATH) and file_exists(FLASH_PATH) then
    return true, "clean"
  end

  os.execute("mkdir -p /tmp/kemofi /etc/kemofi")
  local lock, lock_err = acquire_persist_lock()
  if not lock then
    write_status("error", reason, lock_err)
    return false, lock_err
  end

  local ok, result, detail = pcall(function()
    if not force and not file_exists(DIRTY_PATH) and file_exists(FLASH_PATH) then
      return true, "clean"
    end

    local dirty_before = read_file(DIRTY_PATH)
    os.remove(SNAPSHOT_PATH)

    local source, _, source_err = sqlite3.open(DB_PATH, sqlite3.OPEN_READONLY)
    if not source then return false, source_err or "cannot open runtime database" end
    source:busy_timeout(5000)

    local target, _, target_err = sqlite3.open(
      SNAPSHOT_PATH,
      sqlite3.OPEN_READWRITE + sqlite3.OPEN_CREATE
    )
    if not target then
      source:close()
      return false, target_err or "cannot create flash snapshot"
    end
    target:busy_timeout(5000)
    target:exec("PRAGMA journal_mode=DELETE")
    target:exec("PRAGMA synchronous=FULL")

    local backup = sqlite3.backup_init(target, "main", source, "main")
    if not backup then
      local err = target:errmsg()
      target:close()
      source:close()
      os.remove(SNAPSHOT_PATH)
      return false, "backup init failed: " .. tostring(err)
    end

    local step_rc
    local retries = 0
    repeat
      step_rc = backup:step(128)
      if step_rc == sqlite3.BUSY or step_rc == sqlite3.LOCKED then
        retries = retries + 1
        if retries <= 50 then nixio.nanosleep(0, 100000000) end
      end
    until step_rc == sqlite3.DONE or
          (step_rc ~= sqlite3.OK and step_rc ~= sqlite3.BUSY and step_rc ~= sqlite3.LOCKED) or
          retries > 50

    local finish_rc = backup:finish()
    if step_rc ~= sqlite3.DONE or finish_rc ~= sqlite3.OK then
      local err = target:errmsg()
      target:close()
      source:close()
      os.remove(SNAPSHOT_PATH)
      return false, "backup failed: " .. tostring(err) .. " (step=" .. tostring(step_rc) .. ")"
    end

    local valid, check_err = quick_check(target)
    target:close()
    source:close()
    if not valid then
      os.remove(SNAPSHOT_PATH)
      return false, "snapshot integrity check failed: " .. tostring(check_err)
    end
    sync_path(SNAPSHOT_PATH)

    if file_exists(FLASH_PATH) and not credit_persist then
      local backup_tmp = BACKUP_PATH .. ".tmp"
      os.remove(backup_tmp)
      local copied, copy_err = copy_file(FLASH_PATH, backup_tmp)
      if not copied then
        os.remove(SNAPSHOT_PATH)
        os.remove(backup_tmp)
        return false, copy_err
      end
      local backup_ok, backup_err = os.rename(backup_tmp, BACKUP_PATH)
      if not backup_ok then
        os.remove(SNAPSHOT_PATH)
        os.remove(backup_tmp)
        return false, "cannot rotate previous snapshot: " .. tostring(backup_err)
      end
    end

    local renamed, rename_err = os.rename(SNAPSHOT_PATH, FLASH_PATH)
    if not renamed then
      os.remove(SNAPSHOT_PATH)
      return false, "cannot activate flash snapshot: " .. tostring(rename_err)
    end
    sync_path(FLASH_PATH)
    sync_path(FLASH_DIR)

    if read_file(DIRTY_PATH) == dirty_before then
      os.remove(DIRTY_PATH)
    end
    return true, "persisted"
  end)

  release_persist_lock(lock)
  if not ok then
    write_status("error", reason, result)
    os.remove(SNAPSHOT_PATH)
    return false, tostring(result)
  end
  if not result then
    write_status("error", reason, detail)
    return false, detail
  end
  write_status("ok", reason, detail)
  return true, detail
end

--- Backward-compatible periodic sync. Clean databases do not touch flash.
function M.sync_to_flash()
  return M.persist("periodic", false)
end

--- Immediate sync after credit events (coin insert, voucher redeem, free time)
function M.sync_on_credit(source)
  return M.persist(source or "credit", true)
end

local function is_write_statement(sql)
  local keyword = (sql:match("^%s*(%a+)") or ""):upper()
  local is_write = keyword == "INSERT" or keyword == "UPDATE" or keyword == "DELETE" or
                   keyword == "REPLACE" or keyword == "CREATE" or keyword == "ALTER" or
                   keyword == "DROP"
  return is_write, keyword
end

local function exec_internal(durable, sql, ...)
  if not _initialized then M.init() end
  local db = open_db()
  local stmt = db:prepare(sql)
  if not stmt then
    local err = db:errmsg()
    db:close()
    return false, err
  end
  bind_params(stmt, ...)
  local rc = stmt:step()
  local changed = db:changes() > 0
  local err = rc == sqlite3.DONE and nil or db:errmsg()
  stmt:finalize()
  db:close()
  if rc ~= sqlite3.DONE then return false, err end
  local is_write, keyword = is_write_statement(sql)
  local schema_write = keyword == "CREATE" or keyword == "ALTER" or keyword == "DROP"
  if durable and is_write and (changed or schema_write) then mark_dirty() end
  return true
end

--- Execute a durable mutation and mark the database for flash persistence.
function M.exec(sql, ...)
  return exec_internal(true, sql, ...)
end

--- Execute an ephemeral mutation without scheduling a flash write.
function M.exec_runtime(sql, ...)
  return exec_internal(false, sql, ...)
end

--- Query rows
function M.query(sql, ...)
  if not _initialized then M.init() end
  local db = open_db()
  local stmt = db:prepare(sql)
  if not stmt then db:close() return {} end
  bind_params(stmt, ...)
  local results = {}
  while stmt:step() == sqlite3.ROW do
    local row = {}
    local names = stmt:get_names()
    local values = stmt:get_values()
    for i, name in ipairs(names) do
      row[name] = values[i]
    end
    results[#results + 1] = row
  end
  stmt:finalize()
  db:close()
  return results
end

--- Get a single row
function M.row(sql, ...)
  local rows = M.query(sql, ...)
  return rows[1]
end

--- Get a single scalar value
function M.scalar(sql, ...)
  if not _initialized then M.init() end
  local db = open_db()
  local stmt = db:prepare(sql)
  if not stmt then db:close() return nil end
  bind_params(stmt, ...)
  local result = nil
  if stmt:step() == sqlite3.ROW then
    result = stmt:get_value(0)
  end
  stmt:finalize()
  db:close()
  return result
end

--- Get a setting value
function M.setting(key)
  return M.scalar("SELECT value FROM settings WHERE key = ?", key)
end

--- Load a requested group of settings with one database connection.
function M.settings(keys)
  if type(keys) ~= "table" or #keys == 0 then return {} end
  local placeholders = {}
  for i = 1, #keys do placeholders[i] = "?" end
  local unpack_values = table.unpack or unpack
  local rows = M.query(
    "SELECT key, value FROM settings WHERE key IN (" .. table.concat(placeholders, ",") .. ")",
    unpack_values(keys)
  )
  local values = {}
  for _, row in ipairs(rows) do values[row.key] = row.value end
  return values
end

--- Set a setting value
function M.set_setting(key, value)
  return M.exec([[
    INSERT INTO settings (key, value) VALUES (?, ?)
    ON CONFLICT(key) DO UPDATE SET value = excluded.value
    WHERE settings.value IS NOT excluded.value
  ]], key, value)
end

--- Atomically reserve one daily free-time claim.
--- Returns false, "daily_limit_reached" when the limit is already consumed.
function M.reserve_free_time_claim(key, daily_limit)
  if not _initialized then M.init() end
  if type(key) ~= "string" or key == "" then
    return false, "persistence_failed"
  end
  daily_limit = math.floor(tonumber(daily_limit) or 0)
  if daily_limit < 1 then return false, "daily_limit_reached" end

  local database = open_db()
  local transaction_open = false
  local claimed = false
  local ok, err = pcall(function()
    if database:exec("BEGIN IMMEDIATE") ~= sqlite3.OK then
      error("begin_failed:" .. tostring(database:errmsg()), 0)
    end
    transaction_open = true

    local stmt = database:prepare([[
      INSERT INTO settings (key, value) VALUES (?, 1)
      ON CONFLICT(key) DO UPDATE SET value = CAST(settings.value AS INTEGER) + 1
      WHERE CAST(settings.value AS INTEGER) < ?
    ]])
    if not stmt then error(database:errmsg(), 0) end
    stmt:bind(1, key)
    stmt:bind(2, daily_limit)
    local rc = stmt:step()
    local stmt_err = rc == sqlite3.DONE and nil or database:errmsg()
    stmt:finalize()
    if rc ~= sqlite3.DONE then error(stmt_err or "free-time claim failed", 0) end
    claimed = database:changes() == 1

    if database:exec("COMMIT") ~= sqlite3.OK then
      error("commit_failed:" .. tostring(database:errmsg()), 0)
    end
    transaction_open = false
  end)

  if not ok and transaction_open then database:exec("ROLLBACK") end
  database:close()
  if not ok then return false, "persistence_failed" end
  if claimed then
    mark_dirty()
    return true
  end
  return false, "daily_limit_reached"
end

--- Apply a group of setting updates in one transaction.
--- Each entry is {key = "...", value = "..."}; use delete = true to remove it.
function M.set_settings_atomic(entries)
  if not _initialized then M.init() end
  if type(entries) ~= "table" then return false, "invalid settings batch" end

  local database = open_db()
  local transaction_open = false
  local changed = false
  local ok, err = pcall(function()
    if database:exec("BEGIN IMMEDIATE") ~= sqlite3.OK then
      error("begin_failed:" .. tostring(database:errmsg()), 0)
    end
    transaction_open = true

    for _, entry in ipairs(entries) do
      if type(entry) ~= "table" or type(entry.key) ~= "string" or entry.key == "" then
        error("invalid settings entry", 0)
      end

      local stmt
      if entry.delete then
        stmt = database:prepare("DELETE FROM settings WHERE key = ?")
        if stmt then stmt:bind(1, entry.key) end
      else
        stmt = database:prepare([[
          INSERT INTO settings (key, value) VALUES (?, ?)
          ON CONFLICT(key) DO UPDATE SET value = excluded.value
          WHERE settings.value IS NOT excluded.value
        ]])
        if stmt then
          stmt:bind(1, entry.key)
          stmt:bind(2, tostring(entry.value or ""))
        end
      end
      if not stmt then error(database:errmsg(), 0) end
      local rc = stmt:step()
      local stmt_err = rc == sqlite3.DONE and nil or database:errmsg()
      stmt:finalize()
      if rc ~= sqlite3.DONE then error(stmt_err or "settings write failed", 0) end
      if database:changes() > 0 then changed = true end
    end

    if database:exec("COMMIT") ~= sqlite3.OK then
      error("commit_failed:" .. tostring(database:errmsg()), 0)
    end
    transaction_open = false
  end)

  if not ok and transaction_open then database:exec("ROLLBACK") end
  database:close()
  if not ok then return false, tostring(err) end
  if changed then mark_dirty() end
  return true
end

function M.set_runtime_setting(key, value)
  return M.exec_runtime([[
    INSERT INTO settings (key, value) VALUES (?, ?)
    ON CONFLICT(key) DO UPDATE SET value = excluded.value
    WHERE settings.value IS NOT excluded.value
  ]], key, value)
end

local function prepared_row(database, sql, ...)
  local stmt = database:prepare(sql)
  if not stmt then return nil, database:errmsg() end
  bind_params(stmt, ...)
  local row
  if stmt:step() == sqlite3.ROW then
    row = {}
    local names = stmt:get_names()
    local values = stmt:get_values()
    for i, name in ipairs(names) do row[name] = values[i] end
  end
  stmt:finalize()
  return row
end

local function prepared_exec(database, sql, ...)
  local stmt = database:prepare(sql)
  if not stmt then return false, database:errmsg() end
  bind_params(stmt, ...)
  local rc = stmt:step()
  local err = rc == sqlite3.DONE and nil or database:errmsg()
  stmt:finalize()
  return rc == sqlite3.DONE, err
end

local function database_rate_policy(database)
  local rates_row, rates_err = prepared_row(
    database, "SELECT value FROM settings WHERE key = ?", "portal_rates"
  )
  if rates_err then error(rates_err) end
  local flat_row, flat_err = prepared_row(
    database, "SELECT value FROM settings WHERE key = ?", "coin_min_per_php"
  )
  if flat_err then error(flat_err) end
  return rates_row and rates_row.value or "1:12", flat_row and flat_row.value or ""
end

-- Re-resolve a pending balance using the current policy. This also repairs a
-- pending balance created by an older build that priced each physical coin
-- separately before the customer activates it.
local function pending_rate_totals(database, pending, now)
  local rates_value, flat_value = database_rate_policy(database)
  local amount = math.max(0, math.floor(tonumber(pending.amount_php) or 0))
  local minutes, pause_limit, validity_seconds =
    resolve_pending_rate(amount, rates_value, flat_value)

  local current_valid_until = tonumber(pending.valid_until) or 0
  local valid_until = 0
  if validity_seconds > 0 and current_valid_until ~= 0 then
    valid_until = math.max(current_valid_until, now + validity_seconds)
  end
  return minutes, pause_limit, valid_until
end

--- Generate an exact voucher batch atomically, retrying unique-code collisions.
function M.generate_voucher_batch(options)
  if not _initialized then M.init() end
  options = options or {}
  local count = math.floor(tonumber(options.count) or 0)
  local code_length = math.floor(tonumber(options.code_length) or 0)
  local alphabet = tostring(options.alphabet or "")
  local minutes = tonumber(options.minutes) or 0
  local price_php = tonumber(options.price_php) or 0
  local batch_label = tostring(options.batch_label or "")
  local validity_seconds = math.floor(tonumber(options.validity_seconds) or 0)
  local created_at = math.floor(tonumber(options.created_at) or os.time())

  if count < 1 or code_length < 1 or #alphabet < 2 or minutes <= 0 then
    return false, nil, "invalid_voucher_batch"
  end

  local database = open_db()
  local transaction_open = false
  local generated = {}
  local ok, err = pcall(function()
    if database:exec("BEGIN IMMEDIATE") ~= sqlite3.OK then
      error("begin_failed:" .. tostring(database:errmsg()), 0)
    end
    transaction_open = true

    for _ = 1, count do
      local inserted = false
      for _ = 1, 200 do
        local code, random_err = util.random_string(alphabet, code_length)
        if not code then error(random_err or "secure_random_unavailable", 0) end
        local wrote, write_err = prepared_exec(database, [[
          INSERT OR IGNORE INTO vouchers
            (code, minutes, price_php, status, batch_label, created_at,
             validity_seconds, activated_at, valid_until, archived)
          VALUES (?, ?, ?, 'unused', ?, ?, ?, 0, 0, 0)
        ]], code, minutes, price_php, batch_label, created_at, validity_seconds)
        if not wrote then error(write_err or "voucher_insert_failed", 0) end
        if database:changes() == 1 then
          generated[#generated + 1] = {
            code = code,
            minutes = minutes,
            price_php = price_php,
            validity_seconds = validity_seconds,
            activated_at = 0,
            valid_until = 0
          }
          inserted = true
          break
        end
      end
      if not inserted then error("voucher_code_space_exhausted", 0) end
    end

    if database:exec("COMMIT") ~= sqlite3.OK then
      error("commit_failed:" .. tostring(database:errmsg()), 0)
    end
    transaction_open = false
  end)

  if not ok and transaction_open then database:exec("ROLLBACK") end
  database:close()
  if not ok then return false, nil, tostring(err) end
  mark_dirty()
  return true, generated
end

--- Atomically claim one valid voucher and add its credit to a session.
function M.redeem_voucher_credit(value_mac, value_code, value_now)
  if not _initialized then M.init() end
  local mac = normalize_mac(value_mac)
  if not mac then return false, nil, "invalid_mac" end
  local code, code_err = util.normalize_voucher_code(value_code)
  if not code then return false, nil, code_err end
  local now = tonumber(value_now) or os.time()

  local database = open_db()
  local transaction_open = false
  local result = {}
  local ok, err = pcall(function()
    if database:exec("BEGIN IMMEDIATE") ~= sqlite3.OK then
      error("begin_failed:" .. tostring(database:errmsg()), 0)
    end
    transaction_open = true

    local voucher, row_err = prepared_row(
      database, "SELECT * FROM vouchers WHERE code = ?", code
    )
    if row_err then error(row_err, 0) end
    if not voucher or voucher.status ~= "unused" or tonumber(voucher.archived) == 1 then
      result.error = "invalid_or_used"
      database:exec("ROLLBACK")
      transaction_open = false
      return
    end

    local wrote, write_err = prepared_exec(database, [[
      UPDATE vouchers
      SET status = 'redeemed',
          activated_at = ?,
          valid_until = CASE
            WHEN validity_seconds > 0 THEN ? + validity_seconds
            ELSE 0
          END,
          redeemed_at = ?,
          redeemed_by_mac = ?
      WHERE id = ? AND status = 'unused' AND archived = 0
    ]], now, now, now, mac, voucher.id)
    if not wrote then error(write_err or "voucher_claim_failed", 0) end
    if database:changes() ~= 1 then
      result.error = "invalid_or_used"
      database:exec("ROLLBACK")
      transaction_open = false
      return
    end

    local minutes = tonumber(voucher.minutes) or 0
    if minutes <= 0 then error("invalid_voucher_minutes", 0) end
    local existing
    existing, row_err = prepared_row(
      database, "SELECT * FROM sessions WHERE mac = ?", mac
    )
    if row_err then error(row_err, 0) end

    if existing and (tonumber(existing.expires_at) or 0) > now and
        tonumber(existing.paused) == 0 then
      local expires_at = (tonumber(existing.expires_at) or now) + (minutes * 60)
      if tonumber(existing.valid_until) and tonumber(existing.valid_until) > 0 and
          expires_at > tonumber(existing.valid_until) then
        expires_at = tonumber(existing.valid_until)
      end
      wrote, write_err = prepared_exec(database, [[
        UPDATE sessions
        SET minutes_remaining = ?, expires_at = ?
        WHERE mac = ?
      ]], (tonumber(existing.minutes_remaining) or 0) + minutes,
        expires_at, mac)
    elseif existing and tonumber(existing.paused) == 1 then
      wrote, write_err = prepared_exec(database, [[
        UPDATE sessions SET minutes_remaining = ? WHERE mac = ?
      ]], (tonumber(existing.minutes_remaining) or 0) + minutes, mac)
    else
      wrote, write_err = prepared_exec(database, [[
        INSERT OR REPLACE INTO sessions
          (mac, minutes_remaining, started_at, expires_at, last_seen, paused)
        VALUES (?, ?, ?, ?, ?, 0)
      ]], mac, minutes, now, now + (minutes * 60), now)
    end
    if not wrote then error(write_err or "session_credit_failed", 0) end

    wrote, write_err = prepared_exec(database, [[
      INSERT INTO transactions
        (mac, amount_php, minutes_granted, source, created_at)
      VALUES (?, ?, ?, 'voucher', ?)
    ]], mac, tonumber(voucher.price_php) or 0, minutes, now)
    if not wrote then error(write_err or "transaction_write_failed", 0) end

    wrote, write_err = prepared_exec(database, [[
      INSERT OR IGNORE INTO known_devices (mac, first_seen, last_seen)
      VALUES (?, ?, ?)
    ]], mac, now, now)
    if not wrote then error(write_err or "known_device_insert_failed", 0) end
    wrote, write_err = prepared_exec(
      database, "UPDATE known_devices SET last_seen = ? WHERE mac = ?", now, mac
    )
    if not wrote then error(write_err or "known_device_update_failed", 0) end

    if database:exec("COMMIT") ~= sqlite3.OK then
      error("commit_failed:" .. tostring(database:errmsg()), 0)
    end
    transaction_open = false
    voucher.status = "redeemed"
    voucher.activated_at = now
    voucher.valid_until = (tonumber(voucher.validity_seconds) or 0) > 0 and
      (now + tonumber(voucher.validity_seconds)) or 0
    voucher.redeemed_at = now
    voucher.redeemed_by_mac = mac
    result.voucher = voucher
  end)

  if not ok and transaction_open then database:exec("ROLLBACK") end
  database:close()
  if not ok then return false, nil, tostring(err) end
  if result.error then return false, nil, result.error end
  mark_dirty()
  return true, result.voucher
end

local function alias_group_for(database, mac)
  local row, err = prepared_row(
    database, "SELECT group_id FROM device_aliases WHERE mac = ?", mac
  )
  if err then return nil, err end
  return row and row.group_id or nil
end

local function alias_group_has_other_active(database, group_id, mac_a, mac_b, now)
  if not group_id then return false end
  local row, err = prepared_row(database, [[
    SELECT COUNT(*) AS count
    FROM device_aliases da
    JOIN sessions s ON s.mac = da.mac
    WHERE da.group_id = ? AND da.mac NOT IN (?, ?)
      AND (s.paused = 1 OR (s.paused = 0 AND s.expires_at > ?))
  ]], group_id, mac_a, mac_b, now)
  if err then return nil, err end
  return (tonumber(row and row.count) or 0) > 0
end

local function new_alias_group_id(database)
  for _ = 1, 8 do
    local candidate = util.random_token(24)
    if candidate and #candidate == 24 then
      local existing, err = prepared_row(
        database, "SELECT 1 AS present FROM device_aliases WHERE group_id = ? LIMIT 1",
        candidate
      )
      if err then return nil, err end
      if not existing then return candidate end
    end
  end
  return nil, "alias_group_generation_failed"
end

local function link_device_aliases_in_transaction(database, value_a, value_b, now)
  local mac_a = normalize_mac(value_a)
  local mac_b = normalize_mac(value_b)
  if not mac_a or not mac_b then return nil, "invalid_alias_mac" end

  local group_a, err = alias_group_for(database, mac_a)
  if err then return nil, err end
  local group_b
  group_b, err = alias_group_for(database, mac_b)
  if err then return nil, err end

  local conflict
  conflict, err = alias_group_has_other_active(database, group_a, mac_a, mac_b, now)
  if err then return nil, err end
  if conflict then return nil, "alias_group_conflict" end
  if group_b ~= group_a then
    conflict, err = alias_group_has_other_active(database, group_b, mac_a, mac_b, now)
    if err then return nil, err end
    if conflict then return nil, "alias_group_conflict" end
  end

  local group_id = group_a or group_b
  if not group_id then
    group_id, err = new_alias_group_id(database)
    if not group_id then return nil, err end
  end

  if group_a and group_b and group_a ~= group_b then
    local merged
    merged, err = prepared_exec(
      database, "UPDATE device_aliases SET group_id = ?, verified_at = ? WHERE group_id = ?",
      group_id, now, group_b
    )
    if not merged then return nil, err end
  end

  for _, mac in ipairs({mac_a, mac_b}) do
    local written
    written, err = prepared_exec(database, [[
      INSERT INTO device_aliases (mac, group_id, verified_at) VALUES (?, ?, ?)
      ON CONFLICT(mac) DO UPDATE SET
        group_id = excluded.group_id,
        verified_at = excluded.verified_at
    ]], mac, group_id, now)
    if not written then return nil, err end
  end

  return group_id
end

--- Permanently link two MACs after their shared ownership has been verified.
function M.link_device_aliases(mac_a, mac_b)
  if not _initialized then M.init() end
  local database = open_db()
  local transaction_open = false
  local ok, result = pcall(function()
    if database:exec("BEGIN IMMEDIATE") ~= sqlite3.OK then
      error("begin_failed:" .. tostring(database:errmsg()), 0)
    end
    transaction_open = true
    local group_id, err = link_device_aliases_in_transaction(
      database, mac_a, mac_b, os.time()
    )
    if not group_id then error(err or "alias_link_failed", 0) end
    if database:exec("COMMIT") ~= sqlite3.OK then
      error("commit_failed:" .. tostring(database:errmsg()), 0)
    end
    transaction_open = false
    return group_id
  end)

  if not ok and transaction_open then database:exec("ROLLBACK") end
  database:close()
  if not ok then return false, nil, tostring(result) end
  mark_dirty()
  return true, result
end

--- Find the one active or paused session owned by a verified alias of this MAC.
function M.active_alias_owner(value)
  if not _initialized then M.init() end
  local mac = normalize_mac(value)
  if not mac then return nil, "invalid_alias_mac" end

  local target = M.row("SELECT blocked FROM known_devices WHERE mac = ?", mac)
  if target and target.blocked == 1 then return nil, "target_blocked" end

  local group = M.row("SELECT group_id FROM device_aliases WHERE mac = ?", mac)
  if not group then return nil, "alias_unknown" end

  local now = os.time()
  local current = M.row(
    "SELECT expires_at, paused FROM sessions WHERE mac = ?", mac
  )
  if current and (current.paused == 1 or
      ((tonumber(current.expires_at) or 0) > now)) then
    return nil, "target_has_active_session"
  end

  local owners = M.query([[
    SELECT s.mac, s.expires_at, s.paused
    FROM device_aliases da
    JOIN sessions s ON s.mac = da.mac
    WHERE da.group_id = ? AND da.mac <> ?
      AND (s.paused = 1 OR (s.paused = 0 AND s.expires_at > ?))
    ORDER BY s.last_seen DESC, s.mac ASC
  ]], group.group_id, mac, now)
  if #owners == 0 then return nil, "alias_inactive" end
  if #owners > 1 then return nil, "alias_group_conflict" end
  return owners[1]
end

--- Add one physical coin to durable pending credit without starting internet.
function M.pending_coin_add(mac, minutes, amount_php, browser_fp, device_id, roam_fp,
    pause_limit, validity_seconds, rates_value, flat_value)
  if not _initialized then M.init() end
  local database = open_db()
  local transaction_open = false
  local pending
  local now = os.time()
  local coin_amount = math.max(0, math.floor(tonumber(amount_php) or 0))
  local ok, err = pcall(function()
    if database:exec("BEGIN IMMEDIATE") ~= sqlite3.OK then error(database:errmsg()) end
    transaction_open = true
    local existing = prepared_row(
      database, "SELECT * FROM pending_coin_credits WHERE mac = ?", mac
    )
    local previous_amount = existing and tonumber(existing.amount_php) or 0
    local aggregate_amount = previous_amount + coin_amount
    local aggregate_minutes, aggregate_pause_limit, aggregate_validity_seconds =
      resolve_pending_rate(aggregate_amount, rates_value, flat_value)
    if aggregate_minutes <= 0 then error("invalid_rate") end

    local valid_until = 0
    if aggregate_validity_seconds > 0 and
        (not existing or tonumber(existing.valid_until) ~= 0) then
      valid_until = now + aggregate_validity_seconds
      if existing then
        valid_until = math.max(valid_until, tonumber(existing.valid_until) or 0)
      end
    end
    local transaction_id = existing and tonumber(existing.transaction_id) or 0

    local wrote, write_err
    if transaction_id > 0 then
      wrote, write_err = prepared_exec(database, [[
        UPDATE transactions
        SET amount_php = ?, minutes_granted = ?,
            coin_count = coin_count + 1
        WHERE id = ? AND mac = ? AND source = 'coin'
      ]], aggregate_amount, aggregate_minutes, transaction_id, mac)
      if not wrote or database:changes() ~= 1 then
        error(write_err or "pending transaction missing")
      end
    else
      wrote, write_err = prepared_exec(database, [[
        INSERT INTO transactions
          (mac, amount_php, minutes_granted, source, created_at, coin_count)
        VALUES (?, ?, ?, 'coin', ?, 1)
      ]], mac, aggregate_amount, aggregate_minutes, now)
      if not wrote then error(write_err) end
      transaction_id = database:last_insert_rowid()
    end

    if existing then
      wrote, write_err = prepared_exec(database, [[
        UPDATE pending_coin_credits
        SET minutes = ?, amount_php = ?, coin_count = coin_count + 1,
            pause_limit = ?, valid_until = ?,
            browser_fp = CASE WHEN ? <> '' THEN ? ELSE browser_fp END,
            device_id = CASE WHEN ? <> '' THEN ? ELSE device_id END,
            roam_fp = CASE WHEN ? <> '' THEN ? ELSE roam_fp END,
            updated_at = ?, transaction_id = ?
        WHERE mac = ?
      ]], aggregate_minutes, aggregate_amount, aggregate_pause_limit, valid_until,
        browser_fp or "", browser_fp or "", device_id or "", device_id or "",
        roam_fp or "", roam_fp or "", now, transaction_id, mac)
    else
      wrote, write_err = prepared_exec(database, [[
        INSERT INTO pending_coin_credits
          (mac, minutes, amount_php, coin_count, browser_fp, device_id, roam_fp,
           created_at, updated_at, transaction_id, pause_limit, valid_until)
        VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?)
      ]], mac, aggregate_minutes, aggregate_amount, browser_fp or "", device_id or "",
        roam_fp or "", now, now, transaction_id, aggregate_pause_limit, valid_until)
    end
    if not wrote or database:changes() ~= 1 then error(write_err or "pending credit write failed") end

    pending = prepared_row(database, "SELECT * FROM pending_coin_credits WHERE mac = ?", mac)
    if database:exec("COMMIT") ~= sqlite3.OK then error(database:errmsg()) end
    transaction_open = false
  end)
  if not ok and transaction_open then database:exec("ROLLBACK") end
  database:close()
  if not ok then return false, tostring(err) end
  mark_dirty()
  return true, pending
end

--- Record one authenticated hardware event and its pending credit atomically.
--- Replaying the same event_id returns the original event without adding credit.
function M.coin_event_credit(options)
  if not _initialized then M.init() end
  options = options or {}
  local event_id = tostring(options.event_id or "")
  local node_id = tostring(options.node_id or "")
  local mac = normalize_mac(options.target_mac)
  local pulses = math.floor(tonumber(options.pulses) or 0)
  local amount_php = tonumber(options.amount_php) or 0
  local minutes = tonumber(options.minutes) or 0
  local pause_limit = math.max(0, math.floor(tonumber(options.pause_limit) or 0))
  local now = math.floor(tonumber(options.created_at) or os.time())
  local validity_seconds = math.max(0, math.floor(tonumber(options.validity_seconds) or 0))

  if event_id == "" or #event_id > 80 or node_id == "" or not mac or
      pulses < 1 or amount_php <= 0 or minutes <= 0 then
    return false, nil, "invalid_coin_event"
  end

  local database = open_db()
  local transaction_open = false
  local result
  local changed = false
  local ok, err = pcall(function()
    if database:exec("BEGIN IMMEDIATE") ~= sqlite3.OK then error(database:errmsg(), 0) end
    transaction_open = true

    local existing, row_err = prepared_row(
      database, "SELECT * FROM coin_events WHERE event_id = ?", event_id
    )
    if row_err then error(row_err, 0) end
    if existing then
      result = {
        duplicate = true,
        event = existing,
        pending = prepared_row(
          database, "SELECT * FROM pending_coin_credits WHERE mac = ?", existing.target_mac
        )
      }
      if database:exec("COMMIT") ~= sqlite3.OK then error(database:errmsg(), 0) end
      transaction_open = false
      return
    end

    local existing_pending, pending_err = prepared_row(
      database, "SELECT * FROM pending_coin_credits WHERE mac = ?", mac
    )
    if pending_err then error(pending_err, 0) end
    local previous_amount = existing_pending and tonumber(existing_pending.amount_php) or 0
    local previous_minutes = existing_pending and tonumber(existing_pending.minutes) or 0
    local aggregate_amount = previous_amount + amount_php
    local aggregate_minutes, aggregate_pause_limit, aggregate_validity_seconds =
      resolve_pending_rate(aggregate_amount, options.rates_value, options.flat_value)
    if aggregate_minutes <= 0 then error("invalid_rate", 0) end
    local incremental_minutes = math.max(0, aggregate_minutes - previous_minutes)
    local valid_until = 0
    if aggregate_validity_seconds > 0 and
        (not existing_pending or tonumber(existing_pending.valid_until) ~= 0) then
      valid_until = now + aggregate_validity_seconds
      if existing_pending then
        valid_until = math.max(valid_until, tonumber(existing_pending.valid_until) or 0)
      end
    end
    local transaction_id = existing_pending and tonumber(existing_pending.transaction_id) or 0

    local wrote, write_err = prepared_exec(database, [[
      INSERT INTO coin_events
        (event_id, node_id, target_mac, pulses, amount_php, minutes_granted, pause_limit, validity_seconds, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], event_id, node_id, mac, pulses, amount_php, incremental_minutes,
      aggregate_pause_limit, aggregate_validity_seconds, now)
    if not wrote then error(write_err, 0) end

    if transaction_id > 0 then
      wrote, write_err = prepared_exec(database, [[
        UPDATE transactions
        SET amount_php = ?, minutes_granted = ?,
            coin_count = coin_count + 1
        WHERE id = ? AND mac = ? AND source = 'coin'
      ]], aggregate_amount, aggregate_minutes, transaction_id, mac)
      if not wrote or database:changes() ~= 1 then
        error(write_err or "pending transaction missing", 0)
      end
    else
      wrote, write_err = prepared_exec(database, [[
        INSERT INTO transactions
          (mac, amount_php, minutes_granted, source, created_at, coin_count)
        VALUES (?, ?, ?, 'coin', ?, 1)
      ]], mac, aggregate_amount, aggregate_minutes, now)
      if not wrote then error(write_err, 0) end
      transaction_id = database:last_insert_rowid()
    end

    if existing_pending then
      wrote, write_err = prepared_exec(database, [[
        UPDATE pending_coin_credits
        SET minutes = ?, amount_php = ?, coin_count = coin_count + 1,
            pause_limit = ?, valid_until = ?,
            browser_fp = CASE WHEN ? <> '' THEN ? ELSE browser_fp END,
            device_id = CASE WHEN ? <> '' THEN ? ELSE device_id END,
            roam_fp = CASE WHEN ? <> '' THEN ? ELSE roam_fp END,
            updated_at = ?, transaction_id = ?
        WHERE mac = ?
      ]], aggregate_minutes, aggregate_amount, aggregate_pause_limit, valid_until,
        options.browser_fp or "", options.browser_fp or "", options.device_id or "",
        options.device_id or "", options.roam_fp or "", options.roam_fp or "", now,
        transaction_id, mac)
    else
      wrote, write_err = prepared_exec(database, [[
        INSERT INTO pending_coin_credits
          (mac, minutes, amount_php, coin_count, browser_fp, device_id, roam_fp,
           created_at, updated_at, transaction_id, pause_limit, valid_until)
        VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?)
      ]], mac, aggregate_minutes, aggregate_amount, options.browser_fp or "",
        options.device_id or "", options.roam_fp or "", now, now, transaction_id,
        aggregate_pause_limit, valid_until)
    end
    if not wrote or database:changes() ~= 1 then error(write_err or "pending credit write failed", 0) end

    wrote, write_err = prepared_exec(database, [[
      UPDATE coin_nodes
      SET total_coins = total_coins + 1,
          last_heartbeat = ?,
          ip_address = CASE WHEN ? <> '' THEN ? ELSE ip_address END
      WHERE node_id = ?
    ]], now, options.ip_address or "", options.ip_address or "", node_id)
    if not wrote then error(write_err, 0) end
    if database:changes() ~= 1 then error("unknown_coin_node", 0) end

    local pending, pending_err = prepared_row(
      database, "SELECT * FROM pending_coin_credits WHERE mac = ?", mac
    )
    if pending_err then error(pending_err, 0) end
    result = {
      duplicate = false,
      event = {
        event_id = event_id,
        node_id = node_id,
        target_mac = mac,
        pulses = pulses,
        amount_php = amount_php,
        minutes_granted = incremental_minutes,
        pause_limit = aggregate_pause_limit,
        validity_seconds = aggregate_validity_seconds,
        created_at = now
      },
      pending = pending
    }
    if database:exec("COMMIT") ~= sqlite3.OK then error(database:errmsg(), 0) end
    transaction_open = false
    changed = true
  end)

  if not ok and transaction_open then database:exec("ROLLBACK") end
  database:close()
  if not ok then return false, nil, tostring(err) end
  if changed then mark_dirty() end
  return true, result
end

--- Fast Lane v2 coin path. A small record reaches persistent storage before
--- SQLite is changed or success is returned. The full DB snapshot is flushed
--- later by the supervised timer; replaying a record is idempotent by event_id.
function M.fast_lane_coin_event(options)
  if not _initialized then M.init() end
  options = options or {}
  options.created_at = math.floor(tonumber(options.created_at) or os.time())
  local event_id = tostring(options.event_id or "")
  local node_id = tostring(options.node_id or "")
  local mac = normalize_mac(options.target_mac)
  local pulses = math.floor(tonumber(options.pulses) or 0)
  local amount_php = tonumber(options.amount_php) or 0
  local minutes = tonumber(options.minutes) or 0
  if event_id == "" or #event_id > 80 or node_id == "" or not mac or
      pulses < 1 or amount_php <= 0 or minutes <= 0 then
    return false, nil, "invalid_coin_event"
  end

  local lock, lock_err = acquire_fast_lane_lock()
  if not lock then return false, nil, lock_err end
  local ok, result, detail, extra = pcall(function()
    local existing = M.row("SELECT event_id FROM coin_events WHERE event_id = ?", event_id)
    local canonical = options
    local record_path = fast_lane_event_path(event_id)
    if not existing then
      if file_exists(record_path) then
        local stored, stored_err = read_fast_lane_record(record_path)
        if not stored then return false, nil, stored_err end
        canonical = stored
      else
        local wrote, write_err = write_fast_lane_record(options)
        if not wrote then return false, nil, write_err end
      end
    end
    local credited, credit_result, credit_err = M.coin_event_credit(canonical)
    if not credited then return false, nil, credit_err end
    return true, credit_result, "accepted"
  end)
  release_fast_lane_lock(lock)
  if not ok then return false, nil, tostring(result) end
  return result, detail, extra
end

--- Replay Fast Lane records, snapshot the resulting SQLite state, then remove
--- only records covered by that verified snapshot. This is safe to call on
--- boot and from the timer; duplicate records do not add credit twice.
function M.fast_lane_flush()
  if not _initialized then M.init() end
  local lock, lock_err = acquire_fast_lane_lock()
  if not lock then return false, lock_err end
  local ok, result, detail = pcall(function()
    local paths, paths_err = list_fast_lane_records()
    if not paths then return false, paths_err end
    if #paths == 0 then return true, "empty" end

    for _, path in ipairs(paths) do
      local record, record_err = read_fast_lane_record(path)
      if not record then return false, record_err .. ": " .. path end
      local credited, _, credit_err = M.coin_event_credit(record)
      if not credited then return false, "cannot replay Fast Lane record: " .. tostring(credit_err) end
    end

    local persisted, persist_err = M.persist("coin-fast-lane", false)
    if not persisted then return false, "cannot persist Fast Lane records: " .. tostring(persist_err) end

    for _, path in ipairs(paths) do os.remove(path) end
    -- The verified SQLite snapshot now contains the events. If directory
    -- fsync is unsupported, the records are still safe to remove because the
    -- snapshot was installed first and replay is idempotent.
    sync_path(FAST_LANE_DIR)
    return true, "flushed"
  end)
  release_fast_lane_lock(lock)
  if not ok then return false, tostring(result) end
  return result, detail
end

function M.fast_lane_recover()
  return M.fast_lane_flush()
end

function M.pending_coin_get(mac)
  local pending = M.row("SELECT * FROM pending_coin_credits WHERE mac = ?", mac)
  if not pending then return nil end

  -- Project the corrected aggregate into the status response immediately so
  -- an already-open purchase does not keep showing the old per-coin total.
  -- Finalization persists the same correction atomically below.
  local database = open_db()
  local ok, minutes, pause_limit, valid_until = pcall(function()
    return pending_rate_totals(database, pending, os.time())
  end)
  database:close()
  if ok then
    pending.minutes = minutes
    pending.pause_limit = pause_limit
    pending.valid_until = valid_until
  end
  return pending
end

function M.pending_coin_stale(cutoff)
  return M.query(
    "SELECT mac FROM pending_coin_credits WHERE updated_at <= ? ORDER BY updated_at ASC",
    cutoff
  )
end

--- Atomically consume pending credit and apply it to exactly one session.
function M.pending_coin_finalize(mac)
  if not _initialized then M.init() end
  local database = open_db()
  local transaction_open = false
  local pending
  local mode
  local ok, err = pcall(function()
    if database:exec("BEGIN IMMEDIATE") ~= sqlite3.OK then error(database:errmsg()) end
    transaction_open = true
    pending = prepared_row(database, "SELECT * FROM pending_coin_credits WHERE mac = ?", mac)
    if not pending then
      if database:exec("COMMIT") ~= sqlite3.OK then error(database:errmsg()) end
      transaction_open = false
      return
    end

    local now = os.time()
    local minutes = tonumber(pending.minutes) or 0
    local corrected_minutes, corrected_pause_limit, corrected_valid_until =
      pending_rate_totals(database, pending, now)
    if corrected_minutes ~= minutes or
        corrected_pause_limit ~= (tonumber(pending.pause_limit) or 0) or
        corrected_valid_until ~= (tonumber(pending.valid_until) or 0) then
      minutes = corrected_minutes
      pending.minutes = corrected_minutes
      pending.pause_limit = corrected_pause_limit
      pending.valid_until = corrected_valid_until
      local corrected, correction_err = prepared_exec(database, [[
        UPDATE pending_coin_credits
        SET minutes = ?, pause_limit = ?, valid_until = ?, updated_at = ?
        WHERE mac = ?
      ]], corrected_minutes, corrected_pause_limit, corrected_valid_until, now, mac)
      if not corrected then error(correction_err) end
    end
    local incoming_valid_until = tonumber(pending.valid_until) or 0
    local existing = prepared_row(database, "SELECT * FROM sessions WHERE mac = ?", mac)
    local existing_valid_until = existing and tonumber(existing.valid_until) or 0
    local merged_valid_until
    if not existing or existing_valid_until == 0 or incoming_valid_until == 0 then
      merged_valid_until = existing and (existing_valid_until == 0 and 0 or incoming_valid_until) or incoming_valid_until
    else
      merged_valid_until = math.max(existing_valid_until, incoming_valid_until)
    end
    local wrote, write_err
    if existing and tonumber(existing.paused) == 0 and
        (tonumber(existing.expires_at) or 0) > now then
      mode = "extended"
      local expires_at = (tonumber(existing.expires_at) or now) + (minutes * 60)
      if merged_valid_until > 0 and expires_at > merged_valid_until then
        expires_at = merged_valid_until
      end
      wrote, write_err = prepared_exec(database, [[
        UPDATE sessions
        SET minutes_remaining = minutes_remaining + ?, expires_at = ?, last_seen = ?,
            pause_limit = CASE
              WHEN pause_limit = 0 OR ? = 0 THEN 0
              WHEN ? > pause_limit THEN ?
              ELSE pause_limit
            END,
            valid_until = ?
        WHERE mac = ?
      ]], minutes, expires_at, now, tonumber(pending.pause_limit) or 0,
        tonumber(pending.pause_limit) or 0, tonumber(pending.pause_limit) or 0,
        merged_valid_until, mac)
    elseif existing and tonumber(existing.paused) == 1 then
      mode = "paused"
      wrote, write_err = prepared_exec(database, [[
        UPDATE sessions SET minutes_remaining = minutes_remaining + ?, last_seen = ?,
            pause_limit = CASE
              WHEN pause_limit = 0 OR ? = 0 THEN 0
              WHEN ? > pause_limit THEN ?
              ELSE pause_limit
            END,
            valid_until = ?
        WHERE mac = ?
      ]], minutes, now, tonumber(pending.pause_limit) or 0,
        tonumber(pending.pause_limit) or 0, tonumber(pending.pause_limit) or 0,
        merged_valid_until, mac)
    else
      mode = "started"
      local expires_at = now + (minutes * 60)
      if merged_valid_until > 0 and expires_at > merged_valid_until then
        expires_at = merged_valid_until
      end
      wrote, write_err = prepared_exec(database, [[
        INSERT OR REPLACE INTO sessions
          (mac, minutes_remaining, started_at, expires_at, last_seen, paused, auto_paused, pause_limit, pauses_used, valid_until)
        VALUES (?, ?, ?, ?, ?, 0, 0, ?, 0, ?)
      ]], mac, minutes, now, expires_at, now,
        tonumber(pending.pause_limit) or 0, merged_valid_until)
    end
    if not wrote then error(write_err) end

    if tonumber(pending.transaction_id) and tonumber(pending.transaction_id) > 0 then
      wrote, write_err = prepared_exec(database, [[
        UPDATE transactions
        SET amount_php = ?, minutes_granted = ?
        WHERE id = ? AND mac = ? AND source = 'coin'
      ]], tonumber(pending.amount_php) or 0, minutes,
        tonumber(pending.transaction_id), mac)
      if not wrote then error(write_err) end
    end

    wrote, write_err = prepared_exec(database, [[
      INSERT INTO known_devices (mac, first_seen, last_seen)
      VALUES (?, ?, ?)
      ON CONFLICT(mac) DO UPDATE SET last_seen = excluded.last_seen
    ]], mac, now, now)
    if not wrote then error(write_err) end

    local token_row = prepared_row(
      database, "SELECT token FROM session_tokens WHERE mac = ?", mac
    )
    local token = token_row and token_row.token or nil
    if token then
      wrote, write_err = prepared_exec(
        database, "UPDATE session_tokens SET last_seen = ? WHERE token = ?", now, token
      )
      if not wrote then error(write_err) end
    else
      for _ = 1, 8 do
        local candidate = util.random_token(32)
        if candidate and #candidate == 32 and not prepared_row(
            database, "SELECT token FROM session_tokens WHERE token = ?", candidate
          ) then
          token = candidate
          break
        end
      end
      if not token then error("unable to generate a unique session token") end
      wrote, write_err = prepared_exec(database, [[
        INSERT INTO session_tokens (token, mac, created_at, last_seen) VALUES (?, ?, ?, ?)
      ]], token, mac, now, now)
      if not wrote then error(write_err) end
    end

    wrote, write_err = prepared_exec(database, [[
      INSERT OR REPLACE INTO token_bindings (token, kind, value) VALUES (?, 'mac', ?)
    ]], token, mac)
    if not wrote then error(write_err) end
    if pending.device_id and pending.device_id ~= "" then
      local target = prepared_row(database,
        "SELECT mac FROM session_tokens WHERE token = ?", token)
      local owner = prepared_row(database, [[
        SELECT st.mac, s.expires_at, s.paused
        FROM token_bindings tb
        JOIN session_tokens st ON st.token = tb.token
        LEFT JOIN sessions s ON s.mac = st.mac
        WHERE tb.kind = 'device_id' AND tb.value = ?
      ]], pending.device_id)
      local owner_active = owner and owner.mac ~= (target and target.mac) and
        session_is_active(owner, os.time())
      if not owner_active then
        prepared_exec(database,
          "DELETE FROM token_bindings WHERE kind = 'device_id' AND value = ?",
          pending.device_id)
        wrote, write_err = prepared_exec(database, [[
          INSERT INTO token_bindings (token, kind, value) VALUES (?, 'device_id', ?)
        ]], token, pending.device_id)
      else
        wrote, write_err = true, nil
      end
      if not wrote then error(write_err) end
    end
    pending.token = token

    wrote, write_err = prepared_exec(
      database, "DELETE FROM pending_coin_credits WHERE mac = ?", mac
    )
    if not wrote then error(write_err) end
    if database:exec("COMMIT") ~= sqlite3.OK then error(database:errmsg()) end
    transaction_open = false
  end)
  if not ok and transaction_open then database:exec("ROLLBACK") end
  database:close()
  if not ok then return false, nil, tostring(err) end
  if pending then mark_dirty() end
  return true, pending, mode
end

--- ─── Token / Fingerprint Helpers ─────────────────────────────────────────

--- Mint (create or refresh) a session token for a MAC.
--- Returns the token string.
function M.token_mint(mac)
  local now = os.time()

  -- Check if a token already exists for this MAC
  local existing = M.row("SELECT token FROM session_tokens WHERE mac = ?", mac)
  if existing then
    M.exec_runtime("UPDATE session_tokens SET last_seen = ? WHERE token = ?", now, existing.token)
    return existing.token
  end

  -- Create a cryptographically random token and guard against collisions.
  local token
  for _ = 1, 8 do
    local candidate = util.random_token(32)
    if candidate and #candidate == 32 and
        not M.scalar("SELECT 1 FROM session_tokens WHERE token = ?", candidate) then
      token = candidate
      break
    end
  end
  if not token then
    error("unable to generate a unique session token")
  end
  M.exec(
    "INSERT OR REPLACE INTO session_tokens (token, mac, created_at, last_seen) VALUES (?, ?, ?, ?)",
    token, mac, now, now
  )
  return token
end

--- Bind a fingerprint identifier to a token.
--- kind: "mac" | "browser_fp" | "device_id"
function M.token_bind(token, kind, value)
  if not token or not kind or not value or value == "" then return end
  M.exec(
    "INSERT OR REPLACE INTO token_bindings (token, kind, value) VALUES (?, ?, ?)",
    token, kind, value
  )
end

--- Bind a collision-sensitive device identity without taking it from an active session.
--- Rebinding the same device's newer token is allowed; an expired owner may also
--- release the value.
function M.token_bind_unique(token, kind, value)
  if not token or not kind or not value or value == "" then
    return false, "invalid_binding"
  end

  if not _initialized then M.init() end
  local database = open_db()
  local transaction_open = false
  local changed = false
  local ok, result = pcall(function()
    if database:exec("BEGIN IMMEDIATE") ~= sqlite3.OK then
      error("binding_lock_failed:" .. tostring(database:errmsg()), 0)
    end
    transaction_open = true

    local target, target_err = prepared_row(
      database, "SELECT mac FROM session_tokens WHERE token = ?", token
    )
    if target_err then error(target_err, 0) end
    if not target then error("token_missing", 0) end

    local owner, owner_err = prepared_row(database, [[
      SELECT tb.token, st.mac, s.expires_at, s.paused
      FROM token_bindings tb
      JOIN session_tokens st ON st.token = tb.token
      LEFT JOIN sessions s ON s.mac = st.mac
      WHERE tb.kind = ? AND tb.value = ?
    ]], kind, value)
    if owner_err then error(owner_err, 0) end

    if owner and owner.token == token then
      if database:exec("COMMIT") ~= sqlite3.OK then error(database:errmsg(), 0) end
      transaction_open = false
      return false
    end
    if owner and owner.mac ~= target.mac and session_is_active(owner, os.time()) then
      error("binding_in_use", 0)
    end

    local deleted, delete_err = prepared_exec(
      database, "DELETE FROM token_bindings WHERE kind = ? AND value = ?", kind, value
    )
    if not deleted then error(delete_err or "binding_delete_failed", 0) end
    local inserted, insert_err = prepared_exec(
      database, "INSERT INTO token_bindings (token, kind, value) VALUES (?, ?, ?)",
      token, kind, value
    )
    if not inserted then error(insert_err or "binding_write_failed", 0) end

    if database:exec("COMMIT") ~= sqlite3.OK then error(database:errmsg(), 0) end
    transaction_open = false
    changed = true
    return true
  end)

  if not ok and transaction_open then database:exec("ROLLBACK") end
  database:close()
  if not ok then return false, tostring(result) end
  if changed then mark_dirty() end
  return true, nil, result == true
end

--- Find the token associated with a MAC
function M.token_for_mac(mac)
  if not mac or mac == "" then return nil end
  local row = M.row(
    "SELECT token FROM session_tokens WHERE mac = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
    mac
  )
  return row and row.token or nil
end

--- Atomically move a paid session and its authoritative device identity to a new MAC.
--- The destination may contain an expired placeholder session, but an active or
--- paused paid session is never overwritten. A fresh token is returned so the
--- old MAC loses ownership immediately after the transfer.
function M.rebind_session(old_mac, new_mac, browser_fp, device_id, roam_fp)
  if not _initialized then M.init() end
  if not old_mac or not new_mac or old_mac == "" or new_mac == "" then
    return false, nil, "invalid_mac"
  end

  local database = open_db()
  local transaction_open = false

  local function fail(code)
    error(code, 0)
  end

  local function execute(sql, ...)
    local stmt = database:prepare(sql)
    if not stmt then fail("prepare_failed:" .. tostring(database:errmsg())) end
    bind_params(stmt, ...)
    local rc = stmt:step()
    stmt:finalize()
    if rc ~= sqlite3.DONE then fail("write_failed:" .. tostring(database:errmsg())) end
  end

  local function first(sql, ...)
    local stmt = database:prepare(sql)
    if not stmt then fail("prepare_failed:" .. tostring(database:errmsg())) end
    bind_params(stmt, ...)
    local row
    if stmt:step() == sqlite3.ROW then
      row = {}
      local names = stmt:get_names()
      local values = stmt:get_values()
      for i, name in ipairs(names) do row[name] = values[i] end
    end
    stmt:finalize()
    return row
  end

  local function rows(sql, ...)
    local stmt = database:prepare(sql)
    if not stmt then fail("prepare_failed:" .. tostring(database:errmsg())) end
    bind_params(stmt, ...)
    local result = {}
    while stmt:step() == sqlite3.ROW do
      local row = {}
      local names = stmt:get_names()
      local values = stmt:get_values()
      for i, name in ipairs(names) do row[name] = values[i] end
      result[#result + 1] = row
    end
    stmt:finalize()
    return result
  end

  local ok, result = pcall(function()
    if database:exec("BEGIN IMMEDIATE") ~= sqlite3.OK then
      fail("begin_failed:" .. tostring(database:errmsg()))
    end
    transaction_open = true

    local now = os.time()
    local source = first("SELECT * FROM sessions WHERE mac = ?", old_mac)
    if not source then fail("source_session_missing") end
    local source_active = source.paused == 1 or
      ((tonumber(source.expires_at) or 0) > now and source.paused == 0)
    if not source_active then fail("source_session_expired") end

    local target = first("SELECT expires_at, paused FROM sessions WHERE mac = ?", new_mac)
    if target and (target.paused == 1 or
        ((tonumber(target.expires_at) or 0) > now and target.paused == 0)) then
      fail("target_has_active_session")
    end

    local target_device = first("SELECT blocked FROM known_devices WHERE mac = ?", new_mac)
    if target_device and target_device.blocked == 1 then fail("target_blocked") end

    local alias_group, alias_err = link_device_aliases_in_transaction(
      database, old_mac, new_mac, now
    )
    if not alias_group then fail(alias_err or "alias_link_failed") end

    local preserved = {device_id = {}}
    local token_rows = rows(
      "SELECT token FROM session_tokens WHERE mac = ? OR mac = ?",
      old_mac, new_mac
    )
    for _, token_row in ipairs(token_rows) do
      local binding_rows = rows(
        "SELECT kind, value FROM token_bindings WHERE token = ? AND kind = 'device_id'",
        token_row.token
      )
      for _, binding in ipairs(binding_rows) do
        preserved[binding.kind][binding.value] = true
      end
      execute("DELETE FROM token_bindings WHERE token = ?", token_row.token)
    end
    execute("DELETE FROM session_tokens WHERE mac = ? OR mac = ?", old_mac, new_mac)

    execute([[
      INSERT OR REPLACE INTO sessions
        (mac, minutes_remaining, started_at, expires_at, last_seen, paused, auto_paused, pause_limit, pauses_used, valid_until)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], new_mac, source.minutes_remaining, source.started_at, source.expires_at, now,
      source.paused, source.auto_paused or 0, source.pause_limit or 0,
      source.pauses_used or 0, source.valid_until or 0)
    execute("DELETE FROM sessions WHERE mac = ?", old_mac)

    execute([[
      INSERT OR IGNORE INTO known_devices (mac, name, first_seen, last_seen, blocked)
      SELECT ?, name, first_seen, ?, blocked FROM known_devices WHERE mac = ?
    ]], new_mac, now, old_mac)
    execute("UPDATE known_devices SET last_seen = ? WHERE mac = ?", now, new_mac)
    execute("DELETE FROM known_devices WHERE mac = ?", old_mac)

    local new_token
    for _ = 1, 8 do
      local candidate = util.random_token(32)
      if candidate and #candidate == 32 and
          not first("SELECT token FROM session_tokens WHERE token = ?", candidate) then
        new_token = candidate
        break
      end
    end
    if not new_token then fail("token_generation_failed") end

    execute(
      "INSERT INTO session_tokens (token, mac, created_at, last_seen) VALUES (?, ?, ?, ?)",
      new_token, new_mac, now, now
    )
    execute(
      "INSERT OR REPLACE INTO token_bindings (token, kind, value) VALUES (?, 'mac', ?)",
      new_token, new_mac
    )

    if device_id and device_id ~= "" then preserved.device_id[device_id] = true end
    for value in pairs(preserved.device_id) do
      local owner = first([[
        SELECT st.mac, s.expires_at, s.paused
        FROM token_bindings tb
        JOIN session_tokens st ON st.token = tb.token
        LEFT JOIN sessions s ON s.mac = st.mac
        WHERE tb.kind = 'device_id' AND tb.value = ? AND st.mac <> ?
      ]], value, new_mac)
      if owner and session_is_active(owner, now) then fail("device_id_conflict") end
      execute("DELETE FROM token_bindings WHERE kind = 'device_id' AND value = ?", value)
      execute(
        "INSERT INTO token_bindings (token, kind, value) VALUES (?, 'device_id', ?)",
        new_token, value
      )
    end

    if database:exec("COMMIT") ~= sqlite3.OK then
      fail("commit_failed:" .. tostring(database:errmsg()))
    end
    transaction_open = false
    return new_token
  end)

  if not ok and transaction_open then database:exec("ROLLBACK") end
  database:close()
  if not ok then return false, nil, tostring(result) end

  mark_dirty()
  return true, result
end

local function touch_session_token(token, last_seen, now)
  if not token then return end
  local cutoff = now - TOKEN_TOUCH_INTERVAL_SECONDS
  if (tonumber(last_seen) or 0) >= cutoff then return end
  M.exec_runtime(
    "UPDATE session_tokens SET last_seen = ? WHERE token = ? AND last_seen < ?",
    now, token, cutoff
  )
end

--- Resolve identity from ownership-bearing values only. Passive fingerprints
--- are ignored because identical devices can produce the same value. Priority:
--- cookie > device_id > current_mac.
--- Returns: resolved_mac (may be nil), token (may be nil), match_type
function M.resolve_identity(cookie_token, _browser_fp, device_id, current_mac)
  local now = os.time()

  -- A device that already owns an active or paused session must keep that
  -- identity. This prevents an older browser binding from another randomized
  -- MAC from overriding the session that belongs to the request's live MAC.
  if current_mac and current_mac ~= "" then
    local current_session = M.row(
      "SELECT expires_at, paused FROM sessions WHERE mac = ?",
      current_mac
    )
    local current_active = current_session and (
      current_session.paused == 1 or
      ((tonumber(current_session.expires_at) or 0) > now)
    )
    if current_active then
      local current_token = M.row(
        "SELECT token, last_seen FROM session_tokens WHERE mac = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
        current_mac
      )
      if current_token then touch_session_token(current_token.token, current_token.last_seen, now) end
      return current_mac, current_token and current_token.token or nil, "mac"
    end
  end

  -- 1. Cookie token lookup (highest priority)
  -- Returns match_type="cookie" — rebind is NOT allowed for cookie matches
  if cookie_token and cookie_token ~= "" then
    local row = M.row("SELECT mac, last_seen FROM session_tokens WHERE token = ?", cookie_token)
    if row then
      touch_session_token(cookie_token, row.last_seen, now)
      return row.mac, cookie_token, "cookie"
    end
  end

  -- 2. Device ID lookup. Only an active or paused paid session may be rebound.
  if device_id and device_id ~= "" then
    local did_row = M.row(
      "SELECT tb.token, st.mac, st.last_seen FROM token_bindings tb JOIN session_tokens st ON tb.token = st.token WHERE tb.kind = 'device_id' AND tb.value = ? LIMIT 1",
      device_id
    )
    if did_row then
      local sess = M.row("SELECT expires_at, paused FROM sessions WHERE mac = ?", did_row.mac)
      if sess and session_is_active(sess, now) then
        touch_session_token(did_row.token, did_row.last_seen, now)
        return did_row.mac, did_row.token, "device_id"
      end
    end
  end

  -- 4. Current MAC lookup (lowest priority — may be randomized)
  if current_mac and current_mac ~= "" then
    local row = M.row(
      "SELECT token, last_seen FROM session_tokens WHERE mac = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
      current_mac
    )
    if row then
      touch_session_token(row.token, row.last_seen, now)
      return current_mac, row.token, "mac"
    end
    -- No token yet for this MAC — return MAC only, token will be minted on credit
    return current_mac, nil, "mac"
  end

  return nil, nil, nil
end

--- Remove expired idempotency records without touching paid history or credit.
function M.cleanup_storage(force)
  if not _initialized then M.init() end
  local now = os.time()
  local last = tonumber(M.setting("_storage_cleanup_last_at") or "0") or 0
  if not force and last > 0 and now - last < STORAGE_CLEANUP_INTERVAL_SECONDS then
    return true, "skipped"
  end

  local event_cutoff = now - COIN_EVENT_RETENTION_SECONDS
  if (tonumber(M.scalar([[
    SELECT COUNT(*) FROM coin_events
    WHERE created_at > 0 AND created_at < ?
  ]], event_cutoff) or 0) or 0) > 0 then
    M.exec("DELETE FROM coin_events WHERE created_at > 0 AND created_at < ?", event_cutoff)
  end

  M.set_runtime_setting("_storage_cleanup_last_at", tostring(now))
  return true, "clean"
end

--- Clean up orphaned tokens older than 30 days without touching paid sessions.
function M.cleanup_tokens()
  local cutoff = os.time() - (30 * 86400)
  local stale_count = tonumber(M.scalar([[
    SELECT COUNT(*) FROM session_tokens st
    LEFT JOIN sessions s ON st.mac = s.mac
    WHERE st.last_seen < ? AND s.mac IS NULL
  ]], cutoff)) or 0
  local bindings_ok, bindings_err = M.exec([[
    DELETE FROM token_bindings WHERE token IN (
      SELECT st.token FROM session_tokens st
      LEFT JOIN sessions s ON st.mac = s.mac
      WHERE st.last_seen < ? AND s.mac IS NULL
    )
  ]], cutoff)
  if not bindings_ok then return false, 0, bindings_err end
  local tokens_ok, tokens_err = M.exec([[
    DELETE FROM session_tokens WHERE last_seen < ? AND mac NOT IN (SELECT mac FROM sessions)
  ]], cutoff)
  if not tokens_ok then return false, 0, tokens_err end
  return true, stale_count
end

return M
