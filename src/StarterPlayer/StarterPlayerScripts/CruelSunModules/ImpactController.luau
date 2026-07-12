--[[
Author(s)    @sillyrelshy
Date         12/07/26
Version      1.0.0
]]



--!strict
local Debris            = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService   = game:GetService("TextChatService")
local TweenService      = game:GetService("TweenService")


local systemFolder = ReplicatedStorage:WaitForChild("CruelSun")
local remotesFolder = systemFolder:WaitForChild("Remotes")
local signalsFolder = systemFolder:WaitForChild("Signals")

local hitRemote    = remotesFolder:WaitForChild("CruelSunHit") :: RemoteEvent
local impactSignal = signalsFolder:WaitForChild("Impact") :: BindableEvent


local ImpactController = {}
ImpactController.__index = ImpactController



--[[
@param     Player    player    | The player whose impacts are resolved.
@return    Controller

Constructs a server-authoritative impact controller with optional local hitbox visualization.
]]
function ImpactController.new(player: Player): Controller
	local self = setmetatable({
		Player         = player,
		VisualizeHitbox = player:GetAttribute("HitboxViz") == true,
	}, ImpactController) :: any

	self:_bindVisualizationControls()

	return self
end


--[[
@param     Controller    self    | The impact controller reporting its debug state.
@return    void

Displays whether hitbox visualization is currently enabled.
]]
function ImpactController._announceVisualization(self: Controller)
	local message  = `Cruel Sun hitbox visualization: {if self.VisualizeHitbox then "ON" else "OFF"}`
	local channels = TextChatService:FindFirstChild("TextChannels")
	local general  = channels and channels:FindFirstChild("RBXGeneral")

	if general and general:IsA("TextChannel") then
		general:DisplaySystemMessage(message)
	end
end


--[[
@param     Controller    self    | The impact controller toggling its debug state.
@return    void

Toggles hitbox visualization and mirrors the result to the player's attribute.
]]
function ImpactController._toggleVisualization(self: Controller)
	self.VisualizeHitbox = not self.VisualizeHitbox
	self.Player:SetAttribute("HitboxViz", self.VisualizeHitbox)
	self:_announceVisualization()
end


--[[
@param     Controller    self    | The impact controller binding debug controls.
@return    void

Registers modern and legacy chat controls for the optional hitbox visualizer.
]]
function ImpactController._bindVisualizationControls(self: Controller)
	self.Player:GetAttributeChangedSignal("HitboxViz"):Connect(function()
		self.VisualizeHitbox = self.Player:GetAttribute("HitboxViz") == true
	end)

	local succeeded = pcall(function()
		local existing = TextChatService:FindFirstChild("CruelSunHitboxCommand")
		local command  = if existing and existing:IsA("TextChatCommand")
			then existing
			else Instance.new("TextChatCommand")

		command.Name           = "CruelSunHitboxCommand"
		command.PrimaryAlias   = "/hitbox"
		command.SecondaryAlias = "/hb"
		command.Parent         = TextChatService

		command.Triggered:Connect(function()
			self:_toggleVisualization()
		end)
	end)

	if not succeeded then
		self.Player.Chatted:Connect(function(message)
			if message == "/hitbox" or message == "/hb" then
				self:_toggleVisualization()
			end
		end)
	end
end


--[[
@param     Vector3    position    | The centre of the hitbox visualization.
@param     number     radius      | The radius of the represented hitbox.
@return    void

Creates a temporary ForceField sphere representing the server damage radius.
]]
local function showHitbox(position: Vector3, radius: number)
	local sphere = Instance.new("Part")
	sphere.Name         = "CruelSunHitbox"
	sphere.Shape        = Enum.PartType.Ball
	sphere.Anchored     = true
	sphere.CanCollide   = false
	sphere.CanQuery     = false
	sphere.CanTouch     = false
	sphere.Material     = Enum.Material.ForceField
	sphere.Color        = Color3.fromRGB(255, 40, 40)
	sphere.Transparency = 0.45
	sphere.Size         = Vector3.one * radius * 2
	sphere.CFrame       = CFrame.new(position)
	sphere.Parent       = workspace

	TweenService:Create(
		sphere,
		TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{Transparency = 1}
	):Play()

	Debris:AddItem(sphere, 1.15)
end


--[[
@param     Model    model    | The model intersecting the visualized hitbox.
@return    void

Highlights a model briefly to make debug hit registration visible.
]]
local function flashModel(model: Model)
	local highlight = Instance.new("Highlight")
	highlight.FillColor       = Color3.fromRGB(255, 40, 40)
	highlight.FillTransparency = 0.35
	highlight.OutlineColor    = Color3.fromRGB(255, 90, 40)
	highlight.Parent          = model

	Debris:AddItem(highlight, 0.35)
end


--[[
@param     Controller    self        | The impact controller visualizing targets.
@param     Vector3       position    | The centre of the damage radius.
@param     number        radius      | The maximum damage distance.
@return    void

Visualizes the hitbox and highlights each intersecting Humanoid once.
]]
function ImpactController._visualize(self: Controller, position: Vector3, radius: number)
	local character  = self.Player.Character
	local parameters = OverlapParams.new()
	local seen: {[Humanoid]: true} = {}

	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = if character then {character} else {}

	showHitbox(position, radius)

	for _, part in workspace:GetPartBoundsInRadius(position, radius, parameters) do
		local model    = part:FindFirstAncestorOfClass("Model")
		local humanoid = model and model:FindFirstChildOfClass("Humanoid")

		if model and humanoid and not seen[humanoid] then
			seen[humanoid] = true
			flashModel(model)
		end
	end
end


--[[
@param     Controller    self              | The impact controller resolving the hit.
@param     Vector3       position          | The world-space impact position.
@param     number        radius            | The server-validated damage radius.
@param     number        chargePower       | The normalized charge of Cruel Sun.
@param     number        sizeMultiplier    | The selected variant's size multiplier.
@return    void

Reports the hit to the server, publishes presentation signals, and optionally visualizes it.
]]
function ImpactController.Resolve(
	self: Controller,
	position: Vector3,
	radius: number,
	chargePower: number,
	sizeMultiplier: number
)
	hitRemote:FireServer(position, radius, chargePower)
	impactSignal:Fire(position, radius, chargePower, sizeMultiplier)

	if self.VisualizeHitbox then
		self:_visualize(position, radius)
	end
end



export type Controller = typeof(setmetatable({} :: {
	Player          : Player,
	VisualizeHitbox : boolean,
}, ImpactController))


return table.freeze(ImpactController)
