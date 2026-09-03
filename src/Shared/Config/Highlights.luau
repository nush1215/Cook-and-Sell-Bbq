--[[
    The breathing highlight that marks an interactable the player can act on right now.

    Colours are grouped by verb, not by object, so the palette carries meaning: green always means
    "put what you're holding here", orange always means "work this machine", gold always means
    "there's money in this". A player learns three colours instead of seven objects.

    The transparencies are a range the highlight breathes between -- DIM is the resting end it starts
    at, BRIGHT is what it tweens to and back. Outline is the readable part; the fill only takes the
    edge off so the shape doesn't look hollow.
]]

--
local Highlights = {}

-- The tag that starts an instance breathing. Matches the BreathingHighlight component's file name,
-- which is what it registers itself under -- rename one and you have to rename the other.
Highlights.TAG = "BreathingHighlight"

-- Put what you're holding here: an empty stick stand, a stick with room for another ingredient, a
-- free griller.
Highlights.PLACE = Color3.fromRGB(255, 255, 0)

-- Work this machine: the roll lever, the sauce bottle.
Highlights.OPERATE = Color3.fromRGB(255, 255, 0)

-- Money's waiting: a finished skewer to claim off the grill, the sell stall with one in hand.
Highlights.CLAIM = Color3.fromRGB(255, 205, 65)

-- Seconds for one half of the breath (dim -> bright); the tween reverses, so a full cycle is twice
-- this. Higher = a slow, calm pulse. Lower = urgent, and past about 0.4 it reads as a flicker.
Highlights.BREATHE_DURATION = 1

-- The outline's range. Lower = brighter. OUTLINE_DIM at 1 would fade the outline out completely at
-- the bottom of each breath, which reads as blinking rather than breathing.
Highlights.OUTLINE_DIM = 0
Highlights.OUTLINE_BRIGHT = 0

-- The fill's range, kept faint so the object's own colours still show through.
Highlights.FILL_DIM = 0.6
Highlights.FILL_BRIGHT = 0.9

return Highlights
