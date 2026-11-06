-- Stock balancers: entities with no inventory of their own; they only exist
-- to let scripts/groups.lua detect that two adjacent stations should share
-- one inventory. One rotatable prototype per tier (a
-- simple-entity-with-owner rotates a non-square collision box, confirmed
-- headlessly against 2.0.77: create_entity with east/west gives the rotated
-- box, rotate() works, and ghosts revive with direction intact). North or
-- south it sits in the gap between horizontal stations (1 tile along the
-- row, `width` across it); east or west, between vertical ones.

local constants = require("scripts.constants")
local sprite_util = require("prototypes.util")

for _, tier in ipairs(constants.TIERS) do
  local w = tier.width / 2
  data:extend({
    {
      type = "simple-entity-with-owner",
      name = tier.balancer,
      icon = sprite_util.icon("stock-balancer", tier.key),
      icon_size = 64,
      -- No upgrade path exists, so keep it out of the upgrade planner.
      flags = { "placeable-neutral", "player-creation", "not-upgradable" },
      minable = { mining_time = 0.2, result = tier.balancer_item },
      max_health = 100,
      corpse = "medium-remnants",
      collision_box = { { -0.4, -(w - 0.1) }, { 0.4, w - 0.1 } },
      -- collision_mask (walkable, like a belt): set in data-final-fixes.lua
      selection_box = { { -0.5, -w }, { 0.5, w } },
      -- shared with this tier's underground balancer, so either can be
      -- placed straight over the other
      fast_replaceable_group = "freight-stations-balancer-" .. tier.key,
      picture = {
        north = sprite_util.balancer_picture(tier.key, "x"),
        east = sprite_util.balancer_picture(tier.key, "y"),
        south = sprite_util.balancer_picture(tier.key, "x"),
        west = sprite_util.balancer_picture(tier.key, "y"),
      },
    },
    {
      type = "item",
      name = tier.balancer_item,
      icon = sprite_util.icon("stock-balancer", tier.key),
      icon_size = 64,
      subgroup = sprite_util.SUBGROUP,
      order = sprite_util.order(tier, "b[balancer]"),
      place_result = tier.balancer,
      stack_size = 50,
    },
  })
end
