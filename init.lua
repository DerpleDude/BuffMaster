--[[
    BuffMaster - Buff Server Script
    Casts a configured set of buffs on a requesting player.
    Usage: /lua run buffmaster

    Author(s): Derple
]]

local mq      = require('mq')

local Utils   = require('lib.utils')
local Casting = require('lib.casting')
local Globals = require('lib.globals')
local Logger  = require('lib.logger')
local Events  = require('lib.events')
local Binds   = require('lib.binds')
local Ui      = require('lib.ui')
local Actor   = require('lib.actor')

require('lib.events')

-- Core Buff Logic

local function buffPlayer(playerName, setName, fromTell, abortCheck)
    if Globals.aborted then
        Logger.log_info("\arBuffing halted. Use /buffmaster reset to resume.")
        return false
    end

    setName = setName or Globals.settings.selectedSet
    local set = Utils.getSet(setName)

    if not set then
        Logger.log_info("\arSet '%s' not found.", setName)
        return true
    end

    local senderSpawn = mq.TLO.Spawn("pc =" .. playerName)
    local senderId = senderSpawn.ID() or 0
    if senderId == 0 then
        Logger.log_info("\ay%s is not in zone.", playerName)
        if Globals.settings.tellReplies then
            Utils.SendTell(playerName, "I cannot see you in this zone.")
        end
        return true, "skipped"
    end

    local distance = senderSpawn.Distance3D() or 999
    if distance > Globals.settings.castDistance then
        Logger.log_info("\ay%s is out of range (%.0f).", playerName, distance)
        if Globals.settings.tellReplies then
            Utils.SendTell(playerName, "You are out of range (%.0f). Get within %d.", distance, Globals.settings.castDistance)
        end
        return true, "skipped"
    end

    local stopped = false
    local abortFunc = function()
        if Globals.stopRequested then stopped = true end
        return stopped or (abortCheck and abortCheck())
    end

    local results = {}
    for i, entry in ipairs(set) do
        if entry.enabled and entry.name ~= "" then
            if abortFunc() then break end

            -- Re-check sender existence and range
            local sid = senderSpawn.ID() or 0
            if sid == 0 then
                Logger.log_info("\aySender no longer visible. Skipping remaining buffs.")
                break
            end
            if (senderSpawn.Distance3D() or 999) > Globals.settings.castDistance then
                Logger.log_info("\aySender moved out of range. Skipping remaining buffs.")
                break
            end

            local success = Casting.castOnSender(entry, sid, abortFunc)
            results[i] = success
            if success == true then
                Casting.bumpCastCount(setName, entry.name)
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

    table.insert(Globals.buffHistory, 1, {
        timestamp = os.date("%H:%M:%S"),
        playerName = playerName,
        setName = setName,
        passed = passed,
        total = total,
        failed = failed,
        aborted = wasAborted,
    })
    if #Globals.buffHistory > 50 then
        table.remove(Globals.buffHistory)
    end

    local suffix = wasAborted and " (ABORTED)" or ""
    if #failed > 0 then
        Logger.log_debug("Cast %d/%d buffs for %s. (Set: %s) Failed: %s%s", passed, total, playerName, setName, table.concat(failed, ", "), suffix)
    else
        Logger.log_debug("Cast %d/%d buffs for %s. (Set: %s)%s", passed, total, playerName, setName, suffix)
    end

    if fromTell and Globals.settings.tellReplies then
        if #failed > 0 then
            Utils.SendTell(playerName, "Cast %d/%d buffs. Failed: %s", passed, total, table.concat(failed, ", "))
        else
            Utils.SendTell(playerName, "Cast %d/%d buffs.", passed, total)
        end
    end

    return true
end

-- Queue & Processing

