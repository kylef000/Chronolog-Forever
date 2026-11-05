--[[
  Chronolog-Forever - Core
  ------------------------
  Tracks, per character level (WoW Forever / Midnight client):
    * combat / travel / afk / dead / other - mutually exclusive time buckets that
      always add up to `total` (measured online time)
    * idle      - the part of "other" spent standing still
    * grouped, crafting - overlapping counters (not exclusive with the above)
    * loading   - time in loading screens (NOT part of `total`)
    * kills, quests, dungeons, deaths, xp, gold, spent
    * zones     - seconds spent per zone

  Time is bucketed by a throttled OnUpdate ticker. Each tick is charged to a
  single bucket by priority so the buckets never double-count.

  Data is stored per character in ChronologForeverDB, and a reference to each
  character's levels is mirrored into the account-wide ChronologAccountDB so
  the window can show other characters / all characters.

  WoW Forever notes:
    * COMBAT_LOG_EVENT_UNFILTERED is not available to addons.
    * Some values are "secret" during combat (e.g. GetUnitSpeed("player")).
      Comparing/testing one throws, so every query goes through Clean().
]]

local addonName, ns = ...

local MAX_LEVEL = 60
local TICK = 0.2 -- seconds between accumulation samples
local MAX_DT = 5 -- a longer gap is a stall/loading screen; don't charge it

local UnitLevel = UnitLevel
local UnitGUID = UnitGUID
local UnitAffectingCombat = UnitAffectingCombat
local UnitIsAFK = UnitIsAFK
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local IsMounted = IsMounted
local UnitOnTaxi = UnitOnTaxi
local IsInInstance = IsInInstance
local GetUnitSpeed = GetUnitSpeed
local GetTime = GetTime

local floor = math.floor
local min = math.min
local max = math.max

-- A level needs at least this much tracked time before it is eligible for the
-- busiest/laziest rankings and for per-hour rates, so a few seconds of data
-- can't show a misleading 100% or a huge rate.
local MIN_TOTAL_FOR_RATIO = 60

-- A 5-man run counts as a "dungeon" once you've been inside this long (used as
-- a fallback when the LFG completion reward event doesn't fire, e.g. manual runs).
local DUNGEON_MIN_TIME = 240

-- Shapeshift form IDs that act as mounts: Travel, Aquatic, Ghost Wolf, and the
-- druid Flight / Swift Flight forms.
local TRAVEL_FORMS = { [3] = true, [4] = true, [16] = true, [27] = true, [29] = true }

local BUCKETS = { "combat", "travel", "afk", "other", "dead" }
ns.BUCKETS = BUCKETS

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
  bucket = "?",
}
ns.state = state
ns.MAX_LEVEL = MAX_LEVEL
ns.MIN_TOTAL_FOR_RATIO = MIN_TOTAL_FOR_RATIO

local playerGUID
local sinceLast = 0

-- Which character the window is showing: nil = this character, a character key,
-- or "ALL" for every character on the account.
ns.viewSource = nil

--------------------------------------------------------------------------------
-- Secret-value helpers
--------------------------------------------------------------------------------
local function IsSecret(v)
  return issecretvalue and issecretvalue(v) or false
end

-- nil for secret values, otherwise the value itself.
local function Clean(v)
  if IsSecret(v) then return nil end
  return v
end
ns.IsSecret = IsSecret
ns.Clean = Clean

ns.BACKDROP_TEMPLATE = "BackdropTemplate"

function ns.SetColor(tex, r, g, b, a)
  tex:SetColorTexture(r, g, b, a)
end

--------------------------------------------------------------------------------
-- Data model
--------------------------------------------------------------------------------
local NUM_FIELDS = {
  "combat", "travel", "afk", "other", "dead", "total", "idle",
  "kills", "quests", "dungeons", "grouped", "deaths",
  "xp", "gold", "spent", "crafting", "loading",
}
ns.NUM_FIELDS = NUM_FIELDS

local function NewRow()
  local row = { zones = {} }
  for _, f in ipairs(NUM_FIELDS) do row[f] = 0 end
  return row
end

