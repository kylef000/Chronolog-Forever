--[[
  Chronolog-Forever - Pace & ETA
  ------------------------------
  * Pace: compares how long each level took against a reference, like speedrun
    splits. The reference is either "best splits" (the fastest time any of your
    other characters took for that level) or one specific character. Only
    complete levels are compared: levels you've finished, with time tracked
    from the moment they started (or backfilled from /played).
  * ETA: time to the next level and to 60 at your recent XP rate. The XP needed
    for future levels is learned from your characters as they level; unknown
    levels are extrapolated (the result is then marked as an estimate).
]]

local addonName, ns = ...

local MAX_LEVEL = ns.MAX_LEVEL
local LevelTime = ns.LevelTime

--------------------------------------------------------------------------------
-- Characters
--------------------------------------------------------------------------------
-- Highest level with data, for account entries saved before v1.2 (no `level`).
local function InferLevel(levels)
  local best
  for lvl, row in pairs(levels) do
    if (row.total or 0) > 0 and (not best or lvl > best) then best = lvl end
  end
  return best
end

-- Info for a character: nil = this character, otherwise an account key.
local function CharInfo(key)
  if key == nil or key == ns.CharKey() then
    local db = ns.EnsureDB()
    return {
      key = ns.CharKey(), name = UnitName("player"), me = true,
      levels = db.levels, startLevel = db.startLevel, level = ns.state.currentLevel,
    }
  end
  local a = ChronologAccountDB
  local c = a and a.chars and a.chars[key]
  if not c or type(c.levels) ~= "table" then return nil end
  return {
    key = key, name = ns.DisplayName(c) or key,
    levels = c.levels, startLevel = c.startLevel, level = c.level or InferLevel(c.levels),
  }
end

