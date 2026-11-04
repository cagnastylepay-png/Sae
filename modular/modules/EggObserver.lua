-- Observation des œufs et synchronisation des snapshots après chaque reset.
-- Future module loads the shared library through context.LoadLibrary (loadstring + session cache).
return function(context)
 assert(type(context) == "table", "Module context required")
 local module = {Name = "EggObserver", Status = "scaffold"}
 function module:Start()
  return false, "Not migrated from Test.lua yet"
 end
 function module:Stop()
  self.Status = "stopped"
 end
 return module
end
