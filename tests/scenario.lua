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

step("/played backfill: request at login, chat muted then restored, untracked stored", function()
  eq(PLAYED_REQUESTS, 0, "not before the timer")
  RUN_TIMERS()
  eq(PLAYED_REQUESTS, 1, "requested")
  eq(ChatFrame1.events.TIME_PLAYED_MSG, nil, "chat muted while waiting")
  FIRE("TIME_PLAYED_MSG", 100000, 600)
  eq(ChatFrame1.events.TIME_PLAYED_MSG, true, "chat restored")
  local r = ns.GetRow(ChronologForeverDB, 11)
  near(r.untracked, 600, "untracked")
  eq(r.full, true)
  eq(ChronologForeverDB.playedTotal, 100000)
  eq(ns.LevelTime(r), 600)
  eq(r.xpMax, 1000, "xpMax recorded at login")
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

step("location: world / town / instance / pvp", function()
  local r = row()
  local w0, t0, i0, p0 = r.world, r.town, r.instance, r.pvp
  TICKS(4, 0.25); near(r.world - w0, 1, "world")
  W.resting = true; TICKS(4, 0.25); near(r.town - t0, 1, "town"); W.resting = false
  W.instType = "party"; FIRE("PLAYER_ENTERING_WORLD"); TICKS(4, 0.25); near(r.instance - i0, 1, "instance")
  W.instType = "pvp"; FIRE("PLAYER_ENTERING_WORLD"); TICKS(4, 0.25); near(r.pvp - p0, 1, "pvp")
  W.instType = nil; FIRE("PLAYER_ENTERING_WORLD")
  near(r.world + r.town + r.instance + r.pvp, r.total, "locations sum to total")
end)

step("ETA: recent XP rate -> time to next level and to 60", function()
  TICKS(600, 0.25) -- 150s of active play
  W.xp = 400; FIRE("PLAYER_XP_UPDATE")
  local rate, src = ns.GetXPRate()
  assert(rate and rate > 0, "rate"); eq(src, "recent")
  local toNext, toMax, estimated = ns.GetETA()
  assert(toNext and toNext > 0, "toNext")
  assert(toMax and toMax > toNext, "toMax")
  eq(estimated, true, "future levels extrapolated")
  -- AFK time doesn't count toward the rate
  local a = NS.state.active; W.afk = true; TICKS(40, 0.25); W.afk = false
  near(NS.state.active, a, "afk excluded")
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

step("pace: best splits, specific character, reference cycling", function()
  ChronologAccountDB.chars["Fast-Realm"] = { name = "Fast", startLevel = 1, level = 20, levels = {
    [11] = { total = 300, combat = 100, xpMax = 1000 }, [12] = { total = 200 } } }
  ChronologAccountDB.chars["Slow-Realm"] = { name = "Slow", startLevel = 1, level = 20, levels = {
    [11] = { total = 5000 } } }
  local p = ns.GetPace()
  eq(p.n, 1, "one finished level compared")
  eq(p.levels[11].ref, 300, "best split = fastest")
  eq(p.levels[11].refName, "Fast")
  assert(p.cum > 0, "behind the best split")
  eq(p.curLevel, 12); eq(p.curRef, 200)
  ns.SetPaceRef("Slow-Realm")
  p = ns.GetPace()
  eq(p.refLabel, "Slow"); assert(p.cum < 0, "ahead of Slow")
  ns.SetPaceRef("Gone-Realm") -- missing character falls back to best splits
  eq(ns.GetPace().refLabel, "best splits")
  ns.SetPaceRef("best")
  local refs = ns.GetPaceRefs()
  assert(#refs >= 3, "best + characters")
  SlashCmdList.CHRONOLOG("pace"); SlashCmdList.CHRONOLOG("pace")
  ns.SetPaceRef("best")
  assert(ns.GetPace("ALL") == nil, "no pace for ALL")
  assert(ns.GetPace("Fast-Realm"), "pace for another character")
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
  -- every chart mode, for every source
  local modes = {}
  for _, f in ipairs(ALL_FRAMES) do
    if f.mode and f.scripts.OnClick then modes[#modes + 1] = f end
  end
  eq(#modes, 7, "chart mode buttons")
  for _, src in ipairs({ false, "Fast-Realm", "ALL" }) do
    ns.viewSource = src or nil
    for _, f in ipairs(ALL_FRAMES) do
      if f.scripts.OnClick and f.text == "Charts" then f.scripts.OnClick(f) end
    end
    for _, b in ipairs(modes) do b.scripts.OnClick(b) end
  end
  ns.viewSource = nil
  for _, b in ipairs(modes) do
    if b.mode == "pace" then b.scripts.OnClick(b) end
  end
  eq(ChronologForeverDB.chartMode, "pace")
  -- character selector cycles through every source and back
  local cb = ChronologFrame.charBtn
  for i = 1, #ns.GetSources() do cb.scripts.OnClick(cb) end
  eq(ns.viewSource, nil, "back to this character")
  ns.viewSource = nil
end)

step("row / tile / bar / chart column tooltips run", function()
  for _, f in ipairs(ALL_FRAMES) do

    if f.scripts.OnEnter and f ~= ChronologWidget and f ~= ChronologMinimapButton then
      f.scripts.OnEnter(f)
      if f.scripts.OnLeave then f.scripts.OnLeave(f) end
    end
  end
end)

step("widget: toggle, stats, scale, alpha", function()
  SlashCmdList.CHRONOLOG("widget")
  assert(ChronologWidget.shown)
  SlashCmdList.CHRONOLOG("widget stat kph")
  SlashCmdList.CHRONOLOG("widget stat xph")
  SlashCmdList.CHRONOLOG("widget stat deaths")
  assert(ChronologForeverDB.widget.stats.eta and ChronologForeverDB.widget.stats.pace, "eta/pace default on")
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
  assert(text:find("untracked_s"), "new columns")
end)

step("minimap button (built-in or LibDBIcon) + addon compartment", function()
  if WITH_EUI then
    assert(DBICON and LDB_OBJ, "LibDBIcon used when available")
    assert(not ChronologMinimapButton, "no built-in button")
    SlashCmdList.CHRONOLOG("minimap"); eq(DBICON.shown, false)
    SlashCmdList.CHRONOLOG("minimap"); eq(DBICON.shown, true)
    LDB_OBJ.OnClick(nil, "LeftButton"); LDB_OBJ.OnTooltipShow(GameTooltip)
  else
    SlashCmdList.CHRONOLOG("minimap"); SlashCmdList.CHRONOLOG("minimap")
    assert(ChronologMinimapButton)
    ChronologMinimapButton.scripts.OnClick(ChronologMinimapButton, "LeftButton")
    ChronologMinimapButton.scripts.OnClick(ChronologMinimapButton, "RightButton")
    ChronologMinimapButton.scripts.OnEnter(ChronologMinimapButton)
    ChronologMinimapButton.scripts.OnDragStart(ChronologMinimapButton)
    ChronologMinimapButton.scripts.OnUpdate(ChronologMinimapButton, 0.01)
    ChronologMinimapButton.scripts.OnDragStop(ChronologMinimapButton)
  end
  ChronologForever_OnAddonCompartmentClick("Chronolog-Forever", "LeftButton")
  ChronologForever_OnAddonCompartmentEnter("Chronolog-Forever", UIParent)
  ChronologForever_OnAddonCompartmentLeave()
end)

step("Blizzard settings page: every setting reads and writes", function()
  local expected = { "Minimap", "ReadPlayed", "PaceRef", "WidgetShown", "WidgetScale", "WidgetAlpha", "Stat_eta" }
  for _, k in ipairs(expected) do assert(PROXIES["ChronologForever_" .. k], "missing setting " .. k) end
  PROXIES.ChronologForever_ReadPlayed.set(false); eq(PROXIES.ChronologForever_ReadPlayed.get(), false)
  PROXIES.ChronologForever_ReadPlayed.set(true)
  PROXIES.ChronologForever_WidgetScale.set(1.25); eq(PROXIES.ChronologForever_WidgetScale.get(), 1.25)
  PROXIES.ChronologForever_Stat_dead.set(true); eq(ChronologForeverDB.widget.stats.dead, true)
  PROXIES.ChronologForever_PaceRef.set("Fast-Realm"); eq(PROXIES.ChronologForever_PaceRef.get(), "Fast-Realm")
  PROXIES.ChronologForever_PaceRef.set("best")
  local opts = DROPDOWNS.ChronologForever_PaceRef()
  assert(#opts >= 3, "dropdown lists references")
  PROXIES.ChronologForever_Minimap.set(false); eq(PROXIES.ChronologForever_Minimap.get(), false)
  PROXIES.ChronologForever_Minimap.set(true)
  if not WITH_EUI then SlashCmdList.CHRONOLOG("options"); assert(SETTINGS_OPENED, "opened Blizzard settings") end
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

local function DeepCopy(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = DeepCopy(v) end
  return c
end

-- Save (logout), play an unsaved session, "crash" back to the saved file,
-- then log in again and answer the /played request.
local function CrashAndRelog(play)
  FIRE("PLAYER_LOGOUT")
  local saved = DeepCopy(ChronologForeverDB)
  local cp = saved.checkpoint
  local lostSecs, levelTimeLost = play() -- mutates W (the game), not the DB
  ChronologForeverDB = saved
  NS.state.recoveryChecked, NS.state.playedBase = nil, nil
  FIRE("PLAYER_LOGIN")
  ADVANCE(3); RUN_TIMERS()
  FIRE("TIME_PLAYED_MSG", cp.played + lostSecs + 3, levelTimeLost + 3)
  return cp
end

step("checkpoint written on save; /reload keeps the XP-rate window", function()
  local samplesBefore = #NS.rateSamples
  local activeBefore = NS.state.active
  FIRE("PLAYER_LOGOUT")
  local cp = ChronologForeverDB.checkpoint
  assert(cp and cp.played and cp.level == W.level, "checkpoint")
  eq(cp.stats.kills, 100, "statistics read")
  -- /reload: the Lua state is fresh, the saved session comes back
  NS.state.active = 0; wipe(NS.rateSamples)
  FIRE("PLAYER_LOGIN")
  near(NS.state.active, activeBefore, "active time restored")
  eq(#NS.rateSamples, samplesBefore, "rate samples restored")
end)

step("crash recovery, same level: time, kills, quests, XP, gold put back", function()
  local lvl = W.level
  local r0 = DeepCopy(ns.GetRow(ChronologForeverDB, lvl))
  local before = #PRINTED
  CrashAndRelog(function()
    W.xp = W.xp + 300; W.money = W.money + 5000
    W.stats.kills = W.stats.kills + 7; W.stats.quests = W.stats.quests + 2
    ADVANCE(1800)
    return 1800, ns.LevelTime(r0) + (r0.loading or 0) + 1800
  end)
  local r = ns.GetRow(ChronologForeverDB, lvl)
  near(r.lost - r0.lost, 1800, "lost time")
  eq(r.kills - r0.kills, 7); eq(r.recKills, 7)
  eq(r.quests - r0.quests, 2)
  eq(r.xp - r0.xp, 300); eq(r.gold - r0.gold, 5000)
  near(r.untracked, r0.untracked, "not mistaken for pre-install time")
  eq(ChronologForeverDB.recoveries[1].kills, 7)
  assert(PRINTED[#PRINTED]:find("recovered play that wasn't saved"), "login note")
  -- XP/gold aren't counted a second time by the live trackers
  FIRE("PLAYER_XP_UPDATE"); FIRE("PLAYER_MONEY")
  eq(r.xp - r0.xp, 300, "no double XP"); eq(r.gold - r0.gold, 5000, "no double gold")
end)

step("crash recovery across level-ups: time split by XP, levels marked estimated", function()
  local from = W.level
  local lostBefore = {}
  for L = from, from + 3 do lostBefore[L] = ns.GetRow(ChronologForeverDB, L).lost end
  CrashAndRelog(function()
    W.level = from + 3; W.xp = 200
    W.stats.kills = W.stats.kills + 30; W.stats.deaths = W.stats.deaths + 1
    ADVANCE(10800)
    return 10800, 1200
  end)
  local cur = from + 3
  local sum, kills = 0, 0
  for L = from, cur do
    local r = ns.GetRow(ChronologForeverDB, L)
    sum = sum + (r.lost - lostBefore[L])
    kills = kills + r.recKills
  end
  near(sum, 10800, "all lost time placed")
  near(ns.GetRow(ChronologForeverDB, cur).lost - lostBefore[cur], 1200, "current level from /played")
  eq(ns.GetRow(ChronologForeverDB, from + 1).estimated, true)
  eq(ns.GetRow(ChronologForeverDB, cur).estimated, nil, "current level is exact")
  assert(kills >= 30, "kills allocated")
  -- estimated levels stay out of pace
  local p = ns.GetPace()
  assert(not p.levels[from + 1], "estimated level not compared")
end)

step("nothing lost -> nothing recovered", function()
  local n = #ChronologForeverDB.recoveries
  CrashAndRelog(function() return 0, ns.LevelTime(ns.GetRow(ChronologForeverDB, W.level)) end)
  eq(#ChronologForeverDB.recoveries, n)
end)

step("optional save prompt after level-up", function()
  POPUP, RELOADED = nil, nil
  FIRE("PLAYER_LEVEL_UP", W.level + 1); RUN_TIMERS()
  eq(POPUP, nil, "off by default")
  ChronologForeverDB.options.savePrompt = true
  ADVANCE(400)
  W.combat = true
  FIRE("PLAYER_LEVEL_UP", W.level + 1); RUN_TIMERS()
  eq(POPUP, nil, "not in combat")
  W.combat = false; FIRE("PLAYER_REGEN_ENABLED")
  eq(POPUP and POPUP.name, "CHRONOLOG_FOREVER_SAVE")
  StaticPopupDialogs.CHRONOLOG_FOREVER_SAVE.OnAccept()
  eq(RELOADED, true)
  assert(PROXIES.ChronologForever_SavePrompt, "setting exists")
end)

step("reset wipes data, keeps settings, re-syncs account", function()
  ChronologForeverDB.paceRef = "Fast-Realm"
  local keepScale = ChronologForeverDB.widget.scale
  SlashCmdList.CHRONOLOG("reset yes")
  eq(ChronologForeverDB.widget.scale, keepScale)
  eq(ChronologForeverDB.paceRef, "Fast-Realm", "pace ref kept")
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
