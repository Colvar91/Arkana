-- CRC32

local function buildCRC32Table()
    local t = {}
    for i = 0, 255 do
        local crc = i
        for _ = 1, 8 do
            if bit.band(crc, 1) ~= 0 then
                crc = bit.bxor(bit.rshift(crc, 1), 0xEDB88320)
            else
                crc = bit.rshift(crc, 1)
            end
        end
        t[i] = crc
    end
    return t
end

local CRC32_TABLE = buildCRC32Table()

local function CRC32(str)
    local crc = 0xFFFFFFFF
    for i = 1, #str do
        local b   = string.byte(str, i)
        local idx = bit.band(bit.bxor(crc, b), 0xFF)
        crc = bit.bxor(bit.rshift(crc, 8), CRC32_TABLE[idx])
    end
    return bit.bxor(crc, 0xFFFFFFFF)
end

ARKANA_CRC32 = CRC32  -- globaler Export für Network etc.

-- Serializer

local function valToStr(v)
    if type(v) == "boolean" then return v and "true" or "false" end
    if v == nil then return "" end
    return tostring(v)
end

local function sortedKeys(tbl, skipKey)
    local keys = {}
    for k in pairs(tbl) do
        if k ~= skipKey then keys[#keys + 1] = k end
    end
    table.sort(keys)
    return keys
end

local function serializeTag(tag)
    local parts = { tag.type }
    for _, k in ipairs(sortedKeys(tag, "type")) do
        parts[#parts + 1] = k .. "=" .. valToStr(tag[k])
    end
    return table.concat(parts, ":")
end

local function serializeTags(tags)
    if not tags or #tags == 0 then return "" end
    local out = {}
    for i = 1, #tags do out[i] = serializeTag(tags[i]) end
    table.sort(out)
    return table.concat(out, ",")
end

local function serializeTrigger(t)
    local parts = { t.type }
    for _, k in ipairs(sortedKeys(t, "type")) do
        parts[#parts + 1] = k .. "=" .. valToStr(t[k])
    end
    return table.concat(parts, ":")
end

local function serializeTriggers(triggers)
    if not triggers or #triggers == 0 then return "" end
    local out = {}
    for i = 1, #triggers do out[i] = serializeTrigger(triggers[i]) end
    table.sort(out)
    return table.concat(out, ",")
end

local function serializeSecondaryEffect(se)
    if not se then return "" end
    return valToStr(se.condition) .. ":" .. valToStr(se.effect) .. ":" .. valToStr(se.value)
end

local function serializeHeroPowerEffects(effects)
    if not effects or #effects == 0 then return "" end
    local out = {}
    for i = 1, #effects do
        local e = effects[i]
        out[i] = valToStr(e.effect) .. ":" .. valToStr(e.value) .. ":" .. valToStr(e.expiresEndOfTurn)
    end
    table.sort(out)
    return table.concat(out, ",")
end

local function cardToHashString(c)
    return table.concat({
        c.id              or "",
        valToStr(c.cost),
        c.type            or "",
        c.class           or "",
        valToStr(c.attack),
        valToStr(c.health),
        c.rarity          or "",
        c.race            or "",
        valToStr(c.durability),
        c.targetType      or "",
        c.targetCondition or "",
        serializeTags(c.tags),
        serializeTriggers(c.triggers),
        serializeSecondaryEffect(c.secondaryEffect),
        serializeHeroPowerEffects(c.effects),
    }, "|")
end

-- Sucht-Treffer: aktueller Name ODER ein früherer (altNames, z.B. "Sukkubus" für den
-- umbenannten Teufelspirscher). needle muss bereits kleingeschrieben sein.
function ARKANA_CardMatchesName(card, needle)
    if not needle or needle == "" then return true end
    if not card then return false end
    if (card.name or ""):lower():find(needle, 1, true) then return true end
    for _, alt in ipairs(card.altNames or {}) do
        if alt:lower():find(needle, 1, true) then return true end
    end
    return false
end

function ARKANA_ComputeCatalogHash()
    local ids = {}
    for id in pairs(ARKANA_CardData) do ids[#ids + 1] = id end
    table.sort(ids)
    local parts = {}
    for _, id in ipairs(ids) do
        parts[#parts + 1] = cardToHashString(ARKANA_CardData[id])
    end
    return CRC32(table.concat(parts, "\n"))
end
