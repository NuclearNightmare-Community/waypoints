-- game.lua: the only file that touches the game (UE4SS Lua). It is waypoints.lua's adapter G plus the pawn facts
-- revive.lua needs. Every function is called inside one game-thread callback and returns plain data or objects that
-- the caller uses within that same callback; nothing here is kept between callbacks (AGENTS.md).
-- Evidence for every class, property and call: the markers spec's marker-mechanics.md and the V8.1.2 decompile
-- (Graphics/Journal/LevelLocationUI_C, SateliteUI_C, LevelWaypointActor_C, SatelliteWaypoint_C; InventoryUI_C.Player).
-- Local only: it spawns and destroys the local, unreplicated waypoint actors and edits local widgets. No RPC, no
-- replicated actor, nothing read from another player.
local M = {}

M.FP_CLASS = "BP_FirstPersonCharacter_C"
M.WAYPOINT = { location = "LevelWaypointActor_C", satellite = "SatelliteWaypoint_C" }
M.WAYPOINT_PATH = {
    location = "/Game/Graphics/Journal/LevelWaypointActor.LevelWaypointActor_C",
    satellite = "/Game/Graphics/Journal/SatelliteWaypoint.SatelliteWaypoint_C",
}
M.FLAG, M.SAT_FLAG = "LevelLocationUI_C", "SateliteUI_C"
local GAMEPLAY_STATICS = "/Script/Engine.Default__GameplayStatics"
local SAT_KEY = "#satellite"

-- The UE4SS globals, replaceable for tests (M.use{ FindAllOf = ..., ... }).
local E = setmetatable({}, { __index = _G })
function M.use(env) E = setmetatable(env or {}, { __index = _G }) end

local function valid(o)
    if o == nil or type(o) == "number" or type(o) == "string" or type(o) == "boolean" then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end
M.valid = valid

function M.pathOf(o) return (o:GetFullName():gsub("^%S+ ", "")) end
function M.classOf(o) return o:GetClass():GetFName():ToString() end
-- "World /Game/Maps/SmallLoweIsland/SmallMap.SmallMap": the key revive.lua compares worlds by.
function M.worldOf(o) return o:GetWorld():GetFullName() end
local function text(t) local ok, s = pcall(function() return t:ToString() end) return ok and s or nil end

-- A live actor: a valid object not being destroyed. FindAllOf also returns actors destroyed since the last garbage
-- collection (a flag the player switched off a minute ago); the game's own GetAllActorsOfClass skips those, and so
-- does this.
-- In game (VM probe run 2, V8.1.2): after its flag destroyed it, a waypoint actor still has
-- IsActorBeingDestroyed() == false and UE4SS's IsValid() == true, but UE's own IsValid
-- (UKismetSystemLibrary::IsValid, which checks the garbage flag) is false, and GetAllActorsOfClass skips it.
local KSL_ISVALID, KSL_CDO = "/Script/Engine.KismetSystemLibrary:IsValid", "/Script/Engine.Default__KismetSystemLibrary"
function M.alive(a)
    if not valid(a) then return false end
    local ok, dying = pcall(function() return a:IsActorBeingDestroyed() end)
    if ok and dying == true then return false end
    -- Both objects exist for the whole session, so these lookups hit (no full scan). Called as the UFunction itself:
    -- KSL:IsValid(...) would reach UE4SS's own IsValid method instead.
    local okK, live = pcall(function() return E.StaticFindObject(KSL_ISVALID)(E.StaticFindObject(KSL_CDO), a) end)
    if okK and live == false then return false end
    return true
end

local function findAll(short)
    local ok, list = pcall(E.FindAllOf, short)
    if not ok or type(list) ~= "table" then return {} end
    return list
end

