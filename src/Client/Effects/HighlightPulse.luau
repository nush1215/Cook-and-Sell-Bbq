-- Services
local TweenService = game:GetService("TweenService")

--
-- `pulses` splits the duration into that many fades, so the model blinks rather than dimming once. Defaults to one.
return function(model: Model | BasePart, color: Color3, duration: number, startTransparency: number, pulses: number?)
	local pulseCount = pulses or 1

	local highlight = Instance.new("Highlight")
	highlight.OutlineTransparency = 1
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillTransparency = startTransparency
	highlight.FillColor = color
	highlight.Parent = model

	-- Quad/Out is TweenInfo's own default, spelled out here only so the repeat count can be passed.
	local tweenInfo =
		TweenInfo.new(duration / pulseCount, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, pulseCount - 1)
	TweenService:Create(highlight, tweenInfo, { FillTransparency = 1 }):Play()

	task.delay(duration, function()
		highlight:Destroy()
	end)
end
