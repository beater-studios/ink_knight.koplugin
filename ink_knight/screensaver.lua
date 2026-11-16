-- Pattern "screensaver". This file is copied
-- unchanged into every plugin as <id>/screensaver.lua: change the pattern first, then copy it again.
local Screensaver = require("ui/screensaver")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local PluginScreensaver = {}

-- Every full-screen window of the plugin is named <id>_*, so new screens are covered too.
local function plugin_on_top(prefix)
    for widget in UIManager:topdown_widgets_iter() do
        if widget.covers_fullscreen then
            return type(widget.name) == "string" and widget.name:sub(1, #prefix) == prefix
        end
    end
    return false
end

-- KOReader chooses the book cover first; the plugin only swaps it while it is the screen being
-- shown, so closing the plugin restores the default behavior. Nothing is saved. draw, when the plugin
-- gives one, makes a cover of what is open at that moment (a Blitbuffer the size of the screen, which
-- KOReader frees after showing it); when it gives nothing, the fixed image is the cover.
local function apply(saver, event, image_file, prefix, draw)
    if event ~= nil or not saver.ui or G_reader_settings:readSetting("screensaver_type") ~= "cover" then
        return
    end
    if not plugin_on_top(prefix) then
        return
    end
    local drawn
    if draw then
        local ok, result = pcall(draw)
        if ok then
            drawn = result
        else
            logger.warn("screensaver: the cover could not be drawn, the fixed image stays", result)
        end
    end
    if not drawn and lfs.attributes(image_file, "mode") ~= "file" then
        return
    end
    if saver.image then
        saver.image:free()
    end
    saver.image = drawn or nil
    saver.image_file = not drawn and image_file or nil
    saver.screensaver_type = "cover"
end

-- plugin_dir: the plugin folder (with assets/screensaver.png). id: the plugin identifier, which
-- prefixes the names of its full-screen windows. draw: optional, a function that returns a cover of
-- what is open, or nil for the fixed image. Call it when main.lua loads.
function PluginScreensaver.install(plugin_dir, id, draw)
    assert(type(id) == "string" and id ~= "", "screensaver: the plugin id is required")
    local image_file = plugin_dir .. "/assets/screensaver.png"
    local prefix = id .. "_"
    local key = "_" .. id .. "_original_setup"
    if Screensaver[key] then
        return
    end
    local original_setup = Screensaver.setup
    Screensaver[key] = original_setup
    Screensaver.setup = function(saver, event, ...)
        original_setup(saver, event, ...)
        local ok, err = pcall(apply, saver, event, image_file, prefix, draw)
        if not ok then
            logger.warn(id .. ": screensaver cover failed", err)
        end
    end
end

return PluginScreensaver