-- The live waypoint actors of `world` (nil: any world): { { kind, name, loc, obj } }.
function M.waypoints(world)
    local out = {}
    for _, kind in ipairs({ "location", "satellite" }) do
        for _, a in ipairs(findAll(M.WAYPOINT[kind])) do
            -- One unreadable actor (half torn down) is skipped, not fatal for the rest.
            pcall(function()
                if M.alive(a) and not M.pathOf(a):find("Default__", 1, true) and (world == nil or M.worldOf(a) == world) then
                    local name = kind == "satellite" and "Satellite" or text(a.Name)
                    local v = a:K2_GetActorLocation()
                    out[#out + 1] = { kind = kind, name = name, loc = { X = v.X, Y = v.Y, Z = v.Z }, obj = a }
                end
            end)
        end
    end
    return out
end

-- The facts revive.lua needs from a live local HUD (InventoryUI_C): its pawn (the HUD's own Player, which the game sets
-- when it creates the HUD for a character; else the owning player's pawn) and that pawn's world.
-- Returns { world, pawnPath, pawnClass, pawn } (pawn is the object, for use in this callback only).
function M.pawnFacts(hud)
    local f = {}
    if not valid(hud) then return f end
    local okP, p = pcall(function() return hud.Player end)
    if not (okP and valid(p)) then
        okP, p = pcall(function() return hud:GetOwningPlayerPawn() end)
    end
    if okP and valid(p) then
        f.pawn = p
        pcall(function() f.pawnPath = M.pathOf(p) end)
        pcall(function() f.pawnClass = M.classOf(p) end)
        pcall(function() f.world = M.worldOf(p) end)
    end
    if not f.world then pcall(function() f.world = M.worldOf(hud) end) end
    return f
end

local function waypointClass(kind, template)
    if valid(template) then
        local ok, c = pcall(function() return template:GetClass() end)
        if ok and valid(c) then return c end
    end
    -- Loaded whenever a waypoint has ever existed (the Journal's flags reference it); a hit costs nothing.
    local c = E.StaticFindObject(M.WAYPOINT_PATH[kind])
    if valid(c) then return c end
    error("the " .. M.WAYPOINT[kind] .. " class is not loaded")
end

-- A new waypoint actor for entry { kind, name, loc }, exactly as the flag's click makes one (LevelLocationUI_C ubergraph
-- 1147 / SateliteUI_C): BeginDeferredActorSpawnFromClass at the location with no owner, then for a location its
-- Character (the new pawn: Waypoint1_C colours by Character->IsLocallyControlled()) and Name, then
-- FinishSpawningActor, whose BeginPlay builds the on-screen widget. The satellite gets neither, as in the game.
-- Returns actor, { replicates, via }.
function M.spawn(entry, pawn, template)
    if not valid(pawn) then error("no live pawn to spawn for") end
    local cls = waypointClass(entry.kind, template)
    local loc = entry.loc or {}
    local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = loc.X or 0, Y = loc.Y or 0, Z = loc.Z or 0 },
                 Scale3D = { X = 1, Y = 1, Z = 1 } }
    local function bind(a)
        if entry.kind == "location" then
            a.Character = pawn
            a.Name = E.FText(entry.name)
        end
    end
    local via = "BeginDeferredActorSpawnFromClass"
    local okD, a = pcall(function()
        local gs = E.StaticFindObject(GAMEPLAY_STATICS)
        local x = gs:BeginDeferredActorSpawnFromClass(pawn, cls, xf, 0, nil, 1) -- Undefined collision, MultiplyWithRoot
        if not valid(x) then error("BeginDeferredActorSpawnFromClass returned no actor") end
        bind(x)
        gs:FinishSpawningActor(x, xf, 1)
        return x
    end)
    if not okD then
        -- Fallback: a plain spawn (BeginPlay builds the widget before Name is set), then the actor's own BeginPlay
        -- graph once more with Name and Character set, which replaces the widget (LevelWaypointActor_C ubergraph 10).
        local err = a
        via = "SpawnActor+ReceiveBeginPlay (deferred spawn failed: " .. tostring(err) .. ")"
        a = pawn:GetWorld():SpawnActor(cls, { X = loc.X or 0, Y = loc.Y or 0, Z = loc.Z or 0 }, { Pitch = 0, Yaw = 0, Roll = 0 })
        if not valid(a) then error("spawn failed: " .. tostring(err)) end
        bind(a)
        a:ReceiveBeginPlay()
    end
    local okR, rep = pcall(function() return a.bReplicates end)
    local replicates = nil
    if okR then replicates = rep end
    return a, { replicates = replicates, via = via }
