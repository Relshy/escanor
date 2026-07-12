local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Cooldowns = require(ReplicatedStorage:WaitForChild("CooldownController"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- >>> Set this to the "Group 1" crossed-swords asset id <<<
local ICON = "rbxassetid://90381992271144"
local ICONV2 = "rbxassetid://95776200714812"
-- ability slots (id must match what the ability passes to Cooldowns.start)
local ABILITIES = {
	{ id = "E", label = "E", icon = ICON },
	{ id = "V", label = "V", icon = ICONV2 },
}

local SLOT = 68

local gui = Instance.new("ScreenGui")
gui.Name = "AbilityHUD"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local row = Instance.new("Frame")
row.Name = "Row"
row.AnchorPoint = Vector2.new(1, 1)
row.Position = UDim2.new(1, -24, 1, -24)
row.Size = UDim2.new(0, 0, 0, SLOT)
row.AutomaticSize = Enum.AutomaticSize.X
row.BackgroundTransparency = 1
row.Parent = gui
local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Horizontal
layout.Padding = UDim.new(0, 12)
layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
layout.VerticalAlignment = Enum.VerticalAlignment.Center
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = row

local slots = {}
for index, a in ipairs(ABILITIES) do
	local slot = Instance.new("Frame")
	slot.Name = a.id
	slot.LayoutOrder = index
	slot.Size = UDim2.fromOffset(SLOT, SLOT)
	slot.BackgroundColor3 = Color3.fromRGB(28, 29, 34)
	slot.BorderSizePixel = 0
	slot.Parent = row
	Instance.new("UICorner", slot).CornerRadius = UDim.new(0, 16)
	local stroke = Instance.new("UIStroke", slot)
	stroke.Color = Color3.fromRGB(70, 72, 82); stroke.Thickness = 1.5; stroke.Transparency = 0.35

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"; icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0.5, 0.5); icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.Size = UDim2.new(1, -16, 1, -16); icon.Image = a.icon
	icon.ImageColor3 = Color3.new(1, 1, 1); icon.ZIndex = 2; icon.Parent = slot

	-- cooldown wipe (dark overlay that drains bottom-up)
	local cdFill = Instance.new("Frame")
	cdFill.Name = "CDFill"; cdFill.AnchorPoint = Vector2.new(0.5, 1)
	cdFill.Position = UDim2.fromScale(0.5, 1); cdFill.Size = UDim2.new(1, 0, 0, 0)
	cdFill.BackgroundColor3 = Color3.fromRGB(0, 0, 0); cdFill.BackgroundTransparency = 0.45
	cdFill.BorderSizePixel = 0; cdFill.Visible = false; cdFill.ZIndex = 3; cdFill.Parent = slot
	Instance.new("UICorner", cdFill).CornerRadius = UDim.new(0, 16)

	local cdText = Instance.new("TextLabel")
	cdText.Name = "CDText"; cdText.BackgroundTransparency = 1; cdText.Size = UDim2.fromScale(1, 1)
	cdText.Font = Enum.Font.Arcade; cdText.TextColor3 = Color3.new(1, 1, 1)
	cdText.TextStrokeTransparency = 0.3; cdText.TextScaled = false; cdText.TextSize = 24
	cdText.Visible = false; cdText.ZIndex = 4; cdText.Parent = slot

	local key = Instance.new("TextLabel")
	key.Name = "Key"; key.AnchorPoint = Vector2.new(1, 1)
	key.Position = UDim2.new(1, 3, 1, 3); key.Size = UDim2.fromOffset(22, 22)
	key.BackgroundTransparency = 1; key.Font = Enum.Font.Arcade
	key.Text = a.label; key.TextColor3 = Color3.new(1, 1, 1)
	key.TextStrokeColor3 = Color3.fromRGB(0, 0, 0); key.TextStrokeTransparency = 0
	key.TextScaled = true; key.ZIndex = 5; key.Parent = slot

	slots[a.id] = { slot = slot, icon = icon, cdFill = cdFill, cdText = cdText }
end

RunService.Heartbeat:Connect(function()
	for id, s in pairs(slots) do
		local remaining = Cooldowns.GetRemaining(id)
		local duration = Cooldowns.GetDuration(id)
		if remaining > 0 and duration > 0 then
			s.cdFill.Visible = true
			s.cdFill.Size = UDim2.new(1, 0, math.clamp(remaining / duration, 0, 1), 0)
			s.cdText.Visible = true
			s.cdText.Text = (remaining >= 1) and tostring(math.ceil(remaining)) or string.format("%.1f", remaining)
			s.icon.ImageColor3 = Color3.fromRGB(110, 110, 115)
		else
			if s.cdFill.Visible then s.cdFill.Visible = false; s.cdText.Visible = false; s.icon.ImageColor3 = Color3.new(1,1,1) end
		end
	end
end)
