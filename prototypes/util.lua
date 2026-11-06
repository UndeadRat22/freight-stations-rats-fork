local constants = require("scripts.constants")

local sprite_util = {}

local STATION_SPRITES = require("prototypes.station-sprites")
local BALANCER_SPRITES = require("prototypes.balancer-sprites")
local TANK_SPRITES = require("prototypes.tank-sprites")

-- Body + shadow layers of one rendered sprite entry (see the generated
-- tables above). `offset` (optional {x, y}) moves it.
local function rendered(s, offset)
  local shift = { s.shift[1] + (offset and offset.x or 0), s.shift[2] + (offset and offset.y or 0) }
  local function layer(filename, is_shadow)
    return {
      filename = filename,
      priority = "extra-high",
      width = s.width,
      height = s.height,
      scale = 0.5,
      shift = shift,
      draw_as_shadow = is_shadow,
    }
  end
  return { layers = { layer(s.shadow, true), layer(s.filename, false) } }
end

-- Sprites rendered by tools/sprites/: a station of tier `kind` ("iron" /
-- "steel") lying along `axis` ("x" / "y"); a balancer sitting between
-- stations that lie along `axis` (iron has one sprite for both); an
-- underground balancer facing `direction` ("north", ...).
function sprite_util.station_picture(kind, axis, offset)
  return rendered((STATION_SPRITES[kind] or TANK_SPRITES[kind])[axis], offset)
end

-- Tank tiers ("tank" / "tank-steel", tools/sprites/render_tanks.py): a tank
-- balancer between tanks lying along `axis` (the 1x1 one has one sprite);
-- an underground fluid balancer facing `direction`.
function sprite_util.tank_balancer_picture(kind, axis)
  local s = TANK_SPRITES[kind].balancer
  return rendered(s[axis] or s)
end

-- Where a tank of tier `kind` lying along `axis` shows its fluid level: the
-- sight glass rendered into its sprite, as a window_bounding_box.
function sprite_util.tank_window(kind, axis)
  return TANK_SPRITES[kind]["window_" .. axis]
end

-- The dark glass drawn behind that window (and behind the fluid level).
function sprite_util.tank_window_background(kind, axis)
  local s = TANK_SPRITES[kind]["window_background_" .. axis]
  return { filename = s.filename, width = s.width, height = s.height, scale = 0.5, priority = "extra-high" }
end

function sprite_util.tank_underground_picture(kind, direction)
  return rendered(TANK_SPRITES[kind].underground[direction])
end

function sprite_util.balancer_picture(kind, axis)
  local s = BALANCER_SPRITES[kind].balancer
  return rendered(s[axis] or s)
end

function sprite_util.underground_picture(kind, direction)
  return rendered(BALANCER_SPRITES[kind].underground[direction])
end

-- Item and entity icons, rendered by tools/sprites/render_icons.py.
-- `base` is "freight-station", "stock-balancer" or "underground-stock-balancer".
function sprite_util.icon(base, kind)
  local suffix = ""
  if kind == "steel" or kind == "tank-steel" then
    suffix = "-steel"
  end
  return "__freight-stations-rats-fork__/graphics/icons/" .. base .. suffix .. ".png"
end

-- Every item of the mod sits in the vanilla train row of the Logistics tab,
-- after the signals and before the rolling stock (vanilla orders
-- "b[train-automation]-c[rail-chain-signal]" and "c[rolling-stock]-...").
sprite_util.SUBGROUP = "train-transport"

-- Grouped by tier first (all iron, then all steel, then the tanks), then
-- by kind.
local TIER_ORDER = { iron = "a[iron]", steel = "b[steel]", tank = "c[tank]", ["tank-steel"] = "d[tank-steel]" }
function sprite_util.order(tier, kind)
  return "b[train-automation]-d[freight-stations]-" .. TIER_ORDER[tier.key] .. "-" .. kind
end

-- The vanilla chest's circuit connector, moved onto a station's last tile
-- along its long axis (east or south end) and its last tile across it.
-- `offset` (optional {x, y}) moves it, like station_picture's.
function sprite_util.station_circuit_connector(tier, axis, offset)
  local along = constants.STATION_TILES / 2 - 0.5
  local across = (tier.width - 1) / 2
  local dx, dy = along, across
  if axis == "y" then
    dx, dy = across, along
  end
  if offset then
    dx, dy = dx + offset.x, dy + offset.y
  end
  return circuit_connector_definitions.create_single(universal_connector_template, {
    variation = 26,
    main_offset = { dx + 3 / 32, dy + 5.5 / 32 },
    shadow_offset = { dx + 7.5 / 32, dy + 7.5 / 32 },
    show_shadow = true,
  })
end

-- Per-tier look of every station; the placer (prototypes/placer.lua) reuses
-- it so placement previews and blueprint ghosts look like the real thing.
sprite_util.TIER_ART = {
  iron = {
    icon = sprite_util.icon("freight-station", "iron"),
    corpse = "iron-chest-remnants",
    explosion = "iron-chest-explosion",
    health = 400,
  },
  steel = {
    icon = sprite_util.icon("freight-station", "steel"),
    corpse = "steel-chest-remnants",
    explosion = "steel-chest-explosion",
    health = 700,
  },
  tank = {
    icon = sprite_util.icon("fluid-station", "tank"),
    corpse = "storage-tank-remnants",
    explosion = "storage-tank-explosion",
    health = 500,
  },
  ["tank-steel"] = {
    icon = sprite_util.icon("fluid-station", "tank-steel"),
    corpse = "storage-tank-remnants",
    explosion = "storage-tank-explosion",
    health = 800,
  },
}

return sprite_util
