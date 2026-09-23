-- Fas 4: LrInitPlugin (InitPlugin.lua) now starts a real background poller
-- (see HDRMergeCore.lua) instead of just writing a debug marker — the
-- "Kor HDR-sammanslagning fran PhotoFlow" menu item below is kept as a
-- manual fallback/immediate re-check, both now share the same logic.
--
-- Lightroom-pluginets installningar: LrPluginInfoProvider registers
-- PluginInfo.lua, which adds a "PhotoFlow HDR" settings section to
-- File > Plug-in Manager (sectionsForTopOfDialog) for the wait times that
-- were previously only adjustable by editing HDRMergeCore.lua. Key name
-- verified against Lightroom Classic's own bundled SDK Lua bytecode
-- (LightroomSDK.framework/.../AgPluginManager.lua contains the literal
-- string "LrPluginInfoProvider" alongside "sectionsForTopOfDialog" /
-- "startDialog" / "endDialog") — see FORBATTRINGAR.md for details.
return {
    LrSdkVersion = 10.0,
    LrToolkitIdentifier = "se.photoflow.lightroom",
    LrPluginName = "PhotoFlow HDR",
    LrPluginInfoUrl = "https://github.com/photoflow",

    LrInitPlugin = "InitPlugin.lua",
    LrPluginInfoProvider = "PluginInfo.lua",

    LrLibraryMenuItems = {
        {
            title = "Kor HDR-sammanslagning fran PhotoFlow (manuell koll)",
            file = "RunHDRMerge.lua",
        },
    },

    VERSION = { major=1, minor=3, revision=0 },
}
