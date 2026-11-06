-- Player-facing behaviour of underground fluid balancers. Their pairing is
-- the engine's own underground pipe connection (prototypes/fluid-stations.lua),
-- so unlike the stations' undergrounds (scripts/underground.lua) there is no
-- bookkeeping: this only decides which way one faces and shows the player
-- what it paired with.
local constants = require("scripts.constants")
local compat = require("scripts.compat")

local tanks = {}

local PAIR_COLOR = { r = 0.3, g = 1, b = 0.4, a = 0.8 }
local LINE_HALF_WIDTH = 0.3
local EPSILON = 0.01

-- underground fluid balancer name -> tier
local UNDERGROUND = {}
for _, tier in ipairs(constants.TANK_TIERS) do
  UNDERGROUND[tier.underground] = tier
end

local FACING = {
  [defines.direction.north] = { x = 0, y = -1 },
  [defines.direction.east] = { x = 1, y = 0 },
  [defines.direction.south] = { x = 0, y = 1 },
  [defines.direction.west] = { x = -1, y = 0 },
}

local function opposite(direction)
  return (direction + 8) % 16
end

function tanks.is_underground(name)
  return UNDERGROUND[name] ~= nil
end

function tanks.underground_names()
  local names = {}
  for name in pairs(UNDERGROUND) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

-- The nearest underground of `entity`'s tier straight ahead of it along
-- `direction`, within pairing range, or nil.
local function nearest_on_line(entity, direction)
  local tier = UNDERGROUND[entity.name]
  local f = FACING[direction]
  local p = entity.position
  local far = tier.width + constants.UNDERGROUND_MAX_GAP + EPSILON
  local near = tier.width / 2 + EPSILON
  local area
  if f.x ~= 0 then
    local x1, x2 = p.x + f.x * near, p.x + f.x * far
    area = { { math.min(x1, x2), p.y - LINE_HALF_WIDTH }, { math.max(x1, x2), p.y + LINE_HALF_WIDTH } }
  else
    local y1, y2 = p.y + f.y * near, p.y + f.y * far
    area = { { p.x - LINE_HALF_WIDTH, math.min(y1, y2) }, { p.x + LINE_HALF_WIDTH, math.max(y1, y2) } }
  end
  local best, best_along
  for _, candidate in ipairs(entity.surface.find_entities_filtered({ area = area, name = entity.name })) do
    local along = (candidate.position.x - p.x) * f.x + (candidate.position.y - p.y) * f.y
    if along > 0 and (not best_along or along < best_along) then
      best, best_along = candidate, along
    end
  end
  return best
end

-- The underground `entity`'s underground connection reached, if any: one
-- of its fluid neighbours of the same tier, facing it.
function tanks.partner(entity)
  for _, neighbour in ipairs(compat.fluid_neighbours(entity)) do
    if neighbour.name == entity.name and neighbour.direction == opposite(entity.direction) then
      return neighbour
    end
  end
  return nil
end

local function show_pair(entity, player_index)
  if not (player_index and game.get_player(player_index)) then
    return
  end
  local partner = tanks.partner(entity)
  if partner then
    rendering.draw_line({
      surface = entity.surface,
      from = entity,
      to = partner,
      color = PAIR_COLOR,
      width = 3,
      dash_length = 0.25,
      gap_length = 0.25,
      time_to_live = 120,
      players = { player_index },
    })
  end
end

-- Like an underground belt exit: placed facing the same way as an unpaired
-- underground behind it (which then faces us), turn round to face it.
local function auto_flip(entity)
  if tanks.partner(entity) then
    return
  end
  local behind = nearest_on_line(entity, opposite(entity.direction))
  if behind and behind.direction == entity.direction and not tanks.partner(behind) then
    entity.direction = opposite(entity.direction)
  end
end

function tanks.on_underground_built(entity, player_index)
  -- Only a hand placement auto-flips: blueprint/robot/script layouts already
  -- say exactly which way each one faces.
  if player_index then
    auto_flip(entity)
  end
  show_pair(entity, player_index)
end

-- R flips which way it faces across the track, as for the stations'
-- undergrounds (scripts/underground.lua): a quarter turn would move it
-- onto the other row axis, out of its row. Not when a blueprint pasted
-- over it turned it (2.1 raises this event then), the blueprint wins.
function tanks.on_underground_rotated(entity, previous_direction, player_index)
  local player = player_index and game.get_player(player_index)
  local pasting = player ~= nil and player.is_cursor_blueprint()
  if (previous_direction % 8 == 0) ~= (entity.direction % 8 == 0) and not pasting then
    entity.direction = opposite(previous_direction)
  end
  show_pair(entity, player_index)
end

return tanks
