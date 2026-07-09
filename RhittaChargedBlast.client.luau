-- Connected Discord-GitHub
--[[
	RhittaChargedBlast.client.luau
	Single-script Luau submission, demonstrated in my Roblox Escanor Submission place.
    This is hugely inspired by Escanor from the anime Seven Deadly Sins


	WHAT IT DOES
	Hold E (Compress variant) or V (Giant variant) to charge a Rhitta-style
	fireball in front of the character. Release the key to launch it toward the
	mouse cursor. On impact it spawns a charge-scaled explosion, deals radial
	falloff damage, and shakes nearby cameras.

	HOW THE PIECES FIT TOGETHER
	1. The InputBegan connection at the bottom is the single entry point. It
	   maps the pressed key to a variant table from CONFIG and gates the cast
	   behind a metatable-based cooldown tracker plus an isCasting flag.
	2. runAbility() orchestrates one full cast: it locks movement, clones the
	   fireball, rigs the axe prop to the hand, then runs chargeAbility() and
	   launchProjectile() in sequence.
	3. chargeAbility() grows the fireball every Heartbeat until the key is
	   released and returns a 0-1 "charge power". Everything downstream
	   (explosion size, damage, shake) is derived from that one number.
	4. launchProjectile() simulates the fireball manually with a raycast per
	   frame, then calls spawnExplosion() at the impact point.
	5. spawnExplosion() handles VFX scaling, sound, camera shake, and hands
	   off to damageInRadius().

	Everything runs on the client because this is primarily a VFX showcase.
	Damage is reported to the server through the optional FireBallHit remote
	when it exists (the server should always own damage in a real game);
	otherwise damageInRadius() falls back to local TakeDamage so the demo
	still functions in a plain place with no server code.

	Techniques shown: CFrame math (axe rigging, projectile orientation),
	raycast collision, Heartbeat simulation, metatables, runtime animation
	registration, NumberSequence rebuilding for particle scaling, and a wide
	spread of Roblox services.
]]

-- [ Services & assets ] -------------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContentProvider = game:GetService("ContentProvider")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")

local player = Players.LocalPlayer

-- All templates live under ReplicatedStorage.VFX.FireBall so the client can
-- clone them freely. WaitForChild is deliberate: these assets are required for
-- the ability to work at all, so if they are missing I want the script to
-- stall with an infinite-yield warning at startup instead of erroring later
-- in the middle of a cast.
local vfxFolder = ReplicatedStorage:WaitForChild("VFX"):WaitForChild("FireBall")
local fireballTemplate = vfxFolder:WaitForChild("FlamingSunVFX")
local explosionTemplate = vfxFolder:WaitForChild("FireBallExplosionVFX")
local axeTemplate = vfxFolder:WaitForChild("RhittaAxeTemplate")
local castKeyframes = vfxFolder:WaitForChild("RhittaBlastKeyframes")

-- The server remote is optional on purpose. When a FireBallHit remote exists
-- the server owns damage; when it doesn't, damage falls back to a local path
-- (see damageInRadius). It is resolved lazily and re-checked while unset:
-- a one-time FindFirstChild at startup would race a server that creates the
-- remote a moment after this client boots, and silently downgrade every cast
-- to local damage for the whole session.
local serverHitRemote = nil
local function getHitRemote()
	if not serverHitRemote or not serverHitRemote.Parent then
		serverHitRemote = ReplicatedStorage:FindFirstChild("FireBallHit")
	end
	return serverHitRemote
end

-- [ Tuning ] ------------------------------------------------------------------

