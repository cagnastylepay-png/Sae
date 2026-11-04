-- API migration catalogue, not functional replacements for Test.lua.
return {
 Status = "scaffold",
 ApiVersion = 1,
 Planned = {
  Game = {"LoadModules", "ReadProfile", "ReadCharacter"},
  Eggs = {"ReadField", "ReadOwned", "GetRarity", "GetWeightKg", "GetRatePerSecond", "ObserveCycle"},
  Movement = {"Move", "Stop", "LeaveTreadmill", "EnterTreadmill"},
  Collection = {"Eligibility", "Queue", "Collect", "ConfirmOwnership"},
  Inventory = {"OpenReady", "Place", "Sell", "EquipBest", "Fuse"},
  Servers = {"List", "ChooseLeastPopulated", "RememberVisited", "Teleport"},
  Storage = {"ReadSettings", "SaveSettings", "AppendLog"},
  Network = {"Connect", "Send", "Subscribe", "Disconnect"},
 },
 -- Future context.LoadLibrary uses loadstring and caches one instance per loader session.
}
