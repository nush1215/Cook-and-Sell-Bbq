--[[

████████████████████████████████████████████████████████████╗
╚═══════════════════════════════════════════════════════════╝

 ██████╗ ██████╗ ███╗   ██╗████████╗███████╗██╗  ██╗████████╗
██╔════╝██╔═══██╗████╗  ██║╚══██╔══╝██╔════╝╚██╗██╔╝╚══██╔══╝
██║     ██║   ██║██╔██╗ ██║   ██║   █████╗   ╚███╔╝    ██║   
██║     ██║   ██║██║╚██╗██║   ██║   ██╔══╝   ██╔██╗    ██║   
╚██████╗╚██████╔╝██║ ╚████║   ██║   ███████╗██╔╝ ██╗   ██║   
 ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝   ╚═╝   ╚══════╝╚═╝  ╚═╝   ╚═╝   
                                                             
        █████╗  ██████╗████████╗██╗ ██████╗ ███╗   ██╗              
       ██╔══██╗██╔════╝╚══██╔══╝██║██╔═══██╗████╗  ██║              
       ███████║██║        ██║   ██║██║   ██║██╔██╗ ██║              
       ██╔══██║██║        ██║   ██║██║   ██║██║╚██╗██║              
       ██║  ██║╚██████╗   ██║   ██║╚██████╔╝██║ ╚████║              
       ╚═╝  ╚═╝ ╚═════╝   ╚═╝   ╚═╝ ╚═════╝ ╚═╝  ╚═══╝              
                                                             
     ██╗   ██╗████████╗██╗██╗     ██╗████████╗██╗   ██╗           
     ██║   ██║╚══██╔══╝██║██║     ██║╚══██╔══╝╚██╗ ██╔╝           
     ██║   ██║   ██║   ██║██║     ██║   ██║    ╚████╔╝            
     ██║   ██║   ██║   ██║██║     ██║   ██║     ╚██╔╝             
     ╚██████╔╝   ██║   ██║███████╗██║   ██║      ██║              
      ╚═════╝    ╚═╝   ╚═╝╚══════╝╚═╝   ╚═╝      ╚═╝                


████████████████████████████████████████████████████████████╗
╚═══════════════════════════════════════════════════════════╝
 
▪ 𝐂𝐨𝐧𝐭𝐞𝐱𝐭𝐀𝐜𝐭𝐢𝐨𝐧𝐔𝐭𝐢𝐥𝐢𝐭𝐲 𝐀𝐏𝐈
	▪ Properties
		▪ bool Archivable
		▪ string ClassName
		▪ string Name
		▪ Instance Parent
	▪ Functions
		▪ BindAction(string actionName, Function functionToBind, bool createTouchButton, Tuple inputTypes)
		▪ BindActionAtPriority(string actionName, Function functionToBind, bool createTouchButton, int priorityLevel, Tuple inputTypes)
		▪ UnbindAction(String actionName)
		▪ DisableAction(string actionName)
			▪ Disables action and disconnects events. Works the same as UnbindAction but the button stays.
			▪ DisableAction is a bit wonky right now.
		▪ SetTitle(string actionName, string title)
		▪ SetImage(string actionName, string image)
		▪ SetPressedColor(string actionName, Color3 color)
			▪ Sets the pressed color of the button.
		▪ SetReleasedColor(string actionName, Color3 color)
			▪ Sets the released color of the button.
		▪ GetButton(string actionName)
		▪ MakeButtonRound(actionName, amount)
			▪ Changes the shape and interaction area of the button.
		▪ MakeButtonSquare(actionName)
			▪ Changes the shape and interaction area of the button.
	▪ Events
		▪ LocalToolEquipped(Instance toolEquipped)
		▪ LocalToolUnequipped(Instance toolUnequipped)


████████████████████████████████████████████████████████████╗
╚═══════════════════════════════════════════════════════════╝

▪ 𝐈𝐧𝐟𝐨𝐫𝐦𝐚𝐭𝐢𝐨𝐧

	▪ Written by PseudoPerson
		▪ https://www.roblox.com/users/1735621911/profile
	▪ CC BY License (https://creativecommons.org/licenses/by/4.0)
		▪ Summary: Do what ever you want with the module as long as credit is in the code :)
	▪ Developer Forum Post: https://devforum.roblox.com/t/easy-mobile-buttons-contextactionutility/804219
	▪ Cancel UserInputState may not always fire. This is untested.


████████████████████████████████████████████████████████████╗
╚═══════════════════════════════════════════════════════════╝

▪ 𝐕𝐞𝐫𝐬𝐢𝐨𝐧

	▪ v.0.20.10.3


████████████████████████████████████████████████████████████╗
╚═══════════════════════════════════════════════════════════╝

▪ 𝐑𝐞𝐬𝐨𝐮𝐫𝐜𝐞𝐬

	▪ Buttons
		▪ Default Button:   rbxassetid://5713982324
		▪ Read Button:      rbxassetid://5743592925
		▪ Attack Button:    rbxassetid://5743593320
		▪ Target Button:    rbxassetid://5743593654
		▪ Hamburger Button: rbxassetid://5743594013
		▪ ! Button:         rbxassetid://5754149564
		▪ ? Button:         rbxassetid://5754150372
		▪ ... Button:       rbxassetid://5754151192
		▪ - Button:         rbxassetid://5754152113
		▪ + Button:         rbxassetid://5754152510
		▪ Cancel Button:    rbxassetid://5754151652
		▪ Speech Button:    rbxassetid://5754152998
		▪ Star Button:      rbxassetid://5754153324
		▪ Sword Button:     rbxassetid://5754154247
		▪ Sun Button:       rbxassetid://5754154839
	▪ Developer Forum Post With Vector Images
		▪ https://devforum.roblox.com/t/easy-mobile-buttons-contextactionutility/804219


████████████████████████████████████████████████████████████╗
╚═══════════════════════════════════════════════════════════╝

]]

