-- Launch the maintained SEA_V2 Hub.
local url = "https://raw.githubusercontent.com/cagnastylepay-png/SEA_V2/main/Scripts/Hub.lua"
assert(type(loadstring) == "function", "OVORA: loadstring indisponible")
local downloaded, source = pcall(function()
 return game:HttpGet(url)
end)
assert(downloaded and type(source) == "string" and #source > 0,
 "OVORA: impossible de charger Hub.lua : " .. tostring(source))
local run, compileError = loadstring(source, "SEA_V2/Scripts/Hub.lua")
assert(run, "OVORA: compilation Hub.lua : " .. tostring(compileError))
return run()
