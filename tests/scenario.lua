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

step("heat: packing round-trips exactly", function()
  local t, c, lo, hi = ns.HeatUnpack(ns.HeatPack(1048575, 789, 12, 60))
  eq(t, 1048575); eq(c, 789); eq(lo, 12); eq(hi, 60)
end)

step("heat: seconds per cell, combat share, level range; AFK not mapped", function()
  local heat = ChronologForeverDB.heat
  W.pos = { 0.505, 0.505 }
  local before = heat[1411] and heat[1411][5050] and ns.HeatUnpack(heat[1411][5050]) or 0
  TICKS(20, 0.25) -- 5s
  local t, c, lo, hi = ns.HeatUnpack(heat[1411][5050])
  assert(math.abs((t - before) - 5) <= 1, "about 5s in the cell, got " .. (t - before))
  eq(lo, W.level); eq(hi, W.level)
  -- combat
  W.pos = { 0.105, 0.205 }
  FIRE("PLAYER_REGEN_DISABLED"); TICKS(12, 0.25); FIRE("PLAYER_REGEN_ENABLED")
  local t2, c2 = ns.HeatUnpack(heat[1411][2010])
  assert(c2 >= 2 and c2 <= t2, "combat seconds recorded")
  -- AFK
  W.pos = { 0.305, 0.305 }; W.afk = true; TICKS(12, 0.25); W.afk = false
  eq(heat[1411][3030], nil, "AFK time not mapped")
  -- the account mirror points at the same table
  eq(ChronologAccountDB.chars["Tester-Realm"].heat, heat)
  local n = 0
  ns.ForEachHeatCell(nil, function(map, cell, x, y, tt) n = n + 1; assert(map == 1411 and tt > 0) end)
  assert(n >= 2, "cells iterate")
  W.pos = { 0.5, 0.5 }
end)

