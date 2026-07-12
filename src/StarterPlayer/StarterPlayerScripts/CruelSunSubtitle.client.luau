--[[
	CruelSunSubtitle.client.luau
	Split out of the charged-blast ability (CruelSunClient). This is pure
	presentation — the "Who decided that?" voice line plus its on-screen subtitle
	(a live avatar portrait, a fire-hued Cinzel image reveal, and a typewriter
	paced to the spoken clip). None of it is ability logic, so it lives on its own.

	Driven by ReplicatedStorage.CruelSun.Signals:
	  CastStarted -> show the subtitle + play the voice
	  CastReleased(launched) -> hide it (immediately on cancel, after a hold on launch)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local systemFolder = ReplicatedStorage:WaitForChild("CruelSun")
local assetsFolder = systemFolder:WaitForChild("Assets")
local WhoDecidedVoice = assetsFolder:FindFirstChild("WhoDecidedThatVoice")

local signals = systemFolder:WaitForChild("Signals")

-- Subtitle config lives here now, beside the code that draws it.
local CFG = {
	Enabled = true,
	Text = "Who decided that?",
	-- Baked image of the line in real Cinzel Bold with a fire-hue gradient (Roblox
	-- can't host Cinzel as a font). Re-render + re-upload if you change Text; clear
	-- ImageId to fall back to the TextLabel.
	ImageId = "rbxassetid://109665413822046",
	ImageAspect = 6.21, -- width/height of the baked image
	ImageHeight = 46,
	FontAssetId = 12187374765, -- Playfair Display fallback, used only when ImageId is empty
	CharTime = 0.06,
	FadeOutTime = 0.35,
	HoldAfterLaunch = 1.4,
	VoiceVolume = 2,
	SyncToVoice = true, -- pace the typewriter to the voice clip length
	VoiceSyncFraction = 0.9, -- finish typing at ~90% of the clip
}

local activeSubtitleGui

local function hideAbilitySubtitle(delay)
	local gui = activeSubtitleGui
	activeSubtitleGui = nil
	if not gui then return end

	task.spawn(function()
		if delay and delay > 0 then
			task.wait(delay)
		end
		if not gui.Parent then return end

		local fade = CFG.FadeOutTime or 0.35
		local label = gui:FindFirstChild("SubtitleText", true)
		local viewport = gui:FindFirstChild("AvatarViewport", true)

		if label then
			TweenService:Create(label, TweenInfo.new(fade), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		end
		local image = gui:FindFirstChild("SubtitleImage", true)
		if image then
			TweenService:Create(image, TweenInfo.new(fade), { ImageTransparency = 1 }):Play()
		end
		if viewport then
			TweenService:Create(viewport, TweenInfo.new(fade), { ImageTransparency = 1, BackgroundTransparency = 1 }):Play()
		end

		task.wait(fade + 0.05)
		gui:Destroy()
	end)
end

local function showAbilitySubtitle(text)
	if not CFG.Enabled then return end

	hideAbilitySubtitle(0)

	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return end

	local char = player.Character
	if not char then return end

	local gui = Instance.new("ScreenGui")
	gui.Name = "CruelSunAbilitySubtitle"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 50000

	local container = Instance.new("Frame")
	container.Name = "Container"
	container.AnchorPoint = Vector2.new(0.5, 1)
	container.Position = UDim2.new(0.5, 0, 1, -36)
	container.Size = UDim2.fromOffset(600, 150)
	container.BackgroundTransparency = 1
	container.Parent = gui

	-- avatar portrait (live viewport of the character)
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "AvatarViewport"
	viewport.AnchorPoint = Vector2.new(0.5, 0)
	viewport.Position = UDim2.new(0.5, 0, 0, 0)
	viewport.Size = UDim2.fromOffset(86, 86)
	viewport.BackgroundColor3 = Color3.fromRGB(20, 12, 6)
	viewport.BackgroundTransparency = 0.25
	viewport.Ambient = Color3.fromRGB(255, 235, 200)
	viewport.LightColor = Color3.fromRGB(255, 210, 150)
	viewport.LightDirection = Vector3.new(0, -0.2, -1)
	viewport.Parent = container

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = viewport

	local oldArchivable = char.Archivable
	char.Archivable = true
	local avatar = char:Clone()
	char.Archivable = oldArchivable

	if avatar then
		for _, d in ipairs(avatar:GetDescendants()) do
			if d:IsA("BaseScript") or d:IsA("Sound") or d:IsA("ParticleEmitter") or d:IsA("Fire") or d:IsA("Smoke") then
				d:Destroy()
			end
		end
		avatar:PivotTo(CFrame.new())
		avatar.Parent = viewport

		local head = avatar:FindFirstChild("Head")
		local focus = head and head.Position or Vector3.new(0, 1.5, 0)

		local cam = Instance.new("Camera")
		cam.FieldOfView = 30
		cam.CFrame = CFrame.new(focus + Vector3.new(0, 0.1, -3.4), focus)
		cam.Parent = viewport
		viewport.CurrentCamera = cam
	end

	-- subtitle line: baked Cinzel image when available, TextLabel fallback otherwise
	local label, revealHolder, imageLabel
	local fullW, fullH
	if CFG.ImageId and CFG.ImageId ~= "" then
		fullH = CFG.ImageHeight or 46
		fullW = math.floor(fullH * (CFG.ImageAspect or 6.21))

		revealHolder = Instance.new("Frame")
		revealHolder.Name = "SubtitleReveal"
		revealHolder.BackgroundTransparency = 1
		revealHolder.ClipsDescendants = true
		revealHolder.Position = UDim2.new(0.5, -math.floor(fullW / 2), 0, 92)
		revealHolder.Size = UDim2.fromOffset(0, fullH)
		revealHolder.Parent = container

		imageLabel = Instance.new("ImageLabel")
		imageLabel.Name = "SubtitleImage"
		imageLabel.BackgroundTransparency = 1
		imageLabel.Image = CFG.ImageId
		imageLabel.Size = UDim2.fromOffset(fullW, fullH)
		imageLabel.Parent = revealHolder

		-- ember flicker over the baked hues
		local flameStart = os.clock()
		local flameConn
		flameConn = RunService.RenderStepped:Connect(function()
			if not imageLabel:IsDescendantOf(playerGui) then
				flameConn:Disconnect()
				return
			end
			local t = os.clock() - flameStart
			local flicker = 0.85 + 0.15 * math.sin(t * 13 + math.sin(t * 5) * 2)
			imageLabel.ImageColor3 = Color3.new(1, flicker, flicker * flicker)
		end)
	else
		label = Instance.new("TextLabel")
		label.Name = "SubtitleText"
		label.AnchorPoint = Vector2.new(0.5, 0)
		label.Position = UDim2.new(0.5, 0, 0, 94)
		label.Size = UDim2.new(1, 0, 0, 40)
		label.BackgroundTransparency = 1
		local okFont = pcall(function()
			label.FontFace = Font.fromId(CFG.FontAssetId, Enum.FontWeight.Bold)
		end)
		if not okFont then
			label.Font = Enum.Font.GothamBlack
		end
		label.Text = text
		label.TextColor3 = Color3.new(1, 1, 1) -- gradient below paints the fire colors
		label.TextSize = 30
		label.TextStrokeTransparency = 1 -- hues only, no border
		label.MaxVisibleGraphemes = 0
		label.Parent = container

		-- flaming gradient: yellow-hot base rising to red tips
		local gradient = Instance.new("UIGradient")
		gradient.Rotation = 90
		gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 60, 0)),
			ColorSequenceKeypoint.new(0.45, Color3.fromRGB(255, 150, 30)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 245, 170)),
		})
		gradient.Parent = label

		local flameStart = os.clock()
		local flameConn
		flameConn = RunService.RenderStepped:Connect(function()
			if not label:IsDescendantOf(playerGui) then
				flameConn:Disconnect()
				return
			end
			local t = os.clock() - flameStart
			gradient.Offset = Vector2.new(0, 0.06 * math.sin(t * 9) + 0.05 * math.sin(t * 23 + 1.7))
		end)
	end

	gui.Parent = playerGui
	activeSubtitleGui = gui

	-- voice line
	local voiceClone
	if WhoDecidedVoice then
		voiceClone = WhoDecidedVoice:Clone()
		voiceClone.Volume = CFG.VoiceVolume or 2
		voiceClone.Parent = gui
		task.spawn(function()
			local t0 = os.clock()
			while not voiceClone.IsLoaded and voiceClone.Parent and os.clock() - t0 < 5 do
				task.wait(0.05)
			end
			if voiceClone.Parent then
				voiceClone:Play()
			end
		end)
	end

	-- typewriter reveal, paced to the spoken line when available
	local graphemes = 0
	for _ in utf8.graphemes(text) do
		graphemes += 1
	end
	task.spawn(function()
		local interval = CFG.CharTime or 0.06
		if voiceClone and CFG.SyncToVoice then
			local t0 = os.clock()
			while voiceClone.TimeLength == 0 and voiceClone.Parent and os.clock() - t0 < 3 do
				task.wait(0.05)
			end
			if voiceClone.TimeLength > 0 then
				interval = (voiceClone.TimeLength * (CFG.VoiceSyncFraction or 0.9)) / math.max(graphemes, 1)
			end
		end
		for i = 1, graphemes do
			if gui ~= activeSubtitleGui or not gui.Parent then
				return
			end
			if revealHolder then
				revealHolder.Size = UDim2.fromOffset(math.floor(fullW * i / graphemes), fullH)
			else
				label.MaxVisibleGraphemes = i
			end
			task.wait(interval)
		end
	end)
end

signals:WaitForChild("CastStarted").Event:Connect(function()
	showAbilitySubtitle(CFG.Text)
end)
signals:WaitForChild("CastReleased").Event:Connect(function(launched)
	hideAbilitySubtitle(launched and (CFG.HoldAfterLaunch or 1.4) or 0)
end)
