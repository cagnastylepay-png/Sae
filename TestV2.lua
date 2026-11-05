-- Ovora observer: passive reporting and typed server relocation only.
local O={Connections={},Enabled=true,Serial=0,Destroyed=false,Ready=false,IdentityReady=false,EggDirty=true,PlayerDirty=true,
 EggRevision=0,PlayerRevision=0,NextConnect=0,Backoff=2,NextHop=0,Tried={}}
local Players=game:GetService("Players")
local Http=game:GetService("HttpService")
local RS=game:GetService("ReplicatedStorage")
local Teleport=game:GetService("TeleportService")
local player=Players.LocalPlayer
if not player then return end
if shared.__AutoSAEController and type(shared.__AutoSAEController.Destroy)=="function" then
 pcall(shared.__AutoSAEController.Destroy)
end
local gui=Instance.new("ScreenGui")
gui.Name="OvoraObserver";gui.ResetOnSpawn=false;gui.DisplayOrder=1000
local icon=Instance.new("TextLabel")
icon.Name="Status";icon.Size=UDim2.fromOffset(44,44);icon.Position=UDim2.new(1,-54,0,60)
icon.BackgroundColor3=Color3.fromRGB(210,160,45);icon.Text="OV";icon.TextSize=17
icon.TextColor3=Color3.new(1,1,1);icon.Font=Enum.Font.GothamBold;icon.Parent=gui
local corner=Instance.new("UICorner");corner.CornerRadius=UDim.new(1,0);corner.Parent=icon
local toggle=Instance.new("TextButton")
toggle.Name="ObserverToggle";toggle.Size=UDim2.fromOffset(68,34);toggle.Position=UDim2.new(1,-132,0,65)
toggle.Text="ON";toggle.TextSize=16;toggle.Font=Enum.Font.GothamBold
toggle.TextColor3=Color3.new(1,1,1);toggle.BackgroundColor3=Color3.fromRGB(70,175,90);toggle.Parent=gui
local toggleCorner=Instance.new("UICorner");toggleCorner.CornerRadius=UDim.new(0,8);toggleCorner.Parent=toggle
local statusText=Instance.new("TextLabel")
statusText.Name="ObserverStatus";statusText.Size=UDim2.fromOffset(250,54)
statusText.Position=UDim2.new(1,-260,0,110);statusText.BackgroundTransparency=0.2
statusText.BackgroundColor3=Color3.fromRGB(20,25,35);statusText.TextColor3=Color3.new(1,1,1)
statusText.Font=Enum.Font.Gotham;statusText.TextSize=12;statusText.TextWrapped=true
statusText.Text="Initialisation de l'observateur";statusText.Parent=gui
gui.Parent=player:WaitForChild("PlayerGui")
function O.Status(status,good)
 if O.Destroyed then return end
 statusText.Text=O.Enabled and tostring(status)or "Observateur OFF"
 toggle.Text=O.Enabled and "ON"or "OFF"
 toggle.BackgroundColor3=O.Enabled and Color3.fromRGB(70,175,90)or Color3.fromRGB(95,100,110)
 if not O.Enabled then
  icon:SetAttribute("Status","Observateur OFF");icon.BackgroundColor3=Color3.fromRGB(95,100,110)
  return
 end
 icon:SetAttribute("Status",status)
 icon.BackgroundColor3=good and Color3.fromRGB(70,175,90) or Color3.fromRGB(210,160,45)
end
function O.Connect(signal,callback)
 if not signal then return end
 local ok,connection=pcall(function()return signal:Connect(callback)end)
 if ok then table.insert(O.Connections,connection)end
end
function O.Disconnect()
 O.Ready=false;O.IdentityReady=false;O.Connecting=false;O.EggAckRevision=nil;O.Relocation=nil
 O.Destination=nil;O.DestinationRequest=nil;O.DestinationRequestedAt=nil
 local socket=O.Socket;O.Socket=nil
 if socket then pcall(function()socket:Close()end)end
 O.NextConnect=os.clock()+O.Backoff;O.Backoff=math.min(60,O.Backoff*2)
 O.Status("Reconnexion",false)
end
function O.SetEnabled(enabled)
 if O.Destroyed or O.Enabled==enabled then return end
 O.Enabled=enabled;O.Serial=O.Serial+1
 O.Disconnect();O.PendingAt=nil
 O.PlayerDirty=true;O.EggDirty=true;O.ForcePlayers=true;O.ForceEggs=true
 if enabled then
  O.NextConnect=0;O.NextHop=0;O.Backoff=2;O.Status("Connexion",false)
  if O.Initialized then O.Refresh()end
 else O.Status("Observateur OFF",false)end
