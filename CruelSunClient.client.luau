-- Connected Discord-GitHub
--[[
Author(s)    @sillyrelshy
Date         14/07/26
Version      2.1.0
]]

--!strict
local Debris                   = game:GetService("Debris")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local Players                  = game:GetService("Players")
local ReplicatedStorage        = game:GetService("ReplicatedStorage")
local RunService               = game:GetService("RunService")
local UserInputService         = game:GetService("UserInputService")

local player        = Players.LocalPlayer
local systemFolder  = ReplicatedStorage:WaitForChild("CruelSun")
local assetsFolder  = systemFolder:WaitForChild("Assets")
local remotesFolder = systemFolder:WaitForChild("Remotes")
local signalsFolder = systemFolder:FindFirstChild("Signals")
local cooldownStore = ReplicatedStorage:FindFirstChild("CooldownController")

local sunTemplate   = assetsFolder:WaitForChild("CruelSunProjectileVFX") :: BasePart
local axeTemplate   = assetsFolder:WaitForChild("EscanorAxeTemplate") :: Model
local castKeyframes = assetsFolder:WaitForChild("CruelSunKeyframes") :: KeyframeSequence
local hitRemote     = remotesFolder:WaitForChild("CruelSunHit") :: RemoteEvent

local CONFIG = require(systemFolder:WaitForChild("Configuration"))
local PresentationController = require(script.Parent:WaitForChild("CruelSunPresentation"))

--[[
ARCHITECTURE

The submitted controller owns cast state and advances it linearly through charge,
compression, animation, projectile flight, impact, and cleanup. A single focused
presentation module owns reusable VFX, audio, and camera resources; it never
decides gameplay or networking. This keeps the important ability logic visible
without duplicating presentation cleanup throughout the controller.

The client owns input and presentation for responsiveness, but never decides
damage. Begin, Commit, Impact, and Cancel report observed phases to the server.
The server measures charge time, enforces cooldown, derives radius and damage
from trusted configuration, and rejects implausible positions.
]]

type AbilityVariant = CONFIG.AbilityVariant
type CastPhase =
	"Idle" | "Charging" | "Compressing" | "Animating"
	| "Launching" | "Impacting" | "Cleaning" | "Destroyed"
type CastSession = {
	Variant        : AbilityVariant,
	Sun            : BasePart,
	Parts          : PresentationController.PartScaleMap,
	Emitters       : PresentationController.EmitterScaleMap,
	LaunchEmitters : {ParticleEmitter},
	FirePoint      : Attachment?,
	ChargingSound  : Sound?,
	CrackleSound   : Sound?,
	CastTrack      : AnimationTrack?,
	CurrentScale   : number,
}

local VARIANT_BY_KEY: {[Enum.KeyCode]: AbilityVariant} = {
	[CONFIG.Variants.Compress.Key] = CONFIG.Variants.Compress,
	[CONFIG.Variants.Giant.Key] = CONFIG.Variants.Giant,
}

local CruelSun = {}
CruelSun.__index = CruelSun

local localCooldowns: {[string]: number} = {}

type Controller = typeof(setmetatable({} :: {
	Presentation       : PresentationController.Controller,
	RegisteredCastId   : string?,
	CachedCastTrack    : AnimationTrack?,
	CachedCastHumanoid : Humanoid?,
	TemporaryAxe       : Model?,
	TemporaryGrip      : Motor6D?,
	ActiveSession      : CastSession?,
	Phase              : CastPhase,
	IsCasting          : boolean,
	Destroyed          : boolean,
	Input              : RBXScriptConnection?,
}, CruelSun))

-- Signals drive optional subtitle and impact-rock presentation. FindFirstChild
-- keeps those consumers optional instead of turning them into dependencies.
local function fireSignal(name: string, ...: any)
	local signal = signalsFolder and signalsFolder:FindFirstChild(name)
	if signal and signal:IsA("BindableEvent") then
		signal:Fire(...)
	end
end

-- The HUD already observes attributes on this Instance. Writing the values
-- directly keeps cooldown logic visible here without requiring its ModuleScript.
local function cooldownAttribute(identifier: string, field: string): string
	return "Cooldown_" .. identifier .. "_" .. field
end

