-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Network
local Network = require(ReplicatedStorage.Shared.Network)

--
export type CountData = {
	Value: number,
	Duration: number?,
	Format: ("Price" | "Suffix" | "Comma")?,
	Color: Color3?,
}

export type NotificationData = {
	Text: string,
	Duration: number?,
	Sound: string?,
	Scale: number?,
	Effect: ("Error" | "Success")?,
	Count: CountData?,
}

export type ItemNotificationData = {
	Title: string,
	Description: string?,
	Duration: number?,
	Color: Color3,
	Icon: string,
}

--
local NotificationManager = {
	NotifyNormalEvent = Network.Event("NotifyNormal"),
	NotifyChatEvent = Network.Event("NotifyChat"),
	NotifyItemEvent = Network.Event("NotifyItem"),
}

-- Shows a normal notification to the player.
function NotificationManager:NotifyNormal(player: Player, data: NotificationData)
	self.NotifyNormalEvent:FireClient(player, data)
end

-- Shows a normal notification to every player, for server-wide events (shop restocks and the like).
function NotificationManager:NotifyNormalAll(data: NotificationData)
	self.NotifyNormalEvent:FireAllClients(data)
end

-- Adds a notification to the player's chat.
function NotificationManager:NotifyChat(player: Player, text: string)
	self.NotifyChatEvent:FireClient(player, text)
end

-- Adds a notification to every player's chat.
function NotificationManager:NotifyChatAll(text: string)
	self.NotifyChatEvent:FireAllClients(text)
end

-- Shows an item unlock notification to the player.
function NotificationManager:NotifyItem(player: Player, data: ItemNotificationData)
	self.NotifyItemEvent:FireClient(player, data)
end

return NotificationManager
