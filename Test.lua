-- Auto_SAE v2.8. SellPrompt selection UI. Verified client contracts; no character/anticheat replacement.
-- The live game must provide ReplicatedStorage.Client/Data/Shared.
-- Refresh outbound MoveTo before its native timeout; verify distance before carry.
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local player = Players.LocalPlayer
assert(player, "Auto_SAE doit etre execute sur le client")

local CONFIG = {
	Debug = true,
	ProgressInterval = 0.5,
	MoveRefresh = 0.1,
	ApproachRefresh = 4,
	ApproachDistance = 8,
	PreciseArrivalRadius = 3,
	ScanInterval = 0.25,
	ReturnDistance = 3,
	RequestTimeout = 10,
	MaxCarryAttempts = 5,
	CarryRetryDelay = 0.15,
	EnableArrivalBrake = true,
	ArrivalBrakeDuration = 0.03,
	ObserveRigSync = true,
	MotionPauseTimeout = 12,
	RigSettleTime = 0.15,
	ClaimTimeout = 12,
	NoMovementTimeout = 10,
	FailedTargetCooldown = 10,
	RecoveryStateTimeout = 30,
	RecoveryRetryDelay = 0.5,
}
local MINIMUM_BILLIONS, MAXIMUM_BILLIONS, DEFAULT_BILLIONS = 0.1, 999, 2
local SLOT_STATE = "Slot"
local CARRY_LOST = "CARRY_LOST"
local EggState, Assets, EggRecords, AssetEarnings, SlotIdentity, GuardGeometry, Save
local HalloweenPets
local ready, destroyed, autoEnabled = false, false, false
local generation = 0
local minimumRatePerSecond = DEFAULT_BILLIONS * 1e9
local records, loggedVersions, cooldowns = {}, {}, {}
local trackedEggs = {}
local lifetimeConnections = {}
local currentCycle, safeHome
local inFlightRequest = shared.__AutoSAERemoteLock
local statusLabel, toggleButton, minimumInput
local sequence = 0
local renderControls
local refreshEggInterface
local selectedEggs = {}
local automaticMode = true
local autoIncludeMissingIndex = true
local openBelowRate = 20e9
local searchingServer = false
local searchWaitForEgg = false
local AreaEggCycle, ServerClock
local serverSearchState = "OFF"
local serverHopPending = false
local serverSearchReadyAt = math.huge
local nextServerHopAt = 0
local requestRandomServerHop
local lastMaintenanceAt = -math.huge
local inventoryEggRecords
local inventoryPlacementBusy = false
local placementRequest
local GameplayBalance
local timingEnabled = false
local flightHistory = {}
local refreshFlightLog
local stopAfterFlight = false
local queuedEggs = {}
local removedFromAuto = {}
local queueDecisionLogs = {}
local lastQueueSummary
local queuePaused = false
local syncQueue, wakeQueue, refreshQueueInterface, startAutomation
local stopAutomation
local rigPause = {Character = nil, Until = 0, Reason = nil}
local syncPauseUntil, lastRelocateAt, lastPhysicalBrakeAt = 0, -math.huge, -math.huge
local movementRevision = 0
local movementResumePending = false
local PlotState, TreadmillRemotes, AssetRoster
local PlacedEggRenderer, EggGrowthPolicy
local hatchInProgress = false
local wallMaintenancePending = false
local HaulRemotes
local lastEquipBestAt = -math.huge
local detectedMode = player:GetAttribute("InHalloweenDimension") == true and "Halloween" or "Normal"
local halloweenRecords = {}
local activityRecheckPending = false
local refreshBestEggCard
local treadmillAssigned, treadmillPending = false, false
local autoActivity = "IDLE"

local function isEggInCurrentWorld(record)
	return type(record) == "table"
		and ((record.IsHalloweenObservation == true) == (detectedMode == "Halloween"))
end

-- Optional executor APIs. Capture once; never replace Roblox services or remotes.
local debugLogLines = {}
local pendingLogLines = {}
local executorEnvironment = getfenv()
if type(getgenv) == "function" then
	local ok, environment = pcall(getgenv)
	if ok and type(environment) == "table" then executorEnvironment = environment end
end
local function executorFunction(name)
	local candidate = executorEnvironment[name]
	if type(candidate) ~= "function" then candidate = getfenv()[name] end
	return type(candidate) == "function" and candidate or nil
end
local executorTools = {}
local executorLogPath = "AutoSAE_debug.txt"
function executorTools.Capabilities()
	local result = {}
	for _, name in ipairs({"fireproximityprompt", "writefile", "readfile", "openfile", "isfile", "appendfile"}) do
		result[name] = executorFunction(name) ~= nil
	end
	return result
end
local function callExecutor(name, ...)
	local fn = executorFunction(name)
	if not fn then return false, name .. " indisponible dans cet environnement" end
	return pcall(fn, ...)
end
function executorTools.SaveLog()
	if #pendingLogLines == 0 then return true, executorLogPath end
	local count = #pendingLogLines
	local payload = table.concat(pendingLogLines, "\n", 1, count) .. "\n"
	local ok, result = callExecutor("appendfile", executorLogPath, payload)
	if not ok then
		local readOK, previous = callExecutor("readfile", executorLogPath)
		if readOK and type(previous) == "string" then
			ok, result = callExecutor("writefile", executorLogPath, previous .. (previous:sub(-1) == "\n" and "" or "\n") .. payload)
		else
			local existsOK, exists = callExecutor("isfile", executorLogPath)
			if existsOK and exists == false then ok, result = callExecutor("writefile", executorLogPath, payload)
			else return false, "Impossible de lire le log existant : ecrasement refuse" end
		end
	end
	if ok then for _ = 1, count do table.remove(pendingLogLines, 1) end end
	return ok, ok and executorLogPath or tostring(result)
end

function executorTools.ReadLog()
	return callExecutor("readfile", executorLogPath)
end
function executorTools.OpenLog()
	return callExecutor("openfile", executorLogPath)
end
function executorTools.FirePrompt(prompt)
	if typeof(prompt) ~= "Instance" or not prompt:IsA("ProximityPrompt") or not prompt:IsDescendantOf(Workspace) then
		return false, "ProximityPrompt de Workspace requis"
	end
	return callExecutor("fireproximityprompt", prompt)
end
shared.__AutoSAEExecutorTools = executorTools

local function log(stage, message, ...)
	local allowed = {ERROR=true, FLIGHT_RESULT=true, SESSION=true, STOP=true, WALL_HATCH=true, WALL_EQUIP_BEST=true, PLOT_PLACE=true, EGG_TRACK=true, SYNC_DIAG=true, CARRY_DIAG=true, SERVER_CHANGE=true, GUARD_CONTROL=true}
	if not allowed[stage] then
		return
	end
	sequence += 1
	local ok, text = pcall(string.format, message, ...)
	if not ok then
		text = message .. " | format=" .. tostring(text)
	end
	local line = string.format("[Auto_SAE][%04d][%.3f][%s][%s] %s",
		sequence, os.clock(), stage, currentCycle and currentCycle.uid or "-", text)
	table.insert(debugLogLines, line)
	table.insert(pendingLogLines, line)
	if #debugLogLines > 1000 then table.remove(debugLogLines, 1) end
	print(line)
	local saved, failure = executorTools.SaveLog()
	if not saved and executorFunction("writefile") then warn("[Auto_SAE] Sauvegarde log : "..tostring(failure)) end
end

local function measureAction(_, action, ...)
	return action(...)
end

local settingsPath = "AutoSAE_settings.json"
local lastSettingsJSON, lastSavedLogSequence = nil, -1
function executorTools.SaveSettings()
	local json = HttpService:JSONEncode({
		Version = 1, AutomaticMode = automaticMode,
		IncludeMissingIndex = autoIncludeMissingIndex,
		OpenBelowRate = openBelowRate,
		SearchActive = searchingServer and automaticMode,
		TimingEnabled = timingEnabled,
		MinimumBillions = minimumRatePerSecond / 1e9,
	})
	if json == lastSettingsJSON then return true, settingsPath end
	local ok, result = callExecutor("writefile", settingsPath, json)
	if ok then
		lastSettingsJSON = json
		log("SETTINGS_SAVED", "Auto=%s Index=%s Minimum=%s B/s", tostring(automaticMode), tostring(autoIncludeMissingIndex), tostring(minimumRatePerSecond / 1e9))
	end
	return ok, ok and settingsPath or tostring(result)
end
local function loadSettings()
	local ok, content = callExecutor("readfile", settingsPath)
	if not ok then log("SETTINGS_LOAD", "Valeurs par defaut : %s", tostring(content)); return end
	local decoded, settings = pcall(HttpService.JSONDecode, HttpService, content)
	if not decoded or type(settings) ~= "table" or settings.Version ~= 1 then
		log("SETTINGS_LOAD", "Fichier invalide : valeurs par defaut conservees")
		return
	end
	if type(settings.AutomaticMode) == "boolean" then automaticMode = settings.AutomaticMode end
	if type(settings.IncludeMissingIndex) == "boolean" then autoIncludeMissingIndex = settings.IncludeMissingIndex end
	for _, key in ipairs({"OpenBelowRate"}) do
		local value = settings[key]
		if type(value) == "number" and value == value and value >= 0 and value < math.huge then
			openBelowRate = value
		end
	end
	searchingServer = automaticMode and settings.SearchActive == true
	-- Detailed telemetry disabled.

	local minimum = settings.MinimumBillions
	if type(minimum) == "number" and minimum == minimum and minimum >= MINIMUM_BILLIONS and minimum <= MAXIMUM_BILLIONS then
		minimumRatePerSecond = minimum * 1e9
	end
	log("SETTINGS_LOADED", "Auto=%s Index=%s Minimum=%s B/s", tostring(automaticMode), tostring(autoIncludeMissingIndex), tostring(minimumRatePerSecond / 1e9))
end

local function logQueueDecision(uid, decision)
	if queueDecisionLogs[uid] == decision then return end
	queueDecisionLogs[uid] = decision
	log("QUEUE_DECISION", "UID=%s %s", uid, decision)
end

local lastStatusText
local function setStatus(text, color)
	if text ~= lastStatusText then
		lastStatusText = text
		log("STATUS", "%s", tostring(text))
	end
	if statusLabel then
		statusLabel.Text = text
		statusLabel.TextColor3 = color or Color3.fromRGB(225, 230, 245)
	end
end

local function connect(signal, callback)
	local connection = signal:Connect(callback)
	table.insert(lifetimeConnections, connection)
	return connection
end

local function formatPosition(position)
	return string.format("(%.1f, %.1f, %.1f)", position.X, position.Y, position.Z)
end

local function formatNumber(value)
	for _, unit in ipairs({{1e15, "Qa"}, {1e12, "T"}, {1e9, "B"}, {1e6, "M"}, {1e3, "K"}}) do
		if math.abs(value) >= unit[1] then
			return string.format("%.3g%s", value / unit[1], unit[2])
		end
	end
	return string.format("%.3g", value)
end


local function parseIncomeRate(text)
	if type(text) ~= "string" then return nil end
	local normalized = text:lower():gsub("%s+", ""):gsub(",", "."):gsub("/s$", "")
	local number, unit = normalized:match("^(%d*%.?%d+)(%a*)$")
	local multiplier = ({[""]=1e9,k=1e3,m=1e6,b=1e9,t=1e12,qa=1e15})[unit]
	local value = tonumber(number)
	if not value or not multiplier then return nil end
	value *= multiplier
	if value ~= value or value < 0 or value == math.huge then return nil end
	return value
end

local function getCharacterParts()
	local character = player.Character
	if not character then return nil, nil, nil end
	return character, character:FindFirstChildOfClass("Humanoid"), character:FindFirstChild("HumanoidRootPart")
end

local function distanceXZ(first, second)
	local delta = first - second
	return Vector2.new(delta.X, delta.Z).Magnitude
end

-- Single movement primitive. Returns true only inside the arrival radius.
local function move(destination, options)
	options = options or {}
	local character, humanoid, root = getCharacterParts()
	if not character or not humanoid or not root then return false, "personnage absent" end
	local stopping = options.Stop == true
	local arrived = false
	if not stopping and os.clock() < syncPauseUntil then return false, "synchronisation en cours" end
	if not stopping and movementResumePending then
		movementResumePending = false
		log("SYNC_DIAG", "Reprise du deplacement depuis la position actuelle apres correction")
	end
	if not stopping then
		if typeof(destination) ~= "Vector3" then return false, "destination invalide" end
		local arrivalPosition = options.ArrivalPosition or destination
		local distance = options.Flat == false and (root.Position - arrivalPosition).Magnitude
			or distanceXZ(root.Position, arrivalPosition)
		arrived = distance <= (options.Radius or 3)
		stopping = arrived
	end
	if stopping then humanoid:Move(Vector3.zero) end
	humanoid:MoveTo(stopping and root.Position or destination)
	if stopping then
		local hardBrake = options.HardBrake == true or arrived
		if hardBrake and os.clock() >= syncPauseUntil and character and humanoid.Health > 0 and not humanoid.PlatformStand and not humanoid.Sit
			and character:GetAttribute("IsTrapped") ~= true
			and not (rigPause.Character == character and os.clock() < rigPause.Until) then
			local endsAt = player:GetAttribute("RagdollEndTime")
			local state = humanoid:GetState()
			if (type(endsAt) ~= "number" or endsAt <= Workspace:GetServerTimeNow())
				and state ~= Enum.HumanoidStateType.Ragdoll
				and state ~= Enum.HumanoidStateType.FallingDown
				and state ~= Enum.HumanoidStateType.Physics then
				humanoid.Jump = false
				local velocity = root.AssemblyLinearVelocity
				root.AssemblyLinearVelocity = Vector3.new(0, velocity.Y, 0)
				lastPhysicalBrakeAt = os.clock()
			end
		end
	end
	return arrived
end

local function stopMovement(hardBrake)
	return move(nil, {Stop = true, HardBrake = hardBrake == true})
end

local function readCarry()
	local ok, state = pcall(EggState.ReadCarryState)
	if ok and type(state) == "table" then return state end
	return nil
end

local function ownsEgg(uid)
	local ok, record = pcall(EggState.ReadOwnedEgg, player.UserId, uid)
	if ok and record ~= nil then return true, "ReadOwnedEgg" end
	if Save then
		local saveOK, profile = pcall(Save.Peek)
		if saveOK and profile and profile.EggInventory and profile.EggInventory[uid] then
			return true, "Save.EggInventory"
		end
	end
	for _, container in pairs({Backpack = player:FindFirstChildOfClass("Backpack"), Character = player.Character}) do
		if container then
			for _, tool in ipairs(container:GetChildren()) do
				if tool:IsA("Tool") and tool:GetAttribute("ItemType") == "AssetEgg"
					and tool:GetAttribute("UID") == uid then
					return true, "Tool.UID"
				end
			end
		end
	end
	return false
end


local function isTrackedFieldState(record)
	return record and (record.State == SLOT_STATE or record.State == "Dropped"
		or record.State == "Carried" or record.State == "GuardCarried")
end

local function isHeldByOther(record)
	return record and (record.State == "GuardCarried"
		or (record.State == "Carried" and record.CarrierUserId ~= player.UserId))
end

local function findPhysicalEgg(uid)
	local object=Workspace:FindFirstChild(uid)
	if object and (object:IsA("Model") or object:IsA("BasePart")) then return object end
	for _, other in ipairs(Players:GetPlayers()) do
		local character=other.Character
		local found=character and character:FindFirstChild(uid,true)
		if found and (found:IsA("Model") or found:IsA("BasePart")) then return found end
	end
	return nil
end

local function physicalEggCarrier(object)
	local carrier=object:GetAttribute("CarrierUserId")
	if type(carrier)=="number" then return carrier,true end
	for _,other in ipairs(Players:GetPlayers()) do
		if other.Character and object:IsDescendantOf(other.Character) then return other.UserId,true end
	end
	for _,joint in ipairs(object:GetDescendants()) do
		if joint:IsA("WeldConstraint") or joint:IsA("JointInstance") then
			for _,part in pairs({joint.Part0,joint.Part1}) do
				if part and not part:IsDescendantOf(object) and part~=object and part:IsDescendantOf(Workspace) then
					for _,other in ipairs(Players:GetPlayers()) do
						if other.Character and part:IsDescendantOf(other.Character) then return other.UserId,true end
					end
					return nil,true
				end
			end
		end
	end
	return nil,false
end

local function readField(uid)
	local ok, record = pcall(EggState.ReadFieldEgg, uid)
	if not ok then log("FIELD_READ_ERROR","%s",tostring(record)); return nil,false end
	local tracked=trackedEggs[uid]
	if record then
		if tracked then
			tracked.Record=record
			if record.CarrierUserId then tracked.LastCarrier=record.CarrierUserId end
			tracked.MissingSince=nil
		end
		if queuedEggs[uid] then queuedEggs[uid].Record=record end
		return record,true
	end
	if not tracked then return nil,true end
	if tracked.Record.State=="Claimed" or ownsEgg(uid) then trackedEggs[uid]=nil; return nil,true end
	if tracked.LastCarrier and os.clock()-(tracked.LastOwnerCheck or -math.huge)>=0.5 then
		tracked.LastOwnerCheck=os.clock()
		local ownedOK,owned=pcall(EggState.ReadOwnedEgg,tracked.LastCarrier,uid)
		if ownedOK and owned then
			log("EGG_TRACK","UID=%s Attribue au joueur=%s",uid,tostring(tracked.LastCarrier))
			trackedEggs[uid]=nil
			return nil,true
		end
	end
	local object=findPhysicalEgg(uid)
	if not object then
		tracked.MissingSince=tracked.MissingSince or os.clock()
		-- Briefly preserve a reparented/streamed object; absence is not a delivery verdict.
		if os.clock()-tracked.MissingSince>10 then
			log("EGG_TRACK","UID=%s Suivi termine : aucun objet ni etat observable depuis 10 s ; attribution inconnue",uid)
			trackedEggs[uid]=nil
			return nil,true
		end
		local waiting=table.clone(tracked.Record)
		waiting.State,waiting.CarrierUserId,waiting.ObservationOnly="GuardCarried",nil,true
		if queuedEggs[uid] then queuedEggs[uid].Record=waiting end
		return waiting,true
	end
	tracked.MissingSince=nil
	local position=object:IsA("Model") and object:GetPivot() or object.CFrame
	local carrier,attached=physicalEggCarrier(object)
	local observed=table.clone(tracked.Record)
	observed.BottomCFrame,observed.ObservationOnly=position,true
	if attached then
		tracked.UnattachedSince=nil
		observed.State=carrier and "Carried" or "GuardCarried"
		observed.CarrierUserId=carrier
		if carrier then tracked.LastCarrier=carrier end
	else
		tracked.UnattachedSince=tracked.UnattachedSince or os.clock()
		-- Physical drop is provisional. CarryFieldEgg still validates the UID on the server.
		observed.State=os.clock()-tracked.UnattachedSince>=0.3 and "Dropped" or "GuardCarried"
		observed.CarrierUserId=nil
	end
	if os.clock()-(tracked.LastSync or -math.huge)>3 and not tracked.SyncBusy and type(EggState.SyncFieldEggs)=="function" then
		tracked.LastSync,tracked.SyncBusy=os.clock(),true
		task.spawn(function()
			pcall(EggState.SyncFieldEggs)
			tracked.SyncBusy=false
		end)
	end
	if queuedEggs[uid] then queuedEggs[uid].Record=observed end
	return observed,true
end

local function getSeparationLine()
	local world = Workspace:FindFirstChild("World")
	local areas = world and world:FindFirstChild("Areas")
	local line = areas and areas:FindFirstChild("SeparationLine")
	return line and line:IsA("BasePart") and line or nil
end

local function isSafe(position)
	local line = getSeparationLine()
	if not line then return nil end
	return not GuardGeometry.IsPastLine(line, position)
end

