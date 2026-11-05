# Chronolog-Forever

A lightweight playtime tracker for **WoW Forever** (the Midnight-based client). It records,
**per character level**, how you spend your time and how much you kill, then
shows it in a window with charts.

## What it tracks (per level, plus combined totals)

- **Combat** — time spent in combat.
- **Travel** — time spent actually moving: running on foot, riding a mount, using a
  travel form (Ghost Wolf, Travel/Aquatic/Flight Form), or on a taxi / flight path.
  Standing still (including sitting on a mount) does **not** count as travel (it counts as idle).
- **AFK** — time spent flagged away-from-keyboard.
- **Other** — all remaining active (logged-in, in-world) time.
- **Grouped** — time spent in a party or raid (tracked independently; you can be
  grouped *and* in combat, so this overlaps the four buckets above).
- **Mobs killed** — non-player units killed by you or your pet.
- **Quests** — quests turned in (hooks `GetQuestReward`).
- **Dungeons** — 5-man dungeons completed (see note below).

The first four are mutually exclusive: each second of online time is charged to
exactly one, by priority `Mounted/form/taxi travel > Combat > AFK > On-foot travel >
Other`, so they never double-count and always add up to that level's total
time. Mounted or flight-path travel outranks combat, so moving on a mount (or
on a flight path) while flagged in combat is counted as travel. On foot, combat
wins, so fighting while moving counts as combat. (While in combat the client
hides your speed, so only mounts and taxis can be detected as travel there.) Grouped time, kills, quests and dungeons are
separate counters.

Per-level values for grouped time, quests and dungeons show in each row's hover
tooltip; the table columns show kills and quests, and the header shows totals.

When a character has no saved data yet, Chronolog-Forever seeds one row for every level
from your **current level up to 60**. As you level up, new time and kills flow
into the new level's row automatically.

## Usage

- `/chrono` or `/chronolog` — open/close the main window (drag to move; its
  position is remembered between sessions).
- `/chrono widget` — toggle a small standalone box showing the **current level's**
  stats. Drag to move (position saved), right-click to hide, hover for a full
  breakdown. It remembers whether it was shown between sessions.
- `/chrono reset` — asks for confirmation; `/chrono reset yes` wipes all data
  and restarts tracking from your current level (widget position is kept).

Hover any level row for a full breakdown. Both views refresh live.

## Headline stats

- **Busiest level** — the level with the highest *proportion* of its time spent
  in combat (combat ÷ total).
- **Laziest level** — the highest proportion spent AFK or standing idle
  ((afk + idle) ÷ total), where "idle" means not fighting, not travelling, not
  AFK, and standing still (including sitting on a mount without moving).

Only levels with at least 60 seconds of tracked time qualify for these two, so
a level with a tiny sample can't show a misleading 100%.

## EllesmereUI theme

If [EllesmereUI](https://www.curseforge.com/wow/addons/ellesmereui) is loaded,
the main window and widget are skinned through its skinning API: window and
panel backdrop, close button, scrollbar, UI font and accent color all follow
your current EllesmereUI theme, including live changes. It can be turned off
per addon under EllesmereUI's *Blizzard Skins+ > Window Skins > Third-Party
Addons*. Without EllesmereUI the stock Blizzard look is used. The level
composition colors (combat/travel/AFK/other) are fixed on purpose.

## Notes

- Data is stored per character (`ChronologDB`).
- No external libraries. Targets the WoW Forever client (interface 16001). Safe to keep across launcher re-syncs
  since it is its own addon folder.
- Addons can't read the combat log on Forever, so kills are counted from the
  "<mob> dies, you gain N experience" chat line. Only XP-granting kills count
  (not grey mobs, and nothing at level 60), and kills by group members that
  award you XP are included. Install into
  `World of Warcraft/_forever_/Interface/AddOns/Chronolog-Forever`.
- Dungeon completion is credited when the Dungeon Finder fires
  `LFG_COMPLETION_REWARD`, or — for manual runs that don't use the finder — when
  you leave a 5-man instance after being inside at least 4 minutes. The two are
  de-duplicated so a single run counts once. It's a heuristic: a long partial
  run you abandon may count, and a sub-4-minute manual clear may not.
