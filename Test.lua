local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local SLOT_STATE = "Slot"
local CARRY_PROMPT_NAME = "CarryAreaEgg"
local PROMPT_SEARCH_RADIUS = 18
local PROMPT_ACTIVATION_ATTEMPTS = 40
local POSITION_ARRIVAL_DISTANCE = 4.5
local EGG_ACTIVATION_DISTANCE = 2
local PROMPT_DISPLAY_DISTANCE = 30
local TARGET_PROMPT_DISTANCE = 100
local EGG_CORRECTION_SPEED = 35
local EGG_MOVE_REFRESH_SECONDS = 0.1
local DEBUG_PROGRESS_INTERVAL = 0.5
local MINIMUM_BILLIONS = 0.1
local MAXIMUM_BILLIONS = 999
local DEFAULT_BILLIONS = 2

local PROMPT_ROOT_NAMES = {
	AreaEggSlotsClient = true,
	SmartPromptPart = true,
}

local navigationToken = 0
local activePrompt = nil
local activeUid = nil
local workerRunning = false
local autoEnabled = false
local minimumRatePerSecond = DEFAULT_BILLIONS * 1e9
local queuedUids = {}
local successfulVersions = {}
local loggedVersions = {}
local recordQueue = {}
local promptCacheBySlot = {}
local activeTargetPrompt = nil
local suspendedEggPromptStates = {}
local debugSequence = 0

local function debugLog(stage, message, ...)
	debugSequence += 1
	local ok, rendered = pcall(string.format, message, ...)

	if not ok then
		rendered = message .. " | ERREUR_FORMAT=" .. tostring(rendered)
	end

	print(string.format(
		"[Auto_SAE][DEBUG][%04d][%.3f][%s] %s",
		debugSequence,
		os.clock(),
		stage,
		rendered
	))
end

local function debugWarn(stage, message, ...)
	debugSequence += 1
	local ok, rendered = pcall(string.format, message, ...)

	if not ok then
		rendered = message .. " | ERREUR_FORMAT=" .. tostring(rendered)
	end

	warn(string.format(
		"[Auto_SAE][DEBUG][%04d][%.3f][%s] %s",
		debugSequence,
		os.clock(),
		stage,
		rendered
	))
end

local function formatPosition(position)
	return string.format(
		"(%.1f, %.1f, %.1f)",
		position.X,
		position.Y,
		position.Z
	)
end

local function formatNumber(value)
	local absolute = math.abs(value)

	if absolute >= 1e15 then
		return string.format("%.3gQa", value / 1e15)
	elseif absolute >= 1e12 then
		return string.format("%.3gT", value / 1e12)
	elseif absolute >= 1e9 then
		return string.format("%.3gB", value / 1e9)
	elseif absolute >= 1e6 then
		return string.format("%.3gM", value / 1e6)
	elseif absolute >= 1e3 then
		return string.format("%.3gK", value / 1e3)
	end

	return tostring(math.round(value))
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
	return prompt ~= nil
		and prompt:IsA("ProximityPrompt")
		and prompt.Name == CARRY_PROMPT_NAME
		and isInsideEggPromptRoot(prompt)
end

local function setEggPromptDisplayDistance(prompt)
	if not configureEggPrompt(prompt) then
		return false
	end

	prompt.MaxActivationDistance = PROMPT_DISPLAY_DISTANCE
	return true
end

local function suspendOtherEggPrompts(targetPrompt)
	activeTargetPrompt = targetPrompt
	table.clear(suspendedEggPromptStates)

	local disabledCount = 0

	local function suspend(prompt)
		if not configureEggPrompt(prompt) or prompt == targetPrompt then
			return
		end

		if suspendedEggPromptStates[prompt] == nil then
			suspendedEggPromptStates[prompt] = prompt.Enabled
		end

		if prompt.Enabled then
			prompt.Enabled = false
		end

		disabledCount += 1
	end

	local renderedFolder = Workspace:FindFirstChild("AreaEggSlotsClient")
	if renderedFolder then
		for _, descendant in ipairs(renderedFolder:GetDescendants()) do
			suspend(descendant)
		end
	end

	for _, workspaceChild in ipairs(Workspace:GetChildren()) do
		if workspaceChild.Name == "SmartPromptPart" then
			for _, descendant in ipairs(workspaceChild:GetDescendants()) do
				suspend(descendant)
			end
		end
	end

	debugLog(
		"PROMPT_ISOLATION",
		"%d prompt(s) non cible(s) suspendu(s). Cible=%s Parent=%s",
		disabledCount,
		targetPrompt and targetPrompt:GetFullName() or "nil",
		targetPrompt and targetPrompt.Parent and targetPrompt.Parent:GetFullName() or "nil"
	)