local function cooldownRemaining(identifier: string): number
	if not cooldownStore then
		return math.max(
			0,
			(localCooldowns[identifier] or 0) - workspace:GetServerTimeNow()
		)
	end
	local expiresAt = cooldownStore:GetAttribute(cooldownAttribute(identifier, "ExpiresAt"))
	return if typeof(expiresAt) == "number"
		then math.max(0, expiresAt - workspace:GetServerTimeNow())
		else 0
end

local function startCooldown(identifier: string, duration: number)
	if not cooldownStore then
		localCooldowns[identifier] = workspace:GetServerTimeNow() + duration
		return
	end
	cooldownStore:SetAttribute(
		cooldownAttribute(identifier, "ExpiresAt"),
		workspace:GetServerTimeNow() + duration
	)
	cooldownStore:SetAttribute(cooldownAttribute(identifier, "Duration"), duration)
end

-- Cleanup operations are isolated so a broken VFX cannot prevent movement
-- restoration. debug.traceback keeps the originating line in any warning.
local function cleanupStep(label: string, callback: () -> ())
	local succeeded, failure = xpcall(callback, debug.traceback)
	if not succeeded then
		warn("Cruel Sun " .. label .. " failed:\n", failure)
	end
end

function CruelSun.new(): Controller
	return setmetatable({
		Presentation = PresentationController.new(player),
		RegisteredCastId = nil,
		CachedCastTrack = nil,
		CachedCastHumanoid = nil,
		TemporaryAxe = nil,
		TemporaryGrip = nil,
		ActiveSession = nil,
		Phase = "Idle",
		IsCasting = false,
		Destroyed = false,
		Input = nil,
	}, CruelSun) :: Controller
end

function CruelSun._setPhase(self: Controller, phase: CastPhase)
	self.Phase = if self.Destroyed then "Destroyed" else phase
end

function CruelSun._getHumanoid(self: Controller): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

function CruelSun._getRoot(self: Controller): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- Original movement values are saved because other systems may deliberately use
-- non-default speeds. Cleanup restores observed state rather than assumptions.
function CruelSun._lockMovement(self: Controller): boolean
	local humanoid = self:_getHumanoid()
	if not humanoid then
		return false
	end
	humanoid:SetAttribute("OldWalkSpeed", humanoid.WalkSpeed)
	humanoid:SetAttribute("OldJumpPower", humanoid.JumpPower)
	humanoid:SetAttribute("MovementLocked", true)
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.AutoRotate = false
	return true
end

function CruelSun._unlockMovement(self: Controller)
	local humanoid = self:_getHumanoid()
	if not humanoid then
		return
	end
	local walkSpeed = humanoid:GetAttribute("OldWalkSpeed")
	local jumpPower = humanoid:GetAttribute("OldJumpPower")
	humanoid.WalkSpeed = if typeof(walkSpeed) == "number" then walkSpeed else 16
	humanoid.JumpPower = if typeof(jumpPower) == "number" then jumpPower else 50
	humanoid.AutoRotate = true
	humanoid:SetAttribute("MovementLocked", false)
end

-- Reusing one named attachment keeps the charge transform deterministic even
-- when the melee system already equipped the axe before this ability starts.
local function getFirePoint(handle: BasePart): Attachment
	local existing = handle:FindFirstChild("CruelSunFirePoint")
	local firePoint = if existing and existing:IsA("Attachment")
		then existing
		else Instance.new("Attachment")
	firePoint.Name = "CruelSunFirePoint"
	firePoint.CFrame = CFrame.new(CONFIG.AxeFirePointOffset)
	firePoint.Visible = false
	firePoint.Parent = handle
	return firePoint
end

-- Every fallback part is massless and non-colliding so a presentation prop
-- cannot change Escanor's assembly mass, collision response, or raycast aim.
local function configureAxe(axe: Model)
	for _, descendant in axe:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.Massless = true
		end
	end
end

function CruelSun._cleanupAxe(self: Controller)
	if self.TemporaryGrip then
		self.TemporaryGrip:Destroy()
		self.TemporaryGrip = nil
	end
	if self.TemporaryAxe then
		self.TemporaryAxe:Destroy()
		self.TemporaryAxe = nil
	end
end

