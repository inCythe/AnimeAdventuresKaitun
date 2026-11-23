# Anime Adventures — Kaitun

One-click automation for **[UPD 21] Anime Adventures** (lobby place `8304191830`).
A single hosted script: `Kaitun/AnimeAdventuresKaitun.lua`. `loader.lua` checks
the game, fetches that file and re-queues itself after every teleport. The
script also queues a stub that reloads the local executor-workspace copy, so it
survives lobby ↔ match switches even without autoexec.

```
AA/
  AnimeAdventuresKaitun.lua     old buggy version, kept locally as reference only
  Kaitun/
    loader.lua                  paste into executor / autoexec
    AnimeAdventuresKaitun.lua   the only script hosted on GitHub
```

---

## Full config (`getgenv().Kaitun`)

Set this **before** running the loader/script. Every field is optional — values
below are the defaults from the script itself.

```lua
getgenv().Kaitun = {
	-- progression / planner -------------------------------------------------
	TargetLevel = 50,          -- story loop below this, Infinite at/above
	StoryAct = 1,              -- act of the first story world used for the loop
	LoseWave = 6,              -- vote lose at this wave (0 = disabled)
	NormalChallengeLevel = 15, -- level gate for the normal challenge
	DailyChallengeLevel = 25,  -- level gate for the daily challenge
	Challenges = true,         -- join challenges when available
	ChallengesOnlyAfterCompass = false, -- (accepted for compatibility)
	DoInfinite = true,         -- allow Infinite after TargetLevel

	-- compass / summoning / hunting -----------------------------------------
	CompassUnit = "Elyssia",   -- display name or id; also the hunt target
	CompassId = "celestial_compass_u21",
	Summon = true,             -- one 10x summon per account (saved to disk)
	SummonBanner = "EventClover",
	RollAtGems = 20000,        -- start hunting at this gem count
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
	SkipCutscenes = true,      -- stub summon/reward/hatch cinematics

	-- trait reroll -----------------------------------------------------------
	AutoTrait = true,          -- start once the compass unit is owned
	TraitKeep = { "unique" },  -- Unique is always kept; add e.g. "reaper"
	TraitSources = { "token", "remnant", "remnant_ltd" },
	TraitMinResources = 0,
	MaxTraitRolls = 200,
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
	UpgradesPerTick = 3, ActionDelay = 0.1,

	-- votes / matchmaking ----------------------------------------------------
	VoteStart = true, VoteSkip = true,
	MatchmakingRetries = 4, MatchmakingCooldown = 21, QueueTimeout = 180,
}

loadstring(game:HttpGet("https://raw.githubusercontent.com/inCythe/AnimeAdventuresKaitun/main/loader.lua"))()
```

Runtime helpers:

```lua
getgenv().AAKaitunStop = true  -- stop cleanly at any time
getgenv().AAKaitun             -- State / Lobby / Match / Account (debug)
```

---

## Phase 1 — lobby

The lobby waits for the game before touching anything: profile/session (60s),
collection data (30s), `_LOBBIES` + a populated `more_lobby_params` (30s), then
a 5 second settle. Only then:

1. Redeem each level-gated code and verify it appears in `redeemed_codes`.
2. Use the celestial compass pick if the summon GUI slot is still empty.
3. Claim daily login, board missions, level rewards, quests, battlepass.
4. Do the one-time 10x summon (per-account JSON state file).
5. Equip `Team`, or the highest scoring owned units when `Team` is nil.
6. Auto sell spare units (after summon too).
7. Reroll the compass unit's traits if it is owned and Unique is missing.
8. Plan and join (below), then wait for the teleport.

**Planner order:** hunt → daily challenge → normal challenge → story loop →
Infinite. Challenges are re-checked every `:00`/`:30` reset slot.

## Phase 2 — match

1. `vote_start` fires **once**, only while the real vote popup is open and
   `VotingFinished == false` (prevents the DifficultyService nil-Instance error).
2. The optimizer (`optimizer.lua`, embedded verbatim) runs **only here**. FPS
   cap is 15 by default. Tweak `_G.Cam`, `_G.Transparent`, `_G.Gui`,
   `_G.Render3D`, `_G.FPSCap` directly — there is no FPS config in this script.
3. Scan the enemy path once (nodes around the defended line, blocked spots
   removed via `_bounds` probe), place combat units first then up to 3 farms.
4. Upgrade the highest-priority affordable unit, a few per tick.
5. `vote_wave_skip` while its popup is open; `vote_lose_game` at `LoseWave`
   for story/Infinite loops.
6. On `GameFinished`, fire exactly one transition: replay the loop, or leave
   to the lobby if level reached, hunt is due, a challenge reset passed, or
   the run was a challenge.

## Logic notes

- **State:** `AAKaitun_<UserId>.json` in the executor workspace holds the
  one-time summon flag, compass flag, challenge clears, trait results and the
  black-screen toggle. Delete it to reset progression flags.
- **Traits:** resources are spent tokens → star remnants → limited remnants.
  Before every roll the live traits are re-read; a kept trait stops the loop.
  Unique is always in the keep set. Result is saved so it runs once per unit.
- **Auto sell:** keeps locked/equipped units, level > 1 units, Mythic/Secret
  units, and one copy of each configured Team/Compass unit. Everything else is
  sent to `sell_units` in batches of 50 and the owned count is verified.
- **Votes:** deliberately fire-once per popup. No idle spam, no early firing.
- **Teleports:** `queue_on_teleport` reloads `AnimeAdventuresKaitun.lua` from
  the executor workspace (HTTP fallback), and embeds your config so it still
  applies after a fresh Lua VM.