-- Backfill fields added in later versions onto an existing row.
local function MigrateRow(row)
  for _, f in ipairs(NUM_FIELDS) do
    if row[f] == nil then row[f] = 0 end
  end
  if type(row.zones) ~= "table" then row.zones = {} end
end

function ns.CharKey()
  return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
end

local function EnsureDB()
  if type(ChronologForeverDB) ~= "table" then
    -- One-time migration from the pre-rename saved variable.
    if type(ChronologDB) == "table" and type(ChronologDB.levels) == "table" then
      ChronologForeverDB = ChronologDB
      ChronologDB = nil
    else
      ChronologForeverDB = {}
    end
  end
  local db = ChronologForeverDB
  if type(db.levels) ~= "table" then db.levels = {} end
  db.version = 2
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

-- Create empty rows for currentLevel..60 on first use.
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

-- Mirror this character's data into the account-wide DB (same table reference,
-- so it is always current when the game saves).
local function SyncAccount()
  if type(ChronologAccountDB) ~= "table" then ChronologAccountDB = {} end
  local a = ChronologAccountDB
  if type(a.chars) ~= "table" then a.chars = {} end
  local db = ChronologForeverDB
  if not db then return end
  a.chars[ns.CharKey()] = {
    name = UnitName("player"),
    realm = GetRealmName(),
    class = db.class,
    startLevel = db.startLevel,
    levels = db.levels,
    updated = time(),
  }
end

-- Wipe all data and re-seed from the current level. Settings are kept.
function ns.ResetData()
  local old = ChronologForeverDB
  local keepWidget = old and old.widget
  local keepWindow = old and old.window
  local keepMinimap = old and old.minimap
  ChronologForeverDB = nil
  local db = EnsureDB()
  if keepWidget then db.widget = keepWidget end
  if keepWindow then db.window = keepWindow end
  if keepMinimap then db.minimap = keepMinimap end
  InitLevels(db)
  SyncAccount()
  state.currentLevel = UnitLevel("player") or 1
  if ns.Refresh then ns.Refresh() end
  if ns.RefreshWidget then ns.RefreshWidget() end
end

--------------------------------------------------------------------------------
-- Formatting (shared with the UI)
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

function ns.FormatNumber(n)
  n = n or 0
  if n >= 1000000 then return string.format("%.1fm", n / 1000000) end
  if n >= 1000 then return string.format("%.1fk", n / 1000) end
  return string.format("%d", floor(n + 0.5))
end

-- copper -> "12g 34s"
function ns.FormatGold(copper)
  copper = floor(copper or 0)
  local g = floor(copper / 10000)
  local s = floor((copper % 10000) / 100)
  if g > 0 then return string.format("%dg %02ds", g, s) end
  if s > 0 then return s .. "s" end
  return "0g"
end

-- `field` per hour of tracked time (0 until the level has enough data).
function ns.PerHour(row, field, divisor)
  if (row.total or 0) < MIN_TOTAL_FOR_RATIO then return 0 end
  return (row[field] or 0) / (divisor or 1) / (row.total / 3600)
end

local function Pct(row, field)
  if (row.total or 0) < MIN_TOTAL_FOR_RATIO then return 0 end
  return row[field] / row.total * 100
end

-- Chart metrics: get(row) -> number, fmt(number) -> string.
ns.METRICS = {
  { key = "total",  label = "Time played",  get = function(r) return r.total end, fmt = ns.FormatTime },
  { key = "combat", label = "Combat %",     get = function(r) return Pct(r, "combat") end,
    fmt = function(v) return string.format("%.0f%%", v) end },
  { key = "travel", label = "Travel %",     get = function(r) return Pct(r, "travel") end,
    fmt = function(v) return string.format("%.0f%%", v) end },
  { key = "kills",  label = "Kills",        get = function(r) return r.kills end,
    fmt = function(v) return string.format("%d", v) end },
  { key = "kph",    label = "Kills / hour", get = function(r) return ns.PerHour(r, "kills") end,
    fmt = function(v) return string.format("%.0f", v) end },
  { key = "xph",    label = "XP / hour",    get = function(r) return ns.PerHour(r, "xp") end,
    fmt = ns.FormatNumber },
  { key = "gph",    label = "Gold / hour",  get = function(r) return ns.PerHour(r, "gold", 10000) end,
    fmt = function(v) return string.format("%.1fg", v) end },
  { key = "deaths", label = "Deaths",       get = function(r) return r.deaths end,
    fmt = function(v) return string.format("%d", v) end },
}

