--[[
  Chronolog-Forever - World map heatmap
  -------------------------------------
  Draws the position data recorded by Heat.lua on the game's world map.

  * Zone maps: each visited 1% cell is a colored tile; the color scale is
    logarithmic so a few hotspots (quest hubs) don't wash out everything else.
  * Continent (or any parent) maps: every zone's data is projected onto the
    map you're looking at, so the whole leveling path shows at once.
  * Controls (bottom-left of the map): on/off, layer (time / combat), source
    (this character / all characters), level bracket. Saved per character.
  * Hover: the tooltip is driven by the cursor position, so the overlay never
    takes mouse input - map clicks, panning and other addons' pins keep working.

  It plugs in as a world map data provider (the standard way map addons add
  content) and only redraws when the map is opened, changes zone, a setting
  changes, or every 15 seconds while the map stays open.
]]

local addonName, ns = ...

local floor, min, max, log = math.floor, math.min, math.max, math.log
local GRID = ns.HEAT_GRID -- recording grid (Heat.lua)
local DG = 100            -- display grid on the map being viewed
local MAX_TILES = 5000    -- keep the biggest if a view would need more
local REFRESH_EVERY = 15
local TAG = "|cff66ccffChronolog-Forever|r"

-- Color ramps, low -> high.
local RAMPS = {
  time   = { { 0.20, 0.30, 0.85 }, { 0.10, 0.75, 0.90 }, { 0.30, 0.85, 0.35 }, { 1.00, 0.85, 0.20 }, { 1.00, 0.30, 0.15 } },
  combat = { { 0.40, 0.10, 0.12 }, { 0.70, 0.15, 0.12 }, { 0.92, 0.32, 0.15 }, { 1.00, 0.58, 0.20 }, { 1.00, 0.88, 0.40 } },
}

