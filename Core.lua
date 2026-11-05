--[[
  Chronolog - Core
  ----------------
  Tracks, per character level (WoW Forever):
    * combat  - time spent in combat
    * travel  - time spent moving (on foot, mounted, or on a taxi/flight path)
    * afk     - time spent flagged AFK
    * other   - all remaining active (logged-in, in-world) time
    * total   - combat + travel + afk + other (all measured online time)
    * kills   - mobs (non-player units) that died to you or your pet

  Time is bucketed by a throttled OnUpdate ticker. Each tick is charged to a
  single category by priority (mounted/taxi travel > combat > afk > on-foot travel > other) so the buckets
  never double-count and always sum to `total`.

  All state is stored per-character in the saved variable ChronologDB.
]]

local addonName, ns = ...

local MAX_LEVEL = 60
local TICK = 0.2 -- seconds between accumulation samples


local UnitLevel = UnitLevel
local UnitGUID = UnitGUID
local UnitAffectingCombat = UnitAffectingCombat
local UnitIsAFK = UnitIsAFK
local IsMounted = IsMounted
local UnitOnTaxi = UnitOnTaxi
local IsInInstance = IsInInstance
local GetUnitSpeed = GetUnitSpeed
local GetTime = GetTime

-- A level needs at least this much tracked time before it is eligible for the
-- busiest/laziest proportion rankings, so a level with a few seconds of data
-- can't show a misleading 100%.
local MIN_TOTAL_FOR_RATIO = 60
local floor = math.floor
local min = math.min
local max = math.max

-- A 5-man run counts as a "dungeon" once you've been inside this long (used as
-- a fallback when the LFG completion reward event doesn't fire, e.g. manual runs).
local DUNGEON_MIN_TIME = 240

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local state = {
  ready = false,
  inCombat = false,
  currentLevel = 1,
  inDungeon = false,
  dungeonEnter = 0,
  dungeonCounted = false,
}
ns.state = state
ns.MAX_LEVEL = MAX_LEVEL

local playerGUID

--------------------------------------------------------------------------------
-- WoW Forever (Midnight-based client) notes
--   * COMBAT_LOG_EVENT_UNFILTERED is not available to addons, so kills are
--     counted from the "<mob> dies, you gain N experience." chat line.
--   * Chat payloads can be "secret" values that error if inspected.
--------------------------------------------------------------------------------
ns.BACKDROP_TEMPLATE = "BackdropTemplate"

function ns.SetColor(tex, r, g, b, a)
  tex:SetColorTexture(r, g, b, a)
end

local function IsSecret(v)
  return issecretvalue and issecretvalue(v) or false
end

-- Shapeshift form IDs that act as mounts: Travel, Aquatic, Ghost Wolf, and the
-- druid Flight / Swift Flight forms.
local TRAVEL_FORMS = { [3] = true, [4] = true, [16] = true, [27] = true, [29] = true }

-- nil for secret values, otherwise the value itself.
local function Clean(v)
  if IsSecret(v) then return nil end
  return v
end

--------------------------------------------------------------------------------
-- Data model
--------------------------------------------------------------------------------
local function NewRow()
  return {
    combat = 0, travel = 0, afk = 0, other = 0, total = 0,
    idle = 0, kills = 0, quests = 0, dungeons = 0, grouped = 0,
  }
end

-- Backfill fields added in later versions onto an existing row.
local function MigrateRow(row)
  if row.quests == nil then row.quests = 0 end
  if row.dungeons == nil then row.dungeons = 0 end
  if row.grouped == nil then row.grouped = 0 end
  if row.idle == nil then row.idle = 0 end
end

local function EnsureDB()
  if type(ChronologDB) ~= "table" then ChronologDB = {} end
  local db = ChronologDB
  if type(db.levels) ~= "table" then db.levels = {} end
  if db.version == nil then db.version = 1 end
  return db
