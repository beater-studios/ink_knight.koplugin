-- The windows of Ink Knight for tools/koreader/check_rotation.lua, which opens each one with KOReader in
-- landscape. The texts are read from the folder given, so with the empty folder the opening fails inside the
-- window, after the screen turned, which is what the check needs to see the rotation given back.
local function strings_from(plugin_dir)
    local ok, I18n = pcall(dofile, plugin_dir .. "/ink_knight/i18n.lua")
    return ok and I18n.en or nil
end

return {
    -- Opened from the menu, and a page itself, so the scan does not find it by its own file.
    ["ink_knight/ui/home"] = function(plugin_dir)
        return { plugin_dir = plugin_dir, version = "0" }
    end,
    ["ink_knight/ui/chart_screen"] = function(plugin_dir)
        return { title = "Rapid", points = {}, stats = {}, strings = strings_from(plugin_dir) }
    end,
    ["ink_knight/ui/create_token_screen"] = function(plugin_dir)
        return { strings = strings_from(plugin_dir), on_ready = function() end }
    end,
    -- The page on the network starts too, on the address of this computer when it has a private one.
    ["ink_knight/ui/token_screen"] = function(plugin_dir)
        require("ink_knight/lan").install("ink_knight")
        return { strings = strings_from(plugin_dir), on_token = function() end }
    end,
}