-- Widget stat choices: get(row) -> display string.
ns.STATS = {
  { key = "kills",    label = "Kills",    get = function(r) return tostring(r.kills) end },
  { key = "quests",   label = "Quests",   get = function(r) return tostring(r.quests) end },
  { key = "dungeons", label = "Dungeons", get = function(r) return tostring(r.dungeons) end },
  { key = "grouped",  label = "Grouped",  get = function(r) return ns.FormatTime(r.grouped) end },
  { key = "deaths",   label = "Deaths",   get = function(r) return tostring(r.deaths) end },
  { key = "kph",      label = "Kills/hr", get = function(r) return string.format("%.0f", ns.PerHour(r, "kills")) end },
  { key = "xph",      label = "XP/hr",    get = function(r) return ns.FormatNumber(ns.PerHour(r, "xp")) end },
  { key = "gph",      label = "Gold/hr",  get = function(r) return string.format("%.1fg", ns.PerHour(r, "gold", 10000)) end },
  { key = "crafting", label = "Crafting", get = function(r) return ns.FormatTime(r.crafting) end },
  { key = "dead",     label = "Dead",     get = function(r) return ns.FormatTime(r.dead) end },
}

--------------------------------------------------------------------------------
-- Accumulation ticker
--------------------------------------------------------------------------------
local ticker = CreateFrame("Frame")
ticker:SetScript("OnUpdate", function(_, elapsed)
  sinceLast = sinceLast + elapsed
  if sinceLast < TICK then return end
  local dt = sinceLast
  sinceLast = 0

  if not state.ready or dt > MAX_DT then return end
  local db = ChronologForeverDB
  if not db then return end

  -- Read every query up front and treat "secret" results (the client hides some
  -- values during combat) as unknown. Comparing or testing a secret value
  -- throws, and doing so after bumping `total` would leave time charged to no
  -- bucket.
  local dead = Clean(UnitIsDeadOrGhost("player"))
  local onTaxi = Clean(UnitOnTaxi("player"))
  local formID = GetShapeshiftFormID and Clean(GetShapeshiftFormID())
  -- Travel-type forms (Ghost Wolf, Travel Form, ...) count like a mount.
  local mounted = Clean(IsMounted()) or (formID and TRAVEL_FORMS[formID]) or false
  local speed = Clean(GetUnitSpeed("player"))
  local moving = nil -- unknown while the speed is secret
  if speed ~= nil then moving = speed > 0 end
  local fighting = state.inCombat or Clean(UnitAffectingCombat("player"))
  local afk = Clean(UnitIsAFK("player"))
  local grouped = Clean(IsInGroup()) or Clean(IsInRaid())
  local crafting = ProfessionsFrame and ProfessionsFrame:IsShown()
  local zone = Clean(GetRealZoneText())
  if not zone or zone == "" then zone = Clean(GetZoneText()) end
  if not zone or zone == "" then zone = "Unknown" end

  local row = GetRow(db, state.currentLevel)
  row.total = row.total + dt

  if dead then
    -- Dead or running back as a ghost.
    row.dead = row.dead + dt
    state.bucket = "dead"
  elseif onTaxi or (mounted and moving ~= false) then
    -- Travel takes priority over combat: on a flight path, or mounted (or in
    -- a travel form) AND actually moving, is counted as travel even if the
    -- combat flag is set. Sitting still on a mount is not travel; it falls
    -- through below. If the speed is unknown (secret), a mounted player is
    -- assumed to be moving.
    row.travel = row.travel + dt
    state.bucket = "travel (mount/form/taxi)"
  elseif fighting then
    row.combat = row.combat + dt
    state.bucket = "combat"
  elseif afk then
    row.afk = row.afk + dt
    state.bucket = "afk"
  elseif moving then
    -- Moving on foot (out of combat) also counts as travel.
    row.travel = row.travel + dt
    state.bucket = "travel (on foot)"
  else
    row.other = row.other + dt
    state.bucket = "other"
    -- Idle = not travelling, not fighting, not AFK, and known to be standing
    -- still (this includes sitting on a mount without moving).
    if moving == false then
      row.idle = row.idle + dt
    end
  end

  -- Overlapping counters (not part of the exclusive buckets above).
  if grouped then row.grouped = row.grouped + dt end
  if crafting then row.crafting = row.crafting + dt end
  row.zones[zone] = (row.zones[zone] or 0) + dt
end)

