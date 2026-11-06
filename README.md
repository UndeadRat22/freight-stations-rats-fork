# Freight Stations (rat's fork)

Fork of [Ragingart's Freight Stations](https://mods.factorio.com/mod/freight-stations)
(MIT) with fixes for the blueprint/paste problems found while investigating
them. Same entities, items, recipes and technologies as the original, so
saves and blueprints carry over. But the two mods declare each other
incompatible (`! freight-stations` in info.json), so the game refuses to load
with both enabled. Version is bumped to 0.12.11; upstream history is kept in
`changelog.txt`.

## What's changed

1. **Rail shift on "select new contents"**: a blueprint containing rails
   shifted every rail one tile down and one right. Blueprint entities are now
   stored verbatim (`set_blueprint_entities(entities, false)`).
2. **No rail placement rule**: stations and tanks build exactly where you
   place them, like vanilla containers. The wagon-slot snapping, the
   placement guide and the ghost retry queue are gone with it.
3. **Flipped pastes**: flipping a blueprint lands its balancer ghosts one
   tile inside the stations (the engine can't mirror the placer's one-sided
   footprint). Balancer ghosts inside a built station's footprint are
   removed instead of sitting unbuildable forever, and auto-connect fills
   the real gaps. Known issue, tracked: a balancer built before its station
   can still strand that station's ghost.

Plus fast-replaceable stations (a station blueprint builds over an existing
station), working cmd+z for pasted stations, and a whole-codebase robustness
pass (division/index/nil hardening).

## Development

```sh
make test       # headless lab suite + luacheck (when installed)
make lab        # lab only; LAB_DIR=../test-env by default
make package    # builds releases/freight-stations-rats-fork_<version>.zip
make install    # package + copy into the game's mods dir
make clean
```

`make install` warns if the original `freight-stations_*.zip` is still in the
mods folder: the fork must replace it, never sit beside it.

The headless lab (`tests/run-lab.sh`) needs a one-time setup: a Factorio
scenario `fs-test` with the `fs-test` driver mod in `LAB_DIR` (see
`make lab-setup`). The lab re-syncs this repo into the lab's mod folder on
every run, so it always tests the current tree.
