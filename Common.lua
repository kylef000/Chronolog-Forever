--[[
  Chronolog-Forever - Common
  --------------------------
  UI pieces shared by the main window, the widget and the extra views: the
  category colors, the stacked composition bar, and the hover breakdown.
]]

local addonName, ns = ...

local FormatTime = ns.FormatTime

-- Category colors, order: combat, travel, afk, other, dead.
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

-- "|cffrrggbb" for a category color.
function ns.ColorCode(i)
  local c = COLORS[i]
  return string.format("|cff%02x%02x%02x",
    math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end

-- {combat, travel, afk, other, dead} values for a row.
function ns.RowValues(row)
  return { row.combat, row.travel, row.afk, row.other, row.dead }
end

--------------------------------------------------------------------------------
-- Stacked bar helper
--------------------------------------------------------------------------------
function ns.CreateStackedBar(parent, height)
  local bar = CreateFrame("Frame", nil, parent)
  bar:SetHeight(height)
  bar.bg = bar:CreateTexture(nil, "BACKGROUND")
  bar.bg:SetAllPoints(true)
  ns.SetColor(bar.bg, 0, 0, 0, 0.35)
  bar.segs = {}
  for i = 1, NUM do
    local t = bar:CreateTexture(nil, "ARTWORK")
    local c = COLORS[i]
    ns.SetColor(t, c[1], c[2], c[3], 1)
    bar.segs[i] = t
  end
  return bar
end

-- vals = {combat, travel, afk, other, dead}
function ns.UpdateStackedBar(bar, vals, width)
  local sum = 0
  for i = 1, NUM do sum = sum + (vals[i] or 0) end
  local x = 0
  for i = 1, NUM do
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

--------------------------------------------------------------------------------
-- Hover breakdown for a level row
--------------------------------------------------------------------------------
local GRAY = 0.8

function ns.AddBreakdown(tip, row, avg)
  for i = 1, NUM do
    local c = COLORS[i]
    tip:AddDoubleLine(LABELS[i], FormatTime(row[KEYS[i]]), c[1], c[2], c[3], 1, 1, 1)
  end
  tip:AddDoubleLine("  of which idle", FormatTime(row.idle), 0.6, 0.6, 0.6, 0.8, 0.8, 0.8)
  tip:AddLine(" ")
  tip:AddDoubleLine("Total time", FormatTime(row.total), GRAY, GRAY, GRAY, 1, 1, 1)
  tip:AddDoubleLine("Grouped", FormatTime(row.grouped), GRAY, GRAY, GRAY, 1, 1, 1)
  if row.crafting > 0 then
    tip:AddDoubleLine("Professions window open", FormatTime(row.crafting), GRAY, GRAY, GRAY, 1, 1, 1)
  end
  if row.loading > 0 then
    tip:AddDoubleLine("Loading screens (not counted)", FormatTime(row.loading), 0.5, 0.5, 0.5, 0.7, 0.7, 0.7)
  end
  tip:AddLine(" ")
  tip:AddDoubleLine("Mobs killed", tostring(row.kills), GRAY, GRAY, GRAY, 1, 1, 1)
  tip:AddDoubleLine("Quests turned in", tostring(row.quests), GRAY, GRAY, GRAY, 1, 1, 1)
  tip:AddDoubleLine("Dungeons completed", tostring(row.dungeons), GRAY, GRAY, GRAY, 1, 1, 1)
  tip:AddDoubleLine("Deaths", tostring(row.deaths), GRAY, GRAY, GRAY, 1, 1, 1)
  tip:AddDoubleLine("XP gained", ns.FormatNumber(row.xp), GRAY, GRAY, GRAY, 1, 1, 1)
  tip:AddDoubleLine("Gold gained / spent", ns.FormatGold(row.gold) .. " / " .. ns.FormatGold(row.spent),
    GRAY, GRAY, GRAY, 1, 1, 1)

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