-- The normal Escanor axe is preferred. If the melee loadout is absent, the
-- controller rigs the authored template to either R6 or R15's right hand so
-- the demonstrated ability retains the same casting pose in a clean place.
function CruelSun._prepareAxe(self: Controller): Attachment?
	self:_cleanupAxe()
	local character = player.Character
	local rightArm = character
		and (character:FindFirstChild("Right Arm") or character:FindFirstChild("RightHand"))
	if not character or not rightArm or not rightArm:IsA("BasePart") then
		return nil
	end
	local equipped = character:FindFirstChild("EscanorAxe")
	if equipped and equipped:IsA("Model") then
		local handle = equipped.PrimaryPart or equipped:FindFirstChild("Handle")
		if handle and handle:IsA("BasePart") then
			return getFirePoint(handle)
		end
	end
	local axe = axeTemplate:Clone()
	local handle = axe.PrimaryPart or axe:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then
		axe:Destroy()
		return nil
	end
	configureAxe(axe)
	axe.Name = "EscanorAbilityAxe"
	axe.Parent = character

	-- Pivoting the whole welded model preserves its authored internal offsets;
	-- the Motor6D then records that solved pose relative to the animated arm.
	local grip = rightArm:FindFirstChild("RightGripAttachment")
	local gripFrame = if grip and grip:IsA("Attachment")
		then grip.WorldCFrame
		else rightArm.CFrame * CFrame.new(0, -1, 0)
	local target = CFrame.new(gripFrame.Position) * handle.CFrame.Rotation
	axe:PivotTo(target * handle.CFrame:Inverse() * axe:GetPivot())
	local motor = Instance.new("Motor6D")
	motor.Name = "AxeGrip"
	motor.Part0 = rightArm
	motor.Part1 = handle
	motor.C0 = rightArm.CFrame:ToObjectSpace(handle.CFrame)
	motor.Parent = rightArm
	self.TemporaryAxe = axe
	self.TemporaryGrip = motor
	return getFirePoint(handle)
end

-- As scale grows, the visual centre moves upward so the sphere expands away
-- from Escanor instead of through him.
function CruelSun._getChargeCFrame(
	self: Controller,
	scale: number,
	firePoint: Attachment?
): CFrame?
	local extraScale = math.max(scale - 1, 0)
	if firePoint and firePoint.Parent then
		return firePoint.WorldCFrame + Vector3.new(0, extraScale * CONFIG.AxeScaleLift, 0)
	end
	local root = self:_getRoot()
	if not root then
		return nil
	end
	local offset = CONFIG.ChargeOffset + Vector3.new(
		0,
		extraScale * CONFIG.ChargeUpPush,
		-extraScale * CONFIG.ChargeForwardPush
	)
	return root.CFrame * CFrame.new(offset)
end

function CruelSun._getCastTrack(self: Controller): AnimationTrack?
	local humanoid = self:_getHumanoid()
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
		local registered, identifier = pcall(function(): string
			return KeyframeSequenceProvider:RegisterKeyframeSequence(castKeyframes)
		end)
		if not registered then
			warn("Could not register Cruel Sun animation:", identifier)
			return nil
		end
		self.RegisteredCastId = identifier
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = self.RegisteredCastId
	local loaded, track = pcall(function(): AnimationTrack
		return animator:LoadAnimation(animation)
	end)
	animation:Destroy()
	if not loaded then
		warn("Could not load Cruel Sun animation:", track)
		return nil
	end
	track.Priority = Enum.AnimationPriority.Action4
	track.Looped = false
	self.CachedCastTrack = track
	self.CachedCastHumanoid = humanoid
	return track
end

function CruelSun._stopCompetingAnimations(
	self: Controller,
	exception: AnimationTrack?,
	fadeTime: number
)
	local humanoid = self:_getHumanoid()
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

function CruelSun._createSession(
	self: Controller,
	variant: AbilityVariant
): CastSession?
	local firePoint = self:_prepareAxe()
	local sun = sunTemplate:Clone()
	sun.Name = "CruelSun"
	sun.Anchored = true
	sun.CanCollide = false
	sun.CanQuery = false
	sun.CanTouch = false
	sun.Parent = workspace
	local chargeCFrame = self:_getChargeCFrame(CONFIG.MinScale, firePoint)
	if not chargeCFrame then
		sun:Destroy()
		return nil
	end
	sun.CFrame = chargeCFrame
	local parts, emitters = self.Presentation:GetScaleTargets(sun)
	self.Presentation:ApplyScale(parts, emitters, CONFIG.MinScale)
	local chargingSound = self.Presentation:CreateSound("Charging", sun)
	local crackleSound = self.Presentation:CreateSound("ChargingCrackle", sun)
	if chargingSound then
		chargingSound:Play()
	end
	if crackleSound then
		crackleSound.Looped = true
		crackleSound.Volume = 0
		crackleSound:Play()
	end
	local castTrack = self:_getCastTrack()
	if castTrack then
		self:_stopCompetingAnimations(castTrack, CONFIG.ChargePoseFadeTime)
		castTrack:Play(CONFIG.ChargePoseFadeTime, 1, 0)
		castTrack.TimePosition = 0
		castTrack:AdjustSpeed(0)
	end
	return {
		Variant = variant,
		Sun = sun,
		Parts = parts,
		Emitters = emitters,
		LaunchEmitters = self.Presentation:GetLaunchEmitters(sun),
		FirePoint = firePoint,
		ChargingSound = chargingSound,
		CrackleSound = crackleSound,
		CastTrack = castTrack,
		CurrentScale = CONFIG.MinScale,
	}
