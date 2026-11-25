--[[
  Chronolog-Forever - Common
  --------------------------
  UI pieces shared by the main window, the widget and the extra views: the
  category colors, stacked bars, legends, and the hover breakdown.
]]

local addonName, ns = ...

local FormatTime = ns.FormatTime

-- Activity colors, order: combat, travel, afk, other, dead.
local COLORS = {
  { 0.85, 0.30, 0.30 }, -- combat  (red)
  { 0.30, 0.55, 0.95 }, -- travel  (blue)
  { 0.60, 0.60, 0.62 }, -- afk     (gray)
  { 0.40, 0.75, 0.45 }, -- other   (green)
  { 0.55, 0.38, 0.70 }, -- dead    (purple)
}
local LABELS = { "Combat", "Travel", "AFK", "Other", "Dead" }
local KEYS = { "combat", "travel", "afk", "other", "dead" }
local NUM = #KEYS

ns.COLORS = COLORS
ns.LABELS = LABELS
ns.KEYS = KEYS

-- Location colors, order: world, town, instance, pvp.
ns.LOC_KEYS = { "world", "town", "instance", "pvp" }
ns.LOC_LABELS = { "Open world", "Town", "Dungeon/raid", "PvP" }
ns.LOC_COLORS = {
  { 0.42, 0.62, 0.40 }, -- world    (moss)
  { 0.90, 0.74, 0.35 }, -- town     (gold)
  { 0.30, 0.72, 0.78 }, -- instance (teal)
  { 0.90, 0.48, 0.25 }, -- pvp      (orange)
}

-- Time from before tracking (from /played).
ns.UNTRACKED_COLOR = { 0.32, 0.32, 0.36 }
-- Time recovered from an unsaved session (crash etc.); activity unknown.
ns.LOST_COLOR = { 0.48, 0.38, 0.30 }

-- The pace reference (best splits / another character).
ns.REF_COLOR = { 0.60, 0.60, 0.66 }

ns.AHEAD_COLOR = { 0.30, 0.85, 0.40 }
ns.BEHIND_COLOR = { 1.00, 0.37, 0.34 }

