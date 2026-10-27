-- The phone browsing the files on the glasses (FILES_GET, FILE_GET): part
-- of glaz.lua, in a file of its own, loaded for a request and dropped
-- after. ASCII only, see docs/PROTOCOL.md, "Files".
--
-- Called with list (true for FILES_GET, false for FILE_GET), the request
-- -- [id] then the path -- and the host services table from glaz_host.lua.
-- The first byte of an answer says how it went: '+' or '-' and why.

-- Must match glaz.lua and docs/PROTOCOL.md.
local FILES     = 0x1D    -- [0x1D, id, more, bytes...] a folder listing
local FILE_DATA = 0x1E    -- [0x1E, id, more, bytes...] a file's contents

-- A file is read and sent a line at a time, never held whole --
-- glaz.lua alone is over 50 KB -- but the main loop waits while it
-- goes, so it stops here.
local FILE_MAX  = 64 * 1024

-- The root's listing ends with 's\tfree\ttotal', the file system's bytes,
-- where the firmware can tell: frame.file.space() is ours (firmware glaz),
-- stock firmware has none, and then the line is not there. A phone that
-- does not know the line skips it, as any line it does not know.
local function space()
  if not frame.file.space then return nil end
  local ok, s = pcall(frame.file.space)
  if not ok or type(s) ~= 'table' or not s.free or not s.total then
    return nil
  end
  return 's\t' .. math.floor(s.free) .. '\t' .. math.floor(s.total)
end

local function listing(id, path, host)
  local root = path == '' or path == '/'
  local ok, entries = pcall(frame.file.listdir, root and '/' or path)
  if ok and type(entries) == 'table' then
    local out = {}
    for _, e in ipairs(entries) do
      if e.name ~= '.' and e.name ~= '..' then
        -- type 2 is a folder (littlefs)
        out[#out + 1] = e.type == 2 and ('d\t' .. e.name)
                        or ('f\t' .. e.size .. '\t' .. e.name)
      end
    end
    if root then out[#out + 1] = space() end
    host.send_chunks(FILES, id, '+' .. table.concat(out, '\n'))
  else
    host.send_chunks(FILES, id, '-' .. tostring(entries))
  end
end

local function contents(id, path, host)
  local ok, fh = pcall(frame.file.open, path, 'read')
  if not ok then
    host.send_chunks(FILE_DATA, id, '-' .. tostring(fh))
    return
  end
  -- read() gives a line without its '\n'; send as it comes
  local chunk = frame.bluetooth.max_length() - 3
  local buf, total, sent = '+', 0, true
  while sent do
    local line = fh:read()
    if line == nil then break end
    total = total + #line + 1
    if total > FILE_MAX then
      buf = buf .. '... cut at ' .. FILE_MAX .. ' bytes\n'
      break
    end
    buf = buf .. line .. '\n'
    while sent and #buf >= chunk do
      sent = host.send_packet(FILE_DATA, id, true, string.sub(buf, 1, chunk))
      buf = string.sub(buf, chunk + 1)
    end
  end
  fh:close()
  if sent then host.send_packet(FILE_DATA, id, false, buf) end
end

return function(list, block, host)
  local id = string.byte(block, 1)
  local path = string.sub(block, 2)
  if list then
    listing(id, path, host)
  else
    contents(id, path, host)
  end
end