end

function CruelSun._setChargeScale(
	self: Controller,
	session: CastSession,
	scale: number,
	volumeBoost: number
): boolean
	local target = self:_getChargeCFrame(scale, session.FirePoint)
	if self.Destroyed or not target or not session.Sun.Parent then
		return false
	end
	session.CurrentScale = scale
	session.Sun.CFrame = target
	self.Presentation:ApplyScale(session.Parts, session.Emitters, scale)
	if session.CrackleSound then
		session.CrackleSound.Volume = CONFIG.Volumes.ChargingCrackle * volumeBoost
	end
	return true
end

-- Each drop emits once and uses quintic easing. Its slow start preserves the
-- previous held size long enough to read, while the steep finish makes the
-- contraction feel forceful without adding more per-frame effects.
function CruelSun._dropToScale(
	self: Controller,
	session: CastSession,
	fromScale: number,
	toScale: number,
	duration: number,
	volumeBoost: number,
	pitch: number
): boolean
	self.Presentation:PlayCondensePulse(session.Sun, fromScale, toScale, pitch)
	local startedAt = os.clock()
	while UserInputService:IsKeyDown(session.Variant.Key) do
		local alpha = math.clamp((os.clock() - startedAt) / duration, 0, 1)
		local eased = 1 - (1 - alpha) ^ 5
		if not self:_setChargeScale(
			session,
			fromScale + (toScale - fromScale) * eased,
			volumeBoost
		) then
			return false
		end
		if alpha >= 1 then
			return true
		end
		RunService.Heartbeat:Wait()
	end
	return false
end

-- Holds are deliberate pauses between drops, not idle delays: the sun remains
-- attached to the animated axe and validates character state every Heartbeat.
function CruelSun._holdScale(
	self: Controller,
	session: CastSession,
	scale: number,
	duration: number,
	volumeBoost: number
): boolean
	local startedAt = os.clock()
	while UserInputService:IsKeyDown(session.Variant.Key)
		and os.clock() - startedAt < duration
	do
		if not self:_setChargeScale(session, scale, volumeBoost) then
			return false
		end
		RunService.Heartbeat:Wait()
	end
	return UserInputService:IsKeyDown(session.Variant.Key)
end

-- Three progressively smaller targets reproduce the original "compressed sun"
-- cadence. Every early return means the player released E, so launch continues
-- from the last visible scale rather than completing hidden work afterward.
function CruelSun._compress(
	self: Controller,
	session: CastSession,
	chargeScale: number,
	chargePower: number
): boolean
	self:_setPhase("Compressing")
	local compressed = CONFIG.CompressedScale
		+ (CONFIG.CompressedMaxScale - CONFIG.CompressedScale) * chargePower
	local first = compressed + (chargeScale - compressed) * 0.42
	local second = compressed + (chargeScale - compressed) * 0.16
	if not self:_dropToScale(
		session, chargeScale, first, CONFIG.CompressionDropTime, 1.35, 0.82
	) or not self:_holdScale(
		session, first, CONFIG.CompressionHoldTime, 1.2
	) or not self:_dropToScale(
		session, first, second, CONFIG.CompressionDropTime * 1.35, 1.55, 1
	) or not self:_holdScale(
		session, second, CONFIG.CompressionHoldTime * 1.6, 1.25
	) or not self:_dropToScale(
		session, second, compressed, CONFIG.CompressionFinalTime, 1.65, 1.18
	) then
		return false
	end
	return self:_setChargeScale(session, compressed, 1.45)
end

