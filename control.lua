local constants = require("scripts.constants")
local geometry = require("scripts.geometry")
local groups = require("scripts.groups")
local connect = require("scripts.connect")
local underground = require("scripts.underground")
local highlight = require("scripts.highlight")
local dismantle = require("scripts.dismantle")
local tanks = require("scripts.tanks")
local migrate = require("scripts.migrate")

local function init_storage()
  storage.next_link_id = storage.next_link_id or 1
  storage.highlights = storage.highlights or {}
  storage.highlight_keys = storage.highlight_keys or {}
end

script.on_init(init_storage)

local function name_filter(names)
  local f = {}
  for _, name in ipairs(names) do
    f[#f + 1] = { filter = "name", name = name }
    -- ghost_name matches a ghost's inner name AND a real entity's name,
    -- which is what the build events below need (an entity-ghost built by a
    -- player, or the real entity a script_raised_revive hands over)
    f[#f + 1] = { filter = "ghost_name", name = name }
  end
  return f
end

-- Everything whose build links or re-links stations: stations, balancers,
-- undergrounds (station tiers), and tank undergrounds (to face them and
-- show their pairing; tanks themselves are linked by the engine's own
-- fluid segments). Sorted: an event filter's pairs() order must not vary
-- between clients.
local BUILD_NAMES = {}
for name in pairs(constants.STATION_INFO) do
  BUILD_NAMES[#BUILD_NAMES + 1] = name
end
for _, tier in ipairs(constants.TIERS) do
  BUILD_NAMES[#BUILD_NAMES + 1] = tier.balancer
  BUILD_NAMES[#BUILD_NAMES + 1] = tier.underground
end
for _, name in ipairs(tanks.underground_names()) do
  BUILD_NAMES[#BUILD_NAMES + 1] = name
end
table.sort(BUILD_NAMES)

local BUILD_FILTER = name_filter(BUILD_NAMES)

local function dispatch_built(entity, player_index)
  if not (entity and entity.valid) then
    return
  end
  if tanks.is_underground(entity.name) then
    tanks.on_underground_built(entity, player_index)
    return
  end
  if geometry.is_underground(entity.name) then
    underground.on_built(entity, player_index)
    return
  end
  if geometry.is_station(entity.name) then
    groups.on_station_built(entity)
    connect.on_station_built(entity, player_index)
  else
    groups.on_balancer_built(entity)
  end
end

local function on_built(event)
  dispatch_built(event.entity, event.player_index)
end

local function on_cloned(event)
  dispatch_built(event.destination, nil)
end

local build_events = {
  defines.events.on_built_entity,
  defines.events.on_robot_built_entity,
  defines.events.on_space_platform_built_entity,
  -- 2.1 renamed these: the old on_script_raised_* ids no longer exist
  defines.events.script_raised_built,
  defines.events.script_raised_revive,
}
for _, event_id in ipairs(build_events) do
  script.on_event(event_id, on_built, BUILD_FILTER)
end

script.on_event(defines.events.on_entity_cloned, on_cloned, BUILD_FILTER)

-- Removal: player mining and entity death provide an inventory (buffer or
-- loot) for a removed station's group to empty into; robots, script
-- destroys and cancelled clones give nothing, so it falls to the ground.
local function on_removed(event, inventory)
  local entity = event.entity
  if not (entity and entity.valid) then
    return
  end
  if geometry.is_station(entity.name) then
    dismantle.on_station_mined(entity, inventory)
  end
  if not constants.TANK_INFO[entity.name] then
    groups.on_entity_removed(entity)
  end
end

script.on_event(defines.events.on_player_mined_entity, function(event)
  on_removed(event, event.buffer)
end, BUILD_FILTER)

script.on_event(defines.events.on_robot_mined_entity, function(event)
  on_removed(event, event.buffer)
end, BUILD_FILTER)

script.on_event(defines.events.on_entity_died, function(event)
  on_removed(event, event.loot)
end, BUILD_FILTER)

script.on_event(defines.events.script_raised_destroy, function(event)
  on_removed(event, nil)
end, BUILD_FILTER)

-- Deconstruction marks: the last station of a group becomes a stand-in
-- robots can empty, and back again when the mark is cancelled
-- (scripts/dismantle.lua).
script.on_event(defines.events.on_marked_for_deconstruction, dismantle.on_marked, name_filter(geometry.station_names()))
script.on_event(defines.events.on_cancelled_deconstruction, dismantle.on_cancelled, name_filter(dismantle.names()))

-- Only underground balancers (and the wide fluid balancer, which needs
-- nothing) can be rotated or flipped once placed: stations and regular
-- balancers hold their direction. Neither event takes a filter, so check
-- the name here.
script.on_event(defines.events.on_player_rotated_entity, function(event)
  local entity = event.entity
  if entity and entity.valid and geometry.is_underground(entity.name) then
    underground.on_rotated(entity, event.previous_direction, event.player_index)
  elseif entity and entity.valid and tanks.is_underground(entity.name) then
    tanks.on_underground_rotated(entity, event.previous_direction, event.player_index)
  end
end)

script.on_event(defines.events.on_player_flipped_entity, function(event)
  local entity = event.entity
  if entity and entity.valid and geometry.is_underground(entity.name) then
    underground.on_flipped(entity, event.player_index)
  end
end)

-- Recipes are tech-gated: enables this mod's recipes for every force that
-- has researched a technology unlocking them, or techs researched before a
-- recipe was added would never unlock it. Only ever enables, and only these
-- recipes: force.reset_technology_effects() would also switch off recipes
-- other mods enabled by script.
local function unlock_researched_recipes()
  local ours = {}
  for _, tier in ipairs(constants.ALL_TIERS) do
    ours[tier.item_h] = true
    ours[tier.item_v] = true
    ours[tier.balancer_item] = true
    ours[tier.underground_item] = true
  end
  -- technology name -> our recipes it unlocks (wherever a mod moved them)
  local unlocks = {}
  for name, technology in pairs(prototypes.technology) do
    for _, effect in ipairs(technology.effects) do
      if effect.type == "unlock-recipe" and ours[effect.recipe] then
        unlocks[name] = unlocks[name] or {}
        table.insert(unlocks[name], effect.recipe)
      end
    end
  end
  for _, force in pairs(game.forces) do
    for name, recipes in pairs(unlocks) do
      if force.technologies[name].researched then
        for _, recipe in ipairs(recipes) do
          force.recipes[recipe].enabled = true
        end
      end
    end
  end
end

script.on_configuration_changed(function()
  init_storage()
  -- converts 0.12.x / 0.13.x entities to the fixed-size prototypes
  -- (scripts/migrate.lua); idempotent, does nothing when there are none
  migrate.run()
  unlock_researched_recipes()
end)

-- Mouseover highlight (scripts/highlight.lua).
script.on_event(defines.events.on_selected_entity_changed, highlight.on_selected_entity_changed)
script.on_nth_tick(30, function()
  highlight.refresh_all()
end)

-- The outline is drawn for one player only: drop it when that player leaves.
script.on_event(defines.events.on_player_left_game, function(event)
  highlight.clear(event.player_index)
end)

script.on_event(defines.events.on_player_removed, function(event)
  highlight.clear(event.player_index)
end)
