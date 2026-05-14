--[[
    BuffMaster - ui.lua
    All ImGui rendering. Receives app state/callbacks via init({...}).
]]

local mq    = require('mq')
local imgui = require('ImGui')
local icons = require('mq.Icons')
local utils = require('buffmaster.lib.utils')

local ui    = {}

local me    = mq.TLO.Me

-- App Bindings (set in ui.init)

local deps  = nil

-- Convenience accessors (called every frame)

local function settings()         return deps.settings() end
local function presetSets()       return deps.presetSets() end
local function buffHistory()      return deps.buffHistory() end
local function isBuffing()        return deps.isBuffing() end
local function aborted()          return deps.aborted() end
local function statusText()       return deps.statusText() end
local function showUIFlag()       return deps.showUI() end
local function showWelcomeFlag()  return deps.showWelcome() end
local function getSet(name)       return deps.getSet(name) end
local function getAllSetNames(a)  return deps.getAllSetNames(a) end
local function isPresetSet(name)  return deps.isPresetSet(name) end
local function commands()         return deps.commands end
local function commandOrder()     return deps.commandOrder end
local function setSettingsDirty() deps.setSettingsDirty() end

-- UI Temp State

local showSettings         = false
local showManageSets       = false
local newSetName           = ""
local renameSetName        = ""
local manualPlayerName     = ""
local pendingRemoveIdx     = nil
local newSourceName        = ""
local newSourceType        = "spell"
local newSourceIcon        = 0
local showAddSource        = false
local editingIdx           = nil
local editSourceType       = ""
local editSourceName       = ""
local editSourceIcon       = 0
local commandsExpanded     = nil

-- Lookup Tables

local sourceTypes          = {
    { key = "spell", label = "Spell", },
    { key = "item",  label = "Clicky Item", },
}

local tellAccessOptions    = {
    { key = "disabled",   label = "Disabled", },
    { key = "anyone",     label = "Anyone", },
    { key = "group",      label = "Group Only", },
    { key = "raid",       label = "Raid Only", },
    { key = "fellowship", label = "Fellowship Only", },
    { key = "allowlist",  label = "Allow List", },
    { key = "denylist",   label = "Deny List", },
}

-- Texture Handles

local animItems            = mq.FindTextureAnimation("A_DragItem")
local animSpells           = mq.FindTextureAnimation("A_SpellIcons")
local bgTexture            = nil

local headColor            = ImVec4(0.6, 0.85, 1.0, 1.0)
local bodyColor            = ImVec4(0.78, 0.74, 0.6, 1.0)

-- Helpers

local function findIndex(tbl, key)
    for i, entry in ipairs(tbl) do
        if entry.key == key then return i end
    end
    return 1
end

local function renderWindowBg()
    if not bgTexture then return end
    local winPos  = imgui.GetWindowPosVec()
    local winSize = imgui.GetWindowSizeVec()
    local pMin    = ImVec2(winPos.x, winPos.y)
    local pMax    = ImVec2(winPos.x + winSize.x, winPos.y + winSize.y)
    imgui.GetWindowDrawList():AddImage(bgTexture:GetTextureID(), pMin, pMax,
        ImVec2(0, 0), ImVec2(1, 1), IM_COL32(255, 255, 255, 30))
end

local function renderToggle(id, value)
    local width, height = 26, 14
    local radius        = height * 0.5
    local pos           = imgui.GetCursorScreenPosVec()
    pos.y               = pos.y + (imgui.GetFrameHeight() * 0.5) - (height * 0.5) - imgui.GetStyle().FramePadding.y

    imgui.InvisibleButton(id, width, height)
    local clicked = imgui.IsItemClicked()
    if clicked then value = not value end

    local drawList = imgui.GetWindowDrawList()
    local onColor  = ImVec4(0, 0.8, 0, 1)
    local offColor = ImVec4(0.8, 0, 0, 1)
    local t        = value and 1.0 or 0.0

    drawList:AddRectFilled(ImVec2(pos.x, pos.y), ImVec2(pos.x + width, pos.y + height),
        imgui.GetColorU32(value and onColor or offColor), height * 0.5)
    drawList:AddCircleFilled(ImVec2(pos.x + radius + t * (width - height), pos.y + radius),
        radius * 0.8, imgui.GetColorU32(1, 1, 1, 1), 0)

    return value, clicked
end

local function renderItemIcon(icon)
    local pos = imgui.GetCursorScreenPosVec()
    imgui.Dummy(16, 16)
    imgui.SameLine()
    animItems:SetTextureCell(icon - 500)
    imgui.GetWindowDrawList():AddTextureAnimation(animItems, pos, ImVec2(16, 16))
end