-- Every gameplay number lives in this one table so balancing never means
-- hunting through logic. The two variants are pure data: the entire code
-- path below is shared, which is what keeps this one system instead of two
-- near-identical scripts.
local CONFIG = {
	-- Charge visuals: the ball starts tiny, held at ChargeOffset relative to
	-- the root. Each stud of growth beyond scale 1 also pushes it
	-- ChargeForwardPush studs forward and ChargeUpPush studs up
	-- (see chargeOffsetForScale) so the sphere never swallows the character.
	MinScale = 0.1,
	ChargeOffset = Vector3.new(0, 1, -3),
	ChargeForwardPush = 0.82,
	ChargeUpPush = 0.12,
	-- Axe anchor: where the ball hovers relative to the axe head, plus extra
	-- lift per stud of growth so a large ball clears the blade.
	AxeFirePointOffset = Vector3.new(3.9, 0, 3.05),
	AxeScaleLift = 0.45,
	-- Flight: constant launch speed with a gentle artificial drop. GravityBend
	-- is studs/s^2 and far below real gravity, so shots arc slightly but stay
	-- aimable. MaxRange is a hard cap so a shot into the sky cannot simulate
	-- forever.
	ProjectileSpeed = 360,
	GravityBend = 12,
	MaxRange = 1000,
	-- Impact: explosion visual size grows with charge power. The damage radius
	-- is intentionally smaller than the visual (HitboxRadiusMultiplier) so
	-- grazing the edge of the fire doesn't feel unfair, and damage falls off
	-- linearly down to EdgeDamageFraction at the very rim.
	ExplosionBaseScale = 18,
	ExplosionChargeBonus = 18,
	HitboxRadiusMultiplier = 0.75,
	MinDamage = 25,
	MaxDamage = 100,
	EdgeDamageFraction = 0.3,
	-- Camera shake scales down with distance and is skipped entirely past
	-- ShakeDistance, so far-away explosions don't jitter everyone's screen.
	ShakeDistance = 100,
	ShakeMagnitude = 0.8,
	ShakeDuration = 0.35,
	-- Scale the Compress variant condenses down to once fully charged.
	CompressedScale = 0.9,
	-- Burst size for emitters that don't author their own EmitCount attribute.
	DefaultEmitCount = 5,
	-- Compress: fully charging condenses the ball into a dense core before
	-- launch. Giant: longer charge, much larger ball, triple-size explosion.
	Variants = {
		Compress = {
			Name = "Compress",
			Key = Enum.KeyCode.E,
			Cooldown = 3,
			MaxScale = 8.5,
			ChargeTime = 5.5,
			Condense = true,
			ExplosionMultiplier = 1,
		},
		Giant = {
			Name = "Giant",
			Key = Enum.KeyCode.V,
			Cooldown = 6,
			MaxScale = 25.5,
			ChargeTime = 7,
			Condense = false,
			ExplosionMultiplier = 3,
		},
	},
	-- Audio is data too: makeSound() looks sounds up by name in both tables,
	-- so swapping an asset id or rebalancing volume never touches logic.
	Sounds = {
		Charging = "rbxassetid://115535103935389",
		Crackle = "rbxassetid://89716538298369",
		Launch = "rbxassetid://2157448269",
		Travel = "rbxassetid://9119462937",
		Explosion = "rbxassetid://113076931050699",
	},
	Volumes = {
		Charging = 0.6,
		Crackle = 0.35,
		Launch = 0.5,
		Travel = 0.5,
		Explosion = 3,
	},
}

-- [ Cooldown tracker ] ----------------------------------------------------------

-- Metatable-backed cooldown store, using the standard Luau OOP pattern
-- (constructor + __index methods). It is deliberately small: the point is to
-- keep input gating ("may this variant fire?") separate from ability
-- execution, so the input handler at the bottom stays trivial.
-- os.clock() is used instead of tick()/os.time() because it is monotonic and
-- high resolution: cooldowns can't be broken by system clock adjustments.
local Cooldowns = {}
Cooldowns.__index = Cooldowns

function Cooldowns.new()
	return setmetatable({ active = {} }, Cooldowns)
end

-- Ready when the id was never started, or its stored duration fully elapsed.
-- Expired records are simply overwritten by the next start(), so there is
-- nothing to clean up.
function Cooldowns:isReady(id)
	local record = self.active[id]
	return not record or os.clock() - record.startedAt >= record.duration
end

function Cooldowns:start(id, duration)
	self.active[id] = { startedAt = os.clock(), duration = duration }
end

-- [ Script state ] --------------------------------------------------------------

local cooldowns = Cooldowns.new()
-- Hard re-entry gate: only one cast may ever run at a time.
local isCasting = false
-- Animation caches, filled on first cast (see loadCastTrack): the registered
-- id is valid for the whole session, the loaded track only for the humanoid
-- it was loaded on.
local registeredCastId = nil
local cachedCastTrack = nil
local cachedCastHumanoid = nil
-- Keycode -> variant lookup, so the input handler is one table read instead
-- of an if/elseif chain that would need extending for every new variant.
local variantByKey = {
	[CONFIG.Variants.Compress.Key] = CONFIG.Variants.Compress,
	[CONFIG.Variants.Giant.Key] = CONFIG.Variants.Giant,
}

