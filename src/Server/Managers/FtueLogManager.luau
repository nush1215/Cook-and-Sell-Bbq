-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ConfigService = game:GetService("ConfigService")
local HttpService = game:GetService("HttpService")

-- Shared
local Shared = ReplicatedStorage.Shared
local Network = require(Shared.Network)

-- Managers
local PlayerDataManager = require(script.Parent.PlayerDataManager)
local TutorialManager = require(script.Parent.TutorialManager)

-- The experience config that turns all of this on, and the player attribute the client half reads it off
local CONFIG_KEY = "LogFTUE"

-- The Creator Hub secret holding the webhook's full URL. A secret rather than a constant, the repo being public
local WEBHOOK_SECRET = "FtueWebhook"

-- The funnel step a drop is reported at, and the one before it that puts a player on it (see TutorialManager)
local REPORTED_STEP = "Build Griller"
local REPORTED_STEP_ENTRY = "Equip Griller Tool"

-- Where the tutorial's guides are authored and the one this step points at (see TutorialController:ShowGuide)
local GUIDES_FOLDER_NAME = "TutorialGuides"
local GUIDE_NAME = "Grill"

-- Entries a trail holds before the oldest go. Repeats fold into one, so this is a long run
local MAX_TRAIL_ENTRIES = 80
-- Entries taken from one batch, which is also the most FtueLogController sends
local MAX_BATCH = 32
-- The client batches once a second, so an entry claiming to be older than this is lying or lagging
local MAX_ENTRY_AGE = 2
local MAX_DETAIL_LENGTH = 40

-- The fraction of new players a trail is kept for, and the most this server posts in a minute whatever that comes to
local SAMPLE_RATE = 1
local MAX_POSTS_PER_MINUTE = 5

-- Seconds a closing server waits on posts still in flight, and how long it first waits for one to appear --
-- the last player out queues their report from inside the shutdown, after the wait below has already started
local CLOSE_TIMEOUT = 5
local CLOSE_GRACE = 1

-- A config fetch that fails is a whole server that logs nothing for its lifetime, so it's retried rather than
-- given up on. Backed off per attempt, since the usual cause is a service still waking up
local CONFIG_FETCH_ATTEMPTS = 5
local CONFIG_RETRY_DELAY = 3

-- Stands in for a real recording's key, so a test report shows the footer line a real one carries
local TEST_REPLAY_KEY = "0_0"

local EMBED_COLOR = 0xDC4646
-- What a testFtueWebhook report wears instead, so a check can never be read as a real drop
local TEST_EMBED_COLOR = 0x46A0DC
-- Discord refuses an embed description past 4096 bytes
local MAX_DESCRIPTION_LENGTH = 3900

-- What the client may report, and whether that kind carries a detail. Anything else in a batch is dropped
local CLIENT_KINDS = {
	equip = true,
	unequip = false,
	ghost = true,
	click = true,
	rotate = false,
}

-- Enum.PreferredInput names as the report words them. Doubles as the whitelist for what the client claims to be on
local PLATFORM_NAMES = {
	KeyboardAndMouse = "Desktop",
	Touch = "Touch",
	Gamepad = "Gamepad",
}

-- How each kind reads in the timeline, and what a ghost or click with no refusal reads as instead
local ENTRY_TEXT = {
	step = "step → %s",
	equip = "equip %s",
	unequip = "unequip",
	ghost = "ghost → %s",
	click = "click ✗ %s",
	rotate = "rotate",
	input = "input → %s",
}
local ENTRY_TEXT_CLEAR = {
	ghost = "ghost → valid",
	click = "click ✓ sent",
}