step("heat: micro maps fold into the zone; instances / secret positions are skipped", function()
  W.mapID = 9001; TICKS(8, 0.25)
  eq(MAP_POS_CALLS[#MAP_POS_CALLS], 1411, "cave recorded on the zone map")
  W.mapID = 1411
  W.pos = nil; TICKS(8, 0.25)      -- inside an instance
  W.posSecret = true; TICKS(8, 0.25); W.posSecret = false
  W.pos = { 0.5, 0.5 }
end)

step("subzones recorded per zone", function()
  W.subzone = "Razor Hill"; TICKS(8, 0.25)
  W.subzone = ""; TICKS(4, 0.25)
  local subs = row().subzones.Durotar
  assert(subs["Razor Hill"] >= 2, "subzone time")
  assert(subs[""] >= 1, "open area time")
  W.subzone = "Razor Hill"
end)

step("transport: standing still while the map position moves -> travel", function()
  W.speed = 0
  local r = row()
  local travel0 = r.travel
  local x = 0.40
  for i = 1, 6 do
    x = x + 0.005 -- 20 yards/second on a 4000-yard map
    W.pos = { x, 0.5 }
    TICKS(4, 0.25)
  end
  eq(NS.state.onTransport, true, "detected")
  assert(r.travel - travel0 >= 1.5, "boat time counted as travel")
  eq(NS.state.bucket, "travel (boat/zeppelin/tram)")
  -- walking on deck: on-foot travel, detection restarts
  W.speed = 7; x = x + 0.005; W.pos = { x, 0.5 }; TICKS(4, 0.25)
  eq(NS.state.onTransport, false)
  W.speed = 0
  -- standing still on solid ground (or an elevator): not transport
  for i = 1, 4 do TICKS(4, 0.25) end
  eq(NS.state.onTransport, false, "still")
  -- a teleport-sized jump isn't a boat
  W.pos = { 0.9, 0.1 }; TICKS(4, 0.25); W.pos = { 0.1, 0.9 }; TICKS(4, 0.25); W.pos = { 0.9, 0.1 }; TICKS(4, 0.25)
  eq(NS.state.onTransport, false, "jumps ignored")
  -- a loading screen resets it
  W.pos = { 0.5, 0.5 }
  FIRE("PLAYER_ENTERING_WORLD")
  eq(NS.state.onTransport, false)
end)

step("transport: moving with a secret speed, then stopping, isn't a boat", function()
  -- Seen in game: in combat the speed is secret while you move, then can read
  -- 0 at the moment of the sample. A second's movement must not be put down to
  -- a boat because of that one reading.
  W.speed = 0; W.pos = { 0.5, 0.5 }; TICKS(8, 0.25)
  local x = 0.5
  for i = 1, 4 do
    W.speedSecret = true
    for j = 1, 3 do x = x + 0.0015; W.pos = { x, 0.5 }; TICKS(1, 0.25) end -- ~18 yd/s
    W.speedSecret = false; TICKS(1, 0.25) -- speed reads 0 at the sample
    eq(NS.state.onTransport, false, "sample " .. i)
  end
  -- A real boat ride is still detected afterwards.
  for i = 1, 3 do x = x + 0.005; W.pos = { x, 0.5 }; TICKS(4, 0.25) end
  eq(NS.state.onTransport, true, "boat after")
  W.pos = { 0.5, 0.5 }; FIRE("PLAYER_ENTERING_WORLD")
end)

local function CountCells(pred)
  local n = 0
  for _, v in pairs(ChronologForeverDB.heat[1411]) do
    if not pred or pred(ns.HeatUnpack(v)) then n = n + 1 end
  end
  return n
end

step("heatmap: hooked into the world map as a data provider", function()
  assert(MAP_PROVIDER, "provider added")
  assert(ChronologHeatmapPanel, "controls built")
end)

step("heatmap: zone map draws one tile per visited cell; layers and level brackets filter", function()
  local o = ns.HeatmapOptions()
  o.shown, o.layer, o.source, o.bracket = true, "time", nil, 1
  W.viewMap = 1411; WorldMapFrame.shown = true
  MAP_PROVIDER:RefreshAllData()
  local n = CountCells()
  assert(n >= 3, "cells recorded")
  eq(ns.HeatmapStats().drawn, n, "one tile per cell")
  o.layer = "combat"; ns.RedrawHeatmap()
  local nc = CountCells(function(t, c) return c > 0 end)
  eq(ns.HeatmapStats().drawn, nc, "combat layer")
  assert(nc >= 1 and nc < n, "combat is a subset")
  o.layer = "time"
  o.bracket = 3; ns.RedrawHeatmap() -- levels 11-20: where we are
  eq(ns.HeatmapStats().drawn, n)
  o.bracket = 4; ns.RedrawHeatmap() -- levels 21-30: nothing yet
  eq(ns.HeatmapStats().drawn, 0)
  o.bracket = 1; ns.RedrawHeatmap()
end)

step("heatmap: a continent map shows the zone's data inside the zone's rectangle", function()
  W.viewMap = 1414; MAP_PROVIDER:OnMapChanged()
  local st = ns.HeatmapStats()
  assert(st.drawn >= 1, "projected")
  for d in pairs(st.grid) do
    local x, y = (d % 100) / 100, math.floor(d / 100) / 100
    assert(x >= 0.5 and x < 0.7 and y >= 0.4 and y < 0.6, "inside Durotar's rectangle")
  end
  W.viewMap = 9999; ns.RedrawHeatmap()
  eq(ns.HeatmapStats().drawn, 0, "unrelated map shows nothing")
  W.viewMap = 1411; ns.RedrawHeatmap()
end)

step("heatmap: hover tooltip follows the cursor without taking the mouse", function()
  GameTooltip.shown = false
  W.mouseOverMap = true; W.cursor = { 0.505, 0.505 }
  UPDATE(0.06)
  eq(GameTooltip.shown, true, "tooltip shown")
  local text = table.concat(GameTooltip.lines, "\n")
  assert(text:find("Durotar") and text:find("Time spent here") and text:find("Around here"), text)
  W.cursor = { 0.955, 0.955 }; UPDATE(0.06)
  eq(GameTooltip.shown, false, "empty spot hides it")
  -- someone else's tooltip is left alone
  GameTooltip:SetOwner(UIParent); GameTooltip:Show()
  W.cursor = { 0.505, 0.505 }; UPDATE(0.06)
  eq(GameTooltip:GetOwner(), UIParent, "not stolen")
  GameTooltip:Hide(); W.mouseOverMap = false
end)

step("heatmap: map controls, all characters, /chrono heatmap, setting", function()
  local o = ns.HeatmapOptions()
  for _, f in ipairs(ALL_FRAMES) do if f.heatBtn then f.scripts.OnClick(f) end end
  eq(o.shown, false); eq(o.layer, "combat"); eq(o.source, "ALL"); eq(o.bracket, 2)
  eq(ns.HeatmapStats().drawn, 0, "off draws nothing")
  SlashCmdList.CHRONOLOG("heatmap")
  eq(o.shown, true)
  o.layer, o.bracket = "time", 1; ns.RedrawHeatmap()
  assert(ns.HeatmapStats().drawn >= 1, "all characters")
  o.source = nil
  PROXIES.ChronologForever_Heatmap.set(false); eq(PROXIES.ChronologForever_Heatmap.get(), false)
  PROXIES.ChronologForever_Heatmap.set(true)
  WorldMapFrame.shown = false
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

step("pace never compares a character with a stale copy of itself", function()
  local a = ChronologAccountDB
  -- What the empty-realm-at-logout bug left behind: a copy filed under "Tester-".
  local copy = {}
  for L, r in pairs(ChronologForeverDB.levels) do copy[L] = { total = r.total, untracked = r.untracked, full = r.full } end
  a.chars["Tester-"] = { name = "Tester", realm = "", class = "SHAMAN", startLevel = 11, level = 12,
    levels = copy, updated = 9e9 }
  copy[11].total, copy[11].untracked = 1, 0 -- would be the best split if it counted
  local p = ns.GetPace()
  eq(p.levels[11].refName, "Fast", "the copy is ignored, not used as best split")
  for _, r in ipairs(ns.GetPaceRefs()) do assert(r.id ~= "Tester-", "copy offered as a reference") end
  -- The next sync removes it.
  FIRE("PLAYER_LEVEL_UP", W.level); W.level = W.level
  eq(a.chars["Tester-"], nil, "stale copy removed")
  assert(a.chars["Tester-Realm"].guid, "guid stored")
end)

step("empty realm at logout doesn't create a second entry", function()
  W.realmBlank = true
  FIRE("PLAYER_LOGOUT")
  W.realmBlank = false
  eq(ChronologAccountDB.chars["Tester-"], nil)
  assert(ChronologAccountDB.chars["Tester-Realm"], "still filed under the real realm")
end)

step("other characters' blank-realm duplicates are merged into one entry", function()
  local a = ChronologAccountDB
  a.chars["Dup-Realm"] = { name = "Dup", realm = "Realm", class = "MAGE", level = 9, levels = { [5] = { total = 10 } }, updated = 100 }
  a.chars["Dup-"] = { name = "Dup", realm = "", class = "MAGE", level = 14, levels = { [5] = { total = 99 } }, updated = 200 }
  FIRE("PLAYER_LOGOUT")
  eq(a.chars["Dup-"], nil, "blank copy folded in")
  eq(a.chars["Dup-Realm"].level, 14, "newer data kept")
  eq(a.chars["Dup-Realm"].realm, "Realm")
  -- different realms stay separate characters
  a.chars["Dup-Other"] = { name = "Dup", realm = "Other", class = "MAGE", levels = {}, updated = 300 }
  FIRE("PLAYER_LOGOUT")
  assert(a.chars["Dup-Other"] and a.chars["Dup-Realm"], "kept apart")
  a.chars["Dup-Other"], a.chars["Dup-Realm"] = nil, nil
end)

step("reputation: chat lines are recorded per level and faction", function()
  local lvl = W.level
  local r = row()
  FIRE("CHAT_MSG_COMBAT_FACTION_CHANGE", "Reputation with Orgrimmar increased by 250.")
  FIRE("CHAT_MSG_COMBAT_FACTION_CHANGE", "Reputation with Orgrimmar increased by 1,250. (+125.0 bonus)")
  FIRE("CHAT_MSG_COMBAT_FACTION_CHANGE", "Reputation with Booty Bay decreased by 25.")
  FIRE("CHAT_MSG_COMBAT_FACTION_CHANGE", "Reputation with Darkspear Trolls increased by 10.")
  FIRE("CHAT_MSG_COMBAT_FACTION_CHANGE", "You are now Friendly with Orgrimmar.")
  FIRE("CHAT_MSG_COMBAT_FACTION_CHANGE", SECRET)
  eq(r.factions["Orgrimmar"], 1500, "gain incl. thousands separator and bonus suffix")
  eq(r.factions["Booty Bay"], -25, "loss")
  eq(r.factions["Darkspear Trolls"], 10)
  eq(r.factions["You are now Friendly with Orgrimmar"], nil, "standing line ignored")
  eq(ns.RepGained(r), 1510, "gains only")
  local list = ns.SortedFactions(r.factions)
  eq(list[1].name, "Orgrimmar"); eq(list[2].name, "Booty Bay", "sorted by size of change")
  eq(ns.FormatRep(1500), "+1,500"); eq(ns.FormatRep(-25), "-25"); eq(ns.FormatRep(1234567), "+1,234,567")
  -- next level is kept apart
  W.level = lvl + 1
  FIRE("PLAYER_LEVEL_UP", W.level)
  FIRE("CHAT_MSG_COMBAT_FACTION_CHANGE", "Reputation with Orgrimmar increased by 75.")
  eq(row().factions["Orgrimmar"], 75)
  eq(ns.GetRow(ChronologForeverDB, lvl).factions["Orgrimmar"], 1500, "previous level unchanged")
  W.level = lvl
  ns.state.currentLevel = lvl
  -- totals and the all-characters view merge factions
  eq(ns.GetAggregate(nil).totals.factions["Orgrimmar"], 1575)
  ChronologAccountDB.chars["Alt-Realm"].levels[5].factions = { Orgrimmar = 25, Undercity = 40 }
  local all = ns.GetAggregate("ALL").totals.factions
  eq(all["Orgrimmar"], 1600); eq(all["Undercity"], 40)
  -- tooltip and export
  local text = ns.BuildExport(ns.GetAggregate(nil))
  assert(text:find("level,faction,reputation", 1, true), "rep table exported")
  assert(text:find(lvl .. ",Orgrimmar,1500", 1, true), "rep row exported")
  assert(text:find(lvl .. ",Booty Bay,-25", 1, true), "loss exported")
end)

step("reputation: localized / positional format strings", function()
  local pat, order = ns.RepToPattern("Euer Ruf bei der Fraktion '%s' hat sich um %d verbessert.")
  local caps = { ("Euer Ruf bei der Fraktion 'Orgrimmar' hat sich um 1.250 verbessert."):match(pat) }
  eq(caps[1], "Orgrimmar"); eq(caps[2], "1.250"); eq(order[1], 1); eq(order[2], 2)
  pat, order = ns.RepToPattern("%2$d Ruf bei %1$s (100%%).")
  caps = { ("300 Ruf bei Ironforge (100%)."):match(pat) }
  eq(caps[1], "300"); eq(caps[2], "Ironforge"); eq(order[1], 2); eq(order[2], 1)
  local name, amount = ns.ParseRepMessage("Reputation with Thunder Bluff decreased by 5.")
  eq(name, "Thunder Bluff"); eq(amount, -5)
  eq(ns.ParseRepMessage("Reputation with Thunder Bluff increased by 0."), nil, "zero ignored")
end)

step("reputation: current standing from the faction list", function()
  local st = ns.GetFactionStanding("Orgrimmar")
  eq(st.label, "Friendly"); eq(st.value, 1200); eq(st.max, 6000)
  eq(st.color[2], 0.6)
  eq(ns.GetFactionStanding("Horde"), nil, "header without rep skipped")
  eq(ns.GetFactionStanding("Hidden"), nil, "secret standing skipped")
  -- cached until the reputation list changes
  local calls = FACTION_LIST_CALLS
  ns.GetFactionStanding("Orgrimmar")
  eq(FACTION_LIST_CALLS, calls, "cached")
  W.factionList[2][3] = 6
  FIRE("UPDATE_FACTION")
  local st2 = ns.GetFactionStanding("Orgrimmar")
  eq(FACTION_LIST_CALLS, calls + 1, "rebuilt after UPDATE_FACTION")
  eq(st2.label, "?", "unknown label falls back")
  W.factionList[2][3] = 5
  FIRE("UPDATE_FACTION")
end)

step("flight paths: time, count and cost (clicked destination, or money fallback)", function()
  local r = row()
  local f0, n0, c0, spent0, travel0 = r.flight, r.flights, r.flightCost, r.spent, r.travel
  -- enough gold for the flights, without counting it as income
  local money0 = W.money
  W.money = W.money + 20000; ns.state.lastMoney = W.money
  W.speed = 0
  -- 1) pick a destination on the flight map: its price is the cost
  W.taxiCost = 1234
  TakeTaxiNode(3)
  eq(TAXI_TAKEN, 3, "original TakeTaxiNode still runs")
  W.money = W.money - 1234; FIRE("PLAYER_MONEY")
  W.taxi = true
  TICKS(8, 0.25) -- 2s in the air
  eq(r.flights, n0 + 1, "one flight")
  eq(r.flightCost, c0 + 1234, "cost from the destination")
  near(r.flight, f0 + 2, "time in the air")
  near(r.travel, travel0 + 2, "flying is travel")
  eq(r.spent, spent0 + 1234, "and the gold counts as spent")
  eq(ns.state.bucket, "travel (flight path)")
  TICKS(4, 0.25)
  eq(r.flights, n0 + 1, "still the same flight")
  W.taxi = false; TICKS(2, 0.25)
  -- 2) no destination click seen: the gold paid just before takeoff
  ADVANCE(60)
  W.money = W.money - 300; FIRE("PLAYER_MONEY")
  ADVANCE(1)
  W.taxi = true; TICKS(2, 0.25)
  eq(r.flights, n0 + 2); eq(r.flightCost, c0 + 1534, "money paid before takeoff")
  W.taxi = false; TICKS(2, 0.25)
  -- 3) the money leaves just after takeoff
  ADVANCE(60)
  W.taxi = true; TICKS(2, 0.25)
  eq(r.flightCost, c0 + 1534, "nothing yet")
  W.money = W.money - 66; FIRE("PLAYER_MONEY")
  eq(r.flightCost, c0 + 1600, "money paid just after takeoff")
  W.taxi = false; TICKS(2, 0.25)
  -- 4) an old purchase isn't mistaken for a flight
  ADVANCE(60)
  W.money = W.money - 5000; FIRE("PLAYER_MONEY")
  ADVANCE(30)
  W.taxi = true; TICKS(2, 0.25)
  ADVANCE(30)
  W.money = W.money - 70; FIRE("PLAYER_MONEY")
  eq(r.flights, n0 + 4); eq(r.flightCost, c0 + 1600, "unrelated spending ignored")
  W.taxi = false; TICKS(2, 0.25)
  -- money formatting
  eq(ns.FormatCoins(123456), "|cffffd70012g|r |cffc7c7cf34s|r |cffeda55f56c|r")
  eq(ns.FormatCoins(56), "|cffeda55f56c|r")
  eq(ns.FormatCoins(10002), "|cffffd7001g|r |cffc7c7cf0s|r |cffeda55f2c|r")
  eq(ns.ShortCoins(15000), "1.5g"); eq(ns.ShortCoins(850), "9s"); eq(ns.ShortCoins(40), "40c")
  -- exported and shown in the level tooltip
  local text = ns.BuildExport(ns.GetAggregate(nil))
  assert(text:find("flight_s,flights,flight_copper", 1, true), "export header")
  GameTooltip:SetOwner(UIParent)
  ns.AddBreakdown(GameTooltip, r, nil, nil)
  local tip = table.concat(GameTooltip.lines, "\n")
  assert(tip:find("Flight paths (4 flights)", 1, true), "level tooltip: " .. tip)
  W.money = money0; ns.state.lastMoney = money0
