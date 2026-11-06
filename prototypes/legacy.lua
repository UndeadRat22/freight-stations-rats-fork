-- Legacy prototypes from the 0.12.x / 0.13.x line, kept only so entities in
-- old saves survive loading: the engine removes any entity whose prototype
-- no longer exists before a script ever runs. Old stations were one
-- prototype per group size (family-g1..gN) with a capacity that grew with
-- the member count, and the steel balancer was a non-rotatable h/v pair.
-- scripts/migrate.lua turns them into the fixed-size stations on the first
-- load; these stubs stay hidden forever so the migration is always possible.
--
-- Their inventory_size MUST match the old values exactly: the engine cuts a
-- linked inventory down to its prototype's size when a save loads, deleting
-- the rest (confirmed headless, see the old FACTORIO_API_NOTES.md).
local sprite_util = require("prototypes.util")
local constants = require("scripts.constants")

local TILES = constants.STATION_TILES
local TIER_ART = sprite_util.TIER_ART

local function legacy_station(tier, art, family, axis, size)
  local half_long = TILES / 2
  local half_wide = tier.width / 2
  local collision, selection
  if axis == "x" then
    collision = { { -(half_long - 0.1), -(half_wide - 0.1) }, { half_long - 0.1, half_wide - 0.1 } }
    selection = { { -half_long, -half_wide }, { half_long, half_wide } }
  else
    collision = { { -(half_wide - 0.1), -(half_long - 0.1) }, { half_wide - 0.1, half_long - 0.1 } }
    selection = { { -half_wide, -half_long }, { half_wide, half_long } }
  end
  local entity = {
    type = "linked-container",
    name = family .. "-g" .. size,
    localised_name = { "entity-name." .. family },
    icon = art.icon,
    icon_size = 64,
    hidden = true,
    hidden_in_factoriopedia = true,
    flags = { "placeable-neutral", "player-creation", "not-upgradable", "not-blueprintable", "no-copy-paste" },
    fast_replaceable_group = "freight-stations-station",
    minable = { mining_time = 0.5, result = axis == "x" and tier.item_h or tier.item_v },
    max_health = art.health,
    corpse = art.corpse,
    dying_explosion = art.explosion,
    collision_box = collision,
    selection_box = selection,
    gui_mode = "none",
    -- exactly the old capacity: N members' worth of slots
    inventory_size = size * tier.slots,
    inventory_type = "normal",
    picture = sprite_util.station_picture(tier.key, axis),
    circuit_connector = sprite_util.station_circuit_connector(tier, axis),
    circuit_wire_max_distance = default_circuit_wire_max_distance,
    deconstruction_alternative = family .. "-g1",
  }
  if tier.stack_multiplier then
    entity.inventory_type = "with_custom_stack_size"
    entity.inventory_properties = {
      stack_size_multiplier = tier.stack_multiplier,
      with_bar = false,
    }
  end
  return entity
end

-- The old steel balancer pair: 1 x width, one prototype per row axis.
local function legacy_balancer(tier, name, across_x)
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
    hidden = true,
    hidden_in_factoriopedia = true,
    flags = { "placeable-neutral", "player-creation", "not-upgradable", "not-blueprintable", "no-copy-paste" },
    minable = { mining_time = 0.2, result = tier.balancer_item },
    deconstruction_alternative = tier.balancer,
    max_health = 100,
    corpse = "medium-remnants",
    collision_box = { { -(bx - 0.1), -(by - 0.1) }, { bx - 0.1, by - 0.1 } },
    selection_box = { { -bx, -by }, { bx, by } },
    fast_replaceable_group = "freight-stations-balancer-" .. tier.key,
    picture = sprite_util.balancer_picture(tier.key, across_x and "y" or "x"),
  }
end

-- The old single items (the new line has one item per axis): kept hidden so
-- they do not vanish from player and chest inventories. Unplaceable; mine or
-- use them up before switching is not required, they are just inert.
local function legacy_item(name, icon)
  return {
    type = "item",
    name = name,
    localised_name = { "item-name." .. name },
    icon = icon,
    icon_size = 64,
    hidden = true,
    stack_size = 10,
  }
end

for _, tier in ipairs(constants.TIERS) do
  local art = TIER_ART[tier.key]
  local entities = {}
  for _, pair in ipairs({ { tier.station_h, "x" }, { tier.station_v, "y" } }) do
    for size = 1, tier.max_group do
      entities[#entities + 1] = legacy_station(tier, art, pair[1], pair[2], size)
    end
  end
  if tier.key == "steel" then
    entities[#entities + 1] = legacy_balancer(tier, "stock-balancer-steel-h", false)
    entities[#entities + 1] = legacy_balancer(tier, "stock-balancer-steel-v", true)
  end
  entities[#entities + 1] = legacy_item(tier.item_h:gsub("%-h$", ""), art.icon)
  data:extend(entities)
end

for _, tier in ipairs(constants.TANK_TIERS) do
  local art = TIER_ART[tier.key]
  data:extend({
    legacy_item(tier.item_h:gsub("%-h$", ""), art.icon),
  })
end
