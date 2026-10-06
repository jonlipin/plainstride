# Changelog

## 0.1.0 - 2026-10-06

- First version. Tauren Plainsrunning (+1% speed per 5 seconds of moving, up to 30 stacks) on a bar built from Blizzard's own art: the profession skill bar with an animated fill, one mark per stack and a pip on every fifth.
- The countdown to your next stack while you run, and to your next lost stack when you stop, on the game's own cast bar under the stack bar. Or, with One bar, inside the stack bar itself: the next segment fills while you run and your top segment drains red when you stop.
- Animated changes: gains ease in with the profession bar's flare, a lost stack fades, and a hit that knocks off several stacks leaves a red chunk that lingers and drains, shakes the bar, flashes the cast bar's interrupt glow and floats the number lost. Reaching 30 plays the bonus objective starburst and sheen.
- Wind streaks race through the filled part of the bar while you run, more and faster the more stacks you have.
- A red mark at half your stacks shows where one hit would leave you (players report a hit halves them), and a tooltip on hover gives your stacks, speed, the countdown and the rules.
- The bar hides in combat, where the game does not show the buff to addons, and comes back with your stacks when the fight ends.
- An options page at Esc > Options > AddOns > Plainstride and a minimap button: lock and move, size, opacity at 0 stacks or fade out entirely, background opacity, count and countdown text, one bar or two, 13 profession fills to choose from, wind streaks and their direction, the hit mark, the tooltip, docking under the player frame, hiding in combat, a 40 second demo and a log of recent stack changes (`/plainstride log`).
