--[[
    BuffMaster - utils.lua
    Utility functions: polling, output, settings, hard-block detection
]]

local mq = require('mq')

local utils = {}

local me = mq.TLO.Me

-- Polling

function utils.waitFor(conditionFunc, timeoutMs, checkIntervalMs, abortFunc)
    checkIntervalMs = checkIntervalMs or 100
    local elapsed = 0
    while elapsed < timeoutMs do
        if conditionFunc() then
            return true
        end
        if abortFunc and abortFunc() then
            return false
        end
        mq.delay(checkIntervalMs)
        elapsed = elapsed + checkIntervalMs
    end
    return false
end

-- Output

local config = nil

function utils.bindConfig(s)
    config = s
end

function utils.output(msg, ...)
    printf("\a-t[BuffMaster]\aw " .. msg .. "\ax", ...)
end

function utils.debugOutput(msg, ...)
    if config and config.debugMode then
        local t = mq.gettime()
        printf("\a-t[BuffMaster] \a-y[DEBUG] \a-g[%.3f]\aw " .. msg .. "\ax", t / 1000, ...)
    end
end

function utils.announce(channel, msg, ...)
    if channel == "disabled" then return end
    local text = string.format("[BuffMaster] " .. msg, ...)
    if channel == "dannet" then
        mq.cmdf("/dgt zone_%s_%s %s",
            (mq.TLO.EverQuest.Server() or ""):gsub(" ", ""),
            mq.TLO.Zone.ShortName() or "unknown",
            text)
    elseif channel == "e3bcs" then
        mq.cmdf("/e3bcza %s", text)
    elseif channel == "raid" then
        mq.cmdf("/rsay %s", text)
    elseif channel == "group" then
        mq.cmdf("/g %s", text)
    end
end

function utils.announceQueueResult(channel, wasStopped, wasAborted, pauseReason, isFinished)
    if wasStopped then
        utils.announce(channel, "Buffing stopped.")
    elseif wasAborted then
        utils.announce(channel, "Buffing halted - attention needed.")
    elseif pauseReason then
        utils.announce(channel, "Buffing paused - %s.", pauseReason)
    elseif isFinished then
        utils.announce(channel, "Finished buffing.")
    end
end

-- Settings

local characterName = mq.TLO.Me.Name()
local serverName = mq.TLO.EverQuest.Server():gsub("%s+", "")

function utils.getSettingsPath()
    return mq.configDir .. "/BuffMaster/" .. characterName .. "_" .. serverName .. "_" .. mq.TLO.Me.Class.ShortName() .. ".lua"
end

function utils.defaultSourceEntry()
    return {
        enabled = false,
        name = "",
        type = "spell",
        icon = 0,
    }
end

local function defaultSettings()
    return {
        debugMode = false,
        triggerWord = "buff me",
        selectedSet = "",
        tellAccess = "disabled",
        tellAllowlist = {},
        tellDenylist = {},
        tellReplies = true,
        castDistance = 200,
        preQueueCommand = "",
        postQueueCommand = "",
        announceArming = "disabled",
        welcomeDone = false,
        sets = {},
        castCounts = {},
    }
end

function utils.saveSettings(settings)
    mq.pickle(utils.getSettingsPath(), settings)
end

function utils.loadSettings()
    local defaults = defaultSettings()
    local configData, err = loadfile(utils.getSettingsPath())
    if err or not configData then
        utils.saveSettings(defaults)
        return defaults
    end

    local settings = configData()

    for key, value in pairs(defaults) do
        if settings[key] == nil then
            settings[key] = value
        end
    end

    for _, set in pairs(settings.sets) do
        if type(set) == "table" then
            for _, entry in ipairs(set) do
                local def = utils.defaultSourceEntry()
                for key, value in pairs(def) do
                    if entry[key] == nil then
                        entry[key] = value
                    end
                end
            end
        end
    end

    return settings
end

-- Gating: hard blocks (external interruptions that should abort mid-buff)

local function hasXTargetHaters()
    local xtCount = me.XTarget() or 0
    for i = 1, xtCount do
        local xt = me.XTarget(i)
        if xt and (xt.ID() or 0) > 0 and not xt.Dead()
            and (xt.Type() or "Corpse") ~= "Corpse"
            and (xt.Aggressive() or (xt.TargetType() or ""):lower() == "auto hater") then
            return true
        end
    end
    return false
end

function utils.getHardBlockReason()
    if me.CombatState() == "COMBAT" then return "in combat" end
    if hasXTargetHaters() then return "xtarget haters" end
    if me.Dead() then return "dead" end
    if me.Feigning() then return "feigning" end
    if mq.TLO.MacroQuest.GameState() ~= 'INGAME' then return "not in game" end
    if mq.TLO.Window("TradeWnd").Open() then return "trade window open" end
    if mq.TLO.Window("LootWnd").Open() then return "loot window open" end
    if mq.TLO.Window("MerchantWnd").Open() then return "merchant open" end
    if mq.TLO.Window("BigBankWnd").Open() then return "bank open" end
    return nil
end

function utils.shouldAbortBuffing()
    return utils.getHardBlockReason() ~= nil
end

return utils
