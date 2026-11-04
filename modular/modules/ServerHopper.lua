-- Sélection des serveurs les moins peuplés, historique réinitialisé par cycle, continuation.
-- Future module loads the shared library through context.LoadLibrary (loadstring + session cache).
return function(context)
 assert(type(context) == "table", "Module context required")
 local module = {Name = "ServerHopper", Status = "scaffold"}
 function module:Start()
  return false, "Not migrated from Test.lua yet"
 end
 function module:Stop()
  self.Status = "stopped"
 end
 return module
end