end

local function enforceOtherEggPromptsDisabled()
	local disabledAgain = 0

	for prompt in pairs(suspendedEggPromptStates) do
		if prompt.Parent and prompt.Enabled then
			prompt.Enabled = false
			disabledAgain += 1
		end
	end

	if disabledAgain > 0 then
		debugLog(
			"PROMPT_ISOLATION",
			"%d prompt(s) non cible(s) reactive(s) par le jeu puis redésactive(s).",
			disabledAgain
		)
	end
end

local function restoreOtherEggPrompts(afterTriggered)
	local restoredCount = 0

	for prompt, wasEnabled in pairs(suspendedEggPromptStates) do
		if prompt.Parent then
			prompt.Enabled = afterTriggered and true or wasEnabled
			restoredCount += 1
		end
	end

	table.clear(suspendedEggPromptStates)
	activeTargetPrompt = nil

	debugLog(
		"PROMPT_ISOLATION",
		"%d prompt(s) restaure(s) | Triggered=%s | EtatApres=%s",
		restoredCount,
		tostring(afterTriggered),
		afterTriggered and "Enabled" or "etat initial"
	)
end

local function configureAllEggPrompts()
	local configured = 0
	local renderedFolder = Workspace:FindFirstChild("AreaEggSlotsClient")

	if renderedFolder then
		for _, descendant in ipairs(renderedFolder:GetDescendants()) do
			if setEggPromptDisplayDistance(descendant) then
				configured += 1
			end
		end
	end

	for _, workspaceChild in ipairs(Workspace:GetChildren()) do
		if workspaceChild.Name == "SmartPromptPart" then
			for _, descendant in ipairs(workspaceChild:GetDescendants()) do
				if setEggPromptDisplayDistance(descendant) then
					configured += 1
				end
			end
		end
	end

	return configured
end

Workspace.DescendantAdded:Connect(function(instance)
	if instance:IsA("ProximityPrompt") and instance.Name == CARRY_PROMPT_NAME then
		task.defer(function()
			if not setEggPromptDisplayDistance(instance) then
				return
			end

			debugLog(
				"PROMPT_ADDED",
				"Nouveau prompt detecte : %s | Enabled=%s | MaxDistance=%.1f | HoldDuration=%.2f",
				instance:GetFullName(),
				tostring(instance.Enabled),
				instance.MaxActivationDistance,
				instance.HoldDuration
			)

			if activeTargetPrompt and instance ~= activeTargetPrompt then
				if suspendedEggPromptStates[instance] == nil then
					suspendedEggPromptStates[instance] = instance.Enabled
				end

				instance.Enabled = false
				debugLog("PROMPT_ISOLATION", "Nouveau prompt non cible desactive : %s", instance:GetFullName())
			end
		end)
	end
end)

task.defer(function()
	local configured = configureAllEggPrompts()
	print(string.format(
		"[Auto_SAE] %d prompt(s) d'œuf configuré(s) à %.0f studs.",
		configured,
		PROMPT_DISPLAY_DISTANCE
	))
end)

local clientFolder = ReplicatedStorage:WaitForChild("Client", 10)
local dataFolder = ReplicatedStorage:WaitForChild("Data", 10)
local sharedFolder = ReplicatedStorage:WaitForChild("Shared", 10)

if not clientFolder or not dataFolder or not sharedFolder then
	warn("[Auto_SAE] Client, Data ou Shared est introuvable dans ReplicatedStorage.")
	return
end

local eggStateModule = clientFolder:WaitForChild("EggState", 10)
local assetsModule = dataFolder:WaitForChild("Assets", 10)
local utilFolder = sharedFolder:WaitForChild("Util", 10)
local eggRecordsModule = utilFolder and utilFolder:WaitForChild("EggRecords", 10)
local assetEarningsModule = utilFolder and utilFolder:WaitForChild("AssetEarnings", 10)

