# PetHealthWatch

A hunter pet health monitor. When your pet's health drops to a threshold you
choose, the screen flashes and a **Mend Pet** button appears. If your pet dies,
the button becomes **Revive Pet** and a sound of your choice plays.

Originally written for Turtle WoW; this version is ported to **Wow Forever**
(interface 16001). It does nothing on any class other than Hunter.

## Installation

Put the `PetHealthWatch` folder in your `Interface\AddOns\` directory. The
folder name must be exactly `PetHealthWatch` and contain:

- `PetHealthWatch.toc`
- `PetHealthWatch.lua`

Restart the game or type `/reload`. On load you should see a line in chat with
the version number.

## What it does

- **Low-health alert.** At or below your threshold, a soft colored flash pulses
  over the screen and a Mend Pet button appears. The flash keeps pulsing until
  the pet is healed above the threshold.
- **Mend Pet button.** Left-click to cast Mend Pet. The label shows what's
  going on: `HEAL PET`, `OUT OF RANGE`, your mana versus the cost, or a
  countdown while you channel.
- **Revive Pet.** When the pet is dead, the button switches to `REVIVE PET`.
  Revive Pet works from wherever the pet died, so there is no "call pet" step.
- **Death sound.** A sound plays when your pet dies. Choose from a built-in
  list, or enter any sound ID.
- **Moveable.** Drag the button anywhere. It remembers its position.
- **Threshold** as a percent of health (default 50) or as a raw HP value.

## Settings window

Type `/phw` (or `/phw config`) to open the settings window. It uses the game's
own window style (the same frame as the Options window), with a column for the
alert and a column for the death sound. Everything in it can also be set with
slash commands, and the two stay in sync.

**How is the alert measured?** Choose **Percent of max health** or **Raw HP**
(a fixed amount of health), then set **Alert at** with the arrows. Click an
arrow to change the value by one step; hold Shift while clicking for a bigger
step.

**How it looks.** **Flash intensity** from 0 to 100. 0 turns the screen flash
off.

**Click to cast with.** Pick one: No key, Shift, Ctrl or Alt (see "Phantom
clicks").

**Pet death sound.** Tick **Play a sound when my pet dies**, then choose one
sound from the list. Only one can be selected at a time. The "Now using" line
always shows the active sound. Clicking a sound selects it (and plays it so you
can hear your choice); each row also has a **Play** button to preview a sound
without choosing it.

**Custom ID.** To use a sound that isn't in the list, type its ID in the box
and press **Play** to hear it. When you like it, select the **Custom ID** radio
button (or press Enter in the box) to use it. The Custom ID radio button stays
selected while a custom sound is active, and clicking any sound in the list
switches back to the list. Typing a number without selecting Custom ID doesn't
change anything.

**Buttons along the bottom:** **Test alert** shows the alert so you can see it,
**Reset button position**, **Clear dead-pet memory**, **Reset defaults**
(restores the settings but leaves the button position and dead-pet memory
alone), and **Close**.

Drag the window by its background. Press Escape to close it.

The addon also has a page in the game's own options: **Esc > Options > AddOns >
PetHealthWatch**. It shows a short description and an **Open settings** button
that opens this window.

## Important: hidden pet health

Wow Forever hides a pet's *current* health from addons while still letting the
game draw things based on it. That has a few consequences:

- The alert is drawn by the game from a rule ("show at or below X%"). The
  addon never actually sees the health number.
- Because the addon can't see the moment health crosses the threshold, it
  **cannot play a sound at that moment** and it **cannot flash just once**. The
  flash pulses for as long as health is below the threshold. This is why there
  is a sound for your pet *dying* (which the game does report) but not for low
  health.
- While the pet is out, the Mend Pet button is always present on screen but
  completely transparent until the alert shows, so it can catch clicks. See
  "Phantom clicks" below.

## Choosing the death sound

Sounds are identified by **sound ID number**. Pick one in the settings window,
or use the commands:

```
/phw sounds              (list the built-in choices)
/phw death pick wolf     (use "Wolf Death"; partial names work)
/phw death pick 1462     (use any sound ID directly)
/phw death test          (play the current death sound)
/phw death on|off        (turn the death sound on or off)
```

If a name matches more than one sound (for example, `death`), the addon lists
the matches and asks you to be more specific.

Built-in choices:

| Name | Sound ID |
| --- | --- |
| Sartura - I Serve To The Last | 8648 |
| Sea Turtle Death | 1462 |
| Human Male Death | 2944 |
| Wolf Death | 394 |
| Dragon Whelp Death | 432 |
| Hydra Death | 449 |
| Swarm Guard Death | 8520 |

**Want a different sound?** Browse the sound library at
<https://www.wowhead.com/classic/sounds>, find one you like, and note its ID
number (it's the number in the page address, as in `.../sound=8648/...`). Enter
it in the custom ID box in the settings window, or use
`/phw death pick <number>`. You can test any ID first in game with
`/script PlaySound(<number>)`.

Developers: the list of named choices is the `PHW_SoundLibrary` table near the
top of `PetHealthWatch.lua`; add a line there to add a new named sound. (The
settings window shows every entry in the list.)

## Commands

Type `/phw help` in game for this list.

| Command | What it does |
| --- | --- |
| `/phw` or `/phw config` | Open the settings window |
| `/phw set #` | Set the alert threshold (percent or raw HP, depending on the mode) |
| `/phw toggle` | Switch the threshold between percent and raw HP |
| `/phw flash #` | Screen flash intensity, 0-100 (default 20; 0 turns the flash off) |
| `/phw clickmod none\|shift\|ctrl\|alt` | Key to hold while clicking the button |
| `/phw sounds` | List the built-in death sounds |
| `/phw death on\|off\|test\|pick <name\|id>` | Pet death sound |
| `/phw test` | Toggle the alert display for testing |
| `/phw clear` | Clear the "pet is dead" memory |
| `/phw reset` | Put the button back at its default position (not in combat) |
| `/phw debug` | Show diagnostic info (useful when reporting a problem) |

