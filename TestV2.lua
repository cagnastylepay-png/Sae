-- Launch the maintained SEA_V2 Observer.
local url = "https://raw.githubusercontent.com/cagnastylepay-png/SEA_V2/main/Scripts/Observer.lua"
assert(type(loadstring) == "function", "OVORA: loadstring indisponible")
local downloaded, source = pcall(function()
 return game:HttpGet(url)
end)
assert(downloaded and type(source) == "string" and #source > 0,
 "OVORA: impossible de charger Observer.lua : " .. tostring(source))
local run, compileError = loadstring(source, "SEA_V2/Scripts/Observer.lua")
assert(run, "OVORA: compilation Observer.lua : " .. tostring(compileError))
return run()
