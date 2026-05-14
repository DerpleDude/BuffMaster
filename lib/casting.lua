--[[
    BuffMaster - casting.lua
    Spell memorization, gem management (top-N persistent + scratch slot),
    target-then-cast for spells and clicky items.
]]

local mq = require('mq')
local utils = require('buffmaster.lib.utils')

local casting = {}

local me = mq.TLO.Me
local fizzled = false

local gemMap = {}
local persistentSlots = {}
local scratchGem = nil

mq.event('buffMasterFizzle', "Your spell fizzles#*#", function()
    fizzled = true
end)

-- Spell Memorization

-- Returns gem slot on success, nil on hard failure (not in spellbook), false on transient failure.
function casting.memorizeSpell(gemSlot, spellName, abortFunc)
    if not me.Book(spellName)() then
        utils.output("\ar%s is not in spellbook.", spellName)
        return nil
    end

    for i = 1, me.NumGems() do
        if me.Gem(i)() == spellName then
            utils.debugOutput("Spell '%s' already in gem %d", spellName, i)
            return i
        end
    end

    utils.debugOutput("Memorizing %s in gem %d...", spellName, gemSlot)
    mq.cmdf('/memspell %d "%s"', gemSlot, spellName)

    local spellBook = mq.TLO.Window('SpellBookWnd')
    local bookEverOpened = false
    local maxWait = 25000
    while maxWait > 0 do
        if me.Gem(gemSlot)() == spellName then break end

        if abortFunc and abortFunc() then
            utils.output("\arMemorization of %s aborted.", spellName)
            return false
        end

        if me.Casting() or me.Moving() then
            utils.output("\arMemorization of %s interrupted.", spellName)
            return false
        end

        if spellBook.Open() then
            bookEverOpened = true
        elseif bookEverOpened then
            utils.output("\arMemorization of %s interrupted (spellbook closed).", spellName)
            return false
        end

        mq.delay(100)
        mq.doevents()
        maxWait = maxWait - 100
    end

    if me.Gem(gemSlot)() ~= spellName then
        utils.output("\arTimed out memorizing %s.", spellName)
        return false
    end

    utils.debugOutput("Memorized %s in gem %d.", spellName, gemSlot)
    return gemSlot
end

-- Gem Strategy: Top-N Persistent + Scratch Slot
--
-- Reserves gems 1..(NumGems-1) for persistent buffs (the most-used spells
-- across all enabled sets), and gem NumGems as the scratch slot for on-demand
-- swap-ins of less-used buffs. When gems are scarce (< 2), the scratch slot
-- equals the lowest persistent slot.

local function collectSpellCounts(allSets, castCounts)
    local counts = {}
    for setName, set in pairs(allSets) do
        local setCounts = castCounts[setName] or {}
        for _, entry in ipairs(set) do
            if entry.enabled and entry.type == "spell" and entry.name ~= "" then
                if me.Book(entry.name)() and (mq.TLO.Spell(entry.name).Level() or 0) <= me.Level() then
                    counts[entry.name] = math.max(counts[entry.name] or 0, setCounts[entry.name] or 0)
                end
            end
        end
    end
    return counts
end

