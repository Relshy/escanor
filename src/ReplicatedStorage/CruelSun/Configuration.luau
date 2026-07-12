--[[
Author(s)    @sillyrelshy
Date         12/07/26
Version      1.0.0
]]



--!strict
local Configuration: AbilityConfiguration = {
	MinScale = 0.1,

	ChargeOffset      = Vector3.new(0, 1, -3),
	ChargeForwardPush = 0.82,
	ChargeUpPush      = 0.12,

	AxeFirePointOffset = Vector3.new(3.9, 0, 3.05),
	AxeScaleLift       = 0.45,

	ChargePoseFadeTime        = 0.22,
	CastFadeTime              = 0.08,
	CastLaunchNormalizedTime  = 0.58,

	CompressedScale     = 0.65,
	CompressedMaxScale  = 1.8,
	CompressionDropTime = 0.24,
	CompressionHoldTime = 0.85,
	CompressionFinalTime = 0.36,

	ProjectileSpeed = 360,
	GravityBend     = 12,
	MaxRange        = 1000,

	ExplosionBaseScale     = 18,
	ExplosionChargeBonus   = 18,
	DefaultEmitCount       = 5,

	ShakeDistance  = 100,
	ShakeMagnitude = 0.8,
	ShakeDuration  = 0.35,

	Variants = {
		Compress = {
			Name                = "Compress",
			Key                 = Enum.KeyCode.E,
			Cooldown            = 3,
			MaxScale            = 8.5,
			ChargeTime          = 5.5,
			Condense            = true,
			ExplosionMultiplier = 1,
		},

		Giant = {
			Name                = "Giant",
			Key                 = Enum.KeyCode.V,
			Cooldown            = 6,
			MaxScale            = 25.5,
			ChargeTime          = 7,
			Condense            = false,
			ExplosionMultiplier = 3,
		},
	},

	Sounds = {
		Charging        = "rbxassetid://115535103935389",
		ChargingCrackle = "rbxassetid://89716538298369",
		Launch          = "rbxassetid://2157448269",
		CondenseDrop    = "rbxassetid://79833203443837",
		Traveling       = "rbxassetid://9119462937",
		ExplosionBoom   = "rbxassetid://113076931050699",
		ExplosionCrackle = "rbxassetid://140089926923698",
	},

	Volumes = {
		Charging         = 0.6,
		ChargingCrackle  = 0.35,
		Launch           = 0.5,
		CondenseDrop     = 0.8,
		Traveling        = 0.5,
		ExplosionBoom    = 3,
		ExplosionCrackle = 1.5,
	},

	Hitbox = {
		RadiusMultiplier  = 0.75,
		MinDamage         = 25,
		MaxDamage         = 100,
		EdgeDamageFraction = 0.3,
		MaximumRadius     = 400,
		RequestInterval   = 0.12,
	},

	ImpactFrames = {
		Enabled           = true,
		Image             = "",
		ImageTransparency = 1,
		WhiteTime         = 0.015,
		BlackTime         = 0.065,
		RecoverTime       = 0.08,
		WhiteTransparency = 1,
		BlackTransparency = 0.08,
		Brightness        = 0.18,
		Contrast          = 1.05,
		Saturation        = -1,
		TintColor         = Color3.fromRGB(255, 236, 184),
	},
}


table.freeze(Configuration.Variants.Compress)
table.freeze(Configuration.Variants.Giant)
table.freeze(Configuration.Variants)
table.freeze(Configuration.Sounds)
table.freeze(Configuration.Volumes)
table.freeze(Configuration.Hitbox)
table.freeze(Configuration.ImpactFrames)


type AbilityVariant = {
	Name                : string,
	Key                 : Enum.KeyCode,
	Cooldown            : number,
	MaxScale            : number,
	ChargeTime          : number,
	Condense            : boolean,
	ExplosionMultiplier : number,
}

type AbilityConfiguration = {
	MinScale                    : number,
	ChargeOffset                : Vector3,
	ChargeForwardPush           : number,
	ChargeUpPush                : number,
	AxeFirePointOffset          : Vector3,
	AxeScaleLift                : number,
	ChargePoseFadeTime          : number,
	CastFadeTime                : number,
	CastLaunchNormalizedTime    : number,
	CompressedScale             : number,
	CompressedMaxScale          : number,
	CompressionDropTime         : number,
	CompressionHoldTime         : number,
	CompressionFinalTime        : number,
	ProjectileSpeed             : number,
	GravityBend                 : number,
	MaxRange                    : number,
	ExplosionBaseScale          : number,
	ExplosionChargeBonus        : number,
	DefaultEmitCount            : number,
	ShakeDistance               : number,
	ShakeMagnitude              : number,
	ShakeDuration               : number,
	Variants                    : {
		Compress : AbilityVariant,
		Giant    : AbilityVariant,
	},
	Sounds                      : {[string]: string},
	Volumes                     : {[string]: number},
	Hitbox                      : {
		RadiusMultiplier   : number,
		MinDamage          : number,
		MaxDamage          : number,
		EdgeDamageFraction : number,
		MaximumRadius      : number,
		RequestInterval    : number,
	},
	ImpactFrames                : {
		Enabled           : boolean,
		Image             : string,
		ImageTransparency : number,
		WhiteTime         : number,
		BlackTime         : number,
		RecoverTime       : number,
		WhiteTransparency : number,
		BlackTransparency : number,
		Brightness        : number,
		Contrast          : number,
		Saturation        : number,
		TintColor         : Color3,
	},
}


return table.freeze(Configuration)
