-- Pattern "lan_server". This file is copied unchanged
-- into every plugin that serves a page on the local network, as <id>/lan.lua: change the pattern first.
--
-- KOReader modules are required inside the functions, so tests in plain LuaJIT can use the pure ones
-- (random_token, is_private_ip) without KOReader.
local Lan = {}

-- Without 0, o, 1, l and i, so a code read from the screen can be typed by hand.
local TOKEN_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"

-- Returns nil when /dev/urandom cannot give enough bytes: a weaker code is never made instead.
function Lan.random_token(length)
    length = length or 16
    local source = io.open("/dev/urandom", "rb")
    if not source then
        return nil
    end
    local bytes = source:read(length)
    source:close()
    if not bytes or #bytes < length then
        return nil
    end
    local out = {}
    for i = 1, length do
        local index = bytes:byte(i) % #TOKEN_ALPHABET + 1
        out[i] = TOKEN_ALPHABET:sub(index, index)
    end
    return table.concat(out)
end

-- Connecting a UDP socket picks the outgoing interface without sending any packet. The address is a private
-- one that is not a broadcast address, which Linux refuses to connect to.
function Lan.local_ip()
    local socket = require("socket")
    local udp = socket.udp()
    if not udp then
        return nil
    end
    local connected = udp:setpeername("10.254.254.254", 9)
    local ip = connected and udp:getsockname()
    udp:close()
    if not ip or ip == "0.0.0.0" then
        return nil
    end
    return ip
end

function Lan.is_private_ip(ip)
    local a, b = tostring(ip):match("^(%d+)%.(%d+)%.%d+%.%d+$")
    a, b = tonumber(a), tonumber(b)
    if not a then
        return false
    end
    return a == 10 or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168)
end

local PRIVATE_NETWORKS = { "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16" }

-- Outside KOReader's cache folder, which the "clear caches" menu empties.
local function marker_path()
    return require("datastorage"):getSettingsDir() .. "/" .. Lan.id .. ".firewall"
end

local function read_ports()
    local ports = {}
    local marker = io.open(marker_path(), "r")
    if marker then
        pcall(function()
            for line in marker:lines() do
                local port = tonumber(line)
                if port then
                    ports[#ports + 1] = port
                end
            end
        end)
        marker:close()
    end
    return ports
end

-- Written whole and then renamed, so a crash never leaves half a list. Returns false when it could not.
local function write_ports(ports)
    local path = marker_path()
    if #ports == 0 then
        os.remove(path)
        return io.open(path, "r") == nil
    end
    local marker = io.open(path .. ".new", "w")
    if not marker then
        return false
    end
    local written = marker:write(table.concat(ports, "\n"), "\n")
    if not marker:close() or not written then
        os.remove(path .. ".new")
        return false
    end
    if not os.rename(path .. ".new", path) then
        os.remove(path .. ".new")
        return false
    end
    return true
end

-- The exit code of a command: os.execute gives the raw status in Lua 5.1 and a triple in 5.2 mode.
local function run(command)
    local status, _, code = os.execute(command)
    if type(status) == "number" then
        return status >= 256 and math.floor(status / 256) or status
    end
    return status == true and 0 or (code or 1)
end

-- Incoming connections are accepted only from private networks, so the rule alone keeps the page off any
-- other network, whatever the plugin's access does.
local function rule_specs(port)
    local specs = {}
    for _, network in ipairs(PRIVATE_NETWORKS) do
        specs[#specs + 1] = string.format("INPUT -s %s -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT", network, port)
        specs[#specs + 1] = string.format("OUTPUT -d %s -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT", network, port)
    end
    return specs
end

-- Deletes every copy of the rules of a port. True only when iptables answered "no such rule" for each one,
-- so a failure for any other reason (a missing iptables, a refused command) keeps the port in the marker.
local function remove_rules(port)
    local removed = true
    for _, spec in ipairs(rule_specs(port)) do
        local code
        for _ = 1, 10 do
            code = run("iptables -D " .. spec .. " 2>/dev/null")
            if code ~= 0 then
                break
            end
        end
        removed = removed and code == 1
    end
    return removed
end

local function add_rules(port)
    for _, spec in ipairs(rule_specs(port)) do
        if run("iptables -A " .. spec .. " 2>/dev/null") ~= 0 then
            return false
        end
    end
    return true
end

local function without(ports, port)
    local kept = {}
    for _, value in ipairs(ports) do
        if value ~= port then
            kept[#kept + 1] = value
        end
    end
    return kept
end

local function on_kindle()
    return require("device"):isKindle()
end

-- id: the plugin identifier, which names the marker file. Call it when main.lua loads: a crash or a
-- forced quit with a port open skips the cleanup, and only this closes it. A port whose rules could not be
-- removed stays in the marker for the next start.
function Lan.install(id)
    assert(type(id) == "string" and id ~= "", "lan: the plugin id is required")
    Lan.id = id
    if Lan.recovered then
        return
    end
    Lan.recovered = true
    if not on_kindle() then
        return
    end
    local left = {}
    for _, port in ipairs(read_ports()) do
        if not remove_rules(port) then
            left[#left + 1] = port
        end
    end
    write_ports(left)
end

-- The Kindle firewall drops incoming connections, so the port is opened only while the page is served.
-- Elsewhere this does nothing and returns true. The port is listed in the marker before any rule is added,
-- and nothing is opened when the marker cannot be written. Returns false when the port is not open; the
-- rules added on the way are removed again.
function Lan.open_firewall(port)
    assert(Lan.id, "lan: call Lan.install(id) when main.lua loads")
    if not on_kindle() then
        return true
    end
    local ports = without(read_ports(), port)
    ports[#ports + 1] = port
    if not write_ports(ports) then
        return false
    end
    if not remove_rules(port) or not add_rules(port) then
        Lan.close_firewall(port)
        return false
    end
    return true
end

-- Returns false when a rule could not be removed. The port then stays in the marker, and the next
-- Lan.install tries again.
function Lan.close_firewall(port)
    assert(Lan.id, "lan: call Lan.install(id) when main.lua loads")
    if not on_kindle() then
        return true
    end
    if not remove_rules(port) then
        return false
    end
    write_ports(without(read_ports(), port))
    return true
end

return Lan