local function renderCursorCapture(currentName, currentIcon, idSuffix)
    local hasName = currentName and currentName ~= ""
    if hasName then
        if currentIcon and currentIcon > 0 then renderItemIcon(currentIcon) end
        imgui.Text(currentName)
        imgui.SameLine()
        if imgui.SmallButton(icons.FA_TIMES .. "##clearCapture" .. idSuffix) then
            return "", 0
        end
        return currentName, currentIcon
    end

    local hasCursor = mq.TLO.Cursor.ID()
    if not hasCursor then imgui.BeginDisabled() end
    local clicked = imgui.SmallButton("Add from Cursor##" .. idSuffix)
    if not hasCursor then
        imgui.EndDisabled()
        if imgui.IsItemHovered(ImGuiHoveredFlags.AllowWhenDisabled) then
            imgui.SetTooltip("Place the clicky item on your cursor, then click to capture.")
        end
    end
    if clicked and hasCursor then
        local name = mq.TLO.Cursor.Name() or ""
        local icon = mq.TLO.Cursor.Icon() or 0
        mq.cmd("/autoinventory")
        return name, icon
    end
    return currentName, currentIcon
end

-- Welcome Window

local function renderWelcome()
    imgui.SetNextWindowSize(ImVec2(440, 360), ImGuiCond.Always)
    local titleStr   = string.format("BuffMaster v%s###BuffMasterWelcome", deps.version)
    local shouldDraw = imgui.Begin(titleStr, nil, bit32.bor(ImGuiWindowFlags.NoCollapse, ImGuiWindowFlags.NoResize))
    if shouldDraw then
        imgui.PushStyleColor(ImGuiCol.Text, headColor)
        imgui.SetWindowFontScale(1.15)
        imgui.Text("Welcome to BuffMaster!")
        imgui.SetWindowFontScale(1.0)
        imgui.PopStyleColor()
        imgui.Spacing()

        imgui.PushStyleColor(ImGuiCol.Text, bodyColor)
        imgui.TextWrapped("BuffMaster casts a configured list of buffs on a requester. " ..
            "It can buff on command or when a tell is received with your trigger word.")
        imgui.Spacing()
        imgui.TextWrapped("The most-used buffs stay memmed automatically; less-used buffs swap into a scratch gem on demand.")
        imgui.PopStyleColor()

        imgui.NewLine()

        imgui.PushStyleColor(ImGuiCol.Text, headColor)
        imgui.Text("Getting Started")
        imgui.PopStyleColor()
        imgui.Spacing()

        imgui.PushStyleColor(ImGuiCol.Text, bodyColor)
        imgui.Bullet(); imgui.SameLine()
        imgui.TextWrapped("Set your trigger word in Settings (cog icon).")
        imgui.Spacing()
        imgui.Bullet(); imgui.SameLine()
        imgui.TextWrapped("Pick or create a buff set in Manage Sets.")
        imgui.Spacing()
        imgui.Bullet(); imgui.SameLine()
        imgui.TextWrapped("Enable Tell Access in Settings to accept requests via /tell.")
        imgui.Spacing()
        imgui.Bullet(); imgui.SameLine()
        imgui.TextWrapped("Type /buffmaster help for a full list of commands.")
        imgui.PopStyleColor()

        imgui.NewLine()
        imgui.Separator()
        imgui.Spacing()

        local btnWidth = 100
        imgui.SetCursorPosX((imgui.GetWindowWidth() - btnWidth) * 0.5)
        if imgui.Button("Continue", btnWidth, 0) then
            settings().welcomeDone = true
            setSettingsDirty()
            deps.setShowWelcome(false)
        end
    end
    imgui.End()
end

-- Source Header (two-pass: pre-render claims clicks, post-render draws visuals)

