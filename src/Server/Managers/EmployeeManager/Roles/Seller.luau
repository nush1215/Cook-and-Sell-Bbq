-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Managers
local Managers = script.Parent.Parent.Parent
local PlayerDataManager = require(Managers.PlayerDataManager)
local SellNpcManager = require(Managers.SellNpcManager)

-- Shared
local Shared = ReplicatedStorage.Shared
local Employees = require(Shared.Config.Employees)
local Rating = require(Shared.Config.Rating)

-- Said while minding a stall with nothing on it, which is a different thing from minding a busy one
local EMPTY_VARIANT = "Empty"

-- How long it stays with a customer after closing, just long enough to see them off. Short on purpose: a
-- seller tied up for the whole eat would fall behind a queue that arrives faster than that
local FAREWELL_DELAY = 2

-- The seller: stands its post at the stall and answers customers. Its star is judgement -- how well it reads whether pushing for more beats the risk of the customer walking. It never pushes into a losing bet, so a poor one only ever leaves money on the table rather than costing a sale.

--
local Seller = {}

-- Where a fresh seller starts: on its post. It has no Idle of its own -- minding the stall is the idle
Seller.Initial = "Post"

-- Whether a seller of `skill` turning `record`'s offer down beats taking it. A walk-off doesn't cost the sale -- the skewers go back on the stand for the next customer -- so what's at risk is the wait for that customer, not the money on the table.
function Seller.ShouldPush(skill: number, record): boolean
	-- Under the first mark it never haggles, and the customer's own cap ends it either way
	local rounds = Employees.GetTierFromStars(Employees.SELL_PUSH_MARKS, Rating.ToStars(skill))
	if record.counterRounds >= math.min(rounds, record.maxCounterRounds) then
		return false
	end

	-- What one more round is worth: the headroom left to the customer's cap, at their own average step
	local headroom = record.value * record.counterCap - record.offer
	if headroom <= 0 then
		return false
	end

	local gain = headroom * (record.counterIncreaseMin + record.counterIncreaseMax) / 2
	local chance = math.clamp(record.counterChance / 100, 0, 1)

	-- What a walk-off really costs: this customer gone and the stall idle until the next one turns up
	local risk = record.offer * Employees.SELL_WALK_COST

	-- The margin is the whole "never worse than none" guarantee: a cautious seller demands a bigger edge
	-- before gambling, and being too cautious just means it accepted, which was always a safe outcome
	local margin = Employees.InterpolateBySkill(
		Employees.SELL_MARGIN_WORST,
		Employees.SELL_MARGIN_BEST,
		Employees.SELL_MARGIN_GAMMA,
		skill
	)

	return chance * gain > (1 - chance) * risk * (1 + margin)
end

-- How far along the counter this seller stands, in studs either side of the post. The first is left on the authored spot and the rest alternate out from it, so hiring a second never moves the one already there.
local function getSlotOffset(employee): number
	local index = employee:GetRoleIndex()
	local step = math.floor(index / 2) * Employees.POST_SPACING

	return if index % 2 == 0 then step else -step
end

-- Where it stands when there's nothing doing. The authored post if the base has one, else the sell stall itself, so a base missing the part still gets a seller who goes and minds the counter.
local function getPostPosition(employee): Vector3?
	local offset = getSlotOffset(employee)

	-- Spread sideways rather than crowded onto one spot: staff pass through each other, so two on one post
	-- stand inside one another instead of jostling
	local post = employee:GetCorePart(Employees.SELLER_POST_PART)
	if post then
		return post.Position + post.CFrame.RightVector * offset
	end

	local stand = employee:GetSellStandPart()
	if not stand then
		return nil
	end

	return employee:GetApproachPosition(stand) + stand:GetPivot().RightVector * offset
end

-- Lets a customer go and puts the seller back on its post.
local function finishWith(employee, category: string): string
	local npc = employee._servingNpc

	if npc then
		npc:SetAttribute(Employees.SERVED_BY_ATTRIBUTE, nil)
	end

	employee._servingNpc = nil
	employee:Say(category)

	return "Post"
end

