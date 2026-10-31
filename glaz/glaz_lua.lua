-- The phone's Lua console (LUA_EVAL): part of glaz.lua, in a file of
-- its own, loaded for a request and dropped after. ASCII only, see
-- docs/PROTOCOL.md, "Lua console".
--
-- Called with the request -- [id] then the code -- and the host services
-- table from glaz_host.lua. The code runs inside the app, in its globals:
-- frame.*, the libraries, and whatever earlier requests left there; the
-- app's own locals stay out of reach. It is tried with 'return ' first, so
-- '1+1' and 'frame.battery_level()' answer with their value. What it
-- print()s comes back too, before the values. The answer, LUA_RESULT, is
-- '+' and the text, or '-' and the error: 'not enough memory' too, when
-- the request ran the heap out (docs/PROTOCOL.md, "Lua console").

-- Must match glaz.lua and docs/PROTOCOL.md.
local LUA_RESULT = 0x09   -- [0x09, id, more, bytes...] the answer

local MAX = 8 * 1024      -- an answer is cut here
local SHOWN = 40          -- entries of a table shown

-- t[k] as text, let go of in t: a long string is cut before it is quoted,
-- and the whole of it is garbage by then -- the 40 KB or so the app has
-- holds 8 KB and its quoted copy, not all of it as well.
local function show(t, k)
  local v = t[k]
  t[k] = nil
  if type(v) == 'string' then
    if #v > MAX then v = string.sub(v, 1, MAX) end
    return string.format('%q', v)
  end
  if type(v) ~= 'table' then return tostring(v) end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local out = {}
  for i, k in ipairs(keys) do
    if i > SHOWN then
      out[#out + 1] = '... ' .. (#keys - SHOWN) .. ' more'
      break
    end
    local x = v[k]
    local s = type(x) == 'table' and '{...}'
              or type(x) == 'function' and 'function'
              or type(x) == 'string' and string.format('%q', x)
              or tostring(x)
    out[#out + 1] = tostring(k) .. ' = ' .. s
  end
  return '{ ' .. table.concat(out, ', ') .. ' }'
end

local function run(code)
  local fn = load('return ' .. code, '=console')
  if not fn then
    local err
    fn, err = load(code, '=console')
    if not fn then return false, err end
  end

  local said = {}
  local print_ = print
  print = function(...)
    local parts = table.pack(...)
    for i = 1, parts.n do parts[i] = tostring(parts[i]) end
    said[#said + 1] = table.concat(parts, '\t', 1, parts.n)
  end
  local r = table.pack(pcall(fn))
  print = print_
  if not r[1] and glaz_break(r[2]) then error(r[2], 0) end

  if not r[1] then
    said[#said + 1] = tostring(r[2])
    return false, table.concat(said, '\n')
  end
  for i = 2, r.n do said[#said + 1] = show(r, i) end
  -- one part is the answer as it is, not a copy of it
  return true, #said == 1 and said[1] or table.concat(said, '\n')
end

return function(block, host)
  local id = string.byte(block, 1)
  local done, ok, text = pcall(run, string.sub(block, 2))
  if not done then
    -- out of memory, most likely: the request's garbage is gone by now,
    -- and the phone still gets an answer
    if glaz_break(ok) then error(ok, 0) end
    ok, text = false, tostring(ok)
  end
  local sign = ok and '+' or '-'
  if #text > MAX then
    text = sign .. string.sub(text, 1, MAX) .. '\n... cut at ' .. MAX ..
           ' bytes'
  else
    text = sign .. text
  end
  host.send_chunks(LUA_RESULT, id, text)
end
