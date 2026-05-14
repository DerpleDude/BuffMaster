--[[
    BuffMaster - globals.lua
    Shared module-level state and constants. Access fields directly:
        local globals = require('buffmaster.lib.globals')
        globals.aborted = true
]]

local mq                  = require('mq')
local Set                 = require('mq.Set')

local globals             = {}

globals.version           = "1.0.0"

-- Module-Level State

globals.me                = mq.TLO.Me
globals.myClass           = globals.me.Class.ShortName()
globals.settings          = {}
globals.presetSets        = {}
globals.stopRequested     = false
globals.aborted           = false
globals.buffHistory       = {}
globals.queue             = {}
globals.queuedNames       = Set.new({})
globals.isBuffing         = false
globals.showUI            = true
globals.showWelcome       = false
globals.settingsDirty     = false
globals.statusText        = "Idle"
globals.TellPending       = false
globals.fizzled           = false

globals.tellAccessOptions = {
    { key = "disabled",   label = "Disabled", },
    { key = "anyone",     label = "Anyone", },
    { key = "group",      label = "Group Only", },
    { key = "raid",       label = "Raid Only", },
    { key = "fellowship", label = "Fellowship Only", },
    { key = "allowlist",  label = "Allow List", },
    { key = "denylist",   label = "Deny List", },
}

return globals
