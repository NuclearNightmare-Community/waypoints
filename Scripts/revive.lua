-- revive.lua: decides, from core's HUD events alone, when the local player has been revived (markers spec, "Revive
-- trigger"). Pure Lua: it sees plain facts (strings and numbers) that main.lua reads inside core's HUD callback, never a
-- UObject, so it holds nothing across callbacks and runs outside the game in the unit tests.
--
-- The rule (SPEC "Revive trigger", flag-mechanics.md "Death and revive"):
--   * The local pawn is the pawn of the live local HUD (InventoryUI_C.Player, else its owning player's pawn), read on
--     every `attached` event. Never ReceivePossess: it runs only where the controller has authority.
--   * A revive is the local pawn becoming a NEW BP_FirstPersonCharacter_C in the SAME world, after the HUD was lost
--     (death calls RemoveAllWidgets, so the HUD leaves the viewport: core's `lost`) -> "revive", acted on per onRevive.
--   * A new BP_FirstPersonCharacter_C in the same world with no `lost` in between is not a proven death (for example a
--     pawn swap the game does without one) -> "rebound": only ever restored (re-bound to the new pawn), never cleared.
--   * The same pawn back after a `lost` -> "back": nothing to do in 0.1.0, except in the settle window right after a
--     revive, where the game may clear the widget layer once more (a client's revive multicast can arrive after the
--     new pawn's HUD) -> "again", which re-runs the revive's action.
--   * A spectator or a playable monster (any other pawn class, or none) is not a revive -> "notfp"; the last
--     first-person pawn and the death stay remembered, so the real revive later still counts.
--   * A new world forgets everything (a map change destroys every waypoint actor with the old world).
-- The snapshot of the waypoints that were up is taken by main.lua at the first `lost` after the pawn attached (the
-- death) and handed back with the "revive" decision.
local M = {}
M.__index = M

M.FP_CLASS = "BP_FirstPersonCharacter_C"
M.SETTLE_S = 15 -- seconds after a revive in which the same pawn's HUD coming back re-runs the action

function M.new(opts)
    opts = opts or {}
    local self = setmetatable({ settle = opts.settle or M.SETTLE_S }, M)
    self:reset(nil)
    return self
end

-- Forget everything (a new world, or a map load).
function M:reset(world)
    self.world = world        -- the world the remembered pawn lives in ("World /Game/Maps/...")
    self.pawn = nil           -- path of the last first-person pawn seen with the live HUD
    self.lostSeen = false     -- the HUD was lost since that pawn attached (a death, or the revive's own RemoveAllWidgets)
    self.snapshot = nil       -- the waypoints that were up at that first `lost`
    self.revived = nil        -- { pawn, at, action } of the last revive or rebound, for the settle window
end

function M:loadMap() self:reset(nil) end

-- True when a `lost` now should take a snapshot: a first-person pawn is remembered and this is the first loss since it
-- attached (later losses keep the snapshot closest to the death).
function M:wantsSnapshot() return self.pawn ~= nil and not self.lostSeen end

-- The HUD left the viewport. snapshot: the waypoints up right now (a list), or nil if none was taken.
function M:lost(snapshot)
    if self.pawn == nil then return { kind = "ignored" } end
    local first = not self.lostSeen
    self.lostSeen = true
    if first then self.snapshot = snapshot end
    return { kind = "lost", first = first, pawn = self.pawn, snapshot = self.snapshot }
end

-- A HUD attached. f = { world = string, pawnPath = string|nil, pawnClass = string|nil, now = seconds }.
-- Returns { kind = "unknown"|"notfp"|"first"|"same"|"back"|"again"|"revive"|"rebound", pawn, was, lostSeen, snapshot,
-- action } where action ("revive" | "restore") is what main.lua should run for revive, rebound and again.
function M:attached(f)
    if type(f) ~= "table" or type(f.world) ~= "string" or f.world == "" then return { kind = "unknown" } end
    if self.world ~= f.world then self:reset(f.world) end
    if f.pawnClass ~= M.FP_CLASS or type(f.pawnPath) ~= "string" or f.pawnPath == "" then
        return { kind = "notfp", pawn = f.pawnPath, class = f.pawnClass }
    end
    local now = tonumber(f.now) or 0
    if self.pawn == nil then
        self.pawn, self.lostSeen, self.snapshot = f.pawnPath, false, nil
        return { kind = "first", pawn = f.pawnPath }
    end
    if self.pawn == f.pawnPath then
        local wasLost = self.lostSeen
        self.lostSeen, self.snapshot = false, nil
        local r = self.revived
        if wasLost and r and r.pawn == f.pawnPath and now - r.at <= self.settle then
            return { kind = "again", pawn = f.pawnPath, action = r.action }
        end
        return { kind = wasLost and "back" or "same", pawn = f.pawnPath }
    end
    local was, lost, snap = self.pawn, self.lostSeen, self.snapshot
    self.pawn, self.lostSeen, self.snapshot = f.pawnPath, false, nil
    local kind = lost and "revive" or "rebound"
    local action = lost and "revive" or "restore"
    self.revived = { pawn = f.pawnPath, at = now, action = action }
    return { kind = kind, pawn = f.pawnPath, was = was, lostSeen = lost, snapshot = snap, action = action }
end

return M
