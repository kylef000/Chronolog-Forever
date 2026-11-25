--[[
  Chronolog-Forever - UI
  ----------------------
  The main window:
    * a character selector (this character / others / all)
    * stat tiles (played, kills, quests, deaths, XP/hr, gold/hr, ETA, pace)
    * activity and location composition bars
    * four tabs: Levels (per-level list), Zones, Reputation, Charts
  The window can be resized from the grip in its bottom-right corner (the size
  is saved); the tiles, the Levels activity bars and the charts use the room.
]]

local addonName, ns = ...

local FormatTime = ns.FormatTime

local ROW_H = 20
local ROW_BAR_W = 150
local TILE_W, TILE_H, TILE_GAP = 131, 46, 6
local DEFAULT_W, DEFAULT_H = 580, 700
local MIN_H, MAX_W, MAX_H = 600, 1600, 1200
local extraW = 0 -- how much wider than the default the window is

local frame -- main window
local rows = {} -- pooled per-level row frames
local tiles = {}
local views = {} -- tab id -> view frame (with Refresh)
ns.views = views
local tabButtons = {}
local currentTab = "levels"
local lastAgg

local function pct(part, whole)
  if not whole or whole <= 0 then return "0%" end
  return string.format("%.0f%%", part / whole * 100)
end

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

  row.bar = ns.CreateStackedBar(row, ROW_H - 8)
  row.bar:SetPoint("LEFT", row, "LEFT", 46, 0)
  row.bar:SetWidth(ROW_BAR_W)

  local function Col(anchor, width, template)
    local fs = row:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    fs:SetPoint("LEFT", anchor, "RIGHT", 8, 0)
    fs:SetWidth(width)
    fs:SetJustifyH("RIGHT")
    return fs
  end
  row.kills = Col(row.bar, 46)
  row.quests = Col(row.kills, 46)
  row.time = Col(row.quests, 80)
  row.pace = Col(row.time, 74)

  row.highlight = row:CreateTexture(nil, "BACKGROUND")
  row.highlight:SetAllPoints(true)
  ns.SetColor(row.highlight, 1, 1, 1, 0.06)
  row.highlight:Hide()

  row.stripe = row:CreateTexture(nil, "BACKGROUND")
  row.stripe:SetAllPoints(true)

  row:SetScript("OnEnter", function(self)
    self.highlight:Show()
    local d = self.data
    if not d then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Level " .. d.lvl .. (d.current and " (current)" or ""), 1, 1, 1)
    GameTooltip:AddLine(" ")
    ns.AddBreakdown(GameTooltip, d.row, d.avg, d.pace)
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
-- Stat tiles
--------------------------------------------------------------------------------
local TILE_DEFS = {
  { id = "played", label = "Played" },
  { id = "kills",  label = "Kills" },
  { id = "quests", label = "Quests" },
  { id = "deaths", label = "Deaths" },
  { id = "xph",    label = "XP / hour" },
  { id = "gph",    label = "Gold / hour" },
  { id = "eta",    label = "Next level" },
  { id = "pace",   label = "Pace" },
}

local function BuildTile(parent, def)
  local t = CreateFrame("Frame", nil, parent)
  t:SetSize(TILE_W, TILE_H)
  t:EnableMouse(true)
  t.bg = t:CreateTexture(nil, "BACKGROUND")
  t.bg:SetAllPoints(true)
  ns.SetColor(t.bg, 0, 0, 0, 0.28)
  t.edge = t:CreateTexture(nil, "BORDER")
  t.edge:SetPoint("TOPLEFT", t, "TOPLEFT", 0, 0)
  t.edge:SetPoint("BOTTOMLEFT", t, "BOTTOMLEFT", 0, 0)
  t.edge:SetWidth(2)

  t.label = t:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  t.label:SetPoint("TOPLEFT", t, "TOPLEFT", 8, -5)
  t.label:SetText(def.label)
  ns.TrackAccent(t.label)

  t.value = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  t.value:SetPoint("TOPLEFT", t.label, "BOTTOMLEFT", 0, -2)
  t.value:SetJustifyH("LEFT")

  t.sub = t:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  t.sub:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", -6, 5)
  t.sub:SetJustifyH("RIGHT")

  t:SetScript("OnEnter", function(self)
    ns.SetColor(self.bg, 1, 1, 1, 0.07)
    if not self.tip then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    self.tip(GameTooltip)
    GameTooltip:Show()
  end)
  t:SetScript("OnLeave", function(self)
    ns.SetColor(self.bg, 0, 0, 0, 0.28)
    GameTooltip:Hide()
  end)
  ns.SkinFonts(t)
  return t
end

local function SetTile(id, value, sub, tip)
  local t = tiles[id]
  t.value:SetText(value)
  t.sub:SetText(sub or "")
  t.tip = tip
end

local function RefreshTiles(agg, pace)
  local t = agg.totals
  local hours = t.total / 3600
  local function rate(v) return hours > 0 and v / hours or 0 end
  local r, g, b = ns.GetAccent()
  for _, tile in pairs(tiles) do ns.SetColor(tile.edge, r, g, b, 0.9) end
  if frame.charBtn then ns.SetColor(frame.charBtn.edge, r, g, b, 0.9) end

  local played = t.total + t.untracked + t.lost
  SetTile("played", FormatTime(played),
    played > t.total and ("tracked " .. ns.FormatShortTime(t.total)) or (agg.startLevel and ("since Lv " .. agg.startLevel) or ""),
    function(tip)
      tip:AddLine("Time played", 1, 1, 1)
      tip:AddDoubleLine("Tracked by Chronolog", FormatTime(t.total), 0.8, 0.8, 0.8, 1, 1, 1)
      if t.lost > 0 then
        tip:AddDoubleLine("Recovered from unsaved sessions", FormatTime(t.lost), 0.6, 0.6, 0.6, 0.8, 0.8, 0.8)
      end
      if t.untracked > 0 then
        tip:AddDoubleLine("Before tracking (from /played)", FormatTime(t.untracked), 0.6, 0.6, 0.6, 0.8, 0.8, 0.8)
      end
      tip:AddDoubleLine("Grouped", FormatTime(t.grouped) .. "  (" .. pct(t.grouped, t.total) .. ")", 0.8, 0.8, 0.8, 1, 1, 1)
      tip:AddDoubleLine("Professions window open", FormatTime(t.crafting), 0.8, 0.8, 0.8, 1, 1, 1)
      tip:AddDoubleLine("Loading screens (not counted)", FormatTime(t.loading), 0.5, 0.5, 0.5, 0.7, 0.7, 0.7)
      local db = ns.EnsureDB()
      if agg.source == nil and db.playedTotal then
        tip:AddLine(" ")
        tip:AddDoubleLine("/played (whole character)", FormatTime(db.playedTotal), 0.6, 0.6, 0.6, 0.8, 0.8, 0.8)
      end
      if agg.source == nil then ns.AddUnsavedLine(tip) end
    end)
  SetTile("kills", ns.FormatNumber(t.kills), string.format("%.0f / hr", rate(t.kills)))
  SetTile("quests", ns.FormatNumber(t.quests), t.dungeons .. (t.dungeons == 1 and " dungeon" or " dungeons"))
  SetTile("deaths", tostring(t.deaths), t.dead > 0 and (ns.FormatShortTime(t.dead) .. " dead") or "")
  SetTile("xph", ns.FormatNumber(rate(t.xp)), ns.FormatNumber(t.xp) .. " XP")
  local net = t.gold - t.spent
  SetTile("gph", string.format("%.1fg", rate(t.gold) / 10000),
    "net " .. (net < 0 and "-" or "") .. ns.FormatGold(math.abs(net)),
    function(tip)
      tip:AddLine("Gold", 1, 1, 1)
      tip:AddDoubleLine("Looted / earned", ns.FormatGold(t.gold), 0.8, 0.8, 0.8, 1, 1, 1)
      tip:AddDoubleLine("Spent", ns.FormatGold(t.spent), 0.8, 0.8, 0.8, 1, 1, 1)
    end)

  -- ETA (this character only)
  if agg.source ~= nil then
    SetTile("eta", "-", "this character only")
  elseif ns.state.currentLevel >= ns.MAX_LEVEL then
    SetTile("eta", "Max level", "")
  else
    local toNext, toMax, estimated, source = ns.GetETA()
    if toNext then
      SetTile("eta", FormatTime(toNext),
        toMax and ("60 in " .. (estimated and "~" or "") .. ns.FormatShortTime(toMax)) or "",
        function(tip)
          local rateV = ns.GetXPRate()
          tip:AddLine("Time to level " .. (ns.state.currentLevel + 1), 1, 1, 1)
          tip:AddDoubleLine("At your XP rate", ns.FormatNumber(rateV or 0) .. " XP/hr", 0.8, 0.8, 0.8, 1, 1, 1)
          tip:AddLine(source == "recent" and "Rate from your last 30 minutes of play (AFK excluded)."
            or "Rate from this level's average so far.", 0.6, 0.6, 0.6, true)
          if toMax then
            tip:AddLine(" ")
            tip:AddDoubleLine("Time to 60", FormatTime(toMax), 0.8, 0.8, 0.8, 1, 1, 1)
            if estimated then
              tip:AddLine("Some levels' XP is estimated until one of your characters reaches them.", 0.6, 0.6, 0.6, true)
            end
          end
        end)
    else
      SetTile("eta", "-", "earn some XP first")
    end
  end

  -- Pace
  if agg.source == "ALL" or not pace then
    SetTile("pace", "-", "pick a character")
  elseif pace.n == 0 then
    SetTile("pace", "-", pace.hasOthers and "no levels to compare" or "needs another character",
      function(tip)
        tip:AddLine("Pace", 1, 1, 1)
        tip:AddLine("Compares how long each level took with your other characters (best splits by default).", 0.8, 0.8, 0.8, true)
      end)
  else
    SetTile("pace", ns.ColoredDelta(pace.cum), "vs " .. pace.refLabel, function(tip)
      tip:AddLine("Pace vs. " .. pace.refLabel, 1, 1, 1)
      tip:AddLine((pace.cum <= 0 and "Ahead" or "Behind") .. " over " .. pace.n .. " finished levels.", 0.8, 0.8, 0.8)
      if pace.curRef then
        tip:AddLine(" ")
        tip:AddDoubleLine("Level " .. pace.curLevel .. " so far", FormatTime(pace.curMine), 0.8, 0.8, 0.8, 1, 1, 1)
        tip:AddDoubleLine("Reference for this level", FormatTime(pace.curRef), 0.8, 0.8, 0.8, 1, 1, 1)
      end
      tip:AddLine(" ")
      tip:AddLine("See the Charts tab (Pace) for every level. /chrono pace changes the reference.", 0.6, 0.6, 0.6, true)
    end)
  end
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------
-- "|cffRRGGBB" for a class token (white if unknown).
local function ClassHex(class)
  local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
  if not c then return "|cffffffff" end
  local function B(v) return math.floor(v * 255 + 0.5) end
  return string.format("|cff%02x%02x%02x", B(c.r), B(c.g), B(c.b))
end

-- Display text for a view source: the class-colored name and level, or
-- "All characters (n)".
local function SourceText(source)
  local a = ChronologAccountDB
  if source == "ALL" then
    local n = 0
    for _ in pairs(a and a.chars or {}) do n = n + 1 end
    return "All characters |cff888888(" .. n .. ")|r"
  end
  local name, class, level
  if source and a and a.chars and a.chars[source] then
    local c = a.chars[source]
    name, class, level = c.name or source, c.class, c.level
  else
    local _, cls = UnitClass("player")
    name, class, level = UnitName("player") or "?", cls, ns.state.currentLevel
  end
  return ClassHex(class) .. name .. "|r" .. (level and ("  |cff888888Lv " .. level .. "|r") or "")
end

local function RefreshLevels(agg, pace)
  local view = views.levels
  local content = view.content
  local levels = agg.levels
  local width = view.scroll:GetWidth()
  if width and width > 0 then content:SetWidth(width) end

  local currentLevel = (agg.source == nil) and ns.state.currentLevel or nil
  local dim = "|cff555555-|r"
  for i, lvl in ipairs(levels) do
    local row = AcquireRow(i, content)
    local data = agg.rows[lvl]
    local p = pace and pace.levels[lvl]
    row.data = { lvl = lvl, row = data, avg = agg.avg, pace = p, current = lvl == currentLevel }
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i - 1) * ROW_H)
    row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -(i - 1) * ROW_H)
    ns.SetColor(row.stripe, 1, 1, 1, (i % 2 == 0) and 0.025 or 0)

    if lvl == currentLevel then
      row.level:SetText("|cff" .. ns.AccentHex() .. "Lv " .. lvl .. "|r")
    else
      row.level:SetText("Lv " .. lvl)
    end
    row.bar:SetWidth(ROW_BAR_W + extraW)
    ns.UpdateStackedBar(row.bar, ns.RowValues(data), ROW_BAR_W + extraW)
    row.kills:SetText(data.kills > 0 and tostring(data.kills) or dim)
    row.quests:SetText(data.quests > 0 and tostring(data.quests) or dim)
    local lt = ns.LevelTime(data)
    row.time:SetText(lt > 0 and FormatTime(lt) or dim)
    if p then
      row.pace:SetText(ns.ColoredDelta(p.diff))
    elseif pace and lvl == pace.curLevel and pace.curRef and pace.curMine > pace.curRef then
      row.pace:SetText(ns.ColoredDelta(pace.curMine - pace.curRef))
    else
      row.pace:SetText(dim)
    end
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
    local active = (id == currentTab)
    if fs then
      if active then fs:SetTextColor(r, g, b) else fs:SetTextColor(1, 1, 1) end
    end
    ns.SetColor(btn.underline, r, g, b, 1)
    btn.underline:SetShown(active)
  end
