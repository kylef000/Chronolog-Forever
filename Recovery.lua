--[[
  Chronolog-Forever - Recovery
  ----------------------------
  The game only writes addon data to disk when the UI unloads (logout, /reload,
  quitting, disconnect). A crash or killed client loses everything since the
  last save. This module limits that damage:

  * Checkpoint: at every save (PLAYER_LOGOUT) we store the game's own counters,
    which survive a crash: /played, level, XP, gold, and the achievement
    statistics for kills, quests and deaths. The checkpoint is saved in the
    same file as the data, so the two always match.
  * Recovery: on the next login the live counters are compared with the
    checkpoint. The difference is what the unsaved session did; it is put back
    on the right levels. Time goes into `lost` (shown as "Not recorded", since
    the game can't tell us what you were doing). If you levelled during the
    lost session, its time is split across those levels by XP and they are
    marked `estimated` (left out of pace comparisons).
  * /reload is free: the XP-rate window survives a reload, so the ETA doesn't
    reset.
  * Optional save prompt after each level-up (off by default).
]]

local addonName, ns = ...

local MAX_LEVEL = ns.MAX_LEVEL
local Clean = ns.Clean
local floor, max, min = math.floor, math.max, math.min
local TAG = "|cff66ccffChronolog-Forever|r"

-- Achievement statistics (character-wide, kept by the server).
local STAT_IDS = { kills = 1197, quests = 98, deaths = 60 }
local SESSION_MAX_GAP = 300 -- a relog within this many seconds continues the session
local NOISE = 60            -- /played vs. checkpoint differences below this are timing noise

--------------------------------------------------------------------------------
-- Reading the game's counters
--------------------------------------------------------------------------------
local function ReadStat(id)
  if type(GetStatistic) ~= "function" then return nil end
  local ok, v = pcall(GetStatistic, id)
  if not ok then return nil end
  v = Clean(v)
  if type(v) == "number" then return v end
  if type(v) ~= "string" then return nil end
  return tonumber((v:gsub("[^%d]", "")))
end

local function ReadStats()
  local out = {}
  for key, id in pairs(STAT_IDS) do out[key] = ReadStat(id) end
  return out
end

-- /played right now, if we've had a /played reply this session.
function ns.PlayedNow()
  local s = ns.state
  if not s.playedBase then return nil end
  return s.playedBase + (GetTime() - s.playedBaseAt)
end

-- Seconds since the last save (= since this session started).
function ns.UnsavedSeconds()
  local s = ns.state
  return s.sessionStart and (GetTime() - s.sessionStart) or 0
end

function ns.AddUnsavedLine(tip)
  local secs = ns.UnsavedSeconds()
  if secs >= 300 then
    tip:AddLine(" ")
    tip:AddLine("Unsaved for " .. ns.FormatTime(secs) .. " - /reload saves", 0.5, 0.5, 0.5)
  end
end

--------------------------------------------------------------------------------
-- Checkpoint (written on every save)
--------------------------------------------------------------------------------
-- Last statistics read while playing. During logout the client can hand back
-- blank or zero values (XP and gold come back as 0 on Forever), so nothing in
-- the checkpoint is read from the game at that moment unless it checks out.
local lastStats = {}

local function RefreshStats()
  for key, v in pairs(ReadStats()) do
    if v and (not lastStats[key] or v >= lastStats[key]) then lastStats[key] = v end
  end
end

local function WriteCheckpoint()
  local db = ChronologForeverDB
  local s = ns.state
  if not db or not s.ready then return end
  -- Statistics only ever go up: a missing or lower value at logout is bogus.
  local stats = ReadStats()
  for key in pairs(STAT_IDS) do
    if not stats[key] or (lastStats[key] and stats[key] < lastStats[key]) then
      stats[key] = lastStats[key]
    end
  end
  db.checkpoint = {
    at = time(),
    played = ns.PlayedNow(),
    level = s.currentLevel,
    -- XP and gold as tracked live from PLAYER_XP_UPDATE / PLAYER_MONEY.
    xp = s.lastXP,
    xpMax = s.lastXPMax,
    money = s.lastMoney,
    stats = stats,
  }
  -- Carry the XP-rate window across a /reload.
  local samples = {}
  for i, smp in ipairs(ns.rateSamples) do samples[i] = { a = smp.a, x = smp.x } end
  db.session = { at = time(), active = s.active, sessionXP = s.sessionXP, samples = samples }
end

local function RestoreSession()
  local db = ChronologForeverDB
  local sess = db and db.session
  if db then db.session = nil end
  if type(sess) ~= "table" or not sess.at or time() - sess.at > SESSION_MAX_GAP then return end
  local s = ns.state
  s.active = (sess.active or 0) + s.active
  s.sessionXP = (sess.sessionXP or 0) + s.sessionXP
  wipe(ns.rateSamples)
  for i, smp in ipairs(sess.samples or {}) do ns.rateSamples[i] = { a = smp.a, x = smp.x } end
end

--------------------------------------------------------------------------------
-- Recovery (on the first /played reply of a session)
--------------------------------------------------------------------------------
-- Split an integer total over keys by weight, keeping the exact total.
local function Allocate(total, keys, weights)
  local out = {}
  for _, k in ipairs(keys) do out[k] = 0 end
  if not total or total <= 0 or #keys == 0 then return out end
  local sum = 0
  for _, k in ipairs(keys) do sum = sum + (weights[k] or 0) end
  local function w(k) if sum > 0 then return weights[k] or 0 end return 1 end
  if sum <= 0 then sum = #keys end
  local given, rest = 0, {}
  for _, k in ipairs(keys) do
    local exact = total * w(k) / sum
    out[k] = floor(exact)
    given = given + out[k]
    rest[#rest + 1] = { k = k, f = exact - out[k] }
  end
  table.sort(rest, function(a, b) return a.f > b.f end)
  for i = 1, total - given do out[rest[i].k] = out[rest[i].k] + 1 end
  return out
end

function ns.RecoverUnsaved(totalTime, levelTime)
  local db = ChronologForeverDB
  local cp = db and db.checkpoint
  local s = ns.state
  if type(cp) ~= "table" or not cp.level then return end
  local cur, fromL = s.currentLevel, cp.level
  if cur < fromL then return end -- data doesn't belong to this character state

  local elapsed = ns.UnsavedSeconds() -- this session so far (already tracked)

  -- Lost time: /played now, minus this session, minus /played at the last save.
  local gap = 0
  local timeKnown = type(totalTime) == "number" and type(cp.played) == "number"
  if timeKnown then
    gap = totalTime - elapsed - cp.played
    if gap < NOISE then gap = 0 end
  end

  local now = ReadStats()
  for key, v in pairs(now) do lastStats[key] = v end

  -- /played is the authority: if no time went missing, no session was lost,
  -- whatever the other counters say.
  if timeKnown and gap == 0 then return end

  -- Lost counts from the server statistics.
  local lostCounts = {}
  for key in pairs(STAT_IDS) do
    local a, b = cp.stats and cp.stats[key], now[key]
    lostCounts[key] = (a and b and b > a) and (b - a) or 0
  end

  -- Lost XP per level.
  local levels = {}
  for L = fromL, cur do levels[#levels + 1] = L end
  local xpNow = Clean(UnitXP("player")) or 0
  -- A checkpoint XP is only trusted with a real XP bar size alongside it.
  local cpXP = (type(cp.xpMax) == "number" and cp.xpMax > 0) and cp.xp or nil
  local xpBy = {}
  if cur == fromL then
    xpBy[cur] = cpXP and max(0, xpNow - cpXP) or 0
  else
    xpBy[fromL] = cpXP and max(0, cp.xpMax - cpXP) or 0
    for L = fromL + 1, cur - 1 do xpBy[L] = floor(ns.XPForLevel(L) or 0) end
    xpBy[cur] = xpNow
  end
  local lostXP = 0
  for _, L in ipairs(levels) do lostXP = lostXP + (xpBy[L] or 0) end

  local money = Clean(GetMoney())
  local goldDelta = (money and cp.money) and (money - cp.money) or 0

  if gap == 0 and lostXP == 0 and goldDelta == 0
     and lostCounts.kills == 0 and lostCounts.quests == 0 and lostCounts.deaths == 0 then
    return -- nothing was lost
  end

  -- Lost time per level.
  local timeBy = {}
  local estimated = false
  if gap > 0 then
    if cur == fromL then
      timeBy[cur] = gap
    else
      -- The current level started during the lost session: /played knows
      -- exactly how long we've been at it.
      local curLost = (type(levelTime) == "number") and max(0, min(gap, levelTime - elapsed)) or 0
      timeBy[cur] = curLost
      local earlier = {}
      for L = fromL, cur - 1 do earlier[#earlier + 1] = L end
      -- One finished level gets the exact remainder; several are split by XP.
      local split = Allocate(floor(gap - curLost + 0.5), earlier, xpBy)
      for L, t in pairs(split) do timeBy[L] = t end
      estimated = #earlier > 1
    end
  end

  -- Counts follow the time (or the XP when there's no time information).
  local weights = gap > 0 and timeBy or xpBy
  local killsBy = Allocate(lostCounts.kills, levels, weights)
  local questsBy = Allocate(lostCounts.quests, levels, weights)
  local deathsBy = Allocate(lostCounts.deaths, levels, weights)

  for _, L in ipairs(levels) do
    local row = ns.GetRow(db, L)
    row.lost = row.lost + (timeBy[L] or 0)
    row.xp = row.xp + (xpBy[L] or 0)
    row.kills = row.kills + killsBy[L]
    row.quests = row.quests + questsBy[L]
    row.deaths = row.deaths + deathsBy[L]
    row.recKills = row.recKills + killsBy[L]
    row.recQuests = row.recQuests + questsBy[L]
    row.recDeaths = row.recDeaths + deathsBy[L]
    if L > fromL then row.full = true end -- started inside the lost session
    if estimated and L < cur then row.estimated = true end
  end
  local curRow = ns.GetRow(db, cur)
  if goldDelta > 0 then curRow.gold = curRow.gold + goldDelta
  elseif goldDelta < 0 then curRow.spent = curRow.spent - goldDelta end
  -- Keep the live XP/gold trackers from counting it a second time.
  s.lastXP, s.lastMoney = xpNow, money or s.lastMoney

  db.recoveries = db.recoveries or {}
  table.insert(db.recoveries, 1, {
    at = time(), from = fromL, to = cur, time = gap, xp = lostXP, gold = goldDelta,
    kills = lostCounts.kills, quests = lostCounts.quests, deaths = lostCounts.deaths,
  })
  for i = #db.recoveries, 21, -1 do db.recoveries[i] = nil end

  local parts = {}
  if gap > 0 then parts[#parts + 1] = ns.FormatTime(gap) end
  if lostCounts.kills > 0 then parts[#parts + 1] = lostCounts.kills .. " kills" end
  if lostCounts.quests > 0 then parts[#parts + 1] = lostCounts.quests .. " quests" end
  if lostXP > 0 then parts[#parts + 1] = ns.FormatNumber(lostXP) .. " XP" end
  if cur > fromL then parts[#parts + 1] = "levels " .. fromL .. "-" .. cur end
  print(TAG .. ": recovered play that wasn't saved (game closed without saving, or addon disabled): "
    .. table.concat(parts, ", ") .. ".")
end

--------------------------------------------------------------------------------
-- Optional save prompt after a level-up
--------------------------------------------------------------------------------
local promptPending = false

local function ShowSavePrompt()
  if not StaticPopup_Show then return end
  if InCombatLockdown and InCombatLockdown() then promptPending = true return end
  promptPending = false
  if ns.UnsavedSeconds() < 300 then return end
  StaticPopup_Show("CHRONOLOG_FOREVER_SAVE", ns.FormatTime(ns.UnsavedSeconds()))
end

if StaticPopupDialogs then
  StaticPopupDialogs["CHRONOLOG_FOREVER_SAVE"] = {
    text = "Chronolog-Forever: %s of tracking isn't saved yet.\n\n"
      .. "Save now? This reloads the UI (a short loading screen).",
    button1 = "Save now",
    button2 = "Not now",
    OnAccept = function() ReloadUI() end,
    timeout = 30,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
  }
end

--------------------------------------------------------------------------------
-- One-time repair (v1.3.1): checkpoints written by v1.3 read XP and gold at
-- logout, where Forever returns 0, so every normal logout "recovered" the
-- whole XP bar and gold balance at the next login. Those entries have no lost
-- time, which a real lost session always has; undo them.
--------------------------------------------------------------------------------
local function RepairZeroCheckpointRecoveries()
  local db = ChronologForeverDB
  if not db or db.repairedZeroCheckpoint then return end
  db.repairedZeroCheckpoint = true
  local undone = 0
  for _, rec in ipairs(db.recoveries or {}) do
    if (rec.time or 0) == 0 and not rec.reverted and rec.from and rec.from == rec.to then
      local row = ns.GetRow(db, rec.from)
      row.xp = max(0, row.xp - (rec.xp or 0))
      local g = rec.gold or 0
      if g > 0 then row.gold = max(0, row.gold - g) elseif g < 0 then row.spent = max(0, row.spent + g) end
      for field, recField in pairs({ kills = "recKills", quests = "recQuests", deaths = "recDeaths" }) do
        local n = rec[field] or 0
        row[field] = max(0, row[field] - n)
        row[recField] = max(0, row[recField] - n)
      end
      rec.reverted = true
      undone = undone + 1
    end
  end
  if undone > 0 then
    print(TAG .. ": removed " .. undone .. " incorrect recover" .. (undone == 1 and "y" or "ies")
      .. " from earlier logouts (a bug in v1.3 - sorry!).")
  end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_LOGOUT")
f:RegisterEvent("PLAYER_LEVEL_UP")
f:RegisterEvent("PLAYER_REGEN_ENABLED")

-- Keep a known-good copy of the statistics (cheap: three lookups a minute).
-- Called by the Core ticker, which only runs once tracking is ready.
local sinceStats = 0
function ns.RecoveryTick(dt)
  sinceStats = sinceStats + dt
  if sinceStats >= 60 then
    sinceStats = 0
    RefreshStats()
  end
end

f:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" then
    RepairZeroCheckpointRecoveries()
    RestoreSession()
  elseif event == "PLAYER_LOGOUT" then
    WriteCheckpoint()
  elseif event == "PLAYER_LEVEL_UP" then
    local db = ChronologForeverDB
    if db and db.options and db.options.savePrompt then
      -- Let the level-up settle (and any fight end) before asking.
      if C_Timer then C_Timer.After(2, ShowSavePrompt) else ShowSavePrompt() end
    end
  elseif event == "PLAYER_REGEN_ENABLED" then
    if promptPending then ShowSavePrompt() end
  end
end)
