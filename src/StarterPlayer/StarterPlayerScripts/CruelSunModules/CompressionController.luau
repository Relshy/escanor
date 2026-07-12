--[[
Author(s)    @sillyrelshy
Date         12/07/26
Version      1.0.0
]]



--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")


local systemFolder = ReplicatedStorage:WaitForChild("CruelSun")
local CONFIG       = require(systemFolder:WaitForChild("Configuration"))


local CompressionController = {}
CompressionController.__index = CompressionController



--[[
@param     EffectsController    effects    | The controller that displays compression pulses.
@return    Controller

Constructs the state machine that condenses a fully charged Cruel Sun.
]]
function CompressionController.new(effects: EffectsController): Controller
	return setmetatable({
		Effects = effects,
	}, CompressionController) :: any
end


--[[
@param     Controller       self           | The compression controller performing the transition.
@param     ChargeSession    session        | The active charge session.
@param     ScaleSetter      setScale       | The callback that updates the held sun.
@param     number           fromScale      | The scale at the beginning of the transition.
@param     number           toScale        | The scale at the end of the transition.
@param     number           duration       | The transition duration in seconds.
@param     number           volumeBoost    | The crackle volume multiplier.
@param     number           pitch          | The condensation sound's playback speed.
@return    boolean

Compresses the sun through one eased pulse while the cast key remains held.
]]
function CompressionController._dropToScale(
	self: Controller,
	session: ChargeSession,
	setScale: ScaleSetter,
	fromScale: number,
	toScale: number,
	duration: number,
	volumeBoost: number,
	pitch: number
): boolean
	self.Effects:PlayCondensePulse(session.Sun, fromScale, toScale, pitch)

	local startedAt = os.clock()

	while UserInputService:IsKeyDown(session.Variant.Key) do
		local alpha = math.clamp((os.clock() - startedAt) / duration, 0, 1)
		local eased = 1 - (1 - alpha) ^ 5
		local scale = fromScale + (toScale - fromScale) * eased

		if not setScale(scale, volumeBoost) then
			return false
		end

		if alpha >= 1 then
			return true
		end

		RunService.Heartbeat:Wait()
	end

	return false
end


--[[
@param     Controller       self           | The compression controller maintaining the scale.
@param     ChargeSession    session        | The active charge session.
@param     ScaleSetter      setScale       | The callback that updates the held sun.
@param     number           scale          | The scale to maintain.
@param     number           duration       | The hold duration in seconds.
@param     number           volumeBoost    | The crackle volume multiplier.
@return    boolean

Maintains a compression step while the cast key remains held.
]]
function CompressionController._holdScale(
	self: Controller,
	session: ChargeSession,
	setScale: ScaleSetter,
	scale: number,
	duration: number,
	volumeBoost: number
): boolean
	local startedAt = os.clock()

	while UserInputService:IsKeyDown(session.Variant.Key)
		and os.clock() - startedAt < duration
	do
		if not setScale(scale, volumeBoost) then
			return false
		end

		RunService.Heartbeat:Wait()
	end

	return UserInputService:IsKeyDown(session.Variant.Key)
end


--[[
@param     Controller       self           | The compression controller condensing the sun.
@param     ChargeSession    session        | The active charge session.
@param     number           chargeScale    | The scale reached before compression.
@param     number           chargePower    | The normalized charge of the cast.
@param     ScaleSetter      setScale       | The callback that updates the held sun.
@return    boolean

Runs the three-stage compression sequence used by the compressed variant.
]]
function CompressionController.Run(
	self: Controller,
	session: ChargeSession,
	chargeScale: number,
	chargePower: number,
	setScale: ScaleSetter
): boolean
	local compressed = CONFIG.CompressedScale
		+ (CONFIG.CompressedMaxScale - CONFIG.CompressedScale) * chargePower
	local firstStep  = compressed + (chargeScale - compressed) * 0.42
	local secondStep = compressed + (chargeScale - compressed) * 0.16

	if not self:_dropToScale(
		session,
		setScale,
		chargeScale,
		firstStep,
		CONFIG.CompressionDropTime,
		1.35,
		0.82
	) then
		return false
	end

	if not self:_holdScale(
		session,
		setScale,
		firstStep,
		CONFIG.CompressionHoldTime,
		1.2
	) then
		return false
	end

	if not self:_dropToScale(
		session,
		setScale,
		firstStep,
		secondStep,
		CONFIG.CompressionDropTime * 1.35,
		1.55,
		1
	) then
		return false
	end

	if not self:_holdScale(
		session,
		setScale,
		secondStep,
		CONFIG.CompressionHoldTime * 1.6,
		1.25
	) then
		return false
	end

	if not self:_dropToScale(
		session,
		setScale,
		secondStep,
		compressed,
		CONFIG.CompressionFinalTime,
		1.65,
		1.18
	) then
		return false
	end

	return setScale(compressed, 1.45)
end



type EffectsController = {
	PlayCondensePulse : (
		EffectsController,
		BasePart,
		number,
		number,
		number?
	) -> (),
}

type ChargeSession = {
	Variant      : {Key: Enum.KeyCode},
	Sun          : BasePart,
	CurrentScale : number,
}

type ScaleSetter = (number, number) -> boolean

export type Controller = typeof(setmetatable({} :: {
	Effects: EffectsController,
}, CompressionController))


return table.freeze(CompressionController)
