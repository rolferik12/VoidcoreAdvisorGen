-- VoidcoreAdvisorGen: Generator
-- Developer tool that walks the Encounter Journal and writes a complete
-- Core/SeasonData.lua for VoidcoreAdvisor.
--
-- Usage:
--   1.  Enable this addon alongside VoidcoreAdvisor.
--   2.  Log in at the character select, then enter the world.
--   3.  Open the Encounter Journal (/ej) and wait for it to load fully.
--   4.  Type: /vcagen run
--   5.  Wait for the "Generation complete!" message (a few seconds).
--   6.  Type: /reload
--   7.  Open:  WTF\Account\<name>\SavedVariables\VoidcoreAdvisorGen.lua
--   8.  Copy the value of VoidcoreAdvisorGenDB["seasonData"] into
--       Core/SeasonData.lua, wrapping it as shown in the template.
--
-- The generator collects ALL lootable items by walking every EJ loot
-- filter (all classes and all specs), then unions itemIDs per source.
-- Any item the EJ shows with displayAsPerPlayerLoot=false is included —
-- this covers gear, weapons, tier tokens, synthesis items, and trinkets.
-- Bonus/extra-drop items (crafting plans, cosmetics) are excluded via the
-- displayAsPerPlayerLoot=true flag that Blizzard sets on them in the EJ.
-- Results are stored in pre-grouped byClass / bySpec tables
-- so VoidcoreAdvisor can do direct lookups at runtime — no C_Item.GetItemSpecInfo
-- calls needed.
local _, VCA = ... -- access VoidcoreAdvisor's namespace

-- ── Constants (mirrors VoidcoreAdvisor/Core/Constants.lua) ──────────────────

local RAID_NORMAL = 14
local RAID_HEROIC = 15
local RAID_MYTHIC = 16
local DUNGEON_MYTHIC = 23

local ELIGIBLE_RAID_DIFFS = {RAID_NORMAL, RAID_HEROIC, RAID_MYTHIC}

-- Item class/subclass IDs used to exclude non-Voidcore-eligible items.
local ITEM_CLASS_MISCELLANEOUS = 15 -- LE_ITEM_CLASS_MISCELLANEOUS
local ITEM_SUBCLASS_MOUNT = 5 -- LE_ITEM_MISCELLANEOUS_MOUNT
local ITEM_CLASS_HOUSING = 20 -- Housing Decor items

-- Slot tokens that the drawer cares about.  Maps INVTYPE_* → canonical slot key.
-- Tokens not listed here are ignored (consumables, reagents, etc.).
local SLOT_TOKEN_MAP = {
    INVTYPE_HEAD = "head",
    INVTYPE_NECK = "neck",
    INVTYPE_SHOULDER = "shoulder",
    INVTYPE_CLOAK = "back",
    INVTYPE_CHEST = "chest",
    INVTYPE_ROBE = "chest", -- robe uses the chest slot
    INVTYPE_WRIST = "wrist",
    INVTYPE_HAND = "hands",
    INVTYPE_WAIST = "waist",
    INVTYPE_LEGS = "legs",
    INVTYPE_FEET = "feet",
    INVTYPE_FINGER = "finger",
    INVTYPE_TRINKET = "trinket",
    INVTYPE_WEAPON = "1h", -- one-hand
    INVTYPE_SHIELD = "offhand",
    INVTYPE_WEAPONMAINHAND = "1h",
    INVTYPE_WEAPONOFFHAND = "1h", -- off-hand weapon (treated as 1h for slot grouping)
    INVTYPE_HOLDABLE = "offhand", -- held in off-hand (tomes etc.)
    INVTYPE_2HWEAPON = "2h",
    INVTYPE_RANGED = "ranged",
    INVTYPE_RANGEDRIGHT = "ranged",
    INVTYPE_THROWN = "ranged",
    INVTYPE_RELIC = "ranged"
}

-- ── Helpers ──────────────────────────────────────────────────────────────────

