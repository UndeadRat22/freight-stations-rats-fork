-- Station placers (prototypes/placer.lua) must collide exactly like the
-- station they turn into, plus the drag-spacing reservation's layer. Set
-- here, as late as possible, from the station's own mask or else the
-- linked-container default in the utility constants, so layers other mods
-- add to either are respected. (A plain assembling-machine default would
-- add `meltable`, which containers don't have.)
local util = require("util")
local collision_mask_util = require("__core__/lualib/collision-mask-util")
local constants = require("scripts.constants")

local defaults = data.raw["utility-constants"].default.default_collision_masks

for _, tier in ipairs(constants.TIERS) do
  local station = data.raw["linked-container"][constants.station_name(tier.station_h, 1)]
  local mask = station.collision_mask
    or (defaults and defaults["linked-container"])
    or collision_mask_util.get_default_mask("linked-container")
  mask = util.copy(mask)
  mask.layers = mask.layers or {}
  mask.layers["freight-station-gap"] = true
  data.raw["assembling-machine"][tier.placer].collision_mask = mask
end

-- Tank placers likewise collide like their tank.
for _, tier in ipairs(constants.TANK_TIERS) do
  local tank = data.raw["storage-tank"][tier.station_h]
  local mask = tank.collision_mask
    or (defaults and defaults["storage-tank"])
    or collision_mask_util.get_default_mask("storage-tank")
  mask = util.copy(mask)
  mask.layers = mask.layers or {}
  mask.layers["freight-station-gap"] = true
  data.raw["assembling-machine"][tier.placer].collision_mask = mask
end

-- Balancers are walkable, like belts: their mask is their own (or the
-- simple-entity-with-owner default) without the two layers characters,
-- vehicles and units collide on. Everything that has to stay out of the gap
-- (stations, belts, inserters, other buildings) still collides on `object`.
-- The steel balancer placer takes the same mask, so standing in the gap
-- doesn't refuse a balancer that would fit there.
local function walkable(prototype)
  local mask = util.copy(prototype.collision_mask
    or (defaults and defaults[prototype.type])
    or collision_mask_util.get_default_mask(prototype.type))
  mask.layers = mask.layers or {}
  mask.layers["player"] = nil
  mask.layers["is_object"] = nil
  return mask
end

local simple = data.raw["simple-entity-with-owner"]
for _, tier in ipairs(constants.TIERS) do
  for _, name in ipairs({ tier.balancer_h, tier.balancer_v, tier.underground }) do
    simple[name].collision_mask = walkable(simple[name])
  end
  if tier.balancer_placer then
    data.raw["assembling-machine"][tier.balancer_placer].collision_mask = util.copy(simple[tier.balancer_h].collision_mask)
  end
end

local tanks = data.raw["storage-tank"]
for _, tier in ipairs(constants.TANK_TIERS) do
  for _, name in ipairs({ tier.balancer_h, tier.underground }) do
    tanks[name].collision_mask = walkable(tanks[name])
  end
end
