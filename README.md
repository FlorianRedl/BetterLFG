# Better LFG

A cleaner Group Finder: see all groups and players at a glance, with more info and better filters.

Better LFG adds two tabs to the Group Finder (World of Warcraft Forever):

- **Find Groups** – all open dungeon groups with leader, average level, playstyle and roles; sorting; filters for dungeons, level, playstyle and role counts; a summary of solo players by role and class; one-click whisper to the leader.
- **Find Players** – all solo players with class, level, roles, dungeon and zone; filters for dungeons, roles, level and class; one-click invite.

**See other players' item levels** – the default Group Finder shows no item level at all. Better LFG shows the item level of every group member in the group tooltip, as long as they use Better LFG too (the addons exchange it automatically via hidden addon messages). The more people use it, the more item levels you see.

Also: your own item level with a per-slot breakdown that highlights weak items, a language filter, and greyed-out delisted entries.

Settings: *Options → AddOns → Better LFG*. Slash command: `/blfg`.

## Releasing

Push a tag (for example `v1.0.1`). The GitHub Action packages the addon with the
[BigWigs packager](https://github.com/BigWigsMods/packager), uploads it to CurseForge
and creates a GitHub release. The tag becomes the version in the `.toc`.
