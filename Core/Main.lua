Arkana = LibStub("AceAddon-3.0"):NewAddon("Arkana", "AceComm-3.0", "AceEvent-3.0")
local addon = Arkana

local SCHEMA_VERSION = 1
local PREFIX = "ARKANA"

-- Build-Stempel: wird bei jeder Code-Änderung hochgezählt — /arkana build zeigt ihn an.
-- Damit lässt sich sofort prüfen, ob Copy.bat + /reload wirklich den neuen Stand geladen haben.
ARKANA_BUILD = "2026-08-16-f"

local SETTINGS_DEFAULTS = { dbGridMode = false, dbDeckGridMode = false, dbCardSize = 80, dbDeckCardSize = 80, windowScale = 1.0, tooltipScale = 1.0, boardScale = 1.0, boardAlpha = 1.0, chatMsgs = false, theme = "STANDARD", spectatorSharing = false, rankSharing = false }
local scalableFrames = setmetatable({}, { __mode = "k" })
local themeFrames = setmetatable({}, { __mode = "k" })
local themePalettes = setmetatable({}, { __mode = "k" })
local themeTextures = setmetatable({}, { __mode = "k" })

local THEME_ORDER = {
    "STANDARD", "WOW", "DRUID", "HUNTER", "MAGE", "PALADIN",
    "PRIEST", "ROGUE", "SHAMAN", "WARLOCK", "WARRIOR",
}
local THEMES = {
    STANDARD = { name = "Standard",      accent = { 0.58, 0.30, 0.92 } },
    WOW      = { name = "WoW",           accent = { 1.00, 0.72, 0.18 } },
    DRUID    = { name = "Druide",        accent = { 1.00, 0.49, 0.04 } },
    HUNTER   = { name = "Jäger",         accent = { 0.67, 0.83, 0.45 } },
    MAGE     = { name = "Magier",        accent = { 0.25, 0.78, 0.92 } },
    PALADIN  = { name = "Paladin",       accent = { 0.96, 0.55, 0.73 } },
    PRIEST   = { name = "Priester",      accent = { 1.00, 1.00, 1.00 } },
    ROGUE    = { name = "Schurke",       accent = { 1.00, 0.96, 0.41 } },
    SHAMAN   = { name = "Schamane",      accent = { 0.00, 0.44, 0.87 } },
    WARLOCK  = { name = "Hexenmeister",  accent = { 0.53, 0.53, 0.93 } },
    WARRIOR  = { name = "Krieger",       accent = { 0.78, 0.61, 0.43 } },
}

local function ThemeKey(key)
    key = tostring(key or "STANDARD"):upper()
    return THEMES[key] and key or "STANDARD"
end

local activeThemeKey = ThemeKey(ARKANA_Settings and ARKANA_Settings.theme)

