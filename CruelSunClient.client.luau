-- Connected Discord-GitHub
--[[
Author(s)    @sillyrelshy
Date         13/07/26
Version      2.0.0
]]

--!strict
local Debris                   = game:GetService("Debris")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local Players                  = game:GetService("Players")
local ReplicatedStorage        = game:GetService("ReplicatedStorage")
local RunService               = game:GetService("RunService")
local SoundService             = game:GetService("SoundService")
local TweenService             = game:GetService("TweenService")
local UserInputService         = game:GetService("UserInputService")

local player        = Players.LocalPlayer
local systemFolder  = ReplicatedStorage:WaitForChild("CruelSun")
local assetsFolder  = systemFolder:WaitForChild("Assets")
local remotesFolder = systemFolder:WaitForChild("Remotes")
local signalsFolder = systemFolder:FindFirstChild("Signals")
local cooldownStore = ReplicatedStorage:FindFirstChild("CooldownController")

local sunTemplate       = assetsFolder:WaitForChild("CruelSunProjectileVFX") :: BasePart
local explosionTemplate = assetsFolder:WaitForChild("CruelSunExplosionVFX") :: BasePart
local castKeyframes     = assetsFolder:WaitForChild("CruelSunKeyframes") :: KeyframeSequence
local hitRemote         = remotesFolder:WaitForChild("CruelSunHit") :: RemoteEvent

--[[
ARCHITECTURE

This is the complete client implementation in one submitted script. One object
owns one cast and advances it linearly through charge, optional compression,
animation, projectile flight, impact, and cleanup. Linear ownership makes every
temporary Instance and every cancellation path easy to audit.

The client owns input and presentation for responsiveness, but never decides
damage. Begin, Commit, Impact, and Cancel report observed phases to the server.
The server measures charge time, enforces cooldown, derives radius and damage
from trusted configuration, and rejects implausible positions.
]]

type AbilityVariant = {
	Name                : string,
	Key                 : Enum.KeyCode,
	Cooldown            : number,
	MaxScale            : number,
	ChargeTime          : number,
	Condense            : boolean,
	ExplosionMultiplier : number,
}
type CastPhase =
	"Idle" | "Charging" | "Compressing" | "Animating"
	| "Launching" | "Impacting" | "Cleaning" | "Destroyed"
type PartScaleMap = {[BasePart]: Vector3}
type EmitterScaleMap = {[ParticleEmitter]: NumberSequence}
type CastSession = {
	Variant        : AbilityVariant,
	Sun            : BasePart,
	Parts          : PartScaleMap,
	Emitters       : EmitterScaleMap,
	LaunchEmitters : {ParticleEmitter},
	FirePoint      : Attachment?,
	ChargingSound  : Sound?,
	CrackleSound   : Sound?,
	CastTrack      : AnimationTrack?,
	CurrentScale   : number,
}

local compressVariant: AbilityVariant = table.freeze({
	Name = "Compress", Key = Enum.KeyCode.E, Cooldown = 3,
	MaxScale = 8.5, ChargeTime = 5.5, Condense = true,
	ExplosionMultiplier = 1,
})
local giantVariant: AbilityVariant = table.freeze({
	Name = "Giant", Key = Enum.KeyCode.V, Cooldown = 6,
	MaxScale = 25.5, ChargeTime = 7, Condense = false,
	ExplosionMultiplier = 3,
})
local VARIANT_BY_KEY: {[Enum.KeyCode]: AbilityVariant} = {
	[compressVariant.Key] = compressVariant,
	[giantVariant.Key] = giantVariant,
}
local SOUND_IDS: {[string]: string} = table.freeze({
	Charging = "rbxassetid://115535103935389",
	ChargingCrackle = "rbxassetid://89716538298369",
	Launch = "rbxassetid://2157448269",
	CondenseDrop = "rbxassetid://79833203443837",
	Traveling = "rbxassetid://9119462937",
	ExplosionBoom = "rbxassetid://113076931050699",
	ExplosionCrackle = "rbxassetid://140089926923698",
})
local SOUND_VOLUMES: {[string]: number} = table.freeze({
	Charging = 0.6, ChargingCrackle = 0.35, Launch = 0.5,
	CondenseDrop = 0.8, Traveling = 0.5,
	ExplosionBoom = 3, ExplosionCrackle = 1.5,
})

