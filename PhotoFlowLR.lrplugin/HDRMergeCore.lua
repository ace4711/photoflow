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
local LrExportSession = import 'LrExportSession'

local logger = LrLogger('PhotoFlowHDR')
logger:enable("print")

local M = {}

--- Pluginversion (samma som Info.lua) — skrivs i lr_status.json så att appen/CLI:t ser vilken
--- version som kördes.
M.VERSION = "1.4"

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
--- Pure path computation, no filesystem side effects — safe to call from a
--- read-only context like the Plug-in Manager settings panel, where
--- creating the folder just because someone opened the panel would make
--- "the bridge folder doesn't exist yet" impossible to ever observe.
local function bridgeDirPath()
    local home = LrPathUtils.getStandardFilePath("home")
    local dir = LrPathUtils.child(LrPathUtils.child(home, "Library"), "Application Support")
    return LrPathUtils.child(dir, "PhotoFlow")
end

local function bridgeDir()
    local dir = bridgeDirPath()
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
-- they're adjustable without editing this file. `PluginInfo.lua` now gives
-- the user a real Plug-in Manager settings panel
-- (File > Plug-in Manager > "PhotoFlow HDR") that binds directly to these
-- same `LrPrefs` keys via `LrView`/`LrBinding`, so changes made there save
-- immediately — no separate "apply"/OK step, and no code edit required.
--
-- `M.DEFAULTS` is the single source of truth for default values AND for
-- what "invalid" means: every getter below re-reads `prefs[name]` at call
-- time (never cached at require-time — `require` only runs once per
-- Lightroom session, so a module-level cache would freeze whatever value
-- was live when the plugin first loaded) and falls back to the default
-- whenever the stored value is missing, not a number, or outside
-- `MIN_WAIT_SECONDS`..`MAX_WAIT_SECONDS`. That fallback is what makes a
-- zero/garbage pref safe: it can never make `processGroup` skip a wait
-- outright, only use the same safe default it would use if the pref had
-- never been set. `M.pollingEnabled()` follows the same live-read pattern
-- for its boolean pref.
local prefs = LrPrefs.prefsForPlugin()

M.MIN_WAIT_SECONDS = 1
M.MAX_WAIT_SECONDS = 60

M.DEFAULTS = {
    pollIntervalSeconds = 5,
    selectSettleDelaySeconds = 1,
    hdrPreviewWaitSeconds = 5,
    postMergeSettleSeconds = 8,
    betweenGroupsDelaySeconds = 2,
    pollingEnabled = true,
}

-- Names of the numeric wait-time prefs, in the order they run during a
-- merge — used both by `waitPref`'s validation and by `M.resetDefaults()`.
local WAIT_PREF_NAMES = {
    "pollIntervalSeconds", "selectSettleDelaySeconds", "hdrPreviewWaitSeconds",
    "postMergeSettleSeconds", "betweenGroupsDelaySeconds",
}

local function waitPref(name)
    local value = prefs[name]
    if type(value) ~= "number" or value < M.MIN_WAIT_SECONDS or value > M.MAX_WAIT_SECONDS then
        return M.DEFAULTS[name]
    end
    return value
end

function M.pollIntervalSeconds() return waitPref("pollIntervalSeconds") end
function M.selectSettleDelaySeconds() return waitPref("selectSettleDelaySeconds") end
function M.hdrPreviewWaitSeconds() return waitPref("hdrPreviewWaitSeconds") end
function M.postMergeSettleSeconds() return waitPref("postMergeSettleSeconds") end
function M.betweenGroupsDelaySeconds() return waitPref("betweenGroupsDelaySeconds") end

