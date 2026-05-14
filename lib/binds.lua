--[[
    BuffMaster - Binds.lua
    Slash-command table, command order, and dispatcher.
]]

local mq      = require('mq')
local Utils   = require('lib.utils')
local Logger  = require('lib.logger')
local Globals = require('lib.globals')
local Events  = require('lib.events')

local Binds   = {}

local function queueGroupMembers(getMember, startIndex, count, setName)
    for i = startIndex, count do
        local member = getMember(i)
        if member() and member.DisplayName() then
            Utils.addToQueue(member.DisplayName(), setName, false)
        end
    end
end

Binds.commandOrder = { "help", "stop", "reset", "show", "hide", "buff", "tellaccess", }

Binds.commands     = {
    buff = {
        usage   = "/buffmaster buff <scope> [set]",
        about   = "Buff someone (self/target/group/raid/PlayerName)",
        handler = function(args)
            local scope   = args[2] and args[2]:lower() or ""
            local setName = Utils.joinArgs(args, 3)

            if scope == "self" then
                Utils.addToQueue(Globals.me.DisplayName(), setName, false)
            elseif scope == "target" then
                local t = mq.TLO.Target
                if not t() or t.Type() ~= "PC" then
                    Logger.log_info("\ayTarget is not a PC.")
                else
                    Utils.addToQueue(t.DisplayName(), setName, false)
                end
            elseif scope == "group" then
                queueGroupMembers(mq.TLO.Group.Member, 0, (mq.TLO.Group.GroupSize() or 1) - 1, setName)
            elseif scope == "raid" then
                queueGroupMembers(mq.TLO.Raid.Member, 1, mq.TLO.Raid.Members() or 0, setName)
            elseif scope ~= "" then
                Utils.addToQueue(args[2], setName, false)
            else
                Logger.log_info("Usage: /buffmaster buff <self|target|group|raid|PlayerName> [SetName]")
            end
        end,
    },
    stop = {
        usage   = "/buffmaster stop",
        about   = "Stop the current operation",
        handler = function()
            Globals.stopRequested = true
            Globals.aborted       = true
            Utils.clearQueue()
            if not Globals.isBuffing then
                Globals.statusText = "HALTED - user stopped"
            end
            Logger.log_info("Stop requested.")
        end,
    },
    show = {
        usage   = "/buffmaster show",
        about   = "Show the UI",
        handler = function()
            Globals.showUI = true
        end,
    },
    hide = {
        usage   = "/buffmaster hide",
        about   = "Hide the UI",
        handler = function()
            if Globals.showWelcome then
                Logger.log_info("Please complete the welcome setup first.")
                return
            end
            Globals.showUI = false
        end,
    },
    tellaccess = {
        usage   = "/buffmaster tellaccess [mode]",
        about   = "Set tell access mode (disabled, anyone, group, raid, fellowship, allowlist, denylist)",
        handler = function(args)
            local keys = {}
            for _, opt in ipairs(Globals.tellAccessOptions) do table.insert(keys, opt.key) end
            local mode = args[2] and args[2]:lower() or ""
            if mode == "" then
                local current = Utils.findIndex(Globals.tellAccessOptions, Globals.settings.tellAccess)
                Logger.log_info("Tell access: %s (%s)", Globals.tellAccessOptions[current].label, table.concat(keys, ", "))
                return
            end
            for _, opt in ipairs(Globals.tellAccessOptions) do
                if opt.key == mode then
                    local wasDisabled           = Globals.settings.tellAccess == "disabled"
                    Globals.settings.tellAccess = opt.key
                    Globals.settingsDirty       = true
                    if opt.key == "disabled" then
                        Events.unregisterTellEvent()
                    elseif wasDisabled then
                        Events.registerTellEvent()
                    end
                    Logger.log_info("Tell access set to: %s", opt.label)
                    return
                end
            end
            Logger.log_info("Unknown mode. Options: %s", table.concat(keys, ", "))
        end,
    },
    reset = {
        usage   = "/buffmaster reset",
        about   = "Resume after a halt or error",
        handler = function()
            Globals.aborted       = false
            Globals.stopRequested = false
            Globals.statusText    = "Idle"
            Logger.log_info("Reset complete. Ready to buff.")
        end,
    },
    help = {
        usage   = "/buffmaster help",
        about   = "Print the command list to chat",
        handler = function()
            Logger.log_info("Commands: /buffmaster ...")
            for _, name in ipairs(Binds.commandOrder) do
                if name ~= "help" then
                    local cmd        = Binds.commands[name]
                    local shortUsage = cmd.usage:gsub("^/buffmaster ", "")
                    Logger.log_info("  %s - %s", shortUsage, cmd.about)
                end
            end
        end,
    },
}

function Binds.handler(...)
    local args  = { ..., }
    local cmd   = args[1] and args[1]:lower() or "help"
    local found = Binds.commands[cmd]
    if found then
        found.handler(args)
    else
        Logger.log_info("Unknown command: %s. Try /buffmaster help", cmd)
    end
end

return Binds