-- [ Character helpers ] -----------------------------------------------------------

-- These re-resolve the character on every call instead of caching parts once.
-- If the player dies or respawns mid-cast, callers get nil (which they treat
-- as "abort cleanly") rather than a reference to a destroyed instance.
local function getCharacter()
	return player.Character
end

local function getRoot()
	local character = getCharacter()
	return character and character:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
	local character = getCharacter()
	return character and character:FindFirstChildOfClass("Humanoid")
end

-- Movement is frozen during the charge so the growing ball stays anchored to
-- a predictable spot. The old values are stored as attributes ON the humanoid
-- rather than in local variables: if some other system had modified WalkSpeed
-- before the cast, we restore exactly what it set, and the values live on the
-- instance itself across the long yield through the charge loop.
-- MovementLocked is a cross-script contract: other movement controllers in
-- the place (the sprint script) poll this attribute every frame and stand
-- down while it is true. Without it they would fight this script over
-- WalkSpeed mid-cast and win, letting the player walk away from the charge.
local function lockMovement()
	local humanoid = getHumanoid()
	if not humanoid then return end
	humanoid:SetAttribute("OldWalkSpeed", humanoid.WalkSpeed)
	humanoid:SetAttribute("OldJumpPower", humanoid.JumpPower)
	humanoid:SetAttribute("MovementLocked", true)
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.AutoRotate = false
end

-- The 16/50 fallbacks are the Roblox defaults, covering the edge case where
-- the humanoid we unlock is a fresh respawn that never got the attributes.
local function unlockMovement()
	local humanoid = getHumanoid()
	if not humanoid then return end
	humanoid:SetAttribute("MovementLocked", false)
	humanoid.WalkSpeed = humanoid:GetAttribute("OldWalkSpeed") or 16
	humanoid.JumpPower = humanoid:GetAttribute("OldJumpPower") or 50
	humanoid.AutoRotate = true
end

-- [ Hold-position math ] ----------------------------------------------------------

-- "extra" is how many studs of scale the ball has beyond 1. The ball drifts
-- up and forward proportionally to that growth so the expanding sphere stays
-- readable in front of the player instead of engulfing the torso.
local function chargeOffsetForScale(scale)
	local extra = math.max(scale - 1, 0)
	return CONFIG.ChargeOffset + Vector3.new(0, extra * CONFIG.ChargeUpPush, -extra * CONFIG.ChargeForwardPush)
end

-- Where the ball should sit this frame. The preferred anchor is the axe's
-- fire-point attachment: its WorldCFrame already includes the arm's animation
-- pose, so the ball follows the swing for free, plus a lift that grows with
-- scale so a huge ball doesn't clip into the blade. If the axe failed to rig,
-- fall back to a root-relative offset; multiplying root.CFrame by a local
-- offset keeps the ball in front of the player even while they turn.
local function chargeCFrame(root, scale, firePoint)
	if firePoint and firePoint.Parent then
		local extra = math.max(scale - 1, 0)
		return firePoint.WorldCFrame + Vector3.new(0, extra * CONFIG.AxeScaleLift, 0)
	end
	return root.CFrame * CFrame.new(chargeOffsetForScale(scale))
end

-- [ Audio helpers ] ---------------------------------------------------------------

-- Sounds are built from the CONFIG tables at the moment they are needed and
-- parented to the object they belong to (ball, explosion, root) so they are
-- positional and move with it. Explosions get a much wider rolloff than the
-- charge/travel sounds: everyone nearby should hear an impact, but only the
-- caster needs to hear their own charge-up.
local function makeSound(name, parent)
	local soundId = CONFIG.Sounds[name]
	if not soundId then return nil end
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = soundId
	sound.Volume = CONFIG.Volumes[name] or 1
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = name == "Explosion" and 30 or 5
	sound.RollOffMaxDistance = name == "Explosion" and 3000 or 150
	sound.Parent = parent
	return sound
end

-- Tween the volume to zero, then let Debris delete the sound shortly after
-- the tween lands. Cutting a looped sound instantly reads as a bug; Debris
-- guarantees the instance is cleaned up even if this script stops running.
local function fadeSound(sound, duration)
	if not sound then return end
	TweenService:Create(sound, TweenInfo.new(duration or 0.15), { Volume = 0 }):Play()
	Debris:AddItem(sound, (duration or 0.15) + 0.25)
end

