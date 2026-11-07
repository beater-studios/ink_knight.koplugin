-- The entry of a request as its own program, used only on macOS, where a forked child cannot use the network.
-- It receives the plugin folder and a file with the request, which it deletes as soon as it is read.
local plugin_dir, spec_path = arg[1], arg[2]
require("setupkoenv")
package.path = plugin_dir .. "/?.lua;" .. package.path
local file = assert(io.open(spec_path, "rb"))
local text = file:read("*a")
file:close()
os.remove(spec_path)
require("ink_knight/https_worker").run(require("rapidjson").decode(text))