end
O.Connect(toggle.Activated,function()O.SetEnabled(not O.Enabled)end)
function O.Destroy()
 if O.Destroyed then return end
 O.Destroyed=true
 for _,connection in ipairs(O.Connections)do pcall(function()connection:Disconnect()end)end
 if O.Socket then pcall(function()O.Socket:Close()end)end
 gui:Destroy()
end
shared.__AutoSAEController={Destroy=O.Destroy,Gui=gui,Reporting=O}
O.Connect(gui.Destroying,O.Destroy)
local function module(path)
 local node=RS
 for part in path:gmatch("[^.]+")do node=node:WaitForChild(part,30);if not node then error("Module absent: "..path)end end
 return require(node)
end
local ok,err=pcall(function()
 O.EggState=module("Client.EggState");O.Assets=module("Data.Assets")
 O.Records=module("Shared.Util.EggRecords");O.Earnings=module("Shared.Util.AssetEarnings")
 O.Cycle=module("Shared.Util.AreaEggCycle");O.Clock=module("Shared.Util.ServerClock")
 O.Items=module("Shared.Util.AssetItems");O.Balance=module("Shared.Flags.GameplayBalance")
end)
if not ok then O.Status("Initialisation impossible",false);return end
for key,path in pairs({Roster="Client.AssetRoster",Projection="Client.SpeedPowerProjection",Save="Shared.Save"})do
 local loaded,value=pcall(module,path);if loaded then O[key]=value end
end
local function metric(value)
 return type(value)=="number" and value==value and value>=0 and value<math.huge and value or nil
end
local function safe(fn,...)
 if type(fn)~="function"then return nil end
 local success,value=pcall(fn,...);return success and value or nil
end
function O.Encode(message,key,rows)
 local encoded={}
 for _,row in ipairs(rows)do table.insert(encoded,Http:JSONEncode(row))end
 return Http:JSONEncode(message):sub(1,-2)..',"'..key..'":['..table.concat(encoded,",")..']}'
end
function O.Send(message,key,rows)
 if not O.Enabled or not O.Socket then return false end
 local success=pcall(function()
  O.Socket:Send(key and O.Encode(message,key,rows)or Http:JSONEncode(message))
 end)
 if not success then O.Disconnect()end
 return success
end
O.Session=Http:GenerateGUID(false)
function O.Header(kind,moduleId,revision)
 return {version=1,type=kind,moduleId=moduleId,sessionId=O.Session,revision=revision,
 placeId=tostring(game.PlaceId),jobId=game.JobId}
end
function O.Players()
 local rows,incomes={},{}
 local snapshot=O.Roster and safe(O.Roster.ReadSnapshot)
 for _,owner in ipairs(snapshot or {})do
  local total,known=0,false
  for _,record in pairs(owner.Records or {})do
   local rate=metric(record.MoneyPerSecond)
   if rate then total=total+rate;known=true end
  end
  if known then incomes[tostring(owner.OwnerUserId)]=total end
 end
 local profile=O.Save and safe(O.Save.Peek)
 for _,target in ipairs(Players:GetPlayers())do
  local row={userId=tostring(target.UserId),name=target.Name,displayName=target.DisplayName}
  if target==player then
   row.speedPower=metric(O.Projection and safe(O.Projection.ReadProjected))
    or metric(type(profile)=="table" and profile.SpeedPower)
  end
  row.speedPower=row.speedPower or metric(target:GetAttribute("SpeedPower"))
  local stats=target:FindFirstChild("leaderstats")
  local value=stats and (stats:FindFirstChild("SpeedPower")or stats:FindFirstChild("Speed"))
  if not row.speedPower and value and value:IsA("ValueBase")then row.speedPower=metric(value.Value)end
  row.incomePerSecond=incomes[row.userId]
  table.insert(rows,row)
 end
 table.sort(rows,function(a,b)return a.userId<b.userId end)
 return rows
