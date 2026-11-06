-- Placement rule: a station has to stand beside a track, parallel to it, so
-- it can only ever be a loading platform and never a free-standing
-- warehouse. Every one of its tiles along the track needs a straight rail
-- level with it, at most MAX_RAIL_GAP empty tiles away (1 for an inserter,
-- 2 for a pair of loaders like Krastorio's). Rails on either side count.
--
-- 2.0 straight rails (confirmed headless, 2.0.77): 2x2, centred on odd
-- coordinates, direction north/south (0) = vertical track, east/west (4) =
-- horizontal; diagonals report other directions and never count. Elevated
-- rails are a different type and don't count either: nothing can reach a
-- wagon on them from the ground.
local constants = require("scripts.constants")

local rails = {}

local RAIL_HALF = 1
local EPSILON = 0.01

local TRACK_DIRECTION = {
  x = { [defines.direction.east] = true, [defines.direction.west] = true },
  y = { [defines.direction.north] = true, [defines.direction.south] = true },
}

-- Built entities of `type` in `area` plus ghosts of it: a pasted layout's
-- stations have to fit the rails and stop pasted with them, before robots
-- have built either.
local function find_with_ghosts(surface, area, type)
  local found = surface.find_entities_filtered({ area = area, type = type })
  for _, ghost in ipairs(surface.find_entities_filtered({ area = area, ghost_type = type })) do
    found[#found + 1] = ghost
  end
  return found
end

-- An area spanning `along_min`..`along_max` on the `along` axis and
-- `across_min`..`across_max` on the other.
local function area(along, along_min, along_max, across_min, across_max)
  if along == "x" then
    return { { along_min, across_min }, { along_max, across_max } }
  end
  return { { across_min, along_min }, { across_max, along_max } }
end

-- Positions of every rail (built or ghost) in `area` that a station along
-- `along` can stand beside: straight rails running that way, plus curved
-- rails (flagged `curved`). A curved rail's anchor sits near the middle of
-- its ~4-tile piece on the line of the track it continues (measured headless
-- 2.1.24: an E/W-going curve anchors at even x on the track's y, a N/S-going
-- one at odd x), so covered_tiles' across check keeps it honest; covered_tiles
-- marks its anchor pair plus the tile toward the station, so a station can
-- end where a curved segment begins. Without counting curves, a station can
-- never stand beside the start of a curved segment at all.
local function parallel_rails(surface, search_area, along)
  local found = {}
  for _, rail in ipairs(find_with_ghosts(surface, search_area, "straight-rail")) do
    if TRACK_DIRECTION[along][rail.direction] then
      found[#found + 1] = { x = rail.position.x, y = rail.position.y }
    end
  end
  for _, type in ipairs({ "curved-rail-a", "curved-rail-b" }) do
    for _, rail in ipairs(find_with_ghosts(surface, search_area, type)) do
      found[#found + 1] = { x = rail.position.x, y = rail.position.y, curved = true }
    end
  end
  return found
end

-- How far across the track from a station's centre a rail it can use may sit.
local function reach(tier)
  return tier.width / 2 + constants.MAX_RAIL_GAP + 2 * RAIL_HALF
end

-- The along-track tiles (indexed by the floor of their centre) that have a
-- rail from `rail_positions` level with them, at a usable distance from a
-- station of `family` whose centre sits at `across_value` across the track.
function rails.covered_tiles(rail_positions, family, across_value, along_value)
  local info = constants.FAMILY_INFO[family]
  local along = info.axis
  local across = along == "x" and "y" or "x"
  local half_wide = info.tier.width / 2
  local covered = {}
  for _, p in ipairs(rail_positions) do
    local gap = math.abs(p[across] - across_value) - half_wide - RAIL_HALF
    if gap > -EPSILON and gap < constants.MAX_RAIL_GAP + EPSILON then
      -- the two tiles whose centres lie within RAIL_HALF of the rail's
      covered[math.floor(p[along] - 0.5)] = true
      covered[math.floor(p[along] + 0.5)] = true
      -- a curved rail also covers the tile its piece spans toward the
      -- station (its anchor sits mid-piece; the connection end is on the
      -- station's side). Straight rails must NOT get this: it would paper
      -- over a one-tile missing rail under the station.
      if p.curved and along_value then
        if p[along] > along_value then
          covered[math.floor(p[along] - 1.5)] = true
        elseif p[along] < along_value then
          covered[math.floor(p[along] + 1.5)] = true
        end
      end
    end
  end
  return covered
end

-- True if a station of `family` centred at `position` would satisfy the rule.
-- `covered` (from rails.covered_tiles for this position's across value)
-- saves the lookup when checking many positions at once; nil looks it up.
function rails.station_ok(surface, position, family, covered)
  local info = constants.FAMILY_INFO[family]
  local along = info.axis
  local across = along == "x" and "y" or "x"
  local half_long = constants.STATION_TILES / 2

  if not covered then
    local r = reach(info.tier)
    local rail_positions = parallel_rails(
      surface,
      area(along, position[along] - half_long - RAIL_HALF, position[along] + half_long + RAIL_HALF, position[across] - r, position[across] + r),
      along
    )
    covered = rails.covered_tiles(rail_positions, family, position[across], position[along])
  end

  for i = 0, constants.STATION_TILES - 1 do
    if not covered[math.floor(position[along] - half_long + 0.5 + i)] then
      return false
    end
  end
  return true
end

-- Wagon slots. Measured headless (2.0.77, a locomotive + 3 wagons run into a
-- stop in each of the 4 directions): a stop sits 2 tiles to the right of its
-- track (relative to travel), and a stopped train's carriage k (0 = the
-- front one) is centred 3 + 7k tiles behind the stop along the track.
-- 7 = station (6) + gap (1), so one station lines up with each wagon.
local STOP_TO_TRACK = 2
local FIRST_CAR = 3
local CAR_PITCH = 7

local FORWARD = {
  [defines.direction.north] = { x = 0, y = -1 },
  [defines.direction.east] = { x = 1, y = 0 },
  [defines.direction.south] = { x = 0, y = 1 },
  [defines.direction.west] = { x = -1, y = 0 },
}

rails.CAR_PITCH = CAR_PITCH

-- A stop's track and carriage positions: `along` axis of the track, `track`
-- its across coordinate, `forward` +-1 travel direction along it, `origin`
-- the along coordinate of carriage 0's centre (carriage k is at
-- origin - forward * CAR_PITCH * k). nil for a stop not facing a cardinal
-- direction.
function rails.stop_layout(stop)
  local f = FORWARD[stop.direction]
  if not f then
    return nil
  end
  local along = f.x ~= 0 and "x" or "y"
  local across = along == "x" and "y" or "x"
  local right = { x = -f.y, y = f.x }
  return {
    along = along,
    across = across,
    track = stop.position[across] - STOP_TO_TRACK * right[across],
    forward = f[along],
    origin = stop.position[along] - f[along] * FIRST_CAR,
  }
end

-- Every rail a station of `family` in any of `layout`'s wagon slots could
-- use, on either side, for rails.covered_tiles (scripts/guide.lua).
function rails.slot_rails(surface, layout, family)
  local tier = constants.FAMILY_INFO[family].tier
  local first = layout.origin
  local last = layout.origin - layout.forward * CAR_PITCH * (constants.MAX_TRAIN_CARS - 1)
  local half_long = constants.STATION_TILES / 2
  -- the farthest a station sits from the track, plus its own reach
  local r = RAIL_HALF + constants.MAX_RAIL_GAP + tier.width / 2 + reach(tier)
  return parallel_rails(
    surface,
    area(
      layout.along,
      math.min(first, last) - half_long - RAIL_HALF,
      math.max(first, last) + half_long + RAIL_HALF,
      layout.track - r,
      layout.track + r
    ),
    layout.along
  )
end

-- The nearest point of a stop's carriage grid to `position`, moved along
-- `along` only: the grid point k (0 <= k < count) sits `first` + CAR_PITCH * k
-- behind carriage 0's centre. Only stops whose track runs along `along`
-- and passes beside something `half_wide` across (within MAX_RAIL_GAP)
-- count. Returns the point and its shift, or nil if there's no such stop.
local function nearest_on_grid(surface, position, along, half_wide, first, count)
  local across = along == "x" and "y" or "x"
  local radius = FIRST_CAR + CAR_PITCH * constants.MAX_TRAIN_CARS + CAR_PITCH
  local area = { { position.x - radius, position.y - radius }, { position.x + radius, position.y + radius } }
  local stops = find_with_ghosts(surface, area, "train-stop")

  local best, best_shift
  for _, stop in ipairs(stops) do
    local layout = rails.stop_layout(stop)
    if layout and layout.along == along then
      local track = layout.track
      local gap = math.abs(track - position[across]) - half_wide - RAIL_HALF
      if gap > -EPSILON and gap < constants.MAX_RAIL_GAP + EPSILON then
        local fa = layout.forward
        local origin = layout.origin
        local k = math.floor(((origin - position[along]) * fa - first) / CAR_PITCH + 0.5)
        if k >= 0 and k < count then
          local centre = origin - fa * (first + CAR_PITCH * k)
          local shift = math.abs(centre - position[along])
          if not best_shift or shift < best_shift then
            best_shift = shift
            best = { [along] = centre, [across] = position[across] }
          end
        end
      end
    end
  end
  return best, best_shift
end

-- Where a station of `family` placed at `position` belongs: moved along the
-- track to the nearest wagon slot of a train stop whose track it stands
-- beside (within MAX_RAIL_GAP), counting only the first MAX_TRAIN_CARS
-- carriages behind the stop. Returns nil if there's no such stop. Picks the
-- slot needing the smallest shift if several stops qualify.
function rails.wagon_slot(surface, position, family)
  local info = constants.FAMILY_INFO[family]
  return (nearest_on_grid(surface, position, info.axis, info.tier.width / 2, 0, constants.MAX_TRAIN_CARS))
end

-- Where a balancer of `tier` in a row along `along` belongs: the nearest
-- gap between two wagon slots, by the same rules as rails.wagon_slot.
-- Returns the gap centre and the shift, or nil.
function rails.gap_slot(surface, position, along, tier)
  return nearest_on_grid(surface, position, along, tier.width / 2, CAR_PITCH / 2, constants.MAX_TRAIN_CARS - 1)
end

return rails
