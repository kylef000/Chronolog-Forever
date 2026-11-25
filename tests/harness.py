import sys, os
from lupa.lua51 import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FILES = "Core Skin Common Pace Recovery Heat Reputation Views UI Widget Export Minimap HeatMap Settings".split()
WITH_EUI = len(sys.argv) > 1 and sys.argv[1] == "eui"

lua = LuaRuntime(unpack_returned_tuples=True)

MOCK = r'''
local W = {  -- controllable world state
  level = 11, speed = 0, speedSecret = false, mounted = false, combat = false,
  dead = false, form = nil, zone = "Durotar", xp = 100, xpmax = 1000, money = 5000,
  afk = false, taxi = false, grouped = false,
}
_G.W = W
local SECRET = setmetatable({}, {__tostring = function() error("tostring on secret") end,
  __lt = function() error("compare secret") end, __le = function() error("compare secret") end,
  __add = function() error("arith secret") end, __concat = function() error("concat secret") end})
_G.SECRET = SECRET
function issecretvalue(v) return v == SECRET end

local frames = {}
_G.ALL_FRAMES = frames
local function NewObj(kind, name)
  local o = { __kind = kind, scripts = {}, shown = true, events = {}, text = "" }
  local mt = {}
  mt.__index = function(t, k)
    if type(k) ~= "string" or not k:match("^[A-Z]") then return nil end
    if k == "SetScript" then return function(self, n, f) self.scripts[n] = f end end
    if k == "GetScript" then return function(self, n) return self.scripts[n] end end
    if k == "Show" then return function(self) local was = self.shown; self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end end
    if k == "Hide" then return function(self) self.shown = false end end
    if k == "IsShown" then return function(self) return self.shown end end
    if k == "SetShown" then return function(self, v) self.shown = v and true or false end end
    if k == "RegisterEvent" then return function(self, e) self.events[e] = true end end
    if k == "UnregisterEvent" then return function(self, e) self.events[e] = nil end end
    if k == "IsEventRegistered" then return function(self, e) return self.events[e] or false end end
    if k == "RegisterUnitEvent" then return function(self, e) self.events[e] = true end end
    if k == "CreateFontString" or k == "CreateTexture" or k == "CreateLine" then return function(self) return NewObj("fs") end end
    if k == "GetFontString" then return function(self) return NewObj("fs") end end
    if k == "SetText" then return function(self, s) self.text = s end end
    if k == "SetWidth" then return function(self, v) self.w = v end end
    if k == "SetPoint" then return function(self, p, rel, rp, x, y)
      if type(rel) == "number" then x, y = rel, rp end
      self.pt = { p, x, y }
    end end
    if k == "SetSize" then return function(self, w, h) self.w, self.h = w, h end end
    if k == "GetText" then return function(self) return self.text end end
    if k == "GetWidth" or k == "GetHeight" or k == "GetEffectiveScale" or k == "GetScale" then return function() return 100 end end
    if k == "GetObjectType" then return function(self) return self.__kind == "fs" and "FontString" or "Frame" end end
    if k == "GetRegions" then return function() return end end
    if k == "GetPoint" then return function() return "CENTER", nil, nil, 0, 0 end end
    if k == "GetCenter" then return function() return 100, 100 end end
    if k == "HighlightText" or k == "SetFocus" then return function() end end
    return function() end
  end
  setmetatable(o, mt)
  if name then _G[name] = o end
  frames[#frames + 1] = o
  return o
end

function CreateFrame(kind, name, parent, template) return NewObj(kind, name) end
UIParent = NewObj("Frame"); Minimap = NewObj("Frame"); GameTooltip = NewObj("Frame")
ChatFrame1 = NewObj("Frame"); ChatFrame1.events.TIME_PLAYED_MSG = true
ChatFontNormal = {}
UISpecialFrames = {}
tinsert = table.insert
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function hooksecurefunc(...) end
function GetQuestReward() end
local _print = print
PRINTED = {}
function print(...) local t = {} for i = 1, select("#", ...) do t[#t+1] = tostring((select(i, ...))) end PRINTED[#PRINTED+1] = table.concat(t, " ") end
local now = 1000
function GetTime() return now end
function ADVANCE(dt) now = now + dt end
_G.time = function() return 1700000000 end
function GetCursorPosition() return 150, 120 end
function GetBuildInfo() return "12.1.7", "1", "x", 120107 end
local pname, prealm = "Tester", "Realm"
function SETCHAR(n, r) pname, prealm = n, r or "Realm" end
function UnitName() return pname end
-- Forever shows a surname as part of the name-with-title.
function UnitPVPName() if W.pvpName ~= nil then return W.pvpName end return pname end
function GetRealmName() if W.realmBlank then return "" end return prealm end
function UnitClass() return "Shaman", "SHAMAN" end
function UnitLevel() return W.level end
function UnitGUID(u) if u == "target" then return W.targetGUID end return "Player-1" end
function GetRealZoneText() return W.zone end
function GetZoneText() return W.zone end
function IsInGroup() return W.grouped end
function IsInRaid() return false end
function GetShapeshiftFormID() return W.form end
function IsMounted() return W.mounted end
function UnitOnTaxi() return W.taxi end
function UnitAffectingCombat(u) if u == "target" then return W.targetCombat end if W.combatSecret then return SECRET end return W.combat end
function UnitIsAFK() return W.afk end
function UnitIsDeadOrGhost() return W.dead end
function GetUnitSpeed() if W.speedSecret then return SECRET end return W.speed end
function UnitXP() if W.zeroValues then return 0 end return W.xp end
function UnitXPMax() if W.zeroValues then return 0 end return W.xpmax end
function GetMoney() if W.zeroValues then return 0 end return W.money end
function UnitIsPlayer() return false end
function UnitIsDead(u) return W.targetDead end
function UnitCanAttack() return true end
function UnitIsTapDenied() return false end
function IsInInstance() if W.instType then return true, W.instType end return false, "none" end
function IsResting() return W.resting end
function CreateColor(r, g, b, a) return { r = r, g = g, b = b, a = a } end
TIMERS = {}
C_Timer = { After = function(sec, fn) TIMERS[#TIMERS + 1] = fn end }
function RUN_TIMERS() local t = TIMERS; TIMERS = {}; for _, fn in ipairs(t) do fn() end end
PLAYED_REQUESTS = 0
function RequestTimePlayed() PLAYED_REQUESTS = PLAYED_REQUESTS + 1 end
NUM_CHAT_WINDOWS = 1
W.stats = { kills = 100, quests = 50, deaths = 3 }
local STAT_MAP = { [1197] = "kills", [98] = "quests", [60] = "deaths" }
function GetStatistic(id) local k = STAT_MAP[id]; return k and tostring(W.stats[k]) or "--" end
StaticPopupDialogs = {}
function StaticPopup_Show(name, arg, arg2, data) POPUP = { name = name, arg = arg, data = data } end
function ReloadUI() RELOADED = true end
function InCombatLockdown() return W.combat end

-- Maps: Durotar (1411, a zone) with a cave micro map (9001) inside it.
-- W.pos = {x, y} on the zone map (nil = unavailable, e.g. in an instance).
Enum = { UIMapType = { Cosmic = 0, World = 1, Continent = 2, Zone = 3, Dungeon = 4, Micro = 5, Orphan = 6 } }
W.mapID, W.pos, W.subzone = 1411, { 0.5, 0.5 }, "Razor Hill"
local MAPS = {
  [1411] = { mapID = 1411, mapType = 3, parentMapID = 1414, name = "Durotar" },
  [1414] = { mapID = 1414, mapType = 2, parentMapID = 947, name = "Kalimdor" },
  [9001] = { mapID = 9001, mapType = 5, parentMapID = 1411 },
}
MAP_POS_CALLS = {}
C_Map = {
  GetBestMapForUnit = function() return W.mapID end,
  GetMapInfo = function(id) return MAPS[id] end,
  GetMapWorldSize = function(id) return 4000, 3000 end,
  GetPlayerMapPosition = function(map, unit)
    MAP_POS_CALLS[#MAP_POS_CALLS + 1] = map
    if W.posSecret then return SECRET end
    if not W.pos then return nil end
    local x, y = W.pos[1], W.pos[2]
    return { GetXY = function() return x, y end }
  end,
}
function GetSubZoneText() return W.subzone end
-- Durotar (1411) sits at x 0.5-0.7, y 0.4-0.6 of Kalimdor (1414).
C_Map.GetMapRectOnMap = function(child, top)
  if child == 1411 and top == 1414 then return 0.5, 0.7, 0.4, 0.6 end
end

-- World map + data provider plumbing
MapCanvasDataProviderMixin = {
  OnAdded = function(self, m) self.owningMap = m end,
  GetMap = function(self) return self.owningMap end,
}
function CreateFromMixins(...)
  local t = {}
  for _, m in ipairs({ ... }) do for k, v in pairs(m) do t[k] = v end end
  return t
end
W.viewMap, W.cursor, W.mouseOverMap = 1411, { 0.5, 0.5 }, false
local mapCanvas = NewObj("Frame")
WorldMapFrame = NewObj("Frame", "WorldMapFrame")
WorldMapFrame.shown = false
WorldMapFrame.ScrollContainer = NewObj("Frame")
WorldMapFrame.ScrollContainer.IsMouseOver = function() return W.mouseOverMap end
WorldMapFrame.GetMapID = function() return W.viewMap end
WorldMapFrame.GetCanvas = function() return mapCanvas end
WorldMapFrame.GetNormalizedCursorPosition = function() return W.cursor[1], W.cursor[2] end
WorldMapFrame.AddDataProvider = function(self, p) MAP_PROVIDER = p; p:OnAdded(self) end

-- Tooltip that remembers its owner and lines
GameTooltip.shown = false
GameTooltip.SetOwner = function(self, o) self.owner = o; self.lines = {} end
GameTooltip.GetOwner = function(self) return self.owner end
GameTooltip.AddLine = function(self, s) self.lines = self.lines or {}; table.insert(self.lines, tostring(s)) end
GameTooltip.AddDoubleLine = function(self, a, b)
  self.lines = self.lines or {}; table.insert(self.lines, tostring(a) .. " = " .. tostring(b))
end
local prof = 0
function debugprofilestop() prof = prof + 0.01; return prof end

-- Blizzard Settings API mock: records proxy settings so tests can drive them.
local AUTO = setmetatable({}, {})
getmetatable(AUTO).__index = function() return AUTO end
getmetatable(AUTO).__call = function() return AUTO, AUTO end
PROXIES, DROPDOWNS = {}, {}
Settings = setmetatable({
  VarType = { Boolean = "boolean", Number = "number", String = "string" },
  RegisterProxySetting = function(cat, var, vt, name, def, get, set)
    PROXIES[var] = { get = get, set = set }
    return { var = var }
  end,
  CreateDropdown = function(cat, setting, getOptions) DROPDOWNS[setting.var] = getOptions end,
  CreateControlTextContainer = function()
    local data = {}
    return { Add = function(self, v, l) data[#data + 1] = { value = v, label = l } end,
             GetData = function() return data end }
  end,
  OpenToCategory = function(id) SETTINGS_OPENED = id end,
}, { __index = function() return AUTO end })
CreateSettingsButtonInitializer = AUTO
CreateSettingsListSectionHeaderInitializer = AUTO
MinimalSliderWithSteppersMixin = AUTO
COMBATLOG_XPGAIN_FIRSTPERSON = "%s dies, you gain %d experience."
FACTION_STANDING_INCREASED = "Reputation with %s increased by %d."
FACTION_STANDING_DECREASED = "Reputation with %s decreased by %d."
FACTION_STANDING_LABEL4 = "Neutral"; FACTION_STANDING_LABEL5 = "Friendly"
FACTION_BAR_COLORS = { [4] = { r = 1, g = 1, b = 0 }, [5] = { r = 0, g = 0.6, b = 0.1 } }
-- Classic-style reputation list: a header, Orgrimmar (Friendly), and a
-- faction whose values are secret.
W.factionList = {
  { "Horde", nil, 4, 0, 0, 0, false, false, true, false, false },
  { "Orgrimmar", nil, 5, 3000, 9000, 4200, false, false, false, false, true },
  { "Hidden", nil, SECRET, 0, 3000, 100, false, false, false, false, true },
}
FACTION_LIST_CALLS = 0
function GetNumFactions() FACTION_LIST_CALLS = FACTION_LIST_CALLS + 1; return #W.factionList end
function GetFactionInfo(i) return unpack(W.factionList[i]) end
SlashCmdList = {}

function FIRE(event, ...)
  for _, f in ipairs(frames) do
    if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
  end
end
function UPDATE(dt)
  for _, f in ipairs(frames) do
    if f.scripts.OnUpdate then f.scripts.OnUpdate(f, dt) end
  end
end
function TICKS(n, dt) for i = 1, n do UPDATE(dt or 0.25) end end
'''

