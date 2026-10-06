--- KemoFi connected-client discovery.
-- WiFi station data is authoritative. DHCP and neighbor data enrich IP/name
-- details and cover clients behind a bridged external access point.
local M = {}

local function normalize_mac(value)
  local mac = tostring(value or ""):upper()
  if mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then return mac end
  return nil
end

local function normalize_ip(value)
  local ip = tostring(value or "")
  local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  for _, octet in ipairs({a, b, c, d}) do
    if tonumber(octet) > 255 then return nil end
  end
  return ip
end

local function command_lines(command)
  local handle = io.popen(command .. " 2>/dev/null")
  if not handle then return function() return nil end end
  local closed = false
  return function()
    local line = handle:read("*l")
    if not line and not closed then
      handle:close()
      closed = true
    end
    return line
  end
end

-- Linux bridge ageing_time is exposed in centiseconds. Keep bridged clients
-- present for the full FDB lifetime so an idle external-AP client is not
-- mistaken for a disconnected client after only a few seconds.
local function bridge_ageing_seconds()
  local file = io.open("/sys/class/net/br-lan/bridge/ageing_time", "r")
  local raw = file and file:read("*l") or nil
  if file then file:close() end
  local centiseconds = tonumber(raw)
  if not centiseconds or centiseconds <= 0 then return 300 end
  return math.max(30, math.min(3600, centiseconds / 100))
end

