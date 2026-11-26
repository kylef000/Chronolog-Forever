# Chronolog-Forever (CurseForge page draft)

**Not just how long each level took, but how you spent it.**

Chronolog-Forever tracks every level you play on WoW Forever: what you were
doing, where you were, what you earned, and how your pace compares with your
other characters.

## Highlights

- **Where your time goes.** Every second is split into Combat, Travel, AFK, Dead
  and Other, so the buckets always add up. Travel counts running, mounts,
  travel forms (Ghost Wolf, Travel Form), flight paths, and boats, zeppelins
  and trams. Standing still on
  a mount doesn't count as travel.
- **Flight paths.** Time in the air, number of flights and what they cost, per
  level, with its own chart.
- **Where you were.** Open world, town, dungeons and PvP, plus time per zone
  and subzone.
- **Reputation by faction.** See which factions you earned reputation with at
  each level, and your total with each.
- **World map heatmap.** Your map is colored by where you actually spent your
  time. Switch between all time and combat only, this character and all your
  characters, or a level range. Hover any spot for details.
- **Pace splits.** Each level is compared against your *best splits* (the
  fastest any of your characters took for that level) or a character you pick.
  It's green when you're ahead and red when you're behind, with a running total.
- **Next level ETA.** Based on your last 30 minutes of play (AFK excluded),
  with an estimate for reaching 60.
- **Charts.** Stacked time per level, location share, pace, XP/hour, kills/hour,
  gold/hour, deaths and reputation, with gridlines, averages and hover details.
- **Counts the level you install on.** Time from before installing is filled in
  from `/played`.
- **Survives crashes.** WoW only saves addon data on logout or `/reload`. If the
  game crashes, Chronolog-Forever recovers the lost session's XP, gold, kills,
  quests and deaths at the next login, and its time as "not recorded".
- **Every character.** Switch between characters, or view your whole account
  combined.
- **Level widget.** A small box with the current level's stats, where you choose
  which stats to show.
- **Resizable window.** Drag the corner to make it bigger. The tables and
  charts use the extra room, and the size is remembered.
- **CSV export** for spreadsheets.
- **Fits your UI.** Options → AddOns page, addon menu entry, LibDBIcon minimap
  button and LibDataBroker launcher. With
  EllesmereUI installed, it uses your EllesmereUI theme and accent color.
- **Built for Forever.** It uses no combat log and handles the client's hidden
  ("secret") combat values.

## Commands

`/chrono` opens the window. `/chrono widget` shows or hides the level widget
(drag to move, right-click to hide). `/chrono help` lists everything else.

## How it counts

Addons can't read the combat log on WoW Forever, so a few things are
estimated:

- **Kills** below level 60 are counted from the "dies, you gain experience"
  chat line. Grey mobs give no XP, so they aren't counted. At level 60 a kill
  is counted when a hostile you targeted in combat dies, so area kills of
  mobs you never targeted are missed.
- **Dungeons** are credited when the Dungeon Finder rewards you, or, for runs
  you formed yourself, when you leave a 5-player dungeon after at least
  4 minutes inside.
- **In combat** the game hides your speed, so only mounts, travel forms and
  flight paths count as travel during a fight.
- **Before you installed it**, only the level you were on is filled in (from
  `/played`). The game doesn't keep the time for earlier levels.

<!-- Screenshots to add: main window (Levels tab), Charts → Time, Charts → Pace, the world map heatmap,
     the widget, and the Options → AddOns page. -->
