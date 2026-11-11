-- Waypoints 0.2.0 (story 5): the pure half of the debug-only panel fit check. main.lua calls core.ui.debug.overlaps on
-- the Mark all / Clear all panel (only with debug on) and hands its list and info here; this file classifies each hit
-- and formats the PANELFIT / PANELHIT lines. No UObject, no game call, no core call: unit-tested on its own.
--   under   the hit's rectangle contains the panel's (the page paper the panel sits on): fine
--   partial the hit cuts into the panel without containing it (a map widget, a perk hex, another element): a misfit
-- Rectangles are { l, t, r, b } in screen pixels, as debug.overlaps gives them.
local P = {}
P.MAX_HITS = 10   -- PANELHIT lines per check
P.EPS = 0.5       -- pixels of slack in "contains" (Slate geometry is fractional)

local function num(x) return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge end
function P.isRect(r)
    return type(r) == "table" and num(r.l) and num(r.t) and num(r.r) and num(r.b)
end
-- outer contains inner (within EPS on every edge)
function P.contains(outer, inner)
    local e = P.EPS
    return outer.l <= inner.l + e and outer.t <= inner.t + e and outer.r >= inner.r - e and outer.b >= inner.b - e
end
-- a and b share some area (touching edges don't count)
function P.intersects(a, b)
    return a.l < b.r and b.l < a.r and a.t < b.b and b.t < a.b
end

-- classify(list, rect) -> hits, partial. hits: { kind = "under" | "partial", class, path, rect } for each list entry with
-- a valid rectangle that intersects `rect`, in list order (overlaps sorts them smallest first); partial: how many are
-- "partial". Entries without a rectangle or not intersecting are ignored. A bad `rect` or `list` gives {}, 0.
function P.classify(list, rect)
    local hits, partial = {}, 0
    if type(list) ~= "table" or not P.isRect(rect) then return hits, partial end
    for _, h in ipairs(list) do
        if type(h) == "table" and P.isRect(h.rect) and P.intersects(h.rect, rect) then
            local kind = P.contains(h.rect, rect) and "under" or "partial"
            if kind == "partial" then partial = partial + 1 end
            hits[#hits + 1] = { kind = kind, class = tostring(h.class or "?"), path = tostring(h.path or "?"), rect = h.rect }
        end
    end
    return hits, partial
end

local function rectText(r) return string.format("(%.0f,%.0f)-(%.0f,%.0f)", r.l, r.t, r.r, r.b) end

-- The lines one check logs: "PANELFIT rect=... screen=WxH hits=n partial=k", then at most MAX_HITS
-- "PANELHIT <kind> <class> <path> (l,t)-(r,b)". Partial hits are listed first (they are the ones that matter).
function P.lines(info, hits, partial)
    local rect = type(info) == "table" and info.rect or nil
    local scr = type(info) == "table" and type(info.screen) == "table" and info.screen or {}
    local out = {}
    out[1] = string.format("PANELFIT rect=%s screen=%sx%s hits=%d partial=%d",
        P.isRect(rect) and rectText(rect) or "?", num(scr.w) and string.format("%.0f", scr.w) or "?",
        num(scr.h) and string.format("%.0f", scr.h) or "?", #hits, partial)
    local ordered = {}
    for _, h in ipairs(hits) do if h.kind == "partial" then ordered[#ordered + 1] = h end end
    for _, h in ipairs(hits) do if h.kind ~= "partial" then ordered[#ordered + 1] = h end end
    for i = 1, math.min(#ordered, P.MAX_HITS) do
        local h = ordered[i]
        out[#out + 1] = string.format("PANELHIT %s %s %s %s", h.kind, h.class, h.path, rectText(h.rect))
    end
    return out
end

function P.none(reason) return "PANELFIT none (" .. tostring(reason) .. ")" end

return P
