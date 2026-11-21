# Waypoints

A Nuclear Nightmare mod (UE4SS Lua, on the Nucleus core) for your Journal map waypoints: **Mark all** and **Clear all** buttons on the map, and your waypoints back after a revive.

**0.3.0** (unreleased): `onRevive` moves onto Nucleus's settings service (Nucleus 0.9.0 or newer; Mod Manager story 5 in the workspace). **0.2.0** (spec `_bmad-output/specs/spec-markers-v1/` in the workspace, stories 2, 3 and 5): the revive fix plus the two buttons, on Nucleus 0.6.0 or newer, game V8.2.1 (build 26512322). It is the first release. License: MIT (`LICENSE`); changes: `CHANGELOG.md`; `build.ps1` stages the release package for the workspace's `tools/release/release.ps1`.

## What it does

### Mark all and Clear all

Open the Journal map: two buttons sit on the left page, centred directly under the map square. They appear up to about 1.5 s after the map opens: Nucleus places them from the map's measured position, which exists only once the Journal has been drawn.

- **Mark all** puts a waypoint up for every location flag of the current map and the satellite flag (when the map has one). Flags that already had a waypoint keep it and get no second one.
- **Clear all** takes every waypoint down: no flag stays selected, nothing is left on screen.

Each press goes through the flags' own click handlers, so the game spawns, names and removes the waypoints itself, exactly as if you had clicked each flag. A flag counts as selected only when its waypoint really exists, so the map and the screen agree after every press, and after closing and reopening the map (each time the map opens, Waypoints sets every flag's selection from the waypoints that exist).

### After a revive

In the stock game, clicking a location flag (or the satellite flag) on the Journal map puts a waypoint on screen. After you die and are revived at the radio, the map still shows those flags as selected but the waypoints are gone; the only way back is to click each flag twice. The waypoint actors survive the death, but the death and the revive both call `RemoveAllWidgets`, which also clears the layer the on-screen waypoints draw in.

With Waypoints, when you're revived:

- `onRevive = restore` (default): every waypoint you had up before you died is back on screen, with its distance, and the map shows exactly those flags selected. One waypoint per flag.
- `onRevive = clear`: all your waypoints are removed: none on screen, no flag selected.

It works the same for the host, a client or a solo player, also when nobody else runs mods: waypoints are local to each machine (the waypoint actors are unreplicated and spawned without an owner by the machine that clicked). Waypoints sends nothing over the network, spawns nothing replicated, and reads nothing from other players. Pings are not waypoints and are left alone.

## Install

Needs Nucleus 0.9.0 or newer installed and enabled in the same copy (`mods/Nucleus/deploy.ps1`): the buttons use its panels, buttons, Journal events and Journal regions (the `map` region they sit under), and the `onRevive` setting its settings service (`core.settings`, new in 0.9.0).

```powershell
$copy = 'C:\...\nuclear-nightmare\game-instances\<copy>'   # absolute, also from a worktree
./deploy.ps1 -Instance $copy                     # onRevive = restore
./deploy.ps1 -Instance $copy -OnRevive clear
./deploy.ps1 -Instance $copy -Remove
```

`deploy.ps1` refuses (one line, exit 1) when Nucleus is missing, disabled, older than 0.9.0 (`dependsOn` `>=0.9.0`) or has a `compat.floor` above it; it writes `Waypoints : 1` right below Nucleus's line in `mods.txt` (above `Keybinds : 1`), and `Mods/Waypoints/settings.json` when `-OnRevive` is given (otherwise an existing `settings.json` survives the redeploy; `-Test` without `-OnRevive` resets it to `restore`). Without a compatible core, the mod logs exactly one `[Waypoints]` line naming the cause and does nothing.

## The setting

`onRevive` (`restore` | `clear`, default `restore`, changeable anytime). It is declared in `mod.json` and kept by Nucleus's settings service in `Mods/Waypoints/settings.json` (the Mod Manager edits it later; while the game is closed, `deploy.ps1 -OnRevive` writes it, or edit the file: `{"onRevive":"clear"}`). Waypoints reads it with `core.settings.get("onRevive")` at every revive, so a change takes effect at the next revive without a restart. If it can't be read, one `WARN` and `restore`. A release ships no settings file. Test-only `debug` is in `Scripts/dev.lua`, written only by `deploy.ps1 -Test` (git-ignored, never shipped) and read as text, never run.

## Hand check (about 5 minutes; needs a second player for the revive)

Buttons (solo is enough): open the map, click two flags yourself, then **Mark all**: every flag is selected and has one waypoint on screen (the two you clicked keep theirs). **Clear all**: no flag selected, no waypoint. Close and reopen the map: still none. The log has one `MARKALL` and one `CLEARALL` line, both with `failed=0`.

Revive:

1. Deploy core and Waypoints, launch with `tools/launch.ps1`, start a friends-only match with a second player.
2. Open the map, click two location flags and the satellite flag. Three waypoints show on screen.
3. Die (but not as the last living player, and not drowned or infected, or you become a monster instead).
4. Get revived: the other player calls a reinforcement at the nuke computer.
5. **Restore:** the same three waypoints are on screen again with distances, in white; the map shows exactly those three flags selected; clicking one flag once removes its waypoint (one actor per flag).
6. Set `onRevive` to `clear` (close the game, `deploy.ps1 -OnRevive clear`, start it again; or the Mod Manager once it exists), mark again, die, get revived: no waypoint, no flag selected.
7. `./check.ps1 -Instance $copy -Scenario hand` passes: Waypoints connected, every `REVIVE` followed by `RESTORED` or `CLEARED`, no error.

## How it works

