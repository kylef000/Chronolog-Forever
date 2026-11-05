--[[
  Chronolog-Forever - Export
  --------------------------
  /chrono export opens a window with your data as CSV (the character/all view
  currently selected in the main window) for copying out: Ctrl+A, Ctrl+C.
  Two tables: one row per level, then one row per (level, zone).
]]

local addonName, ns = ...

local frame, editBox

local function Csv(s)
  s = tostring(s)
  if s:find('[,"]') then s = '"' .. s:gsub('"', '""') .. '"' end
  return s
end

function ns.BuildExport(agg)
  local out = {}
  out[#out + 1] = "level,total_s,combat_s,travel_s,afk_s,dead_s,other_s,idle_s,grouped_s,crafting_s,loading_s,"
    .. "kills,quests,dungeons,deaths,xp,gold_copper,spent_copper"
  for _, lvl in ipairs(agg.levels) do
    local r = agg.rows[lvl]
    if r.total > 0 or r.kills > 0 or r.quests > 0 then
      out[#out + 1] = string.format("%d,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%d,%d,%d,%d,%d,%d,%d",
        lvl, r.total, r.combat, r.travel, r.afk, r.dead, r.other, r.idle, r.grouped, r.crafting, r.loading,
        r.kills, r.quests, r.dungeons, r.deaths, r.xp, r.gold, r.spent)
    end
  end
  out[#out + 1] = ""
  out[#out + 1] = "level,zone,seconds"
  for _, lvl in ipairs(agg.levels) do
    for _, z in ipairs(ns.SortedZones(agg.rows[lvl].zones)) do
      out[#out + 1] = string.format("%d,%s,%.0f", lvl, Csv(z.name), z.secs)
    end
  end
  return table.concat(out, "\n"), #out
end

local function Build()
  frame = CreateFrame("Frame", "ChronologExportFrame", UIParent, ns.BACKDROP_TEMPLATE)
  frame:SetSize(540, 420)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("DIALOG")
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
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetClampedToScreen(true)
  frame:Hide()
  tinsert(UISpecialFrames, "ChronologExportFrame")

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", frame, "TOP", 0, -14)
  title:SetText("Chronolog-Forever export")
  ns.TrackAccent(title)

  local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hint:SetPoint("TOP", title, "BOTTOM", 0, -6)
  hint:SetText("Click the text, then Ctrl+A and Ctrl+C to copy.")

  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -6)

  local scroll = CreateFrame("ScrollFrame", "ChronologExportScroll", frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -58)
  scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -36, 18)

  editBox = CreateFrame("EditBox", nil, scroll)
  editBox:SetMultiLine(true)
  editBox:SetAutoFocus(false)
  editBox:SetFontObject(ChatFontNormal)
  editBox:SetWidth(470)
  editBox:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
    frame:Hide()
  end)
  scroll:SetScrollChild(editBox)

  ns.WhenSkinned(function(S)
    frame:SetBackdrop(nil)
    S.Shell(frame)
    S.CloseButton(close)
    S.ScrollBar(scroll.ScrollBar or _G["ChronologExportScrollScrollBar"])
  end)
  ns.SkinFonts(frame)
end

function ns.ShowExport()
  if not frame then Build() end
  local text, lines = ns.BuildExport(ns.GetAggregate(ns.viewSource))
  editBox:SetText(text)
  editBox:SetHeight(math.max(lines * 14 + 10, 100))
  frame:Show()
  editBox:SetFocus()
  editBox:HighlightText()
end
