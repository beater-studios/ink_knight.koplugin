-- Takes the reader to the page of Lichess that creates a token, with the permissions already marked: a page of the plugin with the code in a card, what to do, the address for a device without a camera, and the way on once the token exists.
local QRWidget = require("ui/widget/qrwidget")
local UIManager = require("ui/uimanager")

local Page = require("ink_knight/ui/page")
local TokenScopes = require("ink_knight/token_scopes")

local CreateTokenScreen = Page:extend{
    name = "ink_knight_create_token",
    strings = nil,
    on_ready = nil,
}

-- The code as tall as this, in units of a screen 600 wide.
local CODE_HEIGHT = 290

function CreateTokenScreen:init()
    local s = self.strings
    self.title = s.token_create_title
    self.broken_text = s.unexpected_error
    local manual = string.format(s.token_create_manual, TokenScopes.CREATE_URL:gsub("^https://", ""), table.concat(TokenScopes.SUGGESTED, ", "))
    self.rows = {
        { kind = "drawing", height = CODE_HEIGHT, draw = function(bb, x, y, w, h)
            -- Made at the first paint, when the size is known, and kept until the page closes.
            local size = math.min(w, h) - 2 * self:px(14)
            if not self.code or self.code_size ~= size then
                if self.code then
                    self.code:free()
                end
                self.code, self.code_size = QRWidget:new{ text = TokenScopes.create_url(), width = size, height = size }, size
            end
            self.code:paintTo(bb, x + math.floor((w - size) / 2), y + math.floor((h - size) / 2))
        end },
        { kind = "text", text = s.token_create_steps },
        { kind = "text", text = manual },
        { kind = "primary", text = s.token_create_done, callback = function()
            UIManager:close(self)
            self.on_ready()
        end },
    }
    Page.init(self)
end

-- A code over a page opens and closes with a flash, so no trace of it is left behind.
function CreateTokenScreen:onShow()
    Page.refresh:reset()
    return Page.onShow(self)
end

function CreateTokenScreen:close_refresh()
    Page.refresh:reset()
    Page.close_refresh(self)
end

function CreateTokenScreen:onCloseWidget()
    if self.code then
        self.code:free()
        self.code = nil
    end
    Page.onCloseWidget(self)
end

return CreateTokenScreen