local function pickTopN(counts, n)
    local list = {}
    for name, count in pairs(counts) do
        table.insert(list, { name = name, count = count, })
    end
    table.sort(list, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.name < b.name
    end)
    local top = {}
    for i = 1, math.min(n, #list) do
        table.insert(top, list[i].name)
    end
    return top
end

-- Public: configure gem layout based on current set definitions and cast counts.
-- Called at queue start (and on settings reload).
function casting.ensureTopNMemmed(allSets, castCounts, abortFunc)
    gemMap = {}
    persistentSlots = {}

    local numGems = me.NumGems() or 8
    local persistentCount = math.max(1, numGems - 1)
    scratchGem = numGems

    local counts = collectSpellCounts(allSets, castCounts)
    local top = pickTopN(counts, persistentCount)

    if #top == 0 then
        utils.debugOutput("ensureTopNMemmed: no spells to persist")
        return true
    end

    -- Map already-memmed top spells to their current gems first
    local claimedGems = {}
    for _, spellName in ipairs(top) do
        for i = 1, persistentCount do
            if me.Gem(i)() == spellName and not claimedGems[i] then
                gemMap[spellName] = i
                claimedGems[i] = true
                persistentSlots[i] = spellName
                utils.debugOutput("Top spell '%s' already in gem %d", spellName, i)
                break
            end
        end
    end

    -- Memorize remaining top spells into unclaimed persistent gems
    for _, spellName in ipairs(top) do
        if not gemMap[spellName] then
            local targetGem = nil
            for i = 1, persistentCount do
                if not claimedGems[i] then
                    targetGem = i
                    break
                end
            end
            if not targetGem then
                utils.output("\arNo free persistent gem for %s.", spellName)
                break
            end
            local result = casting.memorizeSpell(targetGem, spellName, abortFunc)
            if result == false then return false end
            if result == nil then
                -- Not in spellbook, skip
            else
                gemMap[spellName] = result
                claimedGems[result] = true
                persistentSlots[result] = spellName
            end
        end
    end

    if me.Sitting() then
        mq.cmd("/stand")
        mq.delay(2000, function() return me.Standing() end)
    end

    return true
end

-- Public: ensure a non-persistent spell is in the scratch gem and return that gem.
-- Reuses the scratch slot for each swap-in.
function casting.ensureGemForSpell(spellName, abortFunc)
    if gemMap[spellName] then
        return gemMap[spellName]
    end

    local target = scratchGem or me.NumGems() or 8
    if me.Gem(target)() == spellName then
        return target
    end

    local result = casting.memorizeSpell(target, spellName, abortFunc)
    if result == false then return false end
    if result == nil then return nil end

    return result
end

-- Casting

function casting.waitForCastComplete(abortFunc)
    fizzled = false

    local startWait = 1000
    while startWait > 0 do
        mq.doevents('buffMasterFizzle')
        if me.Casting() or fizzled then break end
        mq.delay(100)
        startWait = startWait - 100
    end

    if fizzled then return true end
    if not me.Casting() then return false end

    local castWait = 30000
    while castWait > 0 do
        mq.doevents('buffMasterFizzle')
        if fizzled or not me.Casting() then break end
        if abortFunc and abortFunc() then break end
        mq.delay(100)
        castWait = castWait - 100
    end

    return true
end

local function targetSender(senderId, abortFunc)
    if (mq.TLO.Target.ID() or 0) == senderId then return true end
    mq.cmdf("/target id %d", senderId)
    return utils.waitFor(function() return (mq.TLO.Target.ID() or 0) == senderId end, 1000, 100, abortFunc)
end

-- Returns true on success, false on failure, nil on "skip but not failure" (e.g. spell unknown).
function casting.castOnSender(entry, senderId, abortFunc)
    if entry.type == "spell" then
        if not me.Book(entry.name)() then
            utils.output("\ay%s not in spellbook. Skipping.", entry.name)
            return nil
        end

        local gem = casting.ensureGemForSpell(entry.name, abortFunc)
        if gem == false then return false end
        if gem == nil then
            utils.output("\arCannot prepare %s.", entry.name)
            return false
        end

        if not utils.waitFor(function() return me.SpellReady(gem)() end, 30000, 100, abortFunc) then
            utils.output("\arSpell %s not ready in time.", entry.name)
            return false
        end

        if not targetSender(senderId, abortFunc) then
            utils.output("\arFailed to target sender for %s.", entry.name)
            return false
        end

        for attempt = 1, 3 do
            if abortFunc and abortFunc() then return false end
            utils.debugOutput("Casting spell '%s' from gem %d on target %d", entry.name, gem, senderId)
            mq.cmdf("/cast %d", gem)
            local started = casting.waitForCastComplete(abortFunc)
            if not started then
                utils.output("\arSpell %s never started casting.", entry.name)
                return false
            end
            if not fizzled then return true end
            if attempt < 3 then
                utils.debugOutput("Spell fizzled (attempt %d/3), retrying...", attempt)
                if not utils.waitFor(function() return me.SpellReady(gem)() end, 30000, 100, abortFunc) then
                    utils.output("\arSpell %s not ready in time after fizzle.", entry.name)
                    return false
                end
                if not targetSender(senderId, abortFunc) then
                    utils.output("\arLost target before retry of %s.", entry.name)
                    return false
                end
            end
        end
        utils.output("\arSpell %s fizzled 3 times. Giving up.", entry.name)
        return false
    elseif entry.type == "item" then
        if not me.ItemReady(entry.name)() then
            local item = mq.TLO.FindItem("=" .. entry.name)
            if not item() then
                utils.output("\ay%s not found in inventory. Skipping.", entry.name)
                return nil
            end
        end

        if not utils.waitFor(function() return me.ItemReady(entry.name)() end, 30000, 100, abortFunc) then
            utils.output("\arItem %s not ready in time.", entry.name)
            return false
        end

        if not targetSender(senderId, abortFunc) then
            utils.output("\arFailed to target sender for %s.", entry.name)
            return false
        end

        utils.debugOutput("Using item '%s' on target %d", entry.name, senderId)
        mq.cmdf('/useitem "%s"', entry.name)
        casting.waitForCastComplete(abortFunc)
        if abortFunc and abortFunc() then return false end
        return true
    end

    utils.output("\arUnknown source type: %s", entry.type)
    return false
end

return casting