local function validCycle(ctx)
	if detectedMode ~= "Normal" or destroyed or not autoEnabled or generation ~= ctx.generation or currentCycle ~= ctx then
		return false, "annule"
	end
	local character, humanoid, root = getCharacterParts()
	if character ~= ctx.character or not humanoid or not root or humanoid.Health <= 0 then
		return false, "personnage change ou mort"
	end
	return true
end

-- Observe server movement effects; never cancel ragdoll, impulses, or server corrections.
local function motionBlockReason(ctx)
	if os.clock() < syncPauseUntil then return "correction de position en cours" end
	local _, humanoid = getCharacterParts()
	if not humanoid then return "personnage absent" end
	if ctx.character:GetAttribute("IsTrapped") == true then return "IsTrapped" end
	if type(player.GetAttribute) == "function" and type(Workspace.GetServerTimeNow) == "function" then
		local endsAt = player:GetAttribute("RagdollEndTime")
		if type(endsAt) == "number" and endsAt > Workspace:GetServerTimeNow() then
			return "RagdollEndTime serveur"
		end
	end
	if rigPause.Character == ctx.character and os.clock() < rigPause.Until then return rigPause.Reason end
	if humanoid.PlatformStand or humanoid.Sit then return "PlatformStand / Sit" end
	if type(humanoid.GetState) == "function" then
		local state = humanoid:GetState()
		if state == Enum.HumanoidStateType.Ragdoll or state == Enum.HumanoidStateType.FallingDown
			or state == Enum.HumanoidStateType.Physics then return tostring(state) end
	end
	return nil
end

local function observeRigRefresh(payload)
	-- Verified in Controllers.Game.ObbyAntiTPClientController: JSON Action/Arguments.
	if type(payload) ~= "string" then return end
	local ok, message = pcall(HttpService.JSONDecode, HttpService, payload)
	if not ok or type(message) ~= "table" then return end
	local action, arguments = message.Action, message.Arguments
	if action ~= "BeginImpulse" and action ~= "BeginRagdoll" and action ~= "EndRagdoll"
		and action ~= "Relocate" then return end
	local duration = type(arguments) == "table" and tonumber(arguments[1]) or nil
	if not duration or duration ~= duration or math.abs(duration) == math.huge then duration = 1 end
	if rigPause.Character ~= player.Character then rigPause.Until = 0 end
	rigPause.Character, rigPause.Reason = player.Character, "RigSync." .. action
	if action == "BeginImpulse" or action == "BeginRagdoll" then
		rigPause.Until = math.max(rigPause.Until, os.clock() + math.clamp(duration, 0.1, 10))
	else
		rigPause.Until = os.clock() + CONFIG.RigSettleTime
	end
	if action == "Relocate" then
		lastRelocateAt = os.clock()
		movementResumePending = true
		movementRevision += 1
		if autoEnabled then syncPauseUntil = math.max(syncPauseUntil, os.clock()+0.5) end
		if autoEnabled or currentCycle then
			log("SYNC_DIAG", "Source=RigSync.Relocate Revision=%d Phase=%s | repositionnement demande par le serveur ; commandes suspendues",
				movementRevision, currentCycle and currentCycle.phase or autoActivity)
		end
	end
	log("RIG_OBSERVED", "Action=%s PauseRestante=%.2fs | observation seule", action, rigPause.Until - os.clock())
end

local function waitForMotionReady(ctx)
	local started, logged = os.clock(), false
	while validCycle(ctx) do
		local reason = motionBlockReason(ctx)
		if not reason then
			if logged then log("MOVE_RESUME", "Phase=%s Attente=%.2fs", ctx.phase, os.clock() - started) end
			return true
		end
		if not logged then
			logged = true
			stopMovement() -- Cancel walking only, not the physical server impulse.
			log("MOVE_PAUSED", "Phase=%s Raison=%s", ctx.phase, reason)
		end
		if os.clock() - started >= CONFIG.MotionPauseTimeout then return false, "immobilisation serveur prolongee" end
		task.wait(0.05)
	end
	return false, "annule"
end

local function brakeAtArrival(ctx, destination, radius, flat)
	local _, _, root = getCharacterParts()
	if not root then return false, "personnage absent" end
	local started, before = os.clock(), root.AssemblyLinearVelocity
	stopMovement()
	if not CONFIG.EnableArrivalBrake then return true end
	ctx.braking = true
	local function finish(ok, reason)
		ctx.braking = false
		return ok, reason
	end
	repeat
		local valid, reason = validCycle(ctx)
		if not valid then return finish(false, reason) end
		local blocked = motionBlockReason(ctx)
		if blocked then return finish(false, "freinage interrompu : " .. blocked) end
		local distance = flat and distanceXZ(root.Position, destination) or (root.Position - destination).Magnitude
		if distance > radius then return finish(false, "derive apres arrivee") end
		ctx.braking = true
		stopMovement(true)
		if os.clock() - started >= CONFIG.ArrivalBrakeDuration then break end
		RunService.Heartbeat:Wait()
	until false
	log("ARRIVAL_BRAKE", "Phase=%s HorizontalAvant=%.2f HorizontalApres=%.2f Duree=%.3fs",
		ctx.phase, Vector2.new(before.X, before.Z).Magnitude,
		Vector2.new(root.AssemblyLinearVelocity.X, root.AssemblyLinearVelocity.Z).Magnitude, os.clock() - started)
	return finish(true)
end

local function setPhase(ctx, phase, message)
	if ctx.phase ~= phase then
		if timingEnabled then
			local now = os.clock()
			log("TIMING_PHASE", "Phase=%s DureeMs=%.1f DepuisDepartMs=%.1f", tostring(ctx.phase), (now - (ctx.phaseStartedAt or now)) * 1000, (now - (ctx.startedAt or now)) * 1000)
			ctx.phaseStartedAt = now
		end
		log("PHASE", "%s -> %s | %s", tostring(ctx.phase), phase, message or "")
		ctx.phase = phase
	end
	setStatus(message or phase)
end

local function getAssetConfig(record)
	if type(record) ~= "table" or type(record.AssetCategory) ~= "string" then
		return nil
	end

	return Assets.Directory[record.AssetCategory]
end

local function getRarityName(record)
	local config = getAssetConfig(record)
	local rarity = config and config.Rarity

	if type(rarity) == "string" then
		return rarity
	end

	if type(rarity) == "table" then
		return rarity._id or rarity.Id or rarity.Name
	end

	return "Inconnue"
end

local function getAnimalName(record)
	local config = getAssetConfig(record)
	return config and config.DisplayName or record.AssetCategory or "Inconnu"
end

local function recordFlightResult(ctx, succeeded)
	if ctx.resultLogged then return end
	ctx.resultLogged = true
	local text = string.format('Vol de "%s" %s', getAnimalName(ctx.record or {}), succeeded and "Reussi" or "Echoue")
	table.insert(flightHistory, {Text=text, Success=succeeded})
	if #flightHistory > 200 then table.remove(flightHistory, 1) end
	log("FLIGHT_RESULT", "%s", text)
	if refreshFlightLog then refreshFlightLog() end
end

local function getRatePerSecond(record)
	if type(record) == "table" and record.IsHalloweenObservation then
		if record.ObservedRate then return record.ObservedRate end
		if not Assets.Directory[record.AssetCategory] then return nil end
		-- Earnings only needs category, scale and mutations; no cosmetic identity is fabricated.
		local ok, rate = pcall(AssetEarnings.RatePerSecond, {
			Category = record.AssetCategory, Scale = record.AssetScale,
			Mutations = record.Mutations or {}, BaseMutation = record.BaseMutation,
		})
		return ok and type(rate) == "number" and rate or nil
	end
	if type(record) ~= "table" then
		return nil
	end

	local itemOk, itemData = pcall(EggRecords.ToAssetItemData, record)
	if not itemOk then
		warn("[Auto_SAE] Conversion impossible pour le revenu de", record.Uid, itemData)
		return nil
	end

	local rateOk, rate = pcall(AssetEarnings.RatePerSecond, itemData)
	if not rateOk or type(rate) ~= "number" then
		warn("[Auto_SAE] Calcul du revenu impossible pour", record.Uid, rate)
		return nil
	end

	return rate
end

local function getWeightKg(record)
	if type(record) ~= "table"
		or type(record.AssetCategory) ~= "string"
		or type(record.AssetScale) ~= "number" then
		return nil
	end

	local ok, weight = pcall(
		EggRecords.WeightKgForScale,
		record.AssetCategory,
		record.AssetScale
	)

	if ok and type(weight) == "number" then
		return weight
	end

	return nil
end

local function resolveHalloweenCategory(source)
	if type(source) ~= "string" then return nil end
	if Assets.Directory[source] then return source end
	local match
	for category, spec in pairs(HalloweenPets and HalloweenPets.Specs or {}) do
		if spec.Group == "World" and (spec.Source == source or spec.EggSource == source
			or spec.EggModel == source or spec.DisplayName == source) then
			if match and match ~= category then return nil end
			match = category
		end
	end
	return match
end

local function refreshHalloweenRecords()
	local updated, seen = {}, {}
	local map = Workspace:FindFirstChild("HalloweenDimension")
	local folder = map and map:FindFirstChild("WorldEggs")
	local models = folder and folder:GetChildren() or {}
	for _, model in ipairs(CollectionService:GetTagged("HalloweenWorldEgg")) do table.insert(models, model) end
	for _, model in ipairs(models) do
		if not seen[model] and model:IsA("Model") and model:IsDescendantOf(Workspace) then
			seen[model] = true
			local uid = model:GetAttribute("HalloweenEggUid")
			if type(uid) == "string" then
				local source = model:GetAttribute("AssetCategory") or model:GetAttribute("PreparedSourceName")
				local category = resolveHalloweenCategory(source)
				local scale = model:GetAttribute("AssetScale")
				local hasScale = type(scale) == "number" and scale > 0 and scale < math.huge
				local rate = model:GetAttribute("MoneyPerSecond")
				local mutations, hasMutations = {}, false
				local encoded = model:GetAttribute("Mutations")
				if type(encoded) == "string" then
					local ok, decoded = pcall(function() return game:GetService("HttpService"):JSONDecode(encoded) end)
					if ok and type(decoded) == "table" then
						hasMutations = true
						for key, value in pairs(decoded) do
							if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(value) ~= "string" then hasMutations = false; break end
						end
						if hasMutations then mutations = decoded end
					end
				end
				local baseMutation = model:GetAttribute("BaseMutation")
				updated[uid] = {
					Uid = uid, AssetCategory = category or (type(source) == "string" and source or "Halloween Egg"),
					AssetScale = hasScale and scale or 1,
					WeightIsReference = not hasScale,
					RateIsReference = not hasScale or not hasMutations,
					BottomCFrame = model:GetPivot(), AreaId = "Halloween", Zone = model:GetAttribute("Zone"),
					State = model:GetAttribute("HalloweenEggCanPickUp") == true and "Slot" or "Unavailable",
					Mutations = mutations, BaseMutation = type(baseMutation) == "string" and baseMutation or nil,
					IsHalloweenObservation = true,
					ObservedRate = type(rate) == "number" and rate >= 0 and rate < math.huge and rate or nil,
				}
			end
		end
	end
	halloweenRecords = updated
end

local function getRecordPosition(record)
	if type(record) == "table" and typeof(record.BottomCFrame) == "CFrame" then
		return record.BottomCFrame.Position
	end

	return nil
end

local function mutationLabel(record)
	if type(record) ~= "table"
		or type(record.Mutations) ~= "table"
		or #record.Mutations == 0 then
		return "Aucune"
	end

	return table.concat(record.Mutations, ", ")
end

local function versionKey(record)
	return tostring(record and record.Version or 0)
end

local function logEgg(record)
	if type(record) ~= "table" or type(record.Uid) ~= "string" then
		return
	end

	local currentVersion = versionKey(record)
	if loggedVersions[record.Uid] == currentVersion then
		return
	end
	loggedVersions[record.Uid] = currentVersion

	local position = getRecordPosition(record)
	local weight = getWeightKg(record)
	local rate = getRatePerSecond(record)

	print(string.format(
		"[Auto_SAE][EGG] %s | %s | %s | %s | %s Kg | %s $/s | %s | %s",
		record.Uid,
		getAnimalName(record),
		getRarityName(record),
		tostring(record.AreaId or "Inconnu"),
		weight and string.format("%.2f", weight) or "Inconnu",
		rate and formatNumber(rate) or "Inconnu",
		mutationLabel(record),
		position and formatPosition(position) or "Inconnue"
		))
end


local function ownerSnapshot()
	local ok, inventory = pcall(EggState.ReadOwnerEggs, player.UserId)
	local merged = ok and type(inventory) == "table" and inventory or {}
	if Save then
		local saveOK, profile = pcall(Save.Peek)
		if saveOK and profile and type(profile.EggInventory) == "table" then
			for uid, record in pairs(profile.EggInventory) do merged[uid] = record end
		end
	end
	return merged
end

local function claimEvidence(ctx)
	local owned, source = ownsEgg(ctx.uid)
	if owned then return true, source end
	local carry = readCarry()
	if ctx.claimFeedback and (ctx.sawCarry or ctx.remoteAccepted) and carry and not carry.IsCarrying then
		for uid, record in pairs(ownerSnapshot()) do
			if not ctx.ownerBefore[uid] and type(record) == "table"
				and record.AssetCategory == ctx.record.AssetCategory then
				return true, "FieldClaimed + nouvel UID inventaire " .. tostring(uid)
			end
		end
	end
	return false
end

local function updateCarryEvidence(ctx)
	local owned, source = ownsEgg(ctx.uid)
	if owned then
		ctx.claimed = true
		ctx.claimSource = source
		return true
	end
	local carry = readCarry()
	if carry and carry.IsCarrying and carry.Uid == ctx.uid then
		if ctx.reacquiring and not ctx.sawCarry then
			local latest = readField(ctx.uid)
			local freshTransport = latest and latest.State == "Carried"
				and latest.CarrierUserId == player.UserId
				and (not ctx.pickupVersion or latest.Version > ctx.pickupVersion)
			if not freshTransport then return ctx.remoteAccepted == true end
		end
		ctx.sawCarry = true
		return true
	end
	return ctx.remoteAccepted == true
end

local function startReturnImmediately(ctx, source)
	if currentCycle ~= ctx or generation ~= ctx.generation or ctx.returnKickAt then return end
	if not validCycle(ctx) or motionBlockReason(ctx) then return end
	local character, humanoid, root = getCharacterParts()
	if character ~= ctx.character or not humanoid or not root then return end
	ctx.returnKickAt = os.clock()
	ctx.hadCarry = true
	setPhase(ctx, "RETURN", "Prise confirmee : retour immediat")
	move(ctx.home, {Radius = CONFIG.ReturnDistance})
	log("GRAB_TO_RETURN", "Source=%s DelaiDepuisRequeteMs=%.1f WalkSpeed=%.2f | commande retour envoyee sans pause",
		source, (ctx.returnKickAt - (ctx.lastRequest or ctx.returnKickAt)) * 1000, humanoid.WalkSpeed)
end

local function requestCarry(ctx)
	if inFlightRequest and not inFlightRequest.done then return end
	if ctx.attempts >= CONFIG.MaxCarryAttempts then return end
	local request = {uid = ctx.uid, started = os.clock(), done = false, retryable = false, movementRevision = movementRevision}
	inFlightRequest = request
	shared.__AutoSAERemoteLock = request
	ctx.attempts += 1
	ctx.lastRequest = request.started
	setPhase(ctx, "CARRY_PENDING", "Prise serveur : " .. getAnimalName(ctx.record))
	log("CARRY_REQUEST", "Tentative=%d UID=%s", ctx.attempts, ctx.uid)
	task.spawn(function()
		if not validCycle(ctx) then
			request.done = true
			return
		end
		-- Recheck after task.spawn: high speed may have carried us past the egg.
		local _, _, root = getCharacterParts()
		local latest = readField(ctx.uid)
		local eggPosition = getRecordPosition(latest)
		local distance = root and eggPosition and (root.Position - eggPosition).Magnitude
		local blocked = motionBlockReason(ctx)
		local available = latest and (latest.State == SLOT_STATE or latest.State == "Dropped")
		if blocked or not available then
			request.done, request.accepted, request.retryable = true, false, blocked ~= nil
			request.reason = blocked and ("personnage immobilise : " .. blocked) or "oeuf non disponible"
			if ctx.onCarryReply then ctx.onCarryReply(request) end
			return
		end
		if not distance or distance > CONFIG.ApproachDistance then
			request.done, request.accepted, request.retryable = true, false, distance ~= nil
			request.reason = "distance de prise non valide : " .. (distance and string.format("%.2f studs", distance) or "position indisponible")
			ctx.denial = request.reason
			log("CARRY_DISTANCE_BLOCKED", "UID=%s Distance3D=%s Maximum=%.1f | aucun appel serveur",
				ctx.uid, tostring(distance), CONFIG.ApproachDistance)
			if ctx.onCarryReply then ctx.onCarryReply(request) end
			return
		end
		local slotKey
		if SlotIdentity.LooksLikeFirstAreaUid(ctx.uid) then
			slotKey = SlotIdentity.SlotKey(ctx.record.AreaId, ctx.record.NestId)
		end
		local areas = Workspace:FindFirstChild("World")
		areas = areas and areas:FindFirstChild("Areas")
		local line = areas and areas:FindFirstChild("SeparationLine")
		local depth = root and line and line:IsA("BasePart") and line.CFrame.LookVector:Dot(root.Position - line.Position)
		log("CARRY_CONTEXT", "Pos=%s Distance3D=%s ProfondeurLigne=%s Halloween=%s SlotKey=%s",
			root and formatPosition(root.Position) or "absent", tostring(distance), tostring(depth),
			tostring(player:GetAttribute("InHalloweenDimension")), tostring(slotKey))
		local ok, accepted, reason = pcall(EggState.CarryFieldEgg, ctx.uid, slotKey)
		if ok and accepted ~= true and type(reason) == "string" and reason:find("Enter the gameplay area first", 1, true) then
			ctx.gameplayEntryRejected = ctx.attempts >= CONFIG.MaxCarryAttempts
			ctx.preciseRadius = 1.5
		end
		if not ok or accepted ~= true then
			log("CARRY_DIAG", "Refus=%s PosLocale=%s DistanceLocale=%s CoteLigne=%s RevisionAvant=%d RevisionApres=%d DernierFreinMs=%.0f RegionAntiTpActive=%s",
				tostring(ok and reason or accepted), root and formatPosition(root.Position) or "?",
				tostring(distance), tostring(depth), request.movementRevision, movementRevision,
				(os.clock()-lastPhysicalBrakeAt)*1000,
				tostring(Workspace:GetAttribute("AnticheatSuspendedRegion") ~= nil or Workspace:FindFirstChild("MonsterEventMap") ~= nil))
		end
		if ok and accepted ~= true and type(reason) == "string" and reason:lower():find("closer", 1, true) then
			ctx.preciseRadius = 1.5
		end
		request.done = true
		request.callOK, request.retryable = ok, ok and accepted ~= true and not ctx.gameplayEntryRejected
		request.accepted = ok and accepted == true
		request.reason = ok and reason or tostring(accepted)
		-- A timed-out InvokeServer may finish later. It never controls a newer cycle.
		log("CARRY_REPLY", "UID=%s CallOK=%s Accepted=%s Reason=%s Latence=%.3fs SessionActive=%s",
			ctx.uid, tostring(ok), tostring(request.accepted), tostring(request.reason),
			os.clock() - request.started, tostring(validCycle(ctx)))
		if not validCycle(ctx) then return end
		ctx.remoteAccepted = request.accepted
		if request.accepted then startReturnImmediately(ctx, "CARRY_REPLY") end
		ctx.denial = request.reason
		if ctx.onCarryReply then ctx.onCarryReply(request) end
	end)
	return request
end

