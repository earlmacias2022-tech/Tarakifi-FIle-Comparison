--- Shared WiFi rate parsing and resolution.
-- The same canonical rate policy is used by the admin API, portal display,
-- and coinslot credit path. Rate minutes are always whole numbers.
local M = {}

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function validity_seconds(value, unit)
  value = math.max(0, math.floor(tonumber(value) or 0))
  if value == 0 then return 0 end
  unit = tostring(unit or "D"):upper()
  local multiplier = unit == "M" and 60 or (unit == "H" and 3600 or 86400)
  return value * multiplier
end

--- Normalize a flat override. Blank and zero disable the override.
-- Decimal values are deliberately invalid; accepting them causes the credit
-- path to grant fractional minutes while the UI displays rounded minutes.
function M.normalize_flat_rate(value)
  local text = trim(value)
  if text == "" then return "" end
  if not text:match("^%d+$") then return nil end
  local number = tonumber(text)
  if not number or number < 0 then return nil end
  if number == 0 then return "" end
  return tostring(math.floor(number))
end

function M.flat_rate(value)
  local normalized = M.normalize_flat_rate(value)
  if not normalized or normalized == "" then return 0 end
  return tonumber(normalized) or 0
end

--- Parse one legacy (php:minutes / php:minutes:pause) or canonical row.
function M.parse_line(value)
  local line = trim(value)
  if line == "" then return nil end

  local php, minutes, pause_limit, validity_value, validity_unit = line:match(
    "^(%d+)%s*:%s*(%d+)%s*:%s*(%d+)%s*:%s*(%d+)%s*:%s*([DdHhMm])$"
  )
  if not php then
    php, minutes, pause_limit = line:match(
      "^(%d+)%s*:%s*(%d+)%s*:%s*(%d+)$"
    )
  end
  if not php then
    php, minutes = line:match("^(%d+)%s*:%s*(%d+)$")
  end
  if not php then return nil end

  php = tonumber(php)
  minutes = tonumber(minutes)
  pause_limit = math.max(0, math.floor(tonumber(pause_limit) or 0))
  validity_value = math.max(0, math.floor(tonumber(validity_value) or 0))
  validity_unit = tostring(validity_unit or "D"):upper()
  if not php or not minutes or php <= 0 or minutes <= 0 then return nil end
  return {
    php = math.floor(php),
    minutes = math.floor(minutes),
    pause_limit = pause_limit,
    validity_value = validity_value,
    validity_unit = validity_unit,
    validity_seconds = validity_seconds(validity_value, validity_unit)
  }
end

--- Parse all non-empty rows. Empty input is a valid empty policy.
function M.parse(value)
  local rows = {}
  for raw_line in (tostring(value or "") .. "\n"):gmatch("([^\n]*)\n") do
    if trim(raw_line) ~= "" then
      local row = M.parse_line(raw_line)
      if not row then return nil, "invalid_rate" end
      rows[#rows + 1] = row
    end
  end
  return rows
end

--- Normalize rows to the canonical five-field format.
-- Duplicate PHP amounts are rejected because they make exact-tier selection
-- dependent on row order and can make the displayed and applied policy differ.
function M.normalize(value)
  local rows, err = M.parse(value)
  if not rows then return nil, err end
  local seen = {}
  local lines = {}
  for _, row in ipairs(rows) do
    if seen[row.php] then return nil, "duplicate_rate" end
    seen[row.php] = true
    lines[#lines + 1] = string.format(
      "%d:%d:%d:%d:%s", row.php, row.minutes, row.pause_limit,
      row.validity_value, row.validity_unit
    )
  end
  return table.concat(lines, "\n")
end

--- Resolve an amount to minutes, pause limit, and validity seconds.
-- A valid flat override is the explicitly selected policy. Otherwise an
-- exact tier wins first. For an amount without an exact tier, compose the
-- amount from the configured denominations, largest first. This keeps a
-- PHP26 purchase at PHP25 + PHP1 (1 day + 12 minutes), instead of scaling
-- the PHP25 tier's 1,440 minutes-per-25 ratio to 1,497 minutes.
-- If the configured denominations cannot represent a remainder, preserve
-- the legacy best-minutes-per-peso fallback for that remainder.
function M.resolve(amount_php, rates_value, flat_value)
  local amount = math.max(0, math.floor(tonumber(amount_php) or 0))
  local flat = M.flat_rate(flat_value)
  if flat > 0 then return amount * flat, 0, 0 end
  if amount <= 0 then return 0, 0, 0 end

  local rows = M.parse(rates_value) or {}

  for _, row in ipairs(rows) do
    if row.php == amount then
      return row.minutes, row.pause_limit, row.validity_seconds
    end
  end
  table.sort(rows, function(left, right)
    return left.php > right.php
  end)

  local remaining = amount
  local total_minutes = 0
  local selected_row = nil
  for _, row in ipairs(rows) do
    if remaining >= row.php then
      local count = math.floor(remaining / row.php)
      total_minutes = total_minutes + count * row.minutes
      remaining = remaining - count * row.php
      selected_row = selected_row or row
    end
  end

  if remaining > 0 then
    local best_rate = 0
    local fallback_row = nil
    for _, row in ipairs(rows) do
      if remaining >= row.php then
        local rate = row.minutes / row.php
        if rate > best_rate then
          best_rate = rate
          fallback_row = row
        end
      end
    end
    if best_rate > 0 then
      total_minutes = total_minutes + math.floor(remaining * best_rate)
      selected_row = selected_row or fallback_row
    else
      total_minutes = total_minutes + remaining * 12
    end
  end

  if total_minutes > 0 then
    return total_minutes,
      selected_row and selected_row.pause_limit or 0,
      selected_row and selected_row.validity_seconds or 0
  end
  return amount * 12, 0, 0
end

return M
