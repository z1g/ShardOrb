-- ShardOrb. MIT-style, do what you like with it.
--
-- A tiny Necrosis-style soul shard orb for Warlocks: black disc with a purple ring,
-- shard count in the middle, small bordered buttons nested tight against it
-- that cast Create Healthstone, Create Soulstone, Ritual of Summoning, and your four
-- demons (Imp, Voidwalker, Succubus, Felhunter). Nothing else: no timers, no buffs, no
-- reagent shopping list.
--
-- Built for WoW: Forever (Interface 16001), which shares the modern Mainline API:
-- C_SpellBook for the spellbook, C_Item/C_Container for bags, SecureActionButtonTemplate
-- for casting. The cast buttons use a one-time macro ("/cast Create Healthstone") set at
-- button creation rather than a dynamically-updated "spell" attribute: this client's
-- protected-action rules silently refuse later attribute changes on a secure button with
-- no Lua error and no way for pcall to catch it, so the value just has to be right once
-- and never touched again -- exactly what a macro already does on every rank change.

local ADDON, ns = ...

local SHARD_ITEM_ID = 6265 -- Soul Shard, same id this client's reagent/bag API already uses

-- The spells this addon cares about, keyed by role. `name` is the exact spellbook
-- name as the game shows it (every rank shares it; only subName differs).
local SPELL_DEFS = {
    { key = "HEALTHSTONE", name = "Create Healthstone", fallbackIcon = "Interface\\Icons\\INV_Stone_04" },
    { key = "SOULSTONE",   name = "Create Soulstone",   fallbackIcon = "Interface\\Icons\\INV_Misc_Orb_04" },
    { key = "RITUAL",      name = "Ritual of Summoning", fallbackIcon = "Interface\\Icons\\Spell_Shadow_Twilight" },
    { key = "IMP",         name = "Summon Imp",          fallbackIcon = "Interface\\Icons\\Spell_Shadow_SummonImp" },
    { key = "VOIDWALKER",  name = "Summon Voidwalker",   fallbackIcon = "Interface\\Icons\\Spell_Shadow_SummonVoidwalker" },
    { key = "SUCCUBUS",    name = "Summon Succubus",     fallbackIcon = "Interface\\Icons\\Spell_Shadow_SummonSuccubus" },
    { key = "FELHUNTER",   name = "Summon Felhunter",    fallbackIcon = "Interface\\Icons\\Spell_Shadow_SummonFelhunter" },
}

local SPHERE_SIZE = 64
local BUTTON_SIZE = 30
local ORBIT_RADIUS = 40 -- nudged out a bit so the bigger buttons don't overlap each other
local BORDER_THICKNESS = 3
local SPHERE_RING_THICKNESS = 8 -- purple band
local SPHERE_OUTER_THICKNESS = 3 -- black rim outside the purple
local LOGIN_POLL_SECONDS = 20
local LOGIN_POLL_INTERVAL = 0.5

local CIRCLE_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local BORDER_COLOR = { 0.05, 0.03, 0.08, 1 }   -- near-black ring on the orbit buttons
local SHARD_COLOR  = { 0.62, 0.08, 0.82, 1 }   -- Soul Shard purple/magenta (sphere ring)
local SPHERE_FILL   = { 0, 0, 0, 1 }           -- black disc under the count

-- Forever taint: secret values cannot be compared, added, or tostring'd by addons.
-- pcall does NOT catch ADDON_ACTION_BLOCKED, so we have to skip them instead.
local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v)
end

local function ReadableNumber(v)
    if v == nil or IsSecret(v) then return nil end
    return tonumber(v)
end

-- Never bake Enum.BagIndex.ReagentBag into a file-load local: on a Forever cold login
-- that Enum field is often still nil when addons first run, and `for bag = 0, nil`
-- throws "'for' limit must be a number". That used to abort CountShardsInBags AFTER
-- GetItemCount had already returned 14, so the sphere stayed at the BuildFrames "0"
-- until /reload (when Enum is fully populated). Fallback is backpack + 4 bags.
local function LastBagIndex()
    local last = 4
    if type(NUM_BAG_SLOTS) == "number" then
        last = NUM_BAG_SLOTS
    end
    local reagent = Enum and Enum.BagIndex and ReadableNumber(Enum.BagIndex.ReagentBag)
    if reagent and reagent > last then
        last = reagent
    end
    return last
end

local function CountShardsInBags()
    -- Returns count, ready.
    -- ready=false means bag APIs have not actually loaded yet: keep whatever is on
    -- the sphere rather than stamping a fake 0 over a later good value.
    local apiCount = 0
    if C_Item and C_Item.GetItemCount then
        apiCount = ReadableNumber(C_Item.GetItemCount(SHARD_ITEM_ID)) or 0
    elseif GetItemCount then
        apiCount = ReadableNumber(GetItemCount(SHARD_ITEM_ID)) or 0
    end

    local n, anySlots = 0, false
    local scanOk, scanN, scanSlots = pcall(function()
        local found, slots = 0, false
        if not (C_Container and C_Container.GetContainerNumSlots) then
            return found, slots
        end
        local lastBag = LastBagIndex()
        for bag = 0, lastBag do
            local numSlots = ReadableNumber(C_Container.GetContainerNumSlots(bag)) or 0
            if numSlots > 0 then slots = true end
            for slot = 1, numSlots do
                local id
                if C_Container.GetContainerItemID then
                    id = ReadableNumber(C_Container.GetContainerItemID(bag, slot))
                end
                if id == SHARD_ITEM_ID then
                    local add = 1
                    if C_Container.GetContainerItemInfo then
                        local info = C_Container.GetContainerItemInfo(bag, slot)
                        if type(info) == "table" and not IsSecret(info.stackCount) then
                            add = ReadableNumber(info.stackCount) or 1
                        end
                    end
                    found = found + add
                end
            end
        end
        return found, slots
    end)
    if scanOk then
        n = scanN or 0
        anySlots = scanSlots and true or false
    end

    local count = math.max(n, apiCount)
    local ready = (apiCount > 0) or anySlots
    return count, ready
end

-- Classic / Forever soulstone item ids (Create Soulstone still leaves a bag item).
-- Highest rank first so /use hits the best stone if more than one is sitting around.
local SOULSTONE_ID_ORDER = { 36895, 22116, 16896, 16895, 16893, 16892, 5232 }
local SOULSTONE_IDS = {}
for _, id in ipairs(SOULSTONE_ID_ORDER) do
    SOULSTONE_IDS[id] = true
end

local function CombatLocked()
    return InCombatLockdown ~= nil and InCombatLockdown()
end

local function IsSoulstoneName(name)
    if type(name) ~= "string" then return false end
    local l = name:lower()
    return l:find("soulstone", 1, true) ~= nil and l:find("create", 1, true) == nil
end

