-- Unit tests for Scripts/revive.lua: the revive detector's state machine against fake HUD events and pawn paths.
-- Run from the repo root with any standalone Lua 5.3 or 5.4:  texlua test/unit/revive_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
package.path = ROOT .. "/Scripts/?.lua;" .. ROOT .. "/test/unit/?.lua;" .. package.path
local revive = require("revive")
local H = require("fakeue").harness("revive_test")
local ok, eq = H.ok, H.eq

local W1, W2 = "World /Game/Maps/SmallLoweIsland/SmallMap.SmallMap", "World /Game/Maps/ForestMap/ForestMap.ForestMap"
local FP, TP, SPEC = "BP_FirstPersonCharacter_C", "BP_ThirdPersonCharacter_C", "Spectator_C"
local function P(i, w) return (w == W2 and "/Game/Maps/ForestMap/ForestMap.ForestMap" or "/Game/Maps/SmallLoweIsland/SmallMap.SmallMap") .. ":PersistentLevel.BP_FirstPersonCharacter_C_" .. i end
local function att(R, pawn, class, world, now) return R:attached{ world = world or W1, pawnPath = pawn, pawnClass = class or FP, now = now or 0 } end
local SNAP = { { kind = "location", name = "Medbay", key = "medbay", loc = { X = 1, Y = 2, Z = 3 } }, { kind = "satellite", name = "Satellite", key = "#satellite", loc = { X = 0, Y = 0, Z = 0 } } }

do -- The first first-person pawn in a world is remembered; the same pawn again is "same".
    local R = revive.new()
    local d = att(R, P(1))
    eq(d.kind, "first", "first pawn: first")
    eq(att(R, P(1)).kind, "same", "same pawn, no loss: same")
    ok(R:wantsSnapshot(), "a remembered pawn wants a snapshot at its first loss")
end

do -- The real revive: death (HUD lost, snapshot), spectator meanwhile, then a new first-person pawn in the same world.
    local R = revive.new()
    att(R, P(1))
    ok(R:wantsSnapshot(), "first loss wants a snapshot")
    local l = R:lost(SNAP)
    eq(l.kind, "lost", "death: lost")
    ok(l.first and l.snapshot == SNAP, "death: the first loss keeps the snapshot")
    ok(not R:wantsSnapshot(), "after the first loss no further snapshot is wanted")
    local l2 = R:lost({})
    ok(not l2.first and l2.snapshot == SNAP, "a second loss keeps the first snapshot (closest to the death)")
    eq(R:attached{ world = W1, pawnPath = "/Game/Maps/SmallLoweIsland/SmallMap.SmallMap:PersistentLevel.Spectator_C_9", pawnClass = SPEC }.kind, "notfp", "spectator HUD: not a revive")
    eq(att(R, "/x:PersistentLevel.BP_ThirdPersonCharacter_C_3", TP).kind, "notfp", "playable monster: not a revive")
    eq(R:attached{ world = W1 }.kind, "notfp", "no pawn at all: not a revive")
    local d = att(R, P(2), FP, W1, 100)
    eq(d.kind, "revive", "new first-person pawn after a loss: revive")
    eq(d.was, P(1), "revive: was the old pawn")
    eq(d.pawn, P(2), "revive: the new pawn")
    eq(d.action, "revive", "revive: the action is the onRevive setting")
    ok(d.lostSeen == true and d.snapshot == SNAP, "revive: hands back the snapshot from the death")
    eq(att(R, P(2), FP, W1, 101).kind, "same", "after the revive, the same pawn again: same")
    eq(R.snapshot, nil, "the snapshot is consumed by the revive")
end

do -- A new pawn without any loss of the HUD is no proven death: rebound, restore only.
    local R = revive.new()
    att(R, P(1))
    local d = att(R, P(2), FP, W1, 5)
    eq(d.kind, "rebound", "pawn swap without a loss: rebound")
    eq(d.action, "restore", "rebound: restore only, never clear")
    eq(d.snapshot, nil, "rebound: no snapshot")
end

do -- The same pawn back after a loss (a RemoveAllWidgets without a death) is not a revive.
    local R = revive.new()
    att(R, P(1))
    R:lost({})
    eq(att(R, P(1)).kind, "back", "same pawn after a loss: back")
    ok(R:wantsSnapshot(), "back: the next loss takes a fresh snapshot")
    R:lost(SNAP)
    eq(R.snapshot, SNAP, "the fresh snapshot is kept")
end

do -- Settle window: right after a revive, the new pawn's HUD lost and back again re-runs the action; later it doesn't.
    local R = revive.new{ settle = 15 }
    att(R, P(1), FP, W1, 0); R:lost(SNAP)
    eq(att(R, P(2), FP, W1, 100).kind, "revive", "settle: the revive")
    R:lost({})
    local d = att(R, P(2), FP, W1, 104)
    eq(d.kind, "again", "settle: HUD rebuilt 4 s after the revive: again")
    eq(d.action, "revive", "settle: again runs the revive's action")
    R:lost({})
    eq(att(R, P(2), FP, W1, 130).kind, "back", "settle: 30 s after the revive it's only back")
    -- a rebound's settle window re-runs a restore
    att(R, P(3), FP, W1, 200)
    R:lost({})
    local d2 = att(R, P(3), FP, W1, 201)
    ok(d2.kind == "again" and d2.action == "restore", "settle after a rebound: again, restore", d2.kind .. " " .. tostring(d2.action))
end

do -- A new world forgets the pawn, the loss and the snapshot: no revive across a map change.
    local R = revive.new()
    att(R, P(1)); R:lost(SNAP)
    local d = att(R, P(1, W2), FP, W2)
    eq(d.kind, "first", "new world: first, not a revive")
    eq(R.snapshot, nil, "new world: snapshot forgotten")
    -- the LoadMap hook forgets as well, even if the next world's path were the same
    att(R, P(5, W2)); R:lost(SNAP); R:loadMap()
    eq(att(R, P(6, W2), FP, W2).kind, "first", "after loadMap: first")
end

do -- Losses with no pawn remembered are ignored; bad facts are unknown, not errors.
    local R = revive.new()
    eq(R:lost({}).kind, "ignored", "loss before any pawn: ignored")
    ok(not R:wantsSnapshot(), "no pawn: no snapshot wanted")
    eq(R:attached(nil).kind, "unknown", "nil facts: unknown")
    eq(R:attached{ pawnPath = P(1), pawnClass = FP }.kind, "unknown", "no world: unknown")
    eq(R:attached{ world = "", pawnPath = P(1), pawnClass = FP }.kind, "unknown", "empty world: unknown")
    eq(R:attached{ world = W1, pawnPath = "", pawnClass = FP }.kind, "notfp", "empty pawn path: notfp")
    eq(R.pawn, nil, "nothing remembered from bad facts")
end

do -- The menu's HUD (a standalone world) and the match: no revive from menu -> match.
    local R = revive.new()
    eq(att(R, "/Game/Maps/NewMainMenu.NewMainMenu:PersistentLevel.BP_FirstPersonCharacter_C_1", FP, "World /Game/Maps/NewMainMenu.NewMainMenu").kind, "first", "menu pawn: first")
    R:lost({})
    eq(att(R, P(1)).kind, "first", "match after the menu: first (another world)")
end

do -- Revive from a playable monster (if the game ever revives one): the death was seen, the FP pawn changes.
    local R = revive.new()
    att(R, P(1)); R:lost({})
    att(R, "/x:PersistentLevel.BP_ThirdPersonCharacter_C_2", TP)
    eq(att(R, P(3)).kind, "revive", "monster then a new first-person pawn: revive")
end

H.done()
