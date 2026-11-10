-- Pattern "texts". This file is copied unchanged into every
-- plugin that has the pattern, as tools/check_texts.lua: change the pattern first, then copy it again.
--
-- Checks the texts of the plugin with plain LuaJIT, no KOReader needed: every language has the same keys,
-- with values of the same type, the same format markers in the same order, the same numbered markers (%1,
-- %M1) and named markers ({done}) in any order, and no text has a dash or names a brand of e-reader.
-- Usage, from the plugin folder: luajit tools/check_texts.lua [file.lua] [name[:path] ...] [file.lua ...]
--   file.lua: a texts file, relative to the plugin. With none, the one data/i18n.lua or <id>/i18n.lua.
--   name: how the code reads the texts of the file before it (for example "s" for s.title). Every key the
--   code asks for through it must exist. "name()" is a function that returns the texts (for example
--   "strings()" for self:strings().title). With ":path", only the files whose path starts with it are read,
--   for a name the code also gives to something else elsewhere. A name that finds no file or no use is a
--   problem, since it checks nothing.
local root = (arg[0]:match("^(.*)/tools/[^/]+$")) or "."

local problems = 0
local function problem(message)
    problems = problems + 1
    print("PROBLEM " .. message)
end

local function fail(message)
    print("FAILED " .. message)
    os.exit(1)
end

local function exists(path)
    local file = io.open(path, "rb")
    if file then
        file:close()
        return true
    end
    return false
end

local function quote(text)
    return "'" .. text:gsub("'", "'\\''") .. "'"
end

local function lines_of(command)
    local list = {}
    local pipe = io.popen(command)
    for line in pipe:lines() do
        list[#list + 1] = line
    end
    pipe:close()
    return list
end

local function read(path)
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    return text
end

local function sorted_keys(map)
    local keys = {}
    for key in pairs(map) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

-- A string.format marker. The space and # flags are left out, so a percent sign in running text ("30% de",
-- "30% faster") is not taken for one.
local FORMAT = "%%[-+0]*%d*%.?%d*[cdiouxXeEfgGqs]"

