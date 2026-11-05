-- Ovora observer: passive reporting and typed server relocation only.
local O={Connections={},Destroyed=false,Ready=false,IdentityReady=false,EggDirty=true,PlayerDirty=true,
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
gui.Parent=player:WaitForChild("PlayerGui")
function O.Status(status,good)
 if O.Destroyed then return end
 icon:SetAttribute("Status",status)
 icon.BackgroundColor3=good and Color3.fromRGB(70,175,90) or Color3.fromRGB(210,160,45)
end
function O.Connect(signal,callback)
 if not signal then return end
 local ok,connection=pcall(function()return signal:Connect(callback)end)
 if ok then table.insert(O.Connections,connection)end
end
function O.Disconnect()
 O.Ready=false;O.IdentityReady=false;O.Connecting=false
 local socket=O.Socket;O.Socket=nil
 if socket then pcall(function()socket:Close()end)end
 O.NextConnect=os.clock()+O.Backoff;O.Backoff=math.min(60,O.Backoff*2)
 O.Status("Reconnexion",false)
end
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
 if not O.Socket then return false end
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
 if O.Syncing then return end
 local cycle=tostring(O.Cycle.ActivePeriodIndexAt(O.Clock.Now()))
 O.Syncing=true
 task.spawn(function()
  local success=pcall(O.EggState.SyncFieldEggs)
  O.Syncing=false;O.EggDirty=true;O.ForceEggs=true
  if success then O.SnapshotCycle=cycle else O.NextSync=os.clock()+10 end
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
function O.ShouldRelocate()
 local message=O.Relocation
 if not message or not message.relocate or message.placeId~=tostring(game.PlaceId)or message.jobId~=game.JobId then return false end
 local favorites={}
 for _,id in ipairs(message.favoriteUserIds or {})do favorites[tostring(id)]=true end
 for _,target in ipairs(Players:GetPlayers())do
  if target~=player and favorites[tostring(target.UserId)]then return true end
 end
 return false
end
function O.Relocate()
 if O.HopBusy or os.clock()<O.NextHop or not O.ShouldRelocate()then return end
 O.HopBusy=true;O.NextHop=os.clock()+30
 task.spawn(function()
  local success=pcall(function()
   local env=type(getgenv)=="function"and getgenv()or getfenv()
   local requestFn=env.request or env.http_request or (env.syn and env.syn.request)
   local avoid={[game.JobId]=true}
   for _,id in ipairs(O.Relocation.avoidJobIds or {})do avoid[id]=true end
   local candidates,cursor={},nil
   for _=1,3 do
    if not O.ShouldRelocate()then return end
    local url="https://games.roblox.com/v1/games/"..game.PlaceId.."/servers/Public?sortOrder=Asc&limit=100"
    if cursor then url=url.."&cursor="..Http:UrlEncode(cursor)end
    local body
    if requestFn then
     local response=requestFn({Url=url,Method="GET"})
     if response.StatusCode~=200 then error("Liste serveurs indisponible")end
     body=response.Body
    else body=game:HttpGet(url)end
    local data=Http:JSONDecode(body)
    for _,server in ipairs(data.data or {})do
     if type(server.id)=="string"and not avoid[server.id]and not O.Tried[server.id]
      and type(server.playing)=="number"and type(server.maxPlayers)=="number"
      and server.playing<math.min(7,server.maxPlayers)then
      table.insert(candidates,{id=server.id,playing=server.playing,tie=math.random()})
     end
    end
    cursor=data.nextPageCursor
    if #candidates>0 or not cursor then break end
   end
   table.sort(candidates,function(a,b)return a.playing==b.playing and a.tie<b.tie or a.playing<b.playing end)
   local destination=candidates[1]
   if not destination or not O.ShouldRelocate()then return end
   local queue=env.queue_on_teleport or env.queueonteleport or (env.syn and env.syn.queue_on_teleport)
   if type(queue)~="function"then O.Status("Rechargement automatique indisponible",false);return end
   if not O.Queued then
    queue('loadstring(game:HttpGet("https://raw.githubusercontent.com/cagnastylepay-png/Sae/main/TestV2.lua"))()')
    O.Queued=true
   end
   if not O.ShouldRelocate()then return end
   for _,id in ipairs(O.Relocation.avoidJobIds or {})do if id==destination.id then return end end
   O.Tried[destination.id]=true;O.Status("Changement de serveur",false)
   Teleport:TeleportToPlaceInstance(game.PlaceId,destination.id,player)
   task.wait(25)
  end)
  O.HopBusy=false
  if not success then O.Status("Nouvelle tentative de serveur",false)end
 end)
end
O.Connect(Teleport.TeleportInitFailed,function(target)
 if target==player then O.HopBusy=false;O.NextHop=os.clock()+30 end
end)
function O.OpenSocket()
 if O.Connecting or O.Destroyed then return end
 O.Connecting=true;O.LastAck=os.clock()
 task.spawn(function()
  local success=pcall(function()
   local env=type(getgenv)=="function"and getgenv()or getfenv()
   local api=env.WebSocket or env.websocket or (env.syn and env.syn.websocket)
   local connector=api and (api.connect or api.Connect)
   if type(connector)~="function"then error("WebSocket indisponible")end
   local socket=connector("wss://m4gix-ws.onrender.com/sae/ws")
   if O.Destroyed then socket:Close();return end
   O.Socket=socket
   O.Connect(socket.OnClose,function()if O.Socket==socket then O.Disconnect()end end)
   O.Connect(socket.OnMessage,function(raw)
    if O.Destroyed or O.Socket~=socket then return end
    local decoded,message=pcall(Http.JSONDecode,Http,raw)
    if not decoded or type(message)~="table"or message.version~=1 then return end
    if message.type=="hello.ack"then
     O.Ready=true;O.Connecting=false;O.Backoff=2;O.LastAck=os.clock()
     O.PlayerDirty=true;O.EggDirty=true;O.ForcePlayers=true;O.ForceEggs=true
    elseif message.type=="players.ack"then O.IdentityReady=true;O.LastAck=os.clock();O.PendingAt=nil
    elseif message.type=="eggs.ack"then O.LastAck=os.clock();O.PendingAt=nil;O.Status("Observation active",true)
    elseif message.type=="observer.relocate"then
     O.Relocation=message
    elseif message.type=="error"then O.Disconnect()
    end
   end)
   O.Send({version=1,type="hello",role="reporter",reporterUserId=tostring(player.UserId),observerOnly=true})
  end)
  if not success then O.Disconnect()end
 end)
end
O.Refresh()
task.spawn(function()
 while not O.Destroyed do
  local now=os.clock()
  local cycle=tostring(O.Cycle.ActivePeriodIndexAt(O.Clock.Now()))
  if cycle~=O.CurrentCycle then O.CurrentCycle=cycle;O.Tried={};O.Refresh()end
  if not O.Syncing and O.SnapshotCycle~=cycle and now>=(O.NextSync or 0)then O.Refresh()end
  if not O.Socket and not O.Connecting and now>=O.NextConnect then O.OpenSocket()end
  if O.Connecting and now-O.LastAck>20 then O.Disconnect()end
  if O.PendingAt and now-O.PendingAt>25 then O.PendingAt=nil;O.Disconnect()end
  if O.Ready and game.JobId~=""then
   if O.PlayerDirty and now-(O.LastPlayers or 0)>=1 then
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
  O.Relocate()
  task.wait(0.5)
 end
end)
return O
