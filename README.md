# Chronolog-Forever

A playtime tracker for **WoW Forever** (the Midnight-based client) that shows
**how you actually spend your time while leveling**: not just how long each
level took, but what you were doing, where you were, how fast you're going
compared with your other characters, and when you'll hit the next level.

## What it tracks (per level, plus combined totals)

Five **mutually exclusive activity buckets** that always add up to the level's
total time:

- **Combat**: time spent in combat.
- **Travel**: time spent actually moving: running on foot, riding a mount, using
  a travel form (Ghost Wolf, Travel/Aquatic/Flight Form), on a taxi / flight
  path, or riding a **boat or zeppelin**. These are detected when your own speed
  is 0 but your map position keeps moving. Standing still (including sitting on
  a mount) is **not** travel; it counts as idle.
- **AFK**: time spent flagged away-from-keyboard.
- **Dead**: time spent dead or running back as a ghost.
- **Other**: all remaining active time ("idle" is the part of it spent standing
  still).

Each second is charged to exactly one bucket, by priority
`Dead > Mounted/form/taxi travel > Combat > AFK > On-foot travel > Other`.
Mounted or flight-path travel outranks combat; on foot, combat wins. While in
combat the client hides your speed, so only mounts, travel forms and taxis can
be detected as travel there.

**Where** you spent it (also adds up to the total): **open world**, **town**
(rested areas), **dungeons/raids**, and **PvP** (battlegrounds/arenas).

Separate counters (these can overlap the buckets):

- **Grouped**: time in a party or raid.
- **Professions window open**: time the professions window is open (crafting).
  Gathering is not detected.
- **Loading screens**: time spent loading. This is **not** part of the total.
- **Mobs killed**, **Quests** turned in, **Dungeons** completed (see notes),
  **Deaths**, **XP gained**, **Gold gained / spent**.
- **Zones and subzones**: seconds spent in each zone, and in each subzone
  within it (hover a zone on the Zones tab).
- **Position heatmap data**: once a second, your position on the zone map is
  added to a 100 x 100 grid (time, combat time and level range per cell; AFK
  time isn't mapped). A world-map heatmap overlay that uses it is coming. Cave
  and building maps are folded into their zone. Positions inside instances
  aren't available to addons, so dungeon time isn't mapped. A full 1-60
  character adds roughly 100-300 KB of saved data; `/chrono debug` shows the
  current size.

**Time from before you installed it:** at login Chronolog-Forever reads
`/played`, which tells it how long you've already been at your current level,
so the level you install on isn't cut short. (Levels before that aren't
available from the game.) The `/played` chat lines are hidden for this request.
Turn it off in the settings if you prefer.

## If the game crashes

WoW only writes addon data to disk on logout, `/reload` or a normal exit, so a
crash loses whatever was tracked since then. Chronolog-Forever limits the
damage. Each time it saves, it notes the game's own counters, which survive a
crash: `/played`, level, XP, gold, and your kill/quest/death statistics. At the
next login it compares them with the live values and puts back what the unsaved
session did:

- **Time** comes back as **Not recorded** (the game can't say what you were
  doing).
- **XP, gold, kills, quests and deaths** come back on the right level.
- If you levelled during that session, its time is split across those levels
  by XP. Those levels are marked *estimated* and left out of pace comparisons.

A short chat note tells you what was recovered. `/reload` is a quick manual
save and doesn't reset your ETA. There's also an optional "offer to save after
each level-up" setting.

## Pace and ETA

- **Pace**: every level you finish is compared with your **best splits**, the
  fastest time any of your other characters took for that level (or with one
  character you pick). You see the difference per level and as a running total:
  green when you're ahead, red when you're behind. Switch the reference with
  `/chrono pace`, the settings, or the button on the Pace chart.
- **Next level ETA**: time to the next level at your XP rate over your last
  30 minutes of play (AFK excluded), plus an estimate for reaching 60. The XP
  needed for future levels is learned as your characters level; until a
  character has reached a level, its XP is estimated (shown with `~`).

## The window (`/chrono`)

- **Character selector** (top right): this character, your other characters,
  or **All characters** combined. Other characters appear after you've logged
  them in once with this addon.