-- [ VFX scaling ] -----------------------------------------------------------------

-- ParticleEmitter.Size is a NumberSequence (size over particle lifetime), not
-- a plain number, so "scaling" one means rebuilding every keypoint with its
-- value and envelope multiplied. This is the Roblox-specific detail that
-- makes VFX scaling non-trivial compared to scaling parts.
local function scaleSequence(sequence, scale)
	local keypoints = {}
	for _, keypoint in ipairs(sequence.Keypoints) do
		table.insert(keypoints, NumberSequenceKeypoint.new(keypoint.Time, keypoint.Value * scale, keypoint.Envelope * scale))
	end
	return NumberSequence.new(keypoints)
end

-- Snapshot the ORIGINAL size of every part and emitter once, before any
-- scaling happens. applyScale() then always computes original * scale, so any
-- scale value is absolute and repeatable. Scaling in place every frame
-- (size *= factor) would compound floating point error and drift over a long
-- charge; snapshotting makes that impossible.
local function cacheScaleTargets(root)
	local parts = {}
	local emitters = {}
	if root:IsA("BasePart") then parts[root] = root.Size end
	for _, item in ipairs(root:GetDescendants()) do
		if item:IsA("BasePart") then
			parts[item] = item.Size
		elseif item:IsA("ParticleEmitter") then
			emitters[item] = item.Size
		end
	end
	return parts, emitters
end

-- Applies one absolute scale to every cached target. The .Parent checks skip
-- anything that was destroyed mid-cast instead of erroring on a dead
-- instance.
local function applyScale(parts, emitters, scale)
	for part, originalSize in pairs(parts) do
		if part.Parent then part.Size = originalSize * scale end
	end
	for emitter, originalSequence in pairs(emitters) do
		if emitter.Parent then emitter.Size = scaleSequence(originalSequence, scale) end
	end
end

-- [ Axe rig ] ---------------------------------------------------------------------

-- Anchors the charging fireball to the character's axe, and returns both the
-- fire-point attachment and a cleanup function the caller runs when the cast
-- ends.
-- REUSE, don't duplicate: if the character already holds an axe (for example
-- a persistent melee axe welded on by another script), we attach our
-- fire-point to that existing axe instead of cloning a second one on top.
-- Cloning every time would leave a second axe on a character that already has
-- one. We only build our own when the character is holding nothing, so the
-- ability still works on its own in a bare place.
-- The build steps for our own axe:
--   1. Find the right arm ("Right Arm" is R6, "RightHand" is R15, so both
--      names are checked).
--   2. Make every part non-colliding and massless so the weld can't fling the
--      character or fight the physics solver.
--   3. Move the whole model so its Handle sits at the grip attachment while
--      KEEPING the handle's authored rotation. CFrame.new(gripPos) *
--      handle rotation is the target frame; multiplying that by
--      handle.CFrame:Inverse() produces the world-space delta that maps the
--      handle's current frame onto the target. PivotTo applies the delta to
--      the whole model as one rigid move, so multi-part axes stay intact.
--   4. Lock the pose with a Motor6D whose C0 is the handle expressed in the
--      arm's object space. From here on the axe follows the arm through
--      every animation frame.
-- cleanup() always removes the fire-point. When this function built the axe
-- itself it also destroys the axe and its grip motor; a reused melee axe is
-- left alone.
local function equipAxe()
	local noop = function() end
	local character = getCharacter()
	local rightArm = character and (character:FindFirstChild("Right Arm") or character:FindFirstChild("RightHand"))
	if not rightArm or not rightArm:IsA("BasePart") then return nil, noop end
	-- Drop any fallback axe a previous cast failed to clean up, so we never
	-- reuse or stack our own leftover.
	local stale = character:FindFirstChild("RhittaAbilityAxe")
	if stale then stale:Destroy() end
	-- Prefer the melee axe the character already holds. Matching by name keeps
	-- this from adopting some unrelated handled model (a pet rig, a prop);
	-- "RhittaAxe" is the name the server-side equip script gives it.
	local axe
	local held = character:FindFirstChild("RhittaAxe")
	if held and held:IsA("Model") then
		local existingHandle = held:FindFirstChild("Handle")
		if existingHandle and existingHandle:IsA("BasePart") then
			axe = held
		end
	end
	local createdAxe = false
	-- The grip motor lives in the ARM, not the axe model, so it is tracked
	-- separately: destroying the axe alone would strand a dead Motor6D in the
	-- arm after every cast.
	local motor
	if not axe then
		axe = axeTemplate:Clone()
		axe.Name = "RhittaAbilityAxe"
		axe.Parent = character
		local handle = axe:FindFirstChild("Handle")
		if not handle or not handle:IsA("BasePart") then
			axe:Destroy()
			return nil, noop
		end
		createdAxe = true
		for _, item in ipairs(axe:GetDescendants()) do
			if item:IsA("BasePart") then
				item.Anchored = false
				item.CanCollide = false
				item.Massless = true
			end
		end
		local grip = rightArm:FindFirstChild("RightGripAttachment")
		local gripFrame = grip and grip.WorldCFrame or rightArm.CFrame * CFrame.new(0, -1, 0)
		local delta = (CFrame.new(gripFrame.Position) * handle.CFrame.Rotation) * handle.CFrame:Inverse()
		axe:PivotTo(delta * axe:GetPivot())
		motor = Instance.new("Motor6D")
		motor.Name = "AxeGrip"
		motor.Part0 = rightArm
		motor.Part1 = handle
		motor.C0 = rightArm.CFrame:ToObjectSpace(handle.CFrame)
		motor.Parent = rightArm
	end
	local handle = axe:FindFirstChild("Handle")
	-- The offset is authored against the template's Handle; the melee axe in
	-- this place shares that geometry, so the same offset lands correctly.
	local firePoint = Instance.new("Attachment")
	firePoint.Name = "AxeFirePoint"
	firePoint.CFrame = CFrame.new(CONFIG.AxeFirePointOffset)
	firePoint.Parent = handle
	local function cleanup()
		if firePoint then firePoint:Destroy() end
		if motor then motor:Destroy() end
		if createdAxe and axe and axe.Parent then axe:Destroy() end
	end
	return firePoint, cleanup
