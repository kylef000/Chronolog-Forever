# Chronolog-Forever

A lightweight playtime tracker for **WoW Forever** (the Midnight-based client).
It records, **per character level**, how you spend your time and what you
earn, then shows it in a window with a level list, a zone breakdown and charts.

## What it tracks (per level, plus combined totals)

Five **mutually exclusive time buckets** that always add up to the level's
total time:

- **Combat** — time spent in combat.
- **Travel** — time spent actually moving: running on foot, riding a mount, using
  a travel form (Ghost Wolf, Travel/Aquatic/Flight Form), or on a taxi / flight
  path. Standing still (including sitting on a mount) is **not** travel; it
  counts as idle.
- **AFK** — time spent flagged away-from-keyboard.
- **Dead** — time spent dead or running back as a ghost.
- **Other** — all remaining active time ("idle" is the part of it spent standing
  still).

Each second is charged to exactly one bucket, by priority
`Dead > Mounted/form/taxi travel > Combat > AFK > On-foot travel > Other`.
Mounted or flight-path travel outranks combat; on foot, combat wins. While in
combat the client hides your speed, so only mounts, travel forms and taxis can
be detected as travel there.

Separate counters (these can overlap the buckets):

- **Grouped** — time in a party or raid.
- **Professions window open** — time the professions window is open (crafting).
  Gathering is not detected.
- **Loading screens** — time spent loading. This is **not** part of the total.
- **Mobs killed**, **Quests** turned in, **Dungeons** completed (see notes),
  **Deaths**, **XP gained**, **Gold gained / spent**.
- **Zones** — seconds spent in each zone.

When a character has no saved data yet, Chronolog-Forever seeds one row for every
level from your **current level up to 60** (Forever's level cap).

## The window (`/chrono`)

- **Character selector** (top left): switch between this character, your other
  characters, and **All characters** combined. Other characters appear after you
  have logged them in once with this addon.
- **Headline stats**: time per bucket, kills/quests/dungeons/deaths, grouped and
  crafting time, XP and gold with per-hour rates, and your busiest/laziest level.
- **Levels tab**: a row per level with its composition bar. Hover a row for the
  full breakdown, a comparison against your average level (combat share,
  kills/hr, XP/hr, gold/hr) and that level's top zones.
- **Zones tab**: time per zone, biggest first.
- **Charts tab**: one bar per level for a metric you cycle with the button
  (time played, combat %, travel %, kills, kills/hr, XP/hr, gold/hr, deaths).

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
| `/chrono widget stat <name>` | Toggle a widget stat: `kills quests dungeons grouped deaths kph xph gph crafting dead`. |
| `/chrono minimap` | Show/hide the minimap button (left-click: window, right-click: widget, drag to move). |
| `/chrono export` | Copy your data as CSV (per level, and per level and zone). |
| `/chrono options` | Open the settings page in EllesmereUI (if installed). |
| `/chrono debug` | Print tracking diagnostics (form ID, speed, mounted state, last XP line, ...). |
| `/chrono reset` | Asks for confirmation; `/chrono reset yes` wipes this character's data (settings are kept). |

A LibDataBroker launcher is also registered when LibDataBroker is available.

## EllesmereUI integration

If [EllesmereUI](https://www.curseforge.com/wow/addons/ellesmereui) is loaded:

- The windows and widget are skinned through its skinning API (backdrop,
  buttons, close button, scrollbar, UI font, accent color), including live theme
  changes. This can be turned off per addon under *Blizzard Skins+ > Window
  Skins > Third-Party Addons*. The bucket colors are fixed on purpose.
- A **Chronolog-Forever** section appears in EllesmereUI's options with the
  widget settings (show, scale, opacity, which stats) and general options.

Without EllesmereUI the stock Blizzard look is used and everything is available
through the slash commands.

## Notes

- Install into `World of Warcraft/_forever_/Interface/AddOns/Chronolog-Forever`.
  Targets the WoW Forever client (interface 16001).
- Data is stored per character (`ChronologForeverDB`), and mirrored into an
  account-wide `ChronologAccountDB` for the character selector. Data saved by
  earlier versions (`ChronologDB`) is migrated automatically on first login.
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
