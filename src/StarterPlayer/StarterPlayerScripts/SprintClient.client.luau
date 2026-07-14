--[[
Author(s)    @sillyrelshy
Date         14/07/26
Version      2.1.0
]]

--!strict
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")

local player = Players.LocalPlayer
local systemFolder = ReplicatedStorage:WaitForChild("CruelSun")
local CONFIG = require(systemFolder:WaitForChild("Configuration"))

local SPRINT_KEY = Enum.KeyCode.LeftShift
local WALK_SPEED = 16
local SPRINT_SPEED = 28
local TRACK_FADE_TIME = 0.15

local humanoid: Humanoid? = nil
local walkTrack: AnimationTrack? = nil
local sprintTrack: AnimationTrack? = nil

local function loadMovementTrack(
	activeHumanoid: Humanoid,
	name: string,
	animationId: string,
	priority: Enum.AnimationPriority
): AnimationTrack?
	local animator = activeHumanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = activeHumanoid
	end
	local animation = Instance.new("Animation")
	animation.Name = name
	animation.AnimationId = animationId
	local succeeded, track = pcall(function(): AnimationTrack
		return animator:LoadAnimation(animation)
	end)
	animation:Destroy()
	if not succeeded then
		warn(`Could not load {name} animation:`, track)
		return nil
	end
	track.Priority = priority
	track.Looped = true
	return track
end

-- ChildAdded covers the engine recreating Running after spawn without a
-- permanent polling loop or repeatedly traversing the character.
local function muteRunningSound(character: Model)
	local root = character:WaitForChild("HumanoidRootPart", 5)
	if not root then
		return
	end
	local function silence(instance: Instance)
		if instance:IsA("Sound") and instance.Name == "Running" then
			instance.Volume = 0
		end
	end
	for _, child in root:GetChildren() do
		silence(child)
	end
	root.ChildAdded:Connect(silence)
end

local function onCharacter(character: Model)
	for _, track in {walkTrack, sprintTrack} do
		if track then
			track:Stop(0)
			track:Destroy()
		end
	end
	walkTrack = nil
	sprintTrack = nil
	local nextHumanoid = character:WaitForChild("Humanoid") :: Humanoid
	nextHumanoid.WalkSpeed = WALK_SPEED
	humanoid = nextHumanoid
	walkTrack = loadMovementTrack(
		nextHumanoid,
		"EscanorWalk",
		CONFIG.Animations.Walk,
		Enum.AnimationPriority.Movement
	)
	sprintTrack = loadMovementTrack(
		nextHumanoid,
		"EscanorSprint",
		CONFIG.Animations.Sprint,
		Enum.AnimationPriority.Action
	)
	task.spawn(muteRunningSound, character)
end

if player.Character then
	task.spawn(onCharacter, player.Character)
end
player.CharacterAdded:Connect(onCharacter)

-- MovementLocked is shared with Cruel Sun, so Heartbeat never overwrites its
-- zero speed. One selected locomotion track runs at a time, keeping visual and
-- physical movement synchronized without disturbing idle and jump tracks.
RunService.Heartbeat:Connect(function()
	local activeHumanoid = humanoid
	if not activeHumanoid or activeHumanoid.Health <= 0 then
		return
	end
	local locked = activeHumanoid:GetAttribute("MovementLocked") == true
	local wantsSprint = UserInputService:IsKeyDown(SPRINT_KEY)
	if not locked then
		local desiredSpeed = if wantsSprint then SPRINT_SPEED else WALK_SPEED
		if math.abs(activeHumanoid.WalkSpeed - desiredSpeed) > 0.01 then
			activeHumanoid.WalkSpeed = desiredSpeed
		end
	end

	local moving = activeHumanoid.MoveDirection.Magnitude > 0.05
	local selected = if wantsSprint then sprintTrack else walkTrack
	local unselected = if wantsSprint then walkTrack else sprintTrack
	if unselected and unselected.IsPlaying then
		unselected:Stop(TRACK_FADE_TIME)
	end
	if selected and moving and not locked and not selected.IsPlaying then
		selected:Play(TRACK_FADE_TIME)
	elseif selected and (not moving or locked) and selected.IsPlaying then
		selected:Stop(TRACK_FADE_TIME)
	end
end)
