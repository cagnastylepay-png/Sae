local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")

local Auto_SAE = {}

local LOGGED_RARITIES = {
	Divine = true,
	Eternal = true,
	Secret = true,
}

local APPROACH_DISTANCE = 2
local navigationToken = 0

local function formatPosition(position)
	return string.format(
		"(%.1f, %.1f, %.1f)",
		position.X,
		position.Y,
		position.Z
	)
end

local function getCharacterParts()
	local player = Players.LocalPlayer
	if not player then
		return nil, nil
	end

	local character = player.Character
	if not character then
		return nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")

	return humanoid, rootPart
end

local function calculateGoal(rootPosition, eggPosition)
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

local function followPath(eggPosition, token)
	local humanoid, rootPart = getCharacterParts()
	if not humanoid or not rootPart then
		warn("[Auto_SAE] Personnage ou HumanoidRootPart introuvable.")
		return
	end

	local goalPosition = calculateGoal(rootPart.Position, eggPosition)

	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
		AgentCanClimb = true,
		WaypointSpacing = 4,
	})

	local success, errorMessage = pcall(function()
		path:ComputeAsync(rootPart.Position, goalPosition)
	end)

	if not success then
		warn("[Auto_SAE] Calcul du chemin impossible:", errorMessage)
		return
	end

	if path.Status ~= Enum.PathStatus.Success then
		warn(string.format(
			"[Auto_SAE] Aucun chemin valide vers %s.",
			formatPosition(eggPosition)
		))
		return
	end

	for _, waypoint in ipairs(path:GetWaypoints()) do
		if token ~= navigationToken then
			return
		end

		if humanoid.Health <= 0 or not rootPart.Parent then
			return
		end

		if waypoint.Action == Enum.PathWaypointAction.Jump then
			humanoid.Jump = true
		end

		humanoid:MoveTo(waypoint.Position)

		local reached = humanoid.MoveToFinished:Wait()
		if not reached then
			warn("[Auto_SAE] Trajet interrompu avant l'œuf.")
			return
		end
	end

	print(string.format(
		"[Auto_SAE] Arrivé près de l'œuf à %s.",
		formatPosition(eggPosition)
	))
end

function Auto_SAE.OnEggDetected(rarity, position)
	if not LOGGED_RARITIES[rarity] then
		return false
	end

	if typeof(position) == "CFrame" then
		position = position.Position
	end

	if typeof(position) ~= "Vector3" then
		warn("[Auto_SAE] Position invalide pour l'œuf", rarity)
		return false
	end

	print(string.format(
		"[Auto_SAE] Egg detected | Rarity: %s | Position: %s",
		rarity,
		formatPosition(position)
	))

	navigationToken += 1
	local token = navigationToken

	task.spawn(followPath, position, token)

	return true
end

function Auto_SAE.CancelNavigation()
	navigationToken += 1

	local humanoid, rootPart = getCharacterParts()
	if humanoid and rootPart then
		humanoid:MoveTo(rootPart.Position)
	end
end

return table.freeze(Auto_SAE)
