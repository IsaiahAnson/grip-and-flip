# Grip & Flip

**3-axis rotation for held objects in Grain Rot.**

The base game only lets you rotate grabbed loot and furniture around the vertical
axis (Q/E). Grip & Flip adds full pitch and roll — tumble that armchair, hang that
painting sideways, stack crates at whatever angle you want.

## Controls (while holding an object)

| Input | Action |
|---|---|
| **Hold Left Alt + move mouse** | Rotate freely (horizontal = spin, vertical = tumble). Camera stays put while Alt is held. |
| **Arrow keys** | Hold for smooth rotation, tap for a small nudge |
| **Numpad 8 / 2 / 4 / 6** | Precise 15° steps (pitch / roll) |
| **Numpad 5** | Reset to vanilla upright |
| **Q / E** | Native yaw (untouched) |

Releasing or re-grabbing an object cleanly returns it to vanilla behavior.

## Requirements

- **Grain Rot** (Steam, UE 5.7)
- **UE4SS experimental** — grab `UE4SS_v3.0.1-*.zip` from the
  [RE-UE4SS experimental release](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest)
  (builds from Aug 2026 or newer)

## Installation

1. Install UE4SS: extract the UE4SS zip into
   `Steam\steamapps\common\Grain Rot\Helden\Binaries\Win64\`
   (so `dwmapi.dll` sits next to `Helden-Win64-Shipping.exe`).
2. Copy this repo's `UE4SS_Signatures` folder into the `Win64\ue4ss\` folder.
   **This step is required** — stock UE4SS cannot find three engine functions in
   Grain Rot's UE 5.7 build and will fail to start without these signatures.
3. Copy this repo's `Mods\GripAndFlip` folder into `Win64\ue4ss\Mods\`.
   The included `enabled.txt` activates the mod — no `mods.txt` editing needed.
4. Launch the game. You should see `[GripAndFlip] v17 loaded` in the UE4SS console/log.

## Multiplayer

- Friends **do not** need the mod to play with you — nothing in the game files is
  modified, so modded and unmodded players join each other freely.
- **Rotation only works when you are the HOST** (or in singleplayer). The host's
  machine owns held-object physics; as a joining client your rotation would just
  fight the server's corrections, so the mod detects this and disables itself
  with a console message. If everyone in your group wants to grip and flip,
  take turns hosting.
- While you carry a tilted item, other players see it upright (the game replicates
  held rotation yaw-only). The moment you drop or place it, everyone sees the true
  orientation.

## How it works (for the curious)

Grain Rot's grab system rewrites the held object's physics-handle target rotation
as yaw-only every frame (that's the auto-upright behavior). Grip & Flip keeps a
pitch/roll offset and re-composes it onto that target every frame from a hook on
the player's animation update — after the game's write, before physics — so the
game's own physics driver does all the actual movement. Held-key and Alt state
come from a tiny background PowerShell poller (`keypoll.ps1`) because querying key
state through the engine's scripting bridge is fatally crash-prone on this
UE4SS/UE 5.7 combination. The poller starts with the mod and exits with the game.

## Troubleshooting

- **UE4SS says "PS scan timed out" / game runs unmodded** — you skipped step 2
  (the `UE4SS_Signatures` folder). A game update can also invalidate these
  signatures; check this repo for updates.
- **Taps rotate but holding/Alt does nothing** — the key poller didn't start.
  Check the UE4SS log for a `keypoll` warning line.
- **`hook registration failed` in the log at startup** — harmless; the hook
  registers automatically once you're in a level.

## Credits

- UE 5.7 AOB signatures adapted from
  [UE4SS-RE/RE-UE4SS#1228](https://github.com/UE4SS-RE/RE-UE4SS/issues/1228)
  (posted by **aslavd**).
- Built with [RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS).
