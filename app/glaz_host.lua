-- Services the phone provides to the modules, and the settings it sends:
-- part of glaz.lua (main.lua on the glasses), in a file of its own so
-- it compiles on its own -- main.lua in one piece no longer fitted in the
-- glasses' memory to compile. ASCII only, see docs/PROTOCOL.md.
--
-- glaz.lua requires it once at start and keeps what it returns.

-- Must match glaz.lua and docs/PROTOCOL.md.
local NET_REQUEST  = 0x19 -- [0x19, id, more, bytes...] a module's HTTP request
local LOCATION_GET = 0x1C -- [0x1C, id, module...] a module asks where it is
local NET_TIMEOUT  = 20   -- seconds before a request is given up on

-- Module settings, set on the phone (Glaz > Menu > a module). The phone
-- sends the whole set on connect and on every change; it is kept in
-- SETTINGS_FILE too, so the glasses remember it without the phone.
-- module -> { key -> value }, values as text.
local SETTINGS_FILE = 'settings.txt'
local settings = {}

local function parse_settings(text)
  local t = {}
  for line in string.gmatch(text, '[^\n]+') do
    local m, k, v = string.match(line, '^([%w_]+)%.([%w_]+)=(.*)$')
    if m then
      t[m] = t[m] or {}
      t[m][k] = v
    end
  end
  return t
end

-- Settings picked on the glasses themselves (Settings > Notifications):
-- the phone never sends these, so SETTINGS_SET leaves them alone. Lines
-- 'module.key=value' in PREFS_FILE, read at start, written on a change.
local PREFS_FILE = 'prefs.txt'
local prefs = {}

