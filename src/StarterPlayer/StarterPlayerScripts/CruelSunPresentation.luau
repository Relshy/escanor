--[[
Author(s)    @sillyrelshy
Date         14/07/26
Version      2.0.0
]]



--!strict
local ContentProvider   = game:GetService("ContentProvider")
local Debris            = game:GetService("Debris")
local Lighting          = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local SoundService      = game:GetService("SoundService")
local TweenService      = game:GetService("TweenService")


local systemFolder = ReplicatedStorage:WaitForChild("CruelSun")
local assetsFolder = systemFolder:WaitForChild("Assets")

local CONFIG            = require(systemFolder:WaitForChild("Configuration"))
local explosionTemplate = assetsFolder:WaitForChild("CruelSunExplosionVFX") :: BasePart


local PresentationController = {}
PresentationController.__index = PresentationController


--[[
Presentation is separated because visual and audio resources share one lifetime
but do not decide cast state. The submitted controller supplies normalized charge,
world positions, and variant scale; this module turns those trusted presentation
inputs into repeatable VFX without owning gameplay or networking.
]]



--[[
@param     NumberSequence    sequence    | The particle size sequence to scale.
@param     number            scale       | The multiplier applied to every keypoint.
@return    NumberSequence

Creates a scaled copy of the given NumberSequence.
]]
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


--[[
@param     Player    player    | The player receiving local visual and camera feedback.
@return    Controller

Constructs the effects controller used by a Cruel Sun ability.
]]
function PresentationController.new(player: Player): Controller
	return setmetatable({
		Player = player,
	}, PresentationController) :: any
end


--[[
@param     Controller    self    | The effects controller warming the asset cache.
@return    void

Preloads the visual, animation, voice, axe, and sound assets used by Cruel Sun.
]]
function PresentationController.Preload(self: Controller)
	task.spawn(function()
		local assets: {Instance} = {}

		for _, asset in assetsFolder:GetChildren() do
			if asset:IsA("BasePart")
				or asset:IsA("Model")
				or asset:IsA("KeyframeSequence")
				or asset:IsA("Sound")
			then
				table.insert(assets, asset)
			end
		end

		for _, soundId in CONFIG.Sounds do
			local sound = Instance.new("Sound")
			sound.SoundId = soundId
			sound.Volume  = 0
			sound.Parent  = SoundService
			table.insert(assets, sound)
		end

		local succeeded, failure = pcall(function()
			ContentProvider:PreloadAsync(assets)
		end)

		if not succeeded then
			warn("Cruel Sun asset preload failed:", failure)
		end

		for _, asset in assets do
			if asset:IsA("Sound") and asset.Parent == SoundService then
				asset:Destroy()
			end
		end
	end)
end


--[[
@param     Controller    self      | The effects controller creating the sound.
@param     string        name      | The configured name of the sound.
@param     Instance      parent    | The instance from which the sound should play.
@return    Sound?

Creates a spatial sound using the configured asset and volume.
]]
function PresentationController.CreateSound(self: Controller, name: string, parent: Instance): Sound?
	local soundId = CONFIG.Sounds[name]

	if not soundId then
		return nil
	end

	local isExplosion = name == "ExplosionBoom" or name == "ExplosionCrackle"
	local sound       = Instance.new("Sound")

	sound.Name               = name
	sound.SoundId            = soundId
	sound.Volume             = CONFIG.Volumes[name] or 1
	sound.RollOffMode        = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = if isExplosion then 30 else 5
	sound.RollOffMaxDistance = if isExplosion then 3000 else 150
	sound.Parent             = parent

	return sound
end


--[[
@param     Controller    self        | The effects controller fading the sound.
@param     Sound?        sound       | The sound whose volume should fade.
@param     number?       duration    | The fade duration in seconds.
@return    void

Detaches and fades a sound so destroying its former parent cannot cut it off.
]]
function PresentationController.FadeSound(self: Controller, sound: Sound?, duration: number?)
	if not sound or not sound.Parent then
		return
	end

	local fadeDuration = duration or 0.15
	local parent       = sound.Parent
	local position     = Vector3.zero

	if parent:IsA("BasePart") then
		position = parent.Position
	elseif parent:IsA("Attachment") then
		position = parent.WorldPosition
	end

	local origin = Instance.new("Part")
	origin.Name         = "CruelSunSoundHolder"
	origin.Anchored     = true
	origin.CanCollide   = false
	origin.CanQuery     = false
	origin.CanTouch     = false
	origin.Transparency = 1
	origin.Size         = Vector3.new(0.5, 0.5, 0.5)
	origin.CFrame       = CFrame.new(position)
	origin.Parent       = workspace

	sound.Parent = origin

	local tween = TweenService:Create(sound, TweenInfo.new(fadeDuration), {Volume = 0})
	tween:Play()

	Debris:AddItem(origin, fadeDuration + 0.5)
end


