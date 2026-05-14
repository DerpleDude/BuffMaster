--[[
    BuffMaster - Live/Test Server Presets
    Array of preset definitions with title, classes, and ordered effects (priority groups).
    Each priority group is a list of candidates - first available source wins.

    Seed data - signature buff per caster class. Names target reasonably recent live
    expansions; rescan or edit if your character can't see them.
]]

return {
    {
        title = "Class Preset (Live)",
        alias = "preset",
        classes = { "CLR", },
        effects = {
            {
                { name = "Aegolism", type = "spell", },
                { name = "Blessing of Aegolism", type = "spell", },
                { name = "Hand of Conviction", type = "spell", },
            },
        },
    },
    {
        title = "Class Preset (Live)",
        alias = "preset",
        classes = { "DRU", },
        effects = {
            {
                { name = "Protection of the Glades", type = "spell", },
                { name = "Skin like Diamond", type = "spell", },
                { name = "Skin like Nature", type = "spell", },
            },
        },
    },
    {
        title = "Class Preset (Live)",
        alias = "preset",
        classes = { "SHM", },
        effects = {
            {
                { name = "Talisman of Wunshi", type = "spell", },
                { name = "Talisman of the Brute", type = "spell", },
                { name = "Spirit of Wolf", type = "spell", },
            },
        },
    },
    {
        title = "Class Preset (Live)",
        alias = "preset",
        classes = { "ENC", },
        effects = {
            {
                { name = "Visage of Pyzjn", type = "spell", },
                { name = "Brilliance", type = "spell", },
                { name = "Clarity", type = "spell", },
            },
        },
    },
    {
        title = "Class Preset (Live)",
        alias = "preset",
        classes = { "MAG", },
        effects = {
            {
                { name = "Burnout", type = "spell", },
                { name = "Shield of the Magister", type = "spell", },
            },
        },
    },
    {
        title = "Class Preset (Live)",
        alias = "preset",
        classes = { "NEC", },
        effects = {
            {
                { name = "Demonic Visage", type = "spell", },
                { name = "Call of Bones", type = "spell", },
                { name = "Lich", type = "spell", },
            },
        },
    },
    {
        title = "Class Preset (Live)",
        alias = "preset",
        classes = { "WIZ", },
        effects = {
            {
                { name = "Voice of Quellious", type = "item", },
            },
        },
    },
}
