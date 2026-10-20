local RunService = game:GetService("RunService")
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
local CARRY_PROMPT_NAME = "CarryAreaEgg"
local PROMPT_SEARCH_RADIUS = 18
local PROMPT_SEARCH_ATTEMPTS = 40
local PROMPT_HOLD_DURATION = 0
local PROMPT_MAX_ACTIVATION_DISTANCE = 16
local MOVE_ARRIVAL_DISTANCE = 6
local MOVE_REFRESH_SECONDS = 0.25

local PROMPT_ROOT_NAMES = {
	AreaEggSlotsClient = true,
	SmartPromptPart = true,
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

local function isInsideEggPromptRoot(instance)
	local current = instance

	while current and current ~= Workspace do
		if PROMPT_ROOT_NAMES[current.Name] then
			return true
		end

		current = current.Parent
	end

	return false
end

local function configureEggPrompt(prompt)
	if not prompt
		or not prompt:IsA("ProximityPrompt")
		or prompt.Name ~= CARRY_PROMPT_NAME
		or not isInsideEggPromptRoot(prompt) then
		return false
	end

	prompt.HoldDuration = PROMPT_HOLD_DURATION
	prompt.MaxActivationDistance = PROMPT_MAX_ACTIVATION_DISTANCE
	return true
end

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

local function resolveResetWall()
	local world = Workspace:FindFirstChild("World")
	local areas = world and world:FindFirstChild("Areas")
	return areas and areas:FindFirstChild("WallStartCollision")
end

local function wallIsClosed(wall)
	if not wall or not wall.Parent then
		return false
	end

	if wall:IsA("BasePart") and wall.CanCollide then
		return true
	end

	for _, descendant in ipairs(wall:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.CanCollide then
			return true
		end
	end

	return false
end

local function waitForResetWall(token, phaseLabel)
	local wall = resolveResetWall()

	if not wall or not wallIsClosed(wall) then
		return token == navigationToken
	end

	print(string.format(
		"[Auto_SAE] Mur de départ fermé avant %s : attente de son ouverture.",
		phaseLabel
	))

	while token == navigationToken and wallIsClosed(wall) do
		RunService.Heartbeat:Wait()
	end

	if token ~= navigationToken then
		return false
	end

	print("[Auto_SAE] Mur de départ ouvert.")
	return true
end

local function moveDirect(destination, token, destinationLabel)
	local _, humanoid, rootPart = getCharacterParts()

	if not humanoid or not rootPart then
		warn("[Auto_SAE] Personnage ou HumanoidRootPart introuvable.")
		return false
	end

	print(string.format(
		"[Auto_SAE] Déplacement direct vers %s : %s.",
		destinationLabel,
		formatPosition(destination)
	))

	local lastMoveCommand = -math.huge

	while token == navigationToken do
		if humanoid.Health <= 0 or not rootPart.Parent then
			return false
		end

		local distance = (rootPart.Position - destination).Magnitude
		if distance <= MOVE_ARRIVAL_DISTANCE then
			humanoid:Move(Vector3.zero)
			return true
		end

		local now = os.clock()
		if now - lastMoveCommand >= MOVE_REFRESH_SECONDS then
			humanoid:MoveTo(destination)
			lastMoveCommand = now
		end

		RunService.Heartbeat:Wait()
	end

	return false
end

local function getPromptPosition(prompt)
	local parent = prompt.Parent

	if not parent then
		return nil
	end

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
	if not configureEggPrompt(prompt) or not prompt.Enabled then
		return false
	end

	local promptPosition = getPromptPosition(prompt)
	return promptPosition ~= nil
		and (promptPosition - rootPosition).Magnitude <= prompt.MaxActivationDistance + 1
end

local function findNearestCarryPrompt(eggPosition, rootPosition)
	local bestPrompt
	local bestDistance = math.huge

	for _, rootName in ipairs({ "AreaEggSlotsClient", "SmartPromptPart" }) do
		local root = Workspace:FindFirstChild(rootName)

		if root then
			for _, descendant in ipairs(root:GetDescendants()) do
				if descendant:IsA("ProximityPrompt")
					and descendant.Name == CARRY_PROMPT_NAME
					and descendant.Enabled then
					local promptPosition = getPromptPosition(descendant)

					if promptPosition then
						local eggDistance = (promptPosition - eggPosition).Magnitude
						local playerDistance = (promptPosition - rootPosition).Magnitude

						if eggDistance <= PROMPT_SEARCH_RADIUS
							and playerDistance <= PROMPT_MAX_ACTIVATION_DISTANCE + 1
							and eggDistance < bestDistance then
							bestDistance = eggDistance
							bestPrompt = descendant
						end
					end
				end
			end
		end
	end

	if bestPrompt then
		configureEggPrompt(bestPrompt)
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
		local exactPrompt = eggModel and eggModel:FindFirstChild(CARRY_PROMPT_NAME, true)

		if exactPrompt
			and exactPrompt:IsA("ProximityPrompt")
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
		warn(string.format("[Auto_SAE] Prompt %s introuvable pour %s.", CARRY_PROMPT_NAME, record.Uid))
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

	configureEggPrompt(prompt)
	activePrompt = prompt

	print(string.format(
		"[Auto_SAE] Activation du prompt de l'œuf | UID: %s | HoldDuration: %.1f | MaxDistance: %.1f",
		record.Uid,
		prompt.HoldDuration,
		prompt.MaxActivationDistance
	))

	prompt:InputHoldBegin()
	task.wait(math.max(prompt.HoldDuration, 0.05))

	if activePrompt == prompt then
		prompt:InputHoldEnd()
		activePrompt = nil
	end

	return token == navigationToken
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
	local savedStartPosition = rootPart.Position
	local eggDestination = Vector3.new(
		eggPosition.X,
		savedStartPosition.Y,
		eggPosition.Z
	)

	print(string.format(
		"[Auto_SAE] Egg détecté | UID: %s | Rareté: %s | Œuf: %s | Départ mémorisé: %s",
		record.Uid,
		rarity,
		formatPosition(eggDestination),
		formatPosition(savedStartPosition)
	))

	local promptActivated = false

	if waitForResetWall(token, "l'aller vers l'œuf")
		and moveDirect(eggDestination, token, "l'œuf") then
		promptActivated = activateEggPrompt(record, eggPosition, token)
		task.wait(0.15)
	end

	if token == navigationToken then
		local returned = moveDirect(savedStartPosition, token, "la position de départ mémorisée")

		if returned then
			print(string.format(
				"[Auto_SAE] Retour terminé : %s.",
				formatPosition(savedStartPosition)
			))
		end
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

	queuedUids[uid] = true
	table.insert(recordQueue, {
		Record = record,
	})

	print(string.format(
		"[Auto_SAE] Cible ajoutée | UID: %s | Rareté: %s",
		uid,
		rarity
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
print("[Auto_SAE] Actif : trajet direct, retour mémorisé, attente du mur et prompts d'œufs uniquement.")
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
