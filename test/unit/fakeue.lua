-- A fake UE4SS world for the unit tests: just enough UObjects (actors, widgets, pawns, HUDs, classes, worlds) and
-- globals (FindAllOf, StaticFindObject, FText, ExecuteInGameThreadWithDelay, RegisterLoadMapPostHook) for game.lua,
-- markers.lua and main.lua to run outside the game. Destroyed actors stay findable (and IsValid) until gc(), as they do
-- in the game until the next garbage collection; IsActorBeingDestroyed tells them apart.
local F = {}

local Obj = {}
Obj.__index = Obj
function Obj:IsValid() return not self._gone end
function Obj:GetFullName() return self._class.short .. " " .. self._path end
function Obj:GetClass() return self._class end
function Obj:GetWorld() return self._world end
function Obj:GetAddress() return self._addr end
function Obj:K2_GetActorLocation() return { X = self._loc.X, Y = self._loc.Y, Z = self._loc.Z } end
function Obj:K2_DestroyActor()
    if self._world and self._world.failDestroy then error("K2_DestroyActor: boom") end
    self._dying = true
end
function Obj:IsActorBeingDestroyed() return self._dying == true end
function Obj:GetOwningPlayerPawn() return self._owningPawn end
function Obj:ReceiveBeginPlay() self._beginPlays = (self._beginPlays or 0) + 1; self._widgetName = self.Name and self.Name:ToString() end

local function text(s) return setmetatable({ s = s }, { __index = { ToString = function(t) return t.s end } }) end
F.text = text

