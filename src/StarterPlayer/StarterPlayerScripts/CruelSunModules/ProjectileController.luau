--[[
Author(s)    Janss
Date         12/07/26
Version      1.0.0
]]



--!strict
local Debris            = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")


local systemFolder = ReplicatedStorage:WaitForChild("CruelSun")
local CONFIG       = require(systemFolder:WaitForChild("Configuration"))


local ProjectileController = {}
ProjectileController.__index = ProjectileController



--[[
@param     Player                       player     | The player aiming Cruel Sun.
@param     EffectsController            effects    | The controller responsible for projectile audio.
@return    Controller

Constructs a controller that simulates Cruel Sun projectiles.
]]
function ProjectileController.new(player: Player, effects: EffectsController): Controller
	return setmetatable({
		Player  = player,
		Effects = effects,
	}, ProjectileController) :: any
end


--[[
@param     Controller    self      | The projectile controller calculating the direction.
@param     Vector3       origin    | The point from which Cruel Sun will be launched.
@return    Vector3

Projects the mouse position into the world and calculates an aim direction from the sun.
]]
function ProjectileController.GetAimDirection(self: Controller, origin: Vector3): Vector3
	local camera = workspace.CurrentCamera

	if not camera then
		return Vector3.new(0, 0, -1)
	end

	local mousePosition = UserInputService:GetMouseLocation()
	local mouseRay      = camera:ViewportPointToRay(mousePosition.X, mousePosition.Y)
	local character     = self.Player.Character
	local parameters    = RaycastParams.new()

	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = if character then {character} else {}

	local result    = workspace:Raycast(mouseRay.Origin, mouseRay.Direction * 1000, parameters)
	local target    = if result then result.Position else mouseRay.Origin + mouseRay.Direction * 1000
	local direction = target - origin

	return if direction.Magnitude > 0.01 then direction.Unit else camera.CFrame.LookVector
end


--[[
@param     Controller    self    | The projectile controller creating launch audio.
@param     BasePart      sun     | The sun whose launch should be heard.
@return    Sound?

Plays the launch sound from the player's current root and returns the travelling loop.
]]
local function beginAudio(self: Controller, sun: BasePart): Sound?
	local character = self.Player.Character
	local root      = character and character:FindFirstChild("HumanoidRootPart")

	if root and root:IsA("BasePart") then
		local launchSound = self.Effects:CreateSound("Launch", root)

		if launchSound then
			launchSound:Play()
			Debris:AddItem(launchSound, 3)
		end
	end

	local travelSound = self.Effects:CreateSound("Traveling", sun)

	if travelSound then
		travelSound.Looped = true
		travelSound:Play()
	end

	return travelSound
end


--[[
@param     Controller    self    | The projectile controller launching the sun.
@param     BasePart      sun     | The charged Cruel Sun visual.
@return    Vector3

Simulates projectile flight with a raycast on each Heartbeat and returns the impact position.
]]
function ProjectileController.Launch(self: Controller, sun: BasePart): Vector3
	local velocity     = self:GetAimDirection(sun.Position) * CONFIG.ProjectileSpeed
	local travelled    = 0
	local lastPosition = sun.Position
	local hitPosition: Vector3? = nil
	local character    = self.Player.Character
	local parameters   = RaycastParams.new()
	local travelSound  = beginAudio(self, sun)

	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = if character then {sun, character} else {sun}

	while travelled < CONFIG.MaxRange and sun.Parent do
		local deltaTime = RunService.Heartbeat:Wait()
		velocity -= Vector3.new(0, CONFIG.GravityBend * deltaTime, 0)

		local step   = velocity * deltaTime
		local result = workspace:Raycast(sun.Position, step, parameters)

		if result then
			hitPosition  = result.Position
			lastPosition = result.Position
			break
		end

		local nextPosition = sun.Position + step
		sun.CFrame = CFrame.new(nextPosition, nextPosition + velocity)

		lastPosition = nextPosition
		travelled += step.Magnitude
	end

	self.Effects:FadeSound(travelSound, 0.06)
	sun:Destroy()

	return hitPosition or lastPosition
end



type EffectsController = {
	CreateSound : (EffectsController, string, Instance) -> Sound?,
	FadeSound   : (EffectsController, Sound?, number?) -> (),
}

export type Controller = typeof(setmetatable({} :: {
	Player  : Player,
	Effects : EffectsController,
}, ProjectileController))


return table.freeze(ProjectileController)
