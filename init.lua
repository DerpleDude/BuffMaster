--[[
    BuffMaster - Buff Server Script
    Casts a configured set of buffs on a requesting player.
    Usage: /lua run buffmaster
]]

local mq            = require('mq')
local Set           = require('mq.Set')
local utils         = require('buffmaster.lib.utils')
local casting       = require('buffmaster.lib.casting')
local ui            = require('buffmaster.lib.ui')

local version       = "1.0.0"

-- Module-Level State

local me            = mq.TLO.Me
local myClass       = me.Class.ShortName()
local settings      = {}
local presetSets    = {}
local stopRequested = false
local aborted       = false
local buffHistory   = {}
local queue         = {}
local queuedNames   = Set.new({})
local isBuffing     = false
local showUI        = true
local showWelcome   = false
local settingsDirty = false
local statusText    = "Idle"

local tellAccessOptions = {
    { key = "disabled",   label = "Disabled", },
    { key = "anyone",     label = "Anyone", },
    { key = "group",      label = "Group Only", },
    { key = "raid",       label = "Raid Only", },
    { key = "fellowship", label = "Fellowship Only", },
    { key = "allowlist",  label = "Allow List", },
    { key = "denylist",   label = "Deny List", },
}

-- Helpers

local function findIndex(tbl, key)
    for i, entry in ipairs(tbl) do
        if entry.key == key then return i end
    end
    return 1
end

local function joinArgs(args, startIdx)
    local parts = {}
    for i = startIdx, #args do
        table.insert(parts, args[i])
    end
    return #parts > 0 and table.concat(parts, " ") or nil
end

local function bumpCastCount(setName, spellName)
    settings.castCounts = settings.castCounts or {}
    settings.castCounts[setName] = settings.castCounts[setName] or {}
    settings.castCounts[setName][spellName] = (settings.castCounts[setName][spellName] or 0) + 1
    settingsDirty = true
end

-- Preset System

local presetClassMap = {}
local presetAliasOf = {}

local function resolvePresets()
    presetSets = {}
    presetClassMap = {}
    presetAliasOf = {}

    local presetFile
    if mq.TLO.MacroQuest.BuildName():lower() == "emu" then
        local serverName = mq.TLO.EverQuest.Server()
        local fileSuffix = serverName:lower():gsub(" ", "")
        presetFile = "buffmaster.presets." .. fileSuffix
    else
        presetFile = "buffmaster.presets.live"
    end

    package.loaded[presetFile] = nil
    local ok, rawPresets = pcall(require, presetFile)
    if not ok or not rawPresets then
        utils.output("No preset file found (%s). Continuing without presets.", presetFile)
        return
    end

    for _, definition in ipairs(rawPresets) do
        local classMatch = not definition.classes
        if definition.classes then
            for _, cls in ipairs(definition.classes) do
                if cls == myClass then
                    classMatch = true
                    break
                end
            end
        end

        if classMatch then
            local title = definition.title:gsub("Class", myClass)

            local resolvedSet = {}
            for _, group in ipairs(definition.effects) do
                local found = false
                for _, candidate in ipairs(group) do
                    local available = false
                    local resolvedIcon = candidate.icon or 0
                    if candidate.type == "spell" then
                        local spell = mq.TLO.Spell(candidate.name)
                        available = me.Book(candidate.name)() ~= nil and (spell.Level() or 0) <= me.Level()
                    elseif candidate.type == "item" then
                        local item = mq.TLO.FindItem("=" .. candidate.name)
                        if item() ~= nil and (item.Clicky.RequiredLevel() or 0) <= me.Level() then
                            available = true
                            resolvedIcon = item.Icon() or resolvedIcon
                        end
                    end

                    if available then
                        table.insert(resolvedSet, {
                            enabled = true,
                            name = candidate.name,
                            type = candidate.type,
                            icon = resolvedIcon,
                            candidates = group,
                        })
                        found = true
                        break
                    end
                end
                if not found then
                    table.insert(resolvedSet, {
                        enabled = false,
                        name = "",
                        type = "spell",
                        icon = 0,
                        candidates = group,
                    })
                end
            end
            presetClassMap[title] = definition.classes
            presetSets[title] = resolvedSet
            if definition.alias then
                presetAliasOf[title] = definition.alias
            end
        end
    end
end

