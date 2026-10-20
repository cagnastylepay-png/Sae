local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local SLOT_STATE = "Slot"
local CARRY_PROMPT_NAME = "CarryAreaEgg"
local PROMPT_SEARCH_RADIUS = 18
local PROMPT_SEARCH_ATTEMPTS = 40
local MOVE_ARRIVAL_DISTANCE = 0.25
local MOVE_FINAL_CORRECTION_DISTANCE = 1.5
local MOVE_REFRESH_SECONDS = 0.05
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

local function popNearestQueueEntry()
	local _, _, rootPart = getCharacterParts()
	if not rootPart then
		return table.remove(recordQueue, 1)
	end

	local origin = rootPart.Position
	local nearestIndex = 1
	local nearestDistance = math.huge

	for index, queueEntry in ipairs(recordQueue) do
		local position = getEggPosition(queueEntry.Record)
		local distance = position and (position - origin).Magnitude or math.huge

		if distance < nearestDistance then
			nearestDistance = distance
			nearestIndex = index
		end
	end

	return table.remove(recordQueue, nearestIndex)
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
		"[Auto_SAE] Déplacement direct vers %s : %s.",
		destinationLabel,
		formatPosition(destination)
	))

	local lastMoveCommand = -math.huge

	while token == navigationToken and autoEnabled do
		if humanoid.Health <= 0 or not rootPart.Parent then
			return false
		end

		local offset = destination - rootPart.Position
		local horizontalOffset = Vector3.new(offset.X, 0, offset.Z)
		local distance = horizontalOffset.Magnitude

		if distance <= MOVE_ARRIVAL_DISTANCE then
			humanoid:Move(Vector3.zero)
			return true
		end

		if distance <= MOVE_FINAL_CORRECTION_DISTANCE then
			local rotation = rootPart.CFrame - rootPart.Position
			local verticalVelocity = rootPart.AssemblyLinearVelocity.Y

			humanoid:Move(Vector3.zero)
			rootPart.AssemblyLinearVelocity = Vector3.new(0, verticalVelocity, 0)
			rootPart.CFrame = CFrame.new(
				destination.X,
				rootPart.Position.Y,
				destination.Z
			) * rotation
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

	if configureEggPrompt(cachedPrompt)
		and cachedPrompt.Enabled
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
		if not configureEggPrompt(prompt) or not prompt.Enabled then
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
	for _ = 1, PROMPT_SEARCH_ATTEMPTS do
		if token ~= navigationToken or not autoEnabled then
			return nil
		end

		local prompt = findCarryPromptNearEgg(record, eggPosition)
		if prompt then
			return prompt
		end

		task.wait(0.1)
	end

	return nil
end


local function activateEggPrompt(record, prompt, token)
	for _ = 1, PROMPT_SEARCH_ATTEMPTS do
		if token ~= navigationToken or not autoEnabled then
			return false
		end

		local _, _, rootPart = getCharacterParts()
		if not rootPart then
			return false
		end

		if prompt and prompt.Parent and promptIsUsable(prompt, rootPart.Position) then
			print(string.format(
				"[Auto_SAE] Activation du prompt de l'œuf | UID: %s | HoldDuration: %.1f | MaxDistance: %.1f",
				record.Uid,
				prompt.HoldDuration,
				prompt.MaxActivationDistance
			))

			return fireproximityprompt(prompt)
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

		if moveDirect(eggDestination, token, "la zone de l'œuf") then
			local prompt = waitForCarryPromptNearEgg(record, eggPosition, token)

			if not prompt then
				warn(string.format("[Auto_SAE] Prompt %s introuvable près de %s pour %s.", CARRY_PROMPT_NAME, formatPosition(eggPosition), record.Uid))
			else
				promptActivated = activateEggPrompt(record, prompt, token)
				task.wait(0.15)
			end
		end
	end

	if token == navigationToken and autoEnabled then
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
			local queueEntry = popNearestQueueEntry()
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
