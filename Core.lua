--[[
  Chronolog-Forever - Core
  ------------------------
  Tracks, per character level (WoW Forever / Midnight client):
    * combat / travel / afk / dead / other - mutually exclusive time buckets that
      always add up to `total` (measured online time)
    * idle      - the part of "other" spent standing still
    * grouped, crafting - overlapping counters (not exclusive with the above)
    * loading   - time in loading screens (NOT part of `total`)
    * world / town / instance / pvp - where the time was spent (exclusive,
      add up to `total` for data recorded since v1.2)
    * untracked - time at a level from before tracking started (from /played)
    * lost      - time from an unsaved session (crash etc.), recovered at the
      next login; recKills/recQuests/recDeaths are the recovered counts
      (already included in kills/quests/deaths). See Recovery.lua.
    * kills, quests, dungeons, deaths, xp, gold, spent
    * flight, flights, flightCost - time on flight paths (part of travel), the
      number of flights and what they cost in copper (part of spent)
    * zones     - seconds spent per zone; subzones[zone][subzone] likewise
    * factions  - net reputation change per faction name (see Reputation.lua)
  Per character (not per level): heat - a position grid per zone map, see Heat.lua.

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

-- Shapeshift form IDs that act as mounts: Travel, Aquatic and Ghost Wolf.
-- (No flight forms: Forever has no flying.)
local TRAVEL_FORMS = { [3] = true, [4] = true, [16] = true }

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
  locKind = nil,   -- "instance" / "pvp" while inside one, else nil
  active = 0,      -- non-AFK seconds this session (for the XP rate)
  sessionXP = 0,   -- XP gained this session
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
  "world", "town", "instance", "pvp", "untracked",
  "lost", "recKills", "recQuests", "recDeaths",
  "flight", "flights", "flightCost",
}
ns.NUM_FIELDS = NUM_FIELDS

local function NewRow()
  local row = { zones = {}, subzones = {}, factions = {} }
  for _, f in ipairs(NUM_FIELDS) do row[f] = 0 end
  return row
end

-- Backfill fields added in later versions onto an existing row.
local function MigrateRow(row)
  for _, f in ipairs(NUM_FIELDS) do
    if row[f] == nil then row[f] = 0 end
  end
  if type(row.zones) ~= "table" then row.zones = {} end
  if type(row.subzones) ~= "table" then row.subzones = {} end
  if type(row.factions) ~= "table" then row.factions = {} end
end

-- The realm name. On Forever GetRealmName() can return "" (e.g. at logout),
-- which used to file a second, stale copy of the character under "Name-".
-- Remember the last good value and use it when the client returns nothing.
local cachedRealm
local function RealmName()
  local r = Clean(GetRealmName())
  if (not r or r == "") and GetNormalizedRealmName then r = Clean(GetNormalizedRealmName()) end
  if type(r) == "string" and r ~= "" then
    cachedRealm = r
    if ChronologForeverDB then ChronologForeverDB.realm = r end
    return r
  end
  return cachedRealm or (ChronologForeverDB and ChronologForeverDB.realm) or ""
end
ns.RealmName = RealmName

function ns.CharKey()
  return (UnitName("player") or "?") .. "-" .. RealmName()
end

-- The name as the game shows it. Characters on Forever have a surname
-- ("Positive Rolemodel"); addons only see it as part of the name-with-title
-- (UnitPVPName). nil when the client hasn't got it (e.g. during logout).
local function FullName()
  local base = Clean(UnitName("player"))
  local shown = UnitPVPName and Clean(UnitPVPName("player"))
  if type(base) ~= "string" or type(shown) ~= "string" or shown == "" then return nil end
  if shown ~= base and shown:find(base, 1, true) then return shown end
  return base
end
ns.FullName = FullName

-- Display name for an account entry: the full name if we've seen it.
function ns.DisplayName(entry)
  if type(entry) ~= "table" then return nil end
  return entry.fullName or entry.name
end

-- Is this account entry (another key) actually the current character?
function ns.IsCurrentCharEntry(entry)
  if type(entry) ~= "table" then return false end
  local guid = UnitGUID("player")
  if entry.guid and guid then return entry.guid == guid end
  local _, class = UnitClass("player")
  local realm = RealmName()
  return entry.name == UnitName("player") and (entry.class == nil or entry.class == class)
    and (entry.realm == nil or entry.realm == "" or realm == "" or entry.realm == realm)
end

-- Fold duplicate entries of the same character (saved under "Name-" when the
-- realm came back empty) into one, keeping the most recently updated data.
local function DedupeAccount(a)
  local byName = {}
  for key, c in pairs(a.chars) do
    if type(c) == "table" and c.name then
      local id = c.name .. "|" .. (c.class or "?")
      byName[id] = byName[id] or {}
      table.insert(byName[id], key)
    end
  end
  for _, keys in pairs(byName) do
    if #keys > 1 then
      -- Only merge a blank-realm entry into a single realm-named one; two
      -- different realms are different characters.
      local named, blank = {}, {}
      for _, k in ipairs(keys) do
        local c = a.chars[k]
        if c.realm == nil or c.realm == "" then blank[#blank + 1] = k else named[#named + 1] = k end
      end
      if #named == 1 and #blank > 0 then
        local target = a.chars[named[1]]
        for _, k in ipairs(blank) do
          local c = a.chars[k]
          if (c.updated or 0) > (target.updated or 0) then
            c.realm, c.key = target.realm, nil
            a.chars[named[1]] = c
            target = c
          end
          a.chars[k] = nil
        end
      end
    end
  end
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
  if type(db.heat) ~= "table" then db.heat = {} end
  db.version = 4
  if type(db.options) ~= "table" then db.options = {} end
  if db.options.readPlayed == nil then db.options.readPlayed = true end
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
  local key = ns.CharKey()
  -- Drop any other entry that is really this character (stale copies would
  -- otherwise race against us in pace comparisons).
  for k, c in pairs(a.chars) do
    if k ~= key and ns.IsCurrentCharEntry(c) then a.chars[k] = nil end
  end
  DedupeAccount(a)
  local prev = a.chars[key]
  a.chars[key] = {
    name = UnitName("player"),
    fullName = FullName() or (prev and prev.fullName),
    realm = RealmName(),
    guid = UnitGUID("player"),
    class = db.class,
    startLevel = db.startLevel,
    level = state.currentLevel or UnitLevel("player"),
    levels = db.levels,
    heat = db.heat,
    updated = time(),
  }
end

-- Wipe all data and re-seed from the current level. Settings are kept.
function ns.ResetData()
  local old = ChronologForeverDB
  local keep = {}
  for _, k in ipairs({ "widget", "window", "minimap", "options", "paceRef", "chartMode", "repPrimary", "heatmap" }) do
    keep[k] = old and old[k]
  end
  ChronologForeverDB = nil
  local db = EnsureDB()
  for k, v in pairs(keep) do db[k] = v end
  InitLevels(db)
  SyncAccount()
  state.currentLevel = UnitLevel("player") or 1
  if ns.Refresh then ns.Refresh() end
  if ns.RefreshWidget then ns.RefreshWidget() end
end

--------------------------------------------------------------------------------
-- Removing another character
--   Deletes the character's account-wide copy: its levels, zones, reputation
--   and heatmap data, from every view, pace comparison and the heatmap. The
--   character you're logged in on can't be removed (use /chrono reset). If a
--   removed character is logged in again, it starts showing up again with
--   whatever its own saved data still holds.
--------------------------------------------------------------------------------
function ns.RemoveCharacter(key)
  local a = ChronologAccountDB
  local entry = a and a.chars and a.chars[key]
  if not entry or key == ns.CharKey() or ns.IsCurrentCharEntry(entry) then return false end
  a.chars[key] = nil
  if ns.viewSource == key then ns.viewSource = nil end
  local db = ChronologForeverDB
  if db and db.paceRef == key then db.paceRef = nil end
  if ns.Refresh then ns.Refresh() end
  if ns.RefreshWidget then ns.RefreshWidget() end
  if ns.RedrawHeatmap then pcall(ns.RedrawHeatmap) end
  return true
end

-- Other characters that can be removed: { {key, label} }, sorted by name.
function ns.RemovableCharacters()
  local list = {}
  local a = ChronologAccountDB
  for key, c in pairs(a and a.chars or {}) do
    if key ~= ns.CharKey() and not ns.IsCurrentCharEntry(c) then
      list[#list + 1] = { key = key, label = ns.DisplayName(c) or key }
    end
  end
  table.sort(list, function(x, y) return x.label < y.label end)
  return list
end

if StaticPopupDialogs then
  StaticPopupDialogs["CHRONOLOG_FOREVER_REMOVE_CHAR"] = {
    text = "Remove %s from Chronolog?\n\nAll of this character's tracked data (levels, zones, reputation, heatmap) is deleted. This can't be undone.",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function(self, data)
      local key = data or (self and self.data)
      if key and ns.RemoveCharacter(key) then
        print("|cff66ccffChronolog-Forever|r: removed " .. tostring(key) .. ".")
      end
    end,
    showAlert = true,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
  }
end

-- Ask before removing a character (key from RemovableCharacters).
function ns.ConfirmRemoveCharacter(key)
  local a = ChronologAccountDB
  local entry = a and a.chars and a.chars[key]
  if not entry or not StaticPopup_Show then return end
  StaticPopup_Show("CHRONOLOG_FOREVER_REMOVE_CHAR", ns.DisplayName(entry) or key, nil, key)
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

-- copper -> "12g 34s 56c" with the coin colors (or the game's coin icons).
-- Leading zero units are left out: "34s 56c", "56c".
function ns.FormatCoins(copper)
  copper = floor((copper or 0) + 0.5)
  if GetCoinTextureString then
    local ok, s = pcall(GetCoinTextureString, copper)
    if ok and type(s) == "string" and s ~= "" then return s end
  end
  local g, sv, c = floor(copper / 10000), floor((copper % 10000) / 100), copper % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = "|cffffd700" .. g .. "g|r" end
  if g > 0 or sv > 0 then parts[#parts + 1] = "|cffc7c7cf" .. sv .. "s|r" end
  parts[#parts + 1] = "|cffeda55f" .. c .. "c|r"
  return table.concat(parts, " ")
end

-- Short money label for charts: "1.2g", "85s", "40c".
function ns.ShortCoins(copper)
  copper = copper or 0
  if copper >= 10000 then
    local g = copper / 10000
    return (g >= 10 and string.format("%dg", floor(g + 0.5))) or string.format("%.1fg", g)
  end
  if copper >= 100 then return string.format("%ds", floor(copper / 100 + 0.5)) end
  return string.format("%dc", floor(copper + 0.5))
end

-- `field` per hour of tracked time (0 until the level has enough data).
function ns.PerHour(row, field, divisor)
  if (row.total or 0) < MIN_TOTAL_FOR_RATIO then return 0 end
  return (row[field] or 0) / (divisor or 1) / (row.total / 3600)
end

-- Signed duration: "-4m 10s" / "+12m 03s" (negative = faster / ahead).
function ns.FormatDelta(sec)
  sec = sec or 0
  local sign = sec < 0 and "-" or "+"
  return sign .. ns.FormatTime(math.abs(sec))
end

-- Short axis label for a duration: "45m", "1.5h", "12h".
function ns.FormatShortTime(sec)
  sec = sec or 0
  if math.abs(sec) >= 3600 then
    local h = sec / 3600
    if math.abs(h) >= 10 or h == floor(h) then return string.format("%dh", floor(h + 0.5)) end
    return string.format("%.1fh", h)
  end
  return string.format("%dm", floor(sec / 60 + 0.5))
end

-- Time actually spent at a level: tracked time plus any time from before
-- tracking started (learned from /played).
function ns.LevelTime(row)
  return (row.total or 0) + (row.untracked or 0) + (row.lost or 0)
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
  { key = "flight",   label = "Flying",   get = function(r) return ns.FormatTime(r.flight) end },
  { key = "rep",      label = "Rep",      get = function(r) return ns.FormatNumber(ns.RepGained and ns.RepGained(r) or 0) end },
  { key = "eta",      label = "Next lvl", get = function()
      local t = ns.GetETA and ns.GetETA()
      return t and ns.FormatTime(t) or "-"
    end },
  { key = "pace",     label = "Pace",     get = function()
      local p = ns.GetPace and ns.GetPace()
      if not p or p.n == 0 then return "-" end
      return (p.cum <= 0 and "|cff4cd964" or "|cffff5f57") .. ns.FormatDelta(p.cum) .. "|r"
    end },
}

--------------------------------------------------------------------------------
-- Recent XP rate (for the level ETA): XP per non-AFK hour over the last
-- 30 minutes of play this session, falling back to this level's average.
--------------------------------------------------------------------------------
local RATE_WINDOW = 1800
local RATE_STEP = 30
local MIN_RATE_SPAN = 120
local rateSamples = {}
ns.rateSamples = rateSamples -- carried across /reload by Recovery.lua

local function SampleRate()
  local last = rateSamples[#rateSamples]
  if last and state.active - last.a < RATE_STEP then return end
  rateSamples[#rateSamples + 1] = { a = state.active, x = state.sessionXP }
  while #rateSamples > 1 and state.active - rateSamples[2].a >= RATE_WINDOW do
    table.remove(rateSamples, 1)
  end
end

-- XP per hour and where it came from ("recent" or "level"), or nil.
function ns.GetXPRate()
  local first = rateSamples[1]
  if first then
    local span = state.active - first.a
    local gained = state.sessionXP - first.x
    if span >= MIN_RATE_SPAN and gained > 0 then
      return gained / span * 3600, "recent"
    end
  end
  local db = ChronologForeverDB
  if db and db.levels[state.currentLevel] then
    local row = db.levels[state.currentLevel]
    if (row.total or 0) >= 300 and (row.xp or 0) > 0 then
      return row.xp / row.total * 3600, "level"
    end
  end
  return nil
end

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
  local t0 = debugprofilestop and debugprofilestop()

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
  local resting = Clean(IsResting())
  local zone = Clean(GetRealZoneText())
  if not zone or zone == "" then zone = Clean(GetZoneText()) end
  if not zone or zone == "" then zone = "Unknown" end
  local subzone = Clean(GetSubZoneText()) or ""
  -- Standing still on a boat, zeppelin or tram (set by the position sampler
  -- in Heat.lua: the map position moves while our own speed is 0).
  local onTransport = state.onTransport and moving == false
  state.lastMoving, state.lastOnTaxi = moving, onTaxi
  -- Took off on a flight path (not counted again after a /reload mid-flight;
  -- the login handler seeds wasOnTaxi).
  if onTaxi ~= nil then
    if onTaxi and not state.wasOnTaxi and ns.OnFlightStart then ns.OnFlightStart() end
    state.wasOnTaxi = onTaxi and true or false
  end

  local row = GetRow(db, state.currentLevel)
  row.total = row.total + dt

  if dead then
    -- Dead or running back as a ghost.
    row.dead = row.dead + dt
    state.bucket = "dead"
  elseif onTaxi or onTransport or (mounted and moving ~= false) then
    -- Travel takes priority over combat: on a flight path, or mounted (or in
    -- a travel form) AND actually moving, is counted as travel even if the
    -- combat flag is set. Sitting still on a mount is not travel; it falls
    -- through below. If the speed is unknown (secret), a mounted player is
    -- assumed to be moving.
    row.travel = row.travel + dt
    if onTaxi then row.flight = row.flight + dt end
    state.bucket = onTaxi and "travel (flight path)"
      or onTransport and "travel (boat/zeppelin/tram)" or "travel (mount/form)"
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
  local subs = row.subzones[zone]
  if not subs then
    subs = {}
    row.subzones[zone] = subs
  end
  subs[subzone] = (subs[subzone] or 0) + dt

  -- Where: dungeon/raid > battleground/arena > town (rested area) > world.
  local where = state.locKind or (resting and "town") or "world"
  row[where] = row[where] + dt

  if not afk then
    state.active = state.active + dt
    SampleRate()
  end

  -- Position heatmap (samples once a second; AFK time isn't mapped).
  if ns.HeatTick then ns.HeatTick(dt, state.bucket, state.currentLevel) end

  -- Average cost of a tick, for /chrono debug.
  if t0 then
    local cost = debugprofilestop() - t0
    state.tickCost = state.tickCost and (state.tickCost * 0.98 + cost * 0.02) or cost
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
  if inInstance and (instanceType == "party" or instanceType == "raid" or instanceType == "scenario") then
    state.locKind = "instance"
  elseif inInstance and (instanceType == "pvp" or instanceType == "arena") then
    state.locKind = "pvp"
  else
    state.locKind = nil
  end
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
local FLIGHT_PICK_WINDOW = 15 -- seconds from clicking a destination to takeoff
local FLIGHT_SPEND_WINDOW = 5 -- seconds between paying and takeoff (fallback)
local AddFlightCost -- defined with the flight-path code below

local function OnXP()
  local xp, xpMax = Clean(UnitXP("player")), Clean(UnitXPMax("player"))
  if not xp or not xpMax or xpMax <= 0 then return end -- not loaded / logging out
  local last = state.lastXP
  if last then
    local gained = xp - last
    if gained < 0 then gained = (state.lastXPMax or 0) - last + xp end -- leveled up
    local db = ChronologForeverDB
    if gained > 0 and db then
      local row = GetRow(db, state.currentLevel)
      row.xp = row.xp + gained
      state.sessionXP = state.sessionXP + gained
    end
    -- Remember the XP needed for this level (used to estimate time to 60).
    -- Skipped on the update that crosses a level, when the level may not
    -- have switched yet.
    if db and xp >= last then GetRow(db, state.currentLevel).xpMax = xpMax end
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
  if m > last then
    row.gold = row.gold + (m - last)
  else
    local amount = last - m
    row.spent = row.spent + amount
    local now = GetTime()
    if state.flightAwaitCost and now - state.flightAwaitCost <= FLIGHT_SPEND_WINDOW then
      state.flightAwaitCost = nil
      AddFlightCost(amount)
    else
      state.lastSpend = { amount = amount, at = now }
    end
  end
end

--------------------------------------------------------------------------------
-- Flight paths
--   The price comes from the destination you click (TakeTaxiNode ->
--   TaxiNodeCost). If that isn't available, the gold that left your bags just
--   before (or just after) takeoff is used.
--------------------------------------------------------------------------------
function AddFlightCost(amount)
  local db = ChronologForeverDB
  if not db or not amount or amount < 0 then return end
  local row = GetRow(db, state.currentLevel)
  row.flightCost = row.flightCost + amount
end

function ns.OnFlightStart()
  local db = ChronologForeverDB
  if not db then return end
  local row = GetRow(db, state.currentLevel)
  row.flights = row.flights + 1
  local now = GetTime()
  local pick, spend = state.pendingFlight, state.lastSpend
  state.pendingFlight, state.lastSpend = nil, nil
  if pick and pick.cost and now - pick.at <= FLIGHT_PICK_WINDOW then
    AddFlightCost(pick.cost)
  elseif spend and now - spend.at <= FLIGHT_SPEND_WINDOW then
    AddFlightCost(spend.amount)
  else
    state.flightAwaitCost = now -- the money may leave just after takeoff
  end
  if ns.Refresh then ns.Refresh() end
end

if type(TakeTaxiNode) == "function" then
  hooksecurefunc("TakeTaxiNode", function(index)
    local cost = TaxiNodeCost and Clean(TaxiNodeCost(index))
    state.pendingFlight = { at = GetTime(), cost = type(cost) == "number" and cost or nil }
  end)
end

--------------------------------------------------------------------------------
-- /played backfill: the client reports how long you've been at the current
-- level, including time from before Chronolog-Forever was installed (or while
-- it was disabled). The missing part is stored as `untracked` so per-level
-- times and pace comparisons are complete. The chat frames are muted for our
-- own request so the "Total time played" lines don't show up at every login.
--------------------------------------------------------------------------------
local mutedChat = {}
local playedPending = false

local function UnmuteChat()
  for _, cf in ipairs(mutedChat) do cf:RegisterEvent("TIME_PLAYED_MSG") end
  wipe(mutedChat)
end

local function RequestPlayed()
  if not RequestTimePlayed or playedPending then return end
  playedPending = true
  for i = 1, (NUM_CHAT_WINDOWS or 10) do
    local cf = _G["ChatFrame" .. i]
    if cf and cf.IsEventRegistered and cf:IsEventRegistered("TIME_PLAYED_MSG") then
      cf:UnregisterEvent("TIME_PLAYED_MSG")
      mutedChat[#mutedChat + 1] = cf
    end
  end
  RequestTimePlayed()
  -- Never leave chat muted if the reply doesn't come.
  if C_Timer then
    C_Timer.After(10, function() playedPending = false; UnmuteChat() end)
  end
end

local function OnTimePlayed(totalTime, levelTime)
  playedPending = false
  UnmuteChat()
  totalTime, levelTime = Clean(totalTime), Clean(levelTime)
  local db = ChronologForeverDB
  if not db or type(levelTime) ~= "number" then return end
  db.playedTotal = totalTime
  if type(totalTime) == "number" then
    state.playedBase, state.playedBaseAt = totalTime, GetTime()
  end

  -- First reply this session: put back anything an unsaved session (crash,
  -- killed client, addon disabled) did since the last save. See Recovery.lua.
  if not state.recoveryChecked then
    state.recoveryChecked = true
    if ns.RecoverUnsaved then ns.RecoverUnsaved(totalTime, levelTime) end
  end

  -- Whatever is still missing at this level is from before tracking started.
  -- /played includes loading screens, so those count as covered too.
  local row = GetRow(db, state.currentLevel)
  local missing = levelTime - (row.total + row.lost + row.loading)
  -- Small differences are just timing noise between the client and our ticker.
  if missing > 30 and missing > (row.untracked or 0) then
    row.untracked = missing
  end
  row.full = true -- this level's time is now complete from the start
  if ns.Refresh then ns.Refresh() end
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
ev:RegisterEvent("TIME_PLAYED_MSG")
ev:RegisterEvent("UNIT_NAME_UPDATE")

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
    state.currentLevel = UnitLevel("player") or 1
    state.sessionStart = GetTime()
    InitLevels(db)
    SyncAccount()
    state.inCombat = UnitAffectingCombat("player") and true or false
    state.lastXP, state.lastXPMax = Clean(UnitXP("player")), Clean(UnitXPMax("player"))
    -- An XP bar of size 0 means the client hasn't got the real values yet
    -- (Forever reports 0 around logout); treat it as unknown so the first real
    -- update only sets the baseline instead of counting the whole bar as gained.
    if not state.lastXPMax or state.lastXPMax <= 0 then
      state.lastXP, state.lastXPMax = nil, nil
    elseif state.currentLevel < MAX_LEVEL then
      GetRow(db, state.currentLevel).xpMax = state.lastXPMax
    end
    -- Same for gold: 0 is indistinguishable from "not loaded yet".
    local money = Clean(GetMoney())
    state.lastMoney = (money and money > 0) and money or nil
    -- Already on a flight (e.g. /reload mid-flight): not a new one.
    state.wasOnTaxi = Clean(UnitOnTaxi("player")) and true or false
    state.ready = true
    UpdateInstanceState()
    if db.options.readPlayed then
      if C_Timer then C_Timer.After(3, RequestPlayed) else RequestPlayed() end
    end

  elseif event == "TIME_PLAYED_MSG" then
    if state.ready then OnTimePlayed(...) end

  elseif event == "UNIT_NAME_UPDATE" then
    -- The name/title (Forever surname) can arrive or change after login.
    if state.ready and (...) == "player" then
      local full = FullName()
      local entry = ChronologAccountDB and ChronologAccountDB.chars and ChronologAccountDB.chars[ns.CharKey()]
      if full and entry and entry.fullName ~= full then
        entry.fullName = full
        if ns.Refresh then ns.Refresh() end
      end
    end

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
    GetRow(db, newLevel).full = true -- tracked from the moment it started
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
  for zone, subs in pairs(src.subzones or {}) do
    local d = dst.subzones[zone]
    if not d then
      d = {}
      dst.subzones[zone] = d
    end
    for sub, secs in pairs(subs) do d[sub] = (d[sub] or 0) + secs end
  end
  for name, v in pairs(src.factions or {}) do
    dst.factions[name] = (dst.factions[name] or 0) + v
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
      list[#list + 1] = { id = k, label = ns.DisplayName(a.chars[k]) or k }
    end
    if #keys > 0 then list[#list + 1] = { id = "ALL", label = "All characters" } end
  end
  return list
end

--------------------------------------------------------------------------------
-- Debug
--------------------------------------------------------------------------------
-- A raw API value as text; secrets (which can't be tostring'd) show as <secret>.
local function DbgStr(v)
  if IsSecret(v) then return "|cffff5555<secret>|r" end
  return tostring(v)
end

local function Dbg(label, v)
  print("  |cffffff00" .. label .. "|r " .. DbgStr(v))
end

local function PrintDebug()
  print("|cff66ccffChronolog-Forever|r debug (build " .. tostring((select(4, GetBuildInfo()))) .. "):")
  Dbg("tick bucket:", state.bucket)
  Dbg("level:", state.currentLevel)
  Dbg("name / shown as:", DbgStr(UnitName("player")) .. " / " .. DbgStr(UnitPVPName and UnitPVPName("player")))
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
  Dbg("xp / max:", DbgStr(UnitXP("player")) .. " / " .. DbgStr(UnitXPMax("player")))
  Dbg("money:", GetMoney())
  Dbg("professions window open:", ProfessionsFrame and ProfessionsFrame:IsShown() or false)
  Dbg("kill method:", state.currentLevel < MAX_LEVEL and "XP chat line" or "target death (max level)")
  Dbg("kill pattern:", KILL_XP_PATTERN)
  Dbg("last XP chat line:", state.lastXPMsg or "(none yet)")
  Dbg("tracked targets:", trackedCount)
  Dbg("unsaved for:", state.sessionStart and ns.FormatTime(GetTime() - state.sessionStart) or "?")
  local cp = ChronologForeverDB and ChronologForeverDB.checkpoint
  Dbg("last save checkpoint:", cp and string.format("level %s, played %s, %s",
    tostring(cp.level), cp.played and ns.FormatTime(cp.played) or "?",
    cp.stats and cp.stats.kills and "statistics available" or "no statistics") or "(none yet)")
  if ns.RepDebug then ns.RepDebug(Dbg) end
  if ns.HeatDebug then ns.HeatDebug(Dbg) end
  Dbg("avg tick cost:", state.tickCost and string.format("%.3f ms (5 ticks/s)", state.tickCost) or "?")
  Dbg("XP rate window:", string.format("%d samples, %s active", #rateSamples, ns.FormatTime(state.active)))
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
    print("  |cffffff00/chrono pace|r - change what your level times are compared against")
    print("  |cffffff00/chrono heatmap|r - show/hide the heatmap on the world map")
    print("  |cffffff00/chrono minimap|r - show/hide the minimap button")
    print("  |cffffff00/chrono export|r - copy your data as CSV")
    print("  |cffffff00/chrono remove <name>|r - delete another character's data (asks to confirm)")
    print("  |cffffff00/chrono options|r - open the settings")
    print("  |cffffff00/chrono debug|r - print tracking diagnostics")
    print("  |cffffff00/chrono reset|r - erase all tracked data (asks to confirm)")
  elseif cmd == "reset" and rest == "yes" then
    ns.ResetData()
    print(TAG .. ": data reset. Now tracking from level " .. (UnitLevel("player") or "?") .. ".")
  elseif cmd == "reset" then
    print(TAG .. ": this will erase all tracked data. Type |cffffff00/chrono reset yes|r to confirm.")
  elseif cmd == "widget" then
    WidgetCommand(rest)
  elseif cmd == "heatmap" or cmd == "map" then
    if ns.ToggleHeatmap then
      local shown = ns.ToggleHeatmap()
      print(TAG .. ": world map heatmap " .. (shown and "on" or "off") .. ". Open your map (M) to see it.")
    end
  elseif cmd == "pace" then
    if ns.CyclePaceRefCommand then ns.CyclePaceRefCommand() end
  elseif cmd == "minimap" then
    if ns.ToggleMinimapButton then ns.ToggleMinimapButton() end
  elseif cmd == "remove" or cmd == "delete" then
    local list = ns.RemovableCharacters()
    if #list == 0 then
      print(TAG .. ": no other characters to remove.")
      return
    end
    local match
    if rest ~= "" then
      for _, c in ipairs(list) do
        local a = ChronologAccountDB.chars[c.key]
        if rest == c.label:lower() or rest == c.key:lower() or rest == (a.name or ""):lower() then match = c end
      end
    end
    if match then
      ns.ConfirmRemoveCharacter(match.key)
    else
      local names = {}
      for _, c in ipairs(list) do names[#names + 1] = c.label end
      print(TAG .. ": /chrono remove <name> - one of: " .. table.concat(names, ", "))
    end
  elseif cmd == "export" then
    if ns.ShowExport then ns.ShowExport() end
  elseif cmd == "options" or cmd == "settings" then
    if ns.OpenSettings then ns.OpenSettings() end
  elseif cmd == "debug" then
    PrintDebug()
  else
    if ns.ToggleWindow then ns.ToggleWindow() end
  end
end
