--[[
  Chronolog-Forever - Minimap button, broker launcher and addon compartment
  -------------------------------------------------------------------------
  * If LibDataBroker + LibDBIcon are loaded (most UI packs and many addons ship
    them), the minimap button is a standard LibDBIcon button, so minimap-button
    collectors and "hide minimap buttons" settings handle it.
  * Otherwise a small built-in draggable button is used.
  * The addon compartment (the addon menu button by the minimap) entry is set
    up from the .toc and always available.
  Left-click opens the window, right-click toggles the widget.
  /chrono minimap shows/hides the button.
]]

local addonName, ns = ...

local ICON = "Interface\\Icons\\INV_Misc_PocketWatch_01"
local LDB_NAME = "Chronolog-Forever"
local button     -- built-in button (when LibDBIcon isn't available)
local dbIcon     -- LibDBIcon, when used

local function GetDB()
  local db = ns.EnsureDB()
  if type(db.minimap) ~= "table" then db.minimap = { hide = false } end
  local m = db.minimap
  -- LibDBIcon stores the position as `minimapPos`; older versions used `angle`.
  if m.minimapPos == nil then m.minimapPos = m.angle or 225 end
  return m
end

local function ShowTooltip(tip)
  tip:AddLine("Chronolog-Forever", 1, 1, 1)
  local db = ns.EnsureDB()
  local lvl = ns.state.currentLevel
  if db.levels[lvl] then
    local row = ns.GetRow(db, lvl)
    tip:AddLine(string.format("Level %d: %s played, %d kills", lvl, ns.FormatTime(ns.LevelTime(row)), row.kills),
      0.8, 0.8, 0.8)
    local toNext = ns.GetETA and ns.GetETA()
    if toNext then tip:AddLine("Next level in " .. ns.FormatTime(toNext), 0.8, 0.8, 0.8) end
  end
  ns.AddUnsavedLine(tip)
  tip:AddLine(" ")
  tip:AddLine("|cffffff00Left-click|r  open the window", 0.8, 0.8, 0.8)
  tip:AddLine("|cffffff00Right-click|r  toggle the widget", 0.8, 0.8, 0.8)
end

local function Click(btn)
  if btn == "RightButton" then ns.ToggleWidget() else ns.ToggleWindow() end
end

--------------------------------------------------------------------------------
-- Built-in button (fallback)
--------------------------------------------------------------------------------
local function UpdatePosition()
  if not button then return end
  local a = math.rad(GetDB().minimapPos or 225)
  local cos, sin = math.cos(a), math.sin(a)
  local w = (Minimap:GetWidth() / 2) + 5
  local h = (Minimap:GetHeight() / 2) + 5
  local x, y
  if GetMinimapShape and GetMinimapShape() == "SQUARE" then
    x = math.max(-w, math.min(cos * (w * 1.4142 - 10), w))
    y = math.max(-h, math.min(sin * (h * 1.4142 - 10), h))
  else
    x, y = cos * w, sin * h
  end
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function OnDragUpdate()
  local mx, my = Minimap:GetCenter()
  local px, py = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  px, py = px / scale, py / scale
  local deg = math.deg(math.atan2(py - my, px - mx))
  if deg < 0 then deg = deg + 360 end
  GetDB().minimapPos = deg
  UpdatePosition()
end

local function Build()
  button = CreateFrame("Button", "ChronologMinimapButton", Minimap)
  button:SetSize(31, 31)
  button:SetFrameStrata("MEDIUM")
  button:SetFrameLevel(8)
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  button:RegisterForDrag("LeftButton")

  local border = button:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetPoint("TOPLEFT")

  local bg = button:CreateTexture(nil, "BACKGROUND")
  bg:SetSize(20, 20)
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetPoint("TOPLEFT", 7, -5)

  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetSize(17, 17)
  icon:SetTexture(ICON)
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  icon:SetPoint("TOPLEFT", 7, -6)

  button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  button:SetScript("OnClick", function(_, btn) Click(btn) end)
  button:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", OnDragUpdate)
    GameTooltip:Hide()
  end)
  button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    ShowTooltip(GameTooltip)
    GameTooltip:AddLine("|cffffff00Drag|r  move this button", 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)

  UpdatePosition()
end

--------------------------------------------------------------------------------
-- Public toggles
--------------------------------------------------------------------------------
function ns.IsMinimapShown()
  return not GetDB().hide
end

-- force = true/false to show/hide; omit to toggle.
function ns.ToggleMinimapButton(force, quiet)
  local mdb = GetDB()
  local show
  if force == nil then show = mdb.hide and true or false else show = force and true or false end
  mdb.hide = not show
  if dbIcon then
    if show then dbIcon:Show(LDB_NAME) else dbIcon:Hide(LDB_NAME) end
  elseif show then
    if not button then Build() end
    button:Show()
    UpdatePosition()
  elseif button then
    button:Hide()
  end
  if not quiet then
    print("|cff66ccffChronolog-Forever|r: minimap button " .. (show and "shown" or "hidden") .. ".")
  end
end

--------------------------------------------------------------------------------
-- Addon compartment (functions named in the .toc)
--------------------------------------------------------------------------------
function ChronologForever_OnAddonCompartmentClick(_, buttonName)
  Click(buttonName)
end

function ChronologForever_OnAddonCompartmentEnter(_, menuButton)
  GameTooltip:SetOwner(menuButton, "ANCHOR_LEFT")
  ShowTooltip(GameTooltip)
  GameTooltip:Show()
end

function ChronologForever_OnAddonCompartmentLeave()
  GameTooltip:Hide()
end

--------------------------------------------------------------------------------
-- Setup at login (every addon, and so any shared libraries, is loaded by then)
--------------------------------------------------------------------------------
local login = CreateFrame("Frame")
login:RegisterEvent("PLAYER_LOGIN")
login:SetScript("OnEvent", function()
  local mdb = GetDB()
  local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
  local obj
  if LDB then
    obj = LDB:NewDataObject(LDB_NAME, {
      type = "launcher",
      text = "Chronolog",
      icon = ICON,
      OnClick = function(_, btn) Click(btn) end,
      OnTooltipShow = ShowTooltip,
    })
  end
  local icon = LibStub and LibStub("LibDBIcon-1.0", true)
  if obj and icon then
    local ok = pcall(icon.Register, icon, LDB_NAME, obj, mdb)
    if ok then dbIcon = icon return end
  end
  if not mdb.hide then Build() end
end)
