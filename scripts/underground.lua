-- Player-facing behaviour of underground balancers. The pairing rule lives
-- in scripts/geometry.lua, the linking in scripts/groups.lua; this module
-- only decides which way an underground faces and shows the player what it
-- paired with.
local geometry = require("scripts.geometry")
local groups = require("scripts.groups")

local underground = {}

local PAIR_COLOR = { r = 0.3, g = 1, b = 0.4, a = 0.8 }

local function show_pair(entity, player_index)
  if not (player_index and game.get_player(player_index)) then
    return
  end
  local partner = geometry.partner(entity.surface, entity)
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
-- underground behind it (i.e. that one already faces us), turn round to
-- face it. Saves the player from having to pre-rotate the second of a pair.
local function auto_flip(entity)
  local surface = entity.surface
  if geometry.partner(surface, entity) then
    return
  end
  local behind = geometry.nearest_on_line(surface, entity, geometry.opposite(entity.direction))
  -- nothing of this tier sits between us, so `behind` facing our way means
  -- it is looking straight at us and is unpaired
  if behind and behind.direction == entity.direction then
    entity.direction = geometry.opposite(entity.direction)
  end
end

function underground.on_built(entity, player_index)
  -- Only a hand placement auto-flips: blueprint/robot/script layouts already
  -- say exactly which way each one faces.
  if player_index then
    auto_flip(entity)
  end
  groups.on_underground_changed(entity)
  show_pair(entity, player_index)
end

-- R on a placed underground flips which way it faces across the track,
-- same as underground belts. A quarter turn would move it onto the other
-- row axis and silently disconnect it from the stations either side, so it
-- is turned into a half turn instead.
--
-- Not when the rotation came from pasting a blueprint over it: then the
-- blueprint's direction is deliberate and must win (2.1 raises this event
-- for those, forums.factorio.com/131355).
function underground.on_rotated(entity, previous_direction, player_index)
  local player = player_index and game.get_player(player_index)
  local pasting = player ~= nil and player.is_cursor_blueprint()
  local f_old = previous_direction % 8 == 0 -- north/south
  local f_new = entity.direction % 8 == 0
  if f_old ~= f_new and not pasting then
    entity.direction = geometry.opposite(previous_direction)
  end
  groups.on_underground_changed(entity)
  show_pair(entity, player_index)
end

-- A flip can only reverse the facing (or leave it alone), never change the
-- row axis, so there's nothing to correct -- just re-pair.
function underground.on_flipped(entity, player_index)
  groups.on_underground_changed(entity)
  show_pair(entity, player_index)
end

return underground