if not eggStateModule
	or not assetsModule
	or not eggRecordsModule
	or not assetEarningsModule then
	warn("[Auto_SAE] EggState, Assets, EggRecords ou AssetEarnings est introuvable.")
	return
end

local EggState = require(eggStateModule)
local Assets = require(assetsModule)
local EggRecords = require(eggRecordsModule)
local AssetEarnings = require(assetEarningsModule)

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

	local recordPosition = getRecordPosition(record)
	if recordPosition then
		return recordPosition, nil
	end

	return nil, nil
end

local function popHighestRateQueueEntry()
	local highestIndex = 1
	local highestRate = -math.huge

	for index, queueEntry in ipairs(recordQueue) do
		local rate = tonumber(queueEntry.Rate) or -math.huge

		if rate > highestRate then
			highestRate = rate
			highestIndex = index
		end
	end

	return table.remove(recordQueue, highestIndex)
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

local function waitForResetWall(token)
	local wall = resolveResetWall()

	if not wall or not wallIsClosed(wall) then
		return token == navigationToken
	end

	print("[Auto_SAE] Mur de départ fermé : attente de son ouverture.")

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
		"[Auto_SAE] MoveTo rapide vers %s : %s.",
		destinationLabel,
		formatPosition(destination)
	))

	humanoid:MoveTo(destination)
	humanoid.MoveToFinished:Wait()

	if token ~= navigationToken or not autoEnabled then
		return false
	end

	local offsetAfterMove = destination - rootPart.Position
	local distanceAfterMove = Vector3.new(offsetAfterMove.X, 0, offsetAfterMove.Z).Magnitude

	if distanceAfterMove <= POSITION_ARRIVAL_DISTANCE then
		humanoid:Move(Vector3.zero)
		return true
	end

	local speedToRestore = humanoid.WalkSpeed
	humanoid.WalkSpeed = math.min(speedToRestore, EGG_CORRECTION_SPEED)
	local lastMoveCommand = -math.huge

	print(string.format(
		"[Auto_SAE] Ajustement retour à %.0f studs/s, distance restante : %.1f studs.",
		humanoid.WalkSpeed,
		distanceAfterMove
	))

	local function restoreSpeed()
		if humanoid.Parent then
			humanoid.WalkSpeed = speedToRestore
		end
	end

	while token == navigationToken and autoEnabled do
		if humanoid.Health <= 0 or not rootPart.Parent then
			restoreSpeed()
			return false
		end

		local offset = destination - rootPart.Position
		local distance = Vector3.new(offset.X, 0, offset.Z).Magnitude

		if distance <= POSITION_ARRIVAL_DISTANCE then
			humanoid:Move(Vector3.zero)
			restoreSpeed()
			return true
		end

		local now = os.clock()
		if now - lastMoveCommand >= EGG_MOVE_REFRESH_SECONDS then
			humanoid:MoveTo(destination)
			lastMoveCommand = now
		end

		RunService.Heartbeat:Wait()
	end

	humanoid:Move(Vector3.zero)
	restoreSpeed()
	return false
end

local fireprompt
local getPromptPosition