-- Returns itemID, name (either may be nil). Used to swap the soulstone button
-- between Create and /use on the current target.
local function FindSoulstoneInBags()
    if C_Item and C_Item.GetItemCount then
        for _, id in ipairs(SOULSTONE_ID_ORDER) do
            local n = ReadableNumber(C_Item.GetItemCount(id))
            if n and n > 0 then
                local name
                if C_Item.GetItemNameByID then
                    name = C_Item.GetItemNameByID(id)
                end
                if (not name or IsSecret(name)) and GetItemInfo then
                    name = GetItemInfo(id)
                end
                if name and IsSecret(name) then name = nil end
                return id, name
            end
        end
    end

    local foundId, foundName
    pcall(function()
        if not (C_Container and C_Container.GetContainerNumSlots) then return end
        local lastBag = LastBagIndex()
        for bag = 0, lastBag do
            local numSlots = ReadableNumber(C_Container.GetContainerNumSlots(bag)) or 0
            for slot = 1, numSlots do
                local id = C_Container.GetContainerItemID and ReadableNumber(C_Container.GetContainerItemID(bag, slot))
                local name
                if C_Container.GetContainerItemLink then
                    local link = C_Container.GetContainerItemLink(bag, slot)
                    if type(link) == "string" then
                        name = link:match("%[(.-)%]")
                    end
                end
                if (id and SOULSTONE_IDS[id]) or IsSoulstoneName(name) then
                    foundId, foundName = id, name
                    return
                end
            end
        end
    end)
    return foundId, foundName
end

local function SoulstoneUseMacro(id, name)
    local itemRef = id and ("item:" .. tostring(id)) or name
    -- Exact request: apply to the player's current target (not a self fallback).
    return "/use [@target] " .. itemRef
end