--------------------------------------------------------------------------------
-- Dungeon detection
--------------------------------------------------------------------------------
-- Counts a completed 5-man dungeon against the current level. Guarded so a
-- single run can't be counted twice (LFG event + leave-instance fallback).
local function CountDungeon()
  if state.dungeonCounted then return end
  state.dungeonCounted = true
  local db = ChronologForeverDB
  if db then
    local row = GetRow(db, state.currentLevel)
    row.dungeons = row.dungeons + 1
  end
  if ns.Refresh then ns.Refresh() end
end

-- Called on world transitions to track entering/leaving a 5-man dungeon.
local function UpdateInstanceState()
  local inInstance, instanceType = IsInInstance()
  inInstance, instanceType = Clean(inInstance), Clean(instanceType)
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
    local db = ChronologForeverDB
    if db then
      local row = GetRow(db, state.currentLevel)
      row.quests = row.quests + 1
      if ns.Refresh then ns.Refresh() end
    end
  end)
end

--------------------------------------------------------------------------------
-- Kill counting (no combat log on Forever)
--   * Below max level: the "<mob> dies, you gain N experience." chat line.
--   * At max level there is no XP, so a target that dies after we saw it in
--     combat with us is counted instead (targeted kills only).
--------------------------------------------------------------------------------
local function AddKill()
  local db = ChronologForeverDB
  if db then
    local row = GetRow(db, state.currentLevel)
    row.kills = row.kills + 1
  end
end

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

local engaged, counted, trackedCount = {}, {}, 0

local function ResetTargetTracking()
  wipe(engaged)
  wipe(counted)
  trackedCount = 0
end

local function CheckTarget()
  if state.currentLevel < MAX_LEVEL then return end
  local guid = Clean(UnitGUID("target"))
  if not guid then return end
  if Clean(UnitIsPlayer("target")) then return end
  if Clean(UnitIsDead("target")) then
    if engaged[guid] and not counted[guid] then
      counted[guid] = true
      AddKill()
    end
  elseif Clean(UnitAffectingCombat("target")) and Clean(UnitCanAttack("player", "target"))
         and not Clean(UnitIsTapDenied("target")) then
    if not engaged[guid] then
      trackedCount = trackedCount + 1
      if trackedCount > 300 then ResetTargetTracking() end
      engaged[guid] = true
    end
  end
end

--------------------------------------------------------------------------------
-- XP / gold tracking
--------------------------------------------------------------------------------
local function OnXP()
  local xp, xpMax = Clean(UnitXP("player")), Clean(UnitXPMax("player"))
  if not xp or not xpMax then return end
  local last = state.lastXP
  if last then
    local gained = xp - last
    if gained < 0 then gained = (state.lastXPMax or 0) - last + xp end -- leveled up
    if gained > 0 then
      local db = ChronologForeverDB
      if db then
        local row = GetRow(db, state.currentLevel)
        row.xp = row.xp + gained
      end
    end
  end
  state.lastXP, state.lastXPMax = xp, xpMax
end

local function OnMoney()
  local m = Clean(GetMoney())
  if not m then return end
  local last = state.lastMoney
  state.lastMoney = m
  if not last or m == last then return end
  local db = ChronologForeverDB
  if not db then return end
  local row = GetRow(db, state.currentLevel)
  if m > last then row.gold = row.gold + (m - last) else row.spent = row.spent + (last - m) end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_LOGOUT")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_LEAVING_WORLD")
ev:RegisterEvent("PLAYER_LEVEL_UP")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("PLAYER_DEAD")
ev:RegisterEvent("PLAYER_XP_UPDATE")
ev:RegisterEvent("PLAYER_MONEY")
ev:RegisterEvent("PLAYER_TARGET_CHANGED")
ev:RegisterEvent("LFG_COMPLETION_REWARD")
ev:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")

