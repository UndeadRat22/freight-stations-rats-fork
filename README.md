# Freight Stations (rat's fork)

Fork of [Ragingart's Freight Stations](https://mods.factorio.com/mod/freight-stations)
(MIT) with fixes for three problems found while investigating blueprint/paste
behaviour. Same entities, items, recipes and technologies as the original, so
saves and blueprints carry over — but the two mods declare each other
incompatible (`! freight-stations` in info.json), so the game refuses to load
with both enabled. Version is bumped to 0.12.10; upstream history is kept in
`changelog.txt`.

## What's fixed

1. **Rail shift on "select new contents"** — a blueprint containing rails
   shifted every rail one tile down and one right. Blueprint entities are now
   stored verbatim (`set_blueprint_entities(entities, false)`).
2. **Flipped pastes stranding balancer ghosts inside stations** — a gap ghost
   with no gap (flipped/shifted paste, past the row's end) is now refused
   after one retry instead of sitting unbuildable forever; the item comes back.
3. **No placement beside curved rail starts** — curved rails now count toward
   the coverage predicate for the tiles where they still run level with the
   straight run.

Plus a whole-codebase robustness pass (division/index/nil hardening).

## Development

```sh
make test       # headless lab suite + luacheck (when installed)
make lab        # lab only; LAB_DIR=../test-env by default
make package    # builds releases/freight-stations-rats-fork_<version>.zip
make install    # package + copy into the game's mods dir
make clean
```

`make install` warns if the original `freight-stations_*.zip` is still in the
mods folder — the fork must replace it, never sit beside it.

The headless lab (`tests/run-lab.sh`) needs a one-time setup: a Factorio
scenario `fs-test` with the `fs-test` driver mod in `LAB_DIR` (see
`make lab-setup`). The lab re-syncs this repo into the lab's mod folder on
every run, so it always tests the current tree.