end

-- [ Animation ] --------------------------------------------------------------------

-- The cast animation is stored as a KeyframeSequence instance inside the VFX
-- folder rather than a published animation asset.
-- RegisterKeyframeSequence converts it into a temporary animation id at
-- runtime, which keeps the whole demo self-contained: nothing depends on an
-- animation uploaded under my account. The id is registered once and cached
-- in registeredCastId; registration and LoadAnimation are both wrapped in
-- pcall because they can fail while content is still streaming in, and a
-- missing animation should degrade to "cast without animation", never break
-- the cast. Action4 priority puts the swing above default movement anims.
local function loadCastTrack()
	local humanoid = getHumanoid()
	if not humanoid then return nil end
	-- Reuse the already-loaded track: LoadAnimation is not free, and
	-- rebuilding the Animation instance on every cast would be repeated work.
	-- The cache is keyed on the humanoid, so a respawn (new humanoid, new
	-- Animator) naturally invalidates it and forces a clean reload.
	if cachedCastTrack and cachedCastHumanoid == humanoid then
		return cachedCastTrack
	end
	local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator")
	animator.Parent = humanoid
	if not registeredCastId then
		local ok, id = pcall(function()
			return KeyframeSequenceProvider:RegisterKeyframeSequence(castKeyframes)
		end)
		if not ok then return nil end
		registeredCastId = id
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = registeredCastId
	local ok, track = pcall(function() return animator:LoadAnimation(animation) end)
	animation:Destroy()
	if not ok then return nil end
	track.Priority = Enum.AnimationPriority.Action4
	cachedCastTrack = track
	cachedCastHumanoid = humanoid
	return track
end

-- [ Aiming & camera feedback ] -------------------------------------------------------

-- Converts the 2D mouse position into a 3D aim direction: viewport point ->
-- world ray from the camera -> raycast up to 1000 studs, ignoring my own
-- character so I can't target myself. If the ray hits nothing (aiming at the
-- sky), aim at a far point along the ray so the shot still flies. The final
-- direction is measured from the BALL's position, not the camera, otherwise
-- shots would visibly angle away from where the ball actually is. The
-- magnitude guard avoids normalizing a near-zero vector when the aim point
-- sits practically on top of the ball.
local function aimDirection(origin)
	local camera = workspace.CurrentCamera
	local mouse = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = getCharacter() and { getCharacter() } or {}
	local result = workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
	local target = result and result.Position or ray.Origin + ray.Direction * 1000
	local direction = target - origin
	return direction.Magnitude > 0.01 and direction.Unit or camera.CFrame.LookVector
