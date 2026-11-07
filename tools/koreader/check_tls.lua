-- Confirms that a bad certificate is refused for the right reason, with the code the plugin uses. Needs internet
-- and sends no token. A failure for any other reason, such as a timeout, is a problem and not a pass.
-- Usage: tools/koreader/run_headless.sh tools/koreader/check_tls.lua
-- On a device, from the KOReader folder: ./luajit <plugin>/tools/koreader/check_tls.lua (with PLUGIN_DIR set)
local plugin_dir = assert(os.getenv("PLUGIN_DIR"))
require("setupkoenv")
package.path = plugin_dir .. "/?.lua;" .. package.path
local Worker = require("ink_knight/https_worker")

local dir = os.tmpname()
os.remove(dir)
os.execute("mkdir -p '" .. dir .. "'")
local function try(url)
    local prefix = dir .. "/x"
    local ok, result = pcall(Worker.run, {
        url = url, method = "GET", headers = { ["user-agent"] = "InkKnight/check" }, timeout = 25,
        ca_file = "data/ca-bundle.crt",
        out_path = prefix .. ".out", code_path = prefix .. ".code",
    })
    return ok and result or tostring(result)
end

local problems = 0
-- expected: "answers" when any HTTP answer should come, or a word that the reason for the refusal must have.
local function expect(url, expected)
    local result = try(url)
    local good
    if expected == "answers" then
        good = type(result) == "number"
    else
        good = type(result) == "string" and result:find(expected, 1, true) ~= nil
    end
    print(string.format("%-58s %-42s %s", url, tostring(result), good and "ok" or "PROBLEM"))
    if not good then
        problems = problems + 1
    end
end
expect("https://lichess.org/api/puzzle/daily", "answers")
expect("https://explorer.lichess.org/lichess?moves=1", "answers")
expect("https://tablebase.lichess.org/standard?fen=4k3/6KP/8/8/8/8/7p/8_w_-_-_0_1", "answers")
expect("https://expired.badssl.com/", "certificate verify failed")
expect("https://self-signed.badssl.com/", "certificate verify failed")
expect("https://untrusted-root.badssl.com/", "certificate verify failed")
expect("https://wrong.host.badssl.com/", "hostname does not match")
os.execute("rm -rf '" .. dir .. "'")
print("problems: " .. problems)
os.exit(problems == 0 and 0 or 1)
