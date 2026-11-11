-- Unit tests for Scripts/panelfit.lua (story 5): the under/partial classification of debug.overlaps hits against the
-- panel's rectangle, and the PANELFIT / PANELHIT / PANELFIT none lines. Pure: no fake world needed.
-- Run from the repo root:  texlua test/unit/panelfit_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
package.path = ROOT .. "/Scripts/?.lua;" .. ROOT .. "/test/unit/?.lua;" .. package.path
local F = require("fakeue")
local P = require("panelfit")
local H = F.harness("panelfit_test")
local ok, eq = H.ok, H.eq

local function R(l, t, r, b) return { l = l, t = t, r = r, b = b } end
local panel = R(100, 200, 300, 250)
local function hit(path, rect, class) return { path = path, class = class or "Image", rect = rect } end

-- ---------------------------------------------------------------- contains / intersects
ok(P.contains(R(0, 0, 1000, 1000), panel), "a big rect contains the panel")
ok(P.contains(panel, panel), "the same rect contains itself")
ok(P.contains(R(100.4, 199.6, 299.6, 250.4), panel), "within 0.5 px on every edge still contains")
ok(not P.contains(R(101, 200, 300, 250), panel), "1 px short on the left: not contained")
ok(not P.contains(R(100, 200, 300, 249), panel), "1 px short at the bottom: not contained")
ok(P.intersects(R(250, 240, 400, 400), panel), "corner overlap intersects")
ok(not P.intersects(R(300, 200, 400, 250), panel), "touching the right edge does not intersect")
ok(not P.intersects(R(100, 250, 300, 300), panel), "touching the bottom edge does not intersect")

-- ---------------------------------------------------------------- classify
do
    local list = {
        hit("/paper", R(0, 0, 1000, 1000)),                 -- under: contains the panel
        hit("/frame", R(50, 100, 200, 220), "Border"),      -- partial: cuts into the top-left
        hit("/hex", R(150, 240, 170, 260)),                 -- partial: pokes in from below
        hit("/inside", R(120, 210, 140, 230)),              -- partial: drawn inside the panel without containing it
        hit("/apart", R(500, 500, 600, 600)),               -- no overlap: ignored
        hit("/norect", nil),                                -- no rectangle: ignored
        hit("/nan", R(0 / 0, 0, 10, 10)),                   -- NaN: ignored
        "not a table",                                      -- ignored
    }
    local hits, partial = P.classify(list, panel)
    eq(#hits, 4, "classify: 4 hits (the non-overlapping and malformed entries ignored)")
    eq(partial, 3, "classify: 3 partial")
    eq(hits[1].kind, "under", "classify: the paper is under")
    eq(hits[2].kind .. " " .. hits[2].class .. " " .. hits[2].path, "partial Border /frame", "classify: the frame is partial, with class and path")
    eq(hits[3].kind, "partial", "classify: the hex poking in is partial")
    eq(hits[4].kind, "partial", "classify: a widget inside the panel is partial")
end
do
    local hits, partial = P.classify({}, panel)
    eq(#hits + partial, 0, "classify: empty list -> no hits")
    hits, partial = P.classify(nil, panel)
    eq(#hits + partial, 0, "classify: nil list -> no hits")
    hits, partial = P.classify({ hit("/paper", R(0, 0, 1000, 1000)) }, nil)
    eq(#hits + partial, 0, "classify: no panel rect -> no hits")
    hits, partial = P.classify({ hit("/paper", R(0, 0, 1000, 1000)) }, { l = 1, t = 2 })
    eq(#hits + partial, 0, "classify: a half panel rect -> no hits")
end

-- ---------------------------------------------------------------- lines
do
    local list = { hit("/paper", R(0, 0, 1000, 1000)), hit("/hex", R(150, 240, 170, 260)) }
    local hits, partial = P.classify(list, panel)
    local out = P.lines({ rect = R(100.4, 200, 300, 249.6), screen = { w = 1280, h = 720 } }, hits, partial)
    eq(#out, 3, "lines: PANELFIT + one PANELHIT per hit")
    eq(out[1], "PANELFIT rect=(100,200)-(300,250) screen=1280x720 hits=2 partial=1", "lines: the PANELFIT line")
    eq(out[2], "PANELHIT partial Image /hex (150,240)-(170,260)", "lines: partial hits first")
    eq(out[3], "PANELHIT under Image /paper (0,0)-(1000,1000)", "lines: then the under hits")
end
do
    local list = {}
    for i = 1, 15 do list[i] = hit("/u" .. i, R(0, 0, 1000, 1000)) end
    local hits, partial = P.classify(list, panel)
    local out = P.lines({ rect = panel, screen = { w = 3440, h = 1440 } }, hits, partial)
    eq(#out, 1 + P.MAX_HITS, "lines: at most MAX_HITS (10) PANELHIT lines")
    eq(out[1], "PANELFIT rect=(100,200)-(300,250) screen=3440x1440 hits=15 partial=0", "lines: hits counts all 15")
end
eq(P.lines(nil, {}, 0)[1], "PANELFIT rect=? screen=?x? hits=0 partial=0", "lines: no info -> ? placeholders, no error")
eq(P.none("not painted yet"), "PANELFIT none (not painted yet)", "none: names the reason")
eq(P.none(nil), "PANELFIT none (nil)", "none: a nil reason")

H.done()
