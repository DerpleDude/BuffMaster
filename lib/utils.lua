--[[
    BuffMaster - Utils.lua
    Utility functions: polling, output, settings, hard-block detection
]]

local mq      = require('mq')
local Set     = require('mq.Set')
local Logger  = require('lib.logger')
local Globals = require('lib.globals')

local Utils   = {}

local me      = mq.TLO.Me

-- Polling

function Utils.waitFor(conditionFunc, timeoutMs, checkIntervalMs, abortFunc)
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

function Utils.joinArgs(args, startIdx)
    local parts = {}
    for i = startIdx, #args do
        table.insert(parts, args[i])
    end
    return #parts > 0 and table.concat(parts, " ") or nil
end

function Utils.findIndex(tbl, key)
    for i, entry in ipairs(tbl) do
        if entry.key == key then return i end
    end
    return 1
end

function Utils.DoCmd(cmd, ...)
    local resolved = select('#', ...) > 0 and string.format(cmd, ...) or cmd
    Logger.log_verbose("DoCmd: %s", resolved)
    mq.cmd(resolved)
    mq.delay(100) -- don't send commands to close to each other
end

function Utils.SendTell(target, msg, ...)
    local resolved = select('#', ...) > 0 and string.format(msg, ...) or msg
    while Globals.TellPending do
        Logger.log_verbose("Waiting for previous tell to complete...")
        mq.doevents()
        mq.delay(1000)
    end

    Globals.TellPending = true
    Logger.log_verbose("SendTell: %s -> %s", resolved, target)
    Utils.DoCmd('/tell %s %s', target, resolved)
    Utils.waitFor(function()
        mq.doevents()
        return not Globals.TellPending
    end, 10000, 50)
    Logger.log_verbose("SendTell completed: %s -> %s", resolved, target)
end

-- Output

function Utils.bindConfig(s)
    if s then
        local lvl = math.max(3, s.logLevel or 3)
        Logger.set_log_level(lvl)
        Logger.set_log_to_file(s.logToFile or false)
    end
end

function Utils.announce(channel, msg, ...)
    if channel == "disabled" then return end
    local text = string.format("[BuffMaster] " .. msg, ...)
    if channel == "dannet" then
        Utils.DoCmd("/dgt zone_%s_%s %s",
            (mq.TLO.EverQuest.Server() or ""):gsub(" ", ""),
            mq.TLO.Zone.ShortName() or "unknown",
            text)
    elseif channel == "e3bcs" then
        Utils.DoCmd("/e3bcza %s", text)
    elseif channel == "raid" then
        Utils.DoCmd("/rsay %s", text)
    elseif channel == "group" then
        Utils.DoCmd("/g %s", text)
    end
end

function Utils.announceQueueResult(channel, wasStopped, wasAborted, pauseReason, isFinished)
    if wasStopped then
        Utils.announce(channel, "Buffing stopped.")
    elseif wasAborted then
        Utils.announce(channel, "Buffing halted - attention needed.")
    elseif pauseReason then
        Utils.announce(channel, "Buffing paused - %s.", pauseReason)
    elseif isFinished then
        Utils.announce(channel, "Finished buffing.")
    end
end

-- Settings

local characterName = mq.TLO.Me.Name()
local serverName = mq.TLO.EverQuest.Server():gsub("%s+", "")

function Utils.getSettingsPath()
    return mq.configDir .. "/BuffMaster/" .. characterName .. "_" .. serverName .. "_" .. mq.TLO.Me.Class.ShortName() .. ".lua"
end

function Utils.defaultSourceEntry()
    return {
        enabled = false,
        name = "",
        type = "spell",
        icon = 0,
    }
end