end

function ns.Refresh()
  if not frame or not frame:IsShown() then return end

  local agg = ns.GetAggregate(ns.viewSource)
  lastAgg = agg
  local t = agg.totals
  local pace = ns.GetPace(agg.source)

  frame.charBtn.value:SetText(SourceText(ns.viewSource))

  RefreshTiles(agg, pace)

  -- Composition bars
  ns.UpdateStackedBar(frame.actBar, ns.RowValues(t), frame.actBar.width)
  ns.UpdateStackedBar(frame.locBar, ns.LocValues(t), frame.locBar.width, t.total)

  -- Highlights
  local busy = agg.busiestLevel
    and string.format("Lv %d (%.0f%% combat)", agg.busiestLevel, (agg.busiestRatio or 0) * 100) or "-"
  local lazy = agg.laziestLevel
    and string.format("Lv %d (%.0f%% idle)", agg.laziestLevel, (agg.laziestRatio or 0) * 100) or "-"
  local topZone = ns.SortedZones(t.zones, 1)[1]
  frame.highlights:SetText(ns.Gold(
    "|cffffd200Busiest|r " .. busy .. "   |cffffd200Laziest|r " .. lazy
    .. (topZone and ("   |cffffd200Top zone|r " .. topZone.name) or "")))

  StyleTabs()
  if currentTab == "levels" then
    RefreshLevels(agg, pace)
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
local function BuildLevelsView(parent)
  local view = CreateFrame("Frame", nil, parent)
  view:SetAllPoints(parent)

  -- Column headers (aligned to the row columns in AcquireRow)
  local function Hdr(text, x, width, justify)
    local fs = view:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", view, "TOPLEFT", x, 0)
    if width then fs:SetWidth(width) end
    fs:SetJustifyH(justify or "LEFT")
    fs:SetText(text)
    ns.TrackAccent(fs)
    return fs
  end
  local hdr = Hdr("Lvl", 2)
  Hdr("Activity", 46)
  -- The columns after the activity bar follow its width (it stretches with
  -- the window), so they're chained off a spacer of the same width.
  local barSpan = CreateFrame("Frame", nil, view)
  barSpan:SetPoint("TOPLEFT", view, "TOPLEFT", 46, 0)
  barSpan:SetSize(ROW_BAR_W, 1)
  view.barSpan = barSpan
  local prevHdr = barSpan
  local function ColHdr(text, width)
    local fs = Hdr(text, 0, width, "RIGHT")
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", prevHdr, "TOPRIGHT", 8, 0)
    prevHdr = fs
    return fs
  end
  ColHdr("Kills", 46)
  ColHdr("Quests", 46)
  ColHdr("Time", 80)
  local paceHdr = ColHdr("Pace", 74)
  local paceHit = CreateFrame("Frame", nil, view)
  paceHit:SetAllPoints(paceHdr)
  paceHit:EnableMouse(true)
  paceHit:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Pace vs. " .. ns.GetPaceRefLabel(), 1, 1, 1)
    GameTooltip:AddLine("How much faster (green) or slower (red) each level was than your reference.", 0.8, 0.8, 0.8, true)
    GameTooltip:AddLine("/chrono pace changes the reference.", 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
  paceHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

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

local function CompositionBar(label, colors, labels, anchor, tipFn)
  local lab = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  lab:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -10)
  lab:SetWidth(60)
  lab:SetJustifyH("LEFT")
  lab:SetText(label)
  ns.TrackAccent(lab)

  local bar = ns.CreateStackedBar(frame, 14, colors)
  bar:SetPoint("LEFT", lab, "RIGHT", 4, 0)
  bar:SetPoint("RIGHT", frame, "RIGHT", -20, 0)
  bar.width = 480 -- approx; recomputed once laid out
  bar:EnableMouse(true)
  bar:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    tipFn(GameTooltip, (lastAgg or ns.GetAggregate(ns.viewSource)).totals)
    GameTooltip:Show()
  end)
  bar:SetScript("OnLeave", function() GameTooltip:Hide() end)

  local legend = ns.CreateLegend(frame, labels, colors)
  legend:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -4)
  return lab, bar, legend
