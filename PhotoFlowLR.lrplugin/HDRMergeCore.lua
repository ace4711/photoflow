--[[
    PhotoFlow HDR Merge — shared core logic (Fas 4)

    Used by BOTH RunHDRMerge.lua (the manual "Kör HDR-sammanslagning från
    PhotoFlow" Library menu item) and InitPlugin.lua's background poller, so
    they behave identically. Previously all of this lived only in
    RunHDRMerge.lua and had to be run manually every time — the app's log
    line "Pluginet auto-pollar var 5:e sekund" was aspirational, not real.
    InitPlugin.lua now actually starts a polling loop that calls
    `M.runOnce({ showDialogIfMissing = false })` every `M.pollIntervalSeconds()`
    seconds, making that log line true.

    Lua 5.1 compatible (Lightroom's Lua runtime), no goto statements.
]]

local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrLogger = import 'LrLogger'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope = import 'LrProgressScope'
local LrPrefs = import 'LrPrefs'

local logger = LrLogger('PhotoFlowHDR')
logger:enable("print")

local M = {}

-- MARK: - Bridge folder ------------------------------------------------------
--
-- Must match `PipelineRunner+Lightroom.swift`'s `lightroomBridgeDirectory`
-- exactly. Previously the app used `NSTemporaryDirectory()` and the plugin
-- used `LrPathUtils.getStandardFilePath("temp")` — on an unsandboxed setup
-- those happen to resolve to the same per-user $TMPDIR, but that's an
-- assumption about both processes' environments, not a guarantee (different
-- launch contexts/macOS versions can hand out different $TMPDIR values).
-- Both sides now use this fixed, well-known location instead, removing the
-- ambiguity entirely.
local function bridgeDir()
    local home = LrPathUtils.getStandardFilePath("home")
    local dir = LrPathUtils.child(LrPathUtils.child(home, "Library"), "Application Support")
    dir = LrPathUtils.child(dir, "PhotoFlow")
    if not LrFileUtils.exists(dir) then
        LrFileUtils.createAllDirectories(dir)
    end
    return dir
end

function M.triggerPath() return LrPathUtils.child(bridgeDir(), "lr_trigger.json") end
function M.statusPath() return LrPathUtils.child(bridgeDir(), "lr_status.json") end
function M.donePath() return LrPathUtils.child(bridgeDir(), "lr_done.json") end

-- MARK: - Configurable wait times ---------------------------------------------
--
-- Backed by `LrPrefs` (persists in Lightroom's own plugin preferences) so
-- they're adjustable without editing this file — e.g. from Lightroom's
-- File > Plug-in Extras > Plug-in Manager > "PhotoFlow HDR" > "Lua console"-
-- style tooling, or a future Plug-in Manager settings panel could read/write
-- the same keys. A full custom `sectionsForTopOfDialog` settings screen
-- wasn't built in this pass — it can't be exercised without a running
-- Lightroom instance to click through, and shipping untested LrView dialog
-- code seemed riskier than these safely-defaulted, still-adjustable prefs.
local prefs = LrPrefs.prefsForPlugin()

local function pref(name, default)
    if prefs[name] == nil then
        prefs[name] = default
    end
    return prefs[name]
end

function M.pollIntervalSeconds() return pref("pollIntervalSeconds", 5) end
function M.selectSettleDelaySeconds() return pref("selectSettleDelaySeconds", 1) end
function M.hdrPreviewWaitSeconds() return pref("hdrPreviewWaitSeconds", 5) end
function M.postMergeSettleSeconds() return pref("postMergeSettleSeconds", 8) end
function M.betweenGroupsDelaySeconds() return pref("betweenGroupsDelaySeconds", 2) end

-- MARK: - Minimal JSON decoder -------------------------------------------------
--
-- Replaces the old regex-based `parseJSON`, which searched for literal
-- `"group_id"`/`"files"`/`"output_dir"` substrings with Lua %-patterns —
-- it only worked by accident for the exact shape the app happened to write,
-- and would silently mis-parse anything else (e.g. a file path containing
-- the substring `"files"`, or reordered/pretty-printed keys). This is a
-- small, real recursive-descent JSON decoder (object/array/string/number/
-- bool/null, string escapes including \uXXXX) — decode-only, which is all
-- the plugin needs. Verified against real trigger-file JSON (as written by
-- `JSONSerialization` in `PipelineRunner+Lightroom.swift`) with a standalone
-- Lua interpreter outside Lightroom during development — see
-- FORBATTRINGAR.md, Fas 4.
local function jsonError(str, pos, msg)
    error(string.format("JSON-fel vid position %d: %s (...%s...)", pos, msg, str:sub(math.max(1, pos - 20), pos + 20)))
end

local function skipWhitespace(str, pos)
    local _, e = str:find("^[ \t\r\n]*", pos)
    return e + 1
end

local decodeValue -- forward declaration (mutually recursive with array/object)

local function decodeString(str, pos)
    -- pos points at the opening quote.
    local out = {}
    local i = pos + 1
    while true do
        local c = str:sub(i, i)
        if c == "" then
            jsonError(str, i, "oavslutad sträng")
        elseif c == '"' then
            return table.concat(out), i + 1
        elseif c == "\\" then
            local esc = str:sub(i + 1, i + 1)
            if esc == '"' then out[#out + 1] = '"'; i = i + 2
            elseif esc == "\\" then out[#out + 1] = "\\"; i = i + 2
            elseif esc == "/" then out[#out + 1] = "/"; i = i + 2
            elseif esc == "b" then out[#out + 1] = "\b"; i = i + 2
            elseif esc == "f" then out[#out + 1] = "\f"; i = i + 2
            elseif esc == "n" then out[#out + 1] = "\n"; i = i + 2
            elseif esc == "r" then out[#out + 1] = "\r"; i = i + 2
            elseif esc == "t" then out[#out + 1] = "\t"; i = i + 2
            elseif esc == "u" then
                local hex = str:sub(i + 2, i + 5)
                local code = tonumber(hex, 16)
                if not code then jsonError(str, i, "ogiltig \\u-sekvens") end
                -- Trigger JSON only ever contains file paths and short
                -- strings — BMP codepoints re-encoded as UTF-8 is enough, no
                -- surrogate-pair handling for codepoints beyond \uFFFF.
                if code < 0x80 then
                    out[#out + 1] = string.char(code)
                elseif code < 0x800 then
                    out[#out + 1] = string.char(0xC0 + math.floor(code / 0x40), 0x80 + (code % 0x40))
                else
                    out[#out + 1] = string.char(
                        0xE0 + math.floor(code / 0x1000),
                        0x80 + (math.floor(code / 0x40) % 0x40),
                        0x80 + (code % 0x40)
                    )
                end
                i = i + 6
            else
                jsonError(str, i, "okänd escape-sekvens \\" .. esc)
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
end

local function decodeNumber(str, pos)
    local s, e = str:find("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
    if not s then jsonError(str, pos, "ogiltigt tal") end
    return tonumber(str:sub(s, e)), e + 1
end

local function decodeArray(str, pos)
    local arr = {}
    local i = skipWhitespace(str, pos + 1)
    if str:sub(i, i) == "]" then return arr, i + 1 end
    while true do
        local value
        value, i = decodeValue(str, i)
        arr[#arr + 1] = value
        i = skipWhitespace(str, i)
        local c = str:sub(i, i)
        if c == "," then
            i = skipWhitespace(str, i + 1)
        elseif c == "]" then
            return arr, i + 1
        else
            jsonError(str, i, "väntade ',' eller ']'")
        end
    end
end

local function decodeObject(str, pos)
    local obj = {}
    local i = skipWhitespace(str, pos + 1)
    if str:sub(i, i) == "}" then return obj, i + 1 end
    while true do
        if str:sub(i, i) ~= '"' then jsonError(str, i, "väntade en nyckel-sträng") end
        local key
        key, i = decodeString(str, i)
        i = skipWhitespace(str, i)
        if str:sub(i, i) ~= ":" then jsonError(str, i, "väntade ':'") end
        i = skipWhitespace(str, i + 1)
        local value
        value, i = decodeValue(str, i)
        obj[key] = value
        i = skipWhitespace(str, i)
        local c = str:sub(i, i)
        if c == "," then
            i = skipWhitespace(str, i + 1)
        elseif c == "}" then
            return obj, i + 1
        else
            jsonError(str, i, "väntade ',' eller '}'")
        end
    end
end

decodeValue = function(str, pos)
    local i = skipWhitespace(str, pos)
    local c = str:sub(i, i)
    if c == '"' then return decodeString(str, i)
    elseif c == "{" then return decodeObject(str, i)
    elseif c == "[" then return decodeArray(str, i)
    elseif c == "t" and str:sub(i, i + 3) == "true" then return true, i + 4
    elseif c == "f" and str:sub(i, i + 4) == "false" then return false, i + 5
    elseif c == "n" and str:sub(i, i + 3) == "null" then return nil, i + 4
    elseif c:match("[%-%d]") then return decodeNumber(str, i)
    else jsonError(str, i, "oväntat tecken '" .. c .. "'") end
end

--- Returns `nil, errorMessage` on any parse failure instead of throwing, so
--- callers can show a clean dialog/log line rather than an uncaught Lua error.
function M.decodeJSON(str)
    local ok, result = pcall(function() return decodeValue(str, 1) end)
    if ok then return result, nil end
    return nil, tostring(result)
end

-- MARK: - Trigger parsing -------------------------------------------------

--- Extracts the subset of the decoded JSON this plugin actually needs —
--- `{groups: [{group_id, files, output_dir}, ...]}` — skipping any
--- malformed group instead of aborting the whole batch (same tolerant
--- behavior the old regex parser had, just for real reasons now instead of
--- by accident).
function M.parseTrigger(content)
    local decoded, err = M.decodeJSON(content)
    if not decoded then
        return nil, "Kunde inte tolka trigger-filen som JSON: " .. tostring(err)
    end
    if type(decoded) ~= "table" or type(decoded.groups) ~= "table" then
        return nil, "Trigger-filen saknar ett giltigt \"groups\"-fält"
    end

    local groups = {}
    for _, rawGroup in ipairs(decoded.groups) do
        if type(rawGroup) == "table" and type(rawGroup.files) == "table" then
            local files = {}
            for _, f in ipairs(rawGroup.files) do
                if type(f) == "string" then files[#files + 1] = f end
            end
            if #files >= 2 then
                groups[#groups + 1] = {
                    group_id = tonumber(rawGroup.group_id) or (#groups + 1),
                    files = files,
                    output_dir = type(rawGroup.output_dir) == "string" and rawGroup.output_dir or ""
                }
            end
        end
    end
    return { groups = groups }, nil
end

-- MARK: - Status file ---------------------------------------------------------

local function writeStatus(status, results)
    local file = io.open(M.statusPath(), "w")
    if file then
        file:write('{"status":"' .. status .. '","results":[')
        if results then
            local parts = {}
            for _, r in ipairs(results) do
                local msg = (r.message or ""):gsub('"', '\\"'):gsub('\n', '\\n')
                table.insert(parts,
                    '{"group_id":' .. r.group_id ..
                    ',"status":"' .. r.status ..
                    '","message":"' .. msg .. '"}'
                )
            end
            file:write(table.concat(parts, ","))
        end
        file:write(']}')
        file:close()
    end
end

-- MARK: - HDR merge via GUI scripting -----------------------------------------
--
-- The Lightroom SDK has no API for triggering an HDR photo merge — this
-- keeps the same GUI-scripting approach (select the photos, send Ctrl+H,
-- wait for the merge preview dialog, press Return) as before, just with the
-- wait times pulled from `M.*Seconds()` instead of hardcoded, and clearer
-- trace logging at each stage so a stuck/slow merge is visible in
-- Lightroom's own log (`~/Library/Application Support/Adobe/Lightroom/
-- lrc_console.log`, via `LrLogger:enable("print")`) instead of just silently
-- taking longer than expected.
local function processGroup(catalog, group, groupIndex, totalGroups, progress)
    progress:setCaption("Grupp " .. groupIndex .. "/" .. totalGroups)
    logger:trace("Grupp " .. group.group_id .. ": " .. #group.files .. " fil(er)")

    local validFiles = {}
    for _, filePath in ipairs(group.files) do
        if LrFileUtils.exists(filePath) then
            table.insert(validFiles, filePath)
        else
            logger:warn("Hittades inte: " .. filePath)
        end
    end

    if #validFiles < 2 then
        return { group_id = group.group_id, status = "error", message = "För få filer: " .. #validFiles }
    end

    local photos = {}
    local importErr = nil

    local writeOK, writeErr = LrTasks.pcall(function()
        catalog:withWriteAccessDo("PhotoFlow Import " .. groupIndex, function()
            for _, filePath in ipairs(validFiles) do
                local addOK, photo = LrTasks.pcall(function()
                    return catalog:addPhoto(filePath)
                end)

                if addOK and photo then
                    table.insert(photos, photo)
                    logger:trace("Lade till: " .. LrPathUtils.leafName(filePath))
                else
                    local findOK, existing = LrTasks.pcall(function()
                        return catalog:findPhotoByPath(filePath)
                    end)
                    if findOK and existing then
                        table.insert(photos, existing)
                        logger:trace("Fanns redan: " .. LrPathUtils.leafName(filePath))
                    else
                        importErr = tostring(addOK and "nil" or photo)
                        logger:warn("Misslyckades: " .. filePath .. " - " .. tostring(importErr))
                    end
                end
            end
        end)
    end)

    if not writeOK then
        importErr = tostring(writeErr)
        logger:warn("withWriteAccessDo misslyckades: " .. importErr)
    end

    logger:trace("Grupp " .. group.group_id .. ": " .. #photos .. " foton importerade")

    if #photos < 2 then
        return { group_id = group.group_id, status = "error",
            message = "Import gav " .. #photos .. " foton. Fel: " .. (importErr or "okänt") }
    end

    local selOK, selErr = LrTasks.pcall(function()
        catalog:setSelectedPhotos(photos[1], photos)
    end)

    if not selOK then
        return { group_id = group.group_id, status = "error",
            message = "Val misslyckades: " .. tostring(selErr) }
    end

    LrTasks.yield()
    LrTasks.sleep(M.selectSettleDelaySeconds())

    -- Trigger HDR Merge via Ctrl+H
    local mergeOK, mergeErr = LrTasks.pcall(function()
        LrTasks.execute(
            'osascript -e \'tell application "System Events" to tell process ' ..
            '"Adobe Lightroom Classic" to keystroke "h" using {control down}\''
        )
    end)

    if not mergeOK then
        return { group_id = group.group_id, status = "error", message = "HDR-genväg: " .. tostring(mergeErr) }
    end

    logger:trace("Grupp " .. group.group_id .. ": väntar " .. M.hdrPreviewWaitSeconds() .. "s på HDR-förhandsvisningen")
    LrTasks.sleep(M.hdrPreviewWaitSeconds())
    LrTasks.pcall(function()
        LrTasks.execute(
            'osascript -e \'tell application "System Events" to tell process ' ..
            '"Adobe Lightroom Classic" to keystroke return\''
        )
    end)
    logger:trace("Grupp " .. group.group_id .. ": väntar " .. M.postMergeSettleSeconds() .. "s på att sammanslagningen ska bli klar")
    LrTasks.sleep(M.postMergeSettleSeconds())

    return { group_id = group.group_id, status = "ok", message = "HDR utlöst för " .. #photos .. " foton" }
end

-- MARK: - Entry point ----------------------------------------------------------

--- Checks for a trigger file and, if present, processes every group in it —
--- this is the single code path both the manual menu item and the
--- background poller call.
---
--- `opts.showDialogIfMissing`: show a Lightroom dialog when there's no
--- trigger file (or it's invalid) — on for the manual menu item (the user
--- explicitly asked and expects feedback), off for the background poller
--- (silently do nothing most of the time; the app already reports success/
--- failure on its own side by polling `M.donePath()`).
--- `opts.showSummaryDialog`: show the "N mergade, N misslyckades" summary
--- dialog when done — same reasoning, on for manual, off for the poller.
---
--- Returns `true` if a trigger was found and processed (regardless of
--- individual group success/failure), `false` if there was nothing to do.
function M.runOnce(opts)
    opts = opts or {}
    local triggerPath = M.triggerPath()

    if not LrFileUtils.exists(triggerPath) then
        if opts.showDialogIfMissing then
            LrDialogs.message("PhotoFlow HDR", "Ingen HDR-trigger hittades.\n\nSökte: " .. triggerPath, "info")
        end
        return false
    end

    local file = io.open(triggerPath, "r")
    if not file then
        logger:warn("Kunde inte öppna trigger-filen: " .. triggerPath)
        if opts.showDialogIfMissing then
            LrDialogs.showError("Kunde inte läsa: " .. triggerPath)
        end
        return false
    end
    local content = file:read("*all")
    file:close()

    local trigger, parseErr = M.parseTrigger(content)
    if not trigger or #trigger.groups == 0 then
        logger:warn("Ogiltig eller tom trigger-fil: " .. tostring(parseErr))
        if opts.showDialogIfMissing then
            LrDialogs.showError((parseErr or "Inga giltiga grupper.") .. "\n\n" .. content:sub(1, 500))
        end
        return false
    end

    logger:trace("Bearbetar trigger med " .. #trigger.groups .. " grupp(er) från " .. triggerPath)

    local totalGroups = #trigger.groups
    local catalog = LrApplication.activeCatalog()
    local results = {}

    LrFunctionContext.callWithContext("PhotoFlowHDR", function(context)
        local progress = LrProgressScope({
            title = "PhotoFlow HDR",
            functionContext = context,
        })

        for i, group in ipairs(trigger.groups) do
            if progress:isCanceled() then
                table.insert(results, { group_id = group.group_id, status = "cancelled", message = "Avbrutet av användaren" })
                break
            end

            progress:setPortionComplete(i - 1, totalGroups)
            local result = processGroup(catalog, group, i, totalGroups, progress)
            table.insert(results, result)
            logger:trace("Grupp " .. group.group_id .. " resultat: " .. result.status .. " — " .. result.message)

            LrTasks.sleep(M.betweenGroupsDelaySeconds())
        end

        progress:done()
    end)

    writeStatus("complete", results)
    LrFileUtils.delete(triggerPath)

    local okCount, errCount = 0, 0
    for _, r in ipairs(results) do
        if r.status == "ok" then okCount = okCount + 1
        else errCount = errCount + 1 end
    end

    local doneFile = io.open(M.donePath(), "w")
    if doneFile then
        doneFile:write('{"status":"complete","groups":' .. totalGroups .. ',"ok":' .. okCount .. '}')
        doneFile:close()
    end

    logger:trace(string.format("Klar: %d/%d grupper mergade", okCount, totalGroups))

    if opts.showSummaryDialog then
        LrDialogs.message("PhotoFlow HDR", okCount .. " grupper mergade, " .. errCount .. " misslyckades.", "info")
    end

    return true
end

return M
