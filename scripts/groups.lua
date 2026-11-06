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
local wires = require("scripts.wires")
local spill = require("scripts.spill")

local groups = {}

local function fresh_link_id()
  local id = storage.next_link_id
  storage.next_link_id = id + 1
  return id
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

local resize -- forward declaration: unify_onto calls it at the end
local relink -- forward declaration: unify_onto's stale-split repair and
-- groups.on_underground_changed below both call it

-- Capacity growth: a group's inventory is its prototype's fixed size, so
-- the members are swapped onto the size band's prototype whenever the
-- group's band changes (powers of two, scripts/constants.lua - rare,
-- unlike the old mod's exact sizes replaced on every change). The link id
-- carries over: ids are unique per group, so no other group holds it on any
-- prototype. Items pour from the old band's inventory into the new one:
-- growing always fits, shrinking (a member left) spills the overflow around
-- the members. Wires, quality, health, last user and a pending
-- deconstruction order carry over; create_entity with a player keeps the
-- replacement in the builder's undo queue.
resize = function(list)
  if not next(list) then
    return
  end
  local first = list[1]
  if not first.valid then
    return
  end
  local info = constants.STATION_INFO[first.name]
  if not info then
    return
  end
  local band = constants.band_for(info.tier, #list)
  local target = constants.station_name(info.family, band)
  -- Only skip when EVERY member already sits on the band prototype. The
  -- list's order is hash order, so checking only its first member used to
  -- leave freshly built members (which arrive on the band-1 prototype) on
  -- their own private inventory whenever another member happened to sort
  -- first - and since link ids are per prototype, such a member does not
  -- even share the group's inventory: items inserted through it sat in
  -- slots the next real swap destroyed, silently.
  local needs_swap = false
  for _, s in ipairs(list) do
    if s.valid and s.name ~= target then
      needs_swap = true
      break
    end
  end
  if not needs_swap then
    return
  end
  -- Collect EVERY member's inventory through a script inventory before any
  -- swap. Members on one prototype share that inventory, so each distinct
  -- one is drained exactly once; a member stuck on another prototype
  -- contributes its private slots as well, so nothing inserted through it
  -- is lost. Temp holds plain stacks, so a with_custom_stack_size
  -- inventory needs stack_multiplier times its slot count: size temp to the
  -- largest member inventory.
  local fallback_surface = first.surface
  local fallback_position = first.position
  local max_slots = 0
  for _, s in ipairs(list) do
    if s.valid then
      local inv = s.get_inventory(defines.inventory.linked_container_main)
      if #inv > max_slots then
        max_slots = #inv
      end
    end
  end
  local temp = game.create_inventory(math.min(max_slots * (info.tier.stack_multiplier or 1), 65535))
  for _, s in ipairs(list) do
    if s.valid then
      local inv = s.get_inventory(defines.inventory.linked_container_main)
      compat.transfer(inv, temp)
      spill.inventory(s.surface, s.position, inv)
      inv.clear()
    end
  end

  local created = {}
  for _, s in ipairs(list) do
    if s.valid and s.name ~= target then
      local surface, position, force = s.surface, s.position, s.force
      local health, quality, last_user = s.health, s.quality, s.last_user
      local link_id = s.link_id
      local deconstruct = s.to_be_deconstructed()
      local saved_wires = wires.save(s)
      s.destroy()
      local new = surface.create_entity({
        name = target,
        position = position,
        force = force,
        quality = quality,
        create_build_effect_smoke = false,
        player = last_user,
      })
      if new then
        new.health = health
        if last_user then
          new.last_user = last_user
        end
        new.link_id = link_id
        wires.restore(new, saved_wires)
        if deconstruct then
          new.order_deconstruction(force)
        end
        created[#created + 1] = new
      end
    end
  end

  if created[1] then
    local t = created[1].get_inventory(defines.inventory.linked_container_main)
    local spill_at = 1
    local spill_n = 0
    for _, stack in ipairs(stacks_of(temp)) do
      local inserted = t.insert(stack)
      stack.count = stack.count - inserted
      if stack.count > 0 then
        spill_n = spill_n + 1
        spill.stack(created[spill_at].surface, created[spill_at].position, stack, spill_n)
        spill_at = (spill_at % #created) + 1
      end
    end
  else
    -- nothing was recreated: spill everything where the group stood rather
    -- than destroying it in temp
    spill.inventory(fallback_surface, fallback_position, temp)
  end
  temp.destroy()
end

local function count(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end

-- Spills what a transfer could not place around `station`, without losing
-- it (see scripts/spill.lua).
local function spill_leftovers(station, inv)
  for _, stack in ipairs(stacks_of(inv)) do
    spill.stack(station.surface, station.position, stack)
  end
end

-- Gives every station in `list` (an array of one family) `target` as their
-- shared link id. A link_id is per prototype, so stations of different
-- families can never share one; the callers group by family first.
-- Inventories of other ids in the list move into the target's, except those
-- in `kept_elsewhere` (ids another piece keeps: a split, where the
-- inventory stays with its keeper). `moved` collects whether anything was.
-- `skip_stale_check` is set by relink, which has just built the pieces and
-- must not re-detect the split it is resolving.
local function unify_onto(list, target, kept_elsewhere, skip_stale_check)
  if not next(list) then
    return
  end
  local survivor
  local survivor_inventory
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
              survivor_inventory = t.get_inventory(defines.inventory.linked_container_main)
              break
            end
          end
        end
        if survivor then
          compat.transfer(inv, survivor_inventory)
        end
        spill_leftovers(s, inv)
        inv.clear()
      end
    end
  end
  for _, s in ipairs(list) do
    if s.valid and s.link_id ~= target then
      -- An unlinked (id 0) station that holds its own items - a fast-replace
      -- the engine moved contents into, or a station whose build event was
      -- missed - loses them if the link id is simply assigned over them
      -- (measured headless: assigning destroys, it does not merge). Merge
      -- them into the group's inventory first. With no holder of the target
      -- id yet, stash them through a script inventory: this station becomes
      -- the target's first holder and the stash pours straight back in.
      if s.link_id == 0 then
        local inv = s.get_inventory(defines.inventory.linked_container_main)
        if not inv.is_empty() then
          local sinfo = constants.STATION_INFO[s.name]
          local multiplier = sinfo and sinfo.tier.stack_multiplier or 1
          if survivor then
            compat.transfer(inv, survivor_inventory)
            spill_leftovers(s, inv)
            inv.clear()
          else
            local temp = game.create_inventory(math.min(#inv * multiplier, 65535))
            compat.transfer(inv, temp)
            inv.clear()
            s.link_id = target
            survivor = s
            survivor_inventory = s.get_inventory(defines.inventory.linked_container_main)
            compat.transfer(temp, survivor_inventory)
            spill_leftovers(s, temp)
            temp.destroy()
          end
        end
      end
      s.link_id = target
    end
  end
  -- A link id whose holders reach beyond this component means the group was
  -- split by a removal the mod never saw (an undo, a plain script destroy:
  -- neither raises an event, so no relink ran) and both pieces still share
  -- the id - and therefore the inventory. Resizing this component alone
  -- would pour the whole shared inventory into the smaller band: the items
  -- teleport out of the other piece and the overflow spills. Split
  -- semantics instead: walk the outside pieces and hand the whole tangle to
  -- relink, which keeps the id and its items with the largest piece.
  if not skip_stale_check and target ~= 0 and list[1].valid then
    local ours = {}
    local names = {}
    for _, s in ipairs(list) do
      if s.valid then
        ours[s.unit_number] = true
        names[s.name] = true
      end
    end
    local outside = {}
    for name in pairs(names) do
      for _, s in ipairs(list[1].surface.find_entities_filtered({ name = name })) do
        if s.valid and s.link_id == target and not ours[s.unit_number] then
          outside[#outside + 1] = s
        end
      end
    end
    if outside[1] then
      local piece = {}
      for _, s in ipairs(list) do
        if s.valid then
          piece[s.unit_number] = s
        end
      end
      local pieces = { piece }
      local covered = {}
      for u in pairs(ours) do
        covered[u] = true
      end
      for _, h in ipairs(outside) do
        if not covered[h.unit_number] then
          local stations, visited = geometry.reachable_stations(h.surface, h)
          for u in pairs(visited) do
            covered[u] = true
          end
          if next(stations) then
            pieces[#pieces + 1] = stations
          end
        end
      end
      relink(pieces)
      return
    end
  end
  resize(list)
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
-- Ties are broken by the pieces' anchor positions (lowest y, then x), not
-- by table order: the pieces come out of pairs() iteration, whose order is
-- arbitrary, so a hash-order tie-break made the keeper depend on build
-- order. Positions come from the map and are identical on every client.
local function anchor_before(a, b)
  if a.y ~= b.y then
    return a.y < b.y
  end
  return a.x < b.x
end

local function piece_anchor(piece)
  local best
  for _, s in pairs(piece) do
    if not best or anchor_before(s.position, best) then
      best = s.position
    end
  end
  return best
end

relink = function(pieces)
  if #pieces == 0 then
    return
  end
  -- largest piece per link id keeps it
  local keeper, keeper_n, keeper_key = {}, {}, {}
  for i, piece in ipairs(pieces) do
    local n = count(piece)
    local key = piece_anchor(piece)
    local seen = {}
    for _, s in pairs(piece) do
      local id = s.link_id
      if id ~= 0 and not seen[id] then
        seen[id] = true
        if
          not keeper[id]
          or n > keeper_n[id]
          or (n == keeper_n[id] and anchor_before(key, keeper_key[id]))
        then
          keeper[id] = i
          keeper_n[id] = n
          keeper_key[id] = key
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
      unify_onto(list, target or fresh_link_id(), kept_elsewhere, true)
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
