--[[
	Anime Adventures — KAITUN (one-click full automation)
	Game: [UPD 21] Anime Adventures — lobby place 8304191830

	Run via loader.lua (checks the game, downloads this file from GitHub, and
	re-queues itself after every teleport). It also re-queues through
	queue_on_teleport if the executor supports it. It detects lobby vs match
	by itself.

	LOBBY PIPELINE (every time you land in the lobby)
		1. Join group "Gomu" + favorite the game        (until done once)
		2. Redeem codes (each has a minimum account level)
		3. Celestial Compass -> Elyssia                  (only if not used yet)
		4. Claim daily login / missions / quests / level rewards / battlepass
		   (one pass per lobby visit)
		5. Summon 10x ONCE (saved to disk, never again)
		6. Equip team
		7. Planner picks the next thing to join:
		     gems >= 20k and no Elyssia  -> summon until Elyssia, then the configured team
		     Daily challenge  (level 25+, not cleared)
		     Normal challenge (level 15+, not cleared)
		     level <  50 -> Story act 1  (vote lose at wave 6, replay)
		     level >= 50 -> Story act 6 via the story skipper (full clear, then leave) -> Infinite (wave 6 lose loop)
		     (ChallengesOnlyAfterCompass = true: once the compass unit is owned,
		      skip infinite only — story still runs to TargetLevel, then the
		      lobby just takes challenges/dailies)

	MATCH PIPELINE
		Auto place / upgrade / vote start / skip waves, vote lose at wave 6 (loop
		modes only), then at the end of every match: leave to lobby if a challenge
		is pending / level 50 reached / gem hunt due, otherwise replay.

	State is saved per account in AAKaitun_<UserId>.json (workspace folder).
	Delete that file to reset the "summoned once" / "compass used" flags.
]]

if not game:IsLoaded() then
	task.wait()
	repeat
		task.wait()
	until game:IsLoaded()
end

local Players = game:GetService("Players")
local Player = Players.LocalPlayer