-- Keeps a trail of what each new player does up to the reported step, and posts it to Discord only if they leave on that step. A player who gets past it costs a table that's thrown away; nothing is stored, and every call that can fail runs off the gameplay path.
local FtueLogManager = {
	LogFtueTrailEvent = Network.Event("LogFtueTrail", {
		Direction = "ClientToServer",
		RateLimit = { MaxPerSecond = 5 },
		Validate = function(_player, platform, entries)
			return type(platform) == "string" and type(entries) == "table"
		end,
	}),

	_config = nil, -- the server's ConfigSnapshot, nil until fetched; nil reads as off
	-- [player] = { UserId, Username, Variant, StartedAt, StepAt, EndedAt, LastStep, Platform, Distance, ValidSince, ValidSeconds, RefusedClicks, SentClicks, Dropped, Entries }
	_trails = {},
	-- ReplayManager, once it has registered itself, or nil. Never required from here: the reporting must not
	-- fail to load because the replay did, so the optional half depends on this one and not the other way round
	_replayProvider = nil,
	-- Why reports didn't go out on this server. Every one of these was once a silent return, which is
	-- indistinguishable from a broken webhook; testFtueWebhook reads them back
	_skipped = { OtherStep = 0, Disabled = 0, RateCapped = 0 },
	_postTimes = {}, -- os.clock() of each post in the last minute, oldest first
	_inFlight = 0, -- reports queued or mid-request, which is what a closing server waits on
}

-- One config value off this server's snapshot, so nothing else has to fetch a second one. Nil where the
-- fetch never landed, which reads as off everywhere it's used.
function FtueLogManager:GetConfigValue(key: string)
	if not self._config then
		return nil
	end

	local read, value = pcall(function()
		return self._config:GetValue(key)
	end)

	return if read then value else nil
end

-- Registers the manager that keeps motion tracks, so a drop report can carry the key to its recording.
function FtueLogManager:SetReplayProvider(provider)
	self._replayProvider = provider
end

-- Whether the LogFTUE config is on. Read live off the snapshot, so flipping it lands mid-session.
function FtueLogManager:_isEnabled(): boolean
	return self:GetConfigValue(CONFIG_KEY) == true
end

-- Drops a player's trail and tells their client to stop sending.
function FtueLogManager:_stopRecording(player: Player)
	self._trails[player] = nil
	player:SetAttribute(CONFIG_KEY, nil)
end

-- Flat studs from the player to the step's guide, or nil with no character or no authored guide.
function FtueLogManager:_getGuideDistance(player: Player): number?
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local guides = ReplicatedStorage:FindFirstChild(GUIDES_FOLDER_NAME)
	local baseGuides = guides and guides:FindFirstChild(player:GetAttribute("BaseId") or "")
	local guide = baseGuides and baseGuides:FindFirstChild(GUIDE_NAME)
	local hitbox = guide and guide:FindFirstChild("Hitbox")

	if not (root and hitbox) then
		return nil
	end

	return math.round(((root.Position - hitbox.Position) * Vector3.new(1, 0, 1)).Magnitude)
end