end
function O.Eggs()
 local snapshot=O.EggState.ReadFieldEggs()
 if not snapshot or type(snapshot.Records)~="table"then return nil end
 local eggs={}
 for key,record in pairs(snapshot.Records)do
  if type(record)=="table"and record.AssetCategory then
   local config=O.Assets.Directory[record.AssetCategory]or {}
   local rarity=config.Rarity
   if type(rarity)=="table"then rarity=rarity._id or rarity.Id or rarity.Name end
   local item=safe(O.Records.ToAssetItemData,record)
   local egg={uid=tostring(record.Uid or key),category=record.AssetCategory,
    name=config.DisplayName or record.AssetCategory,rarity=tostring(rarity or "Unknown"),
    state=record.State,carrierUserId=metric(record.CarrierUserId),
    observationOnly=record.ObservationOnly==true,
    weightKg=metric(safe(O.Records.WeightKgForScale,record.AssetCategory,record.AssetScale)),
    incomePerSecond=metric(item and safe(O.Earnings.RatePerSecond,item))}
   egg.sellValue=metric(safe(O.Records.SellPrice,record))
   if not egg.sellValue and item then
    item=table.clone(item);item.Mutations={};item.BaseMutation=nil
    egg.sellValue=metric(safe(function()return O.Items.SalePrice(item)*O.Balance.Eggs.SELL_PRICE_SHARE end))
   end
   table.insert(eggs,egg)
  end
 end
 table.sort(eggs,function(a,b)return a.uid<b.uid end)
 return eggs
end
function O.Refresh()
 if not O.Enabled or O.Syncing then return end
 O.Phase="Synchronisation des oeufs"
 local cycle=tostring(O.Cycle.ActivePeriodIndexAt(O.Clock.Now()))
 O.Syncing=true
 task.spawn(function()
  local success=pcall(O.EggState.SyncFieldEggs)
  O.Syncing=false;O.EggDirty=true;O.ForceEggs=true
  if success then O.SnapshotCycle=cycle else O.NextSync=os.clock()+10;O.Status("Snapshot indisponible : nouvel essai dans 10 s",false)end
 end)
end
local function markPlayers()O.PlayerDirty=true end
local function markEggs()O.EggDirty=true end
function O.TrackPlayer(target)
 O.Connect(target.AttributeChanged,markPlayers)
 O.Connect(target:GetPropertyChangedSignal("DisplayName"),markPlayers)
 local function trackStats(stats)
  if stats.Name~="leaderstats"then return end
  local function trackValue(value)
   if value:IsA("ValueBase")then O.Connect(value.Changed,markPlayers)end
   markPlayers()
  end
  for _,value in ipairs(stats:GetChildren())do trackValue(value)end
  O.Connect(stats.ChildAdded,trackValue);O.Connect(stats.ChildRemoved,markPlayers)
 end
 for _,child in ipairs(target:GetChildren())do trackStats(child)end
 O.Connect(target.ChildAdded,trackStats)
 markPlayers()
end
for _,target in ipairs(Players:GetPlayers())do O.TrackPlayer(target)end
O.Connect(Players.PlayerAdded,O.TrackPlayer);O.Connect(Players.PlayerRemoving,markPlayers)
if O.Roster then O.Connect(O.Roster.SnapshotRefreshed,markPlayers)end
if O.Projection then O.Connect(O.Projection.Changed,markPlayers)end
if O.Save and type(O.Save.Watch)=="function"then
 local signal=safe(O.Save.Watch,"SpeedPower");O.Connect(signal,markPlayers)
end
for _,name in ipairs({"FieldRefreshed","FieldShifted","FieldGone","RarityRevealed"})do O.Connect(O.EggState[name],markEggs)end
function O.ShouldRelocate(serial)
 local message=O.Relocation
 if not O.Enabled or (serial~=nil and serial~=O.Serial)or not O.Ready or not O.IdentityReady or not message or not message.relocate
  or message.placeId~=tostring(game.PlaceId)or message.jobId~=game.JobId then return false end
 -- Never leave until Render has accepted the latest complete egg snapshot.
 return message.mode=="roam" and O.EggAckRevision==O.EggRevision and O.EggRevision>0
  and not O.EggDirty and not O.PlayerDirty and not O.Syncing
end
function O.AcceptDestination(message)
     if message.requestId~=O.DestinationRequest then return end
     O.DestinationRequest=nil;O.DestinationRequestedAt=nil
     if message.placeId~=tostring(game.PlaceId)or message.jobId~=game.JobId or not O.ShouldRelocate()then return end
     local target=message.target
     if type(target)~="table"then
      O.NextHop=os.clock()+math.clamp(tonumber(message.retryAfter)or 5,5,300)
      O.Status(message.status and ("Recherche Render : "..tostring(message.status))or "Render poursuit la recherche (2 a 5 joueurs)",false)
      return
     end
     if target.placeId~=tostring(game.PlaceId)or type(target.jobId)~="string"or target.jobId==game.JobId
      or type(target.playing)~="number"or target.playing<2 or target.playing>5
      or type(target.leaseId)~="string"or type(target.expiresAt)~="number"or type(message.serverTime)~="number"then return end
     local remaining=(target.expiresAt-message.serverTime)/1000
     if remaining<=0 or remaining>180 then return end
     target.Deadline=os.clock()+remaining;O.Destination=target;O.NextHop=0