end
ns.EnsureDB = EnsureDB

local function GetRow(db, lvl)
  local row = db.levels[lvl]
  if not row then
    row = NewRow()
    db.levels[lvl] = row
  else
    MigrateRow(row)
  end
  return row
end
ns.GetRow = GetRow

-- Create empty rows for currentLevel..60 on first use, per the spec.
local function InitLevels(db)
  local cur = UnitLevel("player") or 1
  if db.startLevel == nil then
    db.startLevel = cur
    db.createdAt = time()
  end
  db.characterName = UnitName("player")
  local _, class = UnitClass("player")
  db.class = class
  for lvl = min(db.startLevel, cur), MAX_LEVEL do
    if not db.levels[lvl] then db.levels[lvl] = NewRow() end
  end
end

-- Wipe all data and re-seed from the current level.
function ns.ResetData()
  local keepWidget = ChronologDB and ChronologDB.widget
  local keepWindow = ChronologDB and ChronologDB.window
  ChronologDB = nil
  local db = EnsureDB()
  if keepWidget then db.widget = keepWidget end
  if keepWindow then db.window = keepWindow end
  InitLevels(db)
  state.currentLevel = UnitLevel("player") or 1
  if ns.Refresh then ns.Refresh() end
  if ns.RefreshWidget then ns.RefreshWidget() end
end

--------------------------------------------------------------------------------
-- Time formatting (shared with the UI)
--------------------------------------------------------------------------------
function ns.FormatTime(sec)
  sec = floor((sec or 0) + 0.5)
  if sec <= 0 then return "0s" end
  local h = floor(sec / 3600)
  local m = floor((sec % 3600) / 60)
  local s = sec % 60
  if h > 0 then
    return string.format("%dh %02dm", h, m)
  elseif m > 0 then
    return string.format("%dm %02ds", m, s)
  else
    return s .. "s"
  end
end

--------------------------------------------------------------------------------
-- Accumulation ticker
--------------------------------------------------------------------------------
local ticker = CreateFrame("Frame")
local sinceLast = 0
ticker:SetScript("OnUpdate", function(_, elapsed)
  sinceLast = sinceLast + elapsed
  if sinceLast < TICK then return end
  local dt = sinceLast
  sinceLast = 0

  if not state.ready then return end
  local db = ChronologDB
  if not db then return end

  -- Read every unit query up front and treat "secret" results (the client
  -- hides some values during combat) as unknown. Comparing or testing a
  -- secret value throws, and doing so after bumping `total` would leave time
  -- charged to no bucket.
  local onTaxi = Clean(UnitOnTaxi("player"))
  local formID = GetShapeshiftFormID and Clean(GetShapeshiftFormID())
  -- Travel-type forms (Ghost Wolf, Travel Form, ...) count like a mount.
  local mounted = Clean(IsMounted()) or (formID and TRAVEL_FORMS[formID]) or false
  local speed = Clean(GetUnitSpeed("player"))
  local moving = nil -- unknown while the speed is secret
  if speed ~= nil then moving = speed > 0 end
  local fighting = state.inCombat or Clean(UnitAffectingCombat("player"))
  local afk = Clean(UnitIsAFK("player"))

  local row = GetRow(db, state.currentLevel)
  row.total = row.total + dt

  if onTaxi or (mounted and moving ~= false) then
    -- Travel takes priority over combat: on a flight path, or mounted (or in
    -- a travel form) AND
    -- actually moving, is counted as travel even if the combat flag is set.
    -- Sitting still on a mount is not travel; it falls through below. If the
    -- speed is unknown (secret), a mounted player is assumed to be moving.
    row.travel = row.travel + dt
  elseif fighting then
    row.combat = row.combat + dt
  elseif afk then
    row.afk = row.afk + dt
  elseif moving then
    -- Moving on foot (out of combat) also counts as travel.
    row.travel = row.travel + dt
  else
    row.other = row.other + dt
    -- Idle = not travelling, not fighting, not AFK, and known to be standing
    -- still (this includes sitting on a mount without moving).
    if moving == false then
      row.idle = row.idle + dt
    end
  end

  -- Group time is tracked independently of the buckets above (you can be in a
  -- party while also in combat/travel/etc.).
  if IsInGroup() or IsInRaid() then
    row.grouped = row.grouped + dt
  end
end)

