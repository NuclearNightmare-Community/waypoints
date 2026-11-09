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
for _, sc in ipairs({ "probe", "revive", "death", "no-core", "old-core", "pair-victim", "pair-host", "pair-hostvictim" }) do
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
os.remove(DIR .. "/request.txt"); os.remove(DIR .. "/done.txt")
H.done()
