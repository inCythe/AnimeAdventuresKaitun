-- Anime Adventures — Kaitun loader
-- Paste this into your executor (autoexec folder recommended). It downloads
-- the latest Kaitun script from GitHub. It also re-queues itself via queue_on_teleport so the script
-- survives lobby -> match -> lobby teleports even without autoexec.

local LOADER_URL = "https://raw.githubusercontent.com/inCythe/AnimeAdventuresKaitun/main/loader.lua"
local SCRIPT_URL = "https://raw.githubusercontent.com/inCythe/AnimeAdventuresKaitun/main/AnimeAdventuresKaitun.lua"

if not game:IsLoaded() then
	repeat
		task.wait()
	until game:IsLoaded()
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