function F.new()
    local W = { objects = {}, byPath = {}, n = 0, delayed = {}, loadMapHooks = {}, printed = {}, spawns = {}, calls = {} }
    local classes = {}
    local function class(short, path)
        if classes[short] then return classes[short] end
        local c = setmetatable({ short = short, _path = path or ("/Script/Fake." .. short) }, Obj)
        c._class = { short = "Class", GetFName = function() return { ToString = function() return "Class" end } end }
        c.GetFName = function() return { ToString = function() return short end } end
        classes[short] = c
        W.byPath[c._path] = c
        return c
    end
    W.class = class
    function W.world(path)
        return setmetatable({ _path = path, GetFullName = function(self) return "World " .. self._path end }, { __index = Obj })
    end
    W.map = W.world("/Game/Maps/SmallLoweIsland/SmallMap.SmallMap")
    function W.obj(short, path, props)
        W.n = W.n + 1
        local o = setmetatable(props or {}, Obj)
        o._class, o._path, o._addr = class(short), path, 0x10000 + W.n * 16
        o._world = o._world or W.map
        W.objects[#W.objects + 1] = o
        W.byPath[path] = o
        return o
    end
    function W.pawn(i, world)
        local w = world or W.map
        return W.obj("BP_FirstPersonCharacter_C", w._path .. ":PersistentLevel.BP_FirstPersonCharacter_C_" .. i, { _world = w })
    end
    function W.waypoint(kind, name, loc, character, world)
        local short = kind == "satellite" and "SatelliteWaypoint_C" or "LevelWaypointActor_C"
        local w = world or W.map
        W.n = W.n + 1
        local a = W.obj(short, w._path .. ":PersistentLevel." .. short .. "_" .. W.n, { _world = w, _loc = loc or { X = 1, Y = 2, Z = 3 },
            Name = text(kind == "satellite" and "" or name), Character = character, bReplicates = false })
        return a
    end
    function W.flag(name)
        W.n = W.n + 1
        return W.obj("LevelLocationUI_C", "/Engine/Transient.GameEngine_1:BP_GameInstance_C_1.LevelLocationUI_C_" .. W.n, { Name = text(name), Selected = true })
    end
    function W.satFlag()
        W.n = W.n + 1
        return W.obj("SateliteUI_C", "/Engine/Transient.GameEngine_1:BP_GameInstance_C_1.SateliteUI_C_" .. W.n, { Selected = true })
    end
    function W.hud(player, owningPawn)
        W.n = W.n + 1
        return W.obj("InventoryUI_C", "/Engine/Transient.GameEngine_1:BP_GameInstance_C_1.InventoryUI_C_" .. W.n, { Player = player, _owningPawn = owningPawn })
    end
    -- What FindAllOf returns: every object of that class, destroyed-but-not-collected ones included.
    function W.all(short)
        local r = {}
        for _, o in ipairs(W.objects) do if not o._gone and o._class.short == short then r[#r + 1] = o end end
        return r
    end
    function W.live(short)
        local r = {}
        for _, o in ipairs(W.all(short)) do if not o._dying then r[#r + 1] = o end end
        return r
    end
    function W.gc() for _, o in ipairs(W.objects) do if o._dying then o._gone = true end end end
    function W.runDelayed()
        local d = W.delayed; W.delayed = {}
        for _, x in ipairs(d) do x.fn() end
        return #d
    end

    class("LevelWaypointActor_C", "/Game/Graphics/Journal/LevelWaypointActor.LevelWaypointActor_C")
    class("SatelliteWaypoint_C", "/Game/Graphics/Journal/SatelliteWaypoint.SatelliteWaypoint_C")
    local GS = W.obj("GameplayStatics", "/Script/Engine.Default__GameplayStatics")
    W.gs = GS
    function GS:BeginDeferredActorSpawnFromClass(ctx, cls, xf, coll, owner, scale)
        W.calls[#W.calls + 1] = { "begin", ctx = ctx, cls = cls, xf = xf, coll = coll, owner = owner, scale = scale }
        if W.failSpawn then error("BeginDeferredActorSpawnFromClass: boom") end
        if W.nilSpawn then return nil end
        W.n = W.n + 1
        local a = W.obj(cls.short, ctx._world._path .. ":PersistentLevel." .. cls.short .. "_" .. W.n,
            { _world = ctx._world, _loc = { X = xf.Translation.X, Y = xf.Translation.Y, Z = xf.Translation.Z }, bReplicates = false, Name = text("") })
        a._deferred = true
        return a
    end
    function GS:FinishSpawningActor(a, xf, scale)
        W.calls[#W.calls + 1] = { "finish", a = a, scale = scale }
        a._deferred = false
        a._widgetName = a.Name and a.Name:ToString() -- what ReceiveBeginPlay's widget shows
        a._widgetCharacter = a.Character
        W.spawns[#W.spawns + 1] = a
        return a
    end
    W.map.SpawnActor = function(self, cls, loc, rot)
        W.calls[#W.calls + 1] = { "spawnActor", cls = cls }
        W.n = W.n + 1
        local a = W.obj(cls.short, self._path .. ":PersistentLevel." .. cls.short .. "_" .. W.n, { _world = self, _loc = loc, bReplicates = false, Name = text("") })
        W.spawns[#W.spawns + 1] = a
        return a
    end

    W.env = {
        FindAllOf = function(short) local r = W.all(short) return #r > 0 and r or nil end,
        StaticFindObject = function(p) local o = W.byPath[p] if o and not o._gone then return o end return setmetatable({ _gone = true, _path = p, _class = class("None") }, Obj) end,
        FText = text,
    }
    return W
end

-- Installs W's globals into _G (for main.lua, which uses UE4SS's globals directly).
function F.install(W)
    _G.FindAllOf = W.env.FindAllOf
    _G.StaticFindObject = W.env.StaticFindObject
    _G.FText = text
    _G.ExecuteInGameThreadWithDelay = function(ms, fn) W.delayed[#W.delayed + 1] = { ms = ms, fn = fn } end
    _G.RegisterLoadMapPostHook = function(fn) W.loadMapHooks[#W.loadMapHooks + 1] = fn end
    _G.LoopAsync = function() error("Markers must not use LoopAsync") end
    _G.ExecuteInGameThread = function() error("Markers must not use ExecuteInGameThread") end
    _G.print = function(s) W.printed[#W.printed + 1] = (tostring(s):gsub("\n$", "")) end
end

-- A tiny test harness.
function F.harness(name)
    local H = { passed = 0, failed = 0 }
    function H.ok(cond, what, detail)
        if cond then H.passed = H.passed + 1 else H.failed = H.failed + 1; io.stdout:write("FAIL " .. what .. (detail ~= nil and (" -- " .. tostring(detail)) or "") .. "\n") end
    end
    function H.eq(got, want, what) H.ok(got == want, what, "got " .. tostring(got) .. ", want " .. tostring(want)) end
    function H.done()
        io.stdout:write(("%s: %d passed, %d failed\n"):format(name, H.passed, H.failed))
        os.exit(H.failed == 0 and 0 or 1)
    end
    return H
end

return F
