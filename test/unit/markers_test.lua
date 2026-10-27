-- Unit tests for Scripts/markers.lua (snapshot, restore and clear: onRevive both ways) and Scripts/game.lua (the
-- adapter) together, against a fake UE4SS world (fakeue.lua), plus markers.lua alone against a scripted adapter for
-- the failure paths. Run from the repo root:  texlua test/unit/markers_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
package.path = ROOT .. "/Scripts/?.lua;" .. ROOT .. "/test/unit/?.lua;" .. package.path
local F = require("fakeue")
local markers = require("markers")
local game = require("game")
local H = F.harness("markers_test")
local ok, eq = H.ok, H.eq

local function newLog()
    local L = { lines = {} }
    for _, lvl in ipairs({ "info", "warn", "error", "debug" }) do
        L[lvl] = function(fmt, ...) L.lines[#L.lines + 1] = lvl:upper() .. " " .. string.format(fmt, ...) end
    end
    function L.count(pat) local n = 0 for _, l in ipairs(L.lines) do if l:find(pat) then n = n + 1 end end return n end
    return L
end
local function names(list) local t = {} for _, a in ipairs(list) do t[#t + 1] = a.Name:ToString() end table.sort(t) return table.concat(t, ",") end
local WORLD = "World /Game/Maps/SmallLoweIsland/SmallMap.SmallMap"

-- A world as a death leaves it: two location markers and the satellite up, bound to the dead pawn; a flag the player
-- switched off before dying (its actor destroyed, not yet collected); flags (with Selected drift) and a satellite flag.
local function setup()
    local W = F.new()
    game.use(W.env)
    W.dead = W.pawn(1)
    W.new = W.pawn(2)
    W.med = W.waypoint("location", "Medbay", { X = 100, Y = 200, Z = 300 }, W.dead)
    W.air = W.waypoint("location", "Airport", { X = -5, Y = 6, Z = 7 }, W.dead)
    W.sat = W.waypoint("satellite", nil, { X = 9, Y = 9, Z = 9 }, nil)
    W.off = W.waypoint("location", "Oil Plant", { X = 1, Y = 1, Z = 1 }, W.dead); W.off:K2_DestroyActor()
    W.fMed, W.fAir, W.fOil, W.fDrill = W.flag("Medbay"), W.flag("AIRPORT"), W.flag("Oil Plant"), W.flag("Drilling Rig")
    W.fOil.Selected = true -- drift: the tooltip binding set it, nothing cleared it
    W.fDrill.Selected = false
    W.fSat = W.satFlag()
    W.archetype = W.obj("LevelLocationUI_C", "/Game/Graphics/Journal/MapUI.MapUI_C:WidgetTree.LevelLocationUI", { Name = F.text("Medbay"), Selected = false })
    return W
end

-- ---------------------------------------------------------------- game.lua: reading the world
do
    local W = setup()
    local recs = game.waypoints(WORLD)
    eq(#recs, 3, "waypoints: the 3 live actors (the destroyed Oil Plant one is skipped)")
    local snap = markers.snapshot(game, WORLD, newLog())
    eq(#snap, 3, "snapshot: 3 markers")
    local keys = {} for _, s in ipairs(snap) do keys[#keys + 1] = s.key end
    eq(table.concat(keys, ","), "medbay,airport,#satellite", "snapshot: keys, satellite as #satellite")
    ok(snap[1].obj == nil and snap[1].loc.X == 100, "snapshot: plain data with the location, no UObject")
    ok(W.kslCalls > 0, "waypoints: liveness asks UE's IsValid (KismetSystemLibrary), not only IsActorBeingDestroyed")
    W.off._dying = false; W.off._beingDestroyed = true
    eq(#game.waypoints(WORLD), 3, "waypoints: an actor being destroyed is skipped too")
    W.off._dying = true; W.off._beingDestroyed = false
    W.kslBroken = true
    eq(#game.waypoints(WORLD), 4, "waypoints: if UE's IsValid can't be called, a destroyed actor isn't detected (documented risk), nothing breaks")
    W.kslBroken = false
    local other = W.world("/Game/Maps/ForestMap/ForestMap.ForestMap")
    W.waypoint("location", "Lumber Yard", nil, nil, other)
    eq(#game.waypoints(WORLD), 3, "waypoints: another world's actor is not this world's marker")
    eq(#game.waypoints(nil), 4, "waypoints(nil): any world")
    local f = game.pawnFacts(W.hud(W.new))
    ok(f.pawn == W.new and f.pawnClass == "BP_FirstPersonCharacter_C" and f.world == WORLD and f.pawnPath:find("BP_FirstPersonCharacter_C_2$"), "pawnFacts: the HUD's Player", f.pawnPath)
    local f2 = game.pawnFacts(W.hud(nil, W.dead))
    ok(f2.pawn == W.dead, "pawnFacts: no Player -> the owning player's pawn")
    local f3 = game.pawnFacts(W.hud(nil, nil))
    ok(f3.pawn == nil and f3.pawnPath == nil and f3.world == WORLD, "pawnFacts: no pawn at all -> no pawn, the HUD's world")
end

-- ---------------------------------------------------------------- restore (onRevive = restore)
do
    local W = setup()
    local L = newLog()
    local r = markers.restore(game, W.new, WORLD, nil, L)
    eq(r.respawned, 3, "restore: 3 markers respawned")
    eq(r.failed, 0, "restore: none failed")
    eq(r.destroyed, 3, "restore: the 3 old actors destroyed")
    eq(names(W.live("LevelWaypointActor_C")), "Airport,Medbay", "restore: exactly one live location actor per marker")
    eq(#W.live("SatelliteWaypoint_C"), 1, "restore: exactly one live satellite actor")
    local newMed
    for _, a in ipairs(W.live("LevelWaypointActor_C")) do if a.Name:ToString() == "Medbay" then newMed = a end end
    ok(newMed ~= W.med and newMed.Character == W.new, "restore: the new Medbay actor is bound to the new pawn")
    eq(newMed._widgetName, "Medbay", "restore: Name was set before FinishSpawningActor (the widget shows it)")
    ok(newMed._widgetCharacter == W.new, "restore: Character was set before FinishSpawningActor")
    ok(newMed._loc.X == 100 and newMed._loc.Z == 300, "restore: spawned where the old actor was")
    local begin = W.calls[1]
    ok(begin[1] == "begin" and begin.owner == nil and begin.coll == 0 and begin.scale == 1 and begin.ctx == W.new, "restore: deferred spawn with no owner, as the flag's click does")
    eq(begin.xf.Rotation.W, 1, "restore: identity rotation")
    local sat = W.live("SatelliteWaypoint_C")[1]
    ok(sat.Character == nil and sat.Name:ToString() == "", "restore: the satellite gets no Character or Name, as in the game")
    -- flags follow the actors (truth is the actor), also for drift
    ok(W.fMed.Selected == true and W.fAir.Selected == true, "restore: selected flags stay selected (case-insensitive: AIRPORT)")
    ok(W.fOil.Selected == false, "restore: a drifted flag without an actor is deselected")
    ok(W.fDrill.Selected == false, "restore: an unselected flag stays unselected")
    ok(W.fSat.Selected == true, "restore: the satellite flag is selected")
    ok(W.fMed.Character == W.new and W.fDrill.Character == W.new, "restore: flags bound to the new pawn (their next click)")
    ok(W.fMed.LevelWaypoint == newMed, "restore: the flag's LevelWaypoint is the new actor")
    eq(W.archetype.Selected, false, "restore: a widget-tree archetype is never touched")
    eq(r.flags, 4, "restore: 4 location flags set")
    eq(r.satFlags, 1, "restore: 1 satellite flag set")
    eq(L.count("^INFO RESTORE location 'Medbay' respawned bReplicates=false via BeginDeferredActorSpawnFromClass$"), 1, "restore: one RESTORE line per marker with bReplicates")
    eq(L.count("^WARN"), 0, "restore: no warning")
end

do -- The snapshot brings back a marker whose actor vanished between the death and the revive; duplicates collapse.
    local W = setup()
    local snap = markers.snapshot(game, WORLD, newLog())
    W.air:K2_DestroyActor()
    W.waypoint("location", "medbay", { X = 100, Y = 200, Z = 300 }, W.dead) -- a duplicate of Medbay (other case)
    local L = newLog()
    local r = markers.restore(game, W.new, WORLD, snap, L)
    eq(r.fromActors, 2, "snapshot: Medbay and the satellite from their actors")
    eq(r.fromSnapshot, 1, "snapshot: Airport from the snapshot")
    eq(names(W.live("LevelWaypointActor_C")), "Airport,Medbay", "snapshot: one actor each, duplicates collapsed")
    eq(L.count("respawned from the snapshot"), 1, "snapshot: logged as such")
    eq(L.count("2 old actors collapsed into one"), 1, "snapshot: the collapse is logged")
end

do -- Nothing up: restore does nothing but still re-syncs the flags (drift cleared).
    local W = F.new(); game.use(W.env)
    local p = W.pawn(2)
    local fl = W.flag("Medbay"); fl.Selected = true
    local r = markers.restore(game, p, WORLD, {}, newLog())
    ok(r.respawned == 0 and fl.Selected == false, "nothing up: no spawn, drifted flag deselected")
end

-- ---------------------------------------------------------------- clear (onRevive = clear)
do
    local W = setup()
    local L = newLog()
    local r = markers.clear(game, W.new, WORLD, L)
    eq(r.cleared, 3, "clear: 3 markers cleared")
    eq(#W.live("LevelWaypointActor_C") + #W.live("SatelliteWaypoint_C"), 0, "clear: no live waypoint actor left")
    ok(not W.fMed.Selected and not W.fAir.Selected and not W.fOil.Selected and not W.fSat.Selected, "clear: every flag deselected")
    eq(#W.spawns, 0, "clear: nothing spawned")
    eq(L.count("^INFO CLEAR "), 3, "clear: one CLEAR line per marker")
end

do -- A destroy that fails leaves that marker up and its flag selected.
    local W = setup()
    W.map.failDestroy = true
    local L = newLog()
    local r = markers.clear(game, W.new, WORLD, L)
    eq(r.failed, 3, "clear failing: all 3 failed")
    ok(W.fMed.Selected and W.fSat.Selected, "clear failing: flags stay selected with their actors")
    eq(L.count("^WARN CLEAR"), 3, "clear failing: one WARN each")
end

-- ---------------------------------------------------------------- spawn failures
do -- The deferred spawn throws: the fallback spawns and re-runs BeginPlay with Name and Character set.
    local W = setup()
    W.failSpawn = true
    local L = newLog()
    local r = markers.restore(game, W.new, WORLD, nil, L)
    eq(r.respawned, 3, "fallback: still 3 respawned")
    local a = W.live("LevelWaypointActor_C")[1]
    ok(a._beginPlays == 1 and (a._widgetName == "Medbay" or a._widgetName == "Airport") and a.Character == W.new, "fallback: BeginPlay re-run with the name and pawn", tostring(a._widgetName))
    eq(L.count("via SpawnActor%+ReceiveBeginPlay"), 3, "fallback: logged")
end

do -- The spawn returns nothing: the old actor stays (the game's own state), its flag stays selected.
    local W = setup()
    W.nilSpawn = true
    W.map.SpawnActor = function() return nil end
    local L = newLog()
    local r = markers.restore(game, W.new, WORLD, nil, L)
    eq(r.failed, 3, "no spawn: 3 failed")
    eq(r.destroyed, 0, "no spawn: no old actor destroyed")
    ok(W.med._dying ~= true and W.fMed.Selected == true, "no spawn: Medbay left as the game had it")
    eq(L.count("^WARN RESTORE"), 3, "no spawn: one WARN each")
end

do -- A pawn that's already gone: spawn refuses, nothing destroyed.
    local W = setup()
    W.new._gone = true
    local r = markers.restore(game, W.new, WORLD, nil, newLog())
    ok(r.failed == 3 and r.destroyed == 0, "gone pawn: nothing replaced")
end

-- ---------------------------------------------------------------- markers.lua alone: adapter failures
do
    local L = newLog()
    local G = { waypoints = function() error("FindAllOf: boom") end }
    eq(markers.restore(G, {}, WORLD, nil, L), nil, "unreadable world: restore returns nil")
    eq(markers.clear(G, {}, WORLD, L), nil, "unreadable world: clear returns nil")
    eq(markers.snapshot(G, WORLD, L), nil, "unreadable world: snapshot nil")
    eq(L.count("^WARN"), 3, "unreadable world: one WARN each")
    local G2 = { waypoints = function() return { { kind = "location", name = "A", loc = {}, obj = 1 } } end,
                 spawn = function() return 2, { replicates = false, via = "x" } end, destroy = function() end,
                 syncFlags = function() error("flags: boom") end }
    local L2 = newLog()
    local r = markers.restore(G2, {}, WORLD, nil, L2)
    ok(r.respawned == 1 and L2.count("could not update the map's flags") == 1, "flag failure: restore still counts, one WARN")
    -- group(): junk records are ignored
    local g = markers.group({ { kind = "ping", name = "x" }, { kind = "location", name = "" }, { kind = "location" }, { kind = "satellite", obj = 1 }, { kind = "satellite", obj = 2 } })
    ok(#g == 1 and #g[1].actors == 2 and g[1].name == "Satellite", "group: pings and nameless locations ignored; satellites collapse")
    -- plan(): snapshot entries without a location are not respawned
    local p = markers.plan({}, { { kind = "location", name = "X", key = "x" }, { kind = "location", name = "Y", key = "y", loc = { X = 1, Y = 1, Z = 1 } } })
    ok(#p == 1 and p[1].name == "Y", "plan: a snapshot entry needs its location")
    eq(markers.key("location", "Medbay"), markers.key("location", "MEDBAY"), "key: case-insensitive")
    ok(markers.key("location", "Satellite") ~= markers.key("satellite"), "key: a location named Satellite isn't the satellite")
end

H.done()