-- Cancellable waits; movement listeners and refreshes are disposed on completion.
local function awaitCycleOperation(ctx, timeout, start)
	if not validCycle(ctx) then return false, "annule" end
	local signal = Instance.new("BindableEvent")
	local completed, result = false, nil
	local function finish(...)
		if completed then return end
		completed = true
		result = table.pack(...)
		signal:Fire()
	end
	local cancel = function() finish(false, "annule") end
	ctx.cancelPendingWait = cancel
	local timer = task.delay(timeout, function() finish(false, "delai depasse") end)
	local startOK, dispose = pcall(start, finish)
	if not startOK then finish(false, tostring(dispose)) end
	if not completed then signal.Event:Wait() end
	if ctx.cancelPendingWait == cancel then ctx.cancelPendingWait = nil end
	pcall(task.cancel, timer)
	if startOK and type(dispose) == "function" then pcall(dispose) end
	signal:Destroy()
	return table.unpack(result, 1, result.n)
end

local function traceMoveEnd(ctx, root, destination, reached)
	local latest = readField(ctx.uid)
	local fromRecord = latest and typeof(latest.BottomCFrame) == "CFrame"
	local eggPosition = fromRecord and latest.BottomCFrame.Position or ctx.eggPosition or destination
	local playerPosition = root.Position
	local measuredAt = os.clock()
	ctx.moveEndTrace = {
		EggPosition = eggPosition, PlayerPosition = playerPosition,
		Reached = reached, At = measuredAt,
	}
	log("MOVE_END_POSITIONS", "Reached=%s | Oeuf=%s | Player=%s | DestinationMoveTo=%s | DistanceXZ=%.2f studs | Distance3D=%.2f studs | Vitesse=%.2f studs/s | SourceOeuf=%s",
		tostring(reached), formatPosition(eggPosition), formatPosition(playerPosition),
		formatPosition(destination), distanceXZ(playerPosition, eggPosition),
		(playerPosition - eggPosition).Magnitude, root.AssemblyLinearVelocity.Magnitude,
		fromRecord and "EggState" or "memorisee")
	for _, delaySeconds in ipairs({0.1, 0.25, 0.5}) do
		task.delay(delaySeconds, function()
			if not validCycle(ctx) or (ctx.phase ~= "APPROACH" and ctx.phase ~= "CARRY_PENDING") then return end
			local _, _, currentRoot = getCharacterParts()
			if currentRoot ~= root then return end
			local position = root.Position
			log("MOVE_END_DRIFT", "ApresFin=%.3fs | Phase=%s | Oeuf=%s | Player=%s | DistanceXZ=%.2f studs | DeplacementDepuisFinXZ=%.2f studs | Vitesse=%.2f studs/s",
				os.clock() - measuredAt, tostring(ctx.phase), formatPosition(eggPosition),
				formatPosition(position), distanceXZ(position, eggPosition),
				distanceXZ(position, playerPosition), root.AssemblyLinearVelocity.Magnitude)
		end)
	end
end


local function followTakenEgg(ctx)
	local startedFollowing=false
	while validCycle(ctx) do
		if stopAfterFlight then stopMovement(true); return false,"arret du suivi demande" end
		local record,ok=readField(ctx.uid)
		if not ok or not record then stopMovement(true); return false,"TARGET_UNAVAILABLE" end
		if record.State=="Claimed" then
			trackedEggs[ctx.uid]=nil
			stopMovement(true)
			log("EGG_TRACK","UID=%s Etat serveur=Claimed : fin du suivi",ctx.uid)
			return false,"TARGET_UNAVAILABLE"
		end
		ctx.record,ctx.eggPosition=record,getRecordPosition(record)
		if not isHeldByOther(record) then
			if startedFollowing then
				stopMovement(true)
				cooldowns[ctx.uid]=nil
				log("EGG_TRACK","UID=%s Oeuf disponible a nouveau%s",ctx.uid,record.ObservationOnly and " (observation physique, serveur a confirmer)" or "")
			end
			return true
		end
		if not startedFollowing then
			startedFollowing=true
			setPhase(ctx,"FOLLOW","Suivi de "..getAnimalName(record).." porte par un autre joueur")
			log("EGG_TRACK","UID=%s Debut suivi porteur=%s Observation=%s",ctx.uid,tostring(record.CarrierUserId),tostring(record.ObservationOnly==true))
		end
		if motionBlockReason(ctx) then
			local resumed,why=waitForMotionReady(ctx)
			if not resumed then return false,why end
		else
			local _,_,root=getCharacterParts()
			local carrier=record.CarrierUserId and Players:GetPlayerByUserId(record.CarrierUserId)
			local carrierRoot=carrier and carrier.Character and carrier.Character:FindFirstChild("HumanoidRootPart")
			local position=carrierRoot and carrierRoot.Position or ctx.eggPosition
			if root and position then
				local delta=Vector3.new(root.Position.X-position.X,0,root.Position.Z-position.Z)
				if delta.Magnitude>10 then
					local target=position+delta.Unit*7
					move(Vector3.new(target.X,root.Position.Y,target.Z),{Radius=2})
				else stopMovement(true) end
			else stopMovement() end
		end
		task.wait(0.1)
	end
	return false,"annule"
end

local function approachEgg(ctx, destination)
	local _, humanoid, root = getCharacterParts()
	if not humanoid or not root then return false, "personnage absent" end
	setPhase(ctx, "APPROACH", "Course vers : " .. getAnimalName(ctx.record))
	local started, lastCommand, lastLog = os.clock(), -math.huge, -math.huge
	local lastMoved, lastPosition = started, root.Position
	local initialDistance = distanceXZ(root.Position, destination)
	local timeout = math.clamp(initialDistance / math.max(humanoid.WalkSpeed, 1) * 4 + 15, 15, 150) + CONFIG.MotionPauseTimeout
	local nativeReached, retryRequested = nil, false
	local pausedAt
	local previousApproachPosition = root.Position
	log("MOVE_APPROACH_START", "Destination=%s Pos=%s WalkSpeed=%.1f Renouvellement=%.1fs Maximum=%.1fs",
		formatPosition(destination), formatPosition(root.Position), humanoid.WalkSpeed,
		CONFIG.ApproachRefresh, timeout)
	local finished, moveReason = awaitCycleOperation(ctx, timeout, function(finish)
		local active = true
		local function complete(ok, reason)
			if not active then return end
			active = false
			finish(ok, reason)
		end
		local function checkProgress()
			if not active then return end
			local valid, reason = validCycle(ctx)
			if not valid then complete(false, reason); return end
			local blocked = motionBlockReason(ctx)
			if blocked then
				if not pausedAt then
					pausedAt = os.clock()
					stopMovement()
					log("MOVE_PAUSED", "Phase=APPROACH Raison=%s", blocked)
				end
				lastMoved = os.clock()
				if os.clock() - pausedAt >= CONFIG.MotionPauseTimeout then
					complete(false, "immobilisation serveur prolongee")
				end
				return
			elseif pausedAt then
				log("MOVE_RESUME", "Phase=APPROACH Attente=%.2fs", os.clock() - pausedAt)
				pausedAt, lastCommand, lastMoved = nil, -math.huge, os.clock()
				previousApproachPosition = root.Position
			end
			local latest, readOK = readField(ctx.uid)
			local eggPosition = getRecordPosition(latest)
			if not readOK or not eggPosition then
				complete(false, "position actuelle de l'oeuf indisponible")
				return
			end
			if latest.State ~= SLOT_STATE and latest.State ~= "Dropped" then
				complete(false, isHeldByOther(latest) and "TARGET_HELD_OTHER" or "oeuf non disponible pendant l'approche")
				return
			end
			local updatedDestination = Vector3.new(eggPosition.X, ctx.home.Y, eggPosition.Z)
			local targetMoved = distanceXZ(updatedDestination, destination) > 0.01
			ctx.record, ctx.eggPosition, destination = latest, eggPosition, updatedDestination
			local now = os.clock()
			local distance = distanceXZ(root.Position, destination)
			if distanceXZ(lastPosition, root.Position) >= 0.5 then
				lastMoved, lastPosition = now, root.Position
			end
			local preciseRadius = ctx.preciseRadius or CONFIG.PreciseArrivalRadius
			local currentPosition = root.Position
			local segment = Vector3.new(currentPosition.X - previousApproachPosition.X, 0, currentPosition.Z - previousApproachPosition.Z)
			local offset = Vector3.new(eggPosition.X - previousApproachPosition.X, 0, eggPosition.Z - previousApproachPosition.Z)
			local crossed = false
			if segment.Magnitude > 0.01 then
				local projection = offset:Dot(segment) / segment:Dot(segment)
				crossed = projection > 0 and projection < 1
					and (offset - segment * projection).Magnitude <= preciseRadius
			end
			previousApproachPosition = currentPosition
			if distance <= preciseRadius and (root.Position - eggPosition).Magnitude <= CONFIG.ApproachDistance then
				traceMoveEnd(ctx, root, destination, true)
				complete(true, "distance verifiee")
				return
			end
			if crossed then
				stopMovement(true)
				retryRequested = true
				log("APPROACH_OVERSHOOT_BRAKE", "Cible franchie entre deux frames, distance=%.2f : freinage puis correction", distance)
			end
			if now - lastMoved > CONFIG.NoMovementTimeout then
				complete(false, "course bloquee sans progression")
				return
			end
			if distance < 100 or targetMoved or retryRequested or now - lastCommand >= CONFIG.ApproachRefresh then
				local firstCommand = lastCommand == -math.huge
				lastCommand, retryRequested = now, false
				log(firstCommand and "MOVE_COMMAND" or "MOVE_RENEW", "Destination=%s DistanceXZ=%.2f Temps=%.2fs | sans arret ni changement de vitesse",
					formatPosition(destination), distance, now - started)
				move(destination, {Radius = ctx.preciseRadius or CONFIG.PreciseArrivalRadius, Flat = true, ArrivalPosition = eggPosition})
			end
			if now - lastLog >= CONFIG.ProgressInterval then
				lastLog = now
				log("MOVE_PROGRESS", "Phase=APPROACH Pos=%s DistanceXZ=%.2f WalkSpeed=%.1f VitesseReelle=%.1f Temps=%.2fs",
					formatPosition(root.Position), distance, humanoid.WalkSpeed,
					root.AssemblyLinearVelocity.Magnitude, now - started)
			end
		end
		local moveConnection = humanoid.MoveToFinished:Connect(function(didReach)
			if not active then return end
			nativeReached = didReach
			traceMoveEnd(ctx, root, destination, didReach)
			log("MOVE_NATIVE_FINISHED", "Reached=%s DistanceRestanteXZ=%.2f | seule la distance reelle autorise la prise",
				tostring(didReach), distanceXZ(root.Position, destination))
			retryRequested = true
			checkProgress()
		end)
		local heartbeatConnection = RunService.Heartbeat:Connect(checkProgress)
		checkProgress()
		return function()
			active = false
			moveConnection:Disconnect()
			heartbeatConnection:Disconnect()
		end
	end)
	if not finished then
		log("MOVE_APPROACH_CANCELLED", "%s", tostring(moveReason))
		return false, "MoveTo interrompu : " .. tostring(moveReason)
	end
	if not validCycle(ctx) then return false, "annule" end
	-- Cancel momentum immediately; no fixed settling wait before the direct request.
	stopMovement(true)
	local braked = distanceXZ(root.Position, ctx.eggPosition) <= (ctx.preciseRadius or CONFIG.PreciseArrivalRadius)
		and (root.Position - ctx.eggPosition).Magnitude <= CONFIG.ApproachDistance
	local brakeReason = "derive apres arrivee"
	if not braked then return false, brakeReason end
	log("MOVE_APPROACH_FINISHED", "NativeReached=%s Pos=%s DistanceRestanteXZ=%.2f | une tentative serveur apres verification",
		tostring(nativeReached), formatPosition(root.Position), distanceXZ(root.Position, destination))
	traceMoveEnd(ctx, root, destination, true)
	return true
end

local function tryCarryOnce(ctx)
	-- MoveToFinished(false) is not arrival. requestCarry rechecks the live egg distance.
	local replied, accepted, reason, retryable = awaitCycleOperation(ctx, CONFIG.RequestTimeout, function(finish)
		ctx.onCarryReply = function(request)
			finish(true, request.accepted, request.reason, request.retryable)
		end
		local request = requestCarry(ctx)
		if not request then
			finish(false, false, "requete deja en cours ou indisponible")
		elseif request.done then
			finish(true, request.accepted, request.reason, request.retryable)
		end
		return function() ctx.onCarryReply = nil end
	end)
	if not replied then
		return false, reason or tostring(accepted), false
	end
	local grabbed = accepted == true or updateCarryEvidence(ctx)
	log("CARRY_SINGLE_DONE", "Accepted=%s PriseConfirmee=%s Reason=%s",
		tostring(accepted), tostring(grabbed), tostring(reason))
	if grabbed then return true end
	return false, "prise refusee : " .. tostring(reason), retryable == true
end

local function moveThenCarry(ctx, destination)
	local lastReason
	for attempt = 1, CONFIG.MaxCarryAttempts do
		if not validCycle(ctx) then return false, "annule" end
		if updateCarryEvidence(ctx) then return true end
		local movable, moveReason = waitForMotionReady(ctx)
		if not movable then return false, moveReason end
		local arrived, approachReason
		repeat
			local followed, why=followTakenEgg(ctx)
			if not followed then return false,why end
			if updateCarryEvidence(ctx) then return true end
			if ctx.eggPosition then destination=Vector3.new(ctx.eggPosition.X,ctx.home.Y,ctx.eggPosition.Z) end
			arrived,approachReason=approachEgg(ctx,destination)
		until approachReason~="TARGET_HELD_OTHER"
		if validCycle(ctx) and updateCarryEvidence(ctx) then return true end
		local retryable = false
		if arrived then
			if updateCarryEvidence(ctx) then return true end
			local grabbed, reason, canRetry = tryCarryOnce(ctx)
			if grabbed then return true end
			lastReason, retryable = reason, canRetry
		else
			lastReason = approachReason
			retryable = approachReason == "derive apres arrivee" or motionBlockReason(ctx) ~= nil
		end
		if not validCycle(ctx) then return false, "annule" end
		if inFlightRequest and not inFlightRequest.done then return false, lastReason end
		local latest = readField(ctx.uid)
		if not retryable or attempt == CONFIG.MaxCarryAttempts or not latest
			or (latest.State ~= SLOT_STATE and latest.State ~= "Dropped") then break end
		ctx.record, ctx.eggPosition = latest, getRecordPosition(latest)
		if not ctx.eggPosition then break end
		destination = Vector3.new(ctx.eggPosition.X, ctx.home.Y, ctx.eggPosition.Z)
		log("CARRY_RETRY", "UID=%s ProchainEssai=%d/%d Raison=%s Pause=%.2fs | requetes en serie",
			ctx.uid, attempt + 1, CONFIG.MaxCarryAttempts, tostring(lastReason), CONFIG.CarryRetryDelay)
		task.wait(CONFIG.CarryRetryDelay)
	end
	return false, lastReason or "prise non confirmee"
end

local function carryWasLost(ctx)
	if not ctx.hadCarry then return false end
	local latest = readField(ctx.uid)
	local carry = readCarry()
	local newer = latest and (not ctx.pickupVersion or latest.Version > ctx.pickupVersion)
	local dropped = newer and (latest.State == "Dropped" or latest.State == "GuardCarried"
		or latest.State == "Slot"
		or (latest.State == "Carried" and latest.CarrierUserId ~= nil
			and latest.CarrierUserId ~= player.UserId))
	if not dropped and not ctx.carryLostAt and carry and carry.IsCarrying and carry.Uid == ctx.uid then
		ctx.sawCarry = true
		return false
	end
	local owned, source = claimEvidence(ctx)
	if owned then
		ctx.claimed, ctx.claimSource, ctx.carryLostAt = true, source, nil
		return false
	end
	if dropped or ctx.carryLostAt then
		ctx.carryLostAt = ctx.carryLostAt or os.clock()
		ctx.sawCarry = false
		if not ctx.lossLogged then
			ctx.lossLogged = true
			log("EGG_LOST", "UID=%s Etat=%s CarryUID=%s | retour interrompu pour reprendre le meme oeuf",
				ctx.uid, latest and tostring(latest.State) or "en attente",
				carry and tostring(carry.Uid) or "?")
		end
		return true
	end
	return false
end

local function waitForRecoverableEgg(ctx)
	setPhase(ctx, "RECOVERY_WAIT", "Recherche de l'oeuf perdu : " .. getAnimalName(ctx.record))
	local started, lastLog = os.clock(), -math.huge
	while validCycle(ctx) do
		local owned, source = claimEvidence(ctx)
		if owned then
			ctx.claimed, ctx.claimSource = true, source
			return nil, "CLAIMED"
		end
		local latest = readField(ctx.uid)
		local carry = readCarry()
		local blocked = motionBlockReason(ctx)
		local trapped = blocked ~= nil
		if carry and carry.IsCarrying and carry.Uid == ctx.uid
			and (ctx.sawCarry or (latest and latest.State == "Carried"
				and latest.CarrierUserId == player.UserId
				and (not ctx.pickupVersion or latest.Version > ctx.pickupVersion)))
			and (not latest or (latest.State == "Carried" and latest.CarrierUserId == player.UserId)) then
			ctx.sawCarry, ctx.carryLostAt = true, nil
			startReturnImmediately(ctx, "CARRY_CHANGED")
			return nil, "CARRIED"
		end
		if latest and (latest.State == "Dropped" or latest.State == SLOT_STATE)
			and typeof(latest.BottomCFrame) == "CFrame" and not trapped then
			log("EGG_RECOVERABLE", "UID=%s Etat=%s PositionActuelle=%s Version=%s",
				ctx.uid, latest.State, formatPosition(latest.BottomCFrame.Position), tostring(latest.Version))
			return latest, "AVAILABLE"
		end
		local now = os.clock()
		if now - lastLog >= 0.5 then
			lastLog = now
			log("RECOVERY_WAIT", "UID=%s Etat=%s Immobilise=%s Temps=%.1fs",
				ctx.uid, latest and tostring(latest.State) or "absent / replication",
				tostring(blocked), now - started)
		end
		if now - started >= CONFIG.RecoveryStateTimeout then
			return nil, "recuperation impossible : oeuf non disponible apres attente"
		end
		task.wait(0.1)
	end
	return nil, "annule"
end

local function recoverSameEgg(ctx)
	stopMovement()
	local recoveryStarted = os.clock()
	ctx.recoveryCount = (ctx.recoveryCount or 0) + 1
	log("RECOVERY_START", "UID=%s Reprise=%d HomeConservee=%s",
		ctx.uid, ctx.recoveryCount, formatPosition(ctx.home))
	while validCycle(ctx) do
		if os.clock() - recoveryStarted > CONFIG.RecoveryStateTimeout then
			return false, "recuperation abandonnee apres plusieurs echecs"
		end
		local latest, state = waitForRecoverableEgg(ctx)
		if state == "CLAIMED" or state == "CARRIED" then return true end
		if not latest then return false, state end
		if inFlightRequest and not inFlightRequest.done then
			return false, "recuperation suspendue : requete serveur encore en cours"
		end
		ctx.record, ctx.eggPosition, ctx.pickupVersion = latest, latest.BottomCFrame.Position, latest.Version
		ctx.remoteAccepted, ctx.sawCarry, ctx.claimed, ctx.claimFeedback = false, false, false, false
		ctx.carryLostAt, ctx.lossLogged, ctx.reacquiring = nil, false, true
		ctx.attempts, ctx.lastRequest = 0, -math.huge
		ctx.returnKickAt = nil
		local destination = Vector3.new(ctx.eggPosition.X, ctx.home.Y, ctx.eggPosition.Z)
		local grabbed, reason = moveThenCarry(ctx, destination)
		if grabbed then
			ctx.reacquiring, ctx.hadCarry = false, true
			log("RECOVERY_GRABBED", "UID=%s Reprise=%d | nouveau retour vers la meme zone safe",
				ctx.uid, ctx.recoveryCount)
			return true
		end
		if not validCycle(ctx) then return false, "annule" end
		if inFlightRequest and not inFlightRequest.done then
			return false, "recuperation suspendue : requete serveur sans reponse"
		end
		log("RECOVERY_RETRY", "UID=%s Raison=%s | nouvelle lecture de la position avant nouvel essai",
			ctx.uid, tostring(reason))
		task.wait(CONFIG.RecoveryRetryDelay)
	end
	return false, "annule"
