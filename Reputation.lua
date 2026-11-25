--[[
  Chronolog-Forever - Reputation
  ------------------------------
  Records reputation changes per level, broken down by faction, from the
  "Reputation with <faction> increased by <n>." chat line. The patterns are
  built from the client's own (localized) format strings, so this works in
  every language. Bonus suffixes ("(+12.5 bonus)") are ignored; the number in
  the main sentence is the amount gained.

  Stored as row.factions[name] = net change at that level (losses negative).

  The current standing (Friendly, Honored, ...) is read from the reputation
  list for the tooltip. Factions under a collapsed header in the Reputation
  pane aren't listed by the client, so those show no standing.
]]

local addonName, ns = ...

local Clean, IsSecret = ns.Clean, ns.IsSecret
local state = ns.state

-- Global format string, sign of the change. Missing ones are skipped.
local FORMATS = {
  { "FACTION_STANDING_INCREASED", 1 },
  { "FACTION_STANDING_INCREASED_ACCOUNT_WIDE", 1 },
  { "FACTION_STANDING_DECREASED", -1 },
  { "FACTION_STANDING_DECREASED_ACCOUNT_WIDE", -1 },
}
local FALLBACK = {
  FACTION_STANDING_INCREASED = "Reputation with %s increased by %d.",
  FACTION_STANDING_DECREASED = "Reputation with %s decreased by %d.",
}

