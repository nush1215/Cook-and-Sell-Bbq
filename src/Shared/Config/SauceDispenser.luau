-- Dormant while sauce dispensers are postponed -- un-comment alongside SauceDispenserManager.

--[==[
-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Assets
local Assets = ReplicatedStorage.Assets
local SauceBottlesFolder = Assets.SauceBottles

--
export type Size = {
	Id: string, -- also the name of the model under Assets.SauceBottles
	Cost: number, -- what it costs to upgrade *to* this size (Small comes with the unlock)
	Capacity: number, -- how many skewers this size can sauce before it runs dry (one each)
	Model: Model, -- not authored below, back-filled from Assets.SauceBottles
}

--
local SauceDispenser = {}

-- The size a dispenser starts at the moment it's unlocked.
SauceDispenser.DEFAULT_SIZE = "Small"

-- Seconds after a pour starts that the sauce lands on the skewer: the server stamps the start and
-- schedules the finish on this. The client's bottle animation is self-timed (SauceDispenserController
-- plays it off its own phase constants), so this just wants to fall while the bottle is dabbing --
-- around when the pour reads as "applying" -- rather than driving the animation's length.
SauceDispenser.SAUCE_DURATION = 2

-- Ordered smallest to largest: a dispenser upgrades to the next entry in this list. Cost is what
-- the *upgrade into* that size costs, so Small's is never read (it comes free with the unlock).
SauceDispenser.Sizes = {
	{ Id = "Small", Cost = 0, Capacity = 25 },
	{ Id = "Medium", Cost = 20_000, Capacity = 60 },
	{ Id = "Large", Cost = 75_000, Capacity = 150 },
	{ Id = "Huge", Cost = 250_000, Capacity = 400 },
}

-- Each size pulls its own model out of Assets.SauceBottles, matched on Id. A size whose model is
-- missing gets dropped rather than left half-built, so a bad Id can't be rendered onto a dispenser
-- and then error mid-swap.
for index = #SauceDispenser.Sizes, 1, -1 do
	local size = SauceDispenser.Sizes[index]
	local model = SauceBottlesFolder:FindFirstChild(size.Id)

	if not model then
		warn(`Sauce dispenser size {size.Id} has no model in Assets.SauceBottles, it won't render`)
		table.remove(SauceDispenser.Sizes, index)
		continue
	end

	size.Model = model
end

table.freeze(SauceDispenser.Sizes)

function SauceDispenser.GetSizeFromId(id: string): Size?
	for _, size in SauceDispenser.Sizes do
		if size.Id == id then
			return size
		end
	end

	return nil
end

function SauceDispenser.GetSizeIndex(id: string): number?
	for index, size in SauceDispenser.Sizes do
		if size.Id == id then
			return index
		end
	end

	return nil
end

-- Returns the size a dispenser at the given size upgrades into, or nil if it's already the largest.
function SauceDispenser.GetNextSize(id: string): Size?
	local index = SauceDispenser.GetSizeIndex(id)
	if not index then
		return nil
	end

	return SauceDispenser.Sizes[index + 1]
end

return SauceDispenser
]==]

return {}