EUI = r'''
-- Minimal EllesmereUI mock: skin callback + plugin registration
local S = setmetatable({}, {__index = function(t, k)
  if k == "GetAccentColor" then return function() return 0.05, 0.82, 0.62 end end
  if k == "IsEnabled" then return function() return true end end
  if k == "apiVersion" then return 3 end
  return function() end
end})
local pending
EllesmereUI = {
  RegisterSkin = function(name, fn) pending = fn end,
  RegisterPlugin = function(id, spec) PLUGIN = spec; return true end,
  Widgets = setmetatable({}, {__index = function(t, k) return function(self, parent, a, y) return {}, 40 end end}),
  IsSearchPrebuild = function() return false end,
}
function RUN_SKIN() if pending then pending(S) end end

-- LibStub with LibDataBroker + LibDBIcon (as shipped by UI packs)
local libs = {
  ["LibDataBroker-1.1"] = { NewDataObject = function(self, name, obj) LDB_OBJ = obj; return obj end },
  ["LibDBIcon-1.0"] = {
    Register = function(self, name, obj, db) DBICON = { name = name, db = db, shown = not db.hide } end,
    Show = function(self, name) DBICON.shown = true end,
    Hide = function(self, name) DBICON.shown = false end,
  },
}
LibStub = setmetatable({}, { __call = function(self, name, silent) return libs[name] end })
'''

lua.execute(MOCK)
if WITH_EUI:
    lua.execute(EUI)

ns = lua.table()
load = lua.eval("function(src, name) local f, e = loadstring(src, name); if not f then error(e) end return f end")
for f in FILES:
    src = open(os.path.join(ROOT, f + ".lua"), encoding="utf-8").read()
    fn = load(src, "@" + f + ".lua")
    fn("Chronolog-Forever", ns)

# scenario runner written in Lua so errors carry Lua tracebacks
SCENARIO = open(os.path.join(HERE, "scenario.lua"), encoding="utf-8").read()
lua.globals().NS = ns
lua.globals().WITH_EUI = WITH_EUI
res = lua.execute(SCENARIO)
print(res)
sys.exit(0 if str(res).startswith("ALL PASSED") else 1)
