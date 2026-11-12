-- Keeps the first <count> puzzles of each level in a folder of puzzle files, for a package of the release, and
-- writes how many in its manifest.lua. The order is fixed, so the first ones of the larger packages are the same.
-- Usage: luajit tools/puzzles/trim.lua <folder with the files of ink_knight/data/puzzles> <count>
package.path = "./?.lua;" .. package.path
local Pack = require("ink_knight/puzzle_pack")

local folder, count = arg[1], tonumber(arg[2])
if not folder or not count or count < 1 or count ~= math.floor(count) then
    io.stderr:write("usage: luajit tools/puzzles/trim.lua <folder> <count>\n")
    os.exit(1)
end

for _, level in ipairs(Pack.LEVELS) do
    local path = folder .. "/" .. level .. ".lua"
    local file = assert(io.open(path, "rb"))
    local out, kept = {}, 0
    for line in file:lines() do
        if line:match("^    { ") then
            if kept < count then
                kept = kept + 1
                out[#out + 1] = line
            end
        else
            out[#out + 1] = line
        end
    end
    file:close()
    if kept < count then
        io.stderr:write(string.format("%s: only %d puzzles, %d asked for\n", level, kept, count))
        os.exit(1)
    end
    file = assert(io.open(path, "wb"))
    file:write(table.concat(out, "\n"), "\n")
    file:close()
end
local manifest = assert(io.open(folder .. "/manifest.lua", "wb"))
manifest:write(Pack.manifest_source(count))
manifest:close()
