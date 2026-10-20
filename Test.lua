local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EggState = require(ReplicatedStorage.Client.EggState)
local Assets = require(ReplicatedStorage.Data.Assets)

local eggCache = {}

local function getRarity(assetCategory)
	local asset = Assets.Directory[assetCategory]

	if asset and asset.Rarity then
		return asset.Rarity._id
	end

	return "Unknown"
end

local function getPosition(record)
	-- Position enregistrée dans EggState
	if typeof(record.BottomCFrame) == "CFrame" then
		return record.BottomCFrame.Position
	end

	-- Recherche du modèle 3D correspondant à l'UID
	local model = workspace:FindFirstChild(record.Uid, true)

	if model and model:IsA("Model") then
		return model:GetPivot().Position
	end

	return nil
end

local function logEgg(changeType, record)
	local position = getPosition(record)

	local positionText = position
		and string.format(
			"(%.1f, %.1f, %.1f)",
			position.X,
			position.Y,
			position.Z
		)
		or "Inconnue"

	local rarity = getRarity(record.AssetCategory)
	local biome = record.AreaId or "Unknown"
	local nest = record.NestId or "Unknown"

	print(string.format(
		"[EggChange] %s | UID: %s | Rarity: %s | Biome: %s | Nest: %s | Position: %s",
		changeType,
		record.Uid,
		rarity,
		biome,
		nest,
		positionText
	))
end

local function registerEgg(changeType, record)
	eggCache[record.Uid] = record
	logEgg(changeType, record)
end

-- Nouvelle liste complète reçue
EggState.FieldRefreshed:Connect(function(snapshot)
	table.clear(eggCache)

	for _, record in ipairs(snapshot.Records or {}) do
		registerEgg("REFRESHED", record)
	end
end)

-- Œuf apparu, déplacé ou modifié
EggState.FieldShifted:Connect(function(record)
	registerEgg("SHIFTED", record)
end)

-- Œuf retiré du terrain
EggState.FieldGone:Connect(function(uid)
	local record = eggCache[uid]

	if record then
		logEgg("GONE", record)
		eggCache[uid] = nil
	else
		print(string.format(
			"[EggChange] GONE | UID: %s | Rarity: Unknown | Biome: Unknown | Nest: Unknown | Position: Inconnue",
			uid
		))
	end
end)

-- Affiche les œufs déjà présents au lancement
local snapshot = EggState.ReadFieldEggs()

for _, record in ipairs(snapshot.Records or {}) do
	registerEgg("INITIAL", record)
end