local function ThemePalette(key)
    key = ThemeKey(key)
    local a = THEMES[key].accent
    if key == "STANDARD" then
        return {
            panel = { 0.030, 0.024, 0.050, 0.98 }, panelBorder = { 0.30, 0.22, 0.43, 1.00 },
            inner = { 0.055, 0.045, 0.080, 0.97 }, section = { 0.055, 0.045, 0.080, 0.96 },
            row = { 0.055, 0.045, 0.080, 0.96 }, button = { 0.105, 0.088, 0.145, 1.00 },
            purple = { 0.58, 0.30, 0.92, 1.00 }, purpleSoft = { 0.34, 0.24, 0.48, 1.00 },
            title = { 0.82, 0.68, 1.00, 1.00 }, danger = { 0.72, 0.16, 0.24, 1.00 },
        }
    elseif key == "WOW" then
        -- Klassische WoW-Anmutung: fast schwarzes Blau, warme Lederflächen und
        -- goldene Messingakzente. Die Struktur der Arkana-Fenster bleibt erhalten.
        return {
            panel = { 0.018, 0.027, 0.052, 0.98 }, panelBorder = { 0.58, 0.42, 0.16, 1.00 },
            inner = { 0.060, 0.047, 0.025, 0.97 }, section = { 0.050, 0.041, 0.026, 0.96 },
            row = { 0.070, 0.052, 0.027, 0.96 }, button = { 0.115, 0.078, 0.030, 1.00 },
            purple = { 1.00, 0.72, 0.18, 1.00 }, purpleSoft = { 0.48, 0.34, 0.12, 1.00 },
            title = { 1.00, 0.84, 0.42, 1.00 }, danger = { 0.72, 0.16, 0.24, 1.00 },
        }
    end
    local function mix(base, factor, alpha)
        return { base + a[1] * factor, base + a[2] * factor, base + a[3] * factor, alpha or 1 }
    end
    return {
        panel = mix(0.016, 0.035, 0.98), panelBorder = mix(0.10, 0.35, 1),
        inner = mix(0.035, 0.050, 0.97), section = mix(0.035, 0.050, 0.96),
        row = mix(0.035, 0.050, 0.96), button = mix(0.065, 0.070, 1),
        purple = { a[1], a[2], a[3], 1 },
        purpleSoft = { a[1] * 0.58, a[2] * 0.58, a[3] * 0.58, 1 },
        title = { 0.45 + a[1] * 0.55, 0.45 + a[2] * 0.55, 0.45 + a[3] * 0.55, 1 },
        danger = { 0.72, 0.16, 0.24, 1 },
    }
end

local function CopyPalette(target, source)
    for key, color in pairs(source) do
        target[key] = target[key] or {}
        for i = 1, 4 do target[key][i] = color[i] end
    end
    return target
end

function Arkana:UI_RegisterThemePalette(palette)
    palette = palette or {}
    CopyPalette(palette, ThemePalette(activeThemeKey))
    themePalettes[palette] = true
    return palette
end

function Arkana:UI_ThemeOrder() return THEME_ORDER end
function Arkana:UI_ThemeName(key) return THEMES[ThemeKey(key)].name end
function Arkana:UI_CurrentTheme() return ThemeKey(ARKANA_Settings and ARKANA_Settings.theme) end

local function SameColor(a, b, epsilon)
    epsilon = epsilon or 0.015
    if not a or not b then return false end
    for i = 1, 4 do
        if math.abs((a[i] or 1) - (b[i] or 1)) > epsilon then return false end
    end
    return true
end

local function MappedColor(color, oldPalette, newPalette)
    if not color or color[1] == nil or color[2] == nil or color[3] == nil then return nil end
    local semanticKeys = {
        "panel", "panelBorder", "inner", "section", "row",
        "button", "purpleSoft", "title", "danger",
    }
    -- Auch gemischte Restfarben eines früheren Themes erfassen. Das ist wichtig,
    -- wenn ein Fenster während eines Themewechsels bereits geöffnet war.
    for _, sourceKey in ipairs(THEME_ORDER) do
        local source = ThemePalette(sourceKey)
        for _, key in ipairs(semanticKeys) do
            if SameColor(color, source[key]) then return newPalette[key] end
        end
        local sourceAccent = source.purple
        if math.abs(color[1] - sourceAccent[1]) < 0.015 and
           math.abs(color[2] - sourceAccent[2]) < 0.015 and
           math.abs(color[3] - sourceAccent[3]) < 0.015 then
            return { newPalette.purple[1], newPalette.purple[2], newPalette.purple[3], color[4] }
        end
    end
end

