-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Packages
local Packages = ReplicatedStorage.Packages
local Spr = require(Packages.Spr)

-- How many "ClassName Name.Property" rows the breakdown lists, biggest first.
local TOP_ROWS = 15

-- The periodic logger, when one is running.
local logThread: thread? = nil

-- Prints a census of the springs spr is stepping on this client to the output and returns its
-- one-line summary. Temporary diagnostics for the spr frame cost.
local function report(): string
	local snapshot = Spr.debugSnapshot()

	local rows = {}
	for key, row in snapshot.ByKey do
		table.insert(rows, { Key = key, Count = row.Count, Detached = row.Detached })
	end
	table.sort(rows, function(a, b)
		return a.Count > b.Count
	end)

	local minAngle = if snapshot.MinRotationAngle == math.huge then "n/a" else `{snapshot.MinRotationAngle}deg`
	local lines = {
		`[spr] {snapshot.Total} springs ({snapshot.Detached} on detached instances), oldest {math.floor(snapshot.OldestAge)}s`
			.. ` | CFrame: {snapshot.RotationOnly} rotation-only awake, {snapshot.NaNVelocity} NaN velocity, closest rotation {minAngle}`,
	}
	for i = 1, math.min(TOP_ROWS, #rows) do
		local row = rows[i]
		table.insert(lines, `  {row.Count} x {row.Key} ({row.Detached} detached)`)
	end

	print(table.concat(lines, "\n"))
	return lines[1]
end

return {
	Name = "springs",
	Aliases = { "spr" },
	Description = "Reports the springs spr is stepping on this client; pass an interval to log it repeatedly, 0 to stop",
	Args = {
		{
			Type = "number",
			Name = "Interval",
			Description = "Seconds between reports; omit for a single report, 0 to stop a running log",
			Optional = true,
		},
	},

	Run = function(_context, interval: number?)
		if logThread then
			task.cancel(logThread)
			logThread = nil
		end

		if interval and interval > 0 then
			logThread = task.spawn(function()
				while true do
					report()
					task.wait(interval)
				end
			end)

			return `Logging spr springs every {interval}s (run "springs 0" to stop)`
		end

		return report()
	end,
}
