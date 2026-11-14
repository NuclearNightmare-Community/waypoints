# Changelog

All notable changes to Waypoints are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [0.2.0] - 2026-11-13

First release: a soft release to a few testers, not released publicly. Game: Nuclear Nightmare V8.2.3 (build 26601774). UE4SS: v3.0.1-1181-g83330635. Needs Nucleus 0.6.0 or newer (`>=0.6.0`).

For players: **Mark all** and **Clear all** buttons under the Journal map, and your map waypoints back after a revive. Only your own game is changed; it sends nothing over the network.

### Added

- **Mark all** puts up a waypoint for every location flag of the current map and the satellite flag; **Clear all** takes every waypoint down. Both go through the flags' own click handlers, and the map's selected flags match the waypoints on screen after every press and every time the map opens.
- After a revive, setting `onRevive`: `restore` (default) brings back every waypoint you had up before you died, `clear` removes them all.
- Without a compatible Nucleus, one `[Waypoints]` log line naming the cause, and nothing else.
- Log lines `[Waypoints] READY`, `MAPSYNC`, `MARKALL`, `CLEARALL`, `REVIVE` and `WARN` (among others) in `UE4SS.log`.
