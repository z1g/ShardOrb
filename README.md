# ShardOrb

A small Warlock orb for **WoW Forever** (Interface 16001). Inspired by Necrosis, not a port of it: shard count, a few casts, a summon queue, and a couple of combat warnings. No timers, no reagent shopping list, no menus.

MIT-style. Do what you like with it.


![shardorb](https://github.com/z1g/ShardOrb/releases/download/v1.0.9/shardorb.png)
![shardorb](https://github.com/z1g/ShardOrb/releases/download/v1.0.9/shardorb2.png)

## Install

Copy the `ShardOrb` folder to:

`World of Warcraft/_forever_/Interface/AddOns/ShardOrb`

You should have:

```
ShardOrb/
  ShardOrb.toc
  ShardOrb.lua
  shadowtrance.ogg   (optional, Nightfall sound)
  README.md
```

A **new** addon or a new `.toc` needs a full client quit. Lua-only edits are `/reload`. A new sound file usually needs a full quit if you added it while the game was running.

## The orb

- Black disc with the soul shard count (item **6265**).
- Purple ring around that, **one chunk per shard** in your bags (caps at 40). Outer black rim around the purple.
- Drag to move. `/so lock` to freeze it, `/so unlock` to drag again, `/so reset` to recenter.

Orbit buttons (macros, highest rank by name):

| Button | Click |
| --- | --- |
| Create Healthstone | Create only (bind use yourself) |
| Create Soulstone | Create if you have no stone; `/use` on your **current target** if you do |
| Ritual of Summoning | Cast |
| Imp / Voidwalker / Succubus / Felhunter | Summon |

Soulstone create vs use is rewritten **out of combat** only. Forever will not change a secure button in a fight.

## Summon queue

Party / raid / instance chat, **exact** line (case-insensitive, Necrosis defaults):

`123` · `summon` · `inv` · `+1`

Must be a group member. You are not queued for typing it yourself.

Click a name: target them and start Ritual of Summoning. **x** drops one person, **Clear** empties the list.

When the ritual **starts**, you say in raid (or party):

`Summoning <name> to <zone>`

When it **finishes**, they leave the queue. Interrupt keeps them listed.

`/so queue` toggles the window. `/so queue clear` empties it.

## Alerts

**Fear** (red) — attackable NPC Undead or Mechanical, or a fear ward (Fear Ward, Berserker Rage, Divine Shield, etc.).

**Drain** (green) — Mechanical / golems. Drain Life and Siphon Life will not work.

**Banish** (blue) — attackable Demon or Elemental. Same `UnitCreatureType` check Necrosis used.

**Shadow Trance / Nightfall** (purple) — icon + `shadowtrance.ogg`. Forever blocks addons from reading your auras in combat (`Auras cannot be accessed when secret`), so the live proc is detected by **Shadow Bolt cast time going to 0**, not by scanning the buff list. The icon clears when the bolt is no longer instant.

Drag the icons. `/so alerts` toggles fear / drain / banish. `/so trance` toggles Nightfall.

## Slash

`/so` and `/shardorb` are the same.

| Command | What it does |
| --- | --- |
| `/so lock` / `unlock` / `reset` | Orb position |
| `/so queue` / `queue clear` | Summon list |
| `/so alerts` | Fear / drain / banish icons |
| `/so trance` | Nightfall alert |
| `/so trance test` | Force icon + sound (no real proc) |
| `/so auras` | Debug dump of player auras / SB cast time |
| `/so status` / `refresh` / `count` / `spells` | Debug |

## Forever notes

This client is not retail and not a private server UI dump. In particular:

- No addon combat log (`COMBAT_LOG_EVENT` is blocked).
- `Enum.BagIndex.ReagentBag` can be nil on a cold login; shard count does not depend on that.
- Secure `SetAttribute` after a button has been used can fail silently; soulstone and queue rows only change out of combat (or get new frames).
- `UnitName("player")` returns name **and** surname. Queue targeting uses the full name.
- `PlaySoundFile` on this client wants **`.ogg`**, not `.wav`.

## Not included

Full Necrosis: curse menus, timer bars, shard sorting, destroy-extra-shards, click-to-banish/enslave buttons, speech packs, Ace libraries.
