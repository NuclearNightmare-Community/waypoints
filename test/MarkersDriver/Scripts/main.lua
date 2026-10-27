-- MarkersDriver: Markers' test driver. Installed only by deploy.ps1 -Test, never shipped; Markers itself carries no
-- test code. Plain UE4SS Lua: it doesn't connect to core (no-core runs without it), and it can't reach Markers' Lua
-- state, so it judges Markers by the world: the waypoint actors (their Name, Character, bReplicates), the map's flags
-- (Selected), and whether each on-screen waypoint is painted (a hook on its widget's text binding, which Slate calls
-- only while the widget is drawn). It loads Markers' own game.lua (Mods/Markers/Scripts) for the probe's respawn, so
-- the probe exercises the mod's real spawn path.
--
-- mods.txt order (deploy.ps1): <Core>, MarkersDriver, Markers.
-- Scenarios (Scripts/scenario.txt, written by deploy.ps1):
--   probe:   story 2's first in-game checks, solo host. (1) Does MapUI_C's Construct run on every map open? (opens and
--            closes the Journal from Lua three times, hooking MapUI_C:Construct, logging the flag widgets' paths).
--            (2) The bug: three location flags and the satellite clicked through their own handlers are painted;
--            RemoveAllWidgets (what death and the radio revive call) stops the painting. (3) Which repair paints again:
--            toggling the WidgetComponent's space, re-running the actor's BeginPlay (a new widget), or respawning the
--            actor (Markers' way). (4) Liveness: a waypoint the flag destroyed is still returned by FindAllOf until GC,
--            and game.alive() tells it apart.
--   revive:  a revive through the game's own code, solo host: the local character is queued (game state
--            UpdateRespawnQue) and the radio's ReinforceSpecficPlayer spawns and possesses a new character exactly as a
--            reinforcement does (RPCReinforcementMethod2 on this machine: RemoveAllWidgets, Possess, new HUD).
--            Revive 1 with onRevive=restore: one actor per marker, bound to the new pawn, painted, bReplicates false,
--            the flags match; same Journal instance? Then the driver rewrites Markers' settings.lua to onRevive=clear
--            (read at every revive) and revive 2: no waypoint, no flag selected.
--   death:   solo host: markers up, then the player dies (ExplosionDamage on itself; DeathEvent as fallback): spectator,
--            the waypoints keep existing, Markers takes its snapshot and does nothing else.
--   no-core, old-core: in a match: nothing from Markers (check.ps1 judges its one line).
--   pair-victim:     (B, a client in the VM) marks, is killed by the host, is revived by the host's radio; then the
--                    revive 1 checks on the client.
--   pair-host:       (A, the host, Markers not needed) once B is in the match: waits, kills B's character, waits for
--                    B's death, calls the radio's Reinformant (the computer's "call reinforcement"), waits for B's new
--                    character.
--   pair-hostvictim: (A, the host, modded) marks, dies, calls the radio's Reinformant itself, then the revive checks.
-- Keys it can't press itself (Enter for touchdown) go to run.ps1 through request.txt / done.txt next to this file.
-- Never keeps a UObject across steps: only paths and names, re-found each step.
local CORE = "Nucleus"
local MARKERS = "Markers"
local ME = "MarkersDriver"
local scriptDir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\]")
local modsDir = scriptDir:match("^(.*)[/\\][^/\\]+[/\\][Ss]cripts$") or "."

local function say(fmt, ...) print("[" .. ME .. "] " .. string.format(fmt, ...) .. "\n") end

local SCENARIO = "revive"
do
    local f = io.open(scriptDir .. "\\scenario.txt", "r")
    if f then SCENARIO = (f:read("*a") or ""):match("^%s*([%w%-]+)") or SCENARIO; f:close() end
end
say("SCENARIO %s", SCENARIO)

if SCENARIO == "old-core" then
    local f = io.open(modsDir .. "\\" .. CORE .. "\\mod.json", "r")
    local claimed = f and (f:read("*a") or ""):match('"version"%s*:%s*"([^"]+)"')
    if f then f:close() end
    if claimed then
        ModRef:SetSharedVariable(CORE:lower() .. ".version", claimed)
        say("OLDCORE published %s.version=%s (from %s's installed mod.json)", CORE:lower(), claimed, CORE)
    else
        say("FAIL OLDCORE could not read the version from %s's installed mod.json", CORE)
    end
end

local REQ, DONE = scriptDir .. "\\request.txt", scriptDir .. "\\done.txt"
os.remove(REQ); os.remove(DONE)

local MENU_MAP = "/Game/Maps/NewMainMenu"
local MATCH_MAP = "/Game/Maps/SmallLoweIsland/SmallMap"
local FP = "BP_FirstPersonCharacter_C"
local JOURNAL_CLASS = "/Game/Graphics/Journal/Journal.Journal_C"
local LOC_CLICK = "BndEvt__LevelLocationUI_Button_28_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
local SAT_CLICK = "BndEvt__SateliteUI_Button_28_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
local PAINT_FNS = { "/Game/Graphics/Journal/Waypoint1.Waypoint1_C:GetText", "/Game/Graphics/Journal/Waypoint3.Waypoint3_C:GetText" }

local S = { failures = 0, checks = 0, paint = {}, painting = false, marked = {} }

local function valid(o)
    if o == nil or type(o) ~= "userdata" and type(o) ~= "table" then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end
local function found(path) local o = path and StaticFindObject(path) return valid(o) and o or nil end
local function pathOf(o) return (o:GetFullName():gsub("^%S+ ", "")) end
local function classOf(o) local ok, c = pcall(function() return o:GetClass():GetFName():ToString() end) return ok and c or "?" end
local function text(t) local ok, s = pcall(function() return t:ToString() end) return ok and s or nil end
local function check(cond, fmt, ...)
    S.checks = S.checks + 1
    if not cond then S.failures = S.failures + 1 end
    say("%s " .. fmt, cond and "OK" or "FAIL", ...)
    return cond
end
local function GS() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end
local function WLL() return StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary") end

-- Markers' own adapter (the respawn the mod does), loaded from the installed mod; nil without it (no-core).
local G
do
    local chunk = loadfile(modsDir .. "\\" .. MARKERS .. "\\Scripts\\game.lua")
    if chunk then local ok, m = pcall(chunk) if ok then G = m end end
end

-- The local player controller (on a listen host FindFirstOf may return a client's controller).
local function pc()
    for _, c in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(c) then
            local ok, l = pcall(function() return c:IsLocalPlayerController() end)
            if ok and l then return c end
        end
    end
    return nil
end
local function remotePCs()
    local r = {}
    for _, c in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(c) then
            local ok, l = pcall(function() return c:IsLocalPlayerController() end)
            if ok and not l then r[#r + 1] = c end
        end
    end
    return r
end
local function pawnOf(c) if not c then return nil end local ok, p = pcall(function() return c:K2_GetPawn() end) return ok and valid(p) and p or nil end
local function myPawn() return pawnOf(pc()) end
local function worldName() local p = pc() return p and p:GetWorld():GetFullName() or "" end
local function liveHud()
    for _, w in ipairs(FindAllOf("InventoryUI_C") or {}) do
        if valid(w) and w:IsInViewport() then return w end
    end
    return nil
end

-- ---------------------------------------------------------------- markers in the world
local function alive(a) if G then return G.alive(a) end return valid(a) end
-- { name -> { n = count, path, character = path, replicates } } of the live waypoint actors of this world.
local function waypoints()
    local out, total = {}, 0
    local w = worldName()
    for _, short in ipairs({ "LevelWaypointActor_C", "SatelliteWaypoint_C" }) do
        for _, a in ipairs(FindAllOf(short) or {}) do
            if alive(a) and a:GetWorld():GetFullName() == w and not pathOf(a):find("Default__", 1, true) then
                local name = short == "SatelliteWaypoint_C" and "Satellite" or (text(a.Name) or "?")
                local e = out[name] or { n = 0 }
                e.n = e.n + 1
                e.path = pathOf(a)
                local okC, c = pcall(function() return a.Character end)
                e.character = okC and valid(c) and pathOf(c) or nil
                local okR, r = pcall(function() return a.bReplicates end)
                e.replicates = okR and r or nil
                out[name] = e
                total = total + 1
            end
        end
    end
    return out, total
end
local function describe(wp)
    local t = {}
    for name, e in pairs(wp) do t[#t + 1] = string.format("%s x%d char=%s rep=%s", name, e.n, tostring(e.character and e.character:match("[^.]+$")), tostring(e.replicates)) end
    table.sort(t)
    return table.concat(t, "; ")
end

-- ---------------------------------------------------------------- the Journal map, opened and closed from Lua
-- As BP_FirstPersonCharacter_C opens it (decompile ~15040): the prepared Journal for this controller, Controller,
-- OpenWithMap, Character, the character's Map, AddToViewport(0). The input mode isn't changed (nothing is typed).
local function journalFor(p, c)
    local cls = found(JOURNAL_CLASS)
    local lib = StaticFindObject("/Script/NuclearNightmare.Default__NNPreparedWidgetLibrary")
    if cls and valid(lib) then
        local ok, j = pcall(function() return lib:GetPreparedWidget(p, cls, c) end)
        if ok and valid(j) then return j end
    end
    local ok, j = pcall(function() return p.Map end)
    return ok and valid(j) and j or nil
end
local function openMap(phase)
    local c, p = pc(), myPawn()
    if not (c and p) then say("MAP %s no controller or pawn", phase) return nil end
    local j = journalFor(p, c)
    if not j then say("MAP %s no Journal", phase) return nil end
    pcall(function() j.Controller = c; j.OpenWithMap = true; j.Character = p; p.Map = j end)
    pcall(function() j:AddToViewport(0) end)
    S.journalPath = pathOf(j)
    return j
end
local function closeMap()
    local j = found(S.journalPath)
    if j then pcall(function() j:RemoveFromParent() end) end
end
local function mapUI()
    local j = found(S.journalPath)
    if not j then return nil end
    local ok, m = pcall(function() return j.MapWidget.MapUI end)
    return ok and valid(m) and m or nil
end
local function items(arr)
    local out = {}
    pcall(function() arr:ForEach(function(_, e) local x = e:get() if valid(x) then out[#out + 1] = x end end) end)
    return out
end
-- The location flags of the open map (first of each name) and the satellite flag.
local function flags()
    local m = mapUI()
    local list, seen, dupes = {}, {}, 0
    if m then
        for _, f in ipairs(items(m.Levels)) do
            local n = text(f.Name)
            if n then if seen[n] then dupes = dupes + 1 else seen[n] = true; list[#list + 1] = f end end
        end
    end
    local sat
    if m then local ok, s = pcall(function() return m.Satelite end) if ok and valid(s) then sat = s end end
    return list, sat, dupes
end
local function flagState(phase)
    local list, sat, dupes = flags()
    local sel = {}
    for _, f in ipairs(list) do if f.Selected then sel[#sel + 1] = text(f.Name) end end
    if sat and sat.Selected then sel[#sel + 1] = "Satellite" end
    table.sort(sel)
    say("FLAGS %s n=%d selected=%s dupes=%d", phase, #list + (sat and 1 or 0), table.concat(sel, ","), dupes)
    return sel, #list
end

-- ---------------------------------------------------------------- painting (is each waypoint drawn?)
local function paintHook()
    if S.paintHooked then return true end
    local any = false
    for _, fn in ipairs(PAINT_FNS) do
        local ok = pcall(RegisterHook, fn, function(self)
            if not S.painting then return end
            local okN, n = pcall(function() return self:get().Name:ToString() end)
            local name = (okN and n ~= "" and n) or "Satellite"
            S.paint[name] = (S.paint[name] or 0) + 1
        end)
        any = any or ok
        say("PAINTHOOK %s ok=%s", fn, tostring(ok))
    end
    S.paintHooked = any
    return any
end
-- Counts paints for `sec` seconds, then logs "PAINT <phase> name=n ...".
local function paintWindow(phase, sec, store)
    return function()
        S.paint, S.painting = {}, true
        local t0 = os.clock()
        return function()
            if os.clock() - t0 < sec then return false end
            S.painting = false
            local t = {}
            for name, n in pairs(S.paint) do t[#t + 1] = name .. "=" .. n end
            table.sort(t)
            say("PAINT %s %s", phase, #t > 0 and table.concat(t, " ") or "none")
            if store then S[store] = S.paint end
            return true
        end, sec + 5, phase .. " paint window"
    end
end

-- ---------------------------------------------------------------- steps and key requests
local seq = 0
local function request(cmd)
    seq = seq + 1
    local f = io.open(REQ, "w"); f:write(seq .. " " .. cmd); f:close()
    local mine = seq
    return function()
        local d = io.open(DONE, "r")
        if not d then return false end
        local s = d:read("*a"); d:close()
        return tonumber(s) == mine
    end
end
local function after(sec) local t = os.clock() + sec return function() return os.clock() >= t end end

local steps = {}
local function step(name, fn) steps[#steps + 1] = { name = name, fn = fn } end
local function wait(name, sec) step(name, function() return after(sec), sec + 5, name end) end

local function waitWorld(phase, mapPart, timeout)
    step(phase .. ": world", function()
        return function()
            if worldName():find(mapPart, 1, true) then say("WORLD %s %s", phase, worldName():match("/Game/[^ ]+") or "?") return true end
            return false
        end, timeout, phase .. " world " .. mapPart
    end)
end
local function waitHud(phase, timeout)
    step(phase .. ": hud", function()
        local since
        return function()
            local h, p = liveHud(), myPawn()
            if h and p and classOf(p) == FP then
                since = since or os.clock()
                if os.clock() - since >= 3 then S.pawnPath = pathOf(p) say("HUD %s pawn=%s", phase, S.pawnPath) return true end
            end
            return false
        end, timeout, phase .. " live HUD with a first-person pawn"
    end)
end
local function travel(phase, map, options)
    step(phase .. ": travel", function()
        say("TRAVEL %s OpenLevel %s%s", phase, map, options ~= "" and ("?" .. options) or "")
        GS():OpenLevel(pc(), FName(map), true, options)
        return after(3), 5, "travel start"
    end)
end
-- soft: in a pair run nobody may serve the request; the HUD wait after it decides.
local function touchdown(phase, soft)
    step(phase .. ": touchdown", function()
        say("TOUCHDOWN %s requesting Enter", phase)
        local done = request("key ENTER")
        if soft then local t = os.clock() + 20 return function() return done() or os.clock() > t end, 25, "touchdown key" end
        return done, 20, "touchdown key"
    end)
end
local function enterMatch(phase)
    waitWorld(phase, "NewMainMenu", 120)
    travel(phase, MATCH_MAP, "listen")
    waitWorld(phase, "SmallMap", 150)
    touchdown(phase)
    waitHud(phase, 90)
end

-- Opens the map, clicks n location flags and the satellite flag through their own handlers, closes it; checks one
-- waypoint actor per clicked marker.
local function mark(phase, n)
    step(phase .. ": open map", function() openMap(phase) return after(2), 5, "map open" end)
    step(phase .. ": click", function()
        local list, sat = flags()
        S.marked = {}
        for i = 1, math.min(n, #list) do
            local f = list[i]
            local ok, err = pcall(function() f[LOC_CLICK](f) end)
            local name = text(f.Name)
            if ok then S.marked[#S.marked + 1] = name end
            say("CLICK %s '%s' ok=%s %s", phase, tostring(name), tostring(ok), ok and "" or tostring(err))
        end
        if sat then
            local ok, err = pcall(function() sat[SAT_CLICK](sat) end)
            if ok then S.marked[#S.marked + 1] = "Satellite" end
            say("CLICK %s 'Satellite' ok=%s %s", phase, tostring(ok), ok and "" or tostring(err))
        end
        table.sort(S.marked)
        return after(1), 5, "clicks"
    end)
    step(phase .. ": close map", function() closeMap() return after(1), 5, "map closed" end)
    step(phase .. ": marked", function()
        local wp, total = waypoints()
        say("WAYPOINTS %s total=%d %s", phase, total, describe(wp))
        local one = #S.marked == n + 1
        for _, name in ipairs(S.marked) do one = one and wp[name] ~= nil and wp[name].n == 1 end
        check(one and total == #S.marked, "MARKED %s %d markers, one waypoint actor each (%s)", phase, #S.marked, table.concat(S.marked, ","))
        paintHook()
    end)
end

local function drawnAll(phase, store)
    step(phase .. ": drawn", function()
        local p = S[store] or {}
        local miss = {}
        for _, name in ipairs(S.marked) do if not ((p[name] or 0) > 0) then miss[#miss + 1] = name end end
        check(#miss == 0, "DRAWN %s every marker's waypoint is painted%s", phase, #miss > 0 and (" (not: " .. table.concat(miss, ",") .. ")") or "")
    end)
end

-- After a revive (the pawn changed): wait until every marked waypoint is bound to the new pawn (Markers restored it),
-- or until none is left (cleared), then check.
local function waitPawnChange(phase, timeout)
    step(phase .. ": new pawn", function()
        local was = S.pawnPath
        return function()
            local p = myPawn()
            if p and classOf(p) == FP and pathOf(p) ~= was and liveHud() then
                S.oldPawn, S.pawnPath = was, pathOf(p)
                say("NEWPAWN %s %s (was %s)", phase, S.pawnPath, tostring(was))
                return true
            end
            return false
        end, timeout, phase .. " new first-person pawn with a HUD"
    end)
end
local function restoredChecks(phase)
    step(phase .. ": wait restore", function()
        local t0 = os.clock()
        return function()
            local wp = waypoints()
            for _, name in ipairs(S.marked) do
                local e = wp[name]
                if not e then return false end
                if name ~= "Satellite" and e.character ~= S.pawnPath then return false end
            end
            say("RESTORE-SEEN %s after %.1f s", phase, os.clock() - t0)
            return true
        end, 20, phase .. " markers bound to the new pawn"
    end)
    step(phase .. ": restored", function()
        local wp, total = waypoints()
        say("WAYPOINTS %s total=%d %s", phase, total, describe(wp))
        local one, bound, rep = total == #S.marked, true, true
        for _, name in ipairs(S.marked) do
            local e = wp[name]
            one = one and e ~= nil and e.n == 1
            if name ~= "Satellite" then bound = bound and e ~= nil and e.character == S.pawnPath end
            rep = rep and e ~= nil and e.replicates == false
        end
        check(one, "ONE %s exactly one waypoint actor per marker (%d markers, %d actors)", phase, #S.marked, total)
        check(bound, "BOUND %s every location waypoint's Character is the new pawn", phase)
        check(rep, "LOCAL %s every waypoint actor has bReplicates=false", phase)
    end)
    step(phase .. ": paint", paintWindow(phase, 3, "paintAfter"))
    drawnAll(phase, "paintAfter")
    step(phase .. ": open map", function() openMap(phase) return after(2), 5, "map open" end)
    step(phase .. ": flags", function()
        local sel = flagState(phase)
        check(table.concat(sel, ",") == table.concat(S.marked, ","), "FLAGSMATCH %s the map shows exactly the marked flags selected (%s)", phase, table.concat(sel, ","))
        local j = S.journalPath
        say("JOURNAL %s %s (before the revive: %s)", phase, tostring(j), tostring(S.journalBefore))
        if S.journalBefore then say("ANSWER journal-same-after-revive=%s", j == S.journalBefore and "yes" or "no") end
        closeMap()
    end)
end
local function clearedChecks(phase)
    step(phase .. ": wait clear", function()
        return function() local _, total = waypoints() return total == 0 end, 20, phase .. " no waypoint left"
    end)
    step(phase .. ": paint", paintWindow(phase, 3, "paintCleared"))
    step(phase .. ": cleared", function()
        local _, total = waypoints()
        check(total == 0, "NONE %s no waypoint actor left (%d)", phase, total)
        local n = 0 for _ in pairs(S.paintCleared or {}) do n = n + 1 end
        check(n == 0, "NOPAINT %s no waypoint painted", phase)
    end)
    step(phase .. ": open map", function() openMap(phase) return after(2), 5, "map open" end)
    step(phase .. ": flags", function()
        local sel = flagState(phase)
        check(#sel == 0, "FLAGSNONE %s no flag selected (%s)", phase, table.concat(sel, ","))
        closeMap()
    end)
end

-- The radio's reinforcement of one character (BP_Radio_C:ReinforceSpecficPlayer, a server RPC run on the host) after
-- queueing it as a death would (game state UpdateRespawnQue).
local function syntheticRevive(phase)
    -- The death a real revive follows: death calls RemoveAllWidgets, and the player has no HUD for a while (core sees
    -- `lost`). Without it, core could see the old HUD replaced by the new one in one poll (no `lost`), which Markers
    -- rightly treats as a rebound (no proven death), not a revive.
    step(phase .. ": death's RemoveAllWidgets", function()
        local okR = pcall(function() WLL():RemoveAllWidgets(pc()) end)
        say("DEATHSIM %s RemoveAllWidgets ok=%s", phase, tostring(okR))
        return after(3), 8, "HUD lost"
    end)
    step(phase .. ": reinforce", function()
        local c, p = pc(), myPawn()
        S.journalBefore = S.journalPath
        local gs = valid(c) and c:GetWorld() and GS():GetGameState(c) or nil
        local radio = FindFirstOf("BP_Radio_C")
        if not (valid(gs) and valid(radio) and p) then check(false, "REINFORCE %s game state, radio and pawn found", phase) return end
        local okQ, eQ = pcall(function() gs:UpdateRespawnQue(c, p) end)
        local okR, eR = pcall(function() radio:ReinforceSpecficPlayer(p) end)
        say("REINFORCE %s UpdateRespawnQue ok=%s %s; ReinforceSpecficPlayer ok=%s %s", phase, tostring(okQ), okQ and "" or tostring(eQ), tostring(okR), okR and "" or tostring(eR))
    end)
    waitPawnChange(phase, 60)
end

local function setOnRevive(value)
    step("set onRevive=" .. value, function()
        local path = modsDir .. "\\" .. MARKERS .. "\\Scripts\\settings.lua"
        local f = io.open(path, "w")
        if not f then check(false, "SETTINGS could not write %s", path) return end
        f:write('-- Rewritten by MarkersDriver (test only).\nreturn { onRevive = "' .. value .. '", debug = true }\n')
        f:close()
        say("SETTINGS onRevive=%s written to Markers' settings.lua", value)
    end)
end

-- Kills a character on the host (authority): the game's own explosion damage; DeathEvent if it's still alive later.
local function kill(phase, which)
    step(phase .. ": kill", function()
        local target = which()
        if not target then check(false, "KILL %s target found", phase) return end
        S.killed = pathOf(target)
        local ok, err = pcall(function() target:ExplosionDamage(target, 10000.0) end)
        say("KILL %s %s ExplosionDamage ok=%s %s", phase, S.killed, tostring(ok), ok and "" or tostring(err))
        return after(5), 10, "death"
    end)
    step(phase .. ": kill fallback", function()
        local t = found(S.killed)
        local stillPossessed = false
        for _, c in ipairs(FindAllOf("PlayerController") or {}) do if valid(c) and pawnOf(c) and pathOf(pawnOf(c)) == S.killed then stillPossessed = true end end
        if t and stillPossessed then
            local ok, err = pcall(function() t:DeathEvent() end)
            say("KILL %s still possessed after 5 s: DeathEvent ok=%s %s", phase, tostring(ok), ok and "" or tostring(err))
        end
    end)
end

-- ---------------------------------------------------------------- scenarios
local function buildProbe()
    enterMatch("match1")
    -- (1) MapUI_C Construct on every open
    step("construct hook", function()
        local ok = pcall(RegisterHook, "/Game/Graphics/Journal/MapUI.MapUI_C:Construct", function(self)
            S.constructs = (S.constructs or 0) + 1
            local okP, p = pcall(function() return pathOf(self:get()) end)
            say("CONSTRUCT n=%d %s", S.constructs, okP and p or "?")
        end)
        S.constructHooked = ok
        say("CONSTRUCTHOOK ok=%s (a miss before the first open: the class isn't loaded yet; opens 2-4 decide)", tostring(ok))
    end)
    for i = 1, 4 do
        step("open " .. i, function()
            S.opens = (S.opens or 0) + 1
            S.constructsBefore = S.constructs or 0
            openMap("open" .. i)
            if not S.constructHooked then
                S.constructHooked = pcall(RegisterHook, "/Game/Graphics/Journal/MapUI.MapUI_C:Construct", function() S.constructs = (S.constructs or 0) + 1 end)
            end
            return after(2), 5, "open"
        end)
        step("list " .. i, function()
            local list, sat, dupes = flags()
            local paths = {}
            for k = 1, math.min(3, #list) do paths[#paths + 1] = pathOf(list[k]):match("[^.]+$") end
            say("MAPOPEN %d journal=%s mapui=%s flags=%d dupes=%d constructs+%d first=%s", i, tostring(S.journalPath and S.journalPath:match("[^.]+$")),
                tostring(mapUI() and pathOf(mapUI()):match("[^.]+$")), #list, dupes, (S.constructs or 0) - S.constructsBefore, table.concat(paths, ","))
            S.firstFlags = S.firstFlags or {}
            S.firstFlags[i] = table.concat(paths, ",")
            closeMap()
            return after(2), 5, "close"
        end)
    end
    step("answer construct", function()
        local rebuilt = S.firstFlags[2] ~= S.firstFlags[3] or S.firstFlags[3] ~= S.firstFlags[4]
        say("ANSWER construct-every-open=%s flags-rebuilt-each-open=%s (constructs=%d over %d opens)",
            (S.constructs or 0) >= 3 and "yes" or ((S.constructs or 0) == 0 and "unknown" or "no"), rebuilt and "yes" or "no", S.constructs or 0, S.opens or 0)
    end)
    -- (2) the bug: painted, then not after RemoveAllWidgets
    mark("mark", 3)
    step("paint before", paintWindow("before", 3, "paintBefore"))
    drawnAll("before", "paintBefore")
    step("remove all widgets", function()
        local c = pc()
        local okR = pcall(function() WLL():RemoveAllWidgets(c) end)
        say("REMOVEALL ok=%s", tostring(okR))
        return after(1), 5, "removed"
    end)
    step("re-add hud", function()
        local h
        for _, w in ipairs(FindAllOf("InventoryUI_C") or {}) do if valid(w) and pcall(function() return w.Player end) then h = w end end
        local p = myPawn()
        pcall(function() if p and valid(p.DirectInventoryRef) then h = p.DirectInventoryRef end end)
        local ok = h and pcall(function() h:AddToViewport(0) end)
        say("READD hud ok=%s", tostring(ok))
        return after(2), 5, "hud back"
    end)
    step("paint removed", paintWindow("removed", 3, "paintRemoved"))
    step("repro", function()
        local n = 0 for _ in pairs(S.paintRemoved or {}) do n = n + 1 end
        check(n == 0, "REPRO after RemoveAllWidgets no waypoint is painted (%d painted): the bug, and the paint hook sees it", n)
    end)
    -- (3) repairs, one per marker
    step("repairs", function()
        local wp = {}
        for _, short in ipairs({ "LevelWaypointActor_C", "SatelliteWaypoint_C" }) do
            for _, a in ipairs(FindAllOf(short) or {}) do
                if alive(a) then wp[short == "SatelliteWaypoint_C" and "Satellite" or text(a.Name)] = a end
            end
        end
        local names = {}
        for _, n in ipairs(S.marked) do if n ~= "Satellite" then names[#names + 1] = n end end
        S.method = {}
        local function try(name, method, fn)
            local a = wp[name]
            if not a then say("REPAIR %s '%s' no actor", method, tostring(name)) return end
            local ok, err = pcall(fn, a)
            S.method[name] = method
            say("REPAIR %s '%s' ok=%s %s", method, name, tostring(ok), ok and "" or tostring(err))
        end
        try(names[1], "toggle-space", function(a) a.Widget:SetWidgetSpace(0); a.Widget:SetWidgetSpace(1) end)
        try(names[2], "rerun-beginplay", function(a) a:ReceiveBeginPlay() end)
        local p = myPawn()
        local function respawn(a)
            if not G then error("Markers' game.lua not loaded") end
            local kind = classOf(a) == "SatelliteWaypoint_C" and "satellite" or "location"
            local v = a:K2_GetActorLocation()
            local n, info = G.spawn({ kind = kind, name = kind == "satellite" and "Satellite" or text(a.Name), loc = { X = v.X, Y = v.Y, Z = v.Z } }, p, a)
            say("RESPAWN via %s bReplicates=%s", tostring(info.via), tostring(info.replicates))
            G.destroy(a)
        end
        try(names[3], "respawn", respawn)
        try("Satellite", "respawn", respawn)
        return after(1), 5, "repairs"
    end)
    step("paint repaired", paintWindow("repaired", 3, "paintRepaired"))
    step("answer repair", function()
        local t = {}
        for name, method in pairs(S.method or {}) do
            local drawn = ((S.paintRepaired or {})[name] or 0) > 0
            t[#t + 1] = method .. "(" .. name .. ")=" .. (drawn and "drawn" or "not-drawn")
        end
        table.sort(t)
        say("ANSWER repair %s", table.concat(t, " "))
        local okResp = true
        for name, method in pairs(S.method or {}) do if method == "respawn" and not (((S.paintRepaired or {})[name] or 0) > 0) then okResp = false end end
        check(okResp, "RESPAWN-DRAWN a respawned waypoint is painted again (Markers' way)")
    end)
    -- (4) liveness of destroyed actors
    step("liveness", function()
        openMap("liveness")
        local list = flags()
        local f = list[4] or list[#list]
        if not f then check(false, "LIVENESS a fourth flag") return end
        pcall(function() f[LOC_CLICK](f) end); pcall(function() f[LOC_CLICK](f) end) -- on, then off: its actor destroyed
        local name = text(f.Name)
        local seen, live = 0, 0
        for _, a in ipairs(FindAllOf("LevelWaypointActor_C") or {}) do
            if valid(a) and text(a.Name) == name then seen = seen + 1; if alive(a) then live = live + 1 end end
        end
        closeMap()
        say("LIVENESS '%s' FindAllOf=%d alive=%d", tostring(name), seen, live)
        check(live == 0, "LIVENESS a waypoint destroyed by its flag is not counted alive (FindAllOf=%d, alive=%d)", seen, live)
    end)
end

local function buildRevive()
    enterMatch("match1")
    mark("mark", 2)
    step("paint before", paintWindow("before", 3, "paintBefore"))
    drawnAll("before", "paintBefore")
    step("journal before", function() openMap("before") return after(1), 5, "open" end)
    step("journal before 2", function() flagState("before") closeMap() end)
    syntheticRevive("revive1")
    restoredChecks("revive1")
    setOnRevive("clear")
    syntheticRevive("revive2")
    clearedChecks("revive2")
end

local function buildDeath()
    enterMatch("match1")
    mark("mark", 2)
    kill("death", myPawn)
    wait("after death", 15)
    step("dead", function()
        local p = myPawn()
        say("DEAD pawn=%s class=%s hud=%s", p and pathOf(p) or "none", p and classOf(p) or "none", tostring(liveHud() ~= nil))
        check(not (p and classOf(p) == FP and pathOf(p) == S.pawnPath), "DEAD the player no longer controls its first-person character")
        local wp, total = waypoints()
        say("WAYPOINTS dead total=%d %s", total, describe(wp))
        check(total == #S.marked, "KEPT the waypoint actors survive the death (%d of %d)", total, #S.marked)
        local untouched = true
        for name, e in pairs(wp) do if name ~= "Satellite" and e.character ~= S.pawnPath then untouched = false end end
        check(untouched, "UNTOUCHED no waypoint was rebound after a death without a revive")
    end)
end

local function buildNoMarkers()
    enterMatch("match1")
    wait("watch", 10)
    step("no markers activity", function()
        check(true, "NOMARKERS match1 reached the match; Markers' one line is judged by check.ps1")
    end)
end

-- Pair roles (tools/vm/pair.ps1 scenarios in test/pair/markers-scenarios.ps1). The lobby and the match come from
-- PairDriver on the host; the victim only waits for them.
local function waitMatch(phase, timeout)
    step(phase .. ": match", function()
        return function() return worldName():find("/Game/Maps/", 1, true) ~= nil and not worldName():find("NewMainMenu", 1, true) end, timeout, phase .. " a match world"
    end)
    touchdown(phase, true)
    waitHud(phase, 300)
end
local function buildPairVictim()
    waitMatch("match", 900)
    mark("mark", 2)
    step("paint before", paintWindow("before", 3, "paintBefore"))
    drawnAll("before", "paintBefore")
    step("victim ready", function() say("VICTIM ready marked=%s", table.concat(S.marked, ",")) end)
    step("death", function()
        local was = S.pawnPath
        return function() local p = myPawn() return not (p and classOf(p) == FP and pathOf(p) == was) end, 600, "killed by the host"
    end)
    step("dead", function() local p = myPawn() say("DEAD pawn=%s class=%s", p and pathOf(p) or "none", p and classOf(p) or "none") end)
    waitPawnChange("revive", 600)
    restoredChecks("revive")
end
local function buildPairHost()
    waitMatch("match", 900)
    step("victim present", function()
        return function() return #remotePCs() > 0 and pawnOf(remotePCs()[1]) ~= nil and classOf(pawnOf(remotePCs()[1])) == FP end, 600, "the other player's character"
    end)
    wait("victim marks", 90) -- the victim opens its map and marks (it logs VICTIM ready on its own machine)
    kill("victim", function() return pawnOf(remotePCs()[1]) end)
    step("victim dead", function()
        return function()
            local p = pawnOf(remotePCs()[1])
            return not (p and pathOf(p) == S.killed)
        end, 120, "the victim's death"
    end)
    step("victim state", function()
        local p = pawnOf(remotePCs()[1])
        S.victimAfterDeath = p and classOf(p) or "none"
        say("VICTIM after death pawn class=%s%s", S.victimAfterDeath, S.victimAfterDeath == "BP_ThirdPersonCharacter_C" and " (became a monster: the revive can't run; INCONCLUSIVE)" or "")
        return after(10), 15, "settle"
    end)
    step("reinforce", function()
        local radio = FindFirstOf("BP_Radio_C")
        local ok, err = pcall(function() radio:Reinformant() end)
        say("REINFORCE radio:Reinformant() ok=%s %s", tostring(ok), ok and "" or tostring(err))
    end)
    step("victim revived", function()
        return function()
            local p = pawnOf(remotePCs()[1])
            return p ~= nil and classOf(p) == FP and pathOf(p) ~= S.killed
        end, 180, "the victim's new character"
    end)
    step("revived", function()
        check(true, "REVIVED the victim has a new first-person character %s", pathOf(pawnOf(remotePCs()[1])))
        return after(30), 35, "let the victim check"
    end)
end
local function buildPairHostVictim()
    waitMatch("match", 900)
    step("other present", function() return function() return #remotePCs() > 0 end, 600, "the other player" end)
    mark("mark", 2)
    step("paint before", paintWindow("before", 3, "paintBefore"))
    drawnAll("before", "paintBefore")
    kill("death", myPawn)
    wait("after death", 15)
    step("reinforce", function()
        local radio = FindFirstOf("BP_Radio_C")
        local ok, err = pcall(function() radio:Reinformant() end)
        say("REINFORCE radio:Reinformant() ok=%s %s", tostring(ok), ok and "" or tostring(err))
    end)
    waitPawnChange("revive", 180)
    restoredChecks("revive")
end

-- ---------------------------------------------------------------- runner (game thread, every 250 ms)
local idx, waiting, busy, finished = 0, nil, false, false
local function finish()
    finished = true
    say("END result=%s checks=%d failures=%d", (S.failures == 0 and S.checks > 0) and "PASS" or "FAIL", S.checks, S.failures)
end
local function tick()
    if busy or finished then return end
    busy = true
    local ok, err = pcall(function()
        if waiting then
            if not waiting.pred() then
                if os.clock() <= waiting.deadline then return end
                check(false, "TIMEOUT %s", waiting.what)
            end
            waiting = nil
        end
        idx = idx + 1
        local s = steps[idx]
        if not s then finish() return end
        local pred, timeout, what = s.fn()
        if pred then waiting = { pred = pred, deadline = os.clock() + (timeout or 10), what = what or s.name } end
    end)
    if not ok then
        check(false, "STEP '%s' threw: %s", steps[idx] and steps[idx].name or "?", tostring(err))
        waiting = nil
    end
    busy = false
end

local build = ({ probe = buildProbe, revive = buildRevive, death = buildDeath, ["no-core"] = buildNoMarkers, ["old-core"] = buildNoMarkers,
                 ["pair-victim"] = buildPairVictim, ["pair-host"] = buildPairHost, ["pair-hostvictim"] = buildPairHostVictim })[SCENARIO]
if not build then
    say("END result=FAIL checks=0 failures=1 reason=unknown-scenario %s", SCENARIO)
    return
end
build()
-- A game-thread loop (never LoopAsync + ExecuteInGameThread: the pinned UE4SS can lose those callbacks).
local runner
local okL, res = pcall(LoopInGameThreadWithDelay, 250, function()
    tick()
    if finished and runner then pcall(CancelDelayedAction, runner); runner = nil end
end)
if okL then runner = res else say("END result=FAIL checks=0 failures=1 reason=loop %s", tostring(res)) end
say("LOADED %d steps", #steps)