-- Adds one entry to a trail, folding it into the last when it repeats and dropping the oldest past the cap.
function FtueLogManager:_appendTrailEntry(trail, t: number, kind: string, detail: string?)
	local last = trail.Entries[#trail.Entries]

	if last and last.Kind == kind and last.Detail == detail then
		last.Count += 1
		last.LastT = t
		last.Distance = trail.Distance
		return
	end

	table.insert(trail.Entries, {
		T = t,
		LastT = t,
		Kind = kind,
		Detail = detail,
		Count = 1,
		Distance = trail.Distance,
	})

	if #trail.Entries > MAX_TRAIL_ENTRIES then
		table.remove(trail.Entries, 1)
		trail.Dropped += 1
	end
end

-- Follows a player's funnel: step 1 opens their trail, each later one is marked on it, and reaching the reported step closes it unreported.
function FtueLogManager:_onFunnelStep(player: Player, variant: string, stepIndex: number, stepName: string)
	if stepIndex == 1 and self:_isEnabled() and math.random() < SAMPLE_RATE then
		local now = os.clock()

		self._trails[player] = {
			-- Read here rather than at the report, which runs once the player is already gone
			UserId = player.UserId,
			Username = player.Name,
			Variant = variant,
			StartedAt = now,
			StepAt = now,
			LastStep = stepName,
			ValidSeconds = 0,
			RefusedClicks = 0,
			SentClicks = 0,
			Dropped = 0,
			Entries = {},
		}
		player:SetAttribute(CONFIG_KEY, true)
	end

	local trail = self._trails[player]
	if not trail then
		return
	end

	if stepName == REPORTED_STEP then
		self:_stopRecording(player)
		return
	end

	trail.Distance = self:_getGuideDistance(player) or trail.Distance
	trail.LastStep = stepName
	trail.StepAt = os.clock()
	self:_appendTrailEntry(trail, trail.StepAt - trail.StartedAt, "step", stepName)
end

-- Takes one batch of the client's trail. All of it is untrusted and bound for a Discord channel, so kinds are whitelisted and details stripped to plain words.
function FtueLogManager:RecordFtueTrail(player: Player, platform: string, entries: { any })
	local trail = self._trails[player]
	if not trail then
		return
	end

	-- The switch going off mid-run ends the run, rather than leaving the client sending into nothing
	if not self:_isEnabled() then
		self:_stopRecording(player)
		return
	end

	local now = os.clock()
	trail.Distance = self:_getGuideDistance(player) or trail.Distance

	local platformName = PLATFORM_NAMES[platform]
	if platformName and platformName ~= trail.Platform then
		-- The first is only which device they're on; a change after it is something they did
		if trail.Platform then
			self:_appendTrailEntry(trail, now - trail.StartedAt, "input", platformName)
		end

		trail.Platform = platformName
	end

	for index = 1, math.min(#entries, MAX_BATCH) do
		local entry = entries[index]
		if type(entry) ~= "table" then
			continue
		end

		local age, kind, detail = entry[1], entry[2], entry[3]
		local takesDetail = CLIENT_KINDS[kind]

		-- The second comparison is the NaN check, which would otherwise ride the clamp into the timeline
		if takesDetail == nil or type(age) ~= "number" or age ~= age then
			continue
		end

		-- Cut before it's stripped, so an oversized string costs a 40-byte gsub rather than its whole length
		if takesDetail and type(detail) == "string" then
			detail = (string.gsub(string.sub(detail, 1, MAX_DETAIL_LENGTH), "[^%w ']", ""))
		else
			detail = nil
		end

		local t = math.max(0, now - math.clamp(age, 0, MAX_ENTRY_AGE) - trail.StartedAt)

		-- A ghost with no refusal is one that could go down, and the seconds spent on one are the headline
		if kind == "ghost" or kind == "unequip" then
			if trail.ValidSince then
				trail.ValidSeconds += math.max(0, t - trail.ValidSince)
			end

			trail.ValidSince = if kind == "ghost" and detail == nil then t else nil
		elseif kind == "click" then
			if detail then
				trail.RefusedClicks += 1
			else
				trail.SentClicks += 1
			end
		end

		self:_appendTrailEntry(trail, t, kind, detail)
	end
end

-- Whether a report may go out now: the switch still on, and this server's minute not already spent. Spends it when it answers true.
function FtueLogManager:_canPostReport(): boolean
	if not self:_isEnabled() then
		self._skipped.Disabled += 1
		return false
	end

	-- A rolling minute's cap, so a bad release can't become a flood the proxy blocks the webhook over
	local now = os.clock()
	while self._postTimes[1] and now - self._postTimes[1] >= 60 do
		table.remove(self._postTimes, 1)
	end

	if #self._postTimes >= MAX_POSTS_PER_MINUTE then
		self._skipped.RateCapped += 1
		warn(`[FtueLogManager] a drop report was held back by this server's cap of {MAX_POSTS_PER_MINUTE}/min`)
		return false
	end
	table.insert(self._postTimes, now)

	return true
end

-- Renders a trail as a Discord embed and posts it, answering whether it landed and why not. Yields and can throw, so it's only ever called under a pcall.
function FtueLogManager:_postDropReport(trail, replayKey: string?): (boolean, string)
	local endedAt = trail.EndedAt - trail.StartedAt
	if trail.ValidSince then
		trail.ValidSeconds += math.max(0, endedAt - trail.ValidSince)
	end

	-- A step lands the moment it's logged while the batch around it arrives a second late, so arrival order isn't time order
	table.sort(trail.Entries, function(a, b)
		return a.T < b.T
	end)

	local lines = {}
	local shownDistance = nil

	for _, entry in trail.Entries do
		local text = if entry.Detail
			then string.format(ENTRY_TEXT[entry.Kind], entry.Detail)
			else ENTRY_TEXT_CLEAR[entry.Kind] or ENTRY_TEXT[entry.Kind]
		local line = string.format("%4.0fs  %s", entry.T, text)

		if entry.Count > 1 then
			line ..= string.format(" ×%d (%.0fs)", entry.Count, entry.LastT - entry.T)
		end

		-- Only where it moved, so a player stood still doesn't repeat the figure down the whole column
		if entry.Distance and entry.Distance ~= shownDistance then
			shownDistance = entry.Distance
			line ..= ` · {entry.Distance} studs from marker`
		end

		table.insert(lines, line)
	end

	table.insert(lines, string.format("%4.0fs  left", endedAt))

	-- Whole lines off the front rather than a byte cut, which could land inside an arrow and break the JSON
	local description = table.concat(lines, "\n")
	while #description > MAX_DESCRIPTION_LENGTH do
		table.remove(lines, 1)
		trail.Dropped += 1
		description = table.concat(lines, "\n")
	end

	if trail.Dropped > 0 then
		description = `… {trail.Dropped} earlier entries dropped\n{description}`
	end

	local validText = if trail.ValidSeconds >= 1
		then string.format("ghost valid for %.0fs", trail.ValidSeconds)
		else "ghost never valid"

	local response = HttpService:RequestAsync({
		Url = HttpService:GetSecret(WEBHOOK_SECRET),
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = HttpService:JSONEncode({
			-- Nothing in a report may ping, whatever a client managed to get into it
			allowed_mentions = { parse = {} },
			embeds = {
				{
					title = string.format(
						"%s%s drop — %.0fs on step, %s",
						if trail.Test then "TEST · " else "",
						REPORTED_STEP,
						trail.EndedAt - trail.StepAt,
						validText
					),
					description = `\`\`\`\n{description}\n\`\`\``,
					color = if trail.Test then TEST_EMBED_COLOR else EMBED_COLOR,
					footer = {
						text = `{trail.Username} ({trail.UserId}) · {trail.Platform or "Unknown"} · Variant {trail.Variant} · `
							.. `{trail.RefusedClicks} refused clicks · {trail.SentClicks} sent`
							-- Bracketed: an unbracketed `if` swallows everything after it into its own else branch
							.. (if trail.ClosedWithServer then " · server closed" else "")
							.. (if replayKey then ` · replay {replayKey}` else ""),
					},
				},
			},
		}),
	})

	if not response.Success then
		return false, `webhook answered {response.StatusCode} {response.StatusMessage}`
	end

	return true, `webhook answered {response.StatusCode}`
end

-- Whether recording is actually on and what it's holding. An errored snapshot answers GetValue by throwing, and a status line is no place to raise it. For the testFtueWebhook command.
function FtueLogManager:GetStatusSummary(): string
	-- GetConfigValue swallows a bad read, so the only distinction left is whether a snapshot ever landed
	local configState = if not self._config then "unreachable" elseif self:_isEnabled() then "on" else "off"

	local open = 0
	for _ in self._trails do
		open += 1
	end

	-- Sorted, since a dictionary hands its keys back in whatever order it likes
	local skipped = {}
	for reason, count in self._skipped do
		if count > 0 then
			table.insert(skipped, `{count} {reason}`)
		end
	end
	table.sort(skipped)

	local tail = if #skipped > 0 then `, not reported: {table.concat(skipped, ", ")}` else ""

	return `LogFTUE {configState}, {open} trail(s) open{tail}`
end

-- Posts a made-up trail down the same path a real one takes, so the secret, the proxy and the embed can be checked before LogFTUE goes on. Deliberately past both gates -- it's admin-run, and the point is to test with the switch still off. For the testFtueWebhook command.
function FtueLogManager:SendTestReport(player: Player): (boolean, string)
	local now = os.clock()

	-- A stuck desktop session as a real report would read it; the details are what BuildController sends
	return self:_postDropReport({
		Test = true,
		UserId = player.UserId,
		Username = player.Name,
		Variant = "B",
		Platform = "Desktop",
		StartedAt = now - 180,
		StepAt = now - 143,
		EndedAt = now,
		ValidSeconds = 0,
		RefusedClicks = 11,
		SentClicks = 0,
		Dropped = 0,
		Entries = {
			{ T = 37, LastT = 37, Kind = "step", Detail = REPORTED_STEP_ENTRY, Count = 1 },
			{ T = 39, LastT = 39, Kind = "equip", Detail = "RustyGrill", Count = 1, Distance = 31 },
			{ T = 41, LastT = 79, Kind = "ghost", Detail = "Aim at ground you own", Count = 12, Distance = 31 },
			{ T = 82, LastT = 104, Kind = "click", Detail = "Aim at ground you own", Count = 6, Distance = 30 },
			{ T = 110, LastT = 118, Kind = "rotate", Count = 4, Distance = 29 },
			{ T = 140, LastT = 140, Kind = "unequip", Count = 1, Distance = 28 },
		},
	}, TEST_REPLAY_KEY)
end

function FtueLogManager:OnInit()
	PlayerDataManager:RegisterPreCleanupCallback(function(player: Player, _, reason: string)
		local trail = self._trails[player]
		self:_stopRecording(player)

		if not trail then
			return
		end

		-- Left somewhere other than the reported step: before taking the griller out, or after placing it
		if trail.LastStep ~= REPORTED_STEP_ENTRY then
			self._skipped.OtherStep += 1
			return
		end

		trail.EndedAt = os.clock()

		-- Reported either way. The last player out of a quiet server races their own leave against the
		-- shutdown, so their session can end as one -- skipping those loses real drops on private servers.
		-- The report says which it was instead, since a restart that took a player mid-step isn't a drop
		trail.ClosedWithServer = reason ~= "Manual"

		-- Taken synchronously: the track is dropped a frame after this leave, so the thread below would miss it
		local provider = self._replayProvider
		local track = provider and provider:TakeTrack(player)

		-- Counted here rather than in the thread, so a server closing this same frame already sees it
		self._inFlight += 1

		-- Deferred, so none of the report's work sits inside the save this callback is part of
		task.defer(function()
			-- Its own pcall, so a recording that won't save still leaves the report to go out without a key
			local replayKey = nil
			if track then
				local saved, result = pcall(function()
					return provider:SaveDropReplay(track, trail)
				end)

				replayKey = if saved then result else nil

				if not saved then
					warn(`[FtueLogManager] replay save failed: {result}`)
				end
			end

			-- A throw and a bad answer both land in `problem`, there being nothing to tell apart here
			local ran, problem = pcall(function()
				if not self:_canPostReport() then
					return nil
				end

				local posted, message = self:_postDropReport(trail, replayKey)
				return if posted then nil else message
			end)

			self._inFlight -= 1

			if not ran or problem then
				warn(`[FtueLogManager] drop report failed: {problem}`)
			end
		end)
	end)
end

function FtueLogManager:OnStart()
	self.LogFtueTrailEvent:OnServerEvent(function(player: Player, platform: string, entries: { any })
		self:RecordFtueTrail(player, platform, entries)
	end)

	TutorialManager.OnFunnelStep:Connect(function(player: Player, variant: string, stepIndex: number, stepName: string)
		self:_onFunnelStep(player, variant, stepIndex, stepName)
	end)

	task.spawn(function()
		for attempt = 1, CONFIG_FETCH_ATTEMPTS do
			-- Yields, and hangs before erroring in an experience with no configs -- the ordinary case in Studio
			local fetched, snapshot = pcall(function()
				return ConfigService:GetConfigAsync()
			end)

			if fetched then
				self._config = snapshot

				-- A snapshot never moves on its own, so this is what lets the switch land without a restart
				snapshot.UpdateAvailable:Connect(function()
					pcall(function()
						snapshot:Refresh()
					end)
				end)

				return
			end

			task.wait(CONFIG_RETRY_DELAY * attempt)
		end

		-- Said out loud: silently, this is a server that logs nothing at all for the whole of its life
		warn(`[FtueLogManager] no experience config after {CONFIG_FETCH_ATTEMPTS} tries, so this server logs nothing`)
	end)

	-- The last player out closes the server, and without this their report could be cut off mid-request
	game:BindToClose(function()
		local deadline = os.clock() + CLOSE_TIMEOUT
		local grace = os.clock() + CLOSE_GRACE

		-- ProfileStore releases the last profile from inside its own close handler, so a report can still be
		-- queued after this one starts. Returning on an empty count would close the server over it
		while self._inFlight == 0 and os.clock() < grace do
			task.wait(0.1)
		end

		while self._inFlight > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

return FtueLogManager