local function wifi_interfaces()
  local interfaces = {}
  local current
  for line in command_lines("iw dev") do
    local name = line:match("^%s*Interface%s+(%S+)")
    if name and name:match("^[%w%._%-]+$") then
      current = {name = name, ssid = ""}
      interfaces[#interfaces + 1] = current
    elseif current then
      local ssid = line:match("^%s*ssid%s+(.+)$")
      if ssid then current.ssid = ssid end
    end
  end
  return interfaces
end

local function dhcp_leases()
  local leases = {}
  local file = io.open("/tmp/dhcp.leases", "r")
  if not file then return leases end
  for line in file:lines() do
    local _, mac_raw, ip, hostname = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
    local mac = normalize_mac(mac_raw)
    if mac then
      leases[mac] = {
        ip = ip or "",
        hostname = hostname ~= "*" and (hostname or "") or ""
      }
    end
  end
  file:close()
  return leases
end

local function live_neighbors()
  local neighbors = {}
  for line in command_lines("ip neigh show dev br-lan") do
    local ip, mac_raw = line:match("^(%S+).-%slladdr%s+(%S+)")
    local state = line:match("(%u+)%s*$") or ""
    local mac = normalize_mac(mac_raw)
    if mac and (state == "REACHABLE" or state == "DELAY" or state == "PROBE") then
      neighbors[mac] = ip
    end
  end
  return neighbors
end

function M.mac_for_ip(value)
  local wanted = normalize_ip(value)
  if not wanted then return nil end

  local arp = io.open("/proc/net/arp", "r")
  if arp then
    for line in arp:lines() do
      local ip, mac_raw = line:match("^(%S+)%s+%S+%s+%S+%s+(%S+)")
      if ip == wanted then
        local mac = normalize_mac(mac_raw)
        if mac then
          arp:close()
          return mac
        end
      end
    end
    arp:close()
  end

  local leases = io.open("/tmp/dhcp.leases", "r")
  if leases then
    for line in leases:lines() do
      local mac_raw, ip = line:match("^%S+%s+(%S+)%s+(%S+)")
      if ip == wanted then
        local mac = normalize_mac(mac_raw)
        if mac then
          leases:close()
          return mac
        end
      end
    end
    leases:close()
  end

  for line in command_lines("ip neigh show dev br-lan") do
    local ip, mac_raw = line:match("^(%S+).-%slladdr%s+(%S+)")
    if ip == wanted then
      local mac = normalize_mac(mac_raw)
      if mac then return mac end
    end
  end
  return nil
end

local function bridge_clients(max_age)
  local entries = {}
  local age_limit = tonumber(max_age) or 90
  for line in command_lines("brctl showmacs br-lan") do
    local port, mac_raw, is_local, age = line:match(
      "^%s*(%d+)%s+(%S+)%s+(%S+)%s+([%d%.]+)"
    )
    local mac = normalize_mac(mac_raw)
    if port and mac and is_local == "no" and (tonumber(age) or 999) <= age_limit then
      entries[mac] = {
        age = tonumber(age) or 999,
        port = tonumber(port)
      }
    end
  end
  return entries
end

local function wifi_bridge_ports(interfaces)
  local ports = {}
  for line in command_lines("brctl showstp br-lan") do
    local name, port = line:match("^%s*([%w%._%-]+)%s+%((%d+)%)")
    if name and port then
      for _, interface in ipairs(interfaces) do
        if interface.name == name then ports[tonumber(port)] = true end
      end
    end
  end
  return ports
end

local function wifi_interface_names(interfaces)
  local names = {}
  for _, interface in ipairs(interfaces or {}) do
    names[interface.name] = true
  end
  return names
end

local function bridge_fdb_device(mac)
  for line in command_lines("bridge fdb show br br-lan") do
    local mac_raw, device = line:match("^(%S+)%s+dev%s+(%S+)")
    if normalize_mac(mac_raw) == mac then
      return (device or ""):gsub("@.*$", "")
    end
  end
  return nil
end

local function station_present(mac, interfaces)
  for _, interface in ipairs(interfaces or {}) do
    for line in command_lines("iw dev " .. interface.name .. " station dump") do
      if normalize_mac(line:match("^Station%s+(%S+)")) == mac then
        return true
      end
    end
  end
  return false
end

--- True when the router can currently observe at least one WiFi interface.
-- An empty/failing `iw dev` result is not proof that every customer left;
-- it can mean the radio is down or the wireless command is temporarily
-- unavailable. Auto-pause must not consume time in that situation.
function M.wifi_observation_available()
  return #wifi_interfaces() > 0
end

function M.list_connected()
  local by_mac = {}
  local leases = dhcp_leases()

  for _, interface in ipairs(wifi_interfaces()) do
    for line in command_lines("iw dev " .. interface.name .. " station dump") do
      local mac = normalize_mac(line:match("^Station%s+(%S+)"))
      if mac then
        local lease = leases[mac] or {}
        by_mac[mac] = {
          mac = mac,
          connected = true,
          connection = "wifi",
          interface = interface.name,
          ssid = interface.ssid,
          ip = lease.ip or "",
          hostname = lease.hostname or ""
        }
      end
    end
  end

  -- A bridged external AP preserves client MAC addresses, but those clients do
  -- not appear in `iw station dump`. The bridge forwarding table provides the
  -- strongest signal; a reachable neighbor covers devices between FDB updates.
  local bridged = bridge_clients()
  local neighbors = live_neighbors()
  for mac in pairs(neighbors) do
    if bridged[mac] == nil then bridged[mac] = {age = 90, port = nil} end
  end
  for mac, bridge_age in pairs(bridged) do
    if not by_mac[mac] then
      local lease = leases[mac] or {}
      by_mac[mac] = {
        mac = mac,
        connected = true,
        connection = "bridge",
        interface = "br-lan",
        ssid = "External AP",
        ip = lease.ip or neighbors[mac] or "",
        hostname = lease.hostname or "",
        bridge_age = bridge_age.age
      }
    end
  end

  local rows = {}
  for _, client in pairs(by_mac) do rows[#rows + 1] = client end
  table.sort(rows, function(a, b) return a.mac < b.mac end)
  return rows, by_mac
end

function M.hostname_for_mac(mac)
  local normalized = normalize_mac(mac)
  if not normalized then return "" end
  local lease = dhcp_leases()[normalized]
  return lease and lease.hostname or ""
end

--- Describe the strongest link evidence for a client.
-- "wifi" means the station is currently associated with this router.
-- "wifi_stale" means only the router's own WiFi bridge entry remains, so the
-- station has disappeared from the authoritative station table.
-- "bridge" means the client is behind another access point; its absence is
-- deliberately not strong enough evidence for automatic pausing.
function M.connection_kind(mac)
  local normalized = normalize_mac(mac)
  if not normalized then return nil end

  local interfaces = wifi_interfaces()
  if station_present(normalized, interfaces) then return "wifi" end

  local wifi_names = wifi_interface_names(interfaces)
  local fdb_device = bridge_fdb_device(normalized)
  if fdb_device then
    if wifi_names[fdb_device] then return "wifi_stale" end
    return "bridge"
  end

  -- Older OpenWrt images may not ship the `bridge` utility. Keep the brctl
  -- fallback, but classify non-WiFi bridge ports conservatively.
  local bridge = bridge_clients(bridge_ageing_seconds())[normalized]
  if not bridge then return nil end
  local wifi_ports = wifi_bridge_ports(interfaces)
  if bridge.port and wifi_ports[bridge.port] then return "wifi_stale" end
  return "bridge"
end

--- True while a client is directly associated or has a very fresh bridge FDB
--- entry. The short bridge age lets an external-AP handoff settle before time
--- is transferred to a new private MAC.
function M.is_recently_connected(mac, max_bridge_age)
  local normalized = normalize_mac(mac)
  if not normalized then return false end

  local interfaces = wifi_interfaces()
  for _, interface in ipairs(interfaces) do
    local station_found = false
    for line in command_lines("iw dev " .. interface.name .. " station dump") do
      if normalize_mac(line:match("^Station%s+(%S+)")) == normalized then
        station_found = true
      end
    end
    if station_found then return true end
  end

  -- A stale FDB entry on the router's own WiFi bridge port means the station
  -- has actually disassociated, even though the bridge has not aged it out.
  -- For a wired/ external AP port, keep the client present for the complete
  -- bridge ageing window so idle traffic does not trigger auto-pause.
  local bridge = bridge_clients(bridge_ageing_seconds())[normalized]
  if not bridge then return false end
  local wifi_ports = wifi_bridge_ports(interfaces)
  if bridge.port and wifi_ports[bridge.port] then return false end

  local age_limit = tonumber(max_bridge_age) or bridge_ageing_seconds()
  return bridge.age <= age_limit
end

function M.is_connected(mac)
  local normalized = normalize_mac(mac)
  if not normalized then return false end
  local _, by_mac = M.list_connected()
  return by_mac[normalized] ~= nil
end

return M
