-- Freight stations: one pair of prototypes (horizontal/vertical) per tier in
-- scripts/constants.lua. Horizontal and vertical are separate prototypes
-- because LinkedContainerPrototype has no `direction_count` and cannot
-- rotate (confirmed against the 2.0.77 docs, see FACTORIO_API_NOTES.md §8);
-- each axis gets its own item that places it directly.
--
-- Every member of a group shares ONE inventory of the prototype's fixed
-- inventory_size: members add access points, not space. That is what keeps
-- this mod out of the entity-replacement business entirely -- undo,
-- blueprints, ghosts, pipette and fast-replace are all engine-native here.

local sprite_util = require("prototypes.util")
local constants = require("scripts.constants")
local compat = require("scripts.compat")

local TILES = constants.STATION_TILES

local TIER_ART = sprite_util.TIER_ART

local function station_entity(tier, art, family, axis, band)
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
    name = constants.station_name(family, band),
    localised_name = { "entity-name." .. family },
    localised_description = { "entity-description." .. family },
    icon = art.icon,
    icon_size = 64,
    -- larger bands stay out of the factoriopedia: one entry per family
    hidden_in_factoriopedia = band > 1,
    -- No upgrade path exists, so no size is an upgrade source.
    flags = { "placeable-neutral", "player-creation", "not-upgradable" },
    -- Vanilla-container behaviour: a station can be built over (fast
    -- replaced) by another station.
    fast_replaceable_group = "freight-stations-station",
    minable = { mining_time = 0.5, result = axis == "x" and tier.item_h or tier.item_v },
    max_health = art.health,
    corpse = art.corpse,
    dying_explosion = art.explosion,
    collision_box = collision,
    selection_box = selection,
    gui_mode = "none", -- script owns link_id entirely; no player-facing link GUI
    -- The group's capacity, rounded up to its size band: every member
    -- shows every slot.
    inventory_size = band * tier.slots,
    inventory_type = "normal",
    picture = sprite_util.station_picture(tier.key, axis),
    -- Like a vanilla chest, a wired station reads out its contents -- which
    -- for a linked container is the whole group's shared inventory, so any
    -- one member reports the group total.
    circuit_connector = sprite_util.station_circuit_connector(tier, axis),
    circuit_wire_max_distance = default_circuit_wire_max_distance,
  }

  -- One deconstruction planner entry per tier: both axes fold into the
  -- horizontal station, the way vanilla folds curved rails into straight.
  local entry = constants.deconstruction_entry(tier)
  if entity.name ~= entry then
    entity.deconstruction_alternative = entry
  end

  if tier.stack_multiplier then
    -- Steel tier's real advantage over iron beyond footprint: every stack
    -- holds more. Core since base 2.0.56 (FACTORIO_API_NOTES.md §1).
    entity.inventory_type = "with_custom_stack_size"
    entity.inventory_properties = {
      stack_size_multiplier = tier.stack_multiplier,
      with_bar = false,
    }
  end
  return entity
end

-- The stand-in a lone station marked for deconstruction turns into (see
-- scripts/dismantle.lua): looks like a lone station, holds the group
-- inventory's whole contents (sized to the band), and gives the station
-- item when robots finally mine it.
local function dismantling_entity(tier, art, family, axis, band)
  local entity = station_entity(tier, art, family, axis, band)
  entity.type = "container"
  entity.circuit_connector = compat.container_circuit_connector(entity.circuit_connector)
  entity.name = constants.dismantling_name(family, band)
  entity.deconstruction_alternative = constants.deconstruction_entry(tier)
  entity.localised_name = { "entity-name.freight-station-dismantling", { "entity-name." .. family } }
  entity.localised_description = { "entity-description.freight-station-dismantling" }
  entity.hidden = true
  entity.hidden_in_factoriopedia = true
  entity.flags = { "placeable-neutral", "player-creation", "not-blueprintable", "not-upgradable", "no-copy-paste" }
  entity.gui_mode = nil
  return entity
end

local function station_item(tier, art, name, axis)
  return {
    type = "item",
    name = name,
    localised_name = { "item-name." .. name },
    localised_description = { "entity-description." .. (axis == "x" and tier.station_h or tier.station_v) },
    icon = art.icon,
    icon_size = 64,
    subgroup = sprite_util.SUBGROUP,
    order = sprite_util.order(tier, "a[station]"),
    place_result = axis == "x" and tier.station_h or tier.station_v,
    stack_size = 10,
  }
end

for _, tier in ipairs(constants.TIERS) do
  local art = TIER_ART[tier.key]
  local entities = {}
  for _, pair in ipairs({ { tier.station_h, "x" }, { tier.station_v, "y" } }) do
    local family, axis = pair[1], pair[2]
    for _, band in ipairs(constants.BANDS[tier.key]) do
      entities[#entities + 1] = station_entity(tier, art, family, axis, band)
      entities[#entities + 1] = dismantling_entity(tier, art, family, axis, band)
    end
  end
  entities[#entities + 1] = station_item(tier, art, tier.item_h, "x")
  entities[#entities + 1] = station_item(tier, art, tier.item_v, "y")
  data:extend(entities)
end
