--[[
  Chronolog-Forever - Minimap button
  ----------------------------------
  A draggable minimap button (left-click: window, right-click: widget) and, when
  LibDataBroker is available (it ships with EllesmereUI), a launcher object for
  broker displays. /chrono minimap shows/hides the button.
]]

local addonName, ns = ...

local ICON = "Interface\\Icons\\INV_Misc_PocketWatch_01"
local button

local function GetDB()
  local db = ns.EnsureDB()
  if type(db.minimap) ~= "table" then db.minimap = { hide = false, angle = 225 } end
  return db.minimap
end

local function UpdatePosition()
  if not button then return end
  local a = math.rad(GetDB().angle or 225)
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
  GetDB().angle = deg
  UpdatePosition()
end

local function ShowTooltip(tip)
  tip:AddLine("Chronolog-Forever", 1, 1, 1)
  local db = ns.EnsureDB()
  local lvl = ns.state.currentLevel
  if db.levels[lvl] then
    local row = ns.GetRow(db, lvl)
    tip:AddLine(string.format("Level %d: %s played, %d kills", lvl, ns.FormatTime(row.total), row.kills), 0.8, 0.8, 0.8)
  end
  tip:AddLine(" ")
  tip:AddLine("|cffffff00Left-click|r  open the window", 0.8, 0.8, 0.8)
  tip:AddLine("|cffffff00Right-click|r  toggle the widget", 0.8, 0.8, 0.8)
  tip:AddLine("|cffffff00Drag|r  move this button", 0.8, 0.8, 0.8)
end

local function Click(btn)
  if btn == "RightButton" then ns.ToggleWidget() else ns.ToggleWindow() end
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
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)

  UpdatePosition()
end

function ns.IsMinimapShown()
  return not GetDB().hide
end

-- force = true/false to show/hide; omit to toggle.
function ns.ToggleMinimapButton(force)
  local mdb = GetDB()
  local show
  if force == nil then show = mdb.hide else show = force and true or false end
  mdb.hide = not show
  if show then
    if not button then Build() end
    button:Show()
    UpdatePosition()
  elseif button then
    button:Hide()
  end
  print("|cff66ccffChronolog-Forever|r: minimap button " .. (show and "shown" or "hidden") .. ".")
end

-- Broker launcher (optional).
local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
if LDB then
  LDB:NewDataObject("Chronolog-Forever", {
    type = "launcher",
    text = "Chronolog-Forever",
    icon = ICON,
    OnClick = function(_, btn) Click(btn) end,
    OnTooltipShow = ShowTooltip,
  })
end

local login = CreateFrame("Frame")
login:RegisterEvent("PLAYER_LOGIN")
login:SetScript("OnEvent", function()
  if not GetDB().hide then
    Build()
  end
end)
