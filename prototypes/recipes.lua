-- Every recipe of the mod, in one table so costs can be read and tuned in one
-- place. All start locked; prototypes/technology.lua unlocks each tier's
-- three. Ingredients must already be available when that tier's technology
-- is: splitters, underground belts and their fast versions come with
-- Logistics / Logistics 2 (both required by Railway). Advanced circuits
-- (red), processing units (blue) and low density structures come with
-- their own technologies, which are prerequisites of the matching tier.
local constants = require("scripts.constants")

-- Tanks mirror the stations: tier 1 adds iron plates to its storage tanks,
-- tier 2 steel plates, with the same circuits as the station tier. The
-- balancers are pump sets, so they take pumps where the stock balancers take
-- splitters, and an underground takes two balancers' worth plus pipes to
-- ground, like the underground stock balancers. Fluid handling, required by
-- Fluid wagon (a prerequisite), brings storage tanks and pumps.
local RECIPES = {
  iron = {
    station = { time = 5, { "iron-chest", 6 }, { "advanced-circuit", 20 } },
    balancer = { time = 2, { "splitter", 1 }, { "advanced-circuit", 10 } },
    underground = { time = 3, { "splitter", 2 }, { "underground-belt", 1 }, { "advanced-circuit", 20 } },
  },
  steel = {
    station = { time = 8, { "steel-chest", 12 }, { "processing-unit", 10 }, { "low-density-structure", 10 } },
    balancer = { time = 2, { "fast-splitter", 1 }, { "processing-unit", 5 }, { "low-density-structure", 2 } },
    underground = {
      time = 3,
      { "fast-splitter", 2 },
      { "fast-underground-belt", 1 },
      { "processing-unit", 10 },
      { "low-density-structure", 5 },
    },
  },
  tank = {
    station = { time = 5, { "storage-tank", 2 }, { "iron-plate", 30 }, { "advanced-circuit", 20 } },
    balancer = { time = 2, { "pump", 1 }, { "iron-plate", 5 }, { "advanced-circuit", 10 } },
    underground = { time = 3, { "pump", 2 }, { "pipe-to-ground", 2 }, { "iron-plate", 10 }, { "advanced-circuit", 20 } },
  },
  ["tank-steel"] = {
    station = { time = 8, { "storage-tank", 4 }, { "steel-plate", 30 }, { "processing-unit", 10 }, { "low-density-structure", 10 } },
    balancer = { time = 2, { "pump", 2 }, { "steel-plate", 5 }, { "processing-unit", 5 }, { "low-density-structure", 2 } },
    underground = {
      time = 3,
      { "pump", 4 },
      { "pipe-to-ground", 4 },
      { "steel-plate", 10 },
      { "processing-unit", 10 },
      { "low-density-structure", 5 },
    },
  },
}

local function recipe(name, spec)
  local ingredients = {}
  for _, ingredient in ipairs(spec) do
    ingredients[#ingredients + 1] = { type = "item", name = ingredient[1], amount = ingredient[2] }
  end
  return {
    type = "recipe",
    name = name,
    enabled = false, -- unlocked by prototypes/technology.lua
    energy_required = spec.time,
    ingredients = ingredients,
    results = { { type = "item", name = name, amount = 1 } },
  }
end

for _, tier in ipairs(constants.ALL_TIERS) do
  local r = RECIPES[tier.key]
  data:extend({
    recipe(tier.item_h, r.station),
    recipe(tier.item_v, r.station),
    recipe(tier.balancer_item, r.balancer),
    recipe(tier.underground_item, r.underground),
  })
end
