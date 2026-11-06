-- Real stations (and wide-tier balancers) can't rotate at all, so a captured
-- blueprint containing them would always paste in whatever orientation they
-- happened to be in -- rotating or flipping the blueprint couldn't change
-- that. The fix: swap each captured one for its rotatable placer entity
-- before the blueprint is finalized. Pasting then goes through the normal
-- placer build path (scripts/placer.lua), which puts the right real entity
-- back. Covers the blueprint tool, copy, and cut: all three raise
-- on_player_setup_blueprint, distinguished only by `event.item`, which this
-- doesn't need to check since the swap is identical for all three.
local constants = require("scripts.constants")

local blueprint = {}

local SWAP = constants.PLACER_OF

-- The blueprint being set up: an item stack (blueprint tool, copy, cut), or a
-- library record when "select new contents" updates a blueprint stored in
-- the blueprint library, where `stack` is nil.
local function target(event)
  local stack = event.stack
  if stack and stack.valid_for_read and stack.is_blueprint then
    return stack
  end
  local record = event.record
  if record and record.valid_for_write and record.type == "blueprint" then
    return record
  end
  return nil
end

function blueprint.on_setup_blueprint(event)
  local stack = target(event)
  if not stack then
    return
  end

  local entities = stack.get_blueprint_entities()
  if not entities then
    return
  end

  local changed = false
  for _, bp_entity in pairs(entities) do
    local swap = SWAP[bp_entity.name]
    if swap then
      if swap.station then
        -- the placer's position is half a tile off the station's
        local offset = constants.placer_offset(swap.direction)
        bp_entity.position = { x = bp_entity.position.x - offset.x, y = bp_entity.position.y - offset.y }
      end
      bp_entity.name = swap.placer
      bp_entity.direction = swap.direction
      changed = true
    end
  end

  if changed then
    -- fix_positions=false: the half-tile placer offsets above change the
    -- blueprint's snapping context, and with the default (true) the engine
    -- then re-snaps every stored position "invalid for the current
    -- snapping" -- observed as every 2x2 rail in the blueprint jumping
    -- one tile down and one right (a nearest-valid-tile nudge) after
    -- "select new contents" on a capture containing rails. Leaving the
    -- captured positions verbatim keeps rails, stops and balancers where
    -- they were; genuinely invalid positions still get corrected.
    stack.set_blueprint_entities(entities, false)
  end
end

return blueprint