-- Collects all lootable itemIDs visible under the CURRENT EJ selection
-- and CURRENT loot filter.  displayAsPerPlayerLoot=true marks bonus/extra-drop
-- items (crafting plans, cosmetics) that are not part of the standard loot
-- table — exclude those and trust the EJ for everything else.
local function IsExcludedItem(itemID)
    local _, _, _, _, _, classID, subClassID = GetItemInfoInstant(itemID)
    -- Fall back to GetItemInfo if GetItemInfoInstant has no cached data yet.
    if not classID then
        local _, _, _, _, _, c2, s2 = GetItemInfo(itemID)
        classID = c2
        subClassID = s2
    end
    -- If classID is still unknown, exclude to be safe.
    if not classID then
        return true
    end
    if classID == ITEM_CLASS_MISCELLANEOUS and subClassID == ITEM_SUBCLASS_MOUNT then
        return true
    end
    if classID == ITEM_CLASS_HOUSING then
        return true
    end
    return false
end

-- Returns the canonical slot key for an itemID, or nil if not a gear slot.
local function GetSlotKey(itemID)
    local _, _, _, _, _, _, _, _, equipLoc = GetItemInfoInstant(itemID)
    if not equipLoc or equipLoc == "" then
        local _, _, _, _, _, _, _, _, equipLoc2 = GetItemInfo(itemID)
        equipLoc = equipLoc2
    end
    if not equipLoc or equipLoc == "" then
        return nil
    end
    return SLOT_TOKEN_MAP[equipLoc]
end

