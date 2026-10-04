local oldgame = oldgame or game

-- Old fallback returned an "invalidate" function instead of the instance when getreg
-- existed, which turned `game`/services into functions. Passing the ref through is safe.
cloneref = cloneref or function(ref) return ref end

local isFsSupported = readfile and writefile and isfile and isfolder and listfiles and delfile and delfolder

-- Main vars
local Main, Explorer, Properties, ScriptViewer, Console, SaveInstance, ModelViewer, SettingsWindow, ScriptAnalyzer--[[, SecretServicePanel]], DefaultSettings, Notebook, Serializer, Lib local ggv = getgenv or nil
local API, RMD

-- Default Settings
DefaultSettings = (function()
	local rgb = Color3.fromRGB	
	
	return {
		Explorer = {
			_Recurse = true,
			Sorting = true,
			TeleportToOffset = Vector3.new(0,0,0),
			ClickToRename = true,
			AutoUpdateSearch = true,
			AutoUpdateMode = 0, -- 0 Default, 1 no tree update, 2 no descendant events, 3 frozen
			PartSelectionBox = true,
			GuiSelectionBox = true,
			CopyPathUseGetChildren = true
		},
		Properties = {
			_Recurse = true,
			MaxConflictCheck = 50,
			ShowDeprecated = true,
			ShowHidden = false,
			ClearOnFocus = false,
			LoadstringInput = true,
			NumberRounding = 3,
			ShowAttributes = true,
			MaxAttributes = 50,
			ScaleType = 0 -- 0 Full Name Shown, 1 Equal Halves
		},
		-- Soft Dark theme. Bump ThemeVersion when the default palette changes so
		-- old saved themes in DexPlusPlusSettings.json get replaced on next load.
		ThemeVersion = 3,
		Theme = {
			_Recurse = true,
			SoftRemap = true, -- remaps the hardcoded legacy greys/blues of every Dex gui to this palette
			SoftShapes = true, -- rounded buttons/inputs/scrollbars and eased hover transitions
			CornerRadius = 6, -- windows, menus
			ElementRadius = 4, -- buttons, inputs, checkboxes
			Toggle = rgb(108,122,230), -- checked checkbox fill
			ScrollThumb = rgb(58,60,76),
			ScrollThumbHover = rgb(76,79,100),
			Category = rgb(34,35,46), -- Properties category rows
			CategoryText = rgb(170,180,250),
			Main1 = rgb(31,31,37),
			Main2 = rgb(27,27,32),
			Outline1 = rgb(20,20,24), -- Mainly frames
			Outline2 = rgb(33,33,40), -- Mainly button
			Outline3 = rgb(18,18,22), -- Mainly textbox
			TextBox = rgb(23,23,27),
			Menu = rgb(19,19,23),
			ListSelection = rgb(74,86,160),
			Button = rgb(36,36,43),
			ButtonHover = rgb(40,41,49),
			ButtonPress = rgb(24,24,29),
			Highlight = rgb(45,45,54),
			Accent = rgb(132,146,255),
			WindowStroke = rgb(52,54,68),
			Text = rgb(227,230,242),
			PlaceholderText = rgb(95,96,104),
			Important = rgb(240,90,100),
			ExplorerIconMap = "",
			MiscIconMap = "",
			Syntax = {
				Text = rgb(200,202,214),
				Background = rgb(21,21,26),
				Selection = rgb(227,230,242),
				SelectionBack = rgb(74,86,160),
				Operator = rgb(190,192,206),
				Number = rgb(240,190,110),
				String = rgb(165,214,140),
				Comment = rgb(98,102,122),
				Keyword = rgb(232,128,150),
				Error = rgb(240,90,100),
				FindBackground = rgb(120,100,40),
				MatchingWord = rgb(55,58,72),
				BuiltIn = rgb(130,196,236),
				CurrentLine = rgb(32,34,46),
				LocalMethod = rgb(236,226,160),
				LocalProperty = rgb(122,162,240),
				Nil = rgb(240,190,110),
				Bool = rgb(240,190,110),
				Function = rgb(232,128,150),
				Local = rgb(232,128,150),
				Self = rgb(232,128,150),
				FunctionName = rgb(236,226,160),
				Bracket = rgb(190,192,206)
			},
		},
		ScriptViewer = {
			ShowMoreInfo = true;
		},
		Window = {
			TitleOnMiddle = false,
			Transparency = .2
		},
		Decompiler = {
			DecompilerFallback = "Konstant", --Konstant, Shiny, AdvancedDecompiler
			PreferDecompilerFallback = false,
			ShinyDecompilerPort = 3000,
		},
		
		RemoteBlockWriteAttribute = false, -- writes attribute to remote instance if remote is blocked/unblocked
		ClassIcon = "NewDark",
		ToggleKey = "RightControl", -- Enum.KeyCode name that hides/shows every Dex gui, "" to disable
		Telemetry = {
			_Recurse = true,
			Consent = "ask", -- "ask" until the user answers the prompt, then "granted" or "denied"
		},
		
		-- What available icons:
		-- > Vanilla3
		-- > Old
		-- > NewDark
	}
end)()

-- Vars
local function deepCopy(tbl)
	local res = {}
	for k,v in pairs(tbl) do
		res[k] = type(v) == "table" and deepCopy(v) or v
	end
	return res
end

-- Copy so DefaultSettings stays untouched and ResetSettings actually resets
local Settings = DefaultSettings and deepCopy(DefaultSettings) or {}
local Apps = {}
local env = {}

local service = setmetatable({},{__index = function(self,name)
	local serv = cloneref(game:GetService(name))
	self[name] = serv
	return serv
end})
local plr = service.Players.LocalPlayer or service.Players.PlayerAdded:wait()

local create = function(data)
	local insts = {}
	for i,v in pairs(data) do insts[v[1]] = Instance.new(v[2]) end

	for _,v in pairs(data) do
		for prop,val in pairs(v[3]) do
			if type(val) == "table" then
				insts[v[1]][prop] = insts[val[1]]
			else
				insts[v[1]][prop] = val
			end
		end
	end

	return insts[1]
end

local createSimple = function(class,props)
	local inst = Instance.new(class)
	for i,v in next,props do
		inst[i] = v
	end
	return inst
end

