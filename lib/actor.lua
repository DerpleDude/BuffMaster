--[[
    BuffMaster - Actor.lua
    Cross-instance IPC: broadcasts queue requests so all connected
    BuffMaster scripts in the same server+zone queue the same person.
]]

local mq      = require('mq')
local actors  = require('actors')
local Logger  = require('lib.logger')

local Actor   = {}

local myServer = mq.TLO.EverQuest.Server() or ""
local handle = nil

function Actor.register(onQueueRequest)
    handle = actors.register(function(message)
        local msg = message()
        if type(msg) ~= "table" then return end
        if msg.script ~= "BuffMaster" then return end
        if msg.from == mq.TLO.Me.DisplayName() then return end
        if msg.server ~= myServer then return end
        if msg.zoneId ~= (mq.TLO.Zone.ID() or 0) then return end

        if msg.event == "queue" then
            Logger.log_verbose("Actor: %s queued %s", msg.from, msg.playerName)
            onQueueRequest(msg.playerName, msg.setName)
        end
    end)
end

function Actor.broadcastQueue(playerName, setName)
    actors.send({
        script     = "BuffMaster",
        event      = "queue",
        from       = mq.TLO.Me.DisplayName(),
        server     = myServer,
        zoneId     = mq.TLO.Zone.ID() or 0,
        playerName = playerName,
        setName    = setName,
    })
end

return Actor
