-- A fake UE4SS world for the unit tests: just enough UObjects (actors, widgets, pawns, HUDs, classes, worlds) and
-- globals (FindAllOf, StaticFindObject, FText, ExecuteInGameThreadWithDelay, RegisterLoadMapPostHook) for game.lua,
-- waypoints.lua and main.lua to run outside the game. Destroyed actors stay findable (and IsValid) until gc(), as they do
-- in the game until the next garbage collection; UE's IsValid (KismetSystemLibrary:IsValid, a UFunction) tells them apart.
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
-- As in game (VM probe run 2): a destroyed actor still says false here; only UE's IsValid (KSL) sees it.
function Obj:IsActorBeingDestroyed() return self._beingDestroyed == true end
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
    -- A live waypoint actor of `short` in W.map (destroyed ones excluded), as the game's GetAllActorsOfClass sees them.
    local function liveIn(short)
        local r = {}
        for _, o in ipairs(W.all(short)) do if not o._dying and o._world == W.map then r[#r + 1] = o end end
        return r
    end
    W.clicks = {}
    -- The flags' own click handlers, as the V8.2 decompile has them: a location flag destroys the FIRST live
    -- LevelWaypointActor_C whose Name matches its own (case-insensitive) and sets Selected false, else spawns one (no
    -- owner, Character = its own Character, Name = its Name) and sets Selected true; the satellite flag toggles the
    -- first SatelliteWaypoint_C (GetActorOfClass), spawning at the lever.
    local function locClick(self)
        W.clicks[#W.clicks + 1] = self
        if W.failClick and W.failClick(self) then error("click: boom") end
        local mine = self.Name:ToString():lower()
        for _, a in ipairs(liveIn("LevelWaypointActor_C")) do
            if a.Name:ToString():lower() == mine then
                a:K2_DestroyActor()
                self.Selected = false
                return
            end
        end
        if W.noSpawn then return end
        local a = W.waypoint("location", self.Name:ToString(), { X = 10, Y = 20, Z = 30 }, self.Character)
        self.LevelWaypoint = a
        self.Selected = true
    end
    local function satClick(self)
        W.clicks[#W.clicks + 1] = self
        if W.failClick and W.failClick(self) then error("click: boom") end
        local a = liveIn("SatelliteWaypoint_C")[1]
        if a then a:K2_DestroyActor(); self.Selected = false return end
        if W.noSpawn then return end
        W.waypoint("satellite", nil, { X = 7, Y = 7, Z = 7 }, nil)
        self.Selected = true
    end
    local LOC_CLICK = "BndEvt__LevelLocationUI_Button_28_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
    local SAT_CLICK = "BndEvt__SateliteUI_Button_28_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
    function W.flag(name)
        W.n = W.n + 1
        return W.obj("LevelLocationUI_C", "/Engine/Transient.GameEngine_1:BP_GameInstance_C_1.LevelLocationUI_C_" .. W.n, { Name = text(name), Selected = true, [LOC_CLICK] = locClick })
    end
    function W.satFlag()
        W.n = W.n + 1
        return W.obj("SateliteUI_C", "/Engine/Transient.GameEngine_1:BP_GameInstance_C_1.SateliteUI_C_" .. W.n, { Selected = true, [SAT_CLICK] = satClick })
    end
    -- A TArray as UE4SS hands it to Lua: ForEach(fn(index, elem)) with elem:get().
    function W.tarray(list)
        return { ForEach = function(_, fn) for i, x in ipairs(list) do fn(i, { get = function() return x end }) end end, _list = list }
    end
    -- An open Journal_C: MapWidget.MapUI.Levels (the location flags) and .Satelite (nil: none on this map), Character.
    function W.journal(levels, sat, character)
        W.n = W.n + 1
        local base = "/Engine/Transient.GameEngine_1:BP_GameInstance_C_1.Journal_C_" .. W.n
        local mui = W.obj("MapUI_C", base .. ".WidgetTree.MapWidget.WidgetTree.MapUI", { Levels = W.tarray(levels or {}), Satelite = sat })
        local mw = W.obj("MapWidget_C", base .. ".WidgetTree.MapWidget", { MapUI = mui })
        return W.obj("Journal_C", base, { MapWidget = mw, Character = character })
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
    -- UE's IsValid as the UFunction object (callable) and KismetSystemLibrary's class default object.
    W.kslCalls = 0
    W.byPath["/Script/Engine.KismetSystemLibrary:IsValid"] = setmetatable({ IsValid = function() return true end }, {
        __call = function(_, cdo, a) W.kslCalls = W.kslCalls + 1; if W.kslBroken then error("UFunction call failed") end return not (a._dying or a._gone) end })
    W.byPath["/Script/Engine.Default__KismetSystemLibrary"] = setmetatable({ _path = "/Script/Engine.Default__KismetSystemLibrary", _class = class("KismetSystemLibrary") }, Obj)
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
    _G.LoopAsync = function() error("Waypoints must not use LoopAsync") end
    _G.ExecuteInGameThread = function() error("Waypoints must not use ExecuteInGameThread") end
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
