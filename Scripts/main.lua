-- Waypoints 0.1.0 (spec-markers-v1, story 2): after a revive, the map waypoints the player had up show their on-screen
-- waypoints again (onRevive = restore, the default), or every waypoint is cleared (onRevive = clear).
-- Runs on Nucleus (core) through the dependent bootstrap (core's api-contract.md) and uses only core's public API:
-- connect, core.log, core.ui.hud.watch (HUD events), core.ref/deref/free (weak handles), core.clock.micros.
-- Local only (scope client): the waypoint actors are local and unreplicated; no RPC, no chat, no replicated actor, and
-- nothing read from another player. Holds no UObject between callbacks (AGENTS.md): revive.lua sees plain facts, the
-- deferred action re-finds the new pawn through a weak handle. No per-tick work: it acts on HUD events only.
local CORE, NEED, ME = "Nucleus", ">=0.2.0", "Waypoints"
local DELAY_MS = 500 -- after the revive's HUD event, so the game has finished possessing the new pawn
local SNAPSHOT_MS = 50 -- the snapshot at the death runs this much later, outside core's HUD tick (it costs about 2 ms)

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local scriptDir = source:match("^(.*)[/\\]") or "."

-- ---------------------------------------------------------------- the dependent bootstrap (core's api-contract.md)
local mods = source:match("^(.*)[/\\][^/\\]+[/\\][Ss]cripts[/\\]") or "."
package.path = scriptDir .. "/?.lua;" .. package.path .. ";" .. mods .. "/" .. CORE .. "/Scripts/?.lua"
local ok, client = pcall(require, CORE:lower() .. ".client")
if not ok then print(("[%s] %s is not installed. %s will not run.\n"):format(ME, CORE, ME)) return end

local revive = require("revive")
local waypoints = require("waypoints")
local game = require("game")

-- ---------------------------------------------------------------- settings
-- deploy.ps1 generates Scripts/settings.lua from mod.json (onRevive: restore | clear). Until core's settings service
-- exists the mod reads it there; it is read again at every revive, so a changed onRevive takes effect at the next one
-- (changeable "anytime"). Problems are only remembered here and logged once connected (one [Waypoints] line without core).
local VALUES = { restore = true, clear = true }
local function loadSettings()
    local s = { onRevive = "restore", debug = false }
    local chunk, err = loadfile(scriptDir .. "/settings.lua", "t", {})
    if not chunk then return s, "settings.lua could not be read (" .. tostring(err) .. "); run deploy.ps1. Using onRevive = restore" end
    local okS, t = pcall(chunk)
    if not okS or type(t) ~= "table" then return s, "settings.lua did not return a table (" .. tostring(t) .. "); using onRevive = restore" end
    local problem
    if VALUES[t.onRevive] then s.onRevive = t.onRevive
    elseif t.onRevive ~= nil then problem = "onRevive must be restore or clear, got " .. tostring(t.onRevive) .. "; using restore" end
    s.debug = t.debug == true -- DEBUG lines: deploy.ps1 -Test
    return s, problem
end
local settings, settingsProblem = loadSettings()

-- ---------------------------------------------------------------- the revive fix (story 2)
local function start(core)
    local log = core.log
    log.debugEnabled = settings.debug
    local said = {}
    local function sayOnce(p) if p and not said[p] then said[p] = true; log.warn("%s", p) end end
    sayOnce(settingsProblem)
    local hud = type(core.ui) == "table" and type(core.ui.hud) == "table" and core.ui.hud or nil
    if not (hud and type(hud.watch) == "function") then
        log.error("%s's HUD events (core.ui.hud.watch) are not available. %s will not run.", CORE, ME)
        return
    end
    local micros = type(core.clock) == "table" and core.clock.micros or nil
    local function now() if micros then local okM, us = pcall(micros) if okM and us then return us / 1e6 end end return os.time() end

    local R = revive.new()

    -- Runs a revive's action on the new pawn: "revive" means the onRevive setting (read now), "restore" always restores.
    local function run(action, pawn, snapshot)
        if action == "revive" then
            local s, problem = loadSettings()
            sayOnce(problem)
            action = s.onRevive
        end
        local world = game.worldOf(pawn)
        if action == "clear" then
            local r = waypoints.clear(game, pawn, world, log)
            if r then log.info("CLEARED n=%d (failed %d) flags=%d satelliteFlags=%d", r.cleared, r.failed, r.flags, r.satFlags) end
        else
            local r = waypoints.restore(game, pawn, world, snapshot, log)
            if r then
                log.info("RESTORED n=%d (from actors %d, from the snapshot %d, failed %d, old destroyed %d) flags=%d satelliteFlags=%d",
                    r.respawned, r.fromActors, r.fromSnapshot, r.failed, r.destroyed, r.flags, r.satFlags)
            end
        end
    end

    -- The action runs DELAY_MS later on the game thread, outside core's HUD tick. The pawn crosses that gap as a weak
    -- handle (or its path, found again only if handles are unavailable), never as a UObject.
    local function schedule(action, pawn, pawnPath, snapshot)
        local handle
        if type(core.ref) == "function" then
            local okR, h = pcall(core.ref, pawn)
            if okR then handle = h end
        end
        local function go()
            local okG, err = pcall(function()
                local p
                if handle ~= nil then p = core.deref(handle); pcall(core.free, handle)
                else
                    local o = StaticFindObject(pawnPath)
                    if game.valid(o) then p = o end
                end
                if not game.valid(p) then log.warn("the new pawn %s was gone before the %s could run; nothing done", pawnPath, action) return end
                run(action, p, snapshot)
            end)
            if not okG then log.error("%s failed: %s", action, tostring(err)) end
        end
        local okL = type(ExecuteInGameThreadWithDelay) == "function" and pcall(ExecuteInGameThreadWithDelay, DELAY_MS, go)
        if not okL then go() end -- no delayed call available: run now (still the game thread)
    end

    local function onHud(h, info)
        local event = type(info) == "table" and info.event or nil
        if event == "lost" then
            -- The snapshot is read SNAPSHOT_MS later, outside core's HUD tick. revive.lua keeps this same (empty) list
            -- and the deferred read fills it in place, so a revive that comes first still gets it by the time its own
            -- action runs (DELAY_MS later, queued after this). The waypoint actors survive the death (spectator).
            local snap
            if R:wantsSnapshot() then snap = {} end
            local d = R:lost(snap)
            if not (d.kind == "lost" and d.first and snap) then return end
            local world, pawn = R.world, d.pawn
            local function take()
                local okT, err = pcall(function()
                    for _, e in ipairs(waypoints.snapshot(game, world, log) or {}) do snap[#snap + 1] = e end
                    local l, s = waypoints.counts(snap)
                    log.info("LOST pawn=%s snapshot n=%d (locations %d, satellite %d)", pawn, l + s, l, s)
                end)
                if not okT then log.error("snapshot failed: %s", tostring(err)) end
            end
            local okL = type(ExecuteInGameThreadWithDelay) == "function" and pcall(ExecuteInGameThreadWithDelay, SNAPSHOT_MS, take)
            if not okL then take() end
            return
        end
        if event ~= "attached" then return end
        local f = game.pawnFacts(h)
        f.now = now()
        local d = R:attached(f)
        if d.kind == "first" then
            log.info("PAWN first %s", d.pawn)
        elseif d.kind == "notfp" then
            log.info("PAWN %s (%s) is not a first-person character: not a revive", tostring(d.pawn), tostring(d.class))
        elseif d.kind == "same" or d.kind == "back" then
            log.debug("PAWN %s %s", d.kind, d.pawn)
        elseif d.kind == "revive" then
            local l, s = waypoints.counts(d.snapshot)
            log.info("REVIVE pawn=%s was=%s snapshot=%d onRevive=%s", d.pawn, d.was, l + s, (loadSettings()).onRevive)
            schedule(d.action, f.pawn, d.pawn, d.snapshot)
        elseif d.kind == "rebound" then
            log.info("REBOUND pawn=%s was=%s (a new pawn without a HUD loss: restore only, never clear)", d.pawn, d.was)
            schedule(d.action, f.pawn, d.pawn, nil)
        elseif d.kind == "again" then
            log.info("AGAIN pawn=%s (its HUD came back within %d s of the revive: running %s again)", d.pawn, R.settle, d.action)
            schedule(d.action, f.pawn, d.pawn, nil)
        end
    end

    local okW, token = pcall(hud.watch, function(h, info)
        local okH, err = pcall(onHud, h, info)
        if not okH then sayOnce("HUD event failed: " .. tostring(err)) end
    end)
    if not okW then log.error("could not watch the HUD: %s. %s will not run.", tostring(token), ME) return end
    -- A map change destroys every waypoint actor with the old world: forget the old pawn and snapshot.
    pcall(RegisterLoadMapPostHook, function() R:loadMap() end)
    log.info("READY onRevive=%s", settings.onRevive)
end

client.connect{
    mod = ME, need = NEED,
    onReady = function(core)
        local okR, err = pcall(start, core)
        if not okR then print(("[%s] ERROR start failed: %s\n"):format(ME, tostring(err))) end
    end,
    -- connect has already logged the one line naming the cause (CAP-4: exactly one [Waypoints] line). Nothing to add.
    onFail = function() end,
}