local function getSet(setName)
    if settings.sets[setName] then return settings.sets[setName] end
    if presetSets[setName] then return presetSets[setName] end
    local lower = setName:lower()
    for name, set in pairs(settings.sets) do
        if name:lower() == lower then return set end
    end
    for name, set in pairs(presetSets) do
        if name:lower() == lower then return set end
        if presetAliasOf[name] and presetAliasOf[name]:lower() == lower then return set end
    end
    return nil
end

local function findPresetForClass(class)
    for presetName, classes in pairs(presetClassMap) do
        for _, cls in ipairs(classes) do
            if cls == class then return presetName end
        end
    end
end

local function isPresetSet(setName)
    return presetSets[setName] ~= nil
end

local function getAllSetNames(useAliases)
    local names = {}
    for name in pairs(settings.sets) do
        table.insert(names, name)
    end
    table.sort(names)

    local presetNames = {}
    for name in pairs(presetSets) do
        if not settings.sets[name] then
            table.insert(presetNames, useAliases and (presetAliasOf[name] or name) or name)
        end
    end
    table.sort(presetNames)
    for _, name in ipairs(presetNames) do
        table.insert(names, name)
    end
    return names
end

-- Core Buff Logic

local function buffPlayer(playerName, setName, fromTell, abortCheck)
    if aborted then
        utils.output("\arBuffing halted. Use /buffmaster reset to resume.")
        return false
    end

    setName = setName or settings.selectedSet
    local set = getSet(setName)

    if not set then
        utils.output("\arSet '%s' not found.", setName)
        return true
    end

    local senderSpawn = mq.TLO.Spawn("pc =" .. playerName)
    local senderId = senderSpawn.ID() or 0
    if senderId == 0 then
        utils.output("\ay%s is not in zone.", playerName)
        if fromTell and settings.tellReplies then
            mq.cmdf("/tell %s I cannot see you in this zone.", playerName)
        end
        return true, "skipped"
    end

    local distance = senderSpawn.Distance3D() or 999
    if distance > settings.castDistance then
        utils.output("\ay%s is out of range (%.0f).", playerName, distance)
        if fromTell and settings.tellReplies then
            mq.cmdf("/tell %s You are out of range (%.0f). Get within %d.", playerName, distance, settings.castDistance)
        end
        return true, "skipped"
    end

    local stopped = false
    local abortFunc = function()
        if stopRequested then stopped = true end
        return stopped or (abortCheck and abortCheck())
    end

    local results = {}
    for i, entry in ipairs(set) do
        if entry.enabled and entry.name ~= "" then
            if abortFunc() then break end

            -- Re-check sender existence and range
            local sid = senderSpawn.ID() or 0
            if sid == 0 then
                utils.output("\aySender no longer visible. Skipping remaining buffs.")
                break
            end
            if (senderSpawn.Distance3D() or 999) > settings.castDistance then
                utils.output("\aySender moved out of range. Skipping remaining buffs.")
                break
            end

            local success = casting.castOnSender(entry, sid, abortFunc)
            results[i] = success
            if success == true then
                bumpCastCount(setName, entry.name)
            end
            if not success and abortFunc() then break end
        end
    end

    local total, passed, failed = 0, 0, {}
    local wasAborted = false
    for i, entry in ipairs(set) do
        if entry.enabled and entry.name ~= "" then
            if results[i] == true then
                total = total + 1
                passed = passed + 1
            elseif results[i] == false then
                total = total + 1
                table.insert(failed, entry.name)
            elseif results[i] == nil and abortFunc() then
                wasAborted = true
            end
        end
    end

    table.insert(buffHistory, 1, {
        timestamp = os.date("%H:%M:%S"),
        playerName = playerName,
        setName = setName,
        passed = passed,
        total = total,
        failed = failed,
        aborted = wasAborted,
    })
    if #buffHistory > 50 then
        table.remove(buffHistory)
    end

    local suffix = wasAborted and " (ABORTED)" or ""
    if #failed > 0 then
        utils.debugOutput("Cast %d/%d buffs for %s. (Set: %s) Failed: %s%s", passed, total, playerName, setName, table.concat(failed, ", "), suffix)
    else
        utils.debugOutput("Cast %d/%d buffs for %s. (Set: %s)%s", passed, total, playerName, setName, suffix)
    end

    if fromTell and settings.tellReplies then
        if #failed > 0 then
            mq.cmdf("/tell %s Cast %d/%d buffs. Failed: %s", playerName, passed, total, table.concat(failed, ", "))
        else
            mq.cmdf("/tell %s Cast %d/%d buffs.", playerName, passed, total)
        end
    end

    return true
