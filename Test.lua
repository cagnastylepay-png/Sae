local CollectionService = game:GetService("CollectionService")
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
local APPROACH_DISTANCE = 5
local PROMPT_SEARCH_RADIUS = 14
local PROMPT_SEARCH_ATTEMPTS = 40

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

local function getTreadmillPosition(treadmill)
	if not treadmill or not treadmill.Parent then
		return nil
	end

	local slot = string.match(treadmill.Name, "^TreadmillRender_(.+)$")
	local plots = Workspace:FindFirstChild("Plots")
	local plot = slot and plots and plots:FindFirstChild(slot)
	local treadmillBottom = plot and plot:FindFirstChild("TreadmillBottom")

	if treadmillBottom and treadmillBottom:IsA("BasePart") then
		return treadmillBottom.Position + Vector3.new(0, 0.25, 0)
	end

	if treadmill:IsA("BasePart") then
		return treadmill.Position + treadmill.CFrame.UpVector * (treadmill.Size.Y * 0.5 + 0.25)
	end

	if treadmill:IsA("Model") then
		local success, boundingCFrame, boundingSize = pcall(treadmill.GetBoundingBox, treadmill)

		if success then
			return boundingCFrame.Position + Vector3.new(0, boundingSize.Y * 0.5 + 0.25, 0)
		end
	end

	local root = treadmill:FindFirstChild("Root", true)

	if root and root:IsA("BasePart") then
		return root.Position + root.CFrame.UpVector * (root.Size.Y * 0.5 + 0.25)
	end

	local handle = treadmill:FindFirstChild("Handle", true)

	if handle and handle:IsA("BasePart") then
		return handle.Position + handle.CFrame.UpVector * (handle.Size.Y * 0.5 + 0.25)
	end

	return nil
end

local function findActiveTreadmill(rootPosition)
	local bestTreadmill
	local bestDistance = math.huge

	for _, treadmill in ipairs(CollectionService:GetTagged("ActiveTreadmill")) do
		if not treadmill:IsDescendantOf(Workspace) then
			continue
		end

		local position = getTreadmillPosition(treadmill)
		if not position then
			continue
		end

		local distance = (
			Vector3.new(position.X, 0, position.Z)
			- Vector3.new(rootPosition.X, 0, rootPosition.Z)
		).Magnitude

		if distance < bestDistance then
			bestDistance = distance
			bestTreadmill = treadmill
		end
	end

	return bestTreadmill
end

local function resolveTreadmillReturnPosition(preferredTreadmill, rootPosition)
	local treadmill = preferredTreadmill

	if not treadmill or not treadmill.Parent then
		treadmill = findActiveTreadmill(rootPosition)
	end

	if not treadmill then
		return nil, nil
	end

	return getTreadmillPosition(treadmill), treadmill
end

local function calculateApproachGoal(rootPosition, eggPosition)
	local direction = Vector3.new(
		rootPosition.X - eggPosition.X,
		0,
		rootPosition.Z - eggPosition.Z
	)

	if direction.Magnitude < 0.1 then
		direction = Vector3.new(0, 0, 1)
	else
		direction = direction.Unit
	end

	return eggPosition + direction * APPROACH_DISTANCE
end

local function walkPath(destination, token, destinationLabel)
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
		warn("[Auto_SAE] Calcul du chemin impossible:", errorMessage)
		return false
	end

	if path.Status ~= Enum.PathStatus.Success then
		warn(string.format(
			"[Auto_SAE] Aucun chemin valide vers %s à %s.",
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
			warn(string.format("[Auto_SAE] Trajet interrompu vers %s.", destinationLabel))
			return false
		end
	end

	return token == navigationToken
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
	if not prompt or not prompt.Parent or not prompt.Enabled then
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

local function returnToTreadmill(treadmill, token)
	local _, _, rootPart = getCharacterParts()

	if not rootPart then
		return false
	end

	local returnPosition, resolvedTreadmill = resolveTreadmillReturnPosition(
		treadmill,
		rootPart.Position
	)

	if not returnPosition or not resolvedTreadmill then
		warn("[Auto_SAE] Le tapis ActiveTreadmill est introuvable pour le retour.")
		return false
	end

	print(string.format(
		"[Auto_SAE] Retour vers %s à %s.",
		resolvedTreadmill:GetFullName(),
		formatPosition(returnPosition)
	))

	local returned = walkPath(returnPosition, token, "le tapis roulant")

	if returned then
		print("[Auto_SAE] Retour sur le tapis roulant terminé.")
	end

	return returned
end

local function runEgg(record, rarity)
	local _, humanoid, rootPart = getCharacterParts()

	if not humanoid or not rootPart then
		warn("[Auto_SAE] Personnage indisponible pour l'œuf", record.Uid)
		return false
	end

	local treadmill = findActiveTreadmill(rootPart.Position)

	if not treadmill then
		warn("[Auto_SAE] Aucun objet portant le tag ActiveTreadmill n'a été trouvé.")
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
		"[Auto_SAE] Egg détecté | UID: %s | Rareté: %s | Position: %s",
		record.Uid,
		rarity,
		formatPosition(eggPosition)
	))

	humanoid.Jump = true
	humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	task.wait(0.15)

	local promptActivated = false
	local _, _, currentRoot = getCharacterParts()

	if currentRoot and token == navigationToken then
		local approachGoal = calculateApproachGoal(currentRoot.Position, eggPosition)

		if walkPath(approachGoal, token, "l'œuf") then
			print(string.format("[Auto_SAE] Arrivé près de l'œuf %s.", record.Uid))
			promptActivated = activateEggPrompt(record, eggPosition, token)
			task.wait(0.15)
		end
	end

	if token == navigationToken then
		returnToTreadmill(treadmill, token)
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
			local record = table.remove(recordQueue, 1)
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
	table.insert(recordQueue, record)

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
print("[Auto_SAE] Actif : EggState surveille Divine, Eternal et Secret.")
