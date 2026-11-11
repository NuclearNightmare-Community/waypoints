-- WaypointsDriver: Waypoints' test driver. Installed only by deploy.ps1 -Test, never shipped; Waypoints itself carries no
-- test code. Plain UE4SS Lua: it doesn't connect to core (no-core runs without it), and it can't reach Waypoints' Lua
-- state, so it judges Waypoints by the world: the waypoint actors (their Name, Character, bReplicates), the map's flags
-- (Selected), and whether each on-screen waypoint is painted (a hook on its widget's text binding, which Slate calls
-- only while the widget is drawn). It loads Waypoints' own game.lua (Mods/Waypoints/Scripts) for the probe's respawn, so
-- the probe exercises the mod's real spawn path.
--
-- mods.txt order (deploy.ps1): <Core>, WaypointsDriver, Waypoints.
-- Scenarios (Scripts/scenario.txt, written by deploy.ps1):
--   probe:   story 2's first in-game checks, solo host. (1) Does MapUI_C's Construct run on every map open? (opens and
--            closes the Journal from Lua three times, hooking MapUI_C:Construct, logging the flag widgets' paths).
--            (2) The bug: three location flags and the satellite clicked through their own handlers are painted;
--            RemoveAllWidgets (what death and the radio revive call) stops the painting. (3) Which repair paints again:
--            toggling the WidgetComponent's space, re-running the actor's BeginPlay (a new widget), or respawning the
--            actor (Waypoints' way). (4) Liveness: a waypoint the flag destroyed is still returned by FindAllOf until GC,
--            and game.alive() tells it apart.
--   revive:  a revive through the game's own code, solo host (V8.1.5+): the game state's EOGLock holds the match
--            (stands in for a living teammate), the player really dies (kill: one CallDamageEvent(1000), the game's
--            whole death), then the radio's ReinforceSpecficPlayer(dead body) spawns and possesses a new character as
--            the computer's reinforcement button does; EOGLock is released after it.
--            Revive 1 with onRevive=restore: one actor per waypoint, bound to the new pawn, painted, bReplicates false,
--            the flags match; same Journal instance? Then the driver rewrites Waypoints' settings.lua to onRevive=clear
--            (read at every revive) and revive 2: no waypoint, no flag selected.
--   death:   solo host: waypoints up, then the player dies (one CallDamageEvent(1000), then the game's own death):
--            spectator, the waypoint actors keep existing, Waypoints does nothing else. Also answers (not a check)
--            whether the waypoints still paint while spectating.
--   Kills are judged by the game's own signals (DIED: Health <= 0 and NNDeathFadeLibrary:CanBeginTerminalDeathEffects;
--   SPECTATOR: the controller's pawn ~12 s later), never by the HUD. TRACE and HUDSTATE lines log the death path.
--   buttons: story 3, solo host: 2 location flags marked by their own click (no satellite), the lobby countdown cut,
--            the map opened by the real key IA_Map is bound to, Waypoints' Mark all clicked with the real mouse: one
--            live waypoint actor per flag (and the satellite), every flag Selected; Clear all: none left, none
--            Selected; the map closed and reopened by the key: every flag's Selected matches its actor (FLAGSMATCH).
--            Story 5: after both key opens, the panel is placed under the map square (PANELPLACE, canvas units).
--            Waypoints' own MARKALL / CLEARALL / MAPSYNC lines are judged by check.ps1 against the EXPECT line.
--   no-core, old-core: in a match: nothing from Waypoints (check.ps1 judges its one line).
--   The solo scenarios travel to the map named in Scripts/map.txt (deploy.ps1 -Test -Map): a key of the fixed MAPS
--   table, never a path; an unknown key ends the run (FAIL MAP) before any travel; no map.txt is Tower Island. They log
--   "MAP <key> <path> flags=<n>", and buttons checks the map's distinct flag names against n (FLAGCOUNT).
--   pair-victim:     (B, a client in the VM) marks, dies on the host's signal (kill.txt: CallDamageEvent(1000) on its
--                    own pawn), is revived by the host's radio; then the revive 1 checks on the client; then Mark all
--                    and Clear all on the map opened from Lua, each pressed through core's <Core>_OnClicked() (BPRESS;
--                    not an OS click), with the world checks of buttons (phase "pair").
--   pair-host:       (A, the host, Waypoints not needed) once B is in the match: marks one location flag of its own,
--                    waits, signals B's kill (and kills B itself if B is still alive 30 s later), waits for B's death,
--                    calls the radio's Reinformant (the computer's "call reinforcement"), waits for B's new character
--                    and 90 s for B's checks and buttons; then its own waypoint must be untouched (UNAFFECTED host).
--   pair-hostvictim: (A, the host, modded) marks, dies, calls the radio's Reinformant itself, then the revive checks.
-- Keys it can't press itself (Enter for touchdown, the map key) and real mouse clicks ("click x y", desktop pixels) go
-- to run.ps1 through request.txt / done.txt next to this file.
-- Never keeps a UObject across steps: only paths and names, re-found each step.
local CORE = "Nucleus"
local WAYPOINTS = "Waypoints"
local ME = "WaypointsDriver"
local scriptDir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\]")
local modsDir = scriptDir:match("^(.*)[/\\][^/\\]+[/\\][Ss]cripts$") or "."

local function say(fmt, ...) print("[" .. ME .. "] " .. string.format(fmt, ...) .. "\n") end

local SCENARIO = "revive"
do
    local f = io.open(scriptDir .. "\\scenario.txt", "r")
    if f then SCENARIO = (f:read("*a") or ""):match("^%s*([%w%-]+)") or SCENARIO; f:close() end
end
say("SCENARIO %s", SCENARIO)
-- pair-victim's kill signal (written into this folder by pair.ps1 through waypoints-scenarios.ps1); never a stale one.
local KILL_SIGNAL = scriptDir .. "\\kill.txt"
os.remove(KILL_SIGNAL)

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
-- The solo match map (Scripts/map.txt, written by deploy.ps1 -Test -Map, holds only a key of this fixed table; no file
-- content ever becomes a path). flags: the map's distinct location flag names (LevelLocationMap_C on V8.2.1, the SPEC's
-- counts). No map.txt: Tower Island, as before the table existed.
local MAPS = {
    LowIsland   = { path = "/Game/Maps/Gameplay", flags = 10 },
    TowerIsland = { path = "/Game/Maps/SmallLoweIsland/SmallMap", flags = 6 },
    Forest      = { path = "/Game/Maps/ForestMap/ForestMap", flags = 7 },
    Crevasse    = { path = "/Game/Maps/CravasseMapV2/CravasseMap", flags = 9 },
}
local MAP_KEY, MAP_BAD = "TowerIsland", nil
do
    local f = io.open(scriptDir .. "\\map.txt", "r")
    if f then
        local raw = f:read("*a") or ""
        f:close()
        local key = raw:match("^%s*(.-)%s*$")
        if MAPS[key] then MAP_KEY = key else MAP_BAD = key:gsub("[^%w%p ]", "?"):sub(1, 40) end
    end
end
local MAP = MAPS[MAP_KEY]
local MATCH_MAP = MAP.path
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

-- Waypoints' own adapter (the respawn the mod does), loaded from the installed mod; nil without it (no-core).
local G
do
    local chunk = loadfile(modsDir .. "\\" .. WAYPOINTS .. "\\Scripts\\game.lua")
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

-- ---------------------------------------------------------------- waypoints in the world
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
                pcall(function() local v = a:K2_GetActorLocation() e.loc = { X = v.X, Y = v.Y, Z = v.Z } end)
                local okC, c = pcall(function() return a.Character end)
                e.character = okC and valid(c) and pathOf(c) or nil
                local okR, r = pcall(function() return a.bReplicates end)
                if okR then e.replicates = r end
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

