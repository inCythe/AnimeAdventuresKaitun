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
	TargetLevel = 40,        -- level to switch to endgame/infinite (default 50)
	WantedCompass = "Elyssia", -- unit picked with the celestial compass
	Wanted = {               -- units to hunt, in order (replaces HuntUnit)
		"Bulby", "C.E.O.", "Commander", "Hammergirl", "Windsong",
	},
	Supports = {             -- priority team units
		"Bulby", "C.E.O.", "Commander", "Hammergirl", "Windsong",
	},
	StoryTo = "All",         -- "All" or an act number (story skipper target)
	StoryHard = false,       -- true = play story/endgame acts on Hard
	RollAtGems = 20000,      -- go hunt when gems >= this
	SaveGems = 0,            -- never hunt below this many gems
	Webhook = "https://discord.com/api/webhooks/...", -- "" disables
	WebhookType = "Goal Only", -- "Goal Only" milestones | "All" + match events | "None"
	WebhookPing = "",        -- e.g. "<@123456789>" pinged on each webhook
}
```

Unit names are matched case-insensitively (`"C.E.O."` == `"ceo"` == `"c.e.o."`).

## Files

- `loader.lua` — entry point; fetch and run this
- `AnimeAdventuresKaitun.lua` — the automation script (edit here, not the downloaded copy)
