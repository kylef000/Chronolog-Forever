--[[
  Chronolog-Forever - UI
  ----------------------
  The main window:
    * a character selector (this character / others / all)
    * headline stats and an overall composition bar
    * three tabs: Levels (per-level list), Zones, Charts
]]

local addonName, ns = ...

local FormatTime = ns.FormatTime
local COLORS, LABELS = ns.COLORS, ns.LABELS

local ROW_H = 20
local ROW_BAR_W = 170
local NUM_SUMMARY = 7

local frame -- main window
local rows = {} -- pooled per-level row frames
local summaryLines = {}
local views = {} -- tab id -> view frame (with Refresh)
local tabButtons = {}
local currentTab = "levels"
local lastAgg

--------------------------------------------------------------------------------
-- Row pool (Levels tab)
--------------------------------------------------------------------------------
local function AcquireRow(index, parent)
  local row = rows[index]
  if row then return row end

  row = CreateFrame("Frame", nil, parent)
  row:SetHeight(ROW_H)
  row:EnableMouse(true)

  row.level = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.level:SetPoint("LEFT", row, "LEFT", 2, 0)
  row.level:SetWidth(40)
  row.level:SetJustifyH("LEFT")

  row.bar = ns.CreateStackedBar(row, ROW_H - 6)
  row.bar:SetPoint("LEFT", row, "LEFT", 46, 0)
  row.bar:SetWidth(ROW_BAR_W)

  row.kills = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.kills:SetPoint("LEFT", row.bar, "RIGHT", 10, 0)
  row.kills:SetWidth(52)
  row.kills:SetJustifyH("RIGHT")

  row.quests = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.quests:SetPoint("LEFT", row.kills, "RIGHT", 10, 0)
  row.quests:SetWidth(52)
  row.quests:SetJustifyH("RIGHT")

  row.time = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.time:SetPoint("LEFT", row.quests, "RIGHT", 10, 0)
  row.time:SetWidth(90)
  row.time:SetJustifyH("RIGHT")

  row.highlight = row:CreateTexture(nil, "BACKGROUND")
  row.highlight:SetAllPoints(true)
  ns.SetColor(row.highlight, 1, 1, 1, 0.06)
  row.highlight:Hide()

  row:SetScript("OnEnter", function(self)
    self.highlight:Show()
    local d = self.data
    if not d then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Level " .. d.lvl, 1, 1, 1)
    GameTooltip:AddLine(" ")
    ns.AddBreakdown(GameTooltip, d.row, d.avg)
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function(self)
    self.highlight:Hide()
    GameTooltip:Hide()
  end)

  ns.SkinFonts(row)

  rows[index] = row
  return row
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------
local function pct(part, whole)
  if not whole or whole <= 0 then return "0%" end
  return string.format("%.0f%%", part / whole * 100)
end

local function SourceLabel(source)
  for _, s in ipairs(ns.GetSources()) do
    if s.id == source then return s.label end
  end
  return "This character"
end

