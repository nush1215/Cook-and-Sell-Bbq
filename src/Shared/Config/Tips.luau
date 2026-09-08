-- The hints rotated into a player's chat, each one a mechanic the game never states outright. Every number here is quoted from another config -- see docs/balance.md before changing one.
-- Written for a young audience: short lines, plain words, and the in-game name for anything they have to go and find.

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
	"Take your BBQ off while the bar is green! A Perfect cook sells for 1.4x",
	"Leave a BBQ on too long and it burns. Charred sells for even less than Raw!",
	"Need to stop early? Hold the button and your BBQ keeps the cooking it already did",
	"The green part of the bar is never longer than 45 seconds, so stay close!",
	"More Grillers means more BBQs cooking at the same time",
	"Your BBQs keep cooking while you're away! Come back to an almost finished grill",
	"BBQs cooked while you're away stop just before the green, so you never miss it",

	-- Selling
	"Say no to a Customer and they might offer more! Perfect BBQs get the biggest jump",
	"A Customer will only raise their offer 3 times, so don't get too greedy",
	"Saying no too often makes every offer smaller for a minute",
	"Customers only wait 30 seconds for an answer, then they walk away!",

	-- Rating
	"Your Rating sign gives you up to 5 stars for Cooking, Satisfaction, Menu and Kitchen",
	"Selling the same ingredient over and over lowers your Menu stars. Try 12 different ones!",
	"Fill every slot on your Stick to help your Menu stars",
	"You can't buy 5 stars with upgrades. You have to cook well too!",
	"Cooking and Satisfaction are 65% of your Rating. Menu and Kitchen are the rest",
	"Visit another player's base to see their Rating sign",

	-- Custom orders
	"Custom orders pay up to 1.3x, but only if you get the order exactly right",
	"Adding ingredients nobody asked for pays you less. Stick to the order!",
	"Custom order Customers turn up once you own 2 Grillers or 2 rolling stands",

	-- Economy
	"Play with friends! Every friend in the server gives you +10% income, up to +100%",
	"New players get +50% income. It fades as you get richer, so make the most of it",
	"The x2 Bux gamepass doubles every sale you ever make",

	-- Discovery
	"Type the code RELEASE for a free Wooden Stick, Tomato and Zucchini!",
	"The Leaderboards near spawn show who is richest, who sells most and who plays most",
	"In the group? Check the Gift button for a free reward",
	"The Index shows every ingredient you have found so far",
}

table.freeze(Tips.Data)

return Tips
