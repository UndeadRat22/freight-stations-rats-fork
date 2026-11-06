# Freight Stations (UndeadRat22 fork, minimal core)

Fork of [Ragingart's Freight Stations](https://mods.factorio.com/mod/freight-stations)
(MIT), rebuilt around a minimal core after a first-principles pass: the use
case is N wagon-adjacent containers sharing one inventory, joined by 1-tile
balancer buildings - everything that existed only to polish what the engine
does not support natively is gone. Saves from 0.12.x/0.13.x migrate on
first load (see below). The two mods declare each other incompatible,
so the game refuses to load with both enabled.

## How it works

- **Stations build exactly where you place them.** No rail-adjacency rule,
  no wagon-slot snapping. Each tier has a horizontal and a vertical item
  (linked containers cannot rotate), placed directly - no hidden placer
  machines, no entity swapping. Undo, blueprints, ghosts, pipette and
  fast-replace are all engine-native, and flipping a blueprint row builds
  the exact mirrored row.
- **One fixed-size inventory per group.** Stations joined by balancers share
  a single linked inventory (iron: six chests' worth; steel: double stack
  sizes). Members add access points, not space, which is what removes the
  whole resize/replace machinery the original needed for growing windows.
- **The world is the only state.** Group membership is walked live from the
  map and link ids live on the entities: no bookkeeping storage, nothing to
  desync. Merging two groups pours the loser's items into the survivor's;
  splitting leaves the items with the largest piece and the other pieces
  start empty.
- **Auto-connect:** build a station with a matching neighbour exactly one
gap away and a balancer is placed between them, paid for from your
inventory (free in cheat mode). No ghosts are placed by proxy - without the
item, nothing happens until you build or paste one there.
- **Underground balancers** pair across the track like underground belts,
  linking both sides into one inventory; fluid stations are joined by the
  engine's own fluid segments.
- **Dismantling with robots** stays sane: the last station of a group marked
  for deconstruction becomes a plain chest holding the contents, so robots
  empty it load by load instead of spilling it. Group-mates are simply mined
  empty.

## Development

```sh
make test       # headless lab suite + luacheck (when installed)
make lab        # lab only; LAB_DIR=../test-env by default
make package    # builds releases/freight-stations-rats-fork_<version>.zip
make install    # package + copy into the game's mods dir
make clean
```

`make install` warns if the original `freight-stations_*.zip` is still in
the mods folder: the fork must replace it, never sit beside it.

The headless lab (`tests/run-lab.sh`) needs a one-time setup: a Factorio
scenario `fs-test` with the `fs-test` driver mod in `LAB_DIR` (see
`make lab-setup`). The lab re-syncs this repo into the lab's mod folder on
every run, so it always tests the current tree. The suite covers row
builds with auto-connect, shared inventories, merge/split item handling,
the dismantle round-trip, fast-replace, and flipped rows in both axes.

Two engine behaviours this mod depends on (measured headless, 2.1.24):
`get_contents()` on a linked container's inventory reads empty even with
items in the slots, so all linked-inventory reads iterate slots; and
`defines.events.script_raised_built/revive/destroy` have no `on_` prefix.

## Migrating from 0.12.x / 0.13.x

The old size-prototype stations convert to the fixed-size stations on the
first load (their prototypes stay in the mod, hidden, so the entities
survive loading). Every old group becomes one new group with a fresh link
id; quality, health and last user carry over, circuit wires do not. The old
group inventory is poured into the new fixed capacity, and what exceeds
it spills around the group's stations - a 50-station group held 50x the
slots, the new group holds one fixed share, so trim large groups down
before switching if you care where the overflow lands.

Credits: Ragingart's original Freight Stations (MIT) for the sprites,
recipes, technologies and the whole idea. Built with the help of the Kimchi
coding agent.