--------------------------------------------------------------------------------
-- Dungeon detection
--------------------------------------------------------------------------------
-- Counts a completed 5-man dungeon against the current level. Guarded so a
-- single run can't be counted twice (LFG event + leave-instance fallback).
local function CountDungeon()
  if state.dungeonCounted then return end
  state.dungeonCounted = true
  local db = ChronologDB
  if db then
    local row = GetRow(db, state.currentLevel)
    row.dungeons = row.dungeons + 1
  end
  if ns.Refresh then ns.Refresh() end
end

-- Called on world transitions to track entering/leaving a 5-man dungeon.
local function UpdateInstanceState()
  local inInstance, instanceType = IsInInstance()
  if inInstance and instanceType == "party" then
    if not state.inDungeon then
      state.inDungeon = true
      state.dungeonEnter = GetTime()
      state.dungeonCounted = false
    end
  else
    if state.inDungeon then
      -- Left the dungeon: if not already credited (e.g. via LFG reward) and we
      -- stayed long enough, count it as a completed run.
      if not state.dungeonCounted
         and (GetTime() - (state.dungeonEnter or 0)) >= DUNGEON_MIN_TIME then
        CountDungeon()
      end
      state.inDungeon = false
      state.dungeonCounted = false
    end
  end
end

--------------------------------------------------------------------------------
-- Quest turn-ins: GetQuestReward is called when the player finalizes a quest.
--------------------------------------------------------------------------------
if type(GetQuestReward) == "function" then
  hooksecurefunc("GetQuestReward", function()
    if not state.ready then return end
    local db = ChronologDB
    if db then
      local row = GetRow(db, state.currentLevel)
      row.quests = row.quests + 1
      if ns.Refresh then ns.Refresh() end
    end
  end)
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_LEVEL_UP")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("LFG_COMPLETION_REWARD")
ev:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")

-- Build a prefix pattern from the localized kill-XP format string.
local KILL_XP_PATTERN
do
  local fmt = COMBATLOG_XPGAIN_FIRSTPERSON
  if type(fmt) == "string" then
    local pat = fmt:gsub("([%^%$%(%)%.%[%]%*%+%-%?%%])", "%%%1")
    pat = pat:gsub("%%%%%d%%%$[sd]", ".+"):gsub("%%%%[sd]", ".+")
    -- Only match the leading part so group/rested bonus suffixes still count.
    KILL_XP_PATTERN = "^" .. (pat:match("^(.-%%%.)") or pat)
  end
end

ev:SetScript("OnEvent", function(_, event, ...)
  if event == "PLAYER_LOGIN" then
    playerGUID = UnitGUID("player")
    local db = EnsureDB()
    InitLevels(db)
    state.currentLevel = UnitLevel("player") or 1
    state.inCombat = UnitAffectingCombat("player") and true or false
    state.ready = true
    UpdateInstanceState()

  elseif event == "PLAYER_ENTERING_WORLD" then
    if state.ready then
      state.currentLevel = UnitLevel("player") or state.currentLevel
    end
    UpdateInstanceState()

  elseif event == "LFG_COMPLETION_REWARD" then
    -- Definitive "dungeon completed" signal from the Dungeon Finder.
    if state.inDungeon then
      CountDungeon()
    else
      -- Reward can arrive just after leaving; credit the current level anyway.
      state.dungeonCounted = false
      CountDungeon()
    end

  elseif event == "PLAYER_LEVEL_UP" then
    local newLevel = tonumber((...)) or ((state.currentLevel or 0) + 1)
    state.currentLevel = newLevel
    local db = EnsureDB()
    GetRow(db, newLevel)
    if ns.Refresh then ns.Refresh() end
    if ns.RefreshWidget then ns.RefreshWidget() end

  elseif event == "PLAYER_REGEN_DISABLED" then
    state.inCombat = true

  elseif event == "PLAYER_REGEN_ENABLED" then
    state.inCombat = false

  elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
    if not state.ready or not KILL_XP_PATTERN then return end
    local msg = ...
    if type(msg) ~= "string" or IsSecret(msg) then return end
    if msg:find(KILL_XP_PATTERN) then
      local db = ChronologDB
      if db then
        local row = GetRow(db, state.currentLevel)
        row.kills = row.kills + 1
      end
    end
  end
end)

