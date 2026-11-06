local constants = require("scripts.constants")
local geometry = require("scripts.geometry")
local groups = require("scripts.groups")
local placer = require("scripts.placer")
local blueprint = require("scripts.blueprint")
local underground = require("scripts.underground")
local highlight = require("scripts.highlight")
local guide = require("scripts.guide")
local dismantle = require("scripts.dismantle")
local ticker = require("scripts.ticker")
local tanks = require("scripts.tanks")
local ghosts = require("scripts.ghosts")

local function init_storage()
  storage.groups = storage.groups or {}
  storage.station_group = storage.station_group or {}
  storage.next_link_id = storage.next_link_id or 1
  storage.pending_build_mode = storage.pending_build_mode or {}
  storage.highlights = storage.highlights or {}
  storage.highlight_keys = storage.highlight_keys or {}
  storage.guides = storage.guides or {}
  storage.gap_reservations = storage.gap_reservations or {}
  storage.last_drag_tick = storage.last_drag_tick or {}
  storage.pending_ghosts = storage.pending_ghosts or {}
  storage.pending_dismantles = storage.pending_dismantles or {}
  storage.marked_stations = storage.marked_stations or {}
  storage.cancelled_stand_ins = storage.cancelled_stand_ins or {}
end

script.on_init(init_storage)

