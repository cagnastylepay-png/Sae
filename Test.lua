-- Auto_SAE v2. Official EggState API; one client script.
-- The live game must provide ReplicatedStorage.Client/Data/Shared.
-- Display range is cosmetic: server carry validation remains authoritative.
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local player = Players.LocalPlayer
assert(player, "Auto_SAE doit etre execute sur le client")

local CONFIG = {
	Debug = true,
	ProgressInterval = 0.5,
	MoveRefresh = 0.1,
	ScanInterval = 0.25,
	GrabDistance = 2,
	ReturnDistance = 3,
	TargetPromptDistance = 100,
	IsolateOtherEggPrompts = true,
	RequestTimeout = 10,
	RequestInterval = 1,
	MaxCarryAttempts = 3,
	ClaimTimeout = 12,
	NoMovementTimeout = 10,
	FailedTargetCooldown = 10,
}
local MINIMUM_BILLIONS, MAXIMUM_BILLIONS, DEFAULT_BILLIONS = 0.1, 999, 2
local SLOT_STATE = "Slot"
local EggState, Assets, EggRecords, AssetEarnings, SlotIdentity, GuardGeometry, Save
local ready, destroyed, autoEnabled = false, false, false
local generation = 0
local minimumRatePerSecond = DEFAULT_BILLIONS * 1e9
local records, loggedVersions, cooldowns = {}, {}, {}
local prompts, lifetimeConnections = {}, {}
local currentCycle, safeHome
local inFlightRequest = shared.__AutoSAERemoteLock
local statusLabel, toggleButton, minimumInput
local sequence = 0
local renderControls
local stopAutomation

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


local function isEggPrompt(prompt)
	if not prompt:IsA("ProximityPrompt") or prompt.Name ~= "CarryAreaEgg" then return false end
	local ancestor = prompt.Parent
	while ancestor and ancestor ~= Workspace do
		if ancestor.Name == "SmartPromptPart" or ancestor.Name == "AreaEggSlotsClient" then
			return true
		end
		ancestor = ancestor.Parent
	end
	return false
end

local function promptPosition(prompt)
	local parent = prompt.Parent
	if not parent then return nil end
	if parent:IsA("Attachment") then return parent.WorldPosition end
	if parent:IsA("BasePart") then return parent.Position end
	if parent:IsA("Model") then return parent:GetPivot().Position end
	return nil
end

local function enforcePrompt(prompt, entry)
	local ctx = currentCycle
	if entry.writing or not ctx or not prompt.Parent then return end
	local target = prompt == ctx.prompt
	if not target and not CONFIG.IsolateOtherEggPrompts then return end
	if not entry.saved then
		entry.saved = {
			Enabled = prompt.Enabled,
			MaxActivationDistance = prompt.MaxActivationDistance,
			HoldDuration = prompt.HoldDuration,
		}
	end
	entry.writing = true
	if target then
		if prompt.MaxActivationDistance ~= CONFIG.TargetPromptDistance then
			prompt.MaxActivationDistance = CONFIG.TargetPromptDistance
		end
		if prompt.HoldDuration ~= 0 then prompt.HoldDuration = 0 end
	else
		if prompt.Enabled then prompt.Enabled = false end
	end
	entry.writing = false
end

local function restorePrompts()
	for prompt, entry in pairs(prompts) do
		if entry.saved then
			entry.writing = true
			if prompt.Parent then
				prompt.Enabled = entry.saved.Enabled
				prompt.MaxActivationDistance = entry.saved.MaxActivationDistance
				prompt.HoldDuration = entry.saved.HoldDuration
			end
			entry.writing = false
			entry.saved = nil
		end
	end
	log("PROMPTS_RESTORED", "Proprietes externes restaurees")
end

local function registerPrompt(prompt)
	if destroyed or prompts[prompt] or not isEggPrompt(prompt) then return end
	local entry = {writing = false, connections = {}, overwrites = 0}
	prompts[prompt] = entry
	for _, property in ipairs({"Enabled", "MaxActivationDistance", "HoldDuration"}) do
		table.insert(entry.connections, prompt:GetPropertyChangedSignal(property):Connect(function()
			if entry.writing then return end
			local expected
			local ctx = currentCycle
			if ctx and ctx.prompt == prompt then
				if property == "MaxActivationDistance" then expected = CONFIG.TargetPromptDistance end
				if property == "HoldDuration" then expected = 0 end
			elseif ctx and CONFIG.IsolateOtherEggPrompts and property == "Enabled" then
				expected = false
			end
			-- Deferred signals may arrive after our writing flag has been cleared.
			if entry.saved and (expected == nil or prompt[property] ~= expected) then
				entry.saved[property] = prompt[property]
				entry.overwrites += 1
			end
			enforcePrompt(prompt, entry)
		end))
	end
	for _, event in ipairs({"PromptShown", "PromptHidden", "Triggered"}) do
		table.insert(entry.connections, prompt[event]:Connect(function(value)
			local ctx = currentCycle
			if not ctx or ctx.prompt ~= prompt then return end
			if event == "PromptShown" then ctx.promptShown = true end
			if event == "PromptHidden" then ctx.promptShown = false end
			log("PROMPT_" .. string.upper(event), "Value=%s Enabled=%s Hold=%.2f Max=%.1f",
				tostring(value), tostring(prompt.Enabled), prompt.HoldDuration, prompt.MaxActivationDistance)
			-- These local events are diagnostics. They never confirm ownership.
		end))
	end
	table.insert(entry.connections, prompt.Destroying:Connect(function()
		for _, connection in ipairs(entry.connections) do connection:Disconnect() end
		prompts[prompt] = nil
		if currentCycle and currentCycle.prompt == prompt then
			currentCycle.prompt = nil
			log("PROMPT_DESTROYED", "La prise par UID reste disponible")
		end
	end))
	enforcePrompt(prompt, entry)
	log("PROMPT_REGISTERED", "%s Enabled=%s", prompt:GetFullName(), tostring(prompt.Enabled))
