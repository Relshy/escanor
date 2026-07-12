--[[
Author(s)    Janss
Date         12/07/26
Version      1.1.0
]]



--!strict
local Cooldowns = {}

local started = Instance.new("BindableEvent")

Cooldowns.Started = started.Event



--[[
@param     string    identifier    | The identifier from which to derive an attribute name.
@param     string    field         | The cooldown field represented by the attribute.
@return    string

Creates a collision-safe attribute name for shared client cooldown state.
]]
local function getAttributeName(identifier: string, field: string): string
	return `Cooldown_{identifier}_{field}`
end


--[[
@param     string    identifier    | The identifier of the cooldown to query.
@return    boolean

Determines whether the given cooldown has elapsed.
]]
function Cooldowns.IsReady(identifier: string): boolean
	return Cooldowns.GetRemaining(identifier) <= 0
end


--[[
@param     string    identifier    | The identifier of the cooldown to query.
@return    number

Retrieves the number of seconds remaining on the given cooldown.
]]
function Cooldowns.GetRemaining(identifier: string): number
	local expiresAt = script:GetAttribute(getAttributeName(identifier, "ExpiresAt"))

	if typeof(expiresAt) ~= "number" then
		return 0
	end

	return math.max(0, expiresAt - workspace:GetServerTimeNow())
end


--[[
@param     string    identifier    | The identifier of the cooldown to query.
@return    number

Retrieves the full duration of the most recently started cooldown.
]]
function Cooldowns.GetDuration(identifier: string): number
	local duration = script:GetAttribute(getAttributeName(identifier, "Duration"))

	return if typeof(duration) == "number" then duration else 0
end


--[[
@param     string    identifier    | The identifier of the cooldown to begin.
@param     number    duration      | The cooldown duration in seconds.
@return    void

Stores cooldown state on the ModuleScript so every client LocalScript observes
the same values even when their required module environments are isolated.
]]
function Cooldowns.Start(identifier: string, duration: number)
	if duration <= 0 then
		return
	end

	script:SetAttribute(
		getAttributeName(identifier, "ExpiresAt"),
		workspace:GetServerTimeNow() + duration
	)
	script:SetAttribute(
		getAttributeName(identifier, "Duration"),
		duration
	)

	started:Fire(identifier, duration)
end



return table.freeze(Cooldowns)
