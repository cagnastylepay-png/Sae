-- Éligibilité, file de collecte, attribution confirmée et priorités.
-- Future module loads the shared library through context.LoadLibrary (loadstring + session cache).
return function(context)
 assert(type(context) == "table", "Module context required")
 local module = {Name = "EggCollector", Status = "scaffold"}
 function module:Start()
  return false, "Not migrated from Test.lua yet"
 end
 function module:Stop()
  self.Status = "stopped"
 end
 return module
end