end

local function startPromptRegistry()
	-- One initial scan restricted to official egg roots, then event-driven updates.
	local folder = Workspace:FindFirstChild("AreaEggSlotsClient")
	if folder then
		for _, instance in ipairs(folder:GetDescendants()) do registerPrompt(instance) end
	end
	for _, child in ipairs(Workspace:GetChildren()) do
		if child.Name == "SmartPromptPart" then
			for _, instance in ipairs(child:GetDescendants()) do registerPrompt(instance) end
		end
	end
	connect(Workspace.DescendantAdded, function(instance)
		if instance:IsA("ProximityPrompt") and instance.Name == "CarryAreaEgg" then
			task.defer(registerPrompt, instance)
		end
	end)
end

local function findTargetPrompt(ctx)
	if ctx.prompt and ctx.prompt.Parent then return end
	local best, bestDistance, secondDistance = nil, 18, math.huge
	for prompt in pairs(prompts) do
		local position = promptPosition(prompt)
		if position then
			local distance = distanceXZ(position, ctx.eggPosition)
			if distance < bestDistance then
				secondDistance, bestDistance, best = best and bestDistance or math.huge, distance, prompt
			elseif distance < secondDistance then
				secondDistance = distance
			end
		end
	end
	if best and secondDistance - bestDistance > 0.5 then
		ctx.prompt = best
		local entry = prompts[best]
		if entry.saved then
			entry.writing = true
			best.Enabled = entry.saved.Enabled
			entry.writing = false
		end
		enforcePrompt(best, prompts[best])
		log("TARGET_PROMPT", "%s OffsetXZ=%.2f | prise serveur ciblee par UID",
			best:GetFullName(), bestDistance)
	end
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
		ctx.sawCarry = true
		return true
	end
	return ctx.remoteAccepted == true
end

local function requestCarry(ctx)
	if inFlightRequest and not inFlightRequest.done then return end
	if ctx.attempts >= CONFIG.MaxCarryAttempts then return end
	local request = {uid = ctx.uid, started = os.clock(), done = false}
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
		local slotKey
		if SlotIdentity.LooksLikeFirstAreaUid(ctx.uid) then
			slotKey = SlotIdentity.SlotKey(ctx.record.AreaId, ctx.record.NestId)
		end
		local ok, accepted, reason = pcall(EggState.CarryFieldEgg, ctx.uid, slotKey)
		request.done = true
		request.accepted = ok and accepted == true
		request.reason = ok and reason or tostring(accepted)
		-- A timed-out InvokeServer may finish later. It never controls a newer cycle.
		log("CARRY_REPLY", "UID=%s CallOK=%s Accepted=%s Reason=%s Latence=%.3fs SessionActive=%s",
			ctx.uid, tostring(ok), tostring(request.accepted), tostring(request.reason),
			os.clock() - request.started, tostring(validCycle(ctx)))
		if not validCycle(ctx) then return end
		ctx.remoteAccepted = request.accepted
		ctx.denial = request.reason
	end)
end

