# BuffMaster

A Lua script to make buffing other players painless. Listens for tells, casts a configured list of buffs on the requester, and automatically manages your spell gems.

## Features

- **Tell-driven buffing** — set a trigger word, and a configured allow list / group / raid / fellowship can request buffs via `/tell`.
- **Auto gem management** — the most-used buffs in your sets stay memmed permanently; less-used buffs swap into a scratch gem on demand. Usage counts persist across script restarts.
- **Spell and clicky support** — sets can mix memorized spells and clicky items. Pick up the clicky on your cursor and hit "Add from Cursor" in the Add/Edit Buff window — BuffMaster captures the item name and icon, then auto-inventories the clicky.
- **Class presets** — one signature buff per caster class for Live, plus a minimal EQ Might EMU preset. Rescan after gaining levels to pick up upgrades.
- **Custom sets** — create your own sets with any combination of spells and clickies; reorder, toggle, copy, rename.
- **Stop anywhere** — `/buffmaster stop` halts mid-queue.

## Quick Start

```
/lua run buffmaster
```

The welcome window appears on first run. Set your trigger word and continue. Add buffs to a set (or use the class preset), enable tell access in Settings, and you're done.

## Commands

| Command | Description |
|---------|-------------|
| `/buffmaster buff <scope> [set]` | Buff someone. Scope: `self`, `target`, `group`, `raid`, or a player name |
| `/buffmaster stop` | Halt the current operation |
| `/buffmaster reset` | Resume after a halt |
| `/buffmaster show` / `hide` | Show or hide the UI |
| `/buffmaster tellaccess <mode>` | Set tell access (`disabled`/`anyone`/`group`/`raid`/`fellowship`/`allowlist`/`denylist`) |
| `/buffmaster help` | Print the command list |

## Tell Access

A requester sends a tell starting with your configured trigger word, optionally followed by a set name:

```
/tell YourName buff me
/tell YourName buff me MainGroup
```

Access modes mirror common patterns: open to anyone, restricted to your group/raid/fellowship, or explicit allow/deny lists.

## How Buffs Are Cast

BuffMaster targets the requester before each cast, regardless of whether the spell is single-target, group, or self-only. This means group/self spells will still resolve to your normal targeting rules (a self-only spell cast while targeting another player lands on you, by design).

If the requester is out of range or in a different zone, BuffMaster skips them and `/tells` them why. There is no auto-nav.

## Gem Strategy

At queue start, BuffMaster looks at all enabled spell entries across all your sets, sorts by cumulative cast count (persisted), and memorizes the top N spells in gems 1 through `NumGems - 1`. The last gem is a scratch slot for swap-ins.

Cast counts increment only on successful casts and persist in your settings file, so over time the set of "always memmed" buffs becomes your actual usage pattern.

## Acknowledgements

Structurally adapted from [Squire](https://github.com/AlgarDude/Squire) by Algar.