--// 𝐌𝐨𝐝𝐮𝐥𝐞 𝐓𝐚𝐛𝐥𝐞 //--
local ContextActionUtility = {}

--// 𝐒𝐞𝐫𝐯𝐢𝐜𝐞𝐬 //--
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Players = game:GetService("Players")

--// 𝐕𝐚𝐫𝐢𝐚𝐛𝐥𝐞𝐬 //--
--player
local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local TouchGui
local TouchControlFrame
local JumpButton

--mobile
local isMobile = UserInputService.TouchEnabled
if isMobile then
	TouchGui = PlayerGui:WaitForChild("TouchGui")
	TouchControlFrame = TouchGui:WaitForChild("TouchControlFrame")
	JumpButton = TouchControlFrame:WaitForChild("JumpButton")
end

--{actionName = {Name, Button, Slot, Connections}}
local Buttons = {}

--⚫ This can be changed. The indexes are the fill priority (1 being the highest priority).
--1.1x
local ButtonPositions = {
	[1] = UDim2.new(-0.4169, 0, 0.715, 0),
	[2] = UDim2.new(-0.165, 0, -0.165, 0),
	[3] = UDim2.new(0.715, 0, -0.4169, 0),
	[4] = UDim2.new(-1.1077, 0, -0.0396, 0),
	[5] = UDim2.new(-0.858, 0, -0.858, 0),
	[6] = UDim2.new(-0.0396, 0, -1.1077, 0),
}

--// 𝐅𝐮𝐧𝐜𝐭𝐢𝐨𝐧𝐬 //--
local function GetNextSlot()
	local takenSlots = {}
	--Loop makes a table with button slot numbers as indexes
	for actionName, buttonData in pairs(Buttons) do
		takenSlots[buttonData.Slot] = true
	end
	--Loop looks for first open slot
	for i = 1, #ButtonPositions do
		if not takenSlots[i] then
			--Returns first open slot
			return i
		end
	end
	--If no open slot is found function returns nil
	return nil
end

local function ConnectButton(actionName, functionToBind)
	local data = Buttons[actionName]
	local button = data.Button
	local connections = data.Connections or {}

	local function inputBeganHandler(inputObject)
		--Feeds correct input into the function
		functionToBind(actionName, Enum.UserInputState.Begin, inputObject)
		button.ImageColor3 = button.BorderColor3
		local title = button:FindFirstChild("title")
		if title then
			title.TextColor3 = button.BorderColor3
		end
	end
	connections.Begin = button.InputBegan:Connect(inputBeganHandler)

	local function inputChangedHandler(inputObject)
		--Feeds correct input into the function
		functionToBind(actionName, Enum.UserInputState.Change, inputObject)
	end
	connections.Changed = button.InputChanged:Connect(inputChangedHandler)

	local function inputEndedHandler(inputObject)
		--Feeds correct input into the function
		functionToBind(actionName, Enum.UserInputState.End, inputObject)
		button.ImageColor3 = button.BackgroundColor3
		local title = button:FindFirstChild("title")
		if title then
			title.TextColor3 = button.BackgroundColor3
		end
	end
	connections.MenuOpened = GuiService.MenuOpened:Connect(inputEndedHandler)
	connections.End = button.InputEnded:Connect(inputEndedHandler)

	--Roblox touch support is wonky. This makes it so it (probably) always looks right.
	local function mouseLeaveHandler()
		button.ImageColor3 = button.BackgroundColor3
		local title = button:FindFirstChild("title")
		if title then
			title.TextColor3 = button.BackgroundColor3
		end
	end
	button.MouseLeave:Connect(mouseLeaveHandler)
