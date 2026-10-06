--- TarakiFi Database Layer (SQLite3 — RAM with flash sync)
-- DB lives at /tmp/tarakifi.db (fast RAM). Synced to /etc/tarakifi/sessions.db
-- every 60s by timer and immediately on credit events.
-- IMPORTANT: DB is opened and closed per-request to avoid locking between
-- multiple uhttpd processes (portal, admin, captive).
local sqlite3 = require("lsqlite3")
local util = require("lib.util")
local coin_validity = require("lib.coin_validity")
local has_nixio, nixio = pcall(require, "nixio")
local M = {}

local DB_PATH = os.getenv("TARAKIFI_DB_PATH") or "/tmp/tarakifi.db"
local FLASH_PATH = os.getenv("TARAKIFI_FLASH_DB_PATH") or "/etc/tarakifi/sessions.db"
local BACKUP_PATH = os.getenv("TARAKIFI_BACKUP_DB_PATH") or "/etc/tarakifi/sessions.db.bak"
local SNAPSHOT_PATH = os.getenv("TARAKIFI_SNAPSHOT_DB_PATH") or "/etc/tarakifi/sessions.db.tmp"
local DIRTY_PATH = os.getenv("TARAKIFI_DB_DIRTY_PATH") or "/tmp/tarakifi/db_dirty"
local LOCK_PATH = os.getenv("TARAKIFI_DB_LOCK_PATH") or "/tmp/tarakifi/db_persist.lock"
local STATUS_PATH = os.getenv("TARAKIFI_DB_STATUS_PATH") or "/tmp/tarakifi/db_persist_status"
local SCHEMA_READY_PATH = os.getenv("TARAKIFI_SCHEMA_READY_PATH") or (DB_PATH .. ".schema-ready")
local SCHEMA_VERSION = "coin-node-singleton-validity-v1"
local IDENTITY_BINDING_VERSION = "authoritative-device-v1"
local FLASH_DIR = FLASH_PATH:match("^(.*)/[^/]+$") or "/etc/tarakifi"
local _initialized = false
local TOKEN_TOUCH_INTERVAL_SECONDS = tonumber(os.getenv("TARAKIFI_TOKEN_TOUCH_INTERVAL")) or 60
local STORAGE_CLEANUP_INTERVAL_SECONDS = tonumber(os.getenv("TARAKIFI_STORAGE_CLEANUP_INTERVAL")) or 3600
local STORAGE_VACUUM_INTERVAL_SECONDS = tonumber(os.getenv("TARAKIFI_STORAGE_VACUUM_INTERVAL")) or 86400
local TRANSACTION_RETENTION_SECONDS = tonumber(os.getenv("TARAKIFI_TRANSACTION_RETENTION_SECONDS")) or (30 * 86400)
local SESSION_RETENTION_SECONDS = tonumber(os.getenv("TARAKIFI_SESSION_RETENTION_SECONDS")) or 86400
local TOKEN_RETENTION_SECONDS = tonumber(os.getenv("TARAKIFI_TOKEN_RETENTION_SECONDS")) or (30 * 86400)
local DEVICE_RETENTION_SECONDS = tonumber(os.getenv("TARAKIFI_DEVICE_RETENTION_SECONDS")) or (60 * 86400)
local COIN_EVENT_RETENTION_SECONDS = tonumber(os.getenv("TARAKIFI_COIN_EVENT_RETENTION_SECONDS")) or (7 * 86400)
local PENDING_COIN_RETENTION_SECONDS = tonumber(os.getenv("TARAKIFI_PENDING_COIN_RETENTION_SECONDS")) or 86400

local function normalize_mac(value)
  local mac = tostring(value or ""):upper()
  if mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then return mac end
  return nil
end

