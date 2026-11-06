-- Placement guide. The engine's red/green cursor preview only knows about
-- collisions and its own built-in rules, and a script can't feed the train
-- stop / wagon slot rule (scripts/rails.lua) into it, so a station always
-- previews green. Instead, while a player holds a station (item or ghost
-- cursor), every area near them where one could go is shaded green,
-- visible to that player only.
local constants = require("scripts.constants")
local rails = require("scripts.rails")

local guide = {}

local RADIUS = 64
-- premultiplied alpha: a faint green wash
local COLOR = { r = 0.05, g = 0.25, b = 0.05, a = 0.25 }
local MANUAL = defines.build_check_type.manual_ghost
local SIDES = { -1, 1 }

local ITEM_TIER = {}
for _, tier in ipairs(constants.ALL_TIERS) do
  ITEM_TIER[tier.item] = tier
end

function guide.clear(player_index)
  local objects = storage.guides[player_index]
  if objects then
    for _, object in ipairs(objects) do
      if object.valid then
        object.destroy()
      end
    end
    storage.guides[player_index] = nil
  end
end

local function held_tier(player)
  local stack = player.cursor_stack
  if stack and stack.valid_for_read then
    return ITEM_TIER[stack.name]
  end
  local ghost = player.cursor_ghost
  if ghost then
    local name = ghost.name
    if type(name) ~= "string" then
      name = name.name
    end
    return ITEM_TIER[name]
  end
  return nil
end

-- One filled block per wagon slot and side: the union of every position a
-- station could take there at gap 1..MAX_RAIL_GAP (2 x 6 for iron, 3 x 6 for
-- steel), shrunk to the free part if something blocks some of it. Gap 0
-- (touching the rail) is legal, since a second track on the station's other
-- side could serve it, but it leaves no room for an inserter here, so it's
-- never suggested. For a tank only the pump's gap is (constants.PUMP_GAP):
-- nothing else reaches a fluid wagon.
--
-- `lines[side][gap]` is where a station's centre sits across the track at
-- that side and gap, and which tiles along it have a rail it can use.
local function suggested_gaps(tier)
  if tier.fluid then
    return constants.PUMP_GAP, constants.PUMP_GAP
  end
  return 1, constants.MAX_RAIL_GAP
end

local function draw_slot(player, surface, objects, family, tier, along, across, centre, lines)
  local half_long = constants.STATION_TILES / 2
  local half_wide = tier.width / 2
  local name = constants.FAMILY_INFO[family].name
  local first_gap, last_gap = suggested_gaps(tier)
  for _, side in ipairs(SIDES) do
    local lo, hi
    for gap = first_gap, last_gap do
      local line = lines[side][gap]
      local p = { [along] = centre, [across] = line.across }
      if
        rails.station_ok(surface, p, family, line.covered)
        and surface.can_place_entity({ name = name, position = p, force = player.force, build_check_type = MANUAL })
      then
        lo = math.min(lo or math.huge, p[across] - half_wide)
        hi = math.max(hi or -math.huge, p[across] + half_wide)
      end
    end
    if lo then
      objects[#objects + 1] = rendering.draw_rectangle({
        surface = surface,
        left_top = { [along] = centre - half_long, [across] = lo },
        right_bottom = { [along] = centre + half_long, [across] = hi },
        color = COLOR,
        filled = true,
        players = { player },
      })
    end
  end
end

function guide.update(player)
  guide.clear(player.index)
  local tier = held_tier(player)
  if not tier then
    return
  end
  local surface = player.surface
  local pos = player.position
  local objects = {}
  local stops = surface.find_entities_filtered({
    type = "train-stop",
    area = { { pos.x - RADIUS, pos.y - RADIUS }, { pos.x + RADIUS, pos.y + RADIUS } },
  })
  for _, stop in ipairs(stops) do
    local layout = rails.stop_layout(stop)
    if layout then
      local family = layout.along == "x" and tier.station_h or tier.station_v
      -- The rails are looked up once per stop and sorted into tiles once
      -- per line of stations along it, not for each wagon slot.
      local rail_positions = rails.slot_rails(surface, layout, family)
      local lines = {}
      for _, side in ipairs(SIDES) do
        lines[side] = {}
        local first_gap, last_gap = suggested_gaps(tier)
        for gap = first_gap, last_gap do
          local across = layout.track + side * (1 + gap + tier.width / 2)
          lines[side][gap] = { across = across, covered = rails.covered_tiles(rail_positions, family, across) }
        end
      end
      for k = 0, constants.MAX_TRAIN_CARS - 1 do
        local centre = layout.origin - layout.forward * rails.CAR_PITCH * k
        draw_slot(player, surface, objects, family, tier, layout.along, layout.across, centre, lines)
      end
    end
  end
  storage.guides[player.index] = objects
end

function guide.on_cursor_changed(event)
  local player = game.get_player(event.player_index)
  if player then
    guide.update(player)
  end
end

-- Keeps the outlines current while a player walks around or builds. The
-- players are listed first: update() removes and re-adds their entries,
-- which a pairs() loop over storage.guides itself must not see.
function guide.refresh_all()
  local player_indices = {}
  for player_index in pairs(storage.guides) do
    player_indices[#player_indices + 1] = player_index
  end
  for _, player_index in ipairs(player_indices) do
    local player = game.get_player(player_index)
    if player and player.connected then
      guide.update(player)
    else
      guide.clear(player_index)
    end
  end
end

return guide
