-- One technology per tier, unlocking that tier's station, balancer and
-- underground balancer; control.lua's on_configuration_changed re-syncs
-- recipes for existing saves. Steel is a blue-science (chemical) technology.
local constants = require("scripts.constants")

local TECH = {
  iron = {
    name = "freight-stations",
    prerequisites = { "railway", "advanced-circuit" },
    count = 50,
    packs = { "automation-science-pack", "logistic-science-pack" },
  },
  steel = {
    name = "freight-stations-steel",
    -- both need Chemical science pack (and low density structure needs steel)
    prerequisites = { "freight-stations", "processing-unit", "low-density-structure" },
    count = 100,
    packs = { "automation-science-pack", "logistic-science-pack", "chemical-science-pack" },
  },
  tank = {
    name = "fluid-stations",
    prerequisites = { "freight-stations", "fluid-wagon" },
    count = 75,
    packs = { "automation-science-pack", "logistic-science-pack" },
  },
  ["tank-steel"] = {
    name = "fluid-stations-steel",
    prerequisites = { "fluid-stations", "freight-stations-steel" },
    count = 100,
    packs = { "automation-science-pack", "logistic-science-pack", "chemical-science-pack" },
  },
}

for _, tier in ipairs(constants.ALL_TIERS) do
  local t = TECH[tier.key]
  local ingredients = {}
  for _, pack in ipairs(t.packs) do
    ingredients[#ingredients + 1] = { pack, 1 }
  end
  data:extend({
    {
      type = "technology",
      name = t.name,
      icon = "__freight-stations-rats-fork__/graphics/technology/" .. t.name .. ".png",
      icon_size = 256,
      prerequisites = t.prerequisites,
      effects = {
        { type = "unlock-recipe", recipe = tier.item },
        { type = "unlock-recipe", recipe = tier.balancer_item },
        { type = "unlock-recipe", recipe = tier.underground_item },
      },
      unit = {
        count = t.count,
        ingredients = ingredients,
        time = 30,
      },
      order = "c-g-c",
    },
  })
end
