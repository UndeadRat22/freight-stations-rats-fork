-- Migration from the 0.12.x / 0.13.x line. Its stations were one prototype
-- per group size (family-g1..gN, capacity growing with the member count) and
-- its steel balancer was an h/v pair; both survive loading only because
-- prototypes/legacy.lua keeps their prototypes hidden. This turns them into
-- the new fixed-size stations on the first load:
--   - every old group becomes one new group with one fresh link id, so old
--     ids can never collide with ids the new mod already handed out;
--   - the old inventory is poured into the new group's fixed-size one, and
--     what exceeds the fixed capacity spills around the group's stations
--     (the old model grew with member count, the new one does not);
--   - quality, health and last_user carry over; circuit wires do not
--     (nothing links the two entities, and the engine drops a replaced
--     entity's wires) -- re-wire after migrating.
-- Tank stations, fluid balancers, iron balancers, undergrounds and the
-- dismantling stand-ins kept their prototype names, so they need no pass.
local constants = require("scripts.constants")
local compat = require("scripts.compat")

local migrate = {}

local LINKED = defines.inventory.linked_container_main

-- old balancer prototype name -> direction for the new rotatable one
local LEGACY_BALANCERS = {
  ["stock-balancer-steel-h"] = defines.direction.north,
  ["stock-balancer-steel-v"] = defines.direction.east,
}

-- The new fixed-size prototype an old `family-gN` station becomes, or nil.
local function legacy_base(name)
  local base = name:match("^(.-)-g%d+$")
  if base and constants.STATION_INFO[base] then
    return base
  end
  return nil
end

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

local function fresh_link_id()
  local id = storage.next_link_id
  storage.next_link_id = id + 1
  return id
end

-- One old group ({members = {{entity, base}}}, all sharing an old link id):
-- collect the inventory, swap every member for the new fixed-size prototype
-- carrying one shared fresh id, then pour the items back, spilling the
-- overflow around the members.
local function migrate_group(surface, members)
  local new_id = fresh_link_id()
  local first = members[1]
  local old_inventory = first.entity.get_inventory(LINKED)
  -- through a script inventory: normal stack sizes, so a steel inventory
  -- needs stack_multiplier times the slots to be held whole
  local tier = constants.STATION_INFO[first.base].tier
  local temp = game.create_inventory(math.min(#old_inventory * (tier.stack_multiplier or 1), 65535))
  compat.transfer(old_inventory, temp)
  old_inventory.clear()
  -- the group becomes the size band holding its member count: capacity
  -- rounds up, so the old inventory always fits
  local target = constants.station_name(first.base, constants.band_for(tier, #members))

  local created = {}
  for _, m in ipairs(members) do
    local s = m.entity
    if s.valid then
      local position, force, quality, last_user, health = s.position, s.force, s.quality, s.last_user, s.health
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
        new.link_id = new_id
        created[#created + 1] = new
      end
    end
  end

  if created[1] then
    local target = created[1].get_inventory(LINKED)
    local spill_at = 1
    for _, stack in ipairs(stacks_of(temp)) do
      local inserted = target.insert(stack)
      stack.count = stack.count - inserted
      if stack.count > 0 then
        -- spread the overflow around the group's stations
        surface.spill_item_stack({ position = created[spill_at].position, stack = stack })
        spill_at = (spill_at % #created) + 1
      end
    end
  end
  temp.destroy()
end

-- Ghosts of legacy entities become ghosts of the new ones, so a blueprint or
-- construction queue from an old save keeps working. (Ghosts of the old
-- placer machines cannot be revived by anything and are simply gone.)
local function migrate_ghosts(surface)
  for _, ghost in ipairs(surface.find_entities_filtered({ type = "entity-ghost" })) do
    if ghost.valid then
      local name = ghost.ghost_name
      local base = legacy_base(name)
      if base or LEGACY_BALANCERS[name] then
        local spec = {
          name = "entity-ghost",
          position = ghost.position,
          force = ghost.force,
          quality = ghost.quality,
          player = ghost.last_user,
        }
        if base then
          spec.inner_name = base
        else
          spec.inner_name = "stock-balancer-steel"
          spec.direction = LEGACY_BALANCERS[name]
        end
        ghost.destroy()
        surface.create_entity(spec)
      end
    end
  end
end

-- Idempotent: scans for legacy entities and converts them. Runs from
-- on_configuration_changed; safe to call on a world that has none.
function migrate.run()
  for _, surface in pairs(game.surfaces) do
    if surface.valid then
      for old_name, direction in pairs(LEGACY_BALANCERS) do
        for _, balancer in ipairs(surface.find_entities_filtered({ name = old_name })) do
          if balancer.valid then
            local position, force, quality, last_user = balancer.position, balancer.force, balancer.quality, balancer.last_user
            balancer.destroy()
            surface.create_entity({
              name = "stock-balancer-steel",
              position = position,
              direction = direction,
              force = force,
              quality = quality,
              player = last_user,
              raise_built = true,
            })
          end
        end
      end

      local groups = {}
      for _, station in ipairs(surface.find_entities_filtered({ type = "linked-container" })) do
        local base = station.valid and legacy_base(station.name)
        if base then
          local id = station.link_id
          groups[id] = groups[id] or { members = {} }
          table.insert(groups[id].members, { entity = station, base = base })
        end
      end
      for _, group in pairs(groups) do
        migrate_group(surface, group.members)
      end

      migrate_ghosts(surface)
    end
  end
end

return migrate