end

function M.destroy(a)
    if not valid(a) then return end
    a:K2_DestroyActor()
end

-- Live flag widgets only: archetypes and class defaults live under /Game/... (a widget tree) or are Default__ objects.
local function liveWidget(w)
    if not valid(w) then return false end
    local p = M.pathOf(w)
    return not (p:find("^/Game/") or p:find("Default__", 1, true))
end

-- Every flag widget's Selected follows present[key] (truth is the actor). Location flags also get the new pawn as
-- Character (their next click binds the waypoint to it, not to the dead pawn) and LevelWaypoint = the new actor.
-- Returns the number of location flags and satellite flags set.
function M.syncFlags(pawn, present, newByKey)
    present, newByKey = present or {}, newByKey or {}
    local nl, ns = 0, 0
    for _, f in ipairs(findAll(M.FLAG)) do
        pcall(function()
            if liveWidget(f) then
                local name = text(f.Name)
                if name then
                    local k = name:lower()
                    f.Selected = present[k] == true
                    nl = nl + 1
                    if valid(pawn) then pcall(function() f.Character = pawn end) end
                    if newByKey[k] ~= nil then pcall(function() f.LevelWaypoint = newByKey[k] end) end
                end
            end
        end)
    end
    for _, f in ipairs(findAll(M.SAT_FLAG)) do
        pcall(function()
            if liveWidget(f) then
                f.Selected = present[SAT_KEY] == true
                ns = ns + 1
            end
        end)
    end
    return nl, ns
end

-- ---------------------------------------------------------------- the open Journal's flags (Mark all / Clear all)
-- Everything below is read from the Journal the caller holds in this callback (a fresh deref of core's weak handle);
-- nothing is kept. Evidence: the V8.2 decompile, Graphics/Journal/LevelLocationUI_C (its click destroys only the first
-- LevelWaypointActor_C with its Name, else spawns one bound to its own Character) and SateliteUI_C (GetActorOfClass
-- toggle, spawn at the Lever_Actor_C; no Character).
M.LOC_CLICK = "BndEvt__LevelLocationUI_Button_28_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
M.SAT_CLICK = "BndEvt__SateliteUI_Button_28_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"

-- The Journal's flags: { locations = { { widget, name }, ... } in MapUI_C.Levels order (live widgets with a readable
-- Name only), satellite = widget | nil (MapUI_C.Satelite is unset on a map without a Lever_Actor_C) }. Raises when the
-- Journal's MapWidget or MapUI can't be read.
function M.journalFlags(journal)
    if not valid(journal) then error("no live Journal") end
    local mw = journal.MapWidget
    if not valid(mw) then error("the Journal has no MapWidget") end
    local mui = mw.MapUI
    if not valid(mui) then error("the Journal's MapWidget has no MapUI") end
    local out = { locations = {} }
    local okL, levels = pcall(function() return mui.Levels end)
    if okL and levels ~= nil then
        pcall(function()
            levels:ForEach(function(_, e)
                pcall(function()
                    local w = e:get()
                    if valid(w) then
                        local name = text(w.Name)
                        if name and name ~= "" then out.locations[#out.locations + 1] = { widget = w, name = name } end
                    end
                end)
            end)
        end)
    end
    local okS, sat = pcall(function() return mui.Satelite end)
    if okS and valid(sat) then out.satellite = sat end
    return out
end

-- The Journal's Character (the game sets it on every map open) and its class name; pawn is nil unless it is alive.
function M.journalPawn(journal)
    local okC, p = pcall(function() return journal.Character end)
    if not (okC and valid(p)) then return nil, "none" end
    local okK, cls = pcall(M.classOf, p)
    cls = okK and cls or "?"
    if not M.alive(p) then return nil, cls .. " (destroyed)" end
    return p, cls
end

function M.setCharacter(w, pawn) w.Character = pawn end
function M.clickFlag(w) w[M.LOC_CLICK](w) end
function M.clickSat(w) w[M.SAT_CLICK](w) end
function M.selected(w) return w.Selected == true end
function M.setSelected(w, on) w.Selected = on == true end

return M
