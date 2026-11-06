-- Linking: a group is the connected component of stations joined through
-- balancers, sharing ONE linked inventory identified by the link_id every
-- member carries. The world is the only state -- connectivity is walked
-- live (scripts/geometry.lua) and ids live on the entities -- so nothing
-- can drift out of sync and there is no storage to migrate.
--
-- The group's inventory is the prototype's fixed size: members add access
-- points, not space, so joining or leaving a group never strands items.
-- Only two things ever move items: two non-empty groups merging into one
-- (the loser's inventory is poured into the survivor's, spilling what does
-- not fit), and a group splitting (the piece that keeps the old id keeps
-- the items; every other piece starts empty -- a linked inventory has no
-- location, so "where items live" is the keeper piece, by choice).
local constants = require("scripts.constants")
local geometry = require("scripts.geometry")
local compat = require("scripts.compat")

local groups = {}

local function fresh_link_id()
  local id = storage.next_link_id
  storage.next_link_id = id + 1
  return id
end

local function count(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end

-- The stacks of `inventory` as a list. Slot iteration, not get_contents():
-- on a linked container's inventory get_contents() reads empty even with
-- items in the slots (measured headless, 2.1.24), while slot access works.
local function stacks_of(inventory)
  local list = {}
  for i = 1, #inventory do
    local stack = inventory[i]
    if stack.valid_for_read then
      list[#list + 1] = stack
    end
  end
  return list
end

-- Gives every station in `list` (an array of one family) `target` as their
-- shared link id. A link_id is per prototype, so stations of different
-- families can never share one; the callers group by family first.
-- Inventories of other ids in the list move into the target's, except those
-- in `kept_elsewhere` (ids another piece keeps: a split, where the
-- inventory stays with its keeper). `moved` collects whether anything was.
local function unify_onto(list, target, kept_elsewhere)
  if not next(list) then
    return
  end
  local survivor
  local seen = {}
  for _, s in ipairs(list) do
    local id = s.link_id
    if s.valid and id ~= 0 and id ~= target and not seen[id] and not kept_elsewhere[id] then
      seen[id] = true
      local inv = s.get_inventory(defines.inventory.linked_container_main)
      if not inv.is_empty() then
        if not survivor then
          for _, t in ipairs(list) do
            if t.link_id == target then
              survivor = t
              break
            end
          end
        end
        if survivor then
          compat.transfer(inv, survivor.get_inventory(defines.inventory.linked_container_main))
        end
        for _, stack in ipairs(stacks_of(inv)) do
          s.surface.spill_item_stack({ position = s.position, stack = stack })
        end
        inv.clear()
      end
    end
  end
  for _, s in ipairs(list) do
    if s.valid then
      s.link_id = target
    end
  end
end

-- Stations of `stations` ({unit_number = LuaEntity}) grouped into arrays by
-- family: a component that touches several families (a balancer sitting in
-- a corner, say) never shares one id -- a link_id is per prototype, so it
-- could not anyway. Each family unifies on its own most common non-zero id,
-- or a fresh one.
local function unify(stations, kept_elsewhere)
  local by_family = {}
  for _, s in pairs(stations) do
    local info = constants.STATION_INFO[s.name]
    if info then
      by_family[info.family] = by_family[info.family] or {}
      table.insert(by_family[info.family], s)
    end
  end
  for _, list in pairs(by_family) do
    local counts, best, best_n = {}, nil, 0
    for _, s in ipairs(list) do
      local id = s.link_id
      if id ~= 0 and not kept_elsewhere[id] then
        counts[id] = (counts[id] or 0) + 1
        if counts[id] > best_n then
          best, best_n = id, counts[id]
        end
      end
    end
    unify_onto(list, best or fresh_link_id(), kept_elsewhere)
  end
end

function groups.on_station_built(entity)
  unify(geometry.reachable_stations(entity.surface, entity), {})
end

function groups.on_balancer_built(entity)
  unify(geometry.reachable_stations(entity.surface, entity), {})
end

local relink -- forward declaration: groups.on_underground_changed below

-- Build, rotation or flip of an underground balancer: unlike any other
-- build, this can CUT connections as well as make them, so first re-check
-- the pieces that no longer hold together, then merge whatever is
-- connected now.
function groups.on_underground_changed(entity)
  local surface = entity.surface
  relink(geometry.pieces_around(surface, entity, entity.unit_number))
  unify(geometry.reachable_stations(surface, entity), {})
end

-- Split/merge bookkeeping after a removal or a cut: for each link id held
-- by more than one piece, only the largest piece keeps it (and the items);
-- the others get one fresh id per piece and start empty. Within a piece,
-- stations that ended up with several ids (an underground's removal can
-- connect groups that were never connected before) are merged into one.
relink = function(pieces)
  if #pieces == 0 then
    return
  end
  -- largest piece per link id keeps it
  local keeper = {}
  for i, piece in ipairs(pieces) do
    local n = count(piece)
    local seen = {}
    for _, s in pairs(piece) do
      local id = s.link_id
      if id ~= 0 and not seen[id] then
        seen[id] = true
        if not keeper[id] or n > count(pieces[keeper[id]]) then
          keeper[id] = i
        end
      end
    end
  end
  -- ids kept by another piece: their inventories stay with the keeper
  local kept_elsewhere = {}
  for id, i in pairs(keeper) do
    for j, piece in ipairs(pieces) do
      if j ~= i then
        for _, s in pairs(piece) do
          if s.link_id == id then
            kept_elsewhere[id] = true
            break
          end
        end
        if kept_elsewhere[id] then
          break
        end
      end
    end
  end
  for i, piece in ipairs(pieces) do
    -- one id per family: one this piece keeps, else one that exists only
    -- here (a merge), else a fresh one (a split-off piece)
    local by_family = {}
    for _, s in pairs(piece) do
      local info = constants.STATION_INFO[s.name]
      if info then
        by_family[info.family] = by_family[info.family] or {}
        table.insert(by_family[info.family], s)
      end
    end
    for _, list in pairs(by_family) do
      local target
      local seen = {}
      for _, s in ipairs(list) do
        local id = s.link_id
        if id ~= 0 and not seen[id] then
          seen[id] = true
          if keeper[id] == i or not keeper[id] then
            target = id
            break
          end
        end
      end
      unify_onto(list, target or fresh_link_id(), kept_elsewhere)
    end
  end
end

-- Call for any station or balancer that is being removed, BEFORE it becomes
-- invalid (on_player_mined_entity / on_robot_mined_entity / on_entity_died
-- all fire while `entity` is still valid). Station inventories are left to
-- scripts/dismantle.lua, which owns the last-of-group case.
function groups.on_entity_removed(entity)
  relink(geometry.pieces_around(entity.surface, entity, entity.unit_number))
end

return groups
