# Quest Pin

A WoW Forever addon (interface 16001) that keeps Blizzard's quest tracker focused on where you are.

- **Zone quests are tracked automatically.** The tracker's "Quests" section becomes a section named after your zone, holding every quest whose objectives (or turn-in) are on this zone's map, or that the quest log files under this zone.
- **Pin quests to keep them tracked anywhere.** Pinned quests sit at the top in a **Pinned** section, even in their own zone, with a "Go to *Westfall* (from *Elwynn Forest*)" line. Each quest shows once: pinned quests in Pinned, other quests in your zone in the zone section.
- **Dungeons and raids count as a zone.** Inside one, the zone section is named after the instance and holds quests for any of its floors, or that the quest log files under it.
- **Flying doesn't reshuffle the tracker.** On a flight path or a flying mount, the tracker keeps the zone you took off from. It switches to the new zone once you land.
- Uses Blizzard's own tracker and quest log. The two sections are Blizzard's quest module with a filter, so clicking, right-click menus, POI buttons, quest items and super-tracking all work as usual.

## Pinning

| Where | How |
|---|---|
| Quest log | Click the track box, or right-click > **Pin quest** |
| Tracker | Right-click a quest > **Pin quest** / **Unpin quest** |
| Chat | `/qpin <quest link or ID>` |

In the quest log, a tick means **pinned**. Zone quests are tracked without a tick; ticking one moves it to the Pinned section, so it stays tracked when you leave. Unticking it puts it back in the zone section (or untracks it if it's not in your zone).

In the tracker, **Stop tracking** unpins a quest. For a zone quest, it also hides it until you leave the zone.

Hover a quest in the log to see where it goes and where it came from.

## Commands

`/qpin` (or `/questpin`) shows help and settings. Use `/qpin list` to list pinned quests and `/qpin clear` to unpin them all. These toggle a setting:

- `auto`: auto-track zone quests
- `objectives`: count a quest as "in the zone" if the map sends you here
- `logzone`: count it as "in the zone" if the quest log files it under this zone
- `location`: show where pinned quests go
- `flight`: keep the last zone's quests while flying, until you land

## Where the location data comes from

- **Where it sends you:** `GetQuestUiMapID(questID)`, which the world map uses to open a quest. It falls back to `C_QuestLog.GetNextWaypoint`.
- **Where it came from:** the zone you were in when you accepted it, which is saved per character. For quests accepted before installing, it uses the quest log's zone header.

## Development

```bash
pip install lupa
python tests/run.py
```

This syntax-checks the Lua under 5.1 and checks widget methods against Forever's API docs (`tests/forever_widget_methods.txt`).
