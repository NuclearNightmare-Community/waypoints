# Markers

A Nuclear Nightmare mod (UE4SS Lua, on the Nucleus core) that fixes the map markers after a revive.

**0.1.0 = the revive fix only** (spec `_bmad-output/specs/spec-markers-v1/` in the workspace, story 2 plus the repo, bootstrap, deploy and check parts it needs). The **Mark all / Clear all** buttons are 0.2.0 and wait for core 0.3.0 (panels and buttons).

## What it does

In the stock game, clicking a location flag (or the satellite flag) on the Journal map puts a waypoint on screen. After you die and are revived at the radio, the map still shows those flags as selected but the waypoints are gone; the only way back is to click each flag twice. The waypoint actors survive the death, but the death and the revive both call `RemoveAllWidgets`, which also clears the layer the on-screen waypoints draw in.

With Markers, when you're revived:

- `onRevive = restore` (default): every marker you had up before you died shows its on-screen waypoint again, with its distance, and the map shows exactly those flags selected. One waypoint per flag.
- `onRevive = clear`: every marker is cleared: no waypoint, no flag selected.

It works the same for the host, a client or a solo player, also when nobody else runs mods: markers are local to each machine (the waypoint actors are unreplicated and spawned without an owner by the machine that clicked). Markers sends nothing over the network, spawns nothing replicated, and reads nothing from other players. Pings are not markers and are left alone.

## Install

Needs Nucleus 0.2.x installed and enabled in the same copy (`mods/Nucleus/deploy.ps1`).

```powershell
$copy = 'C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463'   # absolute, also from a worktree
./deploy.ps1 -Instance $copy                     # onRevive = restore
./deploy.ps1 -Instance $copy -OnRevive clear
./deploy.ps1 -Instance $copy -Remove
```

`deploy.ps1` refuses (one line, exit 1) when Nucleus is missing, disabled, older than 0.2.0 (`dependsOn` `>=0.2.0`) or has a `compat.floor` above it (the `>=` form is read by Nucleus 0.5.0 and newer, core story 18); it writes `Markers : 1` right below Nucleus's line in `mods.txt` (above `Keybinds : 1`) and generates `Scripts/settings.lua` from `mod.json`. Without a compatible core, the mod logs exactly one `[Markers]` line naming the cause and does nothing.

## The setting

`onRevive` (`restore` | `clear`, default `restore`, changeable anytime). Until core's settings service exists it lives in `Mods/Markers/Scripts/settings.lua`; Markers reads it again at every revive, so editing that file (`return { onRevive = "clear" }`) takes effect at the next revive without a restart. `deploy.ps1 -OnRevive` writes it while the game is closed.

## Hand check (about 5 minutes; needs a second player for the revive)

1. Deploy core and Markers, launch with `tools/launch.ps1`, start a friends-only match with a second player.
2. Open the map, click two location flags and the satellite flag. Three waypoints show on screen.
3. Die (but not as the last living player, and not drowned or infected, or you become a monster instead).
4. Get revived: the other player calls a reinforcement at the nuke computer.
5. **Restore:** the same three waypoints are on screen again with distances, in white; the map shows exactly those three flags selected; clicking one flag once removes its waypoint (one actor per flag).
6. Set `onRevive = "clear"` in `settings.lua`, mark again, die, get revived: no waypoint, no flag selected.
7. `./check.ps1 -Instance $copy -Scenario hand` passes: Markers connected, every `REVIVE` followed by `RESTORED` or `CLEARED`, no error.

## How it works

