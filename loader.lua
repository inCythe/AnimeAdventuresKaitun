-- Anime Adventures — Kaitun loader
-- Paste this into your executor (autoexec folder recommended).
-- Downloads the ONE hosted script (AnimeAdventuresKaitun.lua at repo root) from
-- GitHub and re-queues itself via queue_on_teleport so it survives
-- lobby -> match -> lobby teleports even without autoexec.

local LOADER_URL = "https://raw.githubusercontent.com/inCythe/AnimeAdventuresKaitun/main/loader.lua"
local SCRIPT_URL = "https://raw.githubusercontent.com/inCythe/AnimeAdventuresKaitun/main/AnimeAdventuresKaitun.lua"

if not game:IsLoaded() then
	repeat
		task.wait()
	until game:IsLoaded()
end

-- Never start the hosted script without the user's getgenv config. If we load
-- before the config is set, its built-in default compass unit (elyssia) would
-- be used and then embedded into the teleport stub, replacing the real config.
local ConfigDeadline = os.clock() + 60
while type(getgenv().Kaitun) ~= "table" and os.clock() < ConfigDeadline do
	task.wait(0.2)
end
if type(getgenv().Kaitun) ~= "table" then
	warn("[AA Kaitun] getgenv().Kaitun never appeared - aborting instead of using defaults")
	return
end

-- queue the loader itself for the next server
pcall(function()
	if type(queue_on_teleport) == "function" then
		queue_on_teleport(
			'local fn = loadstring(game:HttpGet("' .. LOADER_URL .. '"))\nif fn then fn() end'
		)
	end
end)

local Ok, Fn = pcall(function()
	return loadstring(game:HttpGet(SCRIPT_URL))
end)
if Ok and type(Fn) == "function" then
	task.spawn(Fn)
else
	warn("[AA Kaitun] loader failed to fetch script:", Fn)
end
