-- Proves that every level of "Learn chess" can be done in its par, with a large budget; the tests use a small one
-- and leave the big levels out. Usage, from the plugin folder: luajit tools/learn/prove_levels.lua [budget]
package.path = "./?.lua;" .. package.path
local Solver = require("tools/learn/solver")
local categories = require("ink_knight/data/learn_stages")

local budget = tonumber(arg[1]) or 400000
local proven, unproven, impossible = 0, {}, {}
for _, category in ipairs(categories) do
    for _, stage in ipairs(category.stages) do
        for index, level in ipairs(stage.levels) do
            local result = Solver.solvable(level, budget)
            if result == true then
                proven = proven + 1
            elseif result == false then
                impossible[#impossible + 1] = stage.key .. " " .. index
            else
                unproven[#unproven + 1] = stage.key .. " " .. index
            end
        end
    end
end
print(string.format("%d levels proven, %d left unproven at %d moves%s", proven, #unproven, budget,
    #unproven > 0 and (": " .. table.concat(unproven, ", ")) or ""))
if #impossible > 0 then
    print("cannot be done in their par: " .. table.concat(impossible, ", "))
    os.exit(1)
end
