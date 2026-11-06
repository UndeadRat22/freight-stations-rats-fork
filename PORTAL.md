# Mod portal page text

Paste into the description field on the Factorio mod portal. Markdown on
purpose — the portal documents its description field as markdown. Kept
conservative (headings, bold, flat lists, links, code spans) since the
portal's renderer is a partial markdown implementation; nested structures and
tables are avoided.

---

# Freight Stations (rat's fork)

A fork of [Ragingart's Freight Stations](https://mods.factorio.com/mod/freight-stations) (MIT) with fixes for three blueprint/placement problems, verified headless against Factorio 2.1.24. Same entities, items, recipes and technologies as the original — saves, blueprints and books carry over untouched.

**This fork replaces the original, it does not add to it.** The two mods declare each other incompatible, so the game refuses to load with both enabled. If Ragingart takes the fixes upstream, drop this fork and nothing of yours changes: every prototype name is identical.

## The rail shift on "select new contents"

Capturing a station into a blueprint rewrites it into its rotatable placer, whose position sits **half a tile off** the station's. The mod then stored the rewritten entity list with `fix_positions` defaulting to true, so the engine re-snapped every stored position that had become "invalid for the current snapping" — every 2×2 rail jumped to the nearest valid tile, which shows up as **all rails moving exactly one tile down and one right**. The entity list is now stored verbatim (`set_blueprint_entities(entities, false)`); positions that are genuinely invalid still get corrected.

## Balancers stranded inside stations after flipping

Flipping a blueprint mirrors positions, but the engine can't mirror the placer's one-sided footprint, so stations come out a tile off their mirrored balancers. The mod's paste-time snapping fixes that — station ghosts move to their wagon slot, balancer ghosts to the gap between slots. But a flipped or shifted paste can put a balancer ghost **where no gap exists**: past the row's end, or inside what already is (or will be) a station's footprint. There it sat forever after its one retry — an unbuildable ghost blocking construction robots, while the row built around it.

Such ghosts are now refused the same way illegal station placements always were: after one retry the ghost is removed, the item is handed back (spilled if your inventory is full), and a message says why (`There's no gap between two stations here for this.`).

## Placing stations beside the start of a curve

The placement rule requires every one of a station's 6 tiles to have a straight rail running level with it — that's what makes a station a loading platform (inserters reach every wagon) and not a free-standing warehouse, and it's a good rule. But it counted straight rails only, so any 6-tile span touching a curve was rejected, even where the curve's start is still perfectly level with the straight run.

Curved rails now count for the tiles where they still run straight: a curved rail covers its anchor pair plus the tile toward the station — enough to end a station where a curve begins, never enough to paper over a missing straight rail under one.

## Compatibility with existing saves

- **Saves and blueprints carry over.** Every entity/item/recipe/technology name is identical to the original; Factorio matches saves by prototype name, not mod name.
- **Bookkeeping rebuilds itself.** The first load after switching runs the mod's recovery pass: stations are found in the world and regrouped, inventories are kept, items are redistributed by the normal group rules.
- **Verified on a real 16-station save**: after the swap, all 16 stations restored with intact inventories (605/3232 slots occupied), every one passing its own placement rule and sitting exactly on its stop's wagon grid, zero errors during the migration tick.
- **Multiplayer**: everyone needs the same mod — if a server ships the original 0.12.9, use that there, or get the host to install this fork.

## Quality

Every fix is verified with a headless engine suite (scenario + driver mod, `make test` in the repository): blueprint capture round-trips byte-stable, all flip combinations (iron and steel, horizontal and vertical, raw ±1 and pre-aligned pastes) build complete rows with zero balancer/station overlaps, and the curve-adjacent placement that used to be rejected is now accepted while positions past the curve stay rejected. A separate whole-codebase robustness pass hardened four theoretical crash paths (nil-index and nil-in-array cases) and reviewed every division and table index in the runtime code.

Upstream history is kept in the changelog, clearly marked. If you find a problem, check whether it exists in the original first — fixes belong upstream where the bugs live, and the maintainer is responsive.
