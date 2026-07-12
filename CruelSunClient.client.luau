-- Connected Discord-GitHub
--[[
Author(s)    Janss
Date         12/07/26
Version      1.0.0
]]



--!strict
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")


local player        = Players.LocalPlayer
local systemFolder  = ReplicatedStorage:WaitForChild("CruelSun")
local assetsFolder  = systemFolder:WaitForChild("Assets")
local signalsFolder = systemFolder:WaitForChild("Signals")
local modulesFolder = script.Parent:WaitForChild("CruelSunModules")

local CONFIG               = require(systemFolder:WaitForChild("Configuration"))
local Cooldowns             = require(ReplicatedStorage:WaitForChild("CooldownController"))
local CharacterController   = require(modulesFolder:WaitForChild("CharacterController"))
local CompressionController = require(modulesFolder:WaitForChild("CompressionController"))
local EffectsController     = require(modulesFolder:WaitForChild("EffectsController"))
local ImpactController      = require(modulesFolder:WaitForChild("ImpactController"))
local ProjectileController  = require(modulesFolder:WaitForChild("ProjectileController"))

local sunTemplate       = assetsFolder:WaitForChild("CruelSunProjectileVFX") :: BasePart
local castStartedSignal = signalsFolder:WaitForChild("CastStarted") :: BindableEvent
local castEndedSignal   = signalsFolder:WaitForChild("CastEnded") :: BindableEvent


local CruelSun = {}
CruelSun.__index = CruelSun

local variantByKey: {[Enum.KeyCode]: AbilityVariant} = {
	[CONFIG.Variants.Compress.Key] = CONFIG.Variants.Compress,
	[CONFIG.Variants.Giant.Key]    = CONFIG.Variants.Giant,
}



--[[
@return    Controller

Constructs the local Cruel Sun ability and its specialized controllers.
]]
function CruelSun.new(): Controller
	local effects = EffectsController.new(player)

	return setmetatable({
		Character   = CharacterController.new(player),
		Compression = CompressionController.new(effects),
		Effects     = effects,
		Impact     = ImpactController.new(player),
		Projectile = ProjectileController.new(player, effects),
		IsCasting  = false,
		Input      = nil,
	}, CruelSun) :: any
end


--[[
@param     Controller      self       | The ability creating the cast session.
@param     AbilityVariant  variant    | The selected Cruel Sun variant.
@return    CastSession?

Creates and initializes every resource whose lifetime belongs to a single cast.
]]
function CruelSun._createSession(self: Controller, variant: AbilityVariant): CastSession?
	local firePoint = self.Character:PrepareAxe()

	if not firePoint then
		return nil
	end

	local sun = sunTemplate:Clone()
	sun.Name       = "CruelSun"
	sun.Anchored   = true
	sun.CanCollide = false
	sun.CanQuery   = false
	sun.CanTouch   = false
	sun.Parent     = workspace

	local chargeCFrame = self.Character:GetChargeCFrame(CONFIG.MinScale, firePoint)

	if not chargeCFrame then
		sun:Destroy()
		return nil
	end

	sun.CFrame = chargeCFrame

	local parts, emitters = self.Effects:GetScaleTargets(sun)
	self.Effects:ApplyScale(parts, emitters, CONFIG.MinScale)

	local chargingSound = self.Effects:CreateSound("Charging", sun)
	local crackleSound  = self.Effects:CreateSound("ChargingCrackle", sun)

	if chargingSound then
		chargingSound:Play()
	end

	if crackleSound then
		crackleSound.Looped = true
		crackleSound.Volume = 0
		crackleSound:Play()
	end

	local castTrack = self.Character:GetCastTrack()

	if castTrack then
		self.Character:StopCompetingAnimations(castTrack, CONFIG.ChargePoseFadeTime)
		castTrack:Play(CONFIG.ChargePoseFadeTime, 1, 0)
		castTrack.TimePosition = 0
		castTrack:AdjustSpeed(0)
	end

	return {
		Variant        = variant,
		Sun            = sun,
		Parts          = parts,
		Emitters       = emitters,
		LaunchEmitters = self.Effects:GetLaunchEmitters(sun),
		FirePoint      = firePoint,
		ChargingSound  = chargingSound,
		CrackleSound   = crackleSound,
		CastTrack      = castTrack,
		CurrentScale   = CONFIG.MinScale,
	}