- **Stat tiles**: time played, kills, quests, deaths, XP/hour, gold/hour, next
  level ETA and pace. Hover any tile for details.
- **Activity** and **Location** bars for the whole view.
- **Levels tab**: a row per level with its activity bar, kills, quests, time,
  and pace against your reference. Hover a row for the full breakdown,
  a comparison against your average level, and that level's top zones.
- **Zones tab**: time per zone, biggest first.
- **Charts tab** (one column per level, with gridlines and axis):
  - **Time**: stacked by activity.
  - **Where**: share of each level in the world, in town, in dungeons, or in PvP.
  - **Pace**: faster/slower per level plus a running-total line.
  - **XP/hr**, **Kills/hr**, **Gold/hr**: with your average as a dashed line.
  - **Deaths**: per level.

**Busiest level** is the level with the highest share of its time in combat;
**laziest** has the highest share AFK or idle. Only levels with at least 60
seconds of tracked time qualify for these and for per-hour rates.

## Commands

| Command | What it does |
|---|---|
| `/chrono` | Open/close the main window (drag to move; position is remembered). |
| `/chrono widget` | Toggle the small current-level widget (drag to move, right-click to hide). |
| `/chrono widget scale <0.5-2>` | Widget size. |
| `/chrono widget alpha <0.2-1>` | Widget opacity. |
| `/chrono widget stat <name>` | Toggle a widget stat: `kills quests dungeons grouped deaths kph xph gph crafting dead eta pace`. |
| `/chrono pace` | Change the pace reference (best splits, or one of your characters). |
| `/chrono minimap` | Show/hide the minimap button (left-click: window, right-click: widget). |
| `/chrono export` | Copy your data as CSV (per level, and per level and zone). |
| `/chrono options` | Open the settings. |
| `/chrono debug` | Print tracking diagnostics (form ID, speed, mounted state, last XP line, ...). |
| `/chrono reset` | Asks for confirmation; `/chrono reset yes` wipes this character's data (settings are kept). |

## Settings, minimap and addon menu

- **Options → AddOns → Chronolog-Forever** has every setting: minimap button,
  `/played` backfill, pace reference, and the widget (scale, opacity, stats).
- The addon also appears in the **addon menu** next to the minimap.
- If LibDBIcon is loaded (most UI packs include it), the minimap button is a
  standard LibDBIcon button, so minimap-button collectors handle it. A
  LibDataBroker launcher is registered for broker displays too.

## EllesmereUI integration

If [EllesmereUI](https://www.curseforge.com/wow/addons/ellesmereui) is loaded:

- The windows and widget are skinned through its skinning API (backdrop,
  buttons, close button, scrollbar, UI font, accent color), including live theme
  changes. This can be turned off per addon under *Blizzard Skins+ > Window
  Skins > Third-Party Addons*. The bucket colors are fixed on purpose.
- A **Chronolog-Forever** section appears in EllesmereUI's options too, and
  `/chrono options` opens that one.

## Notes

- Install into `World of Warcraft/_forever_/Interface/AddOns/Chronolog-Forever`.
  Targets the WoW Forever client (interface 16001).
- Data is stored per character (`ChronologForeverDB`), and mirrored into an
  account-wide `ChronologAccountDB` for the character selector and pace. Data
  saved by earlier versions (`ChronologDB`) is migrated automatically.
- Location data starts with v1.2; levels recorded before that show it as
  "not recorded".
- **Kill counting.** Addons can't read the combat log on Forever, so:
  below level 60 a kill is counted from the "<mob> dies, you gain N experience"
  chat line (grey mobs give no XP and aren't counted; kills by group members
  that give you XP are); at level 60, where there is no XP, a **targeted**
  hostile that dies after you saw it in combat is counted (area kills of mobs
  you never target are missed).
- **Dungeons** are credited when the Dungeon Finder fires
  `LFG_COMPLETION_REWARD`, or, for manual runs, when you leave a 5-man instance
  after at least 4 minutes inside. The two are de-duplicated. It's a heuristic.
- Some client values are hidden ("secret") during combat; Chronolog-Forever
  treats those as unknown instead of erroring.

## Development

`tests/` has a headless test harness (see `tests/README.md`), and
`.github/RELEASING.md` covers tagging releases and the CurseForge upload.
