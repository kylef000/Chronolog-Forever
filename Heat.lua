--[[
  Chronolog-Forever - Heat (position recording + transport detection)
  -------------------------------------------------------------------
  Once a second (not every tick) we read the player's position on the current
  zone map and add the seconds to a 100 x 100 grid cell. This is the data for a
  future world-map heatmap overlay. AFK time isn't mapped (an AFK hour in a city
  would drown everything else).

  Storage, per character: db.heat[zoneMapID][cell] = one packed number:
      total seconds (20 bits) | combat seconds (20 bits) | lowest level (6) | highest level (6)
  52 bits, exact in a Lua number. One number per visited cell keeps the saved
  file small (a full 1-60 run is roughly 100-300 KB).

  Positions inside instances aren't available to addons; that time is simply
  not mapped (zones/locations still count it).

  Transport detection: if our own speed is 0 but the map position keeps moving
  (and we're not on a flight path), we're riding a boat, zeppelin or tram. Two
  moving samples in a row are required, so a single blink/knockback/teleport
  doesn't count. Elevators move us vertically only, so they don't trigger it.
]]

local addonName, ns = ...

local Clean, IsSecret = ns.Clean, ns.IsSecret
local floor, min, max, sqrt = math.floor, math.min, math.max, math.sqrt

local GRID = 100
local SAMPLE_EVERY = 1.0      -- seconds of tracked time between position samples
local P20 = 2 ^ 20
local MAX_SECS = P20 - 1      -- per cell, ~12 days; clamped
local TRANSPORT_MIN_SPEED = 2 -- yards/second
local TRANSPORT_MAX_SPEED = 100
local FALLBACK_MAP_SIZE = 2000 -- yards, if the client can't tell us a map's size

ns.HEAT_GRID = GRID

--------------------------------------------------------------------------------
-- Packing
--------------------------------------------------------------------------------
local function Pack(total, combat, lo, hi)
  return ((total * P20 + combat) * 64 + lo) * 64 + hi
end

local function Unpack(v)
  local hi = v % 64; v = (v - hi) / 64
  local lo = v % 64; v = (v - lo) / 64
  local combat = v % P20
  local total = (v - combat) / P20
  return total, combat, lo, hi
end
ns.HeatPack, ns.HeatUnpack = Pack, Unpack

--------------------------------------------------------------------------------
-- Maps
--------------------------------------------------------------------------------
local ZONE_TYPE = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
local zoneMapCache = {}
local sizeCache = {}

-- Micro maps (caves, building interiors) and dungeon/orphan maps are folded
-- into the zone they belong to, so everything shows on the normal zone map.
local function ZoneMap(mapID)
  local cached = zoneMapCache[mapID]
  if cached then return cached end
  local id, result = mapID, mapID
  for _ = 1, 10 do
    local info = C_Map.GetMapInfo(id)
    if not info then break end
    result = id
    if (info.mapType or ZONE_TYPE) <= ZONE_TYPE then break end
    local parent = info.parentMapID
    if not parent or parent == 0 then break end
    id = parent
  end
  zoneMapCache[mapID] = result
  return result
end

local function MapSize(map)
  local s = sizeCache[map]
  if s then return s[1], s[2] end
  local w, h
  if C_Map.GetMapWorldSize then w, h = C_Map.GetMapWorldSize(map) end
  w, h = Clean(w), Clean(h)
  if not w or w <= 0 or not h or h <= 0 then w, h = FALLBACK_MAP_SIZE, FALLBACK_MAP_SIZE end
  sizeCache[map] = { w, h }
  return w, h
end

--------------------------------------------------------------------------------
-- Transport detection
--------------------------------------------------------------------------------
local lastMap, lastX, lastY
local movingSamples = 0

local function ResetTransport()
  lastMap, lastX, lastY = nil, nil, nil
  movingSamples = 0
  ns.state.onTransport = false
end

local function UpdateTransport(map, x, y, secs)
  local s = ns.state
  local moving = s.lastMoving
  if lastMap == map and lastX and moving == false and not s.lastOnTaxi and secs > 0 then
    local w, h = MapSize(map)
    local dx, dy = (x - lastX) * w, (y - lastY) * h
    local yps = sqrt(dx * dx + dy * dy) / secs
    if yps >= TRANSPORT_MIN_SPEED and yps <= TRANSPORT_MAX_SPEED then
      movingSamples = movingSamples + 1
    else
      movingSamples = 0
    end
  elseif moving ~= nil or lastMap ~= map then
    -- Moving by ourselves, on a taxi, or a new map: start over. (While the
    -- speed is secret, e.g. in combat, keep the current state.)
    movingSamples = 0
  end
  s.onTransport = movingSamples >= 2
  lastMap, lastX, lastY = map, x, y
