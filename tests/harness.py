import sys, os
from lupa.lua51 import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FILES = "Core Skin Common Views UI Widget Export Minimap Settings".split()
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
    if k == "RegisterUnitEvent" then return function(self, e) self.events[e] = true end end
    if k == "CreateFontString" or k == "CreateTexture" then return function(self) return NewObj("fs") end end
    if k == "GetFontString" then return function(self) return NewObj("fs") end end
    if k == "SetText" then return function(self, s) self.text = s end end
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
function GetRealmName() return prealm end
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
function UnitXP() return W.xp end
function UnitXPMax() return W.xpmax end
function GetMoney() return W.money end
function UnitIsPlayer() return false end
function UnitIsDead(u) return W.targetDead end
function UnitCanAttack() return true end
function UnitIsTapDenied() return false end
function IsInInstance() return false, "none" end
COMBATLOG_XPGAIN_FIRSTPERSON = "%s dies, you gain %d experience."
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
