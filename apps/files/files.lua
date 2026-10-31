-- Menu module: browse the files on the glasses. ASCII only, see
-- docs/PROTOCOL.md.
--
--   tilt right / left -- next / previous file
--   single tap        -- preview the file under the cursor; tap again to go
--                        back to the list
--   double tap        -- preview: back to the list; list: back to the menu
--
-- The list is read once, when the module opens. Three lines of output are
-- all a module gets (glaz.lua TEXT_ROWS), so the list shows a window of
-- three files around the cursor, and a preview shows the name and size and
-- then the first lines of the file.
--
-- frame.file.listdir() returns { name, size, type } per entry; type 2 is a
-- directory (littlefs). The root is flat in practice: the host uploads
-- everything there.
local _M = {}

_M.label = 'Files'
_M.mode = 'app'
_M.background = false  -- sleeps: stopped as soon as it leaves the screen

local WINDOW    = 3    -- files on screen at once
local LINE_MAX  = 26   -- characters that fit a line, roughly (proportional font)
local DIR_TYPE  = 2

local files = {}       -- { name, size, dir }, sorted by name
local sel = 1
local preview = nil    -- text of the preview, or nil while listing

local function human(size)
  if size < 1024 then return size .. ' B' end
  return string.format('%.1fK', size / 1024)
end

-- A line longer than a read (512 bytes) comes in pieces, cut wherever the
-- bytes ran out: a piece may then start or end inside a character. Those
-- bytes are dropped, so the rest still counts as UTF-8; a line that is not
-- UTF-8 anyway (a binary file) stays as it is.
local function whole(s)
  if utf8.len(s) then return s end
  local t = string.gsub(s, '^[\x80-\xBF]+', '')
  for k = 0, 3 do
    local u = string.sub(t, 1, #t - k)
    if utf8.len(u) then return u end
  end
  return s
end

-- UTF-8: LINE_MAX counts characters (Cyrillic is two bytes each)
local function clip(s)
  s = whole(s)
  if (utf8.len(s) or #s) <= LINE_MAX then return s end
  local cut = utf8.len(s) and utf8.offset(s, LINE_MAX - 1) or LINE_MAX - 1
  return string.sub(s, 1, cut - 1) .. '..'
end

local function load_list()
  files = {}
  local ok, entries = pcall(frame.file.listdir, '/')
  if not ok then return end
  for _, e in ipairs(entries) do
    if e.name ~= '.' and e.name ~= '..' then
      files[#files + 1] = { name = e.name, size = e.size, dir = e.type == DIR_TYPE }
    end
  end
  table.sort(files, function(a, b) return a.name < b.name end)
end

-- The first `count` lines of a file, clipped to the screen width.
local function head(name, count)
  local ok, fh = pcall(frame.file.open, name, 'read')
  if not ok then return { 'cannot open' } end
  local out = {}
  while #out < count do
    local line = fh:read()
    if line == nil then break end
    out[#out + 1] = clip(line)
  end
  fh:close()
  return out
end

local function list_screen()
  if #files == 0 then return 'no files' end
  -- keep the cursor in the middle row where possible
  local first = math.max(1, math.min(sel - 1, #files - WINDOW + 1))
  local rows = {}
  for i = first, math.min(first + WINDOW - 1, #files) do
    local f = files[i]
    local name = f.dir and (f.name .. '/') or f.name
    local text = name .. '  ' .. (f.dir and '' or human(f.size))
    rows[#rows + 1] = ((i == sel) and '> ' or '  ') .. clip(text)
  end
  return table.concat(rows, '\n')
end

function _M.start()
  load_list()
  sel = 1
  preview = nil
end

function _M.tick()
  return preview or list_screen()
end

function _M.on_roll(dir)
  if preview or #files == 0 then return nil end
  sel = sel + dir
  if sel < 1 then sel = #files end
  if sel > #files then sel = 1 end
  return list_screen()
end

function _M.on_tap()
  if preview then
    preview = nil
    return list_screen()
  end
  local f = files[sel]
  if not f then return nil end
  if f.dir then
    preview = clip(f.name .. '/') .. '\n(directory)'
  else
    local lines = head(f.name, 2)
    preview = clip(f.name .. '  ' .. human(f.size)) .. '\n' ..
              table.concat(lines, '\n')
  end
  return preview
end

-- Back from a preview to the list; from the list, false: the app leaves.
function _M.on_back()
  if not preview then return false end
  preview = nil
  return list_screen()
end

-- Nothing held after the module closes: the list goes with it.
function _M.stop()
  files = {}
  preview = nil
end

return _M
