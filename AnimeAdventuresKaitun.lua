-- Anime Adventures - Kaitun (single-hosted-script rewrite)
-- Game: [UPD 21] Anime Adventures - lobby place 8304191830
--
-- The only Kaitun script hosted in this repo; loader.lua downloads it and
-- re-queues it on every teleport. Always fetched over HTTP - no executor
-- workspace copy is used. Detects lobby vs match by itself.
--
-- LOBBY (each visit, after waiting for the game to finish loading)
--   1. redeem level-gated codes (verified against profile.redeemed_codes)
--   2. celestial compass pick - only while the summon GUI slot is empty
--   3. claim daily login / board missions / level rewards / quests / battlepass
--   4. one 10x summon per account (saved to AAKaitun_<UserId>.json)
--   5. equip the configured Team, otherwise the best owned units
--   6. auto sell spare units (see AUTO SELL below)
--   7. trait reroll on the compass unit once it is owned (see TRAITS below)
--   8. planner, in this order:
--        hunt when gems >= HuntFrom and the compass unit is missing
--        daily challenge  (level 25+)
--        normal challenge (level 15+)
--        level <  TargetLevel -> story act 1 solo, vote lose at wave 6, replay
--        level >= TargetLevel -> world skip to act 6, full clear, leave, then
--                                Infinite vote-lose loop
--
-- MATCH
--   vote start only while the real vote popup is open (votes start once),
--   scan the lane once, place combat units then farms, upgrade by priority,
--   vote wave skip, vote lose at LoseWave in loop modes, then fire exactly one
--   end-of-match decision: replay the loop, or leave to the lobby.
--   optimizer.lua is embedded verbatim as the FPS booster and runs ONLY here.
--
-- TRAITS
--   once CompassUnit is owned: reroll traits with tokens -> star remnants ->
--   limited remnants, always keeping Unique. Re-reads the unit before each
--   roll, stops on Unique or when reroll resources run out. Runs once per unit
--   (saved to disk).
--
-- AUTO SELL
--   after summoning / hunting and on each lobby visit. Never sells locked,
--   equipped, level > 1, or Mythic/Secret units. Keeps one copy of every
--   configured Team/Compass unit and sells the rest (batches of 50).
--
-- UI
--   small lobby status card; full-screen black-screen stats dashboard in
--   matches with a bottom-right ON/OFF toggle. Choice persists between servers.
--
-- CONFIG: edit Config below or set getgenv().Kaitun before running. Any key
--   you leave out keeps its Config default. Accepted getgenv keys: TargetLevel,
--   CompassUnit, Team, RollAtGems, SaveGems, Challenges,
--   ChallengesOnlyAfterCompass, FpsBoost, AutoSell, SkipCutscenes, StatsOverlay,
--   Summon, LoseWave, AutoTrait, TraitKeep, TraitSources, TraitMinResources.
-- Debug: getgenv().AAKaitun (State/Lobby/Match/Account), getgenv().AAKaitunStop.
-- end header

-- ============================================================================
-- boot
-- ============================================================================
if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")
local GroupService = game:GetService("GroupService")
local AvatarEditorService = game:GetService("AvatarEditorService")
local GuiService = game:GetService("GuiService")
local VirtualInputManager = game:GetService("VirtualInputManager")

local GetHui = type(gethui) == "function" and gethui or nil
local FireSignal = type(firesignal) == "function" and firesignal or nil

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local Env = (getgenv and getgenv()) or _G

-- The loader queues itself AND the script queues BootCode for the next server,
-- so two copies can start in the same place and race on spawn/upgrade remotes.
-- PlayerGui is fresh after a teleport, so a marker here is a safe one-per-server
-- guard that does not survive into the next match.
if PlayerGui:FindFirstChild("AAKaitunRunning") then
	print("[AA Kaitun] duplicate instance - exiting")
	return
end
do
	local Marker = Instance.new("ScreenGui")
	Marker.Name = "AAKaitunRunning"
	Marker.ResetOnSpawn = false
	Marker.Enabled = false
	Marker.Parent = PlayerGui
end

local function Log(Format, ...)
	print(("[AA Kaitun] " .. Format):format(...))
end

-- Organised logging: every line carries a short category tag so a busy console
-- is readable at a glance.
local function LogT(Tag, Format, ...)
	print(("[AA Kaitun][%s] " .. Format):format(Tag, ...))
end

-- game modules ---------------------------------------------------------------
local Loader = require(ReplicatedStorage:WaitForChild("src"):WaitForChild("Loader"))

local function SafeLoad(Kind, Name)
	local Ok, Result = pcall(Loader[Kind], nil, Name)
	return Ok and Result or nil
end

-- the client bootstrap only registers its services after SERVER_READY flips
local BootDeadline = os.clock() + 90
repeat
	local Flag = workspace:FindFirstChild("SERVER_READY")
	if Flag and Flag.Value == true then
		break
	end
	task.wait(0.5)
until os.clock() >= BootDeadline
task.wait(0.5)

local EndpointsClient
local LoadDeadline = os.clock() + 30
repeat
	EndpointsClient = SafeLoad("load_client_service", "EndpointsClient")
	if EndpointsClient then
		break
	end
	task.wait(0.5)
until os.clock() >= LoadDeadline
if not EndpointsClient then
	warn("[AA Kaitun] EndpointsClient never loaded - wrong game or stuck bootstrap")
	return
end

local InvokeServer = EndpointsClient.invoke_server
local LobbyServiceClient = SafeLoad("load_client_service", "LobbyServiceClient")
local LevelServiceCore = SafeLoad("load_core_service", "LevelServiceCore")
local UnitServiceCore = SafeLoad("load_core_service", "UnitServiceCore")

local Units = SafeLoad("load_data", "Units") or {}
local Attacks = SafeLoad("load_data", "Attacks") or {}
local Worlds = SafeLoad("load_data", "Worlds") or {}
local Levels = SafeLoad("load_data", "Levels") or {}
local WorldLevelOrder = SafeLoad("load_data", "WorldLevelOrder") or {}
local Banners = SafeLoad("load_data", "Banners") or {}
local GameplaySettings = SafeLoad("load_data", "GameplaySettings") or {}
local PlayerLevelRewards = SafeLoad("load_data", "PlayerLevelRewards") or {}
local Traits = SafeLoad("load_data", "Traits") or {}

-- ============================================================================
-- config
-- ============================================================================
local Config = {
	-- progression ------------------------------------------------------------
	TargetLevel = 50,             -- below this: story loop, at/above: act 6 clear then Infinite
	StoryAct = 1,                 -- act of the first story world used for the loop
	SkipStory = true,             -- at TargetLevel, skip acts 1-5 and clear act 6 first
	SkipWorld = nil,              -- world to skip; nil = first story world
	SkipAct = nil,                -- act to clear; nil = last act (act 6)
	LoseWave = 6,                 -- vote lose at this wave in loop modes (0 = off)
	NormalChallengeLevel = 15,
	DailyChallengeLevel = 25,
	DoChallenges = true,
	DoInfinite = true,

	-- summoning / hunting ----------------------------------------------------
	Summon10Once = true,          -- one 10x roll per account (saved to disk)
	SummonBanner = "EventClover",
	HuntFrom = 20000,             -- go hunting when gems reach this
	-- hunt window by default is minute 01-49 (XX:50 -> XX:00 is blocked).
	-- setting any of these overrides the window with those exact minutes.
	HuntAtMinute = nil,
	HuntAtMinute2 = nil,
	HuntAtMinute3 = nil,
	HuntAtMinute4 = nil,
	KeepGems = 0,                 -- never roll below this
	MaxHuntRolls = 400,
	CompassUnit = "elyssia",      -- the celestial compass pick (nil = skip)
	CompassId = "celestial_compass_u21",

	-- team -------------------------------------------------------------------
	Team = nil,                   -- e.g. { "bulby", "windsong" }; nil = best units
	EquipTeam = true,

	-- lobby chores -----------------------------------------------------------
	-- group + favorite are retried while the social compass code is unredeemed
	JoinGroup = true,
	ForceCodes = false,          -- true = ignore the per-code level gates
	GroupId = 10611639,
	GroupName = "Gomu",
	FavoriteCode = "CELESTIALCOMPASSU21",
	RedeemCodes = true,
	Codes = {
		{ "2MILLIONFAVES", 20 },
		{ "SUMMERCOMEBACK", 20 },
		{ "CELESTIALCOMPASSU21" },
		{ "AACOMEBACK", 10 },
		{ "DUNGEONS" },
		{ "UPDATESOON5189" },
		{ "APRILFOOLS", 20 },
		{ "MILLIONFAVES", 20 },
		{ "2BILLIONAA", 50 },
	},
	Claims = true,                -- daily / missions / quests / levels / battlepass
	AcceptMissions = true,        -- start untaken daily board missions

	-- match placement --------------------------------------------------------
	Percent = 5,                  -- scan centre: % along the enemy path
	NodeSpacing = 2.5,
	RadiusGround = 40,
	RadiusHill = 40,
	RadiusFarm = 10,              -- extra ring outside RadiusGround for farms
	FarmTerrain = "ground",
	DefaultRange = 8,
	RangeSafety = 0.8,
	MaxPlaceRadius = 28,
	MaxFarmPlaceRadius = 45,
	MinCombatFirst = 2,           -- combat units placed before any farm
	FarmQuota = 3,
	PlaceUntilFull = true,        -- place while something is placeable
	ClaimSeconds = 3,
	RejectCooldown = 10,
	BlockedCooldown = 20,
	RescanAfterFails = 3,
	UpgradesPerTick = 3,
	ActionDelay = 0.5,

	-- votes ------------------------------------------------------------------
	VoteStart = true,
	VoteSkip = true,

	-- quality of life --------------------------------------------------------
	-- the FPS optimizer is embedded verbatim and only runs inside matches
	SkipCutscenes = true,
	ShowStatus = true,            -- small lobby status card
	StatsOverlay = true,          -- black screen + full stats panel in matches
	AutoSell = true,              -- sell spare units so the inventory never fills
	FpsBoost = true,              -- run the embedded FPS optimizer inside matches
	ChallengesOnlyAfterCompass = false, -- once the compass unit is owned, stop
	                             -- joining story/infinite (challenges still run)
	MatchmakingRetries = 4,
	MatchmakingCooldown = 20,   -- wait after a timed-out queue before requeueing
	QueueTimeout = 300,         -- leave the queue after 5 minutes still unjoined

	-- auto trait reroll (compass unit; Unique is always kept) ----------------
	AutoTrait = true,
	TraitKeep = { "unique" },
	TraitSources = { "token", "star_remnant", "star_remnant_limited" },
	TraitMinResources = 0,
	TraitRollDelay = 0.25,
	TraitChangeTimeout = 5,
}

-- Normalize the AutoTrait toggle. getgenv can be changed mid-session, and
-- values may arrive as booleans, numbers or strings - treat anything other
-- than true/1/"true" as OFF so setting false actually stops the rolls.
local function AutoTraitValue(Value)
	if type(Value) == "boolean" then
		return Value
	end
	if type(Value) == "number" then
		return Value ~= 0
	end
	if type(Value) == "string" then
		local S = Value:lower()
		return S == "true" or S == "1" or S == "yes"
	end
	return false
end

-- Live toggle: read getgenv on every check so a mid-session change takes
-- effect immediately (the baked-in BootCode config only applies on teleport).
local function AutoTraitEnabled()
	local Live = Env.Kaitun
	if type(Live) == "table" and Live.AutoTrait ~= nil then
		return AutoTraitValue(Live.AutoTrait)
	end
	return Config.AutoTrait == true
end

-- getgenv().Kaitun overrides (same names people already use) ------------------
local User = Env.Kaitun
if type(User) == "table" then
	local function Num(Value)
		return tonumber(Value)
	end
	if Num(User.TargetLevel) then Config.TargetLevel = math.floor(Num(User.TargetLevel)) end
	if Num(User.RollAtGems) then Config.HuntFrom = Num(User.RollAtGems) end
	if Num(User.HuntAtMinute) then Config.HuntAtMinute = math.floor(Num(User.HuntAtMinute)) end
	if Num(User.HuntAtMinute2) then Config.HuntAtMinute2 = math.floor(Num(User.HuntAtMinute2)) end
	if Num(User.HuntAtMinute3) then Config.HuntAtMinute3 = math.floor(Num(User.HuntAtMinute3)) end
	if Num(User.HuntAtMinute4) then Config.HuntAtMinute4 = math.floor(Num(User.HuntAtMinute4)) end
	if Num(User.SaveGems) then Config.KeepGems = Num(User.SaveGems) end
	if User.CompassUnit ~= nil then Config.CompassUnit = tostring(User.CompassUnit):lower() end
	if type(User.Team) == "table" then Config.Team = User.Team end
	if User.Challenges ~= nil then Config.DoChallenges = User.Challenges and true or false end
	if User.ChallengesOnlyAfterCompass ~= nil then
		Config.ChallengesOnlyAfterCompass = User.ChallengesOnlyAfterCompass and true or false
	end
	if User.FpsBoost ~= nil then Config.FpsBoost = User.FpsBoost and true or false end
	if User.StatsOverlay ~= nil then
		Config.StatsOverlay = User.StatsOverlay and true or false
		Config.ShowStatus = Config.StatsOverlay
	end
	if User.AutoSell ~= nil then
		Config.AutoSell = User.AutoSell and true or false
	end
	if User.SkipCutscenes ~= nil then Config.SkipCutscenes = User.SkipCutscenes and true or false end
	if User.Summon ~= nil then Config.Summon10Once = User.Summon and true or false end
	if Num(User.LoseWave) then Config.LoseWave = math.floor(Num(User.LoseWave)) end
	if User.AutoTrait ~= nil then Config.AutoTrait = AutoTraitValue(User.AutoTrait) end
	if type(User.TraitKeep) == "table" then Config.TraitKeep = User.TraitKeep end
	if type(User.TraitSources) == "table" then Config.TraitSources = User.TraitSources end
	if Num(User.TraitMinResources) then Config.TraitMinResources = math.floor(Num(User.TraitMinResources)) end
end

-- survive lobby <-> match teleports ------------------------------------------
-- The queued stub ALWAYS reloads the hosted script over HTTP - there is no
-- local executor-workspace copy or fallback, so a stale cached file can never
-- replace the version you published. The user config is embedded because
-- getgenv() is wiped on teleport in some executors.
local SCRIPT_URL = Env.AAKaitunUrl
	or "https://raw.githubusercontent.com/inCythe/AnimeAdventuresKaitun/main/AnimeAdventuresKaitun.lua"
-- The JSON contains double quotes, so it cannot be pasted straight into a Lua
-- string literal (that was the "Expected ')' ... got 'RollAtGems'" teleport
-- error). %q escapes it; the function form of gsub also keeps any '%' literal.
local OkJson, UserJson = pcall(function()
	return HttpService:JSONEncode(type(User) == "table" and User or {})
end)
if not OkJson then
	UserJson = "{}"
end
local BootCode = [[
getgenv().Kaitun = game:GetService("HttpService"):JSONDecode(__CFG__)
local ok, src = pcall(game.HttpGet, game, __URL__)
local fn = ok and type(src) == "string" and loadstring(src) or nil
if fn then task.spawn(fn) else warn("[AA Kaitun] reload failed - HTTP fetch failed") end
]]
BootCode = BootCode:gsub("__CFG__", function() return string.format("%q", UserJson) end)
BootCode = BootCode:gsub("__URL__", function() return string.format("%q", SCRIPT_URL) end)

pcall(function()
	if type(queue_on_teleport) == "function" then
		queue_on_teleport(BootCode)
	end
end)


-- ============================================================================
-- state (persisted, tiny on purpose)
-- ============================================================================
local State = {
	Summoned = false,   -- the one-time 10x was done
	Compass = false,    -- the compass pick was used
	CompassDone = false, -- same flag, name used by the older hosted build
	Clear = {},         -- challenge mode -> uuid already handled
	TraitRoll = {},     -- unit id -> { doneAt, gotUnique, traits, rolls }
	BlackScreen = true, -- the old overlay's persisted black-screen switch
	Current = nil,      -- { Kind = "story"|"infinite"|"challenge", ... } for the match
}

local StateFile = "AAKaitun_" .. tostring(Player.UserId) .. ".json"

local function SaveState()
	if type(writefile) == "function" then
		pcall(writefile, StateFile, HttpService:JSONEncode(State))
	end
end

local function LoadState()
	if not (type(isfile) == "function" and isfile(StateFile) and type(readfile) == "function") then
		return
	end
	local Ok, Data = pcall(function()
		return HttpService:JSONDecode(readfile(StateFile))
	end)
	if Ok and type(Data) == "table" then
		for Key, Value in pairs(Data) do
			State[Key] = Value
		end
	end
	if type(State.Clear) ~= "table" then
		State.Clear = {}
	end
	if type(State.TraitRoll) ~= "table" then
		State.TraitRoll = {}
	end
end

-- ============================================================================
-- utilities
-- ============================================================================
local Util = {}

-- run anything on its own thread: a few remotes never return on bad arguments
function Util.Call(Timeout, Fn, ...)
	local Args = table.pack(...)
	local Done, Ok, Result = false, nil, nil
	task.spawn(function()
		Ok, Result = pcall(Fn, table.unpack(Args, 1, Args.n))
		Done = true
	end)
	local Deadline = os.clock() + Timeout
	while not Done and os.clock() < Deadline do
		task.wait(0.05)
	end
	if not Done then
		return false, "timeout"
	end
	return Ok, Result
end

local C2S
function Util.Endpoint(Name)
	if not C2S or not C2S.Parent then
		local Root = ReplicatedStorage:FindFirstChild("endpoints")
		C2S = Root and Root:FindFirstChild("client_to_server")
	end
	local Ep = C2S and C2S:FindFirstChild(Name)
	return Ep
end

-- server endpoints (vote_*, teleport_back_to_lobby, ...) are RemoteFunctions
function Util.Fire(Name, ...)
	local Ep = Util.Endpoint(Name)
	if not Ep or not Ep:IsA("RemoteFunction") then
		return nil
	end
	local Ok, Result = pcall(Ep.InvokeServer, Ep, ...)
	return Ok and Result or nil
end

-- invoke_server wrapper: returns result, completed
function Util.Invoke(Name, ...)
	local Ok, Result = Util.Call(15, InvokeServer, Name, ...)
	if not Ok then
		Log("%s failed: %s", Name, tostring(Result))
		return nil, false
	end
	return Result, true
end

-- wait until Read() differs from Before; nil on timeout
function Util.Changed(Read, Before, Timeout)
	local Deadline = os.clock() + (Timeout or 3)
	repeat
		task.wait(0.15)
		local Value = Read()
		if Value ~= Before then
			return Value
		end
	until os.clock() >= Deadline
	return nil
end

function Util.Count(Table)
	local N = 0
	if type(Table) == "table" then
		for _ in pairs(Table) do
			N += 1
		end
	end
	return N
end

function Util.Set(List)
	local Out = {}
	for _, Value in ipairs(List or {}) do
		Out[tostring(Value)] = true
	end
	return Out
end

-- CFrame that looks at a flat target; safe when the points coincide
function Util.LookAt(Position, Target)
	local Flat = Vector3.new(Target.X, Position.Y, Target.Z)
	if (Flat - Position).Magnitude < 0.05 then
		return CFrame.new(Position)
	end
	return CFrame.lookAt(Position, Flat)
end

-- ============================================================================
-- account reads
-- ============================================================================
local Account = {}

function Account.Profile()
	local Session = EndpointsClient.session
	return Session and Session.profile_data or {}
end

function Account.Collection()
	return Account.Profile().collection or {}
end

function Account.Gems()
	local Stats = Player:FindFirstChild("_stats")
	local Value = Stats and Stats:FindFirstChild("gem_amount")
	if Value then
		return math.floor(tonumber(Value.Value) or 0)
	end
	return math.floor(tonumber(Account.Profile().gem_amount) or 0)
end

function Account.Money()
	local Stats = Player:FindFirstChild("_stats")
	local Value = Stats and Stats:FindFirstChild("resource")
	return Value and tonumber(Value.Value) or 0
end

function Account.Xp()
	local Stats = Player:FindFirstChild("_stats")
	local Value = Stats and Stats:FindFirstChild("player_xp")
	if Value and Value:IsA("ValueBase") then
		return tonumber(Value.Value)
	end
	return tonumber(Account.Profile().player_xp)
end

function Account.Level()
	local Xp = Account.Xp()
	if not Xp or not LevelServiceCore then
		return 1
	end
	for _, Arg in ipairs({ 1, Player }) do
		local Ok, Level = pcall(LevelServiceCore.calculate_level, Arg, Xp)
		if Ok and tonumber(Level) then
			return math.floor(tonumber(Level))
		end
	end
	return 1
end

-- unit ids from the config are matched case-insensitively against the data
local UnitIdLookup
function Account.UnitId(Id)
	if Id == nil then
		return nil
	end
	local Raw = tostring(Id)
	if Units[Raw] then
		return Raw
	end
	if not UnitIdLookup then
		UnitIdLookup = {}
		for Key, Def in pairs(Units) do
			local Lower = tostring(Key):lower()
			UnitIdLookup[Lower] = Key
			local Name = type(Def) == "table" and Def.name
			if type(Name) == "string" then
				UnitIdLookup[Name:lower()] = Key
			end
		end
	end
	return UnitIdLookup[Raw:lower()] or Raw
end

function Account.UnitName(Id)
	local Def = Units[Id]
	local Name = type(Def) == "table" and Def.name
	return type(Name) == "string" and Name or tostring(Id)
end

-- The game stores the actual celestial compass pick on the profile. Use that
-- instead of the config value; UnitId resolves both ids and display names.
function Account.CompassUnit()
	local Picked = Account.Profile()._celestial_compass_pick
	if type(Picked) == "string" and Picked ~= "" then
		return Account.UnitId(Picked)
	end
	return Config.CompassUnit and Account.UnitId(Config.CompassUnit) or nil
end

function Account.HasUnit(Id)
	if not Id then
		return false
	end
	local Wanted = Account.UnitId(Id)
	for _, Unit in pairs(Account.Collection().owned_units or {}) do
		if type(Unit) == "table" and (Unit.unit_id == Wanted or Unit.unit_id == Id) then
			return true
		end
	end
	local Stats = Account.Profile()._hatched_unit_stats
	if type(Stats) == "table" then
		for UnitId in pairs(Stats) do
			if UnitId == Wanted or UnitId == Id then
				return true
			end
		end
	end
	return false
end

