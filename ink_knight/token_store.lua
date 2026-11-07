-- Where the token is kept. The shared storage of an e-reader ignores file permissions, so on a Kindle
-- it goes to the system partition, which USB does not reach. Protection is checked, never assumed.
local TokenAccess = require("ink_knight/token_access")

local TokenStore = {}
TokenStore.__index = TokenStore

local FILE_NAME = "ink_knight_token"
local PRIVATE = "rw-------"
local KINDLE_DIR = "/var/local/ink_knight"

-- opts: settings_dir, private_dir (nil to use only the settings folder), permissions_of(path), shell(command).
function TokenStore.new(opts)
    return setmetatable({
        settings_dir = opts.settings_dir,
        private_dir = opts.private_dir,
        permissions_of = opts.permissions_of,
        shell = opts.shell or os.execute,
    }, TokenStore)
end

-- The folder for a Kindle, which only exists in its system partition.
function TokenStore.private_dir_for(is_kindle)
    return is_kindle and KINDLE_DIR or nil
end

local function read_token(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local token = (file:read("*a") or ""):gsub("%s+", "")
    file:close()
    return TokenAccess.is_valid_token(token) and token or nil
end

function TokenStore:settings_path()
    return self.settings_dir .. "/" .. FILE_NAME
end

function TokenStore:private_path()
    return self.private_dir and (self.private_dir .. "/" .. FILE_NAME) or nil
end

-- Writes with the permissions in place from the start, so the file is never readable by others, not even briefly.
function TokenStore:write(path, token)
    local temporary = path .. ".new"
    self.shell(string.format("(umask 077; : > '%s') 2>/dev/null", temporary))
    local file = io.open(temporary, "wb")
    if not file then
        return false
    end
    local written = file:write(token)
    file:close()
    self.shell(string.format("chmod 600 '%s' 2>/dev/null", temporary))
    if not written or not os.rename(temporary, path) then
        os.remove(temporary)
        return false
    end
    return true
end

function TokenStore:is_protected(path)
    return self.permissions_of(path) == PRIVATE
end

-- A Kindle gives its own services access to the whole system partition at every boot, so this is not done only once.
function TokenStore:restrict(path)
    self.shell(string.format("chmod 700 '%s' 2>/dev/null; chmod 600 '%s' 2>/dev/null", self.private_dir, path))
end

-- Tries the private place, and falls back to the settings folder. Returns whether it worked and whether it is protected.
function TokenStore:save(token)
    local private = self:private_path()
    if private then
        self.shell(string.format("mkdir -p '%s' 2>/dev/null && chmod 700 '%s' 2>/dev/null", self.private_dir, self.private_dir))
        if self:write(private, token) then
            if self:is_protected(private) and read_token(private) == token then
                os.remove(self:settings_path())
                return true, true
            end
            os.remove(private)
        end
    end
    local path = self:settings_path()
    if not self:write(path, token) then
        return false, false
    end
    return true, self:is_protected(path)
end

-- Returns the token and whether it is protected. A token found in the settings folder moves to the private place.
function TokenStore:load()
    local private = self:private_path()
    local token = private and read_token(private)
    if token then
        if not self:is_protected(private) then
            self:restrict(private)
        end
        return token, self:is_protected(private)
    end
    token = read_token(self:settings_path())
    if not token then
        return nil, false
    end
    local _, protected = self:save(token)
    return token, protected
end

function TokenStore:clear()
    local private = self:private_path()
    if private then
        os.remove(private)
    end
    os.remove(self:settings_path())
end

return TokenStore