-- A screen-space waypoint is painted only while its location is in view (the first probe run: a waypoint behind the
-- camera had no paints). So each waypoint is checked on its own: the camera is turned to it (the local controller's
-- SetControlRotation), then its paints are counted. Logs "PAINT <phase> name=n ..." and stores { name = n }.
-- The aim is re-applied on every tick and what the camera really shows is checked (the camera manager's rotation, the
-- angle to the waypoint): a window counts only if the waypoint stayed in view the whole time. A window where it didn't is
-- retried (AIMTRIES); a waypoint never held in view gets 0 (DRAWN fails, and the AIM lines say why).
local INVIEW_DEG, AIMTRIES = 10, 4
local function aimAt(loc)
    local c = pc()
    local cam = c.PlayerCameraManager:GetCameraLocation()
    local dx, dy, dz = loc.X - cam.X, loc.Y - cam.Y, loc.Z - cam.Z
    local yaw = math.deg(math.atan(dy, dx))
    local pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy)))
    c:SetControlRotation({ Pitch = pitch, Yaw = yaw, Roll = 0 })
end
-- Degrees between the rendered camera's forward and the direction to loc, and the distance in m.
local function offAim(loc)
    local cm = pc().PlayerCameraManager
    local cam, rot = cm:GetCameraLocation(), cm:GetCameraRotation()
    local dx, dy, dz = loc.X - cam.X, loc.Y - cam.Y, loc.Z - cam.Z
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    if len < 1 then return 0, 0 end
    local p, y = math.rad(rot.Pitch), math.rad(rot.Yaw)
    local dot = (math.cos(p) * math.cos(y) * dx + math.cos(p) * math.sin(y) * dy + math.sin(p) * dz) / len
    return math.deg(math.acos(math.max(-1, math.min(1, dot)))), len / 100
end
local function viewInfo()
    local c = pc()
    local okV, v = pcall(function() return classOf(c:GetViewTarget()) end)
    local okR, r = pcall(function() local x = c.PlayerCameraManager:GetCameraRotation() return string.format("%.0f/%.0f", x.Pitch, x.Yaw) end)
    return (okV and v or "?") .. " cam=" .. (okR and r or "?")