end

-- Queue & Processing

local function clearQueue()
    queue = {}
    queuedNames = Set.new({})
end

local function addToQueue(playerName, setName, fromTell)
    if aborted then
        utils.output("\arBuffing halted. Use /buffmaster reset to resume.")
        return
    end

    local resolvedSetName = setName or settings.selectedSet
    if not getSet(resolvedSetName) then
        local available = table.concat(getAllSetNames(true), ", ")
        utils.output("\arSet '%s' not found. Available sets: %s", resolvedSetName, available)
        if fromTell and settings.tellReplies then
            mq.cmdf('/tell %s Set "%s" not found. Available sets: %s', playerName, resolvedSetName, available)
        end
        return
    end

    if queuedNames:contains(playerName:lower()) then return end

    queuedNames:add(playerName:lower())
    table.insert(queue, {
        playerName = playerName,
        setName = setName,
        fromTell = fromTell or false,
    })

    if fromTell and settings.tellReplies then
        mq.cmdf('/tell %s You have been added to the queue.', playerName)
    end
end

local function processQueue()
    if isBuffing or #queue == 0 then return end

    -- Prepare top-N gem layout once at queue start
    local allSets = {}
    for name, set in pairs(settings.sets) do allSets[name] = set end
    for name, set in pairs(presetSets) do
        if not settings.sets[name] then allSets[name] = set end
    end

    isBuffing = true

    if settings.preQueueCommand ~= "" then
        mq.cmdf("%s", settings.preQueueCommand)
    end

    utils.announce(settings.announceArming, "Buffing - please hold.")

    local pauseReason = nil
    local haltReason = nil
    local abortFired = false
    local abortCheck = function()
        if not abortFired and utils.shouldAbortBuffing() then
            abortFired = true
            pauseReason = utils.getHardBlockReason() or "environmental block"
        end
        return abortFired
    end

    local topNOk = casting.ensureTopNMemmed(allSets, settings.castCounts or {}, abortCheck)
    if topNOk == false then
        utils.output("\arFailed to prepare buff gems.")
        aborted = true
        haltReason = "gem preparation failed"
        clearQueue()
    end

    local processed = 0
    while #queue > 0 do
        if stopRequested then
            clearQueue()
            break
        end

        if abortCheck() then
            clearQueue()
            break
        end

        local request = table.remove(queue, 1)
        queuedNames:remove(request.playerName:lower())
        processed = processed + 1
        statusText = string.format("Buffing %d/%d: %s...", processed, processed + #queue, request.playerName)

        local result, status = buffPlayer(request.playerName, request.setName, request.fromTell, abortCheck)

        if abortFired then
            clearQueue()
            break
        elseif not result then
            aborted = true
            haltReason = status or "unknown error"
            clearQueue()
            break
        end
    end

    local wasStopped = stopRequested
    local wasAborted = aborted

    if settings.postQueueCommand ~= "" then
        mq.cmdf("%s", settings.postQueueCommand)
    end
    utils.announceQueueResult(settings.announceArming, wasStopped, wasAborted, pauseReason, true)

    isBuffing = false
    stopRequested = false
    if wasAborted then
        if wasStopped then
            statusText = "HALTED - user stopped"
        else
            statusText = string.format("HALTED - %s", haltReason or "unknown error")
        end
    elseif pauseReason then
        statusText = string.format("HALTED - %s", pauseReason)
    else
        statusText = "Idle"
    end
end

-- Access Check

local function isAllowedSender(senderName)
    if settings.tellAccess == "anyone" then
        return true
    elseif settings.tellAccess == "group" then
        for i = 1, 5 do
            local member = mq.TLO.Group.Member(i)
            if member() and (member.DisplayName() or ""):lower() == senderName:lower() then
                return true
            end
        end
        return false
    elseif settings.tellAccess == "raid" then
        for i = 1, mq.TLO.Raid.Members() or 0 do
            local member = mq.TLO.Raid.Member(i)
            if member() and (member.DisplayName() or ""):lower() == senderName:lower() then
                return true
            end
        end
        return false
    elseif settings.tellAccess == "fellowship" then
        if me.Fellowship.ID() == 0 then return false end
        local member = me.Fellowship.Member(senderName)
        return member() ~= nil
    elseif settings.tellAccess == "allowlist" then
        for _, name in ipairs(settings.tellAllowlist) do
            if name:lower() == senderName:lower() then
                return true
            end
        end
        return false
    elseif settings.tellAccess == "denylist" then
        for _, name in ipairs(settings.tellDenylist) do
            if name:lower() == senderName:lower() then
                utils.output("\ay%s is on the deny list. Ignoring request.", senderName)
                return false
            end
        end
        return true
    end
    return false
end

local function registerTellEvent()
    mq.event('buffMasterRequest', "#1# tells you, '#2#'", function(line, sender, message)
        if not message then return end
        if sender:lower() == me.DisplayName():lower() then return end
        local trimmed = message:gsub("^%s+", ""):gsub("%s+$", "")
        local triggerLower = settings.triggerWord:lower()

        if triggerLower == "" or trimmed:lower():find(triggerLower, 1, true) ~= 1 then return end
        if not isAllowedSender(sender) then return end

        local afterTrigger = trimmed:sub(#settings.triggerWord + 1):gsub("^%s+", ""):gsub("%s+$", "")
        addToQueue(sender, afterTrigger ~= "" and afterTrigger or nil, true)
    end)
end

local function unregisterTellEvent()
    mq.unevent('buffMasterRequest')
end

-- Command System

local function queueGroupMembers(getMember, startIndex, count, setName)
    for i = startIndex, count do
        local member = getMember(i)
        if member() and member.DisplayName() then
            addToQueue(member.DisplayName(), setName, false)
        end
    end
end

local commandOrder = { "help", "stop", "reset", "show", "hide", "debug", "buff", "tellaccess", }

local commands
commands = {
    buff = {
        usage = "/buffmaster buff <scope> [set]",
        about = "Buff someone (self/target/group/raid/PlayerName)",
        handler = function(args)
            local scope = args[2] and args[2]:lower() or ""
            local setName = joinArgs(args, 3)

            if scope == "self" then
                addToQueue(me.DisplayName(), setName, false)
            elseif scope == "target" then
                local t = mq.TLO.Target
                if not t() or t.Type() ~= "PC" then
                    utils.output("\ayTarget is not a PC.")
                else
                    addToQueue(t.DisplayName(), setName, false)
                end
            elseif scope == "group" then
                queueGroupMembers(mq.TLO.Group.Member, 0, (mq.TLO.Group.GroupSize() or 1) - 1, setName)
            elseif scope == "raid" then
                queueGroupMembers(mq.TLO.Raid.Member, 1, mq.TLO.Raid.Members() or 0, setName)
            elseif scope ~= "" then
                addToQueue(args[2], setName, false)
            else
                utils.output("Usage: /buffmaster buff <self|target|group|raid|PlayerName> [SetName]")
            end
        end,
    },
    stop = {
        usage = "/buffmaster stop",
        about = "Stop the current operation",
        handler = function()
            stopRequested = true
            aborted = true
            clearQueue()
            if not isBuffing then
                statusText = "HALTED - user stopped"
            end
            utils.output("Stop requested.")
        end,
    },
    show = {
        usage = "/buffmaster show",
        about = "Show the UI",
        handler = function()
            showUI = true
        end,
    },
    hide = {
        usage = "/buffmaster hide",
        about = "Hide the UI",
        handler = function()
            if showWelcome then
                utils.output("Please complete the welcome setup first.")
                return
            end
            showUI = false
        end,
    },
    debug = {
        usage = "/buffmaster debug [on|off]",
        about = "Toggle debug logging",
        handler = function(args)
            local arg = args[2] and args[2]:lower() or ""
            local prev = settings.debugMode
            if arg == "on" then
                settings.debugMode = true
            elseif arg == "off" then
                settings.debugMode = false
            else
                settings.debugMode = not settings.debugMode
            end
            if settings.debugMode ~= prev then
                settingsDirty = true
                utils.output("Debug mode: %s", settings.debugMode and "ON" or "OFF")
            end
        end,
    },
    tellaccess = {
        usage = "/buffmaster tellaccess [mode]",
        about = "Set tell access mode (disabled, anyone, group, raid, fellowship, allowlist, denylist)",
        handler = function(args)
            local keys = {}
            for _, opt in ipairs(tellAccessOptions) do table.insert(keys, opt.key) end
            local mode = args[2] and args[2]:lower() or ""
            if mode == "" then
                local current = findIndex(tellAccessOptions, settings.tellAccess)
                utils.output("Tell access: %s (%s)", tellAccessOptions[current].label, table.concat(keys, ", "))
                return
            end
            for _, opt in ipairs(tellAccessOptions) do
                if opt.key == mode then
                    local wasDisabled = settings.tellAccess == "disabled"
                    settings.tellAccess = opt.key
                    settingsDirty = true
                    if opt.key == "disabled" then
                        unregisterTellEvent()
                    elseif wasDisabled then
                        registerTellEvent()
                    end
                    utils.output("Tell access set to: %s", opt.label)
                    return
                end
            end
            utils.output("Unknown mode. Options: %s", table.concat(keys, ", "))
        end,
    },
    reset = {
        usage = "/buffmaster reset",
        about = "Resume after a halt or error",
        handler = function()
            aborted = false
            stopRequested = false
            statusText = "Idle"
            utils.output("Reset complete. Ready to buff.")
        end,
    },
    help = {
        usage = "/buffmaster help",
        about = "Print the command list to chat",
        handler = function()
            utils.output("Commands: /buffmaster ...")
            for _, name in ipairs(commandOrder) do
                if name ~= "help" then
                    local cmd = commands[name]
                    local shortUsage = cmd.usage:gsub("^/buffmaster ", "")
                    utils.output("  %s - %s", shortUsage, cmd.about)
                end
            end
        end,
    },
}

local function commandHandler(...)
    local args = { ..., }
    local cmd = args[1] and args[1]:lower() or "help"
    local found = commands[cmd]
    if found then
        found.handler(args)
    else
        utils.output("Unknown command: %s. Try /buffmaster help", cmd)
    end
end


-- Startup

local function startup()
    settings = utils.loadSettings()
    utils.bindConfig(settings)
    resolvePresets()

    if not getSet(settings.selectedSet) then
        settings.selectedSet = next(settings.sets) or ""
        settingsDirty = true
    end

    if next(settings.sets) == nil and settings.selectedSet == "" then
        local preset = findPresetForClass(myClass)
        if preset then
            settings.selectedSet = preset
            settingsDirty = true
            utils.output("Auto-selected preset '%s' based on class.", preset)
        end
    end

    if settingsDirty then
        utils.saveSettings(settings)
        settingsDirty = false
    end

    if not settings.welcomeDone then
        showWelcome = true
    end

    utils.output("v%s - BuffMaster ready.", version)
    utils.output("Use \ag/buffmaster help\ax for a list of commands.")
end

-- Main

startup()

ui.init({
    version              = version,
    settings             = function() return settings end,
    presetSets           = function() return presetSets end,
    buffHistory          = function() return buffHistory end,
    isBuffing            = function() return isBuffing end,
    aborted              = function() return aborted end,
    statusText           = function() return statusText end,
    showUI               = function() return showUI end,
    showWelcome          = function() return showWelcome end,
    setShowUI            = function(v) showUI = v end,
    setShowWelcome       = function(v) showWelcome = v end,
    setSettingsDirty     = function() settingsDirty = true end,
    resetHalt            = function()
        aborted       = false
        stopRequested = false
        statusText    = "Idle"
    end,
    getSet               = getSet,
    getAllSetNames       = getAllSetNames,
    isPresetSet          = isPresetSet,
    commands             = commands,
    commandOrder         = commandOrder,
    addToQueue           = addToQueue,
    commandHandler       = commandHandler,
    resolvePresets       = resolvePresets,
    registerTellEvent    = registerTellEvent,
    unregisterTellEvent  = unregisterTellEvent,
})

mq.imgui.init('BuffMaster', ui.render)
mq.bind('/buffmaster', commandHandler)

if settings.tellAccess ~= "disabled" then
    registerTellEvent()
end

utils.output("Running.")

while mq.TLO.MacroQuest.GameState() == 'INGAME' do
    mq.doevents()

    if not isBuffing and me.Class.ShortName() ~= myClass then
        local oldTellAccess = settings.tellAccess
        myClass = me.Class.ShortName()
        settings = utils.loadSettings()
        utils.bindConfig(settings)
        resolvePresets()
        if settings.tellAccess ~= oldTellAccess then
            if settings.tellAccess == "disabled" then
                unregisterTellEvent()
            elseif oldTellAccess == "disabled" then
                registerTellEvent()
            end
        end
        if not getSet(settings.selectedSet) then
            settings.selectedSet = findPresetForClass(myClass) or next(settings.sets) or ""
        end
        settingsDirty = true
    end

    if settingsDirty then
        utils.saveSettings(settings)
        settingsDirty = false
    end

    processQueue()
    mq.delay(100)
end

utils.output("No longer in game, exiting.")
