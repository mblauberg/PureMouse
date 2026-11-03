# 21. A daily update check in the menu bar app, after asking once

## Status

Accepted and built. The footprint rig ran the menu app's scenarios with automatic checks on and a
check run, and they stay within budget (`docs/companion.md`, Footprint). It changes the privacy promise "one request, only when you press Check for Updates"
([Privacy](../privacy.md)).

## Context

People forget to look for releases, and PureMouse is not yet distributed by anything that updates
it (the tap is #74, a signed installer #26). Sparkle's practice is to ask on a later launch, check
once a day and, for menu bar apps, remind gently instead of opening a window that takes focus.
The only network code was `UpdateCheck`, run when **Check for Updates** in Settings › About is
pressed. The daemon has none, and must not.

## Decision

- **Where.** The menu bar app runs the check (`UpdateReminders`, `BackgroundActivity`). It already
  owns notifications and is resident. Settings is not (it quits when its window closes), and
  `puremouse` and `PureMouseKit` stay free of network code (`nm` and `strings` on `puremouse` show
  no URLSession, CFNetwork or endpoint symbol that main's build lacks).
- **Ask once.** On the second launch with the icon shown, or a later one if the daemon is not
  running or a permission it needs is missing, an alert asks "Check for updates automatically?"
  (Check Automatically, Don't Check). The answer is stored and the question is never asked
  again. Settings › About has the same switch, so the answer can change; using the switch before
  the question answers it.
- **Schedule.** While the answer is yes: at most one request in 24 hours, counted from the last
  request whether it worked or not, kept across launches and wakes. The system schedules it
  (`NSBackgroundActivityScheduler`, one-shot, re-armed after each run; deferred while the Mac sleeps or
  is busy; its tolerance must be shorter than its interval or it raises, so a check already due
  waits 60 s with a 30 s tolerance). There is no timer of ours. A failure waits for the next window.
- **The request.** The same GET as the on-demand check, with `allowsConstrainedNetworkAccess` and
  `allowsExpensiveNetworkAccess` off, and `If-None-Match` with the ETag of the release on record.
  A 304 keeps that release.
- **Reminders.** A release newer than the running version posts one quiet notification per version
  (clicking it opens the release page), and the menu shows **Update to X.Y.Z…** and **Skip This
  Version** until the running version is at least X.Y.Z. Skipping hides both for that version only.
  Nothing is downloaded or installed, and no window takes focus (the question is the one alert).
- **Stored** in the menu app's preferences, listed in [Privacy](../privacy.md): the answer, launch
  count, last request, ETag, latest release, skipped version and notified version. Settings writes
  the answer there and the menu app hears it (key-value observing), as it hears the notification answer.
- **Once per run.** The question is considered once per run of the menu app: if the daemon is not
  running or a permission is missing then, the next launch asks, not a later moment of the same run.

## Alternatives rejected

- **A short-lived process for the request.** The issue allows it if the menu's budgets break. With a
  check run, the four menu scenarios rose 0.4 to 0.6 MB and stayed under their budgets (a 0.4 MB
  margin after 10 opens is the tightest), so the extra executable, its argument parsing and its result handoff are not built.
- **The Settings helper or the daemon.** Neither is resident; the daemon must stay network-free.
- **A repeating `Timer` or `DispatchSourceTimer`.** A resident wake-up of our own; the menu idles at zero.
- **A repeating `NSBackgroundActivityScheduler`.** Its first run is not anchored to the last request,
  so relaunches could check early; the 24-hour rule is checked against the stored time instead.
- **Asking on the first launch.** The first launch is spent on permissions.
- **A modal alert for a new release.** Takes focus; the notification and menu row do not.

## Consequences

- PureMouse makes its first unattended request. The privacy page, the About footnote and the README's
  network line say so; turning the switch off ends it.
- The user agent and IP address reach GitHub once a day; the ETag sent back is GitHub's own.
- A build whose version is not a release number (`dev`, the rig's) counts every release as newer,
  as the on-demand check does.
- Installing is still manual. Downloading and installing belong to the Developer ID work (#26).
