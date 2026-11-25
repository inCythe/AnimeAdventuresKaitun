# Anime Adventures — Kaitun

One-click automation for **[UPD 21] Anime Adventures** (lobby place `8304191830`).

Paste into your executor / autoexec:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/inCythe/AnimeAdventuresKaitun/main/loader.lua"))()
```

The loader pulls the script from GitHub on every run and after every teleport. No local executor copy is used.

## Full config (getgenv().Kaitun)

Set this before running the loader/script. Every field is optional — values below are the defaults from the script itself.

```lua
getgenv().Kaitun = {
	-- progression / planner -------------------------------------------------
	TargetLevel = 50,          -- story loop below this, act 6 clear then Infinite
	StoryAct = 1,              -- act of the first story world used for the loop
	SkipStory = true,          -- skip acts 1-5 and full-clear act 6 before Infinite
	SkipWorld = nil,           -- world to skip; nil = first story world
	SkipAct = nil,             -- act to clear; nil = last act (act 6)
	LoseWave = 6,              -- vote lose at this wave (0 = disabled)
	NormalChallengeLevel = 15, -- level gate for the normal challenge
	DailyChallengeLevel = 25,  -- level gate for the daily challenge
	Challenges = true,         -- join challenges when available
	ChallengesOnlyAfterCompass = false, -- once the compass unit is owned, skip
	                                    -- story/infinite; challenges still run
	DoInfinite = true,         -- allow Infinite after TargetLevel

	-- compass / summoning / hunting -----------------------------------------
	CompassUnit = "Elyssia",   -- display name or id; also the hunt target
	CompassId = "celestial_compass_u21",
	Summon = true,             -- one 10x summon per account (saved to disk)
	SummonBanner = "EventClover",
	RollAtGems = 20000,        -- start hunting at this gem count
	HuntAtMinute = 0,          -- hunt at XX:00
	HuntAtMinute2 = 30,        -- also hunt at XX:30 (both nil = any time)
	SaveGems = 0,              -- never roll below this many gems
	MaxHuntRolls = 400,        -- safety limit per hunting session

	-- team / inventory -------------------------------------------------------
	Team = nil,                -- e.g. { "Bulby", "Windsong", "C.E.O." }
	AutoSell = true,           -- sell spare units to avoid the inventory cap
	-- Never sold: locked, equipped, level > 1, Mythic / Secret, and one copy
	-- of every configured Team / Compass unit.

	-- lobby chores -----------------------------------------------------------
	RedeemCodes = true,
	Codes = {                  -- { code, minimum level }
		{ "2MILLIONFAVES", 20 }, { "SUMMERCOMEBACK", 20 },
		{ "CELESTIALCOMPASSU21" }, { "AACOMEBACK", 10 },
		{ "DUNGEONS" }, { "UPDATESOON5189" },
		{ "APRILFOOLS", 20 }, { "MILLIONFAVES", 20 },
		{ "2BILLIONAA", 50 },
	},
	Claims = true,             -- daily / missions / levels / quests / battlepass
	AcceptMissions = true,     -- accept untaken board missions
	StatsOverlay = true,       -- small lobby card + match black-screen panel
	FpsBoost = true,           -- FPS optimizer inside matches
	SkipCutscenes = true,      -- stub summon/reward/hatch cinematics

	-- trait reroll -----------------------------------------------------------
	AutoTrait = true,          -- start once the compass unit is owned
	TraitKeep = { "unique" },  -- Unique is always kept; add e.g. "reaper"
	TraitSources = { "token", "star_remnant", "star_remnant_limited" },
	TraitMinResources = 0,
	TraitRollDelay = 0.25,
	TraitChangeTimeout = 5,

	-- match placement --------------------------------------------------------
	Percent = 5,               -- scan centre as % along the enemy path
	NodeSpacing = 2.5,
	RadiusGround = 40, RadiusHill = 40, RadiusFarm = 10,
	FarmTerrain = "ground",
	DefaultRange = 8, RangeSafety = 0.8,
	MaxPlaceRadius = 28, MaxFarmPlaceRadius = 45,
	MinCombatFirst = 2, FarmQuota = 3, PlaceUntilFull = true,
	ClaimSeconds = 3, RejectCooldown = 10, BlockedCooldown = 20,
	RescanAfterFails = 3,
	UpgradesPerTick = 3, ActionDelay = 0.5,

	-- votes / matchmaking ----------------------------------------------------
	VoteStart = true, VoteSkip = true,
	MatchmakingRetries = 4, MatchmakingCooldown = 21, QueueTimeout = 180,
}

loadstring(game:HttpGet("https://raw.githubusercontent.com/inCythe/AnimeAdventuresKaitun/main/loader.lua"))()
```

Only these keys are actually read from `getgenv().Kaitun`: `TargetLevel`, `CompassUnit`, `Team`, `RollAtGems`, `HuntAtMinute`, `HuntAtMinute2`, `SaveGems`, `Challenges`, `ChallengesOnlyAfterCompass`, `FpsBoost`, `AutoSell`, `SkipCutscenes`, `Summon`, `LoseWave`, `AutoTrait`, `TraitKeep`, `TraitSources`, `TraitMinResources`. Everything else above is shown for reference — leave it out and the script uses its own default.

## Phases

- **Lobby (each visit):** redeem codes, use the celestial compass, claim daily / missions / quests / level rewards / battlepass, one 10x summon (once per account), equip the configured team (or best owned units), auto sell spare units, roll compass traits.
- **Planner:** hunt only at `HuntAtMinute` / `HuntAtMinute2` (`:00` and `:30` by default) when gems reach `RollAtGems` and the compass unit is missing — while hunting it joins nothing else → daily challenge → normal challenge → story loop below `TargetLevel`. At/above `TargetLevel`: use the world skip to jump to act 6, full-clear it, leave to lobby, then join Infinite. With `ChallengesOnlyAfterCompass`, once the compass unit is owned it stops story/act 6/Infinite and only takes challenges/dailies.
- **Match:** vote start, scan the lane once, place combat units then farms, upgrade by priority, auto-skip waves, vote lose at `LoseWave` in loop modes. At the end: replay the loop, or leave to lobby when a challenge is due / target level reached / hunt due.
- **Traits:** once the compass unit is owned, spend tokens → star remnants → limited remnants until Unique (or another kept trait) lands or resources run out. Runs once per unit.
- **Auto sell:** sells spare level-1 units; keeps locked, equipped, level > 1, Mythic/Secret, and one copy of each configured Team/Compass unit.

## Runtime helpers

```lua
getgenv().AAKaitunStop = true  -- stop cleanly at any time
getgenv().AAKaitun             -- State / Lobby / Match / Account (debug)
```
