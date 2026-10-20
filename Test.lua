local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local TARGET_RARITIES = {
	Divine = true,
	Eternal = true,
	Secret = true,
}

local SLOT_STATE = "Slot"
local PROMPT_SEARCH_RADIUS = 14
local PROMPT_SEARCH_ATTEMPTS = 40
local MAX_PATH_SEGMENT_DISTANCE = 450
local FIRST_MOVE_RETRY_DELAY = 0.5
local PROMPT_HOLD_DURATION = 0
local PROMPT_MAX_ACTIVATION_DISTANCE = 16
local ROUTE_Y = 71

local ROUTE_POSITIONS = {
	Vector3.new(543, ROUTE_Y, -431),
	Vector3.new(648, ROUTE_Y, -431),
	Vector3.new(796, ROUTE_Y, -431),
	Vector3.new(1007, ROUTE_Y, -431),
	Vector3.new(1242, ROUTE_Y, -431),
	Vector3.new(1566, ROUTE_Y, -431),
	Vector3.new(1951, ROUTE_Y, -431),
	Vector3.new(2381, ROUTE_Y, -431),
	Vector3.new(2885, ROUTE_Y, -431),
	Vector3.new(3525, ROUTE_Y, -431),
	Vector3.new(4266, ROUTE_Y, -429),
	Vector3.new(5131, ROUTE_Y, -429),
	Vector3.new(6011, ROUTE_Y, -429),
}

local navigationToken = 0
local activePrompt = nil
local activeUid = nil
local workerRunning = false
local queuedUids = {}
local successfulVersions = {}
local recordQueue = {}

local function formatPosition(position)
	return string.format(
		"(%.1f, %.1f, %.1f)",
		position.X,
		position.Y,
		position.Z
	)
end

local function getCharacterParts()
	local character = player.Character
	if not character then
		return nil, nil, nil
	end

	return character, character:FindFirstChildOfClass("Humanoid"), character:FindFirstChild("HumanoidRootPart")
end

local function configurePrompt(instance)
	if not instance:IsA("ProximityPrompt") then
		return false
	end

	instance.HoldDuration = PROMPT_HOLD_DURATION
	instance.MaxActivationDistance = PROMPT_MAX_ACTIVATION_DISTANCE
	return true
end

local function configureAllPrompts()
	local configuredCount = 0

	for _, descendant in ipairs(Workspace:GetDescendants()) do
		if configurePrompt(descendant) then
			configuredCount += 1
		end
	end

	return configuredCount
end

Workspace.DescendantAdded:Connect(function(descendant)
	configurePrompt(descendant)
end)

local function teleportToRouteStart()
	local character = player.Character or player.CharacterAdded:Wait()
	local rootPart = character:WaitForChild("HumanoidRootPart", 10)

	if not rootPart then
		warn("[Auto_SAE] Téléportation initiale impossible: HumanoidRootPart introuvable.")
		return
	end

	rootPart.CFrame = CFrame.new(ROUTE_POSITIONS[1])
	rootPart.AssemblyLinearVelocity = Vector3.zero
	rootPart.AssemblyAngularVelocity = Vector3.zero

	print(string.format(
		"[Auto_SAE] Téléportation initiale au point 1: %s.",
		formatPosition(ROUTE_POSITIONS[1])
	))
end

task.spawn(teleportToRouteStart)

local clientFolder = ReplicatedStorage:WaitForChild("Client", 10)
local dataFolder = ReplicatedStorage:WaitForChild("Data", 10)

if not clientFolder or not dataFolder then
	warn("[Auto_SAE] Client ou Data est introuvable dans ReplicatedStorage.")
	return
end

local eggStateModule = clientFolder:WaitForChild("EggState", 10)
local assetsModule = dataFolder:WaitForChild("Assets", 10)

if not eggStateModule or not assetsModule then
	warn("[Auto_SAE] EggState ou Data.Assets est introuvable.")
	return
end

local EggState = require(eggStateModule)
local Assets = require(assetsModule)

local function getRarityName(record)
	if type(record) ~= "table" or type(record.AssetCategory) ~= "string" then
		return nil
	end

	local config = Assets.Directory[record.AssetCategory]
	local rarity = config and config.Rarity

	if type(rarity) == "string" then
		return rarity
	end

	if type(rarity) == "table" then
		return rarity._id or rarity.Id or rarity.Name
	end

	return nil
end

local function resolveEggModel(uid)
	local renderedFolder = Workspace:FindFirstChild("AreaEggSlotsClient")
	local candidate = renderedFolder and renderedFolder:FindFirstChild(uid, true)

	if candidate and candidate:IsA("Model") then
		return candidate
	end

	candidate = Workspace:FindFirstChild(uid, true)

	if candidate and candidate:IsA("Model") then
		return candidate
	end

	return nil
