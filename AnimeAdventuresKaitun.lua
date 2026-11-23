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

task.wait(4)

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

local Players = game:GetService("Players")
local Player = Players.LocalPlayer

local PlayerGui = Player:WaitForChild("PlayerGui")
local Env = (getgenv and getgenv()) or _G

-- executor globals (not in standard Luau)
---@diagnostic disable: undefined-global
local GetGc, HookFunction, IsLClosure = getgc, hookfunction, islclosure
local FireSignal = firesignal
local GetHui = gethui

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
while true do
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
local Attacks = SafeLoad("load_data", "Attacks") or {}
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
	MinGems = 0,                -- hunt never leaves fewer gems than this

	-- compass (CompassUnit = the pick AND the hunt target)
	CompassId = "celestial_compass_u21",
	CompassUnit = "elyssia",
	Challenges = true,           -- join daily/normal challenges and leave matches for resets
	ChallengesOnlyAfterCompass = true, -- true = once the compass unit is owned, stop joining story/infinite and only take challenges/dailies in the lobby

	-- auto trait rolling on the compass unit (kicked off once it is owned)
	AutoTrait = true,          -- roll traits on the compass unit when resources allow
	TraitKeep = { "unique" },  -- Unique is always forced; add ids/names, e.g. "reaper", "Celestial"
	TraitSources = { "token", "remnant", "remnant_ltd" },
	TraitMinResources = 0,
	TraitRollDelay = 0.25,
	TraitChangeTimeout = 5,

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
	ActionDelay = 0.5,
	PlaceRetries = 1,             -- node attempts per unit per tick before giving up
	RetryEvery = 1,               -- seconds before a unit retries after a failed placement
	SummonHatchWait = 0.6,        -- max seconds to wait for the hatch record after a 10x
	RescanAfterFails = 2,         -- this many failed placements in a row -> rescan
	UpgradeRetry = 1,
	VoteRetry = 2,
	ShowVisuals = false,          -- draw scan nodes/rings/arrow like auto_place.lua

	-- getgenv().Kaitun overrides (merged below)
	TeamUnits = nil,             -- Kaitun.Team = { "bulby", ... } — units to equip, in order
	AutoSell = true,             -- sell everything that is not on the team (never units above level 1)
	EquipGap = 0.5,              -- same as equip_best.lua (the game rate-limits)
	EquipRetries = 3,            -- equip passes, same as equip_best.lua
	EquipVerifyTimeout = 8,      -- seconds to wait for the unequip_all to clear
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
--       AutoTrait = true, TraitKeep = { "unique", "reaper" },
--       TraitSources = { "token", "remnant", "remnant_ltd" },
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
	if tonumber(UserConfig.EquipGap) then
		Config.EquipGap = math.max(0.5, tonumber(UserConfig.EquipGap))
	end
	if UserConfig.SkipCutscenes ~= nil then
		Config.SkipCutscenes = UserConfig.SkipCutscenes and true or false
	end
	if UserConfig.Challenges ~= nil then
		Config.Challenges = UserConfig.Challenges and true or false
	end
	if UserConfig.ChallengesOnlyAfterCompass ~= nil then
		Config.ChallengesOnlyAfterCompass = UserConfig.ChallengesOnlyAfterCompass and true or false
	end
	if UserConfig.AutoTrait ~= nil then
		Config.AutoTrait = UserConfig.AutoTrait and true or false
	end
	if type(UserConfig.TraitKeep) == "table" then
		Config.TraitKeep = UserConfig.TraitKeep
	end
	if type(UserConfig.TraitSources) == "table" then
		Config.TraitSources = UserConfig.TraitSources
	end
	if tonumber(UserConfig.TraitMinResources) then
		Config.TraitMinResources = math.floor(tonumber(UserConfig.TraitMinResources))
	end
	if tonumber(UserConfig.TraitRollDelay) then
		Config.TraitRollDelay = tonumber(UserConfig.TraitRollDelay)
	end
	if tonumber(UserConfig.TraitChangeTimeout) then
		Config.TraitChangeTimeout = tonumber(UserConfig.TraitChangeTimeout)
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
	TraitRoll = {},              -- unit id -> { doneAt, gotUnique, traits, rolls }
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
	for _, Key in ipairs({ "Hunted", "RedeemedCodes", "TraitRoll" }) do
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
		task.wait(0.05)
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
	while true and os.clock() < Deadline do
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

-- Profile copies expose their level under different names across builds.
-- Anything above level 1 is protected from AutoSell.
local function UnitLevel(Unit)
	if type(Unit) ~= "table" then
		return 0
	end
	for _, Key in ipairs({ "level", "upgrade", "unit_level", "_level", "_upgrade", "upgrade_level" }) do
		local Value = tonumber(Unit[Key])
		if Value then
			return Value
		end
	end
	return 0
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

-- challenges run when enabled outright, or when challenges-only mode is on
-- and the compass unit has actually been obtained
local function ChallengesEnabled()
	return Config.Challenges == true
		or (Config.ChallengesOnlyAfterCompass == true and State.CompassDone == true)
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
			SetCached(Item, "Material", Enum.Material.SmoothPlastic)
			SetCached(Item, "MaterialVariant", "")
			SetCached(Item, "Reflectance", 0)
			SetCached(Item, "Color", Color3.new(1, 1, 1))
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

-- Keyed reports fire at most once per goal, even across teleports/loader re-runs
-- (the state file can fail to save, so keep an executor-wide ledger too).
local WebhookSent = Env.AAKaitunWebhookSent or {}
Env.AAKaitunWebhookSent = WebhookSent

local function SendWebhook(Title, Description, Color, Key, Icon)
	local function Commas(Value)
		local Text = tostring(math.floor(tonumber(Value) or 0))
		local Sign, Digits = Text:match("^(-?)(%d+)$")
		if not Digits then
			return Text
		end
		Digits = Digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
		return Sign .. Digits
	end

	local function ProgressBar(Value, Max, Width)
		Width = Width or 10
		local Fraction = Max > 0 and math.clamp(Value / Max, 0, 1) or 0
		local Filled = math.floor(Fraction * Width + 0.5)
		return string.rep("\u{25B0}", Filled) .. string.rep("\u{25B1}", Width - Filled)
	end
	if Config.WebhookUrl == "" or Config.WebhookMode == "none" or not RequestFn then
		return
	end
	if Key then
		if WebhookSent[Key] then
			return
		end
		WebhookSent[Key] = true
	end
	-- exact profile paths (verified with check_inventory.lua)
	local Prof = Profile()
	local NormalItems = type(Prof.inventory) == "table"
		and type(Prof.inventory.normal_items) == "table"
		and Prof.inventory.normal_items or {}
	local function ItemCount(Name)
		return tonumber(NormalItems[Name]) or 0
	end
	local Level = tonumber(GetLevel()) or 0
	local Gems = tonumber(Prof.gem_amount) or GetGems()
	local Endgame = tonumber(Config.EndgameLevel) or 0
	local Progress
	if Endgame > 0 and Level < Endgame then
		Progress = ProgressBar(Level, Endgame) .. "  `" .. Level .. "/" .. Endgame .. "`"
	else
		Progress = "\u{2705} Endgame reached"
	end
	local Account = Config.WebhookShowName and Player.Name or "Hidden"

	local Fields = {
		{ name = "\u{2B50} Level", value = "`" .. Commas(Level) .. "`", inline = true },
		{ name = "\u{1F48E} Gems", value = "`" .. Commas(Gems) .. "`", inline = true },
		{ name = "\u{1F3B2} Reroll Tokens", value = "`" .. Commas(tonumber(Prof.trait_reroll_tokens) or 0) .. "`", inline = true },
		{ name = "\u{2728} Remnants", value = "`" .. Commas(ItemCount("star_remnant")) .. "`", inline = true },
		{ name = "\u{1F31F} Remnants (Ltd)", value = "`" .. Commas(ItemCount("star_remnant_limited")) .. "`", inline = true },
		{ name = "\u{1F4C8} Progress", value = Progress, inline = true },
	}
	local Embed = {
		author = { name = tostring(Config.WebhookName) .. "  \u{2022}  " .. Account },
		title = (Icon and (Icon .. "  ") or "") .. tostring(Title),
		color = Color or 5793266,
		fields = Fields,
		footer = { text = "Anime Adventures  \u{2022}  Kaitun" },
		timestamp = DateTime.now():ToIsoDate(),
	}
	if Description and Description ~= "" then
		Embed.description = "> " .. Description
	end
	if Config.WebhookShowName and Player.UserId then
		Embed.thumbnail = {
			url = "https://www.roblox.com/headshot-thumbnail/image?userId="
				.. Player.UserId .. "&width=420&height=420&format=png",
		}
	end
	local Body = {
		username = Config.WebhookName,
		embeds = { Embed },
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
		Icon = "\u{2B50}", Color = 15844367,
		Check = function()
			return GetLevel() >= Config.NormalChallengeLevel
		end,
	},
	{
		Key = "Level" .. Config.DailyChallengeLevel,
		Title = "Level " .. Config.DailyChallengeLevel .. " reached",
		Text = "Daily challenges are unlocked.",
		Icon = "\u{1F4C5}", Color = 15844367,
		Check = function()
			return GetLevel() >= Config.DailyChallengeLevel
		end,
	},
	{
		Key = "Level" .. Config.EndgameLevel,
		Title = "Level " .. Config.EndgameLevel .. " reached",
		Text = "Switching to the act 6 clear, then Infinite.",
		Icon = "\u{1F680}", Color = 15105570,
		Check = function()
			return GetLevel() >= Config.EndgameLevel
		end,
	},
	{
		Key = "Gems" .. Config.HuntGems,
		Title = Config.HuntGems .. " gems reached",
		Text = "Heading to the lobby to hunt.",
		Icon = "\u{1F48E}", Color = 3447003,
		Check = function()
			return GetGems() >= Config.HuntGems
		end,
	},
	{
		Key = "CompassUsed",
		Title = "Celestial Compass used",
		Icon = "\u{1F9ED}", Color = 10181046,
		Text = "Picked " .. UnitDisplayName(Config.CompassUnit) .. ".",
		Check = function()
			return State.CompassDone == true
		end,
	},
	{
		Key = "FirstSummon",
		Title = "First 10x summon done",
		Icon = "\u{1F3B0}", Color = 15277667,
		Text = "Summoned once on " .. Config.SummonBanner .. ".",
		Check = function()
			return State.Summoned == true
		end,
	},
	{
		Key = "HuntDone",
		Title = "Hunt complete",
		Text = "All wanted units are in the collection; the configured team is now used.",
		Icon = "\u{1F3C6}", Color = 5763719,
		Check = function()
			return State.HuntDone == true
		end,
	},
}