-- Draws a bordered circle on `parent`: a slightly larger BACKGROUND disc behind an
-- inset ARTWORK disc, so the outer color only shows through as a ring. Uses a real
-- MaskTexture object (not the legacy TextureBase:SetMask(path) string call, which this
-- client's modern rendering pipeline silently ignores -- it never errors, the texture
-- just stays square). opts.fill / opts.border are {r,g,b,a}; opts.thickness is the
-- ring width in pixels. Returns the inset fill texture so the caller can recolor it
-- or put an icon on it.
local function MaskedDisc(parent, layer, inset, color)
    local tex = parent:CreateTexture(nil, layer)
    tex:SetPoint("TOPLEFT", parent, "TOPLEFT", inset, -inset)
    tex:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -inset, inset)
    local mask = parent:CreateMaskTexture()
    mask:SetAllPoints(tex)
    mask:SetTexture(CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    tex:AddMaskTexture(mask)
    if color then tex:SetColorTexture(unpack(color)) end
    return tex
end

-- Draws concentric circles on `parent`. opts.outerThickness (black rim) sits outside
-- opts.thickness (colored ring). Uses MaskTexture objects (SetMask(path) is ignored
-- on this client). Returns the innermost fill texture.
local function MakeBorderedCircle(parent, opts)
    opts = opts or {}
    local outer = opts.outerThickness or 0
    local thickness = opts.thickness or BORDER_THICKNESS
    local borderColor = opts.border or BORDER_COLOR
    local outerColor = opts.outer or SPHERE_FILL

    if outer > 0 then
        MaskedDisc(parent, "BACKGROUND", 0, outerColor)
        MaskedDisc(parent, "BORDER", outer, borderColor)
    else
        MaskedDisc(parent, "BACKGROUND", 0, borderColor)
    end
    local fill = MaskedDisc(parent, "ARTWORK", outer + thickness, opts.fill)
    return fill
end

-- Forward declarations: the slash command below needs to be able to call these even
-- though they're only actually built further down the file.
local sphere, buttons, RestorePosition, RefreshShardCount, RefreshSpells, RefreshSoulstoneButton, BuildError, didInit, DumpSpellbook, DumpBagDiagnostics, loginElapsed, pollActive
local EnsureSummonQueueWindow, UpdateSummonQueueDisplay, ToggleSummonQueue, ClearSummonQueue, RebuildSummonQueueSecureRows
local UpdateTargetAlerts, UpdateShadowTrance, TestShadowTrance, DumpPlayerAuras
local RefreshRingChunks

----------------------------------------------------------------------
-- Saved position
----------------------------------------------------------------------

local function EnsureDB()
    ShardOrbDB = ShardOrbDB or {}
    if ShardOrbDB.locked == nil then ShardOrbDB.locked = false end
    return ShardOrbDB
end

----------------------------------------------------------------------
-- Slash command -- registered before anything risky, so it always works.
----------------------------------------------------------------------

SLASH_SHARDORB1 = "/shardorb"
SLASH_SHARDORB2 = "/so"
SlashCmdList["SHARDORB"] = function(msg)
    msg = (msg or ""):lower()
    msg = msg:match("^%s*(.-)%s*$") or ""
    local db = EnsureDB()
    if msg == "lock" then
        db.locked = true
        print("ShardOrb: locked.")
    elseif msg == "unlock" then
        db.locked = false
        print("ShardOrb: unlocked, drag it where you like.")
    elseif msg == "reset" then
        db.x, db.y = nil, nil
        if RestorePosition then RestorePosition() end
        print("ShardOrb: position reset.")
    elseif msg == "status" then
        print("ShardOrb status:")
        print("  build error: " .. tostring(BuildError))
        print("  sphere built: " .. tostring(sphere ~= nil))
        if sphere then
            print("  sphere shown: " .. tostring(sphere:IsShown()))
            print("  count text: " .. tostring(sphere.countText and sphere.countText:GetText()))
        end
        local count, ready = CountShardsInBags()
        print("  count now: " .. tostring(count) .. " ready=" .. tostring(ready))
        print("  last bag index: " .. tostring(LastBagIndex()))
        local ssId, ssName = FindSoulstoneInBags()
        print("  soulstone in bags: " .. tostring(ssId or ssName or "none"))
        print("  soulstone button: " .. tostring(buttons and buttons.SOULSTONE and buttons.SOULSTONE.ssMode))
        print("  class: " .. tostring(UnitClassBase and UnitClassBase("player")))
    elseif msg == "refresh" then
        if RefreshSpells then RefreshSpells() end
        if RefreshShardCount then RefreshShardCount() end
        if RefreshSoulstoneButton then RefreshSoulstoneButton() end
        local count, ready = CountShardsInBags()
        print("ShardOrb: icons/count refreshed. Count is now " .. tostring(count) .. " (ready=" .. tostring(ready) .. ")")
    elseif msg == "count" then
        DumpBagDiagnostics()
    elseif msg == "spells" then
        if DumpSpellbook then DumpSpellbook() else print("ShardOrb: spellbook dumper not ready yet.") end
    elseif msg == "queue" then
        if ToggleSummonQueue then ToggleSummonQueue() end
    elseif msg == "queue clear" then
        if ClearSummonQueue then ClearSummonQueue() end
        print("ShardOrb: summon queue cleared.")
    elseif msg == "alerts" then
        local db = EnsureDB()
        db.alerts = not (db.alerts ~= false)
        print("ShardOrb: target alerts " .. (db.alerts and "on" or "off"))
        if UpdateTargetAlerts then UpdateTargetAlerts() end
    elseif msg == "auras" then
        if DumpPlayerAuras then DumpPlayerAuras() else print("ShardOrb: aura dumper not ready yet.") end
    elseif msg == "trance test" then
        if TestShadowTrance then TestShadowTrance() else print("ShardOrb: trance tester not ready yet.") end
    elseif msg == "trance" then
        local db = EnsureDB()
        db.trance = not (db.trance ~= false)
        print("ShardOrb: shadow trance alert " .. (db.trance and "on" or "off"))
        if UpdateShadowTrance then UpdateShadowTrance() end
    else
        print("ShardOrb: /shardorb lock | unlock | reset | status | refresh | count | spells | queue | queue clear | alerts | trance | trance test | auras")
    end
end

----------------------------------------------------------------------
-- Bag diagnostic -- run on demand with /shardorb count
----------------------------------------------------------------------

DumpBagDiagnostics = function()
    local firstBag, lastBag = 0, LastBagIndex()
    local bagCount, ready = CountShardsInBags()
    local apiCount = "n/a"
    if C_Item and C_Item.GetItemCount then
        apiCount = tostring(ReadableNumber(C_Item.GetItemCount(SHARD_ITEM_ID)) or "unreadable")
    end
    print("ShardOrb: combined count = " .. tostring(bagCount) .. " ready=" .. tostring(ready) .. ", C_Item.GetItemCount = " .. tostring(apiCount) .. " (bags " .. firstBag .. " to " .. tostring(lastBag) .. ")")
    if not (C_Container and C_Container.GetContainerNumSlots) then
        print("  C_Container.GetContainerNumSlots missing")
        return
    end
    for bag = firstBag, lastBag do
        local numSlots = ReadableNumber(C_Container.GetContainerNumSlots(bag)) or 0
        local hits = {}
        for slot = 1, numSlots do
            local id = C_Container.GetContainerItemID and C_Container.GetContainerItemID(bag, slot)
            id = ReadableNumber(id)
            if id then hits[#hits + 1] = slot .. "=" .. tostring(id) end
        end
        print("  bag " .. bag .. ": " .. numSlots .. " slots, items: " .. (next(hits) and table.concat(hits, ", ") or "(empty)"))
    end
end

----------------------------------------------------------------------
-- Spellbook dump (diagnostic only, run with /shardorb spells)
----------------------------------------------------------------------

DumpSpellbook = function()
    local numLines = C_SpellBook.GetNumSpellBookSkillLines()
    print("ShardOrb: " .. tostring(numLines) .. " spellbook skill line(s)")
    for i = 1, numLines do
        local skillLineInfo = C_SpellBook.GetSpellBookSkillLineInfo(i)
        if skillLineInfo then
            local offset, numSlots = skillLineInfo.itemIndexOffset, skillLineInfo.numSpellBookItems
            for j = offset + 1, offset + numSlots do
                local info = C_SpellBook.GetSpellBookItemInfo(j, Enum.SpellBookSpellBank.Player)
                if info then
                    local lname = tostring(info.name or "?"):lower()
                    if lname:find("heal") or lname:find("soul") or lname:find("ritual") or lname:find("summon") then
                        print(string.format("    slot %d: type=%s action=%s name=%q subName=%q",
                            j, tostring(info.itemType), tostring(info.actionID), tostring(info.name), tostring(info.subName)))
                    end
                end
            end
        end
    end
end

----------------------------------------------------------------------
-- Frames -- wrapped in pcall so a failure here can't swallow anything above it,
-- and so /shardorb status can tell you exactly what went wrong.
----------------------------------------------------------------------

local function BuildFrames()
    sphere = CreateFrame("Button", "ShardOrbSphere", UIParent)
    sphere:SetSize(SPHERE_SIZE, SPHERE_SIZE)
    sphere:SetFrameStrata("MEDIUM")
    sphere:SetMovable(true)
    sphere:EnableMouse(true)
    sphere:RegisterForDrag("LeftButton")

    -- Outer black rim + inner black disc. Purple lives in the band between them
    -- as one chunk per soul shard (RefreshRingChunks).
    MaskedDisc(sphere, "BACKGROUND", 0, SPHERE_FILL)
    MaskedDisc(sphere, "ARTWORK", SPHERE_OUTER_THICKNESS + SPHERE_RING_THICKNESS, SPHERE_FILL)

    local count = sphere:CreateFontString(nil, "OVERLAY", "NumberFontNormalLarge")
    count:SetPoint("CENTER", sphere, "CENTER", 0, 0)
    count:SetTextColor(1, 1, 1, 1)
    count:SetText("0")
    sphere.countText = count

    sphere:SetScript("OnDragStart", function(self)
        if EnsureDB().locked then return end
        self:StartMoving()
    end)
    sphere:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local db = EnsureDB()
        local x, y = self:GetCenter()
        local ux, uy = UIParent:GetCenter()
        db.x, db.y = x - ux, y - uy
    end)
    sphere:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Soul Shards")
        local n = CountShardsInBags()
        GameTooltip:AddLine(n .. " in your bags", 1, 1, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Drag to move. /shardorb lock to anchor it.", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    sphere:SetScript("OnLeave", GameTooltip_Hide)

    buttons = {}

    local numButtons = #SPELL_DEFS
    for i, def in ipairs(SPELL_DEFS) do
        local b = CreateFrame("Button", "ShardOrb" .. def.key, sphere, "SecureActionButtonTemplate")
        b:SetSize(BUTTON_SIZE, BUTTON_SIZE)
        b:RegisterForClicks("AnyUp", "AnyDown")
        -- Set once at creation. Soulstone is the exception: out of combat we rewrite
        -- macrotext to /use on target once a stone exists (see RefreshSoulstoneButton).
        b:SetAttribute("type", "macro")
        b:SetAttribute("macrotext", "/cast " .. def.name)

        -- Evenly spaced around the full ring, starting at the bottom (270°) so the
        -- first few buttons land where the old hand-placed layout used to sit.
        local angle = math.rad(270 + (i - 1) * (360 / numButtons))
        b:SetPoint("CENTER", sphere, "CENTER", math.cos(angle) * ORBIT_RADIUS, math.sin(angle) * ORBIT_RADIUS)
        b:SetFrameLevel(sphere:GetFrameLevel() + 2)

        local fill = MakeBorderedCircle(b)
        fill:SetTexture(def.fallbackIcon)
        b.icon = fill

        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if def.key == "SOULSTONE" and self.ssMode and self.ssMode ~= "create" then
                GameTooltip:SetText("Use Soulstone")
                GameTooltip:AddLine("Applies to your current target.", 1, 1, 1)
            else
                local ok3 = pcall(GameTooltip.SetSpellByID, GameTooltip, def.name)
                if not ok3 then
                    GameTooltip:SetText(def.name)
                end
            end
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)

        def.button = b
        buttons[def.key] = b
    end
end

local MAX_RING_CHUNKS = 40
local ringChunks = {}
local lastRingN = -1

RefreshRingChunks = function(n)
    if not sphere then return end
    n = math.floor(tonumber(n) or 0)
    if n < 0 then n = 0 end
    if n > MAX_RING_CHUNKS then n = MAX_RING_CHUNKS end
    if n == lastRingN then return end
    lastRingN = n

    if not sphere.ringSolid then
        sphere.ringSolid = MaskedDisc(sphere, "BORDER", SPHERE_OUTER_THICKNESS, SHARD_COLOR)
        sphere.ringSolid:Hide()
    end

    if n <= 0 then
        sphere.ringSolid:Hide()
        for i = 1, #ringChunks do
            ringChunks[i]:Hide()
        end
        return
    end

    -- One shard: a full purple band. sin(pi/n) is 0 at n=1 so bars don't work.
    if n == 1 then
        sphere.ringSolid:Show()
        for i = 1, #ringChunks do
            ringChunks[i]:Hide()
        end
        return
    end

    sphere.ringSolid:Hide()
    local r = (SPHERE_SIZE / 2) - SPHERE_OUTER_THICKNESS - (SPHERE_RING_THICKNESS / 2)
    local width = math.max(3, (2 * math.pi * r / n) * 0.78)
    local start = math.pi / 2 -- top
    for i = 1, n do
        local tex = ringChunks[i]
        if not tex then
            tex = sphere:CreateTexture(nil, "ARTWORK", nil, 1)
            tex:SetColorTexture(unpack(SHARD_COLOR))
            ringChunks[i] = tex
        end
        local a = start - (i - 0.5) * (2 * math.pi / n)
        tex:ClearAllPoints()
        tex:SetPoint("CENTER", sphere, "CENTER", math.cos(a) * r, math.sin(a) * r)
        tex:SetSize(width, SPHERE_RING_THICKNESS)
        if tex.SetRotation then
            pcall(tex.SetRotation, tex, a + math.pi / 2)
        end
        tex:Show()
    end
    for i = n + 1, #ringChunks do
        ringChunks[i]:Hide()
    end
end

RefreshShardCount = function()
    if not sphere or not sphere.countText then return end
    local n, ready = CountShardsInBags()
    if not ready then return end
    sphere.countText:SetText(tostring(n))
    if RefreshRingChunks then RefreshRingChunks(n) end
end

RefreshSpells = function()
    if not buttons then return end
    for _, def in ipairs(SPELL_DEFS) do
        local b = def.button
        if b and b.icon then
            local texPath
            if C_Spell and C_Spell.GetSpellTexture then
                texPath = C_Spell.GetSpellTexture(def.name)
            end
            b.icon:SetTexture(texPath or def.fallbackIcon)
        end
    end
end

-- Create Soulstone when bags have no stone; once one exists, the same click uses it
-- on the current target. Secure attributes can only change out of combat on this
-- client — if a stone appears/disappears mid-fight we wait for PLAYER_REGEN_ENABLED.
local lastSoulstoneKey
local soulstoneDirty = false

RefreshSoulstoneButton = function()
    local b = buttons and buttons.SOULSTONE
    if not b then return end
    if CombatLocked() then
        soulstoneDirty = true
        return
    end
    soulstoneDirty = false
    local id, name = FindSoulstoneInBags()
    local key, macro
    if id or name then
        key = "use:" .. tostring(id or name)
        macro = SoulstoneUseMacro(id, name)
    else
        key = "create"
        macro = "/cast Create Soulstone"
    end
    if key == lastSoulstoneKey then
        b.ssMode = key
        return
    end
    lastSoulstoneKey = key
    b:SetAttribute("type", "macro")
    b:SetAttribute("macrotext", macro)
    b.ssMode = key
end

RestorePosition = function()
    if not sphere then return end
    local db = EnsureDB()
    sphere:ClearAllPoints()
    if db.x and db.y then
        sphere:SetPoint("CENTER", UIParent, "CENTER", db.x, db.y)
    else
        sphere:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
    end
end

----------------------------------------------------------------------
-- Summon queue
-- Party/raid (and instance) chat, exact line like Necrosis: 123, summon, inv, +1
-- Click a name: target them and cast Ritual of Summoning.
----------------------------------------------------------------------

local QUEUE_TRIGGERS = {
    ["123"] = true,
    ["summon"] = true,
    ["inv"] = true,
    ["+1"] = true,
}
local MAX_SUMMON_QUEUE = 20
local QUEUE_ROW_HEIGHT = 22
local QUEUE_WIDTH = 240

local summonQueue = {} -- { { key, display, targetName }, ... }
local queueFrame, queueRows, queueDirty
local queueRowSerial = 0
local pendingSummonName -- who the current Ritual of Summoning is for

local function MessageIsQueueTrigger(message)
    if type(message) ~= "string" or IsSecret(message) then return false end
    local clean = message:match("^%s*(.-)%s*$")
    if not clean or clean == "" then return false end
    return QUEUE_TRIGGERS[clean:lower()] == true
end

local function UnitFullName(unit)
    if not unit or not UnitExists or not UnitExists(unit) then return nil end
    local name, surname = UnitName(unit)
    if not name or IsSecret(name) then return nil end
    if surname and surname ~= "" and not IsSecret(surname) then
        return name .. " " .. surname, name
    end
    return name, name
end

local function NormalizeChatSender(sender)
    if type(sender) ~= "string" or IsSecret(sender) then return nil end
    -- Drop -Realm if present; Forever may already send "Name Surname".
    local noRealm = sender:match("^([^-]+)") or sender
    return noRealm:match("^%s*(.-)%s*$")
end

local function NamesMatch(a, b)
    if not a or not b then return false end
    return a:lower() == b:lower()
end

-- Resolve a chat sender to a party/raid member. Returns display name for
-- /targetexact, or nil if they are not in the group (or are us).
local function ResolveGroupMember(sender)
    local want = NormalizeChatSender(sender)
    if not want then return nil end
    local meFull, meFirst = UnitFullName("player")
    if NamesMatch(want, meFull) or NamesMatch(want, meFirst) then
        return nil
    end

    local function consider(unit)
        if UnitIsUnit and UnitIsUnit(unit, "player") then return nil end
        local full, first = UnitFullName(unit)
        if not full then return nil end
        if NamesMatch(want, full) or NamesMatch(want, first) then
            return full
        end
        return nil
    end

    local inRaid = (IsInRaid and IsInRaid()) or (GetNumRaidMembers and (GetNumRaidMembers() or 0) > 0)
    if inRaid then
        local n = (GetNumGroupMembers and GetNumGroupMembers()) or (GetNumRaidMembers and GetNumRaidMembers()) or 40
        for i = 1, n do
            local hit = consider("raid" .. i)
            if hit then return hit end
        end
        return nil
    end

    local inGroup = (IsInGroup and IsInGroup()) or (GetNumPartyMembers and (GetNumPartyMembers() or 0) > 0)
    if not inGroup then return nil end
    for i = 1, 4 do
        local hit = consider("party" .. i)
        if hit then return hit end
    end
    return nil
end

local function QueueHas(key)
    for _, e in ipairs(summonQueue) do
        if e.key == key then return true end
    end
    return false
end

local function AddToSummonQueue(displayName)
    if not displayName then return end
    local key = displayName:lower()
    if QueueHas(key) then return end
    if #summonQueue >= MAX_SUMMON_QUEUE then
        print("|cffff4040ShardOrb: summon queue is full.|r")
        return
    end
    summonQueue[#summonQueue + 1] = { key = key, display = displayName, targetName = displayName }
    print("ShardOrb: queued " .. displayName)
    EnsureSummonQueueWindow()
    if queueFrame then queueFrame:Show() end
    UpdateSummonQueueDisplay()
end

local function RemoveFromSummonQueue(key)
    for i, e in ipairs(summonQueue) do
        if e.key == key then
            table.remove(summonQueue, i)
            UpdateSummonQueueDisplay()
            return
        end
    end
end

local function CurrentZoneName()
    local zone = (GetZoneText and GetZoneText()) or ""
    if IsSecret(zone) then zone = "" end
    local sub = (GetSubZoneText and GetSubZoneText()) or ""
    if IsSecret(sub) then sub = "" end
    if sub ~= "" and sub ~= zone then
        if zone ~= "" then return zone .. " - " .. sub end
        return sub
    end
    if zone ~= "" then return zone end
    local mini = (GetMinimapZoneText and GetMinimapZoneText()) or "here"
    if IsSecret(mini) then return "here" end
    return mini ~= "" and mini or "here"
end

local lastAnnounceName, lastAnnounceAt

local function AnnounceSummon(name)
    if not name or name == "" or IsSecret(name) then return end
    local now = (GetTime and GetTime()) or 0
    if lastAnnounceName == name and lastAnnounceAt and (now - lastAnnounceAt) < 5 then
        return
    end
    lastAnnounceName, lastAnnounceAt = name, now
    local msg = "Summoning " .. name .. " to " .. CurrentZoneName()
    local channel
    -- Same channel order Necrosis uses. IsInGroup() is a liar on this client.
    if UnitInRaid and UnitInRaid("player") then
        channel = "RAID"
    elseif IsInGroup and LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        channel = "INSTANCE_CHAT"
    elseif UnitInParty and UnitInParty("player") then
        channel = "PARTY"
    elseif IsInRaid and IsInRaid() then
        channel = "RAID"
    elseif IsInGroup and IsInGroup() then
        channel = "PARTY"
    end
    if not channel then return end
    local sent = false
    if C_ChatInfo and C_ChatInfo.SendChatMessage then
        sent = pcall(C_ChatInfo.SendChatMessage, msg, channel)
    end
    if not sent and SendChatMessage then
        pcall(SendChatMessage, msg, channel)
    end
end

local function IsRitualOfSummoning(spellID, spellName)
    local id = ReadableNumber(spellID)
    if id == 698 then return true end
    if type(spellName) == "string" and not IsSecret(spellName) then
        if spellName:lower() == "ritual of summoning" then return true end
    end
    return false
end

-- Forever/retail: unit, castGUID, spellID. Classic: unit, spellName, rank, lineID, spellID.
local function EventIsPlayerRitual(unit, a2, a3, a4, a5)
    if unit ~= "player" then return false end
    local spellID, spellName
    if type(a3) == "number" then
        spellID = a3
        if C_Spell and C_Spell.GetSpellName then
            spellName = C_Spell.GetSpellName(spellID)
        elseif GetSpellInfo then
            spellName = GetSpellInfo(spellID)
        end
    else
        spellName = a2
        spellID = a5 or a4
    end
    if IsSecret(spellName) then spellName = nil end
    return IsRitualOfSummoning(spellID, spellName)
end

ClearSummonQueue = function()
    for i = #summonQueue, 1, -1 do
        summonQueue[i] = nil
    end
    UpdateSummonQueueDisplay()
end

local function PruneSummonQueueLeftGroup()
    local i = 1
    while i <= #summonQueue do
        local e = summonQueue[i]
        if not ResolveGroupMember(e.display) then
            table.remove(summonQueue, i)
        else
            i = i + 1
        end
    end
    UpdateSummonQueueDisplay()
end

local function PaintPanel(frame)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(frame)
    bg:SetColorTexture(0.04, 0.03, 0.06, 0.94)
    local function edge(pointA, pointB, w, h)
        local t = frame:CreateTexture(nil, "BORDER")
        t:SetColorTexture(unpack(SHARD_COLOR))
        t:SetPoint(pointA)
        t:SetPoint(pointB)
        if w then t:SetWidth(w) end
        if h then t:SetHeight(h) end
        return t
    end
    edge("TOPLEFT", "TOPRIGHT", nil, 2)
    edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 2)
    edge("TOPLEFT", "BOTTOMLEFT", 2, nil)
    edge("TOPRIGHT", "BOTTOMRIGHT", 2, nil)
end

EnsureSummonQueueWindow = function()
    if queueFrame then return queueFrame end

    local f = CreateFrame("Frame", "ShardOrbSummonQueue", UIParent)
    f:SetSize(QUEUE_WIDTH, 80)
    f:SetFrameStrata("MEDIUM")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local db = EnsureDB()
        local x, y = self:GetCenter()
        local ux, uy = UIParent:GetCenter()
        db.queueX, db.queueY = x - ux, y - uy
    end)
    PaintPanel(f)

    local db = EnsureDB()
    f:ClearAllPoints()
    if db.queueX and db.queueY then
        f:SetPoint("CENTER", UIParent, "CENTER", db.queueX, db.queueY)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 220, 80)
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetTextColor(unpack(SHARD_COLOR))
    title:SetText("Summon Queue")
    f.title = title

    local close = CreateFrame("Button", nil, f)
    close:SetSize(16, 16)
    close:SetPoint("TOPRIGHT", -6, -6)
    close:SetScript("OnClick", function() f:Hide() end)
    local closeTxt = close:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    closeTxt:SetAllPoints()
    closeTxt:SetText("x")
    closeTxt:SetTextColor(1, 1, 1, 0.85)

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 10, -26)
    hint:SetPoint("TOPRIGHT", -10, -26)
    hint:SetJustifyH("LEFT")
    hint:SetTextColor(0.7, 0.7, 0.75, 1)
    hint:SetText("Party/raid: 123  summon  inv  +1")
    f.hint = hint

    local clearBtn = CreateFrame("Button", nil, f)
    clearBtn:SetSize(60, 18)
    clearBtn:SetPoint("BOTTOMLEFT", 8, 8)
    local clearBg = clearBtn:CreateTexture(nil, "BACKGROUND")
    clearBg:SetAllPoints()
    clearBg:SetColorTexture(0.15, 0.08, 0.2, 1)
    local clearTxt = clearBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    clearTxt:SetPoint("CENTER")
    clearTxt:SetText("Clear")
    clearBtn:SetScript("OnClick", function()
        ClearSummonQueue()
    end)

    queueRows = {}
    f.rowHost = f
    queueFrame = f
    f:Hide()
    return f