local function renderSourceHeaderControls(currentSet, idx, headerCursorPos, headerScreenPos, preRender, editable)
    local entry        = currentSet[idx]
    local startingPos  = imgui.GetCursorPosVec()
    local yOffset      = imgui.GetStyle().FramePadding.y

    if not preRender and entry.name ~= "" then
        local iconCell, iconAnim
        if entry.type == "item" then
            local item    = mq.TLO.FindItem("=" .. entry.name)
            local rawIcon = (item() and item.Icon()) or entry.icon
            if rawIcon and rawIcon > 0 then
                iconCell = rawIcon - 500
                iconAnim = animItems
            end
        elseif entry.type == "spell" then
            local spell = mq.TLO.Spell(entry.name)
            if spell() then
                iconCell = spell.SpellIcon()
                iconAnim = animSpells
            end
        end
        if iconCell and iconAnim then
            local drawList = imgui.GetWindowDrawList()
            iconAnim:SetTextureCell(iconCell)
            drawList:AddTextureAnimation(iconAnim, ImVec2(headerScreenPos.x + 22, headerScreenPos.y + 2), ImVec2(16, 16))
        end
    end

    imgui.SetCursorPos(imgui.GetWindowWidth() - 170, headerCursorPos.y + yOffset)

    imgui.PushID("##hdr_ctrl_" .. idx .. (preRender and "_pre" or ""))

    if editable then
        local _, toggled = renderToggle("##enable", entry.enabled)
        if preRender and toggled then
            entry.enabled = not entry.enabled
            setSettingsDirty()
        end
    else
        imgui.BeginDisabled()
        renderToggle("##enable", entry.enabled)
        imgui.EndDisabled()
    end

    if editable then
        imgui.SameLine()
        if idx > 1 then
            if imgui.SmallButton(icons.FA_CHEVRON_UP) and preRender then
                currentSet[idx], currentSet[idx - 1] = currentSet[idx - 1], currentSet[idx]
                setSettingsDirty()
            end
        else
            imgui.InvisibleButton("##up_spacer", 22, 1)
        end

        imgui.SameLine()
        if idx < #currentSet then
            if imgui.SmallButton(icons.FA_CHEVRON_DOWN) and preRender then
                currentSet[idx], currentSet[idx + 1] = currentSet[idx + 1], currentSet[idx]
                setSettingsDirty()
            end
        else
            imgui.InvisibleButton("##dn_spacer", 22, 1)
        end

        imgui.SameLine()
        if imgui.SmallButton(icons.FA_PENCIL) and preRender then
            editingIdx      = idx
            editSourceType  = entry.type
            editSourceName  = entry.name
            editSourceIcon  = entry.icon or 0
        end

        imgui.SameLine()
        if imgui.SmallButton(icons.FA_TRASH) and preRender then
            pendingRemoveIdx = idx
        end
    end

    imgui.PopID()
    imgui.SetCursorPos(startingPos.x, startingPos.y)
    if not preRender then
        imgui.Dummy(0, 0)
    end
end

-- Main Window

local function renderMainWindow()
    imgui.SetNextWindowSize(ImVec2(400, 380), ImGuiCond.FirstUseEver)
    imgui.SetNextWindowSizeConstraints(ImVec2(400, 380), ImVec2(800, 2000))
    local prevShowUI = showUIFlag()
    local shouldDraw
    local newShowUI
    newShowUI, shouldDraw = imgui.Begin("BuffMaster", prevShowUI)
    deps.setShowUI(newShowUI)
    if not newShowUI and prevShowUI then
        utils.output("Window closed. Use \ag/buffmaster show\ax to reopen.")
    end
    if shouldDraw then
        renderWindowBg()
        local contentStartPos = imgui.GetCursorPosVec()

        imgui.Text("Status:")
        imgui.SameLine()
        if aborted() then
            imgui.TextColored(1, 0, 0, 1, "HALTED")
            imgui.SameLine()
            if imgui.SmallButton("Reset") then
                deps.resetHalt()
            end
            imgui.TextColored(1, 0, 0, 1, statusText())
        elseif isBuffing() then
            imgui.TextColored(1, 1, 0, 1, statusText())
        else
            imgui.TextColored(0, 1, 0, 1, statusText())
        end

        imgui.Text("Current Set:")
        imgui.SameLine()
        imgui.SetNextItemWidth(200)
        local comboLabel = settings().selectedSet ~= "" and settings().selectedSet or "No Sets Found"
        if settings().selectedSet == "" then imgui.PushStyleColor(ImGuiCol.Text, ImVec4(0.5, 0.5, 0.5, 1.0)) end
        if imgui.BeginCombo("##SetCombo", comboLabel) then
            for _, name in ipairs(getAllSetNames()) do
                if imgui.Selectable(name, name == settings().selectedSet) then
                    settings().selectedSet = name
                    setSettingsDirty()
                    editingIdx       = nil
                    showAddSource    = false
                    pendingRemoveIdx = nil
                end
            end
            imgui.EndCombo()
        end
        if settings().selectedSet == "" then imgui.PopStyleColor() end
        imgui.SameLine()
        if imgui.Button("Manage") then
            showManageSets = not showManageSets
        end

        imgui.SeparatorText("Buff")

        if isBuffing() then imgui.BeginDisabled() end
        imgui.PushStyleVar(ImGuiStyleVar.FramePadding, 8, 6)
        if imgui.Button("Self") then
            deps.addToQueue(me.DisplayName(), nil, false)
        end
        imgui.SameLine()
        if imgui.Button("Target") then
            deps.commandHandler("buff", "target")
        end
        imgui.SameLine()
        if imgui.Button("Group") then
            deps.commandHandler("buff", "group")
        end
        imgui.SameLine()
        if imgui.Button("Raid") then
            deps.commandHandler("buff", "raid")
        end
        imgui.PopStyleVar()

        imgui.Text("Buff a player:")
        imgui.SameLine()
        imgui.SetNextItemWidth(150)
        manualPlayerName = imgui.InputTextWithHint("##PlayerName", "Player Name", manualPlayerName)
        imgui.SameLine()
        if imgui.Button("Go") and manualPlayerName ~= "" then
            deps.addToQueue(manualPlayerName, nil, false)
        end
        if isBuffing() then imgui.EndDisabled() end

        if isBuffing() then
            if imgui.Button("Stop") then
                deps.commandHandler("stop")
            end
        end

        if imgui.CollapsingHeader("History") then
            local _, availY = imgui.GetContentRegionAvail()
            imgui.BeginChild("##HistoryScroll", ImVec2(0, availY - imgui.GetFrameHeightWithSpacing()), 0)
            for _, h in ipairs(buffHistory()) do
                imgui.TextColored(0.4, 0.8, 0.4, 1, "[%s]", h.timestamp)
                imgui.SameLine(0, 4)
                if #h.failed > 0 then
                    imgui.TextWrapped("Cast %d/%d buffs for %s. (Set: %s) Failed: %s%s",
                        h.passed, h.total, h.playerName, h.setName,
                        table.concat(h.failed, ", "), h.aborted and " (ABORTED)" or "")
                else
                    imgui.TextWrapped("Cast %d/%d buffs for %s. (Set: %s)%s",
                        h.passed, h.total, h.playerName, h.setName,
                        h.aborted and " (ABORTED)" or "")
                end
            end
            if #buffHistory() == 0 then
                imgui.TextDisabled("No history yet.")
            end
            imgui.EndChild()
        end

        local btnSize = imgui.CalcTextSize(icons.FA_COGS) + imgui.GetStyle().FramePadding.x * 2
        imgui.SetCursorPos(imgui.GetWindowWidth() - btnSize - imgui.GetStyle().WindowPadding.x, contentStartPos.y)
        if imgui.SmallButton(icons.FA_COGS) then
            showSettings = not showSettings
        end
        if imgui.IsItemHovered() then imgui.SetTooltip("Settings and Commands") end
    end
    imgui.End()
