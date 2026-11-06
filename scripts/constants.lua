local constants = {}

-- Shared between data stage (prototypes) and control stage (linking logic).
-- Must not reference any stage-specific API.

constants.STATION_TILES = 6 -- footprint length along a station's long axis
constants.GAP = 1 -- tile between consecutive stations, filled by a balancer

-- Most empty tiles allowed between the footprints of an underground balancer
-- pair. Station | inserter | rail (2) | inserter | station leaves 4; long
-- inserters on both sides leave 6. 8 gives some room beyond that.
constants.UNDERGROUND_MAX_GAP = 8

-- One station prototype per (tier, axis): linked containers cannot rotate,
-- so each axis is its own prototype placed by its own item. A group's
-- inventory is the prototype's fixed size (tier.slots), no matter how many
-- stations share it: members add access points, not space.
--
-- Tier fields:
--   width            tiles across the track (station is STATION_TILES x width)
--   slots            the group inventory's size (one prototype, fixed)
--   stack_multiplier optional; switches the inventory to with_custom_stack_size
--   station_h/v      the two axis prototypes
--   item_h/item_v     the items placing them
--   balancer          ONE rotatable prototype per tier: a
--                     simple-entity-with-owner rotates a non-square box
--                     (confirmed headless, see underground-balancer.lua)
--   underground       rotatable 1 x width balancer that also pairs across the track
constants.TIERS = {
  {
    key = "iron",
    width = 1,
    slots = 134, -- six iron chests (192) less 30%
    max_group = 100,
    station_h = "freight-station-h",
    station_v = "freight-station-v",
    item_h = "freight-station-item-h",
    item_v = "freight-station-item-v",
    balancer = "stock-balancer",
    balancer_item = "stock-balancer-item",
    underground = "underground-stock-balancer",
    underground_item = "underground-stock-balancer-item",
  },
  {
    key = "steel",
    width = 2,
    slots = 202, -- six steel chests (288) less 30%
    stack_multiplier = 2,
    max_group = 50,
    station_h = "freight-station-steel-h",
    station_v = "freight-station-steel-v",
    item_h = "freight-station-steel-item-h",
    item_v = "freight-station-steel-item-v",
    balancer = "stock-balancer-steel",
    balancer_item = "stock-balancer-steel-item",
    underground = "underground-stock-balancer-steel",
    underground_item = "underground-stock-balancer-steel-item",
  },
}

-- Fluid stations: the fluid counterpart, beside fluid wagons. A tank is a
-- storage-tank, and tanks joined by fluid balancers form one fluid segment,
-- which the engine already shares and splits like a group's inventory
-- (FACTORIO_API_NOTES.md §15). No group bookkeeping, one prototype per axis
-- and its own item, like the stations.
--
-- Tank tier fields, where they differ from TIERS:
--   volume       one tank's fluid capacity
--   balancer     one rotatable storage-tank connector
constants.TANK_TIERS = {
  {
    key = "tank",
    fluid = true,
    width = 1,
    volume = 150000, -- three fluid wagons, as an iron station holds about three cargo wagons
    station_h = "fluid-station-h",
    station_v = "fluid-station-v",
    item_h = "fluid-station-item-h",
    item_v = "fluid-station-item-v",
    balancer = "fluid-balancer",
    balancer_item = "fluid-balancer-item",
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
    item_h = "fluid-station-steel-item-h",
    item_v = "fluid-station-steel-item-v",
    balancer = "fluid-balancer-steel",
    balancer_item = "fluid-balancer-steel-item",
    underground = "underground-fluid-balancer-steel",
    underground_item = "underground-fluid-balancer-steel-item",
  },
}

-- Stations, then tanks: everything the build path serves.
constants.ALL_TIERS = {}
for _, list in ipairs({ constants.TIERS, constants.TANK_TIERS }) do
  for _, tier in ipairs(list) do
    constants.ALL_TIERS[#constants.ALL_TIERS + 1] = tier
  end
end

-- underground balancer prototype name -> tier (stations only: tank
-- undergrounds pair through the engine's own underground pipe connection)
constants.UNDERGROUND_TIER = {}
for _, tier in ipairs(constants.TIERS) do
  constants.UNDERGROUND_TIER[tier.underground] = tier
end

-- station prototype name -> { tier, family, axis }. A family is one tier +
-- axis (tier.station_h / tier.station_v); only stations of one family share
-- an inventory (a link_id is per prototype, so different prototypes could
-- never share one anyway).
constants.STATION_INFO = {}
-- family -> { tier, axis }
constants.FAMILY_INFO = {}
-- tank prototype name -> its family info
constants.TANK_INFO = {}
for _, tier in ipairs(constants.ALL_TIERS) do
  for _, pair in ipairs({ { tier.station_h, "x" }, { tier.station_v, "y" } }) do
    local family, axis = pair[1], pair[2]
    local info = { tier = tier, family = family, axis = axis }
    constants.STATION_INFO[family] = info
    constants.FAMILY_INFO[family] = info
    if tier.fluid then
      constants.TANK_INFO[family] = info
    end
  end
end

-- A plain container that stands in for a station marked for deconstruction
-- while it is the last of its group, holding the group's contents so robots
-- empty it one load at a time like a vanilla chest (linked containers
-- never get emptied that way). One station's slots: the most a group
-- inventory can hold. See scripts/dismantle.lua.
function constants.dismantling_name(family)
  return family .. "-dismantling"
end

-- The one entity a tier's stations (both axes and the dismantling stand-in)
-- show up as in the deconstruction planner.
function constants.deconstruction_entry(tier)
  return tier.station_h
end

return constants