-- One normalized value drives scale, crackle volume, compression, presentation,
-- and the server-capped damage model. Heartbeat is appropriate because only one
-- local sun is updated and visible attachment stepping would otherwise occur.
function CruelSun._charge(self: Controller, session: CastSession): number?
	local startedAt = os.clock()
	local chargePower = 0
	while UserInputService:IsKeyDown(session.Variant.Key) do
		local alpha = math.clamp(
			(os.clock() - startedAt) / session.Variant.ChargeTime, 0, 1
		)
		local scale = CONFIG.MinScale
			+ (session.Variant.MaxScale - CONFIG.MinScale) * alpha
		chargePower = alpha
		if not self:_setChargeScale(session, scale, alpha) then
			return nil
		end
		if alpha >= 1 and session.Variant.Condense then
			if not self:_compress(session, scale, chargePower) then
				return if self:_getRoot() then chargePower else nil
			end
			while UserInputService:IsKeyDown(session.Variant.Key) do
				if not self:_setChargeScale(session, session.CurrentScale, 1.45) then
					return nil
				end
				RunService.Heartbeat:Wait()
			end
			return chargePower
		end
		RunService.Heartbeat:Wait()
	end
	return chargePower
end

-- The track is frozen at its charge pose. On release it advances only to the
-- authored launch percentage, coupling gameplay timing to animation timing.
function CruelSun._playCastAnimation(
	self: Controller,
	session: CastSession
): boolean
	local track = session.CastTrack
	if not track then
		return true
	end
	self:_setPhase("Animating")
	self:_stopCompetingAnimations(track, CONFIG.CastFadeTime)
	if track.IsPlaying then
		track.TimePosition = 0
		track:AdjustWeight(1, CONFIG.CastFadeTime)
		track:AdjustSpeed(1)
	else
		track:Play(CONFIG.CastFadeTime, 1, 1)
	end
	local lengthDeadline = os.clock() + 1
	while track.Length <= 0 and os.clock() < lengthDeadline do
		if not self:_setChargeScale(session, session.CurrentScale, 1.45) then
			return false
		end
		RunService.Heartbeat:Wait()
	end
	local launchTime = if track.Length > 0
		then track.Length * CONFIG.CastLaunchNormalizedTime
		else 0.25
	local deadline = os.clock() + launchTime + 0.5
	while track.TimePosition < launchTime and os.clock() < deadline do
		if not self:_setChargeScale(session, session.CurrentScale, 1.45) then
			return false
		end
		RunService.Heartbeat:Wait()
	end
	return true
end

function CruelSun._getAimDirection(self: Controller, origin: Vector3): Vector3
	local camera = workspace.CurrentCamera
	if not camera then
		return Vector3.new(0, 0, -1)
	end
	local mouse = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = if player.Character then {player.Character} else {}
	local result = workspace:Raycast(ray.Origin, ray.Direction * CONFIG.MaxRange, parameters)
	local target = if result
		then result.Position
		else ray.Origin + ray.Direction * CONFIG.MaxRange
	local direction = target - origin
	return if direction.Magnitude > 0.01 then direction.Unit else camera.CFrame.LookVector
end

-- Raycasting the entire frame step prevents a fast projectile from tunnelling
-- through thin parts. Velocity supplies both gravity-bent motion and orientation.
function CruelSun._launchProjectile(self: Controller, sun: BasePart): Vector3
	self:_setPhase("Launching")
	local root = self:_getRoot()
	if root then
		local launchSound = self.Presentation:CreateSound("Launch", root)
		if launchSound then
			launchSound:Play()
			Debris:AddItem(launchSound, 3)
		end
	end
	local travelSound = self.Presentation:CreateSound("Traveling", sun)
	if travelSound then
		travelSound.Looped = true
		travelSound:Play()
	end
	local velocity = self:_getAimDirection(sun.Position) * CONFIG.ProjectileSpeed
	local travelled = 0
	local lastPosition = sun.Position
	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = if player.Character
		then {sun, player.Character}
		else {sun}
	while travelled < CONFIG.MaxRange and sun.Parent do
		local deltaTime = RunService.Heartbeat:Wait()
		velocity -= Vector3.new(0, CONFIG.GravityBend * deltaTime, 0)
		local step = velocity * deltaTime
		local result = workspace:Raycast(sun.Position, step, parameters)
		if result then
			lastPosition = result.Position
			break
		end
		local nextPosition = sun.Position + step
		sun.CFrame = CFrame.new(nextPosition, nextPosition + velocity)
		lastPosition = nextPosition
		travelled += step.Magnitude
	end
	self.Presentation:FadeSound(travelSound, 0.06)
	sun:Destroy()
	return lastPosition