- `Scripts/main.lua`: the dependent bootstrap (`connect{ mod = "Waypoints", need = ">=0.9.0" }`), `onRevive` through `core.settings`, and the wiring: one `core.ui.hud.watch` watcher, a `LoadMap` post-hook, and for the buttons a core panel (`id = "waypoints"`, placed by the one constant `PANEL_PLACE` = `{ host = "journal", near = "map", side = "below", align = "center", gap = "tight" }`, horizontal, `gap = "normal"`: 16 units between the two buttons) with the buttons `markAll` and `clearAll`, created before one `core.ui.journal.watch` watcher (so core has attached them when Waypoints' `opened` runs). The open Journal crosses from its `opened` event to a press only as core's weak handle (`core.ref`, freed on `closed`/`lost`); a press re-derefs it. Without core's panel, button or Journal API it logs one ERROR, the revive fix keeps running and `READY` says `buttons=no`. No loop, no per-tick work. With debug on (`deploy.ps1 -Test`) and core's `ui.debug.overlaps` present, each map open also measures the placed panel once, 2.5 s later (retried every 1 s up to 3 times while it isn't painted; skipped when the map closed or opened again meanwhile): `PANELFIT rect=(l,t)-(r,b) screen=<w>x<h> hits=<n> partial=<k>` and up to 10 `PANELHIT under|partial <class> <path> <rect>` lines, or `PANELFIT none (<reason>)`. With debug off nothing is scheduled and `overlaps` is never called (it walks hundreds of widgets).
- `Scripts/panelfit.lua` (pure): classifies each `overlaps` hit as `under` (its rectangle contains the panel: the page paper and map backdrops it sits on) or `partial` (it cuts into the panel: a misfit), and formats those lines.
- `Scripts/mapbuttons.lua` (pure, over the same adapter): **Mark all** reads the open Journal's flags (`MapWidget.MapUI.Levels`, `.Satelite`) and the live waypoint actors (one `FindAllOf` pass), gives every location flag the Journal's character (it must be a live `BP_FirstPersonCharacter_C`, else one WARN and nothing), and clicks each flag key without an actor once (duplicate-name flags share the first widget). **Clear all** clicks each flag once per live actor of its key (the game's handler removes only the first match), stops if a click removes nothing, and destroys any actor still alive or without a flag on this map directly. Both then set every flag's `Selected` from the actors. The map-open sync does the character and `Selected` part only.
- `Scripts/revive.lua` (pure): decides from HUD events alone. On each `attached` it reads the local pawn (the HUD's own `Player`, else its owning player's pawn). A **revive** is the pawn becoming a new `BP_FirstPersonCharacter_C` in the same world after the HUD was lost (the death's `RemoveAllWidgets`). Never `ReceivePossess` (it runs only where the controller has authority). A spectator or monster pawn is not a revive. A new pawn with no HUD loss in between is a **rebound** (restore only, never clear). Within 15 s after a revive, the new pawn's HUD coming back once more (a client's revive multicast can land after the new HUD) re-runs the action (**again**). A new world forgets everything.
- At the first HUD loss (the death) it takes a **snapshot** of the waypoints you have up (name, kind, location: plain data).
- `Scripts/waypoints.lua` (pure, over an adapter): **restore** spawns a fresh waypoint actor for every waypoint you had up (every live actor, plus any snapshot entry whose actor vanished), bound to the new pawn, and only then destroys the old one, so a failed spawn leaves the game's own state; duplicates collapse to one. **Clear** destroys them all. Both then set every flag's `Selected` from the actors (truth is the actor, not the flag) and bind the flags to the new pawn.
- `Scripts/game.lua`: the only file that touches the game (also the Journal's flags and character, the flags' click handlers and their `Selected`/`Character`). It spawns the way the flag's own click does (`BeginDeferredActorSpawnFromClass` with no owner, `Character` and `Name` set before `FinishSpawningActor`, so `BeginPlay` builds the widget), and filters out actors being destroyed (`IsActorBeingDestroyed`) that `FindAllOf` still returns until GC. The action runs 500 ms after the HUD event through `ExecuteInGameThreadWithDelay` (from the game thread), with the pawn carried as a core weak handle.

Log lines (`[Waypoints]`): `READY onRevive=... buttons=yes|no`, `MAPSYNC flags=<n> selected=<n> satellite=yes|no|none` (each map open), `MARK location '<name>'` / `MARK satellite`, `MARKALL marked=<n> already=<n> failed=<n> waypoints=<n> flags=<n> satellite=yes|no|none`, `CLEAR location '<name>'` / `CLEAR satellite`, `CLEARALL cleared=<n> direct=<n> failed=<n> waypoints=<n> flags=<n>` (`waypoints`: live waypoint actors after the press; `flags`: distinct location flag names), `WARN Mark all skipped: the map is not open` (and the same for a character that isn't a live first-person one), `PAWN first ...`, `LOST pawn=... snapshot n=...`, `REVIVE pawn=... was=... snapshot=... onRevive=...`, `REBOUND ...`, `AGAIN ...`, `RESTORE <kind> '<name>' respawned bReplicates=false via ...`, `RESTORED n=...`, `CLEAR ...`, `CLEARED n=...`.

## Tests

### Routine verification

Waypoints is proven on all four maps (stories 4 and 5), so a routine check is one map and as few game runs as possible:

1. `./test.ps1` (no game).
2. **One run on Tower Island**, the combined scenario: `./run.ps1 -Instance $copy -Scenario buttons-revive` (one launch, one match; every check of `buttons` and of `revive`; don't touch the mouse while it runs).
3. `no-core` and `old-core` only when the dependency logic changes (`connect`, `need`, `mod.json`'s `dependsOn`, deploy.ps1's refusals).
4. The pair runs (`mk-client`, `mk-host`) only when networking-relevant code changes: what runs on a client, the revive detector's event order (`revive.lua`), anything replicated or taken from another player.
5. All-maps sweeps (`-Map LowIsland`, `TowerIsland`, `Forest`, `Crevasse`; `buttons-revive` covers both parts) only after a game patch or a change that is per map (the flags, the map's regions, `PANEL_PLACE`, the driver's map table).

`run.ps1` and `deploy.ps1` keep `-Map` for those sweeps; without it the run is on Tower Island. `buttons`, `revive`, `death` and `probe` stay for narrowing down a failure.

**Loop dispatch hint** (bmad-loop and other unattended runs on this repo): verify with `./test.ps1`, then `./run.ps1 -Instance <absolute path to the main checkout's game-instances/<copy>> -Scenario buttons-revive` once, as a background task (it takes about 3 minutes; wait for its completion, don't poll). Add `no-core`/`old-core` or a pair run only under the conditions above, and an all-maps sweep only after a game patch or a per-map change. Never run the four maps "to be safe".

### Unit tests (no game)

```powershell
./test.ps1            # or ./check.ps1 -Scenario unit
```

Lua (`texlua`, MiKTeX's Lua 5.3, or any Lua 5.3/5.4): `revive_test` (the detector against fake HUD events and pawn paths), `waypoints_test` (snapshot, restore, clear and `game.lua` over a fake UE4SS world, failure paths), `mapbuttons_test` (Mark all, Clear all and the map-open sync with the real `game.lua` over fake flags that click as the V8.2 decompile does: every row of story 3's I/O matrix), `panelfit_test` (the under/partial classification and the PANELFIT lines), `main_test` (bootstrap, settings both ways and changed between revives, the whole HUD-event-to-restore path, and the buttons' wiring over a fake core: panel and button arguments, watch order, the Journal's weak handle, presses with no map open, and the debug fit check: debug on and off, retries, stale opens, a throwing `overlaps`), `driver_test` (the test driver loads every scenario). PowerShell: `deploy_test` (version needs, mods.txt, `settings.json` and `dev.lua`, deploy.ps1 end to end on a fake copy), `check_test` (check.ps1 against synthetic logs, each passing as written and failing after one change).

### Single-player scenarios (`run.ps1`, host or VM)

The test driver `test/WaypointsDriver` (installed only by `deploy.ps1 -Test`, never shipped) judges Waypoints by the world: the waypoint actors, the flags, and whether each waypoint is painted on screen (a hook on its widget's text binding, which Slate calls only while it's drawn).

| Scenario | What it proves |
|---|---|
| `probe` | Story 2's first checks: does `MapUI_C`'s `Construct` run on every map open (the Journal opened and closed from Lua four times)? The bug reproduced (`RemoveAllWidgets` stops painting); which repair paints again: toggling the widget space, re-running the actor's `BeginPlay`, or respawning (Waypoints' way); destroyed actors not counted alive |
| `revive` | A revive through the game's own code, solo: the game state's `EOGLock` holds the match (a stand-in for a living teammate), the player really dies (the driver's kill, below), then `BP_Radio_C:ReinforceSpecficPlayer(dead body)` spawns and possesses a new character as a reinforcement does; `EOGLock` is released after it. `restore`: one actor per waypoint, bound to the new pawn, painted, `bReplicates=false`, flags match; same Journal instance after the revive? Then the driver sets `onRevive` to `clear` through Nucleus's settings service (a raw `settings-set` on core's channel; it logs the reply, `SETTINGS onRevive=clear via settings-set reply=ok:...`) and revives again: nothing left |
| `buttons` | Story 3, solo: 2 location flags marked by their own click (not the satellite), the map opened by the real key `IA_Map` is bound to (read from `IMC_Default`, posted to the game window like Enter), **Mark all** clicked with the real mouse (the button found on the map page by core's tag, its centre from core's `Nucleus_AbsTopLeft`/`_AbsBottomRight`): one live waypoint actor per flag and the satellite, every flag `Selected`, `bReplicates=false`; **Clear all**: none left, none `Selected`; the map closed and reopened by the key: every flag's `Selected` matches its actor (`FLAGSMATCH`). `check.ps1` also requires one `MARKALL` with `already=2 failed=0` whose `marked`, `flags` and `waypoints` match the driver's `EXPECT` line (distinct flag names - 2 + 1 for a satellite flag), one `CLEARALL` with `failed=0 waypoints=0`, and a `MAPSYNC` after it. The clicks take the mouse for a moment on the host (the game window is brought to the front). With `-Map <key>` it runs on that map; the driver also checks the map's distinct flag names against its table (`FLAGCOUNT`) and `check.ps1` that `MARKALL flags=` equals the driver's `MAP ... flags=`. Story 5: after both key opens the driver waits (up to 8 s, instead of a fixed settle) until the panel sits where `PANEL_PLACE` says, measured in the map page canvas's units through core's `Nucleus_RectIn` (`OK PANELPLACE`: panel top = map bottom + 8, panel centre x = map centre x, inside `page-left`, each within 1 unit), and `check.ps1` requires both `PANELPLACE` lines and a `PANELFIT ... partial=0` with none above 0 |
| `buttons-revive` | **The routine check**: `buttons`, then `revive`, in one launch and one match. After the reopen (Clear all left nothing up) the driver marks again from Lua (phase `remark`: 2 location flags and the satellite), dies by the driver's kill, is revived through the radio with `EOGLock` held, and runs every revive check (restore, then `clear`). `check.ps1 -Scenario buttons-revive` requires the union of both scenarios' checks with the same hard and soft rules (`OK MARKED mark 2` and `OK MARKED remark 3`; `buttons`' "no revive action" rule is dropped, since the revives are expected). Unlike `revive`, its deaths come after the lobby countdown (the buttons part cuts it so the map key works): not yet run in game. About 3 minutes on the host (Tower Island: about 50 s to the match, 27 s of buttons, 87 s of revives) against about 3 min 40 s for `buttons` plus `revive`, and one launch instead of two |
| `death` | Death to spectator, solo: nothing happens, the waypoint actors survive (the snapshot at the death is a soft check: since V8.1.3 the game's managed death keeps the HUD). Also answers whether the waypoints paint while dead (`ANSWER painted-while-dead`). `buttons-revive` covers its kill, `DIED`/`SPECTATOR` and the painted-while-dead answer, and its `RESTORED ... from actors 3` shows the actors survive a death; what only `death` adds is a death **not** followed by a revive (the solo match ending): no `REVIVE`/`REBOUND`/`RESTORED`, the actors kept and not rebound (`KEPT`, `UNTOUCHED`). Run it when the death or HUD-loss handling (`revive.lua`) changes, not routinely |
| `no-core`, `old-core` | One `[Waypoints]` line naming the cause; `deploy.ps1` refuses first |

**The map (`-Map`).** The solo scenarios travel to one of four maps, picked by `run.ps1 -Map <key>` (passed to `deploy.ps1 -Test -Map`, which writes only the key to the driver's `Scripts/map.txt`). The driver holds the table; nothing else from the file is used:

| Key | Map | Location flags |
|---|---|---|
| `LowIsland` | `/Game/Maps/Gameplay` | 10 |
| `TowerIsland` (default) | `/Game/Maps/SmallLoweIsland/SmallMap` | 6 |
| `Forest` | `/Game/Maps/ForestMap/ForestMap` | 7 |
| `Crevasse` | `/Game/Maps/CravasseMapV2/CravasseMap` | 9 |

Without `-Map` there is no `map.txt` and the run is on Tower Island, as before (`<scenario>.log`); with it the log is kept as `<scenario>-<key>.log`. Every test deploy removes a stale `map.txt`. The driver logs `MAP <key> <path> flags=<n>`; an unknown key in `map.txt` ends the run before any travel (`FAIL MAP unknown map key`, `END result=FAIL`).

```powershell
$copy = 'C:\...\nuclear-nightmare\game-instances\<copy>'
./run.ps1 -Instance $copy -Scenario buttons-revive        # the routine check (Tower Island): don't touch the mouse while it runs
./run.ps1 -Instance $copy -Scenario probe                 # host: only with no other game running
./run.ps1 -Instance $copy -Scenario buttons               # host: don't touch the mouse while it runs (real clicks)
./run.ps1 -Instance $copy -Scenario buttons -Map Crevasse # the same on The Crevasse (LowIsland, TowerIsland, Forest, Crevasse)
./run.ps1 -Instance $copy -Scenario revive -Target vm     # in the Hyper-V VM (tools/vm/README.md, "Single-player tests in the VM")
./run.ps1 -Instance $copy -Scenario death -Target vm
./check.ps1 -Log <workspace>\dumps\<copy>\waypoints\probe.vm.log -Scenario probe -Target vm
```

**The driver's kill (V8.1.5+).** Since V8.1.5 `DeathEvent()` does nothing on a pawn that took no real damage (its `MoreDeathFX` starts with the native gate `NNDeathFadeLibrary:CanBeginTerminalDeathEffects`, false while Health > 0), so the driver kills with the game's own damage: one `CallDamageEvent(1000)` on the host, then the game's whole death, which takes about 12 s (the fade). It judges the death by the game's signals, never the HUD: `DIED` (right away, Health <= 0 and the gate open, called as a UFunction on `Default__NNDeathFadeLibrary`) and `SPECTATOR` (the controller's pawn is `Spectator_C`, about 12 s later); step timeout 60 s. Only if the character is still possessed after 30 s does it set Health 0 and call `DeathEvent()` (a `FALLBACK` line, a soft check). `TRACE` and `HUDSTATE` lines log the death path; `PAINTLINE` logs the old waypoint's paints through the reinforcement. Ported from the V8.1.5 runs (`dumps/v8.1.5-build26357084/markers/revive.vm.log`, PASS); `revive` passes on V8.2.1 (below).

With `-Target vm`, core comes from `mods/Nucleus/build/package` and Waypoints plus the driver from this repo's `deploy.ps1 -Staged`; the VM copy is put back afterwards. Every Waypoints scenario may run in the VM (none judges timing). Take the workspace's `dumps/vm.lock` around VM runs while other agents share the VM.

**Story 5, buttons under the map square (V8.2.1 build 26512322, Nucleus 0.6.0, Waypoints 0.2.0, 2026-11-11, fresh runs after the first attempt was rolled back; logs `dumps/v8.2-build26512322/waypoints/buttons.vm.log`, `buttons-<map>.log`, `revive-<map>.log`): the panel fits under the map at both sizes, so the placement is `PANEL_PLACE` = `{ host = "journal", near = "map", side = "below", align = "center", gap = "tight" }` and the fallback (`{ corner = "bottom-left", region = "page-left", inset = "tight" }`) is not used. Every run passes.**

| Run | Result |
|---|---|
| `buttons -Target vm` (1280x720, 16:9) | PASS (16 checks): `OK PANELPLACE` on both key opens, panel (424,829)-(642,882) in canvas units under the map (165,210)-(901,821), top - (map bottom + 8) = 0.0, centre dx = 0.0, inside `page-left` (130,108)-(937,897); `PANELFIT rect=(605,709)-(750,744) screen=1280x720 hits=5 partial=0` on every open |
| `buttons -Map LowIsland`, `TowerIsland`, `Forest`, `Crevasse` (host, 3440x1440) | PASS each (16 checks): `MARKALL ... flags=` 10 / 6 / 7 / 9 with `already=2 failed=0`, `CLEARALL ... waypoints=0`; `OK PANELPLACE` on both opens, panel (616,829)-(832,882) under the map (356,210)-(1092,821), dy = 0.0, dx = 0.0, inside `page-left` (175,108)-(1259,896); `PANELFIT rect=(825,1107)-(1114,1178) screen=3440x1440 hits=5 partial=0` (Low Island `hits=4`: its map image `MapUI.Image` doesn't reach under the panel) on every open |
| `revive -Map LowIsland`, `TowerIsland`, `Forest`, `Crevasse` (host) | PASS each (14 checks), unchanged; their Lua map opens also logged `PANELFIT ... partial=0` |

Every hit was `under`: the left page paper (`NN_LeftFieldPaper`, `NN_LeftPaperBack`) and three of `MapUI`'s own backdrop images (`Image`, `Image_1`, `Image_2`), which are larger than the measured map square and contain the panel. No map widget, perk hex or other element cuts into it. The only soft check not met in any run was core's `hud slow tick` WARN. Timing: core's contract allows the panel to appear 1-1.5 s after the map opens (it stays collapsed until the Journal's first paint); in these runs the driver measured it already placed 0.3 s after the Journal reached the viewport (`after 0.3 s`), its first look after its own `opened` step. The pair scenarios (`mk-client`, `mk-host`) were not re-run on Nucleus 0.6.0 or this placement: the pair press's new wait for the button to be drawn (`shown`) is unexercised in game.

**After these runs (2026-11-11): more space between the buttons.** The panel now passes `gap = "normal"` (16 units, core pads Clear all's left side) instead of core's default `tight` (8), both buttons still in the one panel box; `PANEL_PLACE` (its own `gap = "tight"`: 8 units between the map and the panel) is unchanged. Not yet run in game. Expected from the numbers above: the panel grows by 8 canvas units, from 218 to about 226 wide at 1280x720 (216 to about 224 at 3440x1440), still centred on the map, so about (420,829)-(646,882) at 1280x720 and (612,829)-(836,882) at 3440x1440: inside the map square's width (736) and `page-left` (807 at 1280x720, 1084 at 3440x1440) with at least about 290 units of the page to spare on each side (1280x720; over 420 at 3440x1440). On screen that is about 5 px wider at 1280x720 (145 to about 150 px) and about 11 px at 3440x1440 (289 to about 300 px). The panel's height and top don't change, so `PANELPLACE` (top = map bottom + 8, centre dx = 0) should still hold; the `under` hits (page paper, `MapUI`'s backdrop images) are far wider than the panel, so `PANELFIT ... partial=0` is expected at both sizes. The next `buttons-revive` run confirms it at 3440x1440; 1280x720 needs a `-Target vm` run.

**Release runs on the host (story 4: V8.2.1 build 26512322, Nucleus 0.5.0, Waypoints 0.2.0, 2026-11-10; logs `dumps/v8.2-build26512322/waypoints/*.log`): every scenario passes.**

| Run | Result |
|---|---|
| `buttons -Map LowIsland` | PASS (2nd try, below): `MARKALL marked=9 already=2 failed=0 waypoints=11 flags=10 satellite=yes`, `CLEARALL cleared=11 direct=0 failed=0 waypoints=0 flags=10` |
| `buttons -Map TowerIsland` | PASS: `MARKALL marked=5 already=2 failed=0 waypoints=7 flags=6`, `CLEARALL cleared=7 ... waypoints=0` |
| `buttons -Map Forest` | PASS: `MARKALL marked=6 already=2 failed=0 waypoints=8 flags=7`, `CLEARALL cleared=8 ... waypoints=0` |
| `buttons -Map Crevasse` | PASS: `MARKALL marked=8 already=2 failed=0 waypoints=10 flags=9`, `CLEARALL cleared=10 ... waypoints=0` |
| `no-core`, `old-core` | PASS: `deploy.ps1` refused in one line, then one `[Waypoints]` line naming the cause |
| `probe` | PASS (6 checks); `construct-every-open=yes flags-rebuilt-each-open=yes`; repairs: respawn and re-running `BeginPlay` paint again, toggling the widget space did not (on V8.1.2 the toggle failed too) |
| `death` | PASS (6 checks); `painted-while-dead=yes` |
| `revive` (Tower Island, then `-Map LowIsland`, `Forest`, `Crevasse`) | PASS on all four maps (14 checks each): `RESTORED n=3 (... failed 0 ...)`, then with `clear` `CLEARED n=3 (failed 0)`; with `-Map`, run.ps1 confirmed the travelled map (`MAP <key>`) |

Every map has a satellite flag (`satellite=yes`), every `buttons` run had 14 driver checks and 0 failures, `FLAGCOUNT` matched the table (10/6/7/9), and the flags stayed in step with the actors after the key close and reopen (`FLAGSMATCH`). The first `buttons -Map LowIsland` failed after a good Mark all: the real-mouse click on **Clear all** was made but reached no button (no `clicked` line from core), and the map keys after it no longer closed and reopened the map as expected (three `TIMEOUT`s). The cause is not proven; the host's desktop was in use at the time, which can move the real mouse between the driver's aim and its click. The rerun, unchanged, passed (log of the first try: `buttons-LowIsland.try1.log`). Each map run took about 75-110 s.

**Results on the host (V8.2.1 build 26512322, Nucleus 0.5.0, 2026-11-10, story 3; logs `dumps/v8.2-build26512322/waypoints/{buttons,revive}.log`): `buttons` and `revive` pass.**
- `buttons` (Tower Island, 6 location flags and the satellite flag): `MARKALL marked=5 already=2 failed=0 waypoints=7 flags=6 satellite=yes`, one actor per flag, all 7 flag widgets selected; `CLEARALL cleared=7 direct=0 failed=0 waypoints=0 flags=6`, none selected; after the key close and reopen `MAPSYNC flags=6 selected=0 satellite=no` and `FLAGSMATCH`. 13 driver checks, 0 failures. Both buttons were found once each in the panel's box and clicked with the real mouse; the map opened and closed by the real `M` key.
- `revive` with Waypoints 0.2.0: unchanged (restore then clear, 14 checks, 0 failures). Every map open the driver makes now also logs a `MAPSYNC`.
- In `revive`, one soft `hud slow tick` on a `journal opened` event tick (4.5 ms: core's attach of the panel and buttons plus Waypoints' `MAPSYNC`, one `FindAllOf` pass and the flag writes); the other soft slow ticks (one per run) were core's own `prepare` ticks.

**Results in the VM (V8.1.2, 2026-10-26; logs `dumps/v8.1.2-build26193463/markers/*.vm.batch2.log`): probe, death and revive all pass.**
- `MapUI_C`'s `Construct` runs on every map open, and every open gets a **new Journal instance** with all its flags rebuilt (4 opens, 4 Journals). So after a revive the Journal is a new instance too (`journal-same-after-revive=no`); the flags it builds take `Selected` from the waypoint actors, which is why "truth is the actor" is enough.
- `RemoveAllWidgets` stops every waypoint from painting (the bug). A respawned actor paints again (this mod's way, `bReplicates=false`); re-running the actor's `BeginPlay` also works; toggling the widget component's space does not.
- Liveness: a waypoint its flag just destroyed is still returned by `FindAllOf`, with `IsActorBeingDestroyed() == false` and UE4SS's `IsValid() == true`; UE's own `KismetSystemLibrary:IsValid` (called as the UFunction) is false, and `game.lua` uses it.
- Death: `ExplosionDamage` from Lua didn't kill; `DeathEvent()` did. The player became a `Spectator_C`, the waypoint actors survived, the mod took its snapshot and did nothing else.
- Revive (through the radio's own code): `LOST` → `REVIVE` → `RESTORED n=3` about 1.3 s later, every waypoint bound to the new pawn and painted, the map showing exactly those flags; then with `clear`: `CLEARED n=3`, nothing painted, no flag selected.
- The snapshot at `lost` costs about 2 ms inside core's HUD tick (a soft `hud slow tick ... HUD event: lost` warning).
- The match's landing showcase: about 5 s after the pawn and HUD are up, the game state's `UpdateHeliVis` puts the view on the landing helicopter's camera for 9 s and blends back over 3 s. A paint check in that time aims the control rotation but not the rendered camera, so waypoints out of the helicopter's view read 0 (the flaky `DRAWN before` of 2026-10-27). The driver now waits for the view to be back on the pawn (`VIEW`, `HUD` lines), re-aims every tick and counts a waypoint's window only if the rendered camera stayed within 10° of it (`AIM` lines; up to 4 tries). After the fix, revive passed 3 times in a row in the VM.

### Two-player scenarios (the real revive; need tools/vm/pair.ps1)

A solo player can't be revived (the last death ends the match), so the real thing needs two players: `test/pair/waypoints-scenarios.ps1`, in `pair.ps1`'s scenario shape, friends-only lobbies only.

| Scenario | Host A (this PC) | Client B (VM) | Judged by |
|---|---|---|---|
| `mk-client` | WaypointsDriver `pair-host` only (no Waypoints): marks one location flag of its own, waits, signals B's kill (B calls `CallDamageEvent(1000)` on its own pawn), calls `BP_Radio_C:Reinformant()` (the computer's "call reinforcement"), waits 90 s for B's checks and buttons, then checks its own waypoint untouched: exactly that one waypoint actor, its flag `Selected`, no other (`UNAFFECTED host`, CAP-3) | Nucleus + Waypoints + WaypointsDriver `pair-victim`: marks 2 flags + satellite, dies, is revived; then the revive checks; then **Mark all** and **Clear all** on its map (opened from Lua), each pressed through core's `Nucleus_OnClicked()` (`BPRESS`), with the world checks of `buttons` (`ALLMARKED`, `ALLSELECTED`, `ALLCLEARED`, `NONESELECTED pair`) | `check.ps1 -Scenario pair-victim` (VM log: also one `MARKALL ... already=3 failed=0`, one `CLEARALL ... failed=0 waypoints=0`), `-Scenario pair-host` (host log: `OK MARKED host`, `OK UNAFFECTED host`) |
| `mk-host` | Nucleus + Waypoints + WaypointsDriver `pair-hostvictim`: marks, dies, reinforces itself | vanilla (UE4SS off), stays alive | `check.ps1 -Scenario pair-hostvictim` (host log) |

`pair.ps1` loads this file with `-ScenarioFile` and installs the host's mods with the scenario's `HostModPaths` (for the run only; removed afterwards, also by `-Stop`). Before running:
- core is built (`mods/Nucleus/build/package`; `mods/Nucleus/build.ps1`, not while a game runs);
- the host copy has no Waypoints, WaypointsDriver or Nucleus of its own (`mk-client`'s Prereq and `pair.ps1` both refuse otherwise; take them out with their `deploy.ps1 -Remove`);
- the VM is set up as in the workspace's `tools/vm/README.md` (B signed in), nothing else uses it (`dumps/vm.lock`), and nobody plays on the host: `pair.ps1` waits until no Nuclear Nightmare runs on this PC.

From the workspace's main checkout, one at a time:

```powershell
./tools/vm/pair.ps1 -Scenario mk-client -ScenarioFile mods/waypoints/test/pair/waypoints-scenarios.ps1
./tools/vm/pair.ps1 -Scenario mk-host   -ScenarioFile mods/waypoints/test/pair/waypoints-scenarios.ps1
# after an aborted run (closes both games, puts the host and VM copies back):
./tools/vm/pair.ps1 -Stop -Scenario mk-client -ScenarioFile mods/waypoints/test/pair/waypoints-scenarios.ps1
```

**The pair client's presses are not OS clicks.** Nothing serves mouse clicks in a pair run (the VM's game gets no input from the driver), so the client's driver calls the button widget's `Nucleus_OnClicked()`, the Blueprint function the button's `OnClicked` calls; this skips the UMG button's own hit test and its `OnClicked` delegate; core's dispatch hook (tag, enabled, visible, 250 ms debounce) and Waypoints' `onClick` run on it as for a click. The real mouse path is covered by the solo `buttons` scenario on all four maps.

Each run writes `dumps/<copy>/pair/<label>.json` (its `ScenarioReport` holds the `check.ps1` results, `ScenarioVerdict` PASS/FAIL) and the host log next to it; the VM log and screenshots (`marked`, `dead`, `revived`, `buttons`, `play`, `end`; `host-dead`, `after`) go to `dumps/<copy>/vm/`. To re-judge by hand: `./check.ps1 -Log <vm log> -Scenario pair-victim -Target vm`, `./check.ps1 -Log <host log> -Scenario pair-host` (or `pair-hostvictim`). Without the game: the workspace's `tools/vm/tests/pair-scenariofile.tests.ps1 -StageWaypoints` loads this file and stages every role.

The kill (V8.1.5+; on V8.1.2 it was `DeathEvent()`, which no longer kills) is one `CallDamageEvent(1000)` and the game's own death (see "The driver's kill" above). In `mk-host` the host calls it on its own pawn. In `mk-client` the host logs `KILL victim ... signal`, the scenario file writes `Scripts\kill.txt` into the VM's WaypointsDriver, and B calls `CallDamageEvent(1000)` on its own pawn (`SELFKILL` lines; the character's server RPC, which killed B on V8.2.1 without the fallback, 2026-11-10). If B's character is still alive 30 s after the signal, the host calls `CallDamageEvent(1000)` on it itself (`KILL victim FALLBACK`, a soft check; the host-side kill of a client is proven on V8.2). The victim must die neither drowned nor infected (or it becomes a monster: `pair-host` then fails as inconclusive). The hand check above is the fallback.

**Results (V8.2.1 build 26512322, Nucleus 0.5.0, Waypoints 0.2.0, 2026-11-10, friends-only lobby, host + VM): `mk-client` PASS, `mk-host` PASS** (`ScenarioVerdict` PASS in `dumps/v8.2-build26512322/pair/mk-client-20261110-153345.json` and `mk-host-20261110-154109.json`; VM log and screenshots in `dumps/v8.2-build26512322/vm/`; Tower Island, PairDriver's map).
- **`mk-client`:** B's self-kill (`SELFKILL`, no fallback) → `Spectator_C` 12.2 s later → the host's `Reinformant()` → `REVIVE ... snapshot=3` → `RESTORED n=3 (from actors 3, from the snapshot 0, failed 0, old destroyed 3)`; `ONE`, `BOUND`, `LOCAL`, `DRAWN`, `FLAGSMATCH` revive. Then on B's map: `BPRESS markAll via Nucleus_OnClicked` → `MARKALL marked=4 already=3 failed=0 waypoints=7 flags=6 satellite=yes`, `ALLMARKED`/`ALLSELECTED`/`LOCAL pair`; `BPRESS clearAll` → `CLEARALL cleared=7 direct=0 failed=0 waypoints=0 flags=6`, `ALLCLEARED`/`NONESELECTED pair`. 19 driver checks, 0 failures. The unmodded host (CAP-3): its own `Weather Station` waypoint, marked before B's death, was still its only waypoint actor afterwards, with its name, its flag `Selected`, no other flag selected (`OK UNAFFECTED host`). The `buttons` screenshot shows B's game with no waypoint on screen and the map closed.
- **`mk-host`:** `LOST` → `REVIVE` → `RESTORED n=3 ... failed 0`, `ONE`, `BOUND`, `LOCAL`, `DRAWN`, `FLAGSMATCH`; 9 checks, 0 failures; vanilla B unaffected.
- On V8.2.1 the waypoints survive a death on their own (the managed death keeps the HUD), so these revive checks prove that restore and clear still behave after a real revive, not that a wipe is repaired.
- Both runs needed NNB at 8 GB: at its 12 GB (the author setup) the host had only 5.1-5.4 GB available and `pair.ps1` refused to launch (first attempt, 15:25). NNB was set to 8 GB for the runs and back to 12 GB afterwards (workspace `tools/vm/README.md`, "Memory").

**Results (V8.1.2, 2026-10-27, friends-only lobby, host + VM): `mk-client` PASS, `mk-host` PASS.** Logs and JSON: `dumps/v8.1.2-build26193463/pair/mk-client-20261027-015454.*`, `mk-host-20261027-020047.*`; VM log and screenshots in `dumps/v8.1.2-build26193463/vm/`.
- **`mk-client`, the mod on a client (B) of an unmodded host:** a real death (B became `Spectator_C`) and a real reinforcement by the teammate (the host's `BP_Radio_C:Reinformant()`), and the waypoints came back: `RESTORED n=3 (from actors 3, from the snapshot 0, failed 0, old destroyed 3)`, one actor per waypoint, bound to the new pawn, `bReplicates=false`, `DRAWN revive`, `FLAGSMATCH` (Crash Site, Satellite, Weather Station), 7 checks, 0 failures; `pair-host` PASS on the host. The `play` and `end` screenshots show the three waypoints with distances, in white, with the HUD back. The `revived` screenshot came too early (at the new pawn, before `RESTORED`; the scenario now times it from the host's `OK REVIVED`).
- **Event order on the client:** `SELFKILL` → `LOST ... snapshot n=3` (the HUD lost at the death, 12 s after the first kill call) → `DEAD` as `Spectator_C` → host `REINFORCE` → the new pawn with a HUD 1.7 s later (`NEWPAWN`) → `REVIVE ... snapshot=3` 0.4 s after it → `RESTORED n=3` 0.5 s later (the action delay) → painted. No `AGAIN` and no `REBOUND`: on the client the radio's `RemoveAllWidgets` didn't land after the new HUD, so the settle window wasn't needed (one run).
- **`mk-host`, the mod on the host with a vanilla client:** the same: `LOST` → `REINFORCE` → `NEWPAWN` 1.6 s later → `REVIVE` 0.8 s later → `RESTORED n=3 ... failed 0` → `DRAWN`, `FLAGSMATCH`, 7 checks, 0 failures; no `AGAIN`. B's screenshots show a normal match, with no notification or chat.
- **Which call kills is not settled:** in all three deaths so far (solo `death`, `mk-host`, `mk-client`) `LOST` came about 7 s after the *second* kill call (`DeathEvent` again on the host, `CallDamageEvent(100)` on the client), and 12 s after the first, while the 5 s re-check found the pawn still possessed. A death's animation may simply take that long. A run with a longer re-check would tell; the mod doesn't depend on it.
- Not run as a pair: `onRevive = clear` on a client (solo `revive` covers clear on the host).

## Known risks

- `buttons-revive` (the routine check) and the panel's `gap = "normal"` have not run in game yet (2026-11-11). Its revives are the first solo ones after the lobby countdown (the buttons part cuts it; `revive` dies and revives during the countdown, in the CH-47 cabin): the match proper is running then, with the player on the ground. If it fails there and `revive` alone passes, that difference is the first suspect.
- The revive's order of events on a client: one `mk-client` run saw the new HUD after every `RemoveAllWidgets` (no `AGAIN`); the settle window ("again") stays for a late multicast under real latency.
- `FTransform` marshalling for `BeginDeferredActorSpawnFromClass` works (VM runs); the fallback (`SpawnActor` + the actor's own `BeginPlay` graph) stays, logged as such.
- The two-player revive passed once per role on V8.1.2 (2026-10-27) and once per role on V8.2.1 (2026-11-10), between this PC and the VM on one host: little latency. `onRevive = clear` on a client is not run.
- The pair client's buttons are pressed through `Nucleus_OnClicked()`, not by an OS click (nothing serves clicks in a pair run); the real mouse path is proven solo only.
- Mark all / Clear all on a modded host with a client in the match is not run as a pair (only solo, and on a modded client of an unmodded host).
- The first `buttons -Map LowIsland` try (2026-11-10) failed with the cause unproven: the real click on **Clear all** reached no button, then the map-key steps timed out (`TIMEOUT`). Its log was renamed by hand to `buttons-LowIsland.try1.log`, since `run.ps1` overwrites `<scenario>-<map>.log`; the rerun passed.
- Other `RemoveAllWidgets` callers (the player controller, the Wendigo head, the endgame bomb) also hide waypoints without a revive; Waypoints acts only on revives (same pawn back after a loss is logged at DEBUG and left alone).
- `BP_Radio_C:SpawnReinformantRPC` would revive the same character (no new pawn, and it calls `RemoveAllWidgets`): Waypoints would see a HUD loss and the same pawn back and do nothing. Nothing calls it in V8.1.2 or V8.2 (only the unused `SpawnReinformant`).

- Mark all and Clear all pass on all four maps (V8.2.1, `buttons -Map`, 2026-11-10). Every V8.2.1 map has a satellite flag, so `satellite=none` (a map without a `Lever_Actor_C`) is covered by unit tests only.
- The `MAPSYNC` at each map open runs inside core's Journal event tick (a few ms with the actor read); it's an event tick, so core's slow-tick warning for it is soft.
- A Mark all whose click spawns a satellite waypoint is counted by the flag's `Selected` turning true (the satellite handler keeps no actor reference); `waypoints=` in `MARKALL` is the earlier actors still alive plus one per successful click, not a second `FindAllOf`.

Files to add to the workspace's `tools/diff-dumps.watch.json` when Waypoints ships: `flag-mechanics.md`, "Hooks and calls the mod relies on", plus `InventoryUI_C.Player`, `AActor:IsActorBeingDestroyed`, `GameplayStatics:BeginDeferredActorSpawnFromClass`/`FinishSpawningActor`. The Journal map symbols the buttons use (`MapUI_C.Satelite`, `SateliteUI_C`'s `Selected`, `Button_28` and click handler) are in it.

## Feedback

Bug reports, ideas and questions go to [NuclearNightmare-Community/feedback](https://github.com/NuclearNightmare-Community/feedback). For a security problem, please report it privately: see its [SECURITY.md](https://github.com/NuclearNightmare-Community/feedback/blob/main/SECURITY.md).
