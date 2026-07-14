--[[
Author(s)    @sillyrelshy
Date         14/07/26
Version      1.2.0
]]



--!strict
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")


local systemFolder  = ReplicatedStorage:WaitForChild("CruelSun")
local remotesFolder = systemFolder:WaitForChild("Remotes")

local CONFIG    = require(systemFolder:WaitForChild("Configuration"))
local hitRemote = remotesFolder:WaitForChild("CruelSunHit") :: RemoteEvent

local CHARGE_GRACE       = 0.1
local IMPACT_GRACE       = 5
local MAX_CAST_LIFETIME  = 20
local MAX_ORIGIN_DISTANCE = 75
local CASTING_ATTRIBUTE  = "CruelSunCasting"


type AbilityVariant = {
	Name                : string,
	Key                 : Enum.KeyCode,
	Cooldown            : number,
	MaxScale            : number,
	ChargeTime          : number,
	Condense            : boolean,
	ExplosionMultiplier : number,
}

type ActiveCast = {
	Variant     : AbilityVariant,
	StartedAt   : number,
	CommittedAt : number?,
	ChargePower : number?,
	Origin      : Vector3?,
}

local activeCasts: {[Player]: ActiveCast} = {}
local nextReadyAt: {[Player]: {[string]: number}} = {}

-- A server-owned attribute lets sibling combat systems reject overlapping
-- actions without sharing this script's private cast table. The timeout also
-- clears abandoned Begin requests if a client disconnects from the lifecycle.
local function clearActiveCast(player: Player)
	activeCasts[player] = nil
	player:SetAttribute(CASTING_ATTRIBUTE, false)
end



--[[
@param     number    value    | The numeric value being validated.
@return    boolean            | Whether the value is neither NaN nor infinite.

Rejects non-finite remote payloads before they enter distance or damage calculations.
]]
local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end


--[[
@param     Vector3    value    | The world-space vector being validated.
@return    boolean             | Whether every component is finite.

Prevents NaN components from bypassing magnitude comparisons in remote validation.
]]
local function isFiniteVector(value: Vector3): boolean
	return isFiniteNumber(value.X)
		and isFiniteNumber(value.Y)
		and isFiniteNumber(value.Z)
end


--[[
@param     string    variantName    | The client-requested configuration variant.
@return    AbilityVariant?          | The matching immutable variant, when known.

Resolves only variants defined by the server's own configuration table.
]]
local function getVariant(variantName: string): AbilityVariant?
	if variantName == CONFIG.Variants.Compress.Name then
		return CONFIG.Variants.Compress
	elseif variantName == CONFIG.Variants.Giant.Name then
		return CONFIG.Variants.Giant
	end

	return nil
end


--[[
@param     Player       player    | The player whose character is inspected.
@return    BasePart?              | A living character's HumanoidRootPart.

Rejects requests from missing or defeated characters before cast state is changed.
]]
local function getAliveRoot(player: Player): BasePart?
	local character = player.Character
	local humanoid  = character and character:FindFirstChildOfClass("Humanoid")
	local root      = character and character:FindFirstChild("HumanoidRootPart")

	if not humanoid
		or humanoid.Health <= 0
		or not root
		or not root:IsA("BasePart")
	then
		return nil
	end

	return root
end


