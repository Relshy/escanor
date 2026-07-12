--[[
Author(s)    Janss
Date         12/07/26
Version      1.0.0
]]



--!strict
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local ReplicatedStorage        = game:GetService("ReplicatedStorage")


local systemFolder = ReplicatedStorage:WaitForChild("CruelSun")
local assetsFolder = systemFolder:WaitForChild("Assets")

local CONFIG        = require(systemFolder:WaitForChild("Configuration"))
local axeTemplate   = assetsFolder:WaitForChild("EscanorAxeTemplate") :: Model
local castKeyframes = assetsFolder:WaitForChild("CruelSunKeyframes") :: KeyframeSequence


local CharacterController = {}
CharacterController.__index = CharacterController



--[[
@param     Player    player    | The player whose character is controlled.
@return    Controller

Constructs a controller for Escanor's character, axe, movement, and cast animation.
]]
function CharacterController.new(player: Player): Controller
	local self = setmetatable({
		Player             = player,
		RegisteredCastId   = nil,
		CachedCastTrack    = nil,
		CachedCastHumanoid = nil,
		TemporaryAxe       = nil,
		TemporaryGrip      = nil,
	}, CharacterController)

	return self :: any
end


--[[
@param     Controller    self    | The character controller to query.
@return    Model?

Retrieves the player's current character without retaining stale respawn references.
]]
function CharacterController.GetCharacter(self: Controller): Model?
	return self.Player.Character
end


--[[
@param     Controller    self    | The character controller to query.
@return    BasePart?

Retrieves the HumanoidRootPart belonging to the player's current character.
]]
function CharacterController.GetRoot(self: Controller): BasePart?
	local character = self:GetCharacter()
	local root      = character and character:FindFirstChild("HumanoidRootPart")

	return if root and root:IsA("BasePart") then root else nil
end


--[[
@param     Controller    self    | The character controller to query.
@return    Humanoid?

Retrieves the Humanoid belonging to the player's current character.
]]
function CharacterController.GetHumanoid(self: Controller): Humanoid?
	local character = self:GetCharacter()

	return character and character:FindFirstChildOfClass("Humanoid")
end


--[[
@param     Controller    self    | The character controller whose movement should be locked.
@return    boolean

Locks movement and stores the exact values that must be restored after the cast.
]]
function CharacterController.LockMovement(self: Controller): boolean
	local humanoid = self:GetHumanoid()

	if not humanoid then
		return false
	end

	humanoid:SetAttribute("OldWalkSpeed", humanoid.WalkSpeed)
	humanoid:SetAttribute("OldJumpPower", humanoid.JumpPower)
	humanoid:SetAttribute("MovementLocked", true)

	humanoid.WalkSpeed  = 0
	humanoid.JumpPower  = 0
	humanoid.AutoRotate = false

	return true
end


--[[
@param     Controller    self    | The character controller whose movement should be restored.
@return    void

Restores the movement values saved when the cast began.
]]
function CharacterController.UnlockMovement(self: Controller)
	local humanoid = self:GetHumanoid()

	if not humanoid then
		return
	end

	local oldWalkSpeed = humanoid:GetAttribute("OldWalkSpeed")
	local oldJumpPower = humanoid:GetAttribute("OldJumpPower")

	humanoid.WalkSpeed  = if typeof(oldWalkSpeed) == "number" then oldWalkSpeed else 16
	humanoid.JumpPower  = if typeof(oldJumpPower) == "number" then oldJumpPower else 50
	humanoid.AutoRotate = true

	humanoid:SetAttribute("MovementLocked", false)
end


--[[
@param     BasePart    handle    | The axe handle on which the attachment should exist.
@return    Attachment

Retrieves or creates the authored point from which Cruel Sun is charged.
]]
local function getFirePoint(handle: BasePart): Attachment
	local existing = handle:FindFirstChild("CruelSunFirePoint")

	if existing and existing:IsA("Attachment") then
		existing.Visible = false
		existing.CFrame  = CFrame.new(CONFIG.AxeFirePointOffset)
		return existing
	end

	local firePoint = Instance.new("Attachment")
	firePoint.Name   = "CruelSunFirePoint"
	firePoint.CFrame = CFrame.new(CONFIG.AxeFirePointOffset)
	firePoint.Parent = handle

	return firePoint
end


--[[
@param     Model    axe    | The axe whose physical parts should be configured.
@return    void

Makes a temporary axe safe to attach to a character without affecting their physics.
The authored template already owns the welds that keep its parts together.
]]
local function configureAxeParts(axe: Model)
	for _, descendant in axe:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored   = false
			descendant.CanCollide = false
			descendant.CanQuery   = false
			descendant.Massless   = true
		end
	end
end