end

local function moveReturnLoop(ctx, destination)
	local _, humanoid, root = getCharacterParts()
	if not humanoid or not root then return false, "personnage absent" end
	local started, lastCommand, lastLog = os.clock(), -math.huge, -math.huge
	local lastMoved, lastPosition = started, root.Position
	local distance = distanceXZ(root.Position, destination)
	local timeout = math.clamp(distance / math.max(humanoid.WalkSpeed, 1) * 4 + 15, 15, 150) + CONFIG.MotionPauseTimeout
	ctx.returnStartDistance = distance
	ctx.returnDestination = destination
	ctx.lastReturnJump = nil
	setPhase(ctx, "RETURN", "Retour vers la zone sure")
	while true do
		local valid, reason = validCycle(ctx)
		if not valid then return false, reason end
		if ctx.watchForReappearance then
			local carry = readCarry()
			if carry and carry.IsCarrying and carry.Uid == ctx.uid then
				ctx.hadCarry, ctx.sawCarry, ctx.watchForReappearance = true, true, false
				return false, "TARGET_CARRIED"
			end
			local latest, readOK = readField(ctx.uid)
			if readOK and isHeldByOther(latest) then
				local followed,why=followTakenEgg(ctx)
				if not followed then return false,why end
				latest,readOK=readField(ctx.uid)
			end
			if readOK and latest and (latest.State == SLOT_STATE or latest.State == "Dropped")
				and latest.CarrierUserId == nil and getRecordPosition(latest) and not ownsEgg(ctx.uid) then
				ctx.record, ctx.eggPosition = latest, getRecordPosition(latest)
				return false, "TARGET_REAPPEARED"
			end
			if carry and not carry.IsCarrying and ctx.findNext and not (inFlightRequest and not inFlightRequest.done) then
				local nextEgg = ctx.findNext()
				if nextEgg and nextEgg.Uid ~= ctx.uid then return false, "NEXT_AVAILABLE" end
			end
		elseif carryWasLost(ctx) then
			return false, CARRY_LOST
		end
		if motionBlockReason(ctx) then
			local resumed, pauseReason = waitForMotionReady(ctx)
			if not resumed then return false, pauseReason end
			lastMoved, lastCommand, lastPosition = os.clock(), -math.huge, root.Position
			continue
		end
		local now = os.clock()
		distance = distanceXZ(root.Position, destination)
		local insideSafe = isSafe(root.Position) == true
		local arrivalRadius = CONFIG.ReturnDistance
		if insideSafe then
			humanoid.Jump = false
			local velocity = root.AssemblyLinearVelocity
			local horizontalSpeed = Vector2.new(velocity.X, velocity.Z).Magnitude
			arrivalRadius = math.max(arrivalRadius, math.min(30, horizontalSpeed * 0.1))
			local claimed, source = claimEvidence(ctx)
			if claimed then
				ctx.claimed, ctx.claimSource = true, source
				stopMovement(true)
				log("RETURN_CLAIM_EARLY", "Attribution confirmee en zone sure : fin du trajet, distance=%.2f", distance)
				return true
			end
		end
		if distanceXZ(lastPosition, root.Position) >= 0.5 then
			lastMoved, lastPosition = now, root.Position
		end
		if distance <= arrivalRadius then
			log("RETURN_BRAKE_ZONE", "Distance=%.2f Rayon=%.2f Safe=%s", distance, arrivalRadius, tostring(insideSafe))
			local braked, brakeReason = brakeAtArrival(ctx, destination, arrivalRadius, true)
			if carryWasLost(ctx) then return false, CARRY_LOST end
			if braked then return true end
			if not validCycle(ctx) then return false, brakeReason end
			lastCommand, lastMoved = -math.huge, os.clock()
			continue
		end
		if now - started > timeout then return false, "delai de retour depasse" end
		if now - lastMoved > CONFIG.NoMovementTimeout then return false, "retour bloque" end
		if distance < 100 or now - lastCommand >= CONFIG.MoveRefresh then
			move(destination, {Radius = arrivalRadius})
			lastCommand = now
		end
		if now - lastLog >= CONFIG.ProgressInterval then
			lastLog = now
			log("MOVE_PROGRESS", "Phase=RETURN Pos=%s DistanceXZ=%.2f WalkSpeed=%.1f VitesseReelle=%.1f Safe=%s",
				formatPosition(root.Position), distance, humanoid.WalkSpeed,
				root.AssemblyLinearVelocity.Magnitude, tostring(isSafe(root.Position)))
		end
		RunService.Heartbeat:Wait()
	end
end

local function waitForClaim(ctx)
	setPhase(ctx, "CONFIRM_CLAIM", "Verification de l'oeuf dans l'inventaire")
	local started, lastLog = os.clock(), -math.huge
	while validCycle(ctx) do
		local owned, source = claimEvidence(ctx)
		if owned then
			ctx.claimed, ctx.claimSource = true, source
			log("CLAIM_CONFIRMED", "UID=%s Source=%s | cycle termine", ctx.uid, source)
			return true
		end
		if carryWasLost(ctx) then return false, CARRY_LOST end
		local now = os.clock()
		local carry = readCarry()
		if now - lastLog >= 0.5 then
			lastLog = now
			log("CLAIM_WAIT", "Carry=%s CarryUID=%s Feedback=%s Temps=%.1fs",
				carry and tostring(carry.IsCarrying) or "?",
				carry and tostring(carry.Uid) or "?", tostring(ctx.claimFeedback), now - started)
		end
		if now - started >= CONFIG.ClaimTimeout then
			return false, "attribution non confirmee pour l'UID ; verifie la zone safe"
		end
		task.wait(0.1)
	end
	return false, "annule"
end

local function cleanupCycle(ctx)
	if currentCycle ~= ctx then return end
	recordFlightResult(ctx, false)
	if timingEnabled then
		local now = os.clock()
		log("TIMING_CYCLE", "TotalMs=%.1f DernierePhase=%s PhaseMs=%.1f", (now - (ctx.startedAt or now)) * 1000, tostring(ctx.phase), (now - (ctx.phaseStartedAt or now)) * 1000)
	end
	if ctx.cancelPendingWait then ctx.cancelPendingWait() end
	stopMovement()
	if shared.__AutoSAEMovementLock == ctx.movementLock then shared.__AutoSAEMovementLock = nil end
	currentCycle = nil
end

local function getStartAreaDestination()
	local world = Workspace:FindFirstChild("World")
	local areas = world and world:FindFirstChild("Areas")
	local area = areas and areas:FindFirstChild("StartArea")
	local center
	if area and area:IsA("BasePart") then
		center = area.Position
	elseif area and area:IsA("Model") and area:FindFirstChildWhichIsA("BasePart", true) then
		local bounds = area:GetBoundingBox()
		center = bounds.Position
	end
	if not center then return nil, "World.Areas.StartArea introuvable ou sans centre" end
	local _, humanoid = getCharacterParts()
	return center + Vector3.new(0, (humanoid and humanoid.HipHeight or 2) + 2, 0)
end

local function runCycle(record, rate, recovering, findNext)
	local character, humanoid, root = getCharacterParts()
	if not character or not humanoid or not root then return false, "personnage absent" end
	local destination, destinationReason = getStartAreaDestination()
	if not destination then return false, destinationReason end
	safeHome = destination

	if not safeHome or isSafe(safeHome) ~= true then
		return false, "position de retour sure non disponible"
	end
	local ctx = {
		uid = record.Uid, record = record, generation = generation, character = character, findNext = findNext,
		startedAt = os.clock(), phaseStartedAt = os.clock(),
		home = safeHome, eggPosition = record.BottomCFrame and record.BottomCFrame.Position,
		attempts = 0, lastRequest = -math.huge, phase = "SELECTED", ownerBefore = ownerSnapshot(),
		remoteAccepted = recovering == true, sawCarry = recovering == true,
		pickupVersion = record.Version, hadCarry = recovering == true,
	}
	if shared.__AutoSAEMovementLock then return false, "un autre deplacement automatique est actif" end
	ctx.movementLock = {Owner = "Auto_SAE", Character = character, Generation = generation}
	shared.__AutoSAEMovementLock = ctx.movementLock
	currentCycle = ctx
	log("TARGET", "Animal=%s Revenu=%s/s Home=%s Recovery=%s",
		getAnimalName(record), formatNumber(rate or 0), formatPosition(ctx.home), tostring(recovering))
	local cycleOK, completed, failure = xpcall(function()
		local grabbed, grabReason
		if recovering then
			grabbed = true
		elseif not ctx.eggPosition then
			return false, "position de l'oeuf absente"
		else
			local destination = Vector3.new(ctx.eggPosition.X, ctx.home.Y, ctx.eggPosition.Z)
			grabbed, grabReason = measureAction("APPROCHE_ET_PRISE", moveThenCarry, ctx, destination)
		end
		if ctx.gameplayEntryRejected then
			return false, "GAMEPLAY_ENTRY_REQUIRED"
		end
		if not validCycle(ctx) then return false, "annule" end
		if not grabbed and inFlightRequest and not inFlightRequest.done then
			return false, grabReason or "requete serveur encore en cours"
		end
		ctx.hadCarry = grabbed == true
		ctx.watchForReappearance = not grabbed
		if not grabbed then log("TARGET_RETURN_EMPTY", "UID=%s : retour en surveillant sa reapparition", ctx.uid) end
		while validCycle(ctx) do
			local returned, returnReason = measureAction("RETOUR", moveReturnLoop, ctx, ctx.home)
			if returned then
				local _, _, currentRoot = getCharacterParts()
				if not currentRoot or isSafe(currentRoot.Position) ~= true then
					return false, "retour termine mais ligne safe non franchie"
				end
				if not grabbed then return false, "TARGET_UNAVAILABLE" end
				local claimed, claimReason = measureAction("CONFIRMATION_ATTRIBUTION", waitForClaim, ctx)
				if claimed then return true end
				if claimReason ~= CARRY_LOST then return false, claimReason end
				returnReason = CARRY_LOST
			end
			if returnReason == "TARGET_CARRIED" then
				grabbed = true
			elseif returnReason == "TARGET_REAPPEARED" then
				if inFlightRequest and not inFlightRequest.done then
					return false, "requete serveur encore en cours"
				end
				log("TARGET_REAPPEARED", "UID=%s : reprise du trajet vers l'oeuf", ctx.uid)
				ctx.pickupVersion = ctx.record.Version
				ctx.returnKickAt = nil
				ctx.remoteAccepted, ctx.sawCarry, ctx.claimed, ctx.claimFeedback = false, false, false, false
				ctx.carryLostAt, ctx.lossLogged, ctx.reacquiring = nil, false, false
				ctx.attempts, ctx.lastRequest = 0, -math.huge
				local target = Vector3.new(ctx.eggPosition.X, ctx.home.Y, ctx.eggPosition.Z)
				grabbed, grabReason = moveThenCarry(ctx, target)
				if ctx.gameplayEntryRejected then return false, "GAMEPLAY_ENTRY_REQUIRED" end
				if not validCycle(ctx) then return false, "annule" end
				if not grabbed and inFlightRequest and not inFlightRequest.done then
					return false, grabReason or "requete serveur encore en cours"
				end
				ctx.hadCarry = grabbed == true
				ctx.watchForReappearance = not grabbed
			elseif returnReason == CARRY_LOST then
				grabbed = false
				ctx.hadCarry, ctx.watchForReappearance = false, true
				log("TARGET_RETURN_EMPTY", "UID=%s : port perdu, retour sans arret en surveillant l'oeuf", ctx.uid)
			else
				return false, returnReason
			end
		end
		return false, "annule"
	end, debug.traceback)
	recordFlightResult(ctx, cycleOK and completed == true)
	cleanupCycle(ctx)
	if not cycleOK then return false, tostring(completed) end
	return completed, failure
end

local function ingest(record)
	if type(record) ~= "table" or type(record.Uid) ~= "string" then return end
	records[record.Uid] = record
	if trackedEggs[record.Uid] then
		trackedEggs[record.Uid].Record=record
		if record.CarrierUserId then trackedEggs[record.Uid].LastCarrier=record.CarrierUserId end
	end
	logEgg(record)
end

local function snapshot(snapshotData)
	if type(snapshotData) ~= "table" or type(snapshotData.Records) ~= "table" then return end
	local updated = {}
	for _, record in ipairs(snapshotData.Records) do
		if type(record) == "table" and type(record.Uid) == "string" then
			updated[record.Uid] = record
			logEgg(record)
		end
	end
	records = updated
end

local function queueOrder()
	local result = {}
	for uid, entry in pairs(queuedEggs) do
		entry.Uid = uid
		entry.Rate = getRatePerSecond(records[uid] or entry.Record) or entry.Rate or 0
		table.insert(result, entry)
	end
	table.sort(result, function(a, b)
		if a.Rate ~= b.Rate then return a.Rate > b.Rate end
		return a.Uid < b.Uid
	end)
	return result
end

-- Mirror the backpack: placed eggs are excluded from its virtual egg list.
local function backpackEggCategories(profile)
	local categories = {}
	for _, egg in pairs(type(profile) == "table" and profile.EggInventory or {}) do
		if type(egg) == "table" and egg.Placement == nil and type(egg.AssetCategory) == "string" then
			categories[egg.AssetCategory] = true
		end
	end
	return categories
end

local function plotAnimalCategories()
	local categories = {}
	if AssetRoster then
		local ok, pen = pcall(AssetRoster.ReadOwnerPen, player.UserId)
		if ok and type(pen) == "table" then
			for _, record in pairs(pen) do
				local item = type(record) == "table" and record.ItemData
				if type(item) == "table" and type(item.Category) == "string" then categories[item.Category] = true end
			end
		end
	end
	local ok, profile = pcall(Save.Peek)
	if ok and type(profile) == "table" then
		for _, egg in pairs(profile.EggInventory or {}) do
			if type(egg) == "table" and egg.Placement ~= nil and type(egg.AssetCategory) == "string" then
				categories[egg.AssetCategory] = true
			end
		end
	end
	return categories
end

local function enqueueEgg(record, source)
	if type(record) ~= "table" or type(record.Uid) ~= "string" then return false end
	local function reject(reason)
		if source == "AUTO" or source == "DIVINE" then logQueueDecision(record.Uid, reason) end
		return false
	end
	if record.IsHalloweenObservation then return reject("EXCLU : Halloween en observation") end
	if source == "INDEX" and plotAnimalCategories()[record.AssetCategory] then return reject("EXCLU : espece deja presente dans ton plot") end
	if (source == "AUTO" or source == "INDEX") and removedFromAuto[record.Uid] then return reject("EXCLU : retire manuellement de la file") end
	if source == "MANUEL" then removedFromAuto[record.Uid] = nil end
	if source == "INDEX" then
		if currentCycle and currentCycle.record and currentCycle.record.AssetCategory == record.AssetCategory then return false end
		for _, entry in pairs(queuedEggs) do
			if entry.Record.AssetCategory == record.AssetCategory then return false end
		end
	end
	if queuedEggs[record.Uid] then
		if source == "AUTO" or source == "DIVINE" then logQueueDecision(record.Uid, "EN FILE | Auto=" .. tostring(autoEnabled) .. " Pause=" .. tostring(queuePaused) .. " Activite=" .. autoActivity .. " Cooldown=" .. tostring((cooldowns[record.Uid] or 0) > os.clock())) end
		return false
	end
	if not isTrackedFieldState(record) then return reject("EXCLU : etat=" .. tostring(record.State)) end
	if ownsEgg(record.Uid) then return reject("EXCLU : oeuf deja possede") end
	trackedEggs[record.Uid] = trackedEggs[record.Uid] or {Record=record}
	trackedEggs[record.Uid].Record=record
	if record.CarrierUserId then trackedEggs[record.Uid].LastCarrier=record.CarrierUserId end
	queuedEggs[record.Uid] = {Record = record, Rate = getRatePerSecond(record) or 0, Source = source}
	logQueueDecision(record.Uid, "AJOUT " .. source .. " | revenu=" .. tostring(queuedEggs[record.Uid].Rate) .. " seuil=" .. tostring(minimumRatePerSecond))
	return true
end

syncQueue = function()
	if not ready or destroyed then return end
	refreshHalloweenRecords()
	local plotCategories = plotAnimalCategories()
	for uid, entry in pairs(queuedEggs) do
		if not currentCycle or currentCycle.uid ~= uid then
			local record = readField(uid)
			if not record or ownsEgg(uid) or not isTrackedFieldState(record)
				or (entry.Source == "INDEX" and plotCategories[record.AssetCategory]) then
				queuedEggs[uid],trackedEggs[uid] = nil,nil
			else
				entry.Record = record
			end
		end
	end
	if automaticMode then
		local ok, profile = pcall(Save.Peek)
		local index = ok and type(profile) == "table" and profile.Index
		local backpackCategories = backpackEggCategories(ok and profile or nil)
		local candidates = {}
		for uid, record in pairs(records) do
			do
				local calculatedRate = getRatePerSecond(record)
				local rate = calculatedRate or 0
				local missing = autoIncludeMissingIndex and type(index) == "table"
					and type(record.AssetCategory) == "string" and Assets.Directory[record.AssetCategory] ~= nil
					and index[record.AssetCategory] ~= true
					and not backpackCategories[record.AssetCategory]
				if getRarityName(record) == "Divine" then
					local existing = queuedEggs[uid]
					if existing then existing.Source = "DIVINE" end
					enqueueEgg(record, "DIVINE")
				elseif rate >= minimumRatePerSecond then
					local existing = queuedEggs[uid]
					if existing and existing.Source == "INDEX" then existing.Source = "AUTO" end
					enqueueEgg(record, "AUTO")
				elseif missing then
					table.insert(candidates, record)
				else
					logQueueDecision(uid, calculatedRate and ("HORS SEUIL : revenu=" .. tostring(rate) .. " seuil=" .. tostring(minimumRatePerSecond) .. " | index non eligible") or "REVENU INDISPONIBLE : calcul impossible")
				end
			end
		end
		-- Rebuild pending Index entries to keep the most profitable available egg.
		for uid, entry in pairs(queuedEggs) do
			if entry.Source == "INDEX" and not isHeldByOther(entry.Record) and (not currentCycle or currentCycle.uid ~= uid) then
				queuedEggs[uid] = nil
			end
		end
		table.sort(candidates, function(a,b)
			local ar,br = getRatePerSecond(a) or 0,getRatePerSecond(b) or 0
			if ar ~= br then return ar > br end
			return a.Uid < b.Uid
		end)
		for _, record in ipairs(candidates) do enqueueEgg(record, "INDEX") end
	end
	local total, queued, above = 0, 0, 0
	for _, record in pairs(records) do
		total += 1
		if (getRatePerSecond(record) or 0) >= minimumRatePerSecond then above += 1 end
	end
	for _ in pairs(queuedEggs) do queued += 1 end
	local summary = string.format("Mode=%s AutoParam=%s Collecte=%s Pause=%s Seuil=%s Detectes=%d AuDessusSeuil=%d EnFile=%d",
		detectedMode, tostring(automaticMode), tostring(autoEnabled), tostring(queuePaused), tostring(minimumRatePerSecond), total, above, queued)
	if summary ~= lastQueueSummary then
		lastQueueSummary = summary
		log("QUEUE_SUMMARY", "%s", summary)
	end
	if refreshQueueInterface then refreshQueueInterface() end
end