end

-- Impact feedback. Strength falls off linearly with distance and the whole
-- effect is skipped beyond ShakeDistance. BindToRenderStep at Camera priority
-- + 1 runs AFTER the default camera scripts each frame, so the random offset
-- is layered onto a freshly computed camera CFrame and never accumulates
-- frame over frame. alpha is squared for an ease-out so the shake dies down
-- smoothly, and the binding unbinds itself when the duration elapses. The
-- os.clock-based name keeps multiple overlapping shakes from colliding.
local function shakeCamera(position)
	local root = getRoot()
	if not root then return end
	local distance = (root.Position - position).Magnitude
	if distance > CONFIG.ShakeDistance then return end
	local strength = CONFIG.ShakeMagnitude * (1 - distance / CONFIG.ShakeDistance)
	local started = os.clock()
	local name = "RhittaShake_" .. tostring(started)
	RunService:BindToRenderStep(name, Enum.RenderPriority.Camera.Value + 1, function()
		local alpha = 1 - math.clamp((os.clock() - started) / CONFIG.ShakeDuration, 0, 1)
		if alpha <= 0 then
			RunService:UnbindFromRenderStep(name)
			return
		end
		local offset = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5)
		workspace.CurrentCamera.CFrame *= CFrame.new(offset * strength * alpha * alpha)
	end)
end

-- [ Damage & explosion ] --------------------------------------------------------------

-- Damage resolution, two paths:
--   Preferred: report the hit to the server and let it validate and apply
--   damage, because the client should never be authoritative in production.
--   Fallback (no remote in this place): apply damage locally so the demo
--   works standalone.
-- GetPartBoundsInRadius returns every part in range, so one rig shows up once
-- per limb; the `seen` set makes damage strictly once-per-humanoid. Falloff
-- is linear from full damage at the center down to EdgeDamageFraction at the
-- rim, measured from the model's PrimaryPart when it has one.
local function damageInRadius(position, radius, chargePower)
	local remote = getHitRemote()
	if remote then remote:FireServer(position, radius, chargePower) end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = getCharacter() and { getCharacter() } or {}
	local maxDamage = CONFIG.MinDamage + (CONFIG.MaxDamage - CONFIG.MinDamage) * chargePower
	local seen = {}
	for _, part in ipairs(workspace:GetPartBoundsInRadius(position, radius, params)) do
		local model = part:FindFirstAncestorOfClass("Model")
		local humanoid = model and model:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 and not seen[humanoid] then
			seen[humanoid] = true
			if not remote then
				local ref = (model.PrimaryPart and model.PrimaryPart.Position) or part.Position
				local alpha = math.clamp((ref - position).Magnitude / radius, 0, 1)
				local falloff = 1 - (1 - CONFIG.EdgeDamageFraction) * alpha
				humanoid:TakeDamage(maxDamage * falloff)
			end
		end
	end
end

-- Spawns the impact VFX at the hit point. The clone is made fully inert
-- (anchored, no collide/query/touch) because it is scenery, not physics, and
-- shouldn't block raycasts or hitboxes from other systems. Size scales with
-- how long the player charged, times the variant multiplier. Emitters fire a
-- single :Emit() burst rather than being left enabled, since an explosion is
-- an instant event and not a running stream. Each emitter can set its own
-- burst size through an EmitCount attribute in Studio. Debris guarantees the clone
-- disappears after the particles finish, even if anything above it errored.
local function spawnExplosion(position, chargePower, multiplier)
	local explosion = explosionTemplate:Clone()
	explosion.Anchored = true
	explosion.CanCollide = false
	explosion.CanQuery = false
	explosion.CanTouch = false
	explosion.CFrame = CFrame.new(position)
	explosion.Parent = workspace
	local scale = (CONFIG.ExplosionBaseScale + CONFIG.ExplosionChargeBonus * chargePower) * multiplier
	local parts, emitters = cacheScaleTargets(explosion)
	applyScale(parts, emitters, scale)
	for emitter in pairs(emitters) do
		emitter:Emit(emitter:GetAttribute("EmitCount") or CONFIG.DefaultEmitCount)
	end
	local sound = makeSound("Explosion", explosion)
	if sound then sound:Play() end
	shakeCamera(position)
	damageInRadius(position, scale * CONFIG.HitboxRadiusMultiplier, chargePower)
	Debris:AddItem(explosion, 6)
end