local function RecolorFrame(frame, oldPalette, newPalette)
    if not frame then return end
    if frame.GetBackdropColor and frame.SetBackdropColor then
        local r, g, b, a = frame:GetBackdropColor()
        local mapped = MappedColor({ r, g, b, a }, oldPalette, newPalette)
        if mapped then frame:SetBackdropColor(unpack(mapped)) end
    end
    if frame.GetBackdropBorderColor and frame.SetBackdropBorderColor then
        local r, g, b, a = frame:GetBackdropBorderColor()
        local mapped = MappedColor({ r, g, b, a }, oldPalette, newPalette)
        if mapped then frame:SetBackdropBorderColor(unpack(mapped)) end
    end
    for i = 1, select("#", frame:GetRegions()) do
        local region = select(i, frame:GetRegions())
        if region and region.GetObjectType and region:GetObjectType() == "Texture" and
           region.GetColorTexture and region:GetColorTexture() then
            local r, g, b, a = region:GetColorTexture()
            local mapped = MappedColor({ r, g, b, a }, oldPalette, newPalette)
            if mapped then region:SetColorTexture(unpack(mapped)) end
        elseif region and region.GetObjectType and region:GetObjectType() == "FontString" and
               region.GetTextColor and region.SetTextColor then
            local r, g, b, a = region:GetTextColor()
            local mapped = MappedColor({ r, g, b, a }, oldPalette, newPalette)
            if mapped then region:SetTextColor(unpack(mapped)) end
        end
    end
    for i = 1, select("#", frame:GetChildren()) do
        RecolorFrame(select(i, frame:GetChildren()), oldPalette, newPalette)
    end
end

function Arkana:UI_RegisterThemeFrame(frame)
    if frame then themeFrames[frame] = true end
end

function Arkana:UI_BindThemeTexture(texture, color, alpha)
    if not texture or type(color) ~= "table" then return end
    themeTextures[texture] = { color = color, alpha = alpha }
    texture:SetColorTexture(color[1], color[2], color[3], alpha or color[4] or 1)
end

function Arkana:UI_SetTheme(key)
    key = ThemeKey(key)
    ARKANA_Settings = ARKANA_Settings or {}
    local oldPalette = ThemePalette(activeThemeKey)
    local newPalette = ThemePalette(key)
    ARKANA_Settings.theme = key
    activeThemeKey = key
    for palette in pairs(themePalettes) do CopyPalette(palette, newPalette) end
    for texture, binding in pairs(themeTextures) do
        local color = binding.color
        texture:SetColorTexture(color[1], color[2], color[3], binding.alpha or color[4] or 1)
    end
    for frame in pairs(themeFrames) do RecolorFrame(frame, oldPalette, newPalette) end
end

local function NormalizeColorTextures(frame)
    if not frame then return end
    for i = 1, select("#", frame:GetRegions()) do
        local region = select(i, frame:GetRegions())
        if region and region.GetObjectType and region:GetObjectType() == "Texture" and
           region.GetColorTexture and region:GetColorTexture() then
            if region.SetSnapToPixelGrid then region:SetSnapToPixelGrid(false) end
            if region.SetTexelSnappingBias then region:SetTexelSnappingBias(0) end
        end
    end
    for i = 1, select("#", frame:GetChildren()) do
        NormalizeColorTextures(select(i, frame:GetChildren()))
    end
end

local function StopMovingPixelPerfect(frame)
    frame:StopMovingOrSizing()
    local point, relative, relativePoint, x, y = frame:GetPoint(1)
    local scale = frame:GetEffectiveScale()
    if not point or not x or not y or not scale or scale <= 0 then return end
    x = math.floor(x * scale + 0.5) / scale
    y = math.floor(y * scale + 0.5) / scale
    frame:ClearAllPoints()
    frame:SetPoint(point, relative or UIParent, relativePoint or point, x, y)
    NormalizeColorTextures(frame)
end

-- Menüs melden sich hier beim Erstellen an. Dadurch gilt eine gespeicherte
-- Fensterskalierung auch für Fenster, die erst später in der Sitzung entstehen.
function Arkana:UI_RegisterScalableFrame(frame)
    if not frame then return end
    scalableFrames[frame] = true
    themeFrames[frame] = true
    frame:SetScale(ARKANA_Settings and ARKANA_Settings.windowScale or 1.0)
    frame:SetScript("OnDragStop", StopMovingPixelPerfect)
    frame:HookScript("OnShow", function(self)
        -- Die Kinder entstehen häufig erst nach der Registrierung. Beim Anzeigen
        -- sind alle dünnen Rahmen und Linien vorhanden und können normalisiert werden.
        local current = ThemePalette(activeThemeKey)
        RecolorFrame(self, current, current)
        NormalizeColorTextures(self)
    end)