end
function O.RequestDestination()
 if O.DestinationRequest or not O.ShouldRelocate()or os.clock()<O.NextHop then return end
 local id=Http:GenerateGUID(false)
 O.DestinationRequest=id;O.DestinationRequestedAt=os.clock()
 O.Status("Render recherche un serveur de 2 a 5 joueurs",false)
 if not O.Send({version=1,type="observer.next",requestId=id})then O.DestinationRequest=nil end
end
function O.FailDestination(detail)
 local lease=O.CurrentLease
 O.CurrentLease=nil;O.Destination=nil;O.HopBusy=false
 O.NextHop=os.clock()+10
 if lease then O.Send({version=1,type="observer.result",leaseId=lease.leaseId,failed=true})end
 O.LastError=tostring(detail)
 O.Status("Teleportation refusee : "..O.LastError.."; autre serveur via Render",false)
end
function O.Relocate()
 if O.HopBusy or os.clock()<O.NextHop or not O.ShouldRelocate()then return end
 local destination=O.Destination
 if not destination then O.RequestDestination();return end
 if os.clock()>=destination.Deadline or O.Tried[destination.jobId]then O.Destination=nil;O.RequestDestination();return end
 for _,id in ipairs(O.Relocation.avoidJobIds or {})do
  if id==destination.jobId then O.Destination=nil;O.Send({version=1,type="observer.result",leaseId=destination.leaseId,failed=true});O.NextHop=os.clock()+5;return end
 end
 local serial=O.Serial
 O.HopBusy=true;O.CurrentLease=destination
 task.spawn(function()
  local success,failure=pcall(function()
   local env=type(getgenv)=="function"and getgenv()or getfenv()
   local queue=env.queue_on_teleport or env.queueonteleport or (env.syn and env.syn.queue_on_teleport)
   if type(queue)~="function"then error("Rechargement automatique indisponible")end
   if not O.Queued then
    queue('loadstring(game:HttpGet("https://raw.githubusercontent.com/cagnastylepay-png/Sae/main/TestV2.lua"))()')
    O.Queued=true
   end
   if not O.ShouldRelocate(serial)or O.Destination~=destination then O.HopBusy=false;return end
   O.Tried[destination.jobId]=true;O.LastDestination=destination.jobId
   O.Status("Teleportation Render : "..destination.playing.." joueurs observes",false)
   Teleport:TeleportToPlaceInstance(game.PlaceId,destination.jobId,player)
   task.wait(30)
   if not O.Destroyed and serial==O.Serial and O.CurrentLease==destination then O.FailDestination("Connexion non terminee apres 30 s")end
  end)
  if not success and serial==O.Serial then O.FailDestination(failure)end
 end)
end
O.Connect(Teleport.TeleportInitFailed,function(target,result,message)
 if target==player then O.FailDestination(tostring(result)..": "..tostring(message))end
end)
function O.OpenSocket()
 if not O.Enabled or O.Connecting or O.Destroyed then return end
 local serial=O.Serial
 O.Connecting=true;O.LastAck=os.clock()
 task.spawn(function()
  local success=pcall(function()
   local env=type(getgenv)=="function"and getgenv()or getfenv()
   local api=env.WebSocket or env.websocket or (env.syn and env.syn.websocket)
   local connector=api and (api.connect or api.Connect)
   if type(connector)~="function"then error("WebSocket indisponible")end
   local socket=connector("wss://m4gix-ws.onrender.com/sae/ws")
   if O.Destroyed or not O.Enabled or serial~=O.Serial then socket:Close();return end
   O.Socket=socket
   O.Connect(socket.OnClose,function()if O.Socket==socket then O.Disconnect()end end)
   O.Connect(socket.OnMessage,function(raw)
    if O.Destroyed or not O.Enabled or serial~=O.Serial or O.Socket~=socket then return end
    local decoded,message=pcall(Http.JSONDecode,Http,raw)
    if not decoded or type(message)~="table"or message.version~=1 then return end
    if message.type=="hello.ack"then
     O.Ready=true;O.Connecting=false;O.Backoff=2;O.LastAck=os.clock()
     O.PlayerDirty=true;O.EggDirty=true;O.ForcePlayers=true;O.ForceEggs=true
    elseif message.type=="players.ack"then O.IdentityReady=true;O.LastAck=os.clock();O.PendingAt=nil
    elseif message.type=="eggs.ack"then
     O.LastAck=os.clock();O.PendingAt=nil
     if message.accepted==true and message.sessionId==O.Session and message.revision==O.EggRevision then
      O.EggAckRevision=message.revision;O.Status("Observation transmise",true)
     end
    elseif message.type=="observer.destination"then
     O.AcceptDestination(message)
    elseif message.type=="observer.relocate"then
     O.Relocation=message
     if message.mode=="hold"then
      O.Destination=nil;O.DestinationRequest=nil;O.DestinationRequestedAt=nil
      O.Status("En attente du favori : maintien du serveur",true)
     elseif message.mode=="roam"then O.Status("Exploration des serveurs",true)end
    elseif message.type=="error"then O.Disconnect()
    end
   end)
   O.Send({version=1,type="hello",role="reporter",reporterUserId=tostring(player.UserId),observerOnly=true,observerRouting="render"})
  end)
  if serial~=O.Serial or O.Destroyed or not O.Enabled then return end
  if not success then O.Disconnect();O.Status("Socket : "..tostring(failure):sub(1,140),false)end
 end)
