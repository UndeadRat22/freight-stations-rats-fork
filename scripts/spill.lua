-- Spilling items to the ground without losing them. The engine's
-- spill_item_stack drops one-item piles and destroys what it cannot place:
-- around a single point roughly the first hundred piles land, past that
-- hundreds vanish (measured headless, 2.1.24 -- lab EDGE 17: 2000 piles at
-- one point lose 21%, the same piles spread on a 2-tile grid lose none).
-- So: spread the piles out over a deterministic grid of base positions,
-- count what actually landed (the call returns the created item entities),
-- and retry what did not, farther out, before logging a visible remainder.
local spill = {}

-- Offsets on a 2-tile grid out to radius 12, closest first: one spill call
-- lands its one-item piles around its own offset, and past roughly a
-- hundred piles a point starts losing them (lab EDGE 17), so large
-- overflows need many points -- 625 here -- and volumes beyond that walk
-- whole shifted passes over the grid (see spill.stack). Deterministic --
-- no randomness -- so spills land the same way on every client and run.
local SPREAD = {}
do
  local seen = {}
  for radius = 0, 12 do
    for dy = -radius, radius do
      for dx = -radius, radius do
        -- only each ring's edge, so the list stays small and distance-ordered
        if math.max(math.abs(dx), math.abs(dy)) == radius then
          local key = dx .. "," .. dy
          if not seen[key] then
            seen[key] = true
            SPREAD[#SPREAD + 1] = { dx * 2, dy * 2 }
          end
        end
      end
    end
  end
  table.sort(SPREAD, function(a, b)
    local da = math.abs(a[1]) + math.abs(a[2])
    local db = math.abs(b[1]) + math.abs(b[2])
    if da ~= db then
      return da < db
    end
    if a[2] ~= b[2] then
      return a[2] < b[2]
    end
    return a[1] < b[1]
  end)
end

local function landed_count(created)
  local landed = 0
  for _, entity in ipairs(created or {}) do
    if entity.valid then
      landed = landed + entity.stack.count
    end
  end
  return landed
end

local function do_spill(surface, position, name, count, quality)
  local created = surface.spill_item_stack({
    position = position,
    stack = { name = name, count = count, quality = quality },
  })
  return landed_count(created), count - landed_count(created)
end

-- Spills one stack near `position`. `index` (optional) spreads consecutive
-- calls over the offset grid, so a large overflow never piles up around one
-- point; without it, the exact position is used. Whatever the engine could
-- not place is retried outward, and a final remainder is logged so a loss
-- is at least visible.
function spill.stack(surface, position, stack, index)
  if not (stack and stack.valid_for_read and stack.count > 0) then
    return
  end
  local base = position
  if index then
    -- consecutive calls walk the grid; once it is used up, the next pass
    -- shifts by a wider stride so no point accumulates several calls' worth
    -- of piles (the per-point loss regime)
    local slot = (index - 1) % #SPREAD
    local pass = math.floor((index - 1) / #SPREAD)
    local offset = SPREAD[slot + 1]
    if pass > 0 then
      local stride = SPREAD[((pass - 1) % #SPREAD) + 1]
      offset = { offset[1] + stride[1] * 5, offset[2] + stride[2] * 5 }
    end
    base = { x = position.x + offset[1], y = position.y + offset[2] }
  end
  local landed, left = do_spill(surface, base, stack.name, stack.count, stack.quality)
  local ring = 0
  while left > 0 and ring < #SPREAD do
    ring = ring + 1
    local spot = { x = base.x + SPREAD[ring][1], y = base.y + SPREAD[ring][2] }
    local placed, remaining = do_spill(surface, spot, stack.name, left, stack.quality)
    landed = landed + placed
    left = remaining
    if placed == 0 then
      break
    end
  end
  if left > 0 then
    log(string.format("freight-stations: %d of %d x %s could not be spilled near (%g,%g)",
      left, stack.count, stack.name, position.x, position.y))
  end
end

-- Spills the stacks of `inventory` around `position`, spread over the grid.
-- Used for group overflows: band-shrink spill, merge overflow, and the
-- dismantle fallbacks.
function spill.inventory(surface, position, inventory)
  local index = 0
  for i = 1, #inventory do
    local stack = inventory[i]
    if stack.valid_for_read then
      index = index + 1
      spill.stack(surface, position, stack, index)
    end
  end
end

return spill
