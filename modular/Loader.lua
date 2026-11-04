-- Planning manifest only. Does not start modules or execute Test.lua.
return {
 Status = "scaffold",
 Library = "modular/lib/NotreLib.lua",
 Config = "modular/config/Defaults.lua",
 Modules = {
  "WebSocketClient", "EggObserver", "EggReporter", "EggVisualizer",
  "EggCollector", "InventoryManager", "ButterflyCollector", "ServerHopper",
 },
 -- Planned: pin a commit, compile each file with loadstring, inject context.LoadLibrary.
}