end

local function UpdateBarWidths()
  for _, bar in ipairs({ frame.actBar, frame.locBar }) do
    local w = bar:GetWidth()
    if w and w > 0 then bar.width = w end
  end
end

-- Fit the size-dependent parts to the window's current width.
local function LayoutWindow()
  local w = frame:GetWidth() or DEFAULT_W
  extraW = math.max(0, math.floor(w - DEFAULT_W))
  local tw = math.max(TILE_W, (w - 40 - 3 * TILE_GAP) / 4)
  for i, def in ipairs(TILE_DEFS) do
    local tile = tiles[def.id]
    local col, line = (i - 1) % 4, math.floor((i - 1) / 4)
    tile:SetWidth(tw)
    tile:ClearAllPoints()
    tile:SetPoint("TOPLEFT", frame, "TOPLEFT", 20 + col * (tw + TILE_GAP), -48 - line * (TILE_H + TILE_GAP))
  end
  if views.levels and views.levels.barSpan then
    views.levels.barSpan:SetWidth(ROW_BAR_W + extraW)
  end
end

local function SaveGeometry()
  local db = ns.EnsureDB()
  db.window = db.window or {}
  local point, _, relPoint, x, y = frame:GetPoint()
  db.window.point, db.window.relPoint, db.window.x, db.window.y = point, relPoint, x, y
  db.window.w, db.window.h = frame:GetWidth(), frame:GetHeight()
