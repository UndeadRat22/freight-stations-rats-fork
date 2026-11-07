-- Blueprint folding: blueprint records carry whatever prototype a group
-- member currently sits on (band variants, dismantling stand-ins), and
-- those have no item of their own -- pasted ghosts of them could never be
-- built (the engine refuses entities without a placing item as ghosts).
-- Folding the records down to the base family prototype keeps every copied
-- row buildable with the normal item; the build events re-band the rebuilt
-- stations.
local constants = require("scripts.constants")

local blueprint = {}

-- Folds station-family variant records in `entities` (a blueprint's entity
-- records) down to their base prototype, in place. Returns true when
-- anything changed, plus the list. Nil-safe: a blueprint without entities
-- (freshly created, or a book) folds nothing.
function blueprint.fold_entities(entities)
  if not entities then
    return false, entities
  end
  local changed = false
  for _, entity in ipairs(entities) do
    local folded = constants.folded_station_name(entity.name)
    if folded and folded ~= entity.name then
      entity.name = folded
      changed = true
    end
  end
  return changed, entities
end

return blueprint
