-- about.lua's part for Halo: its lines for the round screen, whose text
-- rows hold 14, 13 and 11 characters (glaz.halo.lua, D.fit), so that the
-- version and the author's name are shown whole. Its being here puts
-- about on Halo (docs/DEVICES.md). ASCII only.
local D = {}

-- 'glaz <version>', then the author over two lines, split at the last space:
-- 'by Anton', 'Vasiljev'.
function D.lines(name, version, author)
  local first, last = string.match(author, '^(.*)%s(%S+)$')
  if not first then first, last = author, '' end
  return name .. ' ' .. version .. '\n' .. 'by ' .. first .. '\n' .. last
end

return D
