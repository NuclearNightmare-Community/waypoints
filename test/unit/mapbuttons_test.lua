-- Unit tests for Scripts/mapbuttons.lua (Mark all, Clear all and the map-open sync: every row of story 3's I/O matrix)
-- with the real game.lua over a fake UE4SS world whose flags click as the V8.2 decompile does (fakeue.lua), plus
-- mapbuttons.lua alone against a scripted adapter for the failure paths. Run from the repo root:
--   texlua test/unit/mapbuttons_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
package.path = ROOT .. "/Scripts/?.lua;" .. ROOT .. "/test/unit/?.lua;" .. package.path
local F = require("fakeue")
local mb = require("mapbuttons")
local game = require("game")
local H = F.harness("mapbuttons_test")
local ok, eq = H.ok, H.eq

local function newLog()
    local L = { lines = {} }
    for _, lvl in ipairs({ "info", "warn", "error", "debug" }) do
        L[lvl] = function(fmt, ...) L.lines[#L.lines + 1] = lvl:upper() .. " " .. string.format(fmt, ...) end
    end
    function L.count(pat) local n = 0 for _, l in ipairs(L.lines) do if l:find(pat) then n = n + 1 end end return n end
    function L.dump() return table.concat(L.lines, " | ") end
    return L
end
local function live(W) return #W.live("LevelWaypointActor_C") + #W.live("SatelliteWaypoint_C") end
local function liveNamed(W, name)
    local n = 0
    for _, a in ipairs(W.live("LevelWaypointActor_C")) do if a.Name:ToString():lower() == name:lower() then n = n + 1 end end
    return n
end

-- Tower Island-like map: three location flags (Medbay twice: a duplicate-name flag), the satellite flag, the player's
-- pawn and an open Journal. All flags start unselected with no Character (a map opened from Lua leaves it empty).
local function setup(opts)
    opts = opts or {}
    mb._said = {}
    local W = F.new()
    game.use(W.env)
    W.p = W.pawn(1)
    W.fMed, W.fAir, W.fRig, W.fMed2 = W.flag("Medbay"), W.flag("Airport"), W.flag("Drilling Rig"), W.flag("MEDBAY")
    for _, f in ipairs({ W.fMed, W.fAir, W.fRig, W.fMed2 }) do f.Selected = false end
    if opts.sat ~= false then W.fSat = W.satFlag(); W.fSat.Selected = false end
    W.j = W.journal({ W.fMed, W.fAir, W.fRig, W.fMed2 }, W.fSat, opts.character == nil and W.p or opts.character)
    return W
end
local function allSelected(W, want)
    for _, f in ipairs({ W.fMed, W.fAir, W.fRig, W.fMed2, W.fSat }) do if f and f.Selected ~= want then return false end end
    return true
end

-- ---------------------------------------------------------------- Mark all, none up
do
    local W = setup()
    local L = newLog()
    local r = mb.markAll(game, W.j, L)
    ok(r and r.marked == 4 and r.already == 0 and r.failed == 0, "mark none up: 3 locations + satellite marked", L.dump())
    eq(#W.clicks, 4, "mark none up: one click per flag key + satellite (the duplicate Medbay flag not clicked)")
    ok(W.clicks[1] == W.fMed and W.clicks[4] == W.fSat, "mark none up: the first widget of a name clicks, satellite last")
    ok(liveNamed(W, "Medbay") == 1 and liveNamed(W, "Airport") == 1 and liveNamed(W, "Drilling Rig") == 1 and #W.live("SatelliteWaypoint_C") == 1, "mark none up: one actor per key")
    ok(allSelected(W, true), "mark none up: every flag Selected, the duplicate too")
    ok(W.fMed.Character == W.p and W.fMed2.Character == W.p and W.fRig.Character == W.p, "mark none up: every location flag got the pawn as Character")
    eq(rawget(W.fSat, "Character"), nil, "mark none up: the satellite flag gets no Character")
    for _, a in ipairs(W.live("LevelWaypointActor_C")) do ok(a.Character == W.p, "mark none up: the game's own spawn bound the waypoint to the pawn") end
    eq(L.count("^INFO MARKALL marked=4 already=0 failed=0 waypoints=4 flags=3 satellite=yes$"), 1, "mark none up: MARKALL line")
    eq(L.count("^INFO MARK location 'Medbay'$"), 1, "mark none up: MARK location line")
    eq(L.count("^INFO MARK satellite$"), 1, "mark none up: MARK satellite line")
    eq(L.count("^WARN"), 0, "mark none up: no WARN")
    -- pressed again: everything already up, nothing clicked
    local L2 = newLog()
    local r2 = mb.markAll(game, W.j, L2)
    ok(r2.marked == 0 and r2.already == 4 and #W.clicks == 4 and live(W) == 4, "mark twice: already=4, no click, no second actor")
end

-- ---------------------------------------------------------------- Mark all, some up (one with Selected drifted false)
do
    local W = setup()
    W.waypoint("location", "Medbay", nil, W.p)
    W.waypoint("location", "airport", nil, W.p)
    W.fMed.Selected = true -- W.fAir.Selected stays false: drift
    W.fRig.Selected = true -- drift the other way: selected, no actor
    local L = newLog()
    local r = mb.markAll(game, W.j, L)
    ok(r.already == 2 and r.marked == 2 and r.failed == 0, "mark some up: already=2, Drilling Rig and the satellite marked", L.dump())
    eq(#W.clicks, 2, "mark some up: only the two flags without an actor clicked")
    ok(W.clicks[1] == W.fRig and W.clicks[2] == W.fSat, "mark some up: Drilling Rig (drifted Selected true) clicked, not toggled off")
    ok(liveNamed(W, "Medbay") == 1 and liveNamed(W, "Airport") == 1, "mark some up: no second actor")
    ok(allSelected(W, true), "mark some up: every flag Selected")
    eq(L.count("MARKALL marked=2 already=2 failed=0 waypoints=4 flags=3 satellite=yes$"), 1, "mark some up: MARKALL line")
end

-- ---------------------------------------------------------------- Clear all, some up
do
    local W = setup()
    W.waypoint("location", "Medbay", nil, W.p)
    W.waypoint("location", "Airport", nil, W.p)
    W.waypoint("satellite", nil, nil, nil)
    W.fMed.Selected, W.fAir.Selected, W.fSat.Selected = true, true, true
    local L = newLog()
    local r = mb.clearAll(game, W.j, L)
    ok(r.cleared == 3 and r.direct == 0 and r.failed == 0 and r.waypoints == 0, "clear some up: 3 cleared by their flags", L.dump())
    eq(#W.clicks, 3, "clear some up: each flag clicked once per live actor")
    eq(live(W), 0, "clear some up: no actor left")
    ok(allSelected(W, false), "clear some up: no flag Selected")
    eq(#W.spawns, 0, "clear some up: nothing spawned")
    eq(L.count("^INFO CLEARALL cleared=3 direct=0 failed=0 waypoints=0 flags=3$"), 1, "clear some up: CLEARALL line")
    eq(L.count("^INFO CLEAR location 'Medbay'$") + L.count("^INFO CLEAR satellite$"), 2, "clear some up: CLEAR lines")
    -- pressed again with nothing up: no click, no spawn
    local r2 = mb.clearAll(game, W.j, newLog())
    ok(r2.cleared == 0 and #W.clicks == 3 and live(W) == 0, "clear twice: nothing clicked, nothing spawned")
end

-- ---------------------------------------------------------------- Clear all, duplicate and orphan actors
do
    local W = setup()
    W.waypoint("location", "Medbay", nil, W.p)
    W.waypoint("location", "medbay", nil, W.p) -- two actors of one name: the game's click destroys only the first
    W.waypoint("location", "Lumber Yard", nil, W.p) -- no flag on this map
    W.waypoint("satellite", nil, nil, nil); W.waypoint("satellite", nil, nil, nil)
    local L = newLog()
    local r = mb.clearAll(game, W.j, L)
    ok(r.cleared == 4 and r.direct == 1 and r.failed == 0 and r.waypoints == 0, "clear duplicates: Medbay x2 and satellite x2 by clicks, the orphan directly", L.dump())
    eq(#W.clicks, 4, "clear duplicates: Medbay clicked twice, the satellite twice (bounded by the count)")
    eq(live(W), 0, "clear duplicates: nothing left")
    eq(#W.spawns, 0, "clear duplicates: no click spawned anything")
    eq(L.count("CLEARALL cleared=4 direct=1 failed=0 waypoints=0 flags=3$"), 1, "clear duplicates: CLEARALL line")
    eq(L.count("^INFO CLEAR location 'Lumber Yard'$"), 1, "clear duplicates: the orphan's CLEAR line")
end

do -- A destroy that fails: WARN, counted failed, its flag stays selected.
    local W = setup()
    local orphan = W.waypoint("location", "Lumber Yard", nil, W.p)
    orphan.K2_DestroyActor = function() error("K2_DestroyActor: boom") end
    W.waypoint("location", "Airport", nil, W.p)
    local L = newLog()
    local r = mb.clearAll(game, W.j, L)
    ok(r.cleared == 1 and r.direct == 0 and r.failed == 1 and r.waypoints == 1, "destroy fails: failed=1, waypoints=1", L.dump())
    eq(L.count("^WARN CLEAR location 'Lumber Yard': could not destroy a waypoint"), 1, "destroy fails: one WARN")
    eq(W.fAir.Selected, false, "destroy fails: the others still cleared")
end

do -- A click that removes nothing: the clicking stops (it would put a waypoint up), the actor is destroyed directly.
    local W = setup()
    local a = W.waypoint("location", "Airport", nil, W.p)
    W.fAir[game.LOC_CLICK] = function(self) W.clicks[#W.clicks + 1] = self end -- a handler that does nothing
    local L = newLog()
    local r = mb.clearAll(game, W.j, L)
    ok(r.cleared == 0 and r.direct == 1 and r.failed == 1 and a._dying == true, "click removes nothing: one click, then destroyed directly", L.dump())
    eq(#W.clicks, 1, "click removes nothing: clicked once only")
    eq(L.count("removed no waypoint; stopped clicking"), 1, "click removes nothing: one WARN")
end

-- ---------------------------------------------------------------- no satellite flag
do
    local W = setup{ sat = false }
    local L = newLog()
    local r = mb.markAll(game, W.j, L)
    ok(r.marked == 3 and r.satellite == "none" and #W.live("SatelliteWaypoint_C") == 0, "no satellite flag: locations only", L.dump())
    eq(L.count("MARKALL marked=3 already=0 failed=0 waypoints=3 flags=3 satellite=none$"), 1, "no satellite flag: satellite=none")
    W.waypoint("satellite", nil, nil, nil) -- left from elsewhere: no flag to click, destroyed directly
    local L2 = newLog()
    local r2 = mb.clearAll(game, W.j, L2)
    ok(r2.cleared == 3 and r2.direct == 1 and r2.waypoints == 0, "no satellite flag: clear takes the satellite directly", L2.dump())
    eq(L.count("^WARN") + L2.count("^WARN"), 0, "no satellite flag: no WARN")
end

-- ---------------------------------------------------------------- map not open, pawn not usable
do
    local W = setup()
    local L = newLog()
    eq(mb.markAll(game, nil, L), nil, "not open: mark does nothing")
    eq(mb.clearAll(game, nil, L), nil, "not open: clear does nothing")
    eq(L.count("^WARN Mark all skipped: the map is not open$"), 1, "not open: one WARN for mark")
    eq(L.count("^WARN Clear all skipped: the map is not open$"), 1, "not open: one WARN for clear")
    eq(#W.clicks, 0, "not open: nothing clicked")
    eq(mb.syncOnOpen(game, nil, L), nil, "not open: no sync")
end
do
    local W = setup()
    W.j.Character = W.obj("Spectator_C", "/Game/Maps/SmallLoweIsland/SmallMap.SmallMap:PersistentLevel.Spectator_C_1")
    local L = newLog()
    eq(mb.markAll(game, W.j, L), nil, "spectator: mark does nothing")
    eq(L.count("^WARN Mark all skipped: the map's character is Spectator_C, not a live BP_FirstPersonCharacter_C$"), 1, "spectator: one WARN naming the class", L.dump())
    W.j.Character = W.p; W.p._dying = true
    local L2 = newLog()
    eq(mb.clearAll(game, W.j, L2), nil, "dead pawn: clear does nothing")
    eq(L2.count("^WARN Clear all skipped: the map's character is BP_FirstPersonCharacter_C %(destroyed%)"), 1, "dead pawn: one WARN", L2.dump())
    W.j.Character = nil
    local L3 = newLog()
    eq(mb.markAll(game, W.j, L3), nil, "no pawn: mark does nothing")
    eq(L3.count("character is none"), 1, "no pawn: WARN says none")
    eq(#W.clicks, 0, "pawn not usable: nothing clicked")
end

-- ---------------------------------------------------------------- a click throws
do
    local W = setup()
    W.failClick = function(f) return f == W.fAir end
    local L = newLog()
    local r = mb.markAll(game, W.j, L)
    ok(r.marked == 3 and r.failed == 1, "mark, a click throws: the others continue, failed=1", L.dump())
    eq(L.count("^WARN MARK location 'Airport' failed %(.*boom"), 1, "mark, a click throws: one WARN for that flag")
    ok(W.fAir.Selected == false and W.fMed.Selected == true, "mark, a click throws: Selected from the actors")
    eq(L.count("MARKALL marked=3 already=0 failed=1 waypoints=3 flags=3 satellite=yes$"), 1, "mark, a click throws: MARKALL counts it")
    -- clear with Airport's click throwing (its actor made by hand): destroyed directly, counted failed
    W.waypoint("location", "Airport", nil, W.p)
    local L2 = newLog()
    local r2 = mb.clearAll(game, W.j, L2)
    ok(r2.cleared == 3 and r2.direct == 1 and r2.failed == 1 and r2.waypoints == 0, "clear, a click throws: WARN, direct destroy, failed=1", L2.dump())
    eq(L2.count("^WARN CLEAR location 'Airport': the flag's click failed"), 1, "clear, a click throws: one WARN")
    ok(allSelected(W, false), "clear, a click throws: no flag Selected")
end

do -- A click that runs but spawns nothing counts as failed.
    local W = setup()
    W.noSpawn = true
    local L = newLog()
    local r = mb.markAll(game, W.j, L)
    ok(r.marked == 0 and r.failed == 4 and allSelected(W, false), "mark, no spawn: failed and unselected", L.dump())
    eq(L.count("the click spawned no waypoint"), 4, "mark, no spawn: one WARN each")
end

-- ---------------------------------------------------------------- map opens
do
    local W = setup()
    W.waypoint("location", "Airport", nil, W.p)
    W.waypoint("satellite", nil, nil, nil)
    W.fMed.Selected = true -- drift: no actor
    local L = newLog()
    local r = mb.syncOnOpen(game, W.j, L)
    ok(r and r.flags == 3 and r.selected == 1 and r.satellite == "yes", "open: counts", L.dump())
    ok(W.fAir.Selected and W.fSat.Selected and not W.fMed.Selected and not W.fMed2.Selected and not W.fRig.Selected, "open: Selected = actor presence")
    ok(W.fMed.Character == W.p and W.fRig.Character == W.p, "open: Character = the Journal's pawn")
    eq(#W.clicks, 0, "open: nothing clicked")
    eq(L.count("^INFO MAPSYNC flags=3 selected=1 satellite=yes$"), 1, "open: MAPSYNC line")
    local W2 = setup{ sat = false }
    local L2 = newLog()
    mb.syncOnOpen(game, W2.j, L2)
    eq(L2.count("MAPSYNC flags=3 selected=0 satellite=none$"), 1, "open, no satellite flag: satellite=none")
    -- a spectator's Journal: Selected still synced, Character left alone
    local W3 = setup()
    W3.j.Character = W3.obj("Spectator_C", "/Game/x.Spectator_C_1")
    W3.waypoint("location", "Airport", nil, W3.p) -- found through the Journal's own world (no pawn to take it from)
    local L3 = newLog()
    mb.syncOnOpen(game, W3.j, L3)
    ok(rawget(W3.fMed, "Character") == nil and L3.count("MAPSYNC") == 1 and L3.count("^WARN") == 0, "open, no usable pawn: no Character, still synced")
    ok(W3.fAir.Selected == true and W3.fMed.Selected == false, "open, no usable pawn: Selected from the Journal's world's actors")
    eq(L3.count("MAPSYNC flags=3 selected=1 satellite=no$"), 1, "open, no usable pawn: MAPSYNC selected=1")
end

-- ---------------------------------------------------------------- mapbuttons.lua alone: adapter failures
do
    local base = function()
        local G = {}
        for k, v in pairs(game) do G[k] = v end
        return G
    end
    local W = setup()
    local G = base()
    G.journalFlags = function() error("MapUI: boom") end
    local L = newLog()
    eq(mb.markAll(G, W.j, L), nil, "unreadable flags: mark nil")
    eq(L.count("^WARN Mark all skipped: could not read the map's flags %(.*MapUI: boom"), 1, "unreadable flags: one WARN")
    mb.syncOnOpen(G, W.j, L); mb.syncOnOpen(G, W.j, L)
    eq(L.count("^WARN map open: could not read the map's flags"), 1, "unreadable flags on open: WARN once")
    local G2 = base()
    G2.waypoints = function() error("FindAllOf: boom") end
    local L2 = newLog()
    eq(mb.clearAll(G2, W.j, L2), nil, "unreadable actors: clear nil")
    eq(L2.count("^WARN Clear all skipped: could not read the waypoint actors"), 1, "unreadable actors: one WARN")
    eq(#W.clicks, 0, "unreadable actors: nothing clicked")
    -- one FindAllOf pass per action: count the adapter's waypoints() calls
    local G3, n = base(), 0
    G3.waypoints = function(w) n = n + 1 return game.waypoints(w) end
    mb.markAll(G3, W.j, newLog()); eq(n, 1, "mark: one waypoints() read")
    mb.clearAll(G3, W.j, newLog()); eq(n, 2, "clear: one waypoints() read")
    mb.syncOnOpen(G3, W.j, newLog()); eq(n, 3, "open: one waypoints() read")
    -- MapUI.Levels unreadable, or its ForEach failing: an error, logged as "could not read the map's flags", nothing done
    for _, how in ipairs({ "read", "walk" }) do
        local Wl = setup()
        Wl.waypoint("location", "Airport", nil, Wl.p)
        local mui = Wl.j.MapWidget.MapUI
        if how == "read" then
            local base = getmetatable(mui).__index
            mui.Levels = nil
            setmetatable(mui, { __index = function(_, k) if k == "Levels" then error("Levels: boom") end return base[k] end })
        else mui.Levels = { ForEach = function() error("ForEach: boom") end } end
        local Lm, Lc, Lo = newLog(), newLog(), newLog()
        eq(mb.markAll(game, Wl.j, Lm), nil, "Levels " .. how .. " fails: mark nil")
        eq(mb.clearAll(game, Wl.j, Lc), nil, "Levels " .. how .. " fails: clear nil")
        eq(mb.syncOnOpen(game, Wl.j, Lo), nil, "Levels " .. how .. " fails: sync nil")
        eq(Lm.count("^WARN Mark all skipped: could not read the map's flags %(.*MapUI%.Levels can't be"), 1, "Levels " .. how .. " fails: Mark all WARN")
        eq(Lc.count("^WARN Clear all skipped: could not read the map's flags"), 1, "Levels " .. how .. " fails: Clear all WARN")
        eq(Lo.count("^WARN map open: could not read the map's flags"), 1, "Levels " .. how .. " fails: open WARN")
        ok(#Wl.clicks == 0 and liveNamed(Wl, "Airport") == 1, "Levels " .. how .. " fails: nothing clicked or destroyed")
    end
    -- the real journalFlags on a Journal without a MapWidget raises (caught above as "could not read")
    local bad = W.obj("Journal_C", "/Engine/Transient.Journal_C_bad", { Character = W.p })
    local L4 = newLog()
    eq(mb.markAll(game, bad, L4), nil, "no MapWidget: mark nil")
    eq(L4.count("has no MapWidget"), 1, "no MapWidget: named")
end

H.done()
