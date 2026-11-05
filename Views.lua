--[[
  Chronolog-Forever - Views
  -------------------------
  The "Zones" and "Charts" tabs of the main window. Each builder returns a frame
  with a Refresh(agg) method; the main window calls it once a second while the
  tab is visible.
]]

local addonName, ns = ...

local FormatTime = ns.FormatTime

--------------------------------------------------------------------------------
-- Zones: time spent per zone, biggest first
--------------------------------------------------------------------------------
local ZONE_ROW_H = 20
local ZONE_BAR_W = 130

function ns.BuildZonesView(parent)
  local view = CreateFrame("Frame", nil, parent)
  view:SetAllPoints(parent)

  local hdrName = view:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  hdrName:SetPoint("TOPLEFT", view, "TOPLEFT", 2, 0)
  hdrName:SetText("Zone")
  ns.TrackAccent(hdrName)
  local hdrPct = view:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  hdrPct:SetPoint("TOPLEFT", view, "TOPLEFT", 340, 0)
  hdrPct:SetWidth(40)
  hdrPct:SetJustifyH("RIGHT")
  hdrPct:SetText("Share")
  ns.TrackAccent(hdrPct)
  local hdrTime = view:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  hdrTime:SetPoint("TOPLEFT", view, "TOPLEFT", 384, 0)
  hdrTime:SetWidth(80)
  hdrTime:SetJustifyH("RIGHT")
  hdrTime:SetText("Time")
  ns.TrackAccent(hdrTime)

  local scroll = CreateFrame("ScrollFrame", "ChronologZonesScroll", view, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", view, "TOPLEFT", 0, -18)
  scroll:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -14, 0)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(1, 1)
  scroll:SetScrollChild(content)

  ns.WhenSkinned(function(S)
    S.ScrollBar(scroll.ScrollBar or _G["ChronologZonesScrollScrollBar"])
  end)
  ns.SkinFonts(view)

  local rows = {}
  local function AcquireRow(i)
    local row = rows[i]
    if row then return row end
    row = CreateFrame("Frame", nil, content)
    row:SetHeight(ZONE_ROW_H)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.name:SetWidth(200)
    row.name:SetJustifyH("LEFT")
    row.bar = row:CreateTexture(nil, "ARTWORK")
    row.bar:SetHeight(10)
    row.bar:SetPoint("LEFT", row, "LEFT", 206, 0)
    row.pct = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.pct:SetPoint("LEFT", row, "LEFT", 340, 0)
    row.pct:SetWidth(40)
    row.pct:SetJustifyH("RIGHT")
    row.time = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.time:SetPoint("LEFT", row, "LEFT", 384, 0)
    row.time:SetWidth(80)
    row.time:SetJustifyH("RIGHT")
    ns.SkinFonts(row)
    rows[i] = row
    return row
  end

  function view.Refresh(agg)
    local list = ns.SortedZones(agg.totals.zones)
    local total = agg.totals.total
    local top = list[1] and list[1].secs or 0
    local r, g, b = ns.GetAccent()

    local width = scroll:GetWidth()
    if width and width > 0 then content:SetWidth(width) end

    for i, z in ipairs(list) do
      local row = AcquireRow(i)
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i - 1) * ZONE_ROW_H)
      row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -(i - 1) * ZONE_ROW_H)
      row.name:SetText(z.name)
      ns.SetColor(row.bar, r, g, b, 0.85)
      row.bar:SetWidth(math.max(1, (top > 0 and z.secs / top or 0) * ZONE_BAR_W))
      row.pct:SetText(total > 0 and string.format("%.0f%%", z.secs / total * 100) or "-")
      row.time:SetText(FormatTime(z.secs))
      row:Show()
    end
    for i = #list + 1, #rows do rows[i]:Hide() end
    content:SetHeight(math.max(#list * ZONE_ROW_H, 1))
  end

  return view
end

--------------------------------------------------------------------------------
-- Charts: one bar per level for a chosen metric
--------------------------------------------------------------------------------
function ns.BuildChartsView(parent)
  local view = CreateFrame("Frame", nil, parent)
  view:SetAllPoints(parent)

  local metricIndex = 1

  local btn = CreateFrame("Button", nil, view, "UIPanelButtonTemplate")
  btn:SetSize(220, 20)
  btn:SetPoint("TOPLEFT", view, "TOPLEFT", 0, 0)
  btn:SetScript("OnClick", function()
    metricIndex = metricIndex % #ns.METRICS + 1
    if ns.Refresh then ns.Refresh() end
  end)
  btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Click to change the metric", 1, 1, 1)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  local maxText = view:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  maxText:SetPoint("TOPRIGHT", view, "TOPRIGHT", -4, -4)

  local area = CreateFrame("Frame", nil, view)
  area:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -8)
  area:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -4, 18)
  local bg = area:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(true)
  ns.SetColor(bg, 0, 0, 0, 0.3)

  local empty = view:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  empty:SetPoint("CENTER", area, "CENTER", 0, 0)
  empty:SetText("Not enough data yet - play a level for a minute or two.")

  ns.WhenSkinned(function(S) S.Button(btn) end)
  ns.SkinFonts(view)

  local bars = {}
  local function AcquireBar(i)
    local bar = bars[i]
    if bar then return bar end
    bar = CreateFrame("Frame", nil, area)
    bar:EnableMouse(true)
    bar.tex = bar:CreateTexture(nil, "ARTWORK")
    bar.tex:SetAllPoints(true)
    bar.label = bar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    bar.label:SetPoint("TOP", bar, "BOTTOM", 0, -2)
    bar:SetScript("OnEnter", function(self)
      self.tex:SetAlpha(1)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine("Level " .. (self.lvl or "?"), 1, 1, 1)
      GameTooltip:AddDoubleLine(self.metric.label, self.metric.fmt(self.value or 0), 0.8, 0.8, 0.8, 1, 1, 1)
      if self.row then
        GameTooltip:AddDoubleLine("Time played", FormatTime(self.row.total), 0.8, 0.8, 0.8, 1, 1, 1)
      end
      GameTooltip:Show()
    end)
    bar:SetScript("OnLeave", function(self)
      self.tex:SetAlpha(0.85)
      GameTooltip:Hide()
    end)
    bars[i] = bar
    return bar
  end

  function view.Refresh(agg)
    local metric = ns.METRICS[metricIndex]
    btn:SetText("Metric: " .. metric.label .. "  >")

    -- Only levels with tracked time get a bar.
    local points = {}
    for _, lvl in ipairs(agg.levels) do
      local row = agg.rows[lvl]
      if row.total > 0 then
        points[#points + 1] = { lvl = lvl, row = row, value = metric.get(row) }
      end
    end

    local maxV = 0
    for _, p in ipairs(points) do if p.value > maxV then maxV = p.value end end

    empty:SetShown(#points == 0)
    maxText:SetText(#points > 0 and ("max " .. metric.fmt(maxV)) or "")

    local width = area:GetWidth()
    local height = area:GetHeight()
    if not width or width < 10 then width = 480 end
    if not height or height < 10 then height = 200 end
    local n = #points
    local slot = n > 0 and (width / n) or width
    local r, g, b = ns.GetAccent()
    local plotH = height - 16

    for i, p in ipairs(points) do
      local bar = AcquireBar(i)
      bar.lvl, bar.value, bar.row, bar.metric = p.lvl, p.value, p.row, metric
      bar:ClearAllPoints()
      bar:SetPoint("BOTTOMLEFT", area, "BOTTOMLEFT", (i - 1) * slot + 1, 0)
      bar:SetWidth(math.max(1, slot - 2))
      bar:SetHeight(math.max(1, (maxV > 0 and p.value / maxV or 0) * plotH))
      ns.SetColor(bar.tex, r, g, b, 1)
      bar.tex:SetAlpha(0.85)
      if n <= 15 or p.lvl % 5 == 0 or i == 1 then
        bar.label:SetText(p.lvl)
        bar.label:Show()
      else
        bar.label:Hide()
      end
      bar:Show()
    end
    for i = n + 1, #bars do bars[i]:Hide() end
  end

  return view
end
