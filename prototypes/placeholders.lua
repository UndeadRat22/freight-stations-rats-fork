-- A hidden twin of each item that builds something only through a placer,
-- for the entities behind that placer to name as their placeable_by
-- (constants.placeholder). Never crafted, mined or placed by hand.
local constants = require("scripts.constants")

local items = {}
for _, swap in pairs(constants.PLACER_OF) do
  items[swap.item] = true
end
local names = {}
for item in pairs(items) do
  names[#names + 1] = item
end
table.sort(names)

for _, item in ipairs(names) do
  local real = data.raw.item[item]
  data:extend({
    {
      type = "item",
      name = constants.placeholder(item),
      localised_name = { "item-name." .. item },
      icon = real.icon,
      icon_size = real.icon_size,
      hidden = true,
      stack_size = real.stack_size,
    },
  })
end
