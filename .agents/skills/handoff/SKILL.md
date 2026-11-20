---
name: handoff
description: Bring handoff.md up to date. It is the numbered list of open points that every new thread reads first. Use when the person says "hand off", "new thread" or "start fresh", and as the last step of a wrap-up.
---

# Hand off

`handoff.md` is the list this project keeps between threads. It stays on disk, and every new thread reads it first. Each point in it has a number, so the person can say "do 4" or "drop 6" in any thread. Git ignores the file, so do not commit it.

## The numbers

- A point keeps its number for as long as it exists. Never change a number.
- A new point gets the number after `Last number used`. Then raise `Last number used`. A number is never used twice, also after its point is gone.
- Write a point as `- #4 text`, in the file and in every reply. Never write the points as a numbered list (`4.`): the app that shows your reply would count them again from the first one.

## Bring the file up to date

1. Read `handoff.md` if it exists. Keep its points and their numbers. If its points have no numbers yet, number what is still open in it from 1.
2. Write the file again in this shape. Keep it under 40 lines.

   ```markdown
   # Between threads

   Updated: 2026-11-20. Live version: 2026.11.20.1542. Last number used: 7.

   ## Open, in the order to do them

   - #5 The table on the unit screen still scrolls sideways on a phone. Asked for, not started.
   - #3 Nobody looked at the dark colours after the theme change.
   - #7 The person's idea: sort the saved lists by date.

   ## Done, newest first

   - #6 Bigger buttons on the game screen. Live in 2026.11.20.1542.
   - #4 The home screen shows the newest game first. Live in 2026.11.19.2031.

   ## What the person decided

   - Keep the red theme.
   ```

   - The live version comes from publish in this thread, or from `gleam run -m tabletop/versions`.
   - **Open** holds every point that still needs something done, checked or decided. The first one is the next step. Write each point in one or two plain sentences that a thread which knows nothing else can act on: what, where in the app, and why it is open. Use the person's own words where you have them.
   - **Done** holds the five newest points that are done, each with the version it went live in. Remove older ones.
   - **What the person decided** holds what they chose, liked or did not like, when a later thread needs it. Keep it under 8 lines.
   - When the person says "drop 6", remove that point.
   - When the file does not fit in 40 lines, ask the person which open points to drop.
3. End your reply with the points under "Open", copied from the file: the same order, the same numbers, the same words. Then one sentence: the person can start a new thread now and say "continue", or name a number.