-- services ---------------------------------------------------------------
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local GroupService = game:GetService("GroupService")
local AvatarEditorService = game:GetService("AvatarEditorService")
local GuiService = game:GetService("GuiService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local VirtualUser = game:GetService("VirtualUser")
local CollectionService = game:GetService("CollectionService")
local CoreGui = game:GetService("CoreGui")

local PlayerGui = Player:WaitForChild("PlayerGui")
local Env = (getgenv and getgenv()) or _G

-- executor globals (not in standard Luau)
---@diagnostic disable: undefined-global
local GetGc, HookFunction, IsLClosure = getgc, hookfunction, islclosure
local FireSignal = firesignal
local GetHui = gethui

-- single instance guard --------------------------------------------------
local Token = {}
Env.AAKaitunToken = Token

local function Alive()
	return Env.AAKaitunToken == Token
end

-- teleport re-queue ------------------------------------------------------
-- Registers the loader stub with the executor's queue_on_teleport so this
-- script starts again automatically after every server hop (lobby -> match
-- -> lobby). The stub loads loader.lua, which checks the game and downloads
-- the latest version of this file. Harmless if the executor lacks support.
local KAITUN_LOADER_URL = "https://raw.githubusercontent.com/inCythe/AnimeAdventuresKaitun/main/loader.lua"
pcall(function()
	if type(queue_on_teleport) == "function" then
		queue_on_teleport(
			'local fn = loadstring(game:HttpGet("' .. KAITUN_LOADER_URL .. '"))\nif fn then fn() end'
		)
	end
end)

-- game modules -----------------------------------------------------------
local Loader = require(ReplicatedStorage:WaitForChild("src"):WaitForChild("Loader"))

local function SafeLoad(Kind, Name)
	local Ok, Result = pcall(Loader[Kind], nil, Name)
	if Ok then
		return Result
	end
	return nil
end

-- the client bootstrap calls Loader.init() only after SERVER_READY flips;
-- every service/data lookup returns nil until the registries exist
local BootDeadline = os.clock() + 90
while Alive() do
	local Flag = workspace:FindFirstChild("SERVER_READY")
	if (Flag and Flag.Value == true) or os.clock() >= BootDeadline then
		break
	end
	task.wait(0.5)
end
task.wait(0.5) -- let init() finish registering the services

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
	warn("[AA Kaitun] EndpointsClient failed to load — wrong game or bootstrap stuck")
	return
end
local InvokeServer = EndpointsClient.invoke_server
local LevelServiceCore = SafeLoad("load_core_service", "LevelServiceCore")

local Units = SafeLoad("load_data", "Units") or {}
local Banners = SafeLoad("load_data", "Banners") or {}
local Levels = SafeLoad("load_data", "Levels") or {}
local Worlds = SafeLoad("load_data", "Worlds") or {}
local WorldLevelOrder = SafeLoad("load_data", "WorldLevelOrder") or {}
local GameplaySettings = SafeLoad("load_data", "GameplaySettings") or {}
local PlayerLevelRewards = SafeLoad("load_data", "PlayerLevelRewards") or {}

-- config -----------------------------------------------------------------
local Config = {
	-- progression
	StoryAct = 1,                 -- act used for the early loop

	-- story skipper (used for the one-time clear at EndgameLevel)
	SkipStory = true,             -- true = lobby_world_skip(world) -> jumps to the world's last act
	SkipWorld = nil,              -- world id to skip (e.g. "namek"); nil = first story world
	SkipAct = nil,                -- nil = last act of the world (act 6), or an act number
	LoseWave = 6,                 -- vote lose at this wave in loop modes
	NormalChallengeLevel = 15,
	DailyChallengeLevel = 25,
	EndgameLevel = 50,

	-- summon / hunt
	SummonBanner = "EventClover",
	HuntBanner = "EventClover",
	HuntGems = 20000,             -- go back to lobby and hunt when gems >= this
	MinGems = 200,                -- hunt never leaves fewer gems than this

	-- compass (CompassUnit = the pick AND the hunt target)
	CompassId = "celestial_compass_u21",
	CompassUnit = "elyssia",
	ChallengesOnlyAfterCompass = false, -- true = once the compass unit is owned, stop joining story/infinite and only take challenges/dailies in the lobby

	-- group + favorite
	GroupId = 10611639,
	GroupName = "Gomu",
	FavoriteCode = "CELESTIALCOMPASSU21",
	GroupMaxAttempts = 3,

	-- codes: Level = minimum account level, nil = no gate
	ForceCodes = false,           -- true = ignore the level gates
	Codes = {
		{ Code = "2MILLIONFAVES",       Level = 20 },
		{ Code = "SUMMERCOMEBACK",      Level = 20 },
		{ Code = "CELESTIALCOMPASSU21" },
		{ Code = "AACOMEBACK",          Level = 10 },
		{ Code = "DUNGEONS" },
		{ Code = "UPDATESOON5189" },
		{ Code = "APRILFOOLS",          Level = 20 },
		{ Code = "MILLIONFAVES",        Level = 20 },
		{ Code = "2BILLIONAA",          Level = 50 },
	},

	-- claiming (one pass per lobby visit, no retries)
	AcceptMissions = true,        -- start untaken daily board missions so they track progress

	-- challenges reset on a fixed clock: every :00 and :30
	ChallengeResetSeconds = 1800,
	ChallengeResetGrace = 20,     -- wait this long after the reset before leaving for it
	ChallengeLeaveLead = 20,      -- head to lobby this many seconds BEFORE a reset

	-- challenges
	TrustProfileForClear = false, -- true = also treat a challenge uuid found in the profile as cleared
	MatchmakingRetryWait = 21,
	MatchmakingRetries = 5,
	QueueTimeout = 300,           -- queued this long (5 min) -> leave, wait, queue again
	JoinTimeout = 90,             -- a join that never opened a queue or teleported
	IdleWait = 5,                 -- re-plan this soon when no join was requested

	-- webhook reports (leave the url empty to disable)
	WebhookUrl = "",
	WebhookName = "AA Kaitun",
	WebhookShowName = true,       -- false = hide the account name in reports

	-- fps boost: always applied on execute (lobby and matches)
	FpsBoost = true,
	FpsSettings = {
		FlatTopDownCamera = false,
		HideParts = false,
		StripGui = false,
		Disable3DRender = false,
		DisableShadows = true,
		DisableLightShadows = false,
		StripSky = true,
		StripCharacter = false,
		FlatTerrain = true,
		SweepBackpack = false,
		MuteSounds = true,
		FpsCap = 15,
		FpsCapRestore = 0,
		FpsCapSetter = nil,
	},

	-- placement
	Percent = 5,
	NodeSpacing = 2.5,
	RadiusGround = 40,
	RadiusHill = 40,
	RadiusFarm = 10,
	FarmTerrain = "ground",
	ActionDelay = 0.2,
	RetryEvery = 3,               -- seconds before a unit retries after a failed placement
	SummonHatchWait = 2,          -- max seconds to wait for the hatch record after a 10x
	RescanAfterFails = 6,         -- this many failed placements in a row -> rescan
	UpgradeRetry = 2,
	VoteRetry = 2,
	ShowVisuals = false,          -- draw scan nodes/rings/arrow like auto_place.lua

	-- getgenv().Kaitun overrides (merged below)
	TeamUnits = nil,             -- Kaitun.Team = { "bulby", ... } — units to equip, in order
	AutoSell = true,             -- sell everything that is not on the team
	SkipCutscenes = true,        -- stub summon/reward/hatch cinematics
	WebhookMode = "goal",        -- "goal" milestones only | "all" + match events | "none"
	WebhookPing = "",            -- Kaitun.WebhookPing, sent as webhook message content

	StatsOverlay = true,         -- black screen + live account stats panel
}

-- user config via getgenv().Kaitun -----------------------------------------
-- set this BEFORE running the script/loader, e.g.:
--   getgenv().Kaitun = {
--       TargetLevel = 50, CompassUnit = "Elyssia",
--       Team = { "Bulby", "Windsong", "C.E.O.", "Hammergirl" },
--       RollAtGems = 20000, SaveGems = 0,
--       FpsBoost = true,
--       Webhook = "https://discord.com/api/webhooks/...",
--       WebhookType = "Goal Only", WebhookPing = "",
--       AutoSell = true, SkipCutscenes = true,
--       ChallengesOnlyAfterCompass = true,
--   }
local UserConfig = Env.Kaitun
if type(UserConfig) == "table" then
	local function Num(Value)
		return tonumber(Value)
	end
	if Num(UserConfig.TargetLevel) then
		Config.EndgameLevel = math.floor(Num(UserConfig.TargetLevel))
	end
	if UserConfig.CompassUnit ~= nil then
		Config.CompassUnit = tostring(UserConfig.CompassUnit):lower()
	end
	if type(UserConfig.Team) == "table" then
		Config.TeamUnits = UserConfig.Team
	end
	if Num(UserConfig.RollAtGems) then
		Config.HuntGems = Num(UserConfig.RollAtGems)
	end
	if Num(UserConfig.SaveGems) then
		Config.MinGems = Num(UserConfig.SaveGems)
	end
	if UserConfig.FpsBoost ~= nil then
		Config.FpsBoost = UserConfig.FpsBoost and true or false
	end
	if UserConfig.Webhook ~= nil then
		Config.WebhookUrl = tostring(UserConfig.Webhook)
	end
	if UserConfig.WebhookPing ~= nil then
		Config.WebhookPing = tostring(UserConfig.WebhookPing)
	end
	if UserConfig.WebhookType ~= nil then
		local Kind = tostring(UserConfig.WebhookType):lower()
		if Kind:find("none") or Kind:find("off") or Kind:find("disable") then
			Config.WebhookMode = "none"
		elseif Kind:find("all") then
			Config.WebhookMode = "all"
		else
			Config.WebhookMode = "goal"
		end
	end
	if UserConfig.AutoSell ~= nil then
		Config.AutoSell = UserConfig.AutoSell and true or false
	end
	if UserConfig.SkipCutscenes ~= nil then
		Config.SkipCutscenes = UserConfig.SkipCutscenes and true or false
	end
	if UserConfig.ChallengesOnlyAfterCompass ~= nil then
		Config.ChallengesOnlyAfterCompass = UserConfig.ChallengesOnlyAfterCompass and true or false
	end
	if UserConfig.StatsOverlay ~= nil then
		Config.StatsOverlay = UserConfig.StatsOverlay and true or false
	end
end

-- state (persisted) ------------------------------------------------------
local StateFile = "AAKaitun_" .. tostring(Player.UserId) .. ".json"
local State = {
	Summoned = false,
	CompassDone = false,
	CompassUnit = nil,           -- last resolved compass/hunt unit (survives teleports)
	GroupDone = false,
	GroupAttempts = 0,
	HuntDone = false,
	Reported = {},                -- webhook milestones already sent
	ChallengeSlot = 0,            -- last half-hour slot the challenges were handled in
	ChallengeDone = {},
	Hunted = {},                 -- unit id -> true, hunt targets already acquired
	RedeemedCodes = {},          -- code -> true, backup ledger in case the profile lags
	Current = nil,
}

local function LoadState()
	if not (isfile and readfile and isfile(StateFile)) then
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
	for _, Key in ipairs({ "Hunted", "RedeemedCodes" }) do
		if type(State[Key]) ~= "table" then
			State[Key] = {}
		end
	end
end

local function SaveState()
	if writefile then
		pcall(writefile, StateFile, HttpService:JSONEncode(State))
	end
end

-- helpers ----------------------------------------------------------------
local function Log(Format, ...)
	print(("[AA Kaitun] " .. Format):format(...))
end

local function Profile()
	return EndpointsClient.session and EndpointsClient.session.profile_data or {}
end

local function Collection()
	return Profile().collection or {}
end

local function CountEntries(Table)
	local Count = 0
	if type(Table) == "table" then
		for _ in pairs(Table) do
			Count = Count + 1
		end
	end
	return Count
end

local CallWithTimeout -- defined below

local function Invoke(Name, ...)
	local Ok, Result = CallWithTimeout(10, InvokeServer, Name, ...)
	if not Ok then
		Log("%s failed: %s", Name, tostring(Result))
		return nil, false
	end
	return Result, true
end

-- run a call on its own thread; some remotes never return on bad arguments
CallWithTimeout = function(Timeout, Fn, ...)
	local Args = table.pack(...)
	local Done, Ok, Result = false, nil, nil
	task.spawn(function()
		Ok, Result = pcall(Fn, table.unpack(Args, 1, Args.n))
		Done = true
	end)
	local Deadline = os.clock() + Timeout
	while not Done and os.clock() < Deadline do
		task.wait(0.1)
	end
	if not Done then
		return false, "timeout"
	end
	return Ok, Result
end

local function GetEndpoint(Name)
	local Root = ReplicatedStorage:FindFirstChild("endpoints")
	Root = Root and Root:FindFirstChild("client_to_server")
	return Root and Root:FindFirstChild(Name)
end

local function FireEndpoint(Name, ...)
	local Remote = GetEndpoint(Name)
	if Remote and Remote:IsA("RemoteFunction") then
		local Args = table.pack(...)
		return CallWithTimeout(10, function()
			return Remote:InvokeServer(table.unpack(Args, 1, Args.n))
		end)
	end
	return nil
end

local function WaitForChange(Read, Before, Timeout)
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

local function WaitForSession()
	local Deadline = os.clock() + 90
	while Alive() and os.clock() < Deadline do
		local Session = EndpointsClient.session
		if Session and Session.profile_data then
			return true
		end
		task.wait(0.5)
	end
	return false
end

local function GetGems()
	local Stats = Player:FindFirstChild("_stats")
	local Value = Stats and Stats:FindFirstChild("gem_amount")
	if Value then
		return math.floor(tonumber(Value.Value) or 0)
	end
	return math.floor(tonumber(Profile().gem_amount) or 0)
end

local function GetXp()
	local Stats = Player:FindFirstChild("_stats")
	local Value = Stats and Stats:FindFirstChild("player_xp")
	if Value and Value:IsA("ValueBase") then
		return tonumber(Value.Value)
	end
	return tonumber(Profile().player_xp)
end

local function GetLevel()
	local Xp = GetXp()
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

local function LowerSet(List)
	local Set = {}
	for _, Name in ipairs(List) do
		Set[tostring(Name):lower()] = true
	end
	return Set
end

-- true if any string key/value inside the table mentions the word
local function DefMentions(Table, Word, Depth)
	Depth = Depth or 0
	if type(Table) ~= "table" or Depth > 3 then
		return false
	end
	for Key, Value in pairs(Table) do
		if type(Key) == "string" and Key:lower():find(Word, 1, true) then
			return true
		end
		if type(Value) == "string" and Value:lower():find(Word, 1, true) then
			return true
		end
		if type(Value) == "table" and DefMentions(Value, Word, Depth + 1) then
			return true
		end
	end
	return false
end

-- units ------------------------------------------------------------------
local RarityRank = {}
for Index, Name in ipairs({ "Common", "Rare", "Epic", "Legendary", "Exclusive", "Mythic", "Secret" }) do
	RarityRank[Name] = Index
end

local function ScoreUnit(Unit)
	local Def = Units[Unit.unit_id] or {}
	local Traits = CountEntries(Unit.traits)
	local Damage = tonumber(Def.damage) or 0
	local Health = tonumber(Def.health) or 0
	return (RarityRank[Def.rarity] or 0) * 100000
		+ (Damage + Health / 100) * 10
		+ (Unit.shiny and 5000 or 0)
		+ Traits * 100
end

-- best owned copy per unit id: UnitId -> { Uuid, Score }
local function BestCopies()
	local Best = {}
	for Uuid, Unit in pairs(Collection().owned_units or {}) do
		if type(Unit) == "table" and type(Unit.unit_id) == "string" then
			local Score = ScoreUnit(Unit)
			local Current = Best[Unit.unit_id]
			if not Current or Score > Current.Score then
				Best[Unit.unit_id] = { Uuid = tostring(Uuid), Score = Score }
			end
		end
	end
	return Best
end

local function HatchedTotal(UnitId)
	local Stats = Profile()._hatched_unit_stats or {}
	local Counts = Stats[UnitId]
	if type(Counts) ~= "table" then
		return 0
	end
	return (tonumber(Counts.normal) or 0) + (tonumber(Counts.shiny) or 0)
end

local function HasUnit(UnitId)
	return BestCopies()[UnitId] ~= nil or HatchedTotal(UnitId) > 0
end

-- user-supplied unit ids (Kaitun.Team / Kaitun.CompassUnit) are matched
-- case-insensitively against the Units data, ignoring punctuation
local UnitIdLookup = nil
local function NormalizeUnitId(Id)
	local Raw = tostring(Id or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if Raw == "" then
		return nil
	end
	if Units[Raw] then
		return Raw
	end
	local Lower = Raw:lower()
	if Units[Lower] then
		return Lower
	end
	if not UnitIdLookup then
		UnitIdLookup = {}
		for Key, Def in pairs(Units) do
			local K = tostring(Key)
			UnitIdLookup[K:lower()] = K
			UnitIdLookup[(K:lower():gsub("[^%w]", ""))] = K
			-- display name (e.g. "C.E.O." -> "speedwagon", "Bulby" -> "bulma")
			local Display = type(Def) == "table" and Def.name or nil
			if type(Display) == "string" then
				local D = Display:lower()
				UnitIdLookup[D] = K
				UnitIdLookup[(D:gsub("[^%w]", ""))] = K
			end
		end
	end
	return UnitIdLookup[Lower] or UnitIdLookup[Lower:gsub("[^%w]", "")] or Lower
end

-- CompassUnit doubles as the hunt target; resolve display names once
Config.CompassUnit = NormalizeUnitId(Config.CompassUnit) or Config.CompassUnit

-- the unit being hunted
local function HuntTargets()
	return { Config.CompassUnit }
end

local function HuntRemaining()
	local Remaining = {}
	for _, Id in ipairs(HuntTargets()) do
		if not HasUnit(Id) and not State.Hunted[Id] then
			Remaining[#Remaining + 1] = Id
		end
	end
	return Remaining
end

-- display name for webhooks/logs ("elyssia" -> "Elyssia")
local function UnitDisplayName(Id)
	local Def = Units[Id]
	local Name = type(Def) == "table" and Def.name or nil
	return type(Name) == "string" and Name or tostring(Id)
end

local function HatchCounters()
	local Copy = {}
	for UnitId, Counts in pairs(Profile()._hatched_unit_stats or {}) do
		Copy[UnitId] = { Normal = tonumber(Counts.normal) or 0, Shiny = tonumber(Counts.shiny) or 0 }
	end
	return Copy
end

local function DiffHatches(Before, After)
	local New = {}
	for UnitId, Counts in pairs(After) do
		local Old = Before[UnitId] or { Normal = 0, Shiny = 0 }
		if Counts.Normal > Old.Normal or Counts.Shiny > Old.Shiny then
			New[#New + 1] = { Id = UnitId, Normal = Counts.Normal - Old.Normal, Shiny = Counts.Shiny - Old.Shiny }
		end
	end
	return New
end

-- cinematics -------------------------------------------------------------
local CinematicFunctions = {
	open_star_new = true,
	show_unit_and_item_rewards = true,
	on_show_hatch_effect = true,
	on_show_item_hatch_effect = true,
	on_units_hatched_through_banner = true,
}

local function CinematicStub(...)
	for _, Arg in ipairs({ ... }) do
		if type(Arg) == "function" then
			pcall(Arg)
		end
	end
end

-- the cinematic modules are lazy-loaded, so a one-time scan at boot misses
-- them; rescan on every summon and remember what is already hooked
local CinematicHooked = {}
local function InstallCinematicSkip()
	if not (HookFunction and GetGc and IsLClosure) then
		return
	end
	local Ok, Gc = pcall(GetGc, true)
	if not (Ok and type(Gc) == "table") then
		return
	end
	for _, Value in ipairs(Gc) do
		if type(Value) == "function" and IsLClosure(Value) and not CinematicHooked[Value] then
			local Info = debug.getinfo(Value)
			if Info and Info.name and CinematicFunctions[Info.name] then
				if pcall(HookFunction, Value, CinematicStub) then
					CinematicHooked[Value] = true
				end
			end
		end
	end
end

local function AntiAfk()
	Player.Idled:Connect(function()
		pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end)
	end)
end

-- fps boost --------------------------------------------------------------
-- Strips textures / effects / sky while keeping scene lighting. Every changed
-- property is cached; the returned function restores all of it
-- (also exposed as getgenv().AAKaitunFpsRestore).
local SkyFaces = { "SkyboxBk", "SkyboxDn", "SkyboxFt", "SkyboxLf", "SkyboxRt", "SkyboxUp" }

local function ApplyFpsBoost(Settings)
	Settings = Settings or {}
	local RunService = game:GetService("RunService")
	local Lighting = game:GetService("Lighting")
	local SoundService = game:GetService("SoundService")
	local StarterGui = game:GetService("StarterGui")

	local FlatCam = Settings.FlatTopDownCamera == true
	local HideParts = Settings.HideParts == true
	local StripGui = Settings.StripGui == true
	local No3D = Settings.Disable3DRender == true
	local NoPartShadow = Settings.DisableShadows == true
	local NoLightShadow = Settings.DisableLightShadows == true
	local StripSky = Settings.StripSky == true
	local StripChar = Settings.StripCharacter == true
	local FlatTerrain = Settings.FlatTerrain == true
	local SweepPack = Settings.SweepBackpack == true
	local MuteSounds = Settings.MuteSounds ~= false
	local FpsCap = tonumber(Settings.FpsCap) or 0
	local FpsCapRestore = tonumber(Settings.FpsCapRestore) or 0
	local FpsCapSetter = type(Settings.FpsCapSetter) == "function" and Settings.FpsCapSetter or nil

	local Cache = {}
	local Connections = {}
	local Stopped = false
	local CoreGuiState = nil
	local ThreeDDisabled = false

	local function Remember(Item, Property, Value)
		local Record = Cache[Item]
		if not Record then
			Record = {}
			Cache[Item] = Record
		end
		if Record[Property] == nil then
			Record[Property] = Value
		end
	end

	local function SetCached(Item, Property, Value)
		local Ok, Current = pcall(function()
			return Item[Property]
		end)
		if not Ok or Current == Value then
			return
		end
		Remember(Item, Property, Current)
		pcall(function()
			Item[Property] = Value
		end)
	end

	local function Strip(Item)
		if Stopped or not Item or not Item.Parent then
			return
		end

		if Item:IsA("Terrain") then
			if FlatTerrain then
				SetCached(Item, "Decoration", false)
				SetCached(Item, "WaterWaveSize", 0)
				SetCached(Item, "WaterWaveSpeed", 0)
			end
			return
		end

		if not StripChar then
			local Character = Player.Character
			if Character and Item:IsDescendantOf(Character) then
				return
			end
		end

		if Item:IsA("Sky") then
			if StripSky then
				for _, Face in ipairs(SkyFaces) do
					SetCached(Item, Face, "")
				end
				SetCached(Item, "CelestialBodiesShown", false)
				SetCached(Item, "StarCount", 0)
			end
			return
		end

		if Item:IsA("ParticleEmitter") or Item:IsA("Trail") or Item:IsA("Smoke") or Item:IsA("Fire")
			or Item:IsA("Sparkles") or Item:IsA("Beam") or Item:IsA("Highlight")
			or Item:IsA("BloomEffect") or Item:IsA("BlurEffect")
			or Item:IsA("DepthOfFieldEffect") or Item:IsA("SunRaysEffect") then
			SetCached(Item, "Enabled", false)
			return
		end

		if Item:IsA("Light") then
			if NoLightShadow then
				SetCached(Item, "Shadows", false)
			end
			return
		end

		if Item:IsA("BasePart") then
			local Transparent = Item.Transparency > 0
				or Item.Material == Enum.Material.Glass
				or Item.Material == Enum.Material.ForceField
			if not Transparent then
				SetCached(Item, "Material", Enum.Material.SmoothPlastic)
				SetCached(Item, "MaterialVariant", "")
				SetCached(Item, "Reflectance", 0)
			end
			if NoPartShadow then
				SetCached(Item, "CastShadow", false)
			end
			if Item:IsA("MeshPart") then
				SetCached(Item, "TextureID", "")
				SetCached(Item, "RenderFidelity", Enum.RenderFidelity.Performance)
			end
			if HideParts then
				SetCached(Item, "Transparency", 1)
			end
			return
		end

		if Item:IsA("Decal") then
			SetCached(Item, "Texture", "")
			SetCached(Item, "Transparency", 1)
			return
		end
		if Item:IsA("ShirtGraphic") then
			SetCached(Item, "Graphic", "")
			return
		end
		if Item:IsA("SurfaceAppearance") then
			for _, Map in ipairs({ "ColorMap", "NormalMap", "RoughnessMap", "MetalnessMap", "EmissiveMask" }) do
				SetCached(Item, Map, "")
			end
			return
		end
		if Item:IsA("SpecialMesh") then
			SetCached(Item, "TextureId", "")
			return
		end
		if Item:IsA("Shirt") then
			SetCached(Item, "ShirtTemplate", "")
			return
		end
		if Item:IsA("Pants") then
			SetCached(Item, "PantsTemplate", "")
			return
		end
		if Item:IsA("VideoFrame") then
			SetCached(Item, "Video", "")
			SetCached(Item, "Visible", false)
			return
		end
		if MuteSounds and Item:IsA("Sound") then
			SetCached(Item, "Playing", false)
			SetCached(Item, "Volume", 0)
			return
		end
		if Item:IsA("ImageLabel") or Item:IsA("ImageButton") then
			if Item:FindFirstAncestorOfClass("SurfaceGui") or Item:FindFirstAncestorOfClass("BillboardGui") then
				SetCached(Item, "ImageTransparency", 1)
				SetCached(Item, "BackgroundTransparency", 1)
			end
		end
	end

	local Roots = { workspace, Lighting, SoundService }
	if SweepPack then
		local Backpack = Player:FindFirstChildOfClass("Backpack")
		if Backpack then
			table.insert(Roots, Backpack)
		end
	end

	if StripGui then
		CoreGuiState = {}
		for _, GuiType in ipairs(Enum.CoreGuiType:GetEnumItems()) do
			local Ok, WasEnabled = pcall(function()
				return StarterGui:GetCoreGuiEnabled(GuiType)
			end)
			if Ok then
				CoreGuiState[GuiType] = WasEnabled
			end
		end
		pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false)
		end)

		local function StripGuiObject(Gui)
			if Stopped then
				return
			end
			if Gui:IsA("GuiObject") then
				SetCached(Gui, "BackgroundTransparency", 1)
				SetCached(Gui, "BorderSizePixel", 0)
				if Gui:IsA("ImageLabel") or Gui:IsA("ImageButton") then
					SetCached(Gui, "ImageTransparency", 1)
				end
			elseif Gui:IsA("UIStroke") then
				SetCached(Gui, "Transparency", 1)
			elseif Gui:IsA("UIGradient") then
				SetCached(Gui, "Transparency", NumberSequence.new(1))
			end
		end
		for _, Gui in ipairs(PlayerGui:GetDescendants()) do
			pcall(StripGuiObject, Gui)
		end
		table.insert(Connections, PlayerGui.DescendantAdded:Connect(function(Gui)
			if not Stopped then
				task.defer(pcall, StripGuiObject, Gui)
			end
		end))
	end

	if FlatCam then
		table.insert(Connections, RunService.RenderStepped:Connect(function()
			if Stopped then
				return
			end
			local Camera = workspace.CurrentCamera
			if not Camera then
				return
			end
			if not Cache[Camera] then
				Remember(Camera, "FieldOfView", Camera.FieldOfView)
				Remember(Camera, "CameraType", Camera.CameraType)
			end
			local Character = Player.Character
			local Root = Character and Character:FindFirstChild("HumanoidRootPart")
			if Root then
				Camera.FieldOfView = 1
				Camera.CameraType = Enum.CameraType.Scriptable
				Camera.CFrame = CFrame.new(Root.Position, Root.Position + Vector3.new(0, 1000, 0))
			end
		end))
	end

	for _, Root in ipairs(Roots) do
		table.insert(Connections, Root.DescendantAdded:Connect(function(Item)
			if Stopped or not Item or not Item.Parent then
				return
			end
			task.defer(pcall, Strip, Item)
		end))
	end

	local Count = 0
	for _, Root in ipairs(Roots) do
		if Stopped then
			break
		end
		for _, Item in ipairs(Root:GetDescendants()) do
			if Stopped then
				break
			end
			pcall(Strip, Item)
			Count = Count + 1
			if Count % 1000 == 0 then
				task.wait()
			end
		end
	end

	if No3D then
		if pcall(function()
			RunService:Set3dRenderingEnabled(false)
		end) then
			ThreeDDisabled = true
		end
	end
	if FpsCap > 0 and FpsCapSetter then
		pcall(FpsCapSetter, FpsCap)
	end

	local function Restore()
		if Stopped then
			return
		end
		Stopped = true
		for _, Connection in ipairs(Connections) do
			pcall(function()
				Connection:Disconnect()
			end)
		end
		table.clear(Connections)
		for Item, Record in pairs(Cache) do
			if Item and Item.Parent then
				for Property, Value in pairs(Record) do
					pcall(function()
						Item[Property] = Value
					end)
				end
			end
		end
		table.clear(Cache)
		if CoreGuiState then
			for GuiType, WasEnabled in pairs(CoreGuiState) do
				pcall(function()
					StarterGui:SetCoreGuiEnabled(GuiType, WasEnabled)
				end)
			end
			CoreGuiState = nil
		end
		if ThreeDDisabled then
			pcall(function()
				RunService:Set3dRenderingEnabled(true)
			end)
			ThreeDDisabled = false
		end
		if FpsCap > 0 and FpsCapSetter then
			pcall(FpsCapSetter, FpsCapRestore)
		end
	end

	return Restore
end

-- webhook reports ----------------------------------------------------------
local RequestFn = (syn and syn.request) or http_request or request or (http and http.request)

local function SendWebhook(Title, Description, Color)
	if Config.WebhookUrl == "" or Config.WebhookMode == "none" or not RequestFn then
		return
	end
	-- exact profile paths (verified with check_inventory.lua)
	local Prof = Profile()
	local NormalItems = type(Prof.inventory) == "table"
		and type(Prof.inventory.normal_items) == "table"
		and Prof.inventory.normal_items or {}
	local function ItemCount(Key)
		return tonumber(NormalItems[Key]) or 0
	end
	local Fields = {
		{ name = "Account", value = Config.WebhookShowName and Player.Name or "hidden", inline = true },
		{ name = "Level", value = tostring(GetLevel()), inline = true },
		{ name = "Gems", value = tostring(tonumber(Prof.gem_amount) or GetGems()), inline = true },
		{ name = "Reroll Tokens", value = tostring(tonumber(Prof.trait_reroll_tokens) or 0), inline = true },
		{ name = "Remnants", value = tostring(ItemCount("star_remnant")), inline = true },
		{ name = "Remnants (Ltd)", value = tostring(ItemCount("star_remnant_limited")), inline = true },
	}
	local Body = {
		username = Config.WebhookName,
		embeds = { {
			title = Title,
			description = Description,
			color = Color or 5793266,
			fields = Fields,
			timestamp = DateTime.now():ToIsoDate(),
		} },
	}
	if Config.WebhookPing ~= "" then
		Body.content = Config.WebhookPing
	end
	Body = HttpService:JSONEncode(Body)
	task.spawn(function()
		pcall(RequestFn, {
			Url = Config.WebhookUrl,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = Body,
		})
	end)
end

-- each milestone is reported once per account (saved in the state file)
local Milestones = {
	{
		Key = "Level" .. Config.NormalChallengeLevel,
		Title = "Level " .. Config.NormalChallengeLevel .. " reached",
		Text = "Normal challenges are unlocked.",
		Check = function()
			return GetLevel() >= Config.NormalChallengeLevel
		end,
	},
	{
		Key = "Level" .. Config.DailyChallengeLevel,
		Title = "Level " .. Config.DailyChallengeLevel .. " reached",
		Text = "Daily challenges are unlocked.",
		Check = function()
			return GetLevel() >= Config.DailyChallengeLevel
		end,
	},
	{
		Key = "Level" .. Config.EndgameLevel,
		Title = "Level " .. Config.EndgameLevel .. " reached",
		Text = "Switching to the act 6 clear, then Infinite.",
		Check = function()
			return GetLevel() >= Config.EndgameLevel
		end,
	},
	{
		Key = "Gems" .. Config.HuntGems,
		Title = Config.HuntGems .. " gems reached",
		Text = "Heading to the lobby to hunt.",
		Check = function()
			return GetGems() >= Config.HuntGems
		end,
	},
	{
		Key = "CompassUsed",
		Title = "Celestial Compass used",
		Text = "Picked " .. UnitDisplayName(Config.CompassUnit) .. ".",
		Check = function()
			return State.CompassDone == true
		end,
	},
	{
		Key = "FirstSummon",
		Title = "First 10x summon done",
		Text = "Summoned once on " .. Config.SummonBanner .. ".",
		Check = function()
			return State.Summoned == true
		end,
	},
	{
		Key = "HuntDone",
		Title = "Hunt complete",
		Text = "All wanted units are in the collection; the configured team is now used.",
		Color = 5763719,
		Check = function()
			return State.HuntDone == true
		end,
	},
}

local function StartMilestoneWatcher()
	task.spawn(function()
		while Alive() do
			for _, Milestone in ipairs(Milestones) do
				if not State.Reported[Milestone.Key] then
					local Ok, Reached = pcall(Milestone.Check)
					if Ok and Reached then
						State.Reported[Milestone.Key] = os.time()
						SaveState()
						Log("milestone: %s", Milestone.Title)
						SendWebhook(Milestone.Title, Milestone.Text, Milestone.Color)
					end
				end
			end
			task.wait(10)
		end
	end)
end

-- stats overlay -------------------------------------------------------------
-- full-screen dark screen with a live account dashboard; 3D rendering is
-- disabled for fps. Logo on top, stat cards with the game's own icons,
-- animated status pill and progress bars.
local function StartStatsOverlay()
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
	Gui.DisplayOrder = 1000
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
	}

	local Icons = {
		Rerolls = "rbxassetid://99186363801156",   -- Trait Rerolls
		Remnants = "rbxassetid://137988080790367", -- Star Remnants
		Compass = "rbxassetid://137369120766463",  -- Celestial Compass
		Gems = "rbxassetid://71405874061254",      -- Gems
		Logo = "rbxassetid://73535842368256",      -- Anime Adventures logo
	}

	local ActivityNames = {
		Story1 = "Story loop",
		Act6 = "Story act clear",
		Infinite = "Infinite",
		Normal = "Normal challenge",
		Daily = "Daily challenge",
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
		Size = UDim2.new(1, 0, 0, 20),
		TextSize = 14,
		TextColor3 = Theme.Muted,
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

	-- one line: icon, title on the left, value on the right
	local function AddCard(Order, Caption, IconId, Badge, Tint)
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
			New("ImageLabel", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(32, 32),
				BackgroundTransparency = 1,
				Image = IconId,
				ScaleType = Enum.ScaleType.Fit,
			}, IconBox)
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
			Size = UDim2.new(0, 120, 0, 20),
			TextSize = 13,
			TextColor3 = Theme.Muted,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = Caption,
		})
		return Label(Card, {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -14, 0.5, 0),
			Size = UDim2.new(1, -190, 0, 24),
			Font = Enum.Font.GothamBold,
			TextSize = 17,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = "-",
		})
	end

	local ValueGems = AddCard(1, "Gems", Icons.Gems)
	local ValueCompass = AddCard(2, "Celestial Compass", Icons.Compass)
	local ValueTokens = AddCard(3, "Reroll Tokens", Icons.Rerolls)
	local ValueRemnants = AddCard(4, "Star Remnants", Icons.Remnants)
	local ValueLimited = AddCard(5, "Limited Remnants", Icons.Remnants)
	local ValueLevel = AddCard(6, "Level", nil, "LV", Theme.Accent)

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
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -18, 0, Y),
			Size = UDim2.new(0.5, -18, 0, 16),
			Font = Enum.Font.GothamMedium,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Right,
			Text = "",
		})
		local Track = New("Frame", {
			Position = UDim2.new(0, 18, 0, Y + 22),
			Size = UDim2.new(1, -36, 0, 14),
			BackgroundColor3 = Theme.Back,
			BorderSizePixel = 0,
		}, Bars)
		Round(Track, 6)
		local Fill = New("Frame", {
			Size = UDim2.fromScale(0, 1),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
		}, Track)
		Round(Fill, 6)
		New("UIGradient", { Color = ColorSequence.new(ColorA, ColorB) }, Fill)
		return function(Fraction, Text)
			Percent.Text = Text
			TweenService:Create(Fill, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Size = UDim2.fromScale(math.clamp(Fraction, 0, 1), 1),
			}):Play()
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
		local Prof = Profile()
		local Items = type(Prof.inventory) == "table" and Prof.inventory.normal_items or nil
		if type(Items) ~= "table" then
			Items = {}
		end
		local Level = GetLevel()
		local Gems = GetGems()
		local Up = math.floor(tick() - StartedAt)

		-- header + pill
		Sub.Text = ("%s   ·   %02d:%02d:%02d"):format(Player.Name, math.floor(Up / 3600), math.floor(Up / 60) % 60, Up % 60)
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
		local CompassCount = tonumber(Items[Config.CompassId])
		if State.CompassDone then
			ValueCompass.Text = Pretty(Config.CompassUnit)
			ValueCompass.TextColor3 = Theme.Good
		elseif CompassCount and CompassCount > 0 then
			ValueCompass.Text = ("x%d ready"):format(CompassCount)
			ValueCompass.TextColor3 = Theme.Warn
		else
			ValueCompass.Text = "Not used"
			ValueCompass.TextColor3 = Theme.Text
		end
		ValueGems.Text = Fmt(Gems)
		ValueTokens.Text = Fmt(Prof.trait_reroll_tokens)
		ValueRemnants.Text = Fmt(Items.star_remnant)
		ValueLimited.Text = Fmt(Items.star_remnant_limited)
		ValueLevel.Text = tostring(Level)

		-- bars
		local Endgame = math.max(Config.EndgameLevel, 1)
		SetLevelBar(Level / Endgame, ("Lv %d / %d   ·   %d%%"):format(Level, Endgame, math.floor(math.clamp(Level / Endgame, 0, 1) * 100)))
		local Hunt = math.max(Config.HuntGems, 1)
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
	ToggleGui.DisplayOrder = 1001
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
		while Alive() do
			if BlackOn then
				pcall(Refresh)
			end
			task.wait(1)
		end
	end)
	pcall(Refresh)
	Log("stats overlay on (black screen %s)", BlackOn and "on" or "off")
