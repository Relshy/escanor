--[[
Author(s)    Janss
Date         12/07/26
Version      1.0.0
]]



--!strict
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")


local systemFolder  = ReplicatedStorage:WaitForChild("CruelSun")
local remotesFolder = systemFolder:WaitForChild("Remotes")

local CONFIG    = require(systemFolder:WaitForChild("Configuration"))
local hitRemote = remotesFolder:WaitForChild("CruelSunHit") :: RemoteEvent

local lastRequestAt: {[Player]: number} = {}



--[[
@param     Player     player         | The player requesting damage.
@param     Vector3    position       | The requested centre of the explosion.
@param     number     radius         | The requested damage radius.
@return    boolean

Validates that the requested explosion is plausible for the player's current character.
]]
local function isValidRequest(
	player: Player,
	position: Vector3,
	radius: number
): boolean
	local character = player.Character
	local root      = character and character:FindFirstChild("HumanoidRootPart")

	if not root or not root:IsA("BasePart") then
		return false
	end

	return radius > 0
		and radius <= CONFIG.Hitbox.MaximumRadius
		and (position - root.Position).Magnitude <= CONFIG.MaxRange + radius
end


--[[
@param     Player     player         | The player responsible for the explosion.
@param     Vector3    position       | The centre of the explosion.
@param     number     radius         | The server-validated damage radius.
@param     number     chargePower    | The normalized charge of Cruel Sun.
@return    void

Applies radial, distance-scaled damage once per Humanoid.
]]
local function damageInRadius(
	player: Player,
	position: Vector3,
	radius: number,
	chargePower: number
)
	local character = player.Character

	if not character then
		return
	end

	local maximumDamage = CONFIG.Hitbox.MinDamage
		+ (CONFIG.Hitbox.MaxDamage - CONFIG.Hitbox.MinDamage) * chargePower
	local parameters = OverlapParams.new()
	local damaged: {[Humanoid]: true} = {}

	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = {character}

	for _, part in workspace:GetPartBoundsInRadius(position, radius, parameters) do
		local model    = part:FindFirstAncestorOfClass("Model")
		local humanoid = model and model:FindFirstChildOfClass("Humanoid")

		if model
			and humanoid
			and humanoid.Health > 0
			and not damaged[humanoid]
		then
			damaged[humanoid] = true

			local referencePosition = if model.PrimaryPart
				then model.PrimaryPart.Position
				else part.Position
			local distanceAlpha = math.clamp(
				(referencePosition - position).Magnitude / radius,
				0,
				1
			)
			local falloff = 1
				- (1 - CONFIG.Hitbox.EdgeDamageFraction) * distanceAlpha

			humanoid.BreakJointsOnDeath = false
			humanoid:TakeDamage(maximumDamage * falloff)
		end
	end
end



hitRemote.OnServerEvent:Connect(function(
	player: Player,
	position: unknown,
	radius: unknown,
	chargePower: unknown
)
	if typeof(position) ~= "Vector3"
		or typeof(radius) ~= "number"
		or typeof(chargePower) ~= "number"
	then
		return
	end

	local now = os.clock()
	local lastRequest = lastRequestAt[player]

	if lastRequest
		and now - lastRequest < CONFIG.Hitbox.RequestInterval
	then
		return
	end

	if not isValidRequest(player, position, radius) then
		return
	end

	lastRequestAt[player] = now
	damageInRadius(
		player,
		position,
		radius,
		math.clamp(chargePower, 0, 1)
	)
end)
Players.PlayerRemoving:Connect(function(player: Player)
	lastRequestAt[player] = nil
end)
