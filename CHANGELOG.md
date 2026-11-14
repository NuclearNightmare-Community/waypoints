# Changelog

All notable changes to Waypoints are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased] - 0.3.0

Game: Nuclear Nightmare V8.2.3 (build 26601774). UE4SS: v3.0.1-1181-g83330635. Needs Nucleus 0.9.0 or newer (`>=0.9.0`).

For players: the "after a revive, your map waypoints" setting is now kept by Nucleus in `Mods/Waypoints/settings.json`, so a redeploy keeps it, and a change (from the Mod Manager, later) applies at the next revive without a restart.

### Changed

- `onRevive` comes from Nucleus's settings service (`core.settings.get`), read at every revive. `Scripts/settings.lua` is gone: `deploy.ps1 -OnRevive` writes `Mods/Waypoints/settings.json` instead, a redeploy without it keeps an existing one, and a release ships no settings file.
- An existing `Scripts/settings.lua` is no longer read: a value chosen there must be set again in `Mods/Waypoints/settings.json` (for example `{"onRevive":"clear"}`; in Notepad, save with "All files" so the name ends in `.json`, not `.json.txt`).
- The test-only `debug` flag moved to `Scripts/dev.lua`, written only by `deploy.ps1 -Test`, read as text and never run.
- The test driver switches `onRevive` with a `settings-set` on Nucleus's channel and logs the reply (`revive`, `buttons-revive`).
- Needs Nucleus `>=0.9.0` (`dependsOn` and `connect`).
- The mod id is now `nuclearnightmare-community.waypoints` (was `waypoints`), and `dependsOn` names Nucleus as `nuclearnightmare-community.nucleus` (distribution story 13, `mod-ids.md`): the namespaced ids every released mod takes before the first public release. The folder, `mods.txt` line and `name` are unchanged. `deploy.ps1` finds core's entry by the new id, so a dev copy needs a Nucleus deployed with the new id (Nucleus 0.12.0).

## [0.2.0] - 2026-11-13

First release: a soft release to a few testers, not released publicly. Game: Nuclear Nightmare V8.2.3 (build 26601774). UE4SS: v3.0.1-1181-g83330635. Needs Nucleus 0.6.0 or newer (`>=0.6.0`).

For players: **Mark all** and **Clear all** buttons under the Journal map, and your map waypoints back after a revive. Only your own game is changed; it sends nothing over the network.

### Added

- **Mark all** puts up a waypoint for every location flag of the current map and the satellite flag; **Clear all** takes every waypoint down. Both go through the flags' own click handlers, and the map's selected flags match the waypoints on screen after every press and every time the map opens.
- After a revive, setting `onRevive`: `restore` (default) brings back every waypoint you had up before you died, `clear` removes them all.
- Without a compatible Nucleus, one `[Waypoints]` log line naming the cause, and nothing else.
- Log lines `[Waypoints] READY`, `MAPSYNC`, `MARKALL`, `CLEARALL`, `REVIVE` and `WARN` (among others) in `UE4SS.log`.
