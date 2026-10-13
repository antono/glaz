-- Splash sprite: a cyberpunk eye with a chip for a pupil. ASCII only.
--
-- One character per pixel, one string per row; every row the same length.
-- frame_app.lua draws it scaled up (SPLASH_SCALE) and centred, through
-- frame.display.bitmap in 16-colour mode. The art can be edited by hand:
-- the characters map to Frame's palette through colors below, and '.' is
-- transparent -- the display is an OLED, so transparent is simply black.
local _M = {}

-- character -> palette index (the order of frame.display's colour table)
_M.colors = {
  ['.'] = 0,    -- VOID, transparent
  w = 1,        -- WHITE
  k = 2,        -- GREY
  r = 3,        -- RED
  p = 4,        -- PINK
  o = 7,        -- ORANGE
  y = 8,        -- YELLOW
  g = 10,       -- GREEN
  G = 11,       -- LIGHTGREEN
  n = 12,       -- NIGHTBLUE
  s = 13,       -- SEABLUE
  c = 14,       -- SKYBLUE
  C = 15,       -- CLOUDBLUE
}

_M.art = {
  '..............................................p...................p.............................................',
  '..............................................c...................c.............................................',
  '..............................................c...................c.............................................',
  '..............................................c...................c.............................................',
  '....................................p.........c...ccccccccccccc...c.........p...................................',
  '....................................c........cccccCCCCCCCCCCCCCccccc........c...................................',
  '....................................c.....cccCCCCCnnnnnnnnnnnnnCCCCCccc.....c...................................',
  '....................................c..cccCCCnnnnnnnnnnnnnnnnnnnnnnnCCCccc..c...................................',
  '....................................cccCCCnnnnnnnnnnnnnnpnnnnnnnnnnnnnnCCCccc...................................',
  '...................................ccCCnnnnnnnnnnnnpppppppppppnnnnnnnnnnnnCCcc..................................',
  '.................................ccCCnnnnnnnnnnnnnpppppppppppppnnnnnnnnnnnnnCCcc................................',
  '................................cCCnnnnnnnnnnnnnpppprrrrcrrrrppppnnnnnnnnnnnnnCCc...............................',
  '..............................ccCnnnnnnnnnnnnnnppppcrssscsssrcppppnnnnnnnnnnnnnnCcc.............................',
  '..G......y...................cCCnnnnnnnnnnnnnnppprrscssscssscsrrpppnnnnnnnnnnnnnnCCc...................y......G.',
  '.GGGggggyyy................ccCnnnnnnnnnnnnnnnnpprrsscssscssscssrrppnnnnnnnnnnnnnnnnCcc................yyyggggGGG',
  '..G......y.g..............cCCnnnnnnnnnnnnnnnnppprssscycycycycsssrpppnnnnnnnnnnnnnnnnCCc..............g.y......G.',
  '..........g.g............cCnnnnnnnnnnnnnnnnnpppccssscynynynycsssccpppnnnnnnnnnnnnnnnnnCc............g.g.........',
  '...........g............cCnnnnnnnnnnnnnnnnnnpprrscsckkkkkkkkkcccsrrppnnnnnnnnnnnnnnnnnnCc............g..........',
  '............g..........cCnnnnnnnnnnnnnnnnnnnpprsssyykykkkkkkkyysssrppnnnnnnnnnnnnnnnnnnnCc..........g...........',
  '.............g.......ccCnnnnnnnnnnnnnnnnnnnnpprssscnkkkkkkkkkncsssrppnnnnnnnnnnnnnnnnnnnnCcc.......g............',
  '.......p......g......CCnnnnnnnnnnnnnnnnnnnnnpprsssyykkkwwwkkkyysssrppnnnnnnnnnnnnnnnnnnnnnCC......g......p......',
  '......pppssssssssgppp.nnnnnnnnnnnnnnnnnnnnnpppcccccnkkkwwwkkkncccccpppnnnnnnnnnnnnnnnnnnnnn.pppgssssssssppp.....',
  '.......p......g......ccnnnnnnnnnnnnnnnnnnnnnpprsssyykkkwwwkkkyysssrppnnnnnnnnnnnnnnnnnnnnncc......g......p......',
  '.............g.........cnnnnnnnnnnnnnnnnnnnnpprssscnkkkkkkkkkncsssrppnnnnnnnnnnnnnnnnnnnnc.........g............',
  '............g...........cnnnnnnnnnnnnnnnnnnnpprsssyykkkkkkkkkyysssrppnnnnnnnnnnnnnnnnnnnc...........g...........',
  '...........g.............cnnnnnnnnnnnnnnnnnnpprrscsckkkkkkkkkcscsrrppnnnnnnnnnnnnnnnnnnc.............g..........',
  '..........g...............cnnnnnnnnnnnnnnnnnpppccssscynynynycsssccpppnnnnnnnnnnnnnnnnnc...............g.........',
  '..G......g.................ccnnnnnnnnnnnnnnnnppprssscycycycycsssrpppnnnnnnnnnnnnnnnncc.................g......G.',
  '.GGGggggg....................cnnnnnnnnnnnnnnnnpprrsscssscssscssrrppnnnnnnnnnnnnnnnnc....................gggggGGG',
  '..G...........................ccnnnnnnnnnnnnnnppprrscssscssscsrrpppnnnnnnnnnnnnnncc...........................G.',
  '................................cnnnnnnnnnnnnnnppppcrssscsssrcppppnnnnnnnnnnnnnnc...............................',
  '.................................ccnnnnnnnnnnnnnpppprrrrcrrrrppppnnnnnnnnnnnnncc................................',
  '...................................ccnnnnnnnnnnnnnpppppppppppppnnnnnnnnnnnnncc..................................',
  '.....................................ccnnnnnnnnnnnnpppppppppppnnnnnnnnnnnncc....................................',
  '.......................................cccnnnnnnnnnnnnnnpnnnnnnnnnnnnnnccc......................................',
  '.........................................scccnnnnnnnnnnnnnnnnnnnnnnncccs........................................',
  '.........................................s...cccccnnnnnnnnnnnnnccccc...s........................................',
  '.........................................s........ccccccccccccc........s........................................',
  '.........................................p.............................p........................................',
}

return _M