end

-- Forever often refuses SetAttribute on an already-used secure button, so each
-- assignment creates a fresh button with the macro set once at creation.
RebuildSummonQueueSecureRows = function()
    if not queueFrame then return end
    if CombatLocked() then
        queueDirty = true
        return
    end
    queueDirty = false

    if queueRows then
        for _, row in ipairs(queueRows) do
            if row.btn then row.btn:Hide() row.btn:SetParent(nil) end
            if row.x then row.x:Hide() row.x:SetParent(nil) end
        end
    end
    queueRows = {}

    local top = -44
    for i, e in ipairs(summonQueue) do
        queueRowSerial = queueRowSerial + 1
        local btn = CreateFrame("Button", "ShardOrbSummonRow" .. queueRowSerial, queueFrame, "SecureActionButtonTemplate")
        btn:SetSize(QUEUE_WIDTH - 36, QUEUE_ROW_HEIGHT)
        btn:SetPoint("TOPLEFT", queueFrame, "TOPLEFT", 8, top)
        btn:RegisterForClicks("AnyUp", "AnyDown")
        btn:SetAttribute("type", "macro")
        btn:SetAttribute("macrotext", "/targetexact " .. e.targetName .. "\n/cast Ritual of Summoning")

        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.12, 0.06, 0.16, 0.9)

        local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("LEFT", 6, 0)
        label:SetPoint("RIGHT", -4, 0)
        label:SetJustifyH("LEFT")
        label:SetText(i .. ". " .. e.display)

        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(e.display)
            GameTooltip:AddLine("Click: target and Ritual of Summoning", 1, 1, 1)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", GameTooltip_Hide)
        local queuedName = e.targetName
        btn:SetScript("PostClick", function()
            pendingSummonName = queuedName
            -- Party/raid chat is hardware-gated on this client: the click is the
            -- event that is allowed to SendChatMessage. Spellcast events are backup.
            pcall(AnnounceSummon, queuedName)
        end)

        local x = CreateFrame("Button", nil, queueFrame)
        x:SetSize(18, QUEUE_ROW_HEIGHT)
        x:SetPoint("LEFT", btn, "RIGHT", 2, 0)
        local xt = x:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        xt:SetAllPoints()
        xt:SetText("x")
        xt:SetTextColor(0.85, 0.4, 0.4, 1)
        local key = e.key
        x:SetScript("OnClick", function()
            RemoveFromSummonQueue(key)
        end)

        queueRows[i] = { btn = btn, x = x }
        top = top - QUEUE_ROW_HEIGHT - 2
    end

    local height = 44 + 28
    if #summonQueue == 0 then
        queueFrame.hint:Show()
        height = 80
    else
        queueFrame.hint:Hide()
        height = 44 + (#summonQueue * (QUEUE_ROW_HEIGHT + 2)) + 28
    end
    queueFrame:SetHeight(height)
    queueFrame.title:SetText("Summon Queue (" .. tostring(#summonQueue) .. ")")
end

UpdateSummonQueueDisplay = function()
    if not queueFrame then return end
    RebuildSummonQueueSecureRows()
end

ToggleSummonQueue = function()
    EnsureSummonQueueWindow()
    if queueFrame:IsShown() then
        queueFrame:Hide()
    else
        queueFrame:Show()
        UpdateSummonQueueDisplay()
    end
end

local function OnSummonChat(message, sender)
    if not MessageIsQueueTrigger(message) then return end
    local name = ResolveGroupMember(sender)
    if not name then return end
    AddToSummonQueue(name)
end

local chatDriver = CreateFrame("Frame")
local CHAT_EVENTS = {
    "CHAT_MSG_PARTY",
    "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID",
    "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_RAID_WARNING",
    "CHAT_MSG_INSTANCE_CHAT",
    "CHAT_MSG_INSTANCE_CHAT_LEADER",
    "GROUP_ROSTER_UPDATE",
}
for _, ev in ipairs(CHAT_EVENTS) do
    pcall(chatDriver.RegisterEvent, chatDriver, ev)
end
chatDriver:SetScript("OnEvent", function(self, event, ...)
    if event == "GROUP_ROSTER_UPDATE" then
        pcall(PruneSummonQueueLeftGroup)
        return
    end
    local message, sender = ...
    pcall(OnSummonChat, message, sender)
end)

local SPELLCAST_EVENTS = {
    "UNIT_SPELLCAST_SENT",
    "UNIT_SPELLCAST_SUCCEEDED",
    "UNIT_SPELLCAST_INTERRUPTED",
    "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_FAILED_QUIET",
}

local spellDriver = CreateFrame("Frame")
for _, ev in ipairs(SPELLCAST_EVENTS) do
    -- PeekDrop: RegisterEvent, not RegisterUnitEvent. Forever's unit-event
    -- variant exists but does not deliver these casts.
    pcall(spellDriver.RegisterEvent, spellDriver, ev)
end
spellDriver:SetScript("OnEvent", function(self, event, unit, a2, a3, a4, a5)
    if unit ~= "player" then return end
    local spellID, dest
    if event == "UNIT_SPELLCAST_SENT" then
        -- PeekDrop on Forever: unit, dest, _, spellID
        dest = a2
        spellID = a4 or a3
        if IsSecret(dest) then dest = nil end
    else
        -- PeekDrop SUCCEEDED: unit, _, spellID
        spellID = a3 or a4 or a5
    end
    if not IsRitualOfSummoning(spellID, type(a2) == "string" and a2 or nil) then
        return
    end
    if event == "UNIT_SPELLCAST_SENT" then
        if dest and dest ~= "" then
            pendingSummonName = dest
        elseif not pendingSummonName then
            pendingSummonName = UnitFullName("target")
        end
        -- Backup if the click PostClick couldn't talk (action-bar cast).
        if pendingSummonName then
            pcall(AnnounceSummon, pendingSummonName)
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local name = pendingSummonName or UnitFullName("target")
        pendingSummonName = nil
        if name then
            pcall(RemoveFromSummonQueue, name:lower())
        end
    else
        pendingSummonName = nil
    end
end)




local ok, err = pcall(BuildFrames)
if not ok then
    BuildError = err
    print("|cffff4040ShardOrb failed to build its window:|r " .. tostring(err))
    print("Run /shardorb status for details.")
end

----------------------------------------------------------------------
-- Target alerts (Necrosis AntiFear + golem/drain)
-- Forever: UnitCreatureType + PLAYER_TARGET_CHANGED. No combat log.
-- Skip issecretvalue types (comparing them is ADDON_ACTION_BLOCKED).
----------------------------------------------------------------------

local ALERT_SIZE = 40
local FEAR_WARD_NAMES = {
    ["fear ward"] = true,
    ["will of the forsaken"] = true,
    ["berserker rage"] = true,
    ["recklessness"] = true,
    ["death wish"] = true,
    ["bestial wrath"] = true,
    ["ice block"] = true,
    ["divine protection"] = true,
    ["divine shield"] = true,
    ["tremor totem"] = true,
    ["fearless"] = true,
    ["curse of recklessness"] = true,
}

local fearAlert, drainAlert
local fearWasOn, drainWasOn

local function ClassifyCreatureType(ct)
    if not ct or IsSecret(ct) then return nil end
    local l = tostring(ct):lower()
    if l == "mechanical" or l:find("meca", 1, true) then return "mechanical" end
    if l == "undead" or l == "untoter" or l:find("undead", 1, true)
        or l:find("mort-vivant", 1, true) or l:find("no-muerto", 1, true) then
        return "undead"
    end
    return l
end

local function TargetHasFearWard()
    local function scan(filter)
        for i = 1, 40 do
            local name
            if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
                local data = C_UnitAuras.GetAuraDataByIndex("target", i, filter)
                if not data then break end
                name = data.name
            elseif UnitAura then
                name = UnitAura("target", i, filter)
            elseif filter == "HELPFUL" and UnitBuff then
                name = UnitBuff("target", i)
            elseif filter == "HARMFUL" and UnitDebuff then
                name = UnitDebuff("target", i)
            else
                break
            end
            if not name then break end
            if not IsSecret(name) and FEAR_WARD_NAMES[tostring(name):lower()] then
                return true
            end
        end
        return false
    end
    local ok, hit = pcall(scan, "HELPFUL")
    if ok and hit then return true end
    ok, hit = pcall(scan, "HARMFUL")
    return ok and hit
end

local function PlayAlertSound()
    if PlaySoundFile then
        pcall(PlaySoundFile, "Sound\\Interface\\RaidWarning.ogg")
    elseif PlaySound then
        pcall(PlaySound, 8959)
    end
end

local function MakeAlertIcon(name, icon, r, g, b, tooltipTitle, tooltipBody)
    local f = CreateFrame("Button", name, UIParent)
    f:SetSize(ALERT_SIZE, ALERT_SIZE)
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        if EnsureDB().locked then return end
        self:StartMoving()
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local db = EnsureDB()
        local x, y = self:GetCenter()
        local ux, uy = UIParent:GetCenter()
        db[name .. "X"], db[name .. "Y"] = x - ux, y - uy
    end)
    local fill = MakeBorderedCircle(f, { fill = { 0, 0, 0, 1 }, border = { r, g, b, 1 }, thickness = 3 })
    fill:SetTexture(icon)
    f.icon = fill
    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(tooltipTitle)
        GameTooltip:AddLine(tooltipBody, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", GameTooltip_Hide)
    f:Hide()
    return f
end

local function PlaceAlert(f, key, defaultX, defaultY)
    local db = EnsureDB()
    f:ClearAllPoints()
    if db[key .. "X"] and db[key .. "Y"] then
        f:SetPoint("CENTER", UIParent, "CENTER", db[key .. "X"], db[key .. "Y"])
    elseif sphere then
        f:SetPoint("BOTTOM", sphere, "TOP", defaultX, 10)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", defaultX, 80)
    end
end

local function EnsureAlertFrames()
    if fearAlert then return end
    fearAlert = MakeAlertIcon(
        "ShardOrbFearAlert",
        "Interface\\Icons\\Spell_Shadow_Possession",
        0.85, 0.15, 0.15,
        "Cannot Fear",
        "This target is immune to Fear (Undead, Mechanical, or a fear ward)."
    )
    drainAlert = MakeAlertIcon(
        "ShardOrbDrainAlert",
        "Interface\\Icons\\Spell_Shadow_LifeDrain",
        0.2, 0.75, 0.25,
        "Cannot Drain",
        "Drain Life / Siphon Life will not work (Mechanical / golem)."
    )
    PlaceAlert(fearAlert, "ShardOrbFearAlert", -24, 10)
    PlaceAlert(drainAlert, "ShardOrbDrainAlert", 24, 10)
end

UpdateTargetAlerts = function()
    EnsureAlertFrames()
    local db = EnsureDB()
    local showFear, showDrain = false, false
    if db.alerts ~= false
        and UnitExists and UnitExists("target")
        and UnitCanAttack and UnitCanAttack("player", "target")
        and not (UnitIsDead and UnitIsDead("target")) then
        local kind = ClassifyCreatureType(UnitCreatureType and UnitCreatureType("target"))
        local player = UnitIsPlayer and UnitIsPlayer("target")
        if kind == "mechanical" then
            showFear = true
            showDrain = true
        elseif kind == "undead" and not player then
            showFear = true
        end
        if not showFear and TargetHasFearWard() then
            showFear = true
        end
    end

    if showFear then
        fearAlert:Show()
        if not fearWasOn then PlayAlertSound() end
    else
        fearAlert:Hide()
    end
    if showDrain then
        drainAlert:Show()
        if not drainWasOn and not showFear then PlayAlertSound() end
    else
        drainAlert:Hide()
    end
    fearWasOn, drainWasOn = showFear, showDrain
end

-- Nightfall / Shadow Trance: UNIT_AURA on the player (no combat log). Sound is the
-- wav in the addon folder — same PlaySoundFile path Necrosis used for its mp3.
local TRANCE_SPELL_ID = 17941
local TRANCE_SOUND = "Interface\\AddOns\\ShardOrb\\shadowtrance.ogg"
local tranceAlert, tranceSeen
local tranceTestUntil = 0

local function NameLooksLikeTrance(name)
    if not name or IsSecret(name) then return false end
    local l = tostring(name):lower()
    l = l:gsub("%s+", " ")
    return l:find("shadow trance", 1, true) ~= nil
        or l:find("shadowtrance", 1, true) ~= nil
        or l == "nightfall"
end

local function SlotIsTrance(name, spellId)
    local id = ReadableNumber(spellId)
    if id == TRANCE_SPELL_ID then return true end
    return NameLooksLikeTrance(name)
end

-- Nightfall makes the next Shadow Bolt instant. Cast time is readable in combat
-- when the aura table is not (Forever: "Auras cannot be accessed when secret").
local function ShadowBoltCastTime()
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, "Shadow Bolt")
        if ok and type(info) == "table" then
            return ReadableNumber(info.castTime)
        end
        ok, info = pcall(C_Spell.GetSpellInfo, 686)
        if ok and type(info) == "table" then
            return ReadableNumber(info.castTime)
        end
    end
    if GetSpellInfo then
        local ok, _, _, _, castTime = pcall(GetSpellInfo, "Shadow Bolt")
        if ok then return ReadableNumber(castTime) end
        ok, _, _, _, castTime = pcall(GetSpellInfo, 686)
        if ok then return ReadableNumber(castTime) end
    end
    return nil
end

local function ReadBuffSlot(i)
    if C_UnitAuras then
        if C_UnitAuras.GetAuraDataByIndex then
            local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i)
            if ok then
                if not data then return "END" end
                return "ok", data.name, data.spellId, data.icon
            end
        end
        if C_UnitAuras.GetPlayerAuraBySpellID then
            -- handled in PlayerHasShadowTrance as a fast path, not per-slot
        end
    end
    if UnitBuff then
        local ok, n, a, b, c, d, e, f, g, h, sid = pcall(UnitBuff, "player", i)
        if not ok then return "ERR", n end
        if not n then return "END" end
        -- sid is spellId on WotLK+; on vanilla a is rank.
        local spellId = ReadableNumber(sid) or ReadableNumber(h)
        return "ok", n, spellId, b
    end
    if UnitAura then
        local ok, n = pcall(UnitAura, "player", i)
        if not ok then return "ERR", n end
        if not n then return "END" end
        return "ok", n, nil, nil
    end
    return "END"
end

local function PlayerHasShadowTrance()
    local ct = ShadowBoltCastTime()
    if ct == 0 then return true end

    if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        local ok, data = pcall(C_UnitAuras.GetPlayerAuraBySpellID, TRANCE_SPELL_ID)
        if ok and data then return true end
    end
    if AuraUtil and AuraUtil.FindAuraByName then
        for _, nm in ipairs({ "Shadow Trance", "Nightfall", "Shadowtrance" }) do
            local ok, found = pcall(AuraUtil.FindAuraByName, nm, "player")
            if ok and found then return true end
        end
    end
    local anyErr = false
    local anyOk = false
    for i = 1, 40 do
        local status, name, spellId = ReadBuffSlot(i)
        if status == "END" then break end
        if status == "ERR" then
            anyErr = true
            break
        end
        anyOk = true
        if SlotIsTrance(name, spellId) then return true end
    end
    if anyErr and not anyOk then
        if ct and ct > 0 then return false end
        return nil
    end
    return false
end

DumpPlayerAuras = function()
    print("ShardOrb: player auras (run this WHILE Shadow Trance is on you):")
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, "player", 1)
        print("  GetAuraDataByIndex(player,1) ok=" .. tostring(ok) .. " type=" .. type(data))
        if not ok then print("  err=" .. tostring(data)) end
        if ok and type(data) == "table" then
            print("  name=" .. tostring(data.name) .. " id=" .. tostring(data.spellId))
        end
    else
        print("  C_UnitAuras.GetAuraDataByIndex missing")
    end
    if UnitBuff then
        local ok, n = pcall(UnitBuff, "player", 1)
        print("  UnitBuff(player,1) ok=" .. tostring(ok) .. " n=" .. tostring(n))
        if not ok then print("  err=" .. tostring(n)) end
    else
        print("  UnitBuff missing")
    end
    local listed = 0
    for i = 1, 40 do
        local status, name, spellId = ReadBuffSlot(i)
        if status == "END" then break end
        if status == "ERR" then
            print("  slot " .. i .. " ERR " .. tostring(name))
            break
        end
        listed = listed + 1
        local mark = SlotIsTrance(name, spellId) and "  <<TRANCE" or ""
        print("  " .. i .. ": id=" .. tostring(spellId) .. " name=" .. tostring(name) .. mark)
    end
    print("  listed=" .. listed .. " hasTrance=" .. tostring(PlayerHasShadowTrance()) .. " SB_castTime=" .. tostring(ShadowBoltCastTime()))