local function moveUntilPromptTriggered(destination, prompt, token, destinationLabel)
	local _, humanoid, rootPart = getCharacterParts()

	if not humanoid or not rootPart or not configureEggPrompt(prompt) or not prompt.Parent then
		debugWarn(
			"MOVE_INIT",
			"Demarrage refuse | Humanoid=%s | Root=%s | Prompt=%s | Parent=%s",
			tostring(humanoid ~= nil),
			tostring(rootPart ~= nil),
			tostring(prompt ~= nil),
			tostring(prompt and prompt.Parent ~= nil)
		)
		return false
	end

	prompt.MaxActivationDistance = TARGET_PROMPT_DISTANCE
	prompt.HoldDuration = 0
	suspendOtherEggPrompts(prompt)

	local promptTriggered = false
	local promptShown = false
	local activationInProgress = false
	local moveCommandCount = 0
	local shownCount = 0
	local hiddenCount = 0
	local lastProgressLog = -math.huge
	local lastMoveCommand = -math.huge

	debugLog(
		"MOVE_INIT",
		"Cible preparee | Destination=%s | Prompt=%s | Enabled=%s | MaxDistance=%.1f | HoldDuration=%.2f | Root=%s",
		formatPosition(destination),
		prompt:GetFullName(),
		tostring(prompt.Enabled),
		prompt.MaxActivationDistance,
		prompt.HoldDuration,
		formatPosition(rootPart.Position)
	)

	local function requestActivation(reason)
		if activationInProgress or promptTriggered or not prompt.Parent or not autoEnabled then
			debugLog(
				"ACTIVATION_SKIP",
				"Activation ignoree | Raison=%s | InProgress=%s | Triggered=%s | Parent=%s | Auto=%s",
				reason,
				tostring(activationInProgress),
				tostring(promptTriggered),
				tostring(prompt.Parent ~= nil),
				tostring(autoEnabled)
			)
			return
		end

		activationInProgress = true
		debugLog("ACTIVATION_REQUEST", "fireprompt lance | Raison=%s", reason)

		task.defer(function()
			local activationResult = fireprompt(prompt)
			debugLog(
				"ACTIVATION_RESULT",
				"fireprompt termine | Resultat=%s | TriggeredObserve=%s | Enabled=%s | Parent=%s",
				tostring(activationResult),
				tostring(promptTriggered),
				tostring(prompt.Enabled),
				tostring(prompt.Parent ~= nil)
			)
			activationInProgress = false
		end)
	end

	local triggeredConnection = prompt.Triggered:Connect(function(triggeringPlayer)
		debugLog(
			"TRIGGERED_EVENT",
			"Evenement recu | Joueur=%s | LocalPlayer=%s",
			triggeringPlayer and triggeringPlayer.Name or "nil",
			player.Name
		)

		if triggeringPlayer == nil or triggeringPlayer == player then
			promptTriggered = true
			debugLog("TRIGGERED_EVENT", "Confirmation acceptee : la boucle MoveTo peut s'arreter.")
		else
			debugWarn("TRIGGERED_EVENT", "Confirmation ignoree car elle vient d'un autre joueur.")
		end
	end)

	local shownConnection = prompt.PromptShown:Connect(function(inputType)
		shownCount += 1
		promptShown = true
		prompt.MaxActivationDistance = TARGET_PROMPT_DISTANCE
		prompt.HoldDuration = 0

		debugLog(
			"PROMPT_SHOWN",
			"Affichage #%d | Input=%s | Enabled=%s | MaxDistance=%.1f | HoldDuration=%.2f | Boucle continue jusqu'a Triggered",
			shownCount,
			tostring(inputType),
			tostring(prompt.Enabled),
			prompt.MaxActivationDistance,
			prompt.HoldDuration
		)

		requestActivation("PromptShown #" .. tostring(shownCount))
	end)

	local hiddenConnection = prompt.PromptHidden:Connect(function()
		hiddenCount += 1
		promptShown = false
		debugWarn(
			"PROMPT_HIDDEN",
			"Disparition #%d | Enabled=%s | Parent=%s | La boucle MoveTo continue.",
			hiddenCount,
			tostring(prompt.Enabled),
			tostring(prompt.Parent ~= nil)
		)
	end)

	local function disconnectEvents()
		triggeredConnection:Disconnect()
		shownConnection:Disconnect()
		hiddenConnection:Disconnect()
	end

	RunService.Heartbeat:Wait()

	local promptPosition = getPromptPosition(prompt)
	if prompt.Enabled
		and promptPosition
		and (promptPosition - rootPart.Position).Magnitude <= prompt.MaxActivationDistance + 1 then
		promptShown = true
		debugLog(
			"PROMPT_VISIBLE_FALLBACK",
			"Prompt deja visible a la connexion | Distance3D=%.2f | Activation lancee.",
			(promptPosition - rootPart.Position).Magnitude
		)
		requestActivation("prompt deja visible")
	end

	while token == navigationToken and autoEnabled and not promptTriggered do
		if humanoid.Health <= 0 or not rootPart.Parent then
			debugWarn(
				"MOVE_ABORT",
				"Personnage invalide | Health=%.1f | RootParent=%s",
				humanoid.Health,
				tostring(rootPart.Parent ~= nil)
			)
			break
		end

		if not prompt.Parent then
			debugWarn("MOVE_ABORT", "Le prompt cible a perdu son Parent avant Triggered.")
			break
		end

		local now = os.clock()
		local offset = destination - rootPart.Position
		local horizontalDistanceToEgg = Vector2.new(offset.X, offset.Z).Magnitude
		local promptPositionNow = getPromptPosition(prompt)
		local promptDistance = promptPositionNow and (promptPositionNow - rootPart.Position).Magnitude or -1

		if now - lastMoveCommand >= EGG_MOVE_REFRESH_SECONDS then
			enforceOtherEggPromptsDisabled()
			humanoid:MoveTo(destination)
			lastMoveCommand = now
			moveCommandCount += 1
		end

		if now - lastProgressLog >= DEBUG_PROGRESS_INTERVAL then
			lastProgressLog = now
			debugLog(
				"MOVE_PROGRESS",
				"Commande=%d | Position=%s | DistanceEggXZ=%.2f | DistancePrompt3D=%.2f | Shown=%s | Enabled=%s | Activation=%s | Triggered=%s",
				moveCommandCount,
				formatPosition(rootPart.Position),
				horizontalDistanceToEgg,
				promptDistance,
				tostring(promptShown),
				tostring(prompt.Enabled),
				tostring(activationInProgress),
				tostring(promptTriggered)
			)
		end

		RunService.Heartbeat:Wait()
	end

	humanoid:Move(Vector3.zero)
	humanoid:MoveTo(rootPart.Position)
	disconnectEvents()
	restoreOtherEggPrompts(promptTriggered)

	if promptTriggered and token == navigationToken and autoEnabled then
		debugLog(
			"MOVE_COMPLETE",
			"Triggered confirme apres %d commande(s) MoveTo | Position finale=%s | Retour autorise.",
			moveCommandCount,
			formatPosition(rootPart.Position)
		)
		return true
	end

	debugWarn(
		"MOVE_FAILED",
		"Fin sans Triggered | TokenValide=%s | Auto=%s | PromptParent=%s | Commandes=%d",
		tostring(token == navigationToken),
		tostring(autoEnabled),
		tostring(prompt.Parent ~= nil),
		moveCommandCount
	)
	return false