local function Ramp(ramp, i)
  local pos = max(0, min(1, i)) * (#ramp - 1)
  local k = floor(pos)
  local f = pos - k
  local a, b = ramp[k + 1], ramp[min(k + 2, #ramp)]
  return a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f
end

local BRACKETS = { "All levels", "Levels 1-10", "Levels 11-20", "Levels 21-30",
  "Levels 31-40", "Levels 41-50", "Levels 51-60" }

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------
local function Opts()
  local db = ns.EnsureDB()
  if type(db.heatmap) ~= "table" then db.heatmap = {} end
  local o = db.heatmap
  if o.shown == nil then o.shown = true end
  if o.layer ~= "combat" then o.layer = "time" end
  if o.source ~= "ALL" then o.source = nil end
  o.bracket = tonumber(o.bracket) or 1
  if o.bracket < 1 or o.bracket > #BRACKETS then o.bracket = 1 end
  return o
end
ns.HeatmapOptions = Opts

--------------------------------------------------------------------------------
-- Map geometry
--------------------------------------------------------------------------------
local ancestorCache, rectCache = {}, {}
local IDENTITY = { 0, 1, 0, 1 }

-- Is `top` the map itself or one of `child`'s parent maps?
local function IsWithin(child, top)
  if child == top then return true end
  local key = child .. ":" .. top
  local v = ancestorCache[key]
  if v == nil then
    v = false
    local id = child
    for _ = 1, 10 do
      local info = C_Map.GetMapInfo(id)
      local parent = info and info.parentMapID
      if not parent or parent == 0 then break end
      if parent == top then v = true break end
      id = parent
    end
    ancestorCache[key] = v
  end
  return v
end

-- Where `child` sits on `top`, as {left, right, top, bottom} in 0..1.
local function RectOn(child, top)
  if child == top then return IDENTITY end
  local key = child .. ":" .. top
  local r = rectCache[key]
  if r == nil then
    r = false
    if C_Map.GetMapRectOnMap and IsWithin(child, top) then
      local ok, l, rr, t, b = pcall(C_Map.GetMapRectOnMap, child, top)
      l, rr, t, b = ns.Clean(l), ns.Clean(rr), ns.Clean(t), ns.Clean(b)
      if ok and l and rr and t and b and rr > l and b > t then r = { l, rr, t, b } end
    end
    rectCache[key] = r
  end
  return r or nil
end

--------------------------------------------------------------------------------
-- Aggregation: recorded cells -> display cells on the viewed map
--------------------------------------------------------------------------------
local current = { mapID = nil, grid = {}, maxV = 0, total = 0, drawn = 0 }

local function BuildGrid(mapID, o)
  local grid = {}
  local blo, bhi = 1, 63
  if o.bracket > 1 then blo, bhi = (o.bracket - 2) * 10 + 1, (o.bracket - 1) * 10 end
  for _, heat in ipairs(ns.GetHeatSources(o.source)) do
    for hmap, cells in pairs(heat) do
      local rect = RectOn(hmap, mapID)
      if rect then
        local rw, rh = rect[2] - rect[1], rect[4] - rect[3]
        for cell, v in pairs(cells) do
          local t, c, lo, hi = ns.HeatUnpack(v)
          if hi >= blo and lo <= bhi then
            local x = rect[1] + ((cell % GRID) + 0.5) / GRID * rw
            local y = rect[3] + (floor(cell / GRID) + 0.5) / GRID * rh
            if x >= 0 and x < 1 and y >= 0 and y < 1 then
              local d = floor(y * DG) * DG + floor(x * DG)
              local g = grid[d]
              if not g then
                g = { 0, 0, 63, 0 }
                grid[d] = g
              end
              g[1], g[2] = g[1] + t, g[2] + c
              if lo < g[3] then g[3] = lo end
              if hi > g[4] then g[4] = hi end
            end
          end
        end
      end
    end
  end
  return grid
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------
local map, overlay, panel
local tiles = {}

local function HideTiles(from)
  for i = from, #tiles do tiles[i]:Hide() end
end

local function Draw()
  if not map or not overlay then return end
  local o = Opts()
  if panel and panel.Update then panel.Update() end
  local mapID = map:GetMapID()
  current.mapID = mapID
  if not o.shown or not mapID then
    current.grid, current.drawn, current.total, current.maxV = {}, 0, 0, 0
    HideTiles(1)
    return
  end

  local grid = BuildGrid(mapID, o)
  local layerIdx = (o.layer == "combat") and 2 or 1
  local list, maxV, total = {}, 0, 0
  for d, g in pairs(grid) do
    local v = g[layerIdx]
    if v > 0 then
      list[#list + 1] = { d = d, v = v }
      if v > maxV then maxV = v end
      total = total + v
    end
  end
  if #list > MAX_TILES then
    table.sort(list, function(a, b) return a.v > b.v end)
    for i = #list, MAX_TILES + 1, -1 do list[i] = nil end
  end

  local W, H = overlay:GetWidth(), overlay:GetHeight()
  if not W or W <= 0 then W = 1000 end
  if not H or H <= 0 then H = 667 end
  local cw, ch = W / DG, H / DG
  local ramp = RAMPS[o.layer]
  local logMax = log(1 + maxV)
  for i, e in ipairs(list) do
    local tex = tiles[i]
    if not tex then
      tex = overlay:CreateTexture(nil, "ARTWORK")
      tiles[i] = tex
    end
    local cx, cy = e.d % DG, floor(e.d / DG)
    local k = logMax > 0 and (log(1 + e.v) / logMax) or 0
    local r, g, b = Ramp(ramp, k)
    tex:ClearAllPoints()
    tex:SetPoint("TOPLEFT", overlay, "TOPLEFT", cx * cw, -cy * ch)
    tex:SetSize(cw + 0.5, ch + 0.5)
    ns.SetColor(tex, r, g, b, 0.28 + 0.47 * k)
    tex:Show()
  end
  HideTiles(#list + 1)
  current.grid, current.maxV, current.total, current.drawn = grid, maxV, total, #list
  if panel and panel.Update then panel.Update() end
end
ns.RedrawHeatmap = Draw

function ns.HeatmapStats() return current end

--------------------------------------------------------------------------------
-- Hover tooltip (cursor-driven; the overlay never takes the mouse)
--------------------------------------------------------------------------------
local tipShown = false

local function HideTip()
  if tipShown and GameTooltip:GetOwner() == overlay then GameTooltip:Hide() end
  tipShown = false
end

local function UpdateHover()
  local o = Opts()
  if not o.shown or not map:IsShown() then HideTip() return end
  local sc = map.ScrollContainer
  if not (sc and sc:IsMouseOver()) or (panel and panel:IsMouseOver()) then HideTip() return end
  -- Don't fight another addon's or a pin's tooltip.
  if GameTooltip:IsShown() and GameTooltip:GetOwner() ~= overlay then return end
  local x, y = map:GetNormalizedCursorPosition()
  if not x or x < 0 or x >= 1 or y < 0 or y >= 1 then HideTip() return end
  local cx, cy = floor(x * DG), floor(y * DG)
  local g = current.grid[cy * DG + cx]
  if not g or g[1] <= 0 then HideTip() return end

  -- Neighbourhood (5 x 5 display cells) for an "around here" total.
  local areaT, areaC = 0, 0
  for dy = -2, 2 do
    for dx = -2, 2 do
      local n = current.grid[(cy + dy) * DG + (cx + dx)]
      if n and cx + dx >= 0 and cx + dx < DG then areaT, areaC = areaT + n[1], areaC + n[2] end
    end
  end

  local info = C_Map.GetMapInfo(current.mapID)
  GameTooltip:SetOwner(overlay, "ANCHOR_CURSOR")
  GameTooltip:AddLine((info and info.name or "Here") .. string.format("  |cff888888%.0f, %.0f|r", x * 100, y * 100), 1, 1, 1)
  GameTooltip:AddDoubleLine("Time spent here", ns.FormatTime(g[1]), 0.8, 0.8, 0.8, 1, 1, 1)
  GameTooltip:AddDoubleLine("In combat", string.format("%s  |cff888888%.0f%%|r", ns.FormatTime(g[2]), g[2] / g[1] * 100),
    0.85, 0.30, 0.30, 1, 1, 1)
  GameTooltip:AddDoubleLine("Levels", g[3] == g[4] and tostring(g[3]) or (g[3] .. "-" .. g[4]), 0.8, 0.8, 0.8, 1, 1, 1)
  GameTooltip:AddLine(" ")
  GameTooltip:AddDoubleLine("Around here", string.format("%s  |cff888888%.0f%% combat|r", ns.FormatTime(areaT),
    areaT > 0 and areaC / areaT * 100 or 0), 0.6, 0.6, 0.6, 0.8, 0.8, 0.8)
  GameTooltip:AddLine("Chronolog heatmap (AFK time isn't mapped)", 0.45, 0.45, 0.45)
  GameTooltip:Show()
  tipShown = true
end

--------------------------------------------------------------------------------
-- Controls (bottom-left of the map)
--------------------------------------------------------------------------------
local function BuildPanel()
  panel = CreateFrame("Frame", "ChronologHeatmapPanel", map, ns.BACKDROP_TEMPLATE)
  panel:SetPoint("BOTTOMLEFT", map.ScrollContainer, "BOTTOMLEFT", 8, 8)
  panel:SetSize(470, 48)
  panel:SetFrameStrata(map.ScrollContainer:GetFrameStrata() or "HIGH")
  panel:SetFrameLevel((map.ScrollContainer:GetFrameLevel() or 1) + 60)
  panel:EnableMouse(true)
  local bg = panel:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(true)
  ns.SetColor(bg, 0, 0, 0, 0.65)

  local function Btn(width, onClick, tip)
    local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    b:SetSize(width, 20)
    b:SetScript("OnClick", function() onClick(); Draw() end)
    b:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(tip, 1, 1, 1, true)
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b.heatBtn = true
    ns.WhenSkinned(function(S) S.Button(b) end)
    return b
  end

  local toggle = Btn(110, function() local o = Opts(); o.shown = not o.shown end,
    "Show or hide where you've spent your time (recorded once a second; AFK and dungeon time aren't mapped).")
  toggle:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -4)
  local layer = Btn(80, function() local o = Opts(); o.layer = (o.layer == "time") and "combat" or "time" end,
    "Time: everywhere you've been.\nCombat: only time spent fighting.")
  layer:SetPoint("LEFT", toggle, "RIGHT", 4, 0)
  local source = Btn(120, function() local o = Opts(); o.source = (o.source == "ALL") and nil or "ALL" end,
    "This character, or all your characters combined.")
  source:SetPoint("LEFT", layer, "RIGHT", 4, 0)
  local bracket = Btn(140, function() local o = Opts(); o.bracket = o.bracket % #BRACKETS + 1 end,
    "Only show places you were while in this level range.")
  bracket:SetPoint("LEFT", source, "RIGHT", 4, 0)

  -- Legend: less -> more, plus the total mapped on this map.
  local legend = CreateFrame("Frame", nil, panel)
  legend:SetPoint("TOPLEFT", toggle, "BOTTOMLEFT", 2, -5)
  legend:SetSize(200, 12)
  local less = legend:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  less:SetPoint("LEFT", legend, "LEFT", 0, 0)
  less:SetText("less")
  local sw = {}
  for i = 1, 10 do
    local t = legend:CreateTexture(nil, "ARTWORK")
    t:SetSize(10, 8)
    t:SetPoint("LEFT", less, "RIGHT", 4 + (i - 1) * 10, 0)
    sw[i] = t
  end
  local more = legend:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  more:SetPoint("LEFT", sw[10], "RIGHT", 4, 0)
  more:SetText("more")
  local summary = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  summary:SetPoint("LEFT", more, "RIGHT", 12, 0)
  summary:SetJustifyH("LEFT")

  function panel.Update()
    local o = Opts()
    local r, g, b = ns.GetAccent()
    toggle:SetText(o.shown and "Heatmap: On" or "Heatmap: Off")
    local fs = toggle:GetFontString()
    if fs then if o.shown then fs:SetTextColor(r, g, b) else fs:SetTextColor(0.7, 0.7, 0.7) end end
    layer:SetText(o.layer == "combat" and "Combat" or "Time")
    source:SetText(o.source == "ALL" and "All characters" or "This character")
    bracket:SetText(BRACKETS[o.bracket])
    for _, w in ipairs({ layer, source, bracket, legend, summary }) do w:SetShown(o.shown) end
    panel:SetSize(o.shown and 470 or 118, o.shown and 48 or 28)
    for i, t in ipairs(sw) do
      local cr, cg, cb = Ramp(RAMPS[o.layer], (i - 1) / 9)
      ns.SetColor(t, cr, cg, cb, 0.28 + 0.47 * (i - 1) / 9)
    end
    if current.total > 0 then
      summary:SetText((o.layer == "combat" and "Combat mapped here: " or "Mapped here: ") .. ns.FormatTime(current.total))
    else
      summary:SetText("|cff888888Nothing recorded on this map yet|r")
    end
  end

  -- Hover tracking and periodic refresh while the map is open.
  local sinceHover, sinceRefresh = 0, 0
  panel:SetScript("OnUpdate", function(_, e)
    sinceHover, sinceRefresh = sinceHover + e, sinceRefresh + e
    if sinceHover >= 0.05 then sinceHover = 0; UpdateHover() end
    if sinceRefresh >= REFRESH_EVERY then sinceRefresh = 0; Draw() end
  end)
  panel:SetScript("OnHide", HideTip)

  ns.SkinFonts(panel)
  panel.Update()
end

--------------------------------------------------------------------------------
-- Hooking into the world map
--------------------------------------------------------------------------------
local initialized = false

local function Init()
  if initialized then return true end
  if not (WorldMapFrame and WorldMapFrame.AddDataProvider and MapCanvasDataProviderMixin and CreateFromMixins) then
    return false
  end
  initialized = true

  local provider = CreateFromMixins(MapCanvasDataProviderMixin)
  function provider:OnAdded(owningMap)
    MapCanvasDataProviderMixin.OnAdded(self, owningMap)
    map = owningMap
    local canvas = map:GetCanvas()
    overlay = CreateFrame("Frame", nil, canvas)
    overlay:SetAllPoints(canvas)
    overlay:SetFrameLevel((canvas:GetFrameLevel() or 1) + 1)
    BuildPanel()
  end
  function provider:RemoveAllData() HideTiles(1) end
  function provider:RefreshAllData() Draw() end
  function provider:OnMapChanged() Draw() end
  WorldMapFrame:AddDataProvider(provider)
  return true
end

function ns.ToggleHeatmap(force)
  local o = Opts()
  if force == nil then o.shown = not o.shown else o.shown = force and true or false end
  if map and map:IsShown() then Draw() elseif panel then panel.Update() end
  return o.shown
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(self, event, name)
  if event == "ADDON_LOADED" and name ~= "Blizzard_WorldMap" then return end
  local ok, done = pcall(Init)
  if not ok then
    print(TAG .. ": couldn't add the world map heatmap (" .. tostring(done) .. ").")
    self:UnregisterAllEvents()
  elseif done then
    self:UnregisterAllEvents()
  end
end)