local function load_prefs()
  local ok, fh = pcall(frame.file.open, PREFS_FILE, 'read')
  if not ok or not fh then return end
  local lines = {}
  while true do
    local line = fh:read()
    if line == nil then break end
    lines[#lines + 1] = line
  end
  fh:close()
  prefs = parse_settings(table.concat(lines, '\n'))
end

local function save_prefs()
  local lines = {}
  for m, t in pairs(prefs) do
    for k, v in pairs(t) do lines[#lines + 1] = m .. '.' .. k .. '=' .. v end
  end
  local ok, e = pcall(function()
    local fh = frame.file.open(PREFS_FILE, 'write')
    fh:write(table.concat(lines, '\n'))
    fh:close()
  end)
  if not ok and glaz_break(e) then error(e, 0) end
end

-- owner's pref key: default when unset, a number when default is one
local function pref(owner, key, default)
  local v = prefs[owner] and prefs[owner][key]
  if v == nil or v == '' then return default end
  if type(default) == 'number' then return tonumber(v) or default end
  return v
end

load_prefs()

local function load_settings()
  local ok, fh = pcall(frame.file.open, SETTINGS_FILE, 'read')
  if not ok or not fh then return end
  local lines = {}
  while true do
    local line = fh:read()
    if line == nil then break end
    lines[#lines + 1] = line
  end
  fh:close()
  settings = parse_settings(table.concat(lines, '\n'))
end

local function store_settings(text)
  settings = parse_settings(text)
  local ok, e = pcall(function()
    local fh = frame.file.open(SETTINGS_FILE, 'write')
    fh:write(text)
    fh:close()
  end)
  if not ok and glaz_break(e) then error(e, 0) end
end

load_settings()

-- Services the phone provides to modules. Each module is handed its own
-- copy as _M.host, bound to its file name: that name is what the phone
-- checks the Internet permission against (Glaz > Menu).
--
--   local id, err = _M.host.http('GET', url[, body])  -- nil, why on failure
--   local status, body = _M.host.result(id)  -- nil while pending; then once
--   local id = _M.host.locate()        -- where the phone is: ask, then
--   local fix, why = _M.host.location(id)  -- nil while pending; then once
--                      -- { lat, lon, accuracy, age } or nil, why
--   _M.host.setting(key, default)  -- this module's setting from the phone;
--                      -- default when unset, and a number when default is
--   _M.host.pref(key, default)     -- one picked on the glasses, the same way
--   _M.host.set_pref(key, value)   -- keeps it, in PREFS_FILE
--
-- status 0 means the request never got an answer from the server; body says
-- why. Results are handed out once and then forgotten.
local requests = {}   -- id -> { owner, at, status, body }; status nil = pending
local next_req = 0
local fixes    = {}   -- id -> { owner, at, fix or why }; LOCATION_GET answers
local next_fix = 0
local LOCATION_WHY = { [1] = 'not allowed', [2] = 'no fix' }

-- One packet of a longer message, [code, id, more, bytes...]. The radio
-- may still be busy with the previous packet, so it is retried briefly.
local function send_packet(code, id, more, part)
  local packet = string.char(code, id, more and 1 or 0) .. part
  for _ = 1, 50 do
    if pcall(frame.bluetooth.send, packet) then return true end
    frame.sleep(0.01)
  end
  return false
end

-- A whole message, split into packets of what the link can carry; more is
-- 0 on the last. An empty payload is still one packet.
local function send_chunks(code, id, payload)
  local chunk = frame.bluetooth.max_length() - 3
  local pos = 1
  repeat
    local part = string.sub(payload, pos, pos + chunk - 1)
    pos = pos + chunk
    if not send_packet(code, id, pos <= #payload, part) then return false end
  until pos > #payload
  return true
end

local function send_request(id, payload)
  return send_chunks(NET_REQUEST, id, payload)
end

local function host_api(owner)
  local api = {}

  function api.http(method, url, body)
    if not frame.bluetooth.is_connected() then return nil, 'no phone' end
    next_req = next_req % 255 + 1
    local id = next_req
    requests[id] = { owner = owner, at = frame.time.utc() }
    local payload = owner .. '\n' .. method .. '\n' .. url .. '\n' .. (body or '')
    if not send_request(id, payload) then
      requests[id] = nil
      return nil, 'send failed'
    end
    return id
  end

  function api.result(id)
    local r = requests[id]
    if not r or r.owner ~= owner then return 0, 'unknown request' end
    if r.status == nil then
      if frame.time.utc() - r.at > NET_TIMEOUT then
        requests[id] = nil
        return 0, 'timeout'
      end
      return nil
    end
    requests[id] = nil
    return r.status, r.body
  end

  -- Where the phone is: locate() asks, location(id) gives nil while
  -- pending, then once { lat, lon, accuracy, age } -- degrees, metres,
  -- seconds -- or nil and why: 'not allowed' (Glaz > Menu), 'no fix',
  -- 'timeout'.
  function api.locate()
    if not frame.bluetooth.is_connected() then return nil, 'no phone' end
    next_fix = next_fix % 255 + 1
    local id = next_fix
    fixes[id] = { owner = owner, at = frame.time.utc() }
    local packet = string.char(LOCATION_GET, id) .. owner
    for _ = 1, 50 do
      if pcall(frame.bluetooth.send, packet) then return id end
      frame.sleep(0.01)
    end
    fixes[id] = nil
    return nil, 'send failed'
  end

  function api.location(id)
    local f = fixes[id]
    if not f or f.owner ~= owner then return nil, 'unknown request' end
    if f.fix == nil and f.why == nil then
      if frame.time.utc() - f.at > NET_TIMEOUT then
        fixes[id] = nil
        return nil, 'timeout'
      end
      return nil
    end
    fixes[id] = nil
    return f.fix, f.why
  end

  function api.setting(key, default)
    local v = settings[owner] and settings[owner][key]
    if v == nil or v == '' then return default end
    if type(default) == 'number' then return tonumber(v) or default end
    return v
  end

  function api.pref(key, default) return pref(owner, key, default) end

  function api.set_pref(key, value)
    prefs[owner] = prefs[owner] or {}
    prefs[owner][key] = tostring(value)
    save_prefs()
  end

  return api
end

return {
  requests = requests, fixes = fixes, pref = pref,
  LOCATION_WHY = LOCATION_WHY,
  send_packet = send_packet, send_chunks = send_chunks,
  api = host_api, store_settings = store_settings,
}
