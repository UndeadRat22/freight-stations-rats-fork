local constants = {}

-- Shared between data stage (prototypes) and control stage (group logic).
-- Must not reference any stage-specific API.

constants.STATION_TILES = 6 -- footprint length along a station's long axis
constants.GAP = 1 -- tile between consecutive stations, filled by a balancer

-- Most empty tiles allowed between the footprints of an underground balancer
-- pair. Station | inserter | rail (2) | inserter | station leaves 4; long
-- inserters on both sides leave 6. 8 gives some room beyond that.
constants.UNDERGROUND_MAX_GAP = 8

-- Most empty tiles allowed between a station and the parallel track it
-- serves (scripts/rails.lua): 1 fits an inserter, 2 a loader pair.
constants.MAX_RAIL_GAP = 2

-- Empty tiles between a tank and the track that a pump fills (a pump is
-- 1 x 2 and only reaches a fluid wagon from right beside the rail). The
-- placement guide only suggests this distance for tanks.
constants.PUMP_GAP = 2

-- A station must line up with one of the first this-many carriages of a
-- train stopped at a train stop on its track (scripts/rails.lua).
constants.MAX_TRAIN_CARS = 12

-- Where the real station sits relative to its station placer's position,
-- per placer direction: half a tile toward the placer's local west, away
-- from the gap tile (prototypes/placer.lua). `defines` exists in both stages.
local PLACER_OFFSETS = {
  [defines.direction.north] = { x = -0.5, y = 0 },
  [defines.direction.east] = { x = 0, y = -0.5 },
  [defines.direction.south] = { x = 0.5, y = 0 },
  [defines.direction.west] = { x = 0, y = 0.5 },
}

function constants.placer_offset(direction)
  return PLACER_OFFSETS[direction] or PLACER_OFFSETS[defines.direction.north]
end

-- Every station sharing a link_id shares ONE physical inventory, sized by the
-- prototype's inventory_size (see STATION_INFO below: one prototype per group
-- size). Linked inventories are kept per prototype AND link_id, and outlive
-- their entities (confirmed headless, 2.0.77), so resizing a group means
-- moving its items into the new prototype's inventory and clearing the old.
-- max_group caps a group and is also the number of size prototypes per family.
--
-- Tier fields:
--   width            tiles across the track (station is STATION_TILES x width)
--   slots            one station's contribution to group capacity. Never
--                    lower it under the same prototype names: the engine
--                    cuts a linked inventory down to its prototype's size
--                    when a save loads, deleting the rest (confirmed
--                    headless, 2.0.77). Rename the sizes instead.
--   max_group        stations per group ceiling
--   stack_multiplier optional; switches the inventory to with_custom_stack_size
--   balancer_*       wide tiers (balancer_placer set) get h/v balancer prototypes
--   underground      rotatable 1 x width balancer that also pairs across the track
constants.TIERS = {
  {
    key = "iron",
    width = 1,
    slots = 134, -- six iron chests (192) less 30%
    max_group = 100,
    station_h = "freight-station-h",
    station_v = "freight-station-v",
    placer = "freight-station-placer",
    item = "freight-station-item",
    balancer_item = "stock-balancer-item",
    balancer_h = "stock-balancer",
    balancer_v = "stock-balancer",
    balancer_placer = nil,
    underground = "underground-stock-balancer",
    underground_item = "underground-stock-balancer-item",
  },
  {
    key = "steel",
    width = 2,
    slots = 202, -- six steel chests (288) less 30%
    max_group = 50,
    stack_multiplier = 2,
    station_h = "freight-station-steel-h",
    station_v = "freight-station-steel-v",
    placer = "freight-station-steel-placer",
    item = "freight-station-steel-item",
    balancer_item = "stock-balancer-steel-item",
    balancer_h = "stock-balancer-steel-h",
    balancer_v = "stock-balancer-steel-v",
    balancer_placer = "stock-balancer-steel-placer",
    underground = "underground-stock-balancer-steel",
    underground_item = "underground-stock-balancer-steel-item",
  },
}

-- Fluid stations: the fluid counterpart, beside fluid wagons. A tank is a
-- storage-tank, and tanks joined by fluid balancers form one fluid segment,
-- which the engine already shares and splits like a group's inventory
-- (FACTORIO_API_NOTES.md §15). So there is no group bookkeeping, one
-- prototype per axis and no size variants. They go through the same placer,
-- wagon slots, rail rule, guide and blueprint swap as the stations.
--
-- Tank tier fields, where they differ from TIERS:
--   volume       one tank's fluid capacity
--   balancer_h/v one rotatable storage-tank connector; _h and _v name the
--                same prototype, built facing north in a row along x and
--                east in a row along y
constants.TANK_TIERS = {
  {
    key = "tank",
    fluid = true,
    width = 1,
    volume = 150000, -- three fluid wagons, as an iron station holds about three cargo wagons
    station_h = "fluid-station-h",
    station_v = "fluid-station-v",
    placer = "fluid-station-placer",
    item = "fluid-station-item",
    balancer_item = "fluid-balancer-item",
    balancer_h = "fluid-balancer",
    balancer_v = "fluid-balancer",
    underground = "underground-fluid-balancer",
    underground_item = "underground-fluid-balancer-item",
  },
  {
    key = "tank-steel",
    fluid = true,
    width = 2,
    volume = 500000, -- ten fluid wagons, as a steel station holds about ten cargo wagons
    station_h = "fluid-station-steel-h",
    station_v = "fluid-station-steel-v",
    placer = "fluid-station-steel-placer",
    item = "fluid-station-steel-item",
    balancer_item = "fluid-balancer-steel-item",
    balancer_h = "fluid-balancer-steel",
    balancer_v = "fluid-balancer-steel",
    underground = "underground-fluid-balancer-steel",
    underground_item = "underground-fluid-balancer-steel-item",
  },
}

