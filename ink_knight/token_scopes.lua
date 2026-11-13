-- What a token may do. Lichess states it in a header of its answers, and each endpoint accepts any of its scopes.
local TokenScopes = {}

TokenScopes.CREATE_URL = "https://lichess.org/account/oauth/token/create"
-- What the page for creating a token comes with already marked. preference:read is optional, but it only reads, so it
-- comes marked. preference:write stays out, because it also allows changing the preferences of the account and only
-- favorites need it, and so does note:write, which only the private notes about players need.
TokenScopes.SUGGESTED = { "board:play", "challenge:write", "follow:read", "follow:write", "puzzle:read", "puzzle:write", "preference:read" }

-- The first scope of each list is the one to ask for when none is there.
TokenScopes.FEATURES = {
    play = { "board:play" },
    challenge = { "board:play", "challenge:write" },
    events = { "board:play", "challenge:read" },
    following = { "follow:read" },
    follow_change = { "follow:write" },
    puzzles = { "puzzle:read" },
    puzzle_results = { "puzzle:write" },
    give_time = { "challenge:write" },
    favorites = { "preference:write" },
    -- Lichess asks for it even to read the notes.
    notes = { "note:write" },
    preferences = { "preference:read" },
}

-- What the reader sees listed, in this order. The optional ones do not count as something missing.
TokenScopes.LISTED = { "play", "following", "follow_change", "puzzles", "puzzle_results", "give_time", "favorites", "notes", "preferences" }
TokenScopes.OPTIONAL = { favorites = true, notes = true, preferences = true }

-- text: the value of the header. Without it nothing is known, which is not the same as no scopes.
function TokenScopes.parse(text)
    if type(text) ~= "string" then
        return nil
    end
    local scopes = {}
    for scope in text:gmatch("[^,%s]+") do
        scopes[scope] = true
    end
    return scopes
end

-- When nothing is known it answers yes, and Lichess has the last word.
function TokenScopes.allows(scopes, feature)
    if not scopes then
        return true
    end
    for _, scope in ipairs(TokenScopes.FEATURES[feature]) do
        if scopes[scope] then
            return true
        end
    end
    return false
end

function TokenScopes.missing_count(scopes)
    local count = 0
    for _, feature in ipairs(TokenScopes.LISTED) do
        if not TokenScopes.OPTIONAL[feature] and not TokenScopes.allows(scopes, feature) then
            count = count + 1
        end
    end
    return count
end

function TokenScopes.create_url()
    local parts = {}
    for _, scope in ipairs(TokenScopes.SUGGESTED) do
        parts[#parts + 1] = "scopes[]=" .. scope
    end
    parts[#parts + 1] = "description=Ink+Knight"
    return TokenScopes.CREATE_URL .. "?" .. table.concat(parts, "&")
end

return TokenScopes
