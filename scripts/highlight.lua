-- Mouseover highlight: hovering a station outlines every station sharing its
-- inventory, like the pipe visualiser does for fluid systems, and hovering a
-- fluid station every fluid station sharing its fluid segment. Drawn only for
-- the hovering player and cleared when the selection changes.
local constants = require("scripts.constants")
local compat = require("scripts.compat")
local geometry = require("scripts.geometry")

local highlight = {}

local COLOR = { r = 0.3, g = 0.8, b = 1.0, a = 0.8 }

function highlight.clear(player_index)
  local objects = storage.highlights[player_index]
  if objects then
    for _, object in ipairs(objects) do
      if object.valid then
        object.destroy()
      end
    end
    storage.highlights[player_index] = nil
  end
  storage.highlight_keys[player_index] = nil
end

-- Every fluid station in `tank`'s fluid segment, found in the segment's
-- extent (pipes and other tanks in it aren't outlined).
local function segment_tanks(tank)
  local id = compat.fluid_segment_id(tank)
  if not id then
    return { tank }, nil
  end
  local found = {}
  for _, entity in ipairs(tank.surface.find_entities_filtered({ area = compat.fluid_segment_box(tank), type = "storage-tank" })) do
    if constants.TANK_INFO[entity.name] and compat.fluid_segment_id(entity) == id then
      found[#found + 1] = entity
    end
  end
  return found, id
end

-- What to outline for `selected` (a list of entities) and a key that
-- changes whenever that set gains or loses members, or nil: a lone station
-- or tank has nothing to point out.
local function hovered_group(selected)
  if not (selected and selected.valid) then
    return nil
  end
  if constants.TANK_INFO[selected.name] then
    local tanks, id = segment_tanks(selected)
    if #tanks < 2 then
      return nil
    end
    return tanks, "tank/" .. id .. "/" .. #tanks
  end
  if not constants.STATION_INFO[selected.name] then
    return nil
  end
  -- members of the group: the stations reachable from this one, all sharing
  -- its link_id (walked live -- the world is the only state)
  local members = {}
  for _, station in pairs(geometry.reachable_stations(selected.surface, selected)) do
    members[#members + 1] = station
  end
  if #members < 2 then
    return nil
  end
  return members, selected.link_id .. "/" .. #members
end

local function draw(player)
  highlight.clear(player.index)
  local members, key = hovered_group(player.selected)
  if not members then
    return
  end
  local objects = {}
  for _, station in ipairs(members) do
    if station.valid then
      local box = station.selection_box
      objects[#objects + 1] = rendering.draw_rectangle({
        surface = station.surface,
        left_top = box.left_top,
        right_bottom = box.right_bottom,
        color = COLOR,
        width = 3,
        players = { player },
      })
    end
  end
  storage.highlights[player.index] = objects
  storage.highlight_keys[player.index] = key
end

function highlight.on_selected_entity_changed(event)
  local player = game.get_player(event.player_index)
  if player then
    draw(player)
  end
end

-- Catches a group merging or splitting under the cursor, which changes no
-- selection. (For a tank this looks its segment up again: a find in the
-- segment's extent every 30 ticks while one is hovered.)
function highlight.refresh_all()
  for _, player in pairs(game.connected_players) do
    local _, key = hovered_group(player.selected)
    if key ~= storage.highlight_keys[player.index] then
      draw(player)
    end
  end
end

return highlight
