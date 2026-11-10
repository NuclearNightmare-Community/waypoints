-- mapbuttons.lua: what Mark all, Clear all and each map open do to the open Journal's flags (markers spec CAP-2). Pure
-- logic over an adapter G (game.lua in the game, a fake in the unit tests), like waypoints.lua:
--   G.journalFlags(journal) -> { locations = { { widget, name }, ... }, satellite = widget | nil }   (raises if unreadable)
--   G.journalPawn(journal)  -> pawn | nil, className    (pawn only when alive)
--   G.worldOf(obj)          -> the world key G.waypoints filters by
--   G.waypoints(world)      -> { { kind, name, obj }, ... }: the live waypoint actors (one FindAllOf pass per action)
--   G.alive(obj), G.destroy(obj)
--   G.setCharacter(widget, pawn), G.clickFlag(widget), G.clickSat(widget), G.selected(widget), G.setSelected(widget, on)
-- Truth is the actor (SPEC): a location flag is selected exactly when a live LevelWaypointActor_C with its Name exists
-- (case-insensitive), the satellite flag when any live SatelliteWaypoint_C does. Mark and clear go through the flags'
-- own click handlers, so the game spawns, names and destroys the waypoints itself; only an actor no click removed is
-- destroyed directly. Every game call is protected: a failure is one log line and leaves the game's state as it was.
-- Holds nothing between calls: the Journal, its flags and the actors are passed in or read again on every call.
local waypoints = require("waypoints")

local M = {}
local SAT_KEY = waypoints.SAT_KEY
local FP_CLASS = "BP_FirstPersonCharacter_C"

local function firstLine(e) return (tostring(e):match("^[^\n]*")) end

-- One WARN per distinct message for the map-open sync (it runs on every open; a lasting fault would repeat).
M._said = {}
local function warnOnce(log, fmt, ...)
    local msg = string.format(fmt, ...)
    if M._said[msg] then return end
    M._said[msg] = true
    log.warn("%s", msg)
end