end

local function DisconnectButton(actionName)
	local data = Buttons[actionName]
	if not data.Connections then
		return
	end
	for i, p in pairs(data.Connections) do
		if p then
			p:Disconnect()
		end
	end
	--Will do some testing to see if this is needed ¯\_(ツ)_/¯
	data.Connections = {}
end

local function newDefaultButton(actionName, slot)
	local newButton
	newButton = Instance.new("ImageButton")
	newButton.Name = actionName .. "Button"
	newButton.BackgroundTransparency = 1
	newButton.Size = UDim2.new(0.8, 0, 0.8, 0)
	newButton.Image = "rbxassetid://5713982324"
	newButton.ImageTransparency = 0.5
	newButton.AnchorPoint = Vector2.new(0.5, 0.5)
	--Used for unactived color
	newButton.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	--Used for activated color
	newButton.BorderColor3 = Color3.fromRGB(125, 125, 125)

	--Without this the jump button locks in the jump state because the input ends incorrectly. Dont let the button hitboxes overlap the jump button hit box.
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = newButton

	newButton.Position = ButtonPositions[slot]
	return newButton
end

local function BindButton(actionName, functionToBind)
	local button
	local slot
	local data = Buttons[actionName]
	if data then
		if data.Connections then
			DisconnectButton(actionName)
		end
		if data.Slot then
			slot = data.Slot
		else
			slot = GetNextSlot()
		end
		if data.Button then
			button = data.Button
			--Will do some testing to see if this is needed ¯\_(ツ)_/¯
			button.ImageColor3 = button.BackgroundColor3
			local title = button:FindFirstChild("title")
			if title then
				title.TextColor3 = button.BackgroundColor3
			end
		else
			button = newDefaultButton(actionName, slot)
		end
	else
		slot = GetNextSlot()
		button = newDefaultButton(actionName, slot)
	end

	button.Parent = JumpButton

	Buttons[actionName] = { ["Name"] = actionName, ["Button"] = button, ["Slot"] = slot, ["Connections"] = {} }
	--Should I use OOP? Probably. Am I using Lua's weird table based OOP? No.
	ConnectButton(actionName, functionToBind)
end

local function UnbindButton(actionName)
	--Gets button data
	local data = Buttons[actionName]
	if not data then
		return
	end
	--Disconnects connections
	DisconnectButton(actionName)
	if data.Button then
		data.Button:Destroy()
	end
	--Need to test if this line will do everything. I believe this leaks or something b|c it's just parenting the data to nil.
	Buttons[actionName] = nil
end

local function DisableButton(actionName)
	local data = Buttons[actionName]
	DisconnectButton(actionName)

	local button = data.Button
	button.ImageColor3 = button.BackgroundColor3
	local title = button:FindFirstChild("title")
	if title then
		title.TextColor3 = button.BackgroundColor3
	end
end

--Default jump button can get stuck in the down position. Using a newish ui thing to fix this
local function FixDefaultJumpButton()
	--Removes the corners of the button interaction hitbox so button cant lock
	local uiCorner = Instance.new("UICorner")
	uiCorner.CornerRadius = UDim.new(0.5, 0)
	uiCorner.Parent = JumpButton
end
FixDefaultJumpButton() --Little unorganized to call this here but ¯\_(ツ)_/¯

--// 𝐌𝐨𝐝𝐮𝐥𝐞 𝐕𝐚𝐫𝐢𝐚𝐛𝐥𝐞𝐬 //--
--Properties
ContextActionUtility.Archivable = ContextActionService.Archivable
ContextActionUtility.ClassName = ContextActionService.ClassName
ContextActionUtility.Name = ContextActionService.Name
ContextActionUtility.Parent = ContextActionService.Parent