local MIN_SCALE                   = 0.1
local CHARGE_POSE_FADE_TIME       = 0.22
local CAST_FADE_TIME              = 0.08
local CAST_LAUNCH_NORMALIZED_TIME = 0.58
local COMPRESSED_SCALE            = 0.65
local COMPRESSED_MAX_SCALE        = 1.8
local COMPRESSION_TIME            = 0.3
local PROJECTILE_SPEED            = 360
local GRAVITY_BEND                = 12
local MAX_RANGE                   = 1000
local EXPLOSION_BASE_SCALE        = 18
local EXPLOSION_CHARGE_BONUS      = 18
local HITBOX_RADIUS_MULTIPLIER    = 0.75
local AXE_FIRE_POINT_OFFSET       = Vector3.new(3.9, 0, 3.05)
local FALLBACK_CHARGE_OFFSET      = Vector3.new(0, 1, -3)

local CruelSun = {}
CruelSun.__index = CruelSun

local localCooldowns: {[string]: number} = {}

type Controller = typeof(setmetatable({} :: {
	RegisteredCastId   : string?,
	CachedCastTrack    : AnimationTrack?,
	CachedCastHumanoid : Humanoid?,
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

local function scaleSequence(sequence: NumberSequence, scale: number): NumberSequence
	local keypoints = {}
	for _, keypoint in sequence.Keypoints do
		table.insert(keypoints, NumberSequenceKeypoint.new(
			keypoint.Time,
			keypoint.Value * scale,
			keypoint.Envelope * scale
		))
	end
	return NumberSequence.new(keypoints)
end

-- Scaling always starts from recorded authored sizes. Multiplying the current
-- size each frame would accumulate floating-point error and distort particles.
local function getScaleTargets(root: Instance): (PartScaleMap, EmitterScaleMap)
	local parts: PartScaleMap = {}
	local emitters: EmitterScaleMap = {}
	if root:IsA("BasePart") then
		parts[root] = root.Size
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			parts[descendant] = descendant.Size
		elseif descendant:IsA("ParticleEmitter") then
			emitters[descendant] = descendant.Size
		end
	end
	return parts, emitters
end

local function applyScale(parts: PartScaleMap, emitters: EmitterScaleMap, scale: number)
	for part, originalSize in parts do
		if part.Parent then
			part.Size = originalSize * scale
		end
	end
	for emitter, originalSize in emitters do
		if emitter.Parent then
			emitter.Size = scaleSequence(originalSize, scale)
		end
	end
end

local function createSound(name: string, parent: Instance): Sound?
	local soundId = SOUND_IDS[name]
	if not soundId then
		return nil
	end
	local explosion = name == "ExplosionBoom" or name == "ExplosionCrackle"
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = soundId
	sound.Volume = SOUND_VOLUMES[name] or 1
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = if explosion then 30 else 5
	sound.RollOffMaxDistance = if explosion then 3000 else 150
	sound.Parent = parent
	return sound
end

-- Reparenting before a VFX is destroyed lets the sound fade instead of being
-- cut off with its former parent.
local function fadeSound(sound: Sound?, duration: number)
	if not sound or not sound.Parent then
		return
	end
	sound.Parent = SoundService
	TweenService:Create(sound, TweenInfo.new(duration), {Volume = 0}):Play()
	Debris:AddItem(sound, duration + 0.25)
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
		RegisteredCastId = nil,
		CachedCastTrack = nil,
		CachedCastHumanoid = nil,
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
	humanoid:SetAttribute("CruelSunWalkSpeed", humanoid.WalkSpeed)
	humanoid:SetAttribute("CruelSunJumpPower", humanoid.JumpPower)
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
	local walkSpeed = humanoid:GetAttribute("CruelSunWalkSpeed")
	local jumpPower = humanoid:GetAttribute("CruelSunJumpPower")
	humanoid.WalkSpeed = if typeof(walkSpeed) == "number" then walkSpeed else 16
	humanoid.JumpPower = if typeof(jumpPower) == "number" then jumpPower else 50
	humanoid.AutoRotate = true
end

-- The equipped axe is preferred, but root-relative placement remains a safe
-- fallback if another character system removes it during a cast.
function CruelSun._getFirePoint(self: Controller): Attachment?
	local character = player.Character
	local axe = character and character:FindFirstChild("EscanorAxe")
	if not axe or not axe:IsA("Model") then
		return nil
	end
	local handle = axe.PrimaryPart or axe:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then
		return nil
	end
	local existing = handle:FindFirstChild("CruelSunFirePoint")
	local firePoint = if existing and existing:IsA("Attachment")
		then existing
		else Instance.new("Attachment")
	firePoint.Name = "CruelSunFirePoint"
	firePoint.CFrame = CFrame.new(AXE_FIRE_POINT_OFFSET)
	firePoint.Visible = false
	firePoint.Parent = handle
	return firePoint
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
		return firePoint.WorldCFrame + Vector3.new(0, extraScale * 0.45, 0)
	end
	local root = self:_getRoot()
	if not root then
		return nil
	end
	local offset = FALLBACK_CHARGE_OFFSET
		+ Vector3.new(0, extraScale * 0.12, -extraScale * 0.82)
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

local function getLaunchEmitters(sun: BasePart): {ParticleEmitter}
	local result: {ParticleEmitter} = {}
	for _, descendant in sun:GetDescendants() do
		if descendant:IsA("ParticleEmitter")
			and (descendant.Name == "Dot Spec 1"
				or descendant.Name == "Star10"
				or descendant.Name == "CirclesFB4")
		then
			descendant.Enabled = false
			table.insert(result, descendant)
		end
	end
	return result
end

function CruelSun._createSession(
	self: Controller,
	variant: AbilityVariant
): CastSession?
	local firePoint = self:_getFirePoint()
	local sun = sunTemplate:Clone()
	sun.Name = "CruelSun"
	sun.Anchored = true
	sun.CanCollide = false
	sun.CanQuery = false
	sun.CanTouch = false
	sun.Parent = workspace
	local chargeCFrame = self:_getChargeCFrame(MIN_SCALE, firePoint)
	if not chargeCFrame then
		sun:Destroy()
		return nil
	end
	sun.CFrame = chargeCFrame
	local parts, emitters = getScaleTargets(sun)
	applyScale(parts, emitters, MIN_SCALE)
	local chargingSound = createSound("Charging", sun)
	local crackleSound = createSound("ChargingCrackle", sun)
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
		self:_stopCompetingAnimations(castTrack, CHARGE_POSE_FADE_TIME)
		castTrack:Play(CHARGE_POSE_FADE_TIME, 1, 0)
		castTrack.TimePosition = 0
		castTrack:AdjustSpeed(0)
	end
	return {
		Variant = variant,
		Sun = sun,
		Parts = parts,
		Emitters = emitters,
		LaunchEmitters = getLaunchEmitters(sun),
		FirePoint = firePoint,
		ChargingSound = chargingSound,
		CrackleSound = crackleSound,
		CastTrack = castTrack,
		CurrentScale = MIN_SCALE,
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
	applyScale(session.Parts, session.Emitters, scale)
	if session.CrackleSound then
		session.CrackleSound.Volume = SOUND_VOLUMES.ChargingCrackle * volumeBoost
	end
	return true
end

local function playCompressionPulse(sun: BasePart, fromScale: number, toScale: number)
	local pulse = Instance.new("Part")
	pulse.Name = "CruelSunCompression"
	pulse.Shape = Enum.PartType.Ball
	pulse.Anchored = true
	pulse.CanCollide = false
	pulse.CanQuery = false
	pulse.CanTouch = false
	pulse.Material = Enum.Material.Neon
	pulse.Color = Color3.fromRGB(255, 123, 35)
	pulse.Transparency = 0.48
	pulse.Size = Vector3.one * math.max(fromScale * 1.1, 1)
	pulse.CFrame = sun.CFrame
	pulse.Parent = workspace
	local sound = createSound("CondenseDrop", pulse)
	if sound then
		sound:Play()
	end
	TweenService:Create(
		pulse,
		TweenInfo.new(COMPRESSION_TIME, Enum.EasingStyle.Quint),
		{Size = Vector3.one * math.max(toScale, 0.5), Transparency = 1}
	):Play()
	Debris:AddItem(pulse, COMPRESSION_TIME + 0.1)
end

-- Quintic easing accelerates toward the compressed size, communicating force
-- rather than a uniform resize. Releasing the key cancels the transition and
-- launches at the most recent valid scale.
function CruelSun._compress(
	self: Controller,
	session: CastSession,
	fromScale: number,
	chargePower: number
): boolean
	self:_setPhase("Compressing")
	local targetScale = COMPRESSED_SCALE
		+ (COMPRESSED_MAX_SCALE - COMPRESSED_SCALE) * chargePower
	playCompressionPulse(session.Sun, fromScale, targetScale)
	local startedAt = os.clock()
	while UserInputService:IsKeyDown(session.Variant.Key) do
		local alpha = math.clamp((os.clock() - startedAt) / COMPRESSION_TIME, 0, 1)
		local eased = 1 - (1 - alpha) ^ 5
		local scale = fromScale + (targetScale - fromScale) * eased
		if not self:_setChargeScale(session, scale, 1 + alpha * 0.45) then
			return false
		end
		if alpha >= 1 then
			return true
		end
		RunService.Heartbeat:Wait()
	end
	return false
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
		local scale = MIN_SCALE
			+ (session.Variant.MaxScale - MIN_SCALE) * alpha
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
	self:_stopCompetingAnimations(track, CAST_FADE_TIME)
	if track.IsPlaying then
		track.TimePosition = 0
		track:AdjustWeight(1, CAST_FADE_TIME)
		track:AdjustSpeed(1)
	else
		track:Play(CAST_FADE_TIME, 1, 1)
	end
	local lengthDeadline = os.clock() + 1
	while track.Length <= 0 and os.clock() < lengthDeadline do
		if not self:_setChargeScale(session, session.CurrentScale, 1.45) then
			return false
		end
		RunService.Heartbeat:Wait()
	end
	local launchTime = if track.Length > 0
		then track.Length * CAST_LAUNCH_NORMALIZED_TIME
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
	local result = workspace:Raycast(ray.Origin, ray.Direction * MAX_RANGE, parameters)
	local target = if result then result.Position else ray.Origin + ray.Direction * MAX_RANGE
	local direction = target - origin
	return if direction.Magnitude > 0.01 then direction.Unit else camera.CFrame.LookVector
end

-- Raycasting the entire frame step prevents a fast projectile from tunnelling
-- through thin parts. Velocity supplies both gravity-bent motion and orientation.
function CruelSun._launchProjectile(self: Controller, sun: BasePart): Vector3
	self:_setPhase("Launching")
	local root = self:_getRoot()
	if root then
		local launchSound = createSound("Launch", root)
		if launchSound then
			launchSound:Play()
			Debris:AddItem(launchSound, 3)
		end
	end
	local travelSound = createSound("Traveling", sun)
	if travelSound then
		travelSound.Looped = true
		travelSound:Play()
	end
	local velocity = self:_getAimDirection(sun.Position) * PROJECTILE_SPEED
	local travelled = 0
	local lastPosition = sun.Position
	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = if player.Character
		then {sun, player.Character}
		else {sun}
	while travelled < MAX_RANGE and sun.Parent do
		local deltaTime = RunService.Heartbeat:Wait()
		velocity -= Vector3.new(0, GRAVITY_BEND * deltaTime, 0)
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
	fadeSound(travelSound, 0.06)
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
	local explosion = explosionTemplate:Clone()
	local scale = (
		EXPLOSION_BASE_SCALE + EXPLOSION_CHARGE_BONUS * math.clamp(chargePower, 0, 1)
	) * multiplier
	explosion.Anchored = true
	explosion.CanCollide = false
	explosion.CanQuery = false
	explosion.CanTouch = false
	explosion.CFrame = CFrame.new(position)
	explosion.Parent = workspace
	local parts, emitters = getScaleTargets(explosion)
	applyScale(parts, emitters, scale)
	for emitter in emitters do
		local count = emitter:GetAttribute("EmitCount")
		emitter:Emit(if typeof(count) == "number" then count else 5)
	end
	for _, name in {"ExplosionBoom", "ExplosionCrackle"} do
		local sound = createSound(name, explosion)
		if sound then
			sound:Play()
		end
	end
	Debris:AddItem(explosion, 6)
	return scale * HITBOX_RADIUS_MULTIPLIER
end

function CruelSun._cleanup(self: Controller, session: CastSession?)
	self:_setPhase("Cleaning")
	local active = session or self.ActiveSession
	cleanupStep("presentation cleanup", function()
		if active then
			fadeSound(active.ChargingSound, 0.1)
			fadeSound(active.CrackleSound, 0.15)
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
		fadeSound(session.ChargingSound, 0.1)
		fadeSound(session.CrackleSound, 0.15)
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