end

local function EnsureTranceFrame()
    if tranceAlert then return end
    tranceAlert = MakeAlertIcon(
        "ShardOrbTranceAlert",
        "Interface\\Icons\\Spell_Shadow_Twilight",
        0.62, 0.08, 0.82,
        "Shadow Trance",
        "Nightfall proc — your next Shadow Bolt is instant."
    )
    PlaceAlert(tranceAlert, "ShardOrbTranceAlert", 0, 56)
end

UpdateShadowTrance = function()
    EnsureTranceFrame()
    local db = EnsureDB()
    if db.trance == false then
        tranceAlert:Hide()
        return
    end
    local now = (GetTime and GetTime()) or 0
    if tranceTestUntil > now then
        tranceAlert:Show()
        return
    end
    local ok, has = pcall(PlayerHasShadowTrance)
    if not ok then has = nil end
    -- nil = auras unreadable (combat secret). Keep whatever is on screen.
    if has == nil then return end
    if tranceSeen == nil then
        tranceSeen = has
        if has then tranceAlert:Show() else tranceAlert:Hide() end
        return
    end
    if has and not tranceSeen then
        tranceAlert:Show()
        if not pcall(PlaySoundFile, TRANCE_SOUND, "Master") then
            pcall(PlaySoundFile, TRANCE_SOUND)
        end
    elseif not has then
        tranceAlert:Hide()
    end
    tranceSeen = has
