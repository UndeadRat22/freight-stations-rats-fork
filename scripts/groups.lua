-- Group lifecycle: a group is the connected component of stations joined
-- through balancers. Stations in one group share a link_id and therefore one
-- physical inventory; scripts/geometry.lua discovers connectivity live,
-- this module owns the storage bookkeeping and the actual merge/split math.
local constants = require("scripts.constants")
local geometry = require("scripts.geometry")
local compat = require("scripts.compat")
local wires = require("scripts.wires")

local groups = {}

local function count_keys(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end

local function get_group_inventory(group)
  for _, station in pairs(group.stations) do
    if station.valid then
      return station.get_inventory(defines.inventory.linked_container_main)
    end
  end
  return nil
end

local function spill_inventory(surface, position, inventory)
  for _, stack in ipairs(inventory.get_contents()) do
    surface.spill_item_stack({ position = position, stack = stack })
  end
  inventory.clear()
end

-- Moves all of `stack` into `inventory` (nil: nowhere), spilling whatever
-- doesn't fit at `position`. Inserting the stack itself keeps its quality,
-- spoilage and health.
local function move_stack(stack, inventory, surface, position)
  if inventory then
    local inserted = inventory.insert(stack)
    if inserted >= stack.count then
      stack.clear()
      return
    end
    stack.count = stack.count - inserted
  end
  surface.spill_item_stack({ position = position, stack = stack })
  stack.clear()
end

-- Drops invalid members from `group` (and their bookkeeping) and recounts.
local function prune(group)
  local stations, count = {}, 0
  for unit_number, station in pairs(group.stations) do
    if station.valid then
      stations[unit_number] = station
      count = count + 1
    else
      storage.station_group[unit_number] = nil
    end
  end
  group.stations, group.count = stations, count
end


-- Destroys `station` and builds `name` in its place, keeping everything a
-- player could notice: health, quality, last user, circuit wires, a pending deconstruction
-- order (robots clearing a row would otherwise skip the rest of a group the
-- moment the first station goes), and an open inventory window. Raises no
-- events; the caller owns the bookkeeping. The inventory is NOT carried
-- over (a linked one belongs to the old prototype); see resize. Also swaps
-- a station and its dismantling stand-in (scripts/dismantle.lua), which
-- passes no `link_id`. `stock`, if given, is called with the new entity
-- before it is marked, to fill it.
--
-- Returns nil when the new entity is already gone: marking raises
-- on_marked_for_deconstruction at once, and instant deconstruction (the map
-- editor, or another mod) removes it right there, with what `stock` put in.
local function replace_station(station, name, link_id, stock)
  local surface, position, force = station.surface, station.position, station.force
  local health, quality, last_user = station.health, station.quality, station.last_user
  local deconstruct = station.to_be_deconstructed()
  local saved_wires = wires.save(station)
  local viewers = {}
  for _, player in pairs(game.connected_players) do
    if player.opened == station then
      viewers[#viewers + 1] = player
    end
  end

  station.destroy()
  local new = surface.create_entity({
    name = name,
    position = position,
    force = force,
    quality = quality,
    create_build_effect_smoke = false,
    -- keeps the replacement in the builder's undo queue: create_entity with
    -- a player adds a built-entity undo action for them (confirmed against
    -- 2.0.7x, forums.factorio.com/t=132714), and the destroy above made the
    -- engine drop the steps that referenced the old entity. Without this,
    -- every resize/merge severed the undo record, so cmd+z undid the
    -- balancers and ghosts around a row but never its stations
    player = last_user,
  })
  if not new then
    -- creation raced against something else taking the spot (another mod's
    -- build in the same tick): nothing to replace with. The caller's
    -- bookkeeping treats nil as "member gone".
    return nil
  end
  if link_id then
    new.link_id = link_id
  end
  new.health = health
  if last_user then
    new.last_user = last_user
  end
  if stock then
    stock(new)
  end
  if deconstruct then
    new.order_deconstruction(force)
    if not new.valid then
      return nil
    end
  end
  script.register_on_object_destroyed(new)
  wires.restore(new, saved_wires)
  for _, player in ipairs(viewers) do
    player.opened = new
  end
  return new
end

groups.replace_station = replace_station

-- Makes every member of `group` the prototype sized for its station count
-- (capped at the tier's max_group), linked to `link_id`, so the inventory
-- window shows exactly the group's capacity. Every inventory a member was
-- using before is emptied into the resized one; anything that doesn't fit
-- (only possible past max_group) is spilled. `fresh` skips that collection,
-- for a new group whose members still point at an inventory the caller is
-- about to divide up itself.
local function resize(group, link_id, fresh)
  local rep
  for _, s in pairs(group.stations) do
    if s.valid then
      rep = s
      break
    end
  end
  if not rep then
    return
  end
  local info = constants.STATION_INFO[rep.name]
  local target = constants.station_name(info.family, math.min(group.count, info.tier.max_group))
  local surface, position = rep.surface, rep.position

  -- Inventories to collect: one per distinct (prototype, link_id) in use,
  -- since that pair is what identifies a linked inventory.
  local sources = {}
  local temp_size = 0
  if not fresh then
    local seen = {}
    for _, s in pairs(group.stations) do
      if s.valid and not (s.name == target and s.link_id == link_id) then
        local key = s.name .. "/" .. s.link_id
        if not seen[key] then
          seen[key] = true
          local inventory = s.get_inventory(defines.inventory.linked_container_main)
          if not inventory.is_empty() then
            sources[#sources + 1] = inventory
            temp_size = temp_size + #inventory * (info.tier.stack_multiplier or 1)
          end
        end
      end
    end
  end

  -- Through a script inventory because the old inventories become
  -- unreachable once their last member is replaced. Normal stack sizes, so
  -- it needs stack_multiplier times the slots to hold a steel inventory.
  local temp
  if #sources > 0 then
    temp = game.create_inventory(math.min(temp_size, 65535))
    for _, inventory in ipairs(sources) do
      compat.transfer(inventory, temp)
      spill_inventory(surface, position, inventory)
    end
  end

  local stations, count = {}, 0
  for unit_number, s in pairs(group.stations) do
    if s.valid then
      if s.name ~= target then
        storage.station_group[unit_number] = nil
        -- nil: a marked member removed at once by instant deconstruction
        s = replace_station(s, target, link_id)
      elseif s.link_id ~= link_id then
        s.link_id = link_id
      end
      if s then
        stations[s.unit_number] = s
        storage.station_group[s.unit_number] = link_id
        count = count + 1
      end
    end
  end
  group.stations, group.count = stations, count

  if temp then
    local _, any = next(stations)
    if any then
      compat.transfer(temp, any.get_inventory(defines.inventory.linked_container_main))
    end
    spill_inventory(surface, position, temp)
    temp.destroy()
  end
end


local function next_link_id()
  local id = storage.next_link_id
  storage.next_link_id = id + 1
  return id
end

-- Creates a brand new group out of `stations` ({unit_number = LuaEntity}),
-- relinking every member to the new id at the right size. Starts empty: the
-- members' current inventory is left alone for the caller to divide up.
local function new_group(stations)
  local link_id = next_link_id()
  local group = { stations = stations, count = count_keys(stations) }
  storage.groups[link_id] = group
  resize(group, link_id, true)
  return link_id, group
end

-- Gives `station` a group of its own again when the bookkeeping has lost
-- track of it (see forget_station), or never had it (built by another mod
-- without a build event). Unlike new_group it keeps whatever the station's
-- inventory still holds, unless that inventory belongs to a group still on
-- record: a station copied without an event keeps its original's link_id,
-- and taking that inventory would empty the original's group.
local function adopt(station)
  local owned_elsewhere = storage.groups[station.link_id] ~= nil
  local link_id = next_link_id()
  local group = { stations = { [station.unit_number] = station }, count = 1 }
  storage.groups[link_id] = group
  resize(group, link_id, owned_elsewhere)
  return link_id
end

-- Merges every group in `group_ids` into the largest of them.
local function merge_groups(group_ids)
  table.sort(group_ids, function(a, b)
    return storage.groups[a].count > storage.groups[b].count
  end)
  local winner_id = group_ids[1]
  local winner = storage.groups[winner_id]

  for i = 2, #group_ids do
    local loser_id = group_ids[i]
    local loser = storage.groups[loser_id]
    for unit_number, station in pairs(loser.stations) do
      winner.stations[unit_number] = station
    end
    winner.count = winner.count + loser.count
    storage.groups[loser_id] = nil
  end

  -- Collects the winner's and every loser's inventory into the new size.
  resize(winner, winner_id)
end

-- Floating red text over `entity`, if given. "flying-text" was removed as an
-- entity type pre-2.0 (confirmed via changelog.txt: "Use
-- LuaPlayer::create_local_flying_text or LuaRendering::draw_text instead");
-- surface.create_entity{name="flying-text"} throws "Unknown entity name" on 2.0.77.
local function warn(entity, key, ...)
  if not entity then
    return
  end
  rendering.draw_text({
    surface = entity.surface,
    target = entity.position,
    text = { "freight-stations-messages." .. key, ... },
    color = { r = 1, g = 0.3, b = 0.3 },
    time_to_live = 180,
    alignment = "center",
  })
end

-- Merges every group among `stations` ({unit_number = LuaEntity}, one
-- connected component). A link_id can only be shared by entities of the SAME
-- prototype name, so stations of different families (axis/tier) touching
-- through this component (e.g. a balancer sitting in a corner) can never
-- actually merge. Refuse rather than record a group that doesn't match what
-- the engine will really link; `feedback_entity`, if given, gets a warning
-- drawn on it. Different sizes of one family are fine: merging resizes them.
local function merge_component(stations, feedback_entity)
  local names = {}
  local distinct_names = 0
  local tier
  for _, station in pairs(stations) do
    local info = constants.STATION_INFO[station.name]
    tier = info.tier
    if not names[info.family] then
      names[info.family] = true
      distinct_names = distinct_names + 1
    end
  end

  if distinct_names == 0 then
    return
  end

  if distinct_names > 1 then
    warn(feedback_entity, "mismatched-connection")
    return
  end

  local touched = {}
  local group_ids = {}
  for unit_number, station in pairs(stations) do
    local link_id = storage.station_group[unit_number]
    local group = link_id and storage.groups[link_id]
    if not (group and group.stations[unit_number]) then
      link_id = adopt(station)
    end
    if not touched[link_id] then
      touched[link_id] = true
      group_ids[#group_ids + 1] = link_id
    end
  end

  if #group_ids > 1 then
    local total = 0
    for _, id in ipairs(group_ids) do
      total = total + storage.groups[id].count
    end
    if total > tier.max_group then
      -- Still merges (groups must match connectivity), but the size is capped
      -- at max_group, so the extra stations add no space and overflow spills.
      warn(feedback_entity, "group-full", tier.max_group)
    end
    merge_groups(group_ids)
  end
end

-- Looks at everything physically reachable from `entity` and merges groups
-- as needed. `exclude_unit_number` is walked around (mid-removal entity);
-- `quiet` suppresses the mismatch warning.
-- The tier check runs first: merging resizes the group, which can replace
-- `entity` with a new station and leave it invalid.
local function try_merge_from(entity, exclude_unit_number, quiet)
  if not quiet and geometry.has_tier_mismatch(entity.surface, entity) then
    warn(entity, "wrong-tier-balancer")
  end
  local reachable = geometry.reachable_stations(entity.surface, entity, exclude_unit_number)
  merge_component(reachable, not quiet and entity or nil)
end

function groups.on_station_built(entity)
  -- new_group can replace `entity` too (built at the wrong size, e.g. cloned).
  local _, group = new_group({ [entity.unit_number] = entity })
  local _, station = next(group.stations)
  if station and station.valid then
    try_merge_from(station)
  end
end

function groups.on_balancer_built(entity)
  try_merge_from(entity)
end

-- Splits one old group into `pieces` ({[i] = {unit_number = LuaEntity}, ...}),
-- after an entity was removed from it. The largest piece keeps the old
-- link_id; every other piece gets a fresh link_id. Every piece ends up
-- resized, which replaces its station entities.
--
-- Items are shared out as whole stacks, by slots: each piece gets slots in
-- proportion to its capacity, so every share fits the inventory it lands
-- in. Dividing every item type by count instead puts each type in every
-- piece, which needs more slots than the pieces have as soon as a group
-- holds many types, and the rest spilled.
--
-- Pieces whose stations are all marked for deconstruction are about to go,
-- so they only take what the other pieces can't hold: robots dismantling
-- part of a row take down a balancer first, and the items would otherwise
-- leave with the cut-off part. If every piece is marked, they share as
-- usual. If `removed_station` is given, it only gets what no piece can hold,
-- into `loot_inventory` (spilled at `fallback_position` if that's nil or too
-- small).
local function split_old_group(surface, old_link_id, pieces, removed_station, loot_inventory, fallback_position)
  local old_group = storage.groups[old_link_id]
  if not old_group then
    return
  end

  table.sort(pieces, function(a, b)
    return count_keys(a) > count_keys(b)
  end)
  local kept_piece = pieces[1] or {}

  -- Read the old inventory through an entity that the new pieces' resizing
  -- won't replace: the station being removed, or else a kept one.
  local source = removed_station
  if not (source and source.valid) then
    source = nil
    for _, s in pairs(kept_piece) do
      if s.valid then
        source = s
        break
      end
    end
  end
  if not source then
    storage.groups[old_link_id] = nil
    return
  end
  local old_inventory = source.get_inventory(defines.inventory.linked_container_main)
  old_inventory.sort_and_merge()
  local used = #old_inventory - old_inventory.count_empty_stacks()
  local tier = constants.STATION_INFO[source.name].tier
  local function capacity(station_count)
    return math.min(station_count, tier.max_group) * tier.slots
  end

  -- One share per piece. The kept piece's stacks just stay where they
  -- are. Marks are read before new_group replaces the stations (the
  -- replacements keep them, see replace_station).
  local shares = {}
  local any_unmarked = false
  for i = 1, math.max(#pieces, 1) do
    local piece = pieces[i] or kept_piece
    local share = { room = capacity(count_keys(piece)), marked = next(piece) ~= nil }
    for _, station in pairs(piece) do
      if station.valid and not station.to_be_deconstructed() then
        share.marked = false
        break
      end
    end
    any_unmarked = any_unmarked or not share.marked
    if i == 1 then
      share.keep = true
    else
      local _, group = new_group(piece)
      local _, rep = next(group.stations)
      share.inventory, share.position = get_group_inventory(group), rep.position
    end
    shares[i] = share
  end

  -- Each share's `target` in slots: pieces that stay fill first, in
  -- proportion to their room, then pieces about to be dismantled, then the
  -- removed station. A target never exceeds the share's room, so it fits.
  local rooms = { 0, 0 }
  for _, share in ipairs(shares) do
    share.order = (any_unmarked and share.marked) and 2 or 1
    rooms[share.order] = rooms[share.order] + share.room
  end
  local left = used
  for order = 1, 2 do
    local amount = math.min(left, rooms[order])
    for _, share in ipairs(shares) do
      if share.order == order then
        share.target = rooms[order] > 0 and amount * share.room / rooms[order] or 0
      end
    end
    left = left - amount
  end
  if removed_station and left > 0 then
    shares[#shares + 1] = { target = left, inventory = loot_inventory, position = fallback_position }
  end
  -- `cap` is the most whole slots a share may take
  for _, share in ipairs(shares) do
    share.cap = math.ceil(share.target - 1e-9)
    share.taken = 0
  end

  -- Hands out stacks in inventory order like seats by Sainte-Lague: each
  -- goes to the share with the highest target / (2 * taken + 1). That keeps
  -- every run of stacks, so every item type with several of them, split in
  -- proportion.
  for i = 1, #old_inventory do
    local stack = old_inventory[i]
    if stack.valid_for_read then
      local best, best_priority
      for _, candidate in ipairs(shares) do
        if candidate.taken < candidate.cap then
          local priority = candidate.target / (2 * candidate.taken + 1)
          if not best or priority > best_priority then
            best, best_priority = candidate, priority
          end
        end
      end
      -- the targets add up to `used`, so this is only a safeguard
      best = best or shares[1]
      best.taken = best.taken + 1
      if not best.keep then
        move_stack(stack, best.inventory, surface, best.position)
      end
    end
  end

  -- What's left in old_inventory is the kept piece's; resizing moves it
  -- into the smaller prototype.
  if next(kept_piece) then
    old_group.stations = kept_piece
    old_group.count = count_keys(kept_piece)
    resize(old_group, old_link_id)
  else
    storage.groups[old_link_id] = nil
  end
end

-- `group`'s valid members, minus `exclude_unit_number` (a unit number or a
-- set, see geometry), as the connected pieces they form in the live world
-- ({[i] = {unit_number = LuaEntity}}), walking around the excluded ones.
local function member_pieces(surface, group, exclude_unit_number)
  local members = {}
  for unit_number, station in pairs(group.stations) do
    if station.valid and not geometry.excluded(exclude_unit_number, unit_number) then
      members[unit_number] = station
    end
  end

  local pieces = {}
  local claimed = {}
  for unit_number, station in pairs(members) do
    if not claimed[unit_number] then
      local reachable = geometry.reachable_stations(surface, station, exclude_unit_number)
      local piece = {}
      for u, s in pairs(reachable) do
        if members[u] then
          piece[u] = s
          claimed[u] = true
        end
      end
      pieces[#pieces + 1] = piece
    end
  end
  return pieces
end

-- Re-derives `link_id`'s connected components from the live world and splits
-- the group if it no longer holds together. For changes that cut a group
-- without removing any of its stations. `exclude_unit_number` is walked
-- around (mid-removal entity).
local function revalidate(surface, link_id, position, exclude_unit_number)
  local group = storage.groups[link_id]
  if not group then
    return
  end

  local pieces = member_pieces(surface, group, exclude_unit_number)
  if #pieces > 1 then
    split_old_group(surface, link_id, pieces, nil, nil, position)
  end
end

-- Brings `link_id` back in line with the world after its bookkeeping missed
-- a change (a member destroyed without any event, say): drops members that
-- are gone, splits what no longer holds together and resizes the rest. The
-- members left keep every item.
local function settle(link_id, exclude_unit_number)
  local group = storage.groups[link_id]
  if not group then
    return
  end
  prune(group)
  local _, any = next(group.stations)
  if not any then
    storage.groups[link_id] = nil
    return
  end
  revalidate(any.surface, link_id, any.position, exclude_unit_number)
  group = storage.groups[link_id]
  if group then
    resize(group, link_id)
  end
end

-- Safety net for a station destroyed without any of the removal events
-- (another mod's destroy(), a deleted surface).
function groups.on_station_vanished(unit_number)
  local link_id = storage.station_group[unit_number]
  if link_id then
    storage.station_group[unit_number] = nil
    settle(link_id)
  end
end

-- Re-derives every group from the world: settles each one, merges whatever
-- is connected but recorded apart, and takes in stations that were never
-- recorded at all. For on_configuration_changed.
function groups.resync_all()
  local ids = {}
  for link_id in pairs(storage.groups) do
    ids[#ids + 1] = link_id
  end
  table.sort(ids)
  for _, link_id in ipairs(ids) do
    settle(link_id)
  end
  for _, link_id in ipairs(ids) do
    local group = storage.groups[link_id]
    local _, any = next(group and group.stations or {})
    if any then
      merge_component(geometry.reachable_stations(any.surface, any), nil)
    end
  end
  -- Stations the bookkeeping never saw (another mod's create_entity without
  -- raise_built, say): they'd all share the inventory of link_id 0. Each is
  -- linked with whatever it touches; merge_component adopts it.
  for _, surface in pairs(game.surfaces) do
    local unrecorded = {}
    for _, station in ipairs(geometry.find_stations(surface, {})) do
      if not storage.station_group[station.unit_number] then
        script.register_on_object_destroyed(station)
        unrecorded[#unrecorded + 1] = station
      end
    end
    for _, station in ipairs(unrecorded) do
      -- merging an earlier one may have replaced and recorded it already
      if station.valid and not storage.station_group[station.unit_number] then
        merge_component(geometry.reachable_stations(surface, station), nil)
        -- refused (it touches another family): a group of its own
        if station.valid and not storage.station_group[station.unit_number] then
          adopt(station)
        end
      end
    end
  end
end

-- Build, rotation or flip of an underground balancer. Unlike any other
-- build, this can CUT connections as well as make them: a new underground
-- blocks the line between a pair it lands between, and turning one breaks
-- its old pairing. So first re-check every group close enough to have been
-- affected, then merge whatever is connected now.
function groups.on_underground_changed(entity)
  local surface = entity.surface
  local p = entity.position
  local tier = constants.UNDERGROUND_TIER[entity.name]

  -- Reaches past the farthest possible old partner (width + MAX_GAP away)
  -- far enough to catch the stations touching it.
  local r = constants.UNDERGROUND_MAX_GAP + 2 * tier.width + 1
  local nearby = geometry.find_stations(surface, { area = { { p.x - r, p.y - r }, { p.x + r, p.y + r } } })
  local candidate_ids = {}
  local seen = {}
  for _, station in ipairs(nearby) do
    local link_id = storage.station_group[station.unit_number]
    if link_id and not seen[link_id] then
      seen[link_id] = true
      candidate_ids[#candidate_ids + 1] = link_id
    end
  end
  for _, link_id in ipairs(candidate_ids) do
    revalidate(surface, link_id, p)
  end

  try_merge_from(entity)
end

-- Connected components left behind when `entity` goes: one BFS per neighbour
-- not already covered by an earlier one (two neighbours can still be
-- connected the long way round, e.g. through two underground pairs).
local function pieces_around(surface, entity, removed)
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

-- Call for any station or balancer that is being removed, BEFORE it becomes
-- invalid (on_player_mined_entity/on_robot_mined_entity/on_entity_died all
-- fire while `entity` is still valid). `loot_inventory` is the engine-
-- provided buffer/loot inventory for a removed station's contents that its
-- group can no longer hold (all of them for a lone station), or nil (e.g.
-- script_raised_destroy) to spill those on the ground.
--
-- Splits by OLD group, then merges by NEW connectivity: removing an
-- underground can let the ones either side of it pair up past it, so a
-- surviving piece may span groups that were never connected before.
function groups.on_entity_removed(entity, loot_inventory)
  local surface = entity.surface
  local position = entity.position
  local is_station = geometry.is_station(entity.name)
  local removed = entity.unit_number

  local pieces = pieces_around(surface, entity, removed)

  -- Each old group's surviving members, partitioned by piece.
  local subpieces_by_link = {}
  local link_order = {}
  for _, piece in ipairs(pieces) do
    local by_link = {}
    for unit_number, station in pairs(piece) do
      local link_id = storage.station_group[unit_number]
      if link_id then
        if not by_link[link_id] then
          by_link[link_id] = {}
          if not subpieces_by_link[link_id] then
            subpieces_by_link[link_id] = {}
            link_order[#link_order + 1] = link_id
          end
          table.insert(subpieces_by_link[link_id], by_link[link_id])
        end
        by_link[link_id][unit_number] = station
      end
    end
  end

  if is_station then
    local old_link_id = storage.station_group[removed]
    storage.station_group[removed] = nil
    if old_link_id then
      local subpieces = subpieces_by_link[old_link_id]
      if subpieces then
        split_old_group(surface, old_link_id, subpieces, entity, loot_inventory, position)
      else
        local group = storage.groups[old_link_id]
        if group then
          group.stations[removed] = nil
          prune(group)
        end
        if group and group.count > 0 then
          -- No surviving neighbour shared this group, yet it has other
          -- members: its bookkeeping missed a change. They keep everything.
          settle(old_link_id, removed)
        else
          -- A lone station. The engine leaves a linked inventory behind
          -- when its entity is mined (confirmed headless, 2.0.77: robot and
          -- character mining both left it in place), so its contents go to
          -- the buffer/loot here, or the ground.
          storage.groups[old_link_id] = nil
          local inventory = entity.get_inventory(defines.inventory.linked_container_main)
          for i = 1, #inventory do
            local stack = inventory[i]
            if stack.valid_for_read then
              move_stack(stack, loot_inventory, surface, position)
            end
          end
        end
      end
      subpieces_by_link[old_link_id] = nil
    end
  end

  for _, link_id in ipairs(link_order) do
    local subpieces = subpieces_by_link[link_id]
    if subpieces and #subpieces > 1 then
      split_old_group(surface, link_id, subpieces, nil, nil, position)
    end
  end

  -- Quiet: any mismatch in here was already reported when it was built.
  -- Re-scanned, because the splits above resized (replaced) stations that
  -- `pieces` still points at.
  for _, piece in ipairs(pieces_around(surface, entity, removed)) do
    merge_component(piece, nil)
  end
  if geometry.is_underground(entity.name) then
    for _, u in ipairs(geometry.line_undergrounds(surface, entity, removed)) do
      try_merge_from(u, removed, true)
    end
  end
end

-- Links `stations` (new size-1 stations with no group yet, such as restored
-- dismantling stand-ins) with whatever they touch. Each connected piece is
-- merged, and so resized, once instead of once per station. Quiet: these
-- were checked when first built.
function groups.on_stations_restored(stations)
  for _, station in ipairs(stations) do
    new_group({ [station.unit_number] = station })
  end
  local covered = {}
  for _, station in ipairs(stations) do
    -- a station merged into an earlier piece was replaced, but is covered
    if station.valid and not covered[station.unit_number] then
      local reachable, visited = geometry.reachable_stations(station.surface, station)
      for unit_number in pairs(visited) do
        covered[unit_number] = true
      end
      merge_component(reachable, nil)
    end
  end
end

-- Takes `stations` (a list of recorded members of group `link_id`) out of
-- it in one go, for stations about to be replaced (scripts/dismantle.lua).
-- Shares out like on_entity_removed, but splits and resizes the group once
-- rather than once per station: one at a time, marking a whole 100-station
-- group cost seconds in a single tick. What the stations that stay can't
-- hold goes into `loot_inventory`. Taking stations away never connects
-- anything, so nothing needs merging afterwards.
function groups.remove_members(link_id, stations, loot_inventory)
  local group = storage.groups[link_id]
  local first = stations[1]
  if not (group and first) then
    return
  end
  local leaving = {}
  for _, station in ipairs(stations) do
    leaving[station.unit_number] = true
    storage.station_group[station.unit_number] = nil
  end
  local pieces = member_pieces(first.surface, group, leaving)
  split_old_group(first.surface, link_id, pieces, first, loot_inventory, first.position)
end

return groups