end

function CruelSun._createExplosion(
	self: Controller,
	position: Vector3,
	chargePower: number,
	multiplier: number
): number
	self:_setPhase("Impacting")
	return self.Presentation:CreateExplosion(position, chargePower, multiplier)
end

function CruelSun._cleanup(self: Controller, session: CastSession?)
	self:_setPhase("Cleaning")
	local active = session or self.ActiveSession
	cleanupStep("presentation cleanup", function()
		if active then
			self.Presentation:FadeSound(active.ChargingSound, 0.1)
			self.Presentation:FadeSound(active.CrackleSound, 0.15)
			if active.CastTrack and active.CastTrack.IsPlaying then
				active.CastTrack:Stop(0.05)
			end
			if active.Sun.Parent then
				active.Sun:Destroy()
			end
		end
	end)
	cleanupStep("movement restoration", function()
		self:_unlockMovement()
	end)
	cleanupStep("temporary axe cleanup", function()
		self:_cleanupAxe()
	end)
	if self.ActiveSession == active then
		self.ActiveSession = nil
	end
	self:_setPhase("Idle")
end

-- No phase is spawned into a separate task. Sequential ownership makes failure
-- cleanup deterministic. Cooldown starts only after Commit, so failed setup or
-- cancellation before launch never punishes the player.
function CruelSun._cast(self: Controller, variant: AbilityVariant): boolean
	if self.Destroyed or not self:_lockMovement() then
		return false
	end
	local session: CastSession? = nil
	local signalStarted = false
	local signalReleased = false
	local networkStarted = false
	local impactResolved = false
	local committed = false
	local succeeded, failure = xpcall(function()
		session = self:_createSession(variant)
		if not session then
			return
		end
		self.ActiveSession = session
		self:_setPhase("Charging")
		fireSignal("CastStarted")
		signalStarted = true
		hitRemote:FireServer("Begin", variant.Name)
		networkStarted = true
		local chargePower = self:_charge(session)
		if chargePower == nil or not self:_playCastAnimation(session) then
			return
		end
		self.Presentation:FadeSound(session.ChargingSound, 0.1)
		self.Presentation:FadeSound(session.CrackleSound, 0.15)
		for _, emitter in session.LaunchEmitters do
			emitter.Enabled = true
		end
		hitRemote:FireServer("Commit", chargePower, session.Sun.Position)
		committed = true
		fireSignal("CastReleased", true)
		signalReleased = true
		local position = self:_launchProjectile(session.Sun)
		local radius = self:_createExplosion(
			position, chargePower, variant.ExplosionMultiplier
		)
		hitRemote:FireServer("Impact", position)
		fireSignal("Impact", position, radius, chargePower, variant.ExplosionMultiplier)
		impactResolved = true
	end, debug.traceback)
	if signalStarted and not signalReleased then
		fireSignal("CastReleased", false)
	end
	if networkStarted and not impactResolved then
		hitRemote:FireServer("Cancel")
	end
	self:_cleanup(session)
	if not succeeded then
		warn("Cruel Sun lifecycle failed:\n", failure)
	end
	return committed
end

function CruelSun.Start(self: Controller)
	if self.Destroyed or self.Input then
		return
	end
	self.Presentation:Preload()
	self.Input = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		local variant = VARIANT_BY_KEY[input.KeyCode]
		local identifier = input.KeyCode.Name
		if gameProcessed
			or self.IsCasting
			or not variant
			or cooldownRemaining(identifier) > 0
		then
			return
		end
		self.IsCasting = true
		local succeeded, launched = xpcall(function(): boolean
			return self:_cast(variant)
		end, debug.traceback)
		self.IsCasting = false
		if not succeeded then
			warn("Unhandled Cruel Sun input error:\n", launched)
		elseif launched then
			startCooldown(identifier, variant.Cooldown)
		end
	end)
end

function CruelSun.Destroy(self: Controller)
	if self.Destroyed then
		return
	end
	self.Destroyed = true
	self.Phase = "Destroyed"
	if self.Input then
		self.Input:Disconnect()
		self.Input = nil
	end
	self:_cleanup(self.ActiveSession)
end

local ability = CruelSun.new()
ability:Start()
