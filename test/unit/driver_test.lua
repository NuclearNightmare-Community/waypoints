-- Load test for the test driver (test/WaypointsDriver/Scripts/main.lua) outside the game: for every scenario it loads,
-- builds its steps, registers one 250 ms game-thread loop and runs a few ticks against an empty fake world (no player
-- controller yet) without a step throwing. The scenarios themselves only run in game (run.ps1, pair.ps1).
-- Run from the repo root:  texlua test/unit/driver_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
local DIR = ROOT .. "/test/WaypointsDriver/Scripts"
local MAIN = DIR .. "/main.lua"
package.path = ROOT .. "/test/unit/?.lua;" .. package.path
local H = require("fakeue").harness("driver_test")
local ok = H.ok

local printed, loops, shared, hooks = {}, {}, {}, {}
print = function(s) printed[#printed + 1] = (tostring(s):gsub("\n$", "")) end
local INVALID = { IsValid = function() return false end }
function FindFirstOf() return INVALID end
function FindAllOf() return nil end
function StaticFindObject() return INVALID end
function FName(s) return s end
function RegisterHook(path) hooks[#hooks + 1] = path return 1, 2 end
function LoopInGameThreadWithDelay(ms, fn) loops[#loops + 1] = { ms = ms, fn = fn } return #loops end
function CancelDelayedAction() return true end
function LoopAsync() error("driver must not use LoopAsync") end
function ExecuteInGameThread() error("driver must not use ExecuteInGameThread") end
ModRef = { SetSharedVariable = function(_, k, v) shared[k] = v end, GetSharedVariable = function(_, k) return shared[k] end }

local scenarioFile = DIR .. "/scenario.txt"
for _, sc in ipairs({ "probe", "revive", "death", "buttons", "buttons-revive", "no-core", "old-core", "pair-victim", "pair-host", "pair-hostvictim" }) do
    printed, loops = {}, {}
    local f = assert(io.open(scenarioFile, "w")); f:write(sc); f:close()
    local okL, err = pcall(dofile, MAIN)
    ok(okL, sc .. ": loads", err)
    local loaded, scen
    for _, l in ipairs(printed) do
        if l:find("^%[WaypointsDriver%] LOADED %d+ steps$") then loaded = l end
        if l == "[WaypointsDriver] SCENARIO " .. sc then scen = l end
    end
    ok(scen ~= nil, sc .. ": logs its scenario")
    ok(loaded ~= nil and tonumber(loaded:match("(%d+) steps")) > 3, sc .. ": builds steps", loaded)
    ok(#loops == 1 and loops[1].ms == 250, sc .. ": one 250 ms game-thread loop")
    if loops[1] then
        for _ = 1, 10 do local okT, e = pcall(loops[1].fn); ok(okT, sc .. ": tick runs", e) end
    end
    local threw = false
    for _, l in ipairs(printed) do if l:find("threw") then threw = true end end
    ok(not threw, sc .. ": no step threw")
end
ok(shared["nucleus.version"] == nil, "old-core without a core mod.json publishes nothing")
os.remove(scenarioFile)
printed, loops = {}, {}
local f = assert(io.open(scenarioFile, "w")); f:write("bogus"); f:close()
dofile(MAIN)
os.remove(scenarioFile)
local ended = false
for _, l in ipairs(printed) do if l:find("END result=FAIL .*unknown%-scenario bogus") then ended = true end end
ok(ended and #loops == 0, "unknown scenario: END FAIL, no loop")
-- Story 4: map.txt holds only a key of the driver's fixed table; each key loads and logs its MAP line, a bad key fails
-- the run before any travel (no loop), and no map.txt is Tower Island.
local mapFile = DIR .. "/map.txt"
local function load(sc, key)
    printed, loops = {}, {}
    local f1 = assert(io.open(scenarioFile, "w")); f1:write(sc); f1:close()
    os.remove(mapFile)
    if key then local f2 = assert(io.open(mapFile, "w")); f2:write(key); f2:close() end
    local okL, err = pcall(dofile, MAIN)
    os.remove(mapFile); os.remove(scenarioFile)
    return okL, err
end
local function line(pat) for _, l in ipairs(printed) do if l:find(pat) then return l end end return nil end
local WANT = {
    LowIsland = "/Game/Maps/Gameplay flags=10", TowerIsland = "/Game/Maps/SmallLoweIsland/SmallMap flags=6",
    Forest = "/Game/Maps/ForestMap/ForestMap flags=7", Crevasse = "/Game/Maps/CravasseMapV2/CravasseMap flags=9",
}
for key, want in pairs(WANT) do
    local okL, err = load("buttons", key .. "\r\n")
    ok(okL, "map " .. key .. ": loads", err)
    ok(line("^%[WaypointsDriver%] MAP " .. key .. " " .. want:gsub("%p", "%%%0") .. "$") ~= nil, "map " .. key .. ": MAP line", line("%] MAP "))
    ok(#loops == 1 and line("LOADED %d+ steps") ~= nil, "map " .. key .. ": builds steps and one loop")
    for _ = 1, 5 do local okT, e = pcall(loops[1].fn); ok(okT, "map " .. key .. ": tick runs", e) end
end
load("buttons", nil)
ok(line("^%[WaypointsDriver%] MAP TowerIsland /Game/Maps/SmallLoweIsland/SmallMap flags=6$") ~= nil, "no map.txt: Tower Island", line("%] MAP "))
load("pair-victim", "Forest")
ok(line("%] MAP ") == nil and #loops == 1, "pair role: no MAP line (PairDriver's map)")
for _, bad in ipairs({ "../x", "/Game/Maps/Gameplay", "forest", "TowerIsland2", "" }) do
    load("buttons", bad)
    ok(line("^%[WaypointsDriver%] FAIL MAP unknown map key") ~= nil, "bad key '" .. bad .. "': FAIL MAP", line("MAP"))
    ok(line("END result=FAIL .*reason=unknown%-map") ~= nil and #loops == 0, "bad key '" .. bad .. "': END FAIL, no loop (no travel)")
    ok(line("LOADED") == nil, "bad key '" .. bad .. "': no steps built")
end
os.remove(DIR .. "/request.txt"); os.remove(DIR .. "/done.txt")
H.done()