end
getPromptPosition = function(prompt)
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

local function promptSlotKey(eggPosition)
	return string.format("%.1f|%.1f", eggPosition.X, eggPosition.Z)
end

local function horizontalDistance(firstPosition, secondPosition)
	local offset = firstPosition - secondPosition
	return Vector2.new(offset.X, offset.Z).Magnitude
end

local function findCarryPromptNearEgg(record, eggPosition)
	local cacheKey = promptSlotKey(eggPosition)
	local cachedPrompt = promptCacheBySlot[cacheKey]

	if setEggPromptDisplayDistance(cachedPrompt)
		and cachedPrompt.Parent then
		local cachedPosition = getPromptPosition(cachedPrompt)

		if cachedPosition
			and horizontalDistance(cachedPosition, eggPosition) <= PROMPT_SEARCH_RADIUS then
			return cachedPrompt
		end
	end

	promptCacheBySlot[cacheKey] = nil

	local bestPrompt
	local bestDistance = math.huge

	local function considerPrompt(prompt)
		if not configureEggPrompt(prompt) or not prompt.Parent then
			return
		end

		local promptPosition = getPromptPosition(prompt)
		if not promptPosition then
			return
		end

		local distance = horizontalDistance(promptPosition, eggPosition)
		if distance <= PROMPT_SEARCH_RADIUS and distance < bestDistance then
			bestDistance = distance
			bestPrompt = prompt
		end
	end

	local eggModel = resolveEggModel(record.Uid)
	local exactPrompt = eggModel and eggModel:FindFirstChild(CARRY_PROMPT_NAME, true)
	considerPrompt(exactPrompt)

	local renderedFolder = Workspace:FindFirstChild("AreaEggSlotsClient")
	if renderedFolder then
		for _, descendant in ipairs(renderedFolder:GetDescendants()) do
			considerPrompt(descendant)
		end
	end

	for _, workspaceChild in ipairs(Workspace:GetChildren()) do
		if workspaceChild.Name == "SmartPromptPart" then
			for _, descendant in ipairs(workspaceChild:GetDescendants()) do
				considerPrompt(descendant)
			end
		end
	end

	if bestPrompt then
		promptCacheBySlot[cacheKey] = bestPrompt
	end

	return bestPrompt
end