end

-- Settings Window

local function renderSettingsWindow()
    local settingsHeight = commandsExpanded and 560 or 380
    imgui.SetNextWindowSize(ImVec2(420, settingsHeight), ImGuiCond.Always)
    local settingsDraw
    local newShow
    newShow, settingsDraw = imgui.Begin("BuffMaster Settings###BuffMasterSettings", showSettings, ImGuiWindowFlags.NoResize)
    showSettings = newShow
    if settingsDraw then
        local changed

        local taIndex = findIndex(tellAccessOptions, settings().tellAccess)
        imgui.SetNextItemWidth(200)
        if imgui.BeginCombo("##tellAccess", tellAccessOptions[taIndex].label) then
            for _, opt in ipairs(tellAccessOptions) do
                if imgui.Selectable(opt.label, opt.key == settings().tellAccess) then
                    local wasDisabled = settings().tellAccess == "disabled"
                    settings().tellAccess = opt.key
                    setSettingsDirty()
                    if opt.key == "disabled" then
                        deps.unregisterTellEvent()
                    elseif wasDisabled then
                        deps.registerTellEvent()
                    end
                end
            end
            imgui.EndCombo()
        end
        imgui.SameLine()
        imgui.Text("Tell Access")
        if imgui.IsItemHovered() then
            imgui.SetTooltip("Who can request buffs via tell.")
        end
        imgui.SameLine()
        local startX        = imgui.GetCursorPosX()
        local endX          = imgui.GetWindowWidth() - imgui.GetStyle().WindowPadding.x
        local checkboxWidth = imgui.GetFrameHeight() + imgui.GetStyle().ItemInnerSpacing.x + imgui.CalcTextSize("Tell Replies")
        imgui.SetCursorPosX(startX + (endX - startX - checkboxWidth) / 2)
        settings().tellReplies, changed = imgui.Checkbox("Tell Replies", settings().tellReplies)
        if imgui.IsItemHovered() then
            imgui.SetTooltip("Reply to players who request buffs.")
        end
        if changed then setSettingsDirty() end

        if settings().tellAccess == "allowlist" then
            local alStr = table.concat(settings().tellAllowlist, ", ")
            imgui.SetNextItemWidth(350)
            alStr, changed = imgui.InputTextWithHint("##allowList", "Player1, Player2", alStr)
            if changed then
                settings().tellAllowlist = {}
                for name in alStr:gmatch("([^,]+)") do
                    local trimmed = name:gsub("^%s+", ""):gsub("%s+$", "")
                    if trimmed ~= "" then
                        table.insert(settings().tellAllowlist, trimmed)
                    end
                end
                setSettingsDirty()
            end
            imgui.SameLine()
            imgui.Text("Allow List")
        end

        if settings().tellAccess == "denylist" then
            local dlStr = table.concat(settings().tellDenylist, ", ")
            imgui.SetNextItemWidth(350)
            dlStr, changed = imgui.InputTextWithHint("##denyList", "Player1, Player2", dlStr)
            if changed then
                settings().tellDenylist = {}
                for name in dlStr:gmatch("([^,]+)") do
                    local trimmed = name:gsub("^%s+", ""):gsub("%s+$", "")
                    if trimmed ~= "" then
                        table.insert(settings().tellDenylist, trimmed)
                    end
                end
                setSettingsDirty()
            end
            imgui.SameLine()
            imgui.Text("Deny List")
        end

        imgui.SetNextItemWidth(200)
        local tw
        tw, changed = imgui.InputTextWithHint("##triggerWord", "e.g. buff me", settings().triggerWord)
        if changed then
            settings().triggerWord = tw
            setSettingsDirty()
        end
        imgui.SameLine()
        imgui.Text("Tell Trigger")
        if imgui.IsItemHovered() then
            local example = settings().triggerWord ~= "" and settings().triggerWord or "buff me"
            imgui.SetTooltip("Keyword in a tell that triggers buffing.\nExample: /tell YourName %s [Set Name]", example)
        end

        imgui.Separator()

        local announceOptions = {
            { key = "disabled", label = "Disabled", },
            { key = "group",    label = "Group", },
            { key = "raid",     label = "Raid", },
            { key = "dannet",   label = "DanNet", },
            { key = "e3bcs",    label = "E3BCS", },
        }
        local aaIndex         = findIndex(announceOptions, settings().announceArming)
        imgui.SetNextItemWidth(200)
        if imgui.BeginCombo("##announceArming", announceOptions[aaIndex].label) then
            for _, opt in ipairs(announceOptions) do
                if imgui.Selectable(opt.label, opt.key == settings().announceArming) then
                    settings().announceArming = opt.key
                    setSettingsDirty()
                end
            end
            imgui.EndCombo()
        end
        imgui.SameLine()
        imgui.Text("Announce Buffing")

        imgui.SetNextItemWidth(200)
        local pqc
        pqc, changed = imgui.InputTextWithHint("##preQueueCmd", "/echo Buffing started", settings().preQueueCommand)
        if changed then
            settings().preQueueCommand = pqc
            setSettingsDirty()
        end
        imgui.SameLine()
        imgui.Text("Pre-Queue Command")

        imgui.SetNextItemWidth(200)
        local poqc
        poqc, changed = imgui.InputTextWithHint("##postQueueCmd", "/echo Buffing complete", settings().postQueueCommand)
        if changed then
            settings().postQueueCommand = poqc
            setSettingsDirty()
        end
        imgui.SameLine()
        imgui.Text("Post-Queue Command")

        imgui.Separator()

        imgui.SetNextItemWidth(80)
        local cd
        cd, changed = imgui.InputInt("##castDistance", settings().castDistance, 0, 0)
        if changed then
            settings().castDistance = math.max(10, math.min(500, cd))
            setSettingsDirty()
        end
        imgui.SameLine()
        imgui.Text("Max Cast Distance")
        if imgui.IsItemHovered() then
            imgui.SetTooltip("Maximum distance to a requester before BuffMaster skips them.")
        end

        settings().debugMode, changed = imgui.Checkbox("Debug Logging", settings().debugMode)
        if changed then setSettingsDirty() end

        imgui.NewLine()
        imgui.PushStyleColor(ImGuiCol.Text, headColor)
        commandsExpanded = imgui.CollapsingHeader("Commands: /buffmaster ...")
        imgui.PopStyleColor()
        if commandsExpanded then
            local cmdUsageColor = ImVec4(0.5, 0.72, 0.85, 1.0)
            imgui.PushTextWrapPos(0)
            for _, name in ipairs(commandOrder()) do
                local cmd        = commands()[name]
                local shortUsage = cmd.usage:gsub("^/buffmaster ", "")
                imgui.Indent(10)
                imgui.PushStyleColor(ImGuiCol.Text, cmdUsageColor)
                imgui.Text("%s", shortUsage)
                imgui.PopStyleColor()
                imgui.SameLine(0, 0)
                imgui.PushStyleColor(ImGuiCol.Text, bodyColor)
                imgui.Text(" - %s", cmd.about)
                imgui.PopStyleColor()
                imgui.Unindent(10)
            end
            imgui.PopTextWrapPos()
        end
    end
    imgui.End()
