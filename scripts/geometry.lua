-- Physical adjacency between stations and balancers. Nothing here is
-- persisted -- every query walks the live world, so bookkeeping can never
-- drift out of sync with what's actually placed. That includes underground
-- balancer pairs: a pair is whatever the pairing rule below finds right now.
local constants = require("scripts.constants")

local geometry = {}

local STATION_AXIS = {} -- station prototype name -> its long axis
local TIER_OF = {} -- station / balancer / underground name -> tier key
local UNDERGROUND_TIER = constants.UNDERGROUND_TIER
local RELEVANT_NAMES = {}
for name, info in pairs(constants.STATION_INFO) do
  -- every size band included (name variants like family-s4): members swap
  -- between bands as groups grow, and the walk must keep seeing them
  STATION_AXIS[name] = info.axis
  TIER_OF[name] = info.tier.key
  RELEVANT_NAMES[#RELEVANT_NAMES + 1] = name
end
for _, tier in ipairs(constants.TIERS) do
  RELEVANT_NAMES[#RELEVANT_NAMES + 1] = tier.balancer
  RELEVANT_NAMES[#RELEVANT_NAMES + 1] = tier.underground
  TIER_OF[tier.balancer] = tier.key
  TIER_OF[tier.underground] = tier.key
end
table.sort(RELEVANT_NAMES)

local HALF_LONG = constants.STATION_TILES / 2
local BALANCER_HALF = 0.5
local PROBE_DEPTH = 0.3 -- must stay < 1 tile so a probe can't skip over a balancer
local PROBE_HALF_WIDTH = 0.3 -- must stay < 0.5 so a parallel, non-collinear track isn't caught
local LINE_HALF_WIDTH = 0.3 -- underground pairing: partner centres must be collinear
local EPSILON = 0.01

local FACING = {
  [defines.direction.north] = { x = 0, y = -1 },
  [defines.direction.east] = { x = 1, y = 0 },
  [defines.direction.south] = { x = 0, y = 1 },
  [defines.direction.west] = { x = -1, y = 0 },
}

function geometry.is_station(name)
  return STATION_AXIS[name] ~= nil
end

function geometry.is_underground(name)
  return UNDERGROUND_TIER[name] ~= nil
end

-- Balancers count as connectors: within their own row they link stations
-- exactly like a bridge, the cross-track pairing of undergrounds is on top.
function geometry.is_balancer(name)
  return TIER_OF[name] ~= nil and STATION_AXIS[name] == nil
end

function geometry.relevant_names()
  return RELEVANT_NAMES
end

local STATION_NAMES = {}
for name in pairs(STATION_AXIS) do
  STATION_NAMES[#STATION_NAMES + 1] = name
end
table.sort(STATION_NAMES)

function geometry.station_names()
  return STATION_NAMES
end

-- Searches go by entity type and check the name in Lua: a `name` filter
-- listing every prototype (300+ names in the old size-variant build) cost
-- several times more per call than the search itself (measured headless,
-- 2.0.77: a 100-station group walk went from 33 ms to 7.6 ms).
local RELEVANT = {}
for _, name in ipairs(RELEVANT_NAMES) do
  RELEVANT[name] = true
end
local RELEVANT_TYPES = { "linked-container", "simple-entity-with-owner" }

-- Stations matching `spec` (find_entities_filtered parameters without a
-- name or type), only those of `family` if given.
function geometry.find_stations(surface, spec, family)
  spec.type = "linked-container"
  local found = {}
  for _, entity in ipairs(surface.find_entities_filtered(spec)) do
    local info = constants.STATION_INFO[entity.name]
    if info and (not family or info.family == family) then
      found[#found + 1] = entity
    end
  end
  return found
end

function geometry.opposite(direction)
  return (direction + 8) % 16
end

-- A balancer or underground faces across the track, so its row runs
-- perpendicular to its facing: north/south-facing ones sit in a
-- horizontal (x) row.
local function row_axis(entity)
  local f = FACING[entity.direction]
  if f and f.x == 0 then
    return "x"
  end
  return "y"
end

local function connects_along(entity, axis)
  local station_axis = STATION_AXIS[entity.name]
  if station_axis then
    return station_axis == axis
  end
  return row_axis(entity) == axis
end

local function ports_of(entity)
  local p = entity.position
  local axis = STATION_AXIS[entity.name]
  if axis then
    if axis == "x" then
      return {
        { x = p.x + HALF_LONG, y = p.y, axis = "x" },
        { x = p.x - HALF_LONG, y = p.y, axis = "x" },
      }
    else
      return {
        { x = p.x, y = p.y + HALF_LONG, axis = "y" },
        { x = p.x, y = p.y - HALF_LONG, axis = "y" },
      }
    end
  end
  local ports = {}
  if row_axis(entity) == "x" then
    ports[#ports + 1] = { x = p.x + BALANCER_HALF, y = p.y, axis = "x" }
    ports[#ports + 1] = { x = p.x - BALANCER_HALF, y = p.y, axis = "x" }
  else
    ports[#ports + 1] = { x = p.x, y = p.y + BALANCER_HALF, axis = "y" }
    ports[#ports + 1] = { x = p.x, y = p.y - BALANCER_HALF, axis = "y" }
  end
  return ports
end

local function probe_area(port)
  if port.axis == "x" then
    return {
      { port.x - PROBE_DEPTH, port.y - PROBE_HALF_WIDTH },
      { port.x + PROBE_DEPTH, port.y + PROBE_HALF_WIDTH },
    }
  else
    return {
      { port.x - PROBE_HALF_WIDTH, port.y - PROBE_DEPTH },
      { port.x + PROBE_HALF_WIDTH, port.y + PROBE_DEPTH },
    }
  end
end

-- Every `exclude_unit_number` parameter below is a unit number, a set
-- {unit_number = true}, or nil.
local function excluded(exclude, unit_number)
  if type(exclude) == "table" then
    return exclude[unit_number] == true
  end
  return unit_number == exclude
end

geometry.excluded = excluded

-- The nearest same-tier underground on `entity`'s line, looking along
-- `direction`, within pairing range. Any same-tier underground blocks the
-- line regardless of which way it faces (like underground belts); other
-- entities don't. `exclude_unit_number` is treated as already gone.
function geometry.nearest_on_line(surface, entity, direction, exclude_unit_number)
  local tier = UNDERGROUND_TIER[entity.name]
  local f = FACING[direction]
  if not (tier and f) then
    return nil
  end
  local p = entity.position
  local half = tier.width / 2
  -- partner centres sit exactly `width + gap` away for gap in 0..MAX_GAP
  local max_offset = tier.width + constants.UNDERGROUND_MAX_GAP
  local near = half + EPSILON
  local far = max_offset + EPSILON
  local area
  if f.x ~= 0 then
    local x1, x2 = p.x + f.x * near, p.x + f.x * far
    area = { { math.min(x1, x2), p.y - LINE_HALF_WIDTH }, { math.max(x1, x2), p.y + LINE_HALF_WIDTH } }
  else
    local y1, y2 = p.y + f.y * near, p.y + f.y * far
    area = { { p.x - LINE_HALF_WIDTH, math.min(y1, y2) }, { p.x + LINE_HALF_WIDTH, math.max(y1, y2) } }
  end

  local best, best_offset
  for _, candidate in ipairs(surface.find_entities_filtered({ area = area, name = entity.name })) do
    if candidate.valid and candidate.unit_number ~= entity.unit_number and not excluded(exclude_unit_number, candidate.unit_number) then
      local dx, dy = candidate.position.x - p.x, candidate.position.y - p.y
      local along = dx * f.x + dy * f.y
      local lateral = math.abs(dx * f.y - dy * f.x)
      if lateral < EPSILON and along > 0 and along <= max_offset + EPSILON then
        if not best_offset or along < best_offset then
          best, best_offset = candidate, along
        end
      end
    end
  end
  return best
end

-- The underground `entity` is paired with, if any: the nearest one ahead of
-- it must face straight back. Symmetric by construction -- nothing of the
-- same tier sits between them, so each is the other's nearest.
function geometry.partner(surface, entity, exclude_unit_number)
  local candidate = geometry.nearest_on_line(surface, entity, entity.direction, exclude_unit_number)
  if candidate and candidate.direction == geometry.opposite(entity.direction) then
    return candidate
  end
  return nil
end

-- The nearest same-tier undergrounds on both lines through `entity`, in all
-- four directions. These are the only undergrounds whose pairing `entity`
-- can affect: it blocks a pair whatever way it faces, so a pair across its
-- facing can link up past it once it's gone too.
function geometry.line_undergrounds(surface, entity, exclude_unit_number)
  local found = {}
  for _, d in ipairs({ defines.direction.north, defines.direction.east, defines.direction.south, defines.direction.west }) do
    local u = geometry.nearest_on_line(surface, entity, d, exclude_unit_number)
    if u then
      found[#found + 1] = u
    end
  end
  return found
end

-- A balancer (regular or underground) only links things of its own tier:
-- iron balancers join iron stations, steel balancers steel stations.
-- Station-to-station contact is left to groups.lua, which refuses to merge
-- different families anyway.
local function same_tier_rule(a, b)
  if geometry.is_balancer(a.name) or geometry.is_balancer(b.name) then
    return TIER_OF[a.name] == TIER_OF[b.name]
  end
  return true
end

-- Every collinear entity directly touching `entity`'s ends, tier or not.
local function touching(surface, entity, exclude_unit_number)
  local found = {}
  for _, port in ipairs(ports_of(entity)) do
    local candidates = surface.find_entities_filtered({ area = probe_area(port), type = RELEVANT_TYPES })
    for _, candidate in ipairs(candidates) do
      if
        candidate.valid
        and RELEVANT[candidate.name]
        and candidate.unit_number ~= entity.unit_number
        and not excluded(exclude_unit_number, candidate.unit_number)
        -- a station must share the probing axis to count as a real collinear
        -- neighbour; a balancer must connect along that axis too.
        and connects_along(candidate, port.axis)
      then
        found[candidate.unit_number] = candidate
      end
    end
  end
  return found
end

-- Entities whose footprint directly touches `entity`'s ends and that it may
-- link with (see same_tier_rule), plus an underground's paired partner.
-- `exclude_unit_number` lets callers treat an entity that's mid-removal (but
-- possibly still `.valid`) as if it were already gone.
function geometry.immediate_neighbors(surface, entity, exclude_unit_number)
  local found = {}
  for unit_number, candidate in pairs(touching(surface, entity, exclude_unit_number)) do
    if same_tier_rule(entity, candidate) then
      found[unit_number] = candidate
    end
  end
  if UNDERGROUND_TIER[entity.name] then
    local partner = geometry.partner(surface, entity, exclude_unit_number)
    if partner then
      found[partner.unit_number] = partner
    end
  end
  return found
end

-- BFS over the physical station/balancer graph starting at `start_entity`.
-- Returns every reachable STATION (balancers are pass-through, not members)
-- as {unit_number = LuaEntity}, plus every visited node (stations AND
-- balancers) as {unit_number = true}. `exclude_unit_number` is walked
-- around, for use right after something is removed but before bookkeeping
-- catches up.
function geometry.reachable_stations(surface, start_entity, exclude_unit_number)
  local visited = { [start_entity.unit_number] = true }
  local stations = {}
  local queue = { start_entity }
  local head = 1

  while queue[head] do
    local current = queue[head]
    head = head + 1
    if geometry.is_station(current.name) then
      stations[current.unit_number] = current
    end
    for unit_number, neighbor in pairs(geometry.immediate_neighbors(surface, current, exclude_unit_number)) do
      if not visited[unit_number] then
        visited[unit_number] = true
        queue[#queue + 1] = neighbor
      end
    end
  end

  return stations, visited
end

-- Connected components left behind when `entity` goes: one BFS per
-- neighbour not already covered by an earlier one (two neighbours can still
-- be connected the long way round, e.g. through two underground pairs).
function geometry.pieces_around(surface, entity, removed)
  local pieces = {}
  local covered = {}
  for unit_number, neighbor in pairs(geometry.immediate_neighbors(surface, entity, removed)) do
    if not covered[unit_number] then
      local stations, visited = geometry.reachable_stations(surface, neighbor, removed)
      for u in pairs(visited) do
        covered[u] = true
      end
      if next(stations) then
        pieces[#pieces + 1] = stations
      end
    end
  end
  return pieces
end

return geometry
