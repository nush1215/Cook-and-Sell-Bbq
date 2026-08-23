--!strict
-- Shared bootstrap used by both the Client and Server Runtime scripts.
-- Loads a folder of lifecycle modules (Controllers / Managers) in priority order, runs their
-- OnInit then OnStart, then requires a folder of tag-based Components.

type InitType = "Init" | "Start"

type Config = {
	Label: string, -- "Client" | "Server"; used in timing prints and warnings
	Container: Instance, -- Folder of lifecycle module scripts
	Components: Instance, -- Folder of component module scripts
	Priority: { string }, -- module names loaded first, in order
	Modules: { [string]: any }, -- caller-owned registry, filled with [name] = module
	LoadedComponents: { [string]: any }, -- caller-owned registry, filled with [name] = module
}

local Loader = {}

-- Requires (and caches) a module, then runs its On{initType} under pcall.
local function initModule(module: ModuleScript, initType: InitType, config: Config)
	local name = module.Name
	local loaded = config.Modules[name]

	if not loaded then
		local success, result = pcall(require, module)

		if not success then
			warn(`[{config.Label}] Failed to load '{name}': {result}`)
			return
		end

		loaded = result
		config.Modules[name] = loaded
	end

	local functionName = `On{initType}`
	local initFunction = loaded[functionName]

	if initFunction then
		local success, err = pcall(initFunction, loaded)
		if not success then
			warn(`[{config.Label}] Error in {name}.{functionName}: {err}`)
		end
	end
end

-- Loads the priority modules, in declared order.
local function loadPriority(initType: InitType, config: Config)
	local startTime = os.clock()

	for _, name in config.Priority do
		local module = config.Container:FindFirstChild(name)

		if module and module:IsA("ModuleScript") then
			initModule(module, initType, config)
		else
			warn(`[{config.Label}] Priority module '{name}' not found or is not a ModuleScript`)
		end
	end

	print(string.format("%s %s Priority Loaded: %.2f ms", config.Label, initType, (os.clock() - startTime) * 1000))
end

-- Loads every remaining module (skipping the priority ones).
local function loadOthers(initType: InitType, config: Config)
	local startTime = os.clock()

	for _, module in config.Container:GetChildren() do
		if not module:IsA("ModuleScript") then
			continue
		end

		if table.find(config.Priority, module.Name) then
			continue
		end

		initModule(module, initType, config)
	end

	print(string.format("%s %s Others Loaded: %.2f ms", config.Label, initType, (os.clock() - startTime) * 1000))
end

-- Requires every component, registering its tag and storing it for lookup.
local function loadComponents(config: Config)
	for _, component in config.Components:GetDescendants() do
		if not component:IsA("ModuleScript") then
			continue
		end

		local success, result = pcall(require, component)

		if success then
			config.LoadedComponents[component.Name] = result
		else
			warn(`[{config.Label}] Failed to load component '{component.Name}': {result}`)
		end
	end
end

-- Yields until the given boolean attribute is true (event-driven; no busy polling).
function Loader.waitForAttribute(instance: Instance, name: string)
	while instance:GetAttribute(name) ~= true do
		instance:GetAttributeChangedSignal(name):Wait()
	end
end

-- Runs the full bootstrap sequence.
function Loader.run(config: Config)
	local startTime = os.clock()

	loadPriority("Init", config)
	loadOthers("Init", config)
	loadPriority("Start", config)
	loadOthers("Start", config)
	loadComponents(config)

	print(string.format("%s Fully Loaded: %.2f ms", config.Label, (os.clock() - startTime) * 1000))
end

return Loader