local function selectBest()
	local best, bestRate = nil, -math.huge
	local _, _, root = getCharacterParts()
	for uid, entry in pairs(queuedEggs) do
		local cached = records[uid] or entry.Record
		if queuedEggs[uid] and isTrackedFieldState(cached) and (cooldowns[uid] or 0) <= os.clock() then
			local latest, ok = readField(uid)
			if ok and isTrackedFieldState(latest) and not ownsEgg(uid) then
				if not latest.ObservationOnly then records[uid] = latest end
				local rate = getRatePerSecond(latest)
				if rate == nil and getRarityName(latest) == "Divine" then rate = 0 end
				if rate then
					if rate > bestRate or (rate == bestRate and root and best
						and distanceXZ(latest.BottomCFrame.Position, root.Position)
						< distanceXZ(best.BottomCFrame.Position, root.Position)) then
						best, bestRate = latest, rate
					end
				end
			end
		end
	end
	return best, bestRate
end

stopAutomation = function(reason, pause)
	queuePaused = pause ~= false
	autoEnabled = false
	generation += 1
	if currentCycle then cleanupCycle(currentCycle) end
	stopMovement(true)
	setStatus(reason or "Arrete", Color3.fromRGB(255, 150, 120))
	if renderControls then renderControls() end
	log("STOP", "%s | RemoteEnCours=%s", reason or "utilisateur", tostring(inFlightRequest and not inFlightRequest.done))
end

local function activityValid(token, character)
	return detectedMode == "Normal" and not destroyed and autoEnabled and generation == token and not queuePaused
		and player.Character == character
end

local function moveActivity(destination, token, interruptForEgg, nextDestination)
	local character, humanoid, root = getCharacterParts()
	if not character or not humanoid or not root then return false, "personnage absent" end
	local started = os.clock()
	local deadline = started + math.clamp(distanceXZ(root.Position, destination) / math.max(humanoid.WalkSpeed, 1) * 3 + 5, 8, 30)
	local previous = root.Position
	local nextCommand = 0
	while true do
		if not activityValid(token, character) or humanoid.Health <= 0 then
			stopMovement()
			return false, "annule"
		end
		if interruptForEgg and (not automaticMode or next(queuedEggs) ~= nil) then
			stopMovement()
			return false, "nouvel oeuf"
		end
		local now = os.clock()
		local current = root.Position
		local distance = distanceXZ(current, destination)
		if distance <= 3 then
			move(destination, {Radius = 3})
			log("ACTIVITY_ARRIVED", "Activite=%s Distance=%.2f DureeMs=%.1f", autoActivity, distance, (now-started)*1000)
			if typeof(nextDestination) == "Vector3" then
				move(nextDestination, {Radius = CONFIG.PreciseArrivalRadius})
				log("ACTIVITY_CHAIN", "Depart->oeuf : commande envoyee dans la meme frame que le freinage")
			end
			return true
		end
		if now >= deadline then stopMovement(true); return false, "MoveTo : destination non atteinte" end
		if not motionBlockReason({character = character}) then
			local segment = Vector3.new(current.X-previous.X,0,current.Z-previous.Z)
			local offset = Vector3.new(destination.X-previous.X,0,destination.Z-previous.Z)
			if segment.Magnitude > 0.01 then
				local projection = offset:Dot(segment)/segment:Dot(segment)
				if projection > 0 and projection < 1 and (offset-segment*projection).Magnitude <= 3 then
					stopMovement(true)
					nextCommand = 0
					log("ACTIVITY_OVERSHOOT_BRAKE", "Activite=%s Distance=%.2f : depassement freine", autoActivity, distance)
				end
			end
			if distance < 100 or now >= nextCommand then
				move(destination, {Radius = 3})
				nextCommand = now + CONFIG.MoveRefresh
			end
		end
		previous = current
		RunService.Heartbeat:Wait()
	end
end

-- Serialize treadmill requests, including late replies after a timeout.
local function treadmillRequest(remote, token)
	if treadmillPending then return false, "requete tapis en cours" end
	treadmillPending = true
	local done, accepted, reason = false, false, nil
	task.spawn(function()
		local ok, result, detail = pcall(function() return remote:InvokeServer() end)
		accepted, reason = ok and result == true, ok and detail or result
		done, treadmillPending = true, false
		if accepted and remote == TreadmillRemotes.AskWearStill and (destroyed or not autoEnabled or queuePaused) then
			task.spawn(function() pcall(function() TreadmillRemotes.AskDoff:InvokeServer() end) end)
		end
	end)
	local deadline = os.clock() + CONFIG.RequestTimeout
	while not done and not destroyed and generation == token and os.clock() < deadline do task.wait(0.05) end
	if not done then return false, "reponse tapis en attente" end
	return accepted, reason
end


local function leaveTreadmill(token)
	if not treadmillAssigned and autoActivity ~= "TREADMILL" and autoActivity ~= "TO_TREADMILL" then return true end
	autoActivity = "LEAVING_TREADMILL"
	setStatus("Sortie du tapis puis trajet vers StartArea...")
	local _, humanoid = getCharacterParts()
	if treadmillAssigned then
		local ok, reason = treadmillRequest(TreadmillRemotes.AskDoff, token)
		if not ok then return false, tostring(reason) end
		local deadline = os.clock() + 5
		while treadmillAssigned and autoEnabled and generation == token and os.clock() < deadline do task.wait(0.05) end
		if treadmillAssigned then return false, "sortie du tapis non confirmee" end
	end
	if humanoid then humanoid.Jump = true end
	autoActivity = "FARM"
	safeHome = getStartAreaDestination()
	log("TREADMILL_EXIT_READY", "Sortie confirmee : MoveTo direct vers le centre de StartArea")
	return true
end

local function hatchReadyEggsOnWallClose(token)
	if hatchInProgress or not PlacedEggRenderer or not EggGrowthPolicy then return end
	local ok, eggs = pcall(EggState.ReadOwnerEggs, player.UserId)
	if not ok or type(eggs) ~= "table" then log("HATCH_SCAN", "Lecture des oeufs indisponible"); return end
	local readyUids = {}
	local opened = 0
	for uid, record in pairs(eggs) do
		if type(uid) == "string" and type(record) == "table" and record.Placement ~= nil then
			local valid, grown = pcall(EggGrowthPolicy.IsReady, record, 0)
			local rate = getRatePerSecond(record)
			if valid and grown and rate and rate < openBelowRate then table.insert(readyUids, uid) end
		end
	end
	table.sort(readyUids)
	for _, uid in ipairs(readyUids) do
		if destroyed or not autoEnabled or generation ~= token or not automaticMode or queuePaused then break end
		local readOK, latest = pcall(EggState.ReadOwnedEgg, player.UserId, uid)
		local readyOK, grown = false, false
		if readOK and type(latest) == "table" and latest.Placement ~= nil then
			readyOK, grown = pcall(EggGrowthPolicy.IsReady, latest, 0)
		end
		local rate = readOK and type(latest) == "table" and getRatePerSecond(latest)
		if readyOK and grown and rate and rate < openBelowRate then
			hatchInProgress = true
			setStatus("Mur ferme : ouverture des oeufs prets...")
			local activated, accepted, reason = pcall(PlacedEggRenderer.ActivateLocalEgg, uid)
			hatchInProgress = false
			if activated and accepted == true then opened += 1 end
			log("WALL_HATCH", "UID=%s Accepte=%s Raison=%s", uid, tostring(activated and accepted == true), tostring(activated and reason or accepted))
		end
	end
	return opened
end


-- Egg capacity is independent of the equipped-animal limit.
local function plotEggCapacity(eggs)
	local limit = GameplayBalance and GameplayBalance.EggInventory and GameplayBalance.EggInventory.MAX_PLACED_EGGS
	if type(limit) ~= "number" or limit ~= limit or limit < 0 or limit == math.huge then return nil, 0 end
	local count = 0
	for _, egg in pairs(eggs) do
		if egg.InventoryPlaced or egg.Placement ~= nil then count += 1 end
	end
	return math.max(0, math.floor(limit)-count), count
end

local function inventoryPlacementOrder(eggs, selection)
	local ids = {}
	for uid, egg in pairs(eggs) do
		if not egg.InventoryPlaced and egg.Placement == nil and (not selection or selection[uid]) then
			table.insert(ids, uid)
		end
	end
	table.sort(ids, function(a,b)
		local ar, br = getRatePerSecond(eggs[a]) or 0, getRatePerSecond(eggs[b]) or 0
		if ar ~= br then return ar > br end
		return a < b
	end)
	return ids
end

local function findPlotEggSpot(plot, eggs, reserved)
	local area = plot.PetArea
	local targets = {area}
	PlacedEggRenderer.AppendRaycastTargets(targets, player.UserId)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = targets
	params.IgnoreWater = true
	local occupied = {}
	for _, egg in pairs(eggs) do
		if egg.Placement and typeof(egg.Placement.LocalCFrame) == "CFrame" then
			table.insert(occupied, (plot.CenterPoint.CFrame * egg.Placement.LocalCFrame).Position)
		end
	end
	for _, point in ipairs(reserved) do table.insert(occupied, point) end
	local halfX, halfZ = area.Size.X*0.5-2, area.Size.Z*0.5-2
	if halfX < 0 or halfZ < 0 then return nil end
	local points = {}
	for x=-halfX,halfX,4 do
		for z=-halfZ,halfZ,4 do
			local point = area.CFrame:PointToWorldSpace(Vector3.new(x, area.Size.Y*0.5, z))
			local clear = true
			for _, other in ipairs(occupied) do
				if distanceXZ(point,other) < 4 then clear = false; break end
			end
			if clear then table.insert(points,point) end
		end
	end
	local _, _, root = getCharacterParts()
	table.sort(points,function(a,b)
		return root and distanceXZ(a,root.Position)<distanceXZ(b,root.Position) or (not root and a.X<b.X)
	end)
	for _, point in ipairs(points) do
		local hit = Workspace:Raycast(point+area.CFrame.UpVector*256, -area.CFrame.UpVector*512,params)
		if hit and hit.Instance == area then
			return plot.CenterPoint.CFrame:ToObjectSpace(CFrame.new(hit.Position)), hit.Position
		end
	end
	return nil
end

local function placeInventoryEggs(selection, token, opened)
	if inventoryPlacementBusy or placementRequest or currentCycle or serverHopPending or hatchInProgress then return 0, "Placement indisponible : action en cours" end
	if not ready or destroyed or not PlotState or not inventoryEggRecords then return 0, "Modules indisponibles" end
	local carry = readCarry()
	if not carry or carry.IsCarrying or (inFlightRequest and not inFlightRequest.done) then return 0, "Transport ou requete en cours" end
	local plot = PlotState.ResolvePlot()
	local _, humanoid, root = getCharacterParts()
	if not plot or not root or not humanoid or humanoid.Health<=0 then return 0, "Plot ou personnage indisponible" end
	if isSafe(root.Position)~=true then return 0, "Rejoins la zone sure pour placer les oeufs" end
	if token == nil and (autoEnabled or treadmillAssigned or not PlotState.ContainsLocalPoint(root.Position)) then
		return 0, "Rejoins ton enclos hors du tapis pour placer la selection"
	end
	local placementGeneration, character = generation, player.Character
	local function valid()
		return not destroyed and generation==placementGeneration and player.Character==character
			and not currentCycle and not serverHopPending and humanoid.Health>0
			and (token==nil or (autoEnabled and automaticMode and generation==token and not queuePaused and not stopAfterFlight))
	end
	if not valid() then return 0, "Placement annule" end
	inventoryPlacementBusy = true
	local placed, summary, reserved = 0, "Aucun oeuf a placer", {}
	local ok, failure = xpcall(function()
		local eggs = inventoryEggRecords()
		local ids = inventoryPlacementOrder(eggs,selection)
		if #ids==0 then return end
		local free = plotEggCapacity(eggs)
		if free==nil then summary="Limite d'oeufs places indisponible"; return end
		-- Hatching is asynchronous: let its confirmed inventory update release capacity.
		local untilAt = os.clock()+8
		while free==0 and (opened or 0)>0 and valid() and os.clock()<untilAt do
			task.wait(0.1)
			eggs=inventoryEggRecords()
			free=plotEggCapacity(eggs)
			if free==nil then break end
		end
		if not free or free<=0 then summary="Enclos plein : limite des oeufs places atteinte"; return end
		if token~=nil then
			local exited, reason=leaveTreadmill(token)
			if not exited then summary="Sortie tapis : "..tostring(reason); return end
			autoActivity="TO_PLOT"
			local target=plot.PetArea.Position+Vector3.new(0,humanoid.HipHeight+2,0)
			local reached, reason=moveActivity(target,token,false)
			if not reached then summary="Trajet enclos : "..tostring(reason); return end
		end
		for _,uid in ipairs(ids) do
			if not valid() then summary="Placement interrompu"; break end
			local currentPlot=PlotState.ResolvePlot()
			if not currentPlot or currentPlot.PlotFolder~=plot.PlotFolder then summary="Plot modifie"; break end
			eggs=inventoryEggRecords()
			free=plotEggCapacity(eggs)
			if not free or free<=0 then summary="Enclos plein"; break end
			local egg=eggs[uid]
			if egg and not egg.InventoryPlaced and egg.Placement==nil then
				local localFrame, point=findPlotEggSpot(plot,eggs,reserved)
				if not localFrame then summary="Aucun emplacement libre detecte"; break end
				local request={done=false}
				placementRequest=request
				task.spawn(function()
					request.ok,request.accepted,request.reason=pcall(function()
						local equipped,why=EggState.WearEggTool(uid)
						if equipped~=true then return false,why end
						if not valid() then return false,"Placement annule" end
						return EggState.PlantEgg(uid,localFrame)
					end)
					request.done=true
					if placementRequest==request then placementRequest=nil end
				end)
				local deadline=os.clock()+CONFIG.RequestTimeout
				while not request.done and valid() and os.clock()<deadline do task.wait(0.05) end
				if not request.done then summary="Placement en attente du serveur : aucun nouvel envoi"; break end
				if not request.ok or request.accepted~=true then
					summary="Placement refuse : "..tostring(request.ok and request.reason or request.accepted)
					log("PLOT_PLACE","UID=%s %s",uid,summary)
					break
				end
				table.insert(reserved,point)
				local confirmed=false
				deadline=os.clock()+3
				repeat
					local latest=EggState.ReadOwnedEgg(player.UserId,uid)
					confirmed=latest~=nil and latest.Placement~=nil
					if confirmed or not valid() or os.clock()>=deadline then break end
					task.wait(0.05)
				until false
				log("PLOT_PLACE","UID=%s Accepte=true Confirme=%s",uid,tostring(confirmed))
				if not confirmed then summary="Placement accepte : confirmation inventaire en attente"; break end
				placed+=1
				if selection then selection[uid]=nil end
				PlacedEggRenderer.Refresh()
				summary=tostring(placed).." oeuf(s) place(s)"
			end
		end
	end,debug.traceback)
	inventoryPlacementBusy=false
	if not ok then summary="Placement : "..tostring(failure); log("ERROR","%s",summary) end
	if not destroyed then
		setStatus(summary)
		if refreshEggInterface then refreshEggInterface() end
	end
	return placed,summary
end

local function serviceWallMaintenance(token)
	if destroyed or not automaticMode or not autoEnabled or generation ~= token or currentCycle or inventoryPlacementBusy or placementRequest then return end
	if not wallMaintenancePending and os.clock()-lastMaintenanceAt < 15 then return end
	local _, _, root = getCharacterParts()
	if not root or isSafe(root.Position) ~= true then return end
	wallMaintenancePending = false
	lastMaintenanceAt = os.clock()
	local opened = hatchReadyEggsOnWallClose(token)
	if destroyed or not autoEnabled or generation ~= token or queuePaused then return end
	placeInventoryEggs(nil,token,opened)
	if destroyed or not autoEnabled or generation ~= token or queuePaused or placementRequest then return end
	if HaulRemotes and os.clock() - lastEquipBestAt >= 5 then
		lastEquipBestAt = os.clock()
		setStatus("Mur ferme : Equip Best...")
		local ok, accepted, reason = pcall(function() return HaulRemotes.WearBest:InvokeServer() end)
		log("WALL_EQUIP_BEST", "Accepte=%s Raison=%s", tostring(ok and accepted == true), tostring(ok and reason or accepted))
	end
end

local function idleOnTreadmill(token)
	if not PlotState or not TreadmillRemotes then return false, "modules tapis indisponibles" end
	local slot = PlotState.ResolveLocalSlot()
	local plots = Workspace:FindFirstChild("Plots")
	local plot = plots and slot and plots:FindFirstChild(tostring(slot))
	local bottom = plot and plot:FindFirstChild("TreadmillBottom")
	if not bottom or not bottom:IsA("BasePart") then return false, "tapis de ta parcelle introuvable" end
	autoActivity = "TO_TREADMILL"
	setStatus("File vide : trajet vers le tapis...")
	if not treadmillAssigned then
		local _, humanoid = getCharacterParts()
		local destination = bottom.Position + Vector3.new(0, humanoid.HipHeight + 2, 0)
		local ok, reason = measureAction("ENTREE_TAPIS", moveActivity, destination, token, true)
		if not ok then
			if reason == "nouvel oeuf" then return true end
			return false, reason
		end
		-- The normal controller detects entry with its downward raycast.
		local deadline = os.clock() + 0.35
		while not treadmillAssigned and autoEnabled and generation == token and os.clock() < deadline
			and next(queuedEggs) == nil do task.wait(0.1) end
		if not treadmillAssigned and automaticMode and next(queuedEggs) == nil then
			local accepted, detail = treadmillRequest(TreadmillRemotes.AskWearStill, token)
			if not accepted and not treadmillAssigned then return false, tostring(detail or "entree tapis refusee") end
			deadline = os.clock() + 5
			while not treadmillAssigned and autoEnabled and generation == token and os.clock() < deadline do task.wait(0.1) end
			if not treadmillAssigned then return false, "entree tapis non confirmee" end
		end
	end
	autoActivity = "TREADMILL"
	if destroyed or not autoEnabled or generation ~= token then return true end
	setStatus("TREADMILL : entrainement, attente d'un oeuf...")
	while autoEnabled and generation == token and automaticMode and not queuePaused
		and next(queuedEggs) == nil and not (automaticMode and searchingServer and not searchWaitForEgg) and not activityRecheckPending and not destroyed do
		serviceWallMaintenance(token)
		if not treadmillAssigned and autoActivity ~= "TREADMILL" then return true end
		syncQueue()
		task.wait(CONFIG.ScanInterval)
	end
	return true
end

local function requestUserStop(reason)
	if autoEnabled and (currentCycle ~= nil or autoActivity == "FARM") then
		stopAfterFlight = true
		setStatus("Arret demande : fin du vol puis pause.")
		if renderControls then renderControls() end
		return
	end
	stopAfterFlight = false
	local wasOnTreadmill = treadmillAssigned or autoActivity == "TREADMILL" or autoActivity == "TO_TREADMILL"
	stopAutomation(reason or "AUTO arrete")
	autoActivity = "IDLE"
	if wasOnTreadmill and TreadmillRemotes and not treadmillPending then
		local stopToken = generation
		task.spawn(function() treadmillRequest(TreadmillRemotes.AskDoff, stopToken) end)
	end
end