-- printf-style format -> anchored Lua pattern plus, for each capture, which
-- format argument it is (handles positional "%2$d" in some locales).
-- Only the start of the message is matched, so suffixes don't matter.
local function ToPattern(fmt)
  local out, order, i, auto = { "^" }, {}, 1, 0
  while true do
    local p = fmt:find("%", i, true)
    local lit = fmt:sub(i, p and (p - 1) or #fmt)
    out[#out + 1] = (lit:gsub("[%^%$%(%)%.%[%]%*%+%-%?%%]", "%%%0"))
    if not p then break end
    local argPos, after = fmt:match("^%%(%d+)%$()", p)
    local conv, e = fmt:match("^[%-%d%.]*([sdf%%])()", after or (p + 1))
    if not conv then return nil end
    if conv == "%" then
      out[#out + 1] = "%%"
    else
      auto = auto + 1
      order[#order + 1] = tonumber(argPos) or auto
      if conv == "s" then
        out[#out + 1] = "(.-)"
      else
        out[#out + 1] = "(%d[%d,%.]*)" -- digits, maybe with group separators
      end
    end
    i = e
  end
  return table.concat(out), order
end
ns.RepToPattern = ToPattern

local patterns = {}
for _, f in ipairs(FORMATS) do
  local fmt = _G[f[1]]
  if type(fmt) ~= "string" then fmt = FALLBACK[f[1]] end
  if fmt then
    local pat, order = ToPattern(fmt)
    if pat then patterns[#patterns + 1] = { pat = pat, order = order, sign = f[2], name = f[1] } end
  end
end

-- (faction, signed amount) from a chat line, or nil.
local function Parse(msg)
  for _, p in ipairs(patterns) do
    local caps = { msg:match(p.pat) }
    if caps[1] then
      local args = {}
      for k, idx in ipairs(p.order) do args[idx] = caps[k] end
      local name = args[1]
      local amount = tonumber(((args[2] or ""):gsub("%D", "")))
      if type(name) == "string" and name ~= "" and amount and amount > 0 then
        return name, amount * p.sign
      end
      return nil
    end
  end
end
ns.ParseRepMessage = Parse

local function AddRep(name, delta)
  local db = ChronologForeverDB
  if not db then return end
  local row = ns.GetRow(db, state.currentLevel)
  row.factions[name] = (row.factions[name] or 0) + delta
  if ns.Refresh then ns.Refresh() end
  if ns.RefreshWidget then ns.RefreshWidget() end
end

-- Total reputation gained at a level (gains only, across all factions).
function ns.RepGained(row)
  local sum = 0
  for _, v in pairs(row and row.factions or {}) do
    if v > 0 then sum = sum + v end
  end
  return sum
end

-- Factions in a factions table, biggest change first: { {name, value} }.
function ns.SortedFactions(factions, limit)
  local list = {}
  for name, v in pairs(factions or {}) do
    if v ~= 0 then list[#list + 1] = { name = name, value = v } end
  end
  table.sort(list, function(a, b)
    if math.abs(a.value) ~= math.abs(b.value) then return math.abs(a.value) > math.abs(b.value) end
    return a.name < b.name
  end)
  if limit then
    for i = #list, limit + 1, -1 do list[i] = nil end
  end
  return list
end

-- "+1,250" / "-75"
function ns.FormatRep(v)
  v = math.floor((v or 0) + 0.5)
  local s = tostring(math.abs(v))
  local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return (v < 0 and "-" or "+") .. formatted
end

--------------------------------------------------------------------------------
-- Current standing (this character only), from the reputation list.
--------------------------------------------------------------------------------
local standing, dirty = {}, true

local function StandingLabel(reaction)
  if not reaction then return nil end
  local key = "FACTION_STANDING_LABEL" .. reaction
  if GetText and UnitSex then
    local ok, text = pcall(GetText, key, UnitSex("player"))
    if ok and type(text) == "string" and text ~= "" then return text end
  end
  return _G[key]
end

local function Rebuild()
  wipe(standing)
  dirty = false
  local C = C_Reputation
  if C and C.GetNumFactions and C.GetFactionDataByIndex then
    for i = 1, (Clean(C.GetNumFactions()) or 0) do
      local d = C.GetFactionDataByIndex(i)
      if type(d) == "table" then
        local name = Clean(d.name)
        local reaction = Clean(d.reaction)
        local cur, lo, hi = Clean(d.currentStanding), Clean(d.currentReactionThreshold), Clean(d.nextReactionThreshold)
        if name and reaction and (not d.isHeader or d.isHeaderWithRep) then
          standing[name] = { reaction = reaction,
            value = (cur and lo) and (cur - lo) or nil, max = (hi and lo) and (hi - lo) or nil }
        end
      end
    end
  elseif GetNumFactions and GetFactionInfo then
    for i = 1, (Clean(GetNumFactions()) or 0) do
      local name, _, reaction, barMin, barMax, barValue, _, _, isHeader, _, hasRep = GetFactionInfo(i)
      name, reaction = Clean(name), Clean(reaction)
      barMin, barMax, barValue = Clean(barMin), Clean(barMax), Clean(barValue)
      if name and reaction and (not isHeader or hasRep) then
        standing[name] = { reaction = reaction,
          value = (barValue and barMin) and (barValue - barMin) or nil,
          max = (barMax and barMin) and (barMax - barMin) or nil }
      end
    end
  end
end

-- { label, value, max, color = {r,g,b} } for this character, or nil.
function ns.GetFactionStanding(name)
  if dirty then
    local ok = pcall(Rebuild)
    if not ok then wipe(standing) end
  end
  local s = standing[name]
  if not s then return nil end
  local c = FACTION_BAR_COLORS and FACTION_BAR_COLORS[s.reaction]
  return {
    label = StandingLabel(s.reaction) or "?",
    value = s.value, max = s.max,
    color = c and { c.r, c.g, c.b } or { 1, 1, 1 },
  }
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("CHAT_MSG_COMBAT_FACTION_CHANGE")
ev:RegisterEvent("UPDATE_FACTION")
ev:SetScript("OnEvent", function(_, event, msg)
  if event == "UPDATE_FACTION" then
    dirty = true
    return
  end
  dirty = true
  if not state.ready or type(msg) ~= "string" or IsSecret(msg) then return end
  state.lastRepMsg = msg
  local name, delta = Parse(msg)
  if name then AddRep(name, delta) end
end)

function ns.RepDebug(Dbg)
  Dbg("reputation patterns:", #patterns)
  Dbg("last reputation chat line:", state.lastRepMsg or "(none yet)")
end