-- Build events need the placer in the filter too (its swap handler replaces
-- it with a station, which re-enters this same dispatch); removal events
-- don't, since the placer never survives long enough to be mined or killed.
local BUILD_NAMES = {}
for name in pairs(constants.PLACERS) do
  BUILD_NAMES[#BUILD_NAMES + 1] = name
end
table.sort(BUILD_NAMES) -- pairs() order must not vary between clients
for _, name in ipairs(geometry.relevant_names()) do
  BUILD_NAMES[#BUILD_NAMES + 1] = name
end
-- tank undergrounds: only to face a waiting partner (scripts/tanks.lua)
for _, name in ipairs(tanks.underground_names()) do
  BUILD_NAMES[#BUILD_NAMES + 1] = name
end

local function name_filter(names)
  local f = {}
  for _, name in ipairs(names) do
    f[#f + 1] = { filter = "name", name = name }
  end
  return f
end

local function dispatch_built(entity, player_index)
  if not (entity and entity.valid) then
    return
  end
  if placer.is_placer(entity.name) then
    placer.swap(entity, player_index)
    return
  end
  if tanks.is_underground(entity.name) then
    tanks.on_underground_built(entity, player_index)
    return
  end
  if not (geometry.is_station(entity.name) or geometry.is_balancer(entity.name)) then
    return
  end
  -- First: joining a group can replace a station with a resized prototype
  -- (scripts/groups.lua), after which `entity` is no longer valid.
  script.register_on_object_destroyed(entity)
  if geometry.is_station(entity.name) then
    groups.on_station_built(entity)
  elseif geometry.is_underground(entity.name) then
    underground.on_built(entity, player_index)
  else
    groups.on_balancer_built(entity)
  end
end

local function on_built(event)
  local entity = event.entity
  if entity and entity.valid and entity.name == "entity-ghost" and ghosts.is_swapped(entity.ghost_name) then
    -- one that robots can't build (scripts/ghosts.lua); a player's paste
    -- then snaps like any placer ghost, others stay where they are
    entity = ghosts.to_placer(entity)
    if event.name ~= defines.events.on_built_entity then
      return
    end
  end
  if entity and entity.valid and entity.name == "entity-ghost" then
    if placer.is_gap_ghost(entity.ghost_name) then
      placer.on_gap_ghost_built(entity, event.player_index)
    else
      placer.on_ghost_built(entity, event.player_index)
    end
    return
  end
  dispatch_built(entity, event.player_index)
end

local function on_cloned(event)
  dispatch_built(event.destination)
end

local build_events = {
  defines.events.on_robot_built_entity,
  defines.events.on_space_platform_built_entity,
  defines.events.script_raised_built,
  defines.events.script_raised_revive,
}

local function ghost_filter(filter, names)
  for _, name in ipairs(names) do
    filter[#filter + 1] = { filter = "ghost_name", name = name }
  end
  return filter
end

for _, event_id in ipairs(build_events) do
  script.on_event(event_id, on_built, ghost_filter(name_filter(BUILD_NAMES), ghosts.names()))
end

-- Players also get the station placer ghosts they place (by hand, drag or
-- blueprint), to snap them to their wagon slot right away, see
-- placer.on_ghost_built, and the ghosts of balancers and undergrounds, to
-- snap them to the gap between two slots (placer.on_gap_ghost_built).
local player_ghosts = {}
for _, tier in ipairs(constants.ALL_TIERS) do
  player_ghosts[#player_ghosts + 1] = tier.placer
end
for _, name in ipairs(placer.gap_ghost_names()) do
  if not ghosts.is_swapped(name) then
    player_ghosts[#player_ghosts + 1] = name
  end
end
for _, name in ipairs(ghosts.names()) do
  player_ghosts[#player_ghosts + 1] = name
end
local player_build_filter = ghost_filter(name_filter(BUILD_NAMES), player_ghosts)
script.on_event(defines.events.on_built_entity, on_built, player_build_filter)

script.on_event(defines.events.on_entity_cloned, on_cloned, name_filter(BUILD_NAMES))

-- Pairs with placer.swap: records whether THIS placement was part of a drag
-- (or a blueprint/copy/cut, which always counts as deliberate) so the build
-- event right after it knows whether to auto-connect. Fires for every item
-- placement by any player, not just ours -- on_pre_build carries no entity
-- name to filter on, since nothing has been built yet.
script.on_event(defines.events.on_pre_build, function(event)
  placer.note_pre_build(event)
end)

script.on_event(defines.events.on_player_setup_blueprint, blueprint.on_setup_blueprint)

local REMOVAL_NAMES = geometry.relevant_names()

-- Removal: player mining and entity death provide an inventory
-- (buffer/loot) for whatever a removed station's group can no longer hold
-- -- that's the engine's normal "what you get back" destination, so we feed
-- our redistribution into it rather than fighting it. Robots carry too
-- little for that: they normally get a station already turned into a
-- stand-in when it was marked (scripts/dismantle.lua), which is a plain
-- container and not ours to handle.
script.on_event(defines.events.on_player_mined_entity, function(event)
  groups.on_entity_removed(event.entity, event.buffer)
end, name_filter(REMOVAL_NAMES))

script.on_event(defines.events.on_robot_mined_entity, function(event)
  if geometry.is_station(event.entity.name) then
    dismantle.on_robot_mined(event.entity, event.buffer)
  else
    groups.on_entity_removed(event.entity, event.buffer)
  end
end, name_filter(REMOVAL_NAMES))

-- Deconstruction marks: a marked station becomes a stand-in robots can
-- empty, and back again when the mark is cancelled (scripts/dismantle.lua).
script.on_event(defines.events.on_marked_for_deconstruction, dismantle.on_marked, name_filter(geometry.station_names()))
script.on_event(defines.events.on_cancelled_deconstruction, dismantle.on_cancelled, name_filter(dismantle.names()))

script.on_event(defines.events.on_entity_died, function(event)
  groups.on_entity_removed(event.entity, event.loot)
end, name_filter(REMOVAL_NAMES))

-- The ghosts that stations, tanks and wide balancers leave behind become
-- placer ghosts (scripts/ghosts.lua): on death, on undo, and on pipette the
-- real item stands in for the hidden one.
script.on_event(defines.events.on_post_entity_died, ghosts.on_post_entity_died, {
  { filter = "type", type = "linked-container" },
  { filter = "type", type = "storage-tank" },
  { filter = "type", type = "simple-entity-with-owner" },
})
script.on_event(defines.events.on_undo_applied, ghosts.on_undo_applied)
script.on_event(defines.events.on_player_pipette, ghosts.on_player_pipette)

-- entity is still valid here (same as the other removal events above), but
-- there is no player/robot buffer for what the group can no longer hold, so
-- that falls through to the ground-spill fallback.
script.on_event(defines.events.script_raised_destroy, function(event)
  groups.on_entity_removed(event.entity, nil)
end, name_filter(REMOVAL_NAMES))

-- Only underground balancers (and the wide fluid balancer, which needs
-- nothing) can be rotated or flipped once placed: the
-- placers are swapped out within their own build event, and the real
-- stations and regular balancers can't turn at all. Neither event takes a
-- filter, so check the name here.
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

-- Safety net: a station destroyed through a path that skipped the handlers
-- above. Its group is re-derived from what's left; stations the mod
-- replaced or removed itself are no longer in storage.station_group by now.
script.on_event(defines.events.on_object_destroyed, function(event)
  groups.on_station_vanished(event.useful_id)
end)

-- Recipes are tech-gated: enables this mod's recipes for every force that
-- has researched a technology unlocking them, or techs researched before a
-- recipe was added would never unlock it. Only ever enables, and only these
-- recipes: force.reset_technology_effects() would also switch off recipes
-- other mods enabled by script.
local function unlock_researched_recipes()
  local ours = {}
  for _, tier in ipairs(constants.ALL_TIERS) do
    ours[tier.item] = true
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

local function on_configuration_changed()
  init_storage()
  -- Saves from 0.4.0: the engine removes the old spot resources with their
  -- prototype, this drops their bookkeeping.
  storage.spots = nil
  storage.stop_spots = nil
  -- Up to 0.8.0: tracked balancers, never read.
  storage.balancers = nil
  -- Brings every group in line with the world and to the station prototype
  -- sized for it: needed whenever a tier's max_group changes, and repairs
  -- anything an older version got wrong. A no-op for groups that are right.
  groups.resync_all()
  -- Up to 0.12.0: ghosts of stations, tanks and wide balancers that robots
  -- can't build any more.
  ghosts.migrate()
  unlock_researched_recipes()
  ticker.update()
end

script.on_configuration_changed(on_configuration_changed)

script.on_event(defines.events.on_selected_entity_changed, highlight.on_selected_entity_changed)

-- Station ghosts from a paste that had no train stop yet (placer.retry_ghosts),
-- and stations marked for deconstruction last tick (dismantle.on_tick).
-- Registered only while either has queued work (scripts/ticker.lua).
ticker.set_handler(function()
  placer.retry_ghosts()
  dismantle.on_tick()
  ticker.update()
end)
script.on_load(ticker.update)

-- Drops drag-spacing reservations once a player has stopped dragging.
script.on_nth_tick(60, function(event)
  placer.expire_reservations(event.tick)
end)

-- Placement guide while holding a station (scripts/guide.lua).
script.on_event(defines.events.on_player_cursor_stack_changed, guide.on_cursor_changed)
script.on_nth_tick(30, function()
  guide.refresh_all()
  highlight.refresh_all()
end)

-- Guide and outline are drawn for one player only: drop them when that
-- player leaves, and redraw the guide if they come back holding a station.
script.on_event(defines.events.on_player_left_game, function(event)
  guide.clear(event.player_index)
  highlight.clear(event.player_index)
end)

script.on_event(defines.events.on_player_joined_game, function(event)
  local player = game.get_player(event.player_index)
  if player then
    guide.update(player)
  end
end)

script.on_event(defines.events.on_player_removed, function(event)
  guide.clear(event.player_index)
  highlight.clear(event.player_index)
  placer.forget_player(event.player_index)
end)
