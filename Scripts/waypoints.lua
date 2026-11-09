-- waypoints.lua: what a revive does to the waypoints (markers spec CAP-1). Pure logic over an adapter G (game.lua in the
-- game, a fake in the unit tests), so every decision here is tested outside the game:
--   G.waypoints(world) -> { { kind = "location"|"satellite", name, loc = { X, Y, Z }, obj }, ... }: the live waypoint
--                         actors of that world (LevelWaypointActor_C, SatelliteWaypoint_C)
--   G.spawn(entry, pawn, template) -> obj, { replicates = bool|nil, via = string }: a new waypoint actor for entry, as
--                         the flag's own click spawns it; template is an old actor of the same kind (for its class) or nil
--   G.destroy(obj)
--   G.syncFlags(pawn, present, newByKey) -> nLocationFlags, nSatelliteFlags: every flag's Selected = present[key]
-- Truth is the actor (SPEC): a waypoint is up exactly when a waypoint actor with its Name exists. Each call is protected:
-- a failure is logged once with its context and leaves the game's own state as it was.
local M = {}

M.SAT_KEY = "#satellite" -- the satellite's key; never a location's (location keys are names, lower-cased)

-- The key flags and actors are matched by: the game compares names case-insensitively (EqualEqual_IgnoreCase_TextText).
function M.key(kind, name)
    if kind == "satellite" then return M.SAT_KEY end
    return (tostring(name or "")):lower()
end