--------------------------------------------------------------------------------
-- Aggregate helper for the UI: returns totals + a sorted list of level rows.
--------------------------------------------------------------------------------
function ns.GetAggregate()
  local db = EnsureDB()
  local totals = NewRow()
  local levels = {}
  -- Busiest  = highest proportion of a level's time spent in combat.
  -- Laziest  = highest proportion spent AFK or standing idle (afk + idle).
  -- Only levels with enough tracked time qualify, so tiny samples can't win.
  local busiestLevel, busiestRatio = nil, -1
  local laziestLevel, laziestRatio = nil, -1

  for lvl, row in pairs(db.levels) do
    MigrateRow(row)
    levels[#levels + 1] = lvl
    totals.combat = totals.combat + row.combat
    totals.travel = totals.travel + row.travel
    totals.afk = totals.afk + row.afk
    totals.other = totals.other + row.other
    totals.idle = totals.idle + row.idle
    totals.total = totals.total + row.total
    totals.kills = totals.kills + row.kills
    totals.quests = totals.quests + row.quests
    totals.dungeons = totals.dungeons + row.dungeons
    totals.grouped = totals.grouped + row.grouped

    if row.total >= MIN_TOTAL_FOR_RATIO then
      local combatRatio = row.combat / row.total
      local lazyRatio = (row.afk + row.idle) / row.total
      if combatRatio > busiestRatio then busiestRatio, busiestLevel = combatRatio, lvl end
      if lazyRatio > laziestRatio then laziestRatio, laziestLevel = lazyRatio, lvl end
    end
  end
  table.sort(levels)

  return {
    db = db,
    totals = totals,
    levels = levels,
    busiestLevel = busiestLevel,
    busiestRatio = busiestRatio,
    laziestLevel = laziestLevel,
    laziestRatio = laziestRatio,
  }
end

--------------------------------------------------------------------------------
-- Slash command
--------------------------------------------------------------------------------
SLASH_CHRONOLOG1 = "/chronolog"
SLASH_CHRONOLOG2 = "/chrono"
SlashCmdList["CHRONOLOG"] = function(msg)
  msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")

  if msg == "help" or msg == "?" then
    print("|cff66ccffChronolog|r commands:")
    print("  |cffffff00/chrono|r - toggle the main window")
    print("  |cffffff00/chrono widget|r - toggle the current-level widget")
    print("  |cffffff00/chrono reset|r - erase all tracked data (asks to confirm)")
    print("  |cffffff00/chrono help|r - show this list")
  elseif msg == "reset" then
    print("|cff66ccffChronolog|r: this will erase all tracked data. Type |cffffff00/chrono reset yes|r to confirm.")
  elseif msg == "reset yes" then
    ns.ResetData()
    print("|cff66ccffChronolog|r: data reset. Now tracking from level " .. (UnitLevel("player") or "?") .. ".")
  elseif msg == "widget" then
    if ns.ToggleWidget then ns.ToggleWidget() end
  else
    if ns.ToggleWindow then ns.ToggleWindow() end
  end
end