end

-- Manage Sets Window

local function renderManageSetsWindow()
    imgui.SetNextWindowSize(ImVec2(500, 450), ImGuiCond.FirstUseEver)
    imgui.SetNextWindowSizeConstraints(ImVec2(500, 200), ImVec2(800, 2000))
    local manageSetsDraw
    local newShow
    newShow, manageSetsDraw = imgui.Begin("Manage Sets###BuffMasterEditSets", showManageSets)
    showManageSets = newShow
    if manageSetsDraw then
        local isPreset = isPresetSet(settings().selectedSet)

        imgui.Text("Set:")
        imgui.SameLine()
        imgui.SetNextItemWidth(200)
        if imgui.BeginCombo("##EditSetCombo", settings().selectedSet) then
            for _, name in ipairs(getAllSetNames()) do
                if imgui.Selectable(name .. "##edit", name == settings().selectedSet) then
                    settings().selectedSet = name
                    setSettingsDirty()
                    editingIdx       = nil
                    showAddSource    = false
                    pendingRemoveIdx = nil
                end
            end
            imgui.EndCombo()
        end

        local refreshWidth = imgui.CalcTextSize(icons.FA_REFRESH) + imgui.GetStyle().FramePadding.x * 2
        imgui.SameLine(imgui.GetContentRegionAvail() - refreshWidth + imgui.GetCursorPosX())
        if imgui.Button(icons.FA_REFRESH .. "##Rescan") then
            deps.resolvePresets()
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip("Re-scan presets against your current spellbook and inventory.")
        end

        if imgui.Button("New") then
            newSetName = ""
            imgui.OpenPopup("NewSetPopup##Edit")
        end
        imgui.SameLine()
        if imgui.Button("Copy") then
            newSetName = ""
            imgui.OpenPopup("CopySetPopup##Edit")
        end
        imgui.SameLine()
        if isPreset then imgui.BeginDisabled() end
        if imgui.Button("Rename") then
            renameSetName = settings().selectedSet
            imgui.OpenPopup("RenameSetPopup##Edit")
        end
        imgui.SameLine()
        if imgui.Button("Delete") then
            imgui.OpenPopup("DeleteSetPopup##Edit")
        end
        if isPreset then imgui.EndDisabled() end

        if imgui.BeginPopup("NewSetPopup##Edit") then
            imgui.Text("New Set Name:")
            newSetName = imgui.InputTextWithHint("##NewSetName", "Set Name", newSetName)
            if imgui.Button("Create") and newSetName ~= "" then
                if not settings().sets[newSetName] and not presetSets()[newSetName] then
                    settings().sets[newSetName] = {}
                    settings().selectedSet      = newSetName
                    setSettingsDirty()
                end
                imgui.CloseCurrentPopup()
            end
            imgui.SameLine()
            if imgui.Button("Cancel##New") then imgui.CloseCurrentPopup() end
            imgui.EndPopup()
        end

        if imgui.BeginPopup("CopySetPopup##Edit") then
            imgui.Text("Copy '%s' as:", settings().selectedSet)
            newSetName = imgui.InputTextWithHint("##CopySetName", "Set Name", newSetName)
            if imgui.Button("Copy##Confirm") and newSetName ~= "" then
                if not settings().sets[newSetName] and not presetSets()[newSetName] then
                    local sourceSet = getSet(settings().selectedSet)
                    if sourceSet then
                        local newSet = {}
                        for _, entry in ipairs(sourceSet) do
                            if entry.name ~= "" then
                                table.insert(newSet, {
                                    enabled = entry.enabled,
                                    name    = entry.name,
                                    type    = entry.type,
                                    icon    = entry.icon or 0,
                                })
                            end
                        end
                        settings().sets[newSetName] = newSet
                        settings().selectedSet      = newSetName
                        setSettingsDirty()
                    end
                end
                imgui.CloseCurrentPopup()
            end
            imgui.SameLine()
            if imgui.Button("Cancel##Copy") then imgui.CloseCurrentPopup() end
            imgui.EndPopup()
        end

        if imgui.BeginPopup("RenameSetPopup##Edit") then
            imgui.Text("Rename '%s' to:", settings().selectedSet)
            renameSetName = imgui.InputTextWithHint("##RenameSetName", "Set Name", renameSetName)
            if imgui.Button("Rename##Confirm") and renameSetName ~= "" and renameSetName ~= settings().selectedSet then
                if not settings().sets[renameSetName] and not presetSets()[renameSetName] then
                    settings().sets[renameSetName]          = settings().sets[settings().selectedSet]
                    settings().sets[settings().selectedSet] = nil
                    settings().selectedSet                  = renameSetName
                    setSettingsDirty()
                end
                imgui.CloseCurrentPopup()
            end
            imgui.SameLine()
            if imgui.Button("Cancel##Rename") then imgui.CloseCurrentPopup() end
            imgui.EndPopup()
        end

        if imgui.BeginPopup("DeleteSetPopup##Edit") then
            imgui.Text("Delete '%s'?", settings().selectedSet)
            if imgui.Button("Yes, Delete") then
                settings().sets[settings().selectedSet] = nil
                local remaining                         = getAllSetNames()
                settings().selectedSet                  = remaining[1] or ""
                setSettingsDirty()
                imgui.CloseCurrentPopup()
            end
            imgui.SameLine()
            if imgui.Button("Cancel##Delete") then imgui.CloseCurrentPopup() end
            imgui.EndPopup()
        end

        local currentSet = getSet(settings().selectedSet)
        if currentSet then
            local editable = not isPreset and not isBuffing()

            imgui.SeparatorText("Buffs")

            for i, entry in ipairs(currentSet) do
                imgui.PushID("##source_" .. i)

                local headerScreenPos = imgui.GetCursorScreenPosVec()
                local headerCursorPos = imgui.GetCursorPosVec()

                renderSourceHeaderControls(currentSet, i, headerCursorPos, headerScreenPos, true, editable)

                local unresolved = entry.name == "" and entry.candidates
                local displayName
                if unresolved then
                    displayName = "(No Source Found)"
                else
                    displayName = entry.name ~= "" and entry.name or "(unnamed)"
                end

                if unresolved then imgui.PushStyleColor(ImGuiCol.Text, ImVec4(0.5, 0.5, 0.5, 1.0)) end
                local headerOpen = imgui.CollapsingHeader("       " .. displayName .. "###header")
                if unresolved then imgui.PopStyleColor() end

                renderSourceHeaderControls(currentSet, i, headerCursorPos, headerScreenPos, false, editable)

                if headerOpen then
                    imgui.Indent()
                    local castCount = (settings().castCounts[settings().selectedSet] or {})[entry.name] or 0
                    imgui.TextDisabled("Type: %s   Cast count: %d", entry.type, castCount)
                    if entry.candidates and #entry.candidates > 1 then
                        imgui.Separator()
                        imgui.Text("Priority List:")
                        for _, candidate in ipairs(entry.candidates) do
                            local label = string.format("%s (%s)", candidate.name, candidate.type)
                            if candidate.name == entry.name then
                                imgui.TextColored(0.4, 0.9, 0.4, 1, label)
                            else
                                imgui.TextDisabled(label)
                            end
                        end
                    end
                    imgui.Unindent()
                end

                imgui.PopID()
            end

            if editable then
                if pendingRemoveIdx and (pendingRemoveIdx > #currentSet or pendingRemoveIdx < 1) then
                    pendingRemoveIdx = nil
                end
                if pendingRemoveIdx and not imgui.IsPopupOpen("DeleteSource##Edit") then
                    imgui.OpenPopup("DeleteSource##Edit")
                end
                if imgui.BeginPopup("DeleteSource##Edit") then
                    local entryName = pendingRemoveIdx and currentSet[pendingRemoveIdx]
                        and currentSet[pendingRemoveIdx].name or ""
                    if entryName == "" then entryName = "Buff " .. (pendingRemoveIdx or 0) end
                    imgui.Text("Remove '%s'?", entryName)
                    if imgui.Button("Yes, Remove") then
                        table.remove(currentSet, pendingRemoveIdx)
                        setSettingsDirty()
                        editingIdx       = nil
                        pendingRemoveIdx = nil
                        imgui.CloseCurrentPopup()
                    end
                    imgui.SameLine()
                    if imgui.Button("Cancel##RemoveSource") then
                        pendingRemoveIdx = nil
                        imgui.CloseCurrentPopup()
                    end
                    imgui.EndPopup()
                end

                imgui.Separator()
                if imgui.Button("Add Buff") then
                    newSourceName  = ""
                    newSourceType  = "spell"
                    newSourceIcon  = 0
                    showAddSource  = true
                end
            end
        end
    end
    imgui.End()
end

-- Add Buff Window

local function renderAddSourceWindow()
    local currentSet = getSet(settings().selectedSet)
    if not currentSet or isPresetSet(settings().selectedSet) or isBuffing() then
        showAddSource = false
        return
    end
    imgui.SetNextWindowSize(ImVec2(350, 170), ImGuiCond.FirstUseEver)
    local addOpen, addDraw = imgui.Begin("Add Buff###BuffMasterAddSource", showAddSource)
    if not addOpen then showAddSource = false end
    if addDraw then
        local nsIdx = findIndex(sourceTypes, newSourceType)
        imgui.Text("Type:")
        imgui.SameLine()
        imgui.SetNextItemWidth(180)
        if imgui.BeginCombo("##newType", sourceTypes[nsIdx].label) then
            for _, src in ipairs(sourceTypes) do
                if imgui.Selectable(src.label, src.key == newSourceType) then
                    newSourceType = src.key
                end
            end
            imgui.EndCombo()
        end

        if newSourceType == "item" then
            imgui.Text("Clicky Item:")
            imgui.SameLine()
            newSourceName, newSourceIcon = renderCursorCapture(newSourceName, newSourceIcon, "addCapture")
        else
            imgui.Text("Spell Name:")
            imgui.SameLine()
            imgui.SetNextItemWidth(200)
            newSourceName = imgui.InputTextWithHint("##newName", "Exact In-Game Name", newSourceName)
            newSourceIcon = 0
        end

        imgui.Spacing()
        if imgui.Button("Create") and newSourceName ~= "" then
            table.insert(currentSet, {
                enabled = true,
                name    = newSourceName,
                type    = newSourceType,
                icon    = newSourceIcon or 0,
            })
            setSettingsDirty()
            showAddSource = false
            newSourceName = ""
            newSourceIcon = 0
        end
        imgui.SameLine()
        if imgui.Button("Cancel##AddSource") then
            showAddSource = false
        end
    end
    imgui.End()
end

-- Edit Buff Window

local function renderEditSourceWindow()
    local currentSet = getSet(settings().selectedSet)
    local entry      = currentSet and currentSet[editingIdx]
    if not entry or isPresetSet(settings().selectedSet) or isBuffing() then
        editingIdx = nil
        return
    end
    imgui.SetNextWindowSize(ImVec2(350, 170), ImGuiCond.FirstUseEver)
    local editOpen, editDraw = imgui.Begin("Edit Buff###BuffMasterEditSource", editingIdx ~= nil)
    if not editOpen then editingIdx = nil end
    if editDraw then
        local tIdx = findIndex(sourceTypes, editSourceType)
        imgui.Text("Type:")
        imgui.SameLine()
        imgui.SetNextItemWidth(180)
        if imgui.BeginCombo("##editType", sourceTypes[tIdx].label) then
            for _, src in ipairs(sourceTypes) do
                if imgui.Selectable(src.label, src.key == editSourceType) then
                    editSourceType = src.key
                    if editSourceType ~= "item" then editSourceIcon = 0 end
                end
            end
            imgui.EndCombo()
        end

        if editSourceType == "item" then
            imgui.Text("Clicky Item:")
            imgui.SameLine()
            editSourceName, editSourceIcon = renderCursorCapture(editSourceName, editSourceIcon, "editCapture")
        else
            imgui.Text("Spell Name:")
            imgui.SameLine()
            imgui.SetNextItemWidth(200)
            editSourceName = imgui.InputTextWithHint("##editName", "Exact In-Game Name", editSourceName)
        end

        imgui.Spacing()
        if imgui.Button("Save") then
            entry.type = editSourceType
            entry.name = editSourceName
            entry.icon = editSourceIcon or 0
            setSettingsDirty()
            editingIdx = nil
        end
        imgui.SameLine()
        if imgui.Button("Cancel##EditSource") then
            editingIdx = nil
        end
    end
    imgui.End()
end

-- Render Dispatcher

function ui.render()
    if mq.TLO.MacroQuest.GameState() ~= 'INGAME' then return end
    if not showUIFlag() and not showWelcomeFlag() then return end

    imgui.PushStyleVar(ImGuiStyleVar.FrameRounding, 4)
    imgui.PushStyleVar(ImGuiStyleVar.WindowRounding, 6)
    imgui.PushStyleVar(ImGuiStyleVar.ChildRounding, 4)
    imgui.PushStyleVar(ImGuiStyleVar.PopupRounding, 4)
    imgui.PushStyleVar(ImGuiStyleVar.GrabRounding, 4)

    if showWelcomeFlag() then
        renderWelcome()
        imgui.PopStyleVar(5)
        return
    end

    renderMainWindow()
    if showSettings then renderSettingsWindow() end
    if showManageSets then renderManageSetsWindow() end
    if showAddSource then renderAddSourceWindow() end
    if editingIdx then renderEditSourceWindow() end

    imgui.PopStyleVar(5)
end

function ui.init(d)
    deps       = d
    bgTexture  = mq.CreateTexture(mq.luaDir .. "/buffmaster/resources/buffmaster_bg.png")
end

return ui