-- Groups waypoint records by key, in first-seen order: { { kind, name, key, loc, actors = { obj, ... } }, ... }.
function M.group(records)
    local list, byKey = {}, {}
    for _, r in ipairs(records or {}) do
        if (r.kind == "location" or r.kind == "satellite") and (r.kind == "satellite" or (type(r.name) == "string" and r.name ~= "")) then
            local k = M.key(r.kind, r.name)
            local g = byKey[k]
            if not g then
                g = { kind = r.kind, name = r.kind == "satellite" and "Satellite" or r.name, key = k, loc = r.loc, actors = {} }
                byKey[k] = g
                list[#list + 1] = g
            end
            g.actors[#g.actors + 1] = r.obj
        end
    end
    return list, byKey
end

-- The waypoints up now, as plain data (no UObjects): { { kind, name, key, loc }, ... }, or nil when they can't be read.
function M.snapshot(G, world, log)
    local ok, recs = pcall(G.waypoints, world)
    if not ok then
        if log then log.warn("snapshot: could not read the waypoint actors (%s)", tostring(recs)) end
        return nil
    end
    local out = {}
    for _, g in ipairs((M.group(recs))) do
        local loc = g.loc and { X = g.loc.X, Y = g.loc.Y, Z = g.loc.Z } or nil
        out[#out + 1] = { kind = g.kind, name = g.name, key = g.key, loc = loc }
    end
    return out
end

-- What a restore brings back: every waypoint with a live actor (the truth), plus every waypoint of the snapshot taken at
-- the death that has none any more (source "snapshot": respawned where it was). Nothing else.
function M.plan(groups, snapshot)
    local entries, seen = {}, {}
    for _, g in ipairs(groups or {}) do
        entries[#entries + 1] = { kind = g.kind, name = g.name, key = g.key, loc = g.loc, actors = g.actors, source = "actor" }
        seen[g.key] = true
    end
    for _, s in ipairs(snapshot or {}) do
        local k = s.key or M.key(s.kind, s.name)
        if not seen[k] and (s.kind == "location" or s.kind == "satellite") and type(s.loc) == "table" then
            entries[#entries + 1] = { kind = s.kind, name = s.name, key = k, loc = s.loc, actors = {}, source = "snapshot" }
            seen[k] = true
        end
    end
    return entries
end

local function counts(snapshot)
    local l, s = 0, 0
    for _, e in ipairs(snapshot or {}) do if e.kind == "satellite" then s = s + 1 else l = l + 1 end end
    return l, s
end
M.counts = counts

-- Restore (onRevive = restore): every waypoint that was up gets a fresh waypoint actor bound to the new pawn, spawned
-- the way its flag's click spawns one; only once the new one exists is the old one destroyed, so a failed spawn leaves
-- the waypoint exactly as the game left it. Duplicates of one name collapse into one actor. Then every flag's Selected
-- is set from what is up. Returns { respawned, fromActors, fromSnapshot, failed, destroyed, flags, satFlags } or nil.
function M.restore(G, pawn, world, snapshot, log)
    local ok, recs = pcall(G.waypoints, world)
    if not ok then log.warn("restore: could not read the waypoint actors (%s); nothing done", tostring(recs)) return nil end
    local groups = M.group(recs)
    local entries = M.plan(groups, snapshot)
    local res = { respawned = 0, fromActors = 0, fromSnapshot = 0, failed = 0, destroyed = 0, destroyFailed = 0, flags = 0, satFlags = 0 }
    local present, newByKey = {}, {}
    for _, e in ipairs(entries) do
        local okS, obj, info = pcall(G.spawn, e, pawn, e.actors[1])
        if okS and obj ~= nil then
            present[e.key], newByKey[e.key] = true, obj
            res.respawned = res.respawned + 1
            if e.source == "snapshot" then res.fromSnapshot = res.fromSnapshot + 1 else res.fromActors = res.fromActors + 1 end
            for _, old in ipairs(e.actors) do
                local okD, err = pcall(G.destroy, old)
                if okD then res.destroyed = res.destroyed + 1
                else res.destroyFailed = res.destroyFailed + 1; log.warn("restore: could not destroy the old waypoint of '%s' (%s)", e.name, tostring(err)) end
            end
            info = type(info) == "table" and info or {}
            log.info("RESTORE %s '%s' %s bReplicates=%s via %s%s", e.kind, e.name,
                e.source == "snapshot" and "respawned from the snapshot" or "respawned", tostring(info.replicates), tostring(info.via),
                #e.actors > 1 and (" (" .. #e.actors .. " old actors collapsed into one)") or "")
        else
            res.failed = res.failed + 1
            if #e.actors > 0 then present[e.key] = true end -- the old actor stays up: so does its flag
            log.warn("RESTORE %s '%s' failed (%s); left as the game had it", e.kind, e.name, tostring(okS and "no actor returned" or obj))
        end
    end
    local okF, nl, ns = pcall(G.syncFlags, pawn, present, newByKey)
    if okF then res.flags, res.satFlags = nl or 0, ns or 0
    else log.warn("restore: could not update the map's flags (%s)", tostring(nl)) end
    return res
end

-- Clear (onRevive = clear): every waypoint actor is destroyed and every flag deselected. A failed destroy leaves that
-- waypoint up, and its flag selected. Returns { cleared, failed, flags, satFlags } or nil.
function M.clear(G, pawn, world, log)
    local ok, recs = pcall(G.waypoints, world)
    if not ok then log.warn("clear: could not read the waypoint actors (%s); nothing done", tostring(recs)) return nil end
    local res = { cleared = 0, failed = 0, flags = 0, satFlags = 0 }
    local present = {}
    for _, g in ipairs((M.group(recs))) do
        local failed = false
        for _, obj in ipairs(g.actors) do
            local okD, err = pcall(G.destroy, obj)
            if not okD then failed = true; log.warn("CLEAR %s '%s' failed (%s); left as it was", g.kind, g.name, tostring(err)) end
        end
        if failed then res.failed = res.failed + 1; present[g.key] = true
        else res.cleared = res.cleared + 1; log.info("CLEAR %s '%s'", g.kind, g.name) end
    end
    local okF, nl, ns = pcall(G.syncFlags, pawn, present, {})
    if okF then res.flags, res.satFlags = nl or 0, ns or 0
    else log.warn("clear: could not update the map's flags (%s)", tostring(nl)) end
    return res
end

return M
