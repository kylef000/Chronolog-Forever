--[[
  Chronolog-Forever - Skin
  ------------------------
  Optional EllesmereUI integration. When EllesmereUI is installed (and the user
  hasn't disabled third-party skinning for this addon), our frames are handed
  to its skinning API so they match the user's current theme and follow live
  theme/accent changes. Without EllesmereUI none of this runs and the stock
  Blizzard look is used.

  Frames are built lazily (first /chrono), usually after the skin callback has
  fired, so skinning is queued with ns.WhenSkinned and runs whenever the skin
  becomes available.
]]

local addonName, ns = ...

local skin
local queue = {}
local tracked = {} -- FontStrings tinted with the accent color

local function AccentRGB()
  if skin then
    local ok, r, g, b = pcall(skin.GetAccentColor)
    if ok and r then return r, g, b end
  end
  return 1, 0.82, 0 -- stock Blizzard gold
end

-- r, g, b of the current accent (EllesmereUI's when skinned, else gold).
function ns.GetAccent() return AccentRGB() end

local function Hex2(v) return string.format("%02x", math.floor(v * 255 + 0.5)) end

function ns.AccentHex()
  local r, g, b = AccentRGB()
  return Hex2(r) .. Hex2(g) .. Hex2(b)
end

-- Swap the hardcoded gold color code in a string for the current accent.
function ns.Gold(text)
  return (text:gsub("|cffffd200", "|cff" .. ns.AccentHex()))
end

local function Recolor()
  local r, g, b = AccentRGB()
  for _, fs in ipairs(tracked) do fs:SetTextColor(r, g, b) end
end

-- Tint a FontString with the accent color (gold when not skinned).
function ns.TrackAccent(fs)
  tracked[#tracked + 1] = fs
  fs:SetTextColor(AccentRGB())
end

-- Run fn(S) now if the skin is available, otherwise as soon as it is.
function ns.WhenSkinned(fn)
  if skin then fn(skin) else queue[#queue + 1] = fn end
end

-- Re-font every FontString directly on a frame to the user's UI font.
function ns.SkinFonts(frame)
  ns.WhenSkinned(function(S)
    for _, region in ipairs({ frame:GetRegions() }) do
      if region:GetObjectType() == "FontString" then S.Font(region) end
    end
  end)
end

if EllesmereUI and EllesmereUI.RegisterSkin then
  EllesmereUI.RegisterSkin(addonName, function(S)
    skin = S
    S.OnLooksChanged(function()
      Recolor()
      if ns.Refresh then ns.Refresh() end
      if ns.RefreshWidget then ns.RefreshWidget() end
    end)
    for _, fn in ipairs(queue) do fn(S) end
    wipe(queue)
    Recolor()
  end)
end
