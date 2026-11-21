-- Anime Adventures — Kaitun loader
-- Paste this into your executor (autoexec folder recommended). It only runs
-- inside the Anime Adventures universe and downloads the latest Kaitun script
-- from GitHub. It also re-queues itself via queue_on_teleport so the script
-- survives lobby -> match -> lobby teleports even without autoexec.

local UNIVERSE_ID = 3183403065 -- Anime Adventures
local LOADER_URL = "https://raw.githubusercontent.com/inCythe/AnimeAdventuresKaitun/main/loader.lua"
local SCRIPT_URL = "https://raw.githubusercontent.com/inCythe/AnimeAdventuresKaitun/main/AnimeAdventuresKaitun.lua"

if not game:IsLoaded() then
	repeat
		task.wait()
	until game:IsLoaded()
end

-- wait until the local player exists
local LocalPlayer = game:GetService("Players").LocalPlayer
if not LocalPlayer then
	LocalPlayer = game:GetService("Players").PlayerAdded:Wait()
end

if game.GameId ~= UNIVERSE_ID then
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

local GEN = (getgenv and getgenv()) or _G

local function RunScript()
	GEN.AAKaitunLoaded = false
	local Ok, Fn = pcall(function()
		return loadstring(game:HttpGet(SCRIPT_URL))
	end)
	if Ok and type(Fn) == "function" then
		-- spawn so this loader stays free to poll the loaded flag; the
		-- script's single-instance guard retires any previous copy
		task.spawn(Fn)
	else
		warn("[AA Kaitun] loader failed to fetch script:", Fn)
	end
end

RunScript()

-- the script sets getgenv().AAKaitunLoaded once its session is up; if it
-- never does (slow load, early error, dead remote), run it again
for _ = 1, 5 do
	local Deadline = os.clock() + 60
	while os.clock() < Deadline do
		if GEN.AAKaitunLoaded then
			return
		end
		task.wait(1)
	end
	warn("[AA Kaitun] script not loaded after 60s, retrying")
	RunScript()
end
