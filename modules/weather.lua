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
-- wttr.in places the request by the phone's IP address, unless the phone
-- names a place (url() below). format= picks the
-- fields, '|' separated: location, temperature, conditions. The answer has a
-- degree sign, which the display font lacks, so non-ASCII bytes are dropped.
local _M = {}

_M.label = 'Weather'
_M.mode = 'app'
_M.background = false

-- Where: the city and country set on the phone (Glaz > Menu > Weather),
-- sent as wttr.in wants them, 'City,Country'. With none set, the phone's
-- position if Weather may have it (Location, docs/PROTOCOL.md), as
-- 'lat,lon'; failing that, wttr.in goes by the phone's IP. Anything but
-- letters, digits and ,.- is percent-encoded.
local FORMAT = '?format=%l|%t|%C'

local function encode(place)
  return (string.gsub(place, '[^%w,%.%-]', function(c)
    return string.format('%%%02X', string.byte(c))
  end))
end

local function chosen_place()
  local city = _M.host.setting('city', '')
  local country = _M.host.setting('country', '')
  if city ~= '' and country ~= '' then return city .. ',' .. country end
  return city
end

local LINE_MAX = 26

local req = nil      -- id of the weather request in flight
local loc = nil      -- id of the location request in flight
local here = nil     -- 'lat,lon' when the place came from the phone's GPS
local text = ''

-- UTF-8: LINE_MAX counts characters (Cyrillic is two bytes each)
local function clip(s)
  if (utf8.len(s) or #s) <= LINE_MAX then return s end
  local cut = utf8.len(s) and utf8.offset(s, LINE_MAX - 1) or LINE_MAX - 1
  return string.sub(s, 1, cut - 1) .. '..'
end

local function fetch(place)
  local id, err = _M.host.http('GET', 'https://wttr.in/' .. encode(place) ..
                                        FORMAT)
  req = id
  text = id and 'asking the phone..' or ('no: ' .. err)
end

-- A place set on the phone wins; otherwise ask where the phone is first.
local function start()
  here = nil
  local place = chosen_place()
  if place ~= '' then return fetch(place) end
  loc = _M.host.locate()
  if loc then
    text = 'finding the phone..'
  else
    fetch('')        -- no phone to ask: let wttr.in guess from the IP
  end
end

function _M.start()
  start()
end

function _M.tick()
  if loc then
    -- nil, nil while pending; an answer comes once
    local fix, why = _M.host.location(loc)
    if fix then
      loc = nil
      here = string.format('%.2f,%.2f', fix.lat, fix.lon)
      fetch(here)
    elseif why then
      loc = nil      -- not allowed, no fix, timeout: by the IP then
      fetch('')
    end
  end
  if req then
    local status, body = _M.host.result(req)
    if status == 200 then
      req = nil
      local place, temp, sky = string.match(body, '^([^|]*)|([^|]*)|(.-)%s*$')
      if place then
        -- for a position wttr.in names it by its numbers
        if here then place = 'here, ' .. here end
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
  start()
  return text
end

return _M