local function session_is_active(row, now)
  if not row then return false end
  now = now or os.time()
  local validity_expires_at = tonumber(row.validity_expires_at) or 0
  if validity_expires_at > 0 and validity_expires_at <= now then return false end
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
  os.execute("mkdir -p /tmp/tarakifi")
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
    _initialized = true
    return
  end
  os.execute("mkdir -p /tmp/tarakifi /etc/tarakifi")
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
      validity_expires_at INTEGER DEFAULT 0,
      last_seen INTEGER DEFAULT 0,
      paused INTEGER DEFAULT 0
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
      blocked INTEGER DEFAULT 0
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
      rssi INTEGER,
      conn_mode TEXT DEFAULT 'wifi',
      bind_code TEXT DEFAULT '',
      auth_token TEXT DEFAULT '',
      protocol_version INTEGER DEFAULT 1,
      auth_enrolled_at INTEGER DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS coin_events (
      event_id TEXT PRIMARY KEY,
      node_id TEXT NOT NULL,
      target_mac TEXT NOT NULL,
      pulses INTEGER DEFAULT 0,
      amount_php REAL DEFAULT 0,
      minutes_granted REAL DEFAULT 0,
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

  local coin_nodes_pruned = false
  local coin_node_prune_rc = db:exec([[
    DELETE FROM coin_nodes
    WHERE rowid NOT IN (
      SELECT rowid FROM coin_nodes
      ORDER BY COALESCE(last_heartbeat, 0) DESC, node_id ASC
      LIMIT 1
    )
  ]])
  if coin_node_prune_rc ~= sqlite3.OK then
    local prune_err = db:errmsg()
    db:close()
    error("coin node singleton cleanup failed: " .. tostring(prune_err), 0)
  end
  coin_nodes_pruned = db:changes() > 0

  local coin_node_trigger_rc = db:exec([[
    CREATE TRIGGER IF NOT EXISTS coin_nodes_singleton_insert
    BEFORE INSERT ON coin_nodes
    WHEN EXISTS (
      SELECT 1 FROM coin_nodes WHERE node_id IS NOT NEW.node_id LIMIT 1
    )
    BEGIN
      SELECT RAISE(ABORT, 'coinslot_limit_reached');
    END;
  ]])
  if coin_node_trigger_rc ~= sqlite3.OK then
    local trigger_err = db:errmsg()
    db:close()
    error("coin node singleton migration failed: " .. tostring(trigger_err), 0)
  end

  -- Hardware/browser fingerprints are shared by identical phone models and
  -- cannot prove ownership. Remove their legacy bindings and alias groups once,
  -- while preserving sessions, paid credit, transactions, and device IDs.
  local identity_cleanup_applied = false
  if database_setting(db, "_identity_binding_version") ~= IDENTITY_BINDING_VERSION then
    if db:exec("BEGIN IMMEDIATE") ~= sqlite3.OK then
      local migration_err = db:errmsg()
      db:close()
      error("identity migration lock failed: " .. tostring(migration_err), 0)
    end

    if database_setting(db, "_identity_binding_version") ~= IDENTITY_BINDING_VERSION then
      if db:exec(
          "DELETE FROM token_bindings WHERE kind IN ('browser_fp', 'roam_fp_v2')"
        ) ~= sqlite3.OK or db:exec("DELETE FROM device_aliases") ~= sqlite3.OK or
          db:exec(
            "UPDATE pending_coin_credits SET browser_fp = '', roam_fp = ''"
          ) ~= sqlite3.OK then
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
    {name = "transaction_id", definition = "INTEGER DEFAULT 0"}
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

  local session_validity_added, session_migration_err = ensure_table_column(
    db, "sessions", "validity_expires_at", "INTEGER DEFAULT 0"
  )
  if session_validity_added == nil then
    db:close()
    error("session validity migration failed: " .. tostring(session_migration_err), 0)
  end

  local total_added, total_err = ensure_table_column(
    db, "sessions", "validity_minutes_total", "REAL DEFAULT NULL"
  )
  if total_added == nil then
    db:close()
    error("session purchase total migration failed: " .. tostring(total_err), 0)
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

  if session_validity_added then
    if db:exec([[
      UPDATE sessions
      SET validity_expires_at = COALESCE((
        SELECT MAX(v.valid_until)
        FROM vouchers v
        WHERE v.redeemed_by_mac = sessions.mac
          AND v.status IN ('redeemed', 'used')
          AND v.valid_until > 0
      ), 0)
    ]]) ~= sqlite3.OK then
      local migration_err = db:errmsg()
      db:close()
      error("session validity backfill failed: " .. tostring(migration_err), 0)
    end
  end

  local schema_after = schema_before
  schema_stmt = db:prepare("PRAGMA schema_version")
  if schema_stmt and schema_stmt:step() == sqlite3.ROW then
    schema_after = tonumber(schema_stmt:get_value(0)) or schema_before
  end
  if schema_stmt then schema_stmt:finalize() end
  db:close()

  -- Now open again briefly to set defaults
  local db2 = open_db()
  -- Load defaults (only sets keys that don't already exist)
  local defaults = {
    business_name = "TarakiFi",
    portal_show_business_name = "0",
    portal_name = "TarakiFi WiFi",
    portal_footer_text = "",
    portal_rates = "1:12\n5:60\n10:120",
    portal_show_rates = "1",
    portal_show_voucher = "1",
    portal_show_coin = "1",
    portal_hide_device_info = "0",
    portal_hide_pause_button = "0",
    portal_logo_file = "",
    portal_hero_file = "",
    portal_coin_sound_file = "",
    portal_tick_sound_file = "",
    portal_asset_version = "0",
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
    anti_tethering_enabled = "0",
    bw_mode = "off",
    bw_per_client_down_kbps = "0",
    bw_per_client_up_kbps = "0",
    bw_total_down_kbps = "0",
    bw_total_up_kbps = "0",
    bw_exempt_macs = "",
    pause_penalty_minutes = "0",
    auto_pause_on_disconnect = "0",
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
    cloud_backup_enabled = "0",
    cloud_backup_url = "https://pisowifi.taraki.vip",
    license_key = "",
    license_status = "trial"
  }
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

  if schema_after ~= schema_before or defaults_added or identity_cleanup_applied or
      coin_nodes_pruned then
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
  M.cleanup_storage(false)
  if not force and not file_exists(DIRTY_PATH) and file_exists(FLASH_PATH) then
    return true, "clean"
  end

  os.execute("mkdir -p /tmp/tarakifi /etc/tarakifi")
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
    os.remove(BACKUP_PATH)
    os.remove(BACKUP_PATH .. ".tmp")

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
  M.cleanup_storage(false)
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
    local validity_seconds = tonumber(voucher.validity_seconds) or 0
    local validity_deadline = validity_seconds > 0 and (now + validity_seconds) or 0
    local existing
    existing, row_err = prepared_row(
      database, "SELECT * FROM sessions WHERE mac = ?", mac
    )
    if row_err then error(row_err, 0) end

    local existing_within_validity = existing and (
      (tonumber(existing.validity_expires_at) or 0) == 0 or
      (tonumber(existing.validity_expires_at) or 0) > now
    )
    if existing and existing_within_validity and
        (tonumber(existing.expires_at) or 0) > now and
        tonumber(existing.paused) == 0 then
      wrote, write_err = prepared_exec(database, [[
        UPDATE sessions
        SET minutes_remaining = ?, expires_at = ?,
            validity_expires_at = CASE
              WHEN ? > validity_expires_at THEN ?
              ELSE validity_expires_at
            END
        WHERE mac = ?
      ]], (tonumber(existing.minutes_remaining) or 0) + minutes,
        (tonumber(existing.expires_at) or now) + (minutes * 60),
        validity_deadline, validity_deadline, mac)
    elseif existing and existing_within_validity and tonumber(existing.paused) == 1 then
      wrote, write_err = prepared_exec(database, [[
        UPDATE sessions
        SET minutes_remaining = ?,
            validity_expires_at = CASE
              WHEN ? > validity_expires_at THEN ?
              ELSE validity_expires_at
            END
        WHERE mac = ?
      ]], (tonumber(existing.minutes_remaining) or 0) + minutes,
        validity_deadline, validity_deadline, mac)
    else
      wrote, write_err = prepared_exec(database, [[
        INSERT OR REPLACE INTO sessions
          (mac, minutes_remaining, started_at, expires_at,
           validity_expires_at, last_seen, paused)
        VALUES (?, ?, ?, ?, ?, ?, 0)
      ]], mac, minutes, now, now + (minutes * 60), validity_deadline, now)
    end
    if not wrote then error(write_err or "session_credit_failed", 0) end

    -- Voucher deadlines keep their own rules; a later coin top-up uses the
    -- combined purchased-time total, matching the hEX implementation.
    wrote, write_err = prepared_exec(database,
      "UPDATE sessions SET validity_minutes_total = ? WHERE mac = ?",
      coin_validity.total(existing_within_validity and existing or nil, minutes, now), mac)
    if not wrote then error(write_err or "session_total_failed", 0) end

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
      AND (COALESCE(s.validity_expires_at, 0) = 0 OR s.validity_expires_at > ?)
  ]], group_id, mac_a, mac_b, now, now)
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
    "SELECT expires_at, validity_expires_at, paused FROM sessions WHERE mac = ?", mac
  )
  if session_is_active(current, now) then
    return nil, "target_has_active_session"
  end

  local owners = M.query([[
    SELECT s.mac, s.expires_at, s.validity_expires_at, s.paused
    FROM device_aliases da
    JOIN sessions s ON s.mac = da.mac
    WHERE da.group_id = ? AND da.mac <> ?
      AND (s.paused = 1 OR (s.paused = 0 AND s.expires_at > ?))
      AND (COALESCE(s.validity_expires_at, 0) = 0 OR s.validity_expires_at > ?)
    ORDER BY s.last_seen DESC, s.mac ASC
  ]], group.group_id, mac, now, now)
  if #owners == 0 then return nil, "alias_inactive" end
  if #owners > 1 then return nil, "alias_group_conflict" end
  return owners[1]