--[[
@param     Controller    self    | The effects controller recording scalable targets.
@param     Instance      root    | The root instance whose descendants should be recorded.
@return    PartScaleMap, EmitterScaleMap

Records original part and emitter sizes before any absolute scaling occurs.
]]
function PresentationController.GetScaleTargets(
	self: Controller,
	root: Instance
): (PartScaleMap, EmitterScaleMap)
	local parts: PartScaleMap       = {}
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


--[[
@param     Controller         self        | The effects controller applying the scale.
@param     PartScaleMap       parts       | The original sizes of the target parts.
@param     EmitterScaleMap    emitters    | The original sequences of the target emitters.
@param     number             scale       | The absolute scale to apply.
@return    void

Applies a repeatable absolute scale without accumulating floating-point drift.
]]
function PresentationController.ApplyScale(
	self: Controller,
	parts: PartScaleMap,
	emitters: EmitterScaleMap,
	scale: number
)
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


--[[
@param     Controller    self    | The effects controller querying the sun.
@param     BasePart      sun     | The Cruel Sun visual containing launch emitters.
@return    {ParticleEmitter}

Disables and returns the authored emitters that should begin only when the sun launches.
]]
function PresentationController.GetLaunchEmitters(self: Controller, sun: BasePart): {ParticleEmitter}
	local result: {ParticleEmitter} = {}
	local outer = sun:FindFirstChild("CruelSunOuter") or sun:FindFirstChild("Outer")
	local back  = outer and outer:FindFirstChild("Back")
	local front = outer and outer:FindFirstChild("Front")

	local candidates = {
		back and back:FindFirstChild("Dot Spec 1"),
		back and back:FindFirstChild("Star10"),
		front and front:FindFirstChild("CirclesFB4"),
	}

	for _, candidate in candidates do
		if candidate and candidate:IsA("ParticleEmitter") then
			candidate.Enabled = false
			table.insert(result, candidate)
		end
	end

	return result
end


