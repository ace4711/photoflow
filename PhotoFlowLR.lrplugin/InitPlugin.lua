-- PhotoFlow HDR Init: write a debug marker to verify this file runs
local LrPathUtils = import 'LrPathUtils'

local logPath = LrPathUtils.child(
    LrPathUtils.getStandardFilePath("temp"),
    "photoflow_plugin_debug.log"
)

local f = io.open(logPath, "w")
if f then
    f:write("InitPlugin loaded at " .. os.date() .. "\n")
    f:close()
end
