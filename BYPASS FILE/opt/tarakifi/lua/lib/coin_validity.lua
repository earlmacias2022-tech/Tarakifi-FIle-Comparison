-- Purchased-time thresholds and rolling validity, matching hEX.
local M = {}
local MAX_RULES, MAX_VALUE = 100, 99999

function M.normalize(raw)
  if type(raw) ~= "string" or #raw > 4096 then
    return nil, "Enter validity rules as minutes:hours."
  end
  local rules, seen = {}, {}
  for line in raw:gmatch("[^\r\n]+") do
    if line:match("%S") then
      local minutes, hours = line:match("^%s*(%d+)%s*:%s*(%d+)%s*$")
      minutes, hours = tonumber(minutes), tonumber(hours)
      if not minutes or not hours or minutes < 1 or hours < 1 or
          minutes > MAX_VALUE or hours > MAX_VALUE then
        return nil, "Use whole numbers from 1 to 99999."
      end
      if seen[minutes] then return nil, "Each WiFi time must be unique." end
      if #rules >= MAX_RULES then return nil, "Use at most 100 validity rules." end
      seen[minutes] = true
      rules[#rules + 1] = {minutes = minutes, hours = hours}
    end
  end
  table.sort(rules, function(a, b) return a.minutes < b.minutes end)
  local lines = {}
  for _, rule in ipairs(rules) do
    lines[#lines + 1] = string.format("%d:%d", rule.minutes, rule.hours)
  end
  return table.concat(lines, "\n"), nil, rules
end

function M.active(row, now)
  return row and ((tonumber(row.validity_expires_at) or 0) == 0 or
    tonumber(row.validity_expires_at) > now) and
    (tonumber(row.paused) == 1 or (tonumber(row.expires_at) or 0) > now)
end

function M.total(row, minutes, now)
  -- Old sessions have no purchase counter. Seed from their saved balance only
  -- on the next credit; migration and settings saves never rewrite balances.
  -- Match the existing credit path: until its expiry sweep removes the row,
  -- a fresh top-up retains the paused/running balance and clears stale expiry.
  local retained = row and (tonumber(row.paused) == 1 or (tonumber(row.expires_at) or 0) > now)
  local previous = retained and
    (tonumber(row.validity_minutes_total) or tonumber(row.minutes_remaining) or 0) or 0
  return math.max(0, previous) + minutes
end

function M.deadline(raw, row, total, now)
  local previous = M.active(row, now) and (tonumber(row.validity_expires_at) or 0) or 0
  local normalized, _, rules = M.normalize(raw or "")
  -- Corrupt configuration must not lose a paid coin or shorten a deadline.
  if not normalized then return previous end
  local hours
  for _, rule in ipairs(rules) do
    if total >= rule.minutes then hours = rule.hours else break end
  end
  return hours and math.max(previous, now + hours * 3600) or previous
end

return M