--[[
@param     Player     player         | The player responsible for the explosion.
@param     Vector3    position       | The centre of the explosion.
@param     number     radius         | The server-derived damage radius.
@param     number     chargePower    | The server-capped normalized charge.
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


--[[
@param     Player            player         | The player beginning a cast.
@param     AbilityVariant    variant        | The server-resolved ability variant.
@param     number            now            | The current server clock value.
@return    void

Starts the server-owned charge clock when the player is alive and off cooldown.
]]
local function beginCast(player: Player, variant: AbilityVariant, now: number)
	if not getAliveRoot(player) then
		return
	end

	local currentCast = activeCasts[player]

	if currentCast and now - currentCast.StartedAt <= MAX_CAST_LIFETIME then
		return
	end

	local playerCooldowns = nextReadyAt[player]

	if playerCooldowns and now < (playerCooldowns[variant.Name] or 0) then
		return
	end

	activeCasts[player] = {
		Variant   = variant,
		StartedAt = now,
	}
	player:SetAttribute(CASTING_ATTRIBUTE, true)
	task.delay(MAX_CAST_LIFETIME, function()
		local cast = activeCasts[player]
		if cast and cast.StartedAt == now then
			clearActiveCast(player)
		end
	end)
end


--[[
@param     Player     player             | The player committing a cast.
@param     number     requestedCharge    | The client-observed normalized charge.
@param     Vector3    origin             | The requested projectile launch point.
@param     number     now                | The current server clock value.
@return    void

Caps charge using server elapsed time and begins cooldown only after launch commitment.
]]
local function commitCast(
	player: Player,
	requestedCharge: number,
	origin: Vector3,
	now: number
)
	local cast = activeCasts[player]
	local root = getAliveRoot(player)

	if not cast
		or cast.CommittedAt
		or not root
		or now - cast.StartedAt > MAX_CAST_LIFETIME
		or (origin - root.Position).Magnitude > MAX_ORIGIN_DISTANCE
	then
		return
	end

	local maximumCharge = math.clamp(
		(now - cast.StartedAt) / cast.Variant.ChargeTime + CHARGE_GRACE,
		0,
		1
	)
	local chargePower = math.min(
		math.clamp(requestedCharge, 0, 1),
		maximumCharge
	)

	cast.CommittedAt = now
	cast.ChargePower = chargePower
	cast.Origin = origin

	local playerCooldowns = nextReadyAt[player]

	if not playerCooldowns then
		playerCooldowns = {}
		nextReadyAt[player] = playerCooldowns
	end

	playerCooldowns[cast.Variant.Name] = now + cast.Variant.Cooldown
end


--[[
@param     Player     player      | The player resolving a committed projectile.
@param     Vector3    position    | The client-observed impact position.
@param     number     now         | The current server clock value.
@return    void

Derives hitbox size from trusted configuration and validates the projectile journey.
]]
local function resolveImpact(player: Player, position: Vector3, now: number)
	local cast = activeCasts[player]

	if not cast
		or not cast.CommittedAt
		or not cast.ChargePower
		or not cast.Origin
	then
		return
	end

	clearActiveCast(player)

	local maximumFlightTime = CONFIG.MaxRange / CONFIG.ProjectileSpeed + IMPACT_GRACE

	if now - cast.CommittedAt > maximumFlightTime then
		return
	end

	local explosionScale = (
		CONFIG.ExplosionBaseScale
		+ CONFIG.ExplosionChargeBonus * cast.ChargePower
	) * cast.Variant.ExplosionMultiplier
	local radius = math.min(
		explosionScale * CONFIG.Hitbox.RadiusMultiplier,
		CONFIG.Hitbox.MaximumRadius
	)

	if radius <= 0
		or (position - cast.Origin).Magnitude > CONFIG.MaxRange + radius
	then
		return
	end

	damageInRadius(player, position, radius, cast.ChargePower)
end



hitRemote.OnServerEvent:Connect(function(
	player: Player,
	action: unknown,
	valueA: unknown,
	valueB: unknown
)
	if typeof(action) ~= "string" then
		return
	end

	local now = workspace:GetServerTimeNow()

	if action == "Begin" and typeof(valueA) == "string" then
		local variant = getVariant(valueA)

		if variant then
			beginCast(player, variant, now)
		end
	elseif action == "Commit"
		and typeof(valueA) == "number"
		and typeof(valueB) == "Vector3"
		and isFiniteNumber(valueA)
		and isFiniteVector(valueB)
	then
		commitCast(player, valueA, valueB, now)
	elseif action == "Impact"
		and typeof(valueA) == "Vector3"
		and isFiniteVector(valueA)
	then
		resolveImpact(player, valueA, now)
	elseif action == "Cancel" then
		clearActiveCast(player)
	end
end)

Players.PlayerRemoving:Connect(function(player: Player)
	activeCasts[player] = nil
	nextReadyAt[player] = nil
end)
