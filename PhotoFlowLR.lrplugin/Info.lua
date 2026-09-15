return {
    LrSdkVersion = 10.0,
    LrToolkitIdentifier = "se.photoflow.lightroom",
    LrPluginName = "PhotoFlow HDR",
    LrPluginInfoUrl = "https://github.com/photoflow",

    LrInitPlugin = "InitPlugin.lua",

    LrLibraryMenuItems = {
        {
            title = "Kor HDR-sammanslagning fran PhotoFlow",
            file = "RunHDRMerge.lua",
        },
    },

    VERSION = { major=1, minor=1, revision=0 },
}