--[[
@param     Controller    self    | The character controller preparing the axe.
@return    Attachment?

Reuses Escanor's equipped axe or rigs a temporary fallback when the melee system is absent.
]]
function CharacterController.PrepareAxe(self: Controller): Attachment?
	self:CleanupCast()

	local character = self:GetCharacter()
	local rightArm  = character and (character:FindFirstChild("Right Arm") or character:FindFirstChild("RightHand"))

	if not character or not rightArm or not rightArm:IsA("BasePart") then
		return nil
	end

	local equippedAxe = character:FindFirstChild("EscanorAxe")

	if equippedAxe and equippedAxe:IsA("Model") then
		local handle = equippedAxe.PrimaryPart or equippedAxe:FindFirstChild("Handle")

		if handle and handle:IsA("BasePart") then
			return getFirePoint(handle)
		end
	end

	local axe    = axeTemplate:Clone()
	local handle = axe.PrimaryPart or axe:FindFirstChild("Handle")

	if not handle or not handle:IsA("BasePart") then
		axe:Destroy()
		return nil
	end

	configureAxeParts(axe)

	axe.Name   = "EscanorAbilityAxe"
	axe.Parent = character

	local grip      = rightArm:FindFirstChild("RightGripAttachment")
	local gripFrame = if grip and grip:IsA("Attachment")
		then grip.WorldCFrame
		else rightArm.CFrame * CFrame.new(0, -1, 0)
	local targetFrame = CFrame.new(gripFrame.Position) * handle.CFrame.Rotation
	local delta       = targetFrame * handle.CFrame:Inverse()

	axe:PivotTo(delta * axe:GetPivot())

	local motor = Instance.new("Motor6D")
	motor.Name   = "AxeGrip"
	motor.Part0  = rightArm
	motor.Part1  = handle
	motor.C0     = rightArm.CFrame:ToObjectSpace(handle.CFrame)
	motor.Parent = rightArm

	self.TemporaryAxe  = axe
	self.TemporaryGrip = motor

	return getFirePoint(handle)
end


--[[
@param     Controller     self         | The character controller calculating the position.
@param     number         scale        | The current absolute scale of Cruel Sun.
@param     Attachment?    firePoint    | The preferred axe-relative casting point.
@return    CFrame?

Calculates the world-space CFrame at which the charging sun should be held.
]]
function CharacterController.GetChargeCFrame(
	self: Controller,
	scale: number,
	firePoint: Attachment?
): CFrame?
	if firePoint and firePoint.Parent then
		local extraScale = math.max(scale - 1, 0)

		return firePoint.WorldCFrame + Vector3.new(0, extraScale * CONFIG.AxeScaleLift, 0)
	end

	local root = self:GetRoot()

	if not root then
		return nil
	end

	local extraScale = math.max(scale - 1, 0)
	local offset = CONFIG.ChargeOffset + Vector3.new(
		0,
		extraScale * CONFIG.ChargeUpPush,
		-extraScale * CONFIG.ChargeForwardPush
	)

	return root.CFrame * CFrame.new(offset)
end


--[[
@param     Controller    self    | The character controller loading the animation.
@return    AnimationTrack?

Loads and caches the runtime animation used to cast Cruel Sun.
]]
function CharacterController.GetCastTrack(self: Controller): AnimationTrack?
	local humanoid = self:GetHumanoid()

	if not humanoid then
		return nil
	end

	if self.CachedCastTrack and self.CachedCastHumanoid == humanoid then
		return self.CachedCastTrack
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")

	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	if not self.RegisteredCastId then
		local succeeded, identifier = pcall(function(): string
			return KeyframeSequenceProvider:RegisterKeyframeSequence(castKeyframes)
		end)

		if not succeeded then
			warn("Could not register the Cruel Sun animation:", identifier)
			return nil
		end

		self.RegisteredCastId = identifier
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = self.RegisteredCastId

	local succeeded, track = pcall(function(): AnimationTrack
		return animator:LoadAnimation(animation)
	end)

	animation:Destroy()

	if not succeeded then
		warn("Could not load the Cruel Sun animation:", track)
		return nil
	end

	track.Priority = Enum.AnimationPriority.Action4
	track.Looped   = false

	self.CachedCastTrack    = track
	self.CachedCastHumanoid = humanoid

	return track
end


--[[
@param     Controller         self        | The character controller stopping other animations.
@param     AnimationTrack?    exception   | The track that should be allowed to continue playing.
@param     number             fadeTime    | The duration over which competing tracks should stop.
@return    void

Stops action animations that would visually compete with the Cruel Sun cast.
]]
function CharacterController.StopCompetingAnimations(
	self: Controller,
	exception: AnimationTrack?,
	fadeTime: number
)
	local humanoid = self:GetHumanoid()
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")

	if not animator then
		return
	end

	for _, track in animator:GetPlayingAnimationTracks() do
		if track ~= exception and track.Priority.Value >= Enum.AnimationPriority.Action.Value then
			track:Stop(fadeTime)
		end
	end
end


--[[
@param     Controller    self    | The character controller whose temporary state should be removed.
@return    void

Destroys only the fallback axe state created by this controller.
]]
function CharacterController.CleanupCast(self: Controller)
	if self.TemporaryGrip then
		self.TemporaryGrip:Destroy()
		self.TemporaryGrip = nil
	end

	if self.TemporaryAxe then
		self.TemporaryAxe:Destroy()
		self.TemporaryAxe = nil
	end
end



export type Controller = typeof(setmetatable({} :: {
	Player             : Player,
	RegisteredCastId   : string?,
	CachedCastTrack    : AnimationTrack?,
	CachedCastHumanoid : Humanoid?,
	TemporaryAxe       : Model?,
	TemporaryGrip      : Motor6D?,
}, CharacterController))


return table.freeze(CharacterController)