local function waitForCarryPromptNearEgg(record, eggPosition, token)
	local waitingLogged = false
	local searchCount = 0
	local lastDebugLog = -math.huge

	debugLog(
		"PROMPT_SEARCH",
		"Debut recherche | UID=%s | EggPosition=%s | Rayon=%.1f",
		record.Uid,
		formatPosition(eggPosition),
		PROMPT_SEARCH_RADIUS
	)

	while token == navigationToken and autoEnabled do
		searchCount += 1
		local prompt = findCarryPromptNearEgg(record, eggPosition)

		if prompt then
			local promptPosition = getPromptPosition(prompt)
			debugLog(
				"PROMPT_FOUND",
				"Trouve apres %d scan(s) | Path=%s | Position=%s | Enabled=%s | MaxDistance=%.1f | HoldDuration=%.2f",
				searchCount,
				prompt:GetFullName(),
				promptPosition and formatPosition(promptPosition) or "nil",
				tostring(prompt.Enabled),
				prompt.MaxActivationDistance,
				prompt.HoldDuration
			)
			return prompt
		end

		if not waitingLogged then
			waitingLogged = true
			print(string.format(
				"[Auto_SAE] Prompt de %s pas encore rendu : attente de son SmartPromptPart.",
				record.Uid
			))
		end

		if os.clock() - lastDebugLog >= 1 then
			lastDebugLog = os.clock()
			debugLog(
				"PROMPT_SEARCH",
				"Scan #%d sans resultat | UID=%s | TokenValide=%s | Auto=%s",
				searchCount,
				record.Uid,
				tostring(token == navigationToken),
				tostring(autoEnabled)
			)
		end

		local readOk, currentRecord = pcall(EggState.ReadFieldEgg, record.Uid)
		if readOk and (currentRecord == nil or currentRecord.State ~= SLOT_STATE) then
			debugWarn(
				"PROMPT_SEARCH",
				"Recherche abandonnee : l'oeuf n'est plus dans l'etat Slot | UID=%s",
				record.Uid
			)
			return nil
		end

		task.wait(0.1)
	end

	debugWarn(
		"PROMPT_SEARCH",
		"Recherche interrompue | UID=%s | TokenValide=%s | Auto=%s",
		record.Uid,
		tostring(token == navigationToken),
		tostring(autoEnabled)
	)
	return nil
end

fireprompt = function(prompt)
	if not configureEggPrompt(prompt) or not prompt.Enabled or not prompt.Parent then
		debugWarn(
			"FIRE_REJECTED",
			"Prompt inutilisable | Configure=%s | Enabled=%s | Parent=%s",
			tostring(configureEggPrompt(prompt)),
			tostring(prompt and prompt.Enabled),
			tostring(prompt and prompt.Parent ~= nil)
		)
		return false
	end

	debugLog(
		"FIRE_START",
		"Debut | Prompt=%s | Enabled=%s | MaxDistance=%.1f | HoldDuration=%.2f",
		prompt:GetFullName(),
		tostring(prompt.Enabled),
		prompt.MaxActivationDistance,
		prompt.HoldDuration
	)

	for attempt = 1, 3 do
		if not autoEnabled or not prompt.Parent or not prompt.Enabled then
			debugWarn(
				"FIRE_ABORT",
				"Tentative %d annulee | Auto=%s | Parent=%s | Enabled=%s",
				attempt,
				tostring(autoEnabled),
				tostring(prompt.Parent ~= nil),
				tostring(prompt.Enabled)
			)
			return false
		end

		local triggered = false
		local connection = prompt.Triggered:Connect(function(triggeringPlayer)
			debugLog(
				"FIRE_TRIGGERED",
				"Tentative %d | Joueur=%s",
				attempt,
				triggeringPlayer and triggeringPlayer.Name or "nil"
			)

			if triggeringPlayer == nil or triggeringPlayer == player then
				triggered = true
			end
		end)

		activePrompt = prompt
		debugLog("FIRE_ATTEMPT", "Tentative %d/3 : InputHoldBegin.", attempt)

		local beginOk, beginError = pcall(function()
			prompt:InputHoldBegin()
		end)

		if not beginOk then
			connection:Disconnect()
			activePrompt = nil
			debugWarn("FIRE_ERROR", "InputHoldBegin impossible | Tentative=%d | Erreur=%s", attempt, tostring(beginError))
			return false
		end

		local deadline = os.clock() + math.max(prompt.HoldDuration, 0) + 0.35
		debugLog(
			"FIRE_WAIT",
			"Tentative %d | DeadlineDans=%.3f | HoldDuration=%.2f",
			attempt,
			deadline - os.clock(),
			prompt.HoldDuration
		)

		while activePrompt == prompt
			and autoEnabled
			and prompt.Parent
			and prompt.Enabled
			and not triggered
			and os.clock() < deadline do
			RunService.Heartbeat:Wait()
		end

		if activePrompt == prompt then
			local endOk, endError = pcall(function()
				prompt:InputHoldEnd()
			end)
			activePrompt = nil
			debugLog(
				"FIRE_HOLD_END",
				"Tentative %d | InputHoldEndOk=%s | Erreur=%s",
				attempt,
				tostring(endOk),
				tostring(endError)
			)
		end

		RunService.Heartbeat:Wait()
		connection:Disconnect()

		if triggered then
			debugLog("FIRE_SUCCESS", "Triggered confirme a la tentative %d.", attempt)
			return true
		end

		debugWarn(
			"FIRE_RETRY",
			"Echec tentative %d | Enabled=%s | Parent=%s | Auto=%s",
			attempt,
			tostring(prompt.Enabled),
			tostring(prompt.Parent ~= nil),
			tostring(autoEnabled)
		)
		task.wait(0.1)
	end

	debugWarn("FIRE_FAILED", "Aucun Triggered apres 3 tentatives.")
	return false
