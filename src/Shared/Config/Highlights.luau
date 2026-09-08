-- The breathing highlight's colours, grouped by verb rather than object: green is "put this here", orange "work this", gold "there's money in this". DIM and BRIGHT are the ends it breathes between.

--
local Highlights = {}

-- The tag that starts an instance breathing, matching the BreathingHighlight component's file name
Highlights.TAG = "BreathingHighlight"

-- Put what you're holding here: an empty stand, a stick with room, a free griller
Highlights.PLACE = Color3.fromRGB(255, 255, 0)

-- Work this machine: the roll lever, the sauce bottle.
Highlights.OPERATE = Color3.fromRGB(255, 255, 0)

-- Money's waiting: a finished skewer to claim off the grill, the sell stall with one in hand.
Highlights.CLAIM = Color3.fromRGB(255, 205, 65)

-- Half a breath; the tween reverses. Past about 0.4 it reads as a flicker rather than a pulse
Highlights.BREATHE_DURATION = 1

-- The outline's range; OUTLINE_DIM at 1 would read as blinking rather than breathing
Highlights.OUTLINE_DIM = 0
Highlights.OUTLINE_BRIGHT = 0

-- The fill's range, kept faint so the object's own colours still show through.
Highlights.FILL_DIM = 0.6
Highlights.FILL_BRIGHT = 0.9

return Highlights
