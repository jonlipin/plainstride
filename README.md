# Plainstride

Tauren Plainsrunning for WoW Forever, drawn with Blizzard's own interface art.

Plainsrunning gives +1% movement speed for every 5 seconds you keep moving, up to 30 stacks.
Standing still or taking damage takes stacks away. Plainstride shows all of it:

- **Stack bar.** The profession skill bar with the animated Herbalism fill, one tick per stack and
  a pip on every fifth. Gains ease in with the profession bar's flare. Reaching 30 plays the
  bonus objective starburst and sheen.
- **Gain bar.** The game's own cast bar, in five parts: each check you pass fills one, and the
  fifth brings the next stack. It keeps its progress through short stops and starts again on a
  loss.
- **Loss bar.** A second cast bar under it, shown only while a loss is coming: gold while you
  stand (the next check would catch you), red once a check has, counting down to the tick the
  stack goes on, even if you step in between. Its room is kept, so nothing jumps.
- **Losses.** A stack that decays fades out of the bar. A hit that knocks off several stacks
  leaves a red cracked chunk that lingers and drains away, shakes the bar, flashes the cast bar's
  interrupt glow and floats the number lost.
- **Wind.** While you run, wind streaks race through the filled part of the bar: more of them,
  and faster, the more stacks you have.

## Where the numbers come from

The buff is read directly. In combat the game hides it from addons and nothing else follows the
stacks, so the bar hides when a fight starts and comes back with your stacks when it ends.

The timers follow the game: stacks change on the racial's one second beat, which Plainstride
learns from the changes it sees. Just after each beat the game checks you once. Standing at that
check costs a stack on the next beat, even if you step in between, so the bar keeps counting down
to that loss after you move again. Every other check counts toward the next stack; five give
one. A "~" in front of a time means the beat has not been seen yet, or the last prediction missed.

## Options

Options > AddOns > Plainstride (from the game menu), the minimap button (left-click: options,
right-click: lock or unlock the bar, drag: move it round the minimap), or `/plainstride`.

- Lock the bar (untick to drag it anywhere)
- Size and opacity at 0 stacks
- Background opacity (the empty part of the bars)
- Stack count text ("Plainsrunning 12 / 30")
- Countdown text
- Fade out at 0 stacks (back as soon as you move)
- One bar: the countdowns run inside the stack bar (the next segment fills toward the next stack,
  and a coming loss is a red overlay draining over your top stack) instead of on cast bars under it
- Show the loss bar (on by default)
- Minimap button
- Look: the window style, Automatic, Blizzard or Dark (`/plainstride style`), and the Dark
  background opacity. In Dark and EllesmereUI the bar gets a dark track with a thin edge instead of
  the profession frame, and keeps its animated fill
- Bar texture: any of the profession bars' animated fills (Herbalism, Skinning, Leatherworking,
  Mining, Blacksmithing, Engineering, Alchemy, Enchanting, Tailoring, Inscription, Jewelcrafting,
  Cooking, Fishing)
- Flat bars: one plain color per state instead of the profession and cast bar art, in any window
  style (off by default)
- Tooltip on hover: stacks, speed, the countdown and the rules
- A red mark where one hit would leave you (players report a hit halves your stacks)
- Dock under the player frame (EllesmereUI's while it is shown)
- Wind streaks on or off, and their direction: right (toward the next stack, the default) or left
  (rushing past you)
- Hide in combat (on by default; off keeps the bar up, frozen at your last count)
- Print recent stack changes (`/plainstride log`), with each hit compared to half
- Play the demo (40 seconds, any character), reset position and size

Commands: `/plainstride lock | unlock | scale 0.4-2 | idle 0-1 | background 0-1 | count | timer | fade | fill [name] | flat | combat | streaks [left|right] | marker | tooltip | dock | log [N] | layout | lossbar | style [auto|blizzard|dark] | minimap | demo | reset | debug`.
`/pstride` works too.