-- wait until the collection actually replicated (fresh joins are empty at first)
function Account.WaitCollection(Timeout)
	local Deadline = os.clock() + (Timeout or 30)
	while os.clock() < Deadline do
		local Coll = Account.Collection()
		if type(Coll.owned_units) == "table" and next(Coll.owned_units) ~= nil then
			return true
		end
		task.wait(0.25)
	end
	return false
end

function Account.WaitSession(Timeout)
	local Deadline = os.clock() + (Timeout or 90)
	while os.clock() < Deadline do
		local Session = EndpointsClient.session
		if Session and Session.profile_data then
			return true
		end
		task.wait(0.5)
	end
	return false
end


-- ============================================================================
-- status UI: lobby card + the original black-screen stats dashboard
-- ============================================================================
local UI = { StatusLabel = nil, Last = "" }

function UI.Set(Message)
	if UI.StatusLabel and UI.StatusLabel.Parent then
		UI.StatusLabel.Text = "Working - " .. tostring(Message)
	end
end
function UI.Clear()
	local Gui = PlayerGui:FindFirstChild("AAKaitunLobby")
	if Gui then
		Gui:Destroy()
	end
	UI.StatusLabel = nil
end
function UI.Lobby()
	local function ResetLeft()
		return 1800 - (os.time() % 1800)
	end
	local Old = PlayerGui:FindFirstChild("AAKaitunLobby")
	if Old then
		Old:Destroy()
	end
	local Tween = game:GetService("TweenService")

	local Gui = Instance.new("ScreenGui")
	Gui.Name = "AAKaitunLobby"
	Gui.ResetOnSpawn = false
	Gui.IgnoreGuiInset = true
	Gui.DisplayOrder = 9999
	Gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	Gui.Parent = PlayerGui

	local function New(Class, Props, Parent)
		local Item = Instance.new(Class)
		for Key, Value in pairs(Props) do
			Item[Key] = Value
		end
		Item.Parent = Parent
		return Item
	end

	local Card = New("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 16, 1, -16),
		Size = UDim2.fromOffset(300, 92),
		BackgroundColor3 = Color3.fromRGB(12, 15, 27),
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
	}, Gui)
	New("UICorner", { CornerRadius = UDim.new(0, 12) }, Card)
	New("UIStroke", { Color = Color3.fromRGB(52, 60, 100), Thickness = 1, Transparency = 0.3 }, Card)

	New("TextLabel", {
		Position = UDim2.fromOffset(14, 8),
		Size = UDim2.new(1, -28, 0, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = Color3.fromRGB(245, 247, 255),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "AA Kaitun",
	}, Card)

	local Status = New("TextLabel", {
		Position = UDim2.fromOffset(14, 28),
		Size = UDim2.new(1, -28, 0, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextColor3 = Color3.fromRGB(110, 230, 150),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Working...",
	}, Card)
	UI.StatusLabel = Status

	local Sub = New("TextLabel", {
		Position = UDim2.fromOffset(14, 46),
		Size = UDim2.new(1, -28, 0, 16),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = Color3.fromRGB(150, 160, 192),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
	}, Card)

	local Track = New("Frame", {
		Position = UDim2.fromOffset(14, 68),
		Size = UDim2.new(1, -28, 0, 8),
		BackgroundColor3 = Color3.fromRGB(45, 45, 55),
		BorderSizePixel = 0,
		ClipsDescendants = true,
	}, Card)
	New("UICorner", { CornerRadius = UDim.new(0, 4) }, Track)
	local Fill = New("Frame", {
		Size = UDim2.new(0, 60, 1, 0),
		Position = UDim2.fromOffset(-60, 0),
		BackgroundColor3 = Color3.fromRGB(110, 150, 255),
		BorderSizePixel = 0,
	}, Track)
	New("UICorner", { CornerRadius = UDim.new(0, 4) }, Fill)

	-- slide the bar back and forth inside the track
	task.spawn(function()
		while true do
			local TrackW = Track.AbsoluteSize.X
			if TrackW > 0 then
				local FillW = math.min(60, TrackW * 0.4)
				Fill.Size = UDim2.new(0, FillW, 1, 0)
				Tween:Create(Fill, TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
					Position = UDim2.fromOffset(TrackW - FillW, 0),
				}):Play()
				task.wait(1.15)
				Tween:Create(Fill, TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
					Position = UDim2.fromOffset(0, 0),
				}):Play()
				task.wait(1.15)
			else
				task.wait(0.5)
			end
		end
	end)

	local function Refresh()
		local Current = State.Current
		local Activity = Current and Current.Kind and tostring(Current.Kind) or "planning"
		Status.Text = "Working - " .. Activity
		local Left = ResetLeft()
		local Mm = math.floor(Left / 60)
		local Ss = math.floor(Left % 60)
		Sub.Text = ("Lv %d  -  gems %s  -  next challenges %d:%02d"):format(
			Account.Level(), tostring(Account.Gems()), Mm, Ss)
	end

	task.spawn(function()
		while true do
			pcall(Refresh)
			task.wait(1)
		end
	end)
	Refresh()
	LogT("UI", "lobby widget on")
end


function UI.Overlay()
	local TweenService = game:GetService("TweenService")
	local Camera = workspace.CurrentCamera

	local Holder = PlayerGui
	for _, Name in ipairs({ "AAKaitunStats", "AAKaitunToggle" }) do
		local Old = Holder:FindFirstChild(Name)
		if Old then
			Old:Destroy()
		end
	end

	local Gui = Instance.new("ScreenGui")
	Gui.Name = "AAKaitunStats"
	Gui.ResetOnSpawn = false
	Gui.IgnoreGuiInset = true
	Gui.DisplayOrder = 9999
	Gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	Gui.Parent = Holder

	local Theme = {
		Back = Color3.fromRGB(6, 8, 15),
		Back2 = Color3.fromRGB(18, 14, 38),
		Panel = Color3.fromRGB(12, 15, 27),
		Card = Color3.fromRGB(20, 24, 42),
		Stroke = Color3.fromRGB(52, 60, 100),
		Text = Color3.fromRGB(245, 247, 255),
		Muted = Color3.fromRGB(150, 160, 192),
		Accent = Color3.fromRGB(110, 150, 255),
		Accent2 = Color3.fromRGB(190, 120, 255),
		Good = Color3.fromRGB(110, 230, 150),
		Warn = Color3.fromRGB(255, 184, 90),
		Bad = Color3.fromRGB(255, 96, 96),
	}

	local Icons = {
		Rerolls = "rbxassetid://99186363801156",   -- Trait Rerolls
		Remnants = "rbxassetid://137988080790367", -- Star Remnants
		Compass = "rbxassetid://137369120766463",  -- Celestial Compass
		Gems = "rbxassetid://71405874061254",      -- Gems
		Logo = "rbxassetid://73535842368256",      -- Anime Adventures logo
	}

	local ActivityNames = {
		story = "Story loop",
		act6 = "Act 6 clear",
		infinite = "Infinite",
		challenge = "Challenge",
	}

	local function New(Class, Props, Parent)
		local Item = Instance.new(Class)
		for Key, Value in pairs(Props) do
			Item[Key] = Value
		end
		Item.Parent = Parent
		return Item
	end

	local function Round(Item, Radius)
		return New("UICorner", { CornerRadius = UDim.new(0, Radius) }, Item)
	end

	local function Label(Parent, Props)
		Props.BackgroundTransparency = 1
		Props.Font = Props.Font or Enum.Font.Gotham
		Props.TextColor3 = Props.TextColor3 or Theme.Text
		return New("TextLabel", Props, Parent)
	end

	-- animated gradient outline
	local function GradientStroke(Parent, Thickness)
		local Stroke = New("UIStroke", {
			Color = Color3.new(1, 1, 1),
			Thickness = Thickness,
			Transparency = 0.3,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, Parent)
		local Gradient = New("UIGradient", {
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Theme.Accent),
				ColorSequenceKeypoint.new(0.5, Theme.Accent2),
				ColorSequenceKeypoint.new(1, Theme.Accent),
			}),
		}, Stroke)
		TweenService:Create(Gradient, TweenInfo.new(8, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1), {
			Rotation = 360,
		}):Play()
	end

	-- background -------------------------------------------------------------
	local Back = New("Frame", {
		Name = "Black",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Back,
		BorderSizePixel = 0,
		Active = false,
	}, Gui)
	New("UIGradient", {
		Rotation = 65,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Theme.Back),
			ColorSequenceKeypoint.new(0.55, Theme.Back2),
			ColorSequenceKeypoint.new(1, Theme.Back),
		}),
	}, Back)

	local Glow = New("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, -260),
		Size = UDim2.fromOffset(820, 820),
		BackgroundColor3 = Theme.Accent,
		BackgroundTransparency = 0.88,
		BorderSizePixel = 0,
	}, Back)
	Round(Glow, 410)
	New("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.1),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, Glow)

	-- content ------------------------------------------------------------------
	local Content = New("CanvasGroup", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(740, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		GroupTransparency = 1,
	}, Back)
	New("UIListLayout", {
		Padding = UDim.new(0, 14),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
	}, Content)
	-- room for the outlines: a CanvasGroup clips anything outside its bounds
	New("UIPadding", {
		PaddingLeft = UDim.new(0, 24),
		PaddingRight = UDim.new(0, 24),
		PaddingTop = UDim.new(0, 12),
		PaddingBottom = UDim.new(0, 12),
	}, Content)

	local Scale = New("UIScale", {}, Content)
	local function Rescale()
		local View = Camera and Camera.ViewportSize or Vector2.new(1280, 720)
		Scale.Scale = math.clamp(math.min(View.X / 780, View.Y / 680), 0.45, 1.4)
	end
	Rescale()
	if Camera then
		Camera:GetPropertyChangedSignal("ViewportSize"):Connect(Rescale)
	end

	-- header: logo top center -------------------------------------------------
	local Header = New("Frame", {
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 156),
		BackgroundTransparency = 1,
	}, Content)
	New("ImageLabel", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 0),
		Size = UDim2.fromOffset(124, 124),
		BackgroundTransparency = 1,
		Image = Icons.Logo,
		ScaleType = Enum.ScaleType.Fit,
	}, Header)
	local Sub = Label(Header, {
		Position = UDim2.fromOffset(0, 130),
		Size = UDim2.new(1, 0, 0, 28),
		Font = Enum.Font.GothamBold,
		TextSize = 20,
		TextColor3 = Theme.Text,
		Text = "",
	})

	-- status pill --------------------------------------------------------------
	local PillRow = New("Frame", {
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 38),
		BackgroundTransparency = 1,
	}, Content)
	local Pill = New("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(500, 38),
		BackgroundColor3 = Theme.Panel,
		BorderSizePixel = 0,
	}, PillRow)
	Round(Pill, 19)
	New("UIStroke", { Color = Theme.Stroke, Thickness = 1, Transparency = 0.3 }, Pill)
	local Dot = New("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 16, 0.5, 0),
		Size = UDim2.fromOffset(10, 10),
		BackgroundColor3 = Theme.Good,
		BorderSizePixel = 0,
	}, Pill)
	Round(Dot, 5)
	TweenService:Create(Dot, TweenInfo.new(1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
		BackgroundTransparency = 0.75,
	}):Play()
	local PillText = Label(Pill, {
		Position = UDim2.fromOffset(36, 0),
		Size = UDim2.new(1, -50, 1, 0),
		Font = Enum.Font.GothamMedium,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "",
	})

	-- stat cards ---------------------------------------------------------------
	local Panel = New("Frame", {
		LayoutOrder = 3,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
	}, Content)
	Round(Panel, 16)
	GradientStroke(Panel, 1.5)
	New("UIPadding", {
		PaddingTop = UDim.new(0, 14),
		PaddingBottom = UDim.new(0, 14),
		PaddingLeft = UDim.new(0, 14),
		PaddingRight = UDim.new(0, 14),
	}, Panel)
	New("UIGridLayout", {
		CellSize = UDim2.fromOffset(326, 60),
		CellPadding = UDim2.fromOffset(12, 12),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, Panel)

	-- rainbow gradient from the game's TraitReroll unique Border UIGradient
	local function RainbowGradient(Target)
		local Stops = {
			{ 0, 0.592755, 1, 0.2 }, { 0.1, 0.400755, 1, 0.2 },
			{ 0.2, 0.208755, 1, 0.2 }, { 0.3, 0.2, 1, 0.383245 },
			{ 0.4, 0.2, 1, 0.575245 }, { 0.5, 0.2, 1, 0.767245 },
			{ 0.6, 0.2, 1, 0.959245 }, { 0.7, 0.2, 0.848755, 1 },
			{ 0.8, 0.2, 0.656755, 1 }, { 0.9, 0.2, 0.464755, 1 },
			{ 1, 0.2, 0.272755, 1 },
		}
		local Points = {}
		for _, S in ipairs(Stops) do
			Points[#Points + 1] = ColorSequenceKeypoint.new(S[1], Color3.new(S[2], S[3], S[4]))
		end
		local Gradient = New("UIGradient", {
			Color = ColorSequence.new(Points),
			Rotation = 45,
		}, Target)
		TweenService:Create(Gradient, TweenInfo.new(4, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1), {
			Rotation = 405,
		}):Play()
		return Gradient
	end

	-- one line: icon, title on the left, value on the right
	local function AddCard(Order, Caption, IconId, Badge, Tint, Rainbow)
		local Card = New("Frame", {
			LayoutOrder = Order,
			BackgroundColor3 = Theme.Card,
			BorderSizePixel = 0,
		}, Panel)
		Round(Card, 12)
		New("UIStroke", { Color = Theme.Stroke, Thickness = 1, Transparency = 0.5 }, Card)

		local IconBox = New("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 10, 0.5, 0),
			Size = UDim2.fromOffset(40, 40),
			BackgroundColor3 = Theme.Back,
			BorderSizePixel = 0,
		}, Card)
		Round(IconBox, 10)
		if IconId then
			-- exact game item-frame structure (TraitReroll UseItemFrame.ItemFrame2):
			-- grey BG -> BackgroundGlow -> BorderFrame(0.925, aspect 1) with
			-- bordershadow + pattern + line layers -> the icon itself
			IconBox.BackgroundColor3 = Color3.fromRGB(95, 95, 95)
			New("ImageLabel", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				Image = "rbxassetid://127994770257821", -- EvolvedGlow
				ImageTransparency = 0.8,
			}, IconBox)
			local BorderFrame = New("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(0.925, 0.925),
				BackgroundTransparency = 1,
			}, IconBox)
			Round(BorderFrame, 8)
			New("UIAspectRatioConstraint", { AspectRatio = 1 }, BorderFrame)
			New("ImageLabel", {
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				Image = "rbxassetid://130155782712929", -- bordershadow
			}, BorderFrame)
			New("ImageLabel", {
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				Image = "rbxassetid://86044272558886", -- pattern
				ImageColor3 = Color3.fromRGB(168, 168, 168),
			}, BorderFrame)
			New("ImageLabel", {
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				Image = "rbxassetid://76373203609129", -- inner fill
				ImageColor3 = Color3.fromRGB(150, 150, 150),
				ImageTransparency = 0.5,
			}, BorderFrame)
			local Image = New("ImageLabel", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(32, 32),
				BackgroundTransparency = 1,
				Image = IconId,
				ScaleType = Enum.ScaleType.Fit,
			}, BorderFrame)
			if Rainbow then
				RainbowGradient(Image)
			end
		else
			Label(IconBox, {
				Size = UDim2.fromScale(1, 1),
				Font = Enum.Font.GothamBold,
				TextSize = 14,
				TextColor3 = Tint or Theme.Accent,
				Text = Badge or "",
			})
		end

		Label(Card, {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 60, 0.5, 0),
			Size = UDim2.new(0, 120, 0, 22),
			TextSize = 15,
			TextColor3 = Theme.Muted,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = Caption,
		})
		return Label(Card, {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -14, 0.5, 0),
			Size = UDim2.new(1, -190, 0, 26),
			Font = Enum.Font.GothamBold,
			TextSize = 20,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = "-",
		})
	end

	local ValueGems = AddCard(1, "Gems", Icons.Gems)
	local ValueCompass = AddCard(2, "Celestial Compass", Icons.Compass)
	local ValueUnique = AddCard(3, "Unique", "rbxassetid://106165041836099", nil, nil, true)
	local ValueTokens = AddCard(4, "Reroll Tokens", Icons.Rerolls)
	local ValueRemnants = AddCard(5, "Star Remnants", Icons.Remnants)
	local ValueLimited = AddCard(6, "Limited Remnants", Icons.Remnants)

	-- one font for every stat/card label
	for _, Item in ipairs(Panel:GetDescendants()) do
		if Item:IsA("TextLabel") then
			Item.Font = Enum.Font.GothamBold
		end
	end

	-- progress bars ------------------------------------------------------------
	local Bars = New("Frame", {
		LayoutOrder = 4,
		Size = UDim2.new(1, 0, 0, 118),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
	}, Content)
	Round(Bars, 16)
	New("UIStroke", { Color = Theme.Stroke, Thickness = 1, Transparency = 0.35 }, Bars)

	local function AddBar(Y, Caption, ColorA, ColorB)
		Label(Bars, {
			Position = UDim2.fromOffset(18, Y),
			Size = UDim2.new(0.5, -18, 0, 16),
			TextSize = 14,
			TextColor3 = Theme.Muted,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = Caption,
		})
		local Percent = Label(Bars, {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, Y + 1),
			Size = UDim2.new(1, -36, 0, 20),
			Font = Enum.Font.GothamBold,
			TextSize = 15,
			TextXAlignment = Enum.TextXAlignment.Center,
			Text = "",
			ZIndex = 3,
		})
		-- game health-bar style: dark navy track, cyan -> blue gradient fill
		local Track = New("Frame", {
			Position = UDim2.new(0, 18, 0, Y + 22),
			Size = UDim2.new(1, -36, 0, 14),
			BackgroundColor3 = Color3.fromRGB(0, 0, 38),
			BorderSizePixel = 0,
		}, Bars)
		Round(Track, 6)
		local Fill = New("Frame", {
			Size = UDim2.fromScale(0, 1),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
		}, Track)
		Round(Fill, 6)
		New("UIGradient", {
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(0, 170, 255)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 68, 255)),
			}),
			Rotation = 90,
		}, Fill)
		return function(Fraction, Text)
			Percent.Text = Text
			Fill.Size = UDim2.fromScale(math.clamp(Fraction, 0, 1), 1)
		end
	end

	local SetLevelBar = AddBar(14, "Level progress", Theme.Accent, Theme.Accent2)
	local SetGemBar = AddBar(66, "Gems to hunt", Color3.fromRGB(70, 200, 150), Theme.Good)

	Label(Content, {
		LayoutOrder = 5,
		Size = UDim2.new(1, 0, 0, 16),
		TextSize = 12,
		TextColor3 = Theme.Muted,
		Text = "Toggle Black Screen via the Button on the Bottom Right",
	})

	local StartedAt = tick()

	local function Fmt(Value)
		local Str = tostring(math.floor(tonumber(Value) or 0))
		local Out = Str:reverse():gsub("(%d%d%d)", "%1,"):reverse()
		return (Out:gsub("^,", ""))
	end

	-- Unique status for the compass unit: Not Started / No / Yes
	local function UniqueStatus()
		local UnitId = Account.CompassUnit()
		if not UnitId then
			return "Not Started", Theme.Muted
		end
		local Record = State.TraitRoll and State.TraitRoll[UnitId]
		if not Record then
			return "Not Started", Theme.Muted
		end
		if Record.gotUnique then
			return "Yes", Theme.Good
		end
		return "No", Theme.Warn
	end

	-- "shadow_sorcerer" / "Shadow sorcerer" -> "Shadow Sorcerer"
	local function Pretty(Id)
		local Def = Units[Id]
		local Name = type(Def) == "table" and Def.name or Id
		local Text = tostring(Name or ""):gsub("_", " ")
		return (Text:gsub("(%a)([%w']*)", function(First, Rest)
			return First:upper() .. Rest:lower()
		end))
	end

	local function Refresh()
		local Prof = Account.Profile()
		local Items = type(Prof.inventory) == "table" and Prof.inventory.normal_items or nil
		if type(Items) ~= "table" then
			Items = {}
		end
		local Level = Account.Level()
		local Gems = Account.Gems()
		local Up = math.floor(tick() - StartedAt)

		-- header + pill (challenge countdown lives in the header time)
		local ChallengeRemain = 1800 - (os.time() % 1800)
		Sub.Text = ("%s   ·   %02d:%02d:%02d   ·   Challenges %02d:%02d"):format(
			Player.Name, math.floor(Up / 3600), math.floor(Up / 60) % 60, Up % 60,
			math.floor(ChallengeRemain / 60), math.floor(ChallengeRemain % 60))
		local Running = Config.Enabled ~= false
		local Parts = { Running and "RUNNING" or "PAUSED", Loader.IsLobby and "Lobby" or "Match" }
		local WaveValue = workspace:FindFirstChild("_wave_num")
		if not Loader.IsLobby and WaveValue and WaveValue:IsA("ValueBase") then
			Parts[#Parts + 1] = "Wave " .. tostring(WaveValue.Value)
		end
		local Current = State.Current
		if Current and Current.Kind then
			Parts[#Parts + 1] = ActivityNames[Current.Kind] or tostring(Current.Kind)
		end
		PillText.Text = table.concat(Parts, "   ·   ")
		Dot.BackgroundColor3 = Running and Theme.Good or Theme.Warn

		-- cards
		local CompassUnit = Account.CompassUnit()
		local CompassOwned = CompassUnit and Account.HasUnit(CompassUnit) or false
		local CompassColor = CompassOwned and Theme.Good or Theme.Bad
		local CompassCount = tonumber(Items[Config.CompassId])
		if State.Compass then
			ValueCompass.Text = Pretty(Account.UnitName(CompassUnit))
			ValueCompass.TextColor3 = CompassColor
		elseif CompassCount and CompassCount > 0 then
			ValueCompass.Text = ("x%d ready"):format(CompassCount)
			ValueCompass.TextColor3 = CompassColor
		else
			ValueCompass.Text = "Not used"
			ValueCompass.TextColor3 = CompassColor
		end
		ValueGems.Text = Fmt(Gems)
		ValueTokens.Text = Fmt(Prof.trait_reroll_tokens)
		ValueRemnants.Text = Fmt(Items.star_remnant)
		ValueLimited.Text = Fmt(Items.star_remnant_limited)
		local UniqueText, UniqueColor = UniqueStatus()
		ValueUnique.Text = UniqueText
		ValueUnique.TextColor3 = UniqueColor

		-- bars
		local Endgame = math.max(Config.TargetLevel, 1)
		SetLevelBar(Level / Endgame, ("Lv %d / %d   ·   %d%%"):format(Level, Endgame, math.floor(math.clamp(Level / Endgame, 0, 1) * 100)))
		local Hunt = math.max(Config.HuntFrom, 1)
		SetGemBar(Gems / Hunt, ("%s / %s   ·   %d%%"):format(Fmt(Gems), Fmt(Hunt), math.floor(math.clamp(Gems / Hunt, 0, 1) * 100)))
	end

	-- black screen switch: its own ScreenGui above the overlay, so it stays
	-- clickable while the black screen is hidden. Off = overlay hidden and 3D
	-- rendering back on. The choice is saved and survives teleports.
	local BlackOn = State.BlackScreen ~= false

	local ToggleGui = Instance.new("ScreenGui")
	ToggleGui.Name = "AAKaitunToggle"
	ToggleGui.ResetOnSpawn = false
	ToggleGui.IgnoreGuiInset = true
	ToggleGui.DisplayOrder = 9999
	ToggleGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	ToggleGui.Parent = Holder

	local Toggle = New("TextButton", {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -16, 1, -16),
		Size = UDim2.fromOffset(190, 40),
		BackgroundColor3 = Theme.Panel,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		Font = Enum.Font.GothamMedium,
		TextSize = 14,
		TextColor3 = Theme.Text,
		Text = "",
	}, ToggleGui)
	Round(Toggle, 20)
	New("UIStroke", { Color = Theme.Stroke, Thickness = 1.5, Transparency = 0.1 }, Toggle)

	local function ApplyBlack(Value)
		BlackOn = Value
		Back.Visible = Value
		pcall(function()
			game:GetService("RunService"):Set3dRenderingEnabled(not Value)
		end)
		Toggle.Text = Value and "Black screen: ON" or "Black screen: OFF"
		Toggle.TextColor3 = Value and Theme.Good or Theme.Muted
		State.BlackScreen = Value
		SaveState()
	end

	Toggle.Activated:Connect(function()
		ApplyBlack(not BlackOn)
	end)
	ApplyBlack(BlackOn)

	TweenService:Create(Content, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		GroupTransparency = 0,
	}):Play()

	task.spawn(function()
		while true do
			if BlackOn then
				pcall(Refresh)
			end
			task.wait(1)
		end
	end)
	pcall(Refresh)
	LogT("UI", "stats overlay on (black screen %s)", BlackOn and "on" or "off")
