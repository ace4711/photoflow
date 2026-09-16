--[[
    PhotoFlow HDR Init (Fas 4)

    Starts the background poller that watches for a trigger file written by
    PipelineRunner+Lightroom.swift — every `HDRMergeCore.pollIntervalSeconds()`
    (default 5) seconds, checks whether a trigger is waiting and processes it
    if so. Previously the app logged "Pluginet auto-pollar var 5:e sekund"
    even though nothing here actually polled (RunHDRMerge.lua only ran when
    manually invoked from the Library menu) — this is what makes that true.

    Runs for as long as Lightroom has the plugin enabled. Each iteration is
    wrapped in `LrTasks.pcall` so one failed poll (e.g. a half-written
    trigger file caught mid-write) can't kill the whole loop.
]]

local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'
local LrLogger = import 'LrLogger'
local HDRMergeCore = require 'HDRMergeCore'

local logger = LrLogger('PhotoFlowHDR')
logger:enable("print")

-- Kept from the original version: a simple on-disk marker confirming
-- InitPlugin actually ran — useful for checking whether the plugin loaded at
-- all, independent of whether the polling loop below is behaving.
local logPath = LrPathUtils.child(LrPathUtils.getStandardFilePath("temp"), "photoflow_plugin_debug.log")
local f = io.open(logPath, "w")
if f then
    f:write("InitPlugin loaded at " .. os.date() .. " — startar bakgrundspollning var " .. HDRMergeCore.pollIntervalSeconds() .. "s\n")
    f:close()
end

LrTasks.startAsyncTask(function()
    logger:trace("Bakgrundspollning startad (var " .. HDRMergeCore.pollIntervalSeconds() .. "s)")
    while true do
        local ok, err = LrTasks.pcall(function()
            HDRMergeCore.runOnce({ showDialogIfMissing = false, showSummaryDialog = false })
        end)
        if not ok then
            logger:warn("Bakgrundspollning: fel i en omgång: " .. tostring(err))
        end
        LrTasks.sleep(HDRMergeCore.pollIntervalSeconds())
    end
end)