local function RefreshLevels(agg)
  local view = views.levels
  local content = view.content
  local levels = agg.levels
  local width = view.scroll:GetWidth()
  if width and width > 0 then content:SetWidth(width) end

  local currentLevel = (agg.source == nil) and ns.state.currentLevel or nil
  for i, lvl in ipairs(levels) do
    local row = AcquireRow(i, content)
    local data = agg.rows[lvl]
    row.data = { lvl = lvl, row = data, avg = agg.avg }
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i - 1) * ROW_H)
    row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -(i - 1) * ROW_H)

    if lvl == currentLevel then
      row.level:SetText("|cff00ff00Lv " .. lvl .. "|r")
    else
      row.level:SetText("Lv " .. lvl)
    end
    ns.UpdateStackedBar(row.bar, ns.RowValues(data), ROW_BAR_W)
    row.kills:SetText(data.kills > 0 and tostring(data.kills) or "|cff555555-|r")
    row.quests:SetText(data.quests > 0 and tostring(data.quests) or "|cff555555-|r")
    row.time:SetText(data.total > 0 and FormatTime(data.total) or "|cff555555-|r")
    row:Show()
  end
  for i = #levels + 1, #rows do
    rows[i]:Hide()
  end
  content:SetHeight(math.max(#levels * ROW_H, 1))
end

local function StyleTabs()
  local r, g, b = ns.GetAccent()
  for id, btn in pairs(tabButtons) do
    local fs = btn:GetFontString()
    if fs then
      if id == currentTab then fs:SetTextColor(r, g, b) else fs:SetTextColor(1, 1, 1) end
    end
  end
end

function ns.Refresh()
  if not frame or not frame:IsShown() then return end

  local agg = ns.GetAggregate(ns.viewSource)
  lastAgg = agg
  local t = agg.totals

  frame.charBtn:SetText("Character: " .. SourceLabel(ns.viewSource))

  -- Headline summary lines
  local hours = t.total / 3600
  local kph = (hours > 0) and (t.kills / hours) or 0
  local xph = (hours > 0) and (t.xp / hours) or 0
  local gph = (hours > 0) and (t.gold / 10000 / hours) or 0

  local sinceTxt = agg.startLevel and ("Lv " .. agg.startLevel) or "?"
  summaryLines[1]:SetText(ns.Gold("|cffffd200Tracked playtime:|r " .. FormatTime(t.total)
    .. "   |cff888888(since " .. sinceTxt .. ")|r"))
  summaryLines[2]:SetText(string.format("%sCombat|r %s (%s)   %sTravel|r %s (%s)",
    ns.ColorCode(1), FormatTime(t.combat), pct(t.combat, t.total),
    ns.ColorCode(2), FormatTime(t.travel), pct(t.travel, t.total)))
  summaryLines[3]:SetText(string.format("%sAFK|r %s (%s)   %sDead|r %s (%s)   %sOther|r %s (%s)",
    ns.ColorCode(3), FormatTime(t.afk), pct(t.afk, t.total),
    ns.ColorCode(5), FormatTime(t.dead), pct(t.dead, t.total),
    ns.ColorCode(4), FormatTime(t.other), pct(t.other, t.total)))
  summaryLines[4]:SetText(ns.Gold(string.format(
    "|cffffd200Kills:|r %d   |cffffd200Quests:|r %d   |cffffd200Dungeons:|r %d   |cffffd200Deaths:|r %d",
    t.kills, t.quests, t.dungeons, t.deaths)))
  summaryLines[5]:SetText(ns.Gold(string.format(
    "|cffffd200Grouped:|r %s (%s)   |cffffd200Crafting:|r %s   |cff888888%.1f kills/hr|r",
    FormatTime(t.grouped), pct(t.grouped, t.total), FormatTime(t.crafting), kph)))
  summaryLines[6]:SetText(ns.Gold(string.format(
    "|cffffd200XP:|r %s |cff888888(%s/hr)|r   |cffffd200Gold:|r %s |cff888888(%.1fg/hr, %s spent)|r",
    ns.FormatNumber(t.xp), ns.FormatNumber(xph), ns.FormatGold(t.gold), gph, ns.FormatGold(t.spent))))

  local busy = agg.busiestLevel
    and string.format("Lv %d (%.0f%% combat)", agg.busiestLevel, (agg.busiestRatio or 0) * 100) or "-"
  local lazy = agg.laziestLevel
    and string.format("Lv %d (%.0f%% idle)", agg.laziestLevel, (agg.laziestRatio or 0) * 100) or "-"
  summaryLines[7]:SetText(ns.Gold("|cffffd200Busiest:|r " .. busy .. "   |cffffd200Laziest:|r " .. lazy))

  -- Aggregate composition bar
  ns.UpdateStackedBar(frame.aggBar, ns.RowValues(t), frame.aggBar.width)

  StyleTabs()
  if currentTab == "levels" then
    RefreshLevels(agg)
  else
    views[currentTab].Refresh(agg)
  end
end

local function SelectTab(id)
  currentTab = id
  for tabId, view in pairs(views) do
    if tabId == id then view:Show() else view:Hide() end
  end
  ns.Refresh()
end

--------------------------------------------------------------------------------
-- Window construction
--------------------------------------------------------------------------------
local function CreateLegendSwatch(parent, index, anchorTo)
  local sw = parent:CreateTexture(nil, "ARTWORK")
  local c = COLORS[index]
  ns.SetColor(sw, c[1], c[2], c[3], 1)
  sw:SetWidth(10)
  sw:SetHeight(10)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  fs:SetText(LABELS[index])
  ns.TrackAccent(fs)
  if anchorTo then
    sw:SetPoint("LEFT", anchorTo, "RIGHT", 12, 0)
  else
    sw:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
  end
  fs:SetPoint("LEFT", sw, "RIGHT", 3, 0)
  return fs
end

local function BuildLevelsView(parent)
  local view = CreateFrame("Frame", nil, parent)
  view:SetAllPoints(parent)

  -- Column headers (aligned to the row columns in AcquireRow)
  local hdr = view:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  hdr:SetPoint("TOPLEFT", view, "TOPLEFT", 2, 0)
  hdr:SetText("Lvl")
  ns.TrackAccent(hdr)
  local hdrBar = view:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  hdrBar:SetPoint("LEFT", hdr, "LEFT", 46, 0)
  hdrBar:SetText("Time composition")
  ns.TrackAccent(hdrBar)
  local hdrKills = view:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  hdrKills:SetPoint("LEFT", hdr, "LEFT", 46 + ROW_BAR_W + 10, 0)
  hdrKills:SetWidth(52)
  hdrKills:SetJustifyH("RIGHT")
  hdrKills:SetText("Kills")
  ns.TrackAccent(hdrKills)
  local hdrQuests = view:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  hdrQuests:SetPoint("LEFT", hdrKills, "RIGHT", 10, 0)
  hdrQuests:SetWidth(52)
  hdrQuests:SetJustifyH("RIGHT")
  hdrQuests:SetText("Quests")
  ns.TrackAccent(hdrQuests)
  local hdrTime = view:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  hdrTime:SetPoint("LEFT", hdrQuests, "RIGHT", 10, 0)
  hdrTime:SetWidth(90)
  hdrTime:SetJustifyH("RIGHT")
  hdrTime:SetText("Total")
  ns.TrackAccent(hdrTime)

  local scroll = CreateFrame("ScrollFrame", "ChronologScroll", view, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", -2, -6)
  scroll:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -14, 0)
  view.scroll = scroll

  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(1, 1)
  scroll:SetScrollChild(content)
  view.content = content

  ns.WhenSkinned(function(S)
    S.ScrollBar(scroll.ScrollBar or _G["ChronologScrollScrollBar"])
  end)
  ns.SkinFonts(view)
  return view
end

local function MakeButton(parent, text, width, height)
  local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  btn:SetSize(width, height)
  btn:SetText(text)
  ns.WhenSkinned(function(S) S.Button(btn) end)
  return btn
end

local function BuildWindow()
  frame = CreateFrame("Frame", "ChronologFrame", UIParent, ns.BACKDROP_TEMPLATE)
  frame:SetSize(580, 700)

  -- Restore saved position (falls back to screen center on first use).
  local wdb = ns.EnsureDB()
  frame:ClearAllPoints()
  if wdb.window and wdb.window.point then
    frame:SetPoint(wdb.window.point, UIParent, wdb.window.point, wdb.window.x or 0, wdb.window.y or 0)
  else
    frame:SetPoint("CENTER")
  end

  frame:SetFrameStrata("HIGH")
  frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, _, x, y = self:GetPoint()
    local db = ns.EnsureDB()
    db.window = db.window or {}
    db.window.point, db.window.x, db.window.y = point, x, y
  end)
  frame:SetClampedToScreen(true)
  frame:Hide()
  tinsert(UISpecialFrames, "ChronologFrame")

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", frame, "TOP", 0, -14)
  title:SetText("Chronolog-Forever")
  ns.TrackAccent(title)
  frame.title = title

  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -6)

  -- Character selector: cycles this character -> others -> all characters.
  local charBtn = MakeButton(frame, "Character", 170, 20)
  charBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -40)
  charBtn:SetScript("OnClick", function()
    local sources = ns.GetSources()
    local idx = 1
    for i, s in ipairs(sources) do if s.id == ns.viewSource then idx = i end end
    ns.viewSource = sources[idx % #sources + 1].id
    ns.Refresh()
  end)
  charBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Click to switch between your characters", 1, 1, 1)
    GameTooltip:AddLine("(characters appear here after you log them in once)", 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
  charBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  frame.charBtn = charBtn

  -- Summary lines
  local prev
  for i = 1, NUM_SUMMARY do
    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetJustifyH("LEFT")
    if prev then
      fs:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -5)
    else
      fs:SetPoint("TOPLEFT", charBtn, "BOTTOMLEFT", 0, -10)
    end
    fs:SetPoint("RIGHT", frame, "RIGHT", -20, 0)
    summaryLines[i] = fs
    prev = fs
  end

  -- Aggregate composition bar + legend
  local aggLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  aggLabel:SetPoint("TOPLEFT", summaryLines[NUM_SUMMARY], "BOTTOMLEFT", 0, -12)
  aggLabel:SetText("Overall composition")
  ns.TrackAccent(aggLabel)

  local aggBar = ns.CreateStackedBar(frame, 20)
  aggBar:SetPoint("TOPLEFT", aggLabel, "BOTTOMLEFT", 0, -4)
  aggBar:SetPoint("RIGHT", frame, "RIGHT", -20, 0)
  aggBar.width = 520 -- approx; recomputed once laid out
  frame.aggBar = aggBar

  aggBar:EnableMouse(true)
  aggBar:SetScript("OnEnter", function(self)
    local agg = lastAgg or ns.GetAggregate(ns.viewSource)
    local t = agg.totals
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Overall composition", 1, 1, 1)
    GameTooltip:AddLine(" ")
    for i = 1, #ns.KEYS do
      local c = COLORS[i]
      local v = t[ns.KEYS[i]]
      GameTooltip:AddDoubleLine(LABELS[i], FormatTime(v) .. "  (" .. pct(v, t.total) .. ")",
        c[1], c[2], c[3], 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("  of which idle", FormatTime(t.idle) .. "  (" .. pct(t.idle, t.total) .. ")",
      0.6, 0.6, 0.6, 0.8, 0.8, 0.8)
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Total tracked", FormatTime(t.total), 0.8, 0.8, 0.8, 1, 1, 1)
    GameTooltip:AddDoubleLine("Grouped", FormatTime(t.grouped) .. "  (" .. pct(t.grouped, t.total) .. ")",
      0.8, 0.8, 0.8, 1, 1, 1)
    GameTooltip:AddDoubleLine("Loading screens (not counted)", FormatTime(t.loading), 0.5, 0.5, 0.5, 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  aggBar:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- Legend
  local swatchHolder = CreateFrame("Frame", nil, frame)
  swatchHolder:SetPoint("TOPLEFT", aggBar, "BOTTOMLEFT", 0, -6)
  swatchHolder:SetWidth(400)
  swatchHolder:SetHeight(14)
  local last
  for i = 1, #LABELS do
    last = CreateLegendSwatch(swatchHolder, i, last)
  end

  -- Tabs
  local tabs = {
    { id = "levels", label = "Levels" },
    { id = "zones", label = "Zones" },
    { id = "charts", label = "Charts" },
  }
  local prevTab
  for _, t in ipairs(tabs) do
    local btn = MakeButton(frame, t.label, 90, 22)
    if prevTab then
      btn:SetPoint("LEFT", prevTab, "RIGHT", 6, 0)
    else
      btn:SetPoint("TOPLEFT", swatchHolder, "BOTTOMLEFT", 0, -10)
    end
    btn:SetScript("OnClick", function() SelectTab(t.id) end)
    tabButtons[t.id] = btn
    prevTab = btn
  end

  -- Body: holds the three views
  local body = CreateFrame("Frame", nil, frame)
  body:SetPoint("TOPLEFT", tabButtons.levels, "BOTTOMLEFT", 0, -8)
  body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -20, 36)

  views.levels = BuildLevelsView(body)
  views.zones = ns.BuildZonesView(body)
  views.charts = ns.BuildChartsView(body)
  views.zones:Hide()
  views.charts:Hide()

  -- footer hint
  local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 16)
  hint:SetText("/chrono help  •  hover a row for details")

  -- live refresh while shown
  frame:SetScript("OnShow", function(self)
    local w = self.aggBar:GetWidth()
    if w and w > 0 then self.aggBar.width = w end
    ns.Refresh()
    self.elapsed = 0
  end)
  frame:SetScript("OnUpdate", function(self, e)
    self.elapsed = (self.elapsed or 0) + e
    if self.elapsed >= 1 then
      self.elapsed = 0
      local w = self.aggBar:GetWidth()
      if w and w > 0 then self.aggBar.width = w end
      ns.Refresh()
    end
  end)

  -- EllesmereUI theme (no-op without it).
  ns.WhenSkinned(function(S)
    frame:SetBackdrop(nil) -- drop the Blizzard dialog art; Shell paints the theme
    S.Shell(frame)
    S.CloseButton(close)
  end)
  ns.SkinFonts(frame)
end

function ns.ToggleWindow()
  if not frame then BuildWindow() end
  if frame:IsShown() then
    frame:Hide()
  else
    frame:Show()
  end
end