--[[
@param     Controller    self         | The effects controller creating the pulse.
@param     BasePart      sun          | The sun around which the pulse is displayed.
@param     number        fromScale    | The scale from which the pulse begins.
@param     number        toScale      | The scale toward which the pulse collapses.
@param     number?       pitch        | The playback speed of the condensation sound.
@return    void

Creates the brief light and sound pulse that communicates a compression step.
]]
function PresentationController.PlayCondensePulse(
	self: Controller,
	sun: BasePart,
	fromScale: number,
	toScale: number,
	pitch: number?
)
	if not sun.Parent then
		return
	end

	local pulse = Instance.new("Part")
	pulse.Name         = "CruelSunCondensePulse"
	pulse.Shape        = Enum.PartType.Ball
	pulse.Anchored     = true
	pulse.CanCollide   = false
	pulse.CanQuery     = false
	pulse.CanTouch     = false
	pulse.Material     = Enum.Material.Neon
	pulse.Color        = Color3.fromRGB(255, 123, 35)
	pulse.Transparency = 0.48
	pulse.Size         = Vector3.one * math.max(fromScale * 1.15, 1.2)
	pulse.CFrame       = sun.CFrame
	pulse.Parent       = workspace

	local light = Instance.new("PointLight")
	light.Color      = Color3.fromRGB(255, 145, 57)
	light.Brightness = 5
	light.Range      = math.max(fromScale * 5, 8)
	light.Parent     = pulse

	local sound = self:CreateSound("CondenseDrop", pulse)

	if sound then
		sound.PlaybackSpeed = pitch or 1
		sound:Play()
	end

	local tweenInfo = TweenInfo.new(0.16, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	TweenService:Create(pulse, tweenInfo, {
		Size = Vector3.one * math.max(toScale * 0.9, 0.55),
		Transparency = 1,
	}):Play()
	TweenService:Create(light, tweenInfo, {
		Brightness = 0,
		Range = math.max(toScale * 3, 4),
	}):Play()

	Debris:AddItem(pulse, 1.2)
end


--[[
@param     Controller    self    | The effects controller displaying the frames.
@return    void

Displays the authored white-to-black impact flash and colour correction.
]]
function PresentationController.PlayImpactFrames(self: Controller)
	local settings = CONFIG.ImpactFrames

	if not settings.Enabled then
		return
	end

	local playerGui = self.Player:FindFirstChildOfClass("PlayerGui")

	if not playerGui then
		return
	end

	local gui = Instance.new("ScreenGui")
	gui.Name           = "CruelSunImpactFrames"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn   = false
	gui.DisplayOrder   = 100000
	gui.Parent         = playerGui

	local frame = Instance.new("Frame")
	frame.Size                   = UDim2.fromScale(1, 1)
	frame.BorderSizePixel        = 0
	frame.BackgroundColor3       = Color3.new(1, 1, 1)
	frame.BackgroundTransparency = settings.WhiteTransparency
	frame.Parent                 = gui

	local correction = Instance.new("ColorCorrectionEffect")
	correction.Name       = "CruelSunImpactColour"
	correction.Brightness = settings.Brightness
	correction.Contrast   = settings.Contrast
	correction.Saturation = settings.Saturation
	correction.TintColor  = settings.TintColor
	correction.Parent     = Lighting

	task.wait(settings.WhiteTime)

	frame.BackgroundColor3       = Color3.new(0, 0, 0)
	frame.BackgroundTransparency = settings.BlackTransparency
	correction.Brightness        = -0.08
	correction.Contrast          = settings.Contrast * 0.7
	correction.TintColor         = Color3.new(1, 1, 1)

	task.wait(settings.BlackTime)

	local recover = TweenInfo.new(settings.RecoverTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(frame, recover, {BackgroundTransparency = 1}):Play()
	TweenService:Create(correction, recover, {
		Brightness = 0,
		Contrast = 0,
		Saturation = 0,
		TintColor = Color3.new(1, 1, 1),
	}):Play()

	task.wait(settings.RecoverTime)
	gui:Destroy()
	correction:Destroy()
end


--[[
@param     Controller    self        | The effects controller shaking the camera.
@param     Vector3       position    | The world-space origin of the impact.
@return    void

Applies distance-scaled positional and rotational camera shake after the camera updates.
]]
function PresentationController.ShakeCamera(self: Controller, position: Vector3)
	local character = self.Player.Character
	local root      = character and character:FindFirstChild("HumanoidRootPart")

	if not root or not root:IsA("BasePart") then
		return
	end

	local distance = (root.Position - position).Magnitude

	if distance > CONFIG.ShakeDistance then
		return
	end

	local strength  = CONFIG.ShakeMagnitude * (1 - distance / CONFIG.ShakeDistance)
	local startedAt = os.clock()
	local binding   = `CruelSunShake_{startedAt}`

	RunService:BindToRenderStep(binding, Enum.RenderPriority.Camera.Value + 1, function()
		local camera = workspace.CurrentCamera
		local alpha  = 1 - math.clamp((os.clock() - startedAt) / CONFIG.ShakeDuration, 0, 1)

		if alpha <= 0 or not camera then
			RunService:UnbindFromRenderStep(binding)
			return
		end

		local decay = alpha ^ 2
		local offset = Vector3.new(
			math.random() * 2 - 1,
			math.random() * 2 - 1,
			math.random() * 2 - 1
		) * strength * decay
		local rotation = Vector3.new(
			math.random() * 2 - 1,
			math.random() * 2 - 1,
			math.random() * 2 - 1
		) * strength * 0.15 * decay

		camera.CFrame *= CFrame.new(offset) * CFrame.Angles(rotation.X, rotation.Y, rotation.Z)
	end)
end


--[[
@param     Controller    self             | The effects controller resolving the explosion.
@param     Vector3       position         | The world-space impact position.
@param     number        chargePower      | The normalized charge of Cruel Sun.
@param     number        sizeMultiplier   | The selected variant's size multiplier.
@return    number

Creates all impact VFX and returns the resulting gameplay hitbox radius.
]]
function PresentationController.CreateExplosion(
	self: Controller,
	position: Vector3,
	chargePower: number,
	sizeMultiplier: number
): number
	local explosion = explosionTemplate:Clone()
	local scale = (
		CONFIG.ExplosionBaseScale
		+ CONFIG.ExplosionChargeBonus * math.clamp(chargePower, 0, 1)
	) * sizeMultiplier

	explosion.Anchored   = true
	explosion.CanCollide = false
	explosion.CanQuery   = false
	explosion.CanTouch   = false
	explosion.CFrame     = CFrame.new(position)
	explosion.Parent     = workspace

	for _, descendant in explosion:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end

	local parts, emitters = self:GetScaleTargets(explosion)
	self:ApplyScale(parts, emitters, scale)

	for emitter in emitters do
		local count = emitter:GetAttribute("EmitCount")
		emitter:Emit(if typeof(count) == "number" then count else CONFIG.DefaultEmitCount)
	end

	for _, soundName in {"ExplosionBoom", "ExplosionCrackle"} do
		local sound = self:CreateSound(soundName, explosion)

		if sound then
			sound:Play()
		end
	end

	task.spawn(function()
		self:PlayImpactFrames()
	end)
	self:ShakeCamera(position)

	Debris:AddItem(explosion, 6)

	return scale * CONFIG.Hitbox.RadiusMultiplier
end



export type Controller = typeof(setmetatable({} :: {
	Player: Player,
}, PresentationController))

export type PartScaleMap = {[BasePart]: Vector3}
export type EmitterScaleMap = {[ParticleEmitter]: NumberSequence}

type PartScaleMap = {[BasePart]: Vector3}
type EmitterScaleMap = {[ParticleEmitter]: NumberSequence}


return table.freeze(PresentationController)
