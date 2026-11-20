---
name: wrap-up
description: End a thread well. Use when the person says "wrap up", "let's stop" or "I'm done for now", or says yes to your offer of a wrap-up. Lists what was left unsaid in this thread as numbered points, then brings handoff.md up to date for the next thread.
---

# Wrap up

Each reply sends the whole thread to the model again, so a long thread uses up the person's plan. A wrap-up ends this thread and leaves a numbered list on disk, so the next thread starts small and knows where to go on.

1. Write from what this thread already holds. Read `handoff.md` for its points and its `Last number used`. Read no other file and run no command to build the list.
2. Find what was left unsaid in this thread. Put first anything you told the person earlier in this thread that is wrong now. Then look for:
   - something you assumed and did not check,
   - a step you skipped, or a check that did not run,
   - something that may look wrong in the app,
   - a request you did only in part,
   - something you noticed and did not mention,
   - what you would do differently now.

   Skip what is empty.
3. Give each point the next free number, by the rules in `.agents/skills/handoff/SKILL.md`. Write each as `#8 text` in one or two plain sentences.
4. Then follow the handoff skill in `.agents/skills/handoff/SKILL.md`. The points from step 3 go into `handoff.md` under "Open" with the same numbers, in the order to do them, together with the points that were already there.
5. Write your reply in this order:
   - Anything you told the person earlier in this thread that is wrong now, one plain sentence each.
   - The line "What is open, in the order to do it. The points marked (new) are what I left unsaid:". When step 2 found nothing, the line "Nothing left unsaid. What is open, in the order to do it:".
   - The points under "Open", copied from `handoff.md`: the same order, the same numbers, the same words. Add "(new)" to the end of each point from step 3.
   - The last sentences that the handoff skill asks for.
