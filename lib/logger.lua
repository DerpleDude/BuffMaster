--[[
    BuffMaster - Logger.lua
    Leveled logging adapted from rgmercs/utils/logger.lua (stripped of toast/console/comms).

    Levels: 1=Error  2=Warn  3=Info  4=Debug  5=Verbose  6=Super-Verbose
    Shortcuts: Logger.log_error, log_warn, log_info, log_debug, log_verbose, log_super_verbose
]]

local mq                     = require('mq')

local Logger                 = {}

local logDir                 = mq.TLO.MacroQuest.Path("Logs")()
local logFileOpened          = nil
local logFileHandle          = nil
local logLeaderStart         = '\ar[\ax\agBuffMaster'
local logLeaderEnd           = '\ar]\ax\aw >>>'

local currentLogLevel        = 3
local logToFileAlways        = false
local logTimestampsToConsole = false
local enableTracer           = false
local filters                = {}

local logLevels              = {
    ['super_verbose'] = { level = 6, header = "\atSUPER\aw-\apVERBOSE\ax", },
    ['verbose']       = { level = 5, header = "\apVERBOSE\ax", },
    ['debug']         = { level = 4, header = "\amDEBUG  \ax", },
    ['info']          = { level = 3, header = "\aoINFO   \ax", },
    ['warn']          = { level = 2, header = "\ayWARN   \ax", },
    ['warning']       = { level = 2, header = "\ayWARN   \ax", },
    ['error']         = { level = 1, header = "\arERROR  \ax", },
}

Logger.levelOptions          = {
    { level = 1, label = "Error", },
    { level = 2, label = "Warn", },
    { level = 3, label = "Info", },
    { level = 4, label = "Debug", },
    { level = 5, label = "Verbose", },
    { level = 6, label = "Super Verbose", },
}

function Logger.get_log_level() return currentLogLevel end

function Logger.set_log_level(level) currentLogLevel = level end

function Logger.set_log_timestamps_to_console(value) logTimestampsToConsole = value end

function Logger.set_debug_tracer_enabled(value) enableTracer = value end

function Logger.set_log_to_file(logToFile)
    if logToFileAlways ~= logToFile then
        logToFileAlways = logToFile
        if not logToFileAlways and logFileHandle then
            logFileHandle:close()
            logFileHandle = nil
            logFileOpened = nil
        end
    end
end

function Logger.set_log_filter(filter)
    filters = {}
    for token in (filter or ""):lower():gmatch("[^|]+") do
        table.insert(filters, token)
    end
end

function Logger.clear_log_filter() filters = {} end

local function openLogFile()
    local newFilePath = string.format("%s/BuffMaster_%s.log", logDir, mq.TLO.Me.Name())

    if logFileHandle and logFileOpened ~= newFilePath then
        logFileHandle:close()
        logFileHandle = nil
        logFileOpened = nil
    end

    if not logFileHandle then
        logFileHandle = io.open(newFilePath, "a")
        logFileOpened = newFilePath
        if not logFileHandle then
            print("BuffMaster: could not open log file for writing.")
        end
    end
end

local function getCallStack()
    local info = debug.getinfo(4, "Snl")
    return string.format(" \aw(\ao%s\aw::\ao%s()\aw:\ao%d\ax\aw)",
        info and info.short_src and info.short_src:match("[^\\^/]*.lua$") or "unknown_file",
        info and info.name or "unknown_func",
        info and info.currentline or 0)
end

local function log(logLevel, output, ...)
    local entry = logLevels[logLevel]
    if not entry or currentLogLevel < entry.level then return end

    if (... ~= nil) then output = string.format(output, ...) end
    local plainOutput      = output:gsub("\a.", "")

    local callerTracer = enableTracer and getCallStack() or ""
    local now          = string.format("%.03f", mq.gettime() / 1000)

    if entry.level <= 2 or logToFileAlways then
        local fileHeader = entry.header:gsub("\a.", "")
        local fileTracer = callerTracer:gsub("\a.", "")
        openLogFile()
        if logFileHandle then
            logFileHandle:write(string.format("[%s:%s%s] <%s> %s\n",
                mq.TLO.Me.Name(), fileHeader, fileTracer, now, plainOutput))
            logFileHandle:flush()
        end
    end

    if #filters > 0 then
        local found = false
        local lowerOutput = output:lower()
        for _, logFilter in ipairs(filters) do
            if #logFilter > 0 and (callerTracer:find(logFilter) or lowerOutput:find(logFilter, 1, true)) then
                found = true
                break
            end
        end
        if not found then return end
    end

    printf('%s\aw:%s%s%s%s \ax%s',
        logLeaderStart,
        entry.header,
        logTimestampsToConsole and " \aw<\at" .. now .. ">\aw" or "",
        callerTracer,
        logLeaderEnd,
        output)
end

local function generateShortcuts()
    for level, _ in pairs(logLevels) do
        Logger["log_" .. level] = function(output, ...)
            log(level, output, ...)
        end
    end
end

generateShortcuts()

return Logger