end)

step("main window builds and refreshes all tabs / sources", function()
  SlashCmdList.CHRONOLOG("")
  assert(ChronologFrame and ChronologFrame.shown, "window shown")
  for _, src in ipairs({ false, "Alt-Realm", "ALL" }) do
    ns.viewSource = src or nil
    -- cycle tabs via their buttons
    UPDATE(1.1)
    for _, f in ipairs(ALL_FRAMES) do
      if f.scripts.OnClick and f.text and (f.text == "Zones" or f.text == "Reputation" or f.text == "Charts" or f.text == "Levels") then
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
  eq(#modes, 9, "chart mode buttons")
  -- the main window's flight line and its tooltip
  local ft = ChronologFrame.flightText.text
  assert(ft:find("Flight paths", 1, true) and ft:find("4 flights", 1, true), "flight line: " .. ft)
  -- the Flights chart: a column for the level, cost above it, a headline
  for _, f in ipairs(ALL_FRAMES) do
    if f.scripts.OnClick and f.text == "Charts" then f.scripts.OnClick(f) end
  end
  for _, b in ipairs(modes) do
    if b.mode == "flights" then b.scripts.OnClick(b) end
  end
  local cols, headline = 0, nil
  for _, f in ipairs(ALL_FRAMES) do
    if f.segs and f.tip and f.shown then
      f.scripts.OnEnter(f)
      assert(table.concat(GameTooltip.lines, "\n"):find("Time in the air", 1, true), "flights tooltip")
      assert(f.top.text:find("16s", 1, true), "cost above the column (1,600c): " .. tostring(f.top.text))
      cols = cols + 1
    end
    if f.shown and type(f.text) == "string" and f.text:find("in the air", 1, true) then headline = f.text end
  end
  eq(cols, 1, "one level with flights")
  assert(headline and headline:find("on 4 flights", 1, true), "headline: " .. tostring(headline))
  for _, src in ipairs({ false, "Fast-Realm", "ALL" }) do
    ns.viewSource = src or nil
    for _, f in ipairs(ALL_FRAMES) do
      if f.scripts.OnClick and f.text == "Charts" then f.scripts.OnClick(f) end
    end
    for _, b in ipairs(modes) do b.scripts.OnClick(b) end
  end
  ns.viewSource = nil
  -- the Rep chart: one column per level with reputation, tooltips render
  for _, b in ipairs(modes) do
    if b.mode == "rep" then b.scripts.OnClick(b) end
  end
  local repCols, lossCols = 0, 0
  for _, f in ipairs(ALL_FRAMES) do
    if f.segs and f.tip and f.shown then -- chart columns
      f.scripts.OnEnter(f)
      local text = table.concat(GameTooltip.lines or {}, "\n")
      assert(text:find("Reputation gained", 1, true), "rep column tooltip: " .. text)
      assert(text:find("Orgrimmar", 1, true), "faction listed")
      if text:find("Reputation lost", 1, true) then lossCols = lossCols + 1 end
      repCols = repCols + 1
    end
  end
  eq(repCols, 2, "a rep chart column for each level with reputation")
  eq(lossCols, 1, "the level with a loss says so")
  -- the axis extends below zero for the Booty Bay loss (step 500 for +1,510)
  local below
  for _, f in ipairs(ALL_FRAMES) do
    if f.shown and f.text == "-500" then below = true end
  end
  assert(below, "negative gridline label")
  for _, b in ipairs(modes) do
    if b.mode == "pace" then b.scripts.OnClick(b) end
  end
  eq(ChronologForeverDB.chartMode, "pace")
  -- character selector without the menu API: cycles through every source and back
  local cb = ChronologFrame.charBtn
  for i = 1, #ns.GetSources() do cb.scripts.OnClick(cb) end
  eq(ns.viewSource, nil, "back to this character")
  ns.viewSource = nil
  -- header shows the class-colored name and level
  RAID_CLASS_COLORS = { SHAMAN = { r = 0, g = 0.44, b = 0.87 } }
  UPDATE(1.1)
  assert(cb.value.text:find("|cff0070deTester", 1, true) and cb.value.text:find("Lv " .. ns.state.currentLevel, 1, true),
    "selector value: " .. tostring(cb.value.text))
  -- Forever surnames: the full name is shown and remembered
  W.pvpName = "Tester Rolemodel"
  FIRE("UNIT_NAME_UPDATE", "player")
  eq(ChronologAccountDB.chars["Tester-Realm"].fullName, "Tester Rolemodel", "full name stored")
  UPDATE(1.1)
  assert(cb.value.text:find("Tester Rolemodel", 1, true), "selector shows full name: " .. cb.value.text)
  -- not available (e.g. at logout): keep the last known full name
  W.pvpName = ""
  FIRE("PLAYER_LOGOUT")
  eq(ChronologAccountDB.chars["Tester-Realm"].fullName, "Tester Rolemodel", "kept when unavailable")
  -- another unit's name update is ignored; a name without a surname is used as is
  W.pvpName = "Someone Else"
  FIRE("UNIT_NAME_UPDATE", "target")
  eq(ChronologAccountDB.chars["Tester-Realm"].fullName, "Tester Rolemodel")
  W.pvpName = nil
  FIRE("UNIT_NAME_UPDATE", "player")
  eq(ChronologAccountDB.chars["Tester-Realm"].fullName, "Tester", "plain name")
  -- other characters' full names label the menu and pace references
  ChronologAccountDB.chars["Fast-Realm"].fullName = "Fast Runner"
  local found
  for _, src in ipairs(ns.GetSources()) do if src.label == "Fast Runner" then found = true end end
  assert(found, "sources use the full name")
  found = false
  for _, r in ipairs(ns.GetPaceRefs()) do if r.label == "Fast Runner" then found = true end end
  assert(found, "pace references use the full name")
  -- with the menu API: a radio per source, "All characters" after a divider,
  -- and picking one switches the view
  local items, dividers, removeMenu
  MenuUtil = { CreateContextMenu = function(owner, gen)
    items, dividers, removeMenu = {}, 0, nil
    local root = {
      CreateTitle = function() end,
      CreateDivider = function() dividers = dividers + 1 end,
      CreateRadio = function(_, text, isSel, setSel, data)
        items[#items + 1] = { text = text, isSel = isSel, setSel = setSel, data = data }
      end,
      CreateButton = function(_, text)
        removeMenu = { title = text, entries = {} }
        return { CreateButton = function(_, t, fn) table.insert(removeMenu.entries, { text = t, fn = fn }) end }
      end,
    }
    gen(owner, root)
    MENU_FRAME = { ClearAllPoints = function() end,
      SetPoint = function(self, p, rel, rp) self.pt = { p, rel, rp } end }
    return MENU_FRAME
  end }
  cb.scripts.OnClick(cb)
  eq(MENU_FRAME.pt[1], "TOPRIGHT"); eq(MENU_FRAME.pt[2], cb, "menu drops down from the selector")
  eq(MENU_FRAME.pt[3], "BOTTOMRIGHT")
  local sources = ns.GetSources()
  eq(#items, #sources, "one radio per source")
  eq(dividers, 2, "dividers before All characters and the remove submenu")
  assert(removeMenu and removeMenu.title:find("Remove a character", 1, true), "remove submenu")
  eq(#removeMenu.entries, #sources - 2, "every other character (not you, not All)")
  for _, e in ipairs(removeMenu.entries) do
    assert(not e.text:find("Tester", 1, true), "can't remove yourself")
  end
  assert(items[1].isSel(items[1].data), "this character selected")
  assert(items[1].text:find("(you)", 1, true), "you marked")
  assert(items[#items].text:find("All characters", 1, true), "all last")
  items[#items].setSel(items[#items].data)
  eq(ns.viewSource, "ALL", "picked all characters")
  assert(cb.value.text:find("All characters", 1, true), "selector updated")
  items[1].setSel(items[1].data)
  eq(ns.viewSource, nil)
  MenuUtil = nil
  -- the Reputation tab lists this character's factions with standing
  for _, f in ipairs(ALL_FRAMES) do
    if f.scripts.OnClick and f.text == "Reputation" then f.scripts.OnClick(f) end
  end
  local found
  for _, f in ipairs(ALL_FRAMES) do
    if f.faction == "Orgrimmar" and f.shown then found = f end
  end
  assert(found, "Orgrimmar row shown")
  eq(found.amount.text, "+1,575")
  assert(found.standing.text:find("Friendly"), "standing shown")
  for _, f in ipairs(ALL_FRAMES) do
    if f.scripts.OnClick and f.text == "Levels" then f.scripts.OnClick(f) end
  end
end)

step("window resizes: tiles and level bars stretch, size is saved and clamped", function()
  local f = ChronologFrame
  eq(f.w, 580, "default width"); eq(f.h, 700, "default height")
  assert(f.grip, "resize grip")
  -- widen to 1000: tiles share the extra room, the activity bar takes it all
  f.GetWidth = function() return 1000 end
  f.GetHeight = function() return 800 end
  f.scripts.OnSizeChanged(f)
  local tileW
  for _, t in ipairs(ALL_FRAMES) do
    if t.edge and t.value and t.sub then tileW = t.w end
  end
  near(tileW, (1000 - 40 - 18) / 4, "tile width")
  local span
  for _, t in ipairs(ALL_FRAMES) do if t.w == 150 + 420 then span = t end end
  assert(span, "activity bar span widened by 420")
  UPDATE(0.06) -- redraw after a resize
  local rowBar
  for _, t in ipairs(ALL_FRAMES) do if t.segs and t.w == 570 then rowBar = t end end
  assert(rowBar, "level rows' activity bars widened")
  f.grip.scripts.OnMouseUp(f.grip, "LeftButton")
  eq(ChronologForeverDB.window.w, 1000, "width saved"); eq(ChronologForeverDB.window.h, 800, "height saved")
  -- right-click resets
  f.grip.scripts.OnMouseUp(f.grip, "RightButton")
  eq(f.w, 580); eq(f.h, 700)
  -- narrower than the default never shrinks the tiles below their normal size
  f.GetWidth = function() return 100 end
  f.scripts.OnSizeChanged(f)
  for _, t in ipairs(ALL_FRAMES) do
    if t.edge and t.value and t.sub then eq(t.w, 131, "min tile width") end
  end
  f.GetWidth, f.GetHeight = nil, nil
  f.scripts.OnSizeChanged(f)
end)

step("Zones and Reputation tables stretch with the window", function()
  -- 420px wider than the default: 140 to the name column, 280 to the bars
  for _, id in ipairs({ "zones", "rep" }) do ns.views[id].GetWidth = function() return 960 end end
  ns.views.zones.Refresh(ns.GetAggregate(nil))
  ns.views.rep.Refresh(ns.GetAggregate(nil))
  local zoneRow, repRow
  for _, t in ipairs(ALL_FRAMES) do
    if t.zone == "Durotar" and t.shown then zoneRow = t end
    if t.faction == "Orgrimmar" and t.shown then repRow = t end
  end
  eq(zoneRow.name.w, 340, "zone name column")
  eq(zoneRow.bar.pt[2], 346, "zone bar moved")
  eq(zoneRow.pct.pt[2], 760, "share column moved")
  eq(zoneRow.time.pt[2], 804, "time column moved")
  eq(repRow.name.w, 314, "faction name column (174 + 140)")
  eq(repRow.standing.pt[2], 336, "standing moved")
  eq(repRow.amount.pt[2], 830, "gained column moved")
  eq(repRow.bar.w, 100 + 280, "biggest faction's bar fills the wider column")
  -- back to the default layout
  for _, id in ipairs({ "zones", "rep" }) do ns.views[id].GetWidth = nil end
  ns.views.zones.Refresh(ns.GetAggregate(nil))
  ns.views.rep.Refresh(ns.GetAggregate(nil))
  eq(zoneRow.pct.pt[2], 340); eq(repRow.amount.pt[2], 410); eq(repRow.bar.w, 100)
end)

step("Rep chart colors: top 6 by default, or the factions you choose", function()
  local function Click(text)
    for _, f in ipairs(ALL_FRAMES) do
      if f.scripts.OnClick and f.text == text then f.scripts.OnClick(f) end
    end
  end
  local function Caption()
    for _, f in ipairs(ALL_FRAMES) do
      if f.shown and type(f.text) == "string" and f.text:find("Lost|r", 1, true) then return f.text end
    end
  end
  Click("Charts")
  for _, f in ipairs(ALL_FRAMES) do
    if f.mode == "rep" then f.scripts.OnClick(f) end
  end
  -- default: biggest gainer first, no "Other" (only two factions gained)
  local cap = Caption()
  assert(cap:find("Orgrimmar", 1, true) < cap:find("Darkspear Trolls", 1, true), "top factions in order: " .. cap)
  assert(not cap:find("Other", 1, true), "no Other yet")
  -- choose Darkspear Trolls by clicking its row on the Reputation tab
  Click("Reputation")
  local row
  for _, f in ipairs(ALL_FRAMES) do
    if f.faction == "Darkspear Trolls" and f.shown then row = f end
  end
  assert(row.colored, "top-6 faction has a color")
  row.scripts.OnMouseUp(row, "LeftButton")
  eq(ns.IsRepPrimaryChosen("Darkspear Trolls"), 1, "chosen")
  local hint = ns.views.rep.hint.text
  assert(hint:find("1 chosen", 1, true), "hint: " .. hint)
  assert(ns.views.rep.resetBtn.shown, "reset shown")
  local orgRow
  for _, f in ipairs(ALL_FRAMES) do
    if f.faction == "Orgrimmar" and f.shown then orgRow = f end
  end
  assert(not orgRow.colored, "Orgrimmar is Other now")
  -- the chart follows: Darkspear has the first color, Orgrimmar is in Other
  Click("Charts")
  cap = Caption()
  assert(cap:find("Darkspear Trolls", 1, true) and cap:find("Other", 1, true), "chosen + Other: " .. cap)
  assert(not cap:find("Orgrimmar", 1, true), "Orgrimmar not in the legend")
  local colorOf = ns.RepColors(ns.GetAggregate(nil).totals.factions)
  eq(colorOf["Darkspear Trolls"][1], 0.30, "first palette color")
  -- up to six; a seventh is refused
  for i = 1, 5 do eq(ns.ToggleRepPrimary("Faction " .. i), true) end
  eq(ns.ToggleRepPrimary("Faction 6"), false, "seventh refused")
  -- clicking a chosen faction again removes it
  row.scripts.OnMouseUp(row, "LeftButton")
  eq(ns.IsRepPrimaryChosen("Darkspear Trolls"), nil, "removed")
  -- "Use top 6" goes back to the default
  Click("Reputation")
  ns.views.rep.resetBtn.scripts.OnClick(ns.views.rep.resetBtn)
  eq(#ChronologForeverDB.repPrimary, 0, "reset")
  assert(ns.views.rep.hint.text:find("top 6", 1, true), "hint back to default")
  assert(not ns.views.rep.resetBtn.shown, "reset hidden")
  Click("Charts")
  for _, f in ipairs(ALL_FRAMES) do
    if f.mode == "pace" then f.scripts.OnClick(f) end
  end
  Click("Levels")
end)

step("remove another character (menu / slash command, with confirmation)", function()
  local a = ChronologAccountDB
  a.chars["Gone-Realm"] = { name = "Gone", fullName = "Gone Away", class = "MAGE", startLevel = 1, level = 12,
    levels = { [5] = { total = 300, kills = 9 } }, heat = {} }
  ChronologForeverDB.paceRef = "Gone-Realm"
  ns.viewSource = "Gone-Realm"
  -- the slash command needs a name, then asks to confirm
  POPUP = nil
  SlashCmdList.CHRONOLOG("remove")
  eq(POPUP, nil, "no popup without a name")
  assert(PRINTED[#PRINTED]:find("Gone Away", 1, true), "lists the characters: " .. PRINTED[#PRINTED])
  SlashCmdList.CHRONOLOG("remove gone away")
  eq(POPUP.name, "CHRONOLOG_FOREVER_REMOVE_CHAR"); eq(POPUP.arg, "Gone Away"); eq(POPUP.data, "Gone-Realm")
  assert(a.chars["Gone-Realm"], "nothing deleted before confirming")
  -- confirming deletes it and clears anything pointing at it
  StaticPopupDialogs.CHRONOLOG_FOREVER_REMOVE_CHAR.OnAccept(nil, POPUP.data)
  eq(a.chars["Gone-Realm"], nil, "removed")
  eq(ns.viewSource, nil, "view falls back to this character")
  eq(ChronologForeverDB.paceRef, nil, "pace falls back to best splits")
  for _, src in ipairs(ns.GetSources()) do assert(src.id ~= "Gone-Realm", "gone from the character list") end
  -- the plain name also works; yourself can never be removed
  a.chars["Gone-Realm"] = { name = "Gone", levels = {} }
  SlashCmdList.CHRONOLOG("remove gone")
  eq(POPUP.data, "Gone-Realm")
  StaticPopupDialogs.CHRONOLOG_FOREVER_REMOVE_CHAR.OnAccept(nil, POPUP.data)
  eq(ns.RemoveCharacter("Tester-Realm"), false, "can't remove the logged-in character")
  assert(a.chars["Tester-Realm"], "still there")
  POPUP = nil
  SlashCmdList.CHRONOLOG("remove tester")
  eq(POPUP, nil, "not offered for yourself")
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
  SlashCmdList.CHRONOLOG("widget stat rep")
  assert(ChronologForeverDB.widget.stats.rep, "rep stat available")
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
  assert(text:find("level,zone,subzone,seconds") and text:find("Razor Hill"), "subzones exported")
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
  -- Every value the debug dump reads may be secret (e.g. in combat).
  W.speedSecret = true; W.xpSecret = true; W.pvpName = SECRET
  SlashCmdList.CHRONOLOG("debug"); SlashCmdList.CHRONOLOG("help")
  W.xpSecret = false; W.pvpName = nil
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

local function Relog(playedDelta, levelTime)
  local cp = ChronologForeverDB.checkpoint
  NS.state.recoveryChecked, NS.state.playedBase = nil, nil
  FIRE("PLAYER_LOGIN"); ADVANCE(3); RUN_TIMERS()
  FIRE("TIME_PLAYED_MSG", cp.played + playedDelta + 3, levelTime)
end

step("statistics refresh once a minute from the ticker; a blank logout read falls back to it", function()
  W.stats.kills = W.stats.kills + 5
  TICKS(250, 0.25) -- a bit over 60s of tracked time
  W.statsBlank = true
  FIRE("PLAYER_LOGOUT")
  W.statsBlank = false
  eq(ChronologForeverDB.checkpoint.stats.kills, W.stats.kills, "last good kill statistic used")
end)

step("graceful logout where the client reports 0 XP/gold: nothing recovered", function()
  -- The save-prompt test fired level-ups without changing the mock level; resync.
  FIRE("PLAYER_LEVEL_UP", W.level)
  eq(NS.state.currentLevel, W.level)
  local r = ns.GetRow(ChronologForeverDB, W.level)
  local xp0, gold0, n0 = r.xp, r.gold, #(ChronologForeverDB.recoveries or {})
  W.zeroValues = true
  FIRE("PLAYER_LOGOUT")
  W.zeroValues = false
  local cp = ChronologForeverDB.checkpoint
  eq(cp.xp, W.xp, "checkpoint XP comes from live tracking, not the logout read")
  eq(cp.money, W.money, "same for gold")
  eq(cp.stats.kills, W.stats.kills, "statistics fine")
  Relog(0, 1000)
  eq(#(ChronologForeverDB.recoveries or {}), n0, "no recovery")
  eq(r.xp, xp0); eq(r.gold, gold0)
end)

step("a v1.3 zero checkpoint: no recovery when /played shows no lost time", function()
  W.zeroValues = false
  FIRE("PLAYER_LOGOUT")
  local cp = ChronologForeverDB.checkpoint
  cp.xp, cp.xpMax, cp.money = 0, 0, 0 -- what v1.3 wrote
  local r = ns.GetRow(ChronologForeverDB, W.level)
  local xp0, gold0, n0 = r.xp, r.gold, #ChronologForeverDB.recoveries
  Relog(0, 1000)
  eq(#ChronologForeverDB.recoveries, n0); eq(r.xp, xp0); eq(r.gold, gold0)
end)

step("a real crash after a zero checkpoint: time recovered, bogus XP baseline ignored", function()
  W.zeroValues = false
  FIRE("PLAYER_LOGOUT")
  local cp = ChronologForeverDB.checkpoint
  cp.xp, cp.xpMax, cp.money = 0, 0, nil
  local r = ns.GetRow(ChronologForeverDB, W.level)
  local xp0, lost0 = r.xp, r.lost
  Relog(900, ns.LevelTime(r) + r.loading + 900 + 3)
  near(r.lost - lost0, 900, "lost time recovered")
  eq(r.xp, xp0, "no XP invented from a zero checkpoint")
end)

step("repair: v1.3's bogus logout recoveries are undone once", function()
  local db = ChronologForeverDB
  local r = ns.GetRow(db, W.level)
  r.xp = r.xp + 500; r.gold = r.gold + 1000
  local xp1, gold1 = r.xp, r.gold
  table.insert(db.recoveries, 1, { time = 0, from = W.level, to = W.level, xp = 500, gold = 1000,
    kills = 0, quests = 0, deaths = 0 })
  db.repairedZeroCheckpoint = nil
  NS.state.recoveryChecked = true -- no /played reply in this relog
  FIRE("PLAYER_LOGIN")
  eq(r.xp, xp1 - 500); eq(r.gold, gold1 - 1000)
  eq(db.recoveries[1].reverted, true)
  local found = false
  for _, line in ipairs(PRINTED) do if line:find("removed 1 incorrect recovery") then found = true end end
  assert(found, "note printed")
  FIRE("PLAYER_LOGIN") -- runs only once
  eq(r.xp, xp1 - 500)
  -- genuine recoveries (with lost time) are untouched
  for i = 2, #db.recoveries do assert(not db.recoveries[i].reverted or db.recoveries[i].time == 0) end
end)

step("reset wipes data, keeps settings, re-syncs account", function()
  ChronologForeverDB.paceRef = "Fast-Realm"
  ChronologForeverDB.repPrimary = { "Orgrimmar" }
  local keepScale = ChronologForeverDB.widget.scale
  SlashCmdList.CHRONOLOG("reset yes")
  eq(ChronologForeverDB.widget.scale, keepScale)
  eq(ChronologForeverDB.paceRef, "Fast-Realm", "pace ref kept")
  eq(ChronologForeverDB.repPrimary[1], "Orgrimmar", "primary factions kept")
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