end

local function BuildWindow()
  frame = CreateFrame("Frame", "ChronologFrame", UIParent, ns.BACKDROP_TEMPLATE)

  -- Restore saved size and position (falls back to the default size at the
  -- screen center on first use).
  local wdb = ns.EnsureDB()
  local saved = wdb.window or {}
  local function Clamp(v, lo, hi, def)
    v = tonumber(v) or def
    return math.min(hi, math.max(lo, v))
  end
  frame:SetSize(Clamp(saved.w, DEFAULT_W, MAX_W, DEFAULT_W), Clamp(saved.h, MIN_H, MAX_H, DEFAULT_H))
  frame:ClearAllPoints()
  if saved.point then
    frame:SetPoint(saved.point, UIParent, saved.relPoint or saved.point, saved.x or 0, saved.y or 0)
  else
    frame:SetPoint("CENTER")
  end
  frame:SetResizable(true)
  if frame.SetResizeBounds then
    frame:SetResizeBounds(DEFAULT_W, MIN_H, MAX_W, MAX_H)
  elseif frame.SetMinResize then
    frame:SetMinResize(DEFAULT_W, MIN_H)
    frame:SetMaxResize(MAX_W, MAX_H)
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
    SaveGeometry()
  end)
  frame:SetClampedToScreen(true)
  frame:Hide()
  tinsert(UISpecialFrames, "ChronologFrame")

  -- Header: icon, title and version on the left; the "Viewing" selector and
  -- the close button on the right. Both rows are 32px tall and sit one tile
  -- gap above the stat tiles.
  local header = CreateFrame("Frame", nil, frame)
  header:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -10)
  header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -20, -10)
  header:SetHeight(32)
  header:SetFrameLevel((frame:GetFrameLevel() or 1) + 5) -- above the skin's backdrop

  local iconBg = header:CreateTexture(nil, "ARTWORK")
  iconBg:SetSize(30, 30)
  iconBg:SetPoint("LEFT", header, "LEFT", 0, 0)
  ns.SetColor(iconBg, 0, 0, 0, 0.6)
  local icon = header:CreateTexture(nil, "OVERLAY")
  icon:SetPoint("TOPLEFT", iconBg, "TOPLEFT", 1, -1)
  icon:SetPoint("BOTTOMRIGHT", iconBg, "BOTTOMRIGHT", -1, 1)
  icon:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("LEFT", iconBg, "RIGHT", 10, 1)
  title:SetText("Chronolog")
  ns.TrackAccent(title)
  frame.title = title

  local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  local version = GetMeta and GetMeta(addonName, "Version")
  local ver = header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  ver:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 6, 1)
  ver:SetText(type(version) == "string" and ("v" .. version) or "")

  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("RIGHT", header, "RIGHT", 4, 0)
  close:SetFrameLevel((header:GetFrameLevel() or 1) + 1)

  -- "Viewing" selector, styled like the stat tiles. Opens a menu of your
  -- characters (or, on clients without the menu API, steps through them).
  local charBtn = CreateFrame("Button", nil, header)
  charBtn:SetSize(190, 32)
  charBtn:SetPoint("RIGHT", close, "LEFT", -6, 0)
  charBtn.bg = charBtn:CreateTexture(nil, "BACKGROUND")
  charBtn.bg:SetAllPoints(true)
  ns.SetColor(charBtn.bg, 0, 0, 0, 0.28)
  charBtn.edge = charBtn:CreateTexture(nil, "BORDER")
  charBtn.edge:SetPoint("TOPLEFT", charBtn, "TOPLEFT", 0, 0)
  charBtn.edge:SetPoint("BOTTOMLEFT", charBtn, "BOTTOMLEFT", 0, 0)
  charBtn.edge:SetWidth(2)
  charBtn.label = charBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  charBtn.label:SetPoint("TOPLEFT", charBtn, "TOPLEFT", 8, -4)
  charBtn.label:SetText("Viewing")
  ns.TrackAccent(charBtn.label)
  charBtn.value = charBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  charBtn.value:SetPoint("BOTTOMLEFT", charBtn, "BOTTOMLEFT", 8, 4)
  charBtn.value:SetPoint("RIGHT", charBtn, "RIGHT", -22, 0)
  charBtn.value:SetJustifyH("LEFT")
  charBtn.value:SetWordWrap(false)
  charBtn.arrow = charBtn:CreateTexture(nil, "OVERLAY")
  charBtn.arrow:SetSize(16, 16)
  charBtn.arrow:SetPoint("RIGHT", charBtn, "RIGHT", -4, 0)
  charBtn.arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
  charBtn.arrow:SetTexCoord(0, 1, 0, 0.5)

  local function SelectSource(id)
    ns.viewSource = id
    ns.Refresh()
  end
  charBtn:SetScript("OnClick", function(self)
    local sources = ns.GetSources()
    if MenuUtil and MenuUtil.CreateContextMenu then
      MenuUtil.CreateContextMenu(self, function(_, root)
        root:CreateTitle("Show data for")
        for i, src in ipairs(sources) do
          if src.id == "ALL" then root:CreateDivider() end
          local text = SourceText(src.id) .. (src.id == nil and "  |cff888888(you)|r" or "")
          root:CreateRadio(text,
            function(idx) return sources[idx].id == ns.viewSource end,
            function(idx) SelectSource(sources[idx].id) end, i)
        end
      end)
    else
      local idx = 1
      for i, src in ipairs(sources) do if src.id == ns.viewSource then idx = i end end
      SelectSource(sources[idx % #sources + 1].id)
    end
  end)
  charBtn:SetScript("OnEnter", function(self)
    ns.SetColor(self.bg, 1, 1, 1, 0.07)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Choose whose data to show", 1, 1, 1)
    GameTooltip:AddLine("This character, another of yours, or all of them combined. Characters appear here after you've logged them in once.", 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
  end)
  charBtn:SetScript("OnLeave", function(self)
    ns.SetColor(self.bg, 0, 0, 0, 0.28)
    GameTooltip:Hide()
  end)
  ns.SkinFonts(header)
  ns.SkinFonts(charBtn)
  frame.charBtn = charBtn

  -- Stat tiles: 4 x 2
  for i, def in ipairs(TILE_DEFS) do
    local tile = BuildTile(frame, def)
    local col, line = (i - 1) % 4, math.floor((i - 1) / 4)
    tile:SetPoint("TOPLEFT", frame, "TOPLEFT", 20 + col * (TILE_W + TILE_GAP), -48 - line * (TILE_H + TILE_GAP))
    tiles[def.id] = tile
  end

  -- Activity / location bars
  local actLab, actBar, actLegend = CompositionBar("Activity", ns.COLORS, ns.LABELS, tiles.gph, function(tip, t)
    tip:AddLine("What you were doing", 1, 1, 1)
    tip:AddLine(" ")
    for i, key in ipairs(ns.KEYS) do
      local c = ns.COLORS[i]
      tip:AddDoubleLine(ns.LABELS[i], FormatTime(t[key]) .. "  (" .. pct(t[key], t.total) .. ")", c[1], c[2], c[3], 1, 1, 1)
    end
    tip:AddDoubleLine("  of which idle", FormatTime(t.idle) .. "  (" .. pct(t.idle, t.total) .. ")", 0.6, 0.6, 0.6, 0.8, 0.8, 0.8)
  end)
  actLab:ClearAllPoints()
  actLab:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -48 - 2 * (TILE_H + TILE_GAP) - 8)
  frame.actBar = actBar

  local locLab, locBar, locLegend = CompositionBar("Location", ns.LOC_COLORS, ns.LOC_LABELS, actLegend, function(tip, t)
    tip:AddLine("Where you spent it", 1, 1, 1)
    tip:AddLine(" ")
    local known = 0
    for i, key in ipairs(ns.LOC_KEYS) do
      local c = ns.LOC_COLORS[i]
      known = known + t[key]
      tip:AddDoubleLine(ns.LOC_LABELS[i], FormatTime(t[key]) .. "  (" .. pct(t[key], t.total) .. ")", c[1], c[2], c[3], 1, 1, 1)
    end
    if t.total - known > 60 then
      tip:AddLine(" ")
      tip:AddDoubleLine("Not recorded (before v1.2)", FormatTime(t.total - known), 0.5, 0.5, 0.5, 0.7, 0.7, 0.7)
    end
  end)
  locLab:ClearAllPoints()
  locLab:SetPoint("TOPLEFT", actLab, "BOTTOMLEFT", 0, -22)
  frame.locBar = locBar

  local highlights = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  highlights:SetPoint("TOPLEFT", locLab, "BOTTOMLEFT", 0, -24)
  highlights:SetPoint("RIGHT", frame, "RIGHT", -20, 0)
  highlights:SetJustifyH("LEFT")
  frame.highlights = highlights

  -- Tabs
  local tabs = {
    { id = "levels", label = "Levels" },
    { id = "zones", label = "Zones" },
    { id = "rep", label = "Reputation" },
    { id = "charts", label = "Charts" },
  }
  local prevTab
  for _, t in ipairs(tabs) do
    local btn = MakeButton(frame, t.label, 90, 22)
    if prevTab then
      btn:SetPoint("LEFT", prevTab, "RIGHT", 6, 0)
    else
      btn:SetPoint("TOPLEFT", highlights, "BOTTOMLEFT", 0, -12)
    end
    btn.underline = btn:CreateTexture(nil, "OVERLAY")
    btn.underline:SetHeight(2)
    btn.underline:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 4, -3)
    btn.underline:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -4, -3)
    btn:SetScript("OnClick", function() SelectTab(t.id) end)
    tabButtons[t.id] = btn
    prevTab = btn
  end

  -- Body: holds the views
  local body = CreateFrame("Frame", nil, frame)
  body:SetPoint("TOPLEFT", tabButtons.levels, "BOTTOMLEFT", 0, -10)
  body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -20, 34)

  views.levels = BuildLevelsView(body)
  views.zones = ns.BuildZonesView(body)
  views.rep = ns.BuildReputationView(body)
  views.charts = ns.BuildChartsView(body)
  views.zones:Hide()
  views.rep:Hide()
  views.charts:Hide()

  -- footer hint
  local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 20, 16)
  hint:SetText("Hover anything for details   |   /chrono help")

  -- Resize grip (bottom-right). Right-click puts the default size back.
  local grip = CreateFrame("Button", nil, frame)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -9, 9)
  grip:SetFrameLevel((frame:GetFrameLevel() or 1) + 10)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  grip:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  grip:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" then frame:StartSizing("BOTTOMRIGHT") end
  end)
  grip:SetScript("OnMouseUp", function(_, button)
    frame:StopMovingOrSizing()
    if button == "RightButton" then frame:SetSize(DEFAULT_W, DEFAULT_H) end
    SaveGeometry()
  end)
  grip:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Drag to resize", 1, 1, 1)
    GameTooltip:AddLine("Right-click to reset the size.", 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
  grip:SetScript("OnLeave", function() GameTooltip:Hide() end)
  frame.grip = grip

  -- Re-lay out right away while resizing (cheap), but redraw the contents at
  -- most every 0.05s.
  frame:SetScript("OnSizeChanged", function(self)
    LayoutWindow()
    self.resized = true
  end)

  -- live refresh while shown
  frame:SetScript("OnShow", function(self)
    LayoutWindow()
    UpdateBarWidths()
    ns.Refresh()
    self.elapsed = 0
  end)
  frame:SetScript("OnUpdate", function(self, e)
    self.elapsed = (self.elapsed or 0) + e
    if self.elapsed >= 1 or (self.resized and self.elapsed >= 0.05) then
      self.elapsed = 0
      self.resized = false
      UpdateBarWidths()
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