-- Health/flag changes of the current target (cheap: only the "target" unit).
local targetEv = CreateFrame("Frame")
pcall(targetEv.RegisterUnitEvent, targetEv, "UNIT_HEALTH", "target")
pcall(targetEv.RegisterUnitEvent, targetEv, "UNIT_FLAGS", "target")
targetEv:SetScript("OnEvent", function()
  if state.ready then CheckTarget() end
end)

ev:SetScript("OnEvent", function(_, event, ...)
  if event == "PLAYER_LOGIN" then
    playerGUID = UnitGUID("player")
    local db = EnsureDB()
    InitLevels(db)
    SyncAccount()
    state.currentLevel = UnitLevel("player") or 1
    state.inCombat = UnitAffectingCombat("player") and true or false
    state.lastXP, state.lastXPMax = Clean(UnitXP("player")), Clean(UnitXPMax("player"))
    state.lastMoney = Clean(GetMoney())
    state.ready = true
    UpdateInstanceState()

  elseif event == "PLAYER_LOGOUT" then
    SyncAccount()

  elseif event == "PLAYER_LEAVING_WORLD" then
    state.loadStart = GetTime()

  elseif event == "PLAYER_ENTERING_WORLD" then
    if state.ready then
      state.currentLevel = UnitLevel("player") or state.currentLevel
      -- Loading screens are tracked separately and are not part of `total`.
      if state.loadStart then
        local db = ChronologForeverDB
        if db then
          local row = GetRow(db, state.currentLevel)
          row.loading = row.loading + (GetTime() - state.loadStart)
        end
      end
    end
    state.loadStart = nil
    sinceLast = 0 -- don't charge the loading screen as played time
    ResetTargetTracking()
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
    SyncAccount()
    if ns.Refresh then ns.Refresh() end
    if ns.RefreshWidget then ns.RefreshWidget() end

  elseif event == "PLAYER_REGEN_DISABLED" then
    state.inCombat = true

  elseif event == "PLAYER_REGEN_ENABLED" then
    state.inCombat = false

  elseif event == "PLAYER_DEAD" then
    if state.ready then
      local db = ChronologForeverDB
      if db then
        local row = GetRow(db, state.currentLevel)
        row.deaths = row.deaths + 1
      end
    end

  elseif event == "PLAYER_XP_UPDATE" then
    if state.ready then OnXP() end

  elseif event == "PLAYER_MONEY" then
    if state.ready then OnMoney() end

  elseif event == "PLAYER_TARGET_CHANGED" then
    if state.ready then CheckTarget() end

  elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
    if not state.ready then return end
    local msg = ...
    if type(msg) ~= "string" or IsSecret(msg) then return end
    state.lastXPMsg = msg
    if KILL_XP_PATTERN and state.currentLevel < MAX_LEVEL and msg:find(KILL_XP_PATTERN) then
      AddKill()
    end
  end
end)

