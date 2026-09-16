-- Fas 4: LrInitPlugin (InitPlugin.lua) now starts a real background poller
-- (see HDRMergeCore.lua) instead of just writing a debug marker — the
-- "Kor HDR-sammanslagning fran PhotoFlow" menu item below is kept as a
-- manual fallback/immediate re-check, both now share the same logic.
return {
    LrSdkVersion = 10.0,
    LrToolkitIdentifier = "se.photoflow.lightroom",
    LrPluginName = "PhotoFlow HDR",
    LrPluginInfoUrl = "https://github.com/photoflow",

    LrInitPlugin = "InitPlugin.lua",

    LrLibraryMenuItems = {
        {
            title = "Kor HDR-sammanslagning fran PhotoFlow (manuell koll)",
            file = "RunHDRMerge.lua",
        },
    },

    VERSION = { major=1, minor=2, revision=0 },
}