end

TestShadowTrance = function()
    EnsureTranceFrame()
    tranceTestUntil = ((GetTime and GetTime()) or 0) + 4
    tranceAlert:Show()
    local ok = pcall(PlaySoundFile, TRANCE_SOUND, "Master")
    if not ok then ok = pcall(PlaySoundFile, TRANCE_SOUND) end
    print("ShardOrb: trance test. sound call " .. (ok and "ok" or "failed") .. "  file=" .. TRANCE_SOUND)
end

local alertDriver = CreateFrame("Frame")
pcall(alertDriver.RegisterEvent, alertDriver, "PLAYER_TARGET_CHANGED")
pcall(alertDriver.RegisterEvent, alertDriver, "UNIT_AURA")
pcall(alertDriver.RegisterEvent, alertDriver, "PLAYER_LOGIN")
if alertDriver.RegisterUnitEvent then
    pcall(alertDriver.RegisterUnitEvent, alertDriver, "UNIT_AURA", "player")
end
alertDriver:SetScript("OnEvent", function(self, event, unit)
    if event == "PLAYER_TARGET_CHANGED" then
        pcall(UpdateTargetAlerts)
        return
    end
    -- Forever often omits the unit token on UNIT_AURA. Always re-check player
    -- buffs; target alerts only when it is actually the target (or blank).
    if event == "UNIT_AURA" then
        pcall(UpdateShadowTrance)
        pcall(UpdateTargetAlerts)
        return
    end
    pcall(UpdateTargetAlerts)
    pcall(UpdateShadowTrance)
end)
-- Buff fade sometimes never fires an aura event. While the icon is up, re-read
-- player buffs a few times a second so it actually goes away.
alertDriver:SetScript("OnUpdate", function(self, elapsed)
    local tranceUp = tranceAlert and tranceAlert:IsShown()
    local targetUp = (fearAlert and fearAlert:IsShown()) or (drainAlert and drainAlert:IsShown())
    self.alertAccum = (self.alertAccum or 0) + elapsed
    if self.alertAccum < 0.25 then return end
    self.alertAccum = 0
    -- Always scan player buffs, even when the icon is hidden — UNIT_AURA on
    -- player often never arrives, so a Nightfall would otherwise be missed.
    pcall(UpdateShadowTrance)
    if targetUp then pcall(UpdateTargetAlerts) end
end)

