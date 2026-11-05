local ns = NS
local results, failed = {}, 0

local function step(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    results[#results + 1] = "  ok    " .. name
  else
    failed = failed + 1
    results[#results + 1] = "  FAIL  " .. name .. "\n" .. tostring(err)
  end
end
local function eq(a, b, msg)
  if a ~= b then error((msg or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function near(a, b, msg)
  if math.abs(a - b) > 0.01 then error((msg or "near") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function row() return ns.GetRow(ChronologForeverDB, W.level) end

if WITH_EUI then RUN_SKIN() end

step("login initialises DB, rows 11..60, account mirror", function()
  FIRE("PLAYER_LOGIN")
  eq(ChronologForeverDB.startLevel, 11)
  assert(ChronologForeverDB.levels[60], "seeded to 60")
  assert(ChronologAccountDB.chars["Tester-Realm"], "account entry")
  eq(ChronologAccountDB.chars["Tester-Realm"].levels, ChronologForeverDB.levels, "shared table")
end)

step("idle tick -> other + idle", function()
  TICKS(8, 0.25) -- 2s
  near(row().other, 2); near(row().idle, 2); near(row().total, 2)
  eq(row().zones["Durotar"], 2)
end)

step("on-foot movement -> travel", function()
  W.speed = 7; TICKS(4, 0.25); near(row().travel, 1)
end)

step("mounted + moving -> travel; mounted + still -> idle", function()
  W.mounted = true; TICKS(4, 0.25); near(row().travel, 2)
  W.speed = 0; TICKS(4, 0.25); near(row().idle, 3)
  W.mounted = false
end)

step("ghost wolf form (id 16) moving -> travel", function()
  W.form = 16; W.speed = 7; TICKS(4, 0.25); near(row().travel, 3)
  W.form = nil
end)

step("combat flag via events -> combat", function()
  W.speed = 0; FIRE("PLAYER_REGEN_DISABLED"); TICKS(4, 0.25); near(row().combat, 1)
  FIRE("PLAYER_REGEN_ENABLED")
end)

step("SECRET speed in combat does not throw; counts combat", function()
  W.speedSecret = true; W.combat = true; FIRE("PLAYER_REGEN_DISABLED")
  local before = row().combat
  TICKS(4, 0.25)
  near(row().combat - before, 1, "combat with secret speed")
  FIRE("PLAYER_REGEN_ENABLED"); W.combat = false
end)

step("SECRET speed while mounted counts as travel (assumed moving)", function()
  W.mounted = true; local before = row().travel
  TICKS(4, 0.25); near(row().travel - before, 1)
  W.mounted = false; W.speedSecret = false
end)

step("SECRET combat flag doesn't throw", function()
  W.combatSecret = true; TICKS(4, 0.25); W.combatSecret = false
end)

step("buckets always sum to total", function()
  local r = row()
  near(r.combat + r.travel + r.afk + r.other + r.dead, r.total, "bucket sum")
end)

step("dead -> dead bucket, deaths counter", function()
  W.dead = true; FIRE("PLAYER_DEAD"); TICKS(4, 0.25)
  near(row().dead, 1); eq(row().deaths, 1)
  W.dead = false
end)

step("afk -> afk bucket", function()
  W.afk = true; TICKS(4, 0.25); near(row().afk, 1); W.afk = false
end)

step("loading screen excluded from total, tracked separately", function()
  local before = row().total
  FIRE("PLAYER_LEAVING_WORLD"); ADVANCE(12); UPDATE(12) -- 12s stall
  FIRE("PLAYER_ENTERING_WORLD")
  near(row().loading, 12); near(row().total, before)
end)

step("long frame gap (>5s) is not charged", function()
  local before = row().total; UPDATE(9); near(row().total, before)
end)

step("XP chat line counts a kill below max level", function()
  local before = row().kills
  FIRE("CHAT_MSG_COMBAT_XP_GAIN", "Boar dies, you gain 50 experience.")
  FIRE("CHAT_MSG_COMBAT_XP_GAIN", "Boar dies, you gain 50 experience. (+10 exp Rested bonus)")
  FIRE("CHAT_MSG_COMBAT_XP_GAIN", "You gain 50 experience.")
  FIRE("CHAT_MSG_COMBAT_XP_GAIN", SECRET)
  eq(row().kills, before + 2)
end)

step("XP tracking incl. level rollover", function()
  W.xp = 300; FIRE("PLAYER_XP_UPDATE"); eq(row().xp, 200)
  W.xp = 50;  FIRE("PLAYER_XP_UPDATE"); eq(row().xp, 200 + (1000 - 300 + 50))
end)

step("gold gained / spent", function()
  W.money = 7000; FIRE("PLAYER_MONEY"); eq(row().gold, 2000)
  W.money = 6500; FIRE("PLAYER_MONEY"); eq(row().spent, 500)
end)

step("level up moves charging to the new level + syncs", function()
  W.level = 12; FIRE("PLAYER_LEVEL_UP", 12); TICKS(4, 0.25)
  near(ns.GetRow(ChronologForeverDB, 12).total, 1)
end)

step("max-level target kill counting", function()
  W.level = 60; FIRE("PLAYER_LEVEL_UP", 60)
  W.targetGUID = "Creature-1"; W.targetDead = false; W.targetCombat = true
  FIRE("PLAYER_TARGET_CHANGED")
  W.targetDead = true; FIRE("PLAYER_TARGET_CHANGED"); FIRE("PLAYER_TARGET_CHANGED")
  eq(ns.GetRow(ChronologForeverDB, 60).kills, 1, "single kill, deduped")
  -- XP line must NOT also count at max level
  FIRE("CHAT_MSG_COMBAT_XP_GAIN", "Boar dies, you gain 5 experience.")
  eq(ns.GetRow(ChronologForeverDB, 60).kills, 1, "no double count at max")
  W.level = 12; FIRE("PLAYER_LEVEL_UP", 12)
end)

step("aggregate: current / other char / ALL", function()
  local a = ns.GetAggregate(nil)
  assert(#a.levels >= 2); assert(a.totals.total > 0)
  assert(a.avg ~= nil)
  -- add a second character
  ChronologAccountDB.chars["Alt-Realm"] = { name = "Alt", startLevel = 1, levels = {
    [5] = { combat = 10, total = 100, kills = 7, zones = { Elwynn = 100 } } } }
  local srcs = ns.GetSources()
  eq(#srcs, 3, "this + alt + all")
  local alt = ns.GetAggregate("Alt-Realm"); eq(alt.totals.kills, 7); eq(alt.rows[5].quests, 0, "migrated")
  local all = ns.GetAggregate("ALL")
  eq(all.totals.kills, a.totals.kills + 7)
  eq(all.totals.zones.Elwynn, 100)
end)

step("main window builds and refreshes all tabs / sources", function()
  SlashCmdList.CHRONOLOG("")
  assert(ChronologFrame and ChronologFrame.shown, "window shown")
  for _, src in ipairs({ false, "Alt-Realm", "ALL" }) do
    ns.viewSource = src or nil
    -- cycle tabs via their buttons
    UPDATE(1.1)
    for _, f in ipairs(ALL_FRAMES) do
      if f.scripts.OnClick and f.text and (f.text == "Zones" or f.text == "Charts" or f.text == "Levels") then
        f.scripts.OnClick(f)
      end
    end
  end
  ns.viewSource = nil
  -- charts metric cycling
  for _, f in ipairs(ALL_FRAMES) do
    if f.scripts.OnClick and f.text and f.text:match("^Metric") then
      for i = 1, #ns.METRICS + 1 do f.scripts.OnClick(f) end
    end
  end
  -- character selector
  for _, f in ipairs(ALL_FRAMES) do
    if f.scripts.OnClick and f.text and f.text:match("^Character") then
      f.scripts.OnClick(f); f.scripts.OnClick(f); f.scripts.OnClick(f)
    end
  end
  ns.viewSource = nil
end)

step("row / agg bar / bar tooltips run", function()
  for _, f in ipairs(ALL_FRAMES) do
    if f.scripts.OnEnter and (f.data or f.metric or f == ChronologFrame.aggBar) then
      f.scripts.OnEnter(f)
    end
  end
end)

step("widget: toggle, stats, scale, alpha", function()
  SlashCmdList.CHRONOLOG("widget")
  assert(ChronologWidget.shown)
  SlashCmdList.CHRONOLOG("widget stat kph")
  SlashCmdList.CHRONOLOG("widget stat xph")
  SlashCmdList.CHRONOLOG("widget stat deaths")
  SlashCmdList.CHRONOLOG("widget stat nonsense")
  SlashCmdList.CHRONOLOG("widget scale 1.4")
  SlashCmdList.CHRONOLOG("widget alpha 0.5")
  eq(ChronologForeverDB.widget.scale, 1.4); eq(ChronologForeverDB.widget.alpha, 0.5)
  assert(ChronologForeverDB.widget.stats.kph)
  UPDATE(1.1)
  ChronologWidget.scripts.OnEnter(ChronologWidget)
  ChronologWidget.scripts.OnMouseUp(ChronologWidget, "RightButton")
  assert(not ChronologWidget.shown)
end)

step("export builds CSV", function()
  SlashCmdList.CHRONOLOG("export")
  local text = ns.BuildExport(ns.GetAggregate(nil))
  assert(text:find("level,total_s"), "header")
  assert(text:find("Durotar"), "zones")
end)

step("minimap toggle + click handlers", function()
  SlashCmdList.CHRONOLOG("minimap"); SlashCmdList.CHRONOLOG("minimap")
  assert(ChronologMinimapButton)
  ChronologMinimapButton.scripts.OnClick(ChronologMinimapButton, "LeftButton")
  ChronologMinimapButton.scripts.OnClick(ChronologMinimapButton, "RightButton")
  ChronologMinimapButton.scripts.OnEnter(ChronologMinimapButton)
  ChronologMinimapButton.scripts.OnDragStart(ChronologMinimapButton)
  ChronologMinimapButton.scripts.OnUpdate(ChronologMinimapButton, 0.01)
  ChronologMinimapButton.scripts.OnDragStop(ChronologMinimapButton)
end)

step("debug, help, options, reset confirm", function()
  W.speedSecret = true
  SlashCmdList.CHRONOLOG("debug"); SlashCmdList.CHRONOLOG("help")
  SlashCmdList.CHRONOLOG("options"); SlashCmdList.CHRONOLOG("reset")
  W.speedSecret = false
end)

step("settings page builds (EllesmereUI mock)", function()
  if WITH_EUI then
    assert(PLUGIN, "plugin registered")
    local mod = PLUGIN.modules[1]
    local parent = {}
    for _, page in ipairs(mod.pages) do
      local h = mod.buildPage(page, parent, 0)
      assert(type(h) == "number", "page height")
    end
  end
end)

step("reset wipes data, keeps settings, re-syncs account", function()
  local keepScale = ChronologForeverDB.widget.scale
  SlashCmdList.CHRONOLOG("reset yes")
  eq(ChronologForeverDB.widget.scale, keepScale)
  eq(ChronologAccountDB.chars["Tester-Realm"].levels, ChronologForeverDB.levels, "resynced")
  eq(row().total, 0)
end)

step("old ChronologDB migrates to ChronologForeverDB", function()
  ChronologForeverDB = nil
  ChronologDB = { levels = { [3] = { combat = 5, total = 9, kills = 1 } }, startLevel = 3 }
  FIRE("PLAYER_LOGIN")
  eq(ChronologDB, nil, "old var cleared")
  eq(ChronologForeverDB.levels[3].total, 9)
  ns.GetAggregate(nil)
  eq(ChronologForeverDB.levels[3].zones ~= nil, true, "row migrated on access")
  eq(ChronologForeverDB.levels[3].dead, 0, "new fields backfilled")
end)

local out = table.concat(results, "\n")
out = out .. "\n\nPRINTED:\n  " .. table.concat(PRINTED, "\n  ")
return (failed == 0 and "ALL PASSED" or (failed .. " FAILED")) .. "\n" .. out
