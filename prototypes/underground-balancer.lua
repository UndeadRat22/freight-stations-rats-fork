-- Underground stock balancers. Within its own row one behaves exactly
-- like a regular balancer (it sits in the gap between two stations); on top
-- of that it pairs across the track with a same-tier underground facing
-- straight back at it, like underground belts, linking the station groups on
-- both sides (scripts/geometry.lua owns the pairing rule).
--
-- Unlike stations and wide balancers, this needs no placer: a
-- simple-entity-with-owner takes a Sprite4Way picture and genuinely rotates,
-- including a non-square 1x2 collision box (confirmed headlessly against
-- 2.0.77: create_entity with east/west gives the rotated box, rotate() works,
-- and ghosts revive with direction intact once an item places it). The
-- default (north) box is 1 tile along the row and `width` tiles across it.

local constants = require("scripts.constants")
local sprite_util = require("prototypes.util")

for _, tier in ipairs(constants.TIERS) do
  local w = tier.width / 2
  data:extend({
    {
      type = "simple-entity-with-owner",
      name = tier.underground,
      icon = sprite_util.icon("underground-stock-balancer", tier.key),
      icon_size = 64,
      -- No upgrade path exists, so keep it out of the upgrade planner.
      flags = { "placeable-neutral", "player-creation", "not-upgradable" },
      minable = { mining_time = 0.2, result = tier.underground_item },
      max_health = 150,
      corpse = "small-remnants",
      collision_box = { { -0.4, -(w - 0.1) }, { 0.4, w - 0.1 } },
      -- collision_mask (walkable, like a belt): set in data-final-fixes.lua
      selection_box = { { -0.5, -w }, { 0.5, w } },
      -- shared with this tier's regular balancer, so either can be placed
      -- straight over the other
      fast_replaceable_group = "freight-stations-balancer-" .. tier.key,
      picture = {
        north = sprite_util.underground_picture(tier.key, "north"),
        east = sprite_util.underground_picture(tier.key, "east"),
        south = sprite_util.underground_picture(tier.key, "south"),
        west = sprite_util.underground_picture(tier.key, "west"),
      },
    },
    {
      type = "item",
      name = tier.underground_item,
      icon = sprite_util.icon("underground-stock-balancer", tier.key),
      icon_size = 64,
      subgroup = sprite_util.SUBGROUP,
      order = sprite_util.order(tier, "c[underground]"),
      place_result = tier.underground,
      stack_size = 50,
    },
  })
end