-- The markers string.format reads, in order, since Lua has no way to reorder them in a translation.
local function markers(text)
    local list = {}
    for marker in text:gsub("%%%%", ""):gmatch(FORMAT) do
        list[#list + 1] = marker:sub(-1)
    end
    return table.concat(list, " ")
end

-- Numbered markers, replaced by position (%1 and %2 in KOReader's T()) or by a plugin's own template (%M1),
-- so their order is free.
local function numbered_markers(text)
    local list = {}
    for marker in text:gsub("%%%%", ""):gsub(FORMAT, ""):gmatch("%%%a?%d+") do
        list[#list + 1] = marker
    end
    table.sort(list)
    return table.concat(list, " ")
end

-- Markers such as {done}, replaced by name (with gsub or in a browser page), so their order is free.
local function named_markers(text)
    local list = {}
    for marker in text:gmatch("{[%a_][%w_]*}") do
        list[#list + 1] = marker
    end
    table.sort(list)
    return table.concat(list, " ")
end

-- KOReader runs on all of them, so a text that names one is wrong for the others. Words that are also
-- common English words (nook, remarkable) are left out.
local BRANDS = { "kindle", "kobo", "pocketbook", "boox", "tolino" }

local function brand_in(text)
    local lower = text:lower()
    for _, brand in ipairs(BRANDS) do
        if lower:find("%f[%w]" .. brand .. "s?%f[%W]") then
            return brand
        end
    end
end

-- Loaded with only the basic libraries: a texts file that needs more than that is doing too much.
local function load_texts(relative)
    local chunk, load_error = loadfile(root .. "/" .. relative)
    if not chunk then
        fail(load_error)
    end
    setfenv(chunk, {
        string = string, table = table, math = math, pairs = pairs, ipairs = ipairs, next = next, type = type,
        tostring = tostring, tonumber = tonumber, select = select, unpack = unpack, error = error, assert = assert,
        setmetatable = setmetatable, getmetatable = getmetatable, rawget = rawget,
    })
    local ok, texts = pcall(chunk)
    if not ok or type(texts) ~= "table" then
        fail(relative .. " did not return a table: " .. tostring(texts))
    end
    return texts
end

local sources
local function source_files()
    if not sources then
        sources = {}
        local found = lines_of("cd " .. quote(root) .. " && find . -name '*.lua' -not -path './tests/*' -not -path './tools/*'"
            .. " -not -path './dist/*' -not -path './.ko-home/*' | sort")
        for _, path in ipairs(found) do
            sources[#sources + 1] = { path = path:sub(3), text = read(root .. "/" .. path) }
        end
    end
    return sources
end

local total_texts, total_asked = 0, 0

local function check_file(relative, names)
    local texts = load_texts(relative)
    local languages = {}
    for code, value in pairs(texts) do
        if type(code) == "string" and type(value) == "table" and (code:match("^%l%l$") or code:match("^%l%l_%u%u$")) then
            languages[#languages + 1] = code
        end
    end
    table.sort(languages)
    if #languages < 2 then
        fail(relative .. " has " .. #languages .. " language(s), the pattern is for two or more")
    end
    local base_code = texts.en and "en" or languages[1]
    local base = texts[base_code]

    local function compare(from, other, path, code)
        for _, key in ipairs(sorted_keys(from)) do
            local here = path .. tostring(key)
            local mine, theirs = from[key], other[key]
            if theirs == nil then
                problem(string.format("%s: %s has no %s", relative, code, here))
            elseif type(mine) ~= type(theirs) then
                problem(string.format("%s: %s.%s is a %s, %s.%s is a %s", relative, code, here, type(theirs), base_code, here, type(mine)))
            elseif type(mine) == "table" then
                compare(mine, theirs, here .. ".", code)
            elseif type(mine) == "string" and markers(mine) ~= markers(theirs) then
                problem(string.format("%s: %s.%s has markers [%s], %s.%s has [%s]", relative, code, here, markers(theirs), base_code, here, markers(mine)))
            elseif type(mine) == "string" and numbered_markers(mine) ~= numbered_markers(theirs) then
                problem(string.format("%s: %s.%s has numbered markers [%s], %s.%s has [%s]", relative, code, here,
                    numbered_markers(theirs), base_code, here, numbered_markers(mine)))
            elseif type(mine) == "string" and named_markers(mine) ~= named_markers(theirs) then
                problem(string.format("%s: %s.%s has named markers [%s], %s.%s has [%s]", relative, code, here,
                    named_markers(theirs), base_code, here, named_markers(mine)))
            end
        end
        for _, key in ipairs(sorted_keys(other)) do
            if from[key] == nil then
                problem(string.format("%s: %s has no %s%s, which %s has", relative, base_code, path, tostring(key), code))
            end
        end
    end

    local function check_each(value, path)
        if type(value) == "string" then
            total_texts = total_texts + 1
            if value:find("\226\128\148", 1, true) or value:find("\226\128\147", 1, true) then
                problem(relative .. ": " .. path .. " has a dash")
            end
            local brand = brand_in(value)
            if brand then
                problem(relative .. ": " .. path .. " names " .. brand .. ", say e-reader or device instead")
            end
        elseif type(value) == "table" then
            for _, key in ipairs(sorted_keys(value)) do
                check_each(value[key], path .. "." .. tostring(key))
            end
        end
    end

    for _, code in ipairs(languages) do
        if code ~= base_code then
            compare(base, texts[code], "", code)
        end
        check_each(texts[code], code)
    end

    for _, option in ipairs(names) do
        local name, call, rest = option:match("^([%a_][%w_]*)([()]*)(.*)$")
        local prefix = rest and rest:match("^:(.*)$") or ""
        if not name or (call ~= "" and call ~= "()") or (rest ~= "" and not rest:match("^:.")) then
            fail("a name is a Lua identifier, optionally followed by () and by :path, not " .. option)
        end
        local reader = name .. (call == "()" and "%(%)" or "")
        name = name .. call
        local files, uses = 0, 0
        for _, source in ipairs(source_files()) do
            if source.path ~= relative and source.path:sub(1, #prefix) == prefix then
                files = files + 1
                -- Not after "%", which is a format such as "%s.png" and not the name.
                for chain in ("\n" .. source.text):gmatch("[^%w_%%]" .. reader .. "%.([%a_][%w_]*[%w_.]*)") do
                    uses = uses + 1
                    local value, walked = base, name
                    for key in chain:gmatch("[^.]+") do
                        if type(value) ~= "table" then
                            break
                        end
                        if value[key] == nil then
                            problem(string.format("%s asks for %s.%s, which %s of %s does not have", source.path, walked, key, base_code, relative))
                            break
                        end
                        value, walked = value[key], walked .. "." .. key
                    end
                end
            end
        end
        total_asked = total_asked + uses
        if files == 0 then
            problem(string.format("%s finds no .lua file starting with %q", option, prefix))
        elseif uses == 0 then
            problem(string.format("%s finds no use of %s.<key> in the code", option, name))
        end
    end
    print(string.format("%s: %d languages (%s)", relative, #languages, table.concat(languages, " ")))
end

local groups = {}
for _, option in ipairs(arg) do
    if option:match("%.lua$") and not option:find(":", 1, true) then
        if not exists(root .. "/" .. option) then
            fail("no texts file " .. option)
        end
        groups[#groups + 1] = { file = option, names = {} }
    else
        if #groups == 0 then
            groups[1] = { names = {} }
        end
        table.insert(groups[#groups].names, option)
    end
end
if #groups == 0 then
    groups[1] = { names = {} }
end
for _, group in ipairs(groups) do
    if not group.file then
        if exists(root .. "/data/i18n.lua") then
            group.file = "data/i18n.lua"
        else
            local found = lines_of("cd " .. quote(root) .. " && ls */i18n.lua 2>/dev/null")
            if #found ~= 1 then
                fail("expected one data/i18n.lua or <id>/i18n.lua, found " .. #found .. "; name the file")
            end
            group.file = found[1]
        end
    end
    check_file(group.file, group.names)
end

print(string.format("texts: %d checked, %d uses in the code", total_texts, total_asked))
if problems > 0 then
    print(problems .. " problem(s)")
    os.exit(1)
end
print("everything as expected")
os.exit(0)
