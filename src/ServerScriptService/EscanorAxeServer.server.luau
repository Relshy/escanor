--[[
Author(s)    @sillyrelshy
Date         14/07/26
Version      1.1.0
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local AXE_NAME = "EscanorAxe"
local GRIP_C0 = CFrame.new(0, -1, 0, 0, 1, 0, 0, 0, -1, -1, 0, 0)
local DETACH_THRESHOLD = 4 -- studs; if the handle drifts past this, rebuild

local systemFolder = ReplicatedStorage:WaitForChild("CruelSun")
local assetsFolder = systemFolder:WaitForChild("Assets")
local remotesFolder = systemFolder:WaitForChild("Remotes")

local hitRemote = remotesFolder:WaitForChild("EscanorM1Hit")
local function template() return assetsFolder:FindFirstChild(AXE_NAME) end

-- Clone + weld a fresh axe onto the character's right arm.
local function buildAxe(character)
	local tmpl = template()
	if not tmpl then return end
	local rightArm = character:FindFirstChild("Right Arm") or character:FindFirstChild("RightHand")
	if not rightArm then return end

	local oldGrip = rightArm:FindFirstChild("RightGrip"); if oldGrip then oldGrip:Destroy() end
	local prev = character:FindFirstChild(AXE_NAME); if prev then prev:Destroy() end
	local prevMotor = rightArm:FindFirstChild("AxeGrip"); if prevMotor then prevMotor:Destroy() end

	local axe = tmpl:Clone()
	local handle = axe.PrimaryPart or axe:FindFirstChild("Handle")
	if not handle then axe:Destroy() return end
	for _, d in ipairs(axe:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = false; d.CanCollide = false; d.CanQuery = false; d.Massless = true
			if d ~= handle then
				local w = Instance.new("Weld")
				w.Name = "EscanorWeld"; w.Part0 = handle; w.Part1 = d
				w.C0 = handle.CFrame:Inverse() * d.CFrame
				w.Parent = handle
			end
		end
	end
	axe.Parent = character

	local motor = Instance.new("Motor6D")
	motor.Name = "AxeGrip"; motor.Part0 = rightArm; motor.Part1 = handle; motor.C0 = GRIP_C0
	motor.Parent = rightArm
end

-- Give the axe and keep it attached (rebuild if it ever flings off).
local function manageAxe(character)
	buildAxe(character)
	task.spawn(function()
		while character.Parent do
			task.wait(0.5)
			local hum = character:FindFirstChildOfClass("Humanoid")
			if not hum or hum.Health <= 0 then continue end
			local arm = character:FindFirstChild("Right Arm") or character:FindFirstChild("RightHand")
			local axe = character:FindFirstChild(AXE_NAME)
			local handle = axe and axe:FindFirstChild("Handle")
			if not arm then continue end
			if not handle then
				buildAxe(character)
			elseif (handle.Position - arm.Position).Magnitude > DETACH_THRESHOLD then
				buildAxe(character) -- detached: snap a fresh one back on
			end
		end
	end)
end

local function onCharacter(c) task.defer(manageAxe, c) end
local function onPlayer(p)
	if p.Character then onCharacter(p.Character) end
	p.CharacterAdded:Connect(onCharacter)
end
Players.PlayerAdded:Connect(onPlayer)
for _, p in ipairs(Players:GetPlayers()) do onPlayer(p) end

-- Client-triggered reattach: the OWNER client sees flings the server doesn't,
-- so it asks us to rebuild the welded axe (which then replicates back attached).
local reattachRemote = remotesFolder:WaitForChild("EscanorReattach")
local lastReattach = {}
reattachRemote.OnServerEvent:Connect(function(player)
	local now = os.clock()
	if lastReattach[player] and now - lastReattach[player] < 0.4 then return end
	lastReattach[player] = now
	local character = player.Character
	if character and character:FindFirstChildOfClass("Humanoid") then
		buildAxe(character)
	end
end)

-- ================= MELEE DAMAGE (server-authoritative) =================
local HIT_SIZE = Vector3.new(8, 7, 9)
local HIT_OFFSET = -4.5
local CASTING_ATTRIBUTE = "CruelSunCasting"
local lastHitAt = {}

local hitSoundTemplate = workspace:FindFirstChild("Super Smash Bros. 64 - Moderate Sword Hit Sound")

-- Cloned per landed hit rather than reused: a single swing can overlap-hit
-- multiple targets, and reusing one Sound instance would restart playback on
-- the second hit and cut off the first. The server plays it (not the client)
-- because the server is what actually knows a hit connected; playing here
-- means every nearby player hears it exactly once via normal replication.
local function playHitSound(atPart)
	if not hitSoundTemplate or not atPart then return end
	local sound = hitSoundTemplate:Clone()
	sound.Parent = atPart
	sound:Play()
	Debris:AddItem(sound, 3)
end

hitRemote.OnServerEvent:Connect(function(player)
	-- The client guard protects animation state; this server check protects
	-- damage authority when an altered client fires the M1 remote mid-cast.
	if player:GetAttribute(CASTING_ATTRIBUTE) == true then return end
	local character = player.Character
	if not character then return end
	local hum = character:FindFirstChildOfClass("Humanoid")
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hum or hum.Health <= 0 or not hrp then return end
	local now = os.clock()
	local tmpl = template()
	local cd = (tmpl and tmpl:GetAttribute("InputCooldown")) or 0.55
	if lastHitAt[player] and now - lastHitAt[player] < cd * 0.8 then return end
	lastHitAt[player] = now
	local damage = (tmpl and tmpl:GetAttribute("Damage")) or 8
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	local boxCFrame = hrp.CFrame * CFrame.new(0, 0, HIT_OFFSET)
	local parts = workspace:GetPartBoundsInBox(boxCFrame, HIT_SIZE, params)
	local seen = {}
	for _, part in ipairs(parts) do
		local model = part:FindFirstAncestorOfClass("Model")
		local th = model and model:FindFirstChildOfClass("Humanoid")
		if th and th ~= hum and not seen[th] and th.Health > 0 then
			seen[th] = true; th:TakeDamage(damage)
			playHitSound(model.PrimaryPart or part)
		end
	end
end)
Players.PlayerRemoving:Connect(function(p) lastHitAt[p] = nil end)
