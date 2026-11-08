-- Unit tests for Scripts/main.lua outside the game: the bootstrap, the settings (onRevive both ways, changed between
-- revives), and the whole path from core's HUD events to the restore or clear, with the real revive.lua, markers.lua
-- and game.lua over a fake core (connect, log, ui.hud.watch, ref/deref/free, clock) and a fake UE4SS world.
-- Run from the repo root:  texlua test/unit/main_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
package.path = ROOT .. "/test/unit/?.lua;" .. package.path
local F = require("fakeue")
local H = F.harness("main_test")
local ok, eq = H.ok, H.eq
local MAIN = ROOT .. "/Scripts/main.lua"
local realLoadfile, realLoad = loadfile, load
local W, S -- the fake world; S.settings is the text of settings.lua (false: missing)

local function newLog(tag)
    local L = { debugEnabled = false }
    local function emit(level, fmt, ...) print("[" .. tag .. "] " .. level .. string.format(fmt, ...) .. "\n") end
    function L.info(f, ...) emit("", f, ...) end
    function L.warn(f, ...) emit("WARN ", f, ...) end
    function L.error(f, ...) emit("ERROR ", f, ...) end
    function L.debug(f, ...) if L.debugEnabled then emit("DEBUG ", f, ...) end end
    return L
end