-- Stations, then tanks: everything the placer path serves.
constants.ALL_TIERS = {}
for _, list in ipairs({ constants.TIERS, constants.TANK_TIERS }) do
  for _, tier in ipairs(list) do
    constants.ALL_TIERS[#constants.ALL_TIERS + 1] = tier
  end
end

-- underground balancer prototype name -> tier (stations only: tank
-- undergrounds pair through the engine's own underground pipe connection)
constants.UNDERGROUND_TIER = {}
-- every placer name (station, tank + balancer) -> true
constants.PLACERS = {}
for _, tier in ipairs(constants.TIERS) do
  constants.UNDERGROUND_TIER[tier.underground] = tier
end
for _, tier in ipairs(constants.ALL_TIERS) do
  constants.PLACERS[tier.placer] = true
  if tier.balancer_placer then
    constants.PLACERS[tier.balancer_placer] = true
  end
end

-- One station prototype per (family, group size): a linked-container's
-- inventory_size is fixed per prototype, and the inventory window shows every
-- slot of it, so the only way to show exactly a group's real capacity is for
-- every member to BE the prototype sized for that group. scripts/groups.lua
-- swaps members to the right size whenever a group's station count changes.
-- A family is one tier + axis (tier.station_h / tier.station_v); only
-- stations of one family can share an inventory.
--
-- station prototype name -> { tier, family, axis, size }
constants.STATION_INFO = {}
-- family -> list of every size variant's name, size 1 first
constants.FAMILY_NAMES = {}

function constants.station_name(family, size)
  return family .. "-g" .. size
end

-- The one entity a tier's stations (every size, both axes, the placer and
-- the dismantling stand-in) show up as in the deconstruction planner.
function constants.deconstruction_entry(tier)
  return constants.station_name(tier.station_h, 1)
end

-- A plain container that stands in for a station marked for
-- deconstruction, holding what its group couldn't keep, so robots empty it
-- one load at a time like a vanilla chest (linked containers never get
-- emptied that way). One station's slots: the most a removed station can
-- leave behind. See scripts/dismantle.lua.
function constants.dismantling_name(family)
  return family .. "-dismantling"
end

for _, tier in ipairs(constants.TIERS) do
  for _, pair in ipairs({ { tier.station_h, "x" }, { tier.station_v, "y" } }) do
    local family, axis = pair[1], pair[2]
    local names = {}
    for size = 1, tier.max_group do
      local name = constants.station_name(family, size)
      names[size] = name
      constants.STATION_INFO[name] = { tier = tier, family = family, axis = axis, size = size }
    end
    constants.FAMILY_NAMES[family] = names
  end
end

-- What the placer path needs to know of a family (one tier + axis, station
-- or tank): family -> { tier, axis, name, balancer_direction }. `name` is
-- the prototype a new one is built as (a station's size-1 prototype),
-- `balancer_direction` the direction to build its balancer with.
constants.FAMILY_INFO = {}
-- tank prototype name -> its family info
constants.TANK_INFO = {}
for _, tier in ipairs(constants.ALL_TIERS) do
  for _, pair in ipairs({ { tier.station_h, "x", defines.direction.north }, { tier.station_v, "y", defines.direction.east } }) do
    local family, axis = pair[1], pair[2]
    local info = {
      tier = tier,
      axis = axis,
      family = family,
      name = tier.fluid and family or constants.station_name(family, 1),
      -- station balancers are separate h/v prototypes and don't turn
      balancer_direction = tier.fluid and pair[3] or defines.direction.north,
    }
    constants.FAMILY_INFO[family] = info
    if tier.fluid then
      constants.TANK_INFO[family] = info
    end
  end
end

-- What every entity in PLACER_OF names as its placeable_by: a hidden twin
-- of the item it costs (prototypes/placeholders.lua). The upgrade planner
-- offers any entity some visible item builds as an upgrade target, so with
-- the real item there, every station size showed up in it. An entity with
-- no item at all is left out of blueprints and never gets a ghost (both
-- confirmed headless, 2.0.77), hence an item. Robots can't bring a hidden
-- one, so every ghost of these becomes a ghost of its placer
-- (scripts/ghosts.lua).
function constants.placeholder(item)
  return item .. "-placeholder"
end

-- Entities only ever built through a placer (every station size, both tank
-- axes, the wide tiers' balancers) -> { placer, direction to give the
-- placer, item (what it costs), station (true: the placer sits half a tile
-- off it, constants.placer_offset) }.
constants.PLACER_OF = {}
for _, infos in ipairs({ constants.STATION_INFO, constants.TANK_INFO }) do
  for name, info in pairs(infos) do
    constants.PLACER_OF[name] = {
      placer = info.tier.placer,
      direction = info.axis == "x" and defines.direction.north or defines.direction.east,
      item = info.tier.item,
      station = true,
    }
  end
end
for _, tier in ipairs(constants.TIERS) do
  if tier.balancer_placer then
    constants.PLACER_OF[tier.balancer_h] = { placer = tier.balancer_placer, direction = defines.direction.north, item = tier.balancer_item }
    constants.PLACER_OF[tier.balancer_v] = { placer = tier.balancer_placer, direction = defines.direction.east, item = tier.balancer_item }
  end
end

-- placeholder item name -> the real item
constants.REAL_ITEM = {}
for _, swap in pairs(constants.PLACER_OF) do
  constants.REAL_ITEM[constants.placeholder(swap.item)] = swap.item
end

return constants
