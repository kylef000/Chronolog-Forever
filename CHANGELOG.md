# Changelog

Each release's notes on GitHub (and CurseForge) are taken from its section
below. Add a `## vX.Y.Z - YYYY-MM-DD` section before tagging; the release
workflow refuses to publish a tag without one.

## v1.4.0 - 2026-11-25

The first release for **WoW Forever**. It replaces the old Ascension
Chronolog, and data saved by Chronolog is migrated automatically.

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
