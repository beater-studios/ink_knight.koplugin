-- The look of the plugin in one place (the redesign, direction B in docs/mockups/ink_knight_redesign/ of the kindle project): the grays, the strokes, the corners, the shadow of the cards and the sizes of the text, in units of a screen 600 wide, which every screen scales. Only the 16 grays the Kindle shows, far enough apart to tell on e-ink.
local Blitbuffer = require("ffi/blitbuffer")

local Style = {}

Style.BLACK = Blitbuffer.COLOR_BLACK
Style.WHITE = Blitbuffer.COLOR_WHITE
Style.DARK = Blitbuffer.Color8(0x44)
Style.MID = Blitbuffer.Color8(0x88)
Style.LIGHT = Blitbuffer.Color8(0xBB)
Style.PALE = Blitbuffer.Color8(0xDD)
-- The ground of the pages, under the cards; white where the test on the Kindle says the gray is not clean enough.
Style.PAPER = Blitbuffer.Color8(0xEE)

Style.BOLD = "noto/NotoSans-Bold.ttf"
Style.REGULAR = "noto/NotoSans-Regular.ttf"

-- Strokes and corners.
Style.CARD_BORDER = 2.5
Style.CARD_RADIUS = 10
Style.CARD_SHADOW = 5
Style.BUTTON_BORDER = 2.5
Style.LINE = 1

-- Heights.
Style.BAND = 64
Style.ROW = 64
Style.ROW_DETAIL = 68
Style.SECTION = 30
Style.BUTTON = 56
Style.PLATE = 52
Style.BAR = 62

-- Sizes of text.
Style.TITLE = 24
Style.ROW_TEXT = 17
Style.ROW_DETAIL_TEXT = 13
Style.SECTION_TEXT = 13
Style.BUTTON_TEXT = 18
Style.BAR_TEXT = 13

return Style
