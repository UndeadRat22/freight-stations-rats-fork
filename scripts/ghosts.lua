-- Everything only ever built through a placer (constants.PLACER_OF) names a
-- hidden item as its placeable_by, to stay out of the upgrade planner
-- (constants.placeholder). Robots can't bring that item, so a ghost of
-- one would never be built: each is swapped for a ghost of its placer,
-- which costs the real item and which the placer path turns back into the
-- right entity (scripts/placer.lua). Blueprints already hold placers
-- (scripts/blueprint.lua); ghosts still come from deaths, undo, blueprints
-- made before that swap and saves from before this one.
local constants = require("scripts.constants")
local wires = require("scripts.wires")

local ghosts = {}

local PLACER_OF = constants.PLACER_OF

-- Ghost names to swap, sorted (event filters must not vary between clients).
local NAMES = {}
for name in pairs(PLACER_OF) do
  NAMES[#NAMES + 1] = name
end
table.sort(NAMES)

function ghosts.names()
  return NAMES
end

function ghosts.is_swapped(name)
  return PLACER_OF[name] ~= nil
end

-- Replaces `ghost` with a ghost of its placer, wires included. Returns the
-- new ghost, or nil if it couldn't be made.
function ghosts.to_placer(ghost)
  local swap = PLACER_OF[ghost.ghost_name]
  local surface, position = ghost.surface, ghost.position
  if swap.station then
    -- the placer's position is half a tile off the station's
    local offset = constants.placer_offset(swap.direction)
    position = { x = position.x - offset.x, y = position.y - offset.y }
  end
  local spec = {
    name = "entity-ghost",
    inner_name = swap.placer,
    position = position,
    direction = swap.direction,
    force = ghost.force,
    quality = ghost.quality,
    player = ghost.last_user,
  }
  local saved_wires = wires.save(ghost)
  ghost.destroy()
  local placer_ghost = surface.create_entity(spec)
  if placer_ghost then
    wires.restore(placer_ghost, saved_wires)
  end
  return placer_ghost
end

-- The ghost a station, tank or wide balancer leaves when it dies.
function ghosts.on_post_entity_died(event)
  local ghost = event.ghost
  if ghost and ghost.valid and PLACER_OF[ghost.ghost_name] then
    ghosts.to_placer(ghost)
  end
end

-- Undoing a removal puts a ghost of the removed entity back.
function ghosts.on_undo_applied(event)
  for _, action in ipairs(event.actions) do
    local target = action.type == "removed-entity" and action.target
    local surface = target and PLACER_OF[target.name] and action.surface_index and game.get_surface(action.surface_index)
    if surface then
      for _, ghost in ipairs(surface.find_entities_filtered({ position = target.position, ghost_name = target.name })) do
        ghosts.to_placer(ghost)
      end
    end
  end
end

-- Smart pipette on one of these finds the hidden item: put the real one in
-- the cursor instead, as pipetting its placer would.
function ghosts.on_player_pipette(event)
  local placeholder = event.item and event.item.name
  if not placeholder then
    return
  end
  local item = constants.REAL_ITEM[placeholder]
  if not item then
    return
  end
  local player = game.get_player(event.player_index)
  local stack = player.cursor_stack
  if stack and stack.valid_for_read and stack.name == placeholder then
    stack.clear() -- cheat mode hands out a stack of it
  end
  player.cursor_ghost = nil
  player.pipette(prototypes.item[item], event.quality, true)
end

-- Saves from before 0.12.2 can hold ghosts that named the real item.
function ghosts.migrate()
  for _, surface in pairs(game.surfaces) do
    for _, ghost in ipairs(surface.find_entities_filtered({ type = "entity-ghost" })) do
      if ghost.valid and PLACER_OF[ghost.ghost_name] then
        ghosts.to_placer(ghost)
      end
    end
  end
end

return ghosts
