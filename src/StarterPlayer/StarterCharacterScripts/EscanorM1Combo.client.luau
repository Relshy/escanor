local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local ContentProvider = game:GetService("ContentProvider")
local UserInputService = game:GetService("UserInputService")
local player = Players.LocalPlayer
local character = script.Parent
local humanoid = character:WaitForChild("Humanoid")
local systemFolder = ReplicatedStorage:WaitForChild("CruelSun")
local assetsFolder = systemFolder:WaitForChild("Assets")
local remotesFolder = systemFolder:WaitForChild("Remotes")

local hitRemote = remotesFolder:WaitForChild("EscanorM1Hit")
local axeModel = assetsFolder:WaitForChild("EscanorAxe")
local keyframeFolder = assetsFolder:WaitForChild("EscanorM1Keyframes")
local CFG = {
	ComboMax = axeModel:GetAttribute("ComboMax") or 5,
	ComboResetWindow = axeModel:GetAttribute("ComboResetWindow") or 1.15,
	InputCooldown = axeModel:GetAttribute("InputCooldown") or 0.55,
	FadeTime = 0.12, PlaySpeed = 1.0,
}
local slashNames = {"Ulq Slash 1","Ulq Slash 2","Ulq Slash 3","Ulq Slash 4","Ulq Slash 5"}
local registeredIds, trackCache = {}, {}
local currentTrack, comboIndex = nil, 0
local lastM1At, nextAllowedAt = -math.huge, 0
local function getAnimator()
	local h = character:FindFirstChildOfClass("Humanoid"); if not h then return nil end
	local a = h:FindFirstChildOfClass("Animator"); if not a then a = Instance.new("Animator"); a.Parent = h end
	return a
end
local function registerSequence(index)
	if registeredIds[index] then return registeredIds[index] end
	local seq = keyframeFolder:FindFirstChild(slashNames[index]); if not seq then return nil end
	local ok, id = pcall(function() return KeyframeSequenceProvider:RegisterKeyframeSequence(seq) end)
	if not ok then warn("Escanor M1 register fail", slashNames[index], id) return nil end
	registeredIds[index] = id; return id
end
local function getTrack(index)
	local animator = getAnimator(); if not animator then return nil end
	if trackCache[index] then return trackCache[index] end
	local id = registerSequence(index); if not id then return nil end
	local anim = Instance.new("Animation"); anim.AnimationId = id
	local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
	anim:Destroy()
	if not ok then warn("Escanor M1 load fail", slashNames[index], track) return nil end
	track.Priority = Enum.AnimationPriority.Action4; track.Looped = false
	track.KeyframeReached:Connect(function(kfName) if kfName == "HitFrame" then hitRemote:FireServer(index) end end)
	trackCache[index] = track; return track
end
local function stopCompeting(keep)
	local animator = getAnimator(); if not animator then return end
	for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
		if t ~= keep and t.Priority.Value >= Enum.AnimationPriority.Action.Value then t:Stop(0.05) end
	end
end
local function playSlash(index)
	local track = getTrack(index); if not track then return false end
	if currentTrack and currentTrack.IsPlaying then currentTrack:Stop(0.03) end
	stopCompeting(track)
	track:Play(CFG.FadeTime, 1, CFG.PlaySpeed); track.TimePosition = 0; currentTrack = track
	return true
end
local function attack()
	if humanoid.Health <= 0 then return end
	local now = os.clock(); if now < nextAllowedAt then return end
	if now - lastM1At > CFG.ComboResetWindow then comboIndex = 1
	else comboIndex += 1; if comboIndex > CFG.ComboMax then comboIndex = 1 end end
	if playSlash(comboIndex) then lastM1At = now; nextAllowedAt = now + CFG.InputCooldown end
end
UserInputService.InputBegan:Connect(function(input, gp)
	if gp then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then attack() end
end)
task.spawn(function()
	local preload = {}
	for i = 1, #slashNames do
		local seq = keyframeFolder:FindFirstChild(slashNames[i]); if seq then table.insert(preload, seq) end
		registerSequence(i)
	end
	pcall(function() ContentProvider:PreloadAsync(preload) end)
end)
-- Keep the held axe attached: the client sees physics flings (from teleports/
-- dashes) that the server doesn't, so ask the server to rebuild when it drifts.
task.spawn(function()
	local reattach = remotesFolder:WaitForChild("EscanorReattach", 10)
	local lastReq = 0
	while character.Parent do
		task.wait(0.3)
		local arm = character:FindFirstChild("Right Arm") or character:FindFirstChild("RightHand")
		local axe = character:FindFirstChild("EscanorAxe")
		local handle = axe and axe:FindFirstChild("Handle")
		if arm and handle and reattach then
			if (handle.Position - arm.Position).Magnitude > 4 and (os.clock() - lastReq) > 1 then
				lastReq = os.clock()
				reattach:FireServer()
			end
		end
	end
end)