-- Stands the post and watches for a customer to answer. The stall is where its job is, so it never wanders off it.
Seller.Post = function(employee, now: number): string?
	local data = PlayerDataManager:GetLoadedPlayerData(employee.Player)
	if not data then
		return nil
	end

	-- An empty stand is worth saying out loud: it's the player's cue that the stall wants stocking
	employee:SetVariant(if #data.SkewerStand == 0 then EMPTY_VARIANT else nil)

	-- Solved once per walk: StepWalk holds the target, and re-measuring would re-arm the deadline every tick
	local post = employee._walkTarget or getPostPosition(employee)
	if post then
		local result = employee:StepWalk(now, post, Employees.POST_ARRIVE_DISTANCE)

		if result == "timeout" then
			-- A post isn't a job it can abandon. Every other state falls back to Idle on a bad route, but
			-- there's nothing under this one, so the target is dropped and the walk re-armed next tick
			employee._walkTarget = nil
		elseif result == "arrived" then
			-- Turned to face the lane customers queue in, so it isn't stood with its back to them.
			-- Only once there: facing mid-walk would spend the turn before it has somewhere to turn from
			local standPart = employee:GetCorePart("NPCStandPart")
			if standPart then
				employee:FaceTowards(standPart.Position)
			end
		end
	end

	-- The tutorial teaches the player to press Accept themselves; a seller answering would take that away
	if not data.TutorialCompleted or not employee:ShouldPoll(now) then
		return nil
	end

	local record = SellNpcManager:GetPendingOffer(employee.Player, employee.Uid)
	if not record then
		return nil
	end

	-- Stamped so a second seller doesn't race this one to the answer
	record.npc:SetAttribute(Employees.SERVED_BY_ATTRIBUTE, employee.Uid)

	employee._servingNpc = record.npc
	employee._answeredRound = nil
	employee._dwellRound = nil
	employee._closing = false

	employee:Say("Greet")

	return "Haggle"
end

-- Deals with one customer, round by round. Answering is all this does -- the sale itself stays the sell stall's, so the payout, the stats and the rating window are untouched. Its own pushes are the one exception: they're kept off the refusal ledger, which is a record of the player's own declining.
Seller.Haggle = function(employee, now: number): string?
	local npc = employee._servingNpc

	-- Gone: they bought and left, gave up, or the player answered it themselves while this one deliberated
	local record = npc and SellNpcManager:GetCustomerRecord(employee.Player, npc)
	if not record then
		-- Only a customer this employee itself pushed away gets the sour goodbye. One the player answered
		-- is none of its business, and crowing "your loss" over a sale they just took would read as a bug
		local lost = not employee._closing and employee._answeredRound ~= nil

		return finishWith(employee, if lost then "FarewellLost" else "Farewell")
	end

	employee:FaceTowards(npc:GetPivot().Position)

	-- Deal done: it saw them off rather than standing with them through the whole eat
	if employee._closing then
		return finishWith(employee, "Farewell")
	end

	-- Between rounds the customer is thinking, so there's nothing to answer yet
	if not record.offerPending or employee._answeredRound == record.counterRounds then
		return nil
	end

	-- Weighed for a beat first, which is what a slow seller is slow at. Step skips this handler while the
	-- dwell runs, so reaching here a second time on the same round means the thinking is done
	if employee._dwellRound ~= record.counterRounds then
		employee._dwellRound = record.counterRounds
		employee:Dwell(
			now,
			employee:GetCurveValue(
				Employees.SELL_DECIDE_WORST,
				Employees.SELL_DECIDE_BEST,
				Employees.SELL_DECIDE_GAMMA
			)
		)

		return nil
	end

	local push = Seller.ShouldPush(employee.Record.Skill, record)

	employee._answeredRound = record.counterRounds
	employee:Say(if push then "Push" else "Accept")
	SellNpcManager:AnswerOffer(employee.Player, npc, not push, employee.Uid)

	-- Taking the deal ends its part; a push leaves it here for whatever the customer comes back with
	if not push then
		employee._closing = true
		employee:Dwell(now, FAREWELL_DELAY)
	end

	return nil
end

return Seller