end

-- Info-Meldungen (Spielfluss-Feedback): standardmäßig stumm, /arkana msgs on|off.
-- Fehlermeldungen (rot) laufen weiterhin über print und sind NICHT abschaltbar.
function Arkana:Info(msg)
    if ARKANA_Settings and ARKANA_Settings.chatMsgs then print(msg) end
end
local STATS_DEFAULTS    = { global = { w = 0, l = 0, d = 0 }, decks = {} }

function Arkana:OnInitialize()
    -- ── Umbenennung 2026-08-01 (HearthstoneWoW → Arkana) ────────────────────────
    -- Die Ablage heißt jetzt ARKANA_*. WoW benennt die SavedVariables-DATEI nach dem
    -- Addon-Ordner, deshalb muss der Spieler vorher
    --   WTF\Account\<Konto>\SavedVariables\HearthstoneWoW.lua  →  Arkana.lua
    -- (und dieselbe Datei im Charakter-Ordner) umbenennen. Dann stehen beim Start
    -- noch die alten Globals hier und werden einmalig übernommen. Der Inhalt selbst
    -- ist unberührt. Das frühere kompakte Ablageformat wird beim ersten Start
    -- einmalig gelesen und anschließend transparent als normale Tabelle gespeichert.
    -- Kann entfernt werden, sobald alle Spieler einmal eingeloggt waren.
    if ARKANA_Version == nil and HSWOW_Version ~= nil then
        ARKANA_Version   = HSWOW_Version
        ARKANA_Settings  = HSWOW_Settings
        ARKANA_Decks     = HSWOW_Decks
        ARKANA_Stats     = HSWOW_Stats
        ARKANA_ActionLog = HSWOW_ActionLog
        print("|cff00ff00[Arkana]|r Alter Spielstand übernommen (Umbenennung HearthstoneWoW → Arkana).")
    end
    if ARKANA_CharData == nil and HSWOW_CharData ~= nil then
        ARKANA_CharData = HSWOW_CharData
    end

    -- Charakterdaten aus der Ablage holen, BEVOR irgendetwas ARKANA_CharData liest
    -- (Aliase, Migration und alle Module hängen daran).
    if addon._Store then addon._Store.read() end

    -- Abmelde-Schreiber SOFORT nach dem Lesen registrieren. Stand er am Ende von
    -- OnInitialize, kostete jeder Fehler weiter unten stillschweigend das Speichern:
    -- die Sitzung lief scheinbar normal, beim nächsten Anmelden war alles beim alten
    -- Stand (Tester: "Karten werden quasi nicht gespeichert"). _Store.write() prüft
    -- selbst, ob überhaupt gelesen wurde.
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("PLAYER_LOGOUT")
    ev:SetScript("OnEvent", function() if addon._Store then addon._Store.write() end end)

    -- Ablage nicht lesbar → NICHT weiterspielen, als wäre man ein neuer Charakter.
    -- Ohne diesen Hinweis sieht ein ungelesener Spielstand exakt aus wie ein leerer.
    if addon._Store and addon._Store.ready and not addon._Store.ready() then
        local function warn()
            print("|cffff0000[Arkana] Achtung:|r Dein Spielstand konnte nicht geladen werden. " ..
                  "Decks und Kosmetik erscheinen leer, sind aber noch da — es wird nichts überschrieben. " ..
                  "Bitte den Betreiber ansprechen und NICHT weiterspielen. (/arkana check)")
        end
        warn()
        C_Timer.After(20, warn)   -- der erste geht im Anmelde-Text unter
    end

    if not ARKANA_Version or ARKANA_Version < SCHEMA_VERSION then
        ARKANA_Version   = SCHEMA_VERSION
        ARKANA_Settings  = {}
        ARKANA_Decks     = {}
        ARKANA_Stats     = {}
        ARKANA_ActionLog = {}
    end

    for k, v in pairs(SETTINGS_DEFAULTS) do
        if ARKANA_Settings[k] == nil then ARKANA_Settings[k] = v end
    end
    ARKANA_Settings.theme = ThemeKey(ARKANA_Settings.theme)
    self:UI_SetTheme(ARKANA_Settings.theme)
    -- Veraltete Sperr- und Audit-Einträge nicht weiter mitschleppen.
    ARKANA_Settings.hsBanned = nil
    ARKANA_Settings.hsRevoked = nil
    ARKANA_Settings.witness = nil
    ARKANA_Settings.collectionWipe1 = nil
    ARKANA_Settings.dbOwnedOnly = nil
    ARKANA_Settings.rankedMode = nil
    ARKANA_Settings.rankTooltip = nil
    ARKANA_Settings.channel = nil
    ARKANA_Settings.debug = nil
    -- Entfernte Radar-Funktion: das frühere Opt-in ebenfalls aus der Ablage löschen.
    ARKANA_Settings.presenceOptIn = nil

    -- Absturz-Diagnose (Tester mit ERROR #132 im Duell): 3D-Zauber-Modelle
    -- (Projektile/Impacts, einzige nativen Modell-Loads im Duell) abschaltbar
    if ARKANA_Settings.spell3D == false then addon.USE_3D_SPELL_EFFECTS = false end

    -- ── Charakter-Bindung (2026-07-10): Decks, Statistik, ActionLog und aktives
    -- Deck liegen PRO CHARAKTER in ARKANA_CharData (wie Sammlung/Ranked/Kosmetik).
    -- Die account-weiten Globals bleiben in der .toc nur als Migrations-Quelle und
    -- werden hier auf die Char-Tabellen umgebogen (Alias). WICHTIG: die Globals
    -- danach NIE neu zuweisen — nur in-place ändern (wipe/insert), sonst reißt
    -- der Alias und Änderungen gehen beim Logout verloren!
    ARKANA_CharData = ARKANA_CharData or {}
    -- Frühere Vor-Rollback-Sicherungen werden nicht mehr benötigt.
    ARKANA_CharData.preRB = nil
    -- Veraltete Audit-Daten werden nicht mehr benötigt. Sammlung, Basispaket-
    -- Berechtigung und Booster bleiben dagegen charaktergebunden erhalten.
    ARKANA_CharData.prov = nil
    ARKANA_CharData.provSum = nil
    if ARKANA_CharData.decks == nil then
        if not ARKANA_Settings.charMigrationDone then
            -- EINMALIG account-weit (erster Char nach dem Update, i.d.R. der Main):
            -- Alt-Bestand übernehmen. Alle weiteren/neuen Chars starten LEER.
            ARKANA_CharData.decks           = ARKANA_Decks or {}
            ARKANA_CharData.stats           = ARKANA_Stats or {}
            ARKANA_CharData.actionLog       = ARKANA_ActionLog or {}
            ARKANA_CharData.activeDeckIndex = ARKANA_Settings.activeDeckIndex
        else
            ARKANA_CharData.decks = {}
        end
    end
    ARKANA_Settings.charMigrationDone = true
    ARKANA_CharData.stats     = ARKANA_CharData.stats or {}
    ARKANA_CharData.actionLog = ARKANA_CharData.actionLog or {}
    ARKANA_Decks     = ARKANA_CharData.decks
    ARKANA_Stats     = ARKANA_CharData.stats
    ARKANA_ActionLog = ARKANA_CharData.actionLog

    if not ARKANA_Stats.global then ARKANA_Stats.global = { w = 0, l = 0, d = 0 } end
    if not ARKANA_Stats.decks  then ARKANA_Stats.decks  = {} end

    -- ARKANA_CATALOG_HASH wird am Anfang von GameEngine.lua gesetzt (vor Runtime-Injektionen)

    self:RegisterComm(PREFIX)
    self:Info("|cff00ff00[Arkana]|r Arkana v0.1 geladen. /arkana für Befehle.")
end

SLASH_ARKANA1 = "/arkana"
SLASH_ARKANA2 = "/ark"
SlashCmdList["ARKANA"] = function(input)
    local args = {}
    for arg in input:gmatch("%S+") do args[#args + 1] = arg end
    local cmd = args[1]

    if cmd == "challenge" then
        if addon.ChallengeTarget then addon:ChallengeTarget() end
    elseif cmd == "sandbox" or cmd == "bot" or cmd == "botmatch" then
        if addon.Sandbox_Start then
            addon:Sandbox_Start(args[2])
        else
            print("|cffff0000[Arkana]|r Das Sandbox-Modul wurde nicht geladen. Bitte Addon-Dateien prüfen und /reload ausführen.")
        end
    elseif cmd == "spectate" or cmd == "watch" then
        local sub = args[2]
        if sub == "status" then
            if addon.Spec_Status then addon:Spec_Status() end
        elseif sub == "leave" or sub == "stop" then
            if addon.Spec_Leave then addon:Spec_Leave() end
        elseif sub == "lobby" or sub == "list" or not sub then
            if addon.Spec_EnsureChannel then addon:Spec_EnsureChannel() end
            if addon.Spec_ShowLobby then
                addon:Spec_ShowLobby()
            elseif addon.Spec_GetLobby then
                local list = addon:Spec_GetLobby()
                if #list == 0 then
                    print("|cff00ff00[Arkana]|r Keine laufenden Spiele gefunden (evtl. kurz warten, Aktualisierung etwa alle 10 Sekunden).")
                else
                    print("|cff00ff00[Arkana]|r Laufende Spiele:")
                    for _, g in ipairs(list) do
                        print(string.format("  |cffffd700%s|r  %s vs %s  (Zug %d)  →  /arkana spectate %s",
                            g.sessionId, g.hostName, g.oppName, g.turnNum, g.sessionId))
                    end
                end
            end
        else
            if addon.Spec_Watch then addon:Spec_Watch(sub) end
        end
    elseif cmd == "build" or cmd == "version" then
        print("|cff00ff00[Arkana]|r Build: " .. tostring(ARKANA_BUILD))
    elseif cmd == "check" then
        -- Diagnose: zeigt Ablagezustand, verfügbaren Katalog und gespeicherte Decks.
        local ok = not (Arkana._Store and Arkana._Store.ready) or Arkana._Store.ready()
        local n, kinds = 0, 0
        for id, card in pairs(ARKANA_CardData or {}) do
            if card.collectible == true then
                kinds = kinds + 1
                n = n + (addon.COL_Count and addon:COL_Count(id) or 0)
            end
        end
        print("|cff00ff00[Arkana]|r Build " .. tostring(ARKANA_BUILD) ..
              "  ·  Charakter: " .. tostring(UnitName("player")) ..
              "  ·  Ablage: " .. (ok and "|cff00ff00gelesen|r" or "|cffff0000nicht gelesen|r") ..
              "  ·  Verfügbar: " .. n .. " Karten (" .. kinds .. " verschiedene)" ..
              "  ·  Decks: " .. #(ARKANA_Decks or {}))
        if not ok then
            print("|cffff0000[Arkana]|r Der Spielstand wird in diesem Zustand nicht überschrieben. " ..
                  "Bitte diese Zeile dem Betreiber zeigen und nicht weiterspielen.")
        end
    elseif cmd == "msgs" then
        local sub = args[2]
        if sub == "on" then
            ARKANA_Settings.chatMsgs = true
            print("|cff00ff00[Arkana]|r Info-Meldungen: an")
        elseif sub == "off" then
            ARKANA_Settings.chatMsgs = false
            print("|cff00ff00[Arkana]|r Info-Meldungen: aus")
        else
            print("|cff00ff00[Arkana]|r Info-Meldungen sind " .. (ARKANA_Settings.chatMsgs and "an" or "aus") .. " (/arkana msgs on|off)")
        end
    elseif cmd == "skin" or cmd == "skins" then
        if addon.OpenCosmeticsMenu then addon:OpenCosmeticsMenu() end
    elseif cmd == "booster" or cmd == "boosters" then
        if addon.OpenBoosterWindow then addon:OpenBoosterWindow() end
    elseif cmd == "verteilung" then
        if addon.OpenAdminTool then addon:OpenAdminTool() end
    elseif cmd == "testkosmetik" or cmd == "testcosmetics" then
        if not addon.SEC_GrantAllTestCosmetics then
            print("|cffff0000[Arkana]|r Die Testkosmetik-Funktion ist nicht verfügbar.")
        else
            local ok, message = addon:SEC_GrantAllTestCosmetics()
            print((ok and "|cff00ff00[Arkana]|r " or "|cffff0000[Arkana]|r ") .. tostring(message))
        end
    elseif cmd == "settings" or cmd == "einstellungen" then
        if addon.ToggleScalePanel then addon:ToggleScalePanel() end
    elseif cmd == "3d" then
        local sub = args[2]
        if sub == "off" then
            ARKANA_Settings.spell3D = false
        elseif sub == "on" then
            ARKANA_Settings.spell3D = true
        end
        addon.USE_3D_SPELL_EFFECTS = ARKANA_Settings.spell3D ~= false
        print("|cff00ff00[Arkana]|r 3D-Zauber-Effekte: " .. (addon.USE_3D_SPELL_EFFECTS and "an" or "aus") .. " (/arkana 3d on|off — bei Spiel-Abstürzen im Duell testweise ausschalten)")
    elseif cmd == "tooltips" then
        local scale = tonumber(args[2])
        if scale and scale >= 0.1 and scale <= 2.0 then
            ARKANA_Settings.tooltipScale = scale
            print(string.format("|cff00ff00[Arkana]|r Tooltip-Skalierung auf %.2f gesetzt.", scale))
            Arkana:ApplyScales()
        else
            local current = ARKANA_Settings.tooltipScale or 1.0
            print(string.format("|cffff0000[Arkana]|r Verwendung: /arkana tooltips <0.1 - 2.0> (Aktuell: %.2f)", current))
        end
    elseif cmd == "reset" then
        Arkana:ResetUIPositions()
    else
        Arkana:OpenMainMenu()
    end
end

-- Skalierung auf bestehende Frames anwenden. windowScale steuert die Arkana-Menüs,
-- boardScale das Spielbrett und zugleich die Basisgröße der Karten-Tooltips.
function Arkana:ApplyScales()
    local s = ARKANA_Settings or {}
    local tip = (s.boardScale or 1.0) * (s.tooltipScale or 1.0)
    local a = s.boardAlpha or 1.0
    for frame in pairs(scalableFrames) do
        if frame and frame.SetScale then frame:SetScale(s.windowScale or 1.0) end
    end
    if ARKANA_GameBoard then ARKANA_GameBoard:SetScale(s.boardScale or 1.0); ARKANA_GameBoard:SetAlpha(a) end
    if _G["ARKANA_LogFrame"] then _G["ARKANA_LogFrame"]:SetAlpha(a) end
    if self.minionTooltip then self.minionTooltip:SetScale(tip); self.minionTooltip:SetAlpha(a) end
    if self.deckBuilderTooltip then self.deckBuilderTooltip:SetScale(tip); self.deckBuilderTooltip:SetAlpha(a) end
end