end

-- ============================================================ LOBBY =====

-- scope block: frees the lobby locals before the match section; only the
-- entry points used later (RunLobby by Main, NeedHunt/CurrentSlot by the
-- match planner) are exported through the forward declarations
local RunLobby, NeedHunt, CurrentSlot, NextResetInfo
do

-- group + favorite -------------------------------------------------------
local function UiRoots()
	local Roots = { CoreGui }
	pcall(function()
		if GetHui then
			table.insert(Roots, GetHui())
		end
	end)
	return Roots
end

local function Unselect()
	pcall(function()
		if GuiService.SelectedObject then
			GuiService.SelectedObject = nil
		end
	end)
end

local function IsAlive(Button)
	if not Button then
		return false
	end
	local Ok, Result = pcall(function()
		return Button.Parent ~= nil and Button:IsDescendantOf(game) and Button.Visible
	end)
	return Ok and Result
end

local function PressButton(Button)
	pcall(function()
		if GuiService.SelectedObject ~= Button then
			Button.Selectable = true
			GuiService.SelectedObject = Button
			task.wait(0.05)
		end
		if GuiService.SelectedObject == Button and IsAlive(Button) then
			VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Return, false, game)
			task.wait(0.02)
			VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Return, false, game)
		end
	end)
end

local function SpamButton(Button, Verify, Timeout)
	local Deadline = os.clock() + Timeout
	while os.clock() < Deadline do
		if Verify() then
			Unselect()
			return true
		end
		if not IsAlive(Button) then
			Unselect()
			return Verify()
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
			local Container = Root.RobloxGui.FocusNavigationCoreScriptsWrapper.Main
				.DialogContentWrapper.Folder.Dialog.DialogInner
				.DialogBody.DialogActions.ActionsContainer
			for _, Child in ipairs(Container:GetChildren()) do
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
	Log("opening group join dialog (%s)", Config.GroupName)
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

local function FavoriteViaCode()
	if IsFavorited() then
		return true
	end
	Log("favoriting through the Code UI")

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

	local EnterBox = Window.Enter:WaitForChild("Type")
	EnterBox.Text = Config.FavoriteCode
	task.wait(0.1)
	pcall(function()
		FireSignal(EnterBox.FocusLost, true)
	end)
	task.wait(0.5)

	local YesButton = Window.ButtonHolder:WaitForChild("Yes")
	local YesDeadline = os.clock() + 5
	while os.clock() < YesDeadline do
		if FindFavoriteButton() then
			break
		end
		if not IsAlive(YesButton) or not Window.Parent or not Window.Visible then
			break
		end
		PressButton(YesButton)
		task.wait(0.1)
	end
	Unselect()

	local Deadline = os.clock() + 15
	while os.clock() < Deadline do
		if IsFavorited() then
			Unselect()
			return true
		end
		local Button = FindFavoriteButton()
		if Button then
			SpamButton(Button, IsFavorited, 2)
		else
			task.wait(0.1)
		end
	end
	Unselect()
	return IsFavorited()
end

local function GroupAndFavorite()
	if State.GroupDone then
		return
	end
	if State.GroupAttempts >= Config.GroupMaxAttempts then
		return
	end
	State.GroupAttempts = State.GroupAttempts + 1
	SaveState()

	local Joined = JoinGroup()
	local Favorited = false
	if Joined then
		task.wait(1)
		Favorited = FavoriteViaCode()
	end
	Log("group %s, favorite %s", Joined and "joined" or "NOT joined", Favorited and "done" or "NOT done")
	if Joined and Favorited then
		State.GroupDone = true
		SaveState()
	end
end

-- codes ------------------------------------------------------------------
local CodeDead = {}   -- codes the server ignored this session (never saved to disk)

local function RedeemedSet()
	local Set = {}
	local function Add(Code)
		if Code ~= nil then
			Set[tostring(Code):upper()] = true
		end
	end
	-- redeemed_codes may be a map { CODE = true } or a list { "CODE", ... }
	local Redeemed = Profile().redeemed_codes
	if type(Redeemed) == "table" then
		for Code, Value in pairs(Redeemed) do
			if type(Value) == "string" then
				Add(Value)
			elseif Value then
				Add(Code)
			end
		end
	end
	for Code in pairs(State.RedeemedCodes or {}) do
		Add(Code)
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

-- redeem_code answers nil/""/true for invalid AND already-redeemed, so the
-- profile's redeemed_codes decides which one it was
local function RedeemCodes()
	local Level = GetLevel()
	local Redeemed = RedeemedSet()
	local Seen = {}
	local Now, Locked = 0, 0

	for _, Entry in ipairs(Config.Codes) do
		local Raw = type(Entry) == "table" and Entry.Code or Entry
		local MinLevel = type(Entry) == "table" and Entry.Level or nil
		local Code = tostring(Raw):upper()

		if not Seen[Code] and not Redeemed[Code] and not CodeDead[Code] then
			Seen[Code] = true
			if MinLevel and not Config.ForceCodes and Level < MinLevel then
				Locked = Locked + 1
			else
				local Ok, Reply = CallWithTimeout(10, InvokeServer, "redeem_code", Code)
				if not Ok then
					Log("code %s: request failed (%s)", Code, tostring(Reply))
				elseif Reply == nil or Reply == "" or Reply == true then
					if WaitForRedeemed(Code, 3) then
						Redeemed[Code] = true
						State.RedeemedCodes[Code] = true
						SaveState()
						Now = Now + 1
						Log("code %s: redeemed", Code)
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
		Log("codes: %d redeemed now, %d waiting for a higher level (level %d)", Now, Locked, Level)
	end
end

-- celestial compass ------------------------------------------------------
local CompassTried = false

-- server-side check: the profile/session may record compass usage even when
-- the local state file was deleted or the pick unit was never obtained
local function CompassUsedOnServer()
	local function Scan(Table)
		if type(Table) ~= "table" then
			return false
		end
		for Key, Value in pairs(Table) do
			-- only usage markers (compass_used / compass_pick / ...), never the
			-- item entry itself which would false-positive before it is used
			if type(Key) == "string"
				and Key:lower():find("compass", 1, true)
				and (Key:lower():find("used", 1, true)
					or Key:lower():find("pick", 1, true)
					or Key:lower():find("claim", 1, true)
					or Key:lower():find("done", 1, true))
			then
				if Value == true then
					return true
				end
				if type(Value) == "string" and #Value > 0 then
					return true
				end
				if type(Value) == "table" and next(Value) ~= nil then
					return true
				end
			end
		end
		return false
	end
	if Scan(Profile()) then
		return true
	end
	return Scan(EndpointsClient.session)
end

local function UseCompass()
	if State.CompassDone then
		return
	end
	if CompassUsedOnServer() or HasUnit(Config.CompassUnit) then
		State.CompassDone = true
		SaveState()
		return
	end
	if CompassTried then
		return
	end
	CompassTried = true

	local Remote = GetEndpoint("set_celestial_compass_pick")
	if not Remote then
		Log("compass remote not found")
		return
	end
	local Ok, Result = CallWithTimeout(8, function()
		return Remote:InvokeServer(Config.CompassId, Config.CompassUnit)
	end)
	if not Ok then
		Log("compass failed: %s", tostring(Result))
		return
	end
	if type(Result) == "string" then
		Log("compass replied: %s", Result)
		if Result:lower():find("already", 1, true) then
			State.CompassDone = true
			SaveState()
		end
		return
	end
	if Result ~= false then
		State.CompassDone = true
		SaveState()
		Log("compass used -> %s", Config.CompassUnit)
	end
end