-- Other characters (excluding `exceptKey`) with level data.
local function OtherChars(exceptKey)
  local list = {}
  local a = ChronologAccountDB
  if not (a and a.chars) then return list end
  local meKey = ns.CharKey()
  for key, entry in pairs(a.chars) do
    -- Never compare a character with (a copy of) itself.
    local isSelf = (key == meKey) or ns.IsCurrentCharEntry(entry)
    if key ~= exceptKey and not (exceptKey == meKey and isSelf) then
      local c = CharInfo(key)
      if c then list[#list + 1] = c end
    end
  end
  table.sort(list, function(x, y) return x.key < y.key end)
  return list
end

-- Time a character took for level L, if that level is complete.
local function CompleteTime(c, L)
  local row = c.levels[L]
  if not row or not c.level or L >= c.level then return nil end
  if not (L > (c.startLevel or MAX_LEVEL) or row.full) then return nil end
  -- Time split across several levels after a crash is a guess; don't race it.
  if row.estimated then return nil end
  local t = LevelTime(row)
  if t <= 0 then return nil end
  return t
end

--------------------------------------------------------------------------------
-- Reference selection
--------------------------------------------------------------------------------
local function GetRefID()
  local db = ns.EnsureDB()
  return db.paceRef or "best"
end

-- Choices for the reference: best splits + every other character.
function ns.GetPaceRefs()
  local list = { { id = "best", label = "Best splits (all your characters)" } }
  for _, c in ipairs(OtherChars(ns.CharKey())) do
    list[#list + 1] = { id = c.key, label = c.name }
  end
  return list
end

function ns.SetPaceRef(id)
  ns.EnsureDB().paceRef = (id ~= "best") and id or nil
  if ns.Refresh then ns.Refresh() end
  if ns.RefreshWidget then ns.RefreshWidget() end
end

function ns.CyclePaceRef()
  local refs, cur = ns.GetPaceRefs(), GetRefID()
  local idx = 1
  for i, r in ipairs(refs) do if r.id == cur then idx = i end end
  local nextRef = refs[idx % #refs + 1]
  ns.SetPaceRef(nextRef.id)
  return nextRef
end

function ns.GetPaceRefLabel()
  local id = GetRefID()
  if id == "best" then return "best splits" end
  local c = CharInfo(id)
  return c and c.name or "best splits"
end

--------------------------------------------------------------------------------
-- Pace
--------------------------------------------------------------------------------
-- Returns, for a character (nil = this one; "ALL" isn't supported):
--   cum      - total difference over compared levels (negative = faster)
--   n        - number of levels compared
--   levels   - [L] = { mine, ref, diff, cum, refName }
--   curLevel, curMine, curRef - the level in progress (time so far vs ref)
--   refLabel
function ns.GetPace(source)
  if source == "ALL" then return nil end
  local me = CharInfo(source)
  if not me then return nil end
  local refID = GetRefID()
  local others = OtherChars(me.key)

  local refChar
  if refID ~= "best" then
    for _, c in ipairs(others) do if c.key == refID then refChar = c end end
    if not refChar then refID = "best" end -- reference no longer exists
  end

  local function RefTime(L)
    if refChar then return CompleteTime(refChar, L), refChar.name end
    local best, bestName
    for _, c in ipairs(others) do
      local t = CompleteTime(c, L)
      if t and (not best or t < best) then best, bestName = t, c.name end
    end
    return best, bestName
  end

  local result = {
    cum = 0, n = 0, levels = {},
    refLabel = refChar and refChar.name or "best splits",
    hasOthers = #others > 0,
  }
  local lastLevel = me.level or MAX_LEVEL
  for L = 1, lastLevel - 1 do
    local mine = CompleteTime(me, L)
    if mine then
      local ref, refName = RefTime(L)
      if ref then
        local diff = mine - ref
        result.cum = result.cum + diff
        result.n = result.n + 1
        result.levels[L] = { mine = mine, ref = ref, diff = diff, cum = result.cum, refName = refName }
      end
    end
  end

  -- The level in progress: time so far vs. the reference's full time.
  if me.level and me.level < MAX_LEVEL and me.levels[me.level] then
    result.curLevel = me.level
    result.curMine = LevelTime(me.levels[me.level])
    result.curRef = RefTime(me.level)
  end
  return result
end

--------------------------------------------------------------------------------
-- ETA
--------------------------------------------------------------------------------
-- XP needed per level, as learned from every character on the account.
local function KnownXPTable()
  local known = {}
  local function Add(levels)
    for lvl, row in pairs(levels) do
      if type(row.xpMax) == "number" and row.xpMax > 0 then known[lvl] = row.xpMax end
    end
  end
  local a = ChronologAccountDB
  if a and a.chars then
    for _, c in pairs(a.chars) do
      if type(c.levels) == "table" then Add(c.levels) end
    end
  end
  Add(ns.EnsureDB().levels)
  return known
end

-- Estimate the XP needed for a level we haven't seen, from the known levels.
local function Extrapolate(known, L)
  local lo, hi
  for lvl in pairs(known) do
    if not lo or lvl < lo then lo = lvl end
    if not hi or lvl > hi then hi = lvl end
  end
  if not hi then return nil end
  if lo == hi then return known[hi] * L / hi end
  local slope = (known[hi] - known[lo]) / (hi - lo)
  if L < lo then return math.max(known[lo] - slope * (lo - L), 1) end
  return known[hi] + slope * (L - hi)
end

-- XP needed to go from level L to L+1 (known or estimated), or nil.
function ns.XPForLevel(L)
  local known = KnownXPTable()
  return known[L] or Extrapolate(known, L)
end

-- Seconds of play to the next level, seconds to max level (or nil), whether
-- the max-level figure is an estimate, and the rate source ("recent"/"level").
function ns.GetETA()
  local cur = ns.state.currentLevel
  if cur >= MAX_LEVEL then return nil end
  local xp, xpMax = ns.Clean(UnitXP("player")), ns.Clean(UnitXPMax("player"))
  if not xp or not xpMax or xpMax <= 0 then return nil end
  local rate, source = ns.GetXPRate()
  if not rate or rate <= 0 then return nil end

  local toNext = (xpMax - xp) / rate * 3600
  local needed, estimated = xpMax - xp, false
  local known = KnownXPTable()
  for L = cur + 1, MAX_LEVEL - 1 do
    local v = known[L]
    if not v then
      v = Extrapolate(known, L)
      estimated = true
    end
    if not v then return toNext, nil, true, source end
    needed = needed + v
  end
  return toNext, needed / rate * 3600, estimated, source
end