end


-- ============================================================================
-- fps boost - optimizer.lua, embedded verbatim (runs in matches only)
-- ============================================================================
local Fps = {}

function Fps.Apply()
if _G.Cam == nil then
	_G.Cam = false
end
if _G.Transparent == nil then
	_G.Transparent = true
end
if _G.Gui == nil then
	_G.Gui = true
end
if _G.Render3D == nil then
	_G.Render3D = true
end
if _G.FPSCap == nil then
	_G.FPSCap = 15
end

local a = {}
local b = {}
local c = {}
local d = {}

local e = game:GetService("Players")
local f = e.LocalPlayer
local g = game:GetService("RunService")
local h = workspace

local l = {
	Decal = true,
	Texture = true,
	Clothing = true,
	SurfaceAppearance = true,
	PostEffect = true,
	Light = true,
	Sound = true,
	BloomEffect = true,
	BlurEffect = true,
	ColorCorrectionEffect = true,
	DepthOfFieldEffect = true,
	SunRaysEffect = true,
	Atmosphere = true,
	Sky = true,
	Clouds = true,
}

local m = {
	ParticleEmitter = true,
	Trail = true,
	Smoke = true,
	Fire = true,
	Sparkles = true,
	Beam = true,
	Highlight = true,
}

a.a1 = function(n)
	if not n or not n.Parent then
		return
	end
	if f.Character and n:IsDescendantOf(f.Character) then
		return
	end

	local o = n.ClassName

	if l[o] or n:IsA("PostEffect") or n:IsA("Light") then
		pcall(n.Destroy, n)
	elseif m[o] then
		pcall(function()
			n.Enabled = false
		end)
	elseif n:IsA("BasePart") then
		pcall(function()
			n.Material = Enum.Material.Plastic
			n.Reflectance = 0
			n.Color = Color3.fromRGB(163, 162, 165)
			n.CastShadow = false

			if n:IsA("MeshPart") then
				n.TextureID = ""
				n.RenderFidelity = Enum.RenderFidelity.Performance
			end

			if _G.Transparent then
				n.Transparency = 1
			end
		end)
	elseif n:IsA("SpecialMesh") then
		pcall(function()
			n.TextureId = ""
		end)
	end
end

a.a2 = function()
	local n = { h, game:GetService("Lighting"), game:GetService("MaterialService") }
	local o = 0
	for p, q in ipairs(n) do
		for r, s in ipairs(q:GetDescendants()) do
			a.a1(s)
			o += 1
			if o % 250 == 0 then
				task.wait()
			end
		end
	end
end

a.a3 = function()
	h.DescendantAdded:Connect(function(n)
		if n and n.Parent then
			task.defer(a.a1, n)
		end
	end)
end

b.b1 = function()
	local n = game:GetService("Lighting")
	local o = settings()

	pcall(function()
		game:GetService("SoundService").AmbientReverb = Enum.ReverbType.NoReverb
	end)

	pcall(function()
		o.Rendering.QualityLevel = 1
		o.Rendering.MeshPartDetailLevel = Enum.MeshPartDetailLevel.Level04
	end)

	pcall(function()
		n.GlobalShadows = false
		n.FogEnd = 9e9
		n.FogStart = 0
		n.Brightness = 0
		n.EnvironmentDiffuseScale = 0
		n.EnvironmentSpecularScale = 0
		n.ExposureCompensation = 0
		n.Technology = Enum.Technology.Compatibility
	end)

	pcall(function()
		local p = h:FindFirstChildOfClass("Terrain")
		if p then
			p.WaterWaveSize = 0
			p.WaterWaveSpeed = 0
			p.WaterReflectance = 0
			p.WaterTransparency = 1
		end
	end)

	if setfpscap and type(_G.FPSCap) == "number" and _G.FPSCap > 0 then
		pcall(setfpscap, _G.FPSCap)
	end
end

b.b2 = function()
	if not _G.Render3D then
		pcall(function()
			g:Set3dRenderingEnabled(false)
		end)
	end
end

c.c1 = function()
	if not _G.Cam then
		return
	end
	local n = h.CurrentCamera
	n.FieldOfView = 1
	g.RenderStepped:Connect(function()
		local o = f.Character
		local p = o and o:FindFirstChild("HumanoidRootPart")
		if p then
			n.CameraType = Enum.CameraType.Scriptable
			n.CFrame = CFrame.new(p.Position, p.Position + Vector3.new(0, 1000, 0))
		end
	end)
end

d.d1 = function(n)
	if n:IsA("GuiObject") then
		n.BackgroundTransparency = 1
		n.BorderSizePixel = 0
		if n:IsA("ImageLabel") or n:IsA("ImageButton") then
			n.ImageTransparency = 1
		end
	elseif n:IsA("UIStroke") or n:IsA("UIGradient") or n:IsA("UICorner") then
		pcall(n.Destroy, n)
	end
end

d.d2 = function()
	if _G.Gui then
		return
	end

	pcall(function()
		game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.All, false)
	end)

	local n = f:FindFirstChildOfClass("PlayerGui") or f:WaitForChild("PlayerGui", 5)
	if n then
		for o, p in ipairs(n:GetDescendants()) do
			d.d1(p)
		end
		n.DescendantAdded:Connect(d.d1)
	end
end

b.b1()
b.b2()
a.a2()
a.a3()
c.c1()
d.d2()
end
-- ============================================================================
-- cinematic skip (summon / hatch / reward popups)
-- ============================================================================
-- Same hooker as skip_cutscenes.lua: hook once, verify, retry only if the
-- lazy-loaded modules were not there yet. No perpetual scanning; the stub has
-- a private upvalue tag so a replacement is never hooked again on a retry.
local Cinematic = {
	HookedFn = setmetatable({}, { __mode = "k" }), -- function identity, weak keys
	HookedName = {},
	Count = 0,
}

local CINEMATIC_NAMES = {
	open_star_new = true,
	show_unit_and_item_rewards = true,
	on_show_hatch_effect = true,
	on_show_item_hatch_effect = true,
	on_units_hatched_through_banner = true,
}
local CINEMATIC_ATTEMPTS = 10
local CINEMATIC_RETRY = 1

local Sentinel = {}
local function CinematicStub(...)
	if Sentinel then
		for _, Arg in ipairs({ ... }) do
			if type(Arg) == "function" then
				pcall(Arg)
			end
		end
	end
end
Cinematic.HookedFn[CinematicStub] = true

local function CinematicIsStub(Fn)
	local Ok, _, Value = pcall(debug.getupvalue, Fn, 1)
	return Ok and Value == Sentinel
end

local IsLClosure = type(islclosure) == "function" and islclosure or function() return true end

local function CinematicTryHook(Fn, Name, Owner)
	if type(Fn) ~= "function" or Cinematic.HookedFn[Fn] or CinematicIsStub(Fn) then
		return
	end
	if not pcall(hookfunction, Fn, CinematicStub) then
		return
	end
	Cinematic.HookedFn[Fn] = true
	Cinematic.HookedName[Name] = true
	Cinematic.Count += 1
	if Owner then
		local Now = rawget(Owner, Name)
		if type(Now) == "function" then
			Cinematic.HookedFn[Now] = true
		end
	end
end

local function CinematicScanOnce()
	if not Config.SkipCutscenes then
		return
	end
	local Ok, Gc = pcall(getgc, true)
	if not (Ok and type(Gc) == "table") then
		return
	end
	for _, Value in pairs(Gc) do
		if type(Value) == "function" and not Cinematic.HookedFn[Value]
			and IsLClosure(Value) then
			local Info = debug.getinfo(Value)
			local Name = Info and Info.name
			if Name and CINEMATIC_NAMES[Name] then
				CinematicTryHook(Value, Name)
			end
		elseif type(Value) == "table" then
			for Name in pairs(CINEMATIC_NAMES) do
				local Fn = rawget(Value, Name)
				if type(Fn) == "function" and not Cinematic.HookedFn[Fn]
					and IsLClosure(Fn) then
					CinematicTryHook(Fn, Name, Value)
				end
			end
		end
	end
end

local function CinematicAllHooked()
	for Name in pairs(CINEMATIC_NAMES) do
		if not Cinematic.HookedName[Name] then
			return false
		end
	end
	return true
end

task.spawn(function()
	for Attempt = 1, CINEMATIC_ATTEMPTS do
		CinematicScanOnce()
		if CinematicAllHooked() then
			break
		end
		task.wait(CINEMATIC_RETRY)
	end
	local Missing = {}
	for Name in pairs(CINEMATIC_NAMES) do
		if not Cinematic.HookedName[Name] then
			Missing[#Missing + 1] = Name
		end
	end
	LogT("Cinematic", "hooked %d function(s)%s", Cinematic.Count,
		#Missing > 0 and (" | still missing: " .. table.concat(Missing, ", ")) or "")
end)

-- ============================================================================
-- anti-afk
-- ============================================================================
function Account.AntiAfk()
	local VirtualUser = game:GetService("VirtualUser")
	Player.Idled:Connect(function()
		pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end)
	end)
end

-- ============================================================================
-- game settings - fire toggle_setting only when a value is actually wrong
-- ============================================================================
local GameSettings = {
	Lobby = {
		{ "hide_other_pets", true },
		{ "quick_summon", true },
	},
	Match = {
		{ "disable_effects", true },
		{ "show_overheads", false },
		{ "disable_auto_open_overhead", true },
	},
}

-- Player._settings mirrors every toggle_setting key as a ValueBase child
local function SettingValue(Name)
	local Folder = Player:FindFirstChild("_settings")
	local Value = Folder and Folder:FindFirstChild(Name)
	if Value and Value:IsA("ValueBase") then
		return Value.Value -- false is a valid value, don't use an and/or chain
	end
	return nil
end

function GameSettings.Ensure(Which)
	local List = GameSettings[Which]
	if type(List) ~= "table" then
		return
	end
	local Ep = Util.Endpoint("toggle_setting")
	if not Ep or not Ep:IsA("RemoteFunction") then
		return
	end
	for _, Entry in ipairs(List) do
		local Name, Want = Entry[1], Entry[2]
		if SettingValue(Name) ~= Want then
			local Ok, Result = Util.Call(5, Ep.InvokeServer, Ep, Name, Want)
			if Ok and Result ~= false then
				LogT("Settings", "%s = %s", Name, tostring(Want))
			else
				LogT("Settings", "%s = %s failed: %s", Name, tostring(Want), tostring(Result))
			end
			task.wait(0.15)
		end
	end
end

-- ============================================================================
-- group join - once per account, before redeeming codes
-- ============================================================================
local function UiRoots()
	local Roots = { game:GetService("CoreGui") }
	if GetHui then
		pcall(function()
			local Hui = GetHui()
			if Hui then
				Roots[#Roots + 1] = Hui
			end
		end)
	end
	return Roots
end

local function Unselect()
	pcall(function()
		if GuiService.SelectedObject then
			GuiService.SelectedObject = nil
		end
	end)
end

local function ButtonAlive(Button)
	if not Button then
		return false
	end
	local Ok, Alive = pcall(function()
		return Button.Parent ~= nil and Button:IsDescendantOf(game) and Button.Visible
	end)
	return Ok and Alive
end

local function PressButton(Button)
	pcall(function()
		Button.Selectable = true
		if GuiService.SelectedObject ~= Button then
			GuiService.SelectedObject = Button
			task.wait(0.05)
		end
		if GuiService.SelectedObject == Button and ButtonAlive(Button) then
			VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Return, false, game)
			task.wait(0.02)
			VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Return, false, game)
		end
	end)
end

local function SpamButton(Button, Verify, Timeout)
	local Deadline = os.clock() + Timeout
	while os.clock() < Deadline do
		if Verify() or not ButtonAlive(Button) then
			break
		end
		PressButton(Button)
		task.wait(0.1)
	end
	Unselect()
	return Verify()
end

local function IsInGroup()
	local Ok, Value = pcall(function()
		return Player:IsInGroup(Config.GroupId)
	end)
	return Ok and Value == true
end

local function FindJoinButton()
	for _, Root in ipairs(UiRoots()) do
		local Ok, Button = pcall(function()
			local Actions = Root.RobloxGui.FocusNavigationCoreScriptsWrapper.Main
				.DialogContentWrapper.Folder.Dialog.DialogInner
				.DialogBody.DialogActions.ActionsContainer
			for _, Child in ipairs(Actions:GetChildren()) do
				if Child:IsA("GuiButton") and Child.Name:sub(1, 2) == "1-" then
					return Child
				end
			end
			return nil
		end)
		if Ok and Button then
			return Button
		end
	end
	return nil
end

local function JoinGroup()
	if IsInGroup() then
		return true
	end
	LogT("Group", "opening join dialog for %s", Config.GroupName)
	task.spawn(function()
		pcall(function()
			GroupService:PromptJoinAsync(Config.GroupId)
		end)
	end)
	local Deadline = os.clock() + 15
	while os.clock() < Deadline do
		if IsInGroup() then
			Unselect()
			return true
		end
		local Button = FindJoinButton()
		if Button then
			SpamButton(Button, IsInGroup, 2)
		else
			task.wait(0.1)
		end
	end
	Unselect()
	return IsInGroup()
end

local function IsFavorited()
	local Ok, Value = pcall(function()
		return AvatarEditorService:GetFavorite(game.PlaceId, Enum.AvatarItemType.Asset)
	end)
	return Ok and Value == true
end

local function FindFavoriteButton()
	for _, Root in ipairs(UiRoots()) do
		local Ok, Button = pcall(function()
			return Root.AvatarEditorPromptsApp.ThemeProvider.PromptFrame.Prompt.AlertContents.Footer.Buttons["2"]
		end)
		if Ok and Button then
			return Button
		end
	end
	return nil
end

-- The compass item in inventory is the only success signal: getting it from
-- the code means the group join + favorite actually registered on the account.
local function HasCompassInInventory()
	local P = Account.Profile()
	local Items = type(P.inventory) == "table"
		and type(P.inventory.normal_items) == "table"
		and P.inventory.normal_items or {}
	return (tonumber(Items[Config.CompassId]) or 0) > 0
end

-- Hide the in-world Code UI once we are done with it.
local function CloseCodesUi()
	local Gui = PlayerGui:FindFirstChild("Codes")
	if not Gui then
		return
	end
	pcall(function()
		Gui.Enabled = false
	end)
	local Window = Gui:FindFirstChild("Window")
	if Window then
		pcall(function()
			Window.Visible = false
		end)
	end
end

-- Get the compass item: group join -> Code UI code submit -> handle whichever
-- dialog appears (group join prompt OR favorite prompt). The ONLY success
-- signal is the compass item in inventory — IsFavorited() is never checked.
local function EnsureCompass()
	if HasCompassInInventory() then
		return true
	end

	-- 1) group join: prompt and press the join button if not in the group
	if not IsInGroup() then
		LogT("Group", "not in group - prompting join")
		task.spawn(function()
			pcall(function()
				GroupService:PromptJoinAsync(Config.GroupId)
			end)
		end)
		local Deadline = os.clock() + 12
		while os.clock() < Deadline and not IsInGroup() do
			local Button = FindJoinButton()
			if Button then
				SpamButton(Button, IsInGroup, 2)
			else
				task.wait(0.1)
			end
		end
		Unselect()
	end

	-- 2) walk to the in-world Code UI and submit the compass code ONCE
	local Character = Player.Character or Player.CharacterAdded:Wait()
	local Root = Character:WaitForChild("HumanoidRootPart")
	local CodesPart = workspace:FindFirstChild("_codes")
	if CodesPart then
		local Position
		if CodesPart:IsA("BasePart") then
			Position = CodesPart.Position
		elseif CodesPart:IsA("Model") then
			local Ok, Pivot = pcall(function()
				return CodesPart:GetPivot()
			end)
			if Ok then
				Position = Pivot.Position
			end
		end
		if Position then
			Root.CFrame = CFrame.new(Position + Vector3.new(0, 3, 0))
		end
	end
	task.wait(1.5)

	local CodesUi = PlayerGui:WaitForChild("Codes", 10)
	local Window = CodesUi and CodesUi:WaitForChild("Window", 5)
	if not Window then
		return false
	end
	local UiDeadline = os.clock() + 5
	while not Window.Visible and os.clock() < UiDeadline do
		task.wait(0.1)
	end

	local EnterBox = Window.Enter:FindFirstChild("Type")
	if not EnterBox then
		return false
	end
	EnterBox.Text = Config.FavoriteCode
	task.wait(0.1)
	if FireSignal then
		pcall(function()
			FireSignal(EnterBox.FocusLost, true)
		end)
	end
	task.wait(0.5)
	local YesButton = Window.ButtonHolder and Window.ButtonHolder:FindFirstChild("Yes")
	if YesButton and ButtonAlive(YesButton) then
		PressButton(YesButton) -- press once
	end
	Unselect()

	-- 3) handle the dialog that appears: group join prompt OR favorite prompt
	local PromptDeadline = os.clock() + 20
	while os.clock() < PromptDeadline do
		if HasCompassInInventory() then
			CloseCodesUi()
			return true
		end
		-- group join prompt: press its "1-<name>" button
		local JoinBtn = FindJoinButton()
		if JoinBtn then
			LogT("Group", "group join prompt popped - pressing join")
			SpamButton(JoinBtn, IsInGroup, 2)
			Unselect()
		else
			-- favorite prompt: press its Yes button ("2")
			local FavBtn = FindFavoriteButton()
			if FavBtn then
				LogT("Group", "favorite prompt popped - pressing Yes")
				SpamButton(FavBtn, function() return true end, 2)
				Unselect()
			else
				task.wait(0.2)
			end
		end
	end

	CloseCodesUi()
	return HasCompassInInventory()
end

-- codes the server ignored this session (never saved to disk)
local CodeDead = {}

-- One entry point: group join -> Code UI code submit -> handle the prompt.
-- The compass item in inventory is the only success signal.
local function GroupAndFavorite()
	if not Config.JoinGroup then
		return
	end
	EnsureCompass()
end

-- ============================================================================
-- lobby
-- ============================================================================
local Lobby = {}
local Match = {}

-- redeemed_codes is the game's own ledger under session.profile_data: a LIST
-- of strings or a MAP { CODE = true }. WaitForRedeemed polls it after each
-- redeem, so no local file copy is needed.
local function RedeemedSet()
	local Set = {}
	local function Add(Code)
		if Code ~= nil then
			Set[tostring(Code):upper()] = true
		end
	end
	local Raw = Account.Profile().redeemed_codes
	if type(Raw) == "table" then
		for Code, Value in pairs(Raw) do
			if type(Value) == "string" then
				Add(Value) -- list form: { "CODE", ... }
			elseif Value then
				Add(Code) -- map form: { CODE = true }
			end
		end
	end
	return Set
end

local function WaitForRedeemed(Code, Timeout)
	local Deadline = os.clock() + Timeout
	repeat
		if RedeemedSet()[Code] then
			return true
		end
		task.wait(0.2)
	until os.clock() >= Deadline
	return false
end

function Lobby.RedeemCodes()
	if not Config.RedeemCodes then
		return
	end
	local Level = Account.Level()
	local Redeemed = RedeemedSet()
	local Seen = {}
	local Now, Locked = 0, 0
	local SocialCode = tostring(Config.FavoriteCode):upper()
	for _, Entry in ipairs(Config.Codes) do
		local Code = tostring(type(Entry) == "table" and Entry[1] or Entry):upper()
		-- the social compass code is handled by EnsureCompass() through the
		-- Code UI (group join + favorite prompt) - never via this remote
		if Code == SocialCode then
			continue
		end
		local MinLevel = type(Entry) == "table" and tonumber(Entry[2]) or nil
		if not Seen[Code] and not Redeemed[Code] and not CodeDead[Code] then
			Seen[Code] = true
			if MinLevel and not Config.ForceCodes and Level < MinLevel then
				Locked = Locked + 1
			else
				local Ok, Reply = Util.Call(10, InvokeServer, "redeem_code", Code)
				if not Ok then
					Log("code %s: request failed (%s)", Code, tostring(Reply))
				elseif Reply == nil or Reply == "" or Reply == true then
					if WaitForRedeemed(Code, 3) then
						Redeemed[Code] = true
						Now += 1
						Log("code %s redeemed", Code)
					else
						CodeDead[Code] = true
						Log("code %s: rejected (invalid, expired or already redeemed)", Code)
					end
				else
					Log("code %s: %s", Code, tostring(Reply))
					if tostring(Reply) ~= "needs_social" then
						CodeDead[Code] = true
					end
				end
				task.wait(0.3)
			end
		end
	end
	if Now > 0 or Locked > 0 then
		LogT("Codes", "%d redeemed, %d waiting for a higher level (level %d)", Now, Locked, Level)
	end
