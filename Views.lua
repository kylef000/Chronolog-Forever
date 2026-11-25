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
    row.hl = row:CreateTexture(nil, "BACKGROUND")
    row.hl:SetAllPoints(true)
    ns.SetColor(row.hl, 1, 1, 1, 0.06)
    row.hl:Hide()
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
      self.hl:Show()
      if not self.zone then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddDoubleLine(self.zone, FormatTime(self.secs), 1, 1, 1, 1, 1, 1)
      local subs = ns.SortedZones(self.subs, 12)
      if #subs > 0 then
        GameTooltip:AddLine(" ")
        for _, s in ipairs(subs) do
          GameTooltip:AddDoubleLine(s.name ~= "" and s.name or "|cff888888(open area)|r",
            string.format("%s  |cff888888%.0f%%|r", FormatTime(s.secs), s.secs / self.secs * 100),
            0.85, 0.85, 0.85, 0.8, 0.8, 0.8)
        end
      else
        GameTooltip:AddLine("Subzones are recorded from v1.3 on.", 0.6, 0.6, 0.6)
      end
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function(self)
      self.hl:Hide()
      GameTooltip:Hide()
    end)
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
      row.zone, row.secs, row.subs = z.name, z.secs, agg.totals.subzones[z.name]
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
-- Charts: one column per level, in several modes
--   Time   - stacked by activity (+ time from before tracking)
--   Where  - share of the level spent in the open world / town / dungeons / PvP
--   Pace   - gain/loss per level against your reference, plus the running total
--   XP/hr, Kills/hr, Gold/hr - per-level rates with your average
--   Deaths - deaths per level
--------------------------------------------------------------------------------
local MODES = {
  { id = "time",   label = "Time" },
  { id = "where",  label = "Where" },
  { id = "pace",   label = "Pace" },
  { id = "xph",    label = "XP/hr" },
  { id = "kph",    label = "Kills/hr" },
  { id = "gph",    label = "Gold/hr" },
  { id = "deaths", label = "Deaths" },
}

local TIME_STEPS = { 60, 120, 300, 600, 900, 1200, 1800, 3600, 7200, 10800, 14400, 21600, 43200, 86400 }

local function TimeStep(x)
  for _, s in ipairs(TIME_STEPS) do if s >= x then return s end end
  return math.ceil(x / 86400) * 86400
end

local function NiceStep(x)
  if x <= 0 then return 1 end
  local e = 10 ^ math.floor(math.log10(x))
  local f = x / e
  local n = (f <= 1 and 1) or (f <= 2 and 2) or (f <= 2.5 and 2.5) or (f <= 5 and 5) or 10
  return n * e
end

local function SignedShortTime(v)
  if v > 0 then return "+" .. ns.FormatShortTime(v) end
  if v < 0 then return "-" .. ns.FormatShortTime(-v) end
  return "0"
end

-- Compact signed delta for labels: "-45s", "+4m", "-1.5h".
local function ShortDelta(v)
  local sign = v < 0 and "-" or "+"
  local a = math.abs(v)
  if a < 60 then return sign .. string.format("%ds", math.floor(a + 0.5)) end
  return sign .. ns.FormatShortTime(a)
end