## Phantom clicks

Because the button is always on screen (invisible) while your pet is out, it can
catch a click in that spot, such as pressing the left and right mouse buttons
together to move forward. Things that help:

- The button only responds to the left mouse button, and casts on release.
- Out of combat, the addon ignores a click made while the right button is held.
  The game doesn't allow this check in combat.
- **Move the button** somewhere you don't normally click.
- **Require a key.** Setting "Click to cast with" to Shift (or Ctrl or Alt)
  hides the clickable part of the button unless that key is held, which removes
  the invisible click area entirely. The alert label then reads
  `HEAL PET [SHIFT]`. The button still responds to a plain click when the pet is
  dead, since it's clearly visible then.

## Notes

- Settings are saved account-wide.
- The "pet is dead" state is remembered between sessions. If a hunter with no
  pet ever shows `REVIVE PET`, use "Clear dead-pet memory" (or `/phw clear`).
- Mend Pet's mana cost is detected from your highest known rank.
- The death sound plays when the addon sees your pet go from alive to dead. If
  you log in while your pet is already dead, you may hear it once.

## Version history

- **1.14.0** Settings window rebuilt on the game's own window frame (marble background, gold border,
  title bar, bottom button bar), matching RangeHelper. Description text no longer collides with the
  next row, and the custom-sound hint no longer runs off the edge.
- **1.13.1** Removed the redundant Use button; the Custom ID radio button (or Enter) selects the custom sound.
- **1.13.0** Settings window restyled to match the game's own windows: radio buttons for
  every one-of-many choice, arrow steppers for numbers, and a bottom row of buttons.
  Added Reset defaults.
- **1.12.3** Added a page for the addon in the game's Options > AddOns tab.
- **1.12.2** The custom sound row now shows the same green bar as list sounds when it's the active one.
- **1.12.1** Fixed the custom sound ID box clearing itself before Play/Use; added a "Now using" line.
- **1.12.0** Settings window. Removed the low-health sound, which could not
  trigger while pet health is hidden.
- **1.11.0** Named sound library, pick by name or ID, `/phw sounds`.
- **1.10.0** Death sound.
- **1.9.x** Removed the "flash once" experiment; plain continuous flash.
- **1.7-1.8** Click modifier option; detector experiments (removed).
- **1.6** Hunter-only; removed the "call dead pet" step; left-button-only clicks.
- **1.5** Support for hidden (secret) pet health using game-drawn alerts.
- **1.4** Port to Wow Forever: secure Mend/Revive button and updated API calls.
- **1.3.1** Last Turtle WoW version.
