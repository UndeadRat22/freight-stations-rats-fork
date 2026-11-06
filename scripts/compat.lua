-- 2.0/2.1 compatibility layer. Core mod code must only call into this module
-- for anything that differs between the two targets; it must never branch on
-- version directly.
local compat = {}

local function ver(s)
  local a, b, c = s:match("^(%d+)%.(%d+)%.?(%d*)")
  return tonumber(a) * 1e6 + tonumber(b) * 1e3 + (tonumber(c) or 0)
end

compat.is_2_1 = function(base_version)
  return ver(base_version) >= ver("2.1.0")
end

-- Runtime: script.active_mods lists active mods -> version strings.
function compat.base_version_runtime()
  return script.active_mods["base"]
end

-- Data stage: the global `mods` lists active mods -> version strings.
function compat.base_version_data()
  return mods["base"]
end

-- ContainerPrototype::circuit_connector: one definition on 2.0, a list with
-- one entry per `direction_count` (default 1) on 2.1. LinkedContainer and
-- the placer's assembling machine are unaffected.
function compat.container_circuit_connector(connector)
  if compat.is_2_1(compat.base_version_data()) then
    return { connector }
  end
  return connector
end

-- Hides the connection arrows of a fluidbox in alt mode: one flag on the
-- FluidBox on 2.0, which 2.1 moved onto each PipeConnectionDefinition (an
-- unused property in the wrong place either way).
function compat.hide_connection_info(fluid_box)
  if compat.is_2_1(compat.base_version_data()) then
    for _, connection in ipairs(fluid_box.pipe_connections) do
      connection.hide_connection_info = true
    end
  else
    fluid_box.hide_connection_info = true
  end
  return fluid_box
end

-- Fluid segments: 2.1 removed LuaFluidBox, and its queries moved onto
-- LuaEntity with the fluid storage index (confirmed in the 2.0.77 and
-- 2.1.21 runtime API and a headless probe, FACTORIO_API_NOTES.md §15).
-- The id of the segment `entity`'s first fluidbox belongs to, or nil.
function compat.fluid_segment_id(entity)
  if compat.is_2_1(compat.base_version_runtime()) then
    return entity.get_fluid_segment_id(1)
  end
  return entity.fluidbox.get_fluid_segment_id(1)
end

-- The fluid capacity of that segment.
function compat.fluid_segment_capacity(entity)
  if compat.is_2_1(compat.base_version_runtime()) then
    return entity.get_fluid_segment_capacity(1)
  end
  return entity.fluidbox.get_capacity(1)
end

-- The bounding box of everything in that segment.
function compat.fluid_segment_box(entity)
  if compat.is_2_1(compat.base_version_runtime()) then
    return entity.get_fluid_segment_extent_bounding_box(1)
  end
  return entity.fluidbox.get_fluid_segment_extent_bounding_box(1)
end

-- The entities `entity`'s first fluidbox is connected to.
function compat.fluid_neighbours(entity)
  local found = {}
  if compat.is_2_1(compat.base_version_runtime()) then
    for _, record in ipairs(entity.get_fluid_box_neighbours(1) or {}) do
      found[#found + 1] = record.entity
    end
  else
    for _, fluidbox in ipairs(entity.fluidbox.get_connections(1)) do
      found[#found + 1] = fluidbox.owner
    end
  end
  return found
end

-- Bulk transfer: engine call on 2.1, stack loop on 2.0.
-- LuaItemStack:insert keeps quality/spoilage/health intact.
--
-- Gated on an explicit version check, not `if dst.transfer_from_inventory`:
-- confirmed empirically (headless test, 2026-10-09) that indexing a missing
-- method on a LuaInventory THROWS ("doesn't contain key ...") rather than
-- returning nil, so duck-typing this crashes on 2.0. Resolves the
-- "[verify]" in FACTORIO_API_NOTES.md §8 about missing-member access.
function compat.transfer(src, dst)
  if compat.is_2_1(compat.base_version_runtime()) then
    return dst.transfer_from_inventory(src)
  end
  local moved = 0
  for i = 1, #src do
    local stack = src[i]
    if stack.valid_for_read then
      local n = dst.insert(stack)
      if n > 0 then
        moved = moved + n
        if n >= stack.count then
          stack.clear()
        else
          stack.count = stack.count - n
        end
      end
    end
  end
  return moved
end

return compat