-- claim everything ------------------------------------------------------
-- One pass per lobby visit, no retries: each claim is sent once, and nothing
-- already claimed is sent again (profile ledgers are checked first).
local DailyWait = tonumber(GameplaySettings.DAILY_REWARD_WAIT) or 82800
local function IsClaimedTier(Lane, Tier)
	if type(Lane) ~= "table" then
		return false
	end
	return Lane[tostring(Tier)] == true or Lane[Tier] == true
end

local function DailyPopupOpen()
	local Gui = PlayerGui:FindFirstChild("DailyRewards")
	if not Gui then
		return false
	end
	if Gui:IsA("ScreenGui") then
		return Gui.Enabled == true
	end
	return Gui.Visible == true
end

-- live quest mirror; profile_data.quest_handler is the same data flattened
local function QuestProfile()
	local Session = EndpointsClient.session
	local Handler = Session and Session.quest_handler
	local Live = Handler and Handler.quest_profile_data
	if type(Live) == "table" then
		return Live
	end
	local Mirrored = Profile().quest_handler
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

local function QuestTable()
	local Data = QuestProfile()
	return Data and Data.quests or {}
end

local function CompletedQuests()
	local Data = QuestProfile()
	local Done = Data and Data.unique_quests_completed
	return type(Done) == "table" and Done or {}
end

local function QuestId(Uuid, Quest)
	local Info = Quest.quest_info or {}
	if Info.id then
		return tostring(Info.id)
	end
	local Bare = tostring(Uuid):gsub("[{}]", "")
	return Bare
end

-- daily login
local function ClaimDailyReward()
	local Before = tonumber(Profile().last_daily_reward_claimed_time) or 0
	local Elapsed = os.time() - Before
	if Elapsed < DailyWait and not DailyPopupOpen() then
		return false
	end
	CallWithTimeout(10, InvokeServer, "claim_daily_reward")
	local After = WaitForChange(function()
		return tonumber(Profile().last_daily_reward_claimed_time) or 0
	end, Before, 3)
	if After then
		Log("daily login: claimed (streak %s)", tostring(Profile().days_streak))
		return true
	end
	Log("daily login: not confirmed")
	return false
end