local function moveLoop(ctx, destination, phase)
	local _, humanoid, root = getCharacterParts()
	if not humanoid or not root then return false, "personnage absent" end
	local started, lastCommand, lastLog = os.clock(), -math.huge, -math.huge
	local lastMoved, lastPosition = started, root.Position
	local distance = distanceXZ(root.Position, destination)
	local timeout = math.clamp(distance / math.max(humanoid.WalkSpeed, 1) * 4 + 15, 15, 150)
	setPhase(ctx, phase, phase == "RETURN" and "Retour vers la zone sure" or "Approche : " .. getAnimalName(ctx.record))
	while true do
		local valid, reason = validCycle(ctx)
		if not valid then return false, reason end
		local now = os.clock()
		distance = distanceXZ(root.Position, destination)
		if distanceXZ(lastPosition, root.Position) >= 0.5 then
			lastMoved, lastPosition = now, root.Position
		end
		local carry = readCarry()
		if phase == "APPROACH" then
			if updateCarryEvidence(ctx) then
				stopMovement()
				log("CARRY_CONFIRMED", "ReponseServeur=%s TransportUID=%s PossessionUID=%s",
					tostring(ctx.remoteAccepted), tostring(ctx.sawCarry), tostring(ctx.claimed))
				return true
			end
			if carry and carry.IsCarrying and carry.Uid ~= ctx.uid then
				return false, "un autre oeuf est deja transporte"
			end
			local latest, readOk = readField(ctx.uid)
			if readOk and (not latest or latest.State ~= SLOT_STATE) then
				local pending = inFlightRequest and inFlightRequest.uid == ctx.uid and not inFlightRequest.done
				if not pending then
					-- Allow replication to deliver CarryChanged before treating the egg as lost.
					ctx.missingSince = ctx.missingSince or now
					if now - ctx.missingSince > 1.5 then return false, "oeuf retire sans prise confirmee" end
				end
			else
				ctx.missingSince = nil
			end
			if now - (ctx.lastPromptSearch or -math.huge) >= 0.5 then
				findTargetPrompt(ctx)
				ctx.lastPromptSearch = now
			end
			if distance <= CONFIG.GrabDistance then
				stopMovement()
				local pending = inFlightRequest and not inFlightRequest.done
				if not pending and now - ctx.lastRequest >= CONFIG.RequestInterval then
					if ctx.attempts >= CONFIG.MaxCarryAttempts then
						return false, "prise refusee : " .. tostring(ctx.denial)
					end
					requestCarry(ctx)
				end
				lastMoved = now
			end
		elseif distance <= CONFIG.ReturnDistance then
			stopMovement()
			return true
		end
		if phase == "APPROACH" and inFlightRequest and not inFlightRequest.done
			and now - inFlightRequest.started > CONFIG.RequestTimeout then
			return false, "requete serveur sans reponse ; attente de reconciliation"
		end
		if now - started > timeout then return false, "delai de deplacement depasse" end
		if now - lastMoved > CONFIG.NoMovementTimeout then return false, "deplacement bloque" end
		if distance > (phase == "APPROACH" and CONFIG.GrabDistance or CONFIG.ReturnDistance)
			and now - lastCommand >= CONFIG.MoveRefresh then
			humanoid:MoveTo(destination)
			lastCommand = now
		end
		if now - lastLog >= CONFIG.ProgressInterval then
			lastLog = now
			local overwriteCount = 0
			for _, entry in pairs(prompts) do overwriteCount += entry.overwrites end
			log("MOVE_PROGRESS", "Phase=%s Pos=%s DistanceXZ=%.2f WalkSpeed=%.1f VitesseReelle=%.1f Safe=%s CarryUID=%s Requetes=%d Prompt=%s Reecritures=%d",
				phase, formatPosition(root.Position), distance, humanoid.WalkSpeed,
				root.AssemblyLinearVelocity.Magnitude, tostring(isSafe(root.Position)),
				carry and tostring(carry.Uid) or "?", ctx.attempts, tostring(ctx.prompt ~= nil), overwriteCount)
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
	stopMovement()
	restorePrompts()
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
	}
	currentCycle = ctx
	for prompt, entry in pairs(prompts) do enforcePrompt(prompt, entry) end
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
			grabbed, grabReason = moveLoop(ctx, destination, "APPROACH")
		end
		if not validCycle(ctx) then return false, "annule" end
		if not grabbed and inFlightRequest and not inFlightRequest.done then
			return false, grabReason or "requete serveur encore en cours"
		end
		local returned, returnReason = moveLoop(ctx, ctx.home, "RETURN")
		if not returned then return false, returnReason end
		local _, _, currentRoot = getCharacterParts()
		if not currentRoot or isSafe(currentRoot.Position) ~= true then
			return false, "retour termine mais ligne safe non franchie"
		end
		if not grabbed then return false, grabReason end
		return waitForClaim(ctx)
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
					or string.find(tostring(reason), "attribution", 1, true) then
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
		if ctx and state.IsCarrying and state.Uid == ctx.uid then ctx.sawCarry = true end
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
	startPromptRegistry()
	snapshot(EggState.ReadFieldEggs())
	ready = true
	setStatus("Pret : demarre depuis la zone sure", Color3.fromRGB(96, 230, 145))
	log("READY", "Build=2 | CarryFieldEgg/ReadOwnedEgg | AffichageCible=%d | DistancePrise=%d",
		CONFIG.TargetPromptDistance, CONFIG.GrabDistance)
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
	for prompt, entry in pairs(prompts) do
		for _, connection in ipairs(entry.connections) do connection:Disconnect() end
		prompts[prompt] = nil
	end
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