end
local function activateEggPrompt(record, prompt, token)
	for _ = 1, PROMPT_ACTIVATION_ATTEMPTS do
		if token ~= navigationToken or not autoEnabled then
			return false
		end

		local _, _, rootPart = getCharacterParts()
		if not rootPart then
			return false
		end

		if prompt and prompt.Parent and promptIsUsable(prompt, rootPart.Position) then
			prompt.MaxActivationDistance = TARGET_PROMPT_DISTANCE
			prompt.HoldDuration = 0

			print(string.format(
				"[Auto_SAE] Activation du prompt de l'œuf | UID: %s | HoldDuration: %.1f | MaxDistance: %.1f",
				record.Uid,
				prompt.HoldDuration,
				prompt.MaxActivationDistance
			))

			return fireprompt(prompt)
				and token == navigationToken
				and autoEnabled
		end

		task.wait(0.1)
	end

	warn(string.format("[Auto_SAE] Prompt %s inutilisable pour %s.", CARRY_PROMPT_NAME, record.Uid))
	return false
end

local statusLabel

local function setStatus(text, color)
	if statusLabel then
		statusLabel.Text = text
		statusLabel.TextColor3 = color
	end
end

local function runEgg(record, rate)
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
	setStatus(
		string.format("Cible : %s (%s $/s)", getAnimalName(record), formatNumber(rate)),
		Color3.fromRGB(255, 209, 82)
	)

	print(string.format(
		"[Auto_SAE] Cible sélectionnée | UID: %s | Animal: %s | Revenu: %s $/s | Départ: %s",
		record.Uid,
		getAnimalName(record),
		formatNumber(rate),
		formatPosition(savedStartPosition)
	))

	local promptActivated = false

	if waitForResetWall(token) then
		local eggDestination = Vector3.new(
			eggPosition.X,
			savedStartPosition.Y,
			eggPosition.Z
		)

		local prompt = waitForCarryPromptNearEgg(record, eggPosition, token)

		if not prompt then
			warn(string.format("[Auto_SAE] Prompt %s introuvable près de %s pour %s.", CARRY_PROMPT_NAME, formatPosition(eggPosition), record.Uid))
		else
			debugLog(
				"TARGET_PROMPT",
				"Prompt cible retenu | UID=%s | Path=%s | Enabled=%s | MaxDistanceAvant=%.1f | HoldDurationAvant=%.2f",
				record.Uid,
				prompt:GetFullName(),
				tostring(prompt.Enabled),
				prompt.MaxActivationDistance,
				prompt.HoldDuration
			)

			promptActivated = moveUntilPromptTriggered(
				eggDestination,
				prompt,
				token,
				"la zone de l'œuf"
			)
			task.wait(0.15)
		end
	end

	if promptActivated and token == navigationToken and autoEnabled then
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
	if not autoEnabled
		or type(record) ~= "table"
		or type(record.Uid) ~= "string"
		or record.State ~= SLOT_STATE then
		return false, nil
	end

	local rate = getRatePerSecond(record) or 0
	return rate >= minimumRatePerSecond, rate
