--[[
	CruelSunImpactRocks.client.luau
	Split out of the charged-impact ability (CruelSunClient) so the core
	ability file stays focused on its own mechanics and does not carry the
	external RockModule dependency.

	Listens on ReplicatedStorage.CruelSun.Signals.Impact, which the ability fires
	at every impact impact with (worldPosition, hitboxRadius, chargePower,
	sizeMult). This script snaps the debris to the ground under the impact and
	asks the open-source RockModule for a crater ring plus flying debris.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local player = Players.LocalPlayer
local signals = ReplicatedStorage:WaitForChild("CruelSun"):WaitForChild("Signals")
local impactSignal = signals:WaitForChild("Impact")

-- Rock tuning lives here now, next to the code that uses it, rather than in the
-- ability's config table.
local CFG = {
	CraterRadiusFactor = 0.85, -- crater ring radius relative to the hitbox radius
	CraterMinRocks = 8,
	CraterMaxRocks = 12,
	DebrisBase = 10, -- flying rocks at zero charge
	DebrisChargeBonus = 10, -- extra flying rocks at full charge
}

-- Load the open-source RockModule (Workspace["RockModule V1.0"].RockModule).
-- If it is missing we simply never spawn rocks; the ability itself is unaffected.
local RockModule
do
	local folder = workspace:WaitForChild("RockModule V1.0", 10)
	local mod = folder and folder:FindFirstChild("RockModule")
	if mod then
		local ok, result = pcall(require, mod)
		if ok then
			RockModule = result
		else
			warn("CruelSunImpactRocks: RockModule failed to load:", result)
		end
	end
end

local function spawnRocks(pos, hitboxRadius, chargePower, sizeMult)
	if not RockModule then return end
	sizeMult = sizeMult or 1
	chargePower = chargePower or 0

	-- Snap the rock origin to the ground below the impact; skip rocks for mid-air
	-- explosions so debris never hangs in the sky. Humanoids/debris are excluded
	-- so a impact on a dummy doesn't ring at torso height.
	local rockParams = RaycastParams.new()
	rockParams.FilterType = Enum.RaycastFilterType.Exclude
	local exclude = {}
	if player.Character then table.insert(exclude, player.Character) end
	local debrisFolder = workspace:FindFirstChild("Debris")
	if debrisFolder then table.insert(exclude, debrisFolder) end
	for _, inst in ipairs(CollectionService:GetTagged("RockModuleIgnore")) do
		table.insert(exclude, inst)
	end
	rockParams.FilterDescendantsInstances = exclude

	local groundRay = workspace:Raycast(pos + Vector3.new(0, 2, 0), Vector3.new(0, -60, 0), rockParams)
	if not groundRay then
		return -- no ground within 60 studs below the impact: air burst, no rocks
	end

	local rockCenter = CFrame.new(groundRay.Position + Vector3.new(0, 3, 0))
	local ok, err = pcall(function()
		-- ring radius follows hitboxRadius (already scaled by sizeMult); rock counts
		-- and debris sizes scale too so big impacts throw big rocks
		RockModule.Crater(rockCenter, hitboxRadius * CFG.CraterRadiusFactor, math.floor(CFG.CraterMinRocks * sizeMult), math.floor(CFG.CraterMaxRocks * sizeMult), true)
		local debrisCount = math.floor((CFG.DebrisBase + CFG.DebrisChargeBonus * chargePower) * sizeMult)
		RockModule.Explosion(rockCenter, debrisCount, 0.5 * sizeMult, (2 + chargePower * 1.5) * sizeMult, false)
	end)
	if not ok then
		warn("CruelSunImpactRocks: RockModule effects failed:", err)
	end
end

impactSignal.Event:Connect(function(pos, hitboxRadius, chargePower, sizeMult)
	task.spawn(spawnRocks, pos, hitboxRadius, chargePower, sizeMult)
end)