end


--[[
@param     Controller     self           | The ability updating the cast.
@param     CastSession    session        | The active cast session.
@param     number         scale          | The absolute scale to apply.
@param     number         volumeBoost    | The multiplier applied to charge crackle volume.
@return    boolean

Updates the held sun's position, size, and charge audio for the current frame.
]]
function CruelSun._setChargeScale(
	self: Controller,
	session: CastSession,
	scale: number,
	volumeBoost: number
): boolean
	local target = self.Character:GetChargeCFrame(scale, session.FirePoint)

	if not target or not session.Sun.Parent then
		return false
	end

	session.CurrentScale = scale
	session.Sun.CFrame   = target
	self.Effects:ApplyScale(session.Parts, session.Emitters, scale)

	if session.CrackleSound then
		session.CrackleSound.Volume = CONFIG.Volumes.ChargingCrackle * volumeBoost
	end

	return true
end


--[[
@param     Controller     self       | The ability charging the sun.
@param     CastSession    session    | The active cast session.
@return    number?

Charges Cruel Sun until its key is released and returns normalized charge power.
]]
function CruelSun._charge(self: Controller, session: CastSession): number?
	local startedAt   = os.clock()
	local chargePower = 0

	while UserInputService:IsKeyDown(session.Variant.Key) do
		local alpha = math.clamp(
			(os.clock() - startedAt) / session.Variant.ChargeTime,
			0,
			1
		)
		local chargeScale = CONFIG.MinScale
			+ (session.Variant.MaxScale - CONFIG.MinScale) * alpha

		chargePower = alpha

		if not self:_setChargeScale(session, chargeScale, alpha) then
			return nil
		end

		if alpha >= 1 and session.Variant.Condense then
			local condensed = self.Compression:Run(
				session,
				chargeScale,
				chargePower,
				function(scale: number, volumeBoost: number): boolean
					return self:_setChargeScale(session, scale, volumeBoost)
				end
			)

			if not condensed then
				return if self.Character:GetRoot() then chargePower else nil
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


--[[
@param     Controller     self       | The ability synchronizing the animation.
@param     CastSession    session    | The active cast session.
@return    void

Advances the paused cast animation until the authored launch moment is reached.
]]
function CruelSun._playCastAnimation(self: Controller, session: CastSession)
	local track = session.CastTrack

	if not track then
		return
	end

	self.Character:StopCompetingAnimations(track, CONFIG.CastFadeTime)

	if track.IsPlaying then
		track.TimePosition = 0
		track:AdjustWeight(1, CONFIG.CastFadeTime)
		track:AdjustSpeed(1)
	else
		track:Play(CONFIG.CastFadeTime, 1, 1)
		track.TimePosition = 0
	end

	local lengthDeadline = os.clock() + 1

	while track.Length <= 0 and os.clock() < lengthDeadline do
		if not self:_setChargeScale(session, session.CurrentScale, 1.45) then
			return
		end

		RunService.Heartbeat:Wait()
	end

	local launchTime = if track.Length > 0
		then track.Length * CONFIG.CastLaunchNormalizedTime
		else 0.25
	local deadline = os.clock() + math.max(launchTime, 0.05) + 0.5

	while track.TimePosition < launchTime and os.clock() < deadline do
		if not self:_setChargeScale(session, session.CurrentScale, 1.45) then
			return
		end

		RunService.Heartbeat:Wait()
	end
end


