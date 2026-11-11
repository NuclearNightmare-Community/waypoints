-- Unit tests for Scripts/main.lua outside the game: the bootstrap, the settings (onRevive both ways, changed between
-- revives), the whole path from core's HUD events to the restore or clear, and the Mark all / Clear all wiring (panel and
-- button arguments, the Journal watcher's order and weak handle, presses with and without an open map), with the real
-- revive.lua, waypoints.lua, mapbuttons.lua and game.lua over a fake core (connect, log, ui.hud.watch, ui.panel,
-- ui.button, ui.journal, ref/deref/free, clock) and a fake UE4SS world.
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
    for _, m in ipairs({ "revive", "waypoints", "mapbuttons", "game", "panelfit", "nucleus.client" }) do package.loaded[m] = nil end
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
    local core = { name = "Nucleus", version = "0.6.0", log = newLog("Waypoints"), watchers = {}, jwatchers = {}, seq = {}, panels = {}, buttons = {}, overlapCalls = {} }
    if o.hud ~= false then
        core.ui = { hud = { watch = function(fn) core.watchers[#core.watchers + 1] = fn return #core.watchers end } }
    end
    if o.hud ~= false and o.buttons ~= false then
        -- core 0.6.0's panels, buttons and Journal events, recording what Waypoints asks for and in which order
        core.ui.panel = { remove = function(h) core.seq[#core.seq + 1] = "panel.remove " .. tostring(h.id) end, create = function(spec)
            core.seq[#core.seq + 1] = "panel " .. tostring(spec.id)
            local h = setmetatable({ id = spec.id }, { __metatable = "element handle" })
            core.panels[#core.panels + 1] = { spec = spec, handle = h }
            return h
        end }
        core.ui.button = { create = function(spec)
            core.seq[#core.seq + 1] = "button " .. tostring(spec.id)
            if o.buttonThrows then error("nucleus.ui.button.create: boom") end
            local h = { id = spec.id }
            core.buttons[spec.id] = { spec = spec, handle = h }
            return h
        end }
        core.ui.journal = { watch = function(fn)
            core.seq[#core.seq + 1] = "journal.watch"
            core.jwatchers[#core.jwatchers + 1] = fn
            return #core.jwatchers
        end }
        -- core.ui.debug.overlaps (story 12): o.overlaps(handle) gives its results (default: nothing overlaps);
        -- o.overlaps = false: no debug table at all. Every call is recorded with its handle.
        if o.overlaps ~= false then
            local fake = o.overlaps or function() return {}, { rect = { l = 0, t = 0, r = 10, b = 10 }, screen = { w = 100, h = 100 } } end
            core.ui.debug = { overlaps = function(h, ...)
                core.overlapCalls[#core.overlapCalls + 1] = { handle = h, n = select("#", ...) }
                return fake(h)
            end }
        end
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
-- core's Journal events, and a press as core's button hook makes it (onClick(handle), on the game thread).
local function journalEvent(core, j, event) for _, fn in ipairs(core.jwatchers) do fn(event == "opened" and j or nil, { event = event, path = j and rawget(j, "_path"), reason = "test" }) end end
local function press(core, id) local b = core.buttons[id] b.spec.onClick(b.handle) end
local function nrefs(core) local n = 0 for _ in pairs(core.refs) do n = n + 1 end return n end
local function emit(core, hud, event) for _, fn in ipairs(core.watchers) do fn(hud, { event = event, path = type(hud) == "table" and rawget(hud, "_path") or nil, reason = "test" }) end end
local function lines(pat) local r = {} for _, l in ipairs(W.printed) do if l:find(pat) then r[#r + 1] = l end end return r end
local function count(pat) return #lines(pat) end

-- A match: the player's pawn with a HUD, two location waypoints and the satellite up, their flags.
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
    eq(W.printed[1], "[Waypoints] Nucleus is not installed. Waypoints will not run.", "no core: the line names the cause")
    eq(#S.connects, 0, "no core: no connect")
end
do
    boot()
    eq(#S.connects, 1, "connect called once")
    local c = S.connects[1]
    ok(c.mod == "Waypoints" and c.need == ">=0.6.0", "connect{ mod = 'Waypoints', need = '>=0.6.0' }", tostring(c.mod) .. " " .. tostring(c.need))
    eq(#W.printed, 0, "nothing printed during main.lua")
    c.onFail("Nucleus 0.5.0 is older than Waypoints needs (>=0.6.0). Update Nucleus.")
    eq(#W.printed, 0, "onFail adds no line (connect logged the cause)")
end
do -- core without HUD events: one ERROR, nothing registered.
    boot()
    local core = newCore{ hud = false }
    ready(core)
    eq(count("^%[Waypoints%] ERROR Nucleus's HUD events"), 1, "no core.ui.hud: one ERROR")
    eq(#W.loadMapHooks, 0, "no core.ui.hud: no hook")
end

-- ---------------------------------------------------------------- the revive, onRevive = restore (CAP-1)
do
    boot()
    local core = newCore()
    ready(core)
    eq(count("^%[Waypoints%] READY onRevive=restore buttons=yes$"), 1, "READY onRevive=restore buttons=yes")
    eq(#core.watchers, 1, "one HUD watcher")
    eq(#W.loadMapHooks, 1, "one LoadMap hook")
    match(core)
    eq(count("^%[Waypoints%] PAWN first .*BP_FirstPersonCharacter_C_1$"), 1, "PAWN first")
    dieAndRevive(core)
    eq(count("^%[Waypoints%] LOST pawn=.*_1 snapshot n=3 %(locations 2, satellite 1%)$"), 1, "LOST with the snapshot at the death")
    eq(count("^%[Waypoints%] REVIVE pawn=.*_2 was=.*_1 snapshot=3 onRevive=restore$"), 1, "REVIVE line")
    eq(#W.delayed, 1, "the restore is deferred (ExecuteInGameThreadWithDelay)")
    eq(W.delayed[1].ms, 500, "deferred by 500 ms")
    eq(#W.spawns, 0, "nothing spawned inside core's HUD tick")
    W.runDelayed()
    eq(count("^%[Waypoints%] RESTORED n=3 %(from actors 3, from the snapshot 0, failed 0, old destroyed 3%) flags=3 satelliteFlags=1$"), 1, "RESTORED line")
    local live = liveWaypoints()
    eq(#live, 3, "one waypoint actor per waypoint")
    local bound = true
    for _, a in ipairs(live) do if a._class.short == "LevelWaypointActor_C" and a.Character ~= W.p2 then bound = false end end
    ok(bound, "location waypoints bound to the new pawn")
    ok(W.fMed.Selected and W.fAir.Selected and W.fSat.Selected and not W.fRig.Selected, "flags match the waypoints")
    eq(count("bReplicates=false"), 3, "each RESTORE logs bReplicates=false")
    eq(count("WARN"), 0, "no WARN")
    eq(next(core.refs), nil, "the pawn's weak handle was freed")
    -- the new pawn's HUD rebuilt within the settle window: restored again (still one actor each)
    emit(core, nil, "lost"); core.advance(3); emit(core, W.hud2, "attached")
    eq(count("^%[Waypoints%] AGAIN pawn="), 1, "AGAIN within the settle window")
    W.runDelayed()
    eq(#liveWaypoints(), 3, "AGAIN: still exactly one actor per waypoint")
end

-- ---------------------------------------------------------------- onRevive = clear, and changed between revives
do
    boot{ settings = 'return { onRevive = "clear" }' }
    local core = newCore()
    ready(core)
    eq(count("READY onRevive=clear buttons=yes$"), 1, "READY onRevive=clear")
    match(core)
    dieAndRevive(core)
    W.runDelayed()
    eq(count("^%[Waypoints%] CLEARED n=3 %(failed 0%) flags=3 satelliteFlags=1$"), 1, "CLEARED line")
    eq(#liveWaypoints(), 0, "clear: no waypoint left")
    ok(not W.fMed.Selected and not W.fAir.Selected and not W.fSat.Selected, "clear: no flag selected")
    -- changeable anytime: switch to restore, place a waypoint, die and revive again
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
    eq(count("^%[Waypoints%] LOST pawn=.*_1 snapshot n=3 "), 1, "LOST with the snapshot")
    eq(count("^%[Waypoints%] RESTORED n=3 "), 1, "RESTORED n=3")
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
    eq(count("^%[Waypoints%] REBOUND pawn=.*_2 was=.*_1"), 1, "REBOUND line")
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
    eq(#liveWaypoints(), 3, "spectator: waypoints untouched")
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
    eq(count("^%[Waypoints%] ERROR") + count("traceback"), 0, "bad HUD: no error line")
    ok(count("WARN HUD event failed") <= 1, "bad HUD: at most one WARN")
    emit(core, nil, "shown"); emit(core, nil, "hidden")
    eq(count("REVIVE"), 0, "shown/hidden: nothing")
end

-- ---------------------------------------------------------------- Mark all and Clear all (story 3)
-- A map like Tower Island's: three location flags and the satellite flag in the open Journal.
local function mapFlags()
    W.fA, W.fB, W.fC, W.fS = W.flag("Weather Station"), W.flag("Crash Site"), W.flag("Construction Site"), W.satFlag()
    for _, f in ipairs({ W.fA, W.fB, W.fC, W.fS }) do f.Selected = false end
    return W.journal({ W.fA, W.fB, W.fC }, W.fS, W.p1)
end
do -- The panel and buttons, created before the Journal watcher; READY says buttons=yes.
    boot()
    local core = newCore()
    ready(core)
    eq(table.concat(core.seq, ","), "panel waypoints,button markAll,button clearAll,journal.watch", "panel, then the two buttons, then journal.watch")
    local p = core.panels[1].spec
    ok(p.place.host == "journal" and p.place.near == "map" and p.place.side == "below" and p.place.align == "center" and p.place.gap == "tight"
        and p.layout == "horizontal", "panel: journal, near the map, below, centred, tight gap, horizontal (story 5)")
    local keys = 0 for _ in pairs(p.place) do keys = keys + 1 end
    eq(keys, 5, "panel: the place has exactly host, near, side, align and gap")
    local m, c = core.buttons.markAll.spec, core.buttons.clearAll.spec
    eq(m.label, "Mark all", "button markAll labelled 'Mark all'")
    eq(c.label, "Clear all", "button clearAll labelled 'Clear all'")
    ok(m.place.panel == core.panels[1].handle and c.place.panel == core.panels[1].handle, "both buttons in the panel (place = { panel = handle })")
    ok(type(m.onClick) == "function" and type(c.onClick) == "function", "both buttons have an onClick")
    eq(#core.watchers, 1, "the HUD watcher still there (revive fix)")
end
do -- Map opened: a weak handle on the Journal, MAPSYNC; Mark all, Clear all; closed: freed; a press then: not open.
    boot()
    local core = newCore()
    ready(core)
    match(core) -- Medbay, Airport (no flag on this map: orphans) and the satellite up
    local j = mapFlags()
    journalEvent(core, j, "opened")
    eq(nrefs(core), 1, "opened: one weak handle (the Journal)")
    eq(count("^%[Waypoints%] MAPSYNC flags=3 selected=0 satellite=yes$"), 1, "opened: MAPSYNC")
    ok(W.fA.Character == W.p1 and W.fS.Selected == true, "opened: Character and Selected synced")
    press(core, "markAll")
    eq(count("^%[Waypoints%] MARKALL marked=3 already=1 failed=0 waypoints=6 flags=3 satellite=yes$"), 1, "Mark all: MARKALL")
    ok(W.fA.Selected and W.fB.Selected and W.fC.Selected, "Mark all: flags selected")
    press(core, "clearAll")
    eq(count("^%[Waypoints%] CLEARALL cleared=4 direct=2 failed=0 waypoints=0 flags=3$"), 1, "Clear all: CLEARALL (the two orphans directly)")
    eq(#liveWaypoints(), 0, "Clear all: nothing left")
    journalEvent(core, nil, "closed")
    eq(nrefs(core), 0, "closed: the handle freed")
    press(core, "markAll")
    eq(count("^%[Waypoints%] WARN Mark all skipped: the map is not open$"), 1, "a press after close: one WARN, nothing done")
    eq(#liveWaypoints(), 0, "a press after close: nothing marked")
    -- reopened: a new Journal, a new handle; then gone (lost) without a close
    journalEvent(core, mapFlags(), "opened")
    eq(nrefs(core), 1, "reopened: one handle")
    journalEvent(core, nil, "lost")
    eq(nrefs(core), 0, "lost: freed")
    -- opened, then the Journal is destroyed before the press: deref gives nil
    local j3 = mapFlags()
    journalEvent(core, j3, "opened")
    j3._gone = true
    press(core, "clearAll")
    eq(count("WARN Clear all skipped: the map is not open$"), 1, "Journal gone before the press: not open")
    -- two opens without a close in between: the old handle freed
    journalEvent(core, mapFlags(), "opened"); journalEvent(core, mapFlags(), "opened")
    eq(nrefs(core), 1, "opened twice: only the newest handle held")
    eq(count("ERROR"), 0, "no ERROR")
end
do -- core without panels/buttons/Journal: one ERROR, buttons=no, the revive fix still runs.
    boot()
    local core = newCore{ buttons = false }
    ready(core)
    eq(count("^%[Waypoints%] ERROR Nucleus's panels, buttons or Journal events .* not available"), 1, "no UI API: one ERROR")
    eq(count("^%[Waypoints%] READY onRevive=restore buttons=no$"), 1, "no UI API: READY buttons=no")
    match(core); dieAndRevive(core); W.runDelayed()
    eq(count("RESTORED n=3"), 1, "no UI API: the revive fix still restores")
end
do -- button.create raises: one ERROR, buttons=no, revive fix intact.
    boot()
    local core = newCore{ buttonThrows = true }
    ready(core)
    eq(count("^%[Waypoints%] ERROR could not set up Mark all / Clear all on the map: .*boom"), 1, "button.create raises: one ERROR")
    eq(count("READY onRevive=restore buttons=no$"), 1, "button.create raises: READY buttons=no")
    eq(#core.jwatchers, 0, "button.create raises: no Journal watcher")
    eq(core.seq[#core.seq], "panel.remove waypoints", "button.create raises: the half-made panel removed again")
end
do -- deref raising during a press: treated as not open, nothing done.
    boot()
    local core = newCore()
    ready(core)
    match(core)
    journalEvent(core, mapFlags(), "opened")
    local saved = core.deref
    core.deref = function() error("deref: boom") end
    press(core, "markAll")
    core.deref = saved
    eq(count("WARN Mark all skipped: the map is not open$"), 1, "deref raising: treated as not open")
    eq(count("MARKALL"), 0, "deref raising: nothing marked")
end

-- ---------------------------------------------------------------- the debug-only fit check (story 5, PANELFIT)
local PANEL_RECT = { l = 296, t = 840, r = 416, b = 876 }
local function fitInfo() return { rect = PANEL_RECT, screen = { w = 1280, h = 720 }, checked = 300, drawn = 80 } end
local function debugCore(o) -- booted with debug on and a match
    boot{ settings = 'return { onRevive = "restore", debug = true }' }
    local core = newCore(o)
    ready(core)
    match(core)
    return core
end
do -- Debug on: the open schedules one check 2500 ms later; it calls overlaps(panel) once and logs PANELFIT + PANELHIT.
    local core = debugCore{ overlaps = function()
        return {
            { path = "/J.Paper", class = "Image", rect = { l = 87, t = 72, r = 625, b = 598 + 400 } },
            { path = "/J.MapUI.Frame", class = "Image", rect = { l = 100, t = 100, r = 400, b = 850 } },
            { path = "/J.Perk", class = "Image", rect = { l = 400, t = 860, r = 450, b = 900 } },
        }, fitInfo()
    end }
    eq(#W.delayed, 0, "debug on: nothing scheduled before the map opens")
    journalEvent(core, mapFlags(), "opened")
    eq(#W.delayed, 1, "debug on, opened: one check scheduled")
    eq(W.delayed[1] and W.delayed[1].ms, 2500, "debug on: the check runs 2500 ms after the open")
    eq(#core.overlapCalls, 0, "debug on: overlaps not called inside the open event")
    W.runDelayed()
    eq(#core.overlapCalls, 1, "debug on: overlaps called once")
    ok(core.overlapCalls[1].handle == core.panels[1].handle and core.overlapCalls[1].n == 0, "debug on: overlaps(panel handle), one argument")
    eq(count("^%[Waypoints%] PANELFIT rect=%(296,840%)%-%(416,876%) screen=1280x720 hits=3 partial=2$"), 1, "PANELFIT line: rect, screen, hits, partial")
    eq(count("^%[Waypoints%] PANELHIT "), 3, "one PANELHIT per hit")
    eq(count("^%[Waypoints%] PANELHIT under Image /J%.Paper %(87,72%)%-%(625,998%)$"), 1, "PANELHIT under: the page paper containing the panel")
    eq(count("^%[Waypoints%] PANELHIT partial Image /J%.Perk %(400,860%)%-%(450,900%)$"), 1, "PANELHIT partial: a widget cutting into the panel")
    eq(#W.delayed, 0, "debug on: nothing more scheduled after a result")
    eq(count("WARN") + count("ERROR"), 0, "debug on: no WARN or ERROR")
end
do -- More than 10 hits: at most 10 PANELHIT lines, the partial ones first.
    local core = debugCore{ overlaps = function()
        local list = {}
        for i = 1, 12 do list[i] = { path = "/J.Under" .. i, class = "Image", rect = { l = 0, t = 0, r = 2000, b = 2000 } } end
        list[13] = { path = "/J.Cut", class = "Border", rect = { l = 300, t = 800, r = 350, b = 850 } }
        return list, fitInfo()
    end }
    journalEvent(core, mapFlags(), "opened")
    W.runDelayed()
    eq(count("PANELFIT rect=.* hits=13 partial=1$"), 1, "13 hits, 1 partial")
    eq(count("PANELHIT "), 10, "at most 10 PANELHIT lines")
    ok((lines("PANELHIT ")[1] or ""):find("PANELHIT partial Border /J.Cut", 1, true) ~= nil, "the partial hit is listed first")
end
do -- Not painted yet: retried every 1000 ms up to 3 times, then PANELFIT none (<reason>).
    local core = debugCore{ overlaps = function() return nil, "not painted yet (no on-screen geometry)" end }
    journalEvent(core, mapFlags(), "opened")
    local delays = {}
    for _ = 1, 6 do
        if #W.delayed == 0 then break end
        delays[#delays + 1] = W.delayed[1].ms
        W.runDelayed()
    end
    eq(table.concat(delays, ","), "2500,1000,1000,1000", "not painted: the first try, then 3 retries 1000 ms apart")
    eq(#core.overlapCalls, 4, "not painted: overlaps called 4 times")
    eq(count("^%[Waypoints%] PANELFIT none %(not painted yet %(no on%-screen geometry%)%)$"), 1, "not painted: one PANELFIT none naming the reason")
    eq(count("PANELFIT rect="), 0, "not painted: no PANELFIT rect line")
end
do -- Painted on the second try: one retry, then the PANELFIT line.
    local n = 0
    local core = debugCore{ overlaps = function() n = n + 1 if n == 1 then return nil, "not painted yet" end return {}, fitInfo() end }
    journalEvent(core, mapFlags(), "opened")
    W.runDelayed(); W.runDelayed()
    eq(count("PANELFIT rect=.* hits=0 partial=0$"), 1, "painted on the retry: PANELFIT hits=0 partial=0")
    eq(count("PANELFIT none"), 0, "painted on the retry: no PANELFIT none")
end
do -- Stale: closed before the check, or a newer open: nothing logged for the old open.
    local core = debugCore{ overlaps = function() return {}, fitInfo() end }
    journalEvent(core, mapFlags(), "opened")
    journalEvent(core, nil, "closed")
    W.runDelayed()
    eq(#core.overlapCalls, 0, "closed before the check: overlaps not called")
    eq(count("PANELFIT"), 0, "closed before the check: nothing logged")
    journalEvent(core, mapFlags(), "opened")
    journalEvent(core, nil, "lost")
    W.runDelayed()
    eq(count("PANELFIT"), 0, "lost before the check: nothing logged")
    journalEvent(core, mapFlags(), "opened")
    journalEvent(core, mapFlags(), "opened")
    eq(#W.delayed, 2, "two opens: two checks queued")
    W.runDelayed()
    eq(#core.overlapCalls, 1, "two opens: only the newer check calls overlaps")
    eq(count("PANELFIT rect="), 1, "two opens: one PANELFIT line")
end
do -- Stale during the retries: a close between two tries stops them.
    local core = debugCore{ overlaps = function() return nil, "not painted yet" end }
    journalEvent(core, mapFlags(), "opened")
    W.runDelayed()
    journalEvent(core, nil, "closed")
    W.runDelayed()
    eq(#core.overlapCalls, 1, "closed between retries: no further overlaps call")
    eq(count("PANELFIT"), 0, "closed between retries: nothing logged")
end
do -- overlaps throws: one WARN for the session, nothing else breaks.
    local core = debugCore{ overlaps = function() error("nucleus.ui.debug.overlaps: boom") end }
    journalEvent(core, mapFlags(), "opened"); W.runDelayed()
    journalEvent(core, mapFlags(), "opened"); W.runDelayed()
    eq(count("^%[Waypoints%] WARN PANELFIT check failed: .*boom"), 1, "overlaps throwing: one WARN")
    eq(count("ERROR"), 0, "overlaps throwing: no ERROR")
    press(core, "markAll")
    eq(count("^%[Waypoints%] MARKALL "), 1, "overlaps throwing: Mark all still works")
end
do -- Debug off: no scheduling, no overlaps call.
    boot()
    local core = newCore{ overlaps = function() return {}, fitInfo() end }
    ready(core)
    match(core)
    journalEvent(core, mapFlags(), "opened")
    eq(#W.delayed, 0, "debug off: nothing scheduled on open")
    journalEvent(core, nil, "closed"); journalEvent(core, mapFlags(), "opened")
    eq(#W.delayed, 0, "debug off: still nothing on a reopen")
    eq(#core.overlapCalls, 0, "debug off: overlaps never called")
    eq(count("PANELFIT"), 0, "debug off: no PANELFIT line")
end
do -- Debug on but core without ui.debug: nothing scheduled, no error.
    local core = debugCore{ overlaps = false }
    journalEvent(core, mapFlags(), "opened")
    eq(#W.delayed, 0, "no ui.debug: nothing scheduled")
    eq(count("PANELFIT") + count("WARN") + count("ERROR"), 0, "no ui.debug: no line")
end

loadfile = realLoadfile
H.done()

