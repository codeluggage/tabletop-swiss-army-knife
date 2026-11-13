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

## 4. Make your first change

Type this to Codex, with your own name for the app:

> Change the app's name from "Tabletop" to "My Name Here". Then check, test, commit and push.

Codex changes the files, runs the checks, and asks you before it pushes. After the push, GitHub checks and builds the site. You can watch it under "Actions" on the project's GitHub page. When the build is green, the app on your phone shows "New version - Reload".

## How it stays safe

- Every change runs the type check and the tests. A red build publishes nothing, so the live app keeps working.
- The project holds no game content: no rules text, stats, points or names. Your game data stays in your browser on your device. If you ask Codex to put game content into the code, it builds a screen where you add it yourself instead.
- If Codex shows an error, ask it to fix the error. If you are stuck, send Matias a message.
- If Codex says you reached a usage limit, wait and try again later.

## Good ways to ask

- Ask for one change at a time.
- Say what you see and what you want: "On the unit screen, the weapon table is too wide on my phone. Make it fit."
- Ask Codex to explain what it changed, in plain words.