end

--------------------------------------------------------------------------------
-- Sampling
--------------------------------------------------------------------------------
local acc, accCombat = 0, 0
local lastSample = { map = nil, x = nil, y = nil, cell = nil }

local function Sample(secs, combatSecs, level)
  if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return end
  local best = Clean(C_Map.GetBestMapForUnit("player"))
  if not best then ResetTransport() return end
  local map = ZoneMap(best)
  local pos = C_Map.GetPlayerMapPosition(map, "player")
  if not pos or IsSecret(pos) then ResetTransport() return end -- e.g. inside an instance
  local x, y = pos:GetXY()
  x, y = Clean(x), Clean(y)
  if not x or not y or x < 0 or x >= 1 or y < 0 or y >= 1 then ResetTransport() return end

  UpdateTransport(map, x, y, secs)

  local db = ChronologForeverDB
  if not db then return end
  local heat = db.heat
  local m = heat[map]
  if not m then
    m = {}
    heat[map] = m
  end
  local cell = floor(y * GRID) * GRID + floor(x * GRID)
  local v = m[cell]
  local t, c, lo, hi
  if v then
    t, c, lo, hi = Unpack(v)
  else
    t, c, lo, hi = 0, 0, level, level
  end
  t = min(t + secs, MAX_SECS)
  c = min(c + combatSecs, MAX_SECS)
  lo, hi = min(lo, level), max(hi, level)
  m[cell] = Pack(t, c, min(lo, 63), min(hi, 63))
  lastSample.map, lastSample.x, lastSample.y, lastSample.cell = map, x, y, cell
end

-- Called by the Core ticker with each tick's time and the bucket it went to.
function ns.HeatTick(dt, bucket, level)
  if bucket == "afk" then return end
  acc = acc + dt
  if bucket == "combat" then accCombat = accCombat + dt end
  if acc < SAMPLE_EVERY then return end
  local secs = floor(acc)
  local combatSecs = min(floor(accCombat + 0.5), secs)
  acc, accCombat = acc - secs, 0
  Sample(secs, combatSecs, level or 1)
end

--------------------------------------------------------------------------------
-- Reading (for the future overlay, export and debug)
--------------------------------------------------------------------------------
-- Heat tables for a view source: nil = this character, a key, or "ALL".
function ns.GetHeatSources(source)
  local out = {}
  local a = ChronologAccountDB
  if source == "ALL" and a and a.chars then
    for _, c in pairs(a.chars) do
      if type(c.heat) == "table" then out[#out + 1] = c.heat end
    end
  elseif source and a and a.chars and a.chars[source] then
    if type(a.chars[source].heat) == "table" then out[1] = a.chars[source].heat end
  else
    out[1] = ns.EnsureDB().heat
  end
  return out
end

-- Iterate cells: fn(mapID, cell, x, y, total, combat, lo, hi); x/y = cell centre.
function ns.ForEachHeatCell(source, fn)
  for _, heat in ipairs(ns.GetHeatSources(source)) do
    for map, cells in pairs(heat) do
      for cell, v in pairs(cells) do
        local t, c, lo, hi = Unpack(v)
        local cx, cy = cell % GRID, floor(cell / GRID)
        fn(map, cell, (cx + 0.5) / GRID, (cy + 0.5) / GRID, t, c, lo, hi)
      end
    end
  end
end

function ns.HeatDebug(Dbg)
  local maps, cells = 0, 0
  for _, cellsT in pairs(ns.EnsureDB().heat) do
    maps = maps + 1
    for _ in pairs(cellsT) do cells = cells + 1 end
  end
  Dbg("heatmap:", string.format("%d cells on %d maps (~%d KB saved)", cells, maps, floor(cells * 24 / 1024 + 0.5)))
  if lastSample.map then
    Dbg("position:", string.format("map %d at %.1f, %.1f (cell %d)",
      lastSample.map, lastSample.x * 100, lastSample.y * 100, lastSample.cell))
  else
    Dbg("position:", "unavailable (instance, or not sampled yet)")
  end
  Dbg("on boat/zeppelin/tram:", ns.state.onTransport and "yes" or "no")
end

-- Loading screens break position continuity.
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:SetScript("OnEvent", function()
  ResetTransport()
  acc, accCombat = 0, 0
end)
