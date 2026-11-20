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
	StoryHard = false,         -- true = play story/endgame acts on Hard
	RollAtGems = 20000,        -- go hunt when gems >= this
	SaveGems = 0,              -- never hunt below this many gems
	FpsBoost = true,           -- FPS boost on execute (default true)
	Webhook = "https://discord.com/api/webhooks/...", -- "" disables
	WebhookType = "Goal Only", -- "Goal Only" milestones | "All" + match events | "None"
	WebhookPing = "",          -- e.g. "<@123456789>" pinged on each webhook
	AutoSell = true,           -- sell units not on the team (see below)
}
loadstring(game:HttpGet("https://raw.githubusercontent.com/inCythe/AnimeAdventuresKaitun/main/loader.lua"))()
```

Unit names are matched case/punctuation-insensitively against both ids and
display names (`"C.E.O."`, `"ceo"`, `"speedwagon"` all resolve; `"Bulby"` =
`bulma`, `"Windsong"` = `wendy`, `"Hammergirl"` = `nobara`).

## Auto-sell

After the team is equipped (post-summon / post-hunt, lobby only):

- locked and equipped units are never sold
- each `CompassUnit`/`Team` unit keeps exactly **one** copy — the equipped one,
  or the highest-scored copy if none is equipped
- every other unit (all copies) is sold via `sell_units`

Set `AutoSell = false` to disable.

## Files

- `loader.lua` — entry point; fetch and run this
- `AnimeAdventuresKaitun.lua` — the automation script (edit here, not the downloaded copy)
