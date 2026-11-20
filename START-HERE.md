# Start here: change the app with Codex on Windows

This guide is for changing Tabletop on a Windows 11 PC by talking to Codex in the ChatGPT app. You do not need to know how to program. Codex writes the code, and the project checks every change before it goes live.

## What you need

- A Windows 11 PC.
- A GitHub account with access to this project.
- The ChatGPT desktop app, signed in. Codex is inside it.

## 1. Install the tools, once

Open PowerShell: press the Windows key, type `PowerShell`, and press Enter. Paste these lines one at a time, and press Enter after each one:

```powershell
winget install --id Git.Git -e
winget install --id GitHub.cli -e
winget install --id Gleam.Gleam -e
winget install --id OpenJS.NodeJS.LTS -e
```

Close PowerShell and open it again, so it finds the new tools. Then sign in to GitHub:

```powershell
gh auth login
```

Choose `GitHub.com`, then `HTTPS`, then log in with a web browser.

Then tell Git who you are. Paste these two lines one at a time, with your own GitHub name in both:

```powershell
git config --global user.name "YOUR-GITHUB-NAME"
git config --global user.email "YOUR-GITHUB-NAME@users.noreply.github.com"
```

This address keeps your real email out of the public project.

## 2. Get the project

```powershell
gh repo clone codeluggage/tabletop-swiss-army-knife C:\src\tabletop
```

Keep the project in `C:\src\tabletop`. A folder that OneDrive syncs, such as Documents, can stop Codex from working.

## 3. Open it in Codex

1. Open the ChatGPT app and go to Codex.
2. Open the folder `C:\src\tabletop`.
3. Choose "Ask for approval". Codex then asks you before it runs a command or uses the internet.
4. When Codex asks if you trust this project, say yes.
5. Open "Review hooks" and trust the two hooks. They run the checks after each change.
6. Open Settings, then "Computer use", and turn off the switch named "Any App". With it on, Codex can take over your mouse and your screen while it checks its work. If you do not see that setting, skip this step.

## 4. Set up how Codex talks to you

Paste each of these two texts once.

For Codex: open Codex's Settings, go to Personalization, and paste this into your personal instructions:

> When I ask you to change one of my apps or websites, I mean: make the change and make it live at the usual address. Follow the project's own instructions for checks and publishing. Do any testing yourself, in the background: never take over my mouse, my keyboard or my own browser, because I use the computer while you work. When the change is live, tell me in plain words what changed, the version I should see, and where to look. If you need me to approve something or decide something, tell me exactly what to do. If I say "what do you think?" or "show me an idea", only talk.

For ChatGPT: in ChatGPT's settings, look for custom instructions, and paste this:

> I describe changes to my app in everyday words, and I usually try them on my phone. Help me say what I see, what I want to happen, and where to look for the result. Use plain language, and give me one next step when I need to do something.

## 5. Make your first change

Type this to Codex, with your own name for the app:

> Change the app's name from "Tabletop" to "My Name Here".

Codex makes the change and publishes it. This takes a few minutes. Its reply says which version is live, such as "Version 2026.11.13.1542 is live."

Open the app. If a bar says "New version", tap Reload. Check that the version at the top of the screen is the same.

## 6. Then undo it

Type this to Codex:

> Put the name back the way it was.

A new version comes, with the old name. Check it the same way.

## From your phone

You can write to Codex from the ChatGPT app on your phone. The PC must be on, awake and online, with the ChatGPT desktop app running.

Connect your phone once: in the ChatGPT desktop app, open Settings, then Connections, then "Control this Mac or PC", and follow the steps.

## Versions

The app shows its version at the top of every screen, such as 2026.11.13.1542. It is the date and time of the change, on the UK clock. You can name a version by its last four digits: "I'm on 1542 and the weapon table still scrolls sideways."

## How it stays safe

- Every change is checked before it goes live. A failed check publishes nothing, so the app keeps working.
- The project holds no game content: no rules text, stats, points or names. Your game data stays in your browser on your device. If you ask Codex to put game content into the code, it builds a screen where you add it yourself instead.
- Your lists, game data and cards live in the browser on your device, and a browser can clear them. The home screen has a "Backup" section: save a backup file now and then, and keep it somewhere safe. "Import a file" brings it back, on this device or another one.

## Good ways to ask

- Ask for one change at a time.
- Say what you see and what you want: "On the unit screen, the weapon table is too wide on my phone. Make it fit."
- Say which version you are on.
- "What do you think?" gets an answer and no change.
- When you finish one thing and start another, say "wrap up", then start a new thread in Codex. A long thread uses up your plan faster.
- A wrap-up ends with a numbered list of what is still open, such as #4 and #7. The list is saved on your PC, and every new thread reads it. In the new thread say "continue" for the first point, or name a number: "do 7". A point keeps its number until it is done. "Drop 4" removes a point. To save the list without the wrap-up, say "hand off".

## If something goes wrong

- If Codex shows an error, ask it to fix the error.
- If Codex says to ask the person who helps with the project, send Matias its last message.
- If Codex says you reached a usage limit, wait and try again later.
- If Codex takes over your mouse or your browser while you do something else: do step 6 of "Open it in Codex" above, and tell Codex once "your checks get in my way, stop using the browser". It saves that for every later thread.
