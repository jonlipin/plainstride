# Plainstride

Tauren Plainsrunning for WoW Forever, drawn with Blizzard's own interface art.

Plainsrunning gives +1% movement speed for every 5 seconds you keep moving, up to 30 stacks.
Standing still or taking damage takes stacks away. Plainstride shows all of it:

- **Stack bar.** The profession skill bar with the animated Herbalism fill, one tick per stack and
  a pip on every fifth. Gains ease in with the profession bar's flare. Reaching 30 plays the
  bonus objective starburst and sheen.
- **Tick bar.** The game's own cast bar. While you move it fills (green, like a channel) toward
  your next stack. When you stop it drains (gold, turning red at the end) toward the next stack
  you lose.
- **Losses.** A stack that decays fades out of the bar. A hit that knocks off several stacks
  leaves a red cracked chunk that lingers and drains away, shakes the bar, flashes the cast bar's
  interrupt glow and floats the number lost.
- **Wind.** While you run, wind streaks race through the filled part of the bar: more of them,
  and faster, the more stacks you have.

## Where the numbers come from

Out of combat the buff is read directly. In a fight the client hides buffs from addons, so the
stack count is worked out from your run speed, which moves with the stacks; it is calibrated
against the buff whenever both can be read. If neither can be read (mounted, or where the client
hides your stats), the count carries on as an estimate and is marked with `~`.

The timers follow the game: stacks change on the racial's one second beat, which Plainstride
learns from the changes it sees.

## Options

Options > AddOns > Plainstride (from the game menu), the minimap button (left-click: options,
right-click: lock or unlock the bar, drag: move it round the minimap), or `/plainstride`.

- Lock the bar (untick to drag it anywhere)
- Size and opacity at 0 stacks
- Countdown text on the cast bar
- Minimap button
- Play the demo (40 seconds, any character), reset position and size

Commands: `/plainstride lock | unlock | scale 0.4-2 | idle 0-1 | timer | minimap | demo | reset | debug`.
`/pstride` works too.
