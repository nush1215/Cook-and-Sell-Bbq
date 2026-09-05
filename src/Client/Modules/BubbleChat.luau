-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

-- Shared
local Shared = ReplicatedStorage.Shared
local RandomUtil = require(Shared.RandomUtil)
local NpcDialogue = require(Shared.Config.NpcDialogue)

-- Fallback if the game has no BubbleChatConfiguration to read a duration from.
local DEFAULT_BUBBLE_DURATION = 1.5

-- Client-side chat bubbles for any part, wrapping TextChatService and the NpcDialogue config. Returns the bubble's duration, there being no bubble-ended event.

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

-- Speaks a random line from `category` above `part`, returning the bubble duration. An optional `variant` draws from its sibling category when one exists.
function BubbleChat.SayRandom(part: BasePart, category: string, variant: string?): number?
	local lines = NpcDialogue.GetLines(category, variant)
	if not lines or #lines == 0 then
		return nil
	end

	return BubbleChat.Say(part, RandomUtil.GetRandomFromArray(lines))
end

return BubbleChat
