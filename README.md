# Quest Pin

A WoW Forever addon (interface 16001) that keeps Blizzard's quest tracker focused on where you are.

- **Zone quests are tracked automatically.** The tracker's "Quests" section becomes a section named after your zone, holding every quest whose objectives (or turn-in) are on this zone's map, or that the quest log files under this zone.
- **Pin quests to keep them tracked anywhere.** Outside their zone, pinned quests sit at the top in a **Pinned** section, with a pushpin after their title and a "Go to *Westfall* (from *Elwynn Forest*)" line. Inside their zone they move into the zone section and look like any other zone quest.
- Uses Blizzard's own tracker and quest log. The two sections are Blizzard's quest module with a filter, so clicking, right-click menus, POI buttons, quest items and super-tracking all work as usual.

## Pinning

| Where | How |
|---|---|
| Quest log | Tick the track box (outside the quest's zone, a pushpin replaces the box), or right-click > **Pin quest** |
| Tracker | Right-click a quest > **Pin quest** / **Unpin quest** |
| Chat | `/qpin <quest link or ID>` |

Unticking a quest (or **Stop tracking**) unpins it. For a zone quest, it also hides the quest until you leave the zone.

Hover a quest in the log to see where it goes and where it came from.

## Commands

`/qpin` (or `/questpin`) shows help and settings. Use `/qpin list` to list pinned quests and `/qpin clear` to unpin them all. These toggle a setting:

- `auto`: auto-track zone quests
- `objectives`: count a quest as "in the zone" if the map sends you here
- `logzone`: count it as "in the zone" if the quest log files it under this zone
- `location`: show where pinned quests go

## Where the location data comes from

- **Where it sends you:** `GetQuestUiMapID(questID)`, which the world map uses to open a quest. It falls back to `C_QuestLog.GetNextWaypoint`.
- **Where it came from:** the zone you were in when you accepted it, which is saved per character. For quests accepted before installing, it uses the quest log's zone header.

## Development

```bash
pip install lupa
python tests/run.py
```

This syntax-checks the Lua under 5.1 and checks widget methods against Forever's API docs (`tests/forever_widget_methods.txt`).