--- Whether the background poller (`InitPlugin.lua`) should actually check
--- for a trigger file each cycle. Defaults to on (today's behavior). A
--- non-boolean stored value (shouldn't normally happen, but a corrupted
--- prefs.lua or a future migration bug could produce one) falls back to
--- the default rather than being treated as truthy/falsy by accident.
function M.pollingEnabled()
    local value = prefs.pollingEnabled
    if type(value) ~= "boolean" then return M.DEFAULTS.pollingEnabled end
    return value
end

--- Resets every setting exposed in the Plug-in Manager panel back to its
--- default. Used by that panel's "Återställ till standard" button; also
--- handy from Lightroom's Lua console for support/debugging.
function M.resetDefaults()
    for _, name in ipairs(WAIT_PREF_NAMES) do
        prefs[name] = M.DEFAULTS[name]
    end
    prefs.pollingEnabled = M.DEFAULTS.pollingEnabled
end

--- Exposes the bridge directory path (shared with `PipelineRunner+Lightroom.
--- swift`) for the settings panel's status section. Deliberately the
--- non-creating `bridgeDirPath()`, not `bridgeDir()` — the settings panel
--- only reads/displays this, and must be able to tell the user the folder
--- doesn't exist yet, which `bridgeDir()`'s create-on-access behavior would
--- make impossible to ever see.
function M.bridgeDir() return bridgeDirPath() end

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
                    output_dir = type(rawGroup.output_dir) == "string" and rawGroup.output_dir or "",
                    -- Experimentläget (docs/plan-hdr-jamforelse.md, avsnitt 4):
                    id = type(rawGroup.id) == "string" and rawGroup.id or nil,
                    export_dir = type(rawGroup.export_dir) == "string" and rawGroup.export_dir or nil,
                }
            end
        end
    end
    return {
        groups = groups,
        mode = decoded.mode == "experiment" and "experiment" or "normal",
        export_format = decoded.export_format == "JPEG" and "JPEG" or "TIFF",
        -- false = hoppa över Ctrl+Shift+H och använd bara Ctrl+H + Retur.
        headless = decoded.headless ~= false,
    }, nil
end

-- MARK: - Status file ---------------------------------------------------------

local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

