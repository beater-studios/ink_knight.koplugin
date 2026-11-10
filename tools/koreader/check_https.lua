-- Pattern "https". This file is copied unchanged into every
-- plugin that has the pattern, as tools/koreader/check_https.lua: change the pattern first.
--
-- Checks <id>/tls.lua and <id>/https_request.lua with real connections: good certificates are answered, bad
-- ones are refused for the right reason, a redirect is not followed and a request in a child process ends
-- with its files. Needs internet and sends nothing private. A failure for any other reason, such as a
-- timeout, is a problem and not a pass. The plugin id is the folder that holds https_request.lua.
-- Usage: KOREADER_DIR=<desktop KOReader> tools/koreader/run_headless.sh tools/koreader/check_https.lua
-- On the Kindle the package has no tools/, so copy this file to /tmp and, from the KOReader folder, run
-- PLUGIN_DIR=<installed plugin folder> ./luajit /tmp/check_https.lua
local plugin_dir = assert(os.getenv("PLUGIN_DIR"))
require("setupkoenv")
package.path = plugin_dir .. "/?.lua;" .. package.path
local lfs = require("libs/libkoreader-lfs")

local id
for name in lfs.dir(plugin_dir) do
    if name:sub(1, 1) ~= "." and lfs.attributes(plugin_dir .. "/" .. name .. "/https_request.lua", "mode") == "file" then
        id = name
    end
end
if not id then
    print("FAILED no <id>/https_request.lua in " .. plugin_dir)
    os.exit(1)
end
local Request = require(id .. "/https_request")
local Tls = require(id .. "/tls")

local failures = 0
local function check(good, label, detail)
    print(string.format("%-6s %s%s", good and "ok" or "FAILED", label, detail and (" (" .. tostring(detail) .. ")") or ""))
    if not good then
        failures = failures + 1
    end
end

-- The names of a certificate, without the network.
local names = { "example.org", "*.cdn.example.org", "*.com" }
check(Tls.host_matches(names, "example.org"), "the exact name matches")
check(Tls.host_matches(names, "EXAMPLE.org"), "names match whatever the case")
check(Tls.host_matches(names, "a.cdn.example.org"), "a wildcard stands for one label")
check(not Tls.host_matches(names, "a.b.cdn.example.org"), "a wildcard does not stand for two labels")
check(not Tls.host_matches(names, "cdn.example.org"), "a wildcard does not stand for nothing")
check(not Tls.host_matches(names, "evil.com"), "a wildcard over a top-level domain is refused")
check(not Tls.host_matches(names, "example.org.evil.net"), "a longer name does not match")
check(not Tls.host_matches(names, ""), "an empty host does not match")
check(not Tls.host_matches({}, "example.org"), "a certificate without alternative names matches nothing")

-- Which host an address goes to, without the network. Credentials are chosen with Request.host, and an
-- address that LuaSocket would read differently is refused before connecting.
check(Request.host("https://API.example.org/x") == "api.example.org", "the host of an address, in lowercase")
check(Request.host("https://api.example.org:8443?a=1") == "api.example.org", "a port and a query keep the host")
check(Request.host("https://api.example.org:x@evil.com/") == nil, "credentials before the host are refused")
check(Request.host("https://evil.com?@api.example.org/") == "evil.com", "an @ after the host is not read as credentials")
check(Request.host("http://api.example.org/") == nil, "an address without https is refused")
check(Request.host("https://[::1]/") == nil, "an IPv6 literal is refused")

local dir = os.tmpname()
os.remove(dir)
os.execute("mkdir -p '" .. dir .. "'")
local serial = 0
local function new_spec(url)
    serial = serial + 1
    local spec = Request.paths(dir .. "/r" .. serial)
    spec.url, spec.method, spec.timeout = url, "GET", 25
    spec.headers = { ["user-agent"] = "KOReaderPlugin/check" }
    return spec
end

-- expected: a number for that HTTP code, or a word that the reason for the refusal must have.
local function expect(url, expected)
    local spec = new_spec(url)
    local ok, result = pcall(Request.run, spec)
    result = ok and result or ("error: " .. tostring(result))
    local good
    if type(expected) == "number" then
        good = result == expected
    else
        good = type(result) == "string" and result:find(expected, 1, true) ~= nil
    end
    check(good, url, result)
    return spec
end
expect("https://api.example.org:x@badssl.com/", "address refused")
expect("https://badssl.com/", 200)
expect("https://sha256.badssl.com/", 200)
expect("https://expired.badssl.com/", "certificate verify failed")
expect("https://self-signed.badssl.com/", "certificate verify failed")
expect("https://untrusted-root.badssl.com/", "certificate verify failed")
expect("https://wrong.host.badssl.com/", "hostname does not match")

-- A redirect is answered, not followed, and where it points is in the headers.
local redirect = expect("https://github.com/koreader/koreader/releases/latest", 302)
local _, _, headers = Request.result(redirect)
local location = headers and headers.location
check(type(location) == "string" and location:find("^https://github%.com/") ~= nil, "the redirect is kept in the headers", location)

-- The way the plugin uses it: a child process, files read after it ends, and nothing left behind.
local spec = new_spec("https://badssl.com/")
local pid = Request.spawn(spec)
check(pid ~= false and pid ~= nil, "a request starts in a child process", pid)
if pid then
    local deadline = os.time() + 40
    while not Request.done(pid) and os.time() < deadline do
        os.execute("sleep 0.2")
    end
    if not Request.done(pid) then
        check(false, "the child ends within 40 s")
        Request.kill(pid)
    end
    Request.done(pid, true)
    local code, body = Request.result(spec)
    check(code == 200 and #body > 0, "the child writes the code and the body", code)
end
Request.remove(spec)
local left = 0
for name in lfs.dir(dir) do
    if name:match("^r" .. serial .. "%.") then
        left = left + 1
    end
end
check(left == 0, "removing a request leaves no file", left)
local missing = new_spec("https://badssl.com/")
missing.ca_file = dir .. "/no-certificates.crt"
check(Request.spawn(missing) == false, "without the certificates nothing starts")

os.execute("rm -rf '" .. dir .. "'")
print(failures == 0 and "https: everything as expected" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
