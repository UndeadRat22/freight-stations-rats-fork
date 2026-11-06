-- Stock balancers: entities with no inventory of their own; they only exist
-- to let scripts/groups.lua detect that two adjacent stations should share
-- one inventory. The iron tier's is a 1x1 square (reads the same from any
-- side, so no h/v split). Wider tiers need a 1 x width balancer, which
-- cannot rotate, so those get an h/v pair placed via a rotatable placer
-- (prototypes/placer.lua), same as the stations.

local constants = require("scripts.constants")
local sprite_util = require("prototypes.util")

local function balancer_entity(tier, name, across_x, through_placer)
  local w = tier.width / 2
  local bx, by = 0.5, w
  if across_x then
    bx, by = w, 0.5
  end
  return {
    type = "simple-entity-with-owner",
    name = name,
    icon = sprite_util.icon("stock-balancer", tier.key),
    icon_size = 64,
    -- No upgrade path exists, so keep it out of the upgrade planner.
    flags = { "placeable-neutral", "player-creation", "not-upgradable" },
    minable = { mining_time = 0.2, result = tier.balancer_item },
    -- h/v balancers are only built through their placer (constants.placeholder)
    placeable_by = { item = through_placer and constants.placeholder(tier.balancer_item) or tier.balancer_item, count = 1 },
    -- the -v balancer shares the -h one's deconstruction planner entry
    deconstruction_alternative = name ~= tier.balancer_h and tier.balancer_h or nil,
    max_health = 100,
    corpse = "medium-remnants",
    collision_box = { { -(bx - 0.1), -(by - 0.1) }, { bx - 0.1, by - 0.1 } },
    -- collision_mask (walkable, like a belt): set in data-final-fixes.lua
    selection_box = { { -bx, -by }, { bx, by } },
    -- shared with this tier's underground balancer (prototypes/underground-balancer.lua)
    fast_replaceable_group = "freight-stations-balancer-" .. tier.key,
    picture = sprite_util.balancer_picture(tier.key, across_x and "y" or "x"),
  }
end

for _, tier in ipairs(constants.TIERS) do
  local entities = {}
  if tier.balancer_placer then
    -- "-h": sits in the gap between horizontal stations (1 wide in x, tall in y)
    entities[#entities + 1] = balancer_entity(tier, tier.balancer_h, false, true)
    entities[#entities + 1] = balancer_entity(tier, tier.balancer_v, true, true)
  else
    entities[#entities + 1] = balancer_entity(tier, tier.balancer_h, false)
  end
  entities[#entities + 1] = {
    type = "item",
    name = tier.balancer_item,
    icon = sprite_util.icon("stock-balancer", tier.key),
    icon_size = 64,
    subgroup = sprite_util.SUBGROUP,
    order = sprite_util.order(tier, "b[balancer]"),
    place_result = tier.balancer_placer or tier.balancer_h,
    stack_size = 50,
  }
  data:extend(entities)
end