--------------------------------------------------------------------------------
-- Aggregation for the UI / export
--------------------------------------------------------------------------------
-- Which level tables to read for a view source (nil = this character).
local function SourceTables(source)
  local db = EnsureDB()
  local a = ChronologAccountDB
  if source == "ALL" and a and a.chars then
    local tables, startLevel = {}, nil
    for _, c in pairs(a.chars) do
      if type(c.levels) == "table" then
        tables[#tables + 1] = c.levels
        if c.startLevel then startLevel = min(startLevel or c.startLevel, c.startLevel) end
      end
    end
    if #tables > 0 then return tables, startLevel end
  elseif source and a and a.chars and a.chars[source] then
    local c = a.chars[source]
    return { c.levels }, c.startLevel
  end
  return { db.levels }, db.startLevel
end

local function MergeInto(dst, src)
  for _, f in ipairs(NUM_FIELDS) do dst[f] = dst[f] + (src[f] or 0) end
  for zone, secs in pairs(src.zones or {}) do
    dst.zones[zone] = (dst.zones[zone] or 0) + secs
  end
end

-- Returns totals, a sorted list of levels, per-level rows and comparison
-- averages. `source`: nil = this character, a character key, or "ALL".
function ns.GetAggregate(source)
  local tables, startLevel = SourceTables(source)
  local rows = {}
  if #tables == 1 then
    for lvl, row in pairs(tables[1]) do
      MigrateRow(row)
      rows[lvl] = row
    end
  else
    for _, t in ipairs(tables) do
      for lvl, row in pairs(t) do
        MigrateRow(row)
        rows[lvl] = rows[lvl] or NewRow()
        MergeInto(rows[lvl], row)
      end
    end
  end

  local totals = NewRow()
  local levels = {}
  -- Busiest  = highest proportion of a level's time spent in combat.
  -- Laziest  = highest proportion spent AFK or standing idle (afk + idle).
  -- Only levels with enough tracked time qualify, so tiny samples can't win.
  local busiestLevel, busiestRatio = nil, -1
  local laziestLevel, laziestRatio = nil, -1
  local avg = { combat = 0, kph = 0, xph = 0, gph = 0, n = 0 }

  for lvl, row in pairs(rows) do
    levels[#levels + 1] = lvl
    MergeInto(totals, row)

    if row.total >= MIN_TOTAL_FOR_RATIO then
      local combatRatio = row.combat / row.total
      local lazyRatio = (row.afk + row.idle) / row.total
      if combatRatio > busiestRatio then busiestRatio, busiestLevel = combatRatio, lvl end
      if lazyRatio > laziestRatio then laziestRatio, laziestLevel = lazyRatio, lvl end
      avg.n = avg.n + 1
      avg.combat = avg.combat + combatRatio
      avg.kph = avg.kph + ns.PerHour(row, "kills")
      avg.xph = avg.xph + ns.PerHour(row, "xp")
      avg.gph = avg.gph + ns.PerHour(row, "gold", 10000)
    end
  end
  if avg.n > 0 then
    avg.combat, avg.kph = avg.combat / avg.n, avg.kph / avg.n
    avg.xph, avg.gph = avg.xph / avg.n, avg.gph / avg.n
  end
  table.sort(levels)

  return {
    source = source,
    startLevel = startLevel,
    rows = rows,
    totals = totals,
    levels = levels,
    avg = avg,
    busiestLevel = busiestLevel,
    busiestRatio = busiestRatio,
    laziestLevel = laziestLevel,
    laziestRatio = laziestRatio,
  }
end

-- Zone list for a row (or the aggregate totals), biggest first.
function ns.SortedZones(zones, limit)
  local list = {}
  for name, secs in pairs(zones or {}) do list[#list + 1] = { name = name, secs = secs } end
  table.sort(list, function(a, b) return a.secs > b.secs end)
  if limit then
    for i = #list, limit + 1, -1 do list[i] = nil end
  end
  return list
end

-- View sources: this character, other known characters, and "All characters".
function ns.GetSources()
  local list = { { id = nil, label = "This character" } }
  local a = ChronologAccountDB
  if a and a.chars then
    local me, keys = ns.CharKey(), {}
    for k in pairs(a.chars) do if k ~= me then keys[#keys + 1] = k end end
    table.sort(keys)
    for _, k in ipairs(keys) do
      list[#list + 1] = { id = k, label = a.chars[k].name or k }
    end
    if #keys > 0 then list[#list + 1] = { id = "ALL", label = "All characters" } end
  end
  return list
end

--------------------------------------------------------------------------------
-- Debug
--------------------------------------------------------------------------------
local function Dbg(label, v)
  local s
  if IsSecret(v) then s = "|cffff5555<secret>|r" else s = tostring(v) end
  print("  |cffffff00" .. label .. "|r " .. s)
end

local function PrintDebug()
  print("|cff66ccffChronolog-Forever|r debug (build " .. tostring((select(4, GetBuildInfo()))) .. "):")
  Dbg("tick bucket:", state.bucket)
  Dbg("level:", state.currentLevel)
  Dbg("shapeshift form id:", GetShapeshiftFormID and GetShapeshiftFormID())
  Dbg("speed:", GetUnitSpeed("player"))
  Dbg("mounted:", IsMounted())
  Dbg("on taxi:", UnitOnTaxi("player"))
  Dbg("in combat (flag):", UnitAffectingCombat("player"))
  Dbg("in combat (event):", state.inCombat)
  Dbg("dead/ghost:", UnitIsDeadOrGhost("player"))
  Dbg("afk:", UnitIsAFK("player"))
  Dbg("grouped:", IsInGroup())
  Dbg("zone:", GetRealZoneText())
  Dbg("xp / max:", tostring(UnitXP("player")) .. " / " .. tostring(UnitXPMax("player")))
  Dbg("money:", GetMoney())
  Dbg("professions window open:", ProfessionsFrame and ProfessionsFrame:IsShown() or false)
  Dbg("kill method:", state.currentLevel < MAX_LEVEL and "XP chat line" or "target death (max level)")
  Dbg("kill pattern:", KILL_XP_PATTERN)
  Dbg("last XP chat line:", state.lastXPMsg or "(none yet)")
  Dbg("tracked targets:", trackedCount)
end

--------------------------------------------------------------------------------
-- Slash command
--------------------------------------------------------------------------------
local TAG = "|cff66ccffChronolog-Forever|r"

local function WidgetCommand(rest)
  local sub, arg = rest:match("^(%S*)%s*(.-)$")
  if sub == "" then
    if ns.ToggleWidget then ns.ToggleWidget() end
  elseif sub == "scale" or sub == "alpha" then
    local v = tonumber(arg)
    if not v then print(TAG .. ": usage /chrono widget " .. sub .. " <number>") return end
    if ns.SetWidgetOption then ns.SetWidgetOption(sub, v) end
  elseif sub == "stat" then
    if not (ns.ToggleWidgetStat and ns.ToggleWidgetStat(arg)) then
      local keys = {}
      for _, s in ipairs(ns.STATS) do keys[#keys + 1] = s.key end
      print(TAG .. ": unknown stat. Choose from: " .. table.concat(keys, ", "))
    end
  else
    print(TAG .. ": /chrono widget [scale <n> | alpha <n> | stat <name>]")
  end
end

SLASH_CHRONOLOG1 = "/chronolog"
SLASH_CHRONOLOG2 = "/chrono"
SlashCmdList["CHRONOLOG"] = function(msg)
  msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  local cmd, rest = msg:match("^(%S*)%s*(.-)$")

  if cmd == "help" or cmd == "?" then
    print(TAG .. " commands:")
    print("  |cffffff00/chrono|r - toggle the main window")
    print("  |cffffff00/chrono widget|r - toggle the current-level widget")
    print("  |cffffff00/chrono widget scale <n>|r / |cffffff00alpha <n>|r / |cffffff00stat <name>|r - widget options")
    print("  |cffffff00/chrono minimap|r - show/hide the minimap button")
    print("  |cffffff00/chrono export|r - copy your data as CSV")
    print("  |cffffff00/chrono options|r - open the EllesmereUI settings page")
    print("  |cffffff00/chrono debug|r - print tracking diagnostics")
    print("  |cffffff00/chrono reset|r - erase all tracked data (asks to confirm)")
  elseif cmd == "reset" and rest == "yes" then
    ns.ResetData()
    print(TAG .. ": data reset. Now tracking from level " .. (UnitLevel("player") or "?") .. ".")
  elseif cmd == "reset" then
    print(TAG .. ": this will erase all tracked data. Type |cffffff00/chrono reset yes|r to confirm.")
  elseif cmd == "widget" then
    WidgetCommand(rest)
  elseif cmd == "minimap" then
    if ns.ToggleMinimapButton then ns.ToggleMinimapButton() end
  elseif cmd == "export" then
    if ns.ShowExport then ns.ShowExport() end
  elseif cmd == "options" or cmd == "settings" then
    if EllesmereUI and EllesmereUI.OpenPlugin and EllesmereUI.IsPluginRegistered
       and EllesmereUI.IsPluginRegistered(addonName) then
      EllesmereUI.OpenPlugin(addonName)
    else
      print(TAG .. ": settings need EllesmereUI. Use the slash commands instead (/chrono help).")
    end
  elseif cmd == "debug" then
    PrintDebug()
  else
    if ns.ToggleWindow then ns.ToggleWindow() end
  end
end