local function processQueue()
    if Globals.isBuffing or #Globals.queue == 0 then return end

    -- Prepare top-N gem layout once at queue start
    local allSets = {}
    for name, set in pairs(Globals.settings.sets) do allSets[name] = set end
    for name, set in pairs(Globals.presetSets) do
        if not Globals.settings.sets[name] then allSets[name] = set end
    end

    Globals.isBuffing = true

    if Globals.settings.preQueueCommand ~= "" then
        Utils.DoCmd("%s", Globals.settings.preQueueCommand)
    end

    Utils.announce(Globals.settings.announceArming, "Buffing - please hold.")

    local pauseReason = nil
    local haltReason = nil
    local abortFired = false
    local abortCheck = function()
        if not abortFired and Utils.shouldAbortBuffing() then
            abortFired = true
            pauseReason = Utils.getHardBlockReason() or "environmental block"
        end
        return abortFired
    end

    local topNOk = Casting.ensureTopNMemmed(allSets, Globals.settings.castCounts or {}, abortCheck)
    if topNOk == false then
        Logger.log_info("\arFailed to prepare buff gems.")
        Globals.aborted = true
        haltReason = "gem preparation failed"
        Utils.clearQueue()
    end

    local processed = 0
    while #Globals.queue > 0 do
        if Globals.stopRequested then
            Utils.clearQueue()
            break
        end

        if abortCheck() then
            Utils.clearQueue()
            break
        end

        local request = table.remove(Globals.queue, 1)
        Globals.queuedNames:remove(request.playerName:lower())
        processed = processed + 1
        Globals.statusText = string.format("Buffing %d/%d: %s...", processed, processed + #Globals.queue, request.playerName)

        local result, status = buffPlayer(request.playerName, request.setName, request.fromTell, abortCheck)

        if abortFired then
            Utils.clearQueue()
            break
        elseif not result then
            Globals.aborted = true
            haltReason = status or "unknown error"
            Utils.clearQueue()
            break
        end
    end

    local wasStopped = Globals.stopRequested
    local wasAborted = Globals.aborted

    if Globals.settings.postQueueCommand ~= "" then
        Utils.DoCmd("%s", Globals.settings.postQueueCommand)
    end
    Utils.announceQueueResult(Globals.settings.announceArming, wasStopped, wasAborted, pauseReason, true)

    Globals.isBuffing = false
    Globals.stopRequested = false
    if wasAborted then
        if wasStopped then
            Globals.statusText = "HALTED - user stopped"
        else
            Globals.statusText = string.format("HALTED - %s", haltReason or "unknown error")
        end
    elseif pauseReason then
        Globals.statusText = string.format("HALTED - %s", pauseReason)
    else
        Globals.statusText = "Idle"
    end
end

-- Startup

local function startup()
    Globals.settings = Utils.loadSettings()
    Utils.bindConfig(Globals.settings)
    Utils.resolvePresets()

    if not Utils.getSet(Globals.settings.selectedSet) then
        Globals.settings.selectedSet = next(Globals.settings.sets) or ""
        Globals.settingsDirty = true
    end

    if next(Globals.settings.sets) == nil and Globals.settings.selectedSet == "" then
        local preset = Utils.findPresetForClass(Globals.myClass)
        if preset then
            Globals.settings.selectedSet = preset
            Globals.settingsDirty = true
            Logger.log_info("Auto-selected preset '%s' based on class.", preset)
        end
    end

    if Globals.settingsDirty then
        Utils.saveSettings(Globals.settings)
        Globals.settingsDirty = false
    end

    if not Globals.settings.welcomeDone then
        Globals.showWelcome = true
    end

    Logger.log_info("v%s - BuffMaster ready.", Globals.version)
    Logger.log_info("Use \ag/buffmaster help\ax for a list of commands.")
end

-- Main

startup()

Ui.init()

mq.imgui.init('BuffMaster', Ui.render)
mq.bind('/buffmaster', Binds.handler)

if Globals.settings.tellAccess ~= "disabled" then
    Events.registerTellEvent()
end

Actor.register(function(playerName, setName)
    Utils.addToQueue(playerName, setName, true, true)
end)

Logger.log_info("Running.")

while mq.TLO.MacroQuest.GameState() == 'INGAME' do
    mq.doevents()
    Utils.drainPendingRequests()

    if not Globals.isBuffing and Globals.me.Class.ShortName() ~= Globals.myClass then
        local oldTellAccess = Globals.settings.tellAccess
        Globals.myClass = Globals.me.Class.ShortName()
        Globals.settings = Utils.loadSettings()
        Utils.bindConfig(Globals.settings)
        Utils.resolvePresets()
        if Globals.settings.tellAccess ~= oldTellAccess then
            if Globals.settings.tellAccess == "disabled" then
                Events.unregisterTellEvent()
            elseif oldTellAccess == "disabled" then
                Events.registerTellEvent()
            end
        end
        if not Utils.getSet(Globals.settings.selectedSet) then
            Globals.settings.selectedSet = Utils.findPresetForClass(Globals.myClass) or next(Globals.settings.sets) or ""
        end
        Globals.settingsDirty = true
    end

    if Globals.settingsDirty then
        Utils.saveSettings(Globals.settings)
        Globals.settingsDirty = false
    end

    processQueue()
    mq.delay(100)
end

Logger.log_info("No longer in game, exiting.")