end

-- ============================================================================
-- claims (one pass per lobby visit; each claim verified against the profile)
-- ============================================================================
function Lobby.ClaimDaily()
	local Profile = Account.Profile()
	local Wait = tonumber(GameplaySettings.DAILY_REWARD_WAIT) or 82800
	local Last = tonumber(Profile.last_daily_reward_claimed_time) or 0
	local Gui = PlayerGui:FindFirstChild("DailyRewards")
	local Popup = false
	if Gui then
		if Gui:IsA("ScreenGui") then
			Popup = Gui.Enabled == true
		else
			Popup = Gui.Visible == true
		end
	end
	if os.time() - Last < Wait and not Popup then
		return
	end
	Util.Invoke("claim_daily_reward")
	if Util.Changed(function()
		return tonumber(Account.Profile().last_daily_reward_claimed_time) or 0
	end, Last, 3) then
		Log("daily login claimed (streak %s)", tostring(Account.Profile().days_streak))
	end
end

function Lobby.ClaimLevels()
	local Level = Account.Level()
	local Claimed = Account.Profile().level_rewards_claimed or {}
	local Pending = {}
	for _, Def in pairs(PlayerLevelRewards) do
		local Lv = type(Def) == "table" and tonumber(Def.level)
		if Lv and Lv <= Level and Claimed[Lv] == nil and Claimed[tostring(Lv)] == nil then
			Pending[#Pending + 1] = Lv
		end
	end
	if #Pending == 0 then
		return
	end
	table.sort(Pending)
	Log("level rewards: claiming %s", table.concat(Pending, ", "))
	for _, Lv in ipairs(Pending) do
		-- the remote expects the milestone as a STRING
		Util.Call(3, InvokeServer, "claim_player_level_rewards", tostring(Lv))
		task.wait(0.15)
	end
end

local function QuestData()
	local Session = EndpointsClient.session
	local Handler = Session and Session.quest_handler
	local Live = Handler and Handler.quest_profile_data
	if type(Live) == "table" then
		return Live
	end
	local Mirrored = Account.Profile().quest_handler
	if type(Mirrored) == "table" then
		if type(Mirrored.quest_profile_data) == "table" then
			return Mirrored.quest_profile_data
		end
		if type(Mirrored.quests) == "table" then
			return Mirrored
		end
	end
	return nil
end

local function QuestId(Uuid, Quest)
	local Info = Quest.quest_info or {}
	return tostring(Info.id or tostring(Uuid):gsub("[{}]", ""))
end

function Lobby.ClaimMissions()
	local Ok, List = Util.Call(10, InvokeServer, "request_current_dailymissions")
	local Ids = {}
	if Ok and type(List) == "table" then
		for _, Value in pairs(List) do
			if type(Value) == "string" then
				Ids[#Ids + 1] = Value
			end
		end
	end
	if #Ids == 0 then
		return
	end

	local Data = QuestData()
	local Quests = Data and Data.quests or {}
	local Ledger = (Account.Profile().dailymissions_data or {}).claimed_missions or {}
	local ById = {}
	for Uuid, Quest in pairs(Quests) do
		if type(Quest) == "table" then
			local Id = QuestId(Uuid, Quest)
			ById[Id] = Quest
			ById[Id:gsub("__quest$", "")] = Quest
		end
	end

	local Claimed, Started = 0, 0
	for _, MissionId in ipairs(Ids) do
		local Quest = ById[MissionId]
		if Quest then
			local Need = tonumber((Quest.quest_info or {}).quest_class and (Quest.quest_info.quest_class.amount))
			local Have = tonumber((Quest.quest_progress or {}).amount) or 0
			if Need == nil or Have >= Need then
				Util.Call(10, InvokeServer, "request_claim_dailymission", MissionId)
				Claimed += 1
				task.wait(0.15)
			end
		elseif not Ledger[MissionId] and Config.AcceptMissions then
			Util.Call(10, InvokeServer, "request_claim_dailymission", MissionId)
			Started += 1
			task.wait(0.15)
		end
	end
	if Claimed + Started > 0 then
		Log("daily missions: %d claimed, %d started", Claimed, Started)
	end
end

function Lobby.ClaimQuests()
	local Data = QuestData()
	if not Data then
		return
	end
	local Quests = Data.quests or {}
	local Done = Data.unique_quests_completed or {}

	-- the "Daily Quests Complete!" meta quest waits for the dailies
	local DailyOpen = false
	for _, Quest in pairs(Quests) do
		if type(Quest) == "table" and Quest.quest_type == "daily" then
			local Need = tonumber((Quest.quest_info or {}).quest_class and Quest.quest_info.quest_class.amount)
			local Have = tonumber((Quest.quest_progress or {}).amount) or 0
			if Need and Have < Need then
				DailyOpen = true
				break
			end
		end
	end

	local Redeemed = 0
	for Uuid, Quest in pairs(Quests) do
		if type(Quest) == "table" then
			local Info = Quest.quest_info or {}
			local Bare = type(Uuid) == "string" and Uuid:gsub("[{}]", "") or Uuid
			local Id = type(Info.id) == "string" and Info.id or nil
			local Already = Done[Uuid] or Done[Bare] or (Id and Done[Id])
			if not Already and not Info.block_button_completion then
				local Class = Info.quest_class or {}
				local Need = tonumber(Class.amount)
				local Have = tonumber((Quest.quest_progress or {}).amount) or 0
				local IsMeta = Class.class == "daily_complete" or (Id and Id:find("daily_complete", 1, true))
				local Ready = Need ~= nil and Have >= Need or (Need == nil and not (IsMeta and DailyOpen))
				local Target = Quest.uuid or Uuid
				if Ready and type(Target) == "string" then
					Util.Call(10, InvokeServer, "redeem_quest", Target)
					Redeemed += 1
					task.wait(0.15)
				end
			end
		end
	end
	if Redeemed > 0 then
		Log("quests: %d redeemed", Redeemed)
	end
end

function Lobby.ClaimBattlepass()
	local Defs = SafeLoad("load_data", "BattlePass")
	local Data = Account.Profile().battlepass_data
	if type(Defs) ~= "table" or type(Data) ~= "table" then
		return
	end
	-- only the current pass can be claimed; older passes stay in the profile
	-- with xp but their rewards are rejected. The game marks the active one.
	local Track = GameplaySettings.CURRENT_BATTLEPASS
	if type(Track) ~= "string" or Track == "" then
		return -- no current pass marked: skip rather than guess
	end
	local Def, Info = Defs[Track], Data[Track]
	if type(Def) ~= "table" or type(Info) ~= "table" then
		return
	end
	local Xp = tonumber(Info.xp) or 0
	local Claimed = Info.claimed_tiers or {}
	local Normal = type(Claimed.normal) == "table" and Claimed.normal or {}
	local Premium = type(Claimed.premium) == "table" and Claimed.premium or {}
	local HasPremium = Info.has_premium == true
	local Tiers = {}
	for Key, TierDef in pairs(Def.tiers or {}) do
		local Tier = tonumber(Key) or tonumber(TierDef.tier) or tonumber(TierDef.level)
		local Required = tonumber(TierDef.xp_required)
		if Tier and Required and Xp >= Required then
			local NormalOpen = TierDef.normal_reward ~= nil and not Normal[tostring(Tier)] and not Normal[Tier]
			local PremiumOpen = HasPremium and TierDef.premium_reward ~= nil
				and not Premium[tostring(Tier)] and not Premium[Tier]
			if NormalOpen or PremiumOpen then
				Tiers[#Tiers + 1] = Tier
			end
		end
	end
	table.sort(Tiers)
	local Total = 0
	for _, Tier in ipairs(Tiers) do
		Util.Call(10, InvokeServer, "claim_battlepass_rewards", Track, Tier)
		task.wait(0.2)
		Total += 1
	end
	if Total > 0 then
		Log("battlepass %s: %d tier(s) claimed", Track, Total)
	end
end

function Lobby.Claims()
	if not Config.Claims then
		return
	end
	for _, Step in ipairs({ Lobby.ClaimDaily, Lobby.ClaimMissions, Lobby.ClaimLevels, Lobby.ClaimQuests, Lobby.ClaimBattlepass }) do
		local Ok, Err = pcall(Step)
		if not Ok then
			Log("claim error: %s", tostring(Err))
		end
	end
end

-- ============================================================================
-- auto trait reroll - runs on the compass unit once it is owned
-- spends tokens -> star remnants -> limited remnants; Unique is always kept
-- ============================================================================
local TraitCatalog
local function TraitLookup()
	if not TraitCatalog then
		TraitCatalog = {}
		local Data = SafeLoad("load_data", "Traits")
		local Info = type(Data) == "table" and Data.info or nil
		if type(Info) == "table" then
			for Key, Entry in pairs(Info) do
				if type(Entry) == "table" then
					local Id = tostring(Entry.id or Key):lower()
					local Name = tostring(Entry.name or Key)
					TraitCatalog[Id] = Name
					TraitCatalog[Name:lower()] = Name
				end
			end
		end
	end
	return TraitCatalog
end

local function NormTrait(Value)
	local Text = tostring(Value or ""):lower()
	Text = Text:gsub("^%s+", "")
	Text = Text:gsub("%s+$", "")
	return Text
end

-- best (first) owned copy of a unit id
local function TraitCopy(UnitId)
	for Uuid, Unit in pairs(Account.Collection().owned_units or {}) do
		if type(Unit) == "table" and NormTrait(Unit.unit_id) == NormTrait(UnitId) then
			return { Uuid = tostring(Uuid), Unit = Unit }
		end
	end
	return nil
end

-- live trait list: { { id = "unique", tier = "2" }, ... }
local function UnitTraitList(Unit)
	local Out = {}
	if type(Unit) ~= "table" or type(Unit.traits) ~= "table" then
		return Out
	end
	for Key, Entry in pairs(Unit.traits) do
		if type(Entry) == "table" then
			Out[#Out + 1] = {
				id = NormTrait(Entry.trait or Entry.id or Key),
				tier = tostring(Entry.tier or ""),
			}
		elseif type(Key) == "string" then
			Out[#Out + 1] = { id = NormTrait(Key), tier = "" }
		elseif type(Entry) == "string" then
			Out[#Out + 1] = { id = NormTrait(Entry), tier = "" }
		end
	end
	table.sort(Out, function(A, B)
		if A.id ~= B.id then
			return A.id < B.id
		end
		return A.tier < B.tier
	end)
	return Out
end

local function TraitSignature(List)
	local Parts = {}
	for _, Trait in ipairs(List) do
		Parts[#Parts + 1] = Trait.id .. ":" .. Trait.tier
	end
	return table.concat(Parts, ",")
end

local function TraitLabels(List)
	local Lookup = TraitLookup()
	local Out = {}
	for _, Trait in ipairs(List) do
		Out[#Out + 1] = (Lookup[Trait.id] or Trait.id)
			.. (Trait.tier ~= "" and (" T" .. Trait.tier) or "")
	end
	table.sort(Out)
	return Out
end

local function KeptTrait(List)
	local Keep = { unique = true } -- Unique is ALWAYS kept
	for _, Name in ipairs(Config.TraitKeep or {}) do
		Keep[NormTrait(Name)] = true
	end
	for _, Trait in ipairs(List) do
		if Keep[Trait.id] then
			return Trait
		end
	end
	return nil
end

local function TraitResources()
	local P = Account.Profile()
	local Items = type(P.inventory) == "table"
		and type(P.inventory.normal_items) == "table"
		and P.inventory.normal_items or {}
	return {
		token = tonumber(P.trait_reroll_tokens) or 0,
		star_remnant = tonumber(Items.star_remnant) or 0,
		star_remnant_limited = tonumber(Items.star_remnant_limited) or 0,
	}
end

-- accept the old aliases too, but always work with the real item ids
local function NormalizeTraitSource(Source)
	local S = tostring(Source or ""):lower()
	if S == "remnant" then
		return "star_remnant"
	elseif S == "remnant_ltd" or S == "limited" then
		return "star_remnant_limited"
	elseif S == "tokens" then
		return "token"
	end
	return S
end

-- Star remnants are consumed per rarity (verified game rule):
--   Mythic / Secret -> 5 remnants per reroll
--   Rare / Epic / Legendary (and everything else) -> 1 remnant
-- Tokens always cost 1. "TraitMinResources" stays as a safety reserve.
local function RemnantCost(UnitId)
	local Def = type(Units[UnitId]) == "table" and Units[UnitId] or {}
	local Rarity = tostring(Def.rarity or ""):lower()
	if Rarity == "mythic" or Rarity == "mythical" or Rarity == "secret" then
		return 5
	end
	return 1
end

local function TraitRerollCost(Source, UnitId)
	if Source == "star_remnant" or Source == "star_remnant_limited" then
		return RemnantCost(UnitId)
	end
	return 1
end

local function NextTraitSource(Res, Exhausted, UnitId)
	for _, Raw in ipairs(Config.TraitSources or {}) do
		local Source = NormalizeTraitSource(Raw)
		local Cost = TraitRerollCost(Source, UnitId)
		if not (Exhausted and Exhausted[Source])
			and (tonumber(Res[Source]) or 0) - Cost >= Config.TraitMinResources then
			return Source
		end
	end
	return nil
end

local function SpendTraitReroll(Source, Uuid)
	if Source == "star_remnant" then
		return Util.Call(10, InvokeServer, "use_item", "star_remnant", { unit_uuid = Uuid })
	elseif Source == "star_remnant_limited" then
		return Util.Call(10, InvokeServer, "use_item", "star_remnant_limited", { unit_uuid = Uuid })
	end
	return Util.Call(10, InvokeServer, "request_token_trait_reroll", Uuid)
end

function Lobby.AutoRollTraits(UnitId)
	if not AutoTraitEnabled() or not UnitId then
		return
	end
	UnitId = Account.UnitId(UnitId)
	State.TraitRoll = State.TraitRoll or {}
	local Saved = State.TraitRoll[UnitId]
	if Saved and Saved.doneAt then
		return -- once per unit, even across teleports
	end

	local Copy = TraitCopy(UnitId)
	if not Copy then
		return
	end
	local Uuid = Copy.Uuid

	local Current = UnitTraitList(Copy.Unit)
	local Hit = KeptTrait(Current)
	if Hit then
		State.TraitRoll[UnitId] = {
			doneAt = os.time(), gotUnique = Hit.id == "unique",
			traits = TraitLabels(Current), rolls = 0,
		}
		SaveState()
		Log("%s already has %s - skipping trait rolls", Account.UnitName(UnitId), Hit.id)
		return
	end

	-- A roll that doesn't land just means this resource can't pay for the next
	-- tier on this unit (remnant cost is 5 for Mythic/Secret, 1 otherwise).
	-- Fall through to the next source instead of stopping.
	local Exhausted = {} -- source -> true once it failed / didn't replicate
	if not NextTraitSource(TraitResources(), Exhausted, UnitId) then
		Log("no trait reroll resources for %s - will retry next lobby visit", Account.UnitName(UnitId))
		return
	end

	-- no roll cap: keep going until Unique/kept trait lands or every source fails
	local Rolls, GotUnique = 0, false
	while true do
		-- re-read live state before spending anything
		Copy = TraitCopy(UnitId) or Copy
		Current = UnitTraitList(Copy.Unit)
		Hit = KeptTrait(Current)
		if Hit then
			GotUnique = Hit.id == "unique"
			break
		end

		local Res = TraitResources()
		local Source = NextTraitSource(Res, Exhausted, UnitId)
		if not Source then
			break
		end

		local Cost = TraitRerollCost(Source, UnitId)
		local BeforeSig = TraitSignature(Current)
		local BeforeLeft = tonumber(Res[Source]) or 0
		local Ok, Result = SpendTraitReroll(Source, Uuid)
		local Landed = Ok and Result ~= false
		if Landed then
			-- a reroll only counts when the traits changed OR the resource
			-- actually dropped by the full cost; otherwise the server refused it
			local Changed = false
			local Deadline = os.clock() + Config.TraitChangeTimeout
			repeat
				task.wait(0.1)
				local Fresh = TraitCopy(UnitId)
				local FreshList = Fresh and UnitTraitList(Fresh.Unit) or {}
				local NowRes = TraitResources()
				Changed = (TraitSignature(FreshList) ~= BeforeSig)
					or ((tonumber(NowRes[Source]) or 0) <= BeforeLeft - Cost)
			until Changed or os.clock() >= Deadline
			Landed = Changed
		end
		if not Landed then
			Exhausted[Source] = true
			Log("trait reroll via %s did not land (%d left, needs %d) - trying next source",
				Source, BeforeLeft, Cost)
			continue -- move on to limited remnants / next configured source
		end

		Rolls += 1
		Copy = TraitCopy(UnitId) or Copy
		Current = UnitTraitList(Copy.Unit)
		Hit = KeptTrait(Current)
		if Hit then
			GotUnique = Hit.id == "unique"
			break
		end
		task.wait(Config.TraitRollDelay)
	end

	Copy = TraitCopy(UnitId) or Copy
	Current = UnitTraitList(Copy.Unit)
	Hit = KeptTrait(Current)
	GotUnique = Hit and Hit.id == "unique" or false
	local Record = {
		gotUnique = GotUnique,
		traits = TraitLabels(UnitTraitList(Copy.Unit)),
		rolls = Rolls,
	}
	if Hit then
		Record.doneAt = os.time() -- only stop future visits when it landed
	end
	State.TraitRoll[UnitId] = Record
	SaveState()
	Log("traits for %s: %s (%d roll(s), unique=%s%s)", Account.UnitName(UnitId),
		table.concat(Record.traits, ", "), Rolls, tostring(GotUnique),
		Hit and "" or " - will retry next lobby visit")
end


-- ============================================================================
-- auto sell - keep equipped + locked + one copy of team/compass units,
-- sell every other level-1 unit so the inventory (cap 100) never overflows
-- ============================================================================
-- profile.collection.owned_units entries do NOT carry a `level` field - they
-- carry `xp`. The game derives the unit level from that xp via
-- UnitServiceCore.calculate_level (verified live: xp=125 -> level 2,
-- xp=286 -> level 4). Falling back to 0 here made auto sell treat every
-- leveled unit as level 1 and sell it.
local function UnitLevelOf(Unit)
	if type(Unit) ~= "table" then
		return 0
	end
	for _, Key in ipairs({ "level", "upgrade", "unit_level", "_level", "_upgrade", "upgrade_level" }) do
		local Value = tonumber(Unit[Key])
		if Value then
			return Value
		end
	end
	local Xp = tonumber(Unit.xp)
	if not Xp then
		return 0
	end
	if UnitServiceCore and UnitServiceCore.calculate_level then
		local Ok, Level = pcall(UnitServiceCore.calculate_level, nil, Xp)
		if Ok and tonumber(Level) then
			return math.floor(tonumber(Level))
		end
	end
	if LevelServiceCore and LevelServiceCore.calculate_level then
		local Ok, Level = pcall(LevelServiceCore.calculate_level, nil, Xp)
		if Ok and tonumber(Level) then
			return math.floor(tonumber(Level))
		end
	end
	return 0
end

local PROTECTED_RARITIES = { mythic = true, secret = true }

function Lobby.AutoSell()
	if not Config.AutoSell then
		return
	end
	local Coll = Account.Collection()
	local Owned = Coll.owned_units or {}
	local Equipped = {}
	for _, Uuid in pairs(Coll.equipped_units or {}) do
		Equipped[tostring(Uuid)] = true
	end

	-- unit ids we always keep one copy of
	local KeepIds = {}
	local Compass = Account.CompassUnit()
	if Compass then
		KeepIds[Compass] = true
	end
	for _, Id in ipairs(Config.Team or {}) do
		KeepIds[Account.UnitId(Id)] = true
	end

	local Kept, Sell = {}, {}
	for Uuid, Unit in pairs(Owned) do
		if type(Unit) == "table" then
			local Id = type(Unit.unit_id) == "string" and Unit.unit_id or nil
			local UuidString = type(Unit.uuid) == "string" and Unit.uuid or tostring(Uuid)
			local Def = Id and Units[Id] or nil
			local Rarity = type(Def) == "table" and type(Def.rarity) == "string"
				and Def.rarity:lower() or ""
			if PROTECTED_RARITIES[Rarity] then
				continue -- never sell Mythic/Secret units
			end
			if UnitLevelOf(Unit) > 1 or Unit._locked == true or Equipped[UuidString] then
				if Id and KeepIds[Id] then
					Kept[Id] = true
				end
			elseif Id and KeepIds[Id] and not Kept[Id] then
				Kept[Id] = true
			else
				Sell[#Sell + 1] = UuidString
			end
		end
	end
	if #Sell == 0 then
		return
	end

	local Before = Util.Count(Owned)
	LogT("Sell", "selling %d unit(s)", #Sell)
	for Index = 1, #Sell, 50 do
		local Batch = {}
		for J = Index, math.min(Index + 49, #Sell) do
			Batch[#Batch + 1] = Sell[J]
		end
		Util.Invoke("sell_units", Batch)
		task.wait(0.3)
	end
	local After = Util.Count(Account.Collection().owned_units or {})
	LogT("Sell", "%d -> %d units", Before, After)
end

-- ============================================================================
-- compass / summon / hunt
-- ============================================================================
-- The pick is spent only while the compass ITEM is in the inventory. That count
-- lives in profile.inventory.normal_items - the same table the remnant rerolls
-- read - so the lookup below is identical. The visible summon GUI slot stays
-- the confirmation that the pick actually landed.
local function CompassSlot()
	local Gui = PlayerGui:FindFirstChild("SummonGUI")
	local Frames = Gui and Gui:FindFirstChild("BannerFrames")
	local Banner = Frames and (Frames:FindFirstChild(Config.SummonBanner)
		or Frames:FindFirstChild("EventClover"))
	local Compass = Banner and Banner:FindFirstChild("CelestialCompass")
	return Compass and Compass:FindFirstChild("Slot") or nil
end

local function CompassUsedInGui()
	local Slot = CompassSlot()
	return Slot ~= nil and Slot:FindFirstChild(Config.CompassId) ~= nil
end

local function WaitForCompassGui(Timeout)
	local Deadline = os.clock() + (Timeout or 6)
	while os.clock() < Deadline do
		if CompassUsedInGui() then
			return true
		end
		task.wait(0.1)
	end
	return CompassUsedInGui()
end

local function CompassDone()
	return State.Compass == true or State.CompassDone == true
end

-- Same inventory shape TraitResources() uses for star remnants:
-- profile.inventory.normal_items[itemId] = count.
local function HasCompassItem()
	local P = Account.Profile()
	local Items = type(P.inventory) == "table"
		and type(P.inventory.normal_items) == "table"
		and P.inventory.normal_items or {}
	return (tonumber(Items[Config.CompassId]) or 0) > 0
end

-- The GUI slot confirms the pick; the inventory item is the trigger to spend
-- it. Kept for callers that pass Force, but the item check decides now.
function Lobby.UseCompass(Force)
	local Pick = Account.CompassUnit()
	if not Pick then
		return false
	end
	-- the GUI slot is the source of truth, re-checked on every lobby visit
	if CompassUsedInGui() then
		if not CompassDone() then
			State.Compass = true
			State.CompassDone = true
			SaveState()
		end
		return true
	end
	-- item present = pick not spent yet: always use it (every lobby visit,
	-- no once-per-session throttle). No item = nothing to use.
	if not HasCompassItem() then
		return false
	end

	local Ep = Util.Endpoint("set_celestial_compass_pick")
	if not Ep or not Ep:IsA("RemoteFunction") then
		Log("compass remote not found")
		return false
	end
	Log("compass -> %s", Account.UnitName(Pick))
	local Ok, Result = Util.Call(5, function()
		return Ep:InvokeServer(Config.CompassId, Pick)
	end)
	if not Ok then
		Log("compass failed: %s", tostring(Result))
		return false
	end
	if type(Result) == "string" then
		Log("compass replied: %s", Result)
	end
	if Result == false then
		return false
	end
	-- only accept the pick once the slot actually appears in the GUI
	if WaitForCompassGui(6) then
		State.Compass = true
		State.CompassDone = true
		SaveState()
		Log("compass used -> %s (slot verified)", Account.UnitName(Pick))
		return true
	end
	Log("compass pick sent but the slot is not visible yet - will retry next lobby visit")
	return false
end

Lobby.Compass = function()
	return Lobby.UseCompass(false)
end

-- The hatch result and the collection replicate after the buy_from_banner
-- remote returns, so sell only once the new units are actually visible.
local function HatchFingerprint()
	local Stats = Account.Profile()._hatched_unit_stats or {}
	local Parts = {}
	for Id, Counts in pairs(Stats) do
		Parts[#Parts + 1] = tostring(Id) .. ":" .. tostring(tonumber(Counts.normal) or 0)
			.. "/" .. tostring(tonumber(Counts.shiny) or 0)
	end
	table.sort(Parts)
	return table.concat(Parts, ",")
end

local function OwnedCount()
	return Util.Count(Account.Collection().owned_units or {})
end

local function WaitForSummonCollection(HatchBefore, CountBefore)
	local Deadline = os.clock() + 8
	local Changed = false
	repeat
		task.wait(0.15)
		Changed = (HatchFingerprint() ~= HatchBefore) or (OwnedCount() ~= CountBefore)
	until Changed or os.clock() >= Deadline
	LogT("Summon", Changed and "new units replicated" or "no replication detected - proceeding")
	return Changed
end

-- Hunting runs its own sell after each batch; the one-time summon must NOT
-- sell here, because Lobby.Run equips the team first and only then filters.
local function SellAfterSummon(HatchBefore, CountBefore)
	WaitForSummonCollection(HatchBefore, CountBefore)
	Lobby.AutoSell()
end

function Lobby.SummonOnce()
	if not Config.Summon10Once or State.Summoned then
		return
	end
	-- The compass pick must be used before the very first summon. Retry it
	-- here even if the earlier lobby pass failed, and defer the roll.
	if Account.CompassUnit() and not CompassDone() and not Lobby.UseCompass(true) then
		Log("compass not used yet - deferring the first summon to the next lobby visit")
		return
	end
	local Banner = Banners[Config.SummonBanner]
	if type(Banner) ~= "table" then
		Log("unknown banner %s", tostring(Config.SummonBanner))
		return
	end
	local Cost = (tonumber(Banner.gem_cost) or 50) * 10
	if Account.Gems() < Cost then
		return
	end
	local Before = Account.Gems()
	local HatchBefore = HatchFingerprint()
	local CountBefore = OwnedCount()
	Util.Call(5, InvokeServer, "buy_from_banner", Config.SummonBanner, "gems10")
	local Deadline = os.clock() + 4
	repeat
		task.wait(0.1)
	until Account.Gems() < Before or os.clock() >= Deadline
	if Account.Gems() < Before then
		State.Summoned = true
		SaveState()
		LogT("Summon", "first 10x done on %s", Config.SummonBanner)
		-- wait for the pulled units, then let Lobby.Run equip before selling
		WaitForSummonCollection(HatchBefore, CountBefore)
	else
		Log("first 10x was ignored - will retry next visit")
	end
end

-- True when the compass unit is owned, traits are not settled, and we still
-- have a resource that can pay for a reroll. Used to block story/infinite/
-- challenges until the roll is done.
function Lobby.NeedTraitRoll()
	if not AutoTraitEnabled() then
		return false
	end
	local UnitId = Account.CompassUnit()
	if not UnitId or not Account.HasUnit(UnitId) then
		return false
	end
	local Record = State.TraitRoll and State.TraitRoll[UnitId]
	if Record and Record.doneAt then
		return false
	end
	local Exhausted = {}
	return NextTraitSource(TraitResources(), Exhausted, UnitId) ~= nil
end

function Lobby.HuntTarget()
	return Account.CompassUnit()
end

-- Exact time from the server clock (no grace window). Challenges reset at
-- XX:00 and XX:30; hunting and challenge queueing share the same exact gate.
local LastHuntTimeLog = 0
local function ServerMinute()
	local Ok, Server = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	local Now = (Ok and tonumber(Server)) and Server or os.time()
	return math.floor(Now % 3600 / 60), math.floor(Now / 3600) % 24
end

local function HuntMinutes()
	return {
		tonumber(Config.HuntAtMinute), tonumber(Config.HuntAtMinute2),
		tonumber(Config.HuntAtMinute3), tonumber(Config.HuntAtMinute4),
	}
end

-- challenges reset every 15 minutes (:00/:15/:30/:45) regardless of the hunt
-- window, so use fixed slots here rather than the hunt config.
local function ResetMinuteOk()
	local Minute = ServerMinute()
	for _, Value in ipairs({ 0, 15, 30, 45 }) do
		if Minute == Value then
			return true
		end
	end
	return false
end

-- Hunting is allowed from minute 01 through 50. The XX:51 -> XX:00 window
-- is reserved (no hunting). Config slots work as an override: if any are set,
-- only those exact minutes are used instead of the 1-50 window.
local function HuntTimeOk()
	local Slots = HuntMinutes()
	local Any = false
	for _, Value in ipairs(Slots) do
		if Value ~= nil then Any = true end
	end
	local Minute, Hour = ServerMinute()
	if Any then
		for _, Value in ipairs(Slots) do
			if Value and Minute == math.floor(Value) then
				return true
			end
		end
	else
		-- default window: minutes 1-50
		if Minute >= 1 and Minute <= 50 then
			return true
		end
	end
	if os.clock() - LastHuntTimeLog > 60 then
		LastHuntTimeLog = os.clock()
		local Labels = {}
		if Any then
			for _, Value in ipairs(Slots) do
				if Value ~= nil then Labels[#Labels + 1] = (":%02d"):format(Value) end
			end
		else
			Labels[1] = "01-50"
		end
		LogT("Hunt", "waiting for %s (server %02d:%02d)", table.concat(Labels, "/"), Hour, Minute)
	end
	return false
end

function Lobby.NeedHunt()
	local Target = Lobby.HuntTarget()
	if not Target or Account.HasUnit(Target) then
		return false
	end
	if not HuntTimeOk() then
		return false
	end
	return Account.Gems() >= Config.HuntFrom
end

function Lobby.Hunt()
	local Target = Lobby.HuntTarget()
	if not Target then
		return false
	end
	local Banner = Banners[Config.SummonBanner] or {}
	local Cost = (tonumber(Banner.gem_cost) or 50) * 10
	local Rolls = 0
	local LastHatch, LastCount = HatchFingerprint(), OwnedCount()
	LogT("Hunt", "hunting %s with %d gems", Account.UnitName(Target), Account.Gems())
	while Rolls < Config.MaxHuntRolls do
		if Account.HasUnit(Target) then
			LogT("Hunt", "got %s after %d roll(s)", Account.UnitName(Target), Rolls)
			Lobby.AutoRollTraits(Target) -- roll for Unique as soon as it drops
			SellAfterSummon(LastHatch, LastCount)
			return true
		end
		if Account.Gems() - Cost < Config.KeepGems then
			break
		end
		local Before = Account.Gems()
		LastHatch, LastCount = HatchFingerprint(), OwnedCount()
		Util.Call(5, InvokeServer, "buy_from_banner", Config.SummonBanner, "gems10")
		local Deadline = os.clock() + 5
		repeat
			task.wait(0.2)
		until Account.Gems() < Before or Account.HasUnit(Target) or os.clock() >= Deadline
		if Account.Gems() < Before then
			Rolls += 1
			-- sell after EVERY batch, not only when the compass unit finally drops
			SellAfterSummon(LastHatch, LastCount)
			LastHatch, LastCount = HatchFingerprint(), OwnedCount()
		else
			task.wait(1)
		end
	end
	LogT("Hunt", "stopped after %d roll(s), %d gems left", Rolls, Account.Gems())
	return false
end

-- ============================================================================
-- team
-- ============================================================================
-- Real per-unit stats live on the collection copy, not in the Units module
-- (the module only has base stats). Live-verified fields:
--   trait_stats = { potency_stat = DAMAGE_MULT, speed_stat = ATTACK_SPEED_MULT,
--                   range_stat = RANGE_MULT },  further_modifiers = {...},
--   xp, shiny, traits. DPS scales with potency * speed and the xp-derived level.
-- Equipped relic stats live on the unique-item entry, not on the unit. The
-- relic uuid is Unit._equipped_relic; profile.inventory.unique_items[n] holds
-- _unique_item_data._unique_relic_data with the real crit/mul buffs (the 27%
-- crit shown on the unit card). Cached per relic uuid.
local RelicBuffCache = {}
local function RelicBuffs(Unit)
	local Uuid = type(Unit._equipped_relic) == "string" and Unit._equipped_relic or nil
	if not Uuid then
		return 1, 0
	end
	local Cached = RelicBuffCache[Uuid]
	if Cached then
		return Cached.Mul, Cached.Crit
	end
	local Mul, Crit = 1, 0
	local Items = Account.Profile().inventory
	Items = type(Items) == "table" and type(Items.unique_items) == "table" and Items.unique_items or {}
	for _, Entry in pairs(Items) do
		if type(Entry) == "table" and Entry.uuid == Uuid then
			local Data = type(Entry._unique_item_data) == "table"
				and type(Entry._unique_item_data._unique_relic_data) == "table"
				and Entry._unique_item_data._unique_relic_data or nil
			if Data then
				for _, Buff in pairs(type(Data._core_damage_type_buffs) == "table"
					and Data._core_damage_type_buffs or {}) do
					if type(Buff) == "table" then
						Mul *= 1 + (tonumber(Buff.mul) or 0)
						Crit += tonumber(Buff.crit) or 0
					end
				end
			end
			break
		end
	end
	RelicBuffCache[Uuid] = { Mul = Mul, Crit = Crit }
	return Mul, Crit
end

-- Traits.effects is the game's own table (verified live):
--   unique = { stats = { damage = 3, cooldown = -0.1, range = 0.1 } }  (3x dmg!)
--   superior = { tiers = { [1] = { damage = 0.1 }, ... } }
--   nimble = { tiers = { [1] = { cooldown = -0.05 }, ... } }, etc.
local function TraitEffects(Unit)
	local EffectDefs = type(Traits.effects) == "table" and Traits.effects or {}
	local Damage, Cooldown, Range = 1, 1, 1
	local List = type(Unit.traits) == "table" and Unit.traits or {}
	for _, Entry in pairs(List) do
		if type(Entry) == "table" then
			local Id = Entry.trait
			local Effect = type(Id) == "string" and EffectDefs[Id] or nil
			if type(Effect) == "table" then
				local Stats = type(Effect.stats) == "table" and Effect.stats or {}
				local Tier = math.floor(tonumber(Entry.tier) or 1)
				local TierStats = type(Effect.tiers) == "table" and Effect.tiers[Tier] or nil
				local function Value(Key)
					local V = tonumber(Stats[Key]) or 0
					if type(TierStats) == "table" then
						V += tonumber(TierStats[Key]) or 0
					end
					return V
				end
				-- damage is additive (Unique = 3 => 4x total), cooldown is negative
				Damage *= 1 + Value("damage")
				Cooldown *= 1 / (1 - math.clamp(Value("cooldown"), -0.95, 0))
				Range *= 1 + Value("range")
			end
		end
	end
	return Damage, Cooldown, Range
end

local function TraitMultipliers(Unit)
	local Stats = type(Unit.trait_stats) == "table" and Unit.trait_stats or {}
	local Potency = tonumber(Stats.potency_stat) or 1
	local Speed = tonumber(Stats.speed_stat) or 1
	local Range = tonumber(Stats.range_stat) or 1
	local Mods = type(Unit.further_modifiers) == "table" and Unit.further_modifiers or {}
	for _, Key in ipairs({ "potency_stat", "damage", "damage_multiplier", "dmg" }) do
		local Value = tonumber(Mods[Key])
		if Value then
			Potency *= Value
		end
	end
	for _, Key in ipairs({ "speed_stat", "attack_speed", "speed" }) do
		local Value = tonumber(Mods[Key])
		if Value then
			Speed *= Value
		end
	end
	local RelicMul, RelicCrit = RelicBuffs(Unit)
	-- crit is a 2x hit, so expected value is 1 + crit chance
	Potency *= RelicMul * (1 + math.clamp(RelicCrit, 0, 1))
	-- rolled traits from the game's own effect table (Unique = 3x damage)
	local TraitDamage, TraitCooldown, TraitRange = TraitEffects(Unit)
	Potency *= TraitDamage
	Speed *= TraitCooldown
	Range *= TraitRange
	return Potency, Speed, Range
end

-- merge upgrade[] deltas up to the unit's real (xp-derived) level
local function LevelStats(UnitId, Level)
	local Def = Units[UnitId]
	if type(Def) ~= "table" then
		return {}
	end
	local Merged = {}
	for Key, Value in pairs(Def) do
		Merged[Key] = Value
	end
	if Level > 0 and type(Def.upgrade) == "table" then
		for Index = 1, Level do
			local Entry = Def.upgrade[Index]
			if type(Entry) == "table" then
				for Key, Value in pairs(Entry) do
					Merged[Key] = Value
				end
			end
		end
	end
	return Merged
end

-- Card-verified damage formula: the module damage is scaled linearly with the
-- unit level, then multiplied by the potency IV. Live check: elyssia_evolved
-- base 2800 at Lv95 -> ~29,206 on the card = 2800 * (1 + 94*0.1) * 1.1055.
-- Level-1 units keep base damage; range/SPA come from the trait_stats IVs.
local function ScoreUnit(Unit)
	local Level = UnitLevelOf(Unit)
	local Def = Units[Unit.unit_id] or {}
	local Stats = LevelStats(Unit.unit_id, Level)
	local Damage = tonumber(Stats.damage) or tonumber(Def.damage) or 0
	local Cooldown = tonumber(Stats.attack_cooldown) or tonumber(Stats.cooldown)
		or tonumber(Def.attack_cooldown) or 0

	local Potency, Speed, Range = TraitMultipliers(Unit)
	local LevelScale = 1 + math.max(Level - 1, 0) * 0.1
	local RealDamage = Damage * LevelScale * Potency
	local RealCooldown = Cooldown / (Speed > 0 and Speed or 1)
	local Dps = RealCooldown > 0 and (RealDamage / RealCooldown) or RealDamage

	-- shiny is cosmetic only; stat_luck and rarity are not damage stats.
	-- range IV is only a tiny tie-breaker.
	local Score = Dps + (tonumber(Stats.range) or 0) * Range * 0.000001
	return Score
end

local function BestCopy(UnitId)
	local Out
	for Uuid, Unit in pairs(Account.Collection().owned_units or {}) do
		if type(Unit) == "table" and Unit.unit_id == UnitId then
			local Score = ScoreUnit(Unit)
			if not Out or Score > Out.Score then
				Out = { Uuid = tostring(Uuid), Score = Score }
			end
		end
	end
	return Out
end

local function IsFarm(UnitId)
	local Def = Units[UnitId]
	if type(Def) ~= "table" then
		return false
	end
	if Def.farm_amount ~= nil or Def._show_as_farm_unit == true then
		return true
	end
	for _, Entry in pairs(type(Def.end_of_wave) == "table" and Def.end_of_wave or {}) do
		if type(Entry) == "table" and Entry.type == "farm" then
			return true
		end
	end
	return false
end

local function EquippedSet()
	local Set = {}
	for _, Uuid in pairs(Account.Collection().equipped_units or {}) do
		Set[tostring(Uuid)] = true
	end
	return Set
end

function Lobby.EquipTeam()
	if not Config.EquipTeam or not Account.WaitCollection(20) then
		return
	end
	local Slots = tonumber(GameplaySettings.NUM_TEAM_SLOTS) or 6
	local Used, Want = {}, {}

	local function Add(UnitId)
		UnitId = Account.UnitId(UnitId)
		if not UnitId or Used[UnitId] or #Want >= Slots then
			return
		end
		local Copy = BestCopy(UnitId)
		if Copy then
			Used[UnitId] = true
			Want[#Want + 1] = { Uuid = Copy.Uuid, Farm = IsFarm(UnitId) }
		end
	end

	-- configured team first, in order
	if type(Config.Team) == "table" then
		for _, Id in ipairs(Config.Team) do
			Add(Id)
		end
	end

	-- then the best scoring owned units
	local Ranked = {}
	for _, Unit in pairs(Account.Collection().owned_units or {}) do
		if type(Unit) == "table" and type(Unit.unit_id) == "string" and not Used[Unit.unit_id] then
			Ranked[#Ranked + 1] = { Id = Unit.unit_id, Score = ScoreUnit(Unit) }
		end
	end
	table.sort(Ranked, function(A, B)
		return A.Score > B.Score
	end)
	for _, Entry in ipairs(Ranked) do
		Add(Entry.Id)
	end

	-- farms go to the last slots
	table.sort(Want, function(A, B)
		if A.Farm ~= B.Farm then
			return not A.Farm
		end
		return false
	end)

	local Target = {}
	for Slot, Entry in ipairs(Want) do
		Target[Entry.Uuid] = Slot
	end

	-- already correct? leave it alone (no unequip flicker)
	local Current = EquippedSet()
	local Same = Util.Count(Current) == #Want
	if Same then
		for Uuid in pairs(Target) do
			if not Current[Uuid] then
				Same = false
				break
			end
		end
	end
	if Same then
		LogT("Team", "already equipped %d/%d", Util.Count(Current), Slots)
		return Util.Count(Current) == Slots or Util.Count(Current) == #Want
	end

	local UnequipAll = Util.Endpoint("unequip_all")
	if UnequipAll and UnequipAll:IsA("RemoteFunction") then
		pcall(function()
			UnequipAll:InvokeServer()
		end)
	else
		for Uuid in pairs(EquippedSet()) do
			Util.Call(10, InvokeServer, "unequip_unit", Uuid)
			task.wait(0.5)
		end
	end

	local Deadline = os.clock() + 8
	while os.clock() < Deadline and next(EquippedSet()) ~= nil do
		task.wait(0.3)
	end

	for Pass = 1, 3 do
		local InSlots = EquippedSet()
		local Missing = {}
		for Uuid, Slot in pairs(Target) do
			if not InSlots[Uuid] then
				Missing[#Missing + 1] = { Uuid = Uuid, Slot = Slot }
			end
		end
		if #Missing == 0 then
			break
		end
		for _, Entry in ipairs(Missing) do
			task.wait(0.5)
			if Pass == 1 then
				Util.Call(10, InvokeServer, "equip_unit", Entry.Uuid)
			else
				Util.Call(10, InvokeServer, "equip_unit", Entry.Uuid, Entry.Slot)
			end
		end
	end

	-- wait for the replicated equipment state before declaring the slots full
	local VerifyDeadline = os.clock() + 6
	while os.clock() < VerifyDeadline do
		local Now = EquippedSet()
		local Missing = 0
		for Uuid in pairs(Target) do
			if not Now[Uuid] then
				Missing += 1
			end
		end
		if Missing == 0 then
			break
		end
		task.wait(0.4)
	end

	local Left = Util.Count(EquippedSet())
	local Full = Left == #Want
	LogT("Team", "equipped %d/%d slots (%s)", Left, Slots, Full and "full" or "partial")
	return Full
end


-- ============================================================================
-- joining
-- ============================================================================
Lobby.Skip = {} -- lobby templates that refused the lock

-- Only templates physically inside workspace._LOBBIES.Story may be joined.
-- more_lobby_params also lists challenge/event/portal templates that reuse the
-- same names, so filtering by name alone is not enough - use the Story folder
-- itself as the source of truth.
local function StoryTemplateNames()
	local Set = {}
	local Root = workspace:FindFirstChild("_LOBBIES")
	local Folder = Root and Root:FindFirstChild("Story")
	if Folder then
		for _, Model in ipairs(Folder:GetChildren()) do
			Set[Model.Name] = true
		end
	end
	return Set
end

local function FindLobby()
	local Root = workspace:FindFirstChild("_LOBBIES")
	local Folder = Root and Root:FindFirstChild("Story")
	if not Folder then
		return nil
	end
	for _, Model in ipairs(Folder:GetDescendants()) do
		local Owner = Model:FindFirstChild("Owner")
		if Owner and Owner:IsA("ValueBase") then
			local Value = Owner.Value
			local Name = typeof(Value) == "Instance" and Value.Name or tostring(Value)
			if Name == Player.Name then
				return Model
			end
		end
	end
	return nil
end

local function LobbyCandidates(LevelId)
	local Story = StoryTemplateNames()
	local List = {}
	for Name, Data in pairs((LobbyServiceClient and LobbyServiceClient.more_lobby_params) or {}) do
		if Story[Name] and not Lobby.Skip[Name] then
			local Bound = type(Data) == "table" and type(Data._level_data) == "table" and Data._level_data.id
			-- prefer a template already bound to this level, else any free one
			local Rank = (Bound == LevelId) and 1 or 2
			List[#List + 1] = { Name = Name, Rank = Rank }
		end
	end
	table.sort(List, function(A, B)
		if A.Rank ~= B.Rank then
			return A.Rank < B.Rank
		end
		return A.Name < B.Name
	end)
	return List
end

local function EnsureLobby(LevelId)
	local Model = FindLobby()
	if Model then
		return Model
	end
	for _, Candidate in ipairs(LobbyCandidates(LevelId)) do
		if Util.Invoke("request_join_lobby", Candidate.Name) then
			local Deadline = os.clock() + 8
			repeat
				task.wait(0.25)
				Model = FindLobby()
			until Model or os.clock() >= Deadline
			if Model then
				return Model
			end
		end
	end
	return nil
end

local function LeaveLobby()
	local Model = FindLobby()
	if Model then
		Util.Invoke("request_leave_lobby", Model.Name)
		task.wait(0.4)
	end
end

function Lobby.Queued()
	local Gui = PlayerGui:FindFirstChild("MatchmakingUI")
	return Gui ~= nil and Gui.Enabled == true
end

function Lobby.QueueMap()
	local Gui = PlayerGui:FindFirstChild("MatchmakingUI")
	if not Gui or not Gui.Enabled then
		return nil
	end
	for _, Item in ipairs(Gui:GetDescendants()) do
		if Item:IsA("TextLabel") and Item.Name == "Map" then
			return Item.Text
		end
	end
	return nil
end

local function StageOfWorld(WorldId, Act)
	local World = Worlds[WorldId]
	if type(World) ~= "table" or type(World.levels) ~= "table" then
		return nil
	end
	local Keys = {}
	for Key in pairs(World.levels) do
		Keys[#Keys + 1] = Key
	end
	table.sort(Keys, function(A, B)
		return (tonumber(A) or 9999) < (tonumber(B) or 9999)
	end)
	if #Keys == 0 then
		return nil
	end
	local Index = math.clamp(Act or 1, 1, #Keys)
	local Entry = World.levels[Keys[Index]]
	local Id = type(Entry) == "table" and (Entry.id or Entry.level_id) or Entry
	return type(Id) == "string" and Levels[Id] and Id or nil
end

function Lobby.StoryStage()
	local Order = WorldLevelOrder.WORLD_ORDER
	local WorldId = Order and Order[1] and tostring(Order[1])
	return WorldId and StageOfWorld(WorldId, Config.StoryAct) or nil
end

function Lobby.InfiniteStage()
	for _, WorldId in ipairs(WorldLevelOrder.WORLD_ORDER or {}) do
		local World = Worlds[tostring(WorldId)]
		if type(World) == "table" and type(World.infinite) == "table" then
			local Id = World.infinite.id or World.infinite.level_id
			if type(Id) == "string" then
				return Id
			end
		end
	end
	return nil
end

local function JoinSolo(LevelId, Difficulty, SkipWorld)
	for Attempt = 1, 3 do
		local Model = EnsureLobby(LevelId)
		if not Model then
			Log("no lobby available for %s", tostring(LevelId))
			return false
		end
		local LobbyId = Model.Name
		if LobbyServiceClient then
			LobbyServiceClient.current_lobby = LobbyId
			LobbyServiceClient.current_lobby_model = Model
			LobbyServiceClient.selected_level = LevelId
			LobbyServiceClient.difficulty = Difficulty
			LobbyServiceClient.friends_only = false
			LobbyServiceClient.map_item_id = nil
		end
		task.wait(0.5)
		-- story skipper: jump straight to the last act (acts 1-5 skipped)
		if SkipWorld then
			local _, Sent = Util.Invoke("lobby_world_skip", SkipWorld)
			if not Sent then
				Log("world skip refused for %s", tostring(SkipWorld))
				return false
			end
			Log("world skip -> %s (acts 1-5 skipped)", tostring(SkipWorld))
			task.wait(0.5)
		end
		Log("locking %s in %s (%s, try %d)", LevelId, LobbyId, Difficulty, Attempt)
		-- third arg is the "friends only / private lock" flag: the game expects
		-- true here (verified from the generated Cobalt call), false gets refused
		if Util.Invoke("request_lock_level", LobbyId, LevelId, true, Difficulty) then
			if LobbyServiceClient then
				pcall(LobbyServiceClient.on_request_lock_level)
			end
			task.wait(0.4)
			local Started = Util.Invoke("request_start_game", LobbyId)
			-- the remote sometimes answers nil even when the server accepted
			-- the start: the teleport itself is the proof
			local WaitEnd = os.clock() + 3
			while os.clock() < WaitEnd and Loader.IsLobby do
				task.wait(0.2)
			end
			if not Loader.IsLobby or Started then
				Log("starting %s", LevelId)
				return true
			end
			Log("start refused - releasing the lobby")
		else
			Log("lock refused - releasing the lobby and trying another one")
		end
		-- this template did not take the lock: blacklist it and get a fresh one
		Lobby.Skip[LobbyId] = true
		Util.Invoke("request_leave_lobby", LobbyId)
		task.wait(1)
	end
	Lobby.Skip = {}
	return false
end

function Lobby.JoinStory()
	local Stage = Lobby.StoryStage()
	if not Stage then
		Log("no story stage found")
		return false
	end
	State.Current = { Kind = "story", LevelId = Stage }
	SaveState()
	return JoinSolo(Stage, "Normal")
end

function Lobby.JoinInfinite()
	local Stage = Lobby.InfiniteStage()
	if not Stage then
		Log("no infinite stage found")
		return false
	end
	State.Current = { Kind = "infinite", LevelId = Stage }
	SaveState()
	return JoinSolo(Stage, "Hard")
end

local function ClearedLevels()
	local Set = {}
	local Done = (Account.Profile().level_data or {}).completed_story_levels
	if type(Done) == "table" then
		for Id in pairs(Done) do
			Set[tostring(Id)] = true
		end
	end
	return Set
end

-- last act (act 6) of the world we skip acts 1-5 in
function Lobby.Act6Stage()
	local WorldId = Config.SkipWorld and tostring(Config.SkipWorld)
		or (WorldLevelOrder.WORLD_ORDER and tostring(WorldLevelOrder.WORLD_ORDER[1]))
	if not WorldId then
		return nil, nil, nil
	end
	local World = Worlds[WorldId]
	local Count = 0
	if type(World) == "table" and type(World.levels) == "table" then
		for _ in pairs(World.levels) do
			Count += 1
		end
	end
	if Count == 0 then
		return nil, WorldId, nil
	end
	local Act = math.clamp(math.floor(tonumber(Config.SkipAct) or Count), 1, Count)
	return StageOfWorld(WorldId, Act), WorldId, Act
end

-- returns Joined, AlreadyCleared
-- returns Joined, AlreadyCleared
function Lobby.JoinAct6()
	local Stage, WorldId, Act = Lobby.Act6Stage()
	if not Stage then
		Log("no act 6 stage found")
		return false, false
	end
	if ClearedLevels()[Stage] then
		Log("act 6 (%s) already cleared", Stage)
		return false, true
	end
	State.Current = { Kind = "act6", LevelId = Stage }
	SaveState()
	UI.Set("Clearing act 6 (" .. tostring(WorldId) .. ", act " .. tostring(Act) .. ")")
	local Ok = JoinSolo(Stage, "Normal", Config.SkipStory and WorldId or nil)
	if not Ok then
		State.Current = nil
		SaveState()
	end
	return Ok, false
end

-- ============================================================================
-- challenges
-- ============================================================================
function Lobby.ChallengeDefs()
	return {
		{
			Mode = "daily",
			LevelId = "__DAILY_CHALLENGE",
			Label = "Daily Challenge",
			Map = "Daily Challenge",
			Get = "get_daily_challenge",
			MinLevel = Config.DailyChallengeLevel,
		},
		{
			Mode = "normal",
			LevelId = "__NORMAL_CHALLENGE",
			Label = "Normal Challenge",
			Map = "Challenge",
			Get = "get_normal_challenge",
			MinLevel = Config.NormalChallengeLevel,
		},
	}
end

-- nil = nothing to join (cleared, unavailable, or level gated)
function Lobby.ChallengeUuid(Def)
	local Data, Ok = Util.Invoke(Def.Get)
	if not Ok or type(Data) ~= "table" then
		return nil
	end
	local Uuid = Data.current_uuid and tostring(Data.current_uuid) or nil
	if not Uuid then
		return nil
	end
	-- the endpoint has no reliable "cleared" field, so the saved ledger is the
	-- source of truth: Match.Finish records the uuid once that challenge ends
	if Data.completed == true or Data.cleared == true or Data.already_completed == true
		or Data.claimed == true or Data.already_claimed == true then
		State.Clear[Def.Mode] = Uuid
		SaveState()
		return nil
	end
	if State.Clear[Def.Mode] == Uuid then
		return nil
	end
	return Uuid
end

-- Challenges = true joins them outright. With Challenges = false they are
-- only joined in challenges-only mode AFTER the compass UNIT is actually
-- owned — the compass pick alone must not enable them.
local function ChallengesEnabled()
	if Config.ChallengesOnlyAfterCompass then
		local Compass = Account.CompassUnit()
		return Compass ~= nil and Account.HasUnit(Compass)
	end
	return Config.DoChallenges == true
end

-- exact challenge slot from the server clock - no grace window
function Lobby.Slot()
	local Ok, Server = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	local Now = (Ok and tonumber(Server)) and Server or os.time()
	return math.floor(Now / 1800)
end

function Lobby.JoinChallenge(Def, Uuid)
	if Lobby.QueueMap() == Def.Map then
		return true
	end
	if Lobby.Queued() then
		Util.Invoke("leave_matchmaking")
		task.wait(0.5)
	end
	LeaveLobby()
	if LobbyServiceClient then
		pcall(LobbyServiceClient.cancel_selections)
	end

	State.Current = { Kind = "challenge", Mode = Def.Mode, Uuid = Uuid }
	SaveState()

	for Attempt = 1, Config.MatchmakingRetries do
		Log("queueing %s (%d/%d)", Def.Label, Attempt, Config.MatchmakingRetries)
		Util.Invoke("request_matchmaking", Def.LevelId)
		local QueueStart = os.clock()
		repeat
			if Lobby.QueueMap() == Def.Map then
				Log("queued for %s", Def.Label)
				return true
			end
			-- if we dropped out of the queue on our own, stop waiting
			if not Lobby.Queued() then
				break
			end
			task.wait(0.2)
		until os.clock() - QueueStart >= Config.QueueTimeout

		-- 5 minutes elapsed without joining: explicitly leave, then wait 20s
		if Lobby.Queued() then
			Log("queue timed out after %ds - leaving matchmaking", Config.QueueTimeout)
			Util.Invoke("leave_matchmaking")
			task.wait(0.5)
		end
		if Attempt < Config.MatchmakingRetries then
			task.wait(Config.MatchmakingCooldown)
		end
	end
	Log("could not queue %s", Def.Label)
	State.Current = nil
	SaveState()
	return false
end

-- ============================================================================
-- planner
-- ============================================================================
-- returns Def, Uuid, Reachable. Only the remote reply + our saved ledger decide
-- whether a challenge is still pending.
local function PickChallenge(Level)
	local Reachable = false
	for _, Def in ipairs(Lobby.ChallengeDefs()) do
		if Level >= Def.MinLevel then
			local Data, Ok = Util.Invoke(Def.Get)
			if Ok and type(Data) == "table" then
				Reachable = true
				local Uuid = Data.current_uuid and tostring(Data.current_uuid) or nil
				local Cleared = Data.completed == true or Data.cleared == true
					or Data.already_completed == true or Data.claimed == true
					or Data.already_claimed == true
				if Uuid then
					Cleared = Cleared or State.Clear[Def.Mode] == Uuid
				end
				if Uuid and not Cleared then
					return Def, Uuid, true
				end
			end
		end
	end
	return nil, nil, Reachable
end

function Lobby.Plan()
	local Level = Account.Level()
	Log("level %d | gems %d | hunt %s", Level, Account.Gems(),
		State.HuntDone and "done" or "pending")

	-- compass acquisition: group join -> Code UI compass code -> handle the
	-- group/favorite prompt. The compass item in inventory is the only signal,
	-- so nothing else (story/infinite/challenges/hunt) runs until it lands.
	if not HasCompassInInventory() then
		GroupAndFavorite()
		return "social"
	end

	-- while hunting or trait rerolling, do nothing else at all
	if Lobby.NeedHunt() then
		if Lobby.Hunt() then
			Lobby.EquipTeam()
			Lobby.AutoSell()
			if Lobby.NeedTraitRoll() then
				Lobby.AutoRollTraits(Account.CompassUnit())
			end
		end
		return "hunt"
	end
	if Lobby.NeedTraitRoll() then
		Lobby.AutoRollTraits(Account.CompassUnit())
		return "traits"
	end

	if ChallengesEnabled() then
		local Def, Uuid, Reachable = PickChallenge(Level)
		if Def then
			UI.Set("Joining " .. Def.Label)
			return Lobby.JoinChallenge(Def, Uuid) and "queued" or "idle"
		end
	end

	if Level < Config.TargetLevel then
		UI.Set("Story loop (level " .. Level .. "/" .. Config.TargetLevel .. ")")
		return Lobby.JoinStory() and "joined" or "idle"
	end

	-- full-clear act 6 first: the world skipper jumps acts 1-5, then we clear
	-- act 6 and leave. Infinite is only joined once act 6 is already cleared.
	if Config.SkipStory then
		local Joined, AlreadyCleared = Lobby.JoinAct6()
		if Joined then
			return "joined"
		end
		if not AlreadyCleared then
			return "idle" -- skip/join failed: retry, never skip straight to Infinite
		end
	end

	-- challenges-only mode: once the compass UNIT is actually owned (the pick
	-- alone does not count), stop joining story and infinite. Daily/normal
	-- challenges above still run on every lobby visit.
	local CompassUnit = Account.CompassUnit()
	if Config.ChallengesOnlyAfterCompass and CompassUnit
		and Account.HasUnit(CompassUnit) then
		return "idle"
	end
	if Config.DoInfinite then
		UI.Set("Infinite loop (level " .. Level .. ")")
		return Lobby.JoinInfinite() and "joined" or "idle"
	end
	return "idle"
end

function Lobby.Wait()
	local Started = os.clock()
	while Loader.IsLobby do
		if Lobby.Queued() then
			if os.clock() - Started > Config.QueueTimeout then
				Log("queue timed out after %ds - leaving matchmaking", Config.QueueTimeout)
				Util.Invoke("leave_matchmaking")
				task.wait(Config.MatchmakingCooldown)
				return
			end
		elseif os.clock() - Started > 60 then
			return
		end
		task.wait(1)
	end
end

-- wait until the lobby has actually finished loading before doing anything
function Lobby.WaitReady()
	Log("waiting for the lobby to load")
	if not Account.WaitSession(60) then
		return false
	end
	Account.WaitCollection(30)

	local Deadline = os.clock() + 30
	while os.clock() < Deadline do
		if workspace:FindFirstChild("_LOBBIES")
			and LobbyServiceClient
			and type(LobbyServiceClient.more_lobby_params) == "table"
			and next(LobbyServiceClient.more_lobby_params) ~= nil then
			break
		end
		task.wait(0.5)
	end
	-- let the game finish spawning lobby parts and GUIs
	task.wait(5)
	LogT("Lobby", "ready")
	return true
end

function Lobby.Run()
	LogT("Lobby", "mode")
	if not Lobby.WaitReady() then
		warn("[AA Kaitun] lobby did not finish loading")
		return
	end
	-- Cobalt-generated handshake: fire as soon as the lobby is fully loaded,
	-- before touching any other endpoint (settings, codes, group, etc).
	do
		local Root = ReplicatedStorage:FindFirstChild("endpoints")
		local Events = Root and Root:FindFirstChild("client_to_server")
		local Event = Events and Events:FindFirstChild("ds_nt")
		if Event and Event:IsA("RemoteFunction") then
			local Ok, Err = pcall(function()
				return Event:InvokeServer()
			end)
			if not Ok then
				Log("ds_nt failed: %s", tostring(Err))
			end
		end
	end
	GameSettings.Ensure("Lobby") -- before the first summon so quick_summon applies
	local LastSettings = os.clock()
	if Config.ShowStatus then
		UI.Lobby()
	end

	GroupAndFavorite() -- join group + favorite game before claiming codes
	Lobby.RedeemCodes()
	Lobby.Compass()
	Lobby.Claims()
	Lobby.SummonOnce()
	-- equip the full team BEFORE selling anything; otherwise a newly summoned
	-- unit can be sold before it ever reaches a slot
	local TeamFull = false
	if not Config.EquipTeam then
		TeamFull = true -- user opted out of team equipping
	else
		for Attempt = 1, 4 do
			TeamFull = Lobby.EquipTeam() == true
			if TeamFull then
				break
			end
			LogT("Team", "slots not full (try %d) - waiting before selling", Attempt)
			task.wait(2)
		end
	end
	if TeamFull then
		Lobby.AutoSell() -- only after every slot is equipped
	else
		LogT("Sell", "skipped - team slots are not full yet")
	end
	-- the compass unit can arrive from the pick, the first summon or a hunt;
	-- one guarded call covers all three (state prevents rolling twice)
	local CompassUnit = Account.CompassUnit()
	if CompassUnit then
		Lobby.AutoRollTraits(CompassUnit)
	end

	while Loader.IsLobby do
		if os.clock() - LastSettings >= 15 then
			LastSettings = os.clock()
			GameSettings.Ensure("Lobby")
		end
		if Env.AAKaitunStop then
			Log("stop flag set - exiting")
			return
		end
		UI.Set(("Lv %d | %d gems | %s"):format(Account.Level(), Account.Gems(), "planning"))
		local Ok, Result = pcall(Lobby.Plan)
		if not Ok then
			Log("plan error: %s", tostring(Result))
			Result = nil
		end
		if Result == "queued" or Result == "joined" then
			Lobby.Wait()
		else
			task.wait(5)
		end
	end
	UI.Clear()
end


-- ============================================================================
-- match: data helpers
-- ============================================================================
Match.Core = nil
Match.Paths = nil
Match.Grid = nil
Match.Nodes = {}
Match.Lines = {}
Match.Claims = {}
Match.Occupied = {}
Match.Circles = {}
Match.Priority = {}
Match.Rank = {}
Match.Slots = {}
Match.Caps = {}   -- uuid -> real spawn cap resolved from the game UI
Match.Fails = 0
Match.Need = true
Match.Tries = 0
Match.LastScan = -100
Match.LastMapId = nil

local RarityTiers = type(GameplaySettings.RARITY_TIERS) == "table" and GameplaySettings.RARITY_TIERS or {}

function Match.Init()
	if not Match.Core then
		Match.Core = SafeLoad("load_core_service", "PlacementCore")
	end
	if not Match.Paths then
		Match.Paths = SafeLoad("load_core_service", "PathService")
	end
	if not Match.Grid then
		Match.Grid = SafeLoad("load_client_service", "PlacementServiceClient")
	end
end

local function DpsOf(Def)
	if type(Def) ~= "table" then
		return 0
	end
	local Damage = tonumber(Def.damage) or 0
	local Cooldown = tonumber(Def.attack_cooldown) or tonumber(Def.cooldown) or 0
	return Cooldown > 0 and Damage / Cooldown or Damage
end

-- upgrade[] holds partial stat deltas: every level has to be merged in order
local function StatsAt(UnitId, Level)
	local Def = Units[UnitId]
	if type(Def) ~= "table" then
		return nil
	end
	if not Level or Level <= 0 or type(Def.upgrade) ~= "table" then
		return Def
	end
	local Merged = {}
	for Key, Value in pairs(Def) do
		Merged[Key] = Value
	end
	for Index = 1, Level do
		local Entry = Def.upgrade[Index]
		if type(Entry) == "table" then
			for Key, Value in pairs(Entry) do
				Merged[Key] = Value
			end
		end
	end
	return Merged
end

-- summons inherit the summoner's damage scaled by damage_ratio
local function SummonDps(Stats, AttackId)
	local Attack = Attacks[AttackId]
	if type(Attack) ~= "table" or type(Attack.spawn_unit) ~= "table" then
		return 0
	end
	local Damage = tonumber(Stats.damage) or 0
	local Total = 0
	for _, Group in pairs(Attack.spawn_unit) do
		if type(Group) == "table" then
			for _, Field in ipairs({ "units", "units_nonrandom" }) do
				for _, Entry in pairs(type(Group[Field]) == "table" and Group[Field] or {}) do
					if type(Entry) == "table" then
						local Minion = Units[Entry.unit]
						local Cooldown = type(Minion) == "table"
							and (tonumber(Minion.attack_cooldown) or tonumber(Minion.cooldown)) or nil
						if Cooldown and Cooldown > 0 then
							local Amount = tonumber(Entry.amount) or tonumber(Group.amount) or 1
							local Ratio = tonumber(Entry.damage_ratio) or 1
							Total += Amount * Ratio * Damage / Cooldown
						end
					end
				end
			end
		end
	end
	return Total
end

local function EffectiveDps(UnitId, Level)
	local Stats = StatsAt(UnitId, Level)
	if type(Stats) ~= "table" then
		return 0, Config.DefaultRange
	end
	local Total = DpsOf(Stats)
	if Stats.spawn_unit == true or Stats.spawn_script == true then
		local Primary = Stats.primary_attack or Stats.primary_attack_no_upgrades
		if type(Primary) == "string" then
			Total += SummonDps(Stats, Primary)
		end
		if type(Stats.active_attack) == "string" then
			Total += SummonDps(Stats, Stats.active_attack)
		end
	end
	return Total, tonumber(Stats.range) or Config.DefaultRange
end

local function MaxLevel(UnitId)
	local Def = Units[UnitId]
	return type(Def) == "table" and type(Def.upgrade) == "table" and #Def.upgrade or 0
end

function Match.RangeOf(UnitId)
	local Def = Units[UnitId]
	return tonumber(type(Def) == "table" and Def.range) or Config.DefaultRange
end

local function TierOf(UnitId)
	local Def = Units[UnitId]
	local Tier = type(Def) == "table" and RarityTiers[Def.rarity] or nil
	return type(Tier) == "number" and Tier or -1
end

function Match.CanPlaceOn(UnitId, Kind)
	local Def = Units[UnitId]
	if type(Def) ~= "table" then
		return Kind == "ground"
	end
	if Def.hybrid_placement == true then
		return true
	end
	return (Def.hill_unit == true) == (Kind == "hill")
end

function Match.UnitCost(UnitId)
	local Def = Units[UnitId]
	return type(Def) == "table" and tonumber(Def.cost) or nil
end

local function NextUpgradeCost(UnitId, Level)
	local Def = Units[UnitId]
	if type(Def) ~= "table" or type(Def.upgrade) ~= "table" then
		return nil
	end
	local Entry = Def.upgrade[Level + 1]
	return type(Entry) == "table" and tonumber(Entry.cost) or nil
end

-- ============================================================================
-- match: the units we placed
-- ============================================================================
local function StatValue(Model, Name)
	local Stats = Model:FindFirstChild("_stats")
	local Value = Stats and Stats:FindFirstChild(Name)
	return Value and Value:IsA("ValueBase") and Value.Value or nil
end

-- Strict ownership. An explicit owner value must match us; without one, only
-- a UUID present in OUR collection counts. Never plan/upgrade another player's
-- unit or a stray model that merely happens to be tagged "player_units".
local function IsOurs(Model)
	local Stats = Model:FindFirstChild("_stats")
	local Owner = Stats and Stats:FindFirstChild("player")
	if Owner and Owner:IsA("ValueBase") then
		local Value = Owner.Value
		if typeof(Value) == "Instance" then
			return Value == Player
		elseif type(Value) == "number" then
			return Value == Player.UserId
		end
		return tostring(Value) == Player.Name or tostring(Value) == Player.DisplayName
	end
	local Uuid = StatValue(Model, "uuid")
	if Uuid then
		return type((Account.Collection().owned_units or {})[tostring(Uuid)]) == "table"
	end
	return false
end

local function IsSummon(Model)
	local Stats = Model:FindFirstChild("_stats")
	local Parent = Stats and Stats:FindFirstChild("parent_unit")
	return Parent ~= nil and Parent:IsA("ObjectValue") and Parent.Value ~= nil
end

function Match.Models()
	local Out, Seen = {}, {}
	local function Add(Model)
		if Model and Model:IsA("Model") and Model.Parent and not Seen[Model]
			and IsOurs(Model) and not IsSummon(Model) then
			Seen[Model] = true
			Out[#Out + 1] = Model
		end
	end
	for _, Model in ipairs(CollectionService:GetTagged("player_units")) do
		Add(Model)
	end
	local Folder = workspace:FindFirstChild("_UNITS")
	if Folder then
		for _, Model in ipairs(Folder:GetChildren()) do
			Add(Model)
		end
	end
	return Out
end

-- The replicated money stat lags the server. Reserve every spend we fire and
-- subtract it from affordability until the balance actually drops, so two
-- actions in a row can never be sent against the same money.
Match.Pending = {}
Match.LastAction = 0

function Match.CanAct()
	return os.clock() - Match.LastAction >= Config.ActionDelay
end

function Match.Money()
	local Raw = Account.Money()
	if not Raw then
		return nil
	end
	local Now = os.clock()
	local Held = 0
	for Index = #Match.Pending, 1, -1 do
		local Spend = Match.Pending[Index]
		if Now - Spend.At > 2 or Raw < Spend.Before then
			table.remove(Match.Pending, Index)
		else
			Held += Spend.Cost
		end
	end
	return math.max(0, Raw - Held)
end

-- Called immediately before firing a spend: reserves the cost and starts the
-- ActionDelay window for ALL actions (place and upgrade share this throttle).
local function Reserve(Cost)
	Match.Pending[#Match.Pending + 1] = {
		Cost = Cost,
		Before = Account.Money() or 0,
		At = os.clock(),
	}
	Match.LastAction = os.clock()
end

-- ============================================================================
-- match: priority (which unit to place / upgrade first)
-- ============================================================================
local function EquippedSlots()
	local List = {}
	for Slot, Uuid in pairs(Account.Collection().equipped_units or {}) do
		if type(Uuid) == "string" then
			List[#List + 1] = { Uuid = Uuid, Slot = tonumber(Slot) or 99 }
		end
	end
	table.sort(List, function(A, B)
		return A.Slot < B.Slot
	end)
	return List
end

local function UnitIdForUuid(Uuid)
	local Unit = (Account.Collection().owned_units or {})[Uuid]
	return type(Unit) == "table" and Unit.unit_id or nil
end

function Match.BuildPriority()
	local List = {}
	local Owned = Account.Collection().owned_units or {}
	for _, Entry in ipairs(EquippedSlots()) do
		if type(Owned[Entry.Uuid]) ~= "table" then
			continue -- only equipped units we actually own
		end
		local UnitId = UnitIdForUuid(Entry.Uuid)
		if UnitId and Units[UnitId] then
			local Farm = IsFarm(UnitId)
			local Score
			if Farm then
				Score = tonumber((StatsAt(UnitId, MaxLevel(UnitId)) or {}).farm_amount) or 0
			else
				local Dps, Range = EffectiveDps(UnitId, MaxLevel(UnitId))
				Score = Dps * Range
			end
			List[#List + 1] = {
				Uuid = Entry.Uuid,
				UnitId = UnitId,
				Farm = Farm,
				Tier = TierOf(UnitId),
				Score = Score,
			}
		end
	end
	table.sort(List, function(A, B)
		if A.Farm ~= B.Farm then
			return not A.Farm -- combat first, farms last
		end
		if A.Tier ~= B.Tier then
			return A.Tier > B.Tier
		end
		return A.Score > B.Score
	end)
	Match.Priority = List
	Match.Rank = {}
	for Index, Entry in ipairs(List) do
		if not Match.Rank[Entry.UnitId] then
			Match.Rank[Entry.UnitId] = Index
		end
	end
end

-- equipped UUID -> spawn_units GUI slot (needs the unique trait check)
function Match.RefreshSlots()
	local Slots = {}
	local Gui = PlayerGui:FindFirstChild("spawn_units")
	local Lives = Gui and Gui:FindFirstChild("Lives")
	local Frame = Lives and Lives:FindFirstChild("Frame")
	local List = Frame and Frame:FindFirstChild("Units")
	if List then
		for _, Slot in ipairs(List:GetChildren()) do
			if Slot:IsA("GuiObject") then
				local Uuid = Slot:GetAttribute("_equipped_frame_unit_uuid")
				if type(Uuid) == "string" then
					Slots[Uuid] = Slot
				end
			end
		end
	end
	Match.Slots = Slots
end

-- The spawn GUI only shows the true cap while that slot is selected (the
-- unselected placeholder is meaningless). Select each slot briefly, confirm
-- the game's selected unit_id matches, cache the "current/max" cap, then
-- deselect with Q so no unit stays selected after the scan.
function Match.DiscoverCaps()
	local GuiService = game:GetService("GuiService")
	local VIM = game:GetService("VirtualInputManager")
	local function IsSelected(UnitId)
		local Now = Match.Grid and Match.Grid.unit_id or nil
		if not Now then
			return false
		end
		if tostring(Now):lower() == tostring(UnitId):lower() then
			return true
		end
		local Def = Units[UnitId]
		local Name = type(Def) == "table" and Def.name or nil
		return type(Name) == "string" and tostring(Name):lower() == tostring(Now):lower()
	end

	-- Q is the game's "deselect unit" key. Clearing GuiService.SelectedObject
	-- only drops UI focus; it leaves the unit selected in-game.
	local function Deselect()
		pcall(function()
			VIM:SendKeyEvent(true, Enum.KeyCode.Q, false, game)
			task.wait(0.02)
			VIM:SendKeyEvent(false, Enum.KeyCode.Q, false, game)
		end)
	end

	local Resolved, Failed = 0, {}
	for Uuid, Slot in pairs(Match.Slots) do
		if Match.Caps[Uuid] == nil then
			local UnitId = UnitIdForUuid(Uuid)
			local Selected = false
			-- same select-and-press technique the group joiner uses
			pcall(function()
				Slot.Selectable = true
				GuiService.SelectedObject = Slot
				task.wait(0.08)
				VIM:SendKeyEvent(true, Enum.KeyCode.Return, false, game)
				task.wait(0.02)
				VIM:SendKeyEvent(false, Enum.KeyCode.Return, false, game)
				task.wait(0.15)
				Selected = IsSelected(UnitId)
			end)
			if Selected then
				local Max
				pcall(function()
					for _, Child in ipairs(Slot:GetDescendants()) do
						if Child:IsA("TextLabel") then
							local Value = tonumber(tostring(Child.Text):match("%d+%s*/%s*(%d+)"))
							if Value then
								Max = Value
								break
							end
						end
					end
				end)
				if Max then
					Match.Caps[Uuid] = Max
					Resolved += 1
					LogT("Caps", "%s [%s] = %d", tostring(UnitId), tostring(Uuid):sub(1, 8), Max)
				else
					Failed[#Failed + 1] = tostring(UnitId) .. " [" .. tostring(Uuid):sub(1, 8) .. "] no text"
				end
			else
				Failed[#Failed + 1] = tostring(UnitId) .. " [" .. tostring(Uuid):sub(1, 8)
					.. "] unit_id=" .. tostring(Match.Grid and Match.Grid.unit_id)
			end
			Deselect() -- unselect this unit before moving on to the next slot
		end
	end
	-- leave nothing selected once cap reading is finished
	pcall(function()
		GuiService.SelectedObject = nil
	end)
	Deselect()
	LogT("Caps", "selection cleared")
	LogT("Caps", "resolved %d/%d%s", Resolved, Util.Count(Match.Slots),
		#Failed > 0 and (" | failed: " .. table.concat(Failed, ", ")) or "")
end

-- spawn_cap, except the `unique` trait icon forces exactly one copy
function Match.SpawnCap(UnitId, Uuid)
	local Slot = Uuid and Match.Slots[Uuid] or nil
	if Slot then
		-- the unique-trait icon forces exactly one copy
		local Main = Slot:FindFirstChild("Main")
		local Icons = Main and Main:FindFirstChild("TraitIcons")
		local Unique = Icons and Icons:FindFirstChild("unique")
		if Unique and Unique:IsA("GuiObject") and Unique.Visible then
			return 1
		end
	end
	-- the UI only shows the real cap while the slot is selected, so use the
	-- value resolved by Match.DiscoverCaps() (verified against unit_id)
	if Uuid and Match.Caps[Uuid] then
		return Match.Caps[Uuid]
	end
	local Def = Units[UnitId]
	if type(Def) == "table" and type(Def.spawn_cap) == "number" then
		return Def.spawn_cap
	end
	return nil
end

function Match.Counts()
	local Counts, Combat, Farms = {}, 0, 0
	for _, Model in ipairs(Match.Models()) do
		local UnitId = Match.UnitIdOf(Model)
		if UnitId then
			Counts[UnitId] = (Counts[UnitId] or 0) + 1
			if IsFarm(UnitId) then
				Farms += 1
			else
				Combat += 1
			end
		end
	end
	return Counts, Combat, Farms
end

Match.Cache = setmetatable({}, { __mode = "k" })
function Match.UnitIdOf(Model)
	local Cached = Match.Cache[Model]
	if Cached then
		return Cached
	end
	local Id
	local Uuid = StatValue(Model, "uuid")
	if Uuid then
		Id = UnitIdForUuid(tostring(Uuid))
	end
	if not Id then
		local Raw = StatValue(Model, "id")
		if type(Raw) == "string" and Units[Raw] then
			Id = Raw
		end
	end
	if not Id and Units[Model.Name] then
		Id = Model.Name
	end
	if Id then
		Match.Cache[Model] = Id
	end
	return Id
end


-- ============================================================================
-- match: lane geometry
-- ============================================================================
function Match.GetPaths()
	local Out = {}
	local Cache = Match.Paths and Match.Paths.PATH_CACHE
	if type(Cache) ~= "table" then
		return Out
	end
	local function Collect(OnlyPve)
		for Base, Lanes in pairs(Cache) do
			if type(Lanes) == "table" and (not OnlyPve or tostring(Base) == "pve") then
				for _, Path in pairs(Lanes) do
					if type(Path) == "table" and type(Path.points) == "table" and Path.total_distance then
						Out[#Out + 1] = { Points = Path.points, Total = Path.total_distance }
					end
				end
			end
		end
	end
	Collect(true)
	if #Out == 0 then
		Collect(false)
	end
	return Out
end

local function PointAtDistance(Points, Distance)
	local Previous = Points[1]
	for Index = 2, #Points do
		local Point = Points[Index]
		if (Point.distance_from_spawn or 0) >= Distance then
			local Span = (Point.distance_from_spawn or 0) - (Previous.distance_from_spawn or 0)
			local T = Span > 0 and math.clamp((Distance - (Previous.distance_from_spawn or 0)) / Span, 0, 1) or 0
			return Previous.position:Lerp(Point.position, T)
		end
		Previous = Point
	end
	return Points[#Points].position
end

function Match.PathDistanceXZ(Position)
	local Best = math.huge
	for _, Line in ipairs(Match.Lines) do
		for Index = 1, #Line - 1 do
			local A, B = Line[Index], Line[Index + 1]
			local Abx, Abz = B.X - A.X, B.Z - A.Z
			local Apx, Apz = Position.X - A.X, Position.Z - A.Z
			local Length2 = Abx * Abx + Abz * Abz
			local T = Length2 > 0 and math.clamp((Apx * Abx + Apz * Abz) / Length2, 0, 1) or 0
			local Dx, Dz = Apx - Abx * T, Apz - Abz * T
			local D2 = Dx * Dx + Dz * Dz
			if D2 < Best then
				Best = D2
			end
		end
	end
	return math.sqrt(Best)
end

local function TerrainKind(Hit)
	local Core = Match.Core
	if not Hit or Hit.Name == "_donotplace" then
		return nil
	end
	if Core.HillRaycastParts and Hit:IsDescendantOf(Core.HillRaycastParts) then
		return "hill"
	end
	if Core.GroundRaycastParts and Hit:IsDescendantOf(Core.GroundRaycastParts) then
		return "ground"
	end
	return nil
end

local function DistToPartXZ(Position, Part)
	local Local = Part.CFrame:PointToObjectSpace(Position)
	local Half = Part.Size / 2
	local Closest = Part.CFrame:PointToWorldSpace(Vector3.new(
		math.clamp(Local.X, -Half.X, Half.X),
		math.clamp(Local.Y, -Half.Y, Half.Y),
		math.clamp(Local.Z, -Half.Z, Half.Z)
	))
	local Dx, Dz = Closest.X - Position.X, Closest.Z - Position.Z
	return math.sqrt(Dx * Dx + Dz * Dz)
end

local function NearRoad(Position, RoadParts)
	for _, Part in ipairs(RoadParts) do
		if DistToPartXZ(Position, Part) <= 0.01 then
			return true
		end
	end
	return false
end

-- `_bounds` lives in ReplicatedStorage; GetPartsInPart cannot see it there, so
-- it is moved under workspace for the probe and put back afterwards
local ProbeSize = Vector3.new(0.05, 2.7, 0.05)
local function BlockProbe(Positions)
	local Bounds = ReplicatedStorage:FindFirstChild("_bounds")
	local Road = workspace:FindFirstChild("_road")
	local OriginalParent = Bounds and Bounds.Parent or nil
	local Moved = false
	if Bounds and Bounds.Parent ~= workspace then
		Bounds.Parent = workspace
		Moved = true
	end
	local Restored = {}
	if Bounds then
		for _, Part in ipairs(Bounds:GetDescendants()) do
			if Part:IsA("BasePart") and not Part.CanQuery then
				Part.CanQuery = true
				Restored[#Restored + 1] = Part
			end
		end
	end

	local Probe = Instance.new("Part")
	Probe.Name = "AA_KaitunProbe"
	Probe.Anchored = true
	Probe.CanCollide = false
	Probe.CanQuery = true
	Probe.CanTouch = false
	Probe.Transparency = 1
	Probe.Size = ProbeSize
	Probe.CFrame = CFrame.new(0, -1000, 0)
	Probe.Parent = workspace

	local Params = OverlapParams.new()
	Params.FilterType = Enum.RaycastFilterType.Include
	local Filter = {}
	for _, Item in ipairs({ Bounds, Road }) do
		if Item then
			Filter[#Filter + 1] = Item
		end
	end
	Params.FilterDescendantsInstances = Filter

	local Offset = Vector3.new(0, ProbeSize.Y / 2 + 0.1, 0)
	local Results = {}
	for Index, Position in ipairs(Positions) do
		Probe.CFrame = CFrame.new(Position + Offset)
		local Blocked = false
		for _, Touched in ipairs(workspace:GetPartsInPart(Probe, Params)) do
			if (Road and Touched:IsDescendantOf(Road)) or (Bounds and Touched:IsDescendantOf(Bounds)) then
				Blocked = true
				break
			end
		end
		Results[Index] = Blocked
	end

	Probe:Destroy()
	for _, Part in ipairs(Restored) do
		Part.CanQuery = false
	end
	if Moved and Bounds and OriginalParent then
		Bounds.Parent = OriginalParent
	end
	return Results
end

function Match.Blocked(Position)
	return BlockProbe({ Position })[1] == true
end

local RayHeight = 80
local HybridDef = { hybrid_placement = true }

local function ScanCircle(Center, Face, RoadParts)
	local Nodes = {}
	local FarmOuter = Config.RadiusGround + Config.RadiusFarm
	local MaxRadius = math.max(Config.RadiusGround, Config.RadiusHill, FarmOuter)
	for Gx = -MaxRadius, MaxRadius, Config.NodeSpacing do
		for Gz = -MaxRadius, MaxRadius, Config.NodeSpacing do
			local D2 = Gx * Gx + Gz * Gz
			if D2 <= MaxRadius * MaxRadius then
				local Hit = Match.Core.raycast(Center + Vector3.new(Gx, RayHeight, Gz), Vector3.new(0, -RayHeight * 2, 0))
				local Kind = Hit and TerrainKind(Hit.Instance)
				local NodeRadius = Kind == "hill" and Config.RadiusHill or Config.RadiusGround
				local KindOk = D2 <= NodeRadius * NodeRadius
				local FarmZone = Kind == "ground"
					and D2 > Config.RadiusGround * Config.RadiusGround
					and D2 <= FarmOuter * FarmOuter
				if Kind and (KindOk or FarmZone)
					and Match.Core.is_valid_raycast_hit(Hit.Instance, HybridDef)
					and not NearRoad(Hit.Position, RoadParts) then
					Nodes[#Nodes + 1] = {
						Kind = Kind,
						Valid = true,
						KindOk = KindOk,
						FarmZone = FarmZone,
						Gx = Gx,
						Gz = Gz,
						Dist = math.sqrt(D2),
						Position = Hit.Position,
						Face = Face,
					}
				end
			end
		end
	end
	return Nodes
end

function Match.Rescan()
	local RoadParts = {}
	local Road = workspace:FindFirstChild("_road")
	if Road then
		for _, Part in ipairs(Road:GetDescendants()) do
			if Part:IsA("BasePart") then
				RoadParts[#RoadParts + 1] = Part
			end
		end
	end

	local Paths = Match.GetPaths()
	local Lines = {}
	for _, Path in ipairs(Paths) do
		local Line = {}
		for _, Point in ipairs(Path.Points) do
			Line[#Line + 1] = Point.position
		end
		if #Line > 1 then
			Lines[#Lines + 1] = Line
		end
	end
	if #Lines == 0 then
		return 0
	end
	Match.Lines = Lines

	local Nodes = {}
	for _, Path in ipairs(Paths) do
		if #Path.Points > 1 then
			local Distance = Path.Total * math.clamp(Config.Percent, 0, 100) / 100
			local Center = PointAtDistance(Path.Points, Distance)
			local Face = PointAtDistance(Path.Points, math.max(0, Distance - 15))
			local Lane = ScanCircle(Center, Face, RoadParts)

			local Positions = {}
			for Index, Node in ipairs(Lane) do
				Positions[Index] = Node.Position
			end
			if #Positions > 0 then
				local Results = BlockProbe(Positions)
				for Index, Node in ipairs(Lane) do
					Node.Valid = not Results[Index]
					Node.PathDist = Match.PathDistanceXZ(Node.Position)
					Nodes[#Nodes + 1] = Node
				end
			end
		end
	end

	Match.Nodes = Nodes
	Match.Claims = {}
	Match.Need = #Nodes == 0
	LogT("Scan", "%d nodes", #Nodes)
	return #Nodes
end

function Match.Scan()
	local Missing = Match.Need or #Match.Nodes == 0
	local TooMany = Match.Fails >= Config.RescanAfterFails
	if not Missing and not TooMany then
		return
	end
	local Wait = Missing and (Match.Tries < 15 and 2 or 10) or 15
	if os.clock() - Match.LastScan < Wait then
		return
	end
	Match.LastScan = os.clock()
	Match.Tries += 1
	Match.Fails = 0
	local Ok, Count = pcall(Match.Rescan)
	if not Ok then
		warn("[AA Kaitun] scan error: " .. tostring(Count))
		return
	end
	if Count > 0 then
		Match.Tries = 0
	end
end

-- ============================================================================
-- match: occupancy
-- ============================================================================
-- A placed unit blocks the nodes under its _hitbox. The hitbox is a cylinder
-- whose Y/Z sizes are the diameters, so a simple XZ radius is accurate enough
-- at this node spacing and much cheaper than oriented-box maths.
function Match.CirclesNow()
	local Out = {}
	local function Add(Model)
		local Hitbox = Model:FindFirstChild("_hitbox", true)
		if Hitbox and Hitbox:IsA("BasePart") then
			Out[#Out + 1] = {
				X = Hitbox.Position.X,
				Z = Hitbox.Position.Z,
				R = math.max(Hitbox.Size.Y, Hitbox.Size.Z) / 2 + 0.35,
			}
		end
	end
	for _, Model in ipairs(Match.Models()) do
		Add(Model)
	end
	return Out
end

function Match.PointOccupied(Position)
	for _, Circle in ipairs(Match.Circles) do
		local Dx, Dz = Position.X - Circle.X, Position.Z - Circle.Z
		if Dx * Dx + Dz * Dz <= Circle.R * Circle.R then
			return true
		end
	end
	return false
end

function Match.Claim(Node, Seconds)
	Match.Claims[Node] = os.clock() + (Seconds or Config.ClaimSeconds)
end

function Match.Busy(Node)
	local Expiry = Match.Claims[Node]
	if Expiry then
		if Expiry > os.clock() then
			return true
		end
		Match.Claims[Node] = nil
	end
	return Match.Occupied[Node] == true
end

function Match.RefreshOccupied()
	local Circles = Match.CirclesNow()
	Match.Circles = Circles
	local Occupied = {}
	for _, Node in ipairs(Match.Nodes) do
		for _, Circle in ipairs(Circles) do
			local Dx, Dz = Node.Position.X - Circle.X, Node.Position.Z - Circle.Z
			if Dx * Dx + Dz * Dz <= Circle.R * Circle.R then
				Occupied[Node] = true
				break
			end
		end
	end
	for Node in pairs(Occupied) do
		Match.Claims[Node] = nil -- the unit owns the spot now
	end
	Match.Occupied = Occupied
end

function Match.NearestNode(Position)
	local Best, BestD
	for _, Node in ipairs(Match.Nodes) do
		local Dx, Dz = Node.Position.X - Position.X, Node.Position.Z - Position.Z
		local D = Dx * Dx + Dz * Dz
		if (not BestD or D < BestD) and D <= Config.NodeSpacing * Config.NodeSpacing then
			Best, BestD = Node, D
		end
	end
	return Best
end


-- ============================================================================
-- match: placing / upgrading
-- ============================================================================
-- Throttled "why" logging: explains skips once every 5s per reason instead of
-- flooding the console every tick.
local LastWhy = {}
local function Why(Key, Format, ...)
	local Now = os.clock()
	if Now - (LastWhy[Key] or 0) >= 5 then
		LastWhy[Key] = Now
		LogT("Note", Format, ...)
	end
end

-- Copies of the same equipped unit SHARE a uuid, but the game's
-- upgrade_unit_ingame remote takes the exact MODEL instance. The fixed _hitbox
-- position is unique per placed copy, so it is the reliable copy identity.
local function ShortId(Uuid)
	return tostring(Uuid or "?"):sub(1, 8)
end

local function CopyPos(Model)
	local Hitbox = Model:FindFirstChild("_hitbox", true)
	if Hitbox and Hitbox:IsA("BasePart") then
		return Hitbox.Position
	end
	local Ok, Cf = pcall(function()
		return Model:GetPivot()
	end)
	return Ok and Cf and Cf.Position or nil
end

local function CopyKey(Model)
	local Position = CopyPos(Model)
	if Position then
		return string.format("%.1f,%.1f", Position.X, Position.Z)
	end
	return tostring(Model):sub(-8)
end

function Match.PickNode(UnitId, Farm)
	local Range = Match.RangeOf(UnitId)
	local Best, BestScore
	for _, Node in ipairs(Match.Nodes) do
		if Node.Valid and not Match.Busy(Node) then
			local TerrainOk = Farm and Node.Kind == Config.FarmTerrain
				or (not Farm and Match.CanPlaceOn(UnitId, Node.Kind))
			local ZoneOk = Farm and (Node.FarmZone and Node.Dist <= Config.MaxFarmPlaceRadius)
				or (not Farm and Node.KindOk)
			if TerrainOk and ZoneOk then
				local Score
				if Farm then
					Score = -Node.Dist + (Node.FarmZone and 25 or 0)
				elseif Node.PathDist > Range then
					-- cannot reach the lane from here: only worth it if nothing else
					Score = -1000 - (Node.PathDist - Range) * 10 - Node.Dist * 0.1
				else
					Score = -Node.Dist - Node.PathDist * 0.25
					if Node.PathDist > Range * Config.RangeSafety then
						Score -= 40
					end
					if Node.Dist > Config.MaxPlaceRadius then
						Score -= 300 + (Node.Dist - Config.MaxPlaceRadius)
					end
				end
				if not BestScore or Score > BestScore then
					Best, BestScore = Node, Score
				end
			end
		end
	end
	return Best
end

function Match.TryPlace(Entry)
	local Tag = Entry.UnitId .. " [" .. ShortId(Entry.Uuid) .. "]"
	if not Match.CanAct() then
		Why("delay", "place %s: waiting %.1fs action delay", Tag,
			Config.ActionDelay - (os.clock() - Match.LastAction))
		return false
	end
	local Node = Match.PickNode(Entry.UnitId, Entry.Farm)
	if not Node then
		Why("node:" .. Entry.UnitId, "place %s: no valid free node (range %s, farm %s)",
			Tag, tostring(Match.RangeOf(Entry.UnitId)), tostring(Entry.Farm))
		return false
	end
	local Cf = Util.LookAt(Node.Position, Node.Face)
	if Match.Grid and Match.Grid.get_closest_grid_point then
		local Ok, Snapped = pcall(Match.Grid.get_closest_grid_point, Cf)
		if Ok and typeof(Snapped) == "CFrame" then
			Cf = Snapped
		end
	end
	local Landing = Match.NearestNode(Cf.Position)
	if Landing and Match.Busy(Landing) then
		Why("busy:" .. Entry.UnitId, "place %s: landing node busy", Tag)
		return false
	end
	if Match.PointOccupied(Cf.Position) then
		Why("occupied:" .. Entry.UnitId, "place %s: another unit hitbox covers the spot", Tag)
		return false
	end

	local Cost = Match.UnitCost(Entry.UnitId)
	if not Cost then
		Why("nocost:" .. Entry.UnitId, "place %s: no cost in unit data - skipped", Tag)
		return false
	end
	local MoneyBefore = Match.Money()
	if MoneyBefore < Cost then
		Why("money:place:" .. Entry.UnitId, "place %s: need %d, have %d - skipped", Tag, Cost, MoneyBefore)
		return false
	end
	if Match.Blocked(Cf.Position) then
		Why("blocked", "place %s: bounds/road blocks the node - %ds cooldown", Tag, Config.BlockedCooldown)
		Match.Claim(Node, Config.BlockedCooldown)
		return false
	end

	Reserve(Cost)
	local Before = #Match.Models()
	local Ok, Result = Util.Call(10, InvokeServer, "spawn_unit", Entry.Uuid, Cf)
	-- spawn_unit answers nil on SUCCESS (the model appearing is the proof).
	-- Only an explicit false or a call failure is a real rejection.
	if not Ok or Result == false then
		Why("reject:place:" .. Entry.UnitId, "place %s: server rejected (ok=%s, result=%s) - %ds cooldown",
			Tag, tostring(Ok), tostring(Result), Config.RejectCooldown)
		Match.Claim(Node, Config.RejectCooldown)
		return false
	end

	local Deadline = os.clock() + 1
	repeat
		task.wait(0.1)
	until #Match.Models() > Before or os.clock() >= Deadline
	Match.Claim(Node, Config.ClaimSeconds)
	if Landing then
		Match.Claim(Landing, Config.ClaimSeconds)
	end
	LogT("Place", "%s @%.1f,%.1f | node %.1f,%.1f | path %.1f | cost %d | money %d -> %d | cap %s | models %d -> %d",
		Tag, Cf.Position.X, Cf.Position.Z, Node.Position.X, Node.Position.Z,
		Match.PathDistanceXZ(Cf.Position), Cost, MoneyBefore, Match.Money(),
		tostring(Match.SpawnCap(Entry.UnitId, Entry.Uuid)), Before, #Match.Models())
	return true
end

-- No queue of skipped candidates: pick the FIRST affordable entry from the
-- already-prioritised list, attempt it once, and let the next tick re-plan.
function Match.PlaceTick()
	local Counts, Combat, Farms = Match.Counts()
	local FarmsAllowed = Combat >= Config.MinCombatFirst and Farms < Config.FarmQuota
	local Money = Match.Money() or 0
	for _, Entry in ipairs(Match.Priority) do
		local Cap = Match.SpawnCap(Entry.UnitId, Entry.Uuid)
		if Cap and (Counts[Entry.UnitId] or 0) < Cap and (not Entry.Farm or FarmsAllowed) then
			local Cost = Match.UnitCost(Entry.UnitId)
			if Cost and Money >= Cost then
				return Match.TryPlace(Entry)
			end
		end
	end
	return false
end

-- Order so the LOWEST level copy goes first, but interleave unit ids: three
-- copies of luffy must not be upgraded back-to-back before naruto gets a turn.
local function OrderUpgradeCandidates(Candidates)
	local Pending = {}
	for Index, Candidate in ipairs(Candidates) do
		Pending[Index] = Candidate
	end
	local Picks = {}
	local Ordered = {}
	while #Pending > 0 do
		local BestIndex
		for Index, Candidate in ipairs(Pending) do
			local Best = BestIndex and Pending[BestIndex]
			local Picked = Picks[Candidate.UnitId] or 0
			local BestPicked = Best and (Picks[Best.UnitId] or 0) or 0
			if not Best
				or Candidate.Level < Best.Level
				or (Candidate.Level == Best.Level and Picked < BestPicked)
				or (Candidate.Level == Best.Level and Picked == BestPicked and Candidate.Rank < Best.Rank)
				or (Candidate.Level == Best.Level and Picked == BestPicked
					and Candidate.Rank == Best.Rank and Candidate.Key < Best.Key) then
				BestIndex = Index
			end
		end
		local Chosen = table.remove(Pending, BestIndex)
		Picks[Chosen.UnitId] = (Picks[Chosen.UnitId] or 0) + 1
		Ordered[#Ordered + 1] = Chosen
	end
	return Ordered
end

-- Pick ONE affordable copy per tick, no queue of skipped units. The position
-- key keeps each copy unique even when copies share the same uuid.
function Match.UpgradeTick()
	if not Match.CanAct() then
		return 0
	end
	local Candidates = {}
	local Owned = Account.Collection().owned_units or {}
	for _, Model in ipairs(Match.Models()) do
		local Uuid = StatValue(Model, "uuid")
		if Uuid and type(Owned[tostring(Uuid)]) ~= "table" then
			continue -- never spend on a model we do not own
		end
		local UnitId = Match.UnitIdOf(Model)
		local Level = tonumber(StatValue(Model, "upgrade"))
		local Max = tonumber(StatValue(Model, "max_upgrade"))
		if UnitId and Level and (not Max or Level < Max) and NextUpgradeCost(UnitId, Level) then
			Candidates[#Candidates + 1] = {
				Model = Model,
				Uuid = tostring(Uuid or "?"),
				UnitId = UnitId,
				Key = CopyKey(Model),
				Pos = CopyPos(Model),
				Level = Level,
				Rank = Match.Rank[UnitId] or 99,
			}
		end
	end

	local Money = Match.Money() or 0
	local Chosen, ChosenCost, ChosenLevel
	for _, Entry in ipairs(OrderUpgradeCandidates(Candidates)) do
		local LiveLevel = tonumber(StatValue(Entry.Model, "upgrade"))
		if LiveLevel and Entry.Model.Parent then
			local LiveMax = tonumber(StatValue(Entry.Model, "max_upgrade"))
			local Cost = (not LiveMax or LiveLevel < LiveMax)
				and NextUpgradeCost(Entry.UnitId, LiveLevel) or nil
			if Cost and Money >= Cost then
				Chosen, ChosenCost, ChosenLevel = Entry, Cost, LiveLevel
				break
			end
		end
	end
	if not Chosen then
		return 0
	end

	local Tag = Chosen.UnitId .. "@" .. Chosen.Key
	Why("upchoose", "upgrade target %s | lvl %d -> %d | cost %d | money %d | pos @%s",
		Tag, ChosenLevel, ChosenLevel + 1, ChosenCost, Money,
		Chosen.Pos and string.format("%.1f,%.1f", Chosen.Pos.X, Chosen.Pos.Z) or "?")
	Reserve(ChosenCost)
	local Ok, Result = pcall(function()
		return InvokeServer("upgrade_unit_ingame", Chosen.Model)
	end)
	if Ok and Result ~= false then
		LogT("Upgrade", "%s %d -> %d | cost %d | money %d -> %d | model %s",
			Tag, ChosenLevel, ChosenLevel + 1, ChosenCost, Money, Match.Money(), Chosen.Model.Name)
		return 1
	end
	Why("reject:up", "upgrade %s: server rejected (ok=%s, result=%s)",
		Tag, tostring(Ok), tostring(Result))
	return 0
end

function Match.Reset(Reason)
	Match.Nodes = {}
	Match.Lines = {}
	Match.Claims = {}
	Match.Occupied = {}
	Match.Circles = {}
	Match.Priority = {}
	Match.Rank = {}
	Match.Cache = setmetatable({}, { __mode = "k" })
	Match.Need = true
	Match.Tries = 0
	Match.LastScan = -100
	Match.Fails = 0
	Match.Pending = {}
	Match.LastAction = 0
	LastWhy = {}
	LogT("Scan", "new map (%s) - state reset", tostring(Reason))
end

function Match.Tick()
	if not Match.Core then
		return
	end
	local MapId = tostring((Loader.LevelData and Loader.LevelData.id) or "")
	if MapId ~= "" and Match.LastMapId and MapId ~= Match.LastMapId then
		Match.Reset("map changed")
	end
	Match.LastMapId = MapId

	Match.Scan()
	if #Match.Nodes == 0 then
		Why("scan", "tick: no placement nodes yet (scan tries %d) - waiting", Match.Tries)
		return
	end
	Match.RefreshOccupied()
	Match.BuildPriority()
	Match.RefreshSlots()
	local Counts, Combat, Farms = Match.Counts()
	Why("tick", "tick: map %s | nodes %d | placed %d (%d combat / %d farm) | priority %d | money %d | caps %d",
		MapId, #Match.Nodes, #Match.Models(), Combat, Farms, #Match.Priority,
		Match.Money() or 0, Util.Count(Match.Caps))

	if Match.PlaceTick() then
		return
	end
	Match.UpgradeTick()
end

-- ============================================================================
-- match: flags, votes, end of match
-- ============================================================================
local function DataFlag(Name)
	local Data = workspace:FindFirstChild("_DATA")
	local Flag = Data and Data:FindFirstChild(Name)
	return Flag ~= nil and Flag:IsA("ValueBase") and Flag.Value == true
end

function Match.Active()
	return DataFlag("GameStarted") and not DataFlag("GameFinished")
end

function Match.Finished()
	return DataFlag("GameFinished")
end

function Match.Wave()
	local Value = workspace:FindFirstChild("_wave_num")
	return Value and Value:IsA("ValueBase") and tonumber(Value.Value) or nil
end

function Match.Settings()
	local Settings = Player:FindFirstChild("_settings")
	local Value = Settings and Settings:FindFirstChild("autoskip_waves")
	if Value and Value:IsA("BoolValue") and not Value.Value then
		Value.Value = true
	end
end

Match.VoteStartFired = false
Match.VoteSkipFired = false
function Match.Votes()
	if Config.VoteStart then
		local Gui = PlayerGui:FindFirstChild("VoteStart")
		local Data = workspace:FindFirstChild("_DATA")
		local Vote = Data and Data:FindFirstChild("VoteStart")
		local Flag = Vote and Vote:FindFirstChild("VotingFinished")
		local Voting = Flag ~= nil and Flag:IsA("ValueBase") and Flag.Value == false
		-- only vote while the real vote popup is open - firing earlier makes
		-- DifficultyServiceServer throw on a nil Instance
		if Gui and Gui:IsA("ScreenGui") and Gui.Enabled and Voting then
			if not Match.VoteStartFired then
				Match.VoteStartFired = true
				LogT("Vote", "start")
				Util.Invoke("vote_start")
			end
		else
			Match.VoteStartFired = false
		end
	end

	if Config.VoteSkip then
		local Gui = PlayerGui:FindFirstChild("VoteSkip")
		if Gui and Gui:IsA("ScreenGui") and Gui.Enabled then
			if not Match.VoteSkipFired then
				Match.VoteSkipFired = true
				Util.Invoke("vote_wave_skip")
			end
		else
			Match.VoteSkipFired = false
		end
	end
end

function Match.Decide()
	local Current = State.Current or { Kind = "story" }
	local Gamemode = Loader.LevelData and Loader.LevelData._gamemode
	if Current.Kind == "challenge" or Gamemode == "challenge" then
		LogT("End", "challenge finished -> leave")
		return "leave"
	end
	if Current.Kind == "act6" then
		LogT("End", "act 6 cleared -> leave")
		return "leave"
	end
	-- hunt window reached during the match (or still due now): leave to hunt
	if Match.HuntSeen or Lobby.NeedHunt() then
		LogT("End", "hunt window reached -> leave to lobby")
		return "leave"
	end
	if Lobby.NeedTraitRoll() then
		LogT("End", "trait reroll pending -> leave")
		return "leave"
	end
	if Current.Kind == "story" and Account.Level() >= Config.TargetLevel then
		LogT("End", "target level reached -> leave")
		return "leave"
	end
	-- reset minute hit during this match, or the 30-min slot changed while
	-- playing: leave at the end instead of replaying so the lobby can queue
	-- the new challenges.
	if ChallengesEnabled() and Account.Level() >= Config.NormalChallengeLevel
		and (Match.ResetSeen or ResetMinuteOk() or Lobby.Slot() > (Match.StartSlot or 0)) then
		LogT("End", "challenge reset reached during match -> leave to queue")
		return "leave"
	end
	Why("decide:replay", "match kind %s: nothing due - replaying loop", tostring(Current.Kind))
	return "replay"
end

function Match.Finish()
	-- the game's get_*_challenge response has no dependable cleared flag, so
	-- record the uuid here (same ledger the old one-click script used) to stop
	-- re-queuing the same daily/normal challenge on later lobby visits
	local Current = State.Current
	if Current and Current.Kind == "challenge" and Current.Mode and Current.Uuid then
		State.Clear[Current.Mode] = Current.Uuid
		SaveState()
		Log("challenge %s (%s) marked done", Current.Mode, tostring(Current.Uuid))
	end
	task.wait(2)
	local Decision = Match.Decide()
	LogT("End", "decision=%s", Decision)
	if Decision == "replay" then
		Util.Fire("set_game_finished_vote", "replay")
	else
		Util.Fire("teleport_back_to_lobby")
	end
	local Deadline = os.clock() + 15
	while os.clock() < Deadline do
		if Match.Active() or not Match.Finished() then
			return
		end
		task.wait(0.5)
	end
	Log("still on the end screen - forcing the lobby")
	Util.Fire("teleport_back_to_lobby")
end

function Match.Run()
	LogT("Match", "entered match mode")
	if Config.FpsBoost then
		Fps.Apply() -- optimizer runs in matches only, never in the lobby
	end
	Match.Init()
	Match.Settings()
	GameSettings.Ensure("Match")
	local LastSettings = os.clock()
	-- the spawn GUI is built asynchronously: wait for the slots before trying
	-- to read caps, and retry until they resolve (or the match is well underway)
	task.spawn(function()
		for Attempt = 1, 12 do
			Match.RefreshSlots()
			if Util.Count(Match.Slots) > 0 then
				Match.DiscoverCaps()
				if Util.Count(Match.Caps) == Util.Count(Match.Slots) then
					break
				end
			end
			task.wait(2)
		end
	end)
	if Config.StatsOverlay then
		UI.Overlay()
	end
	UI.Set("Match - starting")

	-- the lobby stores the run kind here before teleporting; it can be nil on a
	-- manual join, so always fall back to an empty table
	local Current = State.Current or {}
	local Handled = false
	local LoseVoted = false
	local LastUi = 0
	local WasActive = false
	-- remember if a reset/hunt window was hit DURING this match, so Decide can
	-- leave at the end even if the minute has already passed by then
	Match.ResetSeen = false
	Match.HuntSeen = false
	Match.StartSlot = Lobby.Slot()

	while true do
		if os.clock() - LastSettings >= 15 then
			LastSettings = os.clock()
			GameSettings.Ensure("Match")
		end
		if Env.AAKaitunStop then
			Log("stop flag set - exiting")
			return
		end
		-- votes must be watched during the pre-game screen too, otherwise the
		-- game sits there for 30 seconds waiting for the start vote
		pcall(Match.Votes)

		if Match.Active() then
			if not WasActive then
				WasActive = true
				Handled = false
				LoseVoted = false
				Match.Reset("new match")
				Match.ResetSeen = false
				Match.HuntSeen = false
				Match.StartSlot = Lobby.Slot()
			end
			-- flag reset/hunt windows reached while this match is running;
			-- Decide will leave instead of replaying once the game finishes
			if ResetMinuteOk() then
				Match.ResetSeen = true
			end
			if Lobby.NeedHunt() then
				Match.HuntSeen = true
			end
			-- act 6 is a full clear and challenges must be completed: never
			-- vote lose there. Check the game's own gamemode too, so a stale
			-- or missing saved run kind can't make us lose a challenge.
			local Gamemode = Loader.LevelData and Loader.LevelData._gamemode
			local IsChallenge = Current.Kind == "challenge" or Gamemode == "challenge"
			if not LoseVoted and Config.LoseWave > 0 and Current.Kind ~= "act6"
				and not IsChallenge then
				local Wave = Match.Wave()
				if Wave and Wave >= Config.LoseWave then
					LoseVoted = true
					Util.Fire("vote_lose_game", true)
					LogT("Vote", "lose at wave %d", Wave)
				end
			end
			local Ok, Err = pcall(Match.Tick)
			if not Ok and os.clock() - LastUi > 10 then
				LastUi = os.clock()
				warn("[AA Kaitun] match tick: " .. tostring(Err))
			end
			if os.clock() - LastUi > 2 then
				LastUi = os.clock()
				UI.Set(("Wave %s | Lv %d | %d gems"):format(
					tostring(Match.Wave() or "?"), Account.Level(), Account.Gems()))
			end
		else
			WasActive = false
			if Match.Finished() and not Handled then
				Handled = true
				task.spawn(Match.Finish)
			end
		end
		task.wait(0.4)
	end
end

-- ============================================================================
-- entry
-- ============================================================================
-- handy for debugging / other scripts: getgenv().AAKaitun.State, .Match, ...
Env.AAKaitun = {
	Config = Config,
	State = State,
	Lobby = Lobby,
	Match = Match,
	Account = Account,
	SaveState = SaveState,
}

local function Main()
	LoadState()
	Account.AntiAfk()
	if not Account.WaitSession(90) then
		warn("[AA Kaitun] profile never loaded")
		return
	end

	if Loader.IsLobby then
		Lobby.Run()
	else
		Match.Run()
	end
end

local Ok, Err = xpcall(Main, debug.traceback)
if not Ok then
	warn("[AA Kaitun] fatal: " .. tostring(Err))
end