end

--- Add one physical coin to durable pending credit without starting internet.
function M.pending_coin_add(mac, minutes, amount_php, browser_fp, device_id, roam_fp)
  if not _initialized then M.init() end
  local database = open_db()
  local transaction_open = false
  local pending
  local ok, err = pcall(function()
    if database:exec("BEGIN IMMEDIATE") ~= sqlite3.OK then error(database:errmsg()) end
    transaction_open = true
    local existing = prepared_row(
      database, "SELECT transaction_id FROM pending_coin_credits WHERE mac = ?", mac
    )
    local transaction_id = existing and tonumber(existing.transaction_id) or 0

    local wrote, write_err
    if transaction_id > 0 then
      wrote, write_err = prepared_exec(database, [[
        UPDATE transactions
        SET amount_php = amount_php + ?, minutes_granted = minutes_granted + ?,
            coin_count = coin_count + 1
        WHERE id = ? AND mac = ? AND source = 'coin'
      ]], amount_php, minutes, transaction_id, mac)
      if not wrote or database:changes() ~= 1 then
        error(write_err or "pending transaction missing")
      end
    else
      wrote, write_err = prepared_exec(database, [[
        INSERT INTO transactions
          (mac, amount_php, minutes_granted, source, created_at, coin_count)
        VALUES (?, ?, ?, 'coin', ?, 1)
      ]], mac, amount_php, minutes, os.time())
      if not wrote then error(write_err) end
      transaction_id = database:last_insert_rowid()
    end

    wrote, write_err = prepared_exec(database, [[
      INSERT INTO pending_coin_credits
        (mac, minutes, amount_php, coin_count, browser_fp, device_id, roam_fp,
         created_at, updated_at, transaction_id)
      VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(mac) DO UPDATE SET
        minutes = pending_coin_credits.minutes + excluded.minutes,
        amount_php = pending_coin_credits.amount_php + excluded.amount_php,
        coin_count = pending_coin_credits.coin_count + 1,
        browser_fp = '',
        device_id = CASE WHEN excluded.device_id <> '' THEN excluded.device_id ELSE pending_coin_credits.device_id END,
        roam_fp = '',
        updated_at = excluded.updated_at,
        transaction_id = excluded.transaction_id
    ]], mac, minutes, amount_php, "", device_id or "", "",
      os.time(), os.time(), transaction_id)
    if not wrote then error(write_err) end

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
  local now = math.floor(tonumber(options.created_at) or os.time())

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
      database,
      "SELECT transaction_id, amount_php, minutes FROM pending_coin_credits WHERE mac = ?",
      mac
    )
    if pending_err then error(pending_err, 0) end
    local transaction_id = existing_pending and tonumber(existing_pending.transaction_id) or 0
    if type(options.calculate_cumulative_minutes) == "function" then
      local cumulative_amount = amount_php +
        (tonumber(existing_pending and existing_pending.amount_php) or 0)
      local already_credited = tonumber(existing_pending and existing_pending.minutes) or 0
      local cumulative_minutes = tonumber(
        options.calculate_cumulative_minutes(cumulative_amount)
      )
      if not cumulative_minutes or cumulative_minutes < 0 then
        error("invalid_cumulative_coin_rate", 0)
      end
      minutes = math.max(0, cumulative_minutes - already_credited)
    end

    local wrote, write_err = prepared_exec(database, [[
      INSERT INTO coin_events
        (event_id, node_id, target_mac, pulses, amount_php, minutes_granted, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    ]], event_id, node_id, mac, pulses, amount_php, minutes, now)
    if not wrote then error(write_err, 0) end

    if transaction_id > 0 then
      wrote, write_err = prepared_exec(database, [[
        UPDATE transactions
        SET amount_php = amount_php + ?, minutes_granted = minutes_granted + ?,
            coin_count = coin_count + 1
        WHERE id = ? AND mac = ? AND source = 'coin'
      ]], amount_php, minutes, transaction_id, mac)
      if not wrote or database:changes() ~= 1 then
        error(write_err or "pending transaction missing", 0)
      end
    else
      wrote, write_err = prepared_exec(database, [[
        INSERT INTO transactions
          (mac, amount_php, minutes_granted, source, created_at, coin_count)
        VALUES (?, ?, ?, 'coin', ?, 1)
      ]], mac, amount_php, minutes, now)
      if not wrote then error(write_err, 0) end
      transaction_id = database:last_insert_rowid()
    end

    wrote, write_err = prepared_exec(database, [[
      INSERT INTO pending_coin_credits
        (mac, minutes, amount_php, coin_count, browser_fp, device_id, roam_fp,
         created_at, updated_at, transaction_id)
      VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(mac) DO UPDATE SET
        minutes = pending_coin_credits.minutes + excluded.minutes,
        amount_php = pending_coin_credits.amount_php + excluded.amount_php,
        coin_count = pending_coin_credits.coin_count + 1,
        browser_fp = '',
        device_id = CASE WHEN excluded.device_id <> '' THEN excluded.device_id ELSE pending_coin_credits.device_id END,
        roam_fp = '',
        updated_at = excluded.updated_at,
        transaction_id = excluded.transaction_id
    ]], mac, minutes, amount_php, "", options.device_id or "", "",
      now, now, transaction_id)
    if not wrote then error(write_err, 0) end

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
        minutes_granted = minutes,
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

function M.pending_coin_get(mac)
  return M.row("SELECT * FROM pending_coin_credits WHERE mac = ?", mac)
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
    local existing = prepared_row(database, "SELECT * FROM sessions WHERE mac = ?", mac)
    local total = coin_validity.total(existing, minutes, now)
    local deadline = coin_validity.deadline(
      database_setting(database, "session_validity_rules"), existing, total, now
    )
    local wrote, write_err
    if existing and tonumber(existing.paused) == 0 and
        (tonumber(existing.expires_at) or 0) > now then
      mode = "extended"
      wrote, write_err = prepared_exec(database, [[
        UPDATE sessions
        SET minutes_remaining = minutes_remaining + ?, expires_at = expires_at + ?,
            validity_expires_at = CASE
              WHEN validity_expires_at > 0 AND validity_expires_at <= ? THEN 0
              ELSE validity_expires_at
            END,
            last_seen = ?
        WHERE mac = ?
      ]], minutes, minutes * 60, now, now, mac)
    elseif existing and tonumber(existing.paused) == 1 then
      mode = "paused"
      wrote, write_err = prepared_exec(database, [[
        UPDATE sessions
        SET minutes_remaining = minutes_remaining + ?,
            validity_expires_at = CASE
              WHEN validity_expires_at > 0 AND validity_expires_at <= ? THEN 0
              ELSE validity_expires_at
            END,
            last_seen = ?
        WHERE mac = ?
      ]], minutes, now, now, mac)
    else
      mode = "started"
      wrote, write_err = prepared_exec(database, [[
        INSERT OR REPLACE INTO sessions
          (mac, minutes_remaining, started_at, expires_at, last_seen, paused)
        VALUES (?, ?, ?, ?, ?, 0)
      ]], mac, minutes, now, now + (minutes * 60), now)
    end
    if not wrote then error(write_err) end

    -- Consume pending credit, update the balance and set validity in one
    -- transaction so retries cannot credit twice or extend the deadline again.
    wrote, write_err = prepared_exec(database, [[
      UPDATE sessions SET validity_minutes_total = ?, validity_expires_at = ? WHERE mac = ?
    ]], total, deadline, mac)
    if not wrote then error(write_err) end

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
      wrote, write_err = prepared_exec(database, [[
        INSERT OR IGNORE INTO token_bindings (token, kind, value) VALUES (?, 'device_id', ?)
      ]], token, pending.device_id)
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

--- Bind a collision-sensitive identity without taking it from an active session.
--- Rebinding the same device's newer token is allowed; an expired owner may also
--- release the value. This is used for the cross-SSID roaming signature.
function M.token_bind_unique(token, kind, value)
  if not token or not kind or not value or value == "" then
    return false, "invalid_binding"
  end

  local target = M.row("SELECT mac FROM session_tokens WHERE token = ?", token)
  if not target then return false, "token_missing" end

  local owner = M.row([[
    SELECT tb.token, st.mac, s.expires_at, s.validity_expires_at, s.paused
    FROM token_bindings tb
    JOIN session_tokens st ON st.token = tb.token
    LEFT JOIN sessions s ON s.mac = st.mac
    WHERE tb.kind = ? AND tb.value = ?
  ]], kind, value)

  if owner and owner.token == token then return true, nil, false end
  if owner and owner.mac ~= target.mac then
    if session_is_active(owner) then return false, "binding_in_use" end
  end

  M.exec("DELETE FROM token_bindings WHERE kind = ? AND value = ?", kind, value)
  local ok = M.exec(
    "INSERT INTO token_bindings (token, kind, value) VALUES (?, ?, ?)",
    token, kind, value
  )
  if not ok then return false, "binding_write_failed" end
  return true, nil, true
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

--- Atomically move a paid session and its authoritative device identity.
--- The destination may contain an expired placeholder session, but an active or
--- paused paid session is never overwritten. A fresh token is returned so the
--- old MAC/browser loses ownership immediately after the transfer.
function M.rebind_session(old_mac, new_mac, _browser_fp, device_id, _roam_fp)
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
    local source_active = session_is_active(source, now)
    if not source_active then fail("source_session_expired") end

    local target = first(
      "SELECT expires_at, validity_expires_at, paused FROM sessions WHERE mac = ?",
      new_mac
    )
    if session_is_active(target, now) then
      fail("target_has_active_session")
    end

    local target_device = first("SELECT blocked FROM known_devices WHERE mac = ?", new_mac)
    if target_device and target_device.blocked == 1 then fail("target_blocked") end

    local alias_group, alias_err = link_device_aliases_in_transaction(
      database, old_mac, new_mac, now
    )
    if not alias_group then fail(alias_err or "alias_link_failed") end

    local preserved_device_ids = {}
    local token_rows = rows(
      "SELECT token FROM session_tokens WHERE mac = ? OR mac = ?",
      old_mac, new_mac
    )
    for _, token_row in ipairs(token_rows) do
      local binding_rows = rows(
        "SELECT value FROM token_bindings WHERE token = ? AND kind = 'device_id'",
        token_row.token
      )
      for _, binding in ipairs(binding_rows) do
        preserved_device_ids[binding.value] = true
      end
      execute("DELETE FROM token_bindings WHERE token = ?", token_row.token)
    end
    execute("DELETE FROM session_tokens WHERE mac = ? OR mac = ?", old_mac, new_mac)

    execute([[
      INSERT OR REPLACE INTO sessions
        (mac, minutes_remaining, started_at, expires_at,
         validity_expires_at, last_seen, paused, validity_minutes_total)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ]], new_mac, source.minutes_remaining, source.started_at, source.expires_at,
      source.validity_expires_at or 0, now, source.paused,
      source.validity_minutes_total or source.minutes_remaining)
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

    if device_id and device_id ~= "" then preserved_device_ids[device_id] = true end
    for value in pairs(preserved_device_ids) do
      execute(
        "INSERT OR IGNORE INTO token_bindings (token, kind, value) VALUES (?, 'device_id', ?)",
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

--- Resolve identity from ownership-bearing values only. Passive browser and
--- hardware fingerprints are intentionally ignored because identical devices
--- can produce the same value. Priority: cookie > device_id > current MAC.
--- Returns: resolved_mac (may be nil), token (may be nil), match_type
function M.resolve_identity(cookie_token, _browser_fp, device_id, current_mac)
  local now = os.time()

  -- A device that already owns an active or paused session must keep that
  -- identity. This prevents an older browser binding from another randomized
  -- MAC from overriding the session that belongs to the request's live MAC.
  if current_mac and current_mac ~= "" then
    local current_session = M.row(
      "SELECT expires_at, validity_expires_at, paused FROM sessions WHERE mac = ?",
      current_mac
    )
    local current_active = session_is_active(current_session, now)
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

  -- 2. Random per-device ID lookup. The binding is unique at the schema level
  -- and is accepted only while its owner has active or paused paid time.
  if device_id and device_id ~= "" then
    local did_row = M.row(
      "SELECT tb.token, st.mac, st.last_seen FROM token_bindings tb JOIN session_tokens st ON tb.token = st.token WHERE tb.kind = 'device_id' AND tb.value = ? LIMIT 1",
      device_id
    )
    if did_row then
      local sess = M.row(
        "SELECT expires_at, validity_expires_at, paused FROM sessions WHERE mac = ?",
        did_row.mac
      )
      if session_is_active(sess, now) then
        touch_session_token(did_row.token, did_row.last_seen, now)
        return did_row.mac, did_row.token, "device_id"
      end
    end
  end

  -- 3. Current MAC lookup (lowest priority — may be randomized)
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

--- Legacy storage hook kept for compatibility.
--- Session cleanup is intentionally handled by session.lua so this helper never
--- deletes paid history, pending credit, session rows, or known devices.
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
  local cutoff = os.time() - TOKEN_RETENTION_SECONDS
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