end

local function getEggPosition(record)
	local model = resolveEggModel(record.Uid)

	if model then
		return model:GetPivot().Position, model
	end

	if typeof(record.BottomCFrame) == "CFrame" then
		return record.BottomCFrame.Position, nil
	end

	return nil, nil
end

local function followPathSegment(destination, token, destinationLabel, segmentIndex)
	local _, humanoid, rootPart = getCharacterParts()

	if not humanoid or not rootPart then
		warn("[Auto_SAE] Personnage ou HumanoidRootPart introuvable.")
		return false
	end

	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
		AgentCanClimb = true,
		WaypointSpacing = 4,
	})

	local success, errorMessage = pcall(function()
		path:ComputeAsync(rootPart.Position, destination)
	end)

	if not success then
		warn(string.format(
			"[Auto_SAE] Calcul du segment %d impossible vers %s: %s",
			segmentIndex,
			destinationLabel,
			tostring(errorMessage)
		))
		return false
	end

	if path.Status ~= Enum.PathStatus.Success then
		warn(string.format(
			"[Auto_SAE] Aucun chemin valide pour le segment %d vers %s à %s.",
			segmentIndex,
			destinationLabel,
			formatPosition(destination)
		))
		return false
	end

	for _, waypoint in ipairs(path:GetWaypoints()) do
		if token ~= navigationToken then
			return false
		end

		if humanoid.Health <= 0 or not rootPart.Parent then
			return false
		end

		if waypoint.Action == Enum.PathWaypointAction.Jump then
			humanoid.Jump = true
		end

		humanoid:MoveTo(waypoint.Position)

		if not humanoid.MoveToFinished:Wait() then
			warn(string.format(
				"[Auto_SAE] Segment %d interrompu vers %s.",
				segmentIndex,
				destinationLabel
			))
			return false
		end
	end

	return token == navigationToken
end

local function walkPath(destination, token, destinationLabel)
	local segmentIndex = 0
	local announcedLongRoute = false

	while token == navigationToken do
		local _, humanoid, rootPart = getCharacterParts()

		if not humanoid or not rootPart then
			return false
		end

		local currentPosition = rootPart.Position
		local delta = destination - currentPosition
		local remainingDistance = delta.Magnitude
		local isFinalSegment = remainingDistance <= MAX_PATH_SEGMENT_DISTANCE

		if not announcedLongRoute and not isFinalSegment then
			announcedLongRoute = true
			print(string.format(
				"[Auto_SAE] Long trajet vers %s découpé en segments de %.0f studs.",
				destinationLabel,
				MAX_PATH_SEGMENT_DISTANCE
			))
		end

		local segmentDestination

		if isFinalSegment then
			-- La destination finale conserve exactement le Y demandé.
			segmentDestination = destination
		else
			local rawDestination = currentPosition + delta.Unit * MAX_PATH_SEGMENT_DISTANCE

			-- Les sous-destinations gardent le Y actuel.
			segmentDestination = Vector3.new(
				rawDestination.X,
				currentPosition.Y,
				rawDestination.Z
			)
		end

		segmentIndex += 1
		local positionBeforeSegment = currentPosition

		if not followPathSegment(
			segmentDestination,
			token,
			destinationLabel,
			segmentIndex
		) then
			return false
		end

		if isFinalSegment then
			return token == navigationToken
		end

		local _, _, updatedRoot = getCharacterParts()

		if not updatedRoot then
			return false
		end

		if (updatedRoot.Position - positionBeforeSegment).Magnitude < 2 then
			warn(string.format(
				"[Auto_SAE] Aucun progrès sur le segment %d vers %s.",
				segmentIndex,
				destinationLabel
			))
			return false
		end
	end

	return false
end

local function buildOutboundRoute(eggPosition)
	local eggGoal = Vector3.new(eggPosition.X, ROUTE_Y, eggPosition.Z)
	local route = {}

	for _, checkpoint in ipairs(ROUTE_POSITIONS) do
		-- La route avance sur X et ne prend jamais un point situé après l'œuf.
		if checkpoint.X >= eggGoal.X then
			break
		end

		table.insert(route, checkpoint)
	end

	return route, eggGoal
end