end
O.Initialized=true
O.Refresh()
function O.Step()
 if not O.Enabled then return end
  local now=os.clock()
  O.Phase="Lecture du cycle"
  local cycle=tostring(O.Cycle.ActivePeriodIndexAt(O.Clock.Now()))
  if cycle~=O.CurrentCycle then O.CurrentCycle=cycle;O.Tried={};O.Refresh()end
  if not O.Syncing and O.SnapshotCycle~=cycle and now>=(O.NextSync or 0)then O.Refresh()end
  if not O.Socket and not O.Connecting and now>=O.NextConnect then O.OpenSocket()end
  if O.Connecting and now-O.LastAck>20 then O.Disconnect()end
  if O.PendingAt and now-O.PendingAt>25 then O.PendingAt=nil;O.Disconnect()end
  if O.Ready and game.JobId~=""then
   if O.PlayerDirty and now-(O.LastPlayers or 0)>=1 then
    O.Phase="Lecture des joueurs"
    local rows=O.Players();local fingerprint=Http:JSONEncode(rows)
    if O.ForcePlayers or fingerprint~=O.PlayerFingerprint then
     O.PlayerRevision=O.PlayerRevision+1
     local message=O.Header("players.snapshot","PlayerReporter",O.PlayerRevision)
     message.reporterUserId=tostring(player.UserId)
     if O.Send(message,"players",rows)then O.PlayerFingerprint=fingerprint;O.ForcePlayers=false;O.PendingAt=O.PendingAt or now end
    end
    O.PlayerDirty=false;O.LastPlayers=now
   end
   if O.IdentityReady and O.SnapshotCycle==cycle and not O.Syncing and O.EggDirty and now-(O.LastEggs or 0)>=1 then
    O.Phase="Lecture des oeufs"
    local rows=O.Eggs()
    if rows then
     local fingerprint=cycle..Http:JSONEncode(rows)
     if O.ForceEggs or fingerprint~=O.EggFingerprint then
      O.EggRevision=O.EggRevision+1
      local message=O.Header("eggs.snapshot","EggReporter",O.EggRevision)
      message.cycleId=cycle;message.observedAt=os.date("!%Y-%m-%dT%H:%M:%SZ")
      message.cycleEndsAt=O.Cycle.NextNightTime(O.Clock.Now())
      if O.Send(message,"eggs",rows)then O.EggFingerprint=fingerprint;O.ForceEggs=false;O.PendingAt=O.PendingAt or now end
     end
     O.EggDirty=false;O.LastEggs=now
    end
   end
  end
  if O.DestinationRequestedAt and now-O.DestinationRequestedAt>20 then
   O.DestinationRequest=nil;O.DestinationRequestedAt=nil;O.NextHop=now+5
   O.Status("Attente de Render : nouvelle demande dans 5 s",false)
  end
  O.Phase="Destination fournie par Render"
  O.Relocate()
end
task.spawn(function()
 while not O.Destroyed do
  local success,failure=xpcall(O.Step,debug.traceback)
  if not success then
   O.LastError=tostring(failure)
   O.Status(tostring(O.Phase or "Observateur").." : "..tostring(failure):sub(1,140),false)
   task.wait(2)
  end
  task.wait(0.5)
 end
end)
return O