-- Loads main.lua fresh. opts.client = false: core not installed.
local function boot(opts)
    opts = opts or {}
    W = F.new()
    F.install(W)
    S = { settings = opts.settings, connects = {} }
    if S.settings == nil then S.settings = 'return { onRevive = "restore" }' end
    for _, m in ipairs({ "revive", "markers", "game", "nucleus.client" }) do package.loaded[m] = nil end
    package.preload["nucleus.client"] = nil
    if opts.client ~= false then
        package.preload["nucleus.client"] = function() return { connect = function(o) S.connects[#S.connects + 1] = o end } end
    end
    loadfile = function(path, mode, env)
        if path:match("[/\\]settings%.lua$") then
            if S.settings == false then return nil, "cannot open " .. path end
            return realLoad(S.settings, "=settings.lua", "t", env)
        end
        return realLoadfile(path, mode, env)
    end
    local chunk = assert(realLoadfile(MAIN))
    chunk()
    -- game.lua uses the globals F.install put in place (its default environment is _G)
end

local function newCore(o)
    o = o or {}
    local core = { name = "Nucleus", version = "0.2.0", log = newLog("Markers"), watchers = {} }
    if o.hud ~= false then
        core.ui = { hud = { watch = function(fn) core.watchers[#core.watchers + 1] = fn return #core.watchers end } }
    end
    if o.ref ~= false then
        local refs, n = {}, 0
        core.ref = function(obj) n = n + 1; refs[n] = obj; return n end
        core.deref = function(h) local x = refs[h] if x and not x._gone then return x end return nil end
        core.free = function(h) refs[h] = nil end
        core.refs = refs
    end
    local t = 0
    core.clock = { micros = function() return t end }
    core.advance = function(sec) t = t + sec * 1e6 end
    return core
end
local function ready(core) S.connects[1].onReady(core) end
local function emit(core, hud, event) for _, fn in ipairs(core.watchers) do fn(hud, { event = event, path = type(hud) == "table" and rawget(hud, "_path") or nil, reason = "test" }) end end
local function lines(pat) local r = {} for _, l in ipairs(W.printed) do if l:find(pat) then r[#r + 1] = l end end return r end
local function count(pat) return #lines(pat) end

-- A match: the player's pawn with a HUD, two location markers and the satellite up, their flags.
local function match(core)
    W.p1 = W.pawn(1)
    W.hud1 = W.hud(W.p1)
    W.med = W.waypoint("location", "Medbay", { X = 1, Y = 2, Z = 3 }, W.p1)
    W.air = W.waypoint("location", "Airport", { X = 4, Y = 5, Z = 6 }, W.p1)
    W.sat = W.waypoint("satellite", nil, { X = 7, Y = 8, Z = 9 }, nil)
    W.fMed, W.fAir, W.fRig, W.fSat = W.flag("Medbay"), W.flag("Airport"), W.flag("Drilling Rig"), W.satFlag()
    W.fRig.Selected = false
    emit(core, W.hud1, "attached")
end
-- Death (HUD lost), then the reinforcement: a new pawn with a new HUD.
local function dieAndRevive(core, i)
    emit(core, nil, "lost")
    if ExecuteInGameThreadWithDelay then
        eq(count("LOST"), 0, "no snapshot inside core's HUD tick at the death")
        eq(#W.delayed, 1, "the snapshot is deferred")
        eq(W.delayed[1].ms, 50, "snapshot deferred by 50 ms")
        W.runDelayed()
    end
    W.p2 = W.pawn(i or 2)
    W.hud2 = W.hud(W.p2)
    core.advance(60)
    emit(core, W.hud2, "attached")
end
local function liveWaypoints()
    local r = {}
    for _, short in ipairs({ "LevelWaypointActor_C", "SatelliteWaypoint_C" }) do for _, a in ipairs(W.live(short)) do r[#r + 1] = a end end
    return r
end

-- ---------------------------------------------------------------- bootstrap (CAP-4)
do
    boot{ client = false }
    eq(#W.printed, 1, "no core: exactly one line")
    eq(W.printed[1], "[Markers] Nucleus is not installed. Markers will not run.", "no core: the line names the cause")
    eq(#S.connects, 0, "no core: no connect")
end
do
    boot()
    eq(#S.connects, 1, "connect called once")
    local c = S.connects[1]
    ok(c.mod == "Markers" and c.need == ">=0.2.0", "connect{ mod = 'Markers', need = '>=0.2.0' }", tostring(c.mod) .. " " .. tostring(c.need))
    eq(#W.printed, 0, "nothing printed during main.lua")
    c.onFail("Nucleus 0.1.0 is older than Markers needs (>=0.2.0). Update Nucleus.")
    eq(#W.printed, 0, "onFail adds no line (connect logged the cause)")
end
do -- core without HUD events: one ERROR, nothing registered.
    boot()
    local core = newCore{ hud = false }
    ready(core)
    eq(count("^%[Markers%] ERROR Nucleus's HUD events"), 1, "no core.ui.hud: one ERROR")
    eq(#W.loadMapHooks, 0, "no core.ui.hud: no hook")
end

-- ---------------------------------------------------------------- the revive, onRevive = restore (CAP-1)
do
    boot()
    local core = newCore()
    ready(core)
    eq(count("^%[Markers%] READY onRevive=restore$"), 1, "READY onRevive=restore")
    eq(#core.watchers, 1, "one HUD watcher")
    eq(#W.loadMapHooks, 1, "one LoadMap hook")
    match(core)
    eq(count("^%[Markers%] PAWN first .*BP_FirstPersonCharacter_C_1$"), 1, "PAWN first")
    dieAndRevive(core)
    eq(count("^%[Markers%] LOST pawn=.*_1 snapshot n=3 %(locations 2, satellite 1%)$"), 1, "LOST with the snapshot at the death")
    eq(count("^%[Markers%] REVIVE pawn=.*_2 was=.*_1 snapshot=3 onRevive=restore$"), 1, "REVIVE line")
    eq(#W.delayed, 1, "the restore is deferred (ExecuteInGameThreadWithDelay)")
    eq(W.delayed[1].ms, 500, "deferred by 500 ms")
    eq(#W.spawns, 0, "nothing spawned inside core's HUD tick")
    W.runDelayed()
    eq(count("^%[Markers%] RESTORED n=3 %(from actors 3, from the snapshot 0, failed 0, old destroyed 3%) flags=3 satelliteFlags=1$"), 1, "RESTORED line")
    local live = liveWaypoints()
    eq(#live, 3, "one waypoint actor per marker")
    local bound = true
    for _, a in ipairs(live) do if a._class.short == "LevelWaypointActor_C" and a.Character ~= W.p2 then bound = false end end
    ok(bound, "location waypoints bound to the new pawn")
    ok(W.fMed.Selected and W.fAir.Selected and W.fSat.Selected and not W.fRig.Selected, "flags match the markers")
    eq(count("bReplicates=false"), 3, "each RESTORE logs bReplicates=false")
    eq(count("WARN"), 0, "no WARN")
    eq(next(core.refs), nil, "the pawn's weak handle was freed")
    -- the new pawn's HUD rebuilt within the settle window: restored again (still one actor each)
    emit(core, nil, "lost"); core.advance(3); emit(core, W.hud2, "attached")
    eq(count("^%[Markers%] AGAIN pawn="), 1, "AGAIN within the settle window")
    W.runDelayed()
    eq(#liveWaypoints(), 3, "AGAIN: still exactly one actor per marker")
end

-- ---------------------------------------------------------------- onRevive = clear, and changed between revives
do
    boot{ settings = 'return { onRevive = "clear" }' }
    local core = newCore()
    ready(core)
    eq(count("READY onRevive=clear"), 1, "READY onRevive=clear")
    match(core)
    dieAndRevive(core)
    W.runDelayed()
    eq(count("^%[Markers%] CLEARED n=3 %(failed 0%) flags=3 satelliteFlags=1$"), 1, "CLEARED line")
    eq(#liveWaypoints(), 0, "clear: no waypoint left")
    ok(not W.fMed.Selected and not W.fAir.Selected and not W.fSat.Selected, "clear: no flag selected")
    -- changeable anytime: switch to restore, place a marker, die and revive again
    S.settings = 'return { onRevive = "restore" }'
    W.waypoint("location", "Medbay", { X = 1, Y = 2, Z = 3 }, W.p2)
    emit(core, nil, "lost")
    local p3 = W.pawn(3); core.advance(60); emit(core, W.hud(p3), "attached")
    W.runDelayed()
    eq(count("REVIVE pawn=.*_3 .*onRevive=restore"), 1, "second revive reads the changed setting")
    eq(count("RESTORED n=1 "), 1, "second revive restores")
end

do -- The revive comes before the deferred snapshot ran: the restore still gets it (filled in place, queued first).
    boot()
    local core = newCore()
    ready(core)
    match(core)
    emit(core, nil, "lost")
    W.p2 = W.pawn(2); W.hud2 = W.hud(W.p2); core.advance(1); emit(core, W.hud2, "attached")
    eq(#W.delayed, 2, "snapshot and restore both queued")
    eq(W.delayed[1].ms, 50, "the snapshot runs first")
    W.runDelayed()
    eq(count("^%[Markers%] LOST pawn=.*_1 snapshot n=3 "), 1, "LOST with the snapshot")
    eq(count("^%[Markers%] RESTORED n=3 "), 1, "RESTORED n=3")
end

do -- The waypoint actors can't be read at the death: an empty snapshot, the revive still restores from the live actors.
    boot()
    local core = newCore()
    ready(core)
    match(core)
    local saved = FindAllOf
    FindAllOf = function() error("boom") end
    emit(core, nil, "lost")
    W.runDelayed()
    FindAllOf = saved
    eq(count("LOST pawn=.*snapshot n=0 "), 1, "LOST with an empty snapshot")
    W.p2 = W.pawn(2); W.hud2 = W.hud(W.p2); core.advance(60); emit(core, W.hud2, "attached")
    W.runDelayed()
    eq(count("RESTORED n=3 %(from actors 3, from the snapshot 0"), 1, "restored from the live actors")
end

do -- A new pawn without a HUD loss (no proven death): REBOUND, restored even with onRevive = clear.
    boot{ settings = 'return { onRevive = "clear" }' }
    local core = newCore()
    ready(core)
    match(core)
    local p2 = W.pawn(2)
    emit(core, W.hud(p2), "attached")
    W.runDelayed()
    eq(count("^%[Markers%] REBOUND pawn=.*_2 was=.*_1"), 1, "REBOUND line")
    eq(count("RESTORED n=3"), 1, "REBOUND restores")
    eq(count("CLEARED"), 0, "REBOUND never clears")
end

do -- Death to spectator, no revive: nothing done; a map change forgets everything.
    boot()
    local core = newCore()
    ready(core)
    match(core)
    emit(core, nil, "lost")
    W.runDelayed()
    local spec = W.obj("Spectator_C", "/Game/Maps/SmallLoweIsland/SmallMap.SmallMap:PersistentLevel.Spectator_C_1")
    emit(core, W.hud(nil, spec), "attached")
    eq(count("PAWN .*Spectator_C_1 %(Spectator_C%) is not a first%-person character: not a revive"), 1, "spectator: not a revive")
    eq(#W.delayed, 0, "spectator: nothing scheduled")
    eq(#liveWaypoints(), 3, "spectator: markers untouched")
    W.loadMapHooks[1]()
    emit(core, W.hud(W.pawn(7)), "attached")
    eq(count("REVIVE"), 0, "after a map load: no revive")
    eq(count("PAWN first"), 2, "after a map load: a first pawn again")
end

do -- The new pawn is gone before the deferred restore runs: one WARN, nothing changed.
    boot()
    local core = newCore()
    ready(core)
    match(core)
    dieAndRevive(core)
    W.p2._gone = true
    W.runDelayed()
    eq(count("WARN the new pawn .* was gone before the revive could run; nothing done"), 1, "gone pawn: one WARN")
    eq(#W.spawns, 0, "gone pawn: nothing spawned")
end

do -- No weak handles: the pawn is found again by its path. No ExecuteInGameThreadWithDelay: runs at once.
    boot()
    local core = newCore{ ref = false }
    ExecuteInGameThreadWithDelay = nil
    ready(core)
    match(core)
    dieAndRevive(core)
    eq(count("RESTORED n=3"), 1, "no delay function, no handles: restored at once by path")
end

do -- Bad settings: one WARN after connect, restore used.
    boot{ settings = 'return { onRevive = "bogus" }' }
    eq(#W.printed, 0, "bad settings: nothing printed before connect")
    local core = newCore()
    ready(core)
    eq(count("WARN onRevive must be restore or clear, got bogus; using restore"), 1, "bad settings: one WARN")
    eq(count("READY onRevive=restore"), 1, "bad settings: restore")
    match(core); dieAndRevive(core); W.runDelayed()
    eq(count("WARN onRevive must be"), 1, "bad settings: still one WARN after the revive re-read it")
    boot{ settings = false }
    ready(newCore())
    eq(count("WARN settings.lua could not be read"), 1, "missing settings: one WARN")
    boot{ settings = 'return { onRevive = "restore", debug = true }' }
    local c2 = newCore()
    ready(c2)
    ok(c2.log.debugEnabled == true, "debug = true turns DEBUG lines on")
end

do -- A watcher fault (a HUD whose reads all throw) is caught and logged once; LoopAsync/ExecuteInGameThread never used.
    boot()
    local core = newCore()
    ready(core)
    local bad = setmetatable({}, { __index = function() error("boom") end })
    emit(core, bad, "attached"); emit(core, bad, "attached")
    eq(count("^%[Markers%] ERROR") + count("traceback"), 0, "bad HUD: no error line")
    ok(count("WARN HUD event failed") <= 1, "bad HUD: at most one WARN")
    emit(core, nil, "shown"); emit(core, nil, "hidden")
    eq(count("REVIVE"), 0, "shown/hidden: nothing")
end

loadfile = realLoadfile
H.done()
