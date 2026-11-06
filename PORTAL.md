# Mod portal page text

Paste into the description field on the Factorio mod portal. Markdown on
purpose: the portal documents its description field as markdown. Kept
conservative (headings, bold, flat lists, links, code spans) since the
portal's renderer is a partial markdown implementation; nested structures and
tables are avoided.

---

# Freight Stations (UndeadRat22 fork)

A rebuild of [Ragingart's Freight Stations](https://mods.factorio.com/mod/freight-stations) (MIT) around a minimal core. Long storage containers and fluid tanks sit alongside your trains; stations joined by stock balancers share one inventory, and you reach that inventory from every wagon position.

**This fork replaces the original; it does not add to it.** The two mods declare each other incompatible, so the game refuses to load with both enabled. Saves from 0.12.x and 0.13.x migrate on first load: every old group becomes one new group in the matching size band, quality, health and last user carry over, and the old inventory always fits (bands round up).

## Build anywhere, undo works

Stations and tanks build exactly where you place them, like vanilla containers: no rail rule, no snapping to wagon slots, no hidden placer machines standing in for what you built. Because nothing is replaced behind the engine's back, **undo, blueprints, ghosts, pipette and fast-replace all work natively** - and flipping a blueprint row builds the exact mirrored row, balancers in the gaps.

Each tier has a horizontal and a vertical item (linked containers cannot rotate), a rotatable stock balancer, and an underground balancer that pairs across the track like an underground belt, linking both sides into one inventory. Fluid stations are joined by the engine's own fluid segments.

## One shared inventory per group, in size bands

A group is every station connected through balancers, and it shares a single linked inventory: six chests' worth for iron, double stack sizes for steel. **The capacity grows with the group**: whenever the member count crosses a power-of-two band (capped at the tier's maximum), the members are swapped onto that band's prototype - a rare, quiet swap that carries wires, quality, health and the shared link id over, and pours the items into the bigger inventory (growing always fits; shrinking after members leave spills the overflow). The inventory window shows the band's capacity, rounded up from the member count.

Build a station with a matching neighbour exactly one gap away and a balancer is placed between them automatically - paid for from your inventory, free in cheat mode. No ghosts are placed by proxy: without the item, the connection is simply not made until you build or paste one there.

When you cut a group apart (remove a balancer), the items stay with the largest piece. When two groups grow into one, the loser's items pour into the survivor's. And when the last station of a group is marked for deconstruction, it becomes a plain chest holding the contents, so construction robots empty it load by load instead of spilling it as item piles.

## Quality

Verified with a headless engine suite (scenario + driver mod, `make test` in the repository): row builds with auto-connect, shared inventory across stations, merges keeping both sides' items, splits leaving the items with the keeper, the deconstruction round-trip, fast-replace keeping contents, and flipped rows in both axes.

Upstream history is kept in the changelog, clearly marked. Credit for the original mod, its sprites, recipes and the whole idea goes to Ragingart (MIT). If you find a problem, feel free to report it both here and in the original mod.

Built with the help of the Kimchi coding agent.
