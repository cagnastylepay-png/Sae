-- Auto_SAE v2.8. SellPrompt selection UI. Verified client contracts; no character/anticheat replacement.
-- The live game must provide ReplicatedStorage.Client/Data/Shared.
-- Refresh outbound MoveTo before its native timeout; verify distance before carry.
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer
assert(player, "Auto_SAE doit etre execute sur le client")

local CONFIG = {
	Debug = true,
	ProgressInterval = 0.5,
	MoveRefresh = 0.1,
	ApproachRefresh = 4,
	ApproachDistance = 8,
	ScanInterval = 0.25,
	ReturnDistance = 3,
	RequestTimeout = 10,
	MaxCarryAttempts = 3,
	CarryRetryDelay = 0.35,
	EnableArrivalBrake = true,
	ArrivalBrakeDuration = 0.1,
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
local ready, destroyed, autoEnabled = false, false, false
local generation = 0
local minimumRatePerSecond = DEFAULT_BILLIONS * 1e9
local records, loggedVersions, cooldowns = {}, {}, {}
local lifetimeConnections = {}
local currentCycle, safeHome
local safeSpeedHumanoid, safeWalkSpeed
local inFlightRequest = shared.__AutoSAERemoteLock
local statusLabel, toggleButton, minimumInput
local sequence = 0
local renderControls
local refreshEggInterface
local selectedEggs = {}
local automaticMode = false
local queuedEggs = {}
local removedFromAuto = {}
local queuePaused = false
local syncQueue, wakeQueue, refreshQueueInterface, startAutomation
local stopAutomation
local rigPause = {Character = nil, Until = 0, Reason = nil}

local function log(stage, message, ...)
	if not CONFIG.Debug and stage ~= "ERROR" and stage ~= "CLAIM_CONFIRMED" then
		return
	end
	sequence += 1
	local ok, text = pcall(string.format, message, ...)
	if not ok then
		text = message .. " | format=" .. tostring(text)
	end
	print(string.format("[Auto_SAE][%04d][%.3f][%s][%s] %s",
		sequence, os.clock(), stage, currentCycle and currentCycle.uid or "-", text))
end

local function setStatus(text, color)
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

local function getCharacterParts()
	local character = player.Character
	if not character then return nil, nil, nil end
	return character, character:FindFirstChildOfClass("Humanoid"), character:FindFirstChild("HumanoidRootPart")
end

local function distanceXZ(first, second)
	local delta = first - second
	return Vector2.new(delta.X, delta.Z).Magnitude
end

local function stopMovement()
	local _, humanoid, root = getCharacterParts()
	if humanoid and root then
		humanoid:Move(Vector3.zero)
		humanoid:MoveTo(root.Position)
	end
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

local function readField(uid)
	local ok, record = pcall(EggState.ReadFieldEgg, uid)
	if ok then return record, true end
	log("FIELD_READ_ERROR", "%s", tostring(record))
	return nil, false
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
	if destroyed or not autoEnabled or generation ~= ctx.generation or currentCycle ~= ctx then
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
	repeat
		local valid, reason = validCycle(ctx)
		if not valid then return false, reason end
		local blocked = motionBlockReason(ctx)
		if blocked then return false, "freinage interrompu : " .. blocked end
		local distance = flat and distanceXZ(root.Position, destination) or (root.Position - destination).Magnitude
		if distance > radius then return false, "derive apres arrivee" end
		local velocity = root.AssemblyLinearVelocity
		-- Preserve vertical physics; do not change WalkSpeed, CFrame, or humanoid state.
		root.AssemblyLinearVelocity = Vector3.new(0, velocity.Y, 0)
		if os.clock() - started >= CONFIG.ArrivalBrakeDuration then break end
		RunService.Heartbeat:Wait()
	until false
	log("ARRIVAL_BRAKE", "Phase=%s HorizontalAvant=%.2f HorizontalApres=%.2f Duree=%.3fs",
		ctx.phase, Vector2.new(before.X, before.Z).Magnitude,
		Vector2.new(root.AssemblyLinearVelocity.X, root.AssemblyLinearVelocity.Z).Magnitude, os.clock() - started)
	return true
end

local function setPhase(ctx, phase, message)
	if ctx.phase ~= phase then
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

local function getRatePerSecond(record)
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

local function requestCarry(ctx)
	if inFlightRequest and not inFlightRequest.done then return end
	if ctx.attempts >= CONFIG.MaxCarryAttempts then return end
	local request = {uid = ctx.uid, started = os.clock(), done = false, retryable = false}
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
		local ok, accepted, reason = pcall(EggState.CarryFieldEgg, ctx.uid, slotKey)
		request.done = true
		request.callOK, request.retryable = ok, ok and accepted ~= true
		request.accepted = ok and accepted == true
		request.reason = ok and reason or tostring(accepted)
		-- A timed-out InvokeServer may finish later. It never controls a newer cycle.
		log("CARRY_REPLY", "UID=%s CallOK=%s Accepted=%s Reason=%s Latence=%.3fs SessionActive=%s",
			ctx.uid, tostring(ok), tostring(request.accepted), tostring(request.reason),
			os.clock() - request.started, tostring(validCycle(ctx)))
		if not validCycle(ctx) then return end
		ctx.remoteAccepted = request.accepted
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
			end
			local latest, readOK = readField(ctx.uid)
			local eggPosition = getRecordPosition(latest)
			if not readOK or not eggPosition then
				complete(false, "position actuelle de l'oeuf indisponible")
				return
			end
			if latest.State ~= SLOT_STATE and latest.State ~= "Dropped" then
				complete(false, "oeuf non disponible pendant l'approche")
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
			if (root.Position - eggPosition).Magnitude <= CONFIG.ApproachDistance then
				traceMoveEnd(ctx, root, destination, true)
				complete(true, "distance verifiee")
				return
			end
			if now - lastMoved > CONFIG.NoMovementTimeout then
				complete(false, "course bloquee sans progression")
				return
			end
			if targetMoved or retryRequested or now - lastCommand >= CONFIG.ApproachRefresh then
				local firstCommand = lastCommand == -math.huge
				lastCommand, retryRequested = now, false
				log(firstCommand and "MOVE_COMMAND" or "MOVE_RENEW", "Destination=%s DistanceXZ=%.2f Temps=%.2fs | sans arret ni changement de vitesse",
					formatPosition(destination), distance, now - started)
				humanoid:MoveTo(destination)
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
	local braked, brakeReason = brakeAtArrival(ctx, ctx.eggPosition, CONFIG.ApproachDistance, false)
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
		local arrived, approachReason = approachEgg(ctx, destination)
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
	setPhase(ctx, "RETURN", "Retour vers la zone sure")
	while true do
		local valid, reason = validCycle(ctx)
		if not valid then return false, reason end
		if carryWasLost(ctx) then
			stopMovement()
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
		if distanceXZ(lastPosition, root.Position) >= 0.5 then
			lastMoved, lastPosition = now, root.Position
		end
		if distance <= CONFIG.ReturnDistance then
			local braked, brakeReason = brakeAtArrival(ctx, destination, CONFIG.ReturnDistance, true)
			if carryWasLost(ctx) then return false, CARRY_LOST end
			if braked then return true end
			if not validCycle(ctx) then return false, brakeReason end
			lastCommand, lastMoved = -math.huge, os.clock()
			continue
		end
		if now - started > timeout then return false, "delai de retour depasse" end
		if now - lastMoved > CONFIG.NoMovementTimeout then return false, "retour bloque" end
		if now - lastCommand >= CONFIG.MoveRefresh then
			humanoid:MoveTo(destination)
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
	if ctx.cancelPendingWait then ctx.cancelPendingWait() end
	stopMovement()
	if shared.__AutoSAEMovementLock == ctx.movementLock then shared.__AutoSAEMovementLock = nil end
	currentCycle = nil
end

local function runCycle(record, rate, recovering)
	local character, humanoid, root = getCharacterParts()
	if not character or not humanoid or not root then return false, "personnage absent" end
	local startIsSafe = isSafe(root.Position)
	if startIsSafe then
		safeHome = root.Position
		local carry = readCarry()
		if not (carry and carry.IsCarrying) and humanoid.WalkSpeed > 0 then
			safeSpeedHumanoid, safeWalkSpeed = humanoid, humanoid.WalkSpeed
		end
	end
	if not safeHome or isSafe(safeHome) ~= true then
		return false, "position de retour sure non disponible"
	end
	local ctx = {
		uid = record.Uid, record = record, generation = generation, character = character,
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
			grabbed, grabReason = moveThenCarry(ctx, destination)
		end
		if not validCycle(ctx) then return false, "annule" end
		if not grabbed and inFlightRequest and not inFlightRequest.done then
			return false, grabReason or "requete serveur encore en cours"
		end
		ctx.hadCarry = grabbed == true
		while validCycle(ctx) do
			local returned, returnReason = moveReturnLoop(ctx, ctx.home)
			if not returned and returnReason ~= CARRY_LOST then return false, returnReason end
			if returned then
				local _, _, currentRoot = getCharacterParts()
				if not currentRoot or isSafe(currentRoot.Position) ~= true then
					return false, "retour termine mais ligne safe non franchie"
				end
				if not grabbed then return false, grabReason end
				local claimed, claimReason = waitForClaim(ctx)
				if claimed then return true end
				if claimReason ~= CARRY_LOST then return false, claimReason end
			end
			local recovered, recoveryReason = recoverSameEgg(ctx)
			if not recovered then return false, recoveryReason end
			grabbed = true
		end
		return false, "annule"
	end, debug.traceback)
	cleanupCycle(ctx)
	if not cycleOK then return false, tostring(completed) end
	return completed, failure
end

local function ingest(record)
	if type(record) ~= "table" or type(record.Uid) ~= "string" then return end
	records[record.Uid] = record
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

local function enqueueEgg(record, source)
	if type(record) ~= "table" or type(record.Uid) ~= "string" then return false end
	if source == "AUTO" and removedFromAuto[record.Uid] then return false end
	if source == "MANUEL" then removedFromAuto[record.Uid] = nil end
	if queuedEggs[record.Uid] then return false end
	if record.State ~= SLOT_STATE and record.State ~= "Dropped" then return false end
	if record.CarrierUserId ~= nil or ownsEgg(record.Uid) then return false end
	queuedEggs[record.Uid] = {Record = record, Rate = getRatePerSecond(record) or 0, Source = source}
	return true
end

syncQueue = function()
	if not ready or destroyed then return end
	for uid, entry in pairs(queuedEggs) do
		if not currentCycle or currentCycle.uid ~= uid then
			local record = records[uid]
			local carriedByMe = record and record.State == "Carried" and record.CarrierUserId == player.UserId
			if not record or ownsEgg(uid)
				or (not carriedByMe and record.State ~= SLOT_STATE and record.State ~= "Dropped")
				or (record.CarrierUserId ~= nil and not carriedByMe) then
				queuedEggs[uid] = nil
			else
				entry.Record = record
			end
		end
	end
	if automaticMode then
		for uid, record in pairs(records) do
			local rate = getRatePerSecond(record)
			if rate and rate >= minimumRatePerSecond and (cooldowns[uid] or 0) <= os.clock() then
				enqueueEgg(record, "AUTO")
			end
		end
	end
	if refreshQueueInterface then refreshQueueInterface() end
end

local function selectBest()
	local best, bestRate = nil, -math.huge
	local _, _, root = getCharacterParts()
	for uid, entry in pairs(queuedEggs) do
		local cached = records[uid] or entry.Record
		if queuedEggs[uid] and (cached.State == SLOT_STATE or cached.State == "Dropped") and (cooldowns[uid] or 0) <= os.clock() then
			local latest, ok = readField(uid)
			if ok and latest and (latest.State == SLOT_STATE or latest.State == "Dropped") and latest.CarrierUserId == nil and not ownsEgg(uid) then
				records[uid] = latest
				local rate = getRatePerSecond(latest)
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
	stopMovement()
	setStatus(reason or "Arrete", Color3.fromRGB(255, 150, 120))
	if renderControls then renderControls() end
	log("STOP", "%s | RemoteEnCours=%s", reason or "utilisateur", tostring(inFlightRequest and not inFlightRequest.done))
end

local function worker(token)
	while autoEnabled and generation == token and not destroyed do
		if inFlightRequest and not inFlightRequest.done then
			stopAutomation("Requete serveur en cours : attendre sa reponse")
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
			local success, reason = runCycle(selected, rate, recovering)
			if not autoEnabled or generation ~= token then return end
			if success then
				selectedEggs[selected.Uid] = nil
				queuedEggs[selected.Uid] = nil
				if refreshQueueInterface then refreshQueueInterface() end
				if renderControls then renderControls() end
			end
			if not success then
				log("CYCLE_FAILED", "UID=%s Raison=%s", selected.Uid, tostring(reason))
				cooldowns[selected.Uid] = os.clock() + CONFIG.FailedTargetCooldown
				queuedEggs[selected.Uid] = nil
				-- Never continue after ambiguous ownership or an unresolved request.
				if recovering or (inFlightRequest and not inFlightRequest.done) then
					stopAutomation(tostring(reason))
					return
				end
				local after = readCarry()
				local _, _, root = getCharacterParts()
				if not after or after.IsCarrying or not root or isSafe(root.Position) ~= true
					or string.find(tostring(reason), "attribution", 1, true)
					or string.find(tostring(reason), "recuperation", 1, true) then
					stopAutomation(tostring(reason))
					return
				end
			end
		else
			stopAutomation(automaticMode and "AUTO : attente du prochain oeuf au seuil" or "File terminee", false)
			return
		end
		task.wait(CONFIG.ScanInterval)
	end
end

startAutomation = function(billions)
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
	if isSafe(root.Position) == true then safeHome = root.Position end
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
	if destroyed or not ready or autoEnabled or queuePaused or next(queuedEggs) == nil then return end
	if inFlightRequest and not inFlightRequest.done then return end
	startAutomation(minimumRatePerSecond / 1e9)
end

local function loadModule(path)
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
	return require(node)
end

local function initialize()
	EggState = loadModule("Client.EggState")
	Assets = loadModule("Data.Assets")
	EggRecords = loadModule("Shared.Util.EggRecords")
	AssetEarnings = loadModule("Shared.Util.AssetEarnings")
	SlotIdentity = loadModule("Shared.Util.AreaEggSlotIdentity")
	GuardGeometry = loadModule("Shared.Util.GuardAreaGeometry")
	Save = loadModule("Shared.Save")
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
	ready = true
	setStatus("Pret : coche tes oeufs puis Add, ou active AUTO.", Color3.fromRGB(96, 230, 145))
	if refreshEggInterface then refreshEggInterface() end
	log("READY", "Build=2.4 | MoveTo renouvele / freinage horizontal / distance 3D <= 8 / %d essais en serie / retour / inventaire / reprise meme UID", CONFIG.MaxCarryAttempts)
end

local function createInterface()
	local playerGui = player:WaitForChild("PlayerGui")
	local previous = shared.__AutoSAEController
	if previous and type(previous.Destroy) == "function" then pcall(previous.Destroy) end
	local old = playerGui:FindFirstChild("AutoSAEGui")
	if old then old:Destroy() end
	local source = game:GetService("StarterGui"):FindFirstChild("SellPrompt") or playerGui:FindFirstChild("SellPrompt")
	assert(source and source:IsA("ScreenGui"), "SellPrompt est introuvable")
	local gui = source:Clone()
	gui.Name = "AutoSAEGui"
	gui.ResetOnSpawn = false
	gui.Enabled = true
	gui.DisplayOrder = math.max(source.DisplayOrder + 10, 100)
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
	mapTab.LayoutOrder, queueTab.LayoutOrder, paramsTab.LayoutOrder = 1, 2, 3
	for _, tabButton in ipairs({mapTab, queueTab, paramsTab}) do
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
	minimumInput.Text = tostring(DEFAULT_BILLIONS)
	minimumInput.Parent = sort
	local thresholdCorner = Instance.new("UICorner", minimumInput)
	thresholdCorner.CornerRadius = UDim.new(0, 8)
	local function readThreshold()
		local value = tonumber((minimumInput.Text:gsub(",", ".")))
		if not value or value ~= value or math.abs(value) == math.huge then
			setStatus("Seuil invalide : entre 0.1 et 999 B/s", Color3.fromRGB(255, 130, 110))
			return nil
		end
		value = math.clamp(value, MINIMUM_BILLIONS, MAXIMUM_BILLIONS)
		minimumInput.Text = tostring(value)
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


	local paramsPanel = Instance.new("Frame")
	paramsPanel.Name = "Params"
	paramsPanel.BackgroundTransparency = 1
	paramsPanel.Position = scroll.Position
	paramsPanel.Size = scroll.Size
	paramsPanel.Visible = false
	paramsPanel.Parent = frame
	local paramsLayout = Instance.new("UIListLayout", paramsPanel)
	paramsLayout.Padding = UDim.new(0, 16)
	paramsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	autoButton.Parent = paramsPanel
	thresholdTitle.Parent = paramsPanel
	minimumInput.Parent = paramsPanel
	autoButton.Size = UDim2.fromScale(0.65, 0.16)
	thresholdTitle.Size = UDim2.fromScale(0.65, 0.10)
	minimumInput.Size = UDim2.fromScale(0.65, 0.14)
	refreshQueueInterface = function()
		local entries = queueOrder()
		queueTab.Title.Text = "Queue (" .. #entries .. ")"
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
			stopAutomation("File en pause")
		end
		if renderControls then renderControls() end
		refreshQueueInterface()
	end
	connect(pauseButton.Activated, toggleQueue)
	connect(pausedButton.Activated, toggleQueue)

	local function switchTab(name)
		activeTab = name
		selectedEggs = name == "Queue" and queueSelection or mapSelection
		scroll.Visible = name ~= "Params"
		paramsPanel.Visible = name == "Params"
		sort.Visible = name ~= "Params"
		paramsTab.Title.TextColor3 = name == "Params" and Color3.new(1,1,1) or Color3.fromRGB(170,180,200)
		mapTab.Title.TextColor3 = name == "Map" and Color3.new(1, 1, 1) or Color3.fromRGB(170, 180, 200)
		queueTab.Title.TextColor3 = name == "Queue" and Color3.new(1, 1, 1) or Color3.fromRGB(170, 180, 200)
		if name == "Queue" and refreshQueueInterface then refreshQueueInterface() end
		if name == "Map" and refreshEggInterface then refreshEggInterface() end
		if renderControls then renderControls() end
	end
	connect(mapTab.Activated, function() switchTab("Map") end)
	connect(queueTab.Activated, function() switchTab("Queue") end)
	connect(paramsTab.Activated, function() switchTab("Params") end)
	switchTab("Map")
	local cards = {}
	local function countSelected()
		local n = 0
		for _ in pairs(selectedEggs) do n += 1 end
		return n
	end
	local function updateSelection()
		local count = countSelected()
		info.Value.Text = activeTab == "Params" and ("AUTO >= " .. formatNumber(minimumRatePerSecond) .. "/s") or (tostring(count) .. (count == 1 and " oeuf" or " oeufs"))
		setAutoCaption(automaticMode and "AUTO : ON" or "AUTO : OFF")
		minimumInput.TextEditable = true
		thresholdTitle.Visible = true
		minimumInput.Visible = true
		sort.Clear.Active = true
		sort.SelectAll.Active = true
		toggleButton.Title.Text = activeTab == "Queue" and "Remove" or "Add"
		toggleButton.Visible = activeTab ~= "Params"
		sort.SelectAll.Visible = activeTab ~= "Params"
		sort.Clear.Visible = activeTab ~= "Params"
		missingButton.Visible = activeTab == "Map"
		pauseButton.Visible = not queuePaused
		pausedButton.Visible = queuePaused
		for uid, card in pairs(cards) do
			local checked = selectedEggs[uid] == true
			card.holder.SelectedOverlay.Visible = checked
			card.holder.SelectedIcon.Visible = checked
			card.button.Active = true
		end
	end
	refreshEggInterface = function()
		if destroyed or not ready then updateSelection(); return end
		local available = {}
		if activeTab == "Queue" then
			for _, entry in ipairs(queueOrder()) do table.insert(available, records[entry.Uid] or entry.Record) end
		else
		for uid, record in pairs(records) do
			if (record.State == SLOT_STATE or record.State == "Dropped")
				and record.CarrierUserId == nil and not ownsEgg(uid) then
				table.insert(available, record)
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
					selectedEggs[uid] = not selectedEggs[uid] or nil
					updateSelection()
				end)
				holder.Parent = scroll
			end
			card.holder.LayoutOrder = index
			local config = getAssetConfig(record)
			local icon = config and config.Egg and config.Egg.Icon
			card.visual.Icon.Image = icon or "rbxassetid://103094823152347"
			local rate = getRatePerSecond(record)
			card.visual.Amount.Text = rate and (formatNumber(rate) .. "/s") or "?"
			local weight = getWeightKg(record)
			card.visual.Weight.Text = weight and string.format("%.1f kg", weight) or ""
			local valueHolder = card.visual:FindFirstChild("ValueHolder")
			if valueHolder then
				valueHolder.Value.Text = getAnimalName(record)
				valueHolder.Value.Size = UDim2.fromScale(0.95, 0.9)
				valueHolder.Value.Position = UDim2.fromScale(0.5, 0.5)
				valueHolder.Value.AnchorPoint = Vector2.new(0.5, 0.5)
				valueHolder.Value.TextScaled = true
				if valueHolder:FindFirstChild("Icon") then valueHolder.Icon.Visible = false end
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
		if automaticMode then queuePaused = false end
		setStatus(automaticMode and "AUTO : ajout des oeufs au seuil dans la file." or "AUTO OFF : la file existante est conservee.")
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
		local count = 0
		for uid in pairs(cards) do
			local record = records[uid]
			if record and type(record.AssetCategory) == "string"
				and Assets.Directory[record.AssetCategory]
				and profile.Index[record.AssetCategory] ~= true then
				mapSelection[uid] = true
				count += 1
			end
		end
		updateSelection()
		setStatus(tostring(count) .. " oeuf(s) d'animaux manquants selectionne(s). Clique Add.")
	end)
	connect(sort.Clear.Activated, function()
		table.clear(selectedEggs)
		updateSelection()
	end)
	connect(sort.SelectAll.Activated, function()
		for uid in pairs(cards) do selectedEggs[uid] = true end
		updateSelection()
	end)
	connect(toggleButton.Activated, function()
		if activeTab == "Params" then return end
		refreshEggInterface()
		if activeTab == "Queue" then
			local removed = 0
			for uid in pairs(queueSelection) do
				if queuedEggs[uid] then
					queuedEggs[uid] = nil
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
			if enqueueEgg(records[uid], "MANUEL") then added += 1 end
		end
		table.clear(selectedEggs)
		queuePaused = false
		setStatus(tostring(added) .. " oeuf(s) ajoute(s) a la file.")
		syncQueue()
		wakeQueue()
		updateSelection()
	end)
	connect(gui.Destroying, function()
		for _, card in pairs(cards) do card.connection:Disconnect() end
		template:Destroy()
	end)
	task.spawn(function()
		local hud = playerGui:WaitForChild("HUD", 30)
		local gameHud = hud and hud:WaitForChild("GameHUD", 30)
		local buttons = gameHud and gameHud:WaitForChild("RightButtons", 30)
		if not buttons or destroyed then return end
		local existing = buttons:FindFirstChild("AutoStealButton")
		if existing then existing:Destroy() end
		local button = buttons:WaitForChild("EggsButton", 10)
		if not button or destroyed then return end
		button = button:Clone()
		button.Name = "AutoStealButton"
		button.LayoutOrder = 15
		button.Visible = true
		for _, name in ipairs({"Notification", "ReadyNotification", "NightImage", "NightText", "GamepadGlyph"}) do
			local object = button:FindFirstChild(name)
			if object then object:Destroy() end
		end
		local icon = button:FindFirstChild("ImageLabel")
		if icon then icon.Image = "rbxassetid://103094823152347" end
		local caption = Instance.new("TextLabel")
		caption.Name = "AutoEggsTitle"
		caption.BackgroundTransparency = 1
		caption.Position = UDim2.fromScale(0, 0.72)
		caption.Size = UDim2.fromScale(1, 0.28)
		caption.Text = "AUTO EGGS"
		caption.TextColor3 = Color3.new(1,1,1)
		caption.TextScaled = true
		caption.Font = Enum.Font.GothamBold
		caption.ZIndex = 200
		caption.Parent = button
		local stroke = Instance.new("UIStroke", caption)
		stroke.Thickness = 2
		button.Parent = buttons
		connect(button.Activated, function() show(not frame.Visible) end)
		connect(gui.Destroying, function() button:Destroy() end)
	end)
	local elapsed = 0
	connect(RunService.Heartbeat, function(dt)
		elapsed += dt
		if elapsed >= 0.75 then
			elapsed = 0
			if ready and not destroyed then
				syncQueue()
				wakeQueue()
				if frame.Visible then refreshEggInterface() end
			end
		end
	end)
	return gui
end

-- Cache the current character's unladen safe-zone speed; freeze it during each trip.
connect(RunService.Heartbeat, function()
	if destroyed or not ready then return end
	local character, humanoid, root = getCharacterParts()
	if not humanoid or not root or humanoid.Health <= 0 then return end
	if safeSpeedHumanoid ~= humanoid then
		safeSpeedHumanoid, safeWalkSpeed = nil, nil
	end
	local ctx = currentCycle
	if not ctx then
		local carry = readCarry()
		if isSafe(root.Position) == true and not (carry and carry.IsCarrying)
			and not motionBlockReason({character = character})
			and humanoid.WalkSpeed > 0 and humanoid.WalkSpeed < math.huge then
			safeSpeedHumanoid, safeWalkSpeed = humanoid, humanoid.WalkSpeed
		end
		return
	end
	if not validCycle(ctx) then return end
	if safeSpeedHumanoid == humanoid and safeWalkSpeed then
		if math.abs(humanoid.WalkSpeed - safeWalkSpeed) > 0.001 then
			humanoid.WalkSpeed = safeWalkSpeed
		end
	end
	-- Request another jump after landing; leave ragdoll/traps and airborne states alone.
	if ctx.phase == "RETURN" and not motionBlockReason(ctx)
		and humanoid.FloorMaterial ~= Enum.Material.Air
		and humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping) then
		humanoid.Jump = true
	end
end)

local gui = createInterface()
setStatus("Chargement des modules du jeu...")
connect(player.CharacterRemoving, function()
	stopAutomation("Personnage retire : redemarre depuis la zone sure")
end)
local function destroy()
	if destroyed then return end
	stopAutomation("Script ferme")
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
	local ok, failure = xpcall(initialize, debug.traceback)
	if not ok and not destroyed then
		ready = false
		setStatus("Modules indisponibles : voir la console", Color3.fromRGB(255, 130, 110))
		log("ERROR", "%s", tostring(failure))
	end
end)

