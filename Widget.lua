--[[
  Chronolog-Forever - Widget
  --------------------------
  A small standalone box showing the CURRENT level's stats, independent of the
  main window. Drag to move (position is saved), right-click to hide, hover for
  a full breakdown. Toggle with /chrono widget. Its shown state persists.

  Options (saved): scale, opacity, and which stats are listed. Change them with
  /chrono widget scale|alpha|stat, or on the EllesmereUI settings page.
]]

local addonName, ns = ...

local FormatTime = ns.FormatTime

local widget

local DEFAULT_STATS = { kills = true, quests = true, dungeons = true, grouped = true }
local STAT_ROWS = 6   -- max lines (two stats per line)
local BASE_HEIGHT = 56
local LINE_HEIGHT = 16

function ns.GetWidgetDB()
  local db = ns.EnsureDB()
  if type(db.widget) ~= "table" then
    db.widget = { shown = false }
  end
  local w = db.widget
  if type(w.stats) ~= "table" then
    w.stats = {}
    for k, v in pairs(DEFAULT_STATS) do w.stats[k] = v end
  end
  if type(w.scale) ~= "number" then w.scale = 1 end
  if type(w.alpha) ~= "number" then w.alpha = 1 end
  return w
end
local GetWidgetDB = ns.GetWidgetDB