--[[
@param     Controller     self       | The ability cleaning the session.
@param     CastSession?   session    | The cast session whose resources should be released.
@return    void

Releases sounds, visuals, movement, and temporary character state on every exit path.
]]
function CruelSun._cleanup(self: Controller, session: CastSession?)
	if session then
		self.Effects:FadeSound(session.ChargingSound, 0.1)
		self.Effects:FadeSound(session.CrackleSound, 0.15)

		if session.CastTrack and session.CastTrack.IsPlaying then
			session.CastTrack:Stop(0.05)
		end

		if session.Sun.Parent then
			session.Sun:Destroy()
		end
	end

	self.Character:CleanupCast()
	self.Character:UnlockMovement()
end


--[[
@param     Controller      self       | The ability executing the cast.
@param     AbilityVariant  variant    | The selected Cruel Sun variant.
@return    void

Orchestrates one complete cast while isolating and cleaning every yielding stage.
]]
function CruelSun._cast(self: Controller, variant: AbilityVariant)
	if not self.Character:LockMovement() then
		return
	end

	local session: CastSession? = nil
	local signalStarted = false
	local signalEnded   = false

	local succeeded, failure = pcall(function()
		session = self:_createSession(variant)

		if not session then
			return
		end

		castStartedSignal:Fire()
		signalStarted = true

		local chargePower = self:_charge(session)

		if chargePower == nil then
			return
		end

		self:_playCastAnimation(session)
		self.Effects:FadeSound(session.ChargingSound, 0.1)
		self.Effects:FadeSound(session.CrackleSound, 0.15)

		for _, emitter in session.LaunchEmitters do
			emitter.Enabled = true
		end

		castEndedSignal:Fire(true)
		signalEnded = true

		local impactPosition = self.Projectile:Launch(session.Sun)
		local hitboxRadius = self.Effects:CreateExplosion(
			impactPosition,
			chargePower,
			variant.ExplosionMultiplier
		)

		self.Impact:Resolve(
			impactPosition,
			hitboxRadius,
			chargePower,
			variant.ExplosionMultiplier
		)
	end)

	if signalStarted and not signalEnded then
		castEndedSignal:Fire(false)
	end

	self:_cleanup(session)

	if not succeeded then
		warn("Cruel Sun failed:", failure)
	end
end


--[[
@param     Controller    self    | The ability receiving player input.
@return    void

Registers input and begins background preloading for Cruel Sun.
]]
function CruelSun.Start(self: Controller)
	self.Effects:Preload()

	self.Input = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		local variant    = variantByKey[input.KeyCode]
		local identifier = input.KeyCode.Name

		if gameProcessed
			or self.IsCasting
			or not variant
			or not Cooldowns.IsReady(identifier)
		then
			return
		end

		self.IsCasting = true
		self:_cast(variant)
		Cooldowns.Start(identifier, variant.Cooldown)
		self.IsCasting = false
	end)
end


--[[
@param     Controller    self    | The ability being destroyed.
@return    void

Disconnects input and removes any remaining cast state.
]]
function CruelSun.Destroy(self: Controller)
	if self.Input then
		self.Input:Disconnect()
		self.Input = nil
	end

	self:_cleanup(nil)
end



type AbilityVariant = typeof(CONFIG.Variants.Compress)

type CastSession = {
	Variant        : AbilityVariant,
	Sun            : BasePart,
	Parts          : EffectsController.PartScaleMap,
	Emitters       : EffectsController.EmitterScaleMap,
	LaunchEmitters : {ParticleEmitter},
	FirePoint      : Attachment?,
	ChargingSound  : Sound?,
	CrackleSound   : Sound?,
	CastTrack      : AnimationTrack?,
	CurrentScale   : number,
}

type Controller = typeof(setmetatable({} :: {
	Character   : CharacterController.Controller,
	Compression : CompressionController.Controller,
	Effects     : EffectsController.Controller,
	Impact     : ImpactController.Controller,
	Projectile : ProjectileController.Controller,
	IsCasting  : boolean,
	Input      : RBXScriptConnection?,
}, CruelSun))


local ability = CruelSun.new()
ability:Start()