local function worker(token)
	local directNext = false
	while autoEnabled and generation == token and not destroyed do
		serviceWallMaintenance(token)
		if activityRecheckPending then
			activityRecheckPending = false
			syncQueue()
			local nextMode = next(queuedEggs) ~= nil and "FARM" or "TREADMILL"
			log("RESET_MODE_CHECK", "Reinitialisation/session : mode choisi=%s", nextMode)
		end
		if placementRequest then stopAutomation("Placement serveur en attente : reprise apres sa reponse"); return end
		if inFlightRequest and not inFlightRequest.done then
			stopAutomation("Requete serveur en cours : attendre sa reponse")
			return
		end
		if stopAfterFlight and not currentCycle then
			stopAfterFlight = false
			stopAutomation("Arret apres le vol")
			autoActivity = "IDLE"
			return
		end
		local carry = readCarry()
		if not carry then
			stopAutomation("Etat de transport indisponible")
			return
		end
		syncQueue()
		local selected, rate, recovering
		if carry.IsCarrying and carry.Uid then
			if not queuedEggs[carry.Uid] then
				stopAutomation("Un oeuf hors de la file est deja porte")
				return
			end
			selected = readField(carry.Uid)
			selected = selected or {Uid = carry.Uid, AssetCategory = carry.AssetCategory}
			recovering = true
		else
			selected, rate = selectBest()
		end
		if selected then
			searchWaitForEgg = false
			serverSearchState = automaticMode and "Oeuf eligible : collecte" or "OFF"
			local exited, exitReason = measureAction("SORTIE_TAPIS", leaveTreadmill, token)
			if not exited then stopAutomation("Sortie tapis : " .. tostring(exitReason)); return end
			if not autoEnabled or generation ~= token then return end
			if not recovering and not directNext then
				local destination, destinationReason = getStartAreaDestination()
				if not destination then stopAutomation(destinationReason); return end
				autoActivity = "TO_FARM"
				setStatus("Trajet vers le centre de StartArea...")
				log("START_AREA_MOVETO", "Trajet direct vers %s", formatPosition(destination))
				local eggPosition = getRecordPosition(records[selected.Uid] or selected)
				local nextDestination = eggPosition and Vector3.new(eggPosition.X, destination.Y, eggPosition.Z)
				local reached, reason = measureAction("TRAJET_STARTAREA", moveActivity, destination, token, false, nextDestination)
				if not reached then stopAutomation("StartArea : " .. tostring(reason)); return end
			end
			if not autoEnabled or generation ~= token then return end
			autoActivity = "FARM"
			log("FARM_START", "UID=%s : sortie StartArea atteinte, trajet vers l'oeuf", selected.Uid)
			directNext = false
			local success, reason = measureAction("VOL_COMPLET", runCycle, selected, rate, recovering, selectBest)
			if not autoEnabled or generation ~= token then return end
			if success then
				wallMaintenancePending = true
				selectedEggs[selected.Uid] = nil
				queuedEggs[selected.Uid],trackedEggs[selected.Uid] = nil,nil
				if refreshQueueInterface then refreshQueueInterface() end
				if renderControls then renderControls() end
				if automaticMode and not stopAfterFlight then
					searchingServer = true
					serviceWallMaintenance(token)
					if requestRandomServerHop and requestRandomServerHop(token, "Oeuf attribue") then return end
				end
			end
			if not success then
				if reason == "GAMEPLAY_ENTRY_REQUIRED" then
					stopAutomation("Prise refusee : entre manuellement dans la zone de jeu puis relance la collecte.")
					return
				end
				log("CYCLE_FAILED", "UID=%s Raison=%s", selected.Uid, tostring(reason))
				cooldowns[selected.Uid] = (reason == "TARGET_UNAVAILABLE" or reason == "NEXT_AVAILABLE") and 0 or (os.clock() + CONFIG.FailedTargetCooldown)
				queuedEggs[selected.Uid] = nil
				-- Never continue after ambiguous ownership or an unresolved request.
				if recovering or (inFlightRequest and not inFlightRequest.done) then
					stopAutomation(tostring(reason))
					return
				end
				local after = readCarry()
				local _, _, root = getCharacterParts()
				if not after or after.IsCarrying or not root or (reason ~= "NEXT_AVAILABLE" and isSafe(root.Position) ~= true)
					or string.find(tostring(reason), "attribution", 1, true)
					or string.find(tostring(reason), "recuperation", 1, true) then
					stopAutomation(tostring(reason))
					return
				end
				if reason == "NEXT_AVAILABLE" then
					directNext = true
					log("NEXT_TARGET", "Oeuf disparu : trajet direct vers le prochain oeuf de la file")
				end
			end
		else
			directNext = false
			if automaticMode and searchingServer then
				if searchWaitForEgg then
					serverSearchState = "Suspendue : attente d'un oeuf eligible"
					local ok, reason = idleOnTreadmill(token)
					if not ok then stopAutomation("Tapis : "..tostring(reason)); return end
				elseif os.clock() < serverSearchReadyAt then
					serverSearchState = "Recherche : chargement des oeufs"
					task.wait(CONFIG.ScanInterval)
				else
					serverSearchState = "Recherche : aucun oeuf eligible"
					if requestRandomServerHop and requestRandomServerHop(token, "Aucun oeuf eligible") then return end
					task.wait(0.5)
				end
			elseif automaticMode then
				serverSearchState = "OFF"
				local ok, reason = idleOnTreadmill(token)
				if not autoEnabled or generation ~= token then return end
				if not ok then stopAutomation("Tapis : " .. tostring(reason)); return end
			else
				stopAutomation("File terminee", false)
				return
			end
		end
		task.wait() -- Yield one frame, then immediately select the next available egg.
	end
end

startAutomation = function(billions)
	if detectedMode ~= "Normal" then setStatus("Mode Halloween : observation uniquement."); return false end
	if destroyed or not ready then
		setStatus("Les modules du jeu sont indisponibles", Color3.fromRGB(255, 130, 110))
		return false
	end
	if inFlightRequest and not inFlightRequest.done then
		setStatus("Une requete attend encore le serveur", Color3.fromRGB(255, 190, 100))
		return false
	end
	local _, humanoid, root = getCharacterParts()
	if not humanoid or not root or humanoid.Health <= 0 then
		setStatus("Personnage indisponible")
		return false
	end
	safeHome = getStartAreaDestination()
	if not safeHome or isSafe(safeHome) ~= true then
		setStatus("File en attente : rejoins la zone sure", Color3.fromRGB(255, 190, 100))
		return false
	end
	if type(billions) ~= "number" or billions ~= billions or math.abs(billions) == math.huge then
		setStatus("Seuil invalide : entre 0.1 et 999 B/s")
		return false
	end
	minimumRatePerSecond = math.clamp(billions, MINIMUM_BILLIONS, MAXIMUM_BILLIONS) * 1e9
	generation += 1
	local token = generation
	autoEnabled = true
	snapshot(EggState.ReadFieldEggs())
	if renderControls then renderControls() end
	log("START", "Minimum=%s/s SafeHome=%s Session=%d",
		formatNumber(minimumRatePerSecond), formatPosition(safeHome), token)
	task.spawn(function()
		local ok, failure = xpcall(function() worker(token) end, debug.traceback)
		if not ok then
			log("ERROR", "%s", tostring(failure))
			if generation == token then stopAutomation("Erreur : voir la console Auto_SAE") end
		end
	end)
	return true
end

wakeQueue = function()
	if inventoryPlacementBusy or placementRequest or serverHopPending or detectedMode ~= "Normal" or destroyed or not ready or autoEnabled or queuePaused or (not automaticMode and next(queuedEggs) == nil) then return end
	if inFlightRequest and not inFlightRequest.done then return end
	startAutomation(minimumRatePerSecond / 1e9)
end

local function loadModule(path)
	log("MODULE_LOADING", "%s", path)
	local deadline, node = os.clock() + 12, ReplicatedStorage
	for name in string.gmatch(path, "[^%.]+") do
		local child = node:FindFirstChild(name)
		while not child and os.clock() < deadline and not destroyed do
			task.wait(0.1)
			child = node:FindFirstChild(name)
		end
		assert(child, "ReplicatedStorage." .. path .. " introuvable")
		node = child
	end
	local module = require(node)
	log("MODULE_READY", "%s", path)
	return module
end

local function initialize()
	EggState = loadModule("Client.EggState")
	AreaEggCycle = loadModule("Shared.Util.AreaEggCycle")
	ServerClock = loadModule("Shared.Util.ServerClock")
	Assets = loadModule("Data.Assets")
	HalloweenPets = loadModule("Data.HalloweenPets")
	EggRecords = loadModule("Shared.Util.EggRecords")
	AssetEarnings = loadModule("Shared.Util.AssetEarnings")
	SlotIdentity = loadModule("Shared.Util.AreaEggSlotIdentity")
	GuardGeometry = loadModule("Shared.Util.GuardAreaGeometry")
	Save = loadModule("Shared.Save")
	PlotState = loadModule("Client.PlotState")
	AssetRoster = loadModule("Client.AssetRoster")
	PlacedEggRenderer = loadModule("Shared.Eggs.PlacedEggRenderer")
	EggGrowthPolicy = loadModule("Shared.Eggs.PlacedEggGrowthPresentationPolicy")
	local remotes = loadModule("Shared.Remotes")
	TreadmillRemotes = remotes.Treadmill
	HaulRemotes = remotes.Haul
	GameplayBalance = loadModule("Shared.Flags.GameplayBalance")
	-- Optional event support must not prevent the egg interface from starting.
	local function updateWorldMode()
		local nextMode = player:GetAttribute("InHalloweenDimension") == true and "Halloween" or "Normal"
		if nextMode ~= detectedMode then
			detectedMode = nextMode
			log("WORLD_MODE", "%s", detectedMode)
			if autoEnabled then stopAutomation("Changement de monde : " .. detectedMode, false) end
			autoActivity = "IDLE"
			activityRecheckPending = true
			if detectedMode == "Normal" then syncQueue(); wakeQueue() end
		end
		if detectedMode == "Halloween" then setStatus("Mode Halloween : observation uniquement, trajets non actives.") end
		if ready then
			refreshHalloweenRecords()
			if refreshEggInterface then refreshEggInterface() end
			if refreshQueueInterface then refreshQueueInterface() end
			if refreshBestEggCard then refreshBestEggCard() end
		end
		if renderControls then renderControls() end
	end
	connect(player:GetAttributeChangedSignal("InHalloweenDimension"), updateWorldMode)
	updateWorldMode()
	local resetWall = loadModule("Client.AreaEggResetWall")
	connect(resetWall.Changed, function(sealed)
		if sealed == true and not destroyed and automaticMode then
			wallMaintenancePending = true
			serverSearchReadyAt = os.clock()+15
			activityRecheckPending = true
			log("EGG_RESET", "Reevaluation de la file et du tapis apres le vol actif.")
			log("WALL_CLOSED", "Ouverture des oeufs prets puis Equip Best; differe si un vol est en cours.")
		end
	end)
	connect(TreadmillRemotes.AssignedBeltShifted.OnClientEvent, function(id)
		treadmillAssigned = id ~= nil
	end)
	if destroyed then return end
	if CONFIG.ObserveRigSync then
		local sharedFolder = ReplicatedStorage:FindFirstChild("Shared")
		local remotesModule = sharedFolder and sharedFolder:FindFirstChild("Remotes")
		local ok, bound = pcall(function()
			local remotes = remotesModule and require(remotesModule)
			if type(remotes) ~= "table" or type(remotes.RigSync) ~= "table" then return false end
			local refresh = remotes.RigSync.Refresh
			local signal = refresh and refresh.OnClientEvent
			if not signal or type(signal.Connect) ~= "function" then return false end
			connect(signal, observeRigRefresh)
			return true
		end)
		if ok and bound then
			log("RIG_OBSERVER_READY", "RigSync.Refresh : lecture seule ; protections du jeu conservees")
		else
			log("RIG_OBSERVER_UNAVAILABLE", "Module optionnel absent ou incompatible : IsTrapped/etat Humanoid restent utilises")
		end
	end
	for _, name in ipairs({"CarryFieldEgg", "ReadFieldEgg", "ReadFieldEggs", "ReadCarryState", "ReadOwnedEgg", "ReadOwnerEggs"}) do
		assert(type(EggState[name]) == "function", "EggState." .. name .. " indisponible")
	end
	connect(EggState.FieldRefreshed, snapshot)
	connect(EggState.FieldShifted, ingest)
	connect(EggState.FieldGone, function(uid)
		records[uid], loggedVersions[uid] = nil, nil
		if trackedEggs[uid] then log("EGG_TRACK","UID=%s Retire du snapshot : suivi physique conserve",uid) end
		log("FIELD_GONE", "UID=%s | ne prouve pas la possession", tostring(uid))
	end)
	connect(EggState.CarryChanged, function(state)
		local ctx = currentCycle
		log("CARRY_CHANGED", "Carrying=%s UID=%s Area=%s SpeedMultiplier=%s",
			tostring(state.IsCarrying), tostring(state.Uid), tostring(state.AreaId), tostring(state.SpeedMultiplier))
		if ctx and state.IsCarrying and state.Uid == ctx.uid then
			ctx.sawCarry, ctx.carryLostAt = true, nil
		elseif ctx and ctx.hadCarry and (ctx.phase == "RETURN" or ctx.phase == "CONFIRM_CLAIM") then
			ctx.carryLostAt = os.clock()
			log("CARRY_RELEASED", "Transport termine | UID cible=%s | verification perte ou attribution", ctx.uid)
		end
	end)
	connect(EggState.FieldClaimed, function(payload)
		local ctx = currentCycle
		log("FIELD_CLAIMED", "Animal=%s Rarity=%s Pos=%s | payload sans UID",
			tostring(payload.AssetCategory), tostring(payload.Rarity), formatPosition(payload.Position))
		if ctx and payload.AssetCategory == ctx.record.AssetCategory
			and (ctx.sawCarry or ctx.remoteAccepted) then
			ctx.claimFeedback = true
		end
		-- Final success is still checked against ReadOwnedEgg(localUserId, exactUid).
	end)
	connect(EggState.OwnerRefreshed, function(userId)
		if userId == player.UserId and currentCycle then
			log("OWNER_REFRESHED", "UID=%s Possession=%s", currentCycle.uid, tostring(ownsEgg(currentCycle.uid)))
		end
	end)
	snapshot(EggState.ReadFieldEggs())
	serverSearchReadyAt = os.clock()+15
	wallMaintenancePending = true
	ready = true
	setStatus("AUTO ON : recherche des oeufs, sinon entrainement au tapis.", Color3.fromRGB(96, 230, 145))
	syncQueue()
	wakeQueue()
	if refreshEggInterface then refreshEggInterface() end
	if refreshBestEggCard then refreshBestEggCard() end
	log("READY", "Build=2.4 | MoveTo renouvele / freinage horizontal / distance 3D <= 8 / %d essais en serie / retour / inventaire / reprise meme UID", CONFIG.MaxCarryAttempts)
end

inventoryEggRecords = function()
	local result = {}
	local ok, profile = pcall(Save.Peek)
	if not ok or type(profile) ~= "table" then return result end
	for uid, saved in pairs(profile.EggInventory or {}) do
		if type(uid) == "string" and type(saved) == "table" then
			local decoded, record = pcall(EggRecords.Decode, saved)
			if decoded and type(record) == "table" then
				record.Uid, record.InventoryOwned = uid, true
				record.InventoryPlaced = saved.Placement ~= nil
				result[uid] = record
			end
		end
	end
	return result
end

local function filterPublicServers(data, currentJobId)
	local result, seen = {}, {}
	for _, server in ipairs(type(data) == "table" and data or {}) do
		if type(server) == "table" and type(server.id) == "string" and server.id ~= currentJobId and not seen[server.id]
			and type(server.playing) == "number" and type(server.maxPlayers) == "number"
			and server.playing >= 0 and server.playing < server.maxPlayers then
			seen[server.id] = true
			table.insert(result, server)
		end
	end
	table.sort(result, function(a,b)
		if a.playing ~= b.playing then return a.playing < b.playing end
		return a.id < b.id
	end)
	return result
end

local function fetchPublicServers()
	local all, cursor = {}, nil
	for page = 1, 3 do
		if destroyed then return {} end
		local url = "https://games.roblox.com/v1/games/" .. tostring(game.PlaceId) .. "/servers/Public?sortOrder=Asc&limit=100"
		if cursor then url ..= "&cursor=" .. HttpService:UrlEncode(cursor) end
		local request = executorFunction("request") or executorFunction("http_request")
		local body
		if request then
			local response = request({Url=url, Method="GET"})
			if type(response) ~= "table" or tonumber(response.StatusCode) ~= 200 then
				error("Recherche serveurs refusee : HTTP " .. tostring(type(response)=="table" and response.StatusCode or "?"))
			end
			body = response.Body
		else
			body = game:HttpGet(url)
		end
		local decoded = HttpService:JSONDecode(body)
		if type(decoded) ~= "table" or type(decoded.data) ~= "table" then error("Reponse serveurs invalide") end
		for _, server in ipairs(decoded.data) do table.insert(all, server) end
		cursor = type(decoded.nextPageCursor) == "string" and decoded.nextPageCursor or nil
		if not cursor or cursor == "" then break end
		task.wait(0.2)
	end
	return filterPublicServers(all, game.JobId)
end



local function holdSearchForReset()
	if searchWaitForEgg then return true end
	if not AreaEggCycle or not ServerClock then return false end
	local ok, remaining = pcall(function()
		if not AreaEggCycle.IsRunning() then return nil end
		-- Same countdown as GameResetTimerController, including schedule overrides.
		return AreaEggCycle.SecondsUntilPhaseEnd(ServerClock.Now())
	end)
	if ok and type(remaining) == "number" and remaining >= 0 and remaining < 60 then
		searchWaitForEgg = true
		serverSearchState = "Suspendue : reset dans "..math.ceil(remaining).." s ; attente d'un oeuf eligible"
		log("SERVER_CHANGE", "Recherche suspendue : compte a rebours %.1f s ; maintien sur ce serveur jusqu'au prochain oeuf eligible", remaining)
		return true
	end
	return false
end

-- Server search starts only after a confirmed successful collection.
local function prepareServerContinuation()
	local queue = executorFunction("queue_on_teleport") or executorFunction("queueonteleport")
	if not queue then
		local synApi = executorEnvironment.syn
		if type(synApi) == "table" and type(synApi.queue_on_teleport) == "function" then queue = synApi.queue_on_teleport end
	end
	if not queue then return false, "Relancement automatique indisponible : queue_on_teleport absent" end
	return pcall(queue, [[
		if not game:IsLoaded() then game.Loaded:Wait() end
		loadstring(game:HttpGet("https://raw.githubusercontent.com/cagnastylepay-png/Sae/main/Test.lua"))()
	]])
end