-- Stats currently enabled, in the canonical order.
local function ActiveStats()
  local wdb = GetWidgetDB()
  local list = {}
  for _, s in ipairs(ns.STATS) do
    if wdb.stats[s.key] then list[#list + 1] = s end
  end
  return list
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------
-- Lay out the stat lines (two per line) and size the box to fit.
local function LayoutStats()
  local active = ActiveStats()
  local lines = math.min(STAT_ROWS, math.ceil(#active / 2))
  for i = 1, STAT_ROWS * 2 do
    local fs = widget.stats[i]
    local stat = active[i]
    if stat and i <= STAT_ROWS * 2 then
      fs.stat = stat
      fs:Show()
    else
      fs.stat = nil
      fs:Hide()
    end
  end
  widget:SetHeight(BASE_HEIGHT + math.max(lines, 1) * LINE_HEIGHT - 2)
end

function ns.RefreshWidget()
  if not widget or not widget:IsShown() then return end

  local db = ns.EnsureDB()
  local lvl = ns.state.currentLevel
  local row = ns.GetRow(db, lvl)
  widget.data = { lvl = lvl, row = row }

  widget.title:SetText("Level " .. lvl)
  widget.total:SetText("|cffffffff" .. FormatTime(row.total) .. "|r played")
  ns.UpdateStackedBar(widget.bar, ns.RowValues(row), widget.bar.width or 170)

  for i = 1, STAT_ROWS * 2 do
    local fs = widget.stats[i]
    if fs.stat then
      fs:SetText("|cffcfcfcf" .. fs.stat.label .. "|r " .. fs.stat.get(row))
    end
  end
end

-- Apply scale/opacity/stat selection (also called from the settings page).
function ns.ApplyWidgetSettings()
  if not widget then return end
  local wdb = GetWidgetDB()
  widget:SetScale(wdb.scale)
  widget:SetAlpha(wdb.alpha)
  LayoutStats()
  ns.RefreshWidget()
end

function ns.SetWidgetOption(name, value)
  local wdb = GetWidgetDB()
  if name == "scale" then
    wdb.scale = math.max(0.5, math.min(2, value))
  elseif name == "alpha" then
    wdb.alpha = math.max(0.2, math.min(1, value))
  end
  ns.ApplyWidgetSettings()
end

-- Toggle a stat by key; returns false if the key is unknown.
function ns.ToggleWidgetStat(key)
  for _, s in ipairs(ns.STATS) do
    if s.key == key then
      local wdb = GetWidgetDB()
      wdb.stats[key] = not wdb.stats[key] or nil
      ns.ApplyWidgetSettings()
      return true
    end
  end
  return false
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------
local function ShowTooltip(self)
  local d = self.data
  if not d then return end
  GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
  GameTooltip:AddLine("Level " .. d.lvl .. " (current)", 1, 1, 1)
  GameTooltip:AddLine(" ")
  ns.AddBreakdown(GameTooltip, d.row)
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Drag to move, right-click to hide.", 0.5, 0.5, 0.5)
  GameTooltip:Show()
end

local function BuildWidget()
  widget = CreateFrame("Frame", "ChronologWidget", UIParent, ns.BACKDROP_TEMPLATE)
  widget:Hide() -- new frames start shown; ToggleWidget decides
  widget:SetWidth(200)
  widget:SetHeight(BASE_HEIGHT + LINE_HEIGHT * 2)
  widget:SetFrameStrata("MEDIUM")
  widget:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  widget:SetBackdropColor(0.05, 0.05, 0.07, 0.9)
  widget:SetClampedToScreen(true)
  widget:EnableMouse(true)
  widget:SetMovable(true)
  widget:RegisterForDrag("LeftButton")
  widget:SetScript("OnDragStart", widget.StartMoving)
  widget:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, _, x, y = self:GetPoint()
    local wdb = GetWidgetDB()
    wdb.point, wdb.x, wdb.y = point, x, y
  end)
  widget:SetScript("OnMouseUp", function(self, button)
    if button == "RightButton" then
      ns.ToggleWidget(false)
    end
  end)
  widget:SetScript("OnEnter", ShowTooltip)
  widget:SetScript("OnLeave", function() GameTooltip:Hide() end)

  widget.title = widget:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  widget.title:SetPoint("TOPLEFT", widget, "TOPLEFT", 10, -8)
  ns.TrackAccent(widget.title)

  widget.total = widget:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  widget.total:SetPoint("TOPRIGHT", widget, "TOPRIGHT", -10, -11)

  widget.bar = ns.CreateStackedBar(widget, 12)
  widget.bar:SetPoint("TOPLEFT", widget, "TOPLEFT", 10, -28)
  widget.bar:SetPoint("TOPRIGHT", widget, "TOPRIGHT", -10, -28)
  widget.bar.width = 180

  -- Stat slots: two per line, filled by LayoutStats.
  widget.stats = {}
  for i = 1, STAT_ROWS * 2 do
    local fs = widget:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    local line = math.ceil(i / 2) - 1
    local col = (i - 1) % 2
    fs:SetPoint("TOPLEFT", widget, "TOPLEFT", 10 + col * 92, -(48 + line * LINE_HEIGHT))
    fs:SetJustifyH("LEFT")
    widget.stats[i] = fs
  end

  -- Restore saved position.
  local wdb = GetWidgetDB()
  widget:ClearAllPoints()
  if wdb.point then
    widget:SetPoint(wdb.point, UIParent, wdb.point, wdb.x or 0, wdb.y or 0)
  else
    widget:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
  end

  widget:SetScript("OnShow", function()
    -- keep the bar width in sync once laid out
    local w = widget.bar:GetWidth()
    if w and w > 0 then widget.bar.width = w end
    ns.RefreshWidget()
    widget.elapsed = 0
  end)
  widget:SetScript("OnUpdate", function(self, e)
    self.elapsed = (self.elapsed or 0) + e
    if self.elapsed >= 1 then
      self.elapsed = 0
      local w = self.bar:GetWidth()
      if w and w > 0 then self.bar.width = w end
      ns.RefreshWidget()
    end
  end)

  -- EllesmereUI theme (no-op without it).
  ns.WhenSkinned(function(S)
    widget:SetBackdrop(nil)
    S.Panel(widget)
  end)
  ns.SkinFonts(widget)

  ns.ApplyWidgetSettings()
end

-- force = true/false to explicitly show/hide; omit to toggle.
function ns.ToggleWidget(force)
  if not widget then BuildWidget() end
  local wdb = GetWidgetDB()

  local show
  if force == nil then
    show = not widget:IsShown()
  else
    show = force and true or false
  end

  if show then
    widget:Show()
  else
    widget:Hide()
  end
  wdb.shown = show
end

function ns.IsWidgetShown()
  return GetWidgetDB().shown and true or false
end

--------------------------------------------------------------------------------
-- Restore on login
--------------------------------------------------------------------------------
local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function()
  local wdb = GetWidgetDB()
  if wdb.shown then
    ns.ToggleWidget(true)
  end
end)