local function CollectItemsForCurrentFilter()
    local items = {}
    local seen = {}
    local n = EJ_GetNumLoot and EJ_GetNumLoot() or 0
    for i = 1, n do
        local info = C_EncounterJournal and C_EncounterJournal.GetLootInfoByIndex(i)
        if info and info.itemID and info.itemID > 0 and not seen[info.itemID] and not info.displayAsPerPlayerLoot then
            if not IsExcludedItem(info.itemID) then
                seen[info.itemID] = true
                items[#items + 1] = info.itemID
            end
        end
    end
    return items
end

local function BuildLootFilters()
    local filters = {}
    local seen = {}

    local function Add(classID, specID)
        classID = tonumber(classID) or 0
        specID = tonumber(specID) or 0
        local key = tostring(classID) .. ":" .. tostring(specID)
        if seen[key] then
            return
        end
        seen[key] = true
        filters[#filters + 1] = {
            classID = classID,
            specID = specID
        }
    end

    -- Always include unfiltered as a baseline.
    Add(0, 0)

    if GetNumClasses and GetClassInfo then
        local numClasses = GetNumClasses() or 0
        for classIndex = 1, numClasses do
            local _, _, classID = GetClassInfo(classIndex)
            if classID then
                -- Class-wide (all specs of that class)
                Add(classID, 0)

                -- Spec-specific filters
                if GetNumSpecializationsForClassID and GetSpecializationInfoForClassID then
                    local numSpecs = GetNumSpecializationsForClassID(classID) or 0
                    for specIndex = 1, numSpecs do
                        local specID = GetSpecializationInfoForClassID(classID, specIndex)
                        if specID then
                            Add(classID, specID)
                        end
                    end
                end
            end
        end
    end

    return filters
end

-- Applies each filter in turn and returns grouped results:
--   { all={sorted itemIDs}, byClass={[classID]={sorted}}, bySpec={[specID]={sorted}} }
-- byClass is populated from class-wide filters (specID==0).
-- bySpec  is populated from spec-specific filters (specID~=0).
local function CollectItemsGroupedByFilter(filters)
    local allSeen = {}
    local all = {}
    local classBuckets = {} -- [classID] = { seen={}, items={} }
    local specBuckets = {} -- [specID]  = { seen={}, items={} }

    local function Merge(bucket, itemID)
        if not bucket.seen[itemID] then
            bucket.seen[itemID] = true
            bucket.items[#bucket.items + 1] = itemID
        end
    end

    for _, filter in ipairs(filters) do
        EJ_SetLootFilter(filter.classID, filter.specID)
        local items = CollectItemsForCurrentFilter()
        for _, itemID in ipairs(items) do
            if not allSeen[itemID] then
                allSeen[itemID] = true;
                all[#all + 1] = itemID
            end
            if filter.specID ~= 0 then
                if not specBuckets[filter.specID] then
                    specBuckets[filter.specID] = {
                        seen = {},
                        items = {}
                    }
                end
                Merge(specBuckets[filter.specID], itemID)
            elseif filter.classID ~= 0 then
                if not classBuckets[filter.classID] then
                    classBuckets[filter.classID] = {
                        seen = {},
                        items = {}
                    }
                end
                Merge(classBuckets[filter.classID], itemID)
            end
        end
    end

    local byClass = {}
    for classID, b in pairs(classBuckets) do
        table.sort(b.items);
        byClass[classID] = b.items
    end
    local bySpec = {}
    for specID, b in pairs(specBuckets) do
        table.sort(b.items);
        bySpec[specID] = b.items
    end
    table.sort(all)
    return {
        all = all,
        byClass = byClass,
        bySpec = bySpec
    }
end

-- ── Season discovery (same logic as LootPool.BuildSeasonFilter) ───────────────

local function DiscoverSeason()
    -- M+ dungeons: match challenge-mode map names to EJ instanceIDs.
    local dungeonNameSet = {}
    if C_ChallengeMode and C_ChallengeMode.GetMapTable then
        local mapIDs = C_ChallengeMode.GetMapTable()
        if mapIDs then
            for _, mapID in ipairs(mapIDs) do
                local name = C_ChallengeMode.GetMapUIInfo(mapID)
                if name then
                    dungeonNameSet[name] = true
                end
            end
        end
    end

    local dungeonInstanceIDs = {} -- ordered array
    local dungeonIDSet = {} -- set for quick lookup
    local raidInstanceIDs = {} -- set  { [instanceID] = true }

    local numTiers = EJ_GetNumTiers and EJ_GetNumTiers() or 0
    if numTiers == 0 then
        return nil, "EJ_GetNumTiers() returned 0 — EJ not fully loaded.  Open the Encounter Journal first."
    end

    local savedTier = EJ_GetCurrentTier()
    EJ_SelectTier(numTiers)

    -- Dungeons (isRaid = false)
    local idx = 1
    while true do
        local instanceID, name = EJ_GetInstanceByIndex(idx, false)
        if not instanceID then
            break
        end
        if name and dungeonNameSet[name] then
            dungeonIDSet[instanceID] = true
            dungeonInstanceIDs[#dungeonInstanceIDs + 1] = instanceID
        end
        idx = idx + 1
    end

    -- EJ instance IDs that appear in the raid list but are world boss collections
    -- and therefore not eligible for Nebulous Voidcores.
    local EXCLUDED_RAID_INSTANCE_IDS = {
        [1312] = true -- Midnight (world bosses: Lu'ashal, Thorm'belan, Predaxas, Cragpine)
    }

    -- Raids (isRaid = true)
    idx = 1
    while true do
        local instanceID = EJ_GetInstanceByIndex(idx, true)
        if not instanceID then
            break
        end
        if not EXCLUDED_RAID_INSTANCE_IDS[instanceID] then
            -- Value starts as true; raid-discover will upgrade it to { mapID=N }.
            raidInstanceIDs[instanceID] = true
        end
        idx = idx + 1
    end

    if savedTier and savedTier > 0 then
        EJ_SelectTier(savedTier)
    end

    if #dungeonInstanceIDs == 0 and not next(raidInstanceIDs) then
        return nil,
            "No season dungeons or raids found.  Make sure C_ChallengeMode data is loaded (try again after entering the world)."
    end

    return {
        dungeonInstanceIDs = dungeonInstanceIDs,
        raidInstanceIDs = raidInstanceIDs
    }
end

-- ── EJ state helpers ─────────────────────────────────────────────────────────

local function SetupEJForCollection(difficultyID)
    local numTiers = EJ_GetNumTiers and EJ_GetNumTiers() or 0
    if numTiers > 0 then
        EJ_SelectTier(numTiers)
    end
    EJ_SetDifficulty(difficultyID)
    EJ_SetLootFilter(0, 0)
end

local function RestoreEJState(origTier, origDifficulty, origClass, origSpec)
    if origTier and origTier > 0 then
        EJ_SelectTier(origTier)
    end
    EJ_SetDifficulty(origDifficulty)
    EJ_SetLootFilter(origClass or 0, origSpec or 0)
end

-- ── Async generation ─────────────────────────────────────────────────────────

local _genTicker = nil
local _genRunning = false

local function RunGeneration()
    if _genRunning then
        print("|cff66ccffVoidcoreAdvisorGen:|r Already running.  Please wait.")
        return
    end

    -- Make sure EJ is loaded.
    if not EncounterJournal then
        if EncounterJournal_LoadUI then
            EncounterJournal_LoadUI()
        end
        if not EncounterJournal then
            print("|cff66ccffVoidcoreAdvisorGen:|r Encounter Journal is not loaded.  Open it first (/ej).")
            return
        end
    end

    local season, err = DiscoverSeason()
    if not season then
        print("|cff66ccffVoidcoreAdvisorGen:|r " .. err)
        return
    end

    _genRunning = true
    print(string.format("|cff66ccffVoidcoreAdvisorGen:|r Starting — %d dungeons, %d raid instance(s).",
        #season.dungeonInstanceIDs, (function()
            local n = 0
            for _ in pairs(season.raidInstanceIDs) do
                n = n + 1
            end
            return n
        end)()))

    -- Save EJ state before we touch anything.
    local origTier = EJ_GetCurrentTier()
    local origDifficulty = EJ_GetDifficulty()
    local origClass, origSpec = EJ_GetLootFilter()

    -- ── Build work queue ──────────────────────────────────────────────────────

    local queue = {}

    -- Dungeon entries (one per encounter in each dungeon)
    for _, instanceID in ipairs(season.dungeonInstanceIDs) do
        -- We need a first pass to discover encounter IDs before collecting.
        queue[#queue + 1] = {
            kind = "dungeon-discover",
            instanceID = instanceID,
            done = false
        }
    end

    -- Raid entries will be queued after dungeon-discover completes.

    -- Collected data
    local lootFilters = BuildLootFilters()
    local result = {
        dungeonInstanceIDs = season.dungeonInstanceIDs,
        raidInstanceIDs = season.raidInstanceIDs,
        dungeons = {}, -- [instanceID] = { all={}, byEncounter={} }
        raids = {} -- [encounterID] = { instanceID=N, [14]={}, [15]={}, [16]={} }
    }

    -- ── Ticker ────────────────────────────────────────────────────────────────

    local function Finish(success)
        if _genTicker then
            _genTicker:Cancel();
            _genTicker = nil
        end
        _genRunning = false

        RestoreEJState(origTier, origDifficulty, origClass, origSpec)

        if not success then
            return
        end

        -- Strip raidInstanceIDs table ref (it was only used during queuing)
        -- and save to SavedVariables.
        if not VoidcoreAdvisorGenDB then
            VoidcoreAdvisorGenDB = {}
        end

        VoidcoreAdvisorGenDB.seasonData = result

        local ver = select(4, GetBuildInfo and GetBuildInfo() or "?")
        VoidcoreAdvisorGenDB.generatedBuild = tostring(ver)

        print(string.format("|cff66ccffVoidcoreAdvisorGen:|r |cff00ff00Generation complete!|r  " ..
                                "%d dungeons, %d raid encounters saved.  " .. "Now type |cffffd700/reload|r, then copy " ..
                                "VoidcoreAdvisorGenDB[\"seasonData\"] from your SavedVariables file " ..
                                "into Core/SeasonData.lua.", (function()
            local n = 0
            for _ in pairs(result.dungeons) do
                n = n + 1
            end
            return n
        end)(), (function()
            local n = 0
            for _ in pairs(result.raids) do
                n = n + 1
            end
            return n
        end)()))
    end

    local qIdx = 0

    _genTicker = C_Timer.NewTicker(0.12, function()
        -- Build raid queue entries once all dungeon-discover passes are done
        -- (we need encounter IDs from the dungeon-discover step first, but for
        -- raids we discover encounters inline during the raid-encounters step).

        qIdx = qIdx + 1
        if qIdx > #queue then
            Finish(true)
            return
        end

        local entry = queue[qIdx]

        -- ── dungeon-discover: enumerate encounters for this dungeon ────────
        if entry.kind == "dungeon-discover" then
            local instanceID = entry.instanceID
            SetupEJForCollection(DUNGEON_MYTHIC)
            EJ_SelectInstance(instanceID)

            local encounterIDs = {}
            local encIdx = 1
            while true do
                local name, _, encounterID = EJ_GetEncounterInfoByIndex(encIdx)
                if not name then
                    break
                end
                encounterIDs[#encounterIDs + 1] = encounterID
                encIdx = encIdx + 1
            end

            -- Capture the InstanceID (mapID) so Detection can resolve the EJ
            -- instanceID purely from GetInstanceInfo()'s 8th return at runtime,
            -- without needing a locale-sensitive name lookup.
            local _, _, _, _, _, _, _, _, _, ejMapID = EJ_GetInstanceInfo(instanceID)
            result.dungeons[instanceID] = {
                mapID = (ejMapID and ejMapID ~= 0) and ejMapID or nil,
                all = {},
                byEncounter = {}
            }

            -- Queue per-encounter collection for this dungeon
            for _, encounterID in ipairs(encounterIDs) do
                table.insert(queue, qIdx + 1, {
                    kind = "dungeon-encounter",
                    instanceID = instanceID,
                    encounterID = encounterID
                })
                qIdx = qIdx -- will increment naturally
            end

            -- After dungeon entries for this instance are queued, also queue
            -- the dungeon-dedup step (inserted after all its encounters).
            table.insert(queue, qIdx + 1 + #encounterIDs, {
                kind = "dungeon-dedup",
                instanceID = instanceID
            })

            return
        end

        -- ── dungeon-encounter: collect items for one encounter ────────────
        if entry.kind == "dungeon-encounter" then
            local instanceID = entry.instanceID
            local encounterID = entry.encounterID

            SetupEJForCollection(DUNGEON_MYTHIC)
            EJ_SelectInstance(instanceID)
            EJ_SelectEncounter(encounterID)
            local grouped = CollectItemsGroupedByFilter(lootFilters)
            result.dungeons[instanceID].byEncounter[encounterID] = grouped.all
            -- Stash per-filter data; the dedup step merges these into instance-level byClass/bySpec.
            local dd = result.dungeons[instanceID]
            if not dd._encClass then
                dd._encClass = {};
                dd._encSpec = {}
            end
            dd._encClass[encounterID] = grouped.byClass
            dd._encSpec[encounterID] = grouped.bySpec
            return
        end

        -- ── dungeon-dedup: merge per-encounter lists into .all/.byClass/.bySpec ─
        if entry.kind == "dungeon-dedup" then
            local instanceID = entry.instanceID
            local dungeonData = result.dungeons[instanceID]
            local seen = {}
            local all = {}
            for _, itemIDs in pairs(dungeonData.byEncounter) do
                for _, itemID in ipairs(itemIDs) do
                    if not seen[itemID] then
                        seen[itemID] = true
                        all[#all + 1] = itemID
                    end
                end
            end
            table.sort(all)
            dungeonData.all = all

            -- Merge per-encounter class/spec buckets into instance-level tables.
            local byClass = {} -- [classID] = { seen={}, items={} }
            local bySpec = {} -- [specID]  = { seen={}, items={} }
            local function Merge(bucket, itemID)
                if not bucket.seen[itemID] then
                    bucket.seen[itemID] = true
                    bucket.items[#bucket.items + 1] = itemID
                end
            end
            for _, classMap in pairs(dungeonData._encClass or {}) do
                for classID, itemIDs in pairs(classMap) do
                    if not byClass[classID] then
                        byClass[classID] = {
                            seen = {},
                            items = {}
                        }
                    end
                    for _, id in ipairs(itemIDs) do
                        Merge(byClass[classID], id)
                    end
                end
            end
            for _, specMap in pairs(dungeonData._encSpec or {}) do
                for specID, itemIDs in pairs(specMap) do
                    if not bySpec[specID] then
                        bySpec[specID] = {
                            seen = {},
                            items = {}
                        }
                    end
                    for _, id in ipairs(itemIDs) do
                        Merge(bySpec[specID], id)
                    end
                end
            end
            local byClassFinal = {}
            for classID, b in pairs(byClass) do
                table.sort(b.items);
                byClassFinal[classID] = b.items
            end
            local bySpecFinal = {}
            for specID, b in pairs(bySpec) do
                table.sort(b.items);
                bySpecFinal[specID] = b.items
            end
            dungeonData.byClass = byClassFinal
            dungeonData.bySpec = bySpecFinal

            -- Build bySlot: { [slotKey] = { sorted itemIDs } }
            local slotBuckets = {}
            for _, itemID in ipairs(dungeonData.all) do
                local slotKey = GetSlotKey(itemID)
                if slotKey then
                    if not slotBuckets[slotKey] then
                        slotBuckets[slotKey] = {}
                    end
                    slotBuckets[slotKey][#slotBuckets[slotKey] + 1] = itemID
                end
            end
            local bySlot = {}
            for slotKey, ids in pairs(slotBuckets) do
                table.sort(ids)
                bySlot[slotKey] = ids
            end
            dungeonData.bySlot = bySlot

            -- Remove temp fields so they are not serialised to SavedVariables.
            dungeonData._encClass = nil
            dungeonData._encSpec = nil

            -- After the last dungeon-dedup, queue all raid work.
            local allDungeonsDeduped = true
            for _, instanceID2 in ipairs(season.dungeonInstanceIDs) do
                if not result.dungeons[instanceID2] or not result.dungeons[instanceID2].all then
                    allDungeonsDeduped = false
                    break
                end
            end
            if allDungeonsDeduped and not entry.raidQueued then
                entry.raidQueued = true
                -- Queue raid-instance discovery for each raid instance
                for raidInstanceID in pairs(season.raidInstanceIDs) do
                    queue[#queue + 1] = {
                        kind = "raid-discover",
                        instanceID = raidInstanceID
                    }
                end
            end
            return
        end

        -- ── raid-discover: enumerate encounters for this raid instance ─────
        if entry.kind == "raid-discover" then
            local instanceID = entry.instanceID
            -- Use normal difficulty for encounter enumeration
            SetupEJForCollection(RAID_NORMAL)
            EJ_SelectInstance(instanceID)

            local encounterIDs = {}
            local encIdx = 1
            while true do
                local name, _, encounterID = EJ_GetEncounterInfoByIndex(encIdx)
                if not name then
                    break
                end
                encounterIDs[#encounterIDs + 1] = encounterID
                encIdx = encIdx + 1
            end

            -- Capture the WoW mapID so Detection can resolve the EJ instanceID
            -- from GetInstanceInfo()'s 8th return at runtime without a name lookup.
            local _, _, _, _, _, _, _, _, _, ejMapID = EJ_GetInstanceInfo(instanceID)
            if ejMapID and ejMapID ~= 0 then
                result.raidInstanceIDs[instanceID] = {
                    mapID = ejMapID
                }
            end

            -- Queue per-encounter × per-difficulty collection
            for _, encounterID in ipairs(encounterIDs) do
                for _, diffID in ipairs(ELIGIBLE_RAID_DIFFS) do
                    queue[#queue + 1] = {
                        kind = "raid-encounter",
                        instanceID = instanceID,
                        encounterID = encounterID,
                        difficultyID = diffID
                    }
                end
            end
            return
        end

        -- ── raid-encounter: collect items for one encounter × difficulty ───
        if entry.kind == "raid-encounter" then
            local instanceID = entry.instanceID
            local encounterID = entry.encounterID
            local diffID = entry.difficultyID

            SetupEJForCollection(diffID)
            EJ_SelectInstance(instanceID)
            EJ_SelectEncounter(encounterID)
            EJ_SetDifficulty(diffID)

            -- Save one sample EJ link per difficulty so Panel.lua can extract
            -- bonus IDs without any range guessing. We grab the first item that
            -- has a non-empty link; all items at the same difficulty share the
            -- same bonus ID set, so any one of them is representative.
            if C_EncounterJournal and C_EncounterJournal.GetLootInfoByIndex then
                local numLoot = EJ_GetNumLoot and EJ_GetNumLoot() or 0
                for i = 1, numLoot do
                    local info = C_EncounterJournal.GetLootInfoByIndex(i)
                    if info and info.link and info.link ~= "" then
                        if not result.raids[encounterID] then
                            result.raids[encounterID] = {
                                instanceID = instanceID,
                                byClass = {},
                                bySpec = {}
                            }
                        end
                        if not result.raids[encounterID].bonusByDiff then
                            result.raids[encounterID].bonusByDiff = {}
                        end
                        result.raids[encounterID].bonusByDiff[diffID] = info.link
                        break
                    end
                end
            end

            local grouped = CollectItemsGroupedByFilter(lootFilters)
            if not result.raids[encounterID] then
                result.raids[encounterID] = {
                    instanceID = instanceID,
                    byClass = {},
                    bySpec = {}
                }
            end
            result.raids[encounterID][diffID] = grouped.all
            result.raids[encounterID].byClass[diffID] = grouped.byClass
            result.raids[encounterID].bySpec[diffID] = grouped.bySpec
            return
        end
    end)
end

-- ── Slash command ─────────────────────────────────────────────────────────────

SLASH_VCAGEN1 = "/vcagen"
SlashCmdList["VCAGEN"] = function(msg)
    local cmd = msg and msg:match("^%s*(%S*)") or ""
    cmd = cmd:lower()

    if cmd == "run" then
        RunGeneration()
    elseif cmd == "status" then
        if _genRunning then
            print("|cff66ccffVoidcoreAdvisorGen:|r Generation is in progress...")
        elseif VoidcoreAdvisorGenDB and VoidcoreAdvisorGenDB.seasonData then
            local build = VoidcoreAdvisorGenDB.generatedBuild or "?"
            local nd, nr = 0, 0
            for _ in pairs(VoidcoreAdvisorGenDB.seasonData.dungeons or {}) do
                nd = nd + 1
            end
            for _ in pairs(VoidcoreAdvisorGenDB.seasonData.raids or {}) do
                nr = nr + 1
            end
            print(string.format("|cff66ccffVoidcoreAdvisorGen:|r Last run on build %s — " ..
                                    "%d dungeons, %d raid encounters stored.", build, nd, nr))
        else
            print("|cff66ccffVoidcoreAdvisorGen:|r No data yet.  Use /vcagen run.")
        end
    else
        print("|cff66ccffVoidcoreAdvisorGen:|r Commands:")
        print("  |cffffd700/vcagen run|r           — Walk EJ and collect season loot data")
        print("  |cffffd700/vcagen status|r         — Show last generation result")
        print("")
        print("After running: type |cffffd700/reload|r, then open your SavedVariables file and")
        print("copy VoidcoreAdvisorGenDB[\"seasonData\"] into Core/SeasonData.lua.")
        print("See the top of Generator.lua for the full workflow.")
    end
end

print("|cff66ccffVoidcoreAdvisorGen:|r Loaded.  Type /vcagen for usage.")