-- The flags as the actions need them: clickers (one per distinct location key, the first widget of that name in
-- MapUI_C.Levels order), every location widget with its key (Selected follows every one of them), the satellite widget.
local function readFlags(G, journal)
    local f = G.journalFlags(journal)
    local all, clickers, byKey = {}, {}, {}
    for _, e in ipairs(f.locations or {}) do
        local k = waypoints.key("location", e.name)
        all[#all + 1] = { widget = e.widget, key = k, name = e.name }
        if not byKey[k] then
            byKey[k] = { widget = e.widget, key = k, name = e.name }
            clickers[#clickers + 1] = byKey[k]
        end
    end
    return { all = all, clickers = clickers, byKey = byKey, satellite = f.satellite }
end

-- The live waypoint actors of the pawn's world, grouped by key: list, byKey (waypoints.group). nil, err if unreadable.
local function readActors(G, worldOf)
    local world
    if worldOf ~= nil then
        local okW, w = pcall(G.worldOf, worldOf)
        if okW then world = w end
    end
    local ok, recs = pcall(G.waypoints, world)
    if not ok then return nil, nil, firstLine(recs) end
    local list, byKey = waypoints.group(recs)
    return list, byKey
end

local function liveCount(G, groups)
    local n = 0
    for _, g in ipairs(groups or {}) do
        for _, a in ipairs(g.actors) do
            local ok, live = pcall(G.alive, a)
            if ok and live then n = n + 1 end
        end
    end
    return n
end

-- Character = pawn on every location flag widget (the satellite flag has none). Returns the number that failed.
local function setCharacters(G, flags, pawn)
    local failed = 0
    for _, e in ipairs(flags.all) do
        if not pcall(G.setCharacter, e.widget, pawn) then failed = failed + 1 end
    end
    return failed
end

-- Every flag widget's Selected = present[key]. Returns the number of distinct location keys shown selected and
-- whether the satellite flag is ("yes" | "no" | "none"), and the number of widgets that couldn't be set.
local function syncSelected(G, flags, present)
    local failed = 0
    for _, e in ipairs(flags.all) do
        if not pcall(G.setSelected, e.widget, present[e.key] == true) then failed = failed + 1 end
    end
    local sel = 0
    for _, c in ipairs(flags.clickers) do if present[c.key] then sel = sel + 1 end end
    local sat = "none"
    if flags.satellite ~= nil then
        if not pcall(G.setSelected, flags.satellite, present[SAT_KEY] == true) then failed = failed + 1 end
        sat = present[SAT_KEY] and "yes" or "no"
    end
    return sel, sat, failed
end

-- The common start of Mark all and Clear all: the open Journal, its flags and a usable pawn, or nil after one WARN.
local function prepare(G, journal, label, log)
    if journal == nil then log.warn("%s skipped: the map is not open", label) return nil end
    local okP, pawn, cls = pcall(G.journalPawn, journal)
    if not okP then log.warn("%s skipped: could not read the map's character (%s)", label, firstLine(pawn)) return nil end
    if pawn == nil or cls ~= FP_CLASS then
        log.warn("%s skipped: the map's character is %s, not a live %s", label, tostring(cls), FP_CLASS)
        return nil
    end
    local okF, flags = pcall(readFlags, G, journal)
    if not okF then log.warn("%s skipped: could not read the map's flags (%s)", label, firstLine(flags)) return nil end
    local bad = setCharacters(G, flags, pawn)
    if bad > 0 then log.warn("%s: could not set the character on %d flag(s)", label, bad) end
    return pawn, flags
end

-- One click on a flag that has no waypoint: it should spawn one (the handler sets Selected = true only then).
local function markOne(G, widget, click)
    pcall(G.setSelected, widget, false)
    local ok, err = pcall(click, widget)
    if not ok then return false, firstLine(err) end
    local okS, sel = pcall(G.selected, widget)
    if okS and sel then return true end
    return false, "the click spawned no waypoint"
end

-- Mark all: every flag key without a live waypoint actor is clicked once (one click per key: duplicate-name flags share
-- it); keys that already have one are left alone (no second waypoint). Then every flag's Selected follows the actors.
-- Returns { marked, already, failed, waypoints, flags, satellite } or nil (logged).
function M.markAll(G, journal, log)
    local pawn, flags = prepare(G, journal, "Mark all", log)
    if not pawn then return nil end
    local groups, byKey, err = readActors(G, pawn)
    if not groups then log.warn("Mark all skipped: could not read the waypoint actors (%s)", err) return nil end
    local res = { marked = 0, already = 0, failed = 0, flags = #flags.clickers }
    local present = {}
    for k in pairs(byKey) do present[k] = true end
    for _, c in ipairs(flags.clickers) do
        if byKey[c.key] then
            res.already = res.already + 1
        else
            local ok, why = markOne(G, c.widget, G.clickFlag)
            if ok then
                res.marked, present[c.key] = res.marked + 1, true
                log.info("MARK location '%s'", c.name)
            else
                res.failed = res.failed + 1
                log.warn("MARK location '%s' failed (%s); left as the game had it", c.name, why)
            end
        end
    end
    if flags.satellite ~= nil then
        if byKey[SAT_KEY] then
            res.already = res.already + 1
        else
            local ok, why = markOne(G, flags.satellite, G.clickSat)
            if ok then
                res.marked, present[SAT_KEY] = res.marked + 1, true
                log.info("MARK satellite")
            else
                res.failed = res.failed + 1
                log.warn("MARK satellite failed (%s); left as the game had it", why)
            end
        end
    end
    -- The waypoints up now: the earlier actors still alive, plus one per successful click (the click's own actor).
    res.waypoints = liveCount(G, groups) + res.marked
    local _, sat, bad = syncSelected(G, flags, present)
    if bad > 0 then log.warn("Mark all: could not set Selected on %d flag(s)", bad) end
    res.satellite = sat
    log.info("MARKALL marked=%d already=%d failed=%d waypoints=%d flags=%d satellite=%s",
        res.marked, res.already, res.failed, res.waypoints, res.flags, res.satellite)
    return res
end

-- The live actors of a group, now.
local function stillAlive(G, actors)
    local out = {}
    for _, a in ipairs(actors) do
        local ok, live = pcall(G.alive, a)
        if ok and live then out[#out + 1] = a end
    end
    return out
end

-- Clear all: every live waypoint actor goes. A flag's click destroys only the first actor with its name, so the flag is
-- clicked once per live actor of its key (never more: each click must remove one, else the clicking stops, so a
-- click can't put a new waypoint up). An actor still alive afterwards, or one whose flag isn't on this map, is
-- destroyed directly. Then every flag's Selected follows the actors.
-- Returns { cleared, direct, failed, waypoints, flags } or nil (logged).
function M.clearAll(G, journal, log)
    local pawn, flags = prepare(G, journal, "Clear all", log)
    if not pawn then return nil end
    local groups, _, err = readActors(G, pawn)
    if not groups then log.warn("Clear all skipped: could not read the waypoint actors (%s)", err) return nil end
    local res = { cleared = 0, direct = 0, failed = 0, flags = #flags.clickers }
    local present = {}
    for _, g in ipairs(groups) do
        local what = g.kind == "satellite" and "satellite" or ("location '" .. g.name .. "'")
        local widget, click
        if g.kind == "satellite" then widget, click = flags.satellite, G.clickSat
        else local c = flags.byKey[g.key]; widget, click = c and c.widget, G.clickFlag end
        local left = stillAlive(G, g.actors)
        local clickFailed = false
        if widget ~= nil then
            for _ = 1, #g.actors do
                if #left == 0 then break end
                local ok, e = pcall(click, widget)
                local now = stillAlive(G, g.actors)
                if not ok then
                    clickFailed = true
                    log.warn("CLEAR %s: the flag's click failed (%s)", what, firstLine(e))
                    left = now
                    break
                end
                if #now >= #left then
                    clickFailed = true
                    log.warn("CLEAR %s: the flag's click removed no waypoint; stopped clicking", what)
                    left = now
                    break
                end
                res.cleared = res.cleared + (#left - #now)
                left = now
            end
        end
        if clickFailed then res.failed = res.failed + 1 end
        local kept = 0
        for _, a in ipairs(left) do
            local ok, e = pcall(G.destroy, a)
            local okA, live = pcall(G.alive, a)
            if ok and okA and not live then
                res.direct = res.direct + 1
            else
                kept = kept + 1
                res.failed = res.failed + 1
                log.warn("CLEAR %s: could not destroy a waypoint (%s); left as it was", what, ok and "still alive" or firstLine(e))
            end
        end
        if kept > 0 then present[g.key] = true
        else log.info("CLEAR %s", what) end
    end
    res.waypoints = liveCount(G, groups)
    local _, _, bad = syncSelected(G, flags, present)
    if bad > 0 then log.warn("Clear all: could not set Selected on %d flag(s)", bad) end
    log.info("CLEARALL cleared=%d direct=%d failed=%d waypoints=%d flags=%d",
        res.cleared, res.direct, res.failed, res.waypoints, res.flags)
    return res
end

-- A map open: Character = the Journal's pawn on every location flag (when it is a live first-person character), and
-- every flag's Selected = whether a live waypoint actor has its key. Returns { flags, selected, satellite } or nil.
function M.syncOnOpen(G, journal, log)
    if journal == nil then return nil end
    local okF, flags = pcall(readFlags, G, journal)
    if not okF then warnOnce(log, "map open: could not read the map's flags (%s)", firstLine(flags)) return nil end
    local okP, pawn, cls = pcall(G.journalPawn, journal)
    if okP and pawn ~= nil and cls == FP_CLASS then
        local bad = setCharacters(G, flags, pawn)
        if bad > 0 then warnOnce(log, "map open: could not set the character on %d flag(s)", bad) end
    else
        pawn = nil
    end
    local groups, byKey, err = readActors(G, pawn or journal)
    if not groups then warnOnce(log, "map open: could not read the waypoint actors (%s)", err) return nil end
    local present = {}
    for k in pairs(byKey) do present[k] = true end
    local sel, sat, bad = syncSelected(G, flags, present)
    if bad > 0 then warnOnce(log, "map open: could not set Selected on %d flag(s)", bad) end
    log.info("MAPSYNC flags=%d selected=%d satellite=%s", #flags.clickers, sel, sat)
    return { flags = #flags.clickers, selected = sel, satellite = sat }
end

return M
