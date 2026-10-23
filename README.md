# Daymark

**Plan a little. Record what happened. Keep what matters.**

Daymark is a local-first planner and journal for the native Omarchy shell. Plan activities, record untimed logs, write a daily diary, and keep important activities close—without accounts, telemetry or application monitoring.

**0.1.0 · `naolselemon.daymark` · [Naol Selemon](https://github.com/naolselemon) · [MIT](LICENSE)**

![Daymark Plan view with pinned activities, dated plans and 14-day activity insights; synthetic records only](preview.png)

The preview is a **1440×1000 native offscreen Qt window-content capture** of Plan, using synthetic records in a real isolated SQLite profile and the current 24-pixel checkbox indicators. It is not a mockup, an installed-shell screenshot, a physical-window-size certification or new evidence of PAM authentication.

## Everyday use

Click the notebook icon in the Omarchy bar to open or close Daymark. The native bar widget, panel and service share one workspace; Daymark does not start a second shell or add a global keyboard binding.

| View | What it does |
| --- | --- |
| **Today** | See your list and what happened on the selected date. Open Diary leads to today's page without showing diary text in Today. |
| **Plan** | Organize intentions into Today, Tomorrow, Other days and Inbox. Open a title to edit; use its checkbox to mark it done. |
| **History** | Search and browse activity entries, completions and recently deleted activity records. Diary text is excluded. |
| **Diary** | Unlock a dated writing page and a searchable, month-grouped page library. Compact windows use Pages / Back to writing. Diary has its own Recently deleted section. |

- **Plan an activity:** enter a title, date and optional note. No date means Inbox. After **Add plan** succeeds, the form keeps its date and focuses a fresh title; repeat, then choose **Done**. Plans do not automatically roll forward or complete.
- **Log activity:** record a dated entry with an optional note, either for a new activity or an existing one. Logging against an existing activity preserves its identity. Completion is a separate, explicit choice; there are no timers or duration fields.
- **Pin activity:** pin from an activity's detail for quick access in Today and Plan on every date. Pins do not change plan dates or create recurring copies. Completion keeps the pin; deletion hides it and Undo restores it.
- **Data & Safety:** use the header action to export the journal or import a backup.

Relative Today/Yesterday/Tomorrow labels follow the local calendar within one minute, including after sleep or clock adjustments. An open diary page, selected activity date and unsaved drafts stay on their original dates. Use **Ctrl+J** or the diary calendar's **Today** action to move to today's page explicitly. An unchanged date does not poll the storage helper.

### Insights, not scores

Today, Plan and History show entries on each of the **last 14 days**, days with entries, current open/done activity counts and up to five recently logged activities. Open an activity for its total entries, days logged, last entry and 14-day pattern. Insights sit beside the content on wide windows and below it on compact windows.

These are entry counts, not time estimates or productivity scores. The inclusive window ends today, independent of History search/paging or the selected Today date. Deleted records are excluded; saved corrections and Undo update counts. Historical multi-day sessions count once on their recorded date. Future entries remain in all-time totals but enter the recent window only when their dates arrive.

### Keyboard shortcuts

| Keys | Action |
| --- | --- |
| Ctrl+1 / Ctrl+2 / Ctrl+3 / Ctrl+4 | Today / Plan / History / Diary |
| Ctrl+N | Plan an activity |
| Ctrl+L | Log the open activity, or start a new log |
| Ctrl+J | Write today's diary |
| Ctrl+Shift+J | Browse diary pages |
| Ctrl+Shift+L | Lock the diary |
| Ctrl+F | Search Diary while there; otherwise search activity History |
| Ctrl+S | Save the form or flush the diary |
| Ctrl+Enter | Add a plan or save a form |
| Ctrl+, | Open Data & Safety |
| Ctrl+/ | Show the full shortcut reference |

In the plan form, **Enter** advances title → date → optional note → Add plan, then adds the plan. **Space** opens the focused date's calendar; **Shift+Enter** inserts a note newline. Only a successful save clears title/note. Logging retains its save-and-close behavior.

Tab/Shift+Tab reveal focused controls; Space activates buttons and checkboxes. Escape closes the nearest popup; changed forms offer Keep editing or Discard. Navigation shortcuts are disabled behind dialogs/calendars. Text retains normal Undo/Redo. The shortcut reference supports keyboard scrolling and compact windows.

## Diary privacy and saving

Diary uses your **current Linux account password** through Quickshell's native PAM service and the existing `/etc/pam.d/omarchy-lock-password` policy. Daymark does not create or modify PAM configuration, store the password, send it to the Python helper or accept a separate app password. Missing providers/policies, errors, cancellation, unsupported conversations and passwordless success cannot unlock it.

Diary starts locked and relocks when you leave its tab, the journal loses focus, or the window is hidden/closed. **Lock** and **Ctrl+Shift+L** lock immediately. The private editor is removed while locked. Pending notes are flushed; failed drafts remain in memory behind the lock for authenticated recovery. Import/Export requires the same authorization because archives can contain diary text. Returning from a file chooser may require unlocking again.

**This is an interface privacy lock, not encryption.** The SQLite database, recovery backups and JSON exports are plaintext. Anyone with access to your account/files can read them outside Daymark; direct backend access is not password-protected storage. There is no secure-memory-erasure promise.

Diary autosaves, but **Saved means SQLite has acknowledged the write**, not merely that text was typed. Failed saves retain input and retry identity; conflicts require an explicit choice. Ordinary closing is guarded while writes or changed forms remain. Host hide, disable, source reload, restart or forced process termination can bypass those guards and lose uncommitted text.

Deletion offers Undo and restoration from Recently deleted. Permanent deletion requires typing `DELETE`; it neither deletes older backups nor promises forensic erasure.

## Data & Safety

### Export a complete backup

Choose **Export journal**, select a **destination folder**, then **Export here**. After authorization, Daymark creates:

```text
daymark-backup-YYYY-MM-DD-HHMMSS-mmm.json
```

The success message shows the full path. Export includes plans, logs, diary pages, deleted records, pins, relationships and historical metadata. Existing files are never overwritten; unsafe/symlink paths are refused. Keep plaintext backups private and outside both the plugin source and live data directory.

### Add records from a backup

Choose **Import a backup**, select a compatible Daymark/Daylog JSON file, then **Add from backup** and authorize. Import **adds to the current journal**, including a populated one:

- New records are added; matching records are skipped.
- Different versions of the same ID or diary date keep **your current version**. Same-date diary text is not silently merged or overwritten.
- Same-title activities with different IDs remain separate.
- The result reports added records, matching skips and conflicts. **Show skipped records** provides protected, paginated details; skipped versions remain in the original backup.

Plans appear according to their original dates/status, logs and completions in History, and pages in Diary behind its lock. Pins and compatible historical/deleted records are preserved. Validation and a private consistent database backup precede the transactional import; failed writes roll back. Retrying the same request is safe, and importing the same unchanged backup again does not duplicate matching records. Failed operations retain the relevant selection/draft for retry rather than pretending they succeeded.

### Storage and older records

Normal data lives in an **absolute** `$XDG_DATA_HOME/daylog`, otherwise `~/.local/share/daylog`. A relative `XDG_DATA_HOME` falls back to HOME. The database remains `daylog.sqlite3`; Daymark's name does not rename existing data or record IDs.

JSON retains `format: "daylog"`, `formatVersion: 1` and current `schemaVersion: 5`. Schema 5 stores pins and creates a private consistent backup before upgrading an older database. Schema-4 JSON still imports with activities initially unpinned. Older Daylog versions may not understand schema-5 archives.

Historical labels, durations, timezone context and measured intervals remain in storage and exports. Basic edits preserve hidden fields; historical clocked/timer entries permit note-only editing so measured dates do not move. Unfinished historical timers are retired at their **last confirmed checkpoint**, including after import, without counting unknown downtime or completing the activity. Failure leaves them readable and unchanged with an explicit Retry message. There is no frontend timer/checkpoint loop.

Import matches canonical IDs before names. A known historical category/project keeps its current version even if renamed; incoming activities retain that ID relationship. Name matching reuses a label only when its incoming ID is not already known.

Saved records are outside installed code. **Never delete the data directory as part of an update or removal.** Prefer complete JSON export over blindly copying an active SQLite database, and verify recovery in a fresh isolated profile before relying on a backup. Filesystem permissions are not encryption. Daymark sends no journal records over the network, has no telemetry, and does not monitor other applications. Git installation/update accesses the source host separately.

## Compatibility and dependencies

Daymark supports the **native Omarchy shell and built-in bar/service contract**. Replacement bars without that shared-service contract are unsupported. The runtime is native QML plus a short-lived Python helper using standard-library SQLite: no third-party Python packages, extra daemon, web server or additional Quickshell process.

These package versions were observed together on Linux x86-64; they are **not minimum versions or a compatibility promise for other releases**:

| Component | Observed package version |
| --- | --- |
| Omarchy | `4.0.5-1` |
| Quickshell | `0.3.2.r7.g2b4501a-1` |
| Qt base | `6.12.0-3` |
| Qt declarative | `6.12.0-1` |
| Python | `3.14.8-1` |

Runtime needs Qt Quick / Controls / Dialogs, Python with SQLite, and Quickshell's `Quickshell.Services.Pam` with the existing Omarchy password policy. Installation uses the existing Omarchy plugin CLI and its utilities; Git is needed for Git-managed installs. Manual copying below additionally uses Bash and tar. The optional development preview needs a C++ compiler, `pkg-config` and Qt development tools, not extra installed-plugin runtime dependencies.

The plain Qt preview **cannot load Quickshell's statically linked PAM module**: its password field is deliberately disabled and Diary/Import/Export remain locked. It is not an alternative authentication route.

## Install

Plugins run **unsandboxed inside your desktop shell**. Review the source before enabling. Daymark is available from its [public source repository](https://github.com/naolselemon/daymark); direct Git installation does not require marketplace approval. The [marketplace submission](https://github.com/omacom/omarchy-plugin-marketplace/issues/12611) is separate from the GitHub release.

### Git-managed installation (recommended)

Run interactively, reviewing the CLI's trust and enable prompts:

```bash
omarchy plugin add https://github.com/naolselemon/daymark.git
```

`omarchy plugin install` is an alias for `add` on the observed CLI. Adding clones and validates the root manifest, installs under `~/.config/omarchy/plugins/naolselemon.daymark`, rescans the catalog, and offers to enable. Decline enabling until you have reviewed the installed source. Private access must already be configured; the CLI disables interactive Git credential prompts. Do not embed credentials in the URL.

If you chose not to enable, wait until the plugin appears in the catalog, then enable when ready:

```bash
omarchy-shell shell listPlugins
omarchy plugin enable naolselemon.daymark
```

The notebook launcher defaults to the bar's right section; interactive installation can offer placement. You can also summon the panel directly:

```bash
omarchy-shell shell summon naolselemon.daymark '{}'
```

IPC responses do not mean asynchronous loading is finished; wait for the visible workspace to settle.

### Manual installation

For a reviewed source directory without a Git-managed installation, run the following **from that source directory**. It refuses an existing target and excludes generated bytecode. The observed CLI uses `$HOME/.config/omarchy/plugins` even when `XDG_CONFIG_HOME` is set.

```bash
(
  set -euo pipefail
  umask 077
  omarchy plugin validate .
  target="$HOME/.config/omarchy/plugins/naolselemon.daymark"
  mkdir -p "$HOME/.config/omarchy/plugins"
  mkdir "$target"
  tar --exclude='__pycache__' --exclude='*.pyc' --exclude='*.pyo' \
    -cf - manifest.json LICENSE README.md preview.png \
    backend prototype integration | tar -xf - -C "$target"
  omarchy plugin validate "$target"
)
```

If copying or validation fails, stop and inspect the error; do not enable a partial installation. After successful validation:

```bash
omarchy-shell shell rescanPlugins
omarchy-shell shell listPlugins
# Wait until naolselemon.daymark appears, then:
omarchy plugin enable naolselemon.daymark
```

A manual copy is **not Git-managed** and cannot be updated with `omarchy plugin update`, even if its source directory is a Git checkout.

## Update, disable or remove safely

**Before any disable, update, source replacement, shell restart or removal:** save or explicitly discard changed forms, wait for Diary's **Saved** acknowledgement, export a fresh JSON backup outside the source/data directory, then close the journal. Uncommitted drafts are not restart-safe. A shell restart affects the desktop, not just Daymark.

For a Git-managed installation with a reviewed upstream and working repository access, run each step only after the previous step succeeds:

```bash
omarchy plugin disable naolselemon.daymark
omarchy plugin update naolselemon.daymark
# Review the diff/confirmation; continue only after a successful update.
omarchy restart shell
omarchy plugin enable naolselemon.daymark
```

The observed updater fetches upstream, shows a diff for confirmation, fast-forwards and validates. A bare `omarchy plugin update` targets all Git-managed plugins and is unnecessary here. There is no automatic-update guarantee. Hot updates have left old QML cached and failed to discover a new QML file until restart; do not rely on seamless hot reload.

For a **manual update**, keep the old source and a fresh journal export, disable Daymark, remove the old code through the command below, then run only the manual **copy/validation block** with the reviewed new source—not its fresh-install enable step. Do not overlay runtime trees or copy generated caches. After validation, run `omarchy-shell shell rescanPlugins`, `omarchy restart shell`, then `omarchy plugin enable naolselemon.daymark`, stopping if a step fails. To switch from manual to Git-managed installation, follow the same backup/disable/removal precautions, add the Git URL and decline its enable prompt, then restart and enable.

To disable without removing code, or re-enable later:

```bash
omarchy plugin disable naolselemon.daymark
omarchy plugin enable naolselemon.daymark
```

To remove installed code, run interactively and review the confirmation:

```bash
omarchy plugin remove naolselemon.daymark
```

On the observed CLI, a non-Git code directory is moved to a hidden timestamped backup under `~/.config/omarchy/plugins`; a Git installation is deleted instead. **Neither removes the external `daylog` data directory or exported backups.** A code-folder backup is not a journal backup.

Before an incompatible schema change, require tested migration/recovery instructions and backups. **Do not open a newer database with older code as an improvised rollback.** Restoring code alone does not restore an older data schema.

## Evidence and known limitations

The original release preparation passed **158 Python tests** with `ResourceWarning` treated as an error from a clean tracked-file package. Qt 6 prototype/integration QML/JS lint, root/staged manifest validation and all seven Qt Quick clock scenarios also passed (nine reported passes including setup/cleanup). These checks cover the exercised source/runtime, not every host or future revision.

The same package ran in the native offscreen Qt host with the real asynchronous helper and isolated SQLite data. Checks exercised consecutive Enter-driven plans, logging against an existing activity without completing it, all four views, acknowledged diary saving with the same editor retained across a palette change, shortcuts and compact dirty-close guards. Actual file/folder selection exercised append import, same-date diary conflicts, repeat without duplicates and a private JSON export. Restoring that exported file and re-exporting produced exact canonical equality. The root preview is from this run.

Earlier installed-shell checks covered the shared launcher/panel/service, lifecycle record preservation and shell palette/typography propagation with a retained draft. A real system-PAM unlock was observed separately with owner-entered credentials; test-only unlocked UI automation is not authentication evidence. The owner reports completing the pre-publication checklist. This release-preparation pass did not modify the installed app, restart the desktop or repeat real-PAM authentication.

The 0.1.0 input refinement also exercised the real Wayland/OpenGL renderer with isolated SQLite profiles. Current dark and light/scaled captures showed all four focus-outline edges across shared single-line and multiline inputs. Native interaction covered Enter-driven planning, saved activity/log edits, typed permanent-deletion confirmation and removal, password masking/cancellation, searches and diary saving. The password prompt used a UI-only authentication fixture; this is not another real-PAM test.

Physical multi-monitor behavior remains unverified. Offscreen captures and resized workspace items do not certify physical window sizes, full-desktop theme-switch effects or suspend/resume hardware behavior. Hot-update limits and the preview's lack of PAM remain as described above.

### Reproducible source checks

From a source checkout, run the Python suite:

```bash
PYTHONDONTWRITEBYTECODE=1 python -W error::ResourceWarning -m unittest discover -s tests -v
```

Clock regression checks use Qt 6 Quick Test with a controlled in-process clock and isolated transport; they do not change the system clock or access a journal:

```bash
QT_QPA_PLATFORM=offscreen QML_DISABLE_DISK_CACHE=1 /usr/lib/qt6/bin/qmltestrunner -input tests
```

The clock scenarios cover calendar/year/leap boundaries, multi-day wake-up and backward-clock simulations, delayed snapshots, refresh failure with a retained draft, and unchanged dates without idle helper polling. Integration QML lint additionally needs a temporary `qs` import mapping to the installed `/usr/share/omarchy/shell`; prototype-only lint does not validate the shell adapter.

For an optional disposable native preview:

```bash
python tools/preview.py --demo --size 1440x1000
# Empty disposable profile:
python tools/preview.py --temporary
# Synthetic records with real write failures:
python tools/preview.py --demo --read-only
```

The launcher builds a temporary Qt host, never silently opens the ordinary journal and does not modify the desktop theme. Demo/temporary profiles are removed on exit; explicit `--profile` directories persist. Use the launcher to quit cleanly. Protected workflows require the native Omarchy plugin, not this preview.

## 0.1.0 release notes

- Four focused views: Today, Plan, activity History and a standalone system-password-locked Diary.
- Consecutive keyboard-driven planning, persistent activity pins, automatic relative-date labels and 14-day entry insights.
- Native theme-following surfaces, responsive layouts, contextual shortcuts and 24-pixel checkbox indicators with at least 44-pixel click targets.
- Inset shared input focus outlines from scrolling-container edges, including permanent-deletion confirmations and system-password prompts.
- Folder-based, no-overwrite JSON exports and append imports that preserve current versions and report conflicts.
- Acknowledged saving, retained failed drafts, deletion recovery and preservation of existing Daylog IDs and historical measurements.

## License, attribution and publication

Daymark is copyright Naol Selemon and licensed under [MIT](LICENSE). Omarchy, Quickshell and Qt are external dependencies with their own licenses; this package does not relicense them.

Integration references: [Omarchy plugin development](https://plugins.omarchy.org/develop.html), [Quickshell Process API](https://quickshell.org/docs/v0.3.1/types/Quickshell.Io/Process/), [Quickshell PAM at the observed revision](https://github.com/quickshell-mirror/quickshell/tree/2b4501a/src/services/pam), [Python SQLite](https://docs.python.org/3/library/sqlite3.html) and the [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir/latest/).

The permanent plugin namespace is `naolselemon.daymark`. The public repository's [initial marketplace submission](https://github.com/omacom/omarchy-plugin-marketplace/issues/12611) is awaiting maintainer review; a submitted request is not a published listing. The [official publishing guide](https://plugins.omarchy.org/publish.html) and [submission contract](https://github.com/omacom/omarchy-plugin-marketplace/blob/main/SUBMISSION.md) require a public GitHub repository with a root manifest, README and license, dependency/install/removal guidance and an optional preview. The submission uses Productivity with Bar and Quickshell tags. Keep corrections on that existing request rather than submitting a duplicate.

Later listing updates use the [verification form](https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=verify-plugin.yml) and full 40-character upstream commit SHA. Compatibility validation, automated baseline checks and maintainer approval apply to the exact reviewed commit; they are not a security audit or certification. Marketplace publication is separate from an end user's targeted plugin update.
