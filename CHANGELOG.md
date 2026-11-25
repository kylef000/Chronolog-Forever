# Changelog

Each release's notes on GitHub (and CurseForge) are taken from its section
below. Add a `## vX.Y.Z - YYYY-MM-DD` section before tagging; the release
workflow refuses to publish a tag without one.

## Unreleased

### New

- **Reputation tracking**: reputation gained with each faction is now recorded
  per level.
  - A new **Reputation** tab lists every faction you've gained (or lost)
    reputation with, along with your current standing. Hover a faction to see
    which levels it came from.
  - A new **Rep** chart shows reputation gained per level, colored by faction,
    with losses (e.g. the opposing centaur clan) as red bars below the line.
  - Level tooltips show that level's top factions.
  - The widget can show reputation gained this level, and `/chrono export`
    includes a per-level, per-faction table.
- **Resizable window**: drag the bottom-right corner of the main window to make
  it wider or taller (right-click the corner to reset). Charts get wider bars,
  so a full 1-60 run stays readable; the Levels, Zones and Reputation tables
  stretch too. The size is remembered.

### Changed

- Charts label every level, or every other level, when there's room (instead
  of every 5th once you're past 20 levels).

### Notes

- Reputation is recorded from this version on; earlier levels have none.
  Reputation earned in a session that isn't saved (a crash) can't be recovered.

## v1.4.0 - 2026-11-25

The first release for **WoW Forever**. Data saved by the earlier Chronolog
is migrated automatically.

### New

- **World map heatmap**: your map is colored by where you've spent your time.
  - Zone maps show each spot; continent maps show your whole leveling path.
  - Switch between all time and combat only, this character and all your
    characters, or a level range.
  - Hover a spot for details. `/chrono heatmap` turns it on and off.
- **Pace splits**: each level you finish is compared with your best splits (the
  fastest any of your other characters took) or a character you choose. You see
  how much faster or slower each level was, plus a running total. Change what
  you're compared with using `/chrono pace`.
- **Next-level ETA**: based on your last 30 minutes of play (AFK excluded),
  with an estimate for reaching 60.
- **Where you spent your time**: open world, town, dungeons and PvP, plus time
  per zone and subzone.
- **Crash recovery**: if the game closes without saving, the lost time, XP,
  gold, kills, quests and deaths are put back at your next login.
- **Time from before installing**: the level you install on is filled in from
  `/played`.
- **More travel counted**: boat and zeppelin rides, and Ghost Wolf, Travel
  Form and Aquatic Form, now count as travel.
- **Time dead** is tracked separately, and loading screens no longer count as
  playtime.
- **XP, gold and deaths** are tracked per level, and kills now count at max
  level too.
- **Redesigned window**:
  - Stat tiles and activity and location bars at the top.
  - Levels, Zones and Charts tabs. The Charts tab has seven chart types: time,
    location, pace, XP/hr, kills/hr, gold/hr and deaths.
  - A character selector that includes all your characters combined.
- **Settings page** under Options → AddOns, plus an addon-menu entry, a
  standard minimap button and CSV export (`/chrono export`).
- **EllesmereUI support**: the windows follow your EllesmereUI theme and
  accent color, and the settings also appear in EllesmereUI's options.

### Notes

- Kills are counted from the XP chat line (and from targeted kills at max
  level), because addons can't read the combat log on Forever.
- Pace needs at least one other character that has leveled with
  Chronolog-Forever.
- The heatmap only covers time played since this version, and dungeon time
  isn't mapped.
