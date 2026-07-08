# appstore

A private app store. A static page on GitHub Pages lists apps; the APKs
themselves are GitHub Release assets. No server, no backend, no auth.

Unlisted, not secret: anyone with the URL can install. That was the deliberate
choice — friends need to be able to use it without accounts.

## Publishing a new app or version

```powershell
cd C:\Dev\appstore
.\publish.ps1 -Name "Today" `
              -Apk "C:\Dev\Notes App\android\app\build\outputs\apk\release\app-release.apk" `
              -Version 1.0.0 `
              -Tagline "A todo list that forgets yesterday."
```

That uploads the APK to a release tagged `today-v1.0.0`, rewrites `apps.json`,
and pushes. The store updates within a minute.

Re-running with the same `-Name` replaces that app's entry in the manifest, so
only the newest version is ever listed. Older releases stay on GitHub but drop
off the page. Re-running with a `-Version` that already has a release fails
loudly rather than clobbering a build people may have installed.

## Signing

Android will refuse to install an update whose signing key differs from the
installed version — the user has to uninstall first and loses their data. So:

- Debug APKs are signed with `~/.android/debug.keystore`, which is per-machine.
  Fine for yourself, fragile for anything you hand to other people.
- Before sharing an app more than once, generate a real keystore, back it up
  somewhere you won't lose it, and sign every subsequent release with it. Losing
  that keystore means every user must uninstall and reinstall.

## Layout

| File | Purpose |
|---|---|
| `index.html` | The storefront. Fetches `apps.json`, renders it. Self-contained. |
| `apps.json` | Generated manifest — `owner`, `repo`, and one entry per app. |
| `publish.ps1` | Build → upload → update manifest → push. |
