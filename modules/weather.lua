-- Menu module: the weather where the phone is, from wttr.in. ASCII only,
-- see docs/PROTOCOL.md.
--
--   single tap -- fetch again
--   double tap -- back to the menu (handled by frame_app.lua)
--
-- The example of a module using the Internet through the phone (_M.host, see
-- frame_app.lua). The phone answers only if this module is allowed the
-- Internet in Glaz > Menu; otherwise the status is 403.
--
-- wttr.in places the request by the phone's IP address. format= picks the
-- fields, '|' separated: location, temperature, conditions. The answer has a
-- degree sign, which the display font lacks, so non-ASCII bytes are dropped.
local _M = {}

_M.label = 'Weather'
_M.mode = 'app'
_M.background = false

local URL = 'https://wttr.in/?format=%l|%t|%C'
local LINE_MAX = 26

local req = nil      -- id of the request in flight
local text = ''

local function clip(s)
  if #s > LINE_MAX then return string.sub(s, 1, LINE_MAX - 2) .. '..' end
  return s
end

local function fetch()
  local id, err = _M.host.http('GET', URL)
  req = id
  text = id and 'asking the phone..' or ('no: ' .. err)
end

function _M.start()
  fetch()
end

function _M.tick()
  if req then
    local status, body = _M.host.result(req)
    if status == 200 then
      req = nil
      body = string.gsub(body, '[\128-\255]', '')
      local place, temp, sky = string.match(body, '^([^|]*)|([^|]*)|(.-)%s*$')
      if place then
        text = clip(place) .. '\n' .. clip(temp) .. '\n' .. clip(sky)
      else
        text = clip(body)
      end
    elseif status then
      req = nil
      text = 'error ' .. status .. '\n' .. clip(body or '')
    end
  end
  return text
end

function _M.on_tap()
  fetch()
  return text
end

return _M