- `Scripts/main.lua`: the dependent bootstrap (`connect{ mod = "Markers", need = ">=0.2.0" }`), settings, and the wiring: one `core.ui.hud.watch` watcher and a `LoadMap` post-hook. No loop, no per-tick work.
- `Scripts/revive.lua` (pure): decides from HUD events alone. On each `attached` it reads the local pawn (the HUD's own `Player`, else its owning player's pawn). A **revive** is the pawn becoming a new `BP_FirstPersonCharacter_C` in the same world after the HUD was lost (the death's `RemoveAllWidgets`). Never `ReceivePossess` (it runs only where the controller has authority). A spectator or monster pawn is not a revive. A new pawn with no HUD loss in between is a **rebound** (restore only, never clear). Within 15 s after a revive, the new pawn's HUD coming back once more (a client's revive multicast can land after the new HUD) re-runs the action (**again**). A new world forgets everything.
- At the first HUD loss (the death) it takes a **snapshot** of the markers up (name, kind, location: plain data).
- `Scripts/markers.lua` (pure, over an adapter): **restore** spawns a fresh waypoint actor for every marker up (every live actor, plus any snapshot entry whose actor vanished), bound to the new pawn, and only then destroys the old one, so a failed spawn leaves the game's own state; duplicates collapse to one. **Clear** destroys them all. Both then set every flag's `Selected` from the actors (truth is the actor, not the flag) and bind the flags to the new pawn.
- `Scripts/game.lua`: the only file that touches the game. It spawns the way the flag's own click does (`BeginDeferredActorSpawnFromClass` with no owner, `Character` and `Name` set before `FinishSpawningActor`, so `BeginPlay` builds the widget), and filters out actors being destroyed (`IsActorBeingDestroyed`) that `FindAllOf` still returns until GC. The action runs 500 ms after the HUD event through `ExecuteInGameThreadWithDelay` (from the game thread), with the pawn carried as a core weak handle.

Log lines (`[Markers]`): `READY onRevive=...`, `PAWN first ...`, `LOST pawn=... snapshot n=...`, `REVIVE pawn=... was=... snapshot=... onRevive=...`, `REBOUND ...`, `AGAIN ...`, `RESTORE <kind> '<name>' respawned bReplicates=false via ...`, `RESTORED n=...`, `CLEAR ...`, `CLEARED n=...`.

## Tests

### Unit tests (no game)

```powershell
./test.ps1            # or ./check.ps1 -Scenario unit
```

Lua (`texlua`, MiKTeX's Lua 5.3, or any Lua 5.3/5.4): `revive_test` (the detector against fake HUD events and pawn paths), `markers_test` (snapshot, restore, clear and `game.lua` over a fake UE4SS world, failure paths), `main_test` (bootstrap, settings both ways and changed between revives, the whole HUD-event-to-restore path over a fake core), `driver_test` (the test driver loads every scenario). PowerShell: `deploy_test` (version needs, mods.txt, enum settings, deploy.ps1 end to end on a fake copy), `check_test` (check.ps1 against synthetic logs, each passing as written and failing after one change).

### Single-player scenarios (`run.ps1`, host or VM)

The test driver `test/MarkersDriver` (installed only by `deploy.ps1 -Test`, never shipped) judges Markers by the world: waypoint actors, flags, and whether each on-screen waypoint is painted (a hook on its widget's text binding, which Slate calls only while it's drawn).

| Scenario | What it proves |
|---|---|
| `probe` | Story 2's first checks: does `MapUI_C`'s `Construct` run on every map open (the Journal opened and closed from Lua four times)? The bug reproduced (`RemoveAllWidgets` stops painting); which repair paints again: toggling the widget space, re-running the actor's `BeginPlay`, or respawning (Markers' way); destroyed actors not counted alive |
| `revive` | A revive through the game's own code, solo: the death's `RemoveAllWidgets`, then the local character queued (`UpdateRespawnQue`) and `BP_Radio_C:ReinforceSpecficPlayer`, which spawns and possesses a new character as a reinforcement does. `restore`: one actor per marker, bound to the new pawn, painted, `bReplicates=false`, flags match; same Journal instance after the revive? Then the driver switches `settings.lua` to `clear` and revives again: nothing left |
| `death` | Death to spectator, solo: the snapshot is taken, nothing else happens, the waypoint actors survive |
| `no-core`, `old-core` | One `[Markers]` line naming the cause; `deploy.ps1` refuses first |

```powershell
$copy = 'C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463'
./run.ps1 -Instance $copy -Scenario probe                 # host: only with no other game running
./run.ps1 -Instance $copy -Scenario revive -Target vm     # in the Hyper-V VM (tools/vm/README.md, "Single-player tests in the VM")
./run.ps1 -Instance $copy -Scenario death -Target vm
./check.ps1 -Log <workspace>\dumps\v8.1.2-build26193463\markers\probe.vm.log -Scenario probe -Target vm
```

With `-Target vm`, core comes from `mods/Nucleus/build/package` and Markers plus the driver from this repo's `deploy.ps1 -Staged`; the VM copy is put back afterwards. Every Markers scenario may run in the VM (none judges timing). Take the workspace's `dumps/vm.lock` around VM runs while other agents share the VM.

**Results in the VM (V8.1.2, 2026-10-26, logs `dumps/v8.1.2-build26193463/markers/*.vm.batch2.log`): probe, death and revive all pass.**
- `MapUI_C`'s `Construct` runs on every map open, and every open gets a **new Journal instance** with all its flags rebuilt (4 opens, 4 Journals). So after a revive the Journal is a new instance too (`journal-same-after-revive=no`); the flags it builds take `Selected` from the waypoint actors, which is why "truth is the actor" is enough.
- `RemoveAllWidgets` stops every waypoint from painting (the bug). A respawned actor paints again (Markers' way, `bReplicates=false`); re-running the actor's `BeginPlay` also works; toggling the widget component's space does not.
- Liveness: a waypoint its flag just destroyed is still returned by `FindAllOf`, with `IsActorBeingDestroyed() == false` and UE4SS's `IsValid() == true`; UE's own `KismetSystemLibrary:IsValid` (called as the UFunction) is false, and `game.lua` uses it.
- Death: `ExplosionDamage` from Lua didn't kill; `DeathEvent()` did. The player became a `Spectator_C`, the waypoint actors survived, Markers took its snapshot and did nothing else.
- Revive (through the radio's own code): `LOST` → `REVIVE` → `RESTORED n=3` about 1.3 s later, every waypoint bound to the new pawn and painted, the map showing exactly those flags; then with `clear`: `CLEARED n=3`, nothing painted, no flag selected.
- The snapshot at `lost` costs about 2 ms inside core's HUD tick (a soft `hud slow tick ... HUD event: lost` warning).
- The match's landing showcase: about 5 s after the pawn and HUD are up, the game state's `UpdateHeliVis` puts the view on the landing helicopter's camera for 9 s and blends back over 3 s. A paint check in that time aims the control rotation but not the rendered camera, so markers out of the helicopter's view read 0 (the flaky `DRAWN before` of 2026-10-27). The driver now waits for the view to be back on the pawn (`VIEW`, `HUD` lines), re-aims every tick and counts a marker's window only if the rendered camera stayed within 10° of it (`AIM` lines; up to 4 tries). After the fix, revive passed 3 times in a row in the VM.

### Two-player scenarios (the real revive; need tools/vm/pair.ps1)

A solo player can't be revived (the last death ends the match), so the real thing needs two players: `test/pair/markers-scenarios.ps1`, in `pair.ps1`'s scenario shape, friends-only lobbies only.

| Scenario | Host A (this PC) | Client B (VM) | Judged by |
|---|---|---|---|
| `mk-client` | MarkersDriver `pair-host` only (no Markers): waits, signals B's kill (B calls `DeathEvent()` on its own pawn), calls `BP_Radio_C:Reinformant()` (the computer's "call reinforcement") | Nucleus + Markers + MarkersDriver `pair-victim`: marks 2 flags + satellite, dies, is revived; then the revive checks | `check.ps1 -Scenario pair-victim` (VM log), `-Scenario pair-host` (host log) |
| `mk-host` | Nucleus + Markers + MarkersDriver `pair-hostvictim`: marks, dies, reinforces itself | vanilla (UE4SS off), stays alive | `check.ps1 -Scenario pair-hostvictim` (host log) |

`pair.ps1` loads this file with `-ScenarioFile` and installs the host's mods with the scenario's `HostModPaths` (for the run only; removed afterwards, also by `-Stop`). Before running:
- core is built (`mods/Nucleus/build/package`; `mods/Nucleus/build.ps1`, not while a game runs);
- the host copy has no Markers, MarkersDriver or Nucleus of its own (`mk-client`'s Prereq and `pair.ps1` both refuse otherwise; take them out with their `deploy.ps1 -Remove`);
- the VM is set up as in the workspace's `tools/vm/README.md` (B signed in), nothing else uses it (`dumps/vm.lock`), and nobody plays on the host: `pair.ps1` waits until no Nuclear Nightmare runs on this PC.

From the workspace's main checkout, one at a time:

```powershell
./tools/vm/pair.ps1 -Scenario mk-client -ScenarioFile mods/markers/test/pair/markers-scenarios.ps1
./tools/vm/pair.ps1 -Scenario mk-host   -ScenarioFile mods/markers/test/pair/markers-scenarios.ps1
# after an aborted run (closes both games, puts the host and VM copies back):
./tools/vm/pair.ps1 -Stop -Scenario mk-client -ScenarioFile mods/markers/test/pair/markers-scenarios.ps1
```

Each run writes `dumps/<copy>/pair/<label>.json` (its `ScenarioReport` holds the `check.ps1` results, `ScenarioVerdict` PASS/FAIL) and the host log next to it; the VM log and screenshots (`marked`, `dead`, `revived`, `play`, `end`; `host-dead`, `after`) go to `dumps/<copy>/vm/`. To re-judge by hand: `./check.ps1 -Log <vm log> -Scenario pair-victim -Target vm`, `./check.ps1 -Log <host log> -Scenario pair-host` (or `pair-hostvictim`). Without the game: the workspace's `tools/vm/tests/pair-scenariofile.tests.ps1 -StageMarkers` loads this file and stages every role.

The kill is the character's own `DeathEvent()` (`ExplosionDamage` didn't kill in the VM), called by the machine that controls the character. In `mk-host` the host calls it on its own pawn (once more after 5 s if still possessed). In `mk-client` the host's `DeathEvent()` on B's remote character did nothing (2026-10-27: still possessed after two calls, `TIMEOUT the victim's death`; the event's first branch acts only on the locally controlled pawn), so the host only logs `KILL victim ... signal`, the scenario file then writes `Scripts\kill.txt` into the VM's MarkersDriver, and B calls `DeathEvent()` on its own pawn (`SELFKILL` lines), then `CallDamageEvent(100)` (the character's server RPC) if still possessed 5 s later. The victim must die neither drowned nor infected (or it becomes a monster: `pair-host` then fails as inconclusive). The hand check above is the fallback.

**Results (V8.1.2, 2026-10-27, friends-only lobby, host + VM): `mk-client` PASS, `mk-host` PASS.** Logs and JSON: `dumps/v8.1.2-build26193463/pair/mk-client-20261027-015454.*`, `mk-host-20261027-020047.*`; VM log and screenshots in `dumps/v8.1.2-build26193463/vm/`.
- **`mk-client`, Markers on a client (B) of an unmodded host:** a real death (B became `Spectator_C`) and a real reinforcement by the teammate (the host's `BP_Radio_C:Reinformant()`), and the markers came back: `RESTORED n=3 (from actors 3, from the snapshot 0, failed 0, old destroyed 3)`, one actor per marker, bound to the new pawn, `bReplicates=false`, `DRAWN revive`, `FLAGSMATCH` (Crash Site, Satellite, Weather Station), 7 checks, 0 failures; `pair-host` PASS on the host. The `play` and `end` screenshots show the three waypoints with distances, in white, with the HUD back. The `revived` screenshot came too early (at the new pawn, before `RESTORED`; the scenario now times it from the host's `OK REVIVED`).
- **Event order on the client:** `SELFKILL` → `LOST ... snapshot n=3` (the HUD lost at the death, 12 s after the first kill call) → `DEAD` as `Spectator_C` → host `REINFORCE` → the new pawn with a HUD 1.7 s later (`NEWPAWN`) → `REVIVE ... snapshot=3` 0.4 s after it → `RESTORED n=3` 0.5 s later (the action delay) → painted. No `AGAIN` and no `REBOUND`: on the client the radio's `RemoveAllWidgets` didn't land after the new HUD, so the settle window wasn't needed (one run).
- **`mk-host`, Markers on the host with a vanilla client:** the same: `LOST` → `REINFORCE` → `NEWPAWN` 1.6 s later → `REVIVE` 0.8 s later → `RESTORED n=3 ... failed 0` → `DRAWN`, `FLAGSMATCH`, 7 checks, 0 failures; no `AGAIN`. B's screenshots show a normal match, with no notification or chat.
- **Which call kills is not settled:** in all three deaths so far (solo `death`, `mk-host`, `mk-client`) `LOST` came about 7 s after the *second* kill call (`DeathEvent` again on the host, `CallDamageEvent(100)` on the client), and 12 s after the first, while the 5 s re-check found the pawn still possessed. A death's animation may simply take that long. A run with a longer re-check would tell; Markers doesn't depend on it.
- Not run as a pair: `onRevive = clear` on a client (solo `revive` covers clear on the host).

## Known risks

- The revive's order of events on a client: one `mk-client` run saw the new HUD after every `RemoveAllWidgets` (no `AGAIN`); the settle window ("again") stays for a late multicast under real latency.
- `FTransform` marshalling for `BeginDeferredActorSpawnFromClass` works (VM runs); the fallback (`SpawnActor` + the actor's own `BeginPlay` graph) stays, logged as such.
- The two-player revive passed once per role (2026-10-27, above), between this PC and the VM on one host: little latency. `onRevive = clear` on a client is not run.
- Other `RemoveAllWidgets` callers (the player controller, the Wendigo head, the endgame bomb) also hide waypoints without a revive; 0.1.0 acts only on revives (same pawn back after a loss is logged at DEBUG and left alone).
- `BP_Radio_C:SpawnReinformantRPC` would revive the same character (no new pawn); nothing calls it in V8.1.2.

Files to add to the workspace's `tools/diff-dumps.watch.json` when Markers ships: `marker-mechanics.md`, "Hooks and calls the mod relies on", plus `InventoryUI_C.Player`, `AActor:IsActorBeingDestroyed`, `GameplayStatics:BeginDeferredActorSpawnFromClass`/`FinishSpawningActor`.