end
local function paintEach(phase, store, settle, window)
    settle, window = settle or 0.6, window or 1.2
    return function()
        local names, i, stage, t, res, try, maxOff, dist = {}, 0, "next", 0, {}, 0, 0, 0
        for _, n in ipairs(S.marked) do names[#names + 1] = n end
        local function aim()
            local e = (waypoints())[names[i]]
            if not (e and e.loc) then return false, "no waypoint actor" end
            local ok, err = pcall(aimAt, e.loc)
            if not ok then return false, err end
            local okO, off, d = pcall(offAim, e.loc)
            return true, okO and off or 180, okO and d or 0
        end
        return function()
            if stage == "next" then
                i, try = i + 1, 0
                if i > #names then
                    local o = {}
                    for _, n in ipairs(names) do o[#o + 1] = n .. "=" .. (res[n] or 0) end
                    say("PAINT %s %s", phase, #o > 0 and table.concat(o, " ") or "none")
                    if store then S[store] = res end
                    return true
                end
                stage = "aim"
            end
            if stage == "aim" then
                try = try + 1
                local ok, err = aim()
                if not ok then say("AIM %s '%s' skipped (%s)", phase, names[i], tostring(err)) res[names[i]] = 0 stage = "next" return false end
                stage, t = "settle", os.clock()
            elseif stage == "settle" then
                local ok = aim()
                if not ok then stage = "aim" return false end
                if os.clock() - t >= settle then S.paint, S.painting, stage, t, maxOff = {}, true, "count", os.clock(), 0 end
            elseif stage == "count" then
                local ok, off, d = aim()
                maxOff, dist = math.max(maxOff, ok and off or 180), ok and d or dist
                if os.clock() - t >= window then
                    S.painting = false
                    local n, held = S.paint[names[i]] or 0, maxOff < INVIEW_DEG
                    say("AIM %s '%s' try=%d off<=%.1f deg dist=%.0f m paints=%d view=%s%s", phase, names[i], try, maxOff, dist, n, viewInfo(),
                        held and "" or " (not held in view)")
                    if held or try >= AIMTRIES then
                        res[names[i]] = held and n or 0
                        stage = "next"
                    else
                        stage = "aim"
                    end
                end
            end
            return false
        end, #names * AIMTRIES * (settle + window + 1) + 10, phase .. " paint per waypoint"
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
-- The landing showcase: with the pawn and the HUD already up, the game state's UpdateHeliVis puts the view on the
-- landing helicopter's camera (Helicopter_BP_Showcase_Landing_C) for 9 s, then blends back to the pawn over 3 s
-- (BP_FirstPersonGameState_C decompile, labels 27274 and 10554). Until it ends, the driver's aim (the control rotation)
-- doesn't move what is rendered: VM runs 2026-10-27 measured the first paint check on that camera. So the match is
-- ready once the view has been on the pawn for 3 s after the showcase, or, if no showcase shows up, after SHOWCASE_WAIT.
local SHOWCASE_WAIT = 30
local function viewTarget(c)
    local ok, v = pcall(function() return c:GetViewTarget() end)
    return ok and valid(v) and v or nil
end
local function waitHud(phase, timeout)
    step(phase .. ": hud", function()
        local since, up, other, t0 = nil, nil, nil, os.clock()
        return function()
            local c = pc()
            local h, p = liveHud(), pawnOf(c)
            if not (h and p and classOf(p) == FP) then since = nil return false end
            up = up or os.clock()
            local v = viewTarget(c)
            if v and pathOf(v) == pathOf(p) then
                since = since or os.clock()
            else
                since = nil
                if not other then other = v and classOf(v) or "none" say("VIEW %s the camera is %s's (%.1f s after the HUD)", phase, other, os.clock() - up) end
            end
            if since and os.clock() - since >= 3 and (other or os.clock() - up >= SHOWCASE_WAIT) then
                S.pawnPath = pathOf(p)
                say("HUD %s pawn=%s (the pawn's camera since %.1f s; before it: %s)", phase, S.pawnPath, since - t0, other or "no other camera")
                return true
            end
            return false
        end, timeout, phase .. " live HUD with a first-person pawn whose camera is the view"
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
    waitWorld(phase, MATCH_MAP .. ".", 150) -- the world's full name holds <path>.<name>
    touchdown(phase)
    waitHud(phase, 90)
end

-- Opens the map, clicks n location flags and (unless noSat) the satellite flag through their own handlers, closes it;
-- checks one waypoint actor per clicked waypoint.
local function mark(phase, n, noSat)
    step(phase .. ": open map", function() openMap(phase) return after(2), 5, "map open" end)
    step(phase .. ": click", function()
        local list, sat = flags()
        S.marked = {}
        for i = 1, math.min(n, #list) do
            local f = list[i]
            -- The game's MapUI_C gives each flag its Character; a map opened from Lua leaves it empty (probe run 1).
            pcall(function() f.Character = myPawn() end)
            local ok, err = pcall(function() f[LOC_CLICK](f) end)
            local name = text(f.Name)
            if ok then S.marked[#S.marked + 1] = name end
            say("CLICK %s '%s' ok=%s %s", phase, tostring(name), tostring(ok), ok and "" or tostring(err))
        end
        if sat and not noSat then
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
        local one = #S.marked == n + (noSat and 0 or 1)
        for _, name in ipairs(S.marked) do one = one and wp[name] ~= nil and wp[name].n == 1 end
        check(one and total == #S.marked, "MARKED %s %d waypoints, one waypoint actor each (%s)", phase, #S.marked, table.concat(S.marked, ","))
        paintHook()
    end)
end

local function drawnAll(phase, store)
    step(phase .. ": drawn", function()
        local p = S[store] or {}
        local miss = {}
        for _, name in ipairs(S.marked) do if not ((p[name] or 0) > 0) then miss[#miss + 1] = name end end
        check(#miss == 0, "DRAWN %s every waypoint's waypoint is painted%s", phase, #miss > 0 and (" (not: " .. table.concat(miss, ",") .. ")") or "")
    end)
end

-- After a revive (the pawn changed): wait until every marked waypoint is bound to the new pawn (Waypoints restored it),
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
        end, 20, phase .. " waypoints bound to the new pawn"
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
        check(one, "ONE %s exactly one waypoint actor per waypoint (%d waypoints, %d actors)", phase, #S.marked, total)
        check(bound, "BOUND %s every location waypoint's Character is the new pawn", phase)
        check(rep, "LOCAL %s every waypoint actor has bReplicates=false", phase)
    end)
    step(phase .. ": paint", paintEach(phase, "paintAfter"))
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
    step(phase .. ": paint", paintEach(phase, "paintCleared"))
    step(phase .. ": cleared", function()
        local _, total = waypoints()
        check(total == 0, "NONE %s no waypoint actor left (%d)", phase, total)
        local n = 0 for _, c in pairs(S.paintCleared or {}) do if c > 0 then n = n + 1 end end
        check(n == 0, "NOPAINT %s no waypoint painted", phase)
    end)
    step(phase .. ": open map", function() openMap(phase) return after(2), 5, "map open" end)
    step(phase .. ": flags", function()
        local sel = flagState(phase)
        check(#sel == 0, "FLAGSNONE %s no flag selected (%s)", phase, table.concat(sel, ","))
        closeMap()
    end)
end

local function setOnRevive(value)
    step("set onRevive=" .. value, function()
        local path = modsDir .. "\\" .. WAYPOINTS .. "\\Scripts\\settings.lua"
        local f = io.open(path, "w")
        if not f then check(false, "SETTINGS could not write %s", path) return end
        f:write('-- Rewritten by WaypointsDriver (test only).\nreturn { onRevive = "' .. value .. '", debug = true }\n')
        f:close()
        say("SETTINGS onRevive=%s written to Waypoints' settings.lua", value)
    end)
end

-- ---------------------------------------------------------------- the game's death path, traced
-- V8.1.3+ (decompile of BP_FirstPersonCharacter_C, V8.1.5 and V8.2): damage (the native CallDamageEvent, what every
-- enemy hit, frostbite and fall damage go through) -> HealthDeath -> DeathEvent (HideInventory, HideCrosshair) ->
-- MoreDeathFX (NNDeathFadeLibrary:CanBeginTerminalDeathEffects, DeathHud) -> the FadeOut widget (RegisterDeathFade; slow
-- on purpose) -> its FadeOut delegate -> Spectate -> NotifyDeathFadeBlack -> RemoveAllWidgets unless
-- IsManagedDeathTransition -> SpawnSpecator (native HandleDeathSpawn) -> Spectator_C BeginPlay. The trace logs every
-- one of those calls that UE4SS can hook ("TRACE" lines, never checks), so a run shows which way the game went.
local CH = "/Game/FirstPerson/Blueprints/BP_FirstPersonCharacter.BP_FirstPersonCharacter_C:"
local NN = "/Script/NuclearNightmare."
local TRACE_FNS = {
    CH .. "DeathEvent", CH .. "MoreDeathFX", CH .. "Spectate", CH .. "SpawnSpecator",
    NN .. "NNDeathFadeLibrary:RegisterDeathFade", NN .. "NNDeathFadeLibrary:NotifyDeathFadeBlack",
    NN .. "NNDeathFadeLibrary:IsManagedDeathTransition", "/Script/UMG.WidgetLayoutLibrary:RemoveAllWidgets",
    NN .. "NNDeathFadeComponent:ClientBeginDeath", NN .. "NNDeathFadeComponent:ClientRequestBlack",
    NN .. "NNDeathFadeComponent:ServerAcknowledgeBlack", NN .. "NNDeathFadeComponent:ClientHandoffCompleted",
    NN .. "NNDeathFadeComponent:ClientCancelDeath",
    NN .. "NNPlayableSpawnLibrary:HandleDeathSpawn", NN .. "NNPlayableSpawnLibrary:RegisterDeathReinforcement",
    "/Game/FirstPerson/Blueprints/BP_FirstPersonGameState.BP_FirstPersonGameState_C:UpdateRespawnQue",
    "/Game/FirstPerson/Blueprints/Spectator.Spectator_C:EndGame",
    "/Game/Gameplay/ClassifiedMaterials/BP_Radio.BP_Radio_C:ReinforceSpecficPlayer",
    "/Game/Gameplay/ClassifiedMaterials/BP_Radio.BP_Radio_C:RPCReinforcementMethod2",
    NN .. "NNRadioReinforcementLibrary:AdmitRadioCandidate", NN .. "NNRadioReinforcementLibrary:TryPossessRadioCandidate",
    NN .. "NNRadioReinforcementOwnerComponent:ClientCompleteOwner",
}
local TRACE = { hooked = {}, n = {}, t0 = os.clock(), lastTry = -10 }
local function traceHooks()
    if os.clock() - TRACE.lastTry < 2 then return end -- a miss is a full object scan: not every tick
    TRACE.lastTry = os.clock()
    for _, fn in ipairs(TRACE_FNS) do
        if not TRACE.hooked[fn] and StaticFindObject(fn) then
            local short = fn:match("[^.:]+:[^:]+$") or fn
            local ok = pcall(RegisterHook, fn, function()
                pcall(function()
                    TRACE.n[fn] = (TRACE.n[fn] or 0) + 1
                    if TRACE.n[fn] <= 4 then say("TRACE +%.1f s %s (#%d)", os.clock() - TRACE.t0, short, TRACE.n[fn]) end
                end)
            end)
            TRACE.hooked[fn] = ok
            if not ok then say("TRACE hook failed %s", short) end
        end
    end
end
-- A native library function called as a UFunction on its class default object (never UE4SS's own method of the same
-- name): "true", "false", "?" (not found) or "error".
local function libCall(cls, fn, ...)
    local lib, f = StaticFindObject(NN .. "Default__" .. cls), StaticFindObject(NN .. cls .. ":" .. fn)
    if not (valid(lib) and valid(f)) then return "?" end
    local args = { ... }
    local ok, r = pcall(function() return f(lib, table.unpack(args)) end)
    return ok and tostring(r) or "error"
end
-- The local HUD as Nucleus sees it (InventoryUI_C in the viewport), its visibility, and the pawn. Logged only (HUDSTATE,
-- PAINTLINE): since V8.1.3 the managed death keeps the HUD in the viewport, so it is no death signal.
local function hudState()
    local inVp, vis = false, "-"
    for _, w in ipairs(FindAllOf("InventoryUI_C") or {}) do
        if valid(w) and not pathOf(w):find("Default__", 1, true) then
            local ok, v = pcall(function() return w:IsInViewport() end)
            if ok and v then inVp = true; pcall(function() vis = tostring(w:GetVisibility()) end) end
        end
    end
    local p = myPawn()
    return string.format("hud=%s vis=%s pawn=%s", tostring(inVp), vis, p and classOf(p) or "none"), inVp
end
local function traceState(tag)
    local s = hudState()
    if s ~= TRACE.last then TRACE.last = s say("HUDSTATE %s +%.1f s %s", tag, os.clock() - TRACE.t0, s) end
end

-- ---------------------------------------------------------------- killing a character (V8.1.5+)
-- Since V8.1.5 DeathEvent() does nothing on a pawn that took no real damage: MoreDeathFX starts with the native gate
-- NNDeathFadeLibrary:CanBeginTerminalDeathEffects, false while Health > 0. So the kill is the game's own damage, one
-- CallDamageEvent(1000) (any amount >= Health kills; 1000 survives damage scaling down to 10x), and then the game's whole
-- death, slow on purpose (the FadeOut plays at 0.1x): the controller's pawn becomes Spectator_C about 12 s later (V8.1.5
-- and V8.2 traces). A re-kill 5 s in cut into it on V8.1.5. The death signals, in order:
--   DYING: right away, CanBeginTerminalDeathEffects(body) is true and Health <= 0 (a client sees the replicated Health);
--   LEFT:  ~12 s later, the controller's pawn is no longer the body (Spectator_C; a playable monster if infected or with
--          Playable Enemy on).
-- Not death signals: the HUD (it stays in the viewport) and HasCalledDeathEvent? (nothing sets it).
local KILL_FALLBACK, KILL_TIMEOUT, SPECTATOR = 30, 60, "Spectator_C"
local function hpOf(p) local ok, h = pcall(function() return p.Health end) return ok and tonumber(h) or nil end
local function guardOf(p) return libCall("NNDeathFadeLibrary", "CanBeginTerminalDeathEffects", p) end

-- A poll for the death of the character S.killed under the local controller. Logs DYING once the immediate signal shows
-- (needGuard: CanBeginTerminalDeathEffects must be true too; a client may only see the replicated Health), runs
-- onStuck(t) once if the controller still has the character after KILL_FALLBACK s, and is done when the controller's
-- pawn is something else (S.left = { t, class, path }).
local function deathWatch(phase, needGuard, onStuck)
    local stuck = false
    S.dying, S.left = nil, nil
    return function()
        traceHooks()
        traceState(phase)
        local t = os.clock() - TRACE.t0
        if not S.dying then
            local body = found(S.killed)
            local g, h = body and guardOf(body), body and hpOf(body)
            if h and h <= 0 and (g == "true" or not needGuard) then
                S.dying = t
                say("DYING %s +%.1f s guard=%s hp=%s", phase, t, tostring(g), tostring(h))
            end
        end
        local p = myPawn()
        if p and pathOf(p) == S.killed then
            if not stuck and t > KILL_FALLBACK then stuck = true; if onStuck then onStuck(t) end end
            return false
        end
        if not p then return false end -- between pawns
        S.left = { t = t, class = classOf(p), path = pathOf(p) }
        say("LEFT %s +%.1f s the controller's pawn is %s (%s) managed=%s fallback=%s", phase, t, S.left.class, S.left.path,
            libCall("NNDeathFadeLibrary", "IsManagedDeathTransition", p), tostring(stuck))
        return true
    end
end
-- The checks after a death: the immediate signal, then the spectator.
local function deathChecks(phase)
    step(phase .. ": died", function()
        check(S.dying ~= nil, "DIED %s the character took the game's death: Health <= 0 and the terminal-death gate open%s", phase,
            S.dying and string.format(" (+%.1f s)", S.dying) or "")
        local l = S.left
        check(l ~= nil and l.class == SPECTATOR, "SPECTATOR %s the controller's pawn became %s%s", phase, SPECTATOR,
            l and string.format(" (%s at +%.1f s)", l.class, l.t) or " (it never left the character)")
    end)
end

-- Kills the local player's own character on the host (authority) the way the game does: one CallDamageEvent(1000), then
-- the game's whole death. Only if the character is still possessed after KILL_FALLBACK s does the driver set Health 0
-- and call DeathEvent itself (a FALLBACK line). Step timeout KILL_TIMEOUT s.
local function kill(phase, which)
    step(phase .. ": kill", function()
        local target = which()
        if not target then check(false, "KILL %s target found", phase) return end
        S.killed = pathOf(target)
        TRACE.t0, TRACE.last = os.clock(), nil
        traceHooks()
        say("KILL %s before guard=%s hp=%s", phase, guardOf(target), tostring(hpOf(target)))
        local ok, err = pcall(function() target:CallDamageEvent(1000) end)
        say("KILL %s %s CallDamageEvent(1000) ok=%s %s", phase, S.killed, tostring(ok), ok and "" or tostring(err))
        local watch = deathWatch(phase, true, function(t)
            local body = found(S.killed)
            if not body then return end
            local okH = pcall(function() body.Health = 0 end)
            local okD, eD = pcall(function() body:DeathEvent() end)
            say("KILL %s FALLBACK still possessed after %.0f s: Health 0 (ok=%s) + DeathEvent ok=%s %s", phase, t, tostring(okH), tostring(okD), okD and "" or tostring(eD))
        end)
        if watch() then return end
        return watch, KILL_TIMEOUT, phase .. " death (the controller leaves the character)"
    end)
    deathChecks(phase)
end

-- While dead (spectating): are the waypoints still painted? Not a check (Waypoints doesn't depend on it): an ANSWER line.
-- Each waypoint aimed at as before (the spectator's controller), then 4 s of any paint without aiming.
local function paintWhileDead(phase)
    step(phase .. ": paint aimed", paintEach(phase, "paintDead"))
    step(phase .. ": paint any", paintWindow(phase .. "-any", 4, "paintDeadAny"))
    step(phase .. ": paint answer", function()
        local n, any = 0, 0
        for _, c in pairs(S.paintDead or {}) do if c > 0 then n = n + 1 end end
        for _, c in pairs(S.paintDeadAny or {}) do any = any + c end
        say("ANSWER painted-while-dead=%s (%d of %d waypoints painted when aimed at; %d paints unaimed) %s", (n > 0 or any > 0) and "yes" or "no",
            n, #S.marked, any, hudState())
    end)
end

-- The game state's EOGLock, the game's own end-of-game latch. Solo, the last death would end the match (Spectator_C:
-- everyone dead -> EndGame -> EndGameCam) before anyone could call reinforcements; holding the latch stands in for a
-- teammate still alive. Released after the revive, or the match could never end.
local function holdMatch(phase, on)
    step(phase .. (on and ": hold the match" or ": release the match"), function()
        local okG, gs = pcall(function() return GS():GetGameState(pc()) end)
        local ok = okG and valid(gs) and pcall(function() gs.EOGLock = on end)
        say("SOLO %s EOGLock=%s ok=%s", phase, tostring(on), tostring(ok))
    end)
end

-- A revive the way the game does it (V8.1.5+), solo host. The radio no longer revives a living character (V8.1.3's
-- native NNRadioReinforcementLibrary:AdmitRadioCandidate checks the queued body), so the player really dies first (kill:
-- the game's own death and respawn-queue entry), then the radio's ReinforceSpecficPlayer(dead body) runs: what the
-- computer's per-player reinforcement button calls (a server RPC, run on the host).
local function realRevive(phase)
    holdMatch(phase, true)
    kill(phase, myPawn)
    paintWhileDead(phase .. "-dead")
    step(phase .. ": reinforce", function()
        S.journalBefore = S.journalPath
        local body = found(S.killed)
        local radio = FindFirstOf("BP_Radio_C")
        if not (body and valid(radio)) then check(false, "REINFORCE %s dead body and radio found", phase) return end
        TRACE.t0 = os.clock()
        local okR, eR = pcall(function() radio:ReinforceSpecficPlayer(body) end)
        say("REINFORCE %s ReinforceSpecficPlayer(dead body %s) ok=%s %s", phase, S.killed:match("[^.]+$"), tostring(okR), okR and "" or tostring(eR))
        -- Does the reinforcement still stop the old waypoints painting (the bug Waypoints fixes)? Until Waypoints replaces
        -- the first location's actor, aim at it every tick and log its paints per tick (PAINTLINE; not a check).
        local name
        for _, n in ipairs(S.marked) do if n ~= "Satellite" then name = n break end end
        local e = name and (waypoints())[name]
        if not (e and e.loc) then return end
        local oldPath, t0, last = e.path, os.clock(), nil
        S.paint, S.painting = {}, true
        return function()
            local now = (waypoints())[name]
            local replaced = not now or now.path ~= oldPath
            local n = S.paint[name] or 0
            S.paint = {}
            local okA = pcall(aimAt, e.loc)
            local okO, off = pcall(offAim, e.loc)
            local line = string.format("%s paints=%d off=%s %s", name, n, okO and string.format("%.0f", off) or "?", hudState())
            if line ~= last or n > 0 then say("PAINTLINE %s +%.2f s %s%s", phase, os.clock() - t0, line, okA and "" or " (aim failed)") last = line end
            if replaced or os.clock() - t0 > 8 then
                S.painting = false
                say("PAINTLINE %s end +%.2f s (%s)", phase, os.clock() - t0, replaced and "Waypoints replaced the old actor" or "8 s")
                return true
            end
            return false
        end, 15, phase .. " paint timeline"
    end)
    waitPawnChange(phase, 60)
    holdMatch(phase, false)
end

-- ---------------------------------------------------------------- buttons (story 3): Mark all / Clear all by real clicks
-- The map opened and closed by the real key IA_Map is bound to (posted to the game window by run.ps1, like Enter), and
-- Waypoints' buttons clicked with the real mouse (run.ps1 "click x y" at the button's centre). The buttons are found as
-- core draws them: on the map page's root canvas (Journal_C.MapWidget's RootWidget) a WBP_<Core>Panel tagged
-- <core>:Waypoints:waypoints, its HBox holding WBP_<Core>Button widgets tagged <core>:Waypoints:markAll / clearAll
-- (CoreTag; core's text.lua tagOf). Screen rectangles from core's <Core>_AbsTopLeft / _AbsBottomRight on its ModActor's
-- class default object, as core's own button tests do (SkelTest clickOn).
local ACTOR_CDO = "/Game/Mods/" .. CORE .. "/ModActor.Default__ModActor_C"
local function tagFor(id) return CORE:lower() .. ":" .. WAYPOINTS .. ":" .. id end
local function coreTag(w) local ok, t = pcall(function() return w.CoreTag:ToString() end) return ok and t or nil end
local function childTagged(container, tag)
    local hit, n = nil, 0
    pcall(function()
        for i = 0, container:GetChildrenCount() - 1 do
            local c = container:GetChildAt(i)
            if valid(c) and coreTag(c) == tag then n = n + 1; hit = hit or c end
        end
    end)
    return hit, n
end
-- The local player's Journal in the viewport (a new Journal_C on every open); nil when the map is closed.
local function openJournal()
    for _, j in ipairs(FindAllOf("Journal_C") or {}) do
        if valid(j) and not pathOf(j):find("Default__", 1, true) then
            local ok, v = pcall(function() return j:IsInViewport() end)
            if ok and v then return j end
        end
    end
    return nil
end
local function buttonWidget(id)
    local j = openJournal()
    local okC, canvas = pcall(function() return j.MapWidget.WidgetTree.RootWidget end)
    if not (j and okC and valid(canvas)) then return nil, "no map canvas" end
    local panel, np = childTagged(canvas, tagFor("waypoints"))
    if not panel then return nil, "no Waypoints panel on the map page" end
    local okB, box = pcall(function() return panel.HBox end)
    if not (okB and valid(box)) then return nil, "the panel has no HBox" end
    local b, nb = childTagged(box, tagFor(id))
    if not b then return nil, "no '" .. id .. "' button in the panel's HBox" end
    return b, nil, np, nb
end
local function screenRect(w)
    local cdo = found(ACTOR_CDO)
    if not (cdo and valid(w)) then return nil end
    local ok, r = pcall(function()
        local a, b = cdo[CORE .. "_AbsTopLeft"](cdo, w), cdo[CORE .. "_AbsBottomRight"](cdo, w)
        return { l = a.X, t = a.Y, r = b.X, b = b.Y }
    end)
    return ok and r or nil
end

-- Story 5: where Waypoints' panel sits, in the map page canvas's units (resolution-independent) through core's
-- <Core>_RectIn, as core's SkelTest measures the Journal regions: canvas = MapWidget.WidgetTree.RootWidget, the `map`
-- region = MapWidget.MapUI, `page-left` = MapWidget.NN_LeftFieldPaper. PANEL_FIT names the placement Waypoints'
-- main.lua uses (PANEL_PLACE): "below-map" = { near = "map", side = "below", align = "center", gap = "tight" }, or the
-- fallback "page-left-corner" = { corner = "bottom-left", region = "page-left", inset = "tight" }. Change both together.
local PANEL_FIT = "below-map"
local TIGHT, FIT_TOL, PANEL_WAIT = 8, 1, 8 -- canvas units; units of slack; seconds to wait for the placed panel
local function rectIn(canvas, w)
    local cdo = found(ACTOR_CDO)
    if not (cdo and valid(canvas) and valid(w)) then return nil end
    local ok, r = pcall(function()
        local fn = cdo[CORE .. "_RectIn"]
        local a, b = fn(cdo, canvas, w, { X = 0, Y = 0 }), fn(cdo, canvas, w, { X = 1, Y = 1 })
        return { l = a.X, t = a.Y, r = b.X, b = b.Y }
    end)
    return ok and r or nil
end
local function rtext(r) return r and string.format("(%.0f,%.0f)-(%.0f,%.0f)", r.l, r.t, r.r, r.b) or "?" end
local function hasArea(r) return r ~= nil and r.r - r.l > 1 and r.b - r.t > 1 end
-- { panel, map, page } in canvas units for the open map (any of them nil when not found), or nil and why.
local function panelRects()
    local j = openJournal()
    if not j then return nil, "the map is not open" end
    local okM, mw = pcall(function() return j.MapWidget end)
    if not (okM and valid(mw)) then return nil, "no MapWidget" end
    local okC, canvas = pcall(function() return mw.WidgetTree.RootWidget end)
    if not (okC and valid(canvas)) then return nil, "no map canvas" end
    local panel = childTagged(canvas, tagFor("waypoints"))
    if not panel then return nil, "no Waypoints panel on the map page" end
    local okU, mapW = pcall(function() return mw.MapUI end)
    local okP, pageW = pcall(function() return mw.NN_LeftFieldPaper end)
    return { panel = rectIn(canvas, panel), map = okU and rectIn(canvas, mapW) or nil, page = okP and rectIn(canvas, pageW) or nil }
end
-- (a) of story 5's fit rule: true when the panel is where PANEL_FIT says, plus a description either way.
local function panelPlacedAt(R)
    if not R then return false, "no rectangles" end
    local p, m, pg = R.panel, R.map, R.page
    local desc = string.format("the panel %s, the map %s, page-left %s", rtext(p), rtext(m), rtext(pg))
    if not (hasArea(p) and hasArea(pg)) then return false, desc .. " (panel not drawn yet)" end
    local inside = p.l >= pg.l - FIT_TOL and p.t >= pg.t - FIT_TOL and p.r <= pg.r + FIT_TOL and p.b <= pg.b + FIT_TOL
    if PANEL_FIT == "page-left-corner" then
        local dl, db = p.l - (pg.l + TIGHT), p.b - (pg.b - TIGHT)
        local good = math.abs(dl) <= FIT_TOL and math.abs(db) <= FIT_TOL and inside
        return good, string.format("%s: left - (page left + %d) = %.1f, bottom - (page bottom - %d) = %.1f, inside page-left=%s",
            desc, TIGHT, dl, TIGHT, db, tostring(inside))
    end
    if not hasArea(m) then return false, desc .. " (map region not drawn yet)" end
    local dy = p.t - (m.b + TIGHT)
    local dx = (p.l + p.r) / 2 - (m.l + m.r) / 2
    local good = math.abs(dy) <= FIT_TOL and math.abs(dx) <= FIT_TOL and inside
    return good, string.format("%s: top - (map bottom + %d) = %.1f, centre dx = %.1f, inside page-left=%s", desc, TIGHT, dy, dx, tostring(inside))
end
-- Waits (polling every runner tick) until the panel is placed per PANEL_FIT, at most PANEL_WAIT s: core keeps a panel
-- near the measured `map` region collapsed until the new Journal's first paint (about 1.1-1.5 s after the open).
-- Logs OK PANELPLACE <phase> ... after <s> s, or FAIL PANELPLACE with the last rectangles.
local function panelPlaced(phase)
    step(phase .. ": panel placed", function()
        local t0, last = os.clock(), "not measured"
        return function()
            local R, why = panelRects()
            local good, desc = panelPlacedAt(R)
            last = R and desc or why
            local t = os.clock() - t0
            if good then
                check(true, "PANELPLACE %s %s after %.1f s (%s)", phase, desc, t, PANEL_FIT)
                return true
            end
            if t >= PANEL_WAIT then
                check(false, "PANELPLACE %s the panel was not placed (%s) within %d s: %s", phase, PANEL_FIT, PANEL_WAIT, last)
                return true
            end
            return false
        end, PANEL_WAIT + 4, phase .. " panel placed"
    end)
end

-- The game state's lobby countdown, cut to 2 s on this (listen server) host: the character opens the map only when
-- LobbyMinutes and LobbySeconds are both 0 (core's SkelTest lobbyOver).
local function lobbyOver(phase)
    step(phase .. ": end the lobby", function()
        local gs = GS():GetGameState(pc())
        if not valid(gs) then check(false, "LOBBY %s game state found", phase) return end
        local m, s = gs.LobbyMinutes, gs.LobbySeconds
        say("LOBBY %s countdown %s:%s; set to 0:02", phase, tostring(m), tostring(s))
        if (tonumber(m) or 0) > 0 or (tonumber(s) or 0) > 2 then pcall(function() gs.LobbyMinutes = 0; gs.LobbySeconds = 2 end) end
        return function()
            local g = GS():GetGameState(pc())
            return valid(g) and (tonumber(g.LobbyMinutes) or 1) <= 0 and (tonumber(g.LobbySeconds) or 1) <= 0
        end, 20, phase .. " lobby countdown over"
    end)
    step(phase .. ": lobby settle", function() return after(3), 5, "settle" end)
end
-- The key IA_Map is bound to, from IMC_Default (a capital letter), else M (core's SkelTest readMapKey).
local function readMapKey()
    step("map key", function()
        local key, all = nil, {}
        local ok, err = pcall(function()
            local imc = StaticFindObject("/Game/FirstPerson/Input/IMC_Default.IMC_Default")
            if not valid(imc) then error("IMC_Default not loaded") end
            imc.Mappings:ForEach(function(_, e)
                local m = e:get()
                local a = m.Action
                if valid(a) and pathOf(a):find("IA_Map.IA_Map", 1, true) then
                    local k = m.Key.KeyName:ToString()
                    all[#all + 1] = k
                    if not key and k:match("^[A-Z]$") then key = k end
                end
            end)
        end)
        S.mapKey = key or "M"
        say("MAPKEY %s (IA_Map keys in IMC_Default: %s%s)", S.mapKey, table.concat(all, ", "), ok and "" or ("; read failed: " .. tostring(err)))
        check(key ~= nil, "MAPKEY IA_Map is bound to the letter %s in IMC_Default", S.mapKey)
    end)
end
-- The map opened (or closed) by the real key; S.journalPath is the open Journal's path (for flags()). With `panel`
-- (an open), waits for Waypoints' panel to be placed under the map (PANELPLACE) instead of the fixed settle.
local function keyMap(phase, open, panel)
    step(phase .. (open and ": open by key" or ": close by key"), function()
        say("MAPKEY %s pressing %s to %s the map", phase, S.mapKey, open and "open" or "close")
        return request("key " .. S.mapKey), 30, phase .. " map key served"
    end)
    step(phase .. (open and ": opened" or ": closed"), function()
        return function()
            local j = openJournal()
            if open and j then S.journalPath = pathOf(j) return true end
            return not open and j == nil
        end, 10, phase .. (open and " the Journal in the viewport" or " the Journal out of the viewport")
    end)
    -- Core's poller sees the open within 500 ms and attaches the buttons; Waypoints' MAPSYNC runs right after. The
    -- panel itself shows only after the Journal's first paint (story 5): wait for it to be placed.
    if open and panel then panelPlaced(phase)
    else step(phase .. ": settle", function() return after(1.5), 4, "map settle" end) end
end
-- A real mouse click on Waypoints' button `id`, then a pause for the hook and the action.
local function clickButton(phase, id)
    step(phase .. ": click " .. id, function()
        local w, why, np, nb = buttonWidget(id)
        local r = w and screenRect(w)
        if not check(r ~= nil and r.r > r.l and r.b > r.t, "BPOINT %s '%s' is on the map page with a screen rectangle %s%s", phase, id,
            r and string.format("(%.0f,%.0f)-(%.0f,%.0f)", r.l, r.t, r.r, r.b) or "?", why and (" (" .. why .. ")") or "") then return end
        check(np == 1 and nb == 1, "BONE %s one Waypoints panel and one '%s' button on the map page (%d, %d)", phase, id, np or 0, nb or 0)
        local x, y = math.floor((r.l + r.r) / 2 + 0.5), math.floor((r.t + r.b) / 2 + 0.5)
        say("BCLICKREQ %s clicking '%s' at (%d,%d)", phase, id, x, y)
        return request(string.format("click %d %d", x, y)), 40, phase .. " click served"
    end)
    step(phase .. ": settle " .. id, function() return after(1.5), 4, "click settle" end)
end
-- Every flag widget of the open map (not only the first of each name) and its Selected.
local function allFlagStates()
    local m = mapUI()
    local out = {}
    if m then
        for _, f in ipairs(items(m.Levels)) do out[#out + 1] = { name = text(f.Name) or "?", selected = f.Selected == true } end
        local ok, s = pcall(function() return m.Satelite end)
        if ok and valid(s) then out[#out + 1] = { name = "Satellite", selected = s.Selected == true } end
    end
    return out
end
local function distinctNames()
    local list, sat = flags()
    local names = {}
    for _, f in ipairs(list) do names[#names + 1] = text(f.Name) end
    return names, sat ~= nil
end
-- The pair client's press: no OS click can be served in a pair run (nothing posts input to the VM's game from the
-- driver), so the driver calls the button widget's <Core>_OnClicked(), the Blueprint function the button's OnClicked
-- calls; core's dispatch hook runs on it as on a real click (core's SkelTest BDOUBLE does the same). Not an OS click.
local function pressButton(phase, id)
    -- The panel near the measured map region shows only after the Journal's first paint (story 5): wait until the
    -- button has a screen rectangle (at most PANEL_WAIT s) before pressing.
    step(phase .. ": shown " .. id, function()
        return function()
            local w = buttonWidget(id)
            local r = w and screenRect(w)
            return r ~= nil and r.r - r.l > 1 and r.b - r.t > 1
        end, PANEL_WAIT, phase .. " '" .. id .. "' shown"
    end)
    step(phase .. ": press " .. id, function()
        local w, why, np, nb = buttonWidget(id)
        if not check(w ~= nil, "BPOINT %s '%s' is on the map page%s", phase, id, why and (" (" .. why .. ")") or "") then return end
        check(np == 1 and nb == 1, "BONE %s one Waypoints panel and one '%s' button on the map page (%d, %d)", phase, id, np or 0, nb or 0)
        local fn = CORE .. "_OnClicked"
        local ok, err = pcall(function() w[fn](w) end)
        say("BPRESS %s via %s ok=%s%s", id, fn, tostring(ok), ok and "" or (" " .. tostring(err)))
        if not ok then check(false, "BPRESS %s '%s' %s() threw", phase, id, fn) end
    end)
    step(phase .. ": settle " .. id, function() return after(1.5), 4, "press settle" end)
end
-- After Mark all: one live waypoint actor per distinct flag name (and the satellite), every flag widget Selected, all
-- unreplicated. S.flagNames / S.hasSat from the open map.
local function markedCheck(phase)
    step(phase .. ": check", function()
        local wp, total = waypoints()
        say("WAYPOINTS %s total=%d %s", phase, total, describe(wp))
        local one, miss = true, {}
        for _, n in ipairs(S.flagNames) do if not (wp[n] and wp[n].n == 1) then one = false; miss[#miss + 1] = n end end
        if S.hasSat and not (wp.Satellite and wp.Satellite.n == 1) then one = false; miss[#miss + 1] = "Satellite" end
        local want = #S.flagNames + (S.hasSat and 1 or 0)
        check(one and total == want, "ALLMARKED %s one live waypoint actor per flag%s (%d actors, want %d)%s", phase, S.hasSat and " and the satellite" or "",
            total, want, #miss > 0 and (" not: " .. table.concat(miss, ",")) or "")
        local states, off = allFlagStates(), {}
        for _, f in ipairs(states) do if not f.selected then off[#off + 1] = f.name end end
        check(#states > 0 and #off == 0, "ALLSELECTED %s every flag Selected (%d widgets)%s", phase, #states, #off > 0 and (" not: " .. table.concat(off, ",")) or "")
        local rep = true
        for _, e in pairs(wp) do rep = rep and e.replicates == false end
        check(rep, "LOCAL %s every waypoint actor has bReplicates=false", phase)
    end)
end
-- After Clear all: no live waypoint actor, no flag widget Selected.
local function clearedCheck(phase)
    step(phase .. ": check", function()
        local wp, total = waypoints()
        check(total == 0, "ALLCLEARED %s no live waypoint actor left (%d: %s)", phase, total, describe(wp))
        local states, on = allFlagStates(), {}
        for _, f in ipairs(states) do if f.selected then on[#on + 1] = f.name end end
        check(#states > 0 and #on == 0, "NONESELECTED %s no flag Selected (%d widgets)%s", phase, #states, #on > 0 and (" still: " .. table.concat(on, ",")) or "")
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
    step("paint before", paintEach("before", "paintBefore"))
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
    step("paint removed", paintEach("removed", "paintRemoved"))
    step("repro", function()
        local n = 0 for _, c in pairs(S.paintRemoved or {}) do if c > 0 then n = n + 1 end end
        check(n == 0, "REPRO after RemoveAllWidgets no waypoint is painted (%d painted): the bug, and the paint hook sees it", n)
    end)
    -- (3) repairs, one per waypoint
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
            if not G then error("Waypoints' game.lua not loaded") end
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
    step("paint repaired", paintEach("repaired", "paintRepaired"))
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
        check(okResp, "RESPAWN-DRAWN a respawned waypoint is painted again (Waypoints' way)")
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
        local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        local kIsValid = StaticFindObject("/Script/Engine.KismetSystemLibrary:IsValid")
        for _, a in ipairs(FindAllOf("LevelWaypointActor_C") or {}) do
            if valid(a) and text(a.Name) == name then
                seen = seen + 1
                if alive(a) then live = live + 1 end
                -- Diagnostics (probe run 1 found the destroyed actor counted alive): every candidate signal.
                local okD, dying = pcall(function() return a:IsActorBeingDestroyed() end)
                local okK, kv = pcall(function() return kIsValid(ksl, a) end)
                local okW, w = pcall(function() return a:GetWorld():GetFullName() end)
                local okR, root = pcall(function() return valid(a.RootComponent) end)
                local okG, garbage = pcall(function() return a:HasAnyInternalFlags(EInternalObjectFlags.Garbage or EInternalObjectFlags.PendingKill) end)
                say("LIVENESS candidate %s IsActorBeingDestroyed=%s/%s KSL.IsValid=%s/%s world=%s root=%s/%s garbageFlag=%s/%s", pathOf(a):match("[^.]+$"),
                    tostring(okD), tostring(dying), tostring(okK), tostring(kv), okW and "yes" or tostring(w), tostring(okR), tostring(root), tostring(okG), tostring(garbage))
            end
        end
        local out = {}
        local okA, errA = pcall(function() GS():GetAllActorsOfClass(pc(), (FindAllOf("LevelWaypointActor_C") or {})[1]:GetClass(), out) end)
        local n = 0 for _ in pairs(out) do n = n + 1 end
        say("LIVENESS flag Selected=%s after on+off; GetAllActorsOfClass ok=%s %s entries=%d", tostring(f.Selected), tostring(okA), okA and "" or tostring(errA), n)
        closeMap()
        say("LIVENESS '%s' FindAllOf=%d alive=%d", tostring(name), seen, live)
        check(live == 0, "LIVENESS a waypoint destroyed by its flag is not counted alive (FindAllOf=%d, alive=%d)", seen, live)
        local _, total = waypoints()
        check(total == #S.marked, "LIVEOK the %d live waypoints are all still counted alive (%d)", #S.marked, total)
    end)
end

local function buildRevive()
    enterMatch("match1")
    mark("mark", 2)
    step("paint before", paintEach("before", "paintBefore"))
    drawnAll("before", "paintBefore")
    step("journal before", function() openMap("before") return after(1), 5, "open" end)
    step("journal before 2", function() flagState("before") closeMap() end)
    realRevive("revive1")
    restoredChecks("revive1")
    setOnRevive("clear")
    realRevive("revive2")
    clearedChecks("revive2")
end

local function buildDeath()
    enterMatch("match1")
    mark("mark", 2)
    step("paint before", paintEach("before", "paintBefore"))
    kill("death", myPawn)
    wait("after death", 3)
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
    paintWhileDead("dead")
end

-- Story 3: 2 flags marked by their own click, then the map opened by the real key, Mark all and Clear all clicked with
-- the real mouse, each checked against the world; then the map closed and reopened by the key and checked again.
local function buildButtons()
    enterMatch("match1")
    lobbyOver("match1")
    mark("mark", 2, true)
    readMapKey()
    keyMap("buttons", true, true)
    step("buttons: expect", function()
        local names, sat = distinctNames()
        S.flagNames, S.hasSat = names, sat
        S.expectMarked = #names - 2 + (sat and 1 or 0)
        say("EXPECT buttons marked=%d flags=%d satellite=%s (%s)", S.expectMarked, #names, sat and "yes" or "no", table.concat(names, ","))
        check(#names > 2, "FLAGS buttons the map has %d location flags", #names)
        check(#names == MAP.flags, "FLAGCOUNT buttons %d distinct location flags on %s (the table says %d)", #names, MAP_KEY, MAP.flags)
    end)
    clickButton("markall", "markAll")
    markedCheck("markall")
    clickButton("clearall", "clearAll")
    clearedCheck("clearall")
    keyMap("close", false)
    keyMap("reopen", true, true)
    step("reopen: flags", function()
        local wp = waypoints()
        local up = {}
        for name in pairs(wp) do up[#up + 1] = name end
        table.sort(up)
        local states, sel, mism = allFlagStates(), {}, {}
        for _, f in ipairs(states) do
            if f.selected then sel[#sel + 1] = f.name end
            if f.selected ~= (wp[f.name] ~= nil) then mism[#mism + 1] = f.name end
        end
        table.sort(sel)
        say("FLAGS reopen n=%d selected=%s actors=%s", #states, table.concat(sel, ","), table.concat(up, ","))
        check(#states > 0 and #mism == 0, "FLAGSMATCH reopen every flag's Selected matches its waypoint actor (selected: %s; actors: %s)%s",
            table.concat(sel, ","), table.concat(up, ","), #mism > 0 and (" differ: " .. table.concat(mism, ",")) or "")
    end)
    -- Keep the reopened map up until Waypoints' debug fit check (2.5 s after core sees the open) has run for it too.
    wait("reopen: fit check", 2.5)
    keyMap("end", false)
end

local function buildNoWaypoints()
    enterMatch("match1")
    wait("watch", 10)
    step("no waypoints activity", function()
        check(true, "NOWAYPOINTS match1 reached the match; Waypoints' one line is judged by check.ps1")
    end)
end

-- Pair roles (tools/vm/pair.ps1 scenarios in test/pair/waypoints-scenarios.ps1). The lobby and the match come from
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
    step("paint before", paintEach("before", "paintBefore"))
    drawnAll("before", "paintBefore")
    step("victim ready", function() say("VICTIM ready marked=%s", table.concat(S.marked, ",")) end)
    -- The kill (V8.1.5+): the host logs "KILL victim", pair.ps1 writes kill.txt next to this file, and this machine
    -- calls CallDamageEvent(1000) on its own pawn (the character's server RPC: the host runs the damage, then the game's
    -- managed death). If this pawn is still alive 30 s after its signal, the host calls CallDamageEvent(1000) on it
    -- itself (pair-host's FALLBACK). Here the DYING signal is the replicated Health alone (the death gate is the
    -- host's); the death ends when this controller's pawn is a Spectator_C.
    step("signal", function()
        return function()
            local f = io.open(KILL_SIGNAL, "r")
            if not f then return false end
            f:close()
            return true
        end, 600, "the host's kill signal (kill.txt)"
    end)
    step("victim: kill", function()
        local p = myPawn()
        if not (p and classOf(p) == FP) then check(false, "KILL victim my first-person pawn found") return end
        S.killed = pathOf(p)
        TRACE.t0, TRACE.last = os.clock(), nil
        traceHooks()
        say("SELFKILL before guard=%s hp=%s", guardOf(p), tostring(hpOf(p)))
        local ok, err = pcall(function() p:CallDamageEvent(1000) end)
        say("SELFKILL the host's signal: CallDamageEvent(1000) on my pawn %s ok=%s %s", S.killed, tostring(ok), ok and "" or tostring(err))
        local watch = deathWatch("victim", false, nil)
        -- The host's fallback comes KILL_FALLBACK s after its own signal line; its death then takes ~12 s more.
        return watch, KILL_FALLBACK + KILL_TIMEOUT, "victim death (this controller leaves the character)"
    end)
    deathChecks("victim")
    step("dead", function() local p = myPawn() say("DEAD pawn=%s class=%s", p and pathOf(p) or "none", p and classOf(p) or "none") end)
    waitPawnChange("revive", 600)
    restoredChecks("revive")
    -- Mark all / Clear all on the client after the revive: the map opened from Lua (core's Journal poller sees it and
    -- attaches the buttons), each button pressed through core's own click function (pressButton), the same world checks
    -- as solo.
    wait("pair: map closed a while", 2) -- core's 500 ms Journal poll sees the close before the next open
    step("pair: open map", function() openMap("pair") return after(2), 5, "map open" end)
    step("pair: expect", function()
        local names, sat = distinctNames()
        S.flagNames, S.hasSat = names, sat
        say("EXPECT pair flags=%d satellite=%s already=%d (%s)", #names, sat and "yes" or "no", #S.marked, table.concat(names, ","))
        check(#names > 2, "FLAGS pair the map has %d location flags", #names)
    end)
    pressButton("pair", "markAll")
    markedCheck("pair")
    pressButton("pair", "clearAll")
    clearedCheck("pair")
    step("pair: close map", function() closeMap() say("VICTIM buttons done") return after(1), 5, "map closed" end)
end
local function buildPairHost()
    waitMatch("match", 900)
    step("victim present", function()
        return function() return #remotePCs() > 0 and pawnOf(remotePCs()[1]) ~= nil and classOf(pawnOf(remotePCs()[1])) == FP end, 600, "the other player's character"
    end)
    -- CAP-3: the unmodded host's own waypoint, checked again after the victim's revive and buttons (UNAFFECTED).
    mark("host", 1, true)
    step("host: own waypoint", function() S.hostMark = S.marked[1] say("HOSTMARK '%s'", tostring(S.hostMark)) end)
    wait("victim marks", 90) -- the victim opens its map and marks (it logs VICTIM ready on its own machine)
    -- The line is the signal: pair.ps1 waits for it and writes the victim's kill.txt; the victim calls
    -- CallDamageEvent(1000) on its own pawn (a server RPC: the damage runs here). If the victim's character is still
    -- alive (Health > 0) and possessed KILL_FALLBACK s later, this host calls CallDamageEvent(1000) on it itself (the
    -- proven V8.2 path; FALLBACK line). The host is the authority, so its DYING line has the death gate too.
    step("victim: kill", function()
        local target = pawnOf(remotePCs()[1])
        if not target then check(false, "KILL victim target found") return end
        S.killed = pathOf(target)
        TRACE.t0 = os.clock()
        traceHooks()
        say("KILL victim %s signal (the victim calls CallDamageEvent(1000) on its own pawn) guard=%s hp=%s", S.killed, guardOf(target), tostring(hpOf(target)))
    end)
    step("victim dead", function()
        local fell
        S.dying = nil
        return function()
            local t = os.clock() - TRACE.t0
            traceHooks()
            local body = found(S.killed)
            local hp = body and hpOf(body)
            if not S.dying and body and hp and hp <= 0 and guardOf(body) == "true" then
                S.dying = t
                say("DYING victim +%.1f s guard=true hp=%s", t, tostring(hp))
            end
            local p = pawnOf(remotePCs()[1])
            local possessed = p ~= nil and pathOf(p) == S.killed
            if possessed and not fell and t > KILL_FALLBACK and hp and hp > 0 then
                fell = true
                local ok, err = pcall(function() body:CallDamageEvent(1000) end)
                say("KILL victim FALLBACK still alive %.0f s after the signal (hp=%s): the host's CallDamageEvent(1000) ok=%s %s", t, tostring(hp), tostring(ok), ok and "" or tostring(err))
            end
            return not possessed
        end, KILL_FALLBACK + KILL_TIMEOUT, "the victim's death"
    end)
    step("victim state", function()
        local p = pawnOf(remotePCs()[1])
        S.victimAfterDeath = p and classOf(p) or "none"
        say("VICTIM after death pawn class=%s%s", S.victimAfterDeath, S.victimAfterDeath == "BP_ThirdPersonCharacter_C" and " (became a monster: the revive can't run; INCONCLUSIVE)" or "")
        check(S.victimAfterDeath == SPECTATOR, "SPECTATOR victim the victim's pawn became %s (%s)", SPECTATOR, S.victimAfterDeath)
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
        local p = pawnOf(remotePCs()[1])
        check(p ~= nil and classOf(p) == FP and pathOf(p) ~= S.killed, "REVIVED the victim has a new first-person character %s", p and pathOf(p) or "none")
        -- The victim's restore checks (up to ~20 s restore wait, a paint check per waypoint) and its Mark all / Clear all.
        return after(90), 95, "let the victim check and press its buttons"
    end)
    -- The host's own state after the victim's revive, Mark all and Clear all: exactly its one waypoint actor, same name,
    -- its flag Selected, no other waypoint actor.
    step("host: open map", function() openMap("host-after") return after(2), 5, "map open" end)
    step("host: unaffected", function()
        local wp, total = waypoints()
        say("WAYPOINTS host-after total=%d %s", total, describe(wp))
        local list, sat = flags()
        local flagSel, others = nil, {}
        for _, f in ipairs(list) do
            local n = text(f.Name)
            if n == S.hostMark then flagSel = f.Selected == true elseif f.Selected then others[#others + 1] = n end
        end
        if sat and sat.Selected then others[#others + 1] = "Satellite" end
        local mine = S.hostMark and wp[S.hostMark]
        check(S.hostMark ~= nil and total == 1 and mine ~= nil and mine.n == 1 and flagSel == true and #others == 0,
            "UNAFFECTED host its own waypoint '%s' untouched: %d waypoint actor(s) (want 1, its own), its flag Selected=%s, other flags selected: %s",
            tostring(S.hostMark), total, tostring(flagSel), #others > 0 and table.concat(others, ",") or "none")
        closeMap()
    end)
end
local function buildPairHostVictim()
    waitMatch("match", 900)
    step("other present", function() return function() return #remotePCs() > 0 end, 600, "the other player" end)
    mark("mark", 2)
    step("paint before", paintEach("before", "paintBefore"))
    drawnAll("before", "paintBefore")
    kill("death", myPawn) -- the teammate B is alive: no EOGLock needed
    wait("after death", 5)
    step("reinforce", function()
        local radio = FindFirstOf("BP_Radio_C")
        TRACE.t0 = os.clock()
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

local build = ({ probe = buildProbe, revive = buildRevive, death = buildDeath, buttons = buildButtons, ["no-core"] = buildNoWaypoints, ["old-core"] = buildNoWaypoints,
                 ["pair-victim"] = buildPairVictim, ["pair-host"] = buildPairHost, ["pair-hostvictim"] = buildPairHostVictim })[SCENARIO]
if not build then
    say("END result=FAIL checks=0 failures=1 reason=unknown-scenario %s", SCENARIO)
    return
end
if MAP_BAD then
    say("FAIL MAP unknown map key '%s' in map.txt (known: Crevasse, Forest, LowIsland, TowerIsland); not travelling", MAP_BAD)
    say("END result=FAIL checks=0 failures=1 reason=unknown-map")
    return
end
-- The solo scenarios travel to MAP; a pair's map is PairDriver's.
if not SCENARIO:find("^pair%-") then say("MAP %s %s flags=%d", MAP_KEY, MAP.path, MAP.flags) end
build()
-- A game-thread loop (never LoopAsync + ExecuteInGameThread: the pinned UE4SS can lose those callbacks).
local runner
local okL, res = pcall(LoopInGameThreadWithDelay, 250, function()
    tick()
    if finished and runner then pcall(CancelDelayedAction, runner); runner = nil end
end)
if okL then runner = res else say("END result=FAIL checks=0 failures=1 reason=loop %s", tostring(res)) end
say("LOADED %d steps", #steps)
