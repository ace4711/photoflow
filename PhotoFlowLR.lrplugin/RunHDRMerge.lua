--[[
    PhotoFlow HDR Merge Plugin for Lightroom Classic — manual trigger
    (Library > Plug-in Extras > "Kör HDR-sammanslagning fran PhotoFlow").

    Fas 4: the actual merge logic moved to HDRMergeCore.lua, shared with
    InitPlugin.lua's background poller so the menu item and the automatic
    5-second poll behave identically. This file is now just the manual
    entry point — kept as a fallback (e.g. if the poller isn't running for
    some reason, or to re-check immediately instead of waiting up to 5s).
]]

local LrTasks = import 'LrTasks'
local HDRMergeCore = require 'HDRMergeCore'

LrTasks.startAsyncTask(function()
    HDRMergeCore.runOnce({ showDialogIfMissing = true, showSummaryDialog = true })
end)