--- Riktig JSON-kodare (ersätter den gamla som bara escapade `"` och `\n`): strängar escapas
--- fullständigt (citattecken, backslash, styrtecken som \u00XX), icke-ändliga tal blir null,
--- tabeller med 1..n-nycklar (och tomma tabeller) blir arrayer, övriga objekt med sorterade
--- nycklar. UTF-8 skickas vidare oförändrat.
local function encodeJSON(value)
    local t = type(value)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return value and "true" or "false"
    elseif t == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return "null" end
        if value == math.floor(value) and math.abs(value) < 1e15 then return string.format("%d", value) end
        return string.format("%.10g", value)
    elseif t == "string" then
        local escaped = value:gsub('[%c"\\]', function(c)
            return ESCAPES[c] or string.format("\\u%04x", c:byte())
        end)
        return '"' .. escaped .. '"'
    elseif t == "table" then
        local parts = {}
        local n = #value
        if n > 0 or next(value) == nil then
            for i = 1, n do parts[#parts + 1] = encodeJSON(value[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(value) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            parts[#parts + 1] = encodeJSON(k) .. ":" .. encodeJSON(value[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

M.encodeJSON = encodeJSON

--- Skriver `lr_status.json`: `{status, plugin_version, results:[…]}`. Resultatobjekten får vara
--- vilka tabeller som helst (i experimentläget även id, export, dng och develop).
local function writeStatus(status, results)
    local file = io.open(M.statusPath(), "w")
    if file then
        file:write(encodeJSON({ status = status, plugin_version = M.VERSION, results = results or {} }))
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

-- MARK: - Experimentläge (docs/plan-hdr-jamforelse.md, avsnitt 4) ----------------------
--
-- Som det normala flödet, men: (1) väntar på att Lightrooms `<ram>-HDR.dng` faktiskt dyker upp i
-- källmappen (polling) i stället för fasta väntetider, (2) provar först den huvudlösa
-- genvägen Ctrl+Skift+H (sammanslagning med senaste inställningarna, ingen dialog) och faller
-- tillbaka på Ctrl+H + Retur, (3) exporterar resultatet med Lightrooms egen exportmotor som
-- 16-bitars sRGB-TIFF ("lr-auto") och (4) rapporterar framkallningsinställningarna och
-- DNG-sökvägen i statusen, så att man ser om Auto Settings verkligen användes.

M.HEADLESS_TIMEOUT_SECONDS = 90
M.DIALOG_TIMEOUT_SECONDS = 120
M.FIND_PHOTO_TIMEOUT_SECONDS = 30

-- Inställningar som är intressanta att jämföra (Auto Settings sätter dem).
local DEVELOP_KEYS = {
    "ProcessVersion", "CameraProfile", "WhiteBalance", "Temperature", "Tint",
    "Exposure2012", "Contrast2012", "Highlights2012", "Shadows2012", "Whites2012", "Blacks2012",
    "Texture", "Clarity2012", "Dehaze", "Vibrance", "Saturation",
}

local LR_PROCESS = "Adobe Lightroom Classic"

local function osascript(script)
    return LrTasks.pcall(function()
        LrTasks.execute("osascript -e '" .. script .. "'")
    end)
end

local function activateLightroom()
    osascript('tell application "' .. LR_PROCESS .. '" to activate')
end

local function sendKeys(keystrokeScript)
    return osascript('tell application "System Events" to tell process "' .. LR_PROCESS .. '" to ' .. keystrokeScript)
end

--- Väntar (i AppleScript, högst `timeoutSeconds`) tills HDR-dialogens förhandsvisning är klar
--- ("… successfully merged" och Merge aktiv) och klickar Merge. En fast väntan följd av Retur
--- räckte inte för stora grupper: med 11 ramar var förhandsvisningen inte klar efter 5 s, Retur
--- föll bort och dialogen blev stående (provkört 2026-10-18). Returnerar true om Merge klickades.
local function clickMergeWhenReady(timeoutSeconds)
    local script = table.concat({
        'tell application "System Events" to tell process "' .. LR_PROCESS .. '"',
        '  repeat ' .. math.floor(timeoutSeconds) .. ' times',
        '    if exists window "HDR Merge Preview" then',
        '      set w to window "HDR Merge Preview"',
        '      set t to ""',
        '      repeat with s in (every static text of w)',
        '        set t to t & (value of s as text)',
        '      end repeat',
        '      if t contains "successfully merged" and (enabled of button "Merge" of w) then',
        '        click button "Merge" of w',
        '        return',
        '      end if',
        '    end if',
        '    delay 1',
        '  end repeat',
        'end tell',
        'error "Merge inte klickad"',
    }, "\n")
    local ok, status = LrTasks.pcall(function()
        return LrTasks.execute("osascript -e '" .. script .. "'")
    end)
    return ok and status == 0
end

--- Mängden `*-HDR*.dng` i en mapp (sökväg → true).
local function hdrDngsIn(dir)
    local found = {}
    for path in LrFileUtils.files(dir) do
        local leaf = LrPathUtils.leafName(path):lower()
        if leaf:match("%-hdr[^/]*%.dng$") then found[path] = true end
    end
    return found
end

local function fileSize(path)
    local attrs = LrFileUtils.fileAttributes(path)
    return attrs and attrs.fileSize or nil
end

--- Pollar tills en ny `*-HDR*.dng` finns i `dir` (jämfört med `before`) och har slutat växa.
--- Returnerar sökvägen eller nil vid tidsgräns.
local function waitForNewDng(dir, before, timeoutSeconds)
    local waited = 0
    while waited < timeoutSeconds do
        LrTasks.sleep(1)
        waited = waited + 1
        for path in pairs(hdrDngsIn(dir)) do
            if not before[path] then
                -- Klar när storleken är oförändrad i två avläsningar med en sekunds mellanrum.
                local size = fileSize(path)
                LrTasks.sleep(1)
                waited = waited + 1
                if size and size > 0 and size == fileSize(path) then return path end
            end
        end
    end
    return nil
end

local function findPhotoInCatalog(catalog, path)
    local waited = 0
    while waited < M.FIND_PHOTO_TIMEOUT_SECONDS do
        local ok, photo = LrTasks.pcall(function() return catalog:findPhotoByPath(path) end)
        if ok and photo then return photo end
        LrTasks.sleep(1)
        waited = waited + 1
    end
    return nil
end

local function readDevelopSettings(photo)
    local ok, settings = LrTasks.pcall(function() return photo:getDevelopSettings() end)
    local out = {}
    if ok and type(settings) == "table" then
        for _, key in ipairs(DEVELOP_KEYS) do
            local value = settings[key]
            if type(value) == "number" or type(value) == "string" or type(value) == "boolean" then
                out[key] = value
            end
        end
    end
    return out
end

--- Exporterar `photo` med Lightrooms egen exportmotor: 16-bitars sRGB-TIFF (eller JPEG),
--- ingen storleksbegränsning, ingen utskärpning, filnamn `lr-auto`. Returnerar filens sökväg.
local function exportPhoto(photo, exportDir, format)
    LrFileUtils.createAllDirectories(exportDir)
    local extensions = format == "JPEG" and { "jpg", "jpeg" } or { "tif", "tiff" }
    for _, ext in ipairs(extensions) do
        LrFileUtils.delete(LrPathUtils.child(exportDir, "lr-auto." .. ext))
    end
    local settings = {
        LR_export_destinationType = "specificFolder",
        LR_export_destinationPathPrefix = exportDir,
        LR_export_useSubfolder = false,
        LR_format = format,
        LR_size_doConstrain = false,
        LR_outputSharpeningOn = false,
        LR_renamingTokensOn = true,
        LR_tokens = "lr-auto",
        LR_collisionHandling = "overwrite",
        LR_reimportExportedPhoto = false,
        LR_export_colorSpace = "sRGB",
    }
    if format == "JPEG" then
        settings.LR_jpeg_quality = 1
    else
        settings.LR_export_bitDepth = 16
    end
    local session = LrExportSession({ photosToExport = { photo }, exportSettings = settings })
    session:doExportOnCurrentTask()
    for _, ext in ipairs(extensions) do
        local path = LrPathUtils.child(exportDir, "lr-auto." .. ext)
        if LrFileUtils.exists(path) then return path end
    end
    return nil
end

--- Sammanslagningen för en grupp i experimentläget. `photos` är redan importerade och markerade.
local function experimentMerge(catalog, group, photos, trigger, firstFile)
    local started = os.time()
    local label = group.id or tostring(group.group_id)
    local result = { group_id = group.group_id, id = group.id, status = "error", message = "" }
    local sourceDir = LrPathUtils.parent(firstFile)
    local before = hdrDngsIn(sourceDir)
    local dngPath = nil

    activateLightroom()
    LrTasks.sleep(1)

    if trigger.headless then
        logger:trace("Grupp " .. label .. ": Ctrl+Skift+H (huvudlös sammanslagning)")
        sendKeys('keystroke "h" using {control down, shift down}')
        dngPath = waitForNewDng(sourceDir, before, M.HEADLESS_TIMEOUT_SECONDS)
        if dngPath then
            result.mergeMethod = "headless"
        else
            logger:warn("Grupp " .. label .. ": ingen DNG efter Ctrl+Skift+H, faller tillbaka på dialogen")
            -- Stäng en eventuell dialog som genvägen råkade öppna innan reservvägen provas.
            sendKeys("key code 53")
            LrTasks.sleep(1)
            activateLightroom()
        end
    end

    if not dngPath then
        logger:trace("Grupp " .. label .. ": Ctrl+H, väntar på förhandsvisningen, Merge")
        sendKeys('keystroke "h" using {control down}')
        LrTasks.sleep(M.hdrPreviewWaitSeconds())
        if not clickMergeWhenReady(M.DIALOG_TIMEOUT_SECONDS) then
            logger:warn("Grupp " .. label .. ": Merge kunde inte klickas, provar Retur")
            sendKeys("keystroke return")
        end
        dngPath = waitForNewDng(sourceDir, before, M.DIALOG_TIMEOUT_SECONDS)
        if dngPath then result.mergeMethod = "dialog" end
    end

    if not dngPath then
        result.message = "Ingen ny -HDR.dng dök upp i " .. sourceDir
        return result
    end
    logger:trace("Grupp " .. label .. ": ny DNG " .. dngPath)

    local photo = findPhotoInCatalog(catalog, dngPath)
    if not photo then
        result.message = "DNG:n hittades inte i katalogen: " .. dngPath
        result.sourceDng = dngPath
        return result
    end
    result.develop = readDevelopSettings(photo)

    local exportDir = group.export_dir or group.output_dir
    if not exportDir or exportDir == "" then
        result.message = "Triggern saknar export_dir"
        result.sourceDng = dngPath
        return result
    end

    -- DNG:n sparas också (bredvid exporten) för senare analys.
    LrFileUtils.createAllDirectories(exportDir)
    local copiedDng = LrPathUtils.child(exportDir, "lr.dng")
    LrFileUtils.delete(copiedDng)
    local copied = LrFileUtils.copy(dngPath, copiedDng)
    result.sourceDng = dngPath
    result.dng = copied and copiedDng or dngPath

    local exportOK, exported = LrTasks.pcall(function() return exportPhoto(photo, exportDir, trigger.export_format) end)
    if not exportOK or not exported then
        result.message = "Exporten misslyckades: " .. tostring(exportOK and "ingen fil" or exported)
        return result
    end
    result.export = exported
    result.status = "ok"
    result.seconds = os.time() - started
    result.message = "HDR klar (" .. (result.mergeMethod or "?") .. "), " .. #photos .. " ramar"
    return result
end

local function processGroup(catalog, group, groupIndex, totalGroups, progress, trigger)
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

    if trigger and trigger.mode == "experiment" then
        return experimentMerge(catalog, group, photos, trigger, validFiles[1])
    end

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
            local result = processGroup(catalog, group, i, totalGroups, progress, trigger)
            table.insert(results, result)
            -- Experimentläget: löpande status, så att `photoflow-cli lr-trigger --wait` kan visa förlopp.
            if trigger.mode == "experiment" then writeStatus("running", results) end
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
        doneFile:write(encodeJSON({ status = "complete", groups = totalGroups, ok = okCount,
                                    mode = trigger.mode, plugin_version = M.VERSION }))
        doneFile:close()
    end

    logger:trace(string.format("Klar: %d/%d grupper mergade", okCount, totalGroups))

    if opts.showSummaryDialog then
        LrDialogs.message("PhotoFlow HDR", okCount .. " grupper mergade, " .. errCount .. " misslyckades.", "info")
    end

    return true
end

return M