----------------------------------------------------------------------
-- Events
----------------------------------------------------------------------

local function PlayerClass()
    if UnitClassBase then
        return UnitClassBase("player")
    end
    local _, class = UnitClass("player")
    return class
end

local function Init()
    if sphere == nil then return end
    if PlayerClass() ~= "WARLOCK" then
        sphere:Hide()
        return
    end
    RestorePosition()
    sphere:Show()
    pcall(RefreshShardCount)
    pcall(RefreshSpells)
    pcall(RefreshSoulstoneButton)
    pcall(UpdateTargetAlerts)
    pcall(UpdateShadowTrance)
    loginElapsed = 0
    pollActive = true
end

local BAG_EVENTS = {
    "PLAYER_LOGIN",
    "PLAYER_ENTERING_WORLD",
    "BAG_UPDATE",
    "BAG_UPDATE_DELAYED",
    "SPELLS_CHANGED",
    "LEARNED_SPELL_IN_TAB",
    "SPELL_TEXT_UPDATE",
    "PLAYER_REGEN_ENABLED",
}

local driver = CreateFrame("Frame")
for _, ev in ipairs(BAG_EVENTS) do
    pcall(driver.RegisterEvent, driver, ev)
end

didInit = false
local eventErrorPrinted = false
driver:SetScript("OnEvent", function(self, event)
    -- Re-register at PLAYER_LOGIN: Forever has dropped events that were only
    -- registered at file load (same trick Necrosis uses for BAG_UPDATE).
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        for _, ev in ipairs(BAG_EVENTS) do
            pcall(self.RegisterEvent, self, ev)
        end
        for _, ev in ipairs(CHAT_EVENTS) do
            pcall(chatDriver.RegisterEvent, chatDriver, ev)
        end
        pcall(alertDriver.RegisterEvent, alertDriver, "PLAYER_TARGET_CHANGED")
        pcall(alertDriver.RegisterEvent, alertDriver, "UNIT_AURA")
        for _, ev in ipairs(SPELLCAST_EVENTS) do
            pcall(spellDriver.RegisterEvent, spellDriver, ev)
        end
    end
    local ok1, err1 = pcall(function()
        if (event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD") and not didInit then
            didInit = true
            Init()
        else
            pcall(RefreshShardCount)
            if event == "BAG_UPDATE" or event == "BAG_UPDATE_DELAYED" or event == "PLAYER_REGEN_ENABLED" or soulstoneDirty then
                pcall(RefreshSoulstoneButton)
            end
            if event == "PLAYER_REGEN_ENABLED" and queueDirty then
                pcall(RebuildSummonQueueSecureRows)
            end
            if event == "SPELLS_CHANGED" or event == "LEARNED_SPELL_IN_TAB" or event == "SPELL_TEXT_UPDATE" or event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
                pcall(RefreshSpells)
            end
        end
    end)
    if not ok1 and not eventErrorPrinted then
        eventErrorPrinted = true
        print("|cffff4040ShardOrb: event handler (" .. tostring(event) .. ") is erroring:|r " .. tostring(err1))
    end
end)

-- Frame OnUpdate is the login safety net. C_Timer.After has been a no-op on this
-- client in the past; bags also often still report 0 slots at PLAYER_LOGIN, and
-- Forever does not always deliver PLAYER_ENTERING_WORLD. Poll for a short window
-- after login so the number catches up without a /reload.
driver:SetScript("OnUpdate", function(self, elapsed)
    if not pollActive then return end
    self.accum = (self.accum or 0) + elapsed
    if self.accum < LOGIN_POLL_INTERVAL then return end
    self.accum = 0
    loginElapsed = (loginElapsed or 0) + LOGIN_POLL_INTERVAL
    pcall(RefreshShardCount)
    pcall(RefreshSoulstoneButton)
    local _, ready = CountShardsInBags()
    if ready or loginElapsed >= LOGIN_POLL_SECONDS then
        pollActive = false
    end
end)