end

local function processQueue()
	if workerRunning then
		return
	end

	workerRunning = true

	task.spawn(function()
		while autoEnabled and #recordQueue > 0 do
			local queueEntry = popHighestRateQueueEntry()
			local record = queueEntry.Record
			queuedUids[record.Uid] = nil

			local latestRecord = EggState.ReadFieldEgg(record.Uid)
			local eligible, rate = eligibleRecord(latestRecord)

			if eligible then
				activeUid = latestRecord.Uid

				if runEgg(latestRecord, rate) then
					successfulVersions[latestRecord.Uid] = versionKey(latestRecord)
				end

				activeUid = nil
			end
		end

		workerRunning = false

		if autoEnabled then
			setStatus(
				string.format("Actif : minimum %s $/s", formatNumber(minimumRatePerSecond)),
				Color3.fromRGB(96, 230, 145)
			)
		end
	end)
end

local function enqueueRecord(record)
	local eligible, rate = eligibleRecord(record)

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
		Rate = rate,
	})

	print(string.format(
		"[Auto_SAE] Cible ajoutée | UID: %s | Animal: %s | Revenu: %s $/s",
		uid,
		getAnimalName(record),
		formatNumber(rate)
	))

	processQueue()
end

local function handleRecord(record)
	logEgg(record)
	enqueueRecord(record)
end

local function handleSnapshot(snapshot)
	if type(snapshot) ~= "table" then
		return
	end

	for _, record in ipairs(snapshot.Records or {}) do
		handleRecord(record)
	end
end

EggState.FieldRefreshed:Connect(handleSnapshot)
EggState.FieldShifted:Connect(handleRecord)
EggState.FieldGone:Connect(function(uid)
	queuedUids[uid] = nil
	successfulVersions[uid] = nil
	loggedVersions[uid] = nil
end)

local function stopAutomation()
	autoEnabled = false
	navigationToken += 1
	recordQueue = {}
	queuedUids = {}
	activeUid = nil

	if activePrompt then
		activePrompt:InputHoldEnd()
		activePrompt = nil
	end

	local _, humanoid = getCharacterParts()
	if humanoid then
		humanoid:Move(Vector3.zero)
	end
end

player.CharacterRemoving:Connect(function()
	stopAutomation()
end)

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

	local toggleButton = Instance.new("TextButton")
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

	toggleButton.Activated:Connect(function()
		if autoEnabled then
			stopAutomation()
			toggleButton.Text = "START"
			toggleButton.BackgroundColor3 = Color3.fromRGB(48, 181, 102)
			input.TextEditable = true
			setStatus("Arrêté", Color3.fromRGB(255, 114, 114))
			print("[Auto_SAE] STOP.")
			return
		end

		local normalizedInput = string.gsub(input.Text, ",", ".")
		local billions = tonumber(normalizedInput)
		if not billions then
			setStatus("Valeur invalide : entre 0.1 et 999", Color3.fromRGB(255, 114, 114))
			return
		end

		billions = math.clamp(billions, MINIMUM_BILLIONS, MAXIMUM_BILLIONS)
		input.Text = tostring(billions)
		minimumRatePerSecond = billions * 1e9

		navigationToken += 1
		recordQueue = {}
		queuedUids = {}
		successfulVersions = {}
		activeUid = nil
		autoEnabled = true

		toggleButton.Text = "STOP"
		toggleButton.BackgroundColor3 = Color3.fromRGB(214, 73, 73)
		input.TextEditable = false
		setStatus(
			string.format("Actif : minimum %s $/s", formatNumber(minimumRatePerSecond)),
			Color3.fromRGB(96, 230, 145)
		)

		print(string.format(
			"[Auto_SAE] START | Minimum configuré : %s $/s.",
			formatNumber(minimumRatePerSecond)
		))

		handleSnapshot(EggState.ReadFieldEggs())
	end)

	return gui
end

createInterface()
handleSnapshot(EggState.ReadFieldEggs())
print("[Auto_SAE] Prêt : récupère uniquement les œufs au-dessus du minimum configuré.")