local function defaultSettings()
    return {
        logLevel = 3,
        logToFile = false,
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

function Utils.saveSettings(settings)
    mq.pickle(Utils.getSettingsPath(), settings)
end

function Utils.loadSettings()
    local defaults = defaultSettings()
    local configData, err = loadfile(Utils.getSettingsPath())
    if err or not configData then
        Utils.saveSettings(defaults)
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
                local def = Utils.defaultSourceEntry()
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

function Utils.getHardBlockReason()
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

function Utils.shouldAbortBuffing()
    return Utils.getHardBlockReason() ~= nil
end

-- Preset System

local presetClassMap = {}
local presetAliasOf  = {}

function Utils.resolvePresets()
    Globals.presetSets = {}
    presetClassMap     = {}
    presetAliasOf      = {}

    local presetFile
    if mq.TLO.MacroQuest.BuildName():lower() == "emu" then
        local serverName = mq.TLO.EverQuest.Server()
        local fileSuffix = serverName:lower():gsub(" ", "")
        presetFile = "presets." .. fileSuffix
    else
        presetFile = "presets.live"
    end

    package.loaded[presetFile] = nil
    local ok, rawPresets = pcall(require, presetFile)
    if not ok or not rawPresets then
        Logger.log_info("No preset file found (%s). Continuing without presets.", presetFile)
        return
    end

    for _, definition in ipairs(rawPresets) do
        local classMatch = not definition.classes
        if definition.classes then
            for _, cls in ipairs(definition.classes) do
                if cls == Globals.myClass then
                    classMatch = true
                    break
                end
            end
        end

        if classMatch then
            local title = definition.title:gsub("Class", Globals.myClass)

            local resolvedSet = {}
            for _, group in ipairs(definition.effects) do
                local found = false
                for _, candidate in ipairs(group) do
                    local available    = false
                    local resolvedIcon = candidate.icon or 0
                    if candidate.type == "spell" then
                        local spell = mq.TLO.Spell(candidate.name)
                        available = Globals.me.Book(candidate.name)() ~= nil and (spell.Level() or 0) <= Globals.me.Level()
                    elseif candidate.type == "aa" then
                        local aa = Globals.me.AltAbility(candidate.name)
                        if (aa.Rank() or 0) > 0 then
                            available    = true
                            resolvedIcon = (aa.Spell() and aa.Spell.SpellIcon()) or resolvedIcon
                        end
                    elseif candidate.type == "item" then
                        local item = mq.TLO.FindItem("=" .. candidate.name)
                        if item() ~= nil and (item.Clicky.RequiredLevel() or 0) <= Globals.me.Level() then
                            available    = true
                            resolvedIcon = item.Icon() or resolvedIcon
                        end
                    end

                    if available then
                        table.insert(resolvedSet, {
                            enabled    = true,
                            name       = candidate.name,
                            type       = candidate.type,
                            icon       = resolvedIcon,
                            candidates = group,
                        })
                        found = true
                        break
                    end
                end
                if not found then
                    table.insert(resolvedSet, {
                        enabled    = false,
                        name       = "",
                        type       = "spell",
                        icon       = 0,
                        candidates = group,
                    })
                end
            end
            presetClassMap[title]     = definition.classes
            Globals.presetSets[title] = resolvedSet
            if definition.alias then
                presetAliasOf[title] = definition.alias
            end
        end
    end
end

function Utils.getSet(setName)
    if Globals.settings.sets[setName] then return Globals.settings.sets[setName] end
    if Globals.presetSets[setName] then return Globals.presetSets[setName] end
    local lower = setName:lower()
    for name, set in pairs(Globals.settings.sets) do
        if name:lower() == lower then return set end
    end
    for name, set in pairs(Globals.presetSets) do
        if name:lower() == lower then return set end
        if presetAliasOf[name] and presetAliasOf[name]:lower() == lower then return set end
    end
    return nil
end

function Utils.findPresetForClass(class)
    for presetName, classes in pairs(presetClassMap) do
        for _, cls in ipairs(classes) do
            if cls == class then return presetName end
        end
    end
end

function Utils.isPresetSet(setName)
    return Globals.presetSets[setName] ~= nil
end

function Utils.getAllSetNames(useAliases)
    local names = {}
    for name in pairs(Globals.settings.sets) do
        table.insert(names, name)
    end
    table.sort(names)

    local presetNames = {}
    for name in pairs(Globals.presetSets) do
        if not Globals.settings.sets[name] then
            table.insert(presetNames, useAliases and (presetAliasOf[name] or name) or name)
        end
    end
    table.sort(presetNames)
    for _, name in ipairs(presetNames) do
        table.insert(names, name)
    end
    return names
end

-- Queue

function Utils.clearQueue()
    Globals.queue       = {}
    Globals.queuedNames = Set.new({})
end

function Utils.addToQueue(playerName, setName, fromTell)
    if Globals.aborted then
        Logger.log_info("\arBuffing halted. Use /buffmaster reset to resume.")
        return
    end

    if (mq.TLO.Spawn("pc =" .. playerName).ID() or 0) == 0 then
        Logger.log_info("\ay%s is not in this zone. Ignoring request.", playerName)
        if fromTell and Globals.settings.tellReplies then
            Utils.SendTell(playerName, "I cannot see you in this zone.")
        end
        return
    end

    local resolvedSetName = setName or Globals.settings.selectedSet
    if not Utils.getSet(resolvedSetName) then
        local available = table.concat(Utils.getAllSetNames(true), ", ")
        Logger.log_info("\arSet '%s' not found. Available sets: %s", resolvedSetName, available)
        if fromTell and Globals.settings.tellReplies then
            Utils.SendTell(playerName, 'Set "%s" not found. Available sets: %s', resolvedSetName, available)
        end
        return
    end

    if Globals.queuedNames:contains(playerName:lower()) then return end

    Globals.queuedNames:add(playerName:lower())
    table.insert(Globals.queue, {
        playerName = playerName,
        setName    = setName,
        fromTell   = fromTell or false,
    })

    if fromTell and Globals.settings.tellReplies then
        Utils.SendTell(playerName, "You have been added to the queue.")
    end
end

return Utils
