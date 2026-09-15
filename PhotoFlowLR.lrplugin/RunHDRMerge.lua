--[[
    PhotoFlow HDR Merge Plugin for Lightroom Classic
    Lua 5.1 compatible (no goto statements)
]]

local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrLogger = import 'LrLogger'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope = import 'LrProgressScope'

local logger = LrLogger('PhotoFlowHDR')
logger:enable("print")

local function parseJSON(str)
    local groups = {}
    local pos = 1
    while true do
        local idStart, idEnd, groupId = str:find('"group_id"%s*:%s*(%d+)', pos)
        if not idStart then break end

        local group = { group_id = tonumber(groupId), files = {} }
        local searchStart = math.max(1, idStart - 500)
        local searchEnd = math.min(#str, idEnd + 2000)
        local block = str:sub(searchStart, searchEnd)

        local filesStr = block:match('"files"%s*:%s*%[(.-)%]')
        if filesStr then
            for filePath in filesStr:gmatch('"([^"]+)"') do
                table.insert(group.files, filePath)
            end
        end
        group.output_dir = block:match('"output_dir"%s*:%s*"([^"]*)"') or ""

        if #group.files >= 2 then
            table.insert(groups, group)
        end
        pos = idEnd + 1
    end
    return { groups = groups }
end

local function writeStatus(status, results)
    local statusPath = LrPathUtils.child(
        LrPathUtils.getStandardFilePath("temp"),
        "photoflow_hdr_status.json"
    )
    local file = io.open(statusPath, "w")
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

local function processGroup(catalog, group, groupIndex, totalGroups, progress)
    progress:setCaption("Grupp " .. groupIndex .. "/" .. totalGroups)
    logger:trace("Group " .. group.group_id .. ": " .. #group.files .. " files")

    -- Check files exist
    local validFiles = {}
    for _, filePath in ipairs(group.files) do
        if LrFileUtils.exists(filePath) then
            table.insert(validFiles, filePath)
        else
            logger:warn("Not found: " .. filePath)
        end
    end

    if #validFiles < 2 then
        return { group_id = group.group_id, status = "error", message = "Too few files: " .. #validFiles }
    end

    -- Import photos
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
                    logger:trace("Added: " .. LrPathUtils.leafName(filePath))
                else
                    local findOK, existing = LrTasks.pcall(function()
                        return catalog:findPhotoByPath(filePath)
                    end)
                    if findOK and existing then
                        table.insert(photos, existing)
                        logger:trace("Found existing: " .. LrPathUtils.leafName(filePath))
                    else
                        importErr = tostring(addOK and "nil" or photo)
                        logger:warn("Failed: " .. filePath .. " - " .. tostring(importErr))
                    end
                end
            end
        end)
    end)

    if not writeOK then
        importErr = tostring(writeErr)
        logger:warn("withWriteAccessDo failed: " .. importErr)
    end

    logger:trace("Group " .. group.group_id .. ": got " .. #photos .. " photos")

    if #photos < 2 then
        return { group_id = group.group_id, status = "error",
            message = "Import got " .. #photos .. " photos. Error: " .. (importErr or "unknown") }
    end

    -- Select photos
    local selOK, selErr = LrTasks.pcall(function()
        catalog:setSelectedPhotos(photos[1], photos)
    end)

    if not selOK then
        return { group_id = group.group_id, status = "error",
            message = "Select failed: " .. tostring(selErr) }
    end

    LrTasks.yield()
    LrTasks.sleep(1)

    -- Trigger HDR Merge via Ctrl+H
    local mergeOK, mergeErr = LrTasks.pcall(function()
        LrTasks.execute(
            'osascript -e \'tell application "System Events" to tell process ' ..
            '"Adobe Lightroom Classic" to keystroke "h" using {control down}\''
        )
    end)

    if not mergeOK then
        return { group_id = group.group_id, status = "error",
            message = "HDR shortcut: " .. tostring(mergeErr) }
    end

    -- Wait for HDR preview, then press Enter to merge
    LrTasks.sleep(5)
    LrTasks.pcall(function()
        LrTasks.execute(
            'osascript -e \'tell application "System Events" to tell process ' ..
            '"Adobe Lightroom Classic" to keystroke return\''
        )
    end)
    LrTasks.sleep(8)

    return { group_id = group.group_id, status = "ok",
        message = "HDR triggered for " .. #photos .. " photos" }
end

local function runHDRMerge()
    LrFunctionContext.callWithContext("PhotoFlowHDR", function(context)
        local triggerPath = LrPathUtils.child(
            LrPathUtils.getStandardFilePath("temp"),
            "photoflow_hdr_trigger.json"
        )

        logger:trace("Trigger path: " .. triggerPath)

        if not LrFileUtils.exists(triggerPath) then
            LrDialogs.message("PhotoFlow HDR",
                "Ingen HDR-trigger hittades.\n\nSokte: " .. triggerPath, "info")
            return
        end

        local file = io.open(triggerPath, "r")
        if not file then
            LrDialogs.showError("Kunde inte lasa: " .. triggerPath)
            return
        end
        local content = file:read("*all")
        file:close()

        local trigger = parseJSON(content)
        if not trigger or not trigger.groups or #trigger.groups == 0 then
            LrDialogs.showError("Inga giltiga grupper.\n\n" .. content:sub(1, 500))
            return
        end

        local totalGroups = #trigger.groups
        local catalog = LrApplication.activeCatalog()
        local results = {}

        local progress = LrProgressScope({
            title = "PhotoFlow HDR",
            functionContext = context,
        })

        for i, group in ipairs(trigger.groups) do
            if progress:isCanceled() then
                table.insert(results, { group_id = group.group_id, status = "cancelled", message = "User cancelled" })
                break
            end

            progress:setPortionComplete(i - 1, totalGroups)
            local result = processGroup(catalog, group, i, totalGroups, progress)
            table.insert(results, result)
            logger:trace("Group " .. group.group_id .. " result: " .. result.status .. " - " .. result.message)

            LrTasks.sleep(2)
        end

        progress:done()
        writeStatus("complete", results)
        LrFileUtils.delete(triggerPath)

        -- Write done marker
        local donePath = LrPathUtils.child(
            LrPathUtils.getStandardFilePath("temp"),
            "photoflow_hdr_done.json"
        )
        local doneFile = io.open(donePath, "w")
        if doneFile then
            local okCount = 0
            for _, r in ipairs(results) do
                if r.status == "ok" then okCount = okCount + 1 end
            end
            doneFile:write('{"status":"complete","groups":' .. totalGroups .. ',"ok":' .. okCount .. '}')
            doneFile:close()
        end

        local okCount, errCount = 0, 0
        for _, r in ipairs(results) do
            if r.status == "ok" then okCount = okCount + 1
            else errCount = errCount + 1 end
        end

        LrDialogs.message("PhotoFlow HDR",
            okCount .. " grupper mergade, " .. errCount .. " misslyckades.", "info")
    end)
end

LrTasks.startAsyncTask(function()
    runHDRMerge()
end)
