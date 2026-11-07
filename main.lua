local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local Awake = require("ink_knight/ui/awake")
local I18n = require("ink_knight/i18n")

local PLUGIN_DIR = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("/main%.lua$", "")

local function meta_version()
    local chunk = loadfile(PLUGIN_DIR .. "/_meta.lua")
    if chunk then
        setfenv(chunk, {})
        local ok, meta = pcall(chunk)
        if ok and type(meta) == "table" then
            return meta.version
        end
    end
    return "?"
end

local InkKnight = WidgetContainer:extend{
    name = "ink_knight",
    is_doc_only = false,
}

local recovered = false

function InkKnight:init()
    self.ui.menu:registerToMainMenu(self)
    if not recovered then
        recovered = true
        Awake.recover()
    end
end

function InkKnight:addToMainMenu(menu_items)
    local strings = I18n[I18n.language_from(G_reader_settings:readSetting("language"))]
    menu_items.ink_knight = {
        text = strings.menu,
        sorting_hint = "tools",
        callback = function()
            local ok, err = pcall(function()
                local Home = require("ink_knight/ui/home")
                UIManager:show(Home:new{ version = meta_version(), plugin_dir = PLUGIN_DIR })
            end)
            if not ok then
                logger.warn("Ink Knight: could not open", err)
                UIManager:show(InfoMessage:new{ text = strings.start_failed })
            end
        end,
    }
end

return InkKnight
