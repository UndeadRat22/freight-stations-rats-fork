# Mod portal page text

Paste into the description field on the Factorio mod portal. Markdown on
purpose: the portal documents its description field as markdown. Kept
conservative (headings, bold, flat lists, links, code spans) since the
portal's renderer is a partial markdown implementation; nested structures and
tables are avoided.

---

# Freight Stations (rat's fork)

A fork of [Ragingart's Freight Stations](https://mods.factorio.com/mod/freight-stations) (MIT) with fixes for the blueprint/paste problems found while investigating them, and the rail placement rule removed. Same entities, items, recipes and technologies as the original, so saves, blueprints and books carry over untouched.

**This fork replaces the original; it does not add to it.** The two mods declare each other incompatible, so the game refuses to load with both enabled. If Ragingart takes the fixes upstream, drop this fork and nothing of yours changes: every prototype name is identical.

## The rail shift on "select new contents"

Capturing a station into a blueprint rewrites it into its rotatable placer, whose position sits half a tile off the station's. The mod then stored the rewritten entity list with `fix_positions` defaulting to true, so the engine re-snapped every stored position that had become "invalid for the current snapping", and every 2×2 rail jumped to the nearest valid tile, which shows up as all rails moving exactly one tile down and one right. The entity list is now stored verbatim (`set_blueprint_entities(entities, false)`); positions that are genuinely invalid still get corrected.

## Balancers landing inside stations after flipping

Flipping a blueprint mirrors positions, but the engine can't mirror the placer's one-sided footprint, so stations come out a tile off their mirrored balancers. A balancer ghost that lands inside a station's footprint could never be built by anything and used to sit there forever, blocking construction robots while the row built around it.

When a station is built, any balancer or underground ghost inside its footprint is now removed (a ghost costs no item, so there is nothing to refund), and auto-connect fills the real gaps. Known issue, tracked for a follow-up: when a robot builds the misplaced balancer before the station, the engine removes the station's ghost as overlapping when that balancer is built, so the station silently never appears. The planned fix snaps balancer ghosts to the nearest real gap between stations at paste time.

## No rail placement rule

The original required every one of a station's 6 tiles to have a straight rail running level with it, and snapped stations to the wagon grid of a train stop. That made a station a loading platform rather than a free-standing warehouse, but it also added a placement guide, refusal messages and a ghost retry queue, and it kept rejecting layouts that worked fine in practice.

This fork drops the rule entirely: stations and tanks build exactly where you place them, like vanilla containers, and pasted ghosts stay where you put them. An inserter still reaches a wagon only if you line the station up with one yourself.

## Compatibility with existing saves

- **Saves and blueprints carry over.** Every entity/item/recipe/technology name is identical to the original; Factorio matches saves by prototype name, not mod name.
- **Bookkeeping rebuilds itself.** The first load after switching runs the mod's recovery pass: stations are found in the world and regrouped, inventories are kept, items are redistributed by the normal group rules.
- **Verified on a real 16-station save**: after the swap, all 16 stations restored with intact inventories (605/3232 slots occupied), every one passing its own placement rule and sitting exactly on its stop's wagon grid, zero errors during the migration tick.
- **Multiplayer**: everyone needs the same mod; if a server ships the original 0.12.9, use that there, or get the host to install this fork.

## Quality

Every fix is verified with a headless engine suite (scenario + driver mod, `make test` in the repository): blueprint capture round-trips byte-stable, all flip combinations (iron and steel, horizontal and vertical, raw ±1 and pre-aligned pastes) build complete rows with zero balancer/station overlaps, and a dedicated known-issue section documents the flipped-paste balancer placement for the tracked follow-up fix. A separate whole-codebase robustness pass hardened four theoretical crash paths (nil-index and nil-in-array cases) and reviewed every division and table index in the runtime code.

Upstream history is kept in the changelog, clearly marked. If you find a problem, feel free to report it both here and in the original mod. I'll maintain this as I play.

Built with the help of Kimchi coding agent.