--Events
ContextActionUtility.LocalToolEquipped = ContextActionService.LocalToolEquipped
ContextActionUtility.LocalToolUnequipped = ContextActionService.LocalToolUnequipped

--// 𝐌𝐨𝐝𝐮𝐥𝐞 𝐅𝐮𝐧𝐜𝐭𝐢𝐨𝐧𝐬 //--
function ContextActionUtility:BindAction(actionName, functionToBind, createTouchButton, ...)
	ContextActionService:BindAction(actionName, functionToBind, false, ...)
	if createTouchButton and isMobile then
		BindButton(actionName, functionToBind)
	end
end

function ContextActionUtility:BindActionAtPriority(actionName, functionToBind, createTouchButton, priorityLevel, ...)
	ContextActionService:BindAction(actionName, functionToBind, false, priorityLevel, ...)
	if createTouchButton and isMobile then
		BindButton(actionName, functionToBind)
	end
end

function ContextActionUtility:UnbindAction(actionName)
	ContextActionService:UnbindAction(actionName)
	if isMobile then
		UnbindButton(actionName)
	end
end

--Added functionality: Disconnects events but the button stays. Effects that can be chosen: Shrink alpha, Fade alpha, Darken alpha
function ContextActionUtility:DisableAction(actionName, effectList)
	ContextActionService:UnbindAction(actionName)
	if isMobile then
		DisableButton(actionName, effectList)
	end
end

function ContextActionUtility:SetTitle(actionName, title)
	local data = Buttons[actionName]
	if not data then
		return
	end
	if not title then
		title = actionName
	end
	local button = data.Button
	if not button then
		return
	end
	local textLabel = button:FindFirstChild("title")
	if not textLabel then
		textLabel = Instance.new("TextLabel")
		textLabel.Name = "title"
		textLabel.AnchorPoint = Vector2.new(0.5, 0.5)
		textLabel.Position = UDim2.new(0.5, 0, 0.5, 0)
		textLabel.BackgroundTransparency = 1
		textLabel.Size = UDim2.new(0.75, 0, 0.45, 0)
		textLabel.Font = Enum.Font.SourceSansBold
		textLabel.TextScaled = true
		textLabel.TextTransparency = 0
		-- fromRGB, not new: Color3.new takes 0-1, so the original's 255s were only white by clamping.
		textLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		textLabel.TextXAlignment = Enum.TextXAlignment.Center
		textLabel.TextYAlignment = Enum.TextYAlignment.Center
	end
	textLabel.Visible = true
	textLabel.Text = title
	textLabel.Parent = button
end

function ContextActionUtility:SetImage(actionName, image)
	local data = Buttons[actionName]
	if not data then
		return
	end
	data.Button.Image = image
end

--Added functionality: Color of pressed button.
function ContextActionUtility:SetPressedColor(actionName, color)
	local data = Buttons[actionName]
	if not data then
		return
	end
	local button = data.Button
	if not button then
		return
	end
	button.BorderColor3 = color
end

--Added functionality: Color of released button
function ContextActionUtility:SetReleasedColor(actionName, color)
	local data = Buttons[actionName]
	if not data then
		return
	end
	local button = data.Button
	if not button then
		return
	end
	button.ImageColor3 = color
	button.BackgroundColor3 = color
	local title = button:FindFirstChild("title")
	if title then
		title.TextColor3 = color
	end
end

--Added functionality: Shape of button and interaction box
function ContextActionUtility:MakeButtonSquare(actionName)
	local data = Buttons[actionName]
	if not data then
		return
	end
	local button = data.Button
	if not button then
		return
	end

	local corner = button:FindFirstChildOfClass("UICorner")
	if corner then
		corner.CornerRadius = UDim.new(0, 0)
	end
end

--Added functionality: Shape of button and interaction box
function ContextActionUtility:MakeButtonRound(actionName, amount)
	local data = Buttons[actionName]
	if not data then
		return
	end
	local button = data.Button
	if not button then
		return
	end

	local corner = button:FindFirstChildOfClass("UICorner")
	if not corner then
		local corner = Instance.new("UICorner", button)
	end
	if not amount then
		amount = 0.5
	end
	corner.CornerRadius = UDim.new(amount, 0)
end

function ContextActionUtility:GetButton(actionName)
	local data = Buttons[actionName]
	if not data then
		return nil
	end
	return data.Button
end

return ContextActionUtility
