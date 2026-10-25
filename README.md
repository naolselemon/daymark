<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/readme/banner-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="assets/readme/banner-light.png">
    <img src="assets/readme/banner-light.png" alt="Daymark" width="360">
  </picture>
</p>

<p align="center"><strong>Plan a little. Make time. Keep what matters.</strong><br>A local-first planner, timer and diary for the native Omarchy shell.</p>

- **Plan & log:** Today, Plan and searchable History; optional pins and a 14-day entry calendar. Logging never implicitly completes an activity.
- **Focus:** a circular countdown, 5 / 15 / 30 / 60-minute presets, custom duration, pause/resume and a gentle completion chime that you can mute.
- **Reflect:** a system-password-locked Diary, plus a clean quote page behind the logo/name with 500 original offline reflections.

## Preview

<table>
  <tr>
    <td align="center"><a href="assets/readme/quotes.png"><img src="assets/readme/quotes.png" alt="Centered italic quotation" width="360"></a><br><strong>Quotes</strong></td>
    <td align="center"><a href="assets/readme/timer.png"><img src="assets/readme/timer.png" alt="Circular Timer and duration keypad" width="360"></a><br><strong>Timer</strong></td>
  </tr>
  <tr>
    <td align="center"><a href="assets/readme/today.png"><img src="assets/readme/today.png" alt="Today's plans, entries and calendar insights" width="360"></a><br><strong>Today</strong></td>
    <td align="center"><a href="assets/readme/plan.png"><img src="assets/readme/plan.png" alt="Plans grouped by date and Inbox" width="360"></a><br><strong>Plan</strong></td>
  </tr>
  <tr>
    <td align="center"><a href="assets/readme/history.png"><img src="assets/readme/history.png" alt="Activity History and separate insights" width="360"></a><br><strong>History</strong></td>
    <td align="center"><a href="assets/readme/diary.png"><img src="assets/readme/diary.png" alt="Diary page library and writing surface" width="360"></a><br><strong>Diary</strong></td>
  </tr>
</table>

Native Qt previews with **synthetic data**, not mockups or installed-shell screenshots. Click an image to enlarge.

## Install

```bash
omarchy plugin add https://github.com/naolselemon/daymark.git
```

Review the source and the CLI's trust/enable prompts: plugins run **unsandboxed inside your desktop shell**. Open Daymark from its ring icon in the bar. Hover or focus icons for their purpose; **Ctrl+/** shows shortcuts.

Requires the native Omarchy bar/service contract, Quickshell with PAM, Qt Quick/Controls/Dialogs and Python 3 with SQLite. Qt Multimedia is optional for the chime. Observed environment: Omarchy **4.0.5**, Quickshell **0.3.2.r7.g2b4501a**, Qt **6.12.0**, Python **3.14.8** on Linux x86-64—not a compatibility guarantee for other versions or replacement bars.

## Your data

- Records stay in `$XDG_DATA_HOME/daylog`, or `~/.local/share/daylog`. No accounts, telemetry or application monitoring.
- **Data & Safety** exports activities and diary separately. Activity exports exclude diary content; diary exports and all imports require a fresh system-password check. Export both scopes for a complete journal backup.
- **The Diary lock is an interface privacy boundary, not encryption.** SQLite files and JSON backups are plaintext; protect your account and backup files.
- Opening Quotes may contact the free, keyless [ZenQuotes API](https://docs.zenquotes.io/zenquotes-documentation/). No journal content is sent; the provider can see ordinary connection metadata such as your IP address. Cached quotes and 500 bundled originals keep the page useful offline.
- The countdown does not log or complete activities. After reboot it resumes only with your confirmation; it is not an alarm service while Daymark is disabled.

## Update or remove

**Save/discard drafts, wait for “Saved”, export both journal scopes and close Daymark first.** For a Git-managed installation, run these steps individually, stopping on failure:

```bash
omarchy plugin disable naolselemon.daymark
omarchy plugin update naolselemon.daymark
omarchy restart shell
omarchy plugin enable naolselemon.daymark
```

A shell restart affects the desktop and is needed to avoid stale QML on the observed runtime. Manual copies are not Git-managed; updating this checkout alone does not update an installed copy.

Remove installed code with `omarchy plugin remove naolselemon.daymark`. Updates, disabling and removal preserve the external data directory. **Never delete it as part of an update.**

<details>
<summary>Development and verification</summary>

```bash
PYTHONDONTWRITEBYTECODE=1 python -W error::ResourceWarning -m unittest discover -s tests -v
QT_QPA_PLATFORM=offscreen QML_DISABLE_DISK_CACHE=1 /usr/lib/qt6/bin/qmltestrunner -input tests
omarchy plugin validate .
python tools/preview.py --demo
```

The disposable preview additionally needs a C++ compiler, `pkg-config` and Qt development tools. It cannot load Quickshell's PAM module: Diary unlock, diary exports and imports remain locked; activity exports still work. Preview tests are not installed-PAM or lifecycle certification.

</details>

**[MIT](LICENSE)** · [Naol Selemon](https://github.com/naolselemon) · [Releases](https://github.com/naolselemon/daymark/releases)

The logo and bundled reflections are original Daymark work. Live quotations retain the linked ZenQuotes attribution; third-party quotations and Omarchy/Quickshell/Qt retain their own rights and licenses.
