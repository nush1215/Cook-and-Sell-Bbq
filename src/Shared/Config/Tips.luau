-- The hints rotated into a player's chat, each one a mechanic the game never states outright. Every number here is quoted from another config -- see docs/balance.md before changing one.

--
local Tips = {}

-- Seconds before a player's first tip, long enough to clear the tutorial's opening beats
Tips.INITIAL_DELAY = 60

-- Seconds between tips after that; over this list it's a full rotation in a little under an hour
Tips.INTERVAL = 120

-- What every line opens with, so a tip reads apart from the system messages it shares a channel with
Tips.PREFIX = "💡 Tip: "

-- Grouped by what they teach, though they're shuffled per player. Keywords and numbers colour themselves -- see Config.Keywords
Tips.Data = {
	-- Cooking
	"Pull your BBQ off in the green band for a Perfect cook — it sells for 1.4x",
	"Leave a BBQ on past the bar and it chars — a Charred BBQ sells for less than a Raw one",
	"Hold the prompt to pull a Raw BBQ off early — the cook is banked, not lost",
	"The Perfect window never runs longer than 45 seconds, however long the cook",
	"More Grillers means more BBQs cooking at once",
	"Your BBQs keep cooking while you're offline — log back in to a grill that's nearly there",
	"An offline cook parks just short of Perfect, so the window is always yours to hit",

	-- Selling
	"Turn a Customer down and they may come back higher — a Perfect BBQ gets pushed the furthest",
	"A Customer will only sweeten their offer 3 times",
	"Decline too many Customers and every offer drops for a minute",
	"Customers only wait 30 seconds for an answer before walking off",

	-- Rating
	"Your Rating sign scores you out of 5 stars on Cooking, Satisfaction, Menu and Kitchen",
	"Selling the same ingredient forever hurts your Menu rating — 12 different ones keeps it full",
	"Filling every slot on your Stick counts toward your Menu rating",
	"Upgrades alone can't buy a Rating — your stars are capped by how well you actually cook",
	"Cooking and Satisfaction are 65% of your Rating — Menu and Kitchen are the rest",
	"Visit another player's base to see their Rating sign",

	-- Custom orders
	"Custom orders pay up to 1.3x — but only for an exact fill",
	"Padding a custom order with ingredients nobody asked for cuts the payout",
	"Custom order Customers won't visit until you own 2 Grillers or 2 rolling stands",

	-- Economy
	"Every friend in the server is +10% income, up to +100%",
	"New players earn +50% income, fading out as you get richer",
	"The x2 Bux gamepass doubles every sale, forever",

	-- Discovery
	"Redeem the code RELEASE for a free Wooden Stick, Tomato and Zucchini",
	"The Leaderboards near spawn track the richest, the most sales and the most playtime",
	"Check the Gift button for a free reward if you're in the group",
	"The Index tracks every ingredient you've discovered",
}

table.freeze(Tips.Data)

return Tips