local function walkRouteToEgg(eggPosition, token)
	local route, eggGoal = buildOutboundRoute(eggPosition)
	local reachedRoute = {}

	for index, checkpoint in ipairs(route) do
		local reached = false

		if index == 2 then
			-- Le mur temporaire entre les points 1 et 2 bloque environ 5 secondes.
			-- On recalcule le chemin sans limite jusqu'à son ouverture ou l'annulation.
			while token == navigationToken and not reached do
				reached = walkPath(
					checkpoint,
					token,
					"le point de route 2"
				)

				if not reached and token == navigationToken then
					print(string.format(
						"[Auto_SAE] Point 2 encore bloqué, nouvelle tentative dans %.1f seconde.",
						FIRST_MOVE_RETRY_DELAY
					))
					task.wait(FIRST_MOVE_RETRY_DELAY)
				end
			end
		else
			reached = walkPath(
				checkpoint,
				token,
				string.format("le point de route %d", index)
			)
		end

		if not reached then
			return false, reachedRoute, eggGoal
		end

		table.insert(reachedRoute, checkpoint)
	end

	local arrived = walkPath(eggGoal, token, "la position de l'œuf à Y = 71")
	return arrived, reachedRoute, eggGoal
end

local function getPromptPosition(prompt)
	local parent = prompt.Parent

	if parent:IsA("Attachment") then
		return parent.WorldPosition
	end

	if parent:IsA("BasePart") then
		return parent.Position
	end

	local model = parent:FindFirstAncestorOfClass("Model")
	return model and model:GetPivot().Position or nil
end

local function promptIsUsable(prompt, rootPosition)
	if not prompt or not prompt.Parent then
		return false
	end

	configurePrompt(prompt)

	if not prompt.Enabled then
		return false
	end

	local promptPosition = getPromptPosition(prompt)

	return promptPosition ~= nil
		and (promptPosition - rootPosition).Magnitude <= prompt.MaxActivationDistance + 1
end

local function findNearestCarryPrompt(eggPosition, rootPosition)
	local bestPrompt
	local bestDistance = math.huge

	for _, descendant in ipairs(Workspace:GetDescendants()) do
		if not descendant:IsA("ProximityPrompt")
			or descendant.Name ~= "CarryAreaEgg"
			or not descendant.Enabled then
			continue
		end

		configurePrompt(descendant)
		local promptPosition = getPromptPosition(descendant)

		if not promptPosition then
			continue
		end

		local eggDistance = (promptPosition - eggPosition).Magnitude

		if eggDistance > PROMPT_SEARCH_RADIUS then
			continue
		end

		if (promptPosition - rootPosition).Magnitude > descendant.MaxActivationDistance + 1 then
			continue
		end

		if eggDistance < bestDistance then
			bestDistance = eggDistance
			bestPrompt = descendant
		end
	end

	return bestPrompt
end

local function activateEggPrompt(record, eggPosition, token)
	local prompt

	for _ = 1, PROMPT_SEARCH_ATTEMPTS do
		if token ~= navigationToken then
			return false
		end

		local _, _, rootPart = getCharacterParts()

		if not rootPart then
			return false
		end

		local eggModel = resolveEggModel(record.Uid)
		local exactPrompt = eggModel and eggModel:FindFirstChild("CarryAreaEgg", true)

		if exactPrompt and exactPrompt:IsA("ProximityPrompt")
			and promptIsUsable(exactPrompt, rootPart.Position) then
			prompt = exactPrompt
			break
		end

		prompt = findNearestCarryPrompt(eggPosition, rootPart.Position)

		if prompt then
			break
		end

		task.wait(0.1)
	end

	if not prompt then
		warn(string.format("[Auto_SAE] Prompt CarryAreaEgg introuvable pour %s.", record.Uid))
		return false
	end

	local _, _, rootPart = getCharacterParts()

	if not rootPart then
		return false
	end

	local promptPosition = getPromptPosition(prompt)

	if promptPosition then
		local lookTarget = Vector3.new(promptPosition.X, rootPart.Position.Y, promptPosition.Z)

		if (lookTarget - rootPart.Position).Magnitude > 0.01 then
			rootPart.CFrame = CFrame.lookAt(rootPart.Position, lookTarget)
		end
	end

	configurePrompt(prompt)
	activePrompt = prompt

	print(string.format(
		"[Auto_SAE] Prompt: %s | UID: %s | RequiresLineOfSight: %s",
		prompt:GetFullName(),
		record.Uid,
		tostring(prompt.RequiresLineOfSight)
	))

	prompt:InputHoldBegin()
	task.wait(math.max(prompt.HoldDuration, 0.05))

	if activePrompt == prompt then
		prompt:InputHoldEnd()
		activePrompt = nil
	end

	return token == navigationToken
end