-- [ Charge & launch ] -----------------------------------------------------------------

-- The charge loop, once per Heartbeat while the key is held:
--   alpha is normalized charge time (0-1) and doubles as the "charge power"
--   returned to the caller. Damage and explosion size both come from it.
--   targetScale grows linearly from MinScale toward the variant's MaxScale.
--   Condense variants snap the TARGET down to CompressedScale once fully
--   charged; lastScale then chases the target at 18% per frame, easing the
--   shrink over several frames so the compression reads as a squeeze rather
--   than an instant pop (non-condensed growth snaps 1:1, factor 1).
--   The crackle loop's volume follows alpha so the audio intensifies in step
--   with the visual.
-- The hold is checked with IsKeyDown rather than an InputEnded connection:
-- the loop only acts once per frame anyway, so polling is exactly as
-- responsive as an event latch, there is no connection to manage or leak,
-- and IsKeyDown also reads false once the window loses focus, which is a case
-- InputEnded never fires for. That way alt-tabbing mid-charge can't leave the
-- player stuck charging at WalkSpeed 0. A release that lands during the yields
-- before this loop (sound/animation setup) is caught by the very first
-- check, so a quick tap fires a minimum-charge shot instead of being lost.
-- If the root disappears mid-charge (death), the loop breaks and returns the
-- power reached so far, letting the caller still resolve the cast cleanly.
local function chargeAbility(variant, ball, parts, emitters, firePoint, crackleSound)
	local start = os.clock()
	local chargePower = 0
	local lastScale = CONFIG.MinScale
	local condensed = false
	while UserInputService:IsKeyDown(variant.Key) do
		local alpha = math.clamp((os.clock() - start) / variant.ChargeTime, 0, 1)
		chargePower = alpha
		local targetScale = CONFIG.MinScale + (variant.MaxScale - CONFIG.MinScale) * alpha
		if variant.Condense and alpha >= 1 then
			condensed = true
			targetScale = CONFIG.CompressedScale
		end
		local root = getRoot()
		if not root then break end
		lastScale += (targetScale - lastScale) * (condensed and 0.18 or 1)
		ball.CFrame = chargeCFrame(root, lastScale, firePoint)
		applyScale(parts, emitters, lastScale)
		if crackleSound then crackleSound.Volume = CONFIG.Volumes.Crackle * alpha end
		RunService.Heartbeat:Wait()
	end
	return chargePower
end

-- Manual projectile flight, one step per Heartbeat. The ball is anchored and
-- moved by CFrame instead of using physics, because a client-owned physics
-- part would be at the mercy of network ownership and workspace gravity.
--   Velocity gets a small constant downward pull (GravityBend) each frame so
--   long shots arc instead of laser-lining.
--   Before each move, a raycast covers exactly this frame's step: that IS the
--   collision detection. Because the ray always spans the full step, a fast
--   ball can never tunnel through a thin wall between frames.
--   CFrame.new(pos, pos + velocity) keeps the ball oriented along its travel
--   direction, and `traveled` accumulates distance so MaxRange can cap a
--   shot fired into open sky.
-- On exit the ball is destroyed and the explosion is spawned at the impact
-- point, or at the last simulated position if the range cap ended the flight.
local function launchProjectile(ball, chargePower, variant)
	local velocity = aimDirection(ball.Position) * CONFIG.ProjectileSpeed
	local traveled = 0
	local lastPosition = ball.Position
	local hitPosition = nil
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ball, getCharacter() }
	local travelSound = makeSound("Travel", ball)
	if travelSound then travelSound.Looped = true; travelSound:Play() end
	while traveled < CONFIG.MaxRange do
		local dt = RunService.Heartbeat:Wait()
		velocity -= Vector3.new(0, CONFIG.GravityBend * dt, 0)
		local step = velocity * dt
		local result = workspace:Raycast(ball.Position, step, params)
		if result then
			hitPosition = result.Position
			lastPosition = result.Position
			break
		end
		local nextPosition = ball.Position + step
		ball.CFrame = CFrame.new(nextPosition, nextPosition + velocity)
		lastPosition = nextPosition
		traveled += step.Magnitude
	end
	fadeSound(travelSound, 0.06)
	ball:Destroy()
	spawnExplosion(hitPosition or lastPosition, chargePower, variant.ExplosionMultiplier)
end

-- [ Cast orchestration ] ----------------------------------------------------------------