-- daily mission board
local function BoardMissionIds()
	local Ok, List = CallWithTimeout(10, InvokeServer, "request_current_dailymissions")
	if Ok and type(List) == "table" then
		local Ids = {}
		for _, Value in pairs(List) do
			if type(Value) == "string" then
				Ids[#Ids + 1] = Value
			end
		end
		if #Ids > 0 then
			return Ids
		end
	end
	local OkDefs, Defs = CallWithTimeout(10, InvokeServer, "request_dailymissions_data")
	if OkDefs and type(Defs) == "table" then
		local Ids = {}
		for MissionId, Data in pairs(Defs) do
			Ids[#Ids + 1] = (type(Data) == "table" and Data.id) or tostring(MissionId)
		end
		if #Ids > 0 then
			table.sort(Ids)
			return Ids
		end
	end
	return nil
end

-- quest present + incomplete  -> tracking, leave it
-- quest present + complete    -> claim it
-- no quest + ledger entry     -> already claimed, NEVER accept again
-- no quest + no ledger entry  -> brand new mission, accept it
local function ClaimDailyMissions()
	local Ids = BoardMissionIds()
	if not Ids then
		Log("daily missions: could not read the board")
		return false
	end

	local Ledger = (Profile().dailymissions_data or {}).claimed_missions
	if type(Ledger) ~= "table" then
		Ledger = {}
	end

	local ById = {}
	for Uuid, Quest in pairs(QuestTable()) do
		if type(Quest) == "table" then
			local Id = QuestId(Uuid, Quest)
			ById[Id] = Quest
			local Bare = Id:gsub("__quest$", "")
			ById[Bare] = ById[Bare] or Quest
		end
	end

	local function StillTracked(MissionId)
		for Uuid, Quest in pairs(QuestTable()) do
			if type(Quest) == "table" then
				local Id = QuestId(Uuid, Quest)
				if Id == MissionId or Id == MissionId .. "__quest" then
					return true
				end
			end
		end
		return false
	end

	local Claimed, Started, InProgress, AlreadyDone, Unconfirmed = 0, 0, 0, 0, 0
	for _, MissionId in ipairs(Ids) do
		local Quest = ById[MissionId]
		if Quest then
			local Class = (Quest.quest_info or {}).quest_class or {}
			local Have = tonumber((Quest.quest_progress or {}).amount) or 0
			local Need = tonumber(Class.amount)
			if Need ~= nil and Have < Need then
				InProgress = InProgress + 1
			else
				CallWithTimeout(10, InvokeServer, "request_claim_dailymission", MissionId)
				local Gone = WaitForChange(function()
					return not StillTracked(MissionId)
				end, false, 2)
				if Gone then
					Claimed = Claimed + 1
				else
					Unconfirmed = Unconfirmed + 1
				end
				task.wait(0.15)
			end
		elseif Ledger[MissionId] == true then
			AlreadyDone = AlreadyDone + 1
		elseif Config.AcceptMissions then
			CallWithTimeout(10, InvokeServer, "request_claim_dailymission", MissionId)
			Started = Started + 1
			task.wait(0.15)
		end
	end

	if Claimed + Started + InProgress + AlreadyDone + Unconfirmed > 0 then
		Log("daily missions: %d claimed, %d started, %d in progress, %d already claimed, %d unconfirmed",
			Claimed, Started, InProgress, AlreadyDone, Unconfirmed)
	end
	return Claimed > 0
end

-- player level rewards (milestone level as a STRING; a number hangs the remote)
local function ClaimLevelRewards()
	local Level = GetLevel()
	local Claimed = Profile().level_rewards_claimed or {}
	local Pending = {}

	local Milestones = {}
	for Key, Def in pairs(PlayerLevelRewards) do
		local Milestone = type(Def) == "table" and tonumber(Def.level)
		if Milestone then
			Milestones[#Milestones + 1] = { Level = Milestone, Key = Key }
		end
	end
	table.sort(Milestones, function(A, B)
		return A.Level < B.Level
	end)

	for _, Entry in ipairs(Milestones) do
		local Milestone = Entry.Level
		-- level_rewards_claimed may be keyed by level or by the def index
		local Done = Claimed[Milestone] ~= nil or Claimed[tostring(Milestone)] ~= nil
			or Claimed[Entry.Key] ~= nil or Claimed[tostring(Entry.Key)] ~= nil
		if Milestone <= Level and not Done then
			Pending[#Pending + 1] = Milestone
		end
	end
	if #Pending == 0 then
		return false
	end
	local Before = CountEntries(Claimed)
	Log("level rewards: level %d, claiming milestone(s) %s", Level, table.concat(Pending, ", "))
	for _, Milestone in ipairs(Pending) do
		CallWithTimeout(3, InvokeServer, "claim_player_level_rewards", tostring(Milestone))
		task.wait(0.15)
	end
	local After = WaitForChange(function()
		return CountEntries(Profile().level_rewards_claimed)
	end, Before, 3)
	return After ~= nil and After > Before
end

-- quests (redeem_quest); the daily_complete meta-quest waits for the dailies
local function ClaimQuests()
	local Data = QuestProfile()
	if not Data then
		return false
	end
	local Done = Data.unique_quests_completed or {}
	local Before = CountEntries(Done)

	local DailyIncomplete = false
	for _, Quest in pairs(Data.quests or {}) do
		if type(Quest) == "table" and Quest.quest_type == "daily" then
			local Class = (Quest.quest_info or {}).quest_class or {}
			local Need = tonumber(Class.amount)
			local Have = tonumber((Quest.quest_progress or {}).amount) or 0
			if Need ~= nil and Have < Need then
				DailyIncomplete = true
				break
			end
		end
	end

	local Attempts = 0
	for Uuid, Quest in pairs(Data.quests or {}) do
		if type(Quest) == "table" then
			local Info = Quest.quest_info or {}
			local Bare = type(Uuid) == "string" and Uuid:gsub("[{}]", "") or Uuid
			local AlreadyDone = Done[Uuid] or Done[Bare] or (type(Info.id) == "string" and Done[Info.id])
			if not AlreadyDone and not Info.block_button_completion then
				local Class = Info.quest_class or {}
				local Need = tonumber(Class.amount)
				local Have = tonumber((Quest.quest_progress or {}).amount) or 0
				local Target = Quest.uuid or Uuid
				local Ready
				if Need == nil then
					local IsMeta = Class.class == "daily_complete"
						or (type(Info.id) == "string" and Info.id:find("daily_complete", 1, true) ~= nil)
					Ready = not (IsMeta and DailyIncomplete)
				else
					Ready = Have >= Need
				end
				if Ready and type(Target) == "string" then
					CallWithTimeout(10, InvokeServer, "redeem_quest", Target)
					Attempts = Attempts + 1
					task.wait(0.15)
				end
			end
		end
	end

	if Attempts == 0 then
		return false
	end
	local After = WaitForChange(function()
		return CountEntries(CompletedQuests())
	end, Before, 2)
	if After and After > Before then
		Log("quests: redeemed %d", After - Before)
		return true
	end
	return false
end

-- battlepass (normal lane always, premium lane only when owned)
local function ClaimBattlepass()
	local Data = Profile().battlepass_data
	local Defs = SafeLoad("load_data", "BattlePass")
	if not (type(Data) == "table" and type(Defs) == "table") then
		return false
	end

	local Total = 0
	for Track, Info in pairs(Data) do
		if type(Info) == "table" and type(Defs[Track]) == "table" then
			local Tiers = Defs[Track].tiers or {}
			local Xp = tonumber(Info.xp) or 0
			local ClaimedTiers = Info.claimed_tiers or {}
			local HasPremium = Info.has_premium == true
			local Claimable = {}

			for TierKey, TierDef in pairs(Tiers) do
				local Tier = tonumber(TierKey) or tonumber(TierDef.tier) or tonumber(TierDef.level)
				local Required = tonumber(TierDef.xp_required)
				if Tier and Required and Xp >= Required then
					local NormalOpen = TierDef.normal_reward ~= nil and not IsClaimedTier(ClaimedTiers.normal, Tier)
					local PremiumOpen = HasPremium and TierDef.premium_reward ~= nil
						and not IsClaimedTier(ClaimedTiers.premium, Tier)
					if (NormalOpen or PremiumOpen) then
						Claimable[#Claimable + 1] = Tier
					end
				end
			end
			table.sort(Claimable)

			if #Claimable > 0 then
				local Before = CountEntries(ClaimedTiers)
				for _, Tier in ipairs(Claimable) do
					CallWithTimeout(10, InvokeServer, "claim_battlepass_rewards", Track, Tier)
					task.wait(0.2)
				end
				local After = WaitForChange(function()
					local Live = (Profile().battlepass_data or {})[Track]
					return CountEntries(Live and Live.claimed_tiers)
				end, Before, 2)
				if After and After > Before then
					Log("battlepass %s: claimed %d tier(s)", tostring(Track), After - Before)
					Total = Total + (After - Before)
				end
			end
		end
	end
	return Total > 0
end

local ClaimSteps = {
	{ "daily", ClaimDailyReward },
	{ "missions", ClaimDailyMissions },
	{ "levels", ClaimLevelRewards },
	{ "quests", ClaimQuests },
	{ "battlepass", ClaimBattlepass },
}

local function ClaimAll()
	local Done = {}
	for _, Step in ipairs(ClaimSteps) do
		local Ok, Result = pcall(Step[2])
		if not Ok then
			Log("claim %s error: %s", Step[1], tostring(Result))
		elseif Result then
			Done[#Done + 1] = Step[1]
		end
	end
	if #Done > 0 then
		Log("claimed: %s", table.concat(Done, ", "))
	end
end

-- summon -----------------------------------------------------------------
-- one 10x roll; returns Charged, Results
local function RollTen(BannerId)
	if Config.SkipCutscenes then
		InstallCinematicSkip()
	end
	local Before = HatchCounters()
	local GemsBefore = GetGems()
	-- a timeout does not mean the roll failed: the gems/hatch checks below are
	-- the source of truth, so keep going even when the invoke never returns
	CallWithTimeout(10, InvokeServer, "buy_from_banner", BannerId, "gems10")
	-- the cinematic module may only load once the roll is in flight
	if Config.SkipCutscenes then
		InstallCinematicSkip()
	end

	-- the invoke returns once the server handled it, so check right away and
	-- only then poll (fast) instead of sleeping fixed steps
	local Charged = GetGems() < GemsBefore
	local ChargeDeadline = os.clock() + 3
	while not Charged and os.clock() < ChargeDeadline do
		task.wait(0.03)
		Charged = GetGems() < GemsBefore
	end

	local Results = DiffHatches(Before, HatchCounters())
	local HatchDeadline = os.clock() + Config.SummonHatchWait
	while #Results == 0 and os.clock() < HatchDeadline do
		task.wait(0.03)
		Results = DiffHatches(Before, HatchCounters())
	end
	return Charged, Results
end

local AutoSell -- defined below; sells dupes after every 10x summon

local function SummonTenOnce()
	if State.Summoned then
		return
	end
	local Banner = Banners[Config.SummonBanner]
	if type(Banner) ~= "table" then
		Log("unknown banner %s", tostring(Config.SummonBanner))
		return
	end
	local Cost = (tonumber(Banner.gem_cost) or 50) * 10
	if GetGems() < Cost then
		Log("not enough gems for the first 10x (%d < %d) — will retry next time", GetGems(), Cost)
		return
	end
	local Charged, Results = RollTen(Config.SummonBanner)
	if Charged or #Results > 0 then
		State.Summoned = true
		SaveState()
		Log("first 10x done on %s", Config.SummonBanner)
	else
		Log("first 10x was ignored — will retry next time")
	end
end

NeedHunt = function()
	if State.HuntDone then
		return false
	end
	if #HuntRemaining() == 0 then
		State.HuntDone = true
		SaveState()
		return false
	end
	return GetGems() >= Config.HuntGems
end

local function HuntUnit()
	local Target = HuntRemaining()[1]
	if not Target then
		return false
	end
	local Banner = Banners[Config.HuntBanner]
	local Cost = (type(Banner) == "table" and tonumber(Banner.gem_cost) or 50) * 10
	local BaseHatched = HatchedTotal(Target)
	local Rolls = 0
	local Hatched = {} -- UnitId -> { Normal, Shiny } totals across all rolls
	Log("hunting %s on %s", Target, Config.HuntBanner)

	while Alive() do
		if HasUnit(Target) or HatchedTotal(Target) > BaseHatched then
			State.Hunted[Target] = true
			if #HuntRemaining() == 0 then
				State.HuntDone = true
			end
			SaveState()
			Log("got %s after %d x10 rolls", Target, Rolls)
			if Config.WebhookMode == "all" then
				local Names = {}
				for Id, Counts in pairs(Hatched) do
					local Name = UnitDisplayName(Id)
					if (Counts.Normal or 0) > 0 then
						Name = Name .. " x" .. Counts.Normal
					end
					if (Counts.Shiny or 0) > 0 then
						Name = Name .. " shiny x" .. Counts.Shiny
					end
					Names[#Names + 1] = Name
				end
				table.sort(Names)
				local Drops = #Names > 0 and (" Drops: " .. table.concat(Names, ", ") .. ".") or ""
				SendWebhook("Hunted " .. UnitDisplayName(Target),
					"Got " .. UnitDisplayName(Target) .. " after " .. Rolls .. " x10 rolls." .. Drops, 5763719)
			end
			return true
		end
		if GetGems() - Cost < Config.MinGems then
			Log("hunt stopped: %d gems left, MinGems %d", GetGems(), Config.MinGems)
			return false
		end
		local Charged, Results = RollTen(Config.HuntBanner)
		if Charged then
			Rolls = Rolls + 1
			for _, Entry in ipairs(Results) do
				local Slot = Hatched[Entry.Id] or { Normal = 0, Shiny = 0 }
				Slot.Normal = Slot.Normal + (Entry.Normal or 0)
				Slot.Shiny = Slot.Shiny + (Entry.Shiny or 0)
				Hatched[Entry.Id] = Slot
			end
			if Config.AutoSell then
				AutoSell()
			end
		elseif #Results == 0 then
			task.wait(0.5)
		end
	end
	return false
end

-- team -------------------------------------------------------------------
local function Slots()
	return tonumber(GameplaySettings.NUM_TEAM_SLOTS) or 6
end

-- ordered list of uuids, index = slot
local function BuildTeam()
	local Best = BestCopies()
	local Team, Used = {}, {}
	local Limit = Slots()

	local function Add(UnitId)
		local Copy = Best[UnitId]
		if Copy and not Used[UnitId] and #Team < Limit then
			Used[UnitId] = true
			Team[#Team + 1] = Copy.Uuid
			return true
		end
		return false
	end

	-- Kaitun.Team: equip these units in order, skipping ones you don't own
	local TeamIds = {}
	for _, Id in ipairs(Config.TeamUnits or {}) do
		local Norm = NormalizeUnitId(Id)
		if Norm then
			TeamIds[#TeamIds + 1] = Norm
		end
	end

	if #TeamIds > 0 then
		for _, Id in ipairs(TeamIds) do
			Add(Id)
		end
	end

	-- fill the remaining slots with the strongest units
	local Ranked = {}
	for UnitId, Copy in pairs(Best) do
		if not Used[UnitId] then
			Ranked[#Ranked + 1] = { Id = UnitId, Score = Copy.Score }
		end
	end
	table.sort(Ranked, function(A, B)
		if A.Score ~= B.Score then
			return A.Score > B.Score
		end
		return A.Id < B.Id
	end)
	for _, Entry in ipairs(Ranked) do
		Add(Entry.Id)
	end
	return Team
end

local function SlotUuid(Slot)
	local Equipped = Collection().equipped_units or {}
	local Value = Equipped[Slot] or Equipped[tostring(Slot)]
	return Value and tostring(Value) or nil
end

-- auto-sell ---------------------------------------------------------------
-- keeps locked + equipped units, keeps ONE copy (best score, equipped copy
-- preferred) of each team/compass/hunt unit, sells everything else.
AutoSell = function()
	local Owned = Collection().owned_units
	if type(Owned) ~= "table" then
		return
	end

	local Equipped = {}
	for _, Uuid in pairs(Collection().equipped_units or {}) do
		Equipped[tostring(Uuid)] = true
	end

	-- unit ids that are allowed to keep a copy
	local KeepIds = {}
	local function AddKeep(Id)
		local Norm = Id and NormalizeUnitId(Id)
		if Norm then
			KeepIds[Norm] = true
		end
	end
	AddKeep(Config.CompassUnit)
	for _, Id in ipairs(Config.TeamUnits or {}) do
		AddKeep(Id)
	end
	if not next(KeepIds) then
		-- no explicit team: keep one copy of every equipped unit id
		for Key, Unit in pairs(Owned) do
			if type(Unit) == "table" and type(Unit.unit_id) == "string" then
				local Uuid = type(Unit.uuid) == "string" and Unit.uuid or tostring(Key)
				if Equipped[Uuid] or Equipped[tostring(Key)] then
					KeepIds[Unit.unit_id] = true
				end
			end
		end
	end

	-- unit ids of equipped units (the equipped copy is the keeper)
	local EquippedIds = {}
	for Key, Unit in pairs(Owned) do
		if type(Unit) == "table" and type(Unit.unit_id) == "string" then
			local Uuid = type(Unit.uuid) == "string" and Unit.uuid or tostring(Key)
			if Equipped[Uuid] or Equipped[tostring(Key)] then
				local Norm = NormalizeUnitId(Unit.unit_id)
				if Norm then
					EquippedIds[Norm] = true
				end
			end
		end
	end

	-- group sellable copies by unit id
	local Copies = {}
	for Key, Unit in pairs(Owned) do
		if type(Unit) == "table" and Unit._locked ~= true then
			local Uuid = type(Unit.uuid) == "string" and Unit.uuid or tostring(Key)
			local IsEquipped = Equipped[Uuid] or Equipped[tostring(Key)]
			if not IsEquipped then
				local Id = type(Unit.unit_id) == "string" and Unit.unit_id or nil
				Copies[#Copies + 1] = {
					Uuid = Uuid,
					Id = Id and NormalizeUnitId(Id) or nil,
					Score = ScoreUnit(Unit),
				}
			end
		end
	end

	-- pick the one keeper per keep-id (highest score)
	local Keeper = {}
	for _, Copy in ipairs(Copies) do
		if Copy.Id and KeepIds[Copy.Id] then
			local Current = Keeper[Copy.Id]
			if not Current or Copy.Score > Current.Score then
				Keeper[Copy.Id] = Copy
			end
		end
	end

	local ToSell = {}
	for _, Copy in ipairs(Copies) do
		local KeepThis = Copy.Id and KeepIds[Copy.Id]
			and not EquippedIds[Copy.Id] and Keeper[Copy.Id] == Copy
		-- keep exactly one copy: the equipped one, else the best unequipped
		if not KeepThis then
			ToSell[#ToSell + 1] = Copy.Uuid
		end
	end

	if #ToSell == 0 then
		return
	end
	Log("auto-sell: %d unit(s)", #ToSell)
	for Index = 1, #ToSell, 50 do
		local Batch = {}
		for J = Index, math.min(Index + 49, #ToSell) do
			Batch[#Batch + 1] = ToSell[J]
		end
		CallWithTimeout(10, InvokeServer, "sell_units", Batch)
		task.wait(0.4)
	end
end

local function EquipTeam()
	local Team = BuildTeam()
	if #Team == 0 then
		return
	end
	local Want = {}
	for _, Uuid in ipairs(Team) do
		Want[Uuid] = true
	end

	for Pass = 1, 3 do
		-- drop everything that should not be equipped
		for _, Uuid in pairs(Collection().equipped_units or {}) do
			if not Want[tostring(Uuid)] then
				CallWithTimeout(10, InvokeServer, "unequip_unit", tostring(Uuid))
				task.wait(0.5)
			end
		end
		local AllGood = true
		for Slot, Uuid in ipairs(Team) do
			if SlotUuid(Slot) ~= Uuid then
				AllGood = false
				local Occupant = SlotUuid(Slot)
				if Occupant then
					CallWithTimeout(10, InvokeServer, "unequip_unit", Occupant)
					task.wait(0.5)
				end
				if Pass == 3 then
					CallWithTimeout(10, InvokeServer, "equip_unit", Uuid)
				else
					CallWithTimeout(10, InvokeServer, "equip_unit", Uuid, Slot)
				end
				task.wait(0.5)
			end
		end
		if AllGood then
			break
		end
	end
	Log("team equipped (%d units)", #Team)
	if Config.AutoSell then
		AutoSell()
	end
end

-- joining ----------------------------------------------------------------
local function ClearedLevels()
	local Set = {}
	local Done = (Profile().level_data or {}).completed_story_levels
	if type(Done) == "table" then
		for Id in pairs(Done) do
			Set[tostring(Id)] = true
		end
	end
	return Set
end

-- ordered stage ids of a world (world.levels is a keyed map)
local function StagesOfWorld(WorldId)
	local World = Worlds[WorldId]
	local Stages = {}
	if type(World) == "table" and type(World.levels) == "table" then
		local Keys = {}
		for Key in pairs(World.levels) do
			Keys[#Keys + 1] = Key
		end
		table.sort(Keys, function(A, B)
			return (tonumber(A) or 9999) < (tonumber(B) or 9999)
		end)
		for _, Key in ipairs(Keys) do
			local Entry = World.levels[Key]
			local Id = type(Entry) == "table" and (Entry.id or Entry.level_id) or Entry
			if type(Id) == "string" and Levels[Id] then
				Stages[#Stages + 1] = Id
			end
		end
	end
	return Stages
end

local function FirstWorldId()
	local Order = WorldLevelOrder.WORLD_ORDER
	return Order and Order[1] and tostring(Order[1]) or nil
end

local function InfiniteFirst()
	local WorldId = FirstWorldId()
	local World = WorldId and Worlds[WorldId]
	if type(World) == "table" and type(World.infinite) == "table" then
		local Id = World.infinite.id or World.infinite.level_id
		if type(Id) == "string" then
			return Id
		end
	end
	for _, Id in ipairs(WorldLevelOrder.WORLD_ORDER or {}) do
		local Other = Worlds[tostring(Id)]
		if type(Other) == "table" and type(Other.infinite) == "table" then
			return Other.infinite.id or Other.infinite.level_id
		end
	end
	return nil
end

local function FindOwnedLobby()
	for _, Folder in ipairs(workspace:GetChildren()) do
		if Folder.Name:sub(1, 1) == "_" then
			for _, Model in ipairs(Folder:GetDescendants()) do
				local Owner = Model:FindFirstChild("Owner")
				if Owner and Owner:IsA("ValueBase") then
					local Value = Owner.Value
					local OwnerName = typeof(Value) == "Instance" and Value.Name or tostring(Value)
					if OwnerName == Player.Name then
						return Model
					end
				end
			end
		end
	end
	return nil
end

local LobbyServiceClient = SafeLoad("load_client_service", "LobbyServiceClient")

local function LobbyCandidates(LevelId)
	local StorySet = {}
	local Lobbies = workspace:FindFirstChild("_LOBBIES")
	local Story = Lobbies and Lobbies:FindFirstChild("Story")
	if Story then
		for _, Model in ipairs(Story:GetChildren()) do
			StorySet[Model.Name] = true
		end
	end
	local Candidates = {}
	for Name, Data in pairs((LobbyServiceClient and LobbyServiceClient.more_lobby_params) or {}) do
		local Bound = type(Data) == "table" and type(Data._level_data) == "table" and Data._level_data.id
		local Rank
		if Bound == LevelId then
			Rank = 1
		elseif not Bound and StorySet[Name] then
			Rank = 2
		elseif not Bound then
			Rank = 3
		end
		if Rank then
			Candidates[#Candidates + 1] = { Name = Name, Rank = Rank }
		end
	end
	table.sort(Candidates, function(A, B)
		if A.Rank ~= B.Rank then
			return A.Rank < B.Rank
		end
		return A.Name < B.Name
	end)
	return Candidates
end

local function EnsureLobby(LevelId)
	local Model = FindOwnedLobby()
	if Model then
		return Model
	end
	for _, Candidate in ipairs(LobbyCandidates(LevelId)) do
		local Joined = Invoke("request_join_lobby", Candidate.Name)
		if Joined then
			local Deadline = os.clock() + 8
			repeat
				task.wait(0.25)
				Model = FindOwnedLobby()
				if Model then
					return Model
				end
			until os.clock() >= Deadline
		end
	end
	return nil
end

local function LeaveOwnedLobby()
	local Model = FindOwnedLobby()
	if Model then
		Invoke("request_leave_lobby", Model.Name)
		task.wait(0.5)
	end
end

local function JoinSolo(LevelId, Difficulty, SkipWorld)
	local Lobby = EnsureLobby(LevelId)
	if not Lobby then
		Log("could not claim a lobby")
		return false
	end
	local LobbyId = Lobby.Name
	if LobbyServiceClient then
		LobbyServiceClient.current_lobby = LobbyId
		LobbyServiceClient.current_lobby_model = Lobby
		LobbyServiceClient.selected_level = LevelId
		LobbyServiceClient.difficulty = Difficulty
		LobbyServiceClient.friends_only = false
		LobbyServiceClient.map_item_id = nil
	end
	-- story skipper: the lobby itself jumps to the world's last act
	if SkipWorld then
		local _, Sent = Invoke("lobby_world_skip", SkipWorld)
		if not Sent then
			Log("story skip refused")
			return false, "skip"
		end
		Log("story skip: lobby_world_skip(%s) sent", SkipWorld)
		task.wait(0.5)
	end
	Log("locking %s (%s) in %s", LevelId, Difficulty, LobbyId)
	if not Invoke("request_lock_level", LobbyId, LevelId, false, Difficulty) then
		return false
	end
	if LobbyServiceClient then
		pcall(LobbyServiceClient.on_request_lock_level)
	end
	task.wait(0.5)
	if not Invoke("request_start_game", LobbyId) then
		return false
	end
	return true
end

-- matchmaking (challenges)
local function MatchmakingGui()
	local Gui = PlayerGui:FindFirstChild("MatchmakingUI")
	return Gui and Gui.Enabled == true and Gui or nil
end

local function MatchmakingMap()
	local Gui = MatchmakingGui()
	if not Gui then
		return nil
	end
	for _, Label in ipairs(Gui:GetDescendants()) do
		if Label:IsA("TextLabel") and Label.Name == "Map" then
			return Label.Text
		end
	end
	return nil
end

local ChallengeDefs = {
	Daily = {
		Mode = "Daily",
		LevelId = "__DAILY_CHALLENGE",
		Label = "Daily Challenge",
		MapLabel = "Daily Challenge",
		MinLevel = function()
			return Config.DailyChallengeLevel
		end,
		GetFn = "get_daily_challenge",
	},
	Normal = {
		Mode = "Normal",
		LevelId = "__NORMAL_CHALLENGE",
		Label = "Normal Challenge",
		MapLabel = "Challenge",
		MinLevel = function()
			return Config.NormalChallengeLevel
		end,
		GetFn = "get_normal_challenge",
	},
}
local ChallengeOrder = { "Daily", "Normal" }

local function UuidInProfile(Uuid)
	local Seen = {}
	local function Scan(Table, Depth)
		if type(Table) ~= "table" or Depth > 5 or Seen[Table] then
			return false
		end
		Seen[Table] = true
		for Key, Value in pairs(Table) do
			if Key == Uuid or Value == Uuid then
				return true
			end
			if type(Value) == "table" and Scan(Value, Depth + 1) then
				return true
			end
		end
		return false
	end
	return Scan(Profile(), 0)
end

-- returns Def, Uuid, Reachable
local function PickChallenge(Level)
	local Reachable = false
	for _, Mode in ipairs(ChallengeOrder) do
		local Def = ChallengeDefs[Mode]
		if Level >= Def.MinLevel() then
			local Ok, Data = CallWithTimeout(10, InvokeServer, Def.GetFn)
			if Ok and type(Data) == "table" then
				Reachable = true
				local Uuid = Data.current_uuid and tostring(Data.current_uuid)
				local Cleared = Data.completed == true or Data.cleared == true or Data.already_completed == true
				if Uuid then
					Cleared = Cleared or State.ChallengeDone[Mode] == Uuid
					if Config.TrustProfileForClear then
						Cleared = Cleared or UuidInProfile(Uuid)
					end
				end
				if Uuid and not Cleared then
					return Def, Uuid, true
				end
			end
		end
	end
	return nil, nil, Reachable
end

-- Challenges reset every :00 and :30. The slot number flips at each reset, so
-- "slot changed since I last handled challenges" == "they reset, go check".
-- Server time is used when available (immune to a wrong PC clock).
CurrentSlot = function()
	local Now = os.time()
	local Ok, ServerNow = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	if Ok and tonumber(ServerNow) then
		Now = ServerNow
	end
	return math.floor((Now - Config.ChallengeResetGrace) / Config.ChallengeResetSeconds)
end

-- seconds until the next :00/:30 challenge reset, plus the reset timestamp.
-- resets land on multiples of ChallengeResetSeconds; server time when available
NextResetInfo = function()
	local Now = os.time()
	local Ok, ServerNow = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	if Ok and tonumber(ServerNow) then
		Now = ServerNow
	end
	local Into = Now % Config.ChallengeResetSeconds -- seconds past the last reset
	if Into == 0 then
		Into = Config.ChallengeResetSeconds -- exactly on a reset: next one is a full period away
	end
	return Config.ChallengeResetSeconds - Into, Now + (Config.ChallengeResetSeconds - Into)
end

local function JoinChallenge(Def, Uuid)
	if MatchmakingMap() == Def.MapLabel then
		return true
	end
	if MatchmakingGui() then
		CallWithTimeout(10, InvokeServer, "leave_matchmaking")
		task.wait(0.5)
	end
	LeaveOwnedLobby()
	if LobbyServiceClient then
		pcall(LobbyServiceClient.cancel_selections)
	end

	State.Current = { Kind = Def.Mode, Mode = Def.Mode, Uuid = Uuid }
	SaveState()

	for Attempt = 1, Config.MatchmakingRetries do
		Log("requesting %s (%d/%d)", Def.Label, Attempt, Config.MatchmakingRetries)
		CallWithTimeout(10, InvokeServer, "request_matchmaking", Def.LevelId)
		local Deadline = os.clock() + 4
		repeat
			if MatchmakingMap() == Def.MapLabel then
				Log("queued for %s", Def.Label)
				return true
			end
			task.wait(0.2)
		until os.clock() >= Deadline
		if Attempt < Config.MatchmakingRetries then
			task.wait(Config.MatchmakingRetryWait)
		end
	end
	return false
end

-- planner ----------------------------------------------------------------
local function JoinStoryLoop()
	local Stages = StagesOfWorld(FirstWorldId())
	local Stage = Stages[Config.StoryAct] or Stages[1]
	if not Stage then
		Log("no story stage found")
		return false
	end
	State.Current = { Kind = "Story1", LevelId = Stage }
	SaveState()
	return JoinSolo(Stage, "Normal")
end

-- story skipper target: world + act (nil act = last act of the world)
local function StorySkipTarget()
	local WorldId = Config.SkipWorld and tostring(Config.SkipWorld) or FirstWorldId()
	if not WorldId then
		return nil
	end
	local Acts = StagesOfWorld(WorldId)
	if #Acts == 0 then
		return nil
	end
	local Act = math.floor(tonumber(Config.SkipAct) or #Acts)
	Act = math.max(1, math.min(#Acts, Act))
	return Acts[Act], WorldId, Act, #Acts, Acts
end

local function JoinAct6()
	local Target, WorldId, Act, Count, Acts = StorySkipTarget()
	if not Target then
		return false
	end
	local Cleared = ClearedLevels()
	if Cleared[Target] then
		return nil
	end

	local SkipWorld = Config.SkipStory and WorldId or nil
	Log("story target: %s act %d/%d (%s)%s", WorldId, Act, Count, Target, SkipWorld and " [skipper]" or "")

	State.Current = { Kind = "Act6", LevelId = Target }
	SaveState()
	local Ok = JoinSolo(Target, "Normal", SkipWorld)
	if Ok then
		return true
	end

	-- skip refused (or the act is locked): play the first uncleared act instead,
	-- clear it, and the next visit moves on to the following act until the target
	for _, Id in ipairs(Acts) do
		if not Cleared[Id] then
			if Id ~= Target or SkipWorld then
				Log("no skip -> playing first uncleared act %s", Id)
				State.Current = { Kind = "Act6", LevelId = Id }
				SaveState()
				return JoinSolo(Id, "Normal")
			end
			break
		end
	end
	return false
end

local function JoinInfiniteLoop()
	local Id = InfiniteFirst()
	if not Id then
		Log("no infinite stage found, falling back to story")
		return JoinStoryLoop()
	end
	State.Current = { Kind = "Infinite", LevelId = Id }
	SaveState()
	return JoinSolo(Id, "Hard")
end

-- one planning step; returns true when a join request went out
local function Plan()
	local Level = GetLevel()
	Log("level %d | gems %d | hunt %s", Level, GetGems(), State.HuntDone and "done" or "pending")

	if NeedHunt() then
		if HuntUnit() then
			EquipTeam()
		end
	end

	local Slot = CurrentSlot()
	local Def, Uuid, Reachable = PickChallenge(Level)
	if Reachable then
		State.ChallengeSlot = Slot
		SaveState()
	end
	if Def then
		Log("%s available (%s)", Def.Label, tostring(Uuid))
		return JoinChallenge(Def, Uuid)
	end

	if Level < Config.EndgameLevel then
		return JoinStoryLoop()
	end

	-- one attempt at act 6; if it is cleared or fails, move on to infinite
	if JoinAct6() == true then
		return true
	end

	-- challenges-only: once the compass unit is actually summoned/owned, never
	-- join infinite — story still runs until EndgameLevel so low-level
	-- accounts keep progressing (using the compass item alone does not count)
	if Config.ChallengesOnlyAfterCompass and HasUnit(Config.CompassUnit) then
		return false
	end
	return JoinInfiniteLoop()
end

-- lobby status widget -------------------------------------------------------
-- compact card showing the script is alive: current activity, level/gems,
-- countdown to the next challenge reset, and an indeterminate progress bar
local function StartLobbyWidget()
	local Old = PlayerGui:FindFirstChild("AAKaitunLobby")
	if Old then
		Old:Destroy()
	end
	local Tween = game:GetService("TweenService")

	local Gui = Instance.new("ScreenGui")
	Gui.Name = "AAKaitunLobby"
	Gui.ResetOnSpawn = false
	Gui.IgnoreGuiInset = true
	Gui.DisplayOrder = 900
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
	}, Card)
	New("UICorner", { CornerRadius = UDim.new(0, 4) }, Track)
	local Fill = New("Frame", {
		Size = UDim2.fromOffset(60, 1),
		Position = UDim2.fromOffset(-60, 0),
		BackgroundColor3 = Color3.fromRGB(110, 150, 255),
		BorderSizePixel = 0,
	}, Track)
	New("UICorner", { CornerRadius = UDim.new(0, 4) }, Fill)

	-- slide the bar back and forth forever
	task.spawn(function()
		while Alive() do
			local TrackW = Track.AbsoluteSize.X
			if TrackW > 0 then
				Fill.Size = UDim2.fromOffset(math.min(60, TrackW * 0.4), 1)
				Tween:Create(Fill, TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
					Position = UDim2.fromOffset(TrackW - Fill.Size.X.Offset, 0),
				}):Play()
				task.wait(1.15)
				Tween:Create(Fill, TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
					Position = UDim2.fromOffset(-Fill.Size.X.Offset, 0),
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
		Status.Text = "Working - " .. activity
		local Left = select(1, NextResetInfo())
		local Mm = math.floor(Left / 60)
		local Ss = math.floor(Left % 60)
		Sub.Text = ("Lv %d  -  gems %s  -  next challenges %d:%02d"):format(
			GetLevel(), tostring(GetGems()), Mm, Ss)
	end

	task.spawn(function()
		while Alive() do
			pcall(Refresh)
			task.wait(1)
		end
	end)
	Refresh()
	Log("lobby widget on")
end

RunLobby = function()
	Log("lobby mode")
	if Config.StatsOverlay then
		StartLobbyWidget()
	end
	GroupAndFavorite()
	RedeemCodes()
	UseCompass()
	ClaimAll()
	SummonTenOnce()
	EquipTeam()

	while Alive() and Loader.IsLobby do
		local Ok, Requested = pcall(Plan)
		if not Ok then
			Log("plan error: %s", tostring(Requested))
			Requested = nil
		end

		-- wait for the teleport. A matchmaking queue gets QueueTimeout (5 min);
		-- a plain join gets JoinTimeout; when Plan requested nothing (idle,
		-- challenges-only, failed join) re-plan after IdleWait instead of
		-- sitting out the full timeout
		local Started = os.clock()
		while Alive() and Loader.IsLobby do
			task.wait(1)
			local Limit = Requested
				and (MatchmakingGui() and Config.QueueTimeout or Config.JoinTimeout)
				or Config.IdleWait
			if os.clock() - Started >= Limit then
				break
			end
		end
		if Alive() and MatchmakingGui() then
			Log("queued too long (%ds) -> leaving matchmaking, retrying in %ds", math.floor(os.clock() - Started), Config.MatchmakingRetryWait)
			CallWithTimeout(10, InvokeServer, "leave_matchmaking")
			task.wait(Config.MatchmakingRetryWait)
		end
	end
end
end -- end lobby scope block

-- ============================================================ MATCH =====
-- scope block: frees the match locals before Main() so the chunk stays
-- under Luau's 200-local limit; RunInGame is exported for Main below
local RunInGame
do
local Placer = {
	Nodes = {},
	Used = {},
	LastAttempt = {},
	UpgradeFail = {},
	Fails = 0,
	NeedScan = true,
	ScanTries = 0,
	LastScan = 0,
	LastWarn = 0,
	ModelIds = setmetatable({}, { __mode = "k" }),
	Core = nil,
	Paths = nil,
	Grid = nil,
}

-- a node that has a unit on it (ours or anyone's) or that failed twice is
-- retired for good: never picked again and its visual dot is removed
function Placer.Retire(Node)
	Placer.Used[Node] = true
	if Node.Dot then
		Node.Dot:Destroy()
		Node.Dot = nil
	end
end

local ProbeSize = Vector3.new(0.05, 2.7, 0.05)
local RayHeight = 80
local LedgeDrop = 1.5
local HybridDef = { hybrid_placement = true }

local function GetPvePaths()
	local Paths = {}
	local Cache = Placer.Paths.PATH_CACHE
	if type(Cache) ~= "table" then
		return Paths
	end
	local function Collect(OnlyPve)
		for Base, Lanes in pairs(Cache) do
			if type(Lanes) == "table" and (not OnlyPve or tostring(Base) == "pve") then
				for Lane, Path in pairs(Lanes) do
					if type(Path) == "table" and type(Path.points) == "table" and Path.total_distance then
						Paths[#Paths + 1] = { Lane = Lane, Points = Path.points, Total = Path.total_distance }
					end
				end
			end
		end
	end
	Collect(true)
	if #Paths == 0 then
		Collect(false)
	end
	return Paths
end

local function PointAtDistance(Points, Distance)
	local Previous = Points[1]
	for Index = 2, #Points do
		local Point = Points[Index]
		if Point.distance_from_spawn >= Distance then
			local Span = Point.distance_from_spawn - Previous.distance_from_spawn
			local T = Span > 0 and math.clamp((Distance - Previous.distance_from_spawn) / Span, 0, 1) or 0
			return Previous.position:Lerp(Point.position, T)
		end
		Previous = Point
	end
	return Points[#Points].position
end

local function TerrainKind(Hit)
	local Core = Placer.Core
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

local function DistToRoadPart(Position, Part)
	local LocalPos = Part.CFrame:PointToObjectSpace(Position)
	local Half = Part.Size / 2
	local Closest = Part.CFrame:PointToWorldSpace(Vector3.new(
		math.clamp(LocalPos.X, -Half.X, Half.X),
		math.clamp(LocalPos.Y, -Half.Y, Half.Y),
		math.clamp(LocalPos.Z, -Half.Z, Half.Z)
	))
	local Dx, Dz = Closest.X - Position.X, Closest.Z - Position.Z
	return math.sqrt(Dx * Dx + Dz * Dz)
end

local function NearRoad(Position, RoadParts)
	for _, Part in ipairs(RoadParts) do
		if DistToRoadPart(Position, Part) <= 0.01 then
			return true
		end
	end
	return false
end

local function ValidateNodes(Nodes)
	if #Nodes == 0 then
		return
	end
	local Bounds = ReplicatedStorage:FindFirstChild("_bounds")
	local Ignore = workspace:FindFirstChild("ignore")
	local Road = workspace:FindFirstChild("_road")
	local UnitsFolder = workspace:FindFirstChild("_UNITS")
	local Dead = workspace:FindFirstChild("_DEAD_UNITS")

	local Moved = false
	if Bounds and Ignore and Bounds.Parent ~= Ignore then
		Bounds.Parent = Ignore
		Moved = true
	end

	local Restored = {}
	local function EnableQuery(Root, OnlyHitbox)
		for _, Part in ipairs(Root:GetDescendants()) do
			if Part:IsA("BasePart") and (not OnlyHitbox or Part.Name == "_hitbox") and not Part.CanQuery then
				Part.CanQuery = true
				Restored[#Restored + 1] = Part
			end
		end
	end
	if Bounds then
		EnableQuery(Bounds, false)
	end
	if UnitsFolder then
		EnableQuery(UnitsFolder, true)
	end
	if Dead then
		EnableQuery(Dead, true)
	end

	local Probe = Instance.new("Part")
	Probe.Name = "AA_PlaceProbe"
	Probe.Anchored = true
	Probe.CanCollide = false
	Probe.CanQuery = true
	Probe.CanTouch = false
	Probe.Transparency = 1
	Probe.Size = ProbeSize
	Probe.CFrame = CFrame.new(0, -1000, 0)
	Probe.Parent = workspace

	local Overlap = OverlapParams.new()
	Overlap.FilterType = Enum.RaycastFilterType.Include
	local Filter = {}
	for _, Item in ipairs({ Bounds, Road, UnitsFolder, Dead }) do
		if Item then
			Filter[#Filter + 1] = Item
		end
	end
	Overlap.FilterDescendantsInstances = Filter

	local Offset = Vector3.new(0, ProbeSize.Y / 2 + 0.1, 0)
	for _, Node in ipairs(Nodes) do
		Probe.CFrame = CFrame.new(Node.Position + Offset)
		Node.Valid = true
		for _, Touched in ipairs(workspace:GetPartsInPart(Probe, Overlap)) do
			local Invalid = false
			if Touched.Name == "_hitbox" and Touched.Parent and Touched.Parent.Parent
				and (Touched.Parent.Parent == UnitsFolder or Touched.Parent.Parent == Dead)
				and CollectionService:HasTag(Touched.Parent, "player_units") then
				Invalid = true
			elseif (Road and Touched:IsDescendantOf(Road)) or (Bounds and Touched:IsDescendantOf(Bounds)) then
				Invalid = true
			end
			if Invalid then
				Node.Valid = false
				break
			end
		end
	end

	Probe:Destroy()
	for _, Part in ipairs(Restored) do
		Part.CanQuery = false
	end
	if Moved and Bounds then
		Bounds.Parent = ReplicatedStorage
	end
end

local LedgeOffsets = {}
for _, Radius in ipairs({ 1.5, 3 }) do
	for Index = 0, 7 do
		local Angle = Index * math.pi / 4
		LedgeOffsets[#LedgeOffsets + 1] = Vector3.new(math.cos(Angle) * Radius, 0, math.sin(Angle) * Radius)
	end
end

local function MarkLedges(Nodes)
	for _, Node in ipairs(Nodes) do
		if Node.Kind ~= "hill" and Node.Valid then
			for _, Offset in ipairs(LedgeOffsets) do
				local Origin = Node.Position + Offset + Vector3.new(0, RayHeight, 0)
				local Hit = Placer.Core.raycast(Origin, Vector3.new(0, -RayHeight * 2, 0))
				local HitPos = Hit and Hit.Position
				if not HitPos or Node.Position.Y - HitPos.Y > LedgeDrop then
					Node.Valid = false
					break
				end
			end
		end
	end
end

local function ScanCircle(Center, FaceTarget, RoadParts)
	local Nodes = {}
	local FarmOuter = Config.RadiusGround + Config.RadiusFarm
	local MaxRadius = math.max(Config.RadiusGround, Config.RadiusHill, FarmOuter)
	for Gx = -MaxRadius, MaxRadius, Config.NodeSpacing do
		for Gz = -MaxRadius, MaxRadius, Config.NodeSpacing do
			local D2 = Gx * Gx + Gz * Gz
			if D2 <= MaxRadius * MaxRadius then
				local Origin = Center + Vector3.new(Gx, RayHeight, Gz)
				local Hit = Placer.Core.raycast(Origin, Vector3.new(0, -RayHeight * 2, 0))
				local Instance_ = Hit and Hit.Instance
				local Kind = TerrainKind(Instance_)
				local NodeRadius = Kind == "hill" and Config.RadiusHill or Config.RadiusGround
				local KindOk = D2 <= NodeRadius * NodeRadius
				local FarmZone = Kind == "ground"
					and D2 > Config.RadiusGround * Config.RadiusGround
					and D2 <= FarmOuter * FarmOuter
				if Kind and (KindOk or FarmZone)
					and Placer.Core.is_valid_raycast_hit(Instance_, HybridDef)
					and not NearRoad(Hit.Position, RoadParts) then
					Nodes[#Nodes + 1] = {
						Kind = Kind,
						Valid = true,
						KindOk = KindOk,
						FarmZone = FarmZone,
						Gx = Gx,
						Gz = Gz,
						Position = Hit.Position,
						CFrame = CFrame.lookAt(
							Hit.Position + Vector3.new(0, 0.5, 0),
							Vector3.new(FaceTarget.X, Hit.Position.Y, FaceTarget.Z)
						),
					}
				end
			end
		end
	end
	return Nodes
end

-- visuals (ported from auto_place.lua / scan_placement.lua) ---------------
local VisualKindColors = {
	ground = Color3.fromRGB(0, 255, 80),
	hill = Color3.fromRGB(255, 170, 0),
}
local VisualBlockedColor = Color3.fromRGB(255, 60, 60)
local VisualRingColor = Color3.fromRGB(255, 255, 255)
local VisualFarmRingColor = Color3.fromRGB(190, 80, 255)
local VisualFarmNodeColor = Color3.fromRGB(230, 90, 0)
local VisualRingSegments = 64
local VisualRootName = "AA_Kaitun"

local function ClearScanVisuals()
	local Old = workspace:FindFirstChild(VisualRootName)
	if Old then
		Old:Destroy()
	end
end

local function MakeVisualPart(Props)
	local Part = Instance.new("Part")
	Part.Anchored = true
	Part.CanCollide = false
	Part.CanQuery = false
	Part.CanTouch = false
	Part.CastShadow = false
	Part.Material = Enum.Material.Neon
	for Key, Value in pairs(Props) do
		Part[Key] = Value
	end
	return Part
end

local function AddVisualHighlight(Folder, Color, FillTrans, OutlineTrans)
	local Highlight = Instance.new("Highlight")
	Highlight.FillColor = Color
	Highlight.OutlineColor = Color
	Highlight.FillTransparency = FillTrans or 0.45
	Highlight.OutlineTransparency = OutlineTrans or 0.2
	Highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	Highlight.Parent = Folder
end

local function VisualizeScan(Lanes)
	if not Config.ShowVisuals then
		return
	end
	ClearScanVisuals()
	local Root = Instance.new("Folder")
	Root.Name = VisualRootName

	local ValidGround = Instance.new("Folder")
	ValidGround.Name = "ValidGround"
	local ValidHill = Instance.new("Folder")
	ValidHill.Name = "ValidHill"
	local ValidFarm = Instance.new("Folder")
	ValidFarm.Name = "ValidFarm"
	local BlockedFolder = Instance.new("Folder")
	BlockedFolder.Name = "Blocked"
	local RingFolder = Instance.new("Folder")
	RingFolder.Name = "Ring"
	for _, Folder in ipairs({ ValidGround, ValidHill, ValidFarm, BlockedFolder, RingFolder }) do
		Folder.Parent = Root
	end
	AddVisualHighlight(ValidGround, VisualKindColors.ground)
	AddVisualHighlight(ValidHill, VisualKindColors.hill)
	AddVisualHighlight(ValidFarm, VisualFarmNodeColor)
	AddVisualHighlight(BlockedFolder, VisualBlockedColor)
	AddVisualHighlight(RingFolder, VisualRingColor, 0.15, 0)

	for _, Lane in ipairs(Lanes) do
		local Center = Lane.Center
		local RingY = Center.Y + 1.2

		local Rings = {
			{ Radius = Config.RadiusGround, Color = VisualRingColor },
		}
		if Config.RadiusHill ~= Config.RadiusGround then
			Rings[#Rings + 1] = { Radius = Config.RadiusHill, Color = VisualKindColors.hill }
		end
		local FarmRingDrawn = false
		for _, Ring in ipairs(Rings) do
			if math.abs(Ring.Radius - Config.RadiusFarm) < 0.01 then
				FarmRingDrawn = true
			end
		end
		if not FarmRingDrawn and Config.RadiusFarm > Config.RadiusGround then
			Rings[#Rings + 1] = { Radius = Config.RadiusFarm, Color = VisualFarmRingColor }
		end
		for _, Ring in ipairs(Rings) do
			for I = 0, VisualRingSegments - 1 do
				local Angle = (I / VisualRingSegments) * math.pi * 2
				local SegLen = (2 * math.pi * Ring.Radius / VisualRingSegments) * 1.15
				local Segment = MakeVisualPart({
					Size = Vector3.new(0.15, 0.15, SegLen),
					CFrame = CFrame.new(
						Center.X + math.cos(Angle) * Ring.Radius,
						RingY,
						Center.Z + math.sin(Angle) * Ring.Radius
					) * CFrame.Angles(0, -Angle, 0),
					Color = Ring.Color,
					Transparency = 0.1,
				})
				Segment.Parent = RingFolder
			end
		end

		for _, Node in ipairs(Lane.Nodes) do
			local Folder
			local Color
			local Transparency
			if Node.Valid then
				if Node.FarmZone then
					Folder = ValidFarm
					Color = VisualFarmNodeColor
				else
					Folder = Node.Kind == "hill" and ValidHill or ValidGround
					Color = VisualKindColors[Node.Kind] or VisualKindColors.ground
				end
				Transparency = 0.55
			else
				Folder = BlockedFolder
				Color = VisualBlockedColor
				Transparency = 0.7
			end
			local Dot = MakeVisualPart({
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(0.15, 0.55, 0.55),
				CFrame = CFrame.new(Node.Position + Vector3.new(0, 0.45, 0)) * CFrame.Angles(0, 0, math.rad(90)),
				Color = Color,
				Transparency = Transparency,
			})
			Dot.Parent = Folder
			Node.Dot = Dot
		end

		-- center marker: floating billboard arrow, same images as _UnitPointer
		local ArrowColor = Color3.fromRGB(80, 220, 255)
		local Anchor = Instance.new("Part")
		Anchor.Name = "AA_ScanArrow"
		Anchor.Anchored = true
		Anchor.CanCollide = false
		Anchor.CanQuery = false
		Anchor.CanTouch = false
		Anchor.CastShadow = false
		Anchor.Transparency = 1
		Anchor.Size = Vector3.new(1, 1, 1)
		Anchor.CFrame = CFrame.new(Center.X, Center.Y + 9, Center.Z)
		Anchor.Parent = Root
		local Billboard = Instance.new("BillboardGui")
		Billboard.Size = UDim2.fromOffset(100, 100)
		Billboard.AlwaysOnTop = true
		Billboard.LightInfluence = 0
		Billboard.MaxDistance = math.huge
		Billboard.Parent = Anchor
		local Glow = Instance.new("ImageLabel")
		Glow.BackgroundTransparency = 1
		Glow.Image = "rbxassetid://81351645241261"
		Glow.ImageTransparency = 0.55
		Glow.ImageColor3 = ArrowColor
		Glow.AnchorPoint = Vector2.new(0.5, 0.5)
		Glow.Position = UDim2.fromScale(0.5, 0.5)
		Glow.Size = UDim2.fromScale(1, 1)
		Glow.Parent = Billboard
		local Arrow = Instance.new("ImageLabel")
		Arrow.BackgroundTransparency = 1
		Arrow.Image = "rbxassetid://81256616982657"
		Arrow.ImageTransparency = 0.35
		Arrow.ImageColor3 = ArrowColor
		Arrow.AnchorPoint = Vector2.new(0.5, 0.5)
		Arrow.Position = UDim2.fromScale(0.5, 0.5)
		Arrow.Size = UDim2.fromScale(0.31, 0.31)
		Arrow.Rotation = 180
		Arrow.Parent = Billboard

		local GlowStuds = 5
		local Camera = workspace.CurrentCamera
		local BaseY = Center.Y + 1.5
		local T0 = os.clock()
		local Connection
		Connection = game:GetService("RunService").Heartbeat:Connect(function()
			if not Anchor.Parent then
				Connection:Disconnect()
				return
			end
			local Bob = math.sin((os.clock() - T0) * 3) * 0.5
			Anchor.CFrame = CFrame.new(Center.X, BaseY + Bob, Center.Z)
			local Distance = (Camera.CFrame.Position - Anchor.Position).Magnitude
			local PxPerStud = Camera.ViewportSize.Y / (2 * math.tan(math.rad(Camera.FieldOfView) / 2) * math.max(Distance, 1))
			Billboard.Size = UDim2.fromOffset(GlowStuds * PxPerStud, GlowStuds * PxPerStud)
		end)
	end

	Root.Parent = workspace
	return Root
end

local function Rescan()
	local RoadParts = {}
	local Road = workspace:FindFirstChild("_road")
	if Road then
		for _, Part in ipairs(Road:GetDescendants()) do
			if Part:IsA("BasePart") then
				RoadParts[#RoadParts + 1] = Part
			end
		end
	end
	local Paths = GetPvePaths()
	local PathPoints = {}
	for _, Path in ipairs(Paths) do
		for _, Point in ipairs(Path.Points) do
			PathPoints[#PathPoints + 1] = Point.position
		end
	end

	local All = {}
	local Lanes = {}
	for _, Path in ipairs(Paths) do
		local Distance = Path.Total * math.clamp(Config.Percent, 0, 100) / 100
		local Center = PointAtDistance(Path.Points, Distance)
		local EnemyDir = PointAtDistance(Path.Points, math.max(0, Distance - 15))
		local Nodes = ScanCircle(Center, EnemyDir, RoadParts)
		ValidateNodes(Nodes)
		MarkLedges(Nodes)
		local LaneNodes = {}
		for _, Node in ipairs(Nodes) do
			local Best = math.huge
			for _, Point in ipairs(PathPoints) do
				local Dx, Dy, Dz = Node.Position.X - Point.X, Node.Position.Y - Point.Y, Node.Position.Z - Point.Z
				local D2 = Dx * Dx + Dy * Dy + Dz * Dz
				if D2 < Best then
					Best = D2
				end
			end
			Node.PathDist = math.sqrt(Best)
			Node.BaseValid = Node.Valid
			All[#All + 1] = Node
			LaneNodes[#LaneNodes + 1] = Node
		end
		Lanes[#Lanes + 1] = { Center = Center, Nodes = LaneNodes }
	end
	Placer.Nodes = All
	Placer.Lanes = Lanes
	Placer.Used = {}
	Placer.LastAttempt = {}
	Placer.UpgradeFail = {}
	Log("placement scan: %d nodes", #All)
	if #All > 0 then
		VisualizeScan(Lanes)
	end
	return #All
end

-- unit classification
local function IsFarmUnit(UnitId)
	local Def = Units[UnitId]
	if type(Def) ~= "table" then
		return false
	end
	if Def.farm_amount ~= nil or Def.farm == true or type(Def.farm) == "number" then
		return true
	end
	if type(Def.end_of_wave) == "table" then
		for _, Value in pairs(Def.end_of_wave) do
			if type(Value) == "table" and Value.farm_amount then
				return true
			end
		end
	end
	return false
end

local BuffCache = {}
local function IsBuffUnit(UnitId)
	if BuffCache[UnitId] == nil then
		local Def = Units[UnitId]
		BuffCache[UnitId] = type(Def) == "table"
			and (Def.buff or Def.buffs or Def.aura or Def.support or Def.team_buff or DefMentions(Def, "buff")) and true or false
	end
	return BuffCache[UnitId]
end

local function TerrainForUnit(UnitId)
	local Def = Units[UnitId]
	if type(Def) == "table" and Def.hill_unit == true then
		return "hill"
	end
	return "ground"
end

local function SpawnCap(UnitId)
	local Def = Units[UnitId]
	if type(Def) ~= "table" then
		return 5
	end
	return tonumber(Def.spawn_cap) or tonumber(Def.max_spawn_units) or 5
end

local function UnitCost(UnitId)
	local Def = Units[UnitId]
	return type(Def) == "table" and type(Def.cost) == "number" and Def.cost or 0
end

local function StatValue(Model, Name)
	local Stats = Model:FindFirstChild("_stats")
	local Value = Stats and Stats:FindFirstChild(Name)
	if Value and Value:IsA("ValueBase") then
		return Value.Value
	end
	return nil
end

local function NextUpgradeCost(UnitId, Level)
	local Def = Units[UnitId]
	if type(Def) ~= "table" or type(Def.upgrade) ~= "table" or Level == nil then
		return nil
	end
	local Entry = Def.upgrade[Level + 1] or Def.upgrade[tostring(Level + 1)]
	if type(Entry) ~= "table" then
		return nil
	end
	return tonumber(Entry.cost) or 0
end

local function GetMoney()
	local Stats = Player:FindFirstChild("_stats")
	local Value = Stats and Stats:FindFirstChild("resource")
	return Value and Value:IsA("ValueBase") and Value.Value or nil
end

local function GetWave()
	local Value = workspace:FindFirstChild("_wave_num")
	return Value and Value:IsA("ValueBase") and Value.Value or nil
end

local function EquippedUuids()
	local List = {}
	for Slot, Uuid in pairs(Collection().equipped_units or {}) do
		if type(Uuid) == "string" then
			List[#List + 1] = { Uuid = Uuid, Slot = tonumber(Slot) or 999 }
		end
	end
	table.sort(List, function(A, B)
		return A.Slot < B.Slot
	end)
	local Out = {}
	for _, Entry in ipairs(List) do
		Out[#Out + 1] = Entry.Uuid
	end
	return Out
end

local function UnitIdForUuid(Uuid)
	local Owned = Collection().owned_units or {}
	local Unit = Owned[Uuid] or Owned[tostring(Uuid)]
	return type(Unit) == "table" and Unit.unit_id or nil
end

local function PlayerUnitModels()
	local Out, Seen = {}, {}
	local Equipped = {}
	for _, Uuid in ipairs(EquippedUuids()) do
		Equipped[Uuid] = true
	end
	local function Add(Model)
		if Model:IsA("Model") and Model:IsDescendantOf(workspace) and not Seen[Model] then
			local Stats = Model:FindFirstChild("_stats")
			local Parent = Stats and Stats:FindFirstChild("parent_unit")
			local Summoned = Parent and Parent:IsA("ObjectValue") and Parent.Value ~= nil
			if not Summoned then
				Seen[Model] = true
				Out[#Out + 1] = Model
			end
		end
	end
	for _, Model in ipairs(CollectionService:GetTagged("player_units")) do
		Add(Model)
	end
	local Folder = workspace:FindFirstChild("_UNITS")
	if Folder then
		for _, Model in ipairs(Folder:GetChildren()) do
			local Uuid = StatValue(Model, "uuid")
			if Uuid and Equipped[tostring(Uuid)] then
				Add(Model)
			end
		end
	end
	return Out
end

local function ModelUnitId(Model)
	local Cached = Placer.ModelIds[Model]
	if Cached ~= nil then
		return Cached ~= false and Cached or nil
	end
	local Id
	local Uuid = StatValue(Model, "uuid")
	if Uuid then
		Id = UnitIdForUuid(tostring(Uuid))
	end
	if not Id then
		local Raw = StatValue(Model, "id")
		if Raw and Units[Raw] then
			Id = Raw
		end
	end
	if not Id and Units[Model.Name] then
		Id = Model.Name
	end
	-- only cache a hit; stats may not be replicated yet on a fresh model
	if Id then
		Placer.ModelIds[Model] = Id
	end
	return Id
end

local function PickNode(Pool, Farm, PreferPath)
	local Best, BestScore
	for _, Node in ipairs(Pool) do
		local ZoneOk
		if Farm then
			ZoneOk = Node.FarmZone
		else
			ZoneOk = Node.KindOk
		end
		if Node.Valid and not Node.Bad and not Placer.Used[Node] and ZoneOk then
			local Score = Node.Gx * Node.Gx + Node.Gz * Node.Gz
			if PreferPath then
				Score = Score * 1000 + Node.PathDist
			end
			if not BestScore or Score < BestScore then
				Best, BestScore = Node, Score
			end
		end
	end
	return Best
end

local function NodesFor(UnitId)
	local Farm = IsFarmUnit(UnitId)
	local Terrain = Farm and Config.FarmTerrain or TerrainForUnit(UnitId)
	local Pool = {}
	for _, Node in ipairs(Placer.Nodes) do
		if Node.BaseValid and (Terrain == "any" or Node.Kind == Terrain) then
			Pool[#Pool + 1] = Node
		end
	end
	return Pool, Farm, (not Farm) and Terrain == "hill"
end

-- nearest scanned node to a world position (used or not), no spacing radius:
-- a unit only ever occupies the single node it stands on
function Placer.NearestNode(Position)
	local Limit = Config.NodeSpacing * Config.NodeSpacing
	local Best, BestD
	for _, Node in ipairs(Placer.Nodes) do
		local Dx, Dz = Node.Position.X - Position.X, Node.Position.Z - Position.Z
		local D = Dx * Dx + Dz * Dz
		if D <= Limit and (not BestD or D < BestD) then
			Best, BestD = Node, D
		end
	end
	return Best
end

-- every unit in the match (ours AND other players') retires the node under it
function Placer.RefreshOccupied()
	local Seen = {}
	local function Check(Model)
		if Model and not Seen[Model] and Model:IsA("Model") and Model:IsDescendantOf(workspace) then
			Seen[Model] = true
			local Ok, Pivot = pcall(function()
				return Model:GetPivot()
			end)
			if Ok then
				local Node = Placer.NearestNode(Pivot.Position)
				if Node and not Placer.Used[Node] then
					Placer.Retire(Node)
				end
			end
		end
	end
	local Folder = workspace:FindFirstChild("_UNITS")
	if Folder then
		for _, Model in ipairs(Folder:GetChildren()) do
			Check(Model)
		end
	end
	for _, Model in ipairs(CollectionService:GetTagged("player_units")) do
		Check(Model)
	end
end

-- returns Placed, Reason ("nonode" = no free node, "occupied" = retry another)
function Placer.PlaceOnce(Uuid, UnitId)
	Placer.RefreshOccupied()
	local Pool, Farm, PreferPath = NodesFor(UnitId)
	local Node = PickNode(Pool, Farm, PreferPath)
	if not Node then
		return false, "nonode"
	end
	local Cf = Node.CFrame
	if Placer.Grid and Placer.Grid.get_closest_grid_point then
		local Ok, Snapped = pcall(Placer.Grid.get_closest_grid_point, Cf)
		if Ok and typeof(Snapped) == "CFrame" then
			Cf = Snapped
		end
	end
	-- the grid snap can land on a node that already has a unit
	local Landing = Placer.NearestNode(Cf.Position)
	if Landing and Landing ~= Node and Placer.Used[Landing] then
		Placer.Retire(Node)
		return false, "occupied"
	end

	local Before = #PlayerUnitModels()
	local Ok, Result = CallWithTimeout(10, InvokeServer, "spawn_unit", Uuid, Cf)
	if not (Ok and Result) then
		-- a node only becomes permanently bad after failing twice
		Node.Fails = (Node.Fails or 0) + 1
		if Node.Fails >= 2 then
			Node.Bad = true
			Placer.Retire(Node)
		end
		return false, "server"
	end
	-- the server accepted it; give the model a moment to replicate
	local Deadline = os.clock() + 2
	repeat
		task.wait(0.1)
	until #PlayerUnitModels() > Before or os.clock() >= Deadline
	Placer.Retire(Node)
	if Landing then
		Placer.Retire(Landing)
	end
	Log("placed %s", UnitId)
	return true
end

local function TryPlace(Uuid, UnitId)
	for _ = 1, 8 do
		local Placed, Reason = Placer.PlaceOnce(Uuid, UnitId)
		if Reason ~= "occupied" then
			return Placed, Reason
		end
	end
	return false, "nonode"
end

-- (re)scan until nodes exist: the path cache can still be empty right when a
-- match starts, and a failed run of placements also triggers a fresh scan
local function EnsureScan()
	local Missing = Placer.NeedScan or #Placer.Nodes == 0
	local TooManyFails = Placer.Fails >= Config.RescanAfterFails
	if not Missing and not TooManyFails then
		return
	end
	local Wait = 15
	if Missing then
		Wait = Placer.ScanTries < 15 and 2 or 10
	end
	if os.clock() - Placer.LastScan < Wait then
		return
	end
	Placer.LastScan = os.clock()
	Placer.ScanTries = Placer.ScanTries + 1
	Placer.Fails = 0
	local Ok, Count = pcall(Rescan)
	if not Ok then
		warn("[AA Kaitun] scan error: " .. tostring(Count))
		return
	end
	if Count and Count > 0 then
		Placer.NeedScan = false
		Placer.ScanTries = 0
	else
		Placer.NeedScan = true
	end
end

local function RunUpgrades()
	local Farm, Other, Buff = {}, {}, {}
	for _, Model in ipairs(PlayerUnitModels()) do
		local UnitId = ModelUnitId(Model)
		if UnitId and IsFarmUnit(UnitId) then
			Farm[#Farm + 1] = Model
		elseif UnitId and IsBuffUnit(UnitId) then
			Buff[#Buff + 1] = Model
		else
			Other[#Other + 1] = Model
		end
	end
	local Now = os.clock()
	for _, Tier in ipairs({ Farm, Other, Buff }) do
		for _, Model in ipairs(Tier) do
			local UnitId = ModelUnitId(Model)
			local Level = StatValue(Model, "upgrade")
			local MaxLevel = StatValue(Model, "max_upgrade")
			if UnitId and Level ~= nil and (MaxLevel == nil or Level < MaxLevel) then
				local Cost = NextUpgradeCost(UnitId, Level)
				if Cost ~= nil then
					local Money = GetMoney()
					if Money ~= nil and Money < Cost then
						return
					end
					if Now - (Placer.UpgradeFail[Model] or 0) >= Config.UpgradeRetry then
						local Ok, Result = CallWithTimeout(10, InvokeServer, "upgrade_unit_ingame", Model)
						if Ok and Result then
							Placer.UpgradeFail[Model] = nil
							task.wait(Config.ActionDelay)
						else
							Placer.UpgradeFail[Model] = Now
						end
					end
				end
			end
		end
	end
end

local function PlacementTick()
	EnsureScan()
	if #Placer.Nodes == 0 then
		return
	end
	Placer.RefreshOccupied()
	local Equipped = EquippedUuids()
	if #Equipped == 0 and os.clock() - Placer.LastWarn > 15 then
		Placer.LastWarn = os.clock()
		Log("no equipped units found in the profile — nothing to place")
	end
	local Counts = {}
	for _, Model in ipairs(PlayerUnitModels()) do
		local UnitId = ModelUnitId(Model)
		if UnitId then
			Counts[UnitId] = (Counts[UnitId] or 0) + 1
		end
	end
	for _, Uuid in ipairs(Equipped) do
		local UnitId = UnitIdForUuid(Uuid)
		if UnitId and Units[UnitId] then
			local CanRetry = os.clock() - (Placer.LastAttempt[Uuid] or 0) > Config.RetryEvery
			local Money = GetMoney()
			if (Counts[UnitId] or 0) < SpawnCap(UnitId) and CanRetry and (Money == nil or Money >= UnitCost(UnitId)) then
				local Placed, Reason = TryPlace(Uuid, UnitId)
				if Placed then
					Counts[UnitId] = (Counts[UnitId] or 0) + 1
					Placer.LastAttempt[Uuid] = nil
					Placer.Fails = 0
					task.wait(Config.ActionDelay)
				else
					Placer.LastAttempt[Uuid] = os.clock()
					if Reason ~= "nonode" then
						Placer.Fails = Placer.Fails + 1
					end
				end
			end
		end
	end
	RunUpgrades()
end

-- match state ------------------------------------------------------------
local function DataFlag(Name)
	local Data = workspace:FindFirstChild("_DATA")
	local Flag = Data and Data:FindFirstChild(Name)
	return Flag ~= nil and Flag:IsA("ValueBase") and Flag.Value == true
end

local function MatchActive()
	return DataFlag("GameStarted") and not DataFlag("GameFinished")
end

local function GameFinished()
	return DataFlag("GameFinished")
end

local VoteClock = { Start = 0, Skip = 0 }

local function AutoVotes()
	local Now = os.clock()
	local StartGui = PlayerGui:FindFirstChild("VoteStart")
	local Data = workspace:FindFirstChild("_DATA")
	local VoteFolder = Data and Data:FindFirstChild("VoteStart")
	local Finished = VoteFolder and VoteFolder:FindFirstChild("VotingFinished")
	local Voting = Finished and Finished:IsA("ValueBase") and Finished.Value == false
	if StartGui and StartGui:IsA("ScreenGui") and StartGui.Enabled and Voting
		and Now - VoteClock.Start > Config.VoteRetry then
		VoteClock.Start = Now
		CallWithTimeout(10, InvokeServer, "vote_start")
	end

	local SkipGui = PlayerGui:FindFirstChild("VoteSkip")
	if SkipGui and SkipGui:IsA("ScreenGui") and SkipGui.Enabled and Now - VoteClock.Skip > Config.VoteRetry then
		VoteClock.Skip = Now
		CallWithTimeout(10, InvokeServer, "vote_wave_skip")
	end

	local Settings = Player:FindFirstChild("_settings")
	local AutoSkip = Settings and Settings:FindFirstChild("autoskip_waves")
	if AutoSkip and AutoSkip:IsA("BoolValue") and not AutoSkip.Value then
		AutoSkip.Value = true
	end
end

-- end-of-match decision --------------------------------------------------
local function IsChallengeKind(Kind)
	return Kind == "Normal" or Kind == "Daily"
end

-- "Leave" or "Replay"
local function DecideAfterMatch(Ctx)
	if IsChallengeKind(Ctx.Kind) or Ctx.Kind == "Act6" then
		return "Leave"
	end

	local Level = GetLevel()
	if Ctx.Kind == "Story1" and Level >= Config.EndgameLevel then
		Log("level %d reached -> leaving for the endgame route", Level)
		return "Leave"
	end
	if NeedHunt() then
		Log("gems >= %d -> leaving to hunt", Config.HuntGems)
		return "Leave"
	end

	-- challenges reset at :00 and :30 — if a reset passed since the lobby last
	-- handled them, go back and check (get_*_challenge only works in the lobby)
	if Level >= Config.NormalChallengeLevel and CurrentSlot() > (State.ChallengeSlot or 0) then
		Log("challenge reset passed -> leaving to check them")
		return "Leave"
	end
	return "Replay"
end

local function FinishMatch(Ctx)
	task.wait(3)
	if IsChallengeKind(Ctx.Kind) and Ctx.Uuid then
		State.ChallengeDone[Ctx.Mode or Ctx.Kind] = Ctx.Uuid
		SaveState()
	end
	task.wait(1)

	local Decision = DecideAfterMatch(Ctx)
	Log("match finished -> %s", Decision)
	if Config.WebhookMode == "all" then
		SendWebhook("Match finished (" .. tostring(Ctx.Kind) .. ")", "Decision: " .. Decision .. ".", 5793266)
	end

	local function Transitioned()
		return not GameFinished() or MatchActive()
	end

	if Decision == "Replay" then
		local Deadline = os.clock() + 10
		while os.clock() < Deadline and not Transitioned() do
			pcall(FireEndpoint, "set_game_finished_vote", "replay")
			task.wait(0.5)
		end
	end
	while Alive() and not Transitioned() do
		pcall(FireEndpoint, "teleport_back_to_lobby")
		task.wait(0.5)
	end
end

local function CurrentContext()
	local Ctx = State.Current
	if type(Ctx) ~= "table" or not Ctx.Kind then
		Ctx = { Kind = "Story1" }
	end
	return Ctx
end

local function LoseWaveFor(Ctx)
	if Ctx.Kind == "Story1" or Ctx.Kind == "Infinite" then
		return Config.LoseWave
	end
	return 0
end

-- match-start settings ----------------------------------------------------
-- show_overheads / disable_effects persist server-side. Only invoke when the
-- replicated _settings value is missing or different; keys that are not
-- replicated are sent once per session so the remote cannot flip them every
-- match if it turns out to be a toggle.
local MatchSettingsSent = {}
local function ApplyMatchSettings()
	local Folder = Player:FindFirstChild("_settings")
	for Name, Want in pairs({ show_overheads = false, disable_effects = true }) do
		local Flag = Folder and Folder:FindFirstChild(Name)
		if Flag and Flag:IsA("BoolValue") then
			if Flag.Value ~= Want then
				CallWithTimeout(10, InvokeServer, "toggle_setting", Name, Want)
			end
		elseif not MatchSettingsSent[Name] then
			MatchSettingsSent[Name] = true
			CallWithTimeout(10, InvokeServer, "toggle_setting", Name, Want)
		end
	end
end

RunInGame = function()
	Log("match mode (%s)", CurrentContext().Kind)
	ClearScanVisuals()
	ApplyMatchSettings()
	if Config.StatsOverlay then
		StartStatsOverlay()
	end

	Placer.Core = Loader.load_core_service(nil, "PlacementCore")
	Placer.Paths = Loader.load_core_service(nil, "PathService")
	Placer.Grid = SafeLoad("load_client_service", "PlacementServiceClient")

	-- fps boost only runs inside a match
	if Config.FpsBoost then
		task.spawn(function()
			if Env.AAKaitunFpsRestore then
				pcall(Env.AAKaitunFpsRestore)
			end
			Env.AAKaitunFpsRestore = ApplyFpsBoost(Config.FpsSettings)
		end)
	end

	local WasActive = false
	local LoseVoted = false
	local Handled = false
	local LastHuntCheck = 0
	local LastResetCheck = 0
	local ResetLeaveAt = nil

	-- placement / upgrades on their own thread
	task.spawn(function()
		while Alive() do
			if MatchActive() then
				local Ok, Err = pcall(PlacementTick)
				if not Ok then
					warn("[AA Kaitun] placement error: " .. tostring(Err))
				end
			end
			task.wait(1)
		end
	end)

	while Alive() do
		local Ctx = CurrentContext()
		pcall(AutoVotes)

		if MatchActive() then
			if not WasActive then
				WasActive = true
				LoseVoted = false
				Handled = false
				-- the placement thread scans (and keeps retrying until nodes exist)
				Placer.Nodes = {}
				Placer.Used = {}
				Placer.NeedScan = true
				Placer.ScanTries = 0
				Placer.Fails = 0
				Placer.LastScan = 0
			end

			local LoseWave = LoseWaveFor(Ctx)
			local Wave = GetWave()
			if LoseWave > 0 and Wave and Wave >= LoseWave and not LoseVoted then
				LoseVoted = true
				pcall(FireEndpoint, "vote_lose_game", true)
				Log("voted lose at wave %s", tostring(Wave))
			end

			-- gem hunt is due: do not wait for the match to end
			if (Ctx.Kind == "Story1" or Ctx.Kind == "Infinite") and os.clock() - LastHuntCheck > 5 then
				LastHuntCheck = os.clock()
				if NeedHunt() then
					Log("hunt due -> back to lobby")
					pcall(FireEndpoint, "teleport_back_to_lobby")
				end
			end

			-- a challenge reset is coming: leave early so the lobby queue is
			-- already open when the new challenges land (once per reset)
			if os.clock() - LastResetCheck > 5 then
				LastResetCheck = os.clock()
				local Left, Boundary = NextResetInfo()
				if GetLevel() >= Config.NormalChallengeLevel
					and Boundary ~= ResetLeaveAt
					and Left <= Config.ChallengeLeaveLead then
					ResetLeaveAt = Boundary
					Log("challenge reset in %ds -> leaving to lobby", math.floor(Left))
					pcall(FireEndpoint, "teleport_back_to_lobby")
				end
			end
		else
			WasActive = false
			if GameFinished() and not Handled then
				Handled = true
				local Ok, Err = pcall(FinishMatch, Ctx)
				if not Ok then
					warn("[AA Kaitun] finish error: " .. tostring(Err))
				end
			end
		end
		task.wait(0.5)
	end
end
end -- end match scope block

-- entry ------------------------------------------------------------------
local function Main()
	LoadState()
	-- getgenv().Kaitun may be gone after a teleport re-run; fall back to the
	-- last resolved unit saved in the state file, then persist the result
	if UserConfig.CompassUnit == nil and type(State.CompassUnit) == "string" and State.CompassUnit ~= "" then
		Config.CompassUnit = NormalizeUnitId(State.CompassUnit) or State.CompassUnit
	end
	State.CompassUnit = Config.CompassUnit
	SaveState()
	if not WaitForSession() then
		warn("[AA Kaitun] profile never loaded")
		return
	end
	AntiAfk()
	if Config.SkipCutscenes then
		InstallCinematicSkip()
	end
	-- mark the compass done if the server says the pick changed
	pcall(function()
		EndpointsClient.connect_endpoint("celestial_compass_pick_changed", function()
			State.CompassDone = true
			SaveState()
		end)
	end)
	StartMilestoneWatcher()

	if Loader.IsLobby then
		RunLobby()
	else
		RunInGame()
	end
end

local Ok, Err = xpcall(Main, debug.traceback)
if not Ok then
	warn("[AA Kaitun] fatal: " .. tostring(Err))
end