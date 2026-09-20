-- Services
local SocialService = game:GetService("SocialService")

-- Controllers
local NotificationController = require(script.Parent.NotificationController)

-- The mailbox prop the prompt hangs off, under workspace.Core.
local MAILBOX_NAME = "Mailbox"

-- How long the mailbox gets to replicate before the prompt is given up on
local MAILBOX_TIMEOUT = 10

local PROMPT_ACTION_TEXT = "Leave Feedback"

-- Matched to the other fixed props rather than the roomier NPC prompts
local PROMPT_DISTANCE = 10

-- Held rather than tapped, so brushing past the mailbox doesn't throw the dialog up
local PROMPT_HOLD = 0.3

-- Roblox takes one submission per player per day and says so itself, so this only covers the dialog never opening
local FAILURE_TEXT = "Couldn't open feedback right now"

-- The Leave Feedback mailbox: opens Roblox's own feedback dialog, which files what they write to the experience's Creator Dashboard.
local FeedbackController = {
	-- The dialog call yields, so a second press while it's up would stack another open behind it
	_prompting = false,
}

-- Opens Roblox's feedback dialog for the local player. Yields, and throws when the client refuses it.
function FeedbackController:OpenFeedbackPrompt()
	if self._prompting then
		return
	end

	self._prompting = true

	local success, err = pcall(function()
		SocialService:PromptFeedbackSubmissionAsync()
	end)

	self._prompting = false

	if not success then
		warn(`[Feedback] The feedback dialog wouldn't open: {err}`)
		NotificationController:NotifyNormal({ Text = FAILURE_TEXT, Effect = "Error" })
	end
end

-- Puts the prompt on the world's mailbox, straight to the dialog with no gating.
function FeedbackController:_setupMailbox()
	local mailbox = workspace:WaitForChild("Core"):WaitForChild(MAILBOX_NAME, MAILBOX_TIMEOUT)
	if not mailbox then
		warn(`[Feedback] No Core.{MAILBOX_NAME} in the place file, so there's no {PROMPT_ACTION_TEXT} prompt`)
		return
	end

	-- On a part rather than the model, since a prompt parented to a Model never fires at all
	local promptParent = if mailbox:IsA("Model")
		then mailbox.PrimaryPart or mailbox:FindFirstChildWhichIsA("BasePart", true)
		else mailbox

	if not promptParent then
		warn(`[Feedback] Core.{MAILBOX_NAME} has no part to hang the prompt on`)
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = PROMPT_ACTION_TEXT
	prompt.HoldDuration = PROMPT_HOLD
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.Parent = promptParent

	prompt.Triggered:Connect(function()
		self:OpenFeedbackPrompt()
	end)
end

function FeedbackController:OnStart()
	-- Off this thread, since the wait above yields and the loader runs every OnStart on one
	task.spawn(function()
		self:_setupMailbox()
	end)
end

return FeedbackController