local function LegendText(labels, colors)
  local parts = {}
  for i, l in ipairs(labels) do parts[#parts + 1] = ns.Hex(colors[i]) .. l .. "|r" end
  return table.concat(parts, "  ")
end

-- Build the data for a mode. Returns a spec:
--   points = { { lvl, segs = { { v, color, gradient } }, tip = fn(tooltip) } }
--   kind   = "stack" | "diverge";  isTime; fixedMax; minStep
--   fmt    = axis label formatter;  avg (optional) dashed line
--   line   = { [i] = value } (optional; running-total line)
--   caption, empty
local function BuildSpec(mode, agg, pace)
  local spec = { points = {}, kind = "stack", fmt = tostring }
  local cur = (agg.source == nil) and ns.state.currentLevel or nil
  local accent = { ns.GetAccent() }

  if mode == "time" then
    spec.isTime, spec.fmt = true, ns.FormatShortTime
    local sum, n = 0, 0
    for _, lvl in ipairs(agg.levels) do
      local row = agg.rows[lvl]
      local lt = ns.LevelTime(row)
      if lt > 0 then
        local segs = {}
        for i, key in ipairs(ns.KEYS) do segs[#segs + 1] = { row[key], ns.COLORS[i] } end
        segs[#segs + 1] = { row.lost or 0, ns.LOST_COLOR }
        segs[#segs + 1] = { row.untracked or 0, ns.UNTRACKED_COLOR }
        spec.points[#spec.points + 1] = { lvl = lvl, segs = segs, tip = function(tip)
          tip:AddLine("Level " .. lvl .. (lvl == cur and " (current)" or ""), 1, 1, 1)
          tip:AddLine(" ")
          ns.AddBreakdown(tip, row, agg.avg, pace and pace.levels[lvl])
        end }
        if lvl ~= cur then sum, n = sum + lt, n + 1 end
      end
    end
    if n > 1 then spec.avg = sum / n end
    spec.caption = LegendText(ns.LABELS, ns.COLORS) .. "  " .. ns.Hex(ns.LOST_COLOR) .. "Not recorded|r  "
      .. ns.Hex(ns.UNTRACKED_COLOR) .. "Before tracking|r"
      .. "   |cff888888dashed: avg|r"
    spec.empty = "No tracked time yet."

  elseif mode == "where" then
    spec.fixedMax, spec.minStep = 100, 25
    spec.fmt = function(v) return string.format("%d%%", v) end
    for _, lvl in ipairs(agg.levels) do
      local row = agg.rows[lvl]
      local locSum = row.world + row.town + row.instance + row.pvp
      if row.total > 0 and locSum > 0 then
        local segs = {}
        for i, key in ipairs(ns.LOC_KEYS) do
          segs[#segs + 1] = { row[key] / row.total * 100, ns.LOC_COLORS[i] }
        end
        spec.points[#spec.points + 1] = { lvl = lvl, segs = segs, tip = function(tip)
          tip:AddLine("Level " .. lvl .. " - where you spent it", 1, 1, 1)
          tip:AddLine(" ")
          for i, key in ipairs(ns.LOC_KEYS) do
            local c = ns.LOC_COLORS[i]
            tip:AddDoubleLine(ns.LOC_LABELS[i], string.format("%s  |cff888888%.0f%%|r",
              FormatTime(row[key]), row[key] / row.total * 100), c[1], c[2], c[3], 1, 1, 1)
          end
          local zones = ns.SortedZones(row.zones, 3)
          if #zones > 0 then
            tip:AddLine(" ")
            for _, z in ipairs(zones) do tip:AddDoubleLine(z.name, FormatTime(z.secs), 1, 1, 1, 0.8, 0.8, 0.8) end
          end
        end }
      end
    end
    spec.caption = LegendText(ns.LOC_LABELS, ns.LOC_COLORS)
    spec.empty = "Location tracking starts with this version - play a little and it fills in."

  elseif mode == "pace" then
    -- Two bars per level: your time next to the reference's, with the gain or
    -- loss written above the pair.
    spec.isTime, spec.fmt = true, ns.FormatShortTime
    local you, ref = accent, ns.REF_COLOR
    local refLabel = pace and pace.refLabel or "best splits"
    local refTitle = (refLabel == "best splits") and "Best splits" or refLabel
    if pace then
      for lvl = 1, ns.MAX_LEVEL do
        local p = pace.levels[lvl]
        if p then
          local dc = p.diff <= 0 and ns.AHEAD_COLOR or ns.BEHIND_COLOR
          spec.points[#spec.points + 1] = {
            lvl = lvl,
            pair = { { p.mine, you }, { p.ref, ref } },
            top = ns.Hex(dc) .. ShortDelta(p.diff) .. "|r",
            tip = function(tip)
              tip:AddLine("Level " .. lvl, 1, 1, 1)
              tip:AddDoubleLine("You", FormatTime(p.mine), you[1], you[2], you[3], 1, 1, 1)
              tip:AddDoubleLine(refLabel == "best splits" and ("Best split (" .. (p.refName or "?") .. ")") or refLabel,
                FormatTime(p.ref), ref[1], ref[2], ref[3], 1, 1, 1)
              tip:AddLine(" ")
              tip:AddDoubleLine(p.diff <= 0 and "Faster by" or "Slower by", ns.ColoredDelta(p.diff),
                0.8, 0.8, 0.8, 1, 1, 1)
              tip:AddDoubleLine("Running total after this level", ns.ColoredDelta(p.cum), 0.8, 0.8, 0.8, 1, 1, 1)
            end,
          }
        end
      end
      -- The level in progress: your time so far against the reference's full time.
      if pace.curLevel and pace.curRef then
        local behind = pace.curMine > pace.curRef
        spec.points[#spec.points + 1] = {
          lvl = pace.curLevel,
          pair = { { pace.curMine, you, nil, 0.45 }, { pace.curRef, ref, nil, 0.45 } },
          top = behind and (ns.Hex(ns.BEHIND_COLOR) .. ShortDelta(pace.curMine - pace.curRef) .. "|r") or "|cff888888...|r",
          tip = function(tip)
            tip:AddLine("Level " .. pace.curLevel .. " (in progress)", 1, 1, 1)
            tip:AddDoubleLine("You so far", FormatTime(pace.curMine), you[1], you[2], you[3], 1, 1, 1)
            tip:AddDoubleLine(refTitle, FormatTime(pace.curRef), ref[1], ref[2], ref[3], 1, 1, 1)
            if behind then
              tip:AddLine("Already slower than the reference on this level.", 1, 0.45, 0.4, true)
            else
              tip:AddLine("Ding within " .. FormatTime(pace.curRef - pace.curMine) .. " to beat it.", 0.3, 0.85, 0.4, true)
            end
          end,
        }
      end
      if pace.n > 0 then
        spec.headline = string.format("%s overall vs %s  |cff888888(%s over %d finished %s)|r",
          ns.ColoredDelta(pace.cum), refLabel, pace.cum <= 0 and "ahead" or "behind",
          pace.n, pace.n == 1 and "level" or "levels")
      end
    end
    spec.caption = ns.Hex(you) .. "You|r  vs  " .. ns.Hex(ref) .. refTitle .. "|r"
      .. "   |cff888888above each pair: " .. ns.Hex(ns.AHEAD_COLOR) .. "faster|r|cff888888 / |r"
      .. ns.Hex(ns.BEHIND_COLOR) .. "slower|r"
    if agg.source == "ALL" then
      spec.empty = "Pick a single character to see its pace."
    elseif pace and not pace.hasOthers then
      spec.empty = "Pace compares your levels with your other characters.\nLevel another character with Chronolog-Forever to unlock it."
    else
      spec.empty = "No finished levels to compare yet."
    end

  else
    -- Rates and deaths: one accent column per level.
    local get, avg
    if mode == "xph" then
      get, avg, spec.fmt = function(r) return ns.PerHour(r, "xp") end, agg.avg.xph, ns.FormatNumber
    elseif mode == "kph" then
      get, avg = function(r) return ns.PerHour(r, "kills") end, agg.avg.kph
      spec.fmt = function(v) return string.format("%.0f", v) end
    elseif mode == "gph" then
      get, avg = function(r) return ns.PerHour(r, "gold", 10000) end, agg.avg.gph
      spec.fmt = function(v) return v == math.floor(v) and string.format("%dg", v) or string.format("%.1fg", v) end
    else -- deaths
      get, spec.minStep = function(r) return r.deaths end, 1
      spec.fmt = function(v) return string.format("%d", v) end
    end
    local color = (mode == "deaths") and ns.COLORS[5] or accent
    local label
    for _, m in ipairs(MODES) do if m.id == mode then label = m.label end end
    for _, lvl in ipairs(agg.levels) do
      local row = agg.rows[lvl]
      if row.total >= ns.MIN_TOTAL_FOR_RATIO or (mode == "deaths" and row.total > 0) then
        local v = get(row)
        spec.points[#spec.points + 1] = { lvl = lvl, segs = { { v, color, true } }, tip = function(tip)
          tip:AddLine("Level " .. lvl .. (lvl == cur and " (current)" or ""), 1, 1, 1)
          tip:AddDoubleLine(label, spec.fmt(v), 0.8, 0.8, 0.8, 1, 1, 1)
          if avg and avg > 0 then
            tip:AddDoubleLine("Your average", spec.fmt(avg), 0.6, 0.6, 0.6, 0.8, 0.8, 0.8)
          end
          tip:AddDoubleLine("Time at level", FormatTime(ns.LevelTime(row)), 0.6, 0.6, 0.6, 0.8, 0.8, 0.8)
        end }
      end
    end
    if avg and avg > 0 then
      spec.avg = avg
      spec.caption = "|cff888888dashed: your average level|r"
    else
      spec.caption = ""
    end
    spec.empty = "Not enough data yet - play a level for a minute or two."
  end
  return spec
end

function ns.BuildChartsView(parent)
  local view = CreateFrame("Frame", nil, parent)
  view:SetAllPoints(parent)

  local db = ns.EnsureDB()
  local mode = db.chartMode or "time"

  -- Mode selector
  local modeBtns = {}
  local prev
  for _, m in ipairs(MODES) do
    local b = CreateFrame("Button", nil, view, "UIPanelButtonTemplate")
    b:SetSize(70, 20)
    b:SetText(m.label)
    if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", view, "TOPLEFT", 0, 0) end
    b:SetScript("OnClick", function()
      mode = m.id
      ns.EnsureDB().chartMode = m.id
      if ns.Refresh then ns.Refresh() end
    end)
    b.mode = m.id
    ns.WhenSkinned(function(S) S.Button(b) end)
    modeBtns[#modeBtns + 1] = b
    prev = b
  end

  -- Plot area (left gutter for axis labels, bottom gutter for level labels)
  local area = CreateFrame("Frame", nil, view)
  area:SetPoint("TOPLEFT", view, "TOPLEFT", 40, -32)
  area:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -6, 40)
  local bg = area:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(true)
  ns.SetColor(bg, 0, 0, 0, 0.25)

  -- Annotations (average line, headline, running-total line) live on their
  -- own frame above the columns: the columns are child frames of `area`, so
  -- anything drawn on `area` itself would end up behind the bars.
  local fg = CreateFrame("Frame", nil, area)
  fg:SetAllPoints(area)
  fg:SetFrameLevel((area:GetFrameLevel() or 1) + 20)

  local empty = view:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  empty:SetPoint("CENTER", area, "CENTER", 0, 0)
  empty:SetWidth(380)

  -- One-line summary drawn inside the plot (pace: running total).
  local headline = fg:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  headline:SetPoint("TOPLEFT", area, "TOPLEFT", 6, -6)
  headline:SetJustifyH("LEFT")

  local caption = view:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  caption:SetPoint("BOTTOMLEFT", view, "BOTTOMLEFT", 0, 2)
  caption:SetJustifyH("LEFT")

  -- Pace reference switcher (only in pace mode)
  local refBtn = CreateFrame("Button", nil, view, "UIPanelButtonTemplate")
  refBtn:SetSize(120, 18)
  refBtn:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -6, 0)
  refBtn:SetText("Change reference")
  refBtn:SetScript("OnClick", function() ns.CyclePaceRef() end)
  refBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Pace reference", 1, 1, 1)
    GameTooltip:AddLine("Best splits = the fastest time any of your other characters took for each level.", 0.8, 0.8, 0.8, true)
    GameTooltip:AddLine("Click to cycle through best splits and each of your characters.", 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
  end)
  refBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  ns.WhenSkinned(function(S) S.Button(refBtn) end)

  ns.SkinFonts(view)

  -- Pools ---------------------------------------------------------------------
  local grid, cols, dashes, lines, dots = {}, {}, {}, {}, {}

  local function Grid(i)
    local g = grid[i]
    if g then return g end
    g = {}
    g.line = area:CreateTexture(nil, "BORDER")
    g.line:SetHeight(1)
    g.label = view:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    g.label:SetJustifyH("RIGHT")
    g.label:SetWidth(36)
    grid[i] = g
    return g
  end

  local function Col(i)
    local c = cols[i]
    if c then return c end
    c = CreateFrame("Frame", nil, area)
    c:EnableMouse(true)
    c.hl = c:CreateTexture(nil, "BACKGROUND")
    c.hl:SetAllPoints(true)
    c.segs = {}
    c.label = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    c.label:SetPoint("TOP", c, "BOTTOM", 0, -3)
    c.top = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c:SetScript("OnEnter", function(self)
      ns.SetColor(self.hl, 1, 1, 1, 0.08)
      if self.tip then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        self.tip(GameTooltip)
        GameTooltip:Show()
      end
    end)
    c:SetScript("OnLeave", function(self)
      ns.SetColor(self.hl, 1, 1, 1, self.isCurrent and 0.04 or 0)
      GameTooltip:Hide()
    end)
    cols[i] = c
    return c
  end

  local function Seg(c, j)
    local t = c.segs[j]
    if t then return t end
    t = c:CreateTexture(nil, "ARTWORK")
    c.segs[j] = t
    return t
  end

  local function Dash(i)
    local d = dashes[i]
    if d then return d end
    d = fg:CreateTexture(nil, "ARTWORK")
    d:SetSize(6, 1)
    dashes[i] = d
    return d
  end
  local avgLabel = fg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  avgLabel:SetJustifyH("RIGHT")
  -- Dark backing so the label stays readable on top of a bar.
  local avgBg = fg:CreateTexture(nil, "BORDER")
  avgBg:SetPoint("TOPLEFT", avgLabel, "TOPLEFT", -3, 2)
  avgBg:SetPoint("BOTTOMRIGHT", avgLabel, "BOTTOMRIGHT", 3, -2)
  ns.SetColor(avgBg, 0, 0, 0, 0.7)

  local function Line(i)
    local l = lines[i]
    if l then return l end
    if not fg.CreateLine then return nil end
    l = fg:CreateLine(nil, "OVERLAY")
    lines[i] = l
    return l
  end
  local function Dot(i)
    local d = dots[i]
    if d then return d end
    d = fg:CreateTexture(nil, "OVERLAY")
    d:SetSize(5, 5)
    dots[i] = d
    return d
  end

  local function HideFrom(pool, n)
    for i = n + 1, #pool do
      local o = pool[i]
      if o.line then o.line:Hide(); o.label:Hide() else o:Hide() end
    end
  end

  -- Refresh -------------------------------------------------------------------
  function view.Refresh(agg)
    local r, g, b = ns.GetAccent()
    for _, btn in ipairs(modeBtns) do
      local fs = btn:GetFontString()
      if fs then
        if btn.mode == mode then fs:SetTextColor(r, g, b) else fs:SetTextColor(1, 1, 1) end
      end
    end

    local pace = ns.GetPace(agg.source)
    local spec = BuildSpec(mode, agg, pace)
    caption:SetText(spec.caption or "")
    headline:SetText(spec.headline or "")
    headline:SetShown(spec.headline ~= nil and #spec.points > 0)
    refBtn:SetShown(mode == "pace" and agg.source ~= "ALL")
    if mode == "pace" then refBtn:SetText("vs " .. ns.GetPaceRefLabel()) end

    local points = spec.points
    local n = #points
    empty:SetShown(n == 0)
    empty:SetText(spec.empty or "")
    if n == 0 then
      HideFrom(grid, 0); HideFrom(cols, 0); HideFrom(dashes, 0); HideFrom(lines, 0); HideFrom(dots, 0)
      avgLabel:Hide(); avgBg:Hide()
      return
    end

    -- Value range
    local maxPos, maxNeg = 0, 0
    for _, p in ipairs(points) do
      local pos, neg = 0, 0
      if p.pair then
        for _, s in ipairs(p.pair) do if s[1] > pos then pos = s[1] end end
      else
        for _, s in ipairs(p.segs) do
          if s[1] > 0 then pos = pos + s[1] else neg = neg + s[1] end
        end
      end
      if pos > maxPos then maxPos = pos end
      if neg < maxNeg then maxNeg = neg end
    end
    if spec.line then
      for _, v in pairs(spec.line) do
        if v > maxPos then maxPos = v end
        if v < maxNeg then maxNeg = v end
      end
    end
    if spec.avg and spec.avg > maxPos then maxPos = spec.avg end
    -- Headroom for the labels above the columns and the headline.
    if points[1].top then maxPos = maxPos * 1.12 end
    if spec.headline then maxPos = maxPos * 1.12 end

    local yMin, yMax, step
    if spec.kind == "diverge" then
      local m = math.max(maxPos, -maxNeg, 1)
      step = spec.isTime and TimeStep(m / 2) or NiceStep(m / 2)
      yMax = step * math.ceil(m / step)
      yMin = -yMax
    else
      local m = spec.fixedMax or math.max(maxPos, 1e-9)
      step = spec.isTime and TimeStep(m / 4) or NiceStep(m / 4)
      if spec.minStep and step < spec.minStep then step = spec.minStep end
      yMin = 0
      yMax = math.max(step, step * math.ceil(m / step - 1e-9))
    end

    local W, H = area:GetWidth(), area:GetHeight()
    if not W or W < 10 then W = 480 end
    if not H or H < 10 then H = 220 end
    local function Y(v) return (v - yMin) / (yMax - yMin) * H end

    -- Gridlines
    local gi = 0
    local v = yMin
    while v <= yMax + step * 0.01 and gi < 20 do
      gi = gi + 1
      local gl = Grid(gi)
      local y = Y(v)
      gl.line:ClearAllPoints()
      gl.line:SetPoint("BOTTOMLEFT", area, "BOTTOMLEFT", 0, y)
      gl.line:SetPoint("BOTTOMRIGHT", area, "BOTTOMRIGHT", 0, y)
      ns.SetColor(gl.line, 1, 1, 1, math.abs(v) < step * 0.01 and 0.35 or 0.08)
      gl.label:ClearAllPoints()
      gl.label:SetPoint("RIGHT", area, "BOTTOMLEFT", -4, y)
      gl.label:SetText(spec.fmt(v))
      gl.line:Show(); gl.label:Show()
      v = v + step
    end
    HideFrom(grid, gi)

    -- Columns
    local slot = W / n
    local paired = points[1].pair ~= nil
    local barW = math.max(2, math.min(slot * (paired and 0.8 or 0.7), paired and 36 or 26))
    local inset = (slot - barW) / 2
    local cur = (agg.source == nil) and ns.state.currentLevel or nil
    local every = (n <= 20) and 1 or 5
    for i, p in ipairs(points) do
      local c = Col(i)
      c.tip = p.tip
      c.isCurrent = (p.lvl == cur)
      c:ClearAllPoints()
      c:SetPoint("BOTTOMLEFT", area, "BOTTOMLEFT", (i - 1) * slot, 0)
      c:SetSize(slot, H)
      ns.SetColor(c.hl, 1, 1, 1, c.isCurrent and 0.04 or 0)

      local pos, neg = 0, 0
      local j = 0
      local top = 0
      if p.pair then
        -- Side-by-side bars (pace: you vs. the reference).
        local half = math.max(1, barW / 2 - 1)
        for k, s in ipairs(p.pair) do
          local val, color = s[1], s[2]
          if val > top then top = val end
          if val > 0 then
            j = j + 1
            local t = Seg(c, j)
            t:ClearAllPoints()
            t:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", inset + (k - 1) * (barW / 2) + (k - 1), Y(0))
            t:SetSize(half, math.max(1, Y(val) - Y(0)))
            ns.SetColor(t, color[1], color[2], color[3], s[4] or 0.9)
            t:Show()
          end
        end
      end
      for _, s in ipairs(p.pair and {} or p.segs) do
        local val, color = s[1], s[2]
        if val ~= 0 then
          local lo, hi
          if val > 0 then lo, hi = pos, pos + val; pos = hi else lo, hi = neg + val, neg; neg = lo end
          local y0, y1 = Y(lo), Y(hi)
          if y1 - y0 >= 0.5 then
            j = j + 1
            local t = Seg(c, j)
            t:ClearAllPoints()
            t:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", inset, y0)
            t:SetSize(barW, y1 - y0)
            if s[3] and t.SetGradient and CreateColor then
              ns.SetColor(t, 1, 1, 1, 1)
              t:SetGradient("VERTICAL", CreateColor(color[1] * 0.45, color[2] * 0.45, color[3] * 0.45, 0.9),
                CreateColor(color[1], color[2], color[3], 0.95))
            else
              ns.SetColor(t, color[1], color[2], color[3], 0.9)
            end
            t:Show()
          end
        end
      end
      for k = j + 1, #c.segs do c.segs[k]:Hide() end

      -- Value written above the column (pace: gain/loss), if there's room.
      if p.top and slot >= 18 then
        c.top:ClearAllPoints()
        c.top:SetPoint("BOTTOM", c, "BOTTOMLEFT", slot / 2, Y(top) + 2)
        c.top:SetText(p.top)
        c.top:Show()
      else
        c.top:Hide()
      end

      if every == 1 or p.lvl % every == 0 or i == 1 or i == n or c.isCurrent then
        c.label:SetText(p.lvl)
        if c.isCurrent then c.label:SetTextColor(r, g, b) else c.label:SetTextColor(0.55, 0.55, 0.55) end
        c.label:Show()
      else
        c.label:Hide()
      end
      c:Show()
    end
    HideFrom(cols, n)

    -- Dashed average line
    local nd = 0
    if spec.avg and spec.avg > 0 then
      local y = Y(spec.avg)
      local x = 0
      while x < W - 4 do
        nd = nd + 1
        local d = Dash(nd)
        d:ClearAllPoints()
        d:SetPoint("BOTTOMLEFT", area, "BOTTOMLEFT", x, y)
        ns.SetColor(d, 1, 1, 1, 0.8)
        d:Show()
        x = x + 10
      end
      avgLabel:ClearAllPoints()
      avgLabel:SetPoint("BOTTOMRIGHT", area, "BOTTOMLEFT", W - 2, y + 2)
      avgLabel:SetText("avg " .. spec.fmt(spec.avg))
      avgLabel:Show(); avgBg:Show()
    else
      avgLabel:Hide(); avgBg:Hide()
    end
    HideFrom(dashes, nd)

    -- Running-total line (pace)
    local nl, ndot = 0, 0
    if spec.line then
      local px, py
      for i = 1, n do
        local val = spec.line[i]
        if val then
          local x, y = (i - 0.5) * slot, Y(val)
          ndot = ndot + 1
          local d = Dot(ndot)
          d:ClearAllPoints()
          d:SetPoint("CENTER", area, "BOTTOMLEFT", x, y)
          ns.SetColor(d, r, g, b, 1)
          d:Show()
          if px then
            local l = Line(nl + 1)
            if l then
              nl = nl + 1
              l:SetThickness(2)
              l:SetColorTexture(r, g, b, 0.9)
              l:SetStartPoint("BOTTOMLEFT", area, px, py)
              l:SetEndPoint("BOTTOMLEFT", area, x, y)
              l:Show()
            end
          end
          px, py = x, y
        end
      end
    end
    HideFrom(lines, nl)
    HideFrom(dots, ndot)
  end

  return view
end
