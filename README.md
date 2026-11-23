# Anime Adventures — Kaitun

One-click full automation for **[☀️UPD 21🏖️] Anime Adventures** (universe `3183403065`).

## Usage

Paste `loader.lua` into your executor (autoexec folder recommended). It:

- only runs inside the Anime Adventures universe
- downloads the latest `AnimeAdventuresKaitun.lua` from GitHub
- re-queues itself via `queue_on_teleport` so it survives lobby → match → lobby teleports

## Options

Set `getgenv().Kaitun` **before** running the loader/script:

```lua
getgenv().Kaitun = {
	TargetLevel = 50,          -- level to switch to endgame/infinite (default 50)
	CompassUnit = "Elyssia",   -- celestial compass pick AND hunt target
	Team = {                   -- units to equip, in order; unowned ones are skipped
		"Bulby", "Windsong", "C.E.O.", "Hammergirl",
	},
	RollAtGems = 20000,        -- go hunt when gems >= this
	SaveGems = 0,              -- never hunt below this many gems
	FpsBoost = true,           -- FPS boost on execute (default true)
	Webhook = "https://discord.com/api/webhooks/...", -- "" disables
	WebhookType = "Goal Only", -- "Goal Only" milestones | "All" + match events | "None"
	WebhookPing = "",          -- e.g. "<@123456789>" pinged on each webhook
	AutoSell = true,           -- sell units not on the team (see below)
	SkipCutscenes = true,      -- skip summon/reward/hatch cinematics (default true)
	Challenges = false,        -- true = join daily/normal challenges and leave
	                           -- matches for the :00/:30 resets (default false)
	ChallengesOnlyAfterCompass = false, -- true = once the compass unit is owned,
	                                 -- stop joining story/infinite; lobby only
	                                 -- takes challenges/dailies
	AutoTrait = true,          -- roll traits on the compass unit once owned (default true)
	TraitKeep = { "unique" },  -- traits to keep; Unique is ALWAYS kept, add more below
	                           -- e.g. { "reaper", "divine", "Celestial" } (id or display name)
	TraitSources = { "token", "remnant", "remnant_ltd" }, -- spending order;
	                           -- skips any source with no resources left
	TraitMinResources = 0,     -- stop when every source is at/below this
	TraitRollDelay = 0.25,     -- seconds between rolls
	TraitChangeTimeout = 5,    -- seconds to wait for a roll to register
}
loadstring(game:HttpGet("https://raw.githubusercontent.com/inCythe/AnimeAdventuresKaitun/main/loader.lua"))()
```

Unit names are matched case/punctuation-insensitively against both ids and
display names (`"C.E.O."`, `"ceo"`, `"speedwagon"` all resolve; `"Bulby"` =
`bulma`, `"Windsong"` = `wendy`, `"Hammergirl"` = `nobara`).

## Auto-sell

After every hunt 10x roll, and again after the team is equipped
(post-summon / post-hunt, lobby only — the first summon is excluded):

- locked and equipped units are never sold
- each `CompassUnit`/`Team` unit keeps exactly **one** copy — the equipped one,
  or the highest-scored copy if none is equipped
- every other unit (all copies) is sold via `sell_units`

Set `AutoSell = false` to disable.

## Challenges

Daily/Normal challenge joins are **off by default**. Set `Challenges = true`
to enable them — the lobby will queue challenges when they reset on the
:00/:30 clock, and matches will end a bit early to be in the lobby in time.

## Challenges-only mode

Set `ChallengesOnlyAfterCompass = true` to stop the infinite grind once the
celestial compass unit is actually summoned/owned — using the compass item
alone does not trigger it:

- infinite tower is never joined again (story still runs until `TargetLevel`,
  and act 6 is still attempted once)
- the script stays in the lobby and only takes Daily/Normal challenge joins,
  including ones that reset on the :00/:30 clock (requires `Challenges = true`)
- hunt and the one-time lobby claims (codes, dailies, summons, team equip)
  still run normally before the compass unit is obtained

## Auto trait rolling

Once the compass unit is actually owned (from the compass pick, the first
summon, or the hunt), the script rolls its traits automatically:

- spends **trait reroll tokens** first, then `star_remnant`, then
  `star_remnant_limited` — each source is skipped when it runs out, so all
  available resources are used before stopping
- `Unique` is **always** kept; add more winners with `TraitKeep` (ids or
  display names, e.g. `{ "reaper", "divine", "Celestial" }`)
- before **every** roll it re-reads the unit's live traits and stops if a kept
  trait is already present, so a roll is never wasted
- stops when a kept trait lands or all resources are gone; there is no roll
  limit
- a **webhook** reports the result: "Unique rolled on X" (green) if it landed,
  otherwise "Trait rolls finished on X" with the final trait list. Requires
  `Webhook` to be set; `WebhookType = "None"` disables all webhooks.
- the outcome is saved per unit in the state file, so each unit is only rolled
  once. Set `AutoTrait = false` to disable entirely.

## Files

- `loader.lua` — entry point; fetch and run this
- `AnimeAdventuresKaitun.lua` — the automation script (edit here, not the downloaded copy)
