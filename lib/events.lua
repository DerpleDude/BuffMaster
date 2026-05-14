--[[
    BuffMaster - Events.lua
    All mq.event handlers.
]]

local mq      = require('mq')
local Logger  = require('lib.logger')
local Globals = require('lib.globals')
local Utils   = require('lib.utils')

local Events  = {}

-- Outbound tell echo: confirms a /tell actually reached the chat layer.
mq.event('buffMasterTellSent', "You told #1#, '#2#'", function(_, msg)
    Logger.log_verbose("\agTell echo received: %s", msg)
    Globals.TellPending = false
end)

mq.event('buffMasterTellWindowSent', string.format("%s tells you, '#1#'", mq.TLO.Me.DisplayName()), function(_, msg)
    Logger.log_verbose("\agTell Window echo received: %s", msg)
    Globals.TellPending = false
end)

-- Spell fizzle: read by Casting.waitForCastComplete to drive the retry loop.
mq.event('buffMasterFizzle', "Your spell fizzles#*#", function()
    Globals.fizzled = true
end)

-- Dynamic tell-trigger handler: registered/unregistered by tellAccess setting.

local function isAllowedSender(senderName)
    local me = Globals.me
    if Globals.settings.tellAccess == "anyone" then
        return true
    elseif Globals.settings.tellAccess == "group" then
        for i = 1, 5 do
            local member = mq.TLO.Group.Member(i)
            if member() and (member.DisplayName() or ""):lower() == senderName:lower() then
                return true
            end
        end
        return false
    elseif Globals.settings.tellAccess == "raid" then
        for i = 1, mq.TLO.Raid.Members() or 0 do
            local member = mq.TLO.Raid.Member(i)
            if member() and (member.DisplayName() or ""):lower() == senderName:lower() then
                return true
            end
        end
        return false
    elseif Globals.settings.tellAccess == "fellowship" then
        if me.Fellowship.ID() == 0 then return false end
        local member = me.Fellowship.Member(senderName)
        return member() ~= nil
    elseif Globals.settings.tellAccess == "allowlist" then
        for _, name in ipairs(Globals.settings.tellAllowlist) do
            if name:lower() == senderName:lower() then
                return true
            end
        end
        return false
    elseif Globals.settings.tellAccess == "denylist" then
        for _, name in ipairs(Globals.settings.tellDenylist) do
            if name:lower() == senderName:lower() then
                Logger.log_info("\ay%s is on the deny list. Ignoring request.", senderName)
                return false
            end
        end
        return true
    end
    return false
end

function Events.registerTellEvent()
    mq.event('buffMasterRequest', "#1# tells you, '#2#'", function(line, sender, message)
        if not message then return end
        if sender:lower() == Globals.me.DisplayName():lower() then return end
        local trimmed      = message:gsub("^%s+", ""):gsub("%s+$", "")
        local triggerLower = Globals.settings.triggerWord:lower()

        if triggerLower == "" or trimmed:lower():find(triggerLower, 1, true) ~= 1 then return end
        if not isAllowedSender(sender) then return end

        local afterTrigger = trimmed:sub(#Globals.settings.triggerWord + 1):gsub("^%s+", ""):gsub("%s+$", "")
        Utils.addToQueue(sender, afterTrigger ~= "" and afterTrigger or nil, true)
    end)
end

function Events.unregisterTellEvent()
    mq.unevent('buffMasterRequest')
end

return Events