local function returnToStartPosition(outboundRoute, token)
	print(string.format(
		"[Auto_SAE] Retour par les points vers le départ %s.",
		formatPosition(ROUTE_POSITIONS[1])
	))

	for index = #outboundRoute, 2, -1 do
		if not walkPath(
			outboundRoute[index],
			token,
			string.format("le point de retour %d", index)
		) then
			return false
		end
	end

	local returned = walkPath(
		ROUTE_POSITIONS[1],
		token,
		"la position 1 de départ"
	)

	if returned then
		print("[Auto_SAE] Retour à la position 1 terminé.")
	end

	return returned
end

local function runEgg(record, rarity)
	local _, humanoid, rootPart = getCharacterParts()

	if not humanoid or not rootPart then
		warn("[Auto_SAE] Personnage indisponible pour l'œuf", record.Uid)
		return false
	end

	local eggPosition = getEggPosition(record)

	if not eggPosition then
		warn("[Auto_SAE] Position introuvable pour l'œuf", record.Uid)
		return false
	end

	navigationToken += 1
	local token = navigationToken

	print(string.format(
		"[Auto_SAE] Egg détecté | UID: %s | Rareté: %s | Position: %s | Départ/retour: %s",
		record.Uid,
		rarity,
		formatPosition(eggPosition),
		formatPosition(ROUTE_POSITIONS[1])
	))

	local promptActivated = false
	local reachedRoute = {}
	local _, _, currentRoot = getCharacterParts()

	if currentRoot and token == navigationToken then
		local arrived, traversedRoute, eggGoal = walkRouteToEgg(eggPosition, token)
		reachedRoute = traversedRoute

		if arrived then
			print(string.format(
				"[Auto_SAE] Arrivé à la position de l'œuf %s: %s.",
				record.Uid,
				formatPosition(eggGoal)
			))
			promptActivated = activateEggPrompt(record, eggPosition, token)
			task.wait(0.15)
		end
	end

	if token == navigationToken then
		returnToStartPosition(reachedRoute, token)
	end

	return promptActivated
end

local function eligibleRecord(record)
	if type(record) ~= "table"
		or type(record.Uid) ~= "string"
		or record.State ~= SLOT_STATE then
		return false, nil
	end

	local rarity = getRarityName(record)
	return rarity ~= nil and TARGET_RARITIES[rarity] == true, rarity
end

local function versionKey(record)
	return tostring(record.Version or 0)
end

local function processQueue()
	if workerRunning then
		return
	end

	workerRunning = true

	task.spawn(function()
		while #recordQueue > 0 do
			local queueEntry = table.remove(recordQueue, 1)
			local record = queueEntry.Record
			queuedUids[record.Uid] = nil

			local latestRecord = EggState.ReadFieldEgg(record.Uid)
			local eligible, rarity = eligibleRecord(latestRecord)

			if eligible then
				activeUid = latestRecord.Uid

				if runEgg(latestRecord, rarity) then
					successfulVersions[latestRecord.Uid] = versionKey(latestRecord)
				end

				activeUid = nil
			end
		end

		workerRunning = false
	end)
end

local function enqueueRecord(record)
	local eligible, rarity = eligibleRecord(record)

	if not eligible then
		return
	end

	local uid = record.Uid
	local key = versionKey(record)

	if queuedUids[uid]
		or activeUid == uid
		or successfulVersions[uid] == key then
		return
	end

	local configuredPromptCount = configureAllPrompts()
	print(string.format(
		"[Auto_SAE] Détection: %d prompt(s) configuré(s) | HoldDuration: %.1f | Distance: %.1f",
		configuredPromptCount,
		PROMPT_HOLD_DURATION,
		PROMPT_MAX_ACTIVATION_DISTANCE
	))

	queuedUids[uid] = true
	table.insert(recordQueue, {
		Record = record,
	})

	print(string.format(
		"[Auto_SAE] Cible ajoutée | UID: %s | Rareté: %s | Départ/retour: %s",
		uid,
		rarity,
		formatPosition(ROUTE_POSITIONS[1])
	))

	processQueue()
end

local function applySnapshot(snapshot)
	if type(snapshot) ~= "table" then
		return
	end

	for _, record in ipairs(snapshot.Records or {}) do
		enqueueRecord(record)
	end
end

EggState.FieldRefreshed:Connect(applySnapshot)
EggState.FieldShifted:Connect(enqueueRecord)
EggState.FieldGone:Connect(function(uid)
	queuedUids[uid] = nil
	successfulVersions[uid] = nil
end)

player.CharacterRemoving:Connect(function()
	navigationToken += 1
	activeUid = nil

	if activePrompt then
		activePrompt:InputHoldEnd()
		activePrompt = nil
	end
end)

applySnapshot(EggState.ReadFieldEggs())
print("[Auto_SAE] Actif : EggState surveille Divine, Eternal et Secret.")