requestRandomServerHop = function(token, reason)
	if serverHopPending then return true end
	if not automaticMode or not autoEnabled or generation ~= token
		or destroyed or currentCycle or inventoryPlacementBusy or placementRequest or hatchInProgress or stopAfterFlight or queuePaused
		or os.clock() < nextServerHopAt then return false end
	if holdSearchForReset() then return false end
	local carry = readCarry()
	if not carry or carry.IsCarrying or (inFlightRequest and not inFlightRequest.done) then return false end
	nextServerHopAt = os.clock()+30
	serverSearchState = "Recherche de serveur..."
	setStatus(serverSearchState)
	local ok, servers = pcall(fetchPublicServers)
	-- An OFF click during HTTP must cancel this departure.
	if destroyed or not automaticMode or not autoEnabled
		or generation ~= token or queuePaused or stopAfterFlight then return false end
	if not ok or #servers == 0 then
		serverSearchState = "Recherche : nouvel essai dans 30 s"
		log("SERVER_CHANGE", "Recherche echouee : %s", ok and "aucun serveur disponible" or tostring(servers))
		return false
	end
	if reason == "Aucun oeuf eligible" then
		syncQueue()
		if os.clock() < serverSearchReadyAt or selectBest() then return false end
	end
	if holdSearchForReset() then return false end
	local saved, saveReason = executorTools.SaveSettings()
	if not saved then
		serverSearchState = "Recherche bloquee : sauvegarde indisponible"
		log("SERVER_CHANGE", "%s", tostring(saveReason))
		return false
	end
	local queued, queueReason = prepareServerContinuation()
	if not queued then
		serverSearchState = "Recherche bloquee : relancement indisponible"
		log("SERVER_CHANGE", "%s", tostring(queueReason))
		return false
	end
	local destination = servers[Random.new():NextInteger(1,#servers)].id
	serverHopPending = true
	serverSearchState = "Changement de serveur..."
	stopMovement(true)
	log("SERVER_CHANGE", "%s | Destination=%s Recherche=%s", reason, destination, tostring(searchingServer))
	executorTools.SaveLog()
	local function resumeAfterFailure(message)
		if not serverHopPending or destroyed then return end
		serverHopPending = false
		autoEnabled = false
		autoActivity = "IDLE"
		serverSearchState = "Echec connexion : nouvel essai dans 30 s"
		nextServerHopAt = os.clock()+30
		log("SERVER_CHANGE", "%s", tostring(message))
		if automaticMode and not queuePaused then wakeQueue() end
	end
	local failureConnection
	failureConnection = connect(game:GetService("TeleportService").TeleportInitFailed,function(failedPlayer, result, message)
		if failedPlayer ~= player then return end
		failureConnection:Disconnect()
		resumeAfterFailure(tostring(result)..": "..tostring(message))
	end)
	local sent, failure = pcall(function()
		game:GetService("TeleportService"):TeleportToPlaceInstance(game.PlaceId,destination,player)
	end)
	if not sent then failureConnection:Disconnect(); resumeAfterFailure(failure); return true end
	task.delay(25,function()
		failureConnection:Disconnect()
		resumeAfterFailure("Connexion non terminee apres 25 s")
	end)
	return true
end

-- FOXIN reference logic: direct Workspace models, matching names, zero Velocity,
-- MoveTo at the current root position, every 0.2 seconds. Always active.
local function immobilizeReferenceGuards()
	for _, model in ipairs(Workspace:GetChildren()) do
		if model:IsA("Model") then
			local nameL = model.Name:lower()
			if string.find(nameL, "guard") or string.find(nameL, "boss")
				or string.find(nameL, "jefe") or string.find(nameL, "enemy") then
				local npcHumanoid = model:FindFirstChildOfClass("Humanoid")
				local hrp = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
				if npcHumanoid and hrp then
					hrp.Velocity = Vector3.zero
					npcHumanoid:MoveTo(hrp.Position)
				end
			end
		end
	end
end
local guardControlElapsed = 0
connect(RunService.Heartbeat, function(delta)
	if destroyed then return end
	guardControlElapsed += delta
	if guardControlElapsed < 0.2 then return end
	guardControlElapsed = 0
	local ok, reason = pcall(immobilizeReferenceGuards)
	if not ok then log("GUARD_CONTROL", "Reference FOXIN : %s", tostring(reason)) end
end)

local function createInterface()
	local playerGui = player:WaitForChild("PlayerGui")
	local previous = shared.__AutoSAEController
	if previous and type(previous.Destroy) == "function" then pcall(previous.Destroy) end
	local old = playerGui:FindFirstChild("AutoSAEGui")
	if old then old:Destroy() end
	local source = game:GetService("StarterGui"):FindFirstChild("SellPrompt") or playerGui:FindFirstChild("SellPrompt")
	assert(source and source:IsA("ScreenGui"), "SellPrompt est introuvable")
	local gui = Instance.new("ScreenGui")
	gui.Name = "AutoSAEGui"
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.IgnoreGuiInset = false
	for _, name in ipairs({"Frame", "Assets", "Backdrop"}) do
		local child = source:FindFirstChild(name)
		if child then child:Clone().Parent = gui end
	end
	gui.ResetOnSpawn = false
	gui.Enabled = true
	gui.DisplayOrder = 10000
	for _, descendant in ipairs(gui:GetDescendants()) do
		if descendant:IsA("BaseScript") then descendant:Destroy() end
	end
	local frame = gui:WaitForChild("Frame")
	frame.Visible = false
	local tabs = frame:WaitForChild("TabButtonHolder")
	local mapTab = tabs:WaitForChild("EggsTab")
	local queueTab = tabs:WaitForChild("PetsTab")
	mapTab.Name = "MapTab"
	queueTab.Name = "QueueTab"
	mapTab.Title.Text = "Map"
	queueTab.Title.Text = "Queue"
	local paramsTab = queueTab:Clone()
	paramsTab.Name = "ParamsTab"
	paramsTab.Title.Text = "Params"
	paramsTab.Parent = tabs
	local eggsTab = mapTab:Clone()
	eggsTab.Name = "BackpackTab"
	eggsTab.Title.Text = "Backpack"
	eggsTab.Parent = tabs
	local plotTab = eggsTab:Clone()
	plotTab.Name = "PlotEggsTab"
	plotTab.Title.Text = "Plot"
	plotTab.Parent = tabs
	mapTab.LayoutOrder, queueTab.LayoutOrder, eggsTab.LayoutOrder, plotTab.LayoutOrder, paramsTab.LayoutOrder = 1, 2, 3, 4, 5
	tabs.Size = UDim2.new(tabs.Size.X.Scale * 0.5, tabs.Size.X.Offset * 0.5, tabs.Size.Y.Scale, tabs.Size.Y.Offset)
	for _, tabButton in ipairs({mapTab, queueTab, eggsTab, plotTab, paramsTab}) do
		tabButton.Size = UDim2.fromScale(1, 0)
		local aspect = tabButton:FindFirstChildOfClass("UIAspectRatioConstraint")
		if not aspect then aspect = Instance.new("UIAspectRatioConstraint", tabButton) end
		aspect.AspectRatio = 1
		aspect.DominantAxis = Enum.DominantAxis.Width
		aspect.AspectType = Enum.AspectType.ScaleWithParentSize
	end
	local activeTab = "Map"
	local mapSelection = selectedEggs
	local queueSelection = {}
	local inventorySelection = {}
	local plotSelection = {}
	local inventoryRecords = {}
	local sort = frame:WaitForChild("SortByHolder")
	for _, name in ipairs({"Weight", "Value", "PaddingTop", "PaddingSelect"}) do
		local object = sort:FindFirstChild(name)
		if object then object:Destroy() end
	end
	sort.Title.Text = "Collecte"
	sort.Title.LayoutOrder = 90
	local selectionTitle = sort.Title:Clone()
	selectionTitle.Name = "SelectionTitle"
	selectionTitle.Text = "Selection"
	selectionTitle.LayoutOrder = 0
	selectionTitle.Parent = sort
	local collectionSpacer = Instance.new("Frame")
	collectionSpacer.Name = "CollectionSpacer"
	collectionSpacer.BackgroundTransparency = 1
	collectionSpacer.Size = UDim2.fromScale(0.91, 0.04)
	collectionSpacer.LayoutOrder = 80
	collectionSpacer.Parent = sort
	local function caption(button, text)
		button.AutoLocalize = false
		for _, object in ipairs(button:GetDescendants()) do
			if object:IsA("TextLabel") or object:IsA("TextButton") then
				object.AutoLocalize = false
				object.Text = text
			end
		end
	end
	caption(sort.SelectAll, "Selectionner")

	sort.Clear.LayoutOrder = 60
	sort.SelectAll.LayoutOrder = 50
	local missingButton = sort.SelectAll:Clone()
	missingButton.Name = "SelectMissingIndex"
	missingButton.LayoutOrder = 45
	missingButton.Parent = sort
	for _, object in ipairs(missingButton:GetDescendants()) do
		if object:IsA("TextLabel") then
			object.Text = "Manquants"
			object.AutoLocalize = false
			object.Size = UDim2.fromScale(0.92, 0.85)
			object.Position = UDim2.fromScale(0.5, 0.5)
			object.AnchorPoint = Vector2.new(0.5, 0.5)
			object.TextScaled = true
		end
	end
	local missingIcon = missingButton:FindFirstChild("Icon")
	if missingIcon then missingIcon.Visible = false end
	local autoButton = sort.SelectAll:Clone()
	autoButton.Name = "AutomaticMode"
	autoButton.LayoutOrder = 10
	autoButton.Parent = sort
	local autoIcon = autoButton:FindFirstChild("Icon")
	if autoIcon then autoIcon.Visible = false end
	local function setAutoCaption(text)
		for _, object in ipairs(autoButton:GetDescendants()) do
			if object:IsA("TextLabel") then
				object.Text = text
				object.Size = UDim2.fromScale(0.92, 0.85)
				object.Position = UDim2.fromScale(0.5, 0.5)
				object.AnchorPoint = Vector2.new(0.5, 0.5)
				object.TextScaled = true
			end
		end
	end
	local thresholdTitle = sort.Title:Clone()
	thresholdTitle.Name = "ThresholdTitle"
	thresholdTitle.LayoutOrder = 20
	thresholdTitle.Text = "Minimum (B/s)"
	thresholdTitle.Size = UDim2.fromScale(0.95, 0.08)
	thresholdTitle.TextScaled = true
	thresholdTitle.Parent = sort
	minimumInput = Instance.new("TextBox")
	minimumInput.Name = "MinimumBillions"
	minimumInput.LayoutOrder = 30
	minimumInput.Size = UDim2.fromScale(0.91, 0.12)
	minimumInput.BackgroundColor3 = Color3.fromRGB(35, 41, 57)
	minimumInput.TextColor3 = Color3.new(1, 1, 1)
	minimumInput.Font = Enum.Font.GothamBold
	minimumInput.TextSize = 16
	minimumInput.ClearTextOnFocus = false
	minimumInput.PlaceholderText = "0.1 - 999"
	minimumInput.Text = formatNumber(minimumRatePerSecond).."/s"
	minimumInput.Parent = sort
	local thresholdCorner = Instance.new("UICorner", minimumInput)
	thresholdCorner.CornerRadius = UDim.new(0, 8)
	local function readThreshold()
		local rate = parseIncomeRate(minimumInput.Text)
		local value = rate and rate / 1e9
		if not value or value ~= value or math.abs(value) == math.huge then
			setStatus("Seuil invalide : entre 0.1 et 999 B/s", Color3.fromRGB(255, 130, 110))
			return nil
		end
		value = math.clamp(value, MINIMUM_BILLIONS, MAXIMUM_BILLIONS)
		minimumInput.Text = formatNumber(value*1e9).."/s"
		return value
	end
	connect(minimumInput.FocusLost, function()
		do
			local value = readThreshold()
			if value then
				minimumRatePerSecond = value * 1e9
				if syncQueue then syncQueue() end
				if wakeQueue then wakeQueue() end
				if renderControls then renderControls() end
			end
		end
	end)

	local header = frame:WaitForChild("Header")
	for _, name in ipairs({"Title", "Title2Stroke"}) do
		local title = header:FindFirstChild(name)
		if title then title.Text = "Auto Eggs" end
	end
	local info = frame:WaitForChild("SellInfoHolder")
	info.Title.Text = "Selection :"
	info.Value.Text = "0 oeuf"
	info.Icon.Visible = false
	toggleButton = info:WaitForChild("Sell")
	toggleButton.Name = "Add"
	toggleButton.Title.Text = "Add"
	local scroll = frame:WaitForChild("ScrollingFrame")
	scroll.AnchorPoint = Vector2.zero
	scroll.Position = UDim2.fromScale(0.22, 0.16)
	scroll.Size = UDim2.fromScale(0.766, 0.67)
	local template = gui.Assets:WaitForChild("TemplateHolder"):Clone()
	template.Visible = true
	for _, object in ipairs(scroll:GetChildren()) do
		if object:IsA("GuiObject") then object:Destroy() end
	end
	local grid = scroll:FindFirstChildOfClass("UIGridLayout") or Instance.new("UIGridLayout", scroll)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.CellPadding = UDim2.fromOffset(10, 16)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new()
	local function resizeGrid()
		local width = math.max(scroll.AbsoluteSize.X - scroll.ScrollBarThickness - 12, 120)
		local columns = math.max(1, math.floor((width + 10) / 130))
		local side = math.floor((width - (columns - 1) * 10) / columns)
		grid.CellSize = UDim2.fromOffset(side, side + 25)
	end
	connect(scroll:GetPropertyChangedSignal("AbsoluteSize"), resizeGrid)
	resizeGrid()
	statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "AutoStealStatus"
	statusLabel.BackgroundTransparency = 1
	statusLabel.TextColor3 = Color3.fromRGB(225, 230, 245)
	statusLabel.Font = Enum.Font.GothamMedium
	statusLabel.TextSize = 12
	statusLabel.TextWrapped = true
	statusLabel.AnchorPoint = Vector2.new(0, 1)
	statusLabel.Position = UDim2.fromScale(0.02, 0.99)
	statusLabel.Size = UDim2.fromScale(0.70, 0.28)
	statusLabel.ZIndex = toggleButton.ZIndex + 5
	statusLabel.Parent = info
	info.Title.Position = UDim2.fromScale(0.03, 0.08)
	info.Title.AnchorPoint = Vector2.zero
	info.Title.Size = UDim2.fromScale(0.23, 0.35)
	info.Value.Position = UDim2.fromScale(0.28, 0.08)
	info.Value.AnchorPoint = Vector2.zero
	info.Value.Size = UDim2.fromScale(0.42, 0.35)
	for _, object in ipairs(info:GetChildren()) do
		if object.Name == "ShadowDecor" then object.Visible = false end
	end
	local function paintEggCard(visual, record)
		local config = getAssetConfig(record)
		local icon = config and config.Egg and config.Egg.Icon
		visual.Icon.Image = icon or "rbxassetid://103094823152347"
		local rate = getRatePerSecond(record)
		visual.Amount.Text = rate and (formatNumber(rate) .. "/s") or "?"
		local weight = getWeightKg(record)
		visual.Weight.Text = weight and string.format("%.1f kg", weight) or ""
		local valueHolder = visual:FindFirstChild("ValueHolder")
		if valueHolder then
			valueHolder.Value.Text = getAnimalName(record)
			valueHolder.Value.Size = UDim2.fromScale(0.95, 0.9)
			valueHolder.Value.Position = UDim2.fromScale(0.5, 0.5)
			valueHolder.Value.AnchorPoint = Vector2.new(0.5, 0.5)
			valueHolder.Value.TextScaled = true
			if valueHolder:FindFirstChild("Icon") then valueHolder.Icon.Visible = false end
		end
		if record.IsHalloweenObservation then
			visual.Weight.Text = weight and (string.format("%.1f kg", weight) .. (record.WeightIsReference and " base" or "")) or "Poids inconnu"
			visual.Amount.Text = rate and (formatNumber(rate) .. "/s" .. (not record.ObservedRate and record.RateIsReference and " base" or "")) or "Revenu inconnu"
		end
	end
	local backdrop = gui:FindFirstChild("Backdrop")
	local hudToggle = gui:FindFirstChild("HudToggle")
	if hudToggle then hudToggle:Destroy() end
	local function show(open)
		frame.Visible = open
		if backdrop then backdrop.Visible = open end
		if open and refreshEggInterface then refreshEggInterface() end
		if open and refreshQueueInterface then refreshQueueInterface() end
	end
	connect(frame.Close.Activated, function() show(false) end)
	if backdrop and backdrop:IsA("GuiButton") then
		connect(backdrop.Activated, function() show(false) end)
	end
	gui.Parent = playerGui
	local mainCard = template:Clone()
	mainCard.Name = "BestEggLauncher"
	mainCard.Visible = true
	mainCard.AnchorPoint = Vector2.new(1, 0)
	mainCard.Position = UDim2.new(1, -16, 0, 16)
	mainCard.Size = UDim2.fromOffset(120, 145)
	mainCard.ZIndex = 1000
	mainCard.Parent = gui
	for _, object in ipairs(mainCard:GetDescendants()) do
		if object:IsA("GuiObject") then object.ZIndex += 1000 end
	end
	mainCard.SelectedOverlay.Visible = false
	mainCard.SelectedIcon.Visible = false
	local openCard = Instance.new("TextButton")
	openCard.Name = "OpenAutoEggs"
	openCard.BackgroundTransparency = 1
	openCard.Text = ""
	openCard.Size = UDim2.fromScale(1, 1)
	openCard.ZIndex = 2000
	openCard.Parent = mainCard
	local dragInput, dragStart, dragPosition, dragging, moved, suppressClickUntil
	suppressClickUntil = 0
	connect(openCard.InputBegan, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragInput, dragStart, dragPosition = input, input.Position, mainCard.Position
			dragging, moved = true, false
		end
	end)
	connect(UserInputService.InputChanged, function(input)
		if not dragging then return end
		if input == dragInput or input.UserInputType == Enum.UserInputType.MouseMovement then
			local delta = input.Position - dragStart
			if delta.Magnitude > 6 then moved = true end
			if moved then
				local viewport = gui.AbsoluteSize
				local minX = math.min(mainCard.AbsoluteSize.X, viewport.X)
				local x = math.clamp(dragPosition.X.Scale * viewport.X + dragPosition.X.Offset + delta.X, minX, viewport.X)
				local y = math.clamp(dragPosition.Y.Scale * viewport.Y + dragPosition.Y.Offset + delta.Y, 0, math.max(0, viewport.Y-mainCard.AbsoluteSize.Y))
				mainCard.Position = UDim2.fromOffset(x, y)
			end
		end
	end)
	connect(UserInputService.InputEnded, function(input)
		if input == dragInput or (dragging and input.UserInputType == Enum.UserInputType.MouseButton1) then
			if moved then suppressClickUntil = os.clock() + 0.25 end
			dragging, dragInput = false, nil
		end
	end)
	connect(openCard.Activated, function()
		if not moved and os.clock() >= suppressClickUntil then show(not frame.Visible) end
	end)
	refreshBestEggCard = function()
		if destroyed or not ready then return end
		local best, bestRate
		for _, pool in ipairs({detectedMode == "Halloween" and halloweenRecords or records}) do
			for uid, record in pairs(pool) do
				if (record.State == SLOT_STATE or record.State == "Dropped") and record.CarrierUserId == nil and not ownsEgg(uid) then
					local rate = getRatePerSecond(record)
					local score = rate or -1
					if not best or score > bestRate or (score == bestRate and uid < best.Uid) then best, bestRate = record, score end
				end
			end
		end
		local visual = mainCard.Template
		if best then
			paintEggCard(visual, best)
			mainCard:SetAttribute("EggUid", best.Uid)
		else
			visual.Icon.Image = "rbxassetid://103094823152347"
			visual.Amount.Text = "Aucun oeuf"
			visual.Weight.Text = detectedMode
			local label = visual:FindFirstChild("ValueHolder")
			if label then label.Value.Text = "Auto Eggs" end
			mainCard:SetAttribute("EggUid", nil)
		end
	end

	local paramsPanel = Instance.new("ScrollingFrame")
	paramsPanel.Name = "Params"
	paramsPanel.AutomaticCanvasSize = Enum.AutomaticSize.Y
	paramsPanel.CanvasSize = UDim2.new()
	paramsPanel.ScrollBarThickness = 6
	paramsPanel.ScrollingDirection = Enum.ScrollingDirection.Y
	paramsPanel.BorderSizePixel = 0
	paramsPanel.BackgroundTransparency = 1
	paramsPanel.Position = scroll.Position
	paramsPanel.Size = scroll.Size
	paramsPanel.Visible = false
	paramsPanel.Parent = frame
	local worldModeLabel = thresholdTitle:Clone()
	worldModeLabel.Name = "DetectedWorldMode"
	worldModeLabel.LayoutOrder = 0
	worldModeLabel.Size = UDim2.fromScale(0.95, 0.10)
	worldModeLabel.Parent = paramsPanel
	local paramsLayout = Instance.new("UIListLayout", paramsPanel)
	paramsLayout.Padding = UDim.new(0, 16)
	paramsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	autoButton.Parent = paramsPanel
	local includeMissingButton = autoButton:Clone()
	includeMissingButton.Name = "AutoIncludeMissingIndex"
	includeMissingButton.LayoutOrder = 40
	includeMissingButton.Parent = paramsPanel
	caption(includeMissingButton, "Manquants : ON")
	connect(includeMissingButton.Activated, function()
		autoIncludeMissingIndex = not autoIncludeMissingIndex
		caption(includeMissingButton, autoIncludeMissingIndex and "Manquants : ON" or "Manquants : OFF")
		setStatus(autoIncludeMissingIndex and "AUTO : seuil OU animaux manquants." or "AUTO : seuil de revenu uniquement. File existante conservee.")
		if ready then syncQueue(); wakeQueue() end
	end)

	local function paramButton(name, order, text, callback)
		local button = autoButton:Clone()
		button.Name = name
		button.LayoutOrder = order
		button.Size = UDim2.new(0.9, 0, 0, 44)
		button.Parent = paramsPanel
		caption(button, text)
		connect(button.Activated, callback)
		return button
	end

	local function rateInput(name, order, label, initial, apply)
		local title = thresholdTitle:Clone()
		title.Name, title.LayoutOrder = name.."Label", order
		title.Text, title.Size = label, UDim2.new(0.95,0,0,32)
		title.Parent = paramsPanel
		local input = minimumInput:Clone()
		input.Name, input.LayoutOrder = name, order+1
		input.Size = UDim2.new(0.9,0,0,44)
		input.Text = formatNumber(initial).."/s"
		input.Parent = paramsPanel
		connect(input.FocusLost,function()
			local rate = parseIncomeRate(input.Text)
			if not rate then setStatus("Revenu invalide : exemple 2B/s ou 500M/s"); input.Text = formatNumber(initial).."/s"; return end
			initial = rate
			input.Text = formatNumber(rate).."/s"
			apply(rate)
			wallMaintenancePending = true
			executorTools.SaveSettings()
		end)
		return input
	end
	rateInput("OpenBelowRate", 52, "Ouvrir les oeufs prets sous ce revenu", openBelowRate, function(rate) openBelowRate = rate end)
	thresholdTitle.Parent = paramsPanel
	minimumInput.Parent = paramsPanel
	autoButton.Size = UDim2.fromScale(0.65, 0.16)
	thresholdTitle.Size = UDim2.fromScale(0.65, 0.10)
	minimumInput.Size = UDim2.fromScale(0.65, 0.14)
	refreshQueueInterface = function()
		local entries = queueOrder()
		local visibleCount = 0
		for _, entry in ipairs(entries) do
			if isEggInCurrentWorld(entry.Record or records[entry.Uid]) then visibleCount += 1 end
		end
		queueTab.Title.Text = "Queue (" .. visibleCount .. ")"
		for uid in pairs(queueSelection) do
			if not queuedEggs[uid] then queueSelection[uid] = nil end
		end
		if activeTab == "Queue" and refreshEggInterface then refreshEggInterface() end
	end
	local pauseButton = sort.SelectAll:Clone()
	pauseButton.Name = "QueueOn"
	pauseButton.LayoutOrder = 100
	caption(pauseButton, "ON")
	pauseButton.Parent = sort
	local pausedButton = sort.Clear:Clone()
	pausedButton.Name = "QueueOff"
	pausedButton.LayoutOrder = 100
	caption(pausedButton, "OFF")
	pausedButton.Parent = sort
	local function toggleQueue()
		if queuePaused then
			queuePaused = false
			wakeQueue()
		else
			requestUserStop("File en pause")
		end
		if renderControls then renderControls() end
		refreshQueueInterface()
	end
	connect(pauseButton.Activated, toggleQueue)
	connect(pausedButton.Activated, toggleQueue)

	local function switchTab(name)
		activeTab = name
		selectedEggs = name == "Queue" and queueSelection or (name == "Backpack" and inventorySelection or (name == "Plot" and plotSelection or mapSelection))
		scroll.Visible = name ~= "Params"
		paramsPanel.Visible = name == "Params"
		sort.Visible = name ~= "Params"
		plotTab.Title.TextColor3 = name == "Plot" and Color3.new(1,1,1) or Color3.fromRGB(170,180,200)
		eggsTab.Title.TextColor3 = name == "Backpack" and Color3.new(1,1,1) or Color3.fromRGB(170,180,200)
		paramsTab.Title.TextColor3 = name == "Params" and Color3.new(1,1,1) or Color3.fromRGB(170,180,200)
		mapTab.Title.TextColor3 = name == "Map" and Color3.new(1, 1, 1) or Color3.fromRGB(170, 180, 200)
		queueTab.Title.TextColor3 = name == "Queue" and Color3.new(1, 1, 1) or Color3.fromRGB(170, 180, 200)
		if name == "Queue" and refreshQueueInterface then refreshQueueInterface() end
		if (name == "Map" or name == "Backpack" or name == "Plot") and refreshEggInterface then refreshEggInterface() end
		if renderControls then renderControls() end
	end
	connect(mapTab.Activated, function() switchTab("Map") end)
	connect(queueTab.Activated, function() switchTab("Queue") end)
	connect(paramsTab.Activated, function() switchTab("Params") end)
	connect(eggsTab.Activated, function() switchTab("Backpack") end)
	connect(plotTab.Activated, function() switchTab("Plot") end)
	switchTab("Map")
	local cards = {}
	local function countSelected()
		local n = 0
		for _ in pairs(selectedEggs) do n += 1 end
		return n
	end
	local function updateSelection()
		worldModeLabel.Text = "Mode : " .. detectedMode .. (detectedMode == "Halloween" and " (observation)" or "")
		for _, name in ipairs({"Title", "Title2Stroke"}) do
			local title = header:FindFirstChild(name)
			if title then title.Text = "Auto Eggs - " .. detectedMode end
		end
		local count = countSelected()
		info.Value.Text = activeTab == "Params" and ("AUTO >= " .. formatNumber(minimumRatePerSecond) .. "/s") or (tostring(count) .. (count == 1 and " oeuf" or " oeufs"))
		setAutoCaption(stopAfterFlight and "ARRET EN ATTENTE" or (automaticMode and "AUTO : ON" or "AUTO : OFF"))
		caption(includeMissingButton, autoIncludeMissingIndex and "Manquants : ON" or "Manquants : OFF")
		minimumInput.TextEditable = true
		thresholdTitle.Visible = true
		minimumInput.Visible = true
		toggleButton.Title.Text = activeTab == "Backpack" and (inventoryPlacementBusy and "Placement..." or "Placer") or (activeTab == "Queue" and "Remove" or "Add")
		toggleButton.Visible = activeTab ~= "Plot" and activeTab ~= "Params"
		missingButton.Visible = activeTab == "Map"
		pauseButton.Visible = activeTab ~= "Backpack" and activeTab ~= "Plot" and not queuePaused
		pausedButton.Visible = activeTab ~= "Backpack" and activeTab ~= "Plot" and queuePaused
		sort.Title.Visible = activeTab ~= "Backpack" and activeTab ~= "Plot"
		collectionSpacer.Visible = activeTab ~= "Backpack" and activeTab ~= "Plot"
		for uid, card in pairs(cards) do
			local checked = selectedEggs[uid] == true
			card.holder.SelectedOverlay.Visible = checked
			card.holder.SelectedIcon.Visible = checked
			card.button.Active = activeTab ~= "Plot" and not inventoryPlacementBusy and not (activeTab == "Backpack" and inventoryRecords[uid] and inventoryRecords[uid].InventoryPlaced)
		end
	end
	refreshEggInterface = function()
		if destroyed or not ready then updateSelection(); return end
		local available = {}
		if activeTab == "Backpack" or activeTab == "Plot" then
			inventoryRecords = inventoryEggRecords()
			local backpackCount, plotCount = 0, 0
			for _, record in pairs(inventoryRecords) do
				local placed = record.InventoryPlaced == true or record.Placement ~= nil
				if placed then plotCount += 1 else backpackCount += 1 end
				if (activeTab == "Plot") == placed then table.insert(available, record) end
			end
			eggsTab.Title.Text = "Backpack (" .. backpackCount .. ")"
			plotTab.Title.Text = "Plot (" .. plotCount .. ")"
		elseif activeTab == "Queue" then
			for _, entry in ipairs(queueOrder()) do
				local record = entry.Record or records[entry.Uid]
				if isEggInCurrentWorld(record) then table.insert(available, record) end
			end
		else

			local seenMap={}
			for uid, record in pairs(detectedMode=="Halloween" and halloweenRecords or records) do
				if (isTrackedFieldState(record) or record.IsHalloweenObservation) and not ownsEgg(uid) then
					table.insert(available,record)
					seenMap[uid]=true
				end
			end
			if detectedMode=="Normal" then
				for uid in pairs(trackedEggs) do
					if not seenMap[uid] then
						local observed=readField(uid)
						if isTrackedFieldState(observed) and not ownsEgg(uid) then table.insert(available,observed) end
					end
				end
			end
		end
		table.sort(available, function(a, b)
			local ar, br = getRatePerSecond(a) or 0, getRatePerSecond(b) or 0
			if ar ~= br then return ar > br end
			return tostring(a.Uid) < tostring(b.Uid)
		end)
		local seen = {}
		for index, record in ipairs(available) do
			local uid = record.Uid
			seen[uid] = true
			local card = cards[uid]
			if not card then
				local holder = template:Clone()
				holder.Name = uid
				holder.Visible = true
				holder:SetAttribute("EggUid", uid)
				local visual = holder:WaitForChild("Template")
				local click = Instance.new("TextButton")
				click.Name = "SelectEgg"
				click.BackgroundTransparency = 1
				click.Text = ""
				click.Size = UDim2.fromScale(1, 1)
				click.ZIndex = 200
				click.Parent = holder
				card = {holder = holder, visual = visual, button = click}
				cards[uid] = card
				card.connection = click.Activated:Connect(function()
					if activeTab == "Plot" or inventoryPlacementBusy or (activeTab == "Backpack" and inventoryRecords[uid] and inventoryRecords[uid].InventoryPlaced) then return end
					selectedEggs[uid] = not selectedEggs[uid] or nil
					updateSelection()
				end)
				holder.Parent = scroll
			end
			card.holder.LayoutOrder = index
			paintEggCard(card.visual, record)
			if isHeldByOther(record) then
				card.visual.Weight.Text = "Suivi : "..(record.CarrierUserId and tostring(record.CarrierUserId) or "transport")
			elseif record.ObservationOnly then
				card.visual.Weight.Text = "Oeuf retrouve - serveur a confirmer"
			elseif record.InventoryPlaced then
				card.visual.Weight.Text = "Place"
				if activeTab == "Backpack" then inventorySelection[uid] = nil end
			end
		end
		for uid, card in pairs(cards) do
			if not seen[uid] then
				card.connection:Disconnect()
				card.holder:Destroy()
				cards[uid] = nil
				if not currentCycle or currentCycle.uid ~= uid then selectedEggs[uid] = nil end
			end
		end
		for uid in pairs(selectedEggs) do
			if not seen[uid] and (not currentCycle or currentCycle.uid ~= uid) then selectedEggs[uid] = nil end
		end
		updateSelection()
	end
	renderControls = updateSelection
	connect(autoButton.Activated, function()
		local value = readThreshold()
		if not value then return end
		minimumRatePerSecond = value * 1e9
		automaticMode = not automaticMode
		if automaticMode then
			stopAfterFlight = false
			queuePaused = false
			safeHome = getStartAreaDestination()
			setStatus("AUTO ON : MoveTo vers StartArea ou MoveTo vers le tapis selon la file.")
		else
			searchingServer, searchWaitForEgg = false, false
			requestUserStop("AUTO OFF")
		end
		syncQueue()
		wakeQueue()
		updateSelection()
	end)
	connect(missingButton.Activated, function()
		if activeTab ~= "Map" or not ready then return end
		local ok, profile = pcall(Save.Peek)
		if not ok or type(profile) ~= "table" or type(profile.Index) ~= "table" then
			setStatus("Index indisponible : attends le chargement du profil.", Color3.fromRGB(255,130,110))
			return
		end
		refreshEggInterface()
		table.clear(mapSelection)
		local backpackCategories = backpackEggCategories(profile)
		local plotCategories = plotAnimalCategories()
		local count = 0
		local bestByCategory = {}
		for uid in pairs(cards) do
			local record = records[uid]
			if record and type(record.AssetCategory) == "string"
				and Assets.Directory[record.AssetCategory]
				and profile.Index[record.AssetCategory] ~= true
				and not backpackCategories[record.AssetCategory]
				and not plotCategories[record.AssetCategory] then
				local previous = bestByCategory[record.AssetCategory]
				local rate = getRatePerSecond(record) or 0
				if not previous or rate > previous.Rate or (rate == previous.Rate and uid < previous.Uid) then
					bestByCategory[record.AssetCategory] = {Uid=uid,Rate=rate}
				end
			end
		end
		for _, best in pairs(bestByCategory) do mapSelection[best.Uid] = true; count += 1 end
		updateSelection()
		setStatus(tostring(count) .. " oeuf(s) d'animaux manquants selectionne(s). Clique Add.")
	end)
	connect(toggleButton.Activated, function()
		if activeTab == "Params" or activeTab == "Plot" then return end
		refreshEggInterface()
		if activeTab == "Backpack" then
			if inventoryPlacementBusy or placementRequest then setStatus("Placement deja en cours"); return end
			if countSelected()==0 then setStatus("Coche les oeufs a placer."); return end
			if autoEnabled then
				wallMaintenancePending=true
				setStatus("AUTO : ouverture puis placement de tous les oeufs au prochain passage en zone sure.")
			else
				task.spawn(function() placeInventoryEggs(inventorySelection,nil,0) end)
			end
			return
		end
		if activeTab == "Queue" then
			local removed = 0
			for uid in pairs(queueSelection) do
				if queuedEggs[uid] then
					queuedEggs[uid],trackedEggs[uid] = nil,nil
					removedFromAuto[uid] = true
					removed += 1
				end
			end
			table.clear(queueSelection)
			setStatus(tostring(removed) .. " oeuf(s) retire(s). Le trajet deja en cours se termine.")
			refreshQueueInterface()
			updateSelection()
			return
		end
		if countSelected() == 0 then setStatus("Coche au moins un oeuf puis Add."); return end
		local added = 0
		for uid in pairs(selectedEggs) do
			if enqueueEgg(records[uid] or halloweenRecords[uid], "MANUEL") then added += 1 end
		end
		table.clear(selectedEggs)
		queuePaused = false
		setStatus(tostring(added) .. " oeuf(s) ajoute(s). Halloween : observation uniquement.")
		syncQueue()
		wakeQueue()
		updateSelection()
	end)
	connect(gui.Destroying, function()
		for _, card in pairs(cards) do card.connection:Disconnect() end
		template:Destroy()
	end)
	local elapsed = 0
	connect(RunService.Heartbeat, function(dt)
		elapsed += dt
		if elapsed >= 0.75 then
			elapsed = 0
			if ready and not destroyed then
				syncQueue()
				wakeQueue()
				if refreshBestEggCard then refreshBestEggCard() end
				if frame.Visible then refreshEggInterface() end
			end
		end
	end)
	sort.SelectAll:Destroy()
	sort.Clear:Destroy()
	show(true)
	log("UI_READY", "Interface autonome creee avec carte meilleur oeuf deplacable.")
	return gui
end

-- Repeat return jumps after landing, without overriding the game's speed.
connect(RunService.Heartbeat, function()
	if destroyed or not ready then return end
	local ctx = currentCycle
	if not ctx or not validCycle(ctx) or ctx.phase ~= "RETURN" or ctx.braking then return end
	local _, humanoid, root = getCharacterParts()
	if not humanoid or not root or humanoid.Health <= 0 or motionBlockReason(ctx) then return end
	if not ctx.returnDestination or not ctx.returnStartDistance then return end
	if isSafe(root.Position) == true then humanoid.Jump = false; return end
	if distanceXZ(root.Position, ctx.returnDestination) > ctx.returnStartDistance * 0.5 then return end
	if humanoid.FloorMaterial == Enum.Material.Air then return end
	if not humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping) then return end
	local now = os.clock()
	if now - (ctx.lastReturnJump or -math.huge) < 0.2 then return end
	ctx.lastReturnJump = now
	humanoid.Jump = true
	humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
end)

-- Explicit, bounded black-box probes; never start automatically.


local correctionSample
local lastCorrectionNotice = -math.huge
connect(RunService.Heartbeat, function()
	if destroyed or not ready or not autoEnabled then correctionSample = nil; return end
	local character, humanoid, root = getCharacterParts()
	if not root or not humanoid then correctionSample = nil; return end
	local now = os.clock()
	if correctionSample and correctionSample.Character == character then
		local delta = now-correctionSample.Time
		local distance = distanceXZ(root.Position, correctionSample.Position)
		local allowance = math.max(40, math.max(humanoid.WalkSpeed, correctionSample.WalkSpeed)*delta*2.5+15)
		if delta > 0 and delta < 0.5 and distance > allowance and now-lastCorrectionNotice > 1 then
			lastCorrectionNotice = now
			movementResumePending = true
			movementRevision += 1
			syncPauseUntil = math.max(syncPauseUntil, now+0.5)
			if currentCycle then
				currentCycle.syncCorrectionCount = (currentCycle.syncCorrectionCount or 0)+1
				if currentCycle.syncCorrectionCount > 5 then
					log("SYNC_DIAG", "Corrections repetees : collecte suspendue apres 5 reprises")
					stopAutomation("Corrections de position repetees : voir le log")
				end
			end
			stopMovement() -- Cancel walking without cancelling the incoming physical correction.
			log("SYNC_DIAG", "Source=%s Revision=%d SautObserve=%.1f Seuil=%.1f Phase=%s DernierFreinMs=%.0f | cause non deduite de la seule position",
				now-lastRelocateAt < 1 and "Relocate_recent" or "deplacement_discontinu_origine_inconnue",
				movementRevision, distance, allowance, currentCycle and currentCycle.phase or autoActivity, (now-lastPhysicalBrakeAt)*1000)
		end
	end
	correctionSample = {Character=character, Time=now, Position=root.Position, WalkSpeed=humanoid.WalkSpeed}
end)

local historyOK, previousLog = executorTools.ReadLog()
if historyOK and type(previousLog) == "string" then
	for line in previousLog:gmatch("[^\r\n]+") do
		if line:find("[FLIGHT_RESULT]", 1, true) then
			local name, result = line:match('Vol de "(.-)" (.+)$')
			if name and (result == "Reussi" or result == "Echoue") then
				table.insert(flightHistory, {Text='Vol de "'..name..'" '..result, Success=result=="Reussi"})
				if #flightHistory > 200 then table.remove(flightHistory,1) end
			end
		end
	end
end
log("SESSION", "Nouveau lancement %s", os.date("%Y-%m-%d %H:%M:%S"))
loadSettings()
local gui = createInterface()
setStatus("Chargement des modules du jeu...")
connect(player.CharacterRemoving, function()
	stopAutomation("Personnage retire : redemarre depuis la zone sure")
end)
local function destroy()
	if destroyed then return end
	stopAutomation("Script ferme")
	executorTools.SaveSettings()
	executorTools.SaveLog()
	destroyed = true
	for _, connection in ipairs(lifetimeConnections) do connection:Disconnect() end
	table.clear(lifetimeConnections)
	if shared.__AutoSAEController and shared.__AutoSAEController.Gui == gui then
		shared.__AutoSAEController = nil
	end
	if gui.Parent then gui:Destroy() end
end

local previous = shared.__AutoSAEController
if previous and type(previous.Destroy) == "function" then
	pcall(previous.Destroy)
end
shared.__AutoSAEController = {Destroy = destroy, Gui = gui}
connect(gui.Destroying, destroy)
connect(script.Destroying, destroy)
task.spawn(function()
	while not destroyed do
		task.wait(2)
		if destroyed then break end
		if executorFunction("writefile") then
			local settingsOK, settingsError = executorTools.SaveSettings()
			if not settingsOK then warn("[Auto_SAE] Ecriture parametres : " .. tostring(settingsError)) end
			if sequence ~= lastSavedLogSequence then
				local sequenceToSave = sequence
				local logOK, logError = executorTools.SaveLog()
				if logOK then lastSavedLogSequence = sequenceToSave
				else warn("[Auto_SAE] Ecriture logs : " .. tostring(logError)) end
			end
		end
	end
end)
task.spawn(function()
	local ok, failure = xpcall(initialize, debug.traceback)
	if not ok and not destroyed then
		ready = false
		setStatus("Modules indisponibles : voir la console", Color3.fromRGB(255, 130, 110))
		log("ERROR", "%s", tostring(failure))
	end
end)