-- One complete cast from key press to explosion. The ordering here matters:
--   1. Lock movement first, so the player can't walk out from under the
--      ball while it charges.
--   2. Create the ball and axe, and snapshot original sizes so all scaling
--      is absolute (see cacheScaleTargets).
--   3. Block inside chargeAbility until the key is released, then hold
--      briefly so the launch syncs with the swing keyframes.
--   4. Fade the charge audio, launch, and only restore movement once the
--      flight has fully resolved.
-- Everything after the movement lock can yield for seconds and touches
-- instances that may die mid-cast, so it runs inside pcall and the cleanup
-- after the pcall is unconditional: no error path can leak the ball into
-- workspace or leave the player frozen. The error is re-raised after cleanup
-- so the input handler decides how to report it.
-- Charge sounds are parented to the ball itself, so they travel with it and
-- get destroyed along with it, which leaves no orphaned sounds behind.
local function runAbility(variant)
	if not getRoot() then return end
	lockMovement()
	local ball
	local cleanupAxe
	local ok, err = pcall(function()
		ball = fireballTemplate:Clone()
		ball.Anchored = true
		ball.CanCollide = false
		ball.CanQuery = false
		ball.Parent = workspace
		local firePoint
		firePoint, cleanupAxe = equipAxe()
		local parts, emitters = cacheScaleTargets(ball)
		local charging = makeSound("Charging", ball)
		if charging then charging:Play() end
		local crackle = makeSound("Crackle", ball)
		if crackle then crackle.Looped = true; crackle.Volume = 0; crackle:Play() end
		local track = loadCastTrack()
		if track then track:Play(0.18, 1, 0) end
		local chargePower = chargeAbility(variant, ball, parts, emitters, firePoint, crackle)
		if track then track:AdjustSpeed(1); task.wait(0.35) end
		fadeSound(charging, 0.1)
		fadeSound(crackle, 0.15)
		-- The root is re-fetched here on purpose: a root captured before a
		-- multi-second charge could belong to an old character after a
		-- respawn, and parenting a sound to a destroyed part errors.
		local launchSound = makeSound("Launch", getRoot())
		if launchSound then launchSound:Play(); Debris:AddItem(launchSound, 3) end
		launchProjectile(ball, chargePower, variant)
	end)
	unlockMovement()
	if cleanupAxe then cleanupAxe() end
	if ball and ball.Parent then ball:Destroy() end
	if not ok then error(err, 0) end
end

-- [ Preload ] -----------------------------------------------------------------------

-- Warm the asset cache in the background so the FIRST cast doesn't hitch or
-- play silent sounds while assets stream in. Sounds have to exist as live
-- instances for PreloadAsync to fetch them, so muted temporaries are created,
-- preloaded, then destroyed. task.spawn keeps this entirely off the critical
-- path (input is hooked up immediately below), and the pcall means a failed
-- preload only costs us the warm-up, never functionality.
task.spawn(function()
	local preload = { fireballTemplate, explosionTemplate, axeTemplate, castKeyframes }
	for _, soundId in pairs(CONFIG.Sounds) do
		local sound = Instance.new("Sound")
		sound.SoundId = soundId
		sound.Volume = 0
		sound.Parent = SoundService
		table.insert(preload, sound)
	end
	pcall(function() ContentProvider:PreloadAsync(preload) end)
	for _, item in ipairs(preload) do if item:IsA("Sound") then item:Destroy() end end
end)

-- [ Input entry point ] ----------------------------------------------------------------

-- Single entry point for the whole ability. gameProcessed filters out keys
-- the engine already consumed (typing in chat, UI focus). isCasting and the
-- cooldown tracker gate re-entry. runAbility guarantees its own cleanup
-- (movement unlock, ball removal); the pcall here is the last line of
-- defense that reports the error and, crucially, lets isCasting reset, so
-- one failed cast can never wedge the ability shut for the whole session.
-- The cooldown intentionally starts when the cast RESOLVES rather than on
-- key press, so time spent holding a 7 second charge doesn't eat into the
-- cooldown.
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or isCasting then return end
	local variant = variantByKey[input.KeyCode]
	if not variant or not cooldowns:isReady(variant.Name) then return end
	isCasting = true
	local ok, err = pcall(runAbility, variant)
	if not ok then warn("Rhitta charged blast failed:", err) end
	cooldowns:start(variant.Name, variant.Cooldown)
	isCasting = false
end)