local function Hex(c)
  return string.format("|cff%02x%02x%02x",
    math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end
ns.Hex = Hex

-- "|cffrrggbb" for an activity color.
function ns.ColorCode(i) return Hex(COLORS[i]) end

-- Colored signed delta: green when ahead (negative), red when behind.
function ns.ColoredDelta(sec)
  return Hex(sec <= 0 and ns.AHEAD_COLOR or ns.BEHIND_COLOR) .. ns.FormatDelta(sec) .. "|r"
end

-- {combat, travel, afk, other, dead} values for a row.
function ns.RowValues(row)
  return { row.combat, row.travel, row.afk, row.other, row.dead }
end

function ns.LocValues(row)
  return { row.world, row.town, row.instance, row.pvp }
end

--------------------------------------------------------------------------------
-- Stacked bar helper
--------------------------------------------------------------------------------
-- colors defaults to the activity colors.
function ns.CreateStackedBar(parent, height, colors)
  colors = colors or COLORS
  local bar = CreateFrame("Frame", nil, parent)
  bar:SetHeight(height)
  bar.bg = bar:CreateTexture(nil, "BACKGROUND")
  bar.bg:SetAllPoints()
  ns.SetColor(bar.bg, 0, 0, 0, 0.35)
  bar.segs = {}
  for i = 1, #colors do
    local t = bar:CreateTexture(nil, "ARTWORK")
    local c = colors[i]
    ns.SetColor(t, c[1], c[2], c[3], 1)
    bar.segs[i] = t
  end
  return bar
end

-- Lay out the segments. With `denom`, segments are scaled against it instead
-- of their own sum (the rest stays empty, e.g. time without location data).
function ns.UpdateStackedBar(bar, vals, width, denom)
  local n = #bar.segs
  local sum = 0
  for i = 1, n do sum = sum + (vals[i] or 0) end
  if denom and denom > sum then sum = denom end
  local x = 0
  for i = 1, n do
    local seg = bar.segs[i]
    local w = (sum > 0) and ((vals[i] or 0) / sum) * width or 0
    seg:ClearAllPoints()
    if w > 0.5 then
      seg:SetPoint("TOPLEFT", bar, "TOPLEFT", x, 0)
      seg:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", x, 0)
      seg:SetWidth(w)
      seg:Show()
      x = x + w
    else
      seg:Hide()
    end
  end
end

-- A row of color swatches with labels. Returns the holder frame.
function ns.CreateLegend(parent, labels, colors)
  local holder = CreateFrame("Frame", nil, parent)
  holder:SetHeight(12)
  holder:SetWidth(500)
  local prev
  for i, label in ipairs(labels) do
    local c = colors[i]
    local sw = holder:CreateTexture(nil, "ARTWORK")
    ns.SetColor(sw, c[1], c[2], c[3], 1)
    sw:SetSize(8, 8)
    if prev then
      sw:SetPoint("LEFT", prev, "RIGHT", 10, 0)
    else
      sw:SetPoint("LEFT", holder, "LEFT", 0, 0)
    end
    local fs = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetText(label)
    fs:SetTextColor(0.75, 0.75, 0.75)
    fs:SetPoint("LEFT", sw, "RIGHT", 4, 0)
    prev = fs
  end
  ns.SkinFonts(holder)
  return holder
end

--------------------------------------------------------------------------------
-- Hover breakdown for a level row
--------------------------------------------------------------------------------
local GRAY = 0.8

local function Pct(part, whole)
  if not whole or whole <= 0 then return "" end
  return string.format("  |cff888888%.0f%%|r", part / whole * 100)
end

-- pace (optional) = one entry of ns.GetPace().levels for this level.
function ns.AddBreakdown(tip, row, avg, pace)
  for i = 1, NUM do
    local c = COLORS[i]
    tip:AddDoubleLine(LABELS[i], FormatTime(row[KEYS[i]]) .. Pct(row[KEYS[i]], row.total),
      c[1], c[2], c[3], 1, 1, 1)
  end
  tip:AddDoubleLine("  of which idle", FormatTime(row.idle), 0.6, 0.6, 0.6, 0.8, 0.8, 0.8)
  tip:AddLine(" ")
  tip:AddDoubleLine("Tracked time", FormatTime(row.total), GRAY, GRAY, GRAY, 1, 1, 1)
  if (row.untracked or 0) > 0 then
    tip:AddDoubleLine("Before tracking (from /played)", FormatTime(row.untracked), 0.6, 0.6, 0.6, 0.8, 0.8, 0.8)
  end
  if (row.lost or 0) > 0 then
    local c = ns.LOST_COLOR
    tip:AddDoubleLine("Not recorded (unsaved session)", FormatTime(row.lost), c[1] + 0.2, c[2] + 0.2, c[3] + 0.2, 0.8, 0.8, 0.8)
  end
  if (row.untracked or 0) > 0 or (row.lost or 0) > 0 then
    tip:AddDoubleLine("Time at this level", FormatTime(ns.LevelTime(row))
      .. (row.estimated and "  |cff888888(estimated)|r" or ""), GRAY, GRAY, GRAY, 1, 1, 1)
  end
  tip:AddDoubleLine("Grouped", FormatTime(row.grouped), GRAY, GRAY, GRAY, 1, 1, 1)
  if (row.flight or 0) > 0 or (row.flights or 0) > 0 then
    tip:AddDoubleLine(string.format("Flight paths (%d %s)", row.flights, row.flights == 1 and "flight" or "flights"),
      FormatTime(row.flight) .. "  " .. ns.FormatCoins(row.flightCost), GRAY, GRAY, GRAY, 1, 1, 1)
  end
  if row.crafting > 0 then
    tip:AddDoubleLine("Professions window open", FormatTime(row.crafting), GRAY, GRAY, GRAY, 1, 1, 1)
  end
  if row.loading > 0 then
    tip:AddDoubleLine("Loading screens (not counted)", FormatTime(row.loading), 0.5, 0.5, 0.5, 0.7, 0.7, 0.7)
  end

  local locSum = row.world + row.town + row.instance + row.pvp
  if locSum > 0 then
    tip:AddLine(" ")
    for i, key in ipairs(ns.LOC_KEYS) do
      if row[key] > 0 then
        local c = ns.LOC_COLORS[i]
        tip:AddDoubleLine(ns.LOC_LABELS[i], FormatTime(row[key]) .. Pct(row[key], row.total),
          c[1], c[2], c[3], 1, 1, 1)
      end
    end
  end

  tip:AddLine(" ")
  local function Rec(n)
    return (n or 0) > 0 and ("  |cff888888(" .. n .. " recovered)|r") or ""
  end
  tip:AddDoubleLine("Mobs killed", tostring(row.kills) .. Rec(row.recKills), GRAY, GRAY, GRAY, 1, 1, 1)
  tip:AddDoubleLine("Quests turned in", tostring(row.quests) .. Rec(row.recQuests), GRAY, GRAY, GRAY, 1, 1, 1)
  tip:AddDoubleLine("Dungeons completed", tostring(row.dungeons), GRAY, GRAY, GRAY, 1, 1, 1)
  tip:AddDoubleLine("Deaths", tostring(row.deaths) .. Rec(row.recDeaths), GRAY, GRAY, GRAY, 1, 1, 1)
  tip:AddDoubleLine("XP gained", ns.FormatNumber(row.xp), GRAY, GRAY, GRAY, 1, 1, 1)
  tip:AddDoubleLine("Gold gained / spent", ns.FormatGold(row.gold) .. " / " .. ns.FormatGold(row.spent),
    GRAY, GRAY, GRAY, 1, 1, 1)

  local factions = ns.SortedFactions and ns.SortedFactions(row.factions) or {}
  if #factions > 0 then
    tip:AddLine(" ")
    tip:AddLine("Reputation", 0.6, 0.6, 0.6)
    for i, f in ipairs(factions) do
      if i > 4 then
        tip:AddLine(string.format("  ... and %d more (see the Reputation tab)", #factions - 4), 0.5, 0.5, 0.5)
        break
      end
      local c = f.value < 0 and ns.BEHIND_COLOR or { 1, 1, 1 }
      tip:AddDoubleLine(f.name, ns.FormatRep(f.value), GRAY, GRAY, GRAY, c[1], c[2], c[3])
    end
  end

  if pace then
    tip:AddLine(" ")
    tip:AddLine("Pace vs. " .. (pace.refName or "reference"), 0.6, 0.6, 0.6)
    tip:AddDoubleLine("This level", FormatTime(pace.mine) .. "  |cff888888(ref " .. FormatTime(pace.ref) .. ")|r",
      GRAY, GRAY, GRAY, 1, 1, 1)
    tip:AddDoubleLine("Difference", ns.ColoredDelta(pace.diff), GRAY, GRAY, GRAY, 1, 1, 1)
    tip:AddDoubleLine("Running total", ns.ColoredDelta(pace.cum), GRAY, GRAY, GRAY, 1, 1, 1)
  end

  -- Compare this level with the average of the other qualifying levels.
  if avg and avg.n and avg.n > 1 and row.total >= ns.MIN_TOTAL_FOR_RATIO then
    tip:AddLine(" ")
    tip:AddLine("vs. your average level", 0.6, 0.6, 0.6)
    local function cmp(label, value, average, fmt)
      tip:AddDoubleLine(label, string.format(fmt, value) .. "  |cff888888(avg " .. string.format(fmt, average) .. ")|r",
        GRAY, GRAY, GRAY, 1, 1, 1)
    end
    cmp("Combat share", row.combat / row.total * 100, avg.combat * 100, "%.0f%%")
    cmp("Kills / hour", ns.PerHour(row, "kills"), avg.kph, "%.0f")
    cmp("XP / hour", ns.PerHour(row, "xp"), avg.xph, "%.0f")
    cmp("Gold / hour", ns.PerHour(row, "gold", 10000), avg.gph, "%.1f")
  end

  local zones = ns.SortedZones(row.zones, 3)
  if #zones > 0 then
    tip:AddLine(" ")
    tip:AddLine("Top zones", 0.6, 0.6, 0.6)
    for _, z in ipairs(zones) do
      tip:AddDoubleLine(z.name, FormatTime(z.secs), 1, 1, 1, 0.8, 0.8, 0.8)
    end
  end
end
