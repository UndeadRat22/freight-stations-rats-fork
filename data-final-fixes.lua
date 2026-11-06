-- Balancers and undergrounds are walkable, like belts: their mask is their
-- own (or the simple-entity-with-owner / storage-tank default) without the
-- two layers characters, vehicles and units collide on. Everything that has
-- to stay out of the gap (stations, belts, inserters, other buildings)
-- still collides on `object`.
local util = require("util")
local collision_mask_util = require("__core__/lualib/collision-mask-util")
local constants = require("scripts.constants")

local defaults = data.raw["utility-constants"].default.default_collision_masks

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
  for _, name in ipairs({ tier.balancer, tier.underground }) do
    simple[name].collision_mask = walkable(simple[name])
  end
end

local tanks = data.raw["storage-tank"]
for _, tier in ipairs(constants.TANK_TIERS) do
  for _, name in ipairs({ tier.balancer, tier.underground }) do
    tanks[name].collision_mask = walkable(tanks[name])
  end
end
