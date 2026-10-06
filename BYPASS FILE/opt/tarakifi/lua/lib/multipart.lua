--- multipart.lua — Minimal multipart/form-data parser for uhttpd Lua handler
-- Parses raw body bytes into named fields and file parts.
-- Designed for small uploads (sounds, images) on constrained hardware.

local M = {}

--- Extract boundary from Content-Type header
-- @param content_type string e.g. "multipart/form-data; boundary=----WebKitFormBoundary..."
-- @return string|nil boundary string (without leading --)
function M.get_boundary(content_type)
  if not content_type then return nil end
  local boundary = content_type:match("boundary=([^\r\n;]+)")
  if boundary then
    -- Remove optional quotes
    boundary = boundary:gsub('^"', ''):gsub('"$', '')
  end
  return boundary
end

--- Parse multipart body into parts
-- @param body string raw body bytes
-- @param boundary string the boundary string
-- @return table { [name] = { value=string, filename=string|nil, content_type=string|nil } }
function M.parse(body, boundary)
  local parts = {}
  if not body or not boundary then return parts end

  local delim = "--" .. boundary
  local end_delim = delim .. "--"

  -- Split by delimiter
  local pos = 1
  while true do
    local start_pos = body:find(delim, pos, true)
    if not start_pos then break end

    -- Move past delimiter + CRLF
    local after_delim = start_pos + #delim
    -- Check if this is the end delimiter
    if body:sub(after_delim, after_delim + 1) == "--" then break end
    -- Skip CRLF after delimiter
    if body:sub(after_delim, after_delim + 1) == "\r\n" then
      after_delim = after_delim + 2
    elseif body:sub(after_delim, after_delim) == "\n" then
      after_delim = after_delim + 1
    end

    -- Find end of headers (double CRLF)
    local headers_end = body:find("\r\n\r\n", after_delim, true)
    if not headers_end then
      -- Try LF only
      headers_end = body:find("\n\n", after_delim, true)
      if not headers_end then break end
      local headers_str = body:sub(after_delim, headers_end - 1)
      local data_start = headers_end + 2
      local next_delim = body:find(delim, data_start, true)
      if not next_delim then break end
      -- Data ends before CRLF before next delimiter
      local data_end = next_delim - 2
      if body:sub(data_end, data_end) == "\n" then data_end = data_end - 1 end
      local data = body:sub(data_start, data_end)
      local part = M._parse_headers(headers_str, data)
      if part and part.name then parts[part.name] = part end
      pos = next_delim
    else
      local headers_str = body:sub(after_delim, headers_end - 1)
      local data_start = headers_end + 4
      local next_delim = body:find(delim, data_start, true)
      if not next_delim then break end
      -- Data ends before CRLF before next delimiter
      local data_end = next_delim - 3
      if body:sub(data_end + 1, data_end + 2) == "\r\n" then
        -- normal case
      else
        data_end = next_delim - 2
        if body:sub(data_end, data_end) == "\n" then data_end = data_end - 1 end
      end
      local data = body:sub(data_start, data_end)
      local part = M._parse_headers(headers_str, data)
      if part and part.name then parts[part.name] = part end
      pos = next_delim
    end
  end

  return parts
end

--- Parse headers from a single part
function M._parse_headers(headers_str, data)
  local part = { value = data }

  -- Extract Content-Disposition
  local disposition = headers_str:match("[Cc]ontent%-[Dd]isposition:%s*(.-)[\r\n]")
  if not disposition then
    disposition = headers_str:match("[Cc]ontent%-[Dd]isposition:%s*(.+)$")
  end
  if disposition then
    part.name = disposition:match('name="([^"]*)"')
    part.filename = disposition:match('filename="([^"]*)"')
  end

  -- Extract Content-Type
  local ct = headers_str:match("[Cc]ontent%-[Tt]ype:%s*(.-)[\r\n]")
  if not ct then
    ct = headers_str:match("[Cc]ontent%-[Tt]ype:%s*(.+)$")
  end
  if ct then part.content_type = ct:match("^%s*(.-)%s*$") end

  return part
end

return M
