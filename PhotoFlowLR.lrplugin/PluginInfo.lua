--[[
    PhotoFlow HDR — Plug-in Manager settings panel

    Registered via `LrPluginInfoProvider` in `Info.lua`. Adds a section to
    Lightroom's own "File > Plug-in Manager > PhotoFlow HDR" screen so the
    GUI-scripting wait times in `HDRMergeCore.lua` (previously only
    adjustable by editing that file or via Lightroom's Lua console — see
    Fas 4 in FORBATTRINGAR.md) can be tuned from inside Lightroom itself.

    Every control below binds straight to the plugin's `LrPrefs` table
    (`bind_to_object = prefs`) instead of copying values into a separate
    dialog-only property table and writing them back on `endDialog` — per
    the Lightroom SDK, `LrPrefs.prefsForPlugin()` tables are themselves
    bindable, so a change here is written to the real preference (and picked
    up by `HDRMergeCore.lua`'s next `LrTasks.sleep(...)` call, and by the
    background poller's next cycle) the moment the field loses focus /
    the checkbox is toggled — no OK/Apply button, nothing to forget to save.

    Lua 5.1 compatible (Lightroom's Lua runtime), no goto statements.
]]

local LrView = import 'LrView'
local LrPrefs = import 'LrPrefs'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local HDRMergeCore = require 'HDRMergeCore'

local prefs = LrPrefs.prefsForPlugin()
local bind = LrView.bind

local PluginInfo = {}

-- MARK: - Wait-time validation -------------------------------------------------
--
-- Mirrors `HDRMergeCore.lua`'s own `waitPref()` fallback (min/max, numbers
-- only) so the field visibly rejects/clamps bad input instead of silently
-- storing it — but that core-side fallback is the REAL safety net (it reads
-- straight from `LrPrefs` at merge time and has no dependency on this
-- dialog ever having been opened), so a mistake here can't hurt the HDR
-- merge itself, only annoy whoever's typing.
--
-- `validate`'s signature (`function(view, value) return isValid, valueToUse,
-- errorMessage end`) is standard `LrView` control behavior; not exercised
-- against a running Lightroom in this pass (see FORBATTRINGAR.md).
local function validateWaitSeconds(view, value)
    local n = tonumber(value)
    if not n then
        return false, value, "Ange ett tal (sekunder)."
    end
    if n < HDRMergeCore.MIN_WAIT_SECONDS then n = HDRMergeCore.MIN_WAIT_SECONDS end
    if n > HDRMergeCore.MAX_WAIT_SECONDS then n = HDRMergeCore.MAX_WAIT_SECONDS end
    return true, n
end

--- One "label — edit field — sekunder" row, bound directly to `prefs[key]`.
--
-- Note: clamping happens only in `validate` (called on every edit), not via
-- `min`/`max` keys on the `edit_field` itself — those are a real `LrView`
-- property on `slider`, but not confirmed as one for `edit_field` (see
-- FORBATTRINGAR.md), so relying only on the confirmed `validate` mechanism
-- avoids asserting an unverified API. `HDRMergeCore.lua`'s own `waitPref()`
-- clamps/falls back again at merge time regardless, independent of this UI.
local function waitRow(f, labelText, key)
    return f:row {
        spacing = 8,
        f:static_text {
            title = labelText,
            alignment = 'right',
            width = LrView.share "photoflow_wait_label_width",
        },
        f:edit_field {
            bind_to_object = prefs,
            value = bind(key),
            precision = 0,
            width_in_chars = 5,
            validate = validateWaitSeconds,
        },
        f:static_text {
            title = string.format("sekunder (%d–%d)", HDRMergeCore.MIN_WAIT_SECONDS, HDRMergeCore.MAX_WAIT_SECONDS),
        },
    }
end

-- MARK: - Status section --------------------------------------------------------
--
-- Reads the bridge folder's `lr_done.json` (written by `HDRMergeCore.
-- writeStatus`/`runOnce` at the end of the last merge run — see Fas 4) to
-- show a one-line summary of what happened last time, without requiring
-- Lightroom's own log file. Read-only, best-effort: any missing/unreadable/
-- unparsable file just falls back to a clear "no run yet" message rather
-- than an error, since this is purely informational.
local function readLastRunSummary()
    local dir = HDRMergeCore.bridgeDir()
    if not LrFileUtils.exists(dir) then
        return "Bryggmappen finns inte än: " .. dir ..
            "\n(Den skapas automatiskt första gången appen eller pluginet behöver den.)"
    end

    local donePath = LrPathUtils.child(dir, "lr_done.json")
    if not LrFileUtils.exists(donePath) then
        return "Ingen körning hittad än.\nBryggmapp: " .. dir
    end

    local file = io.open(donePath, "r")
    if not file then
        return "Kunde inte läsa senaste körningens statusfil.\nBryggmapp: " .. dir
    end
    local content = file:read("*all")
    file:close()

    local decoded = HDRMergeCore.decodeJSON(content)
    if type(decoded) ~= "table" or type(decoded.groups) ~= "number" then
        return "Senaste statusfilen kunde inte tolkas.\nBryggmapp: " .. dir
    end

    local ok = tonumber(decoded.ok) or 0
    local total = decoded.groups
    local failed = total - ok
    local line = string.format("Senaste körning: %d grupp(er), %d lyckades", total, ok)
    if failed > 0 then
        line = line .. string.format(", %d misslyckades", failed)
    end
    return line .. ".\nBryggmapp: " .. dir
end

-- MARK: - LrPluginInfoProvider entry point --------------------------------------

function PluginInfo.sectionsForTopOfDialog(f, propertyTable)
    local resetButton = f:push_button {
        title = "Återställ till standard",
        action = function()
            local confirm = LrDialogs.confirm(
                "Återställ väntetider till standard?",
                "Alla väntetider och pollningsinställningar återställs till PhotoFlows standardvärden.",
                "Återställ", "Avbryt"
            )
            if confirm == "ok" then
                HDRMergeCore.resetDefaults()
                LrDialogs.message("PhotoFlow HDR", "Standardvärden återställda.", "info")
            end
        end,
    }

    return {
        {
            title = "PhotoFlow HDR – väntetider för HDR-sammanslagning",
            synopsis = "Väntetider och pollning för GUI-scriptad HDR-sammanslagning",

            f:static_text {
                title = "PhotoFlow slår ihop HDR-brackets genom att styra Lightrooms " ..
                    "gränssnitt (Ctrl+H, sedan Enter) eftersom Lightrooms SDK saknar ett " ..
                    "eget API för HDR-sammanslagning. Är datorn/katalogen långsam en dag " ..
                    "kan för korta väntetider klippa sammanslagningen för tidigt — höj " ..
                    "värdena nedan om grupper misslyckas.",
                width_in_chars = 60,
                height_in_lines = 4,
            },
            f:spacer { height = 8 },

            waitRow(f, "Efter att HDR-dialogen öppnats:", "hdrPreviewWaitSeconds"),
            waitRow(f, "Efter Enter (medan Lightroom mergear):", "postMergeSettleSeconds"),
            waitRow(f, "Mellan grupper:", "betweenGroupsDelaySeconds"),
            waitRow(f, "Efter att bilderna valts (innan Ctrl+H):", "selectSettleDelaySeconds"),

            f:spacer { height = 8 },
            f:row {
                f:checkbox {
                    bind_to_object = prefs,
                    title = "Pollning efter trigger-fil aktiverad",
                    value = bind "pollingEnabled",
                },
            },
            f:row {
                spacing = 8,
                f:static_text {
                    title = "Pollintervall:",
                    alignment = 'right',
                    width = LrView.share "photoflow_wait_label_width",
                },
                f:edit_field {
                    bind_to_object = prefs,
                    value = bind "pollIntervalSeconds",
                    precision = 0,
                    width_in_chars = 5,
                    -- `bind_to_object` above is a per-table default: every
                    -- plain `bind '<key>'` shorthand used anywhere in THIS
                    -- widget's spec (both `value` and `enabled` here)
                    -- resolves against `prefs`, not just the first one.
                    enabled = bind "pollingEnabled",
                    validate = validateWaitSeconds,
                },
                f:static_text {
                    title = string.format("sekunder (%d–%d)", HDRMergeCore.MIN_WAIT_SECONDS, HDRMergeCore.MAX_WAIT_SECONDS),
                },
            },

            f:spacer { height = 8 },
            f:row { resetButton },
        },
        {
            title = "PhotoFlow HDR – senaste körning",
            synopsis = "Status för senaste HDR-sammanslagningen",

            f:static_text {
                title = readLastRunSummary(),
                width_in_chars = 60,
                height_in_lines = 3,
            },
        },
    }
end

return PluginInfo
