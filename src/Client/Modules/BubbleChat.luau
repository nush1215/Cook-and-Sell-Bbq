-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

-- Shared
local Shared = ReplicatedStorage.Shared
local RandomUtil = require(Shared.RandomUtil)
local NpcDialogue = require(Shared.Config.NpcDialogue)

-- Fallback if the game has no BubbleChatConfiguration to read a duration from.
local DEFAULT_BUBBLE_DURATION = 1.5

--[[
    Reusable client-side chat bubbles for NPCs (or any part). Wraps TextChatService:DisplayBubble and the
    NpcDialogue config, so any system can make a part speak: BubbleChat.Say(part, "hi") for a literal line,
    BubbleChat.SayRandom(part, "NPCDeciding") for a random line from a dialogue category, or a third
    argument to draw from that category's variant for some state (e.g. "Overcooked").

    Both return how long the bubble stays up (the game's BubbleChatConfiguration.BubbleDuration), since
    there's no bubble-ended event -- callers that react to a bubble appearing (e.g. lifting a UI above it)
    use this to know when it's gone.
]]

--
local BubbleChat = {}

-- How long a bubble stays up, per the game's BubbleChatConfiguration (or the fallback).
local function getBubbleDuration(): number
	local config = TextChatService:FindFirstChildOfClass("BubbleChatConfiguration")
	return if config then config.BubbleDuration else DEFAULT_BUBBLE_DURATION
end

-- Shows a chat bubble with `message` above `part`, returning how long it will stay up.
function BubbleChat.Say(part: BasePart, message: string): number
	TextChatService:DisplayBubble(part, message)
	return getBubbleDuration()
end

-- Shows a random line from the NpcDialogue `category` above `part`, returning the bubble duration. An
-- optional `variant` draws from that category's `{category}{variant}` sibling when it has one, so a
-- caller can colour every line it speaks by some state of its own (the sell customer passes the cook
-- state of the skewer it's holding) without knowing which beats actually vary. Does nothing (returns
-- nil) if the category is missing or empty.
function BubbleChat.SayRandom(part: BasePart, category: string, variant: string?): number?
	local lines = NpcDialogue.GetLines(category, variant)
	if not lines or #lines == 0 then
		return nil
	end

	return BubbleChat.Say(part, RandomUtil.GetRandomFromArray(lines))
end

return BubbleChat