Main = (function()
	local Main = {}

	Main.ModuleList = {"Explorer","Properties","ScriptViewer","Console","SaveInstance","ModelViewer","SettingsWindow","ScriptAnalyzer"}
	-- Extras that must never stop Dex from starting: a failure only warns and the app is skipped
	Main.OptionalModules = {ScriptAnalyzer = true}
	Main.Elevated = false
	Main.AllowDraggableOnMobile = true
	Main.MissingEnv = {}
	Main.Version = "3.0"
	Main.Mouse = plr:GetMouse()
	Main.AppControls = {}
	Main.Apps = Apps
	Main.MenuApps = {}
	Main.GitName = "il4pt"
	Main.RepoName = "Dex-"
	Main.GitRepoName = Main.GitName.."/"..Main.RepoName
	Main.ReleaseTag = "v3.3.2-soft"

	-- Opt-in usage counter. Empty disables it entirely (no prompt, no request).
	-- When set, the user is asked once; only after they accept is {username, placeId, version}
	-- POSTed as JSON to this URL on launch. Declining sends nothing, ever.
	Main.TelemetryEndpoint = ""

	Main.DisplayOrders = {
		SideWindow = 8,
		Window = 10,
		Menu = 100000,
		Core = 101000
	}
	
	Main.Plugins = {}
	
	--[[Main.LoadAdonisBypass = function()
		-- skidded off reddit :pensive:
		local getinfo = getinfo or debug.getinfo
		local DEBUG = false
		local Hooked = {}

		local Detected, Kill

		setthreadidentity(2)

		for i, v in getgc(true) do
			if typeof(v) == "table" then
				local DetectFunc = rawget(v, "Detected")
				local KillFunc = rawget(v, "Kill")

				if typeof(DetectFunc) == "function" and not Detected then
					Detected = DetectFunc

					local Old; Old = hookfunction(Detected, function(Action, Info, NoCrash)
						if Action ~= "_" then
							if DEBUG then
								warn(`Adonis AntiCheat flagged\nMethod: {Action}\nInfo: {Info}`)
							end
						end

						return true
					end)

					table.insert(Hooked, Detected)
				end

				if rawget(v, "Variables") and rawget(v, "Process") and typeof(KillFunc) == "function" and not Kill then
					Kill = KillFunc
					local Old; Old = hookfunction(Kill, function(Info)
						if DEBUG then
							warn(`Adonis AntiCheat tried to kill (fallback): {Info}`)
						end
					end)

					table.insert(Hooked, Kill)
				end
			end
		end

		local Old; Old = hookfunction(getrenv().debug.info, newcclosure(function(...)
			local LevelOrFunc, Info = ...

			if Detected and LevelOrFunc == Detected then
				if DEBUG then
					warn(`Adonis AntiCheat sanity check detected and broken`)
				end

				return coroutine.yield(coroutine.running())
			end

			return Old(...)
		end))
		-- setthreadidentity(9)
		setthreadidentity(7)
	end
	
	Main.LoadGCBypass = function()
		loadstring(game:HttpGet("https://raw.githubusercontent.com/secretisadev/Babyhamsta_Backup/refs/heads/main/Universal/Bypasses.lua", true))()
	end]]
	
	Main.GetRandomString = function()
		local output = ""
		for i = 2, 25 do
			output = output .. string.char(math.random(1,250))
		end
		
		return output
	end
	
	-- Must mirror where SecureGui parents guis
	Main.GetSecureContainer = function()
		if gethui then return gethui() end
		if (syn and syn.protect_gui) or protect_gui or protectgui or Main.Elevated then
			return service.CoreGui
		end
		return service.Players.LocalPlayer:WaitForChild("PlayerGui")
	end
	
	-- Soft theme remap
	-- Most of the UI is built from hardcoded Studio-like greys, so instead of rewriting
	-- hundreds of Color3 literals every Dex gui passes through here. Neutral greys are
	-- darkened and given a slight cool tint, known accent blues are softened. Results
	-- are never neutral greys themselves, so remapping a remapped colour is a no-op.
	Main.GuiVisible = true

	local themedRoots = setmetatable({},{__mode = "k"})
	local themedObjs = setmetatable({},{__mode = "k"})
	local round = math.round or function(n) return math.floor(n + 0.5) end

	local accentMap = {
		[11*65536 + 90*256 + 175] = Color3.fromRGB(74,86,160),   -- list selection
		[0*65536 + 170*256 + 255] = Color3.fromRGB(132,146,255), -- highlights
		[53*65536 + 178*256 + 251] = Color3.fromRGB(132,146,255),
		[16*65536 + 132*256 + 255] = Color3.fromRGB(112,128,240),
		[61*65536 + 143*256 + 220] = Color3.fromRGB(104,120,214),
		[86*65536 + 125*256 + 188] = Color3.fromRGB(98,110,180),
	}

	-- Colour swatches that must show the real value
	local skipNames = {ColorPreview = true, Preview = true, ColorSpace = true, ColorStrip = true}
	local skipParents = {BasicColors = true, CustomColors = true}

	local function toRGB(c)
		return round(c.R*255), round(c.G*255), round(c.B*255)
	end

	local function neutral(r,g,b)
		return math.abs(r-g) <= 1 and math.abs(g-b) <= 1
	end

	Main.SoftBackColor = function(c)
		local r,g,b = toRGB(c)
		local accent = accentMap[r*65536 + g*256 + b]
		if accent then return accent end
		if neutral(r,g,b) and g >= 17 and g <= 150 then
			local base = g * 0.62
			return Color3.fromRGB(round(base*0.96), round(base*0.97), round(base*1.16))
		end
		return c
	end

	Main.SoftTextColor = function(c)
		local r,g,b = toRGB(c)
		local accent = accentMap[r*65536 + g*256 + b]
		if accent then return accent end
		if neutral(r,g,b) then
			if g >= 200 then
				return Color3.fromRGB(round(g*0.89), round(g*0.9), round(g*0.95))
			elseif g >= 90 then
				return Color3.fromRGB(round(g*0.95), round(g*0.96), round(g*1.04))
			end
		end
		return c
	end

	local backProps = {"BackgroundColor3","BorderColor3"}
	local textProps = {"TextColor3","PlaceholderColor3"}

	local function hookProp(obj,prop,func)
		local function apply()
			local cur = obj[prop]
			local new = func(cur)
			if new ~= cur then obj[prop] = new end
		end
		apply()
		obj:GetPropertyChangedSignal(prop):Connect(apply)
	end

	Main.ThemeObject = function(obj)
		if themedObjs[obj] then return end
		themedObjs[obj] = true

		if skipNames[obj.Name] or (obj.Parent and skipParents[obj.Parent.Name]) or obj:GetAttribute("DexNoTheme") then return end

		if obj:IsA("GuiObject") then
			for _,prop in ipairs(backProps) do hookProp(obj,prop,Main.SoftBackColor) end
			if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
				hookProp(obj,"TextColor3",Main.SoftTextColor)
				if obj:IsA("TextBox") then hookProp(obj,"PlaceholderColor3",Main.SoftTextColor) end
			end
			if obj:IsA("ScrollingFrame") then hookProp(obj,"ScrollBarImageColor3",Main.SoftBackColor) end
		elseif obj:IsA("UIStroke") then
			hookProp(obj,"Color",Main.SoftBackColor)
		end
	end

	Main.ApplyTheme = function(gui)
		if not Settings.Theme.SoftRemap or themedRoots[gui] then return end
		themedRoots[gui] = true

		pcall(Main.ThemeObject,gui)
		for _,obj in ipairs(gui:GetDescendants()) do
			pcall(Main.ThemeObject,obj)
		end
		gui.DescendantAdded:Connect(function(obj)
			pcall(Main.ThemeObject,obj)
		end)
	end

	Main.SetGuiVisible = function(val)
		Main.GuiVisible = val
		for _,gui in pairs(Main.GetSecureContainer():GetChildren()) do
			if string.sub(gui.Name,1,5) == "_DPP_" and gui:IsA("ScreenGui") then
				gui.Enabled = val
			end
		end
	end

	Main.SetupToggleKey = function()
		if Main.ToggleKeyConnection then Main.ToggleKeyConnection:Disconnect() Main.ToggleKeyConnection = nil end

		local keyName = Settings.ToggleKey
		if type(keyName) ~= "string" or keyName == "" then return end
		local s,keyCode = pcall(function() return Enum.KeyCode[keyName] end)
		if not s or not keyCode then return end

		Main.ToggleKeyConnection = service.UserInputService.InputBegan:Connect(function(input,processed)
			if processed then return end
			if input.KeyCode == keyCode then
				Main.SetGuiVisible(not Main.GuiVisible)
			end
		end)
	end

	Main.SendUsagePing = function()
		if Main.TelemetryEndpoint == "" or Settings.Telemetry.Consent ~= "granted" or not env.request then return end
		task.spawn(pcall, env.request, {
			Url = Main.TelemetryEndpoint,
			Method = "POST",
			Headers = {["Content-Type"] = "application/json"},
			Body = service.HttpService:JSONEncode({
				username = plr.Name,
				placeId = game.PlaceId,
				version = Main.ReleaseTag
			})
		})
	end

	Main.SetTelemetryConsent = function(granted)
		Settings.Telemetry.Consent = granted and "granted" or "denied"
		Main.SaveCurrentSettings()
		if granted then Main.SendUsagePing() end
	end

	Main.ShowTelemetryConsent = function()
		local win = Lib.Window.new()
		win.Alignable = false
		win.Resizable = false
		win:SetTitle("Usage Statistics")
		win:SetSize(340,160)

		local host = Main.TelemetryEndpoint:match("^%a+://([^/]+)") or Main.TelemetryEndpoint
		local info = Lib.Label.new()
		info.Position = UDim2.new(0,10,0,8)
		info.Size = UDim2.new(1,-20,1,-44)
		info.Gui.TextWrapped = true
		info.Gui.TextYAlignment = Enum.TextYAlignment.Top
		info.Text = "Help count how many people use Dex-?\n\n"
			.."If you allow it, each launch sends your Roblox username, the place ID and the Dex version to "..host..". "
			.."Nothing else is collected, and nothing is sent if you decline. You can change this any time in Settings."
		win:Add(info)

		local allow = Lib.Button.new()
		allow.Text = "Allow"
		allow.AnchorPoint = Vector2.new(0,1)
		allow.Position = UDim2.new(0,5,1,-5)
		allow.Size = UDim2.new(0.5,-7,0,20)
		allow.OnClick:Connect(function()
			Main.SetTelemetryConsent(true)
			win:Close()
		end)
		win:Add(allow)

		local deny = Lib.Button.new()
		deny.Text = "Don't Allow"
		deny.AnchorPoint = Vector2.new(1,1)
		deny.Position = UDim2.new(1,-5,1,-5)
		deny.Size = UDim2.new(0.5,-7,0,20)
		deny.OnClick:Connect(function()
			Main.SetTelemetryConsent(false)
			win:Close()
		end)
		win:Add(deny)

		win:Show()
	end

	Main.InitTelemetry = function()
		if Main.TelemetryEndpoint == "" or not env.request then return end
		local consent = Settings.Telemetry.Consent
		if consent == "granted" then
			Main.SendUsagePing()
		elseif consent ~= "denied" then
			Main.ShowTelemetryConsent()
		end
	end

	Main.SecureGui = function(gui)
		--warn("Secured: "..gui.Name)
		gui.Name = "_DPP_".. Main.GetRandomString()
		Main.ApplyTheme(gui)
		if gui:IsA("ScreenGui") then gui.Enabled = Main.GuiVisible end
		-- service already using cloneref
		if gethui then
			gui.Parent = gethui()
		elseif syn and syn.protect_gui then
			syn.protect_gui(gui)
			gui.Parent = service.CoreGui
		elseif protect_gui then
			protect_gui(gui)
			gui.Parent = service.CoreGui
		elseif protectgui then
			protectgui(gui)
			gui.Parent = service.CoreGui
		else
			if Main.Elevated then
				gui.Parent = service.CoreGui
			else
				gui.Parent = service.Players.LocalPlayer:WaitForChild("PlayerGui")
			end
		end
	end

	Main.GetInitDeps = function()
		return {
			Main = Main,
			Lib = Lib,
			Apps = Apps,
			Settings = Settings,

			API = API,
			RMD = RMD,
			env = env,
			service = service,
			plr = plr,
			create = create,
			createSimple = createSimple
		}
	end

	Main.Error = function(str)
		if rconsoleprint then
			rconsoleprint("DEX ERROR: "..tostring(str).."\n")
			wait(9e9)
		else
			error(str)
		end
	end

	Main.LoadModule = function(name)
		if Main.Elevated then -- If you don't have filesystem api then ur outta luck tbh
			local control

			if EmbeddedModules then -- Offline Modules
				control = EmbeddedModules[name]()

				-- TODO: Remove when open source
				if gethsfuncs then
					control = _G.moduleData
				end

				if not control then Main.Error("Missing Embedded Module: "..name) end
			else
				-- Get hash data
				local hashs = Main.ModuleHashData
				if not hashs then
					local s,hashDataStr = pcall(oldgame.HttpGet, game, "https://api.github.com/repos/"..Main.GitRepoName.."/ModuleHashs.dat")
					if not s then Main.Error("Failed to get module hashs") end

					local s,hashData = pcall(service.HttpService.JSONDecode,service.HttpService,hashDataStr)
					if not s then Main.Error("Failed to decode module hash JSON") end

					hashs = hashData
					Main.ModuleHashData = hashs
				end

				-- Check if local copy exists with matching hashs
				local hashfunc = (syn and syn.crypt.hash) or function() return "" end
				local filePath = "dex/ModuleCache/"..name..".lua"
				local s,moduleStr = pcall(env.readfile,filePath)

				if s and hashfunc(moduleStr) == hashs[name] then
					control = loadstring(moduleStr)()
				else
					-- Download and cache
					local s,moduleStr = pcall(oldgame.HttpGet, game, "https://api.github.com/repos/"..Main.GitRepoName.."/Modules/"..name..".lua")
					if not s then Main.Error("Failed to get external module data of "..name) end

					env.writefile(filePath,moduleStr)
					control = loadstring(moduleStr)()
				end
			end

			Main.AppControls[name] = control
			control.InitDeps(Main.GetInitDeps())

			local moduleData = control.Main()
			Apps[name] = moduleData
			return moduleData
		else
			local module = script:WaitForChild("Modules"):WaitForChild(name,2)
			if not module then Main.Error("CANNOT FIND MODULE "..name) end

			local control = require(module)
			Main.AppControls[name] = control
			control.InitDeps(Main.GetInitDeps())

			local moduleData = control.Main()
			Apps[name] = moduleData
			return moduleData
		end
	end
	
	Main.LoadPluginFile = function(pluginDir)
		if env.readfile then
			if isfile(pluginDir) then
				local preloadedPlugin = loadfile and loadfile(pluginDir) or loadstring(env.readfile(pluginDir))
				local loadedPlugin = preloadedPlugin()
				
				local control = loadedPlugin
				control.InitDeps(Main.GetInitDeps())

				local moduleData = control.Main()
				Apps[pluginDir] = moduleData
				Main.AppControls[pluginDir] = control
				
				moduleData.PluginData = control.PluginData
				
				return moduleData
			else
				Main.Error("CANNOT FIND FILE MODULE "..pluginDir)
			end
		end
	end

	Main.LoadModules = function()
		for i,v in pairs(Main.ModuleList) do
			local s,e = pcall(Main.LoadModule,v)
			if not s then
				if Main.OptionalModules[v] then
					warn("[Dex-] Optional module "..v.." failed to load: "..tostring(e))
				else
					Main.Error("FAILED LOADING " .. v .. " CAUSE " .. e)
				end
			end
		end

		-- Init Major Apps and define them in modules
		Explorer = Apps.Explorer
		Properties = Apps.Properties
		ScriptViewer = Apps.ScriptViewer
		Console = Apps.Console
		SaveInstance = Apps.SaveInstance
		ModelViewer = Apps.ModelViewer
		Notebook = Apps.Notebook
		SettingsWindow = Apps.SettingsWindow
		ScriptAnalyzer = Apps.ScriptAnalyzer
		
		
		--SecretServicePanel = Apps.SecretServicePanel
		local appTable = {
			Explorer = Explorer,
			Properties = Properties,
			ScriptViewer = ScriptViewer,
			Console = Console,
			SaveInstance = SaveInstance,
			ModelViewer = ModelViewer,
			Notebook = Notebook,
			SettingsWindow = SettingsWindow,
			ScriptAnalyzer = ScriptAnalyzer
			--SecretServicePanel = SecretServicePanel,
		}
		
		

		Main.AppControls.Lib.InitAfterMain(appTable)
		for i,v in pairs(Main.ModuleList) do
			local control = Main.AppControls[v]
			if control then
				local s,e = pcall(control.InitAfterMain,appTable)
				if not s then
					if not Main.OptionalModules[v] then error(e,0) end
					warn("[Dex-] Optional module "..v.." failed InitAfterMain: "..tostring(e))
				end
			end
		end
	end

	Main.InitEnv = function()
		setmetatable(env,{__newindex = function(self,name,func)
			if not func then Main.MissingEnv[#Main.MissingEnv+1] = name return end
			rawset(self,name,func)
		end})

		env.isonmobile = game:GetService("UserInputService").TouchEnabled
		
		env.loadstring = (pcall(loadstring,"local a = 1") and loadstring) or (game:GetService("RunService"):IsStudio() and script.Modules:FindFirstChild("Loadstring") and require(script.Modules:FindFirstChild("Loadstring")))

		-- file
		env.isfile = isfile
		env.isfolder = isfolder
		env.readfile = readfile
		env.writefile = writefile
		env.appendfile = appendfile
		env.makefolder = makefolder
		env.listfiles = listfiles
		env.loadfile = loadfile
		env.saveinstance = saveinstance or (function()
			--warn("No built-in saveinstance exists, using SynSaveInstance and wrapper...")
			if game:GetService("RunService"):IsStudio() then return function() error("Cannot run in Roblox Studio!") end end
			local Params = {
				RepoURL = "https://raw.githubusercontent.com/luau/SynSaveInstance/main/",
				SSI = "saveinstance",
			}
			local synsaveinstance = loadstring(oldgame:HttpGet(Params.RepoURL .. Params.SSI .. ".luau", true), Params.SSI)()
		
			local function wrappedsaveinstance(obj, filepath, options)
				options["FilePath"] = filepath
				--options["ReadMe"] = false
				options["Object"] = obj
				return synsaveinstance(options)
			end
			
			getgenv().saveinstance = wrappedsaveinstance
			return wrappedsaveinstance
		end)()
		
		env.parsefile = function(name)
			return tostring(name):gsub("[*\\?:<>|]+", ""):sub(1, 175)
		end

		-- debug
		env.getupvalues = debug.getupvalues or getupvalues or getupvals
		env.getconstants = debug.getconstants or getconstants or getconsts
		env.islclosure = islclosure or is_l_closure
		env.checkcaller = checkcaller
		env.getreg = getreg
		env.getgc = getgc
		
		-- hooks
		env.hookfunction = hookfunction
		env.hookmetamethod = hookmetamethod

		-- other
		env.getscriptbytecode = getscriptbytecode
		env.setfflag = setfflag
		env.protectgui = protect_gui or (syn and syn.protect_gui)
		env.gethui = gethui
		env.setclipboard = setclipboard
		env.getnilinstances = getnilinstances or get_nil_instances
		env.getloadedmodules = getloadedmodules
		
		env.isViableDecompileScript = function(obj)
			if obj:IsA("ModuleScript") then
				return true
			elseif obj:IsA("LocalScript") and (obj.RunContext == Enum.RunContext.Client or obj.RunContext == Enum.RunContext.Legacy) then
				return true
			elseif obj:IsA("Script") and obj.RunContext == Enum.RunContext.Client then
				return true
			end
			return false
		end
		env.request = (syn and syn.request) or (http and http.request) or http_request or (fluxus and fluxus.request) or request
		
		env.isdecompile = function()
			return typeof(decompile) == "function" or typeof(getscriptbytecode) == "function" or false
		end
		
		env.isdecompilefallback = function()
			return typeof(decompile) ~= "function" or typeof(getscriptbytecode) == "function" or false
		end
		
		
		-- DECOMPILERS
		
		local AdvancedDecompilerCache
		pcall(function()
			AdvancedDecompilerCache = loadstring(game:HttpGet("https://raw.githubusercontent.com/AZYsGithub/Advanced-Decompiler-V3/refs/heads/main/init.lua"))()
		end)
		
		local konstant_last_call = 0
		
		local function KonstantDec(...)
			-- by lovrewe
			--warn("No built-in decompiler exists, using Konstant decompiler...")
			--assert(getscriptbytecode, "Exploit not supported.")
			local API = "http://api.plusgiant5.com"

			local request = env.request

			local function call(konstantType, scriptPath)
				local success, bytecode = pcall(env.getscriptbytecode, scriptPath)

				if (not success) then
					return `-- Failed to get script bytecode, error:\n\n--[[\n{bytecode}\n--]]`
				end

				local time_elapsed = os.clock() - konstant_last_call
				if time_elapsed <= .5 then
					task.wait(.5 - time_elapsed)
				end

				local httpResult = env.request({
					Url = API .. konstantType,
					Body = bytecode,
					Method = "POST",
					Headers = {
						["Content-Type"] = "text/plain"
					}
				})

				konstant_last_call = os.clock()

				if (httpResult.StatusCode ~= 200) then
					return `-- Error occurred while requesting Konstant API, error:\n\n--[[\n{httpResult.Body}\n--]]`
				else
					return httpResult.Body
				end
			end

			local function konstantDecompile(scriptPath)
				return call("/konstant/decompile", scriptPath)
			end

			return konstantDecompile(...)
		end
		local ADDec = AdvancedDecompilerCache or function() return "Failed to load Advanced Decompiler" end

		local function ShinyDec(script_instance)
			if typeof(crypt) ~= "table" then return "-- 'crypt' library is missing!" end
			local success, result = pcall(function()
				return game:HttpGet("http://127.0.0.1:"..tostring(Settings.Decompiler.ShinyDecompilerPort))
			end)
			if not success then return "-- Shiny decompiler is not active or port is wrong!" end

			local bytecode = getscriptbytecode(script_instance)
			local encoded = crypt.base64encode(bytecode)
			return env.request(
				{
					Url = "http://127.0.0.1:"..tostring(Settings.Decompiler.ShinyDecompilerPort).."/luau/decompile",
					Method = "POST",
					Body = encoded
				}
			).Body
		end
		env.decompile = function(...)
			if typeof(decompile) == "function" and Settings.Decompiler.PreferDecompilerFallback == false then
				return decompile(...)
			elseif typeof(getscriptbytecode) == "function" then
				local fallbackMode = Settings.Decompiler.DecompilerFallback
				
				if fallbackMode == "Konstant" then
					return KonstantDec(...)
				elseif fallbackMode == "AdvancedDecompiler" then
					return ADDec(...)
				elseif  fallbackMode == "Shiny" then
					return ShinyDec(...)
				end
			end
		end
		
		--[[if Main.Elevated then
			getgenv().decompile = env.decompile
		end]]
		

		if identifyexecutor then
			Main.Executor = identifyexecutor()
		end

		Main.GuiHolder = Main.Elevated and service.CoreGui or plr:FindFirstChildOfClass("PlayerGui")

		setmetatable(env,nil)
	end

	Main.IncompatibleTest = function()
		--[[local function incompatibleMessage(reason, tolerated)
			local msg = Instance.new("ScreenGui")
			msg.IgnoreGuiInset = true
			local t = Instance.new("TextLabel",msg)
			t.BackgroundColor3 = Color3.fromRGB(50,50,50)
			t.Position = UDim2.new(0,0,0,0)
			t.Size = UDim2.new(1,0,1,0)
			t.TextColor3 = Color3.new(1,1,1)
			t.TextWrapped = true
			t.TextScaled = true
			t.Text = "\n\n\n\n\n\n\n\nHello Skidsploit user,\nZinnia, Chillz and the Secret Service does not approve of Dex being used on your skidsploit.\nPlease consider getting something better.\n\nIncompatible Reason: "..reason.."\n\n\n\n\n\n\n\n"
			
			-- This sound wont work!!!
			local sound = Instance.new("Sound",msg)
			sound.SoundId = "rbxassetid://175964948"
			sound.Volume = 1
			sound.Looped = true
			sound.Playing = true
			
			if not tolerated then
				Lib.ShowGui(msg)
				
				if os and os.execute then pcall(os.execute,'explorer "https://weao.xyz"') end
				if pcall(game.GetService, game,"MessageBusService") and game:GetService("MessageBusService").Publish then pcall(game:GetService("MessageBusService").Publish, game:GetService("MessageBusService"), game:GetService("MessageBusService"):GetMessageId("Linking", "openURLRequest"), {url = 'explorer "https://weao.xyz"'}) end
			else
				warn(msg)
			end			
		end
		
																																													local yummy, evilList = "\105\100\101\110\116\105\102\121\101\120\101\99\117\116\111\114", { "\120\101\110\111", "\115\111\108\97\114\97", "\119\97\118\101" }
																																													if ggv and ggv()[yummy] then local wow = ggv()[yummy] if table.find(evilList, string.lower(wow)) then incompatibleMessage("\83\72\73\84\84\89\32\69\88\69\67\85\84\79\82") end end
																																													
		local t = {}
		t[1] = t
		local x = unpack(t) or incompatibleMessage("WRAPPER FAILED TO CYCLIC #1")
		if x[1] ~= t then incompatibleMessage("WRAPPER FAILED TO CYCLIC #2") end
		
		if game ~= workspace.Parent then
			incompatibleMessage("WRAPPER NO CACHE (game ≠ workspace.Parent)", true)
			game = workspace.Parent
		end
		
		if Main.Elevated and not loadstring("for i = 1,1 do continue end") then incompatibleMessage("CAN'T CONTINUE OR NO LOADSTRING")end
		
		local obj = newproxy(true)
		local mt = getmetatable(obj)
		mt.__index = function() incompatibleMessage("CAN'T NAMECALL (__index triggered instead of __namecall)") end
		mt.__namecall = function() end
		obj:No()
		
		local fEnv = setmetatable({zin = 5},{__index = getfenv()})
		local caller = function(f) f() end
		setfenv(caller,fEnv)
		caller(function() if not getfenv(2).zin then incompatibleMessage("RERU WILL BE FILING A LAWSUIT AGAINST YOU SOON") end end)
		
		local second = false
		coroutine.wrap(function() local start = tick() wait(5) if tick() - start < 0.1 or not second then incompatibleMessage("SKIDDED YIELDING") end end)()
		second = true]]
	end
	
	local function serialize(val)
		if typeof(val) == "Color3" then
			local serializedColor = {}
			serializedColor.R = val.R
			serializedColor.G = val.G
			serializedColor.B = val.B
			return serializedColor
		else
			return val
		end
	end
	
	local function deserialize(val)
		if typeof(val) == "table" then
			if val.R and val.G and val.B then
				return Color3.new(val.R, val.G, val.B)
			else
				return val
			end
		else
			return val
		end
	end
	
	Main.ExportSettings = function()
		local rawData = Settings or DefaultSettings

		local function recur(tbl)
			local newTbl = {}
			for i, v in pairs(tbl) do
				if typeof(v) == "table" then
					newTbl[i] = recur(v)
				else
					newTbl[i] = serialize(v)
				end
			end
			return newTbl
		end

		-- serialize color3 sebelum encode
		local serializedData = recur(rawData)

		local s, json = pcall(service.HttpService.JSONEncode, service.HttpService, serializedData)
		if s and json then
			return json
		end
	end


	--warn(Main.ExportSettings())

	Main.LoadSettings = function()
		local s, data = pcall(env.readfile or error, "DexPlusPlusSettings.json")
		if s and data and data ~= "" then
			
			local s, decoded = pcall(service.HttpService.JSONDecode, service.HttpService, data)
			if s and decoded then

				local function recur(tbl)
					local newTbl = {}
					for i, v in pairs(tbl) do
						if typeof(v) == "table" then
							newTbl[i] = deserialize(recur(v))
						else
							newTbl[i] = deserialize(v)
						end
					end
					return newTbl
				end

				local deserializedData = recur(decoded)

				-- Saved theme is from an older palette, drop it so the new default is used
				local migrated = false
				if deserializedData.ThemeVersion ~= DefaultSettings.ThemeVersion then
					deserializedData.Theme = nil
					deserializedData.ThemeVersion = DefaultSettings.ThemeVersion
					migrated = true
				end

				-- Merge instead of replace so settings added in newer versions keep their defaults
				local function merge(target, src)
					for k, v in pairs(src) do
						if type(v) == "table" and type(target[k]) == "table" then
							merge(target[k], v)
						else
							target[k] = v
						end
					end
				end
				merge(Settings, deserializedData)

				if migrated then Main.SaveCurrentSettings() end
			else
				warn("failed to decode settings json")
			end
		else
			Main.ResetSettings()
		end
	end

	
	

	Main.ResetSettings = function()
		local function recur(t,res)
			for set,val in pairs(t) do
				if type(val) == "table" and val._Recurse then
					if type(res[set]) ~= "table" then
						res[set] = {}
					end
					recur(val,res[set])
				else
					res[set] = type(val) == "table" and deepCopy(val) or val
				end
			end
			return res
		end
		recur(DefaultSettings,Settings)
	end

	Main.FetchAPI = function(callbackiflong, callbackiftoolong, XD)
		local downloaded = false
		local api,rawAPI
		if Main.Elevated then
			if Main.LocalDepsUpToDate() then
				local localAPI = Lib.ReadFile("dex/rbx_api.dat")
				if localAPI then 
					rawAPI = localAPI
				else
					Main.DepsVersionData[1] = ""
				end
			end
			task.spawn(function()
				task.wait(10)
				if not downloaded and callbackiflong then callbackiflong() end

				task.wait(20) -- 30
				if not downloaded and callbackiftoolong then callbackiftoolong() end

				task.wait(30) -- 60
				if not downloaded and XD then XD() end
			end)
			-- lmfao async makes it work to load big file
			rawAPI = rawAPI or game:HttpGet("http://setup.roblox.com/"..Main.RobloxVersion.."-API-Dump.json")
		else
			if script:FindFirstChild("API") then
				rawAPI = require(script.API)
			else
				error("NO API EXISTS")
			end
		end
		downloaded = true
		
		Main.RawAPI = rawAPI
		api = service.HttpService:JSONDecode(rawAPI)

		local classes,enums = {},{}
		local categoryOrder,seenCategories = {},{}

		local function insertAbove(t,item,aboveItem)
			local findPos = table.find(t,item)
			if not findPos then return end
			table.remove(t,findPos)

			local pos = table.find(t,aboveItem)
			if not pos then return end
			table.insert(t,pos,item)
		end

		for _,class in pairs(api.Classes) do
			local newClass = {}
			newClass.Name = class.Name
			newClass.Superclass = class.Superclass
			newClass.Properties = {}
			newClass.Functions = {}
			newClass.Events = {}
			newClass.Callbacks = {}
			newClass.Tags = {}

			if class.Tags then for c,tag in pairs(class.Tags) do newClass.Tags[tag] = true end end
			for __,member in pairs(class.Members) do
				local newMember = {}
				newMember.Name = member.Name
				newMember.Class = class.Name
				newMember.Security = member.Security
				newMember.Tags ={}
				if member.Tags then for c,tag in pairs(member.Tags) do newMember.Tags[tag] = true end end

				local mType = member.MemberType
				if mType == "Property" then
					local propCategory = member.Category or "Other"
					propCategory = propCategory:match("^%s*(.-)%s*$")
					if not seenCategories[propCategory] then
						categoryOrder[#categoryOrder+1] = propCategory
						seenCategories[propCategory] = true
					end
					newMember.ValueType = member.ValueType
					newMember.Category = propCategory
					newMember.Serialization = member.Serialization
					table.insert(newClass.Properties,newMember)
				elseif mType == "Function" then
					newMember.Parameters = {}
					newMember.ReturnType = member.ReturnType.Name
					for c,param in pairs(member.Parameters) do
						table.insert(newMember.Parameters,{Name = param.Name, Type = param.Type.Name})
					end
					table.insert(newClass.Functions,newMember)
				elseif mType == "Event" then
					newMember.Parameters = {}
					for c,param in pairs(member.Parameters) do
						table.insert(newMember.Parameters,{Name = param.Name, Type = param.Type.Name})
					end
					table.insert(newClass.Events,newMember)
				end
			end

			classes[class.Name] = newClass
		end

		for _,class in pairs(classes) do
			class.Superclass = classes[class.Superclass]
		end

		for _,enum in pairs(api.Enums) do
			local newEnum = {}
			newEnum.Name = enum.Name
			newEnum.Items = {}
			newEnum.Tags = {}

			if enum.Tags then for c,tag in pairs(enum.Tags) do newEnum.Tags[tag] = true end end
			for __,item in pairs(enum.Items) do
				local newItem = {}
				newItem.Name = item.Name
				newItem.Value = item.Value
				table.insert(newEnum.Items,newItem)
			end

			enums[enum.Name] = newEnum
		end

		local function getMember(class,member)
			if not classes[class] or not classes[class][member] then return end
			local result = {}

			local currentClass = classes[class]
			while currentClass do
				for _,entry in pairs(currentClass[member]) do
					result[#result+1] = entry
				end
				currentClass = currentClass.Superclass
			end

			table.sort(result,function(a,b) return a.Name < b.Name end)
			return result
		end

		insertAbove(categoryOrder,"Behavior","Tuning")
		insertAbove(categoryOrder,"Appearance","Data")
		insertAbove(categoryOrder,"Attachments","Axes")
		insertAbove(categoryOrder,"Cylinder","Slider")
		insertAbove(categoryOrder,"Localization","Jump Settings")
		insertAbove(categoryOrder,"Surface","Motion")
		insertAbove(categoryOrder,"Surface Inputs","Surface")
		insertAbove(categoryOrder,"Part","Surface Inputs")
		insertAbove(categoryOrder,"Assembly","Surface Inputs")
		insertAbove(categoryOrder,"Character","Controls")
		categoryOrder[#categoryOrder+1] = "Unscriptable"
		categoryOrder[#categoryOrder+1] = "Attributes"

		local categoryOrderMap = {}
		for i = 1,#categoryOrder do
			categoryOrderMap[categoryOrder[i]] = i
		end

		return {
			Classes = classes,
			Enums = enums,
			CategoryOrder = categoryOrderMap,
			GetMember = getMember
		}
	end

	Main.FetchRMD = function()
		local rawXML
		if Main.Elevated then
			if Main.LocalDepsUpToDate() then
				local localRMD = Lib.ReadFile("dex/rbx_rmd.dat")
				if localRMD then 
					rawXML = localRMD
				else
					Main.DepsVersionData[1] = ""
				end
			end
			rawXML = rawXML or game:HttpGet("https://raw.githubusercontent.com/CloneTrooper1019/Roblox-Client-Tracker/roblox/ReflectionMetadata.xml")
		else
			if script:FindFirstChild("RMD") then
				rawXML = require(script.RMD)
			else
				error("NO RMD EXISTS")
			end
		end
		Main.RawRMD = rawXML
		local parsed = Lib.ParseXML(rawXML)
		local classList = parsed.children[1].children[1].children
		local enumList = parsed.children[1].children[2].children
		local propertyOrders = {}

		local classes,enums = {},{}
		for _,class in pairs(classList) do
			local className = ""
			for _,child in pairs(class.children) do
				if child.tag == "Properties" then
					local data = {Properties = {}, Functions = {}}
					local props = child.children
					for _,prop in pairs(props) do
						local name = prop.attrs.name
						name = name:sub(1,1):upper()..name:sub(2)
						data[name] = prop.children[1].text
					end
					className = data.Name
					classes[className] = data
				elseif child.attrs.class == "ReflectionMetadataProperties" then
					local members = child.children
					for _,member in pairs(members) do
						if member.attrs.class == "ReflectionMetadataMember" then
							local data = {}
							if member.children[1].tag == "Properties" then
								local props = member.children[1].children
								for _,prop in pairs(props) do
									if prop.attrs then
										local name = prop.attrs.name
										name = name:sub(1,1):upper()..name:sub(2)
										data[name] = prop.children[1].text
									end
								end
								if data.PropertyOrder then
									local orders = propertyOrders[className]
									if not orders then orders = {} propertyOrders[className] = orders end
									orders[data.Name] = tonumber(data.PropertyOrder)
								end
								classes[className].Properties[data.Name] = data
							end
						end
					end
				elseif child.attrs.class == "ReflectionMetadataFunctions" then
					local members = child.children
					for _,member in pairs(members) do
						if member.attrs.class == "ReflectionMetadataMember" then
							local data = {}
							if member.children[1].tag == "Properties" then
								local props = member.children[1].children
								for _,prop in pairs(props) do
									if prop.attrs then
										local name = prop.attrs.name
										name = name:sub(1,1):upper()..name:sub(2)
										data[name] = prop.children[1].text
									end
								end
								classes[className].Functions[data.Name] = data
							end
						end
					end
				end
			end
		end

		for _,enum in pairs(enumList) do
			local enumName = ""
			for _,child in pairs(enum.children) do
				if child.tag == "Properties" then
					local data = {Items = {}}
					local props = child.children
					for _,prop in pairs(props) do
						local name = prop.attrs.name
						name = name:sub(1,1):upper()..name:sub(2)
						data[name] = prop.children[1].text
					end
					enumName = data.Name
					enums[enumName] = data
				elseif child.attrs.class == "ReflectionMetadataEnumItem" then
					local data = {}
					if child.children[1].tag == "Properties" then
						local props = child.children[1].children
						for _,prop in pairs(props) do
							local name = prop.attrs.name
							name = name:sub(1,1):upper()..name:sub(2)
							data[name] = prop.children[1].text
						end
						enums[enumName].Items[data.Name] = data
					end
				end
			end
		end

		return {Classes = classes, Enums = enums, PropertyOrders = propertyOrders}
	end

	Main.ShowGui = Main.SecureGui

	Main.CreateIntro = function(initStatus) -- TODO: Must theme and show errors
		local theme = Settings.Theme
		local rgb = Color3.fromRGB
		local mainCol = theme.Main1 or rgb(31,31,37)
		local holderCol = theme.Main2 or rgb(27,27,32)
		local textCol = theme.Text or rgb(227,230,242)
		local accent = theme.Accent or rgb(132,146,255)
		local corner = UDim.new(0,8)

		local gui = create({
			{1,"ScreenGui",{Name="Intro",}},
			{2,"Frame",{Active=true,BackgroundColor3=mainCol,BorderSizePixel=0,Name="Main",Parent={1},Position=UDim2.new(0.5,-175,0.5,-100),Size=UDim2.new(0,350,0,200),}},
			{3,"Frame",{BackgroundColor3=holderCol,BorderSizePixel=0,ClipsDescendants=true,Name="Holder",Parent={2},Size=UDim2.new(1,0,1,0),}},
			{4,"UIGradient",{Parent={3},Rotation=30,Transparency=NumberSequence.new({NumberSequenceKeypoint.new(0,1,0),NumberSequenceKeypoint.new(1,1,0),}),}},
			{5,"TextLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Font=4,Name="Title",Parent={3},Position=UDim2.new(0,-190,0,15),Size=UDim2.new(0,100,0,50),Text="Dex++",TextColor3=textCol,TextSize=50,TextTransparency=1,}},
			{6,"TextLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Font=3,Name="Desc",Parent={3},Position=UDim2.new(0,-230,0,60),Size=UDim2.new(0,180,0,25),Text="Ultimate Debugging Suite",TextColor3=textCol,TextSize=18,TextTransparency=1,}},
			{7,"TextLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Font=3,Name="StatusText",Parent={3},Position=UDim2.new(0,20,0,110),Size=UDim2.new(0,180,0,25),Text="Fetching API",TextColor3=textCol,TextSize=14,TextTransparency=1,}},
			{8,"Frame",{BackgroundColor3=mainCol,BorderSizePixel=0,Name="ProgressBar",Parent={3},Position=UDim2.new(0,110,0,145),Size=UDim2.new(0,0,0,4),}},
			{9,"Frame",{BackgroundColor3=accent,BorderSizePixel=0,Name="Bar",Parent={8},Size=UDim2.new(0,0,1,0),}},
			{10,"UICorner",{CornerRadius=UDim.new(1,0),Parent={8},}},
			{11,"TextLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Font=3,Name="Creator",Parent={2},Position=UDim2.new(1,-155,1,-20),Size=UDim2.new(0,150,0,20),Text="Developed by il4pt",TextColor3=textCol,TextSize=14,TextXAlignment=1,}},
			{12,"UIGradient",{Parent={11},Transparency=NumberSequence.new({NumberSequenceKeypoint.new(0,1,0),NumberSequenceKeypoint.new(1,1,0),}),}},
			{13,"TextLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Font=3,Name="Version",Parent={2},Position=UDim2.new(1,-155,1,-35),Size=UDim2.new(0,150,0,20),Text=Main.Version,TextColor3=textCol,TextSize=14,TextXAlignment=1,}},
			{14,"UIGradient",{Parent={13},Transparency=NumberSequence.new({NumberSequenceKeypoint.new(0,1,0),NumberSequenceKeypoint.new(1,1,0),}),}},
			-- Rounded outline: a stroke on a transparent frame, the gradient drives the same sweep animation the old image outline had
			{15,"Frame",{BackgroundTransparency=1,BorderSizePixel=0,Name="Outlines",Parent={2},Size=UDim2.new(1,0,1,0),}},
			{16,"UIStroke",{ApplyStrokeMode=Enum.ApplyStrokeMode.Border,Color=theme.WindowStroke or rgb(52,54,68),Thickness=1,Parent={15},}},
			{17,"UIGradient",{Parent={16},Rotation=-30,Transparency=NumberSequence.new({NumberSequenceKeypoint.new(0,1,0),NumberSequenceKeypoint.new(1,1,0),}),}},
			{18,"UIGradient",{Parent={2},Rotation=-30,Transparency=NumberSequence.new({NumberSequenceKeypoint.new(0,1,0),NumberSequenceKeypoint.new(1,1,0),}),}},
			{19,"UICorner",{CornerRadius=corner,Parent={2},}},
			{20,"UICorner",{CornerRadius=corner,Parent={3},}},
			{21,"UICorner",{CornerRadius=corner,Parent={15},}},
			{22,"UICorner",{CornerRadius=UDim.new(1,0),Parent={9},}},
			{23,"UIDragDetector", {Parent={2}}}
		})
		Main.ShowGui(gui)
		local backGradient = gui.Main.UIGradient
		local outlinesGradient = gui.Main.Outlines.UIStroke.UIGradient
		local holderGradient = gui.Main.Holder.UIGradient
		local titleText = gui.Main.Holder.Title
		local descText = gui.Main.Holder.Desc
		local versionText = gui.Main.Version
		local versionGradient = versionText.UIGradient
		local creatorText = gui.Main.Creator
		local creatorGradient = creatorText.UIGradient
		local statusText = gui.Main.Holder.StatusText
		local progressBar = gui.Main.Holder.ProgressBar
		local tweenS = service.TweenService

		local renderStepped = service.RunService.RenderStepped
		local signalWait = renderStepped.wait
		local fastwait = function(s)
			if not s then return signalWait(renderStepped) end
			local start = tick()
			while tick() - start < s do signalWait(renderStepped) end
		end

		statusText.Text = initStatus

		local function tweenNumber(n,ti,func)
			local tweenVal = Instance.new("IntValue")
			tweenVal.Value = 0
			tweenVal.Changed:Connect(func)
			local tween = tweenS:Create(tweenVal,ti,{Value = n})
			tween:Play()
			tween.Completed:Connect(function()
				tweenVal:Destroy()
			end)
		end

		local ti = TweenInfo.new(0.4,Enum.EasingStyle.Quad,Enum.EasingDirection.Out)
		tweenNumber(100,ti,function(val)
			val = val/200
			local start = NumberSequenceKeypoint.new(0,0)
			local a1 = NumberSequenceKeypoint.new(val,0)
			local a2 = NumberSequenceKeypoint.new(math.min(0.5,val+math.min(0.05,val)),1)
			if a1.Time == a2.Time then a2 = a1 end
			local b1 = NumberSequenceKeypoint.new(1-val,0)
			local b2 = NumberSequenceKeypoint.new(math.max(0.5,1-val-math.min(0.05,val)),1)
			if b1.Time == b2.Time then b2 = b1 end
			local goal = NumberSequenceKeypoint.new(1,0)
			backGradient.Transparency = NumberSequence.new({start,a1,a2,b2,b1,goal})
			outlinesGradient.Transparency = NumberSequence.new({start,a1,a2,b2,b1,goal})
		end)

		fastwait(0.4)

		tweenNumber(100,ti,function(val)
			val = val/166.66
			local start = NumberSequenceKeypoint.new(0,0)
			local a1 = NumberSequenceKeypoint.new(val,0)
			local a2 = NumberSequenceKeypoint.new(val+0.01,1)
			local goal = NumberSequenceKeypoint.new(1,1)
			holderGradient.Transparency = NumberSequence.new({start,a1,a2,goal})
		end)

		tweenS:Create(titleText,ti,{Position = UDim2.new(0,60,0,15), TextTransparency = 0}):Play()
		tweenS:Create(descText,ti,{Position = UDim2.new(0,20,0,60), TextTransparency = 0}):Play()

		local function rightTextTransparency(obj)
			tweenNumber(100,ti,function(val)
				val = val/100
				local a1 = NumberSequenceKeypoint.new(1-val,0)
				local a2 = NumberSequenceKeypoint.new(math.max(0,1-val-0.01),1)
				if a1.Time == a2.Time then a2 = a1 end
				local start = NumberSequenceKeypoint.new(0,a1 == a2 and 0 or 1)
				local goal = NumberSequenceKeypoint.new(1,0)
				obj.Transparency = NumberSequence.new({start,a2,a1,goal})
			end)
		end
		rightTextTransparency(versionGradient)
		rightTextTransparency(creatorGradient)

		fastwait(0.9)

		local progressTI = TweenInfo.new(0.25,Enum.EasingStyle.Quad,Enum.EasingDirection.Out)

		tweenS:Create(statusText,progressTI,{Position = UDim2.new(0,20,0,120), TextTransparency = 0}):Play()
		tweenS:Create(progressBar,progressTI,{Position = UDim2.new(0,60,0,145), Size = UDim2.new(0,100,0,4)}):Play()

		fastwait(0.25)

		local function setProgress(text,n)
			statusText.Text = text
			tweenS:Create(progressBar.Bar,progressTI,{Size = UDim2.new(n,0,1,0)}):Play()
		end

		local function close()
			tweenS:Create(titleText,progressTI,{TextTransparency = 1}):Play()
			tweenS:Create(descText,progressTI,{TextTransparency = 1}):Play()
			tweenS:Create(versionText,progressTI,{TextTransparency = 1}):Play()
			tweenS:Create(creatorText,progressTI,{TextTransparency = 1}):Play()
			tweenS:Create(statusText,progressTI,{TextTransparency = 1}):Play()
			tweenS:Create(progressBar,progressTI,{BackgroundTransparency = 1}):Play()
			tweenS:Create(progressBar.Bar,progressTI,{BackgroundTransparency = 1}):Play()

			tweenNumber(100,TweenInfo.new(0.4,Enum.EasingStyle.Back,Enum.EasingDirection.In),function(val)
				val = val/250
				local start = NumberSequenceKeypoint.new(0,0)
				local a1 = NumberSequenceKeypoint.new(0.6+val,0)
				local a2 = NumberSequenceKeypoint.new(math.min(1,0.601+val),1)
				if a1.Time == a2.Time then a2 = a1 end
				local goal = NumberSequenceKeypoint.new(1,a1 == a2 and 0 or 1)
				holderGradient.Transparency = NumberSequence.new({start,a1,a2,goal})
			end)

			fastwait(0.5)
			gui.Main.BackgroundTransparency = 1
			outlinesGradient.Rotation = 30

			tweenNumber(100,ti,function(val)
				val = val/100
				local start = NumberSequenceKeypoint.new(0,1)
				local a1 = NumberSequenceKeypoint.new(val,1)
				local a2 = NumberSequenceKeypoint.new(math.min(1,val+math.min(0.05,val)),0)
				if a1.Time == a2.Time then a2 = a1 end
				local goal = NumberSequenceKeypoint.new(1,a1 == a2 and 1 or 0)
				outlinesGradient.Transparency = NumberSequence.new({start,a1,a2,goal})
				holderGradient.Transparency = NumberSequence.new({start,a1,a2,goal})
			end)

			fastwait(0.45)
			gui:Destroy()
		end

		return {SetProgress = setProgress, Close = close, Object = gui}
	end

	Main.CreateApp = function(data)
		if Main.MenuApps[data.Name] then return end -- TODO: Handle conflict
		local control = {}

		local app = Main.AppTemplate:Clone()

		local iconIndex = data.Icon
		if data.IconMap and iconIndex then
			if type(iconIndex) == "number" then
				data.IconMap:Display(app.Main.Icon,iconIndex)
			elseif type(iconIndex) == "string" then
				data.IconMap:DisplayByKey(app.Main.Icon,iconIndex)
			end
		elseif type(iconIndex) == "string" then
			app.Main.Icon.Image = iconIndex
		else
			app.Main.Icon.Image = ""
		end

		local function updateState()
			app.Main.BackgroundTransparency = data.Open and 0 or (Lib.CheckMouseInGui(app.Main) and 0 or 1)
			app.Main.Highlight.Visible = data.Open
		end

		local function enable(silent)
			if data.Open then return end
			data.Open = true
			updateState()
			if not silent then
				if data.Window then data.Window:Show() end
				if data.OnClick then data.OnClick(data.Open) end
			end
		end

		local function disable(silent)
			if not data.Open then return end
			data.Open = false
			updateState()
			if not silent then
				if data.Window then data.Window:Hide() end
				if data.OnClick then data.OnClick(data.Open) end
			end
		end

		updateState()

		local ySize = service.TextService:GetTextSize(data.Name,14,Enum.Font.SourceSans,Vector2.new(62,999999)).Y
		app.Main.Size = UDim2.new(1,0,0,math.clamp(46+ySize,60,74))
		app.Main.AppName.Text = data.Name

		app.Main.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				Lib.SoftSet(app.Main,"BackgroundTransparency",0)
				Lib.SoftSet(app.Main,"BackgroundColor3",Settings.Theme.ButtonHover)
			end
		end)


		app.Main.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				Lib.SoftSet(app.Main,"BackgroundTransparency",data.Open and 0 or 1)
				Lib.SoftSet(app.Main,"BackgroundColor3",Settings.Theme.Button)
			end
		end)

		app.Main.MouseButton1Click:Connect(function()
			if data.Open then disable() else enable() end
		end)

		local window = data.Window
		if window then
			if Settings.Theme.SoftShapes and window.SetIcon and iconIndex then
				pcall(window.SetIcon,window,data.IconMap,iconIndex)
			end
			window.OnActivate:Connect(function() enable(true) end)
			window.OnDeactivate:Connect(function() disable(true) end)
		end

		app.Visible = true
		app.Parent = Main.AppsContainer
		Main.AppsFrame.CanvasSize = UDim2.new(0,0,0,Main.AppsContainerGrid.AbsoluteCellCount.Y*82 + 8)

		control.Enable = enable
		control.Disable = disable
		Main.MenuApps[data.Name] = control
		return control
	end

	Main.SetMainGuiOpen = function(val)
		Main.MainGuiOpen = val

		Main.MainGui.OpenButton.Text = val and "Close" or "Dex++"
		if val then Main.MainGui.OpenButton.MainFrame.Visible = true end
		Main.MainGui.OpenButton.MainFrame:TweenSize(val and UDim2.new(0,224,0,200) or UDim2.new(0,0,0,0),Enum.EasingDirection.Out,Enum.EasingStyle.Quad,0.2,true)
		--Main.MainGui.OpenButton.BackgroundTransparency = val and 0 or (Lib.CheckMouseInGui(Main.MainGui.OpenButton) and 0 or 0.2)
		service.TweenService:Create(Main.MainGui.OpenButton,TweenInfo.new(0.2,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{BackgroundTransparency = val and 0 or (Lib.CheckMouseInGui(Main.MainGui.OpenButton) and 0 or 0.2)}):Play()

		if Main.MainGuiMouseEvent then Main.MainGuiMouseEvent:Disconnect() end

		if not val then
			local startTime = tick()
			Main.MainGuiCloseTime = startTime
			coroutine.wrap(function()
				Lib.FastWait(0.2)
				if not Main.MainGuiOpen and startTime == Main.MainGuiCloseTime then Main.MainGui.OpenButton.MainFrame.Visible = false end
			end)()
		else
			Main.MainGuiMouseEvent = service.UserInputService.InputBegan:Connect(function(input)
				if (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) and not Lib.CheckMouseInGui(Main.MainGui.OpenButton) and not Lib.CheckMouseInGui(Main.MainGui.OpenButton.MainFrame) then

					Main.SetMainGuiOpen(false)
				end
			end)
		end
	end

	Main.CreateMainGui = function()
		local gui = create({
			{1,"ScreenGui",{IgnoreGuiInset=true,Name="MainMenu",}},
			{2,"TextButton",{AnchorPoint=Vector2.new(0.5,0),AutoButtonColor=false,BackgroundColor3=Color3.new(0.17647059261799,0.17647059261799,0.17647059261799),BorderSizePixel=0,Font=4,Name="OpenButton",Parent={1},Position=UDim2.new(0.5,0,0,2),Size=UDim2.new(0,55,0,32),Text="Dex++",TextColor3=Color3.new(1,1,1),TextSize=16,TextTransparency=0.20000000298023,}},
			{3,"UICorner",{CornerRadius=UDim.new(0,6),Parent={2},}},
			{4,"Frame",{AnchorPoint=Vector2.new(0.5,0),BackgroundColor3=Color3.new(0.17647059261799,0.17647059261799,0.17647059261799),ClipsDescendants=true,Name="MainFrame",Parent={2},Position=UDim2.new(0.5,0,1,-4),Size=UDim2.new(0,224,0,200),}},
			{5,"UICorner",{CornerRadius=UDim.new(0,6),Parent={4},}},
			{6,"Frame",{BackgroundColor3=Color3.new(0.20392157137394,0.20392157137394,0.20392157137394),Name="BottomFrame",Parent={4},Position=UDim2.new(0,0,1,-24),Size=UDim2.new(1,0,0,24),}},
			{7,"UICorner",{CornerRadius=UDim.new(0,6),Parent={6},}},
			{8,"Frame",{BackgroundColor3=Color3.new(0.20392157137394,0.20392157137394,0.20392157137394),BorderSizePixel=0,Name="CoverFrame",Parent={6},Size=UDim2.new(1,0,0,4),}},
			{9,"Frame",{BackgroundColor3=Color3.new(0.1294117718935,0.1294117718935,0.1294117718935),BorderSizePixel=0,Name="Line",Parent={8},Position=UDim2.new(0,0,0,-1),Size=UDim2.new(1,0,0,1),}},
			{10,"TextButton",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Font=3,Name="Settings",Parent={6},Position=UDim2.new(1,-48,0,0),Size=UDim2.new(0,24,1,0),Text="",TextColor3=Color3.new(1,1,1),TextSize=14,}},
			{11,"ImageLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Image="rbxassetid://6578871732",ImageTransparency=0.20000000298023,Name="Icon",Parent={10},Position=UDim2.new(0,4,0,4),Size=UDim2.new(0,16,0,16),}},
			{12,"TextButton",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Font=3,Name="Information",Parent={6},Position=UDim2.new(1,-24,0,0),Size=UDim2.new(0,24,1,0),Text="",TextColor3=Color3.new(1,1,1),TextSize=14,}},
			{13,"ImageLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Image="rbxassetid://6578933307",ImageTransparency=0.20000000298023,Name="Icon",Parent={12},Position=UDim2.new(0,4,0,4),Size=UDim2.new(0,16,0,16),}},
			{14,"ScrollingFrame",{Active=true,AnchorPoint=Vector2.new(0.5,0),BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,BorderColor3=Color3.new(0.1294117718935,0.1294117718935,0.1294117718935),BorderSizePixel=0,Name="AppsFrame",Parent={4},Position=UDim2.new(0.5,0,0,0),ScrollBarImageColor3=Color3.new(0,0,0),ScrollBarThickness=4,Size=UDim2.new(0,222,1,-25),}},
			{15,"Frame",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Name="Container",Parent={14},Position=UDim2.new(0,7,0,8),Size=UDim2.new(1,-14,0,2),}},
			{16,"UIGridLayout",{CellSize=UDim2.new(0,66,0,74),Parent={15},SortOrder=2,}},
			{17,"Frame",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Name="App",Parent={1},Size=UDim2.new(0,100,0,100),Visible=false,}},
			{18,"TextButton",{AutoButtonColor=false,BackgroundColor3=Color3.new(0.2352941185236,0.2352941185236,0.2352941185236),BorderSizePixel=0,Font=3,Name="Main",Parent={17},Size=UDim2.new(1,0,0,60),Text="",TextColor3=Color3.new(0,0,0),TextSize=14,}},
			{19,"ImageLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Image="rbxassetid://129589545519436",ImageRectSize=Vector2.new(32,32),Name="Icon",Parent={18},Position=UDim2.new(0.5,-16,0,4),ScaleType=4,Size=UDim2.new(0,32,0,32),}},
			{20,"TextLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,BorderSizePixel=0,Font=3,Name="AppName",Parent={18},Position=UDim2.new(0,2,0,38),Size=UDim2.new(1,-4,1,-40),Text="Explorer",TextColor3=Color3.new(1,1,1),TextSize=14,TextTransparency=0.10000000149012,TextTruncate=1,TextWrapped=true,TextYAlignment=0,}},
			{21,"Frame",{BackgroundColor3=Color3.new(0,0.66666668653488,1),BorderSizePixel=0,Name="Highlight",Parent={18},Position=UDim2.new(0,0,1,-2),Size=UDim2.new(1,0,0,2),}},
		})

		if Settings.Theme.SoftShapes then
			local tile = gui.App.Main
			Instance.new("UICorner",tile).CornerRadius = UDim.new(0,Settings.Theme.CornerRadius or 6)
			tile.Highlight.AnchorPoint = Vector2.new(0.5,1)
			tile.Highlight.Position = UDim2.new(0.5,0,1,-3)
			tile.Highlight.Size = UDim2.new(0.4,0,0,3)
			Instance.new("UICorner",tile.Highlight).CornerRadius = UDim.new(1,0)
		end
		Main.MainGui = gui
		Main.AppsFrame = gui.OpenButton.MainFrame.AppsFrame
		Main.AppsContainer = Main.AppsFrame.Container
		Main.AppsContainerGrid = Main.AppsContainer.UIGridLayout
		Main.AppTemplate = gui.App
		Main.MainGuiOpen = false

		local menuStroke = Instance.new("UIStroke")
		menuStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		menuStroke.Color = Settings.Theme.WindowStroke
		menuStroke.Transparency = 0.3
		menuStroke.Parent = gui.OpenButton.MainFrame

		local openButton = gui.OpenButton
		openButton.BackgroundTransparency = 0.2
		openButton.MainFrame.Size = UDim2.new(0,0,0,0)
		openButton.MainFrame.Visible = false
		openButton.MouseButton1Click:Connect(function()
			Main.SetMainGuiOpen(not Main.MainGuiOpen)
		end)

		openButton.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				service.TweenService:Create(Main.MainGui.OpenButton,TweenInfo.new(0,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{BackgroundTransparency = 0}):Play()
			end
		end)

		openButton.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				service.TweenService:Create(Main.MainGui.OpenButton,TweenInfo.new(0,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{BackgroundTransparency = Main.MainGuiOpen and 0 or 0.2}):Play()
			end
		end)
		
		local infoDexIntro, isInfoCD
		
		--openButton.MainFrame.BottomFrame.Settings.Visible = false
		
		openButton.MainFrame.BottomFrame.Settings.MouseButton1Click:Connect(function()
			if not SettingsWindow.Window.Closed then
				SettingsWindow.Window:Hide()
			else
				SettingsWindow.Window:Show()
			end		
		end)
		
		openButton.MainFrame.BottomFrame.Information.MouseButton1Click:Connect(function()
			local duration = 1
			local Infos = {
				"Soft Dark Edition by il4pt",
				"Contributors >>",
				"Chillz (Dex++)",
				"Toon (IY Dex and PRs)",
				"Moon (Dex)",
				"Cazan (3D Preview)",
			}
			
			if isInfoCD then return end
			isInfoCD = true
			if not infoDexIntro then
				infoDexIntro = Main.CreateIntro("Running")
				--Main.AppControls ~= {}
				coroutine.wrap(function()
					while infoDexIntro and openButton.Parent ~= nil do
						for i,text in Infos do
							if not infoDexIntro or openButton.Parent == nil then break end
							infoDexIntro.SetProgress(text,(1 / #Infos) * i)
							task.wait(duration)
						end
					end
				end)()
				
				Lib.FastWait(1.5)
				isInfoCD = false
			else
				coroutine.wrap(function()
					infoDexIntro.Close()
					infoDexIntro = nil
					
					Lib.FastWait(1.5)
					isInfoCD = false
				end)()
			end
		end)

		-- Create Main Apps
		Main.CreateApp({Name = "Explorer", IconMap = Main.LargeIcons, Icon = "Explorer", Open = true, Window = Explorer.Window})

		Main.CreateApp({Name = "Properties", IconMap = Main.LargeIcons, Icon = "Properties", Open = true, Window = Properties.Window})

		local cptsOnMouseClick = nil
		Main.CreateApp({Name = "Click part to select", IconMap = Explorer.ClassIcons, Icon = "SelectionBox", OnClick = function(callback)
			if callback then
				local mouse = Main.Mouse
				cptsOnMouseClick = mouse.Button1Down:Connect(function()
					pcall(function()
						local object = mouse.Target
						if nodes[object] then
							selection:Set(nodes[object])
							Explorer.ViewNode(nodes[object])
						end
					end)
				end)
			else if cptsOnMouseClick ~= nil then cptsOnMouseClick:Disconnect() cptsOnMouseClick = nil end end
		end})

		Main.CreateApp({Name = "Notepad", IconMap = Main.LargeIcons, Icon = "Script_Viewer", Window = ScriptViewer.Window})
		
		Main.CreateApp({Name = "Console", IconMap = Main.LargeIcons, Icon = "Executor", Window = Console.Window})
		
		Main.CreateApp({Name = "Save Instance", IconMap = Main.LargeIcons, Icon = "Book", Window = SaveInstance.Window})
		
		Main.CreateApp({Name = "3D Viewer", IconMap = Main.LargeIcons, Icon = "Object", Window = ModelViewer.Window})

		if ScriptAnalyzer and ScriptAnalyzer.Window then
			Main.CreateApp({Name = "Script Analyzer", IconMap = Main.LargeIcons, Icon = "Watcher", Window = ScriptAnalyzer.Window})
		end

		--Main.CreateApp({Name = "Secret Service Panel", IconMap = Main.LargeIcons, Icon = "Output", Window = SecretServicePanel.Window})
		
		for _, loadedplugin in pairs(Main.Plugins) do
			Main.CreateApp({Name = loadedplugin.PluginData.FriendlyName, IconMap = Explorer.ClassIcons, Icon = "Attachment", Window = loadedplugin.Window})
		end
		
		Lib.ShowGui(gui)
	end

	Main.SetupFilesystem = function()
		if not env.writefile or not env.makefolder then return end

		local writefile,makefolder = env.writefile,env.makefolder

		makefolder("dex")
		makefolder("dex/assets")
		makefolder("dex/saved")
		makefolder("dex/plugins")
		makefolder("dex/ModuleCache")
	end

	Main.SaveCurrentSettings = function()
		if writefile then
			writefile("DexPlusPlusSettings.json", Main.ExportSettings())
		end
	end

	Main.LocalDepsUpToDate = function()
		return Main.DepsVersionData and Main.ClientVersion == Main.DepsVersionData[1]
	end

	Main.Init = function()
		Main.Elevated = pcall(function() local a = game:GetService("CoreGui"):GetFullName() end)
		
		-- saves new settings if does not exist
		if isfile and not isfile("DexPlusPlusSettings.json") then
			Main.SaveCurrentSettings()
		end
		
		Main.InitEnv()
		Main.LoadSettings() -- loads the settings before init
		
		Main.SetupFilesystem()

		-- Load Lib
		local intro = Main.CreateIntro("Initializing Library")
		Lib = Main.LoadModule("Lib")
		Lib.FastWait()

		-- Init other stuff
		Main.IncompatibleTest()

		-- Init icons
		Main.MiscIcons = Lib.IconMap.new("rbxassetid://6511490623",256,256,16,16)
		Main.MiscIcons:SetDict({
			Reference = 0,             Cut = 1,                         Cut_Disabled = 2,      Copy = 3,               Copy_Disabled = 4,    Paste = 5,                Paste_Disabled = 6,
			Delete = 7,                Delete_Disabled = 8,             Group = 9,             Group_Disabled = 10,    Ungroup = 11,         Ungroup_Disabled = 12,    TeleportTo = 13,
			Rename = 14,               JumpToParent = 15,               ExploreData = 16,      Save = 17,              CallFunction = 18,    CallRemote = 19,          Undo = 20,
			Undo_Disabled = 21,        Redo = 22,                       Redo_Disabled = 23,    Expand_Over = 24,       Expand = 25,          Collapse_Over = 26,       Collapse = 27,
			SelectChildren = 28,       SelectChildren_Disabled = 29,    InsertObject = 30,     ViewScript = 31,        AddStar = 32,         RemoveStar = 33,          Script_Disabled = 34,
			LocalScript_Disabled = 35, Play = 36,                       Pause = 37,            Rename_Disabled = 38,   Empty = 1000
		})
		Main.LargeIcons = Lib.IconMap.new("rbxassetid://129589545519436",256,256,32,32)
		Main.LargeIcons:SetDict({
			Explorer = 0, Properties = 1, Script_Viewer = 2, Watcher = 3, Output = 4, ScriptEdit = 5, Book = 6, Executor = 7, Object = 8, Honey = 9
		})
		
		--[[ Loading bypasses
		intro.SetProgress("Loading Adonis Bypass",0.1)
		pcall(Main.LoadAdonisBypass)
		
		intro.SetProgress("Loading GC Bypass",0.2)
		pcall(Main.LoadGCBypass)]]

		-- Fetch version if needed
		intro.SetProgress("Fetching Roblox Version",0.3)
		if Main.Elevated then
			local fileVer = Lib.ReadFile("dex/deps_version.dat")
			Main.ClientVersion = Version()
			if fileVer then
				Main.DepsVersionData = string.split(fileVer,"\n")
				if Main.LocalDepsUpToDate() then
					Main.RobloxVersion = Main.DepsVersionData[2]
				end
			end
			
			Main.RobloxVersion = Main.RobloxVersion or oldgame:HttpGet("https://clientsettings.roblox.com/v2/client-version/WindowsStudio64/channel/LIVE"):match("(version%-[%w]+)")
		end

		-- Fetch external deps
		intro.SetProgress("Fetching API",0.35)
		API = Main.FetchAPI(
			function()
				intro.SetProgress("Fetching API, Please Wait.",0.4)
			end,
			function()
				intro.SetProgress("Fetching API, Please Wait Due To Huge API File To Download.",0.45)
			end,
			function()
				intro.SetProgress("Fetching API, LOL STILL DOWNlOADING? bad wifi xD",0.475)
			end
		)
		Lib.FastWait()
		intro.SetProgress("Fetching RMD",0.5)
		RMD = Main.FetchRMD()
		Lib.FastWait()

		-- Save external deps locally if needed
		if Main.Elevated and env.writefile and not Main.LocalDepsUpToDate() then
			env.writefile("dex/deps_version.dat",Main.ClientVersion.."\n"..Main.RobloxVersion)
			env.writefile("dex/rbx_api.dat",Main.RawAPI)
			env.writefile("dex/rbx_rmd.dat",Main.RawRMD)
		end

		-- Load other modules
		intro.SetProgress("Loading Modules",0.75)
		Main.AppControls.Lib.InitDeps(Main.GetInitDeps()) -- Missing deps now available
		Main.LoadModules()
		Lib.FastWait()

		-- Init other modules
		intro.SetProgress("Initializing Modules",0.8)
		Explorer.Init()
		Properties.Init()
		ScriptViewer.Init()
		Console.Init()
		SaveInstance.Init()
		ModelViewer.Init()
		SettingsWindow.Init()
		if ScriptAnalyzer then
			local s,e = pcall(ScriptAnalyzer.Init)
			if not s then
				warn("[Dex-] Script Analyzer disabled: "..tostring(e))
				ScriptAnalyzer = nil
				Apps.ScriptAnalyzer = nil
			end
		end
		--SecretServicePanel.Init()
		
		
		if env.readfile and listfiles then
			if #listfiles("dex/plugins") > 0 then
				intro.SetProgress("Loading Plugin Files",0.8)
				for _, pluginDir in pairs(listfiles("dex/plugins")) do
					-- A broken plugin should not take the whole explorer down with it
					local s, e = pcall(function()
						local moduleData = Main.LoadPluginFile(pluginDir)
						moduleData.PluginData = moduleData.PluginData or {}

						moduleData.Init()

						local pluginFriendlyName = moduleData.PluginData.FriendlyName or moduleData.Window.GuiElems.Title.Text or "Unnamed Plugin"
						local pluginName = moduleData.PluginData.Name or moduleData.Window.GuiElems.Title.Text:gsub(" ", "") or "unnamedPlugin"

						intro.SetProgress("Initializing Plugin: ".. pluginFriendlyName,0.9)

						moduleData.PluginData.Name = pluginName
						moduleData.PluginData.FriendlyName = pluginFriendlyName

						table.insert(Main.Plugins, moduleData)
					end)
					if not s then
						warn("[Dex++] Failed to load plugin "..tostring(pluginDir)..": "..tostring(e))
					end
				end
			end	
		end
		
		
		Lib.FastWait()

		-- Done
		intro.SetProgress("Complete",1)
		coroutine.wrap(function()
			Lib.FastWait(1.25)
			intro.Close()
		end)()

		-- Init window system, create main menu, show explorer and properties
		Lib.Window.Init()
		Main.CreateMainGui()
		Explorer.Window:Show({Align = "right", Pos = 1, Size = 0.5, Silent = true})
		Properties.Window:Show({Align = "right", Pos = 2, Size = 0.5, Silent = true})
		
		Lib.DeferFunc(function() Lib.Window.ToggleSide("right") end)

		Main.SetupToggleKey()
		pcall(Main.InitTelemetry)
	end

	Main.Uninit = function()
		if Main.ToggleKeyConnection then Main.ToggleKeyConnection:Disconnect() Main.ToggleKeyConnection = nil end
		Main.GuiVisible = true
		Main.MenuApps = {}
		Main.AppControls = {}
		Main.Plugins = {}
		for _, gui in pairs(Main.GetSecureContainer():GetChildren()) do
			if string.sub(gui.Name,1,5) == "_DPP_" then -- DPP stands for DexPlusPlus
				gui:Destroy()
			end
		end
	end

	Main.Reinit = function()
		Main.Uninit()
		task.wait()
		Main.Init()
	end

	return Main
end)()

-- Start
Main.Init()

--for i,v in pairs(Main.MissingEnv) do print(i,v) end