local function StartMilestoneWatcher()
	task.spawn(function()
		while true do
			for _, Milestone in ipairs(Milestones) do
				if not State.Reported[Milestone.Key] then
					local Ok, Reached = pcall(Milestone.Check)
					if Ok and Reached then
						State.Reported[Milestone.Key] = os.time()
						SaveState()
						Log("milestone: %s", Milestone.Title)
						SendWebhook(Milestone.Title, Milestone.Text, Milestone.Color,
							"goal:" .. tostring(Milestone.Key), Milestone.Icon)
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
	Log("stats overlay on (black screen %s)", BlackOn and "on" or "off")
end

-- ============================================================ LOBBY =====

-- scope block: frees the lobby locals before the match section; only the
-- entry points used later (RunLobby by Main, NeedHunt/CurrentSlot by the
-- match planner) are exported through the forward declarations
local RunLobby, NeedHunt, CurrentSlot, NextResetInfo
do

-- auto trait rolling -----------------------------------------------------
-- Once the compass unit is owned, spend whatever reroll resources exist
-- (tokens -> star remnants -> limited remnants) until Unique lands. Every
-- roll re-reads the unit's live traits first so nothing is spent on a unit
-- that already carries a wanted trait. A webhook reports Unique or the
-- final trait list; the outcome is saved so it only runs once per unit.

local function TraitResources()
	local Prof = Profile()
	local Items = type(Prof.inventory) == "table"
		and type(Prof.inventory.normal_items) == "table"
		and Prof.inventory.normal_items or {}
	return {
		token = tonumber(Prof.trait_reroll_tokens) or 0,
		remnant = tonumber(Items.star_remnant) or 0,
		remnant_ltd = tonumber(Items.star_remnant_limited) or 0,
	}
end

local function NextTraitSource(Res)
	for _, Source in ipairs(Config.TraitSources or {}) do
		if (tonumber(Res[Source]) or 0) > Config.TraitMinResources then
			return Source
		end
	end
	return nil
end

local TraitCatalog
local function TraitLookup()
	if not TraitCatalog then
		TraitCatalog = {}
		local Data = SafeLoad("load_data", "Traits")
		if type(Data) == "table" and type(Data.info) == "table" then
			for Key, Info in pairs(Data.info) do
				if type(Info) == "table" then
					local Id = tostring(Info.id or Key):lower()
					local Name = tostring(Info.name or Key)
					TraitCatalog[Id] = Name
					TraitCatalog[Name:lower()] = Name
				end
			end
		end
	end
	return TraitCatalog
end

-- Live trait list: { { trait = "nimble", tier = "2" }, ... }
local function UnitTraitList(Uuid)
	local Unit = (Collection().owned_units or {})[Uuid]
	local Out = {}
	if type(Unit) == "table" and type(Unit.traits) == "table" then
		for _, Entry in ipairs(Unit.traits) do
			if type(Entry) == "table" then
				Out[#Out + 1] = {
					id = tostring(Entry.trait or Entry.id or "?"):lower(),
					tier = tostring(Entry.tier or ""),
				}
			end
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

local function TraitLabels(List, Lookup)
	local Out = {}
	for _, Trait in ipairs(List) do
		Out[#Out + 1] = (Lookup[Trait.id] or Trait.id)
			.. (Trait.tier ~= "" and (" T" .. Trait.tier) or "")
	end
	table.sort(Out)
	return Out
end

local function KeptTrait(List)
	local Keep = {}
	for _, Name in ipairs(Config.TraitKeep or {}) do
		Keep[tostring(Name):lower()] = true
	end
	Keep["unique"] = true -- Unique is always kept
	for _, Trait in ipairs(List) do
		if Keep[Trait.id] then
			return Trait
		end
	end
	return nil
end

local function SpendTraitReroll(Source, Uuid)
	if Source == "remnant" then
		return FireEndpoint("use_item", "star_remnant", { unit_uuid = Uuid })
	elseif Source == "remnant_ltd" then
		return FireEndpoint("use_item", "star_remnant_limited", { unit_uuid = Uuid })
	end
	return FireEndpoint("request_token_trait_reroll", Uuid)
end

local function AutoRollTraits(UnitId)
	if not Config.AutoTrait or type(UnitId) ~= "string" or UnitId == "" then
		return
	end
	local Saved = (State.TraitRoll or {})[UnitId]
	if Saved and Saved.doneAt then
		return -- already reported / rolled for this unit
	end

	local Copy = BestCopies()[UnitId]
	if not Copy then
		return
	end
	local Uuid, Lookup = Copy.Uuid, TraitLookup()

	local Current = UnitTraitList(Uuid)
	local Hit = KeptTrait(Current)
	if Hit then
		State.TraitRoll = State.TraitRoll or {}
		State.TraitRoll[UnitId] = {
			doneAt = os.time(), gotUnique = Hit.id == "unique",
			traits = TraitLabels(Current, Lookup), rolls = 0,
		}
		SaveState()
		Log("%s already has %s — skipping trait rolls", UnitId, Hit.id)
		return
	end

	if not NextTraitSource(TraitResources()) then
		Log("no trait reroll resources for %s — will retry later", UnitId)
		return
	end

	local Rolls, GotUnique, Reason = 0, false, "exhausted"
	while true do
		-- verify live state before spending anything
		Current = UnitTraitList(Uuid)
		Hit = KeptTrait(Current)
		if Hit then
			GotUnique = Hit.id == "unique"
			Reason = GotUnique and "unique" or "kept"
			break
		end

		local Res = TraitResources()
		local Source = NextTraitSource(Res)
		if not Source then
			Reason = "exhausted"
			break
		end

		local BeforeSig = TraitSignature(Current)
		local BeforeLeft = tonumber(Res[Source]) or 0
		local Ok = SpendTraitReroll(Source, Uuid)
		if not Ok then
			Reason = "nochange"
			Log("trait reroll via %s failed", Source)
			break
		end

		local Deadline = os.clock() + Config.TraitChangeTimeout
		local Changed = false
		repeat
			task.wait(0.15)
			local Fresh = UnitTraitList(Uuid)
			local NowRes = TraitResources()
			Changed = (TraitSignature(Fresh) ~= BeforeSig)
				or ((tonumber(NowRes[Source]) or 0) < BeforeLeft)
		until Changed or os.clock() >= Deadline

		if not Changed then
			Reason = "nochange"
			Log("trait roll %d via %s: no change — stopping", Rolls + 1, Source)
			break
		end

		Rolls += 1
		Current = UnitTraitList(Uuid)
		Hit = KeptTrait(Current)
		if Hit then
			GotUnique = Hit.id == "unique"
			Reason = GotUnique and "unique" or "kept"
			break
		end
		task.wait(Config.TraitRollDelay)
	end

	Current = UnitTraitList(Uuid)
	Hit = KeptTrait(Current)
	GotUnique = Hit ~= nil and Hit.id == "unique" or false
	local Labels = TraitLabels(Current, Lookup)
	local Text = #Labels > 0 and table.concat(Labels, ", ") or "none"

	-- only persist/report when an attempt really concluded
	if Reason ~= "nochange" then
		State.TraitRoll = State.TraitRoll or {}
		State.TraitRoll[UnitId] = {
			doneAt = os.time(), gotUnique = GotUnique,
			traits = Labels, rolls = Rolls,
		}
		SaveState()
		local Title = GotUnique
			and ("Unique rolled on " .. UnitDisplayName(UnitId))
			or ("Trait rolls finished on " .. UnitDisplayName(UnitId))
		local Desc = GotUnique
			and ("Got Unique after " .. Rolls .. " roll(s). Traits: " .. Text .. ".")
			or ("No kept trait after " .. Rolls .. " roll(s). Final traits: " .. Text .. ".")
		SendWebhook(Title, Desc, GotUnique and 5763719 or 15105570, nil,
			GotUnique and "\u{1F3C6}" or "\u{1F3B2}")
	end
	Log("traits for %s: %s (%d roll(s), unique=%s)", UnitId, Text, Rolls, tostring(GotUnique))
end

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

-- Compass usage is checked ONLY through the summon GUI slot. Profile markers
-- and the celestial_compass_pick_changed callback are deliberately ignored —
-- the visible slot is the single source of truth (see CompassUsedInGui).
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

-- Force = retry even if a previous attempt this session failed (used right
-- before the first summon, which must never happen before the compass pick).
local function UseCompass(Force)
	-- the GUI slot is the source of truth
	if CompassUsedInGui() then
		if not State.CompassDone then
			State.CompassDone = true
			SaveState()
		end
		return true
	end
	-- GUI-only: owning the unit or a profile/callback marker is NOT enough.
	if CompassTried and not Force then
		return false
	end
	CompassTried = true

	local Remote = GetEndpoint("set_celestial_compass_pick")
	if not Remote then
		Log("compass remote not found")
		return false
	end
	local Ok, Result = CallWithTimeout(5, function()
		return Remote:InvokeServer(Config.CompassId, Config.CompassUnit)
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
		State.CompassDone = true
		SaveState()
		Log("compass used -> %s (slot verified)", Config.CompassUnit)
		return true
	end
	Log("compass pick sent but the slot is not visible yet — will retry next lobby visit")
	return false
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
	CallWithTimeout(5, InvokeServer, "buy_from_banner", BannerId, "gems10")
	-- the cinematic module may only load once the roll is in flight
	if Config.SkipCutscenes then
		InstallCinematicSkip()
	end

	-- the invoke returns once the server handled it, so check right away and
	-- only then poll (fast) instead of sleeping fixed steps
	local Charged = GetGems() < GemsBefore
	local ChargeDeadline = os.clock() + 1.5
	while not Charged and os.clock() < ChargeDeadline do
		task.wait(0.015)
		Charged = GetGems() < GemsBefore
	end

	local Results = DiffHatches(Before, HatchCounters())
	local HatchDeadline = os.clock() + Config.SummonHatchWait
	while #Results == 0 and os.clock() < HatchDeadline do
		task.wait(0.015)
		Results = DiffHatches(Before, HatchCounters())
	end
	return Charged, Results
end

local AutoSell -- defined below; sells dupes after every 10x summon

local function SummonTenOnce()
	if State.Summoned then
		return
	end
	-- The compass pick must be used before the very first summon. Retry it here
	-- even if an earlier lobby pass failed, and defer the roll until it lands.
	if not State.CompassDone and not UseCompass(true) then
		Log("compass not used yet — deferring the first summon to the next lobby visit")
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

	while true do
		if HasUnit(Target) or HatchedTotal(Target) > BaseHatched then
			State.Hunted[Target] = true
			if #HuntRemaining() == 0 then
				State.HuntDone = true
			end
			SaveState()
			Log("got %s after %d x10 rolls", Target, Rolls)
			AutoRollTraits(Target)
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
					"Got " .. UnitDisplayName(Target) .. " after " .. Rolls .. " x10 rolls." .. Drops,
					5763719, "hunt:" .. tostring(Target), "\u{1F3AF}")
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
			task.wait(0.15)
		end
	end
	return false
end

-- team -------------------------------------------------------------------
local function Slots()
	return tonumber(GameplaySettings.NUM_TEAM_SLOTS) or 6
end

-- Collection data is replicated separately from the session. Wait until the
-- owned/equipped maps are actually populated before building or equipping a
-- team, otherwise we equip an empty roster and never retry.
local function WaitForCollection(Timeout)
	local Deadline = os.clock() + (Timeout or 30)
	while os.clock() < Deadline do
		local C = Collection()
		if type(C.owned_units) == "table" and next(C.owned_units) ~= nil
			and type(C.equipped_units) == "table" then
			return true
		end
		task.wait(0.25)
	end
	warn("[AA Kaitun] collection data did not load in time")
	return false
end

local function LobbyIsFarmUnit(UnitId)
	local Def = Units[UnitId]
	if type(Def) ~= "table" then
		return false
	end
	if Def.farm_amount ~= nil or Def._show_as_farm_unit == true then
		return true
	end
	if type(Def.end_of_wave) == "table" then
		for _, Entry in pairs(Def.end_of_wave) do
			if type(Entry) == "table" and Entry.type == "farm" then
				return true
			end
		end
	end
	return false
end

-- Same effective-DPS formula as the match scorer: own attack + summons,
-- weighted by range. Lobby has no live models, so max-level data stats are
-- used. This is the ranking source for the auto-equip refactor.
local function UnitDps(UnitId)
	local Def = Units[UnitId]
	if type(Def) ~= "table" then
		return 0
	end
	local Stats = {}
	for Key, Value in pairs(Def) do
		Stats[Key] = Value
	end
	if type(Def.upgrade) == "table" then
		for Index = 1, #Def.upgrade do
			local Entry = Def.upgrade[Index]
			if type(Entry) == "table" then
				for Key, Value in pairs(Entry) do
					Stats[Key] = Value
				end
			end
		end
	end
	local Damage = tonumber(Stats.damage) or 0
	local Cd = tonumber(Stats.attack_cooldown) or tonumber(Stats.cooldown) or 0
	local Total = Cd > 0 and Damage / Cd or Damage
	if Stats.spawn_unit == true or Stats.spawn_script == true then
		local function AddSummons(AttackId, Weight)
			local Attack = Attacks[AttackId]
			if type(Attack) ~= "table" or type(Attack.spawn_unit) ~= "table" then
				return
			end
			for _, Group in pairs(Attack.spawn_unit) do
				if type(Group) == "table" then
					for _, Field in ipairs({ "units", "units_nonrandom" }) do
						local List = Group[Field]
						if type(List) == "table" then
							for _, Entry in pairs(List) do
								if type(Entry) == "table" then
									local Minion = Units[Entry.unit]
									local MinionCd = type(Minion) == "table"
										and (tonumber(Minion.attack_cooldown) or tonumber(Minion.cooldown)) or nil
									if MinionCd and MinionCd > 0 then
										local Amount = tonumber(Entry.amount) or tonumber(Group.amount) or 1
										local Ratio = tonumber(Entry.damage_ratio) or 1
										Total += Weight * Amount * Ratio * Damage / MinionCd
									end
								end
							end
						end
					end
				end
			end
		end
		local Primary = Stats.primary_attack or Stats.primary_attack_no_upgrades
		if type(Primary) == "string" then
			AddSummons(Primary, 1)
		end
		if type(Stats.active_attack) == "string" then
			local Active = type(Stats.active_attack_stats) == "table" and Stats.active_attack_stats or {}
			local ActiveCd = tonumber(Active.attack_cooldown)
			AddSummons(Stats.active_attack, ActiveCd and ActiveCd > 0 and math.min(1, Cd / ActiveCd) or 1)
		end
	end
	return Total * math.max(tonumber(Stats.range) or 8, 1)
end

-- ordered list of uuids, index = slot. DPS units first, farms last.
local function BuildTeam()
	local Best = BestCopies()
	local DpsTeam, FarmTeam, Used = {}, {}, {}
	local Limit = Slots()

	local function Add(UnitId)
		local Copy = Best[UnitId]
		if Copy and not Used[UnitId] and (#DpsTeam + #FarmTeam) < Limit then
			Used[UnitId] = true
			if LobbyIsFarmUnit(UnitId) then
				FarmTeam[#FarmTeam + 1] = Copy.Uuid
			else
				DpsTeam[#DpsTeam + 1] = Copy.Uuid
			end
			return true
		end
		return false
	end

	-- Kaitun.Team: equip these units in order, skipping ones you don't own.
	-- Farms are still pushed to the back slots even if listed here.
	local TeamIds = {}
	for _, Id in ipairs(Config.TeamUnits or {}) do
		local Norm = NormalizeUnitId(Id)
		if Norm then
			TeamIds[#TeamIds + 1] = Norm
		end
	end
	for _, Id in ipairs(TeamIds) do
		Add(Id)
	end

	-- fill remaining slots by effective DPS (new checker)
	local Ranked = {}
	for UnitId, Copy in pairs(Best) do
		if not Used[UnitId] then
			Ranked[#Ranked + 1] = { Id = UnitId, Score = UnitDps(UnitId) }
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

	local Team = {}
	for _, Uuid in ipairs(DpsTeam) do
		Team[#Team + 1] = Uuid
	end
	for _, Uuid in ipairs(FarmTeam) do
		Team[#Team + 1] = Uuid
	end
	return Team
end

local function SlotUuid(Slot)
	local Equipped = Collection().equipped_units or {}
	local Value = Equipped[Slot] or Equipped[tostring(Slot)]
	return Value and tostring(Value) or nil
end

-- equip_best.lua style: set of equipped UUIDs (slot is not checked here)
local function EquippedSet()
	local Set = {}
	for _, Uuid in pairs(Collection().equipped_units or {}) do
		Set[tostring(Uuid)] = true
	end
	return Set
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
		-- never sell a unit that has been levelled past 1
		if type(Unit) == "table" and Unit._locked ~= true and UnitLevel(Unit) <= 1 then
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
	-- Do not build/equip until the collection has actually replicated.
	if not WaitForCollection() then
		return
	end
	local Team = BuildTeam()
	if #Team == 0 then
		return
	end

	local Gap = math.max(0.5, tonumber(Config.EquipGap) or 1.5)
	local Retries = math.max(1, tonumber(Config.EquipRetries) or 3)
	local Verify = math.max(2, tonumber(Config.EquipVerifyTimeout) or 8)

	-- One-shot unequip_all instead of one remote call per unit.
	local UnequipAll = ReplicatedStorage:FindFirstChild("endpoints")
	UnequipAll = UnequipAll and UnequipAll:FindFirstChild("client_to_server")
	UnequipAll = UnequipAll and UnequipAll:FindFirstChild("unequip_all")
	if UnequipAll and UnequipAll:IsA("RemoteFunction") then
		pcall(function()
			UnequipAll:InvokeServer()
		end)
	else
		-- fallback only if the game does not expose unequip_all
		for _, Uuid in pairs(Collection().equipped_units or {}) do
			task.wait(Gap)
			CallWithTimeout(10, InvokeServer, "unequip_unit", tostring(Uuid))
		end
	end

	-- VERIFY the unequip landed before sending any equip request.
	local ClearDeadline = os.clock() + math.max(Verify, 8)
	while os.clock() < ClearDeadline do
		if CountEntries(Collection().equipped_units or {}) == 0 then
			break
		end
		task.wait(0.3)
	end

	-- equip_best.lua style: want = uuid -> slot. unequip_all above guarantees
	-- the slots are empty, so auto-assign (pass 1) fills them in Team order —
	-- DPS units first, farms in the last slots.
	local Want = {}
	for Slot, Uuid in ipairs(Team) do
		Want[Uuid] = Slot
	end

	for Pass = 1, Retries do
		local InSlots = EquippedSet()
		local Missing = {}
		for Uuid, Slot in pairs(Want) do
			if not InSlots[Uuid] then
				Missing[#Missing + 1] = { Uuid = Uuid, Slot = Slot }
			end
		end
		if #Missing == 0 then
			break
		end
		for _, Entry in ipairs(Missing) do
			task.wait(Gap)
			if Pass == 1 then
				-- generated client call: equip_unit(uuid) only
				CallWithTimeout(10, InvokeServer, "equip_unit", Entry.Uuid)
			else
				-- retries force the intended slot, exactly like equip_best.lua
				CallWithTimeout(10, InvokeServer, "equip_unit", Entry.Uuid, Entry.Slot)
			end
		end
	end

	-- verify by UUID set (same as equip_best.lua), no extra request spam
	local InSlots = EquippedSet()
	local Missing = {}
	for Uuid in pairs(Want) do
		if not InSlots[Uuid] then
			Missing[#Missing + 1] = tostring(Uuid)
		end
	end
	if #Missing == 0 then
		Log("team verified: %d units equipped (dps first / farms last)", #Team)
	else
		Log("team partially equipped: %d unit(s) missing", #Missing)
	end
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

	State.Current = { Kind = Def.Mode, Mode = Def.Mode, Uuid = Uuid, Token = HttpService:GenerateGUID(false) }
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
	State.Current = { Kind = "Story1", LevelId = Stage, Token = HttpService:GenerateGUID(false) }
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

	State.Current = { Kind = "Act6", LevelId = Target, Token = HttpService:GenerateGUID(false) }
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
				State.Current = { Kind = "Act6", LevelId = Id, Token = HttpService:GenerateGUID(false) }
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
	State.Current = { Kind = "Infinite", LevelId = Id, Token = HttpService:GenerateGUID(false) }
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

	if ChallengesEnabled() then
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
	if Config.ChallengesOnlyAfterCompass and State.CompassDone == true then
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
		local Left = select(1, NextResetInfo())
		local Mm = math.floor(Left / 60)
		local Ss = math.floor(Left % 60)
		Sub.Text = ("Lv %d  -  gems %s  -  next challenges %d:%02d"):format(
			GetLevel(), tostring(GetGems()), Mm, Ss)
	end

	task.spawn(function()
		while true do
			pcall(Refresh)
			task.wait(1)
		end
	end)
	Refresh()
	Log("lobby widget on")
end

-- Lobby-only toggles: sent when the replicated setting is missing or wrong,
-- and once per session for keys the game does not replicate.
local LobbySettingsSent = {}
local function ApplyLobbySettings()
	local Folder = Player:FindFirstChild("_settings")
	for Name, Want in pairs({ quick_summon = true, hide_other_pets = true }) do
		local Flag = Folder and Folder:FindFirstChild(Name)
		if Flag and Flag:IsA("BoolValue") then
			if Flag.Value ~= Want then
				CallWithTimeout(10, InvokeServer, "toggle_setting", Name, Want)
			end
		elseif not LobbySettingsSent[Name] then
			LobbySettingsSent[Name] = true
			CallWithTimeout(10, InvokeServer, "toggle_setting", Name, Want)
		end
	end
end

RunLobby = function()
	Log("lobby mode")
	-- collection (owned_units / equipped_units) replicates after the session;
	-- wait for it before ANY lobby logic reads it
	WaitForCollection()
	if Config.StatsOverlay then
		StartLobbyWidget()
	end
	ApplyLobbySettings()
	GroupAndFavorite()
	RedeemCodes()
	UseCompass()
	ClaimAll()
	SummonTenOnce()
	EquipTeam()
	-- the compass unit may arrive from the compass pick, the first summon or
	-- the hunt; one check here covers all three (state prevents re-rolling)
	if HasUnit(Config.CompassUnit) then
		AutoRollTraits(Config.CompassUnit)
	end

	while true and Loader.IsLobby do
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
		while true and Loader.IsLobby do
			task.wait(1)
			local Limit = Requested
				and (MatchmakingGui() and Config.QueueTimeout or Config.JoinTimeout)
				or Config.IdleWait
			if os.clock() - Started >= Limit then
				break
			end
		end
		if true and MatchmakingGui() then
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
local RunService = game:GetService("RunService")

local PlaceConfig = {
	Percent = 5,
	NodeSpacing = 2.5,
	RadiusGround = 40,
	RadiusHill = 40,
	RadiusFarm = 10,
	FarmTerrain = "ground",
	ShowVisuals = true,
	PlaceRetries = 1,
	RetryEvery = 1,
	RescanAfterFails = 2,
	UpgradeRetry = 1,
	ActionDelay = 0.1,

	-- scoring: which unit to place / upgrade next
	PlaceStrategy = "value", -- "value" | "farm_first" | "role_spread"
	UpgradeStrategy = "value", -- "spread" | "value" | "farm_first"
	PlaceDpsWeight = 2, -- raw DPS is the primary placement score for combat units
	PlaceDpsPerCostWeight = 5, -- secondary efficiency bonus
	PlaceTierWeight = 1000, -- rarity tier outranks DPS: Epic before Rare, etc.
	UpgradeTierWeight = 1000, -- same rule when choosing which unit to upgrade next
	UpgradeRawDpsWeight = 4, -- bonus for upgrading high-DPS units when stable
	PlaceFarmWeight = 60,
	PlaceBuffWeight = 20,
	PlaceSpreadPenalty = 2, -- low: fill the best unit to its cap before diversifying
	PlacePathWeight = 1,
	DefaultRange = 8, -- used when a unit has no range stat
	ClusterWeight = 4, -- keep combat units packed together instead of scattering
	OutOfRangePenalty = 1000, -- nodes this far outside range are essentially skipped
	-- action queue
	QueueSize = 40, -- entries kept in the queue (places + upgrades, best first)
	ActionsPerTick = 6, -- successful actions per tick
	ExtraTries = 8, -- extra rejected / skipped attempts allowed per tick
	PendingSeconds = 0.75, -- a spend counts against the money until the balance replicates
	UpgradeSpreadWeight = 40,
	UpgradeValueWeight = 10000,
	UpgradeRecencyWeight = 0.5,

	-- learned from the live game: farm upgrades compound, combat upgrades pay
	-- by DPS-per-yen, and early waves are for building the army.
	EstimatedWaves = 25,
	FarmUpgradeUntilWave = 12,
	FarmUpgradeWeight = 1000,
	CombatUpgradeWeight = 10000,
	EarlyPlaceWaves = 5, -- place freely before this wave, upgrade after
	PlaceMoneyHeadroom = 2, -- still place if money >= headroom * cheapest upgrade
	-- dynamic threat / farm economy
	EnemyHpPerWave = 40, -- last-resort HP estimate per wave
	PathLength = 180, -- fallback path length if the path cache is empty
	MinDefenseSafety = 2,
	MaxDefenseSafety = 6,
	MinCombatBeforeFarms = 2, -- floor; real value = lanes + 2
	MaxCombatBeforeFarms = 6,
	FarmCopies = 5, -- max copies of EACH farm unit to place (also capped by the unit's spawn cap)
	AoeDefaultRadius = 4, -- fallback AoE radius when an attack has an aoe but no size field
	-- placement: must reach the path, then prefer the scan center
	RangeSafety = 0.8, -- max distance from node to path as a fraction of range
	PathProximityWeight = 0.25, -- secondary: closer to path is better
	DistanceWeight = 1, -- primary: closest to scan center wins
	MaxPlaceRadius = 28, -- combat units: studs from the scan center
	MaxFarmPlaceRadius = 45, -- farms may sit outside the combat ring
	HitboxPadding = 0, -- studs added to every _hitbox radius when testing nodes
	-- wait-or-spend planning: save for the best DPS purchase when it is worth it
	WaitEnabled = true,
	IncomeWindow = 20, -- seconds of income history used for the rate
	IncomeMinSeconds = 3, -- need this much history before trusting the rate
	MaxWaitSeconds = 30, -- never save longer than this for one purchase
	PlanHorizon = 90, -- seconds a purchase is assumed to keep paying off
	SecondsPerWave = 30, -- fallback until real wave lengths are measured
	FarmSpendPaybackFactor = 0.5, -- farm buys must repay within this fraction of the horizon
	PlaceFirstUntilFull = true, -- always place while any unit can still be placed; upgrade only once the roster is full
	PlacePreference = 1.25, -- bias toward placing another unit over upgrading (value multiplier)
	UnreachedGainFactor = 0.3, -- a placement that cannot reach the lane counts this much of its DPS
	ClaimSeconds = 3, -- temporary claim on a node while a spawn replicates
	RejectCooldown = 10, -- skip a node this long after the server rejects a spawn there
	BlockedCooldown = 20, -- skip a node this long after the pre-spawn probe blocks it
	ClusterRadius = 6, -- studs: units within this distance count as neighbors
	FallbackPathWeight = 10, -- no node reaches the lane: each stud closer to it is worth this much
	FallbackDistanceWeight = 0.1, -- ...and centre distance only breaks ties
	MarginalReachPenalty = 40, -- node reaches the lane only at the edge of the range
	OutsideRadiusPenalty = 300, -- reaching nodes beyond MaxPlaceRadius rank below all inside it
	CoverageWeight = 0.5, -- score per stud of lane a node covers with the unit's range
	HitboxHeightTolerance = 4, -- studs of slack along the cylinder axis (multi-level maps)
	PlaceHeightOffset = 0, -- 0 = place on the ground surface, not on the floating marker
	ShowQueueArrows = true,
}

PlaceConfig.ShowVisuals = Config.ShowVisuals -- master switch from the Kaitun config

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
	Occupied = {},
	UnitCenters = {},
	Neighbors = {},
	IncomeSamples = {},
	IncomeLast = nil,
	IncomeStart = nil,
	WaveClock = { Wave = nil, Time = nil, Durations = {} },
	Target = nil,
	LastWaitLog = 0,
	PathLines = {},
	Samples = nil,
	NodeGrid = nil,
	OccupiedAt = 0,
	UnitCounts = {},
	UnitRanges = {},
	FarmStats = {},
	Enemies = setmetatable({}, { __mode = "k" }),
	EnemyWatch = setmetatable({}, { __mode = "k" }),
	PathEnd = nil,
	PathPoints = {},
	ScanCenter = nil,
	ScanCenterDistance = 0,
	AttackData = nil,
	UpgradeAt = setmetatable({}, { __mode = "k" }),
	LastUpgradeWarn = 0,
	LastUpgradeDiag = 0,
	LastWave = 0,
	LastMatchActive = false,
	LastMapId = nil,
	LastDefenseDiag = 0,
	Defense = nil,
	Queue = { Place = nil, Upgrade = nil, Upgrades = {} },
	Core = nil,
	Paths = nil,
	Grid = nil,
	Slots = {}, -- equipped UUID -> spawn_units GUI slot (unique-trait check)
	Live = {}, -- equipped UUID -> live _stats of its placed model
}

-- Taken/rejected nodes are excluded from placement, but their marker stays on
-- the map — same as auto_place.lua. Destroying the dot here made occupied
-- spots look like the scan never found nodes there. Recolor instead so the
-- full scanned grid stays visible.
local VisualTakenColor = Color3.fromRGB(120, 160, 180)

-- A claim is TEMPORARY (Used[Node] = expiry time). It only covers a spawn that
-- is in flight or was just rejected; it never outlives the unit, so selling a
-- unit always returns its node to the original state.
function Placer.Retire(Node, Duration)
	Placer.Used[Node] = os.clock() + (Duration or PlaceConfig.ClaimSeconds)
	if Node.Dot and Node.Dot.Parent then
		Node.Dot.Color = VisualTakenColor
		Node.Dot.Transparency = 0.85
	end
end

function Placer.IsUsed(Node)
	local Expiry = Placer.Used[Node]
	if not Expiry then
		return false
	end
	if Expiry <= os.clock() then
		Placer.Used[Node] = nil
		return false
	end
	return true
end

-- Path geometry ------------------------------------------------------------
-- Lanes are kept as separate polylines. The old code concatenated every lane
-- into one list, which created fake segments joining the end of one lane to the
-- start of the next and corrupted every distance measured against it.
local SampleStep = 2 -- studs between samples along a lane

function Placer.SetPathLines(Lines)
	Placer.PathLines = Lines or {}
	Placer.Samples = nil
end

-- true XZ distance from a point to the nearest lane segment
function Placer.PathDistanceXZ(Position)
	local Best = math.huge
	local Px, Pz = Position.X, Position.Z
	for _, Line in ipairs(Placer.PathLines) do
		for Index = 1, #Line - 1 do
			local A, B = Line[Index], Line[Index + 1]
			local Abx, Abz = B.X - A.X, B.Z - A.Z
			local Apx, Apz = Px - A.X, Pz - A.Z
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

-- evenly spaced points along every lane (built once per scan)
function Placer.GetSamples()
	if Placer.Samples then
		return Placer.Samples
	end
	local Out = {}
	for _, Line in ipairs(Placer.PathLines) do
		for Index = 1, #Line - 1 do
			local A, B = Line[Index], Line[Index + 1]
			local Length = math.sqrt((B.X - A.X) ^ 2 + (B.Z - A.Z) ^ 2)
			local Steps = math.max(1, math.ceil(Length / SampleStep))
			for Step = 0, Steps - 1 do
				local T = Step / Steps
				Out[#Out + 1] = { X = A.X + (B.X - A.X) * T, Z = A.Z + (B.Z - A.Z) * T }
			end
		end
	end
	Placer.Samples = Out
	return Out
end

-- studs of lane inside a circle of Range around Position: how long a unit
-- standing there can actually shoot at enemies. math.huge = no path data.
function Placer.PathCoverage(Position, Range)
	local Samples = Placer.GetSamples()
	if #Samples == 0 then
		return math.huge
	end
	local R2 = Range * Range
	local Count = 0
	for _, Sample in ipairs(Samples) do
		local Dx, Dz = Sample.X - Position.X, Sample.Z - Position.Z
		if Dx * Dx + Dz * Dz <= R2 then
			Count += 1
		end
	end
	return Count * SampleStep
end

-- cached per node and range bucket (nodes and lanes are static between scans)
function Placer.NodeCoverage(Node, Range)
	local Cache = Node.CoverageCache
	if not Cache then
		Cache = {}
		Node.CoverageCache = Cache
	end
	local Key = math.floor(Range * 2 + 0.5)
	local Value = Cache[Key]
	if Value == nil then
		Value = Placer.PathCoverage(Node.Position, Range)
		Cache[Key] = Value
	end
	return Value
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

-- XZ distance from a point to an oriented part's box. Works for road plates
-- and for unit _hitbox rods (which are much wider than the node spacing).
local function DistToPartXZ(Position, Part)
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
		if DistToPartXZ(Position, Part) <= 0.01 then
			return true
		end
	end
	return false
end

-- workspace:GetPartsInPart cannot see parts parented to ReplicatedStorage.
-- _bounds normally lives there, so we must temporarily move it under workspace.
-- Never rely on the game's `ignore` folder — it disappears between maps, which
-- silently disabled all bounds blocking and made every node look valid.

-- Unit hitboxes are NOT part of this static test: they come and go, so a node
-- under a unit during a scan would stay invalid after the unit is sold. Live
-- occupancy (Placer.RefreshOccupied + the pre-spawn hitbox check) handles units.
local function RunBlockProbe(Positions)
	local Bounds = ReplicatedStorage:FindFirstChild("_bounds")
	local Road = workspace:FindFirstChild("_road")

	local OriginalParent = Bounds and Bounds.Parent or nil
	-- no holder folder: _bounds is parented straight to workspace for the query
	local Moved = false
	if Bounds and Bounds.Parent ~= workspace then
		Bounds.Parent = workspace
		Moved = true
	end

	local Restored = {}
	local function EnableQuery(R, OnlyHitbox)
		for _, Part in ipairs(R:GetDescendants()) do
			if Part:IsA("BasePart") and (not OnlyHitbox or Part.Name == "_hitbox") and not Part.CanQuery then
				Part.CanQuery = true
				Restored[#Restored + 1] = Part
			end
		end
	end
	if Bounds then
		EnableQuery(Bounds, false)
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
	for _, Item in ipairs({ Bounds, Road }) do
		if Item then
			Filter[#Filter + 1] = Item
		end
	end
	Overlap.FilterDescendantsInstances = Filter

	local Offset = Vector3.new(0, ProbeSize.Y / 2 + 0.1, 0)
	local Results = {}
	for Index, Position in ipairs(Positions) do
		Probe.CFrame = CFrame.new(Position + Offset)
		local Blocked = false
		for _, Touched in ipairs(workspace:GetPartsInPart(Probe, Overlap)) do
			local Invalid = false
			if (Road and Touched:IsDescendantOf(Road)) or (Bounds and Touched:IsDescendantOf(Bounds)) then
				Invalid = true
			end
			if Invalid then
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

local function ValidateNodes(Nodes)
	if #Nodes == 0 then
		return
	end
	local Positions = {}
	for _, Node in ipairs(Nodes) do
		Positions[#Positions + 1] = Node.Position
	end
	local Results = RunBlockProbe(Positions)
	for Index, Node in ipairs(Nodes) do
		Node.Valid = not Results[Index]
	end
end

-- Final safety check at the exact CFrame we are about to send to the server.
local function IsSpotBlocked(Position)
	return RunBlockProbe({ Position })[1] == true
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
	local FarmOuter = PlaceConfig.RadiusGround + PlaceConfig.RadiusFarm
	local MaxRadius = math.max(PlaceConfig.RadiusGround, PlaceConfig.RadiusHill, FarmOuter)
	for Gx = -MaxRadius, MaxRadius, PlaceConfig.NodeSpacing do
		for Gz = -MaxRadius, MaxRadius, PlaceConfig.NodeSpacing do
			local D2 = Gx * Gx + Gz * Gz
			if D2 <= MaxRadius * MaxRadius then
				local Origin = Center + Vector3.new(Gx, RayHeight, Gz)
				local Hit = Placer.Core.raycast(Origin, Vector3.new(0, -RayHeight * 2, 0))
				local Instance_ = Hit and Hit.Instance
				local Kind = TerrainKind(Instance_)
				local NodeRadius = Kind == "hill" and PlaceConfig.RadiusHill or PlaceConfig.RadiusGround
				local KindOk = D2 <= NodeRadius * NodeRadius
				local FarmZone = Kind == "ground"
					and D2 > PlaceConfig.RadiusGround * PlaceConfig.RadiusGround
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
							Hit.Position + Vector3.new(0, PlaceConfig.PlaceHeightOffset, 0),
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
	if not PlaceConfig.ShowVisuals then
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
			{ Radius = PlaceConfig.RadiusGround, Color = VisualRingColor },
		}
		if PlaceConfig.RadiusHill ~= PlaceConfig.RadiusGround then
			Rings[#Rings + 1] = { Radius = PlaceConfig.RadiusHill, Color = VisualKindColors.hill }
		end
		local FarmRingDrawn = false
		for _, Ring in ipairs(Rings) do
			if math.abs(Ring.Radius - PlaceConfig.RadiusFarm) < 0.01 then
				FarmRingDrawn = true
			end
		end
		if not FarmRingDrawn and PlaceConfig.RadiusFarm > PlaceConfig.RadiusGround then
			Rings[#Rings + 1] = { Radius = PlaceConfig.RadiusFarm, Color = VisualFarmRingColor }
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
				CFrame = CFrame.new(Node.Position + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.rad(90)),
				Color = Color,
				Transparency = Transparency,
			})
			Dot.Parent = Folder
			Node.Dot = Dot
			Node.BaseDotColor = Color
			Node.BaseDotTransparency = Transparency
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
	local PathLines = {}
	for _, Path in ipairs(Paths) do
		local Line = {}
		for _, Point in ipairs(Path.Points) do
			PathPoints[#PathPoints + 1] = Point.position
			Line[#Line + 1] = Point.position
		end
		PathLines[#PathLines + 1] = Line
	end
	Placer.PathPoints = PathPoints
	Placer.SetPathLines(PathLines)

	local All = {}
	local Lanes = {}
	Placer.ScanCenter = nil
	Placer.ScanCenterDistance = 0
	for _, Path in ipairs(Paths) do
		-- the last path point is the enemy's goal (the base)
		if #Path.Points > 0 then
			Placer.PathEnd = Path.Points[#Path.Points].position
		end
		local Distance = Path.Total * math.clamp(PlaceConfig.Percent, 0, 100) / 100
		local Center = PointAtDistance(Path.Points, Distance)
		-- the scan center is our defended line: only enemies PAST this point
		-- on the way to the base count as leaks
		if not Placer.ScanCenter then
			Placer.ScanCenter = Center
			Placer.ScanCenterDistance = Distance
		end
		local EnemyDir = PointAtDistance(Path.Points, math.max(0, Distance - 15))
		local Nodes = ScanCircle(Center, EnemyDir, RoadParts)
		ValidateNodes(Nodes)
		MarkLedges(Nodes)
		local LaneNodes = {}
		for _, Node in ipairs(Nodes) do
			local Best, BestXZ = math.huge, math.huge
			for _, Point in ipairs(PathPoints) do
				local Dx, Dy, Dz = Node.Position.X - Point.X, Node.Position.Y - Point.Y, Node.Position.Z - Point.Z
				local D2 = Dx * Dx + Dy * Dy + Dz * Dz
				if D2 < Best then
					Best = D2
				end
				local XZ = Dx * Dx + Dz * Dz
				if XZ < BestXZ then
					BestXZ = XZ
				end
			end
			Node.PathDist = math.sqrt(Best)
			local SegmentXZ = Placer.PathDistanceXZ(Node.Position)
			Node.PathDistXZ = SegmentXZ < math.huge and SegmentXZ or math.sqrt(BestXZ)
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

-- unit classification — real fields from Loader.load_data(nil, "Units")
local function IsFarmUnit(UnitId)
	local Def = Units[UnitId]
	if type(Def) ~= "table" then
		return false
	end
	if Def.farm_amount ~= nil or Def._show_as_farm_unit == true then
		return true
	end
	if type(Def.end_of_wave) == "table" then
		for _, Entry in pairs(Def.end_of_wave) do
			if type(Entry) == "table" and Entry.type == "farm" then
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

-- hill_unit = hill only; hybrid_placement = either terrain
-- Sub-scope (200-local limit): exported onto Placer below.
do
local function CanPlaceOn(UnitId, Kind)
	local Def = Units[UnitId]
	if type(Def) ~= "table" then
		return Kind == "ground"
	end
	if Def.hybrid_placement == true then
		return true
	end
	return (Def.hill_unit == true) == (Kind == "hill")
end

-- Equipped UUID -> spawn_units GUI slot. The slot attribute uses the exact
-- same UUID string (with braces) as profile_data.collection.equipped_units.
local function RefreshSpawnSlots()
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
	Placer.Slots = Slots
end

local function SlotFor(UnitId, Uuid)
	if Uuid and Placer.Slots[Uuid] then
		return Placer.Slots[Uuid]
	end
	local Def = Units[UnitId]
	local Name = type(Def) == "table" and Def.name or nil
	if Name then
		for _, Slot in pairs(Placer.Slots) do
			local Label = Slot:FindFirstChild("name")
			if Label and Label:IsA("TextLabel") and Label.Text == Name then
				return Slot
			end
		end
	end
	return nil
end

Placer.CanPlaceOn = CanPlaceOn
Placer.RefreshSpawnSlots = RefreshSpawnSlots
Placer.SlotFor = SlotFor
end -- end placement helper sub-scope

-- Cap comes from Units[UnitId].spawn_cap. The ONLY override is the `unique`
-- trait icon at PlayerGui.spawn_units.Lives.Frame.Units["N"].Main.TraitIcons.unique
-- which forces 1 placement (e.g. eren: data says 2, unique makes it 1).
-- max_spawn_units is a minion count and is never used here.
local function SpawnCap(UnitId, Uuid)
	local Slot = Placer.SlotFor(UnitId, Uuid)
	if Slot then
		local Main = Slot:FindFirstChild("Main")
		local Icons = Main and Main:FindFirstChild("TraitIcons")
		local Unique = Icons and Icons:FindFirstChild("unique")
		if Unique and Unique:IsA("GuiObject") and Unique.Visible then
			return 1
		end
	end
	local Def = Units[UnitId]
	if type(Def) == "table" and type(Def.spawn_cap) == "number" then
		return Def.spawn_cap
	end
	return nil
end

local function UnitCost(UnitId)
	local Def = Units[UnitId]
	if type(Def) == "table" and type(Def.cost) == "number" then
		return Def.cost
	end
	return nil
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
	local Entry = Def.upgrade[Level + 1] -- contiguous numeric array, no string keys
	if type(Entry) ~= "table" or type(Entry.cost) ~= "number" then
		return nil
	end
	return Entry.cost
end

local function GetMoney()
	local Stats = Player:FindFirstChild("_stats")
	local Value = Stats and Stats:FindFirstChild("resource")
	return Value and Value:IsA("ValueBase") and Value.Value or nil
end

-- Money changes between building the queue and invoking the server (and
-- between two upgrades in one tick), so re-check immediately before every
-- spend. If the stat is not replicated yet we treat it as unaffordable rather
-- than firing a request that would only be rejected.
local function CanAfford(Cost)
	local Money = GetMoney()
	return Money ~= nil and Money >= Cost
end

local function GetWave()
	local Value = workspace:FindFirstChild("_wave_num")
	return Value and Value:IsA("ValueBase") and Value.Value or nil
end

-- The live map's wave count lives in Waves[Loader.LevelData.waves].waves.
-- Story maps have a fixed count (e.g. namek_level_1 = 15); infinite maps have
-- no max, so return nil and let the configured fallback take over.
local WavesData
local function GetMaxWave()
	local Key = Loader.LevelData and Loader.LevelData.waves
	if not Key then
		return nil
	end
	if not WavesData then
		local Ok, Data = pcall(function()
			return Loader.load_data(nil, "Waves")
		end)
		if Ok and type(Data) == "table" then
			WavesData = Data
		end
	end
	local Def = WavesData and WavesData[Key]
	-- story levels can be `{ template = "aot_level_1", override_waves = {...} }`
	-- instead of carrying their own wave list — follow the template chain.
	local Seen = {}
	while type(Def) == "table" and Def.template and not Def.waves and not Def.infinite do
		if Seen[Def.template] then
			break
		end
		Seen[Def.template] = true
		Def = WavesData[Def.template]
	end
	if type(Def) ~= "table" or Def.infinite then
		return nil
	end
	if type(Def.waves) ~= "table" then
		if type(Def.override_waves) == "table" then
			local N = 0
			for _ in pairs(Def.override_waves) do N = N + 1 end
			return N > 0 and N or nil
		end
		return nil
	end
	local Max = #Def.waves
	if Max == 0 then
		for _ in pairs(Def.waves) do
			Max = Max + 1
		end
	end
	return Max > 0 and Max or nil
end

-- Enemy-path length straight from the game's path cache.
local function GetPathLength()
	local Total = 0
	for _, Path in ipairs(GetPvePaths()) do
		if type(Path.Total) == "number" and Path.Total > Total then
			Total = Path.Total
		end
	end
	return Total > 0 and Total or nil
end

-- Expected enemy HP for this wave, from the resolved wave definition and the
-- map's difficulty scaling. Live enemy health always wins when present.
local GameSettings
local function GetExpectedEnemyHp()
	local Wave = tonumber(GetWave()) or 1
	local Key = Loader.LevelData and Loader.LevelData.waves
	local Def = WavesData and WavesData[Key]
	local Seen = {}
	while type(Def) == "table" and Def.template and not Def.waves do
		if Seen[Def.template] then
			break
		end
		Seen[Def.template] = true
		Def = WavesData[Def.template]
	end
	local Base = PlaceConfig.EnemyHpPerWave * Wave
	if type(Def) == "table" and type(Def.waves) == "table" then
		local W = Def.waves[Wave]
		if type(W) == "table" then
			Base = Base * (1 + (tonumber(W.wave_diff_scale) or 0.5))
		end
	end
	if not GameSettings then
		local Ok, Data = pcall(function()
			return Loader.load_data(nil, "GameplaySettings")
		end)
		if Ok and type(Data) == "table" then
			GameSettings = Data
		end
	end
	local Diff = Loader.LevelData and Loader.LevelData._difficulty
	local Scales = GameSettings and GameSettings.DIFFICULTY_HEALTH_SCALES
	if Diff and type(Scales) == "table" then
		local S = Scales[Diff]
		if type(S) == "table" then
			S = S.health or S.Health or S.value or S.multiplier
		end
		if tonumber(S) then
			Base = Base * tonumber(S)
		end
	end
	return Base
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

-- Live units carry their real attack range in _stats.range (the upgraded
-- value). Prefer it over the static Units data so long-range units can use
-- wider nodes and short-range ones get pulled tight to the lane.
local function RefreshUnitRanges()
	local Ranges = {}
	local Folder = workspace:FindFirstChild("_UNITS")
	if Folder then
		for _, Model in ipairs(Folder:GetChildren()) do
			local Id = ModelUnitId(Model)
			if Id and Ranges[Id] == nil then
				local Value = StatValue(Model, "range") or StatValue(Model, "range")
				if Value ~= nil then
					Ranges[Id] = tonumber(Value)
				end
			end
		end
	end
	Placer.UnitRanges = Ranges
end

-- Live farm units expose their current yen-per-wave in _stats.farm_amount.
local function RefreshFarmStats()
	local Stats = {}
	local Folder = workspace:FindFirstChild("_UNITS")
	if Folder then
		for _, Model in ipairs(Folder:GetChildren()) do
			local Id = ModelUnitId(Model)
			if Id and Stats[Id] == nil then
				local Value = StatValue(Model, "farm_amount")
				if Value ~= nil then
					Stats[Id] = tonumber(Value)
				end
			end
		end
	end
	Placer.FarmStats = Stats
end

-- Level 0 = base def. Level N = base def with upgrade[1..N] applied in order;
-- entries are partial deltas and later levels do NOT repeat earlier fields.
local function StatsAt(UnitId, Level)
	local Def = Units[UnitId]
	if type(Def) ~= "table" then
		return nil
	end
	if Level <= 0 or type(Def.upgrade) ~= "table" then
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

-- Farm ROI: extra yen per wave, what that upgrade costs, and how many waves
-- are left to earn it back. Higher `value` = better investment.
local function FarmRoi(UnitId, Level, Cost, Model)
	-- read the copy's own yield: FarmStats only holds the first copy found
	local Cur = Model and tonumber(StatValue(Model, "farm_amount"))
	if Cur == nil then
		Cur = Placer.FarmStats and Placer.FarmStats[UnitId]
	end
	if Cur == nil then
		Cur = tonumber((StatsAt(UnitId, Level) or {}).farm_amount) or 0
	end
	local Next = tonumber((StatsAt(UnitId, Level + 1) or {}).farm_amount) or Cur
	local Delta = Next - Cur
	local Payback = Delta > 0 and Cost / math.max(Delta, 0) or math.huge
	local MaxWave = GetMaxWave() or PlaceConfig.EstimatedWaves
	local Remaining = math.max(0, MaxWave - (GetWave() or 1))
	local Horizon = math.min(Remaining, 10)
	return {
		delta = Delta, payback = Payback, remaining = Remaining, horizon = Horizon,
		value = Delta * Horizon / math.max(Cost, 1),
	}
end


-- True distance from a position to the path centerline (point-to-segment,
-- not nearest path point — the points are ~18 studs apart, so using points
-- alone badly overestimates the distance for nodes beside the lane).
local function DistanceToPath(Position)
	return Placer.PathDistanceXZ(Position)
end

-- Combat placement, in priority order:
--   1. the unit's range must REACH the lane (path within Range * RangeSafety);
--      among those nodes the one closest to the scan centre wins, with lane
--      coverage as a mild tie-break;
--   2. nodes that only just reach the lane (within full Range) rank below clean
--      reach by a small margin;
--   3. if no node reaches, the node closest to the lane wins (centre distance
--      only breaks ties).
-- Returns the score and whether the node reaches the lane.
local function NodeFitScore(Node, UnitId, Farm)
	local Dist = math.sqrt(Node.Gx * Node.Gx + Node.Gz * Node.Gz)
	if Farm then
		return -Dist * PlaceConfig.PlacePathWeight + (Node.FarmZone and 25 or 0), true
	end

	local Range = Placer.UnitRanges and Placer.UnitRanges[UnitId]
	if not Range then
		local Def = Units[UnitId]
		Range = tonumber(Def and Def.range) or PlaceConfig.DefaultRange
	end
	local PathDist = Node.PathDistXZ or DistanceToPath(Node.Position)
	local SafeReach = Range * PlaceConfig.RangeSafety

	if PathDist > Range then
		-- cannot hit the lane from here: closest to the lane first
		return -PlaceConfig.OutOfRangePenalty - (PathDist - SafeReach) * PlaceConfig.FallbackPathWeight
			- Dist * PlaceConfig.FallbackDistanceWeight, false
	end

	local Score = -Dist * PlaceConfig.DistanceWeight - PathDist * PlaceConfig.PathProximityWeight
	if PathDist > SafeReach then
		Score = Score - PlaceConfig.MarginalReachPenalty
	end
	local Coverage = Placer.NodeCoverage(Node, Range)
	if Coverage == math.huge then
		Coverage = 0
	end
	Score = Score + math.min(Coverage, Range * 1.2) * PlaceConfig.CoverageWeight
	if Dist > PlaceConfig.MaxPlaceRadius then
		Score = Score - PlaceConfig.OutsideRadiusPenalty - (Dist - PlaceConfig.MaxPlaceRadius)
	end
	if IsBuffUnit(UnitId) then
		Score = Score + 10
	end
	local Neighbors = Placer.Neighbors[Node] or 0
	return Score + math.min(Neighbors, 6) * PlaceConfig.ClusterWeight, true
end

local function WithinPlaceRadius(Node, Farm)
	local Limit = Farm and PlaceConfig.MaxFarmPlaceRadius or PlaceConfig.MaxPlaceRadius
	return Node.Gx * Node.Gx + Node.Gz * Node.Gz <= Limit * Limit
end

local function PickNode(Pool, UnitId, Farm)
	local Best, BestScore, BestReaches
	for _, Node in ipairs(Pool) do
		local ZoneOk
		if Farm then
			ZoneOk = Node.FarmZone and WithinPlaceRadius(Node, true)
		else
			ZoneOk = Node.KindOk -- combat radius is a soft penalty in NodeFitScore
		end
		if Node.Valid and ZoneOk and not Placer.NodeBusy(Node) then
			local Score, Reaches = NodeFitScore(Node, UnitId, Farm)
			if not BestScore or Score > BestScore then
				Best, BestScore, BestReaches = Node, Score, Reaches
			end
		end
	end
	return Best, BestReaches
end

local function NodesFor(UnitId)
	local Farm = IsFarmUnit(UnitId)
	local Pool = {}
	for _, Node in ipairs(Placer.Nodes) do
		local TerrainOk = Farm
			and Node.Kind == PlaceConfig.FarmTerrain
			or not Farm and Placer.CanPlaceOn(UnitId, Node.Kind)
		if Node.BaseValid and TerrainOk then
			Pool[#Pool + 1] = Node
		end
	end
	return Pool, Farm
end

-- nearest scanned node to a fixed placement slot (used or not). Callers must
-- pass a unit's stable anchor, never its animated pivot. A unit occupies only
-- the single node of its formation slot; neighbors stay free.
function Placer.NearestNode(Position)
	local Best, BestD
	for _, Node in ipairs(Placer.NodesNear(Position, PlaceConfig.NodeSpacing)) do
		local Dx, Dz = Node.Position.X - Position.X, Node.Position.Z - Position.Z
		local D = Dx * Dx + Dz * Dz
		if not BestD or D < BestD then
			Best, BestD = Node, D
		end
	end
	return Best
end

-- The model pivot follows the unit's walk/attack animation, so reading it for
-- occupancy makes the animated position drift onto neighboring nodes and burn
-- them permanently. The game stores the fixed placement slot in
-- _stats.formation_goal (a Part in workspace.ignore); fall back to the unit's
-- _hitbox, and only then to the pivot. Summoned/path units are skipped — they
-- move along the lane and have no fixed slot.
local function UnitAnchorPosition(Model)
	local Stats = Model:FindFirstChild("_stats")
	if Stats then
		local Parent = Stats:FindFirstChild("parent_unit")
		if Parent and Parent:IsA("ObjectValue") and Parent.Value ~= nil then
			return nil
		end
	end
	-- the game keeps a fixed _hitbox rod at the placement spot; use it first
	-- because the model pivot animates while this stays put
	local Hitbox = Model:FindFirstChild("_hitbox", true)
	if Hitbox and Hitbox:IsA("BasePart") then
		return Hitbox.Position
	end
	local Goal = Stats and Stats:FindFirstChild("formation_goal")
	local Slot = Goal and Goal:IsA("ObjectValue") and Goal.Value
	if Slot and (Slot:IsA("BasePart") or Slot:IsA("Model")) then
		local Ok, Cf = pcall(function()
			return Slot:GetPivot()
		end)
		if Ok and Cf then
			return Cf.Position
		end
	end
	local Ok, Cf = pcall(function()
		return Model:GetPivot()
	end)
	return Ok and Cf and Cf.Position or nil
end

-- Unit hitboxes ------------------------------------------------------------
-- Every unit carries a `_hitbox` CYLINDER. Its real footprint is what blocks a
-- node, so occupancy is computed from that part's own CFrame and Size only —
-- never a fixed radius, never a fixed axis.
--
-- Roblox cylinders run along the part's local X axis (Size.X = length,
-- Size.Y / Size.Z = the two diameters), and the game usually rotates them
-- upright. The old code tested local X/Z with Size.X as the radius, which is
-- the length axis, so rotated hitboxes were measured with the wrong numbers.
-- Here we find the length axis, test the node against the elliptical disc
-- perpendicular to it, then bound the node along the axis.

local IndexCell = 5

local function CellKey(Cx, Cz)
	return Cx * 65536 + Cz
end

-- spatial hash of the scanned nodes: occupancy / nearest-node queries only
-- touch the few cells around a point instead of every node
function Placer.NodeIndex()
	local Nodes = Placer.Nodes
	local Index = Placer.NodeGrid
	if Index and Index.Source == Nodes and Index.Count == #Nodes then
		return Index
	end
	Index = { Source = Nodes, Count = #Nodes, Cells = {} }
	for _, Node in ipairs(Nodes) do
		local Key = CellKey(math.floor(Node.Position.X / IndexCell), math.floor(Node.Position.Z / IndexCell))
		local Cell = Index.Cells[Key]
		if not Cell then
			Cell = {}
			Index.Cells[Key] = Cell
		end
		Cell[#Cell + 1] = Node
	end
	Placer.NodeGrid = Index
	return Index
end

-- every node whose centre is within Radius (XZ) of Position
function Placer.NodesNear(Position, Radius)
	local Out = {}
	local Cells = Placer.NodeIndex().Cells
	local MinX = math.floor((Position.X - Radius) / IndexCell)
	local MaxX = math.floor((Position.X + Radius) / IndexCell)
	local MinZ = math.floor((Position.Z - Radius) / IndexCell)
	local MaxZ = math.floor((Position.Z + Radius) / IndexCell)
	local R2 = Radius * Radius
	for Cx = MinX, MaxX do
		for Cz = MinZ, MaxZ do
			local Cell = Cells[CellKey(Cx, Cz)]
			if Cell then
				for _, Node in ipairs(Cell) do
					local Dx = Node.Position.X - Position.X
					local Dz = Node.Position.Z - Position.Z
					if Dx * Dx + Dz * Dz <= R2 then
						Out[#Out + 1] = Node
					end
				end
			end
		end
	end
	return Out
end

local function Component(Vector, Axis)
	if Axis == 1 then
		return Vector.X
	elseif Axis == 2 then
		return Vector.Y
	end
	return Vector.Z
end

-- precompute everything a point test needs from one _hitbox part
local function BuildHitbox(Part)
	local Cf, Size = Part.CFrame, Part.Size
	local Axis
	if Part.Shape == Enum.PartType.Cylinder then
		Axis = 1
	else
		-- not a Cylinder shape: treat the most vertical local axis as the length
		local Best = -1
		for Index, Vector in ipairs({ Cf.RightVector, Cf.UpVector, Cf.LookVector }) do
			local Dot = math.abs(Vector.Y)
			if Dot > Best then
				Best, Axis = Dot, Index
			end
		end
	end
	local Ia, Ib
	if Axis == 1 then
		Ia, Ib = 2, 3
	elseif Axis == 2 then
		Ia, Ib = 1, 3
	else
		Ia, Ib = 1, 2
	end
	local Pad = PlaceConfig.HitboxPadding or 0
	local Ra = math.max(Component(Size, Ia) / 2 + Pad, 0.05)
	local Rb = math.max(Component(Size, Ib) / 2 + Pad, 0.05)
	local Half = Component(Size, Axis) / 2 + (PlaceConfig.HitboxHeightTolerance or 0)
	local Center = Part.Position
	return {
		Part = Part,
		Inverse = Cf:Inverse(),
		Axis = Axis, Ia = Ia, Ib = Ib,
		Ra = Ra, Rb = Rb, Half = Half,
		Center = Center,
		-- bounding sphere, used only to pick which nodes are worth testing
		Bound = math.sqrt(math.max(Ra, Rb) ^ 2 + Half * Half),
	}
end

local function PointInHitbox(Box, Position)
	local Local = Box.Inverse * Position
	local Na = Component(Local, Box.Ia) / Box.Ra
	local Nb = Component(Local, Box.Ib) / Box.Rb
	if Na * Na + Nb * Nb > 1 then
		return false
	end
	return math.abs(Component(Local, Box.Axis)) <= Box.Half
end

-- live hitboxes of every unit model (player units tag + _UNITS folder)
function Placer.CollectHitboxes()
	local Out, Seen = {}, {}
	local function Check(Model)
		if not Model or Seen[Model] or not Model:IsA("Model") or not Model:IsDescendantOf(workspace) then
			return
		end
		local Dead = workspace:FindFirstChild("_DEAD_UNITS")
		if Dead and Model:IsDescendantOf(Dead) then
			return -- sold / killed: its hitbox no longer holds a node
		end
		Seen[Model] = true
		for _, Part in ipairs(Model:GetDescendants()) do
			if Part.Name == "_hitbox" and Part:IsA("BasePart") and Part.Parent then
				Out[#Out + 1] = BuildHitbox(Part)
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
	return Out
end

-- is this exact world point inside any live unit hitbox? (final pre-spawn guard)
function Placer.PointInAnyHitbox(Position)
	for _, Box in ipairs(Placer.CollectHitboxes()) do
		local Dx, Dz = Box.Center.X - Position.X, Box.Center.Z - Position.Z
		if Dx * Dx + Dz * Dz <= Box.Bound * Box.Bound and PointInHitbox(Box, Position) then
			return true
		end
	end
	return false
end

-- fixed centre of a unit's _hitbox (nil when there is none)
local function UnitHitboxPosition(Model)
	local Hitbox = Model:FindFirstChild("_hitbox", true)
	if Hitbox and Hitbox:IsA("BasePart") and Hitbox.Parent then
		return Hitbox.Position
	end
	return nil
end

-- Occupancy is rebuilt from the live hitboxes each pass: a node is occupied
-- when its centre lies inside a hitbox cylinder. Nothing is retired here —
-- occupancy is transient and disappears as soon as the hitbox is gone (unit
-- sold, killed or the match ended), and the node returns to its scan colour.
function Placer.RefreshOccupied(Force)
	local Now = os.clock()
	if not Force and Now - Placer.OccupiedAt < 0.4 then
		return
	end
	Placer.OccupiedAt = Now

	local Occupied, Centers, Neighbors = {}, {}, {}
	for _, Box in ipairs(Placer.CollectHitboxes()) do
		Centers[#Centers + 1] = Box.Center
		for _, Node in ipairs(Placer.NodesNear(Box.Center, Box.Bound)) do
			if not Occupied[Node] and PointInHitbox(Box, Node.Position) then
				Occupied[Node] = true
			end
		end
		for _, Node in ipairs(Placer.NodesNear(Box.Center, PlaceConfig.ClusterRadius)) do
			Neighbors[Node] = (Neighbors[Node] or 0) + 1
		end
	end
	-- a claim only bridges the gap until the new unit's hitbox replicates; once
	-- the hitbox owns the node the claim is dropped, so selling the unit frees it
	for Node in pairs(Occupied) do
		Placer.Used[Node] = nil
	end
	Placer.Occupied = Occupied
	Placer.UnitCenters = Centers
	Placer.Neighbors = Neighbors

	for _, Node in ipairs(Placer.Nodes) do
		local Dot = Node.Dot
		if Dot and Dot.Parent then
			if Occupied[Node] or Placer.IsUsed(Node) then
				Dot.Color = VisualTakenColor
				Dot.Transparency = 0.85
			elseif Node.BaseDotColor then
				Dot.Color = Node.BaseDotColor
				Dot.Transparency = Node.BaseDotTransparency or 0.55
			end
		end
	end
end

-- busy = under a live unit hitbox, or briefly claimed by a spawn in flight
function Placer.NodeBusy(Node)
	return Placer.Occupied[Node] == true or Placer.IsUsed(Node)
end

-- scoring -----------------------------------------------------------------
-- Sub-scope: these helpers are exported onto Placer so their locals do not
-- stay alive in the match scope (Luau allows only 200 active locals per chunk).
do
-- Rarity tier from GameplaySettings.RARITY_TIERS (Secret 6 ... Common 0).
local RarityTiers = type(GameplaySettings.RARITY_TIERS) == "table"
	and GameplaySettings.RARITY_TIERS or {}
local function TierOf(UnitId)
	local Def = Units[UnitId]
	local Tier = type(Def) == "table" and RarityTiers[Def.rarity] or nil
	return type(Tier) == "number" and Tier or -1
end

-- Actual post-scaling stats off placed models. Traits, relics, buffs and
-- level scaling are already baked into _stats.damage / .attack_cooldown / .range.
-- Summons share their owner's uuid, so skip models with a parent_unit.
local function RefreshLiveStats()
	local Live = {}
	local function Add(Model)
		if not (Model and Model:IsA("Model") and Model:IsDescendantOf(workspace)) then
			return
		end
		local Stats = Model:FindFirstChild("_stats")
		if not Stats then
			return
		end
		local Parent = Stats:FindFirstChild("parent_unit")
		if Parent and Parent:IsA("ObjectValue") and Parent.Value ~= nil then
			return
		end
		local Uuid = StatValue(Model, "uuid")
		if type(Uuid) ~= "string" or Live[Uuid] then
			return
		end
		Live[Uuid] = {
			damage = tonumber(StatValue(Model, "damage")),
			attack_cooldown = tonumber(StatValue(Model, "attack_cooldown")),
			range = tonumber(StatValue(Model, "range")),
			level = tonumber(StatValue(Model, "upgrade")),
		}
	end
	local Folder = workspace:FindFirstChild("_UNITS")
	if Folder then
		for _, Model in ipairs(Folder:GetChildren()) do
			Add(Model)
		end
	end
	for _, Model in ipairs(CollectionService:GetTagged("player_units")) do
		Add(Model)
	end
	Placer.Live = Live
end

Placer.TierOf = TierOf
Placer.RefreshLiveStats = RefreshLiveStats
end -- end scoring helper sub-scope

local function DpsOf(Def)
	if type(Def) ~= "table" then
		return 0
	end
	local Damage = tonumber(Def.damage) or 0
	-- attack_cooldown is the real field; a few boss-style defs only have cooldown
	local Cd = tonumber(Def.attack_cooldown)
	if Cd == nil then
		Cd = tonumber(Def.cooldown) or 0
	end
	return Cd > 0 and Damage / Cd or Damage
end

local function UpgradeDefAt(UnitId, Level)
	local Def = Units[UnitId]
	if type(Def) ~= "table" or type(Def.upgrade) ~= "table" then
		return nil
	end
	return Def.upgrade[Level + 1]
end

-- Another sub-scope for the summon/DPS helpers (same 200-local reason).
do
-- Summoned units inherit the SUMMONER's damage scaled by damage_ratio in the
-- attack data. Their own attack_cooldown sets the cadence. This is why a
-- damage=0 summoner (eren) still has a real DPS once its summon is unlocked.
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
				local List = Group[Field]
				if type(List) == "table" then
					for _, Entry in pairs(List) do
						if type(Entry) == "table" then
							local Minion = Units[Entry.unit]
							local Cd = type(Minion) == "table"
								and (tonumber(Minion.attack_cooldown) or tonumber(Minion.cooldown)) or nil
							if Cd and Cd > 0 then
								local Amount = tonumber(Entry.amount) or tonumber(Group.amount) or 1
								local Ratio = tonumber(Entry.damage_ratio) or 1
								Total += Amount * Ratio * Damage / Cd
							end
						end
					end
				end
			end
		end
	end
	return Total
end

-- Stats at Level, optionally rooted at the model's LIVE level so an upgrade
-- delta is applied on top of real stats instead of the static max-level data.
local function StatsAtLive(UnitId, Level, Uuid, LiveLevel)
	local Base = StatsAt(UnitId, LiveLevel and (LiveLevel > 0 and LiveLevel or 0) or 0)
	if type(Base) ~= "table" then
		return nil
	end
	local Copy = {}
	for Key, Value in pairs(Base) do
		Copy[Key] = Value
	end
	local Live = Uuid and Placer.Live[Uuid]
	if Live then
		if Live.damage then
			Copy.damage = Live.damage
		end
		if Live.attack_cooldown and Live.attack_cooldown > 0 then
			Copy.attack_cooldown = Live.attack_cooldown
		end
		if Live.range and Live.range > 0 then
			Copy.range = Live.range
		end
	end
	if LiveLevel and Level > LiveLevel then
		for Index = LiveLevel + 1, Level do
			local Entry = UpgradeDefAt(UnitId, Index - 1)
			if type(Entry) == "table" then
				for Key, Value in pairs(Entry) do
					Copy[Key] = Value
				end
			end
		end
	end
	return Copy
end

-- Own attack + primary summon + active-attack summon, with live stats when
-- a placed copy exists. Returns DPS and range (range weights damage per pass).
local function EffectiveDpsAt(UnitId, Level, Uuid, LiveLevel)
	local Stats = StatsAtLive(UnitId, Level, Uuid, LiveLevel)
	if type(Stats) ~= "table" then
		return 0, 0
	end
	local Total = DpsOf(Stats)
	if Stats.spawn_unit == true or Stats.spawn_script == true then
		local Primary = Stats.primary_attack or Stats.primary_attack_no_upgrades
		if type(Primary) == "string" then
			Total += SummonDps(Stats, Primary)
		end
		if type(Stats.active_attack) == "string" then
			local Active = type(Stats.active_attack_stats) == "table" and Stats.active_attack_stats or {}
			local ActiveCd = tonumber(Active.attack_cooldown)
			local OwnCd = tonumber(Stats.attack_cooldown) or 0
			local Bonus = SummonDps(Stats, Stats.active_attack)
			if ActiveCd and ActiveCd > 0 and OwnCd > 0 then
				Total += Bonus * math.min(1, OwnCd / ActiveCd)
			else
				Total += Bonus
			end
		end
	end
	local Range = tonumber(Stats.range) or tonumber(PlaceConfig.DefaultRange) or 8
	return Total, math.max(Range, 1)
end

-- Max-level DPS for an unplaced/equipped unit (used by placement scoring).
local function EffectiveDpsOf(UnitId, Uuid)
	local Def = Units[UnitId]
	local Level = type(Def) == "table" and type(Def.upgrade) == "table" and #Def.upgrade or 0
	return EffectiveDpsAt(UnitId, Level, Uuid, nil)
end

Placer.SummonDps = SummonDps
Placer.StatsAtLive = StatsAtLive
Placer.EffectiveDpsAt = EffectiveDpsAt
Placer.EffectiveDpsOf = EffectiveDpsOf
end -- end DPS helper sub-scope

-- Which equipped unit to place next. Farm units open the economy, buffs are
-- worth a slot, combat units rank by damage-per-second per yen. Under-used
-- unit ids get a boost so the lineup spreads out.
local function UnitPlaceScore(UnitId, Uuid)
	local Def = Units[UnitId]
	if type(Def) ~= "table" then
		return 0
	end
	local Cost = math.max(tonumber(Def.cost) or 1, 1)
	local Score
	if IsFarmUnit(UnitId) then
		Score = PlaceConfig.PlaceFarmWeight + (tonumber(Def.farm_amount) or 0)
		if PlaceConfig.PlaceStrategy == "farm_first" then
			Score = Score * 10
		end
	elseif IsBuffUnit(UnitId) then
		Score = PlaceConfig.PlaceBuffWeight
	else
		-- effective DPS (own + summons) * range, using live stats when placed
		local Dps, Range = Placer.EffectiveDpsOf(UnitId, Uuid)
		Score = Dps * Range * PlaceConfig.PlaceDpsWeight
			+ Dps / Cost * PlaceConfig.PlaceDpsPerCostWeight
	end
	-- rarity decides order first: Epic before Rare, etc.
	Score = Score + Placer.TierOf(UnitId) * (tonumber(PlaceConfig.PlaceTierWeight) or 1000)
	local Spread = PlaceConfig.PlaceSpreadPenalty
	if PlaceConfig.PlaceStrategy == "role_spread" then
		Spread = Spread * 3
	end
	return Score - (Placer.UnitCounts[UnitId] or 0) * Spread
end

-- Which placed unit to upgrade next.
--  farm:   value = extra yen/wave * waves left / cost. Farm upgrades compound,
--          so a short payback (cost / extra-yen-per-wave) is almost always the
--          best buy early on.
--  combat: value = DPS gain / cost, heavily discounted when the unit's spot
--          is outside its range (an out-of-range upgrade deals no damage).
local function UpgradeScore(Model, UnitId, Level, Cost)
	local Now = os.clock()
	local Wave = GetWave() or 1
	local MaxWave = GetMaxWave() or PlaceConfig.EstimatedWaves
	local Remaining = math.max(1, MaxWave - Wave)
	local Farm = IsFarmUnit(UnitId)
	local Score

	if PlaceConfig.UpgradeStrategy == "spread" then
		Score = -Level * PlaceConfig.UpgradeSpreadWeight
			+ math.min(Now - (Placer.UpgradeAt[Model] or 0), 60) * PlaceConfig.UpgradeRecencyWeight
	elseif PlaceConfig.UpgradeStrategy == "farm_first" then
		Score = (Farm and 1000 or 0) - Level * PlaceConfig.UpgradeSpreadWeight
	else
		if Farm then
			local Roi = FarmRoi(UnitId, Level, Cost, Model)
			if Wave <= PlaceConfig.FarmUpgradeUntilWave and Roi.payback <= Roi.remaining then
				Score = Roi.value * PlaceConfig.FarmUpgradeWeight
			else
				Score = -Roi.payback
			end
			-- never feed the economy while the lane is leaking
			if Placer.Defense and not Placer.Defense.stable then
				Score = Score * 0.1
			end
		else
			-- live stats from this exact copy, with the next upgrade delta
			-- applied on top (not the static max-level guess)
			local Uuid = StatValue(Model, "uuid")
			local CurDps = Placer.EffectiveDpsAt(UnitId, Level, Uuid, Level)
			local NextDps = Placer.EffectiveDpsAt(UnitId, Level + 1, Uuid, Level)
			local Gain = NextDps - CurDps
			Score = Gain / math.max(Cost, 1) * PlaceConfig.CombatUpgradeWeight
			-- scale by how much lane the unit's real position can still reach:
			-- full value at good coverage, 20% when it cannot hit anything
			local Pos = UnitHitboxPosition(Model)
			if Pos then
				local Range = Placer.UnitRanges[UnitId] or PlaceConfig.DefaultRange
				local Fraction = math.min(1, Placer.PathCoverage(Pos, Range) / (Range * 1.2))
				Score = Score * (0.2 + 0.8 * Fraction)
			end
			if Placer.Defense and Placer.Defense.stable then
				-- defense is holding: compound the strongest damage dealers
				Score = Score + NextDps * PlaceConfig.UpgradeRawDpsWeight
			else
				Score = Score * 1.5 -- shore up the defense first
			end
			Score = Score - Level * 2
		end
	end

	if Farm then
		Score = Score + 5
	end
	if IsBuffUnit(UnitId) then
		Score = Score - 5
	end
	-- higher rarity tier is upgraded first (Epic before Rare, etc.)
	Score = Score + Placer.TierOf(UnitId) * (tonumber(PlaceConfig.UpgradeTierWeight) or 1000)
	return Score
end

-- animated queue arrows: same billboard / bob / distance-scaling as the scan
-- center arrow. Green = next placement, orange = next upgrade. They stay up
-- and follow the queue targets instead of flashing during a single action.
local IntentArrows = {}
local IntentColors = {
	place = Color3.fromRGB(80, 255, 140),
	upgrade = Color3.fromRGB(255, 170, 60),
}
local ArrowGlowStuds = 5
local ArrowBaseHeight = 1.5

local function HideIntentArrow(Kind)
	if Kind then
		local State = IntentArrows[Kind]
		if State then
			if State.Connection then
				State.Connection:Disconnect()
			end
			if State.Anchor then
				State.Anchor:Destroy()
			end
			IntentArrows[Kind] = nil
		end
		return
	end
	for Key in pairs(IntentArrows) do
		HideIntentArrow(Key)
	end
end

local function SetIntentArrow(Kind, Position)
	if not Position then
		HideIntentArrow(Kind)
		return
	end
	local State = IntentArrows[Kind]
	if not State then
		local Color = IntentColors[Kind] or Color3.new(1, 1, 1)
		local Anchor = Instance.new("Part")
		Anchor.Name = "AA_IntentArrow"
		Anchor.Anchored = true
		Anchor.CanCollide = false
		Anchor.CanQuery = false
		Anchor.CanTouch = false
		Anchor.CastShadow = false
		Anchor.Transparency = 1
		Anchor.Size = Vector3.new(1, 1, 1)
		Anchor.CFrame = CFrame.new(Position.X, Position.Y + ArrowBaseHeight, Position.Z)
		Anchor.Parent = workspace
		local Billboard = Instance.new("BillboardGui")
		Billboard.Size = UDim2.fromOffset(70, 70)
		Billboard.AlwaysOnTop = true
		Billboard.LightInfluence = 0
		Billboard.MaxDistance = math.huge
		Billboard.Parent = Anchor
		local Glow = Instance.new("ImageLabel")
		Glow.BackgroundTransparency = 1
		Glow.Image = "rbxassetid://81351645241261"
		Glow.ImageTransparency = 0.55
		Glow.ImageColor3 = Color
		Glow.AnchorPoint = Vector2.new(0.5, 0.5)
		Glow.Position = UDim2.fromScale(0.5, 0.5)
		Glow.Size = UDim2.fromScale(1, 1)
		Glow.Parent = Billboard
		local Arrow = Instance.new("ImageLabel")
		Arrow.BackgroundTransparency = 1
		Arrow.Image = "rbxassetid://81256616982657"
		Arrow.ImageTransparency = 0.35
		Arrow.ImageColor3 = Color
		Arrow.AnchorPoint = Vector2.new(0.5, 0.5)
		Arrow.Position = UDim2.fromScale(0.5, 0.5)
		Arrow.Size = UDim2.fromScale(0.31, 0.31)
		Arrow.Rotation = 180
		Arrow.Parent = Billboard
		State = {
			Anchor = Anchor,
			Billboard = Billboard,
			X = Position.X,
			Z = Position.Z,
			BaseY = Position.Y + ArrowBaseHeight,
			T0 = os.clock(),
		}
		local Camera = workspace.CurrentCamera
		State.Connection = RunService.Heartbeat:Connect(function()
			if not Anchor.Parent then
				State.Connection:Disconnect()
				return
			end
			local Bob = math.sin((os.clock() - State.T0) * 3) * 0.5
			Anchor.CFrame = CFrame.new(State.X, State.BaseY + Bob, State.Z)
			local Distance = (Camera.CFrame.Position - Anchor.Position).Magnitude
			local PxPerStud = Camera.ViewportSize.Y
				/ (2 * math.tan(math.rad(Camera.FieldOfView) / 2) * math.max(Distance, 1))
			Billboard.Size = UDim2.fromOffset(ArrowGlowStuds * PxPerStud, ArrowGlowStuds * PxPerStud)
		end)
		IntentArrows[Kind] = State
	else
		local X, Z, BaseY = Position.X, Position.Z, Position.Y + ArrowBaseHeight
		if State.X ~= X or State.Z ~= Z or State.BaseY ~= BaseY then
			State.X, State.Z, State.BaseY = X, Z, BaseY
			State.T0 = os.clock()
			State.Anchor.CFrame = CFrame.new(X, BaseY, Z)
		end
	end
end

-- Are the units on the map strong enough to stop the enemies before they
-- reach the base? Uses live enemy health/speed and our in-range DPS.
local function AssessDefense()
	local MaxHP, MaxSpeed, Count = 0, 2, 0
	local Folder = workspace:FindFirstChild("_UNITS")
	if Folder then
		for _, Model in ipairs(Folder:GetChildren()) do
			if not CollectionService:HasTag(Model, "player_units") then
				local Stats = Model:FindFirstChild("_stats")
				local HP = Stats and Stats:FindFirstChild("health")
				if HP and HP:IsA("ValueBase") then
					Count += 1
					local H = tonumber(HP.Value) or 0
					if H > MaxHP then MaxHP = H end
					local Spd = Stats:FindFirstChild("speed")
					if Spd and Spd:IsA("ValueBase") then
						local S = tonumber(Spd.Value) or 2
						if S > MaxSpeed then MaxSpeed = S end
					end
				end
			end
		end
	end
	if MaxHP > 0 then
		Placer.LastEnemyHP = MaxHP -- remember for gaps between enemy spawns
	else
		MaxHP = Placer.LastEnemyHP or GetExpectedEnemyHp()
	end
	local Dps = 0
	for _, Model in ipairs(PlayerUnitModels()) do
		local UnitId = ModelUnitId(Model)
		if UnitId and not IsFarmUnit(UnitId) then
			local Pos = UnitHitboxPosition(Model)
			local Range = (Placer.UnitRanges and Placer.UnitRanges[UnitId]) or PlaceConfig.DefaultRange
			if not Pos or Placer.PathCoverage(Pos, Range) > 0 then
				Dps = Dps + DpsOf(StatsAt(UnitId, tonumber(StatValue(Model, "upgrade")) or 0))
			end
		end
	end
	local KillTime = MaxHP / math.max(Dps, 0.001)
	local TransitTime = (GetPathLength() or PlaceConfig.PathLength) / math.max(MaxSpeed, 0.1)
	local Safety = math.clamp(PlaceConfig.MinDefenseSafety + math.floor(Count / 3),
		PlaceConfig.MinDefenseSafety, PlaceConfig.MaxDefenseSafety)
	return {
		hp = MaxHP, speed = MaxSpeed, count = Count, dps = Dps,
		killTime = KillTime, transitTime = TransitTime, safety = Safety,
		stable = Dps > 0 and KillTime * Safety <= TransitTime,
	}
end

-- enemy intelligence -------------------------------------------------------
local function GetAttackData()
	if not Placer.AttackData then
		local Ok, Data = pcall(function()
			return Loader.load_data(nil, "Attacks")
		end)
		if Ok and type(Data) == "table" then
			Placer.AttackData = Data
		end
	end
	return Placer.AttackData
end

-- Range, DPS and AoE size for a unit at a given upgrade level.
local function AttackProfile(UnitId, Level)
	local Def = StatsAt(UnitId, Level) or {}
	local Data = GetAttackData()
	local Key = Def.primary_attack_no_upgrades
	local Attack = Key and Data and Data[Key]
	local Range
	if type(Attack) == "table" and type(Attack.range) == "table" then
		Range = tonumber(Attack.range[2])
	end
	local LiveRange = Placer.UnitRanges and Placer.UnitRanges[UnitId]
	Range = LiveRange or Range or tonumber(Def.range) or PlaceConfig.DefaultRange
	local HasAoe = type(Attack) == "table" and type(Attack.aoe) == "table"
	local AoeRadius = 0
	if HasAoe then
		for _, Entry in pairs(Attack.aoe) do
			if type(Entry) == "table" and type(Entry.aoe_type) == "table" then
				for _, V in pairs(Entry.aoe_type) do
					if tonumber(V) and tonumber(V) > AoeRadius then
						AoeRadius = tonumber(V)
					end
				end
			end
		end
		if AoeRadius <= 0 then
			AoeRadius = PlaceConfig.AoeDefaultRadius
		end
	end
	return { range = Range, dps = DpsOf(Def), aoe = HasAoe, aoeRadius = AoeRadius }
end

-- One enemy snapshot: raw stats + mechanics + effective HP + movement.
local function ReadEnemy(Model)
	local Stats = Model:FindFirstChild("_stats")
	if not Stats then
		return nil
	end
	local HP = Stats:FindFirstChild("health")
	if not HP or not HP:IsA("ValueBase") then
		return nil
	end
	local function Num(Name)
		local V = Stats:FindFirstChild(Name)
		return V and V:IsA("ValueBase") and tonumber(V.Value) or 0
	end
	local Prev = Placer.Enemies[Model]
	local ParentRef = Stats:FindFirstChild("parent_unit")
	local Parent = ParentRef and ParentRef:IsA("ObjectValue") and ParentRef.Value or nil
	local Pos = Model:GetPivot().Position
	local E = {
		model = Model,
		id = tostring((Stats:FindFirstChild("id") and Stats.id.Value) or Model.Name),
		hp = tonumber(HP.Value) or 0,
		baseHP = Num("health"),
		shield = Num("shield") + Num("barrier"),
		maxShield = Num("max_shield") + Num("max_barrier"),
		regen = Num("Regen"),
		armor = Num("Armor"),
		damageReduction = Num("damage_reduction"),
		speed = math.max(Num("speed"), 0.1),
		reward = Num("resource_reward"),
		clones = Parent ~= nil or Num("max_spawn_units") > 0,
		invincible = Num("invincible") > 0,
		bend = Num("last_reached_bend"),
		nextBend = Num("next_bend"),
		position = Pos,
		prevPosition = Prev and Prev.position or Pos,
		lastSeen = os.clock(),
		velocity = 0,
		mechanics = {},
	}
	local dt = os.clock() - (Prev and Prev.lastSeen or os.clock())
	if dt > 0.01 then
		E.velocity = (Pos - E.prevPosition).Magnitude / dt
	end
	for _, Name in ipairs({ "Regen", "Armor", "Flying", "Burst", "Soaring",
		"Ice", "Fire", "Water", "Dark", "Lightning", "Air", "buildup_sanity" }) do
		local V = Num(Name)
		if V > 0 then
			E.mechanics[#E.mechanics + 1] = Name .. "=" .. V
		end
	end
	if E.shield > 0 then
		E.mechanics[#E.mechanics + 1] = "shield=" .. E.shield
	end
	if E.clones then
		E.mechanics[#E.mechanics + 1] = "clones"
	end
	-- effective HP: health + shields, armor and regen folded in
	local Effective = E.hp + E.shield
	if E.maxShield > 0 then
		Effective = Effective + E.maxShield * 0.5
	end
	Effective = Effective * (1 + E.armor * 0.01)
	if E.regen > 0 then
		Effective = Effective + E.regen * 5
	end
	E.effectiveHP = Effective
	return E
end

local function RefreshEnemies()
	local Folder = workspace:FindFirstChild("_UNITS")
	if not Folder then
		return
	end
	local Seen = {}
	for _, Model in ipairs(Folder:GetChildren()) do
		if not CollectionService:HasTag(Model, "player_units") then
			local E = ReadEnemy(Model)
			if E then
				Seen[Model] = true
				Placer.Enemies[Model] = E
			end
		end
	end
	for Model in pairs(Placer.Enemies) do
		if not Seen[Model] then
			Placer.Enemies[Model] = nil
		end
	end
end

local function WatchEnemies()
	if Placer.EnemyWatching then
		return
	end
	Placer.EnemyWatching = true
	local function Poke()
		task.defer(RefreshEnemies)
	end
	local function Hook(Folder)
		if not Folder then
			return
		end
		Folder.ChildAdded:Connect(Poke)
		Folder.ChildRemoved:Connect(Poke)
	end
	Hook(workspace:FindFirstChild("_UNITS"))
	workspace.ChildAdded:Connect(function(Child)
		if Child.Name == "_UNITS" then
			Hook(Child)
		end
	end)
end

-- How far along the pve path an enemy is, measured from the enemy spawn.
-- Nearest path point is enough because path points already carry distance.
local function EnemyPathProgress(E)
	local Best, Progress = math.huge, 0
	for _, Path in ipairs(GetPvePaths()) do
		for _, Point in ipairs(Path.Points) do
			local P = Point.position
			local Dx, Dz = E.position.X - P.X, E.position.Z - P.Z
			local D = Dx * Dx + Dz * Dz
			if D < Best then
				Best = D
				Progress = tonumber(Point.distance_from_spawn) or 0
			end
		end
	end
	return Progress
end

-- Enemy snapshot for the defense diagnostic: counts and effective HP only.
local function AssessEnemies()
	RefreshEnemies()
	local Count, TotalHP = 0, 0
	for _, E in pairs(Placer.Enemies) do
		Count += 1
		TotalHP += E.effectiveHP
	end
	return { count = Count, totalHP = TotalHP }
end

-- Put every node marker back to its scan colour. Called when a match ends so
-- retired/taken dots stop looking occupied, and on a fresh match reset.
local function RestoreNodeColors()
	for _, Node in ipairs(Placer.Nodes) do
		if Node.Dot and Node.Dot.Parent and Node.BaseDotColor then
			Node.Dot.Color = Node.BaseDotColor
			Node.Dot.Transparency = Node.BaseDotTransparency or 0.55
		end
	end
end

-- Wipe every piece of match state when a new match / map begins. Without
-- this, dots and used nodes from the previous match linger on the new map.
-- KeepScan: the map was already scanned before the match (visual preview), so
-- keep the nodes, lanes, path data and visuals and only reset match state.
local function ResetForNewMatch(Reason, KeepScan)
	local Keep = KeepScan == true and #Placer.Nodes > 0 and not Placer.NeedScan
	if not Keep then
		Placer.Nodes = {}
		Placer.Lanes = {}
	end
	Placer.Used = {}
	Placer.Occupied = {}
	Placer.IncomeSamples = {}
	Placer.IncomeLast = nil
	Placer.IncomeStart = nil
	Placer.WaveClock = { Wave = nil, Time = nil, Durations = {} }
	Placer.Target = nil
	Placer.UnitCenters = {}
	Placer.Neighbors = {}
	if not Keep then
		Placer.NodeGrid = nil
	end
	Placer.OccupiedAt = 0
	Placer.LastAttempt = {}
	Placer.UpgradeFail = {}
	Placer.UpgradeAt = setmetatable({}, { __mode = "k" })
	Placer.Pending = {}
	Placer.TargetSince = nil
	Placer.TargetFailAt = nil
	Placer.UnitCounts = {}
	Placer.UnitRanges = {}
	Placer.FarmStats = {}
	Placer.Enemies = setmetatable({}, { __mode = "k" })
	Placer.EnemyWatch = setmetatable({}, { __mode = "k" })
	Placer.ModelIds = setmetatable({}, { __mode = "k" })
	if not Keep then
		Placer.PathEnd = nil
		Placer.PathPoints = {}
		Placer.SetPathLines({})
		Placer.ScanCenter = nil
		Placer.ScanCenterDistance = 0
		Placer.NeedScan = true
		Placer.ScanTries = 0
		Placer.LastScan = -100 -- allow an immediate rescan on the next tick
		ClearScanVisuals()
	else
		RestoreNodeColors()
	end
	Placer.Queue = { Place = nil, Upgrade = nil, Upgrades = {} }
	Placer.Fails = 0
	Placer.LastWave = 0
	HideIntentArrow()
	Log("new match (%s) — nodes and state reset", tostring(Reason))
end

-- queue -------------------------------------------------------------------
-- Recompute the next placement and the next upgrade every tick. The arrows
-- preview these targets so the next action is visible before it happens.
-- Economy planning ---------------------------------------------------------
-- Highest-DPS purchase first. When it costs more than we have, compare the
-- cost of WAITING (the target's damage is delayed) against the value of
-- spending on something cheaper now (that purchase pays immediately, but the
-- target is pushed back by cost / income seconds).

-- Action queue ------------------------------------------------------------
-- The queue is rebuilt every tick from live state and holds places AND upgrades
-- in priority order. An entry is only a request: cost, level, money and the
-- spot are all re-read at the moment it runs, so a stale queue can never
-- spend money that is no longer there. A rejected entry is retried straight
-- away, but at the very end of the queue and only once.
Placer.Pending = {} -- spends the server took that the balance has not shown yet

-- Money after subtracting spends that have not replicated yet. The balance
-- value lags the server for a moment, so reading it raw right after a purchase
-- shows money that is already gone and the next action gets rejected.
function Placer.Money()
	local Raw = GetMoney()
	if Raw == nil then
		return nil
	end
	local Pending = Placer.Pending
	if not Pending then
		Pending = {}
		Placer.Pending = Pending
	end
	local Now = os.clock()
	local Held = 0
	for I = #Pending, 1, -1 do
		local Spend = Pending[I]
		-- reflected once the balance fell below what it was before the spend
		if Now - Spend.At > PlaceConfig.PendingSeconds or Raw < Spend.Before then
			table.remove(Pending, I)
		else
			Held += Spend.Cost
		end
	end
	return Raw - Held
end

function Placer.CanSpend(Cost)
	if Cost == nil then
		return false
	end
	local Money = Placer.Money()
	return Money ~= nil and Money >= Cost
end

-- Before = Placer.Money() read just before the action
function Placer.Reserve(Cost, Before)
	local Pending = Placer.Pending
	if not Pending then
		Pending = {}
		Placer.Pending = Pending
	end
	Pending[#Pending + 1] = { Cost = Cost, Before = Before or Placer.Money() or 0, At = os.clock() }
end

-- copies of one unit we are willing to place (farms have their own cap)
function Placer.PlaceCap(UnitId, Uuid)
	local Cap = SpawnCap(UnitId, Uuid)
	if Cap == nil then
		return nil -- unknown: caller skips instead of guessing
	end
	if IsFarmUnit(UnitId) then
		Cap = math.min(Cap, tonumber(PlaceConfig.FarmCopies) or Cap)
	end
	return Cap
end

-- the best free spot for a unit right now (nil when there is none)
function Placer.Resolve(UnitId)
	local Pool, Farm = NodesFor(UnitId)
	local Node, Reaches = PickNode(Pool, UnitId, Farm)
	if not Node then
		return nil
	end
	local Cf = Node.CFrame
	if Placer.Grid and Placer.Grid.get_closest_grid_point then
		local Ok, Snapped = pcall(Placer.Grid.get_closest_grid_point, Cf)
		if Ok and typeof(Snapped) == "CFrame" then
			Cf = Snapped
		end
	end
	local Landing = Placer.NearestNode(Cf.Position)
	if Landing and Placer.NodeBusy(Landing) then
		return nil
	end
	return { Node = Node, Reaches = Reaches, Cf = Cf, Landing = Landing, Farm = Farm }
end

-- merge places and upgrades into one ordered queue
--   early waves / roster not full: places first, then upgrades (farms ahead of
--   combat inside each group); otherwise upgrades first.
function Placer.BuildItems(Places, Upgrades)
	Places = Places or {}
	Upgrades = Upgrades or {}
	local PlaceFirst = (GetWave() or 1) <= PlaceConfig.EarlyPlaceWaves or PlaceConfig.PlaceFirstUntilFull
		or (Placer.Target ~= nil and Placer.Target.Kind == "place")
	table.sort(Places, function(A, B)
		if A.Reaches ~= B.Reaches then
			return A.Reaches == true
		end
		if A.Score ~= B.Score then
			return A.Score > B.Score
		end
		return tostring(A.Uuid) < tostring(B.Uuid)
	end)
	local FarmPlaces, CombatPlaces, FarmUps, CombatUps = {}, {}, {}, {}
	for _, Entry in ipairs(Places) do
		if Entry.Farm then
			FarmPlaces[#FarmPlaces + 1] = Entry
		else
			CombatPlaces[#CombatPlaces + 1] = Entry
		end
	end
	for _, Entry in ipairs(Upgrades) do
		if IsFarmUnit(Entry.UnitId) then
			FarmUps[#FarmUps + 1] = Entry
		else
			CombatUps[#CombatUps + 1] = Entry
		end
	end
	local Order
	if PlaceFirst then
		Order = { FarmPlaces, CombatPlaces, FarmUps, CombatUps }
	else
		Order = { FarmUps, CombatUps, FarmPlaces, CombatPlaces }
	end
	local Items = {}
	for _, Tier in ipairs(Order) do
		for _, Entry in ipairs(Tier) do
			Items[#Items + 1] = Entry
		end
	end
	local Max = math.max(1, tonumber(PlaceConfig.QueueSize) or 20)
	while #Items > Max do
		table.remove(Items)
	end
	return Items
end

-- measured income: money gained between ticks (spending is marked out, so only
-- real gains are counted), averaged over a sliding window
function Placer.TrackIncome()
	local Now = os.clock()
	local Money = GetMoney()
	local Last = Placer.IncomeLast
	if Money and Last and Money > Last.Money then
		Placer.IncomeSamples[#Placer.IncomeSamples + 1] = { Time = Now, Gain = Money - Last.Money }
	end
	local Samples = Placer.IncomeSamples
	local Cut = Now - PlaceConfig.IncomeWindow
	while Samples[1] and Samples[1].Time < Cut do
		table.remove(Samples, 1)
	end

	-- wave clock: how long a wave really lasts in this match
	local Wave = GetWave()
	local Clock = Placer.WaveClock
	if Wave and Wave ~= Clock.Wave then
		if Clock.Wave and Clock.Time and Wave > Clock.Wave then
			local Each = (Now - Clock.Time) / (Wave - Clock.Wave)
			if Each > 1 and Each < 300 then
				Clock.Durations[#Clock.Durations + 1] = Each
				if #Clock.Durations > 5 then
					table.remove(Clock.Durations, 1)
				end
			end
		end
		Clock.Wave, Clock.Time = Wave, Now
	end
end

-- call after spending so the next tick's delta is pure income
function Placer.MarkMoney()
	local Money = GetMoney()
	if Money then
		Placer.IncomeLast = { Money = Money, Time = os.clock() }
		Placer.IncomeStart = Placer.IncomeStart or os.clock()
	end
end

-- yen per second, or nil while there is not enough data
function Placer.IncomeRate()
	if not Placer.IncomeStart then
		return nil
	end
	local Span = os.clock() - Placer.IncomeStart
	if Span < PlaceConfig.IncomeMinSeconds then
		return nil
	end
	local Total = 0
	for _, Sample in ipairs(Placer.IncomeSamples) do
		Total += Sample.Gain
	end
	local Rate = Total / math.min(Span, PlaceConfig.IncomeWindow)
	return Rate > 0 and Rate or nil
end

function Placer.SecondsPerWave()
	local Durations = Placer.WaveClock.Durations
	if #Durations == 0 then
		return PlaceConfig.SecondsPerWave
	end
	local Sum = 0
	for _, Each in ipairs(Durations) do
		Sum += Each
	end
	return Sum / #Durations
end

-- seconds a purchase is assumed to keep paying off
function Placer.PlanHorizon()
	local MaxWave = GetMaxWave() or PlaceConfig.EstimatedWaves
	local Remaining = math.max(1, MaxWave - (GetWave() or 1))
	return math.min(PlaceConfig.PlanHorizon, Remaining * Placer.SecondsPerWave())
end

local function PlaceGain(UnitId)
	return DpsOf(StatsAt(UnitId, 0))
end

-- Payoff of a purchase: DPS added, for as long as it is live inside the
-- planning horizon (time spent saving for it is dead time), per yen spent.
local function ActionValue(Gain, Cost, Horizon, Money, Income)
	if Gain <= 0 then
		return 0
	end
	local Wait = Income and math.max(0, Cost - Money) / Income or 0
	local Live = Horizon - Wait
	if Live <= 0 then
		return 0
	end
	return Gain * Live / math.max(Cost, 1)
end

-- The purchase we are building toward, ignoring money. Placing another strong
-- unit competes head to head with upgrading an existing one: whichever adds
-- the most effective DPS per yen (after waiting time) wins, so a weak unit's
-- upgrade loses to a fresh high-DPS placement when that is the better buy.
-- Effective DPS counts only what can actually reach the lane.
function Placer.ChooseTarget(TopPlace, Upgrades)
	local Money = Placer.Money() or 0
	local Income = Placer.IncomeRate()
	local Horizon = Placer.PlanHorizon()

	local PlaceTarget
	if TopPlace then
		local Cost = UnitCost(TopPlace.UnitId)
		local Gain = PlaceGain(TopPlace.UnitId) * (TopPlace.Reaches and 1 or PlaceConfig.UnreachedGainFactor)
		PlaceTarget = {
			Kind = "place", Ref = TopPlace, UnitId = TopPlace.UnitId, Cost = Cost, Gain = Gain,
			Value = ActionValue(Gain, Cost, Horizon, Money, Income) * PlaceConfig.PlacePreference,
		}
	end

	local UpgradeTarget
	local SeenUnit = {}
	for _, Entry in ipairs(Upgrades) do
		-- copies of one unit are listed lowest level first: only the first one
		-- competes, otherwise the highest-level copy always wins and the rest never get upgraded
		if not IsFarmUnit(Entry.UnitId) and Entry.EffGain > 0 and not SeenUnit[Entry.UnitId] then
			SeenUnit[Entry.UnitId] = true
			local Value = ActionValue(Entry.EffGain, Entry.Cost, Horizon, Money, Income)
			if not UpgradeTarget or Value > UpgradeTarget.Value then
				UpgradeTarget = {
					Kind = "upgrade", Ref = Entry, UnitId = Entry.UnitId, Cost = Entry.Cost,
					Gain = Entry.EffGain, Value = Value,
				}
			end
		end
	end

	local Chosen
	if PlaceTarget and (PlaceConfig.PlaceFirstUntilFull or (GetWave() or 1) <= PlaceConfig.EarlyPlaceWaves) then
		Chosen = PlaceTarget -- fill the roster first: more units beats stronger units
	elseif PlaceTarget and UpgradeTarget then
		Chosen = PlaceTarget.Value >= UpgradeTarget.Value and PlaceTarget or UpgradeTarget
	else
		Chosen = PlaceTarget or UpgradeTarget
	end

	if Chosen then
		local Key = Chosen.Kind .. ":" .. tostring(Chosen.UnitId)
		if not Placer.TargetSince or Key ~= Placer.LastTargetKey then
			Placer.TargetSince = os.clock()
		end
		if Key ~= Placer.LastTargetKey then
			Placer.LastTargetKey = Key
			local Other = Chosen == PlaceTarget and UpgradeTarget or PlaceTarget
			Log("target: %s %s (value %.3f, +%.1f dps, cost %d)%s", Chosen.Kind, tostring(Chosen.UnitId),
				Chosen.Value, Chosen.Gain, Chosen.Cost,
				Other and (" over %s %s (value %.3f)"):format(Other.Kind, tostring(Other.UnitId), Other.Value) or "")
		end
	end
	return Chosen
end

function Placer.IsTarget(Kind, Ref)
	local Target = Placer.Target
	if not Target or Target.Kind ~= Kind then
		return false
	end
	if Kind == "upgrade" then
		return Target.Ref.Model == Ref.Model
	end
	return Target.Ref == Ref
end

function Placer.ClearTarget(Kind, Ref)
	if Placer.IsTarget(Kind, Ref) then
		Placer.Target = nil
		Placer.TargetSince = nil
	end
end

-- Should this purchase happen now, or keep saving for the target?
--   delay = how much later the target is bought if we spend `Cost` now
--   spend when Gain * horizon >= TargetGain * delay  (damage added vs delayed)
function Placer.AllowSpend(Kind, Ref, UnitId, Cost, Gain)
	local Target = Placer.Target
	if not PlaceConfig.WaitEnabled or not Target or Placer.IsTarget(Kind, Ref) then
		return true
	end
	-- Farm PLACEMENT is the economy engine: once unlocked and affordable it is
	-- never worth delaying for a combat target. Only farm upgrades are checked
	-- against the payback horizon below.
	if IsFarmUnit(UnitId) and Kind == "place" then
		return true
	end
	-- a target that has been saved for too long, or whose purchase keeps failing
	-- (no valid spot, server rejects it), stops holding every other spend
	if Placer.TargetSince and os.clock() - Placer.TargetSince > PlaceConfig.MaxWaitSeconds * 2 then
		return true
	end
	if Target.Kind == "place" and os.clock() - (Placer.TargetFailAt or -100) < 8 then
		return true
	end
	local Money = Placer.Money() or 0
	local Income = Placer.IncomeRate()
	local function Hold(Why)
		if os.clock() - Placer.LastWaitLog > 5 then
			Placer.LastWaitLog = os.clock()
			Log("saving for %s %s (cost %d, have %d): holding %s %s — %s",
				Target.Kind, tostring(Target.UnitId), Target.Cost, Money, Kind, tostring(UnitId), Why)
		end
		return false
	end

	if not Income then
		-- no income data yet: never raid money the target already has
		return Money < Target.Cost or Money - Cost >= Target.Cost
	end
	local WaitNow = math.max(0, Target.Cost - Money) / Income
	local WaitAfter = math.max(0, Target.Cost - (Money - Cost)) / Income
	local Delay = WaitAfter - WaitNow
	if Delay <= 0 then
		return true -- still enough left for the target: free to spend
	end
	if WaitNow > PlaceConfig.MaxWaitSeconds then
		return true -- target is too far away to be worth saving for
	end
	if Placer.Defense and not Placer.Defense.stable then
		return true -- lane is leaking: spend now
	end

	local Horizon = Placer.PlanHorizon()
	if IsFarmUnit(UnitId) then
		-- economy purchase: fine if it pays itself back well inside the horizon
		local PaybackSeconds
		if Kind == "upgrade" then
			PaybackSeconds = FarmRoi(UnitId, Ref.Level, Cost, Ref.Model).payback * Placer.SecondsPerWave()
		else
			local PerWave = tonumber((StatsAt(UnitId, 0) or {}).farm_amount) or 0
			PaybackSeconds = PerWave > 0 and Cost / PerWave * Placer.SecondsPerWave() or math.huge
		end
		if PaybackSeconds <= Horizon then
			return true
		end
		return Hold(("farm payback %.0fs is too slow"):format(PaybackSeconds))
	end
	if (Gain or 0) * Horizon >= Target.Gain * Delay then
		return true
	end
	return Hold(("it would delay the target %.1fs for %.1f dps"):format(Delay, Gain or 0))
end

local function ComputePlaceCandidate()
	RefreshUnitRanges()
	local Counts = {}
	for _, Model in ipairs(PlayerUnitModels()) do
		local UnitId = ModelUnitId(Model)
		if UnitId then
			Counts[UnitId] = (Counts[UnitId] or 0) + 1
		end
	end
	Placer.UnitCounts = Counts
	-- Count combat units to enforce "first defenders, then farms".
	local CombatCount = 0
	for Id, Count in pairs(Counts) do
		if not IsFarmUnit(Id) then
			CombatCount = CombatCount + Count
		end
	end
	local MinCombat = math.clamp(#GetPvePaths() + 2,
		PlaceConfig.MinCombatBeforeFarms, PlaceConfig.MaxCombatBeforeFarms)
	-- Farms go down after the first combat units, even if defense currently
	-- reads WEAK, otherwise they never get placed at all.
	local FarmsAllowed = CombatCount >= MinCombat
	local BestFarm, BestCombat, TopCombat
	local All = {}
	for _, Uuid in ipairs(EquippedUuids()) do
		local UnitId = UnitIdForUuid(Uuid)
		local Cap = UnitId and Placer.PlaceCap(UnitId, Uuid) or nil
		if UnitId and Units[UnitId] and Cap
			and (not IsFarmUnit(UnitId) or FarmsAllowed)
			and (Counts[UnitId] or 0) < Cap then
			local Spot = Placer.Resolve(UnitId)
			if Spot then
				local Farm = Spot.Farm
				local Score = UnitPlaceScore(UnitId, Uuid) + NodeFitScore(Spot.Node, UnitId, Farm)
				local Cost = UnitCost(UnitId)
				local Entry = {
					Kind = "place", Id = Uuid, Uuid = Uuid, UnitId = UnitId, Farm = Farm,
					Node = Spot.Node, Cf = Spot.Cf, Landing = Spot.Landing, Score = Score,
					Reaches = Spot.Reaches, Cost = Cost, Affordable = Placer.CanSpend(Cost),
				}
				All[#All + 1] = Entry
				if Farm then
					if Entry.Affordable and (not BestFarm or Score > BestFarm.Score) then
						BestFarm = Entry
					end
				else
					-- a unit that reaches the lane always beats one that doesn't
					local function Better(Current)
						return not Current or (Entry.Reaches and not Current.Reaches)
							or (Entry.Reaches == Current.Reaches and Score > Current.Score)
					end
					if Entry.Affordable and Better(BestCombat) then
						BestCombat = Entry
					end
					if Better(TopCombat) then
						TopCombat = Entry -- best combat placement regardless of money
					end
				end
			end
		end
	end
	-- An unlocked farm compounds for the rest of the match, then plain combat.
	return (FarmsAllowed and BestFarm) or BestCombat, TopCombat, All
end

local function UpgradeCandidates()
	local Now = os.clock()
	local List = {}
	for _, Model in ipairs(PlayerUnitModels()) do
		local UnitId = ModelUnitId(Model)
		local Level = StatValue(Model, "upgrade")
		local MaxLevel = StatValue(Model, "max_upgrade")
		if UnitId and Level ~= nil and (MaxLevel == nil or Level < MaxLevel) then
			local Cost = NextUpgradeCost(UnitId, Level)
			if Cost ~= nil then
				-- money is NOT filtered here: the top entry may be the thing we
				-- are saving for. Callers check affordability when they spend.
				local Uuid = StatValue(Model, "uuid")
				local Gain = Placer.EffectiveDpsAt(UnitId, Level + 1, Uuid, Level)
					- Placer.EffectiveDpsAt(UnitId, Level, Uuid, Level)
				-- effective gain: scaled by how much lane the unit can really reach
				local EffGain = Gain
				if not IsFarmUnit(UnitId) then
					local Pos = UnitHitboxPosition(Model)
					if Pos then
						local Range = Placer.UnitRanges[UnitId] or PlaceConfig.DefaultRange
						local Fraction = math.min(1, Placer.PathCoverage(Pos, Range) / (Range * 1.2))
						EffGain = Gain * (0.2 + 0.8 * Fraction)
					end
				end
				List[#List + 1] = {
					Index = #List + 1, Kind = "upgrade", Id = Model,
					Model = Model, UnitId = UnitId, Level = Level,
					Cost = Cost, Score = UpgradeScore(Model, UnitId, Level, Cost),
					Position = UnitAnchorPosition(Model),
					Gain = Gain, EffGain = EffGain,
					Affordable = Placer.CanSpend(Cost),
				}
			end
		end
	end
	table.sort(List, function(A, B)
		local SA, SB = A.Score, B.Score
		if SA ~= SA then SA = -math.huge end -- NaN guard: a bad score must not break the sort
		if SB ~= SB then SB = -math.huge end
		if SA ~= SB then
			return SA > SB
		end
		return A.Index < B.Index
	end)
	-- The score decides which UNIT goes first; the copies of one unit are then
	-- handed those slots lowest level first, so every copy gets upgraded in turn
	-- instead of the best one snowballing while the others sit at level 0.
	local Groups = {}
	for _, Entry in ipairs(List) do
		local Group = Groups[Entry.UnitId]
		if not Group then
			Group = { Entries = {}, Cursor = 0 }
			Groups[Entry.UnitId] = Group
		end
		Group.Entries[#Group.Entries + 1] = Entry
	end
	for _, Group in pairs(Groups) do
		if #Group.Entries > 1 then
			table.sort(Group.Entries, function(A, B)
				if A.Level ~= B.Level then
					return A.Level < B.Level
				end
				return A.Index < B.Index
			end)
		end
	end
	local Ordered = {}
	for _, Entry in ipairs(List) do
		local Group = Groups[Entry.UnitId]
		Group.Cursor += 1
		Ordered[#Ordered + 1] = Group.Entries[Group.Cursor]
	end
	return Ordered
end

local function ComputeQueue()
	Placer.RefreshSpawnSlots() -- unique-trait cap check
	Placer.RefreshLiveStats() -- actual damage/cooldown/range off placed models
	RefreshFarmStats()
	Placer.EnemyInfo = AssessEnemies()
	Placer.Defense = AssessDefense()
	if os.clock() - Placer.LastDefenseDiag > 15 then
		Placer.LastDefenseDiag = os.clock()
		local D = Placer.Defense
		Log("defense: dps=%.1f hp=%.0f kill=%.1fs transit=%.1fs safety=%.0f path=%.0f -> %s",
			D.dps, D.hp, D.killTime, D.transitTime, D.safety,
			GetPathLength() or PlaceConfig.PathLength, D.stable and "STABLE" or "WEAK")
		local EI = Placer.EnemyInfo
		Log("enemies: alive=%d effHP=%.0f", EI.count, EI.totalHP)
	end
	local Place, TopPlace, Places = ComputePlaceCandidate()
	local Upgrades = UpgradeCandidates()
	Placer.Target = Placer.ChooseTarget(TopPlace, Upgrades)
	Placer.Queue = {
		Place = Place, Upgrade = Upgrades[1], Upgrades = Upgrades,
		Items = Placer.BuildItems(Places, Upgrades),
	}
	if PlaceConfig.ShowVisuals and PlaceConfig.ShowQueueArrows then
		SetIntentArrow("place", Place and Place.Cf.Position or nil)
		SetIntentArrow("upgrade", Upgrades[1] and Upgrades[1].Position or nil)
	else
		HideIntentArrow()
	end
end

function Placer.PlaceOnce(Candidate)
	Placer.RefreshOccupied()
	local Node = Candidate.Node
	if not Node then
		return false, "nonode"
	end
	local Cf, Uuid, UnitId = Candidate.Cf, Candidate.Uuid, Candidate.UnitId
	-- a node under a unit's hitbox is only busy while that hitbox exists, so
	-- it is skipped, not retired (retiring would burn it after the unit dies)
	if Placer.NodeBusy(Node) then
		return false, "occupied"
	end
	-- the grid snap can land on a node that already has a unit
	local Landing = Candidate.Landing or Placer.NearestNode(Cf.Position)
	if Landing and Placer.NodeBusy(Landing) then
		return false, "occupied"
	end
	-- exact-point check against the live _hitbox cylinders at the CFrame we send
	if Placer.PointInAnyHitbox(Cf.Position) then
		return false, "occupied"
	end

	-- money may have changed since the queue was built (e.g. an upgrade in
	-- this same tick) — never send a spawn we can't pay for
	if not CanAfford(UnitCost(UnitId)) then
		return false, "nomoney"
	end
	-- final guard: the scene may have changed since the scan (new enemy/unit
	-- hitboxes, bounds, road). Never send a CFrame the game would reject.
	if IsSpotBlocked(Cf.Position) then
		Placer.Retire(Node, PlaceConfig.BlockedCooldown)
		return false, "blocked"
	end

	local Before = #PlayerUnitModels()
	local Ok, Result = CallWithTimeout(10, InvokeServer, "spawn_unit", Uuid, Cf)
	if not (Ok and Result) then
		-- a rejected spawn retires the node immediately: the next attempt
		-- must land somewhere else, not hammer the same spot
		Placer.Retire(Node, PlaceConfig.RejectCooldown)
		return false, "server"
	end
	-- the server accepted it; give the model a moment to replicate
	local Deadline = os.clock() + 1
	repeat
		task.wait(0.1)
	until #PlayerUnitModels() > Before or os.clock() >= Deadline
	-- short claim covers replication lag; the hitbox takes over from here and
	-- the claim is dropped as soon as the unit's hitbox owns the node
	Placer.Retire(Node)
	if Landing then
		Placer.Retire(Landing)
	end
	Placer.RefreshOccupied(true)
	Log("placed %s", UnitId)
	return true
end

-- (re)scan until nodes exist: the path cache can still be empty right when a
-- match starts, and a failed run of placements also triggers a fresh scan
local function EnsureScan()
	local Missing = Placer.NeedScan or #Placer.Nodes == 0
	local TooManyFails = Placer.Fails >= PlaceConfig.RescanAfterFails
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

local function RunQueue()
	local Queue = Placer.Queue and Placer.Queue.Items or {}

	-- A rejected entry moves straight on: it is put at the very end of the
	-- queue and retried once there. A second rejection drops it for this tick.
	local function Requeue(Item)
		if not Item.Retried then
			Item.Retried = true
			Queue[#Queue + 1] = Item
		end
	end

	local MaxDone = math.max(1, tonumber(PlaceConfig.ActionsPerTick) or 1)
	local MaxTries = MaxDone + math.max(0, tonumber(PlaceConfig.ExtraTries) or 0)
	local Done, Tries, Held, Short = 0, 0, 0, 0
	-- If a higher-priority upgrade cannot be bought right now (money or held
	-- for a target), fall through to the next priority instead of stalling.
	local UpgradeBlocked = false
	for _, Item in ipairs(Queue) do
		if Done >= MaxDone or Tries >= MaxTries then
			break
		end
		if Item.Kind == "upgrade" then
			-- level and cost are read NOW, not taken from when the queue was built
			local Model = Item.Model
			local Alive = Model ~= nil and Model.Parent ~= nil
			local Level = Alive and tonumber(StatValue(Model, "upgrade")) or nil
			local MaxLevel = Alive and StatValue(Model, "max_upgrade") or nil
			local Cost = Level ~= nil and NextUpgradeCost(Item.UnitId, Level) or nil
			if Cost ~= nil and (MaxLevel == nil or Level < MaxLevel) then
				if not Placer.CanSpend(Cost) then
					Short += 1
					UpgradeBlocked = true
				elseif not (UpgradeBlocked or IsFarmUnit(Item.UnitId)
					or Placer.AllowSpend("upgrade", Item, Item.UnitId, Cost, Item.EffGain)) then
					Held += 1 -- farm upgrades pay for themselves and are never held
					UpgradeBlocked = true
				else
					Tries += 1
					local Before = Placer.Money()
					local Ok, Result = pcall(function()
						return InvokeServer("upgrade_unit_ingame", Model)
					end)
					if not Ok or Result == false then
						Requeue(Item)
						if os.clock() - Placer.LastUpgradeWarn > 10 then
							Placer.LastUpgradeWarn = os.clock()
							Log("upgrade rejected: %s lvl %s cost %.0f money %s (ok=%s res=%s)",
								tostring(Item.UnitId), tostring(Level), Cost, tostring(Before),
								tostring(Ok), tostring(Result))
						end
					else
						-- the endpoint often returns nil on success: confirm by the level itself
						local Deadline = os.clock() + 0.5
						local Confirmed = false
						repeat
							task.wait(0.05)
							local Now = tonumber(StatValue(Model, "upgrade"))
							Confirmed = Now ~= nil and Now > Level
						until Confirmed or os.clock() >= Deadline or not Model.Parent
						if Confirmed then
							Placer.Reserve(Cost, Before)
							Placer.UpgradeAt[Model] = os.clock()
							Placer.ClearTarget("upgrade", Item)
							Done += 1
							Log("upgraded %s to lvl %s", tostring(Item.UnitId), tostring(Level + 1))
							task.wait(PlaceConfig.ActionDelay)
						elseif Model.Parent then
							Placer.Reserve(Cost, Before) -- accepted: the spend may still land
						end
					end
				end
			end
		else
			-- placement: the spot and the money are resolved NOW
			local UnitId = Item.UnitId
			local Cost = UnitCost(UnitId)
			local Cap = Placer.PlaceCap(UnitId, Item.Uuid)
			if Cost == nil then
				Short += 1 -- no cost in the data: skip instead of guessing
			elseif Cap and (Placer.UnitCounts[UnitId] or 0) >= Cap then
				Short += 0 -- full: an earlier entry this tick used the last slot
			elseif not Placer.CanSpend(Cost) then
				Short += 1
			elseif not IsFarmUnit(UnitId)
				and not Placer.AllowSpend("place", Item, UnitId, Cost, PlaceGain(UnitId)) then
				Held += 1
			else
				Placer.RefreshOccupied()
				local Spot = Placer.Resolve(UnitId)
				if Spot then
					Item.Node, Item.Cf, Item.Landing, Item.Reaches = Spot.Node, Spot.Cf, Spot.Landing, Spot.Reaches
					Tries += 1
					local Before = Placer.Money()
					local Placed, Reason = Placer.PlaceOnce(Item)
					if Placed then
						Placer.Reserve(Cost, Before)
						Placer.UnitCounts[UnitId] = (Placer.UnitCounts[UnitId] or 0) + 1
						Placer.ClearTarget("place", Item)
						Placer.Fails = 0
						Done += 1
						task.wait(PlaceConfig.ActionDelay)
					elseif Reason == "server" or Reason == "blocked" then
						Placer.Fails = Placer.Fails + 1
						Placer.TargetFailAt = os.clock() -- stop saving for something that will not place
						Requeue(Item)
					end
				end
			end
		end
	end

	if os.clock() - Placer.LastUpgradeDiag > 10 then
		Placer.LastUpgradeDiag = os.clock()
		local Parts = {}
		for I = 1, math.min(#Queue, 8) do
			local Item = Queue[I]
			Parts[#Parts + 1] = ("%s%s%s $%.0f"):format(Item.Kind == "place" and "+" or "^",
				tostring(Item.UnitId), Item.Retried and "!" or "", Item.Cost or 0)
		end
		Log("queue %d: %s | done %d tried %d held %d short %d | money %s",
			#Queue, table.concat(Parts, " "), Done, Tries, Held, Short, tostring(Placer.Money()))
	end
end

-- connection-based freshness: any unit model added/removed (ours, other
-- players', summoned adds) refreshes occupancy immediately and queues a node
-- rescan, instead of waiting for the next timed scan
local WatchingUnits = false
local LastUnitPoke = 0
local function WatchUnits()
	if WatchingUnits then
		return
	end
	WatchingUnits = true
	local Deferred = false
	local function Poke()
		local Now = os.clock()
		if Now - LastUnitPoke < 0.5 then
			-- never drop a change: refresh once the debounce window ends, so a
			-- unit sold right after another event still frees its node
			if not Deferred then
				Deferred = true
				task.delay(0.5, function()
					Deferred = false
					LastUnitPoke = os.clock()
					Placer.RefreshOccupied(true)
				end)
			end
			return
		end
		LastUnitPoke = Now
		-- node geometry is static — a unit spawning/dying only changes which
		-- node is occupied, so refresh the data, don't rescan the map
		Placer.RefreshOccupied(true)
	end
	local function HookFolder(Folder)
		Folder.ChildAdded:Connect(Poke)
		Folder.ChildRemoved:Connect(Poke)
		Folder.DescendantRemoving:Connect(function(Instance_)
			if Instance_.Name == "_hitbox" then
				task.defer(Poke)
			end
		end)
	end
	local Folder = workspace:FindFirstChild("_UNITS")
	if Folder then
		HookFolder(Folder)
	end
	workspace.ChildAdded:Connect(function(Child)
		if Child.Name == "_UNITS" then
			HookFolder(Child)
		end
	end)
	CollectionService:GetInstanceAddedSignal("player_units"):Connect(Poke)
	CollectionService:GetInstanceRemovedSignal("player_units"):Connect(Poke)
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

local function PlacementTick()
	WatchUnits()
	WatchEnemies()

	-- Full reset when a new match starts, the map changes, or the wave counter
	-- rolls back. Covers replay / next-match / teleport between maps.
	local Active = MatchActive()
	if Active and not Placer.LastMatchActive then
		ResetForNewMatch("game started", true)
	end
	Placer.LastMatchActive = Active
	local MapId = tostring(Loader.LevelData and Loader.LevelData.id or "")
	if MapId ~= "" and Placer.LastMapId and MapId ~= Placer.LastMapId then
		ResetForNewMatch("map changed")
	end
	Placer.LastMapId = MapId
	local WaveNow = GetWave() or 0
	if WaveNow > 0 and WaveNow < Placer.LastWave then
		ResetForNewMatch("wave reset")
	end
	Placer.LastWave = WaveNow

	EnsureScan()
	Placer.RefreshOccupied()
	Placer.TrackIncome()
	if #EquippedUuids() == 0 and os.clock() - Placer.LastWarn > 15 then
		Placer.LastWarn = os.clock()
		Log("no equipped units found in the profile — nothing to place")
	end

	-- Rebuild the queue from live state, then walk it: every entry is
	-- re-checked (money, level, spot) right before it runs.
	local QueueOk, QueueErr = pcall(ComputeQueue)
	if not QueueOk then
		if os.clock() - (Placer.LastQueueWarn or 0) > 10 then
			Placer.LastQueueWarn = os.clock()
			warn("[AA Kaitun] queue error: " .. tostring(QueueErr))
		end
		-- scoring failed: still build a plain queue so nothing stops
		pcall(function()
			Placer.RefreshSpawnSlots()
			Placer.RefreshLiveStats()
			local Place, _, Places = ComputePlaceCandidate()
			Placer.Queue = { Place = Place, Upgrades = {}, Items = Placer.BuildItems(Places, UpgradeCandidates()) }
		end)
	end
	local RunOk, RunErr = pcall(RunQueue)
	if not RunOk and os.clock() - (Placer.LastUpgradeErr or 0) > 10 then
		Placer.LastUpgradeErr = os.clock()
		warn("[AA Kaitun] queue run error: " .. tostring(RunErr))
	end
	Placer.MarkMoney()
end

-- Visual preview: with ShowVisuals on, the scan and its markers appear as soon
-- as the script runs inside a map, before the match starts. Nothing is placed
-- or upgraded here; PlacementTick only runs once the match is active.
local function PreviewTick()
	if not PlaceConfig.ShowVisuals then
		return
	end
	if not (Loader.LevelData and workspace:FindFirstChild("_road")) then
		return -- lobby / map not loaded yet
	end
	local MapId = tostring(Loader.LevelData.id or "")
	if MapId ~= "" and Placer.LastMapId and MapId ~= Placer.LastMapId then
		ResetForNewMatch("map changed")
	end
	Placer.LastMapId = MapId
	EnsureScan()
end

-- initialise the new placement system ---------------------------------------
Placer.Core = Loader.load_core_service(nil, "PlacementCore")
Placer.Paths = Loader.load_core_service(nil, "PathService")
Placer.Grid = SafeLoad("load_client_service", "PlacementServiceClient")
HideIntentArrow()

local function StartAutoPlace()
	task.spawn(function()
		while true do
			local Active = MatchActive()
			if Active then
				local Ok, Err = pcall(PlacementTick)
				if not Ok then
					warn("[AA Kaitun] placement error: " .. tostring(Err))
				end
			elseif Placer.LastMatchActive then
				-- match just ended: free all node state and restore the dots
				Placer.Used = {}
				Placer.Occupied = {}
				Placer.UnitCenters = {}
				Placer.Neighbors = {}
				Placer.Target = nil
				Placer.LastMatchActive = false
				RestoreNodeColors()
				HideIntentArrow()
				Log("match finished — node markers restored")
			end
			if not Active then
				local Ok, Err = pcall(PreviewTick)
				if not Ok then
					warn("[AA Kaitun] preview error: " .. tostring(Err))
				end
			end
			task.wait(0.5)
		end
	end)
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
	if ChallengesEnabled() and Level >= Config.NormalChallengeLevel and CurrentSlot() > (State.ChallengeSlot or 0) then
		Log("challenge reset passed -> leaving to check them")
		return "Leave"
	end
	return "Replay"
end

-- Called ONCE from the GameFinished value-change hook. Every remote is fired
-- at most once; after that we only wait for the value to flip back / a new
-- match to start. No polling loop and no repeat firing.
local function FinishMatch(Ctx)
	task.wait(3)
	if IsChallengeKind(Ctx.Kind) and Ctx.Uuid then
		State.ChallengeDone[Ctx.Mode or Ctx.Kind] = Ctx.Uuid
		SaveState()
	end

	local Decision = DecideAfterMatch(Ctx)
	Log("match finished -> %s (firing once)", Decision)
	if Config.WebhookMode == "all" then
		SendWebhook("Match finished (" .. tostring(Ctx.Kind) .. ")",
			"Decision: " .. Decision .. ".", 5793266, "match:" .. tostring(Ctx.Token or Ctx.Kind))
	end

	local function Transitioned()
		return not GameFinished() or MatchActive()
	end

	-- one shot only: replay vote OR the leave-to-lobby remote
	if Decision == "Replay" then
		pcall(FireEndpoint, "set_game_finished_vote", "replay")
	else
		pcall(FireEndpoint, "teleport_back_to_lobby")
	end

	-- wait for the server to react; do not fire again
	local Deadline = os.clock() + 15
	while os.clock() < Deadline and not Transitioned() do
		task.wait(0.25)
	end
	if not Transitioned() then
		Log("finish remote sent once; still waiting for the transition")
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
	for Name, Want in pairs({ show_overheads = false, disable_effects = true, disable_auto_open_overhead = true }) do
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
	local FinishHandled = false -- one finish per match, driven by the value change
	local LastHuntCheck = 0
	local LastResetCheck = 0
	local ResetLeaveAt = nil

	-- GameFinished is detected by VALUE CHANGE, not by polling. The single
	-- remote (replay or leave) is fired once by FinishMatch; the value going
	-- false arms the next match.
	local function HandleFinish(Ctx)
		if FinishHandled then
			return
		end
		FinishHandled = true
		local Ok, Err = pcall(FinishMatch, Ctx or CurrentContext())
		if not Ok then
			warn("[AA Kaitun] finish error: " .. tostring(Err))
		end
	end
	task.spawn(function()
		while true do
			local Data = workspace:FindFirstChild("_DATA")
			local Flag = Data and Data:FindFirstChild("GameFinished")
			if Flag and Flag:IsA("ValueBase") then
				local Connected = false
				pcall(function()
					Flag:GetPropertyChangedSignal("Value"):Connect(function()
						if Flag.Value == true then
							HandleFinish(CurrentContext())
						else
							FinishHandled = false
						end
					end)
					Connected = true
				end)
				if Connected and Flag.Value == true then
					HandleFinish(CurrentContext())
				end
				break
			end
			task.wait(0.5)
		end
	end)

	-- placement / upgrades / preview run on their own thread (new system)
	StartAutoPlace()

	while true do
		local Ctx = CurrentContext()
		pcall(AutoVotes)

		if MatchActive() then
			if not WasActive then
				WasActive = true
				LoseVoted = false
				if not GameFinished() then
					FinishHandled = false
				end
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
			if ChallengesEnabled() and os.clock() - LastResetCheck > 5 then
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
			-- finish is handled by the GameFinished value-change hook above
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
	local UserUnit = type(UserConfig) == "table" and UserConfig.CompassUnit or nil
	if UserUnit == nil and type(State.CompassUnit) == "string" and State.CompassUnit ~= "" then
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
	-- CompassDone is set ONLY by CompassUsedInGui() (the visible summon slot).
	-- No profile scan and no celestial_compass_pick_changed callback.
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