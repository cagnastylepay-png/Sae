-- Auto_SAE v2.4. Verified client contracts; no character/anticheat replacement.
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
local inFlightRequest = shared.__AutoSAERemoteLock
local statusLabel, toggleButton, minimumInput
local sequence = 0
local renderControls
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
	if startIsSafe then safeHome = root.Position end
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

local function selectBest()
	local best, bestRate = nil, -math.huge
	local _, _, root = getCharacterParts()
	for uid, cached in pairs(records) do
		if cached.State == SLOT_STATE and (cooldowns[uid] or 0) <= os.clock() then
			local latest, ok = readField(uid)
			if ok and latest and latest.State == SLOT_STATE and not ownsEgg(uid) then
				records[uid] = latest
				local rate = getRatePerSecond(latest)
				if rate and rate >= minimumRatePerSecond then
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

stopAutomation = function(reason)
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
		local selected, rate, recovering
		if carry.IsCarrying and carry.Uid then
			selected = readField(carry.Uid)
			selected = selected or {Uid = carry.Uid, AssetCategory = carry.AssetCategory}
			recovering = true
		else
			selected, rate = selectBest()
		end
		if selected then
			local success, reason = runCycle(selected, rate, recovering)
			if not autoEnabled or generation ~= token then return end
			if not success then
				log("CYCLE_FAILED", "UID=%s Raison=%s", selected.Uid, tostring(reason))
				cooldowns[selected.Uid] = os.clock() + CONFIG.FailedTargetCooldown
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
			setStatus("En attente : minimum " .. formatNumber(minimumRatePerSecond) .. " $/s",
				Color3.fromRGB(96, 230, 145))
		end
		task.wait(CONFIG.ScanInterval)
	end
end

local function startAutomation(billions)
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
		setStatus("Place-toi dans la zone sure puis START", Color3.fromRGB(255, 190, 100))
		return false
	end
	minimumRatePerSecond = math.clamp(billions, MINIMUM_BILLIONS, MAXIMUM_BILLIONS) * 1e9
	generation += 1
	local token = generation
	autoEnabled = true
	cooldowns = {}
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
	setStatus("Pret : demarre depuis la zone sure", Color3.fromRGB(96, 230, 145))
	log("READY", "Build=2.4 | MoveTo renouvele / freinage horizontal / distance 3D <= 8 / %d essais en serie / retour / inventaire / reprise meme UID", CONFIG.MaxCarryAttempts)
end

local function createInterface()
	local playerGui = player:WaitForChild("PlayerGui")
	local oldGui = playerGui:FindFirstChild("AutoSAEGui")

	if oldGui then
		oldGui:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "AutoSAEGui"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.AnchorPoint = Vector2.new(1, 0)
	frame.Position = UDim2.new(1, -24, 0, 120)
	frame.Size = UDim2.fromOffset(280, 178)
	frame.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
	frame.BorderSizePixel = 0
	frame.Active = true
	frame.Draggable = true
	frame.Parent = gui

	local frameCorner = Instance.new("UICorner")
	frameCorner.CornerRadius = UDim.new(0, 12)
	frameCorner.Parent = frame

	local frameStroke = Instance.new("UIStroke")
	frameStroke.Color = Color3.fromRGB(71, 119, 255)
	frameStroke.Thickness = 2
	frameStroke.Transparency = 0.2
	frameStroke.Parent = frame

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Position = UDim2.fromOffset(14, 10)
	title.Size = UDim2.new(1, -28, 0, 28)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.Text = "AUTO EGG"
	title.TextColor3 = Color3.fromRGB(245, 248, 255)
	title.TextSize = 20
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = frame

	local inputLabel = Instance.new("TextLabel")
	inputLabel.Name = "InputLabel"
	inputLabel.Position = UDim2.fromOffset(14, 43)
	inputLabel.Size = UDim2.new(1, -28, 0, 20)
	inputLabel.BackgroundTransparency = 1
	inputLabel.Font = Enum.Font.Gotham
	inputLabel.Text = "Minimum $/s en milliards (0.1 à 999)"
	inputLabel.TextColor3 = Color3.fromRGB(174, 183, 204)
	inputLabel.TextSize = 13
	inputLabel.TextXAlignment = Enum.TextXAlignment.Left
	inputLabel.Parent = frame

	local input = Instance.new("TextBox")
	input.Name = "MinimumBillions"
	input.Position = UDim2.fromOffset(14, 67)
	input.Size = UDim2.fromOffset(112, 38)
	input.BackgroundColor3 = Color3.fromRGB(35, 41, 57)
	input.BorderSizePixel = 0
	input.ClearTextOnFocus = false
	input.Font = Enum.Font.GothamBold
	input.PlaceholderText = "0.1 - 999"
	input.Text = tostring(DEFAULT_BILLIONS)
	input.TextColor3 = Color3.fromRGB(255, 255, 255)
	input.TextSize = 18
	input.Parent = frame
	minimumInput = input

	local inputCorner = Instance.new("UICorner")
	inputCorner.CornerRadius = UDim.new(0, 8)
	inputCorner.Parent = input

	local suffix = Instance.new("TextLabel")
	suffix.Name = "Suffix"
	suffix.Position = UDim2.fromOffset(132, 67)
	suffix.Size = UDim2.fromOffset(44, 38)
	suffix.BackgroundTransparency = 1
	suffix.Font = Enum.Font.GothamBold
	suffix.Text = "B/s"
	suffix.TextColor3 = Color3.fromRGB(174, 183, 204)
	suffix.TextSize = 17
	suffix.TextXAlignment = Enum.TextXAlignment.Left
	suffix.Parent = frame

	toggleButton = Instance.new("TextButton")
	toggleButton.Name = "Toggle"
	toggleButton.Position = UDim2.new(1, -104, 0, 67)
	toggleButton.Size = UDim2.fromOffset(90, 38)
	toggleButton.BackgroundColor3 = Color3.fromRGB(48, 181, 102)
	toggleButton.BorderSizePixel = 0
	toggleButton.Font = Enum.Font.GothamBold
	toggleButton.Text = "START"
	toggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	toggleButton.TextSize = 15
	toggleButton.Parent = frame

	local buttonCorner = Instance.new("UICorner")
	buttonCorner.CornerRadius = UDim.new(0, 8)
	buttonCorner.Parent = toggleButton

	statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "Status"
	statusLabel.Position = UDim2.fromOffset(14, 118)
	statusLabel.Size = UDim2.new(1, -28, 0, 43)
	statusLabel.BackgroundColor3 = Color3.fromRGB(28, 33, 46)
	statusLabel.BorderSizePixel = 0
	statusLabel.Font = Enum.Font.GothamMedium
	statusLabel.Text = "Arrêté"
	statusLabel.TextColor3 = Color3.fromRGB(255, 114, 114)
	statusLabel.TextSize = 13
	statusLabel.TextWrapped = true
	statusLabel.Parent = frame

	local statusCorner = Instance.new("UICorner")
	statusCorner.CornerRadius = UDim.new(0, 8)
	statusCorner.Parent = statusLabel


	renderControls = function()
		toggleButton.Text = autoEnabled and "STOP" or "START"
		toggleButton.BackgroundColor3 = autoEnabled and Color3.fromRGB(214, 73, 73) or Color3.fromRGB(48, 181, 102)
		input.TextEditable = not autoEnabled
	end
	toggleButton.Activated:Connect(function()
		if autoEnabled then
			stopAutomation("Arrete par l'utilisateur")
			return
		end
		local normalized = string.gsub(input.Text, ",", ".")
		local billions = tonumber(normalized)
		if not billions or billions ~= billions or math.abs(billions) == math.huge then
			setStatus("Valeur invalide : entre 0.1 et 999", Color3.fromRGB(255, 114, 114))
			return
		end
		billions = math.clamp(billions, MINIMUM_BILLIONS, MAXIMUM_BILLIONS)
		input.Text = tostring(billions)
		startAutomation(billions)
	end)

	return gui
end


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

