"""Updater regressions: real disposable Git history, fake desktop, no network.

Only the Python constructor supplies synthetic roots/providers. The production
CLI cannot override the installed root, release provider, or repository identity.
"""
from contextlib import closing
import copy
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

from backend.updater import (LATEST_RELEASE, LIMIT, NoRedirect, PLUGIN_ID, REPOSITORY,
                             SOURCE_ROOT, UpdateError, Updater, exchange, latest_release,
                             read_json, run_command)


class UpdaterTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="daymark-updater-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.remote = self.root / "remote"
        self.remote.mkdir()
        self.profile = self.root / "profile"
        self.profile.mkdir(mode=0o700)
        self.source = self.root / "plugins" / PLUGIN_ID
        self.source.parent.mkdir()
        self.git(self.remote, "init", "--quiet")
        self.write_release("0.1.0")
        (self.remote / ".gitignore").write_text("__pycache__/\n", encoding="utf-8")
        self.old = self.commit("initial")
        self.git(self.remote, "tag", "v0.1.0")
        # Historical high-number tags must not override GitHub's declared latest.
        self.git(self.remote, "tag", "v1.0.0")
        self.write_release("0.2.0")
        self.new = self.commit("stable")
        self.git(self.remote, "tag", "-a", "v0.2.0", "-m", "stable release")
        self.git(self.root, "clone", "--quiet", "--no-hardlinks", str(self.remote), str(self.source))
        self.git(self.source, "checkout", "--quiet", "--detach", self.old)
        self.release = {"id": 42, "tag_name": "v0.2.0", "draft": False, "prerelease": False,
                        "html_url": "https://github.com/naolselemon/daymark/releases/tag/v0.2.0"}
        self.config = {"version": 1, "plugins": [{"id": "other.service"}],
                       "bar": {"layout": {"right": ["clock", {"id": PLUGIN_ID,
                                  "settings": {"color": "user-value", "width": 47}}, "battery"]}}}
        self.enabled = True
        self.now = 100000
        self.calls = []
        self.launched = []
        self.restart_failures = 0
        self.validation_fails = False
        self.manager_state = "active"
        self.restart_hook = None
        self.fetches = 0
        self.elapsed = 0.0
        self.shell_running = True
        self.shell_generation = 1
        self.configuration = "/synthetic/omarchy/shell/shell.qml"
        self.stop_delay = 0
        self.stopping = False
        self.stop_refused = False
        self.locked_state = 1
        self.lock_pending = False
        self.other_instances = []
        self.readiness = {}
        self.bar_readiness = {}
        self.readiness_source = None
        self.status_during_readiness = False
        self.hotloads = 0
        self.lifecycle = []
        self.updater = self.engine()

    def git(self, directory, *args):
        result = subprocess.run(["/usr/bin/git", "-c", "user.name=Updater fixture", "-c",
                                 "user.email=updater@example.invalid", "-c", "commit.gpgsign=false",
                                 "-C", str(directory), *args], check=True, capture_output=True, text=True)
        return result.stdout.strip()

    def write_release(self, version):
        manifest = {"schemaVersion": 1, "id": PLUGIN_ID, "name": "Daymark", "version": version,
                    "kinds": ["bar-widget", "panel", "service"],
                    "entryPoints": {"barWidget": "Widget.qml", "panel": "Panel.qml", "service": "Service.qml"}}
        (self.remote / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        for name in ("Widget.qml", "Panel.qml", "Service.qml"):
            (self.remote / name).write_text("import QtQuick\nItem {}\n", encoding="utf-8")

    def commit(self, message):
        self.git(self.remote, "add", ".")
        self.git(self.remote, "commit", "--quiet", "-m", message)
        return self.git(self.remote, "rev-parse", "HEAD")

    def fetch(self):
        self.fetches += 1
        return copy.deepcopy(self.release)

    def runner(self, argv, **kwargs):
        argv = list(map(str, argv))
        self.calls.append(argv)
        executable = Path(argv[0]).name
        if executable == "git":
            return run_command(argv, **kwargs)
        if executable == "omarchy-plugin-validate":
            if self.validation_fails:
                raise UpdateError("validation", "Synthetic manifest validation failure")
            manifest = read_json(Path(argv[1]) / "manifest.json")
            self.assertEqual(manifest["id"], PLUGIN_ID)
            for entry in manifest["entryPoints"].values():
                self.assertTrue((Path(argv[1]) / entry).is_file())
            return 0, ""
        if executable == "omarchy-shell":
            if not self.shell_running:
                raise UpdateError("ipc", "Synthetic shell is stopped")
            if argv[1:] == ["shell", "listShellConfig"]:
                return 0, json.dumps(self.config)
            if argv[1:] == ["lock", "status"]:
                return 0, json.dumps({"secure": False, "requested": self.lock_pending})
            self.assertEqual(argv[1:], [PLUGIN_ID, "updateReadiness"])
            if self.status_during_readiness:
                self.assertEqual(self.updater.result()["phase"], "installing")
            commit = self.git(self.source, "rev-parse", "HEAD")
            self.lifecycle.append(("readiness", commit))
            return 0, json.dumps({"protocol": 1, "ready": self.readiness.get(commit, True),
                                 "barReady": self.bar_readiness.get(commit, True),
                                 "source": self.readiness_source or str(self.source)})
        if executable == "omarchy-plugin-list":
            self.assertEqual(argv[1:], ["--json"])
            self.assertTrue(self.shell_running)
            return 0, json.dumps([{"id": PLUGIN_ID, "enabled": self.enabled}])
        if executable == "omarchy-restart-shell":
            self.lifecycle.append(("restart", self.git(self.source, "rev-parse", "HEAD")))
            if self.restart_failures:
                self.restart_failures -= 1
                raise UpdateError("restart", "Synthetic restart refusal")
            self.shell_running = True
            self.stopping = False
            self.shell_generation += 1
            if self.restart_hook:
                self.restart_hook()
            return 0, ""
        if executable == "omarchy-hyprland-session-locked":
            return self.locked_state, ""
        if executable == "quickshell":
            if argv[1:] == ["list", "-a", "-j"]:
                if self.stopping:
                    if self.stop_delay:
                        self.stop_delay -= 1
                    else:
                        self.shell_running = False
                        self.stopping = False
                instances = list(self.other_instances)
                if self.shell_running:
                    instances.append({"config_path": self.configuration,
                                      "id": "shell-" + str(self.shell_generation),
                                      "pid": 1000 + self.shell_generation})
                return 0, json.dumps(instances)
            self.assertEqual(argv[1:], ["kill", "--id", "shell-" + str(self.shell_generation), "--any-display"])
            self.lifecycle.append(("stop", self.shell_generation))
            if self.stop_refused:
                raise UpdateError("stop_refused", "Synthetic stop refusal")
            self.stopping = True
            return 0, ""
        if executable == "systemctl":
            if argv[1:] == ["--user", "show-environment"]:
                return 0, "OMARCHY_PATH=/synthetic/omarchy"
            return 0, self.manager_state
        if executable == "systemd-run":
            return 0, ""
        self.fail("Unexpected external operation: " + repr(argv))

    def sleep(self, seconds):
        self.elapsed += seconds

    def exchange(self, left, right):
        self.lifecycle.append(("exchange", self.git(left, "rev-parse", "HEAD")))
        exchange(left, right)
        if self.shell_running:
            self.hotloads += 1
            if self.restart_hook:
                self.restart_hook()

    def engine(self, **changes):
        options = dict(source=self.source, installed_root=self.source,
                       repository=str(self.remote), release_fetcher=self.fetch,
                       runner=self.runner, launcher=lambda worker, token: self.launched.append((worker, token)),
                       clock=lambda: self.now, exchanger=self.exchange,
                       monotonic=lambda: self.elapsed, sleeper=self.sleep)
        options.update(changes)
        return Updater(self.profile, **options)

    def request(self, operation, args=None):
        return {"protocol": 1, "requestId": "fixture", "op": "update_" + operation, "args": args or {}}

    def prepare(self):
        result = self.updater.handle(self.request("check"))
        self.assertEqual(result["phase"], "ready")
        self.assertEqual(result["availableCommit"], self.new)
        return result

    def approve(self):
        return self.updater.handle(self.request("install", {"commit": self.new, "restartApproved": True}))

    def run_worker(self):
        self.updater.work(self.launched[-1][1])

    def assert_error(self, code, function, *args, **kwargs):
        with self.assertRaises(UpdateError) as caught:
            function(*args, **kwargs)
        self.assertEqual(caught.exception.code, code)
        return str(caught.exception)

    def test_status_is_offline_and_read_only_status_creates_nothing(self):
        missing = self.root / "missing-profile"
        updater = Updater(missing, read_only=True, source=self.source, installed_root=self.source,
                          repository=str(self.remote), runner=self.runner,
                          release_fetcher=lambda: self.fail("status fetched network"))
        result = updater.handle(self.request("status"))
        self.assertEqual(result["installedVersion"], "0.1.0")
        self.assertFalse(result["supported"])
        self.assertFalse(missing.exists())
        self.assert_error("read_only", updater.check)
        self.assertFalse(missing.exists())

    def test_declared_latest_and_annotated_tag_resolve_exact_commit(self):
        result = self.prepare()
        self.assertEqual(result["availableVersion"], "0.2.0")
        self.assertEqual(result["lastAttemptAt"], self.now)
        self.assertEqual(result["lastCheckedAt"], self.now)
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), self.old)
        candidate = Path(self.updater.load()["prepared"]["path"])
        self.assertNotIn(self.source, candidate.parents)
        self.assertEqual(self.git(candidate, "rev-parse", "HEAD"), self.new)
        self.updater.handle(self.request("status"))
        self.assertEqual(self.fetches, 1)
        fetched = [call for call in self.calls if "fetch" in call]
        self.assertTrue(any("refs/tags/v0.2.0:refs/tags/v0.2.0" in call for call in fetched))
        self.assertFalse(any("refs/tags/v1.0.0" in str(call) for call in fetched))

    def test_newer_installed_history_is_not_downgraded(self):
        self.write_release("0.3.0")
        newer = self.commit("newer development")
        self.git(self.source, "fetch", "--quiet", "origin")
        self.git(self.source, "checkout", "--quiet", "--detach", newer)
        result = self.updater.check()
        self.assertEqual(result["phase"], "current")
        self.assertNotIn("prepared", self.updater.load())
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), newer)

    def test_diverged_history_is_rejected_without_source_mutation(self):
        (self.source / "local.txt").write_text("committed local change")
        self.git(self.source, "add", ".")
        self.git(self.source, "commit", "--quiet", "-m", "diverged")
        installed = self.git(self.source, "rev-parse", "HEAD")
        self.assert_error("diverged", self.updater.check)
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), installed)
        self.assertEqual(self.updater.load()["phase"], "idle")

    def test_manifest_downgrade_on_forward_history_is_rejected(self):
        self.write_release("0.0.9")
        self.commit("bad downgrade")
        self.git(self.remote, "tag", "v0.0.9")
        self.release.update(tag_name="v0.0.9", html_url="https://github.com/naolselemon/daymark/releases/tag/v0.0.9")
        self.assert_error("downgrade", self.updater.check)

    def test_wrong_release_identity_prerelease_and_manifest_mismatch(self):
        for change in ({"draft": True}, {"prerelease": True}, {"tag_name": "main"},
                       {"id": True}, {"html_url": "https://example.invalid/release"}):
            original = copy.deepcopy(self.release)
            self.release.update(change)
            with self.subTest(change=change), self.assertRaises(UpdateError):
                self.updater.check()
            self.assertEqual(self.updater.load()["phase"], "idle")
            self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), self.old)
            self.release = original
        self.git(self.remote, "tag", "v0.4.0")
        self.release.update(tag_name="v0.4.0", html_url="https://github.com/naolselemon/daymark/releases/tag/v0.4.0")
        self.assert_error("release_invalid", self.updater.check)

    def test_failed_checks_persist_attempt_without_inventing_success(self):
        self.now += 50
        self.updater.release_fetcher = lambda: (_ for _ in ()).throw(UpdateError("network", "offline fixture"))
        self.assert_error("network", self.updater.check)
        result = self.updater.result()
        self.assertEqual(result["lastAttemptAt"], self.now)
        self.assertEqual(result["lastCheckedAt"], 0)
        self.assertIn("offline fixture", result["message"])

    def test_preview_wrong_origin_dirty_and_symlink_sources_fail_closed(self):
        preview = self.engine(installed_root=self.root / "actual-installed")
        self.assertFalse(preview.result()["supported"])
        self.assert_error("unsupported", preview.check)
        self.git(self.source, "remote", "set-url", "origin", "https://example.invalid/not-daymark.git")
        self.assert_error("identity", self.updater.check)
        self.git(self.source, "remote", "set-url", "origin", str(self.remote))
        (self.source / "user-notes.txt").write_text("never discard")
        self.assert_error("dirty_source", self.updater.check)
        self.assertEqual((self.source / "user-notes.txt").read_text(), "never discard")
        linked = self.root / "linked"
        linked.symlink_to(self.source, target_is_directory=True)
        self.assert_error("unsafe_path", self.engine, source=linked)

    def test_normal_ignored_bytecode_does_not_disable_installed_updater(self):
        cache = self.source / "__pycache__"
        cache.mkdir()
        (cache / "helper.cpython-314.pyc").write_bytes(b"disposable cache")
        self.prepare()
        (cache / "user-notes.txt").write_text("must preserve")
        self.assert_error("dirty_source", self.approve)

    def test_candidate_validation_and_tampering_are_rejected(self):
        self.validation_fails = True
        self.assert_error("validation", self.updater.check)
        self.validation_fails = False
        self.prepare()
        candidate = Path(self.updater.load()["prepared"]["path"])
        (candidate / "Widget.qml").write_text("changed after approval screen")
        self.assert_error("candidate_changed", self.approve)
        self.assertFalse(self.launched)

    def test_approval_is_explicit_exact_and_cannot_be_reused(self):
        self.prepare()
        for args in ({"commit": self.new}, {"commit": self.new, "restartApproved": 1},
                     {"commit": self.new[:12], "restartApproved": True}):
            self.assert_error("approval_required", self.updater.install, args)
        self.assert_error("approval_stale", self.updater.install,
                          {"commit": self.old, "restartApproved": True})
        self.assertEqual(self.approve()["phase"], "installing")
        self.assert_error("approval_stale", self.approve)
        worker, token = self.launched[0]
        self.assertEqual(worker.parent, self.updater.root)
        self.assertEqual(worker.read_bytes(), (SOURCE_ROOT / "backend/updater.py").read_bytes())
        self.assertEqual(worker.stat().st_mode & 0o777, 0o600)
        self.assertEqual(len(token), 32)

    def test_launch_failure_keeps_preparation_retryable(self):
        self.prepare()
        self.updater.launcher = lambda *args: (_ for _ in ()).throw(UpdateError("launch", "service unavailable"))
        self.assert_error("launch", self.approve)
        self.assertEqual(self.updater.load()["phase"], "ready")
        self.assertNotIn("token", self.updater.load())
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), self.old)

    def test_worker_rechecks_countdown_and_source_after_dispatch(self):
        self.prepare()
        self.approve()
        with closing(sqlite3.connect(self.profile / "countdown.sqlite3")) as db:
            db.execute("CREATE TABLE countdown(id INTEGER PRIMARY KEY,status TEXT)")
            db.execute("INSERT INTO countdown VALUES(1,'paused')")
            db.commit()
        self.assertIn("countdown", self.assert_error("install_failed", self.run_worker))
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), self.old)
        self.assertEqual(self.updater.load()["phase"], "idle")
        with closing(sqlite3.connect(self.profile / "countdown.sqlite3")) as db:
            db.execute("UPDATE countdown SET status='idle'")
            db.commit()
        self.prepare()
        self.approve()
        (self.source / "user.txt").write_text("late edit")
        self.assertIn("local changes", self.assert_error("install_failed", self.run_worker))
        self.assertEqual((self.source / "user.txt").read_text(), "late edit")

    def test_worker_backup_atomic_swap_exact_placement_and_external_data(self):
        connection = sqlite3.connect(self.profile / "daylog.sqlite3")
        self.addCleanup(connection.close)
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("CREATE TABLE notes(value TEXT)")
        connection.execute("INSERT INTO notes VALUES('private fixture note')")
        connection.commit()
        (self.profile / "private-key").write_bytes(b"private fixture material")
        before = copy.deepcopy(self.config)
        self.prepare()
        self.approve()
        self.run_worker()
        state = self.updater.load()
        self.assertEqual(state["phase"], "updated")
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), self.new)
        self.assertEqual(self.config, before)
        self.assertTrue(self.enabled)
        backup = Path(state["backup"])
        with closing(sqlite3.connect(backup / "daylog.sqlite3")) as db:
            self.assertEqual(db.execute("SELECT value FROM notes").fetchone(), ("private fixture note",))
            self.assertEqual(db.execute("PRAGMA quick_check").fetchone(), ("ok",))
        self.assertEqual((backup / "private-key").read_bytes(), b"private fixture material")
        self.assertEqual((backup / "private-key").stat().st_mode & 0o777, 0o600)
        self.assertEqual(connection.execute("SELECT value FROM notes").fetchone(), ("private fixture note",))
        self.assertEqual(self.git(Path(state["rollbackSource"]), "rev-parse", "HEAD"), self.old)
        self.assertEqual(sum(Path(call[0]).name == "omarchy-restart-shell" for call in self.calls), 1)
        self.assert_error("approval_stale", self.run_worker)

    def test_disabled_plugin_is_not_enabled_by_update(self):
        self.enabled = False
        self.config["bar"]["layout"]["right"].pop(1)
        self.config["disabledPlugins"] = [PLUGIN_ID]
        before = copy.deepcopy(self.config)
        self.prepare()
        self.approve()
        self.run_worker()
        self.assertEqual(self.updater.load()["phase"], "updated")
        self.assertFalse(self.enabled)
        self.assertEqual(self.config, before)

    def test_restart_failure_rolls_code_back_but_does_not_claim_data_recovery(self):
        self.prepare()
        self.approve()
        self.restart_failures = 1
        message = self.assert_error("install_failed", self.run_worker)
        self.assertIn("NOT rolled back", message)
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), self.old)
        self.assertEqual(self.updater.load()["phase"], "idle")
        self.assertTrue(self.updater.load()["recoveryRequired"])
        self.assert_error("recovery_required", self.updater.check)

    def test_runtime_migration_and_failed_activation_keep_backups_and_report_recovery(self):
        path = self.profile / "settings.sqlite3"
        with closing(sqlite3.connect(path)) as db:
            db.execute("PRAGMA user_version=1")
        def migrate():
            with closing(sqlite3.connect(path)) as db:
                db.execute("PRAGMA user_version=2")
            entries = self.config["bar"]["layout"]["right"]
            entries.append(entries.pop(1))
        self.restart_hook = migrate
        self.prepare()
        self.approve()
        self.assert_error("install_failed", self.run_worker)
        state = self.updater.load()
        self.assertNotEqual(state["phase"], "updated")
        self.assertTrue(state["recoveryRequired"])
        with closing(sqlite3.connect(Path(state["backup"]) / "settings.sqlite3")) as db:
            self.assertEqual(db.execute("PRAGMA user_version").fetchone()[0], 1)
        with closing(sqlite3.connect(path)) as db:
            self.assertEqual(db.execute("PRAGMA user_version").fetchone()[0], 2)
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), self.new)
        self.assertTrue(self.shell_running)
        self.assertTrue(Path(state["failedBackup"]).exists())
        with closing(sqlite3.connect(Path(state["failedBackup"]) / "settings.sqlite3")) as db:
            self.assertEqual(db.execute("PRAGMA user_version").fetchone()[0], 2)
        self.assertFalse(any(event == ("restart", self.old) for event in self.lifecycle))

    def test_failed_rollback_reports_incomplete_and_retains_both_trees(self):
        self.prepare()
        candidate = Path(self.updater.load()["prepared"]["path"])
        self.approve()
        self.restart_failures = 2
        message = self.assert_error("install_failed", self.run_worker)
        self.assertIn("RECOVERY INCOMPLETE", message)
        self.assertTrue(candidate.exists())
        self.assertTrue(Path(self.updater.load()["backup"]).exists())

    def test_interrupted_worker_becomes_durable_explicit_recovery_state(self):
        self.prepare()
        self.approve()
        self.now += 31000
        self.assertEqual(self.updater.result()["phase"], "installing")
        self.manager_state = "inactive"
        result = self.updater.result()
        self.assertEqual(result["phase"], "idle")
        self.assertIn("interrupted", result["message"])
        self.assertTrue(self.updater.load()["recoveryRequired"])
        self.assertNotIn("token", self.updater.load())
        self.assertEqual(self.fetches, 1)

    def test_detached_launcher_uses_bounded_user_service_not_shell_child(self):
        self.updater.launch_worker(self.profile / "copied-worker.py", "a" * 32)
        command = self.calls[-1]
        self.assertEqual(command[0], "/usr/bin/systemd-run")
        self.assertIn("--user", command)
        self.assertIn("--property=RuntimeMaxSec=600", command)
        self.assertIn("--property=TimeoutStopSec=5", command)
        self.assertIn("-I", command)
        self.assertNotIn("restartApproved", " ".join(command))

    def test_private_paths_and_corrupt_state_are_not_overwritten(self):
        self.profile.chmod(0o755)
        self.assert_error("unsafe_path", self.updater.check)
        self.profile.chmod(0o700)
        self.updater.private_root()
        self.updater.state_path.write_text("not json")
        self.assert_error("invalid_state", self.updater.check)
        self.assertEqual(self.updater.state_path.read_text(), "not json")
        self.updater.state_path.unlink()
        outside = self.root / "outside.json"
        outside.write_text("untouched")
        self.updater.state_path.symlink_to(outside)
        self.assert_error("unsafe_path", self.updater.check)
        self.assertEqual(outside.read_text(), "untouched")

    def test_protocol_and_production_cli_have_no_provider_or_source_override(self):
        for request in ({}, self.request("status", {"url": "file:///unsafe"}),
                        {**self.request("status"), "protocol": True}):
            with self.assertRaises(UpdateError):
                self.updater.handle(request)
        script = SOURCE_ROOT / "backend/updater.py"
        result = subprocess.run([sys.executable, str(script), "--profile", str(self.profile), "--read-only"],
                                input=json.dumps(self.request("status")), capture_output=True, text=True, check=True)
        response = json.loads(result.stdout)
        self.assertTrue(response["ok"])
        self.assertEqual(response["requestId"], "fixture")
        self.assertNotIn("snapshot", response)
        self.assertFalse(response["result"]["supported"])
        self.assertFalse((self.profile / "updater").exists())
        rejected = subprocess.run([sys.executable, str(script), "--profile", str(self.profile),
                                   "--source", str(self.source)], capture_output=True, text=True)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertEqual(REPOSITORY, "https://github.com/naolselemon/daymark.git")
        self.assertEqual(LATEST_RELEASE, "https://api.github.com/repos/naolselemon/daymark/releases/latest")

    def test_http_uses_only_fixed_unauthenticated_endpoint_and_bounds_payload(self):
        response = MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = json.dumps(self.release).encode()
        opener = MagicMock()
        opener.open.return_value = response
        with patch("backend.updater.urllib.request.build_opener", return_value=opener):
            self.assertEqual(latest_release(), self.release)
            request = opener.open.call_args.args[0]
            self.assertEqual(request.full_url, LATEST_RELEASE)
            self.assertIsNone(request.get_header("Authorization"))
            self.assertEqual(opener.open.call_args.kwargs["timeout"], 20)
            response.read.assert_called_with(LIMIT + 1)
            response.read.return_value = b"x" * (LIMIT + 1)
            self.assert_error("release_invalid", latest_release)
        self.assert_error("release_identity", NoRedirect().redirect_request,
                          None, None, 302, "", {}, "https://example.invalid/")

    def test_active_countdown_blocks_approval_before_worker_launch(self):
        self.prepare()
        with closing(sqlite3.connect(self.profile / "countdown.sqlite3")) as db:
            db.execute("CREATE TABLE countdown(id INTEGER PRIMARY KEY,status TEXT)")
            db.execute("INSERT INTO countdown VALUES(1,'running')")
            db.commit()
        self.assert_error("countdown_active", self.approve)
        self.assertFalse(self.launched)
        self.assertEqual(self.updater.load()["phase"], "ready")

    def test_moved_remote_tag_cannot_change_already_approved_commit(self):
        self.prepare()
        self.write_release("0.3.0")
        moved = self.commit("remote moved after review")
        self.git(self.remote, "tag", "-f", "v0.2.0", moved)
        self.approve()
        self.run_worker()
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), self.new)
        self.assertEqual(self.fetches, 1)

    def test_busy_lock_prevents_competing_preparation(self):
        with self.updater.locked():
            self.assert_error("busy", self.engine().check)
        self.assertEqual(self.fetches, 0)

    def test_new_check_removes_only_obsolete_prepared_candidate(self):
        self.prepare()
        previous = Path(self.updater.load()["prepared"]["path"])
        self.prepare()
        self.assertFalse(previous.exists())
        self.assertTrue(Path(self.updater.load()["prepared"]["path"]).exists())

    def test_native_watcher_is_quiescent_before_initial_and_rollback_exchange(self):
        self.stop_delay = 3
        self.readiness[self.new] = False
        self.prepare()
        self.approve()
        self.assert_error("install_failed", self.run_worker)
        boundaries = [event[0] for event in self.lifecycle if event[0] != "readiness"]
        self.assertEqual(boundaries, ["stop", "exchange", "restart", "stop", "exchange", "restart"])
        self.assertEqual(self.hotloads, 0)
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), self.old)
        self.assertTrue(self.shell_running)
        self.assertIn(("readiness", self.old), self.lifecycle)
        self.assertNotEqual(self.updater.load()["phase"], "updated")

    def test_delayed_stop_and_refused_restart_cannot_hotload_candidate(self):
        self.stop_delay = 5
        self.restart_failures = 1
        self.prepare()
        self.approve()
        self.assert_error("install_failed", self.run_worker)
        self.assertEqual(self.hotloads, 0)
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), self.old)
        self.assertTrue(self.shell_running)
        self.assertTrue(Path(self.updater.load()["failedBackup"]).exists())

    def test_stop_refusal_prevents_exchange_and_preserves_original_tree(self):
        self.stop_refused = True
        self.prepare()
        self.approve()
        self.assert_error("install_failed", self.run_worker)
        self.assertFalse(any(event[0] == "exchange" for event in self.lifecycle))
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), self.old)
        self.assertEqual(self.hotloads, 0)

    def test_locked_unknown_and_pending_sessions_are_never_stopped(self):
        for lock_state, pending in ((0, False), (2, False), (1, True)):
            with self.subTest(lock_state=lock_state, pending=pending):
                self.locked_state = lock_state
                self.lock_pending = pending
                self.prepare()
                self.approve()
                self.assert_error("install_failed", self.run_worker)
                self.assertEqual(self.lifecycle, [])
                self.assertTrue(self.shell_running)
                self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), self.old)

    def test_other_quickshell_instances_are_not_killed(self):
        self.other_instances = [{"config_path": "/preview/shell.qml", "id": "preview", "pid": 9876}]
        self.prepare()
        self.approve()
        message = self.assert_error("install_failed", self.run_worker)
        self.assertIn("Close previews", message)
        self.assertEqual(self.lifecycle, [])
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), self.old)

    def test_unchanged_config_with_unloaded_components_cannot_succeed(self):
        before = copy.deepcopy(self.config)
        self.readiness[self.new] = False
        self.prepare()
        self.approve()
        message = self.assert_error("install_failed", self.run_worker)
        self.assertIn("ready components", message)
        self.assertEqual(self.config, before)
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), self.old)
        self.assertTrue(self.updater.load()["recoveryRequired"])
        self.assertEqual(self.hotloads, 0)

    def test_runtime_readiness_must_identify_the_installed_source(self):
        self.readiness_source = str(self.root / "unrelated-preview")
        self.prepare()
        self.approve()
        message = self.assert_error("install_failed", self.run_worker)
        self.assertIn("ready components", message)
        self.assertIn("RECOVERY INCOMPLETE", message)
        self.assertEqual(self.updater.load()["phase"], "idle")
        self.assertNotIn("activation verified", message)

    def test_shell_respawn_before_exchange_cancels_replacement(self):
        self.prepare()
        self.approve()
        prepared = self.updater.prepared
        def respawn_after_stop(state, commit):
            candidate = prepared(state, commit)
            if not self.shell_running:
                self.shell_running = True
                self.shell_generation += 1
            return candidate
        self.updater.prepared = respawn_after_stop
        self.assert_error("install_failed", self.run_worker)
        self.assertFalse(any(event[0] == "exchange" for event in self.lifecycle))
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), self.old)

    def test_changed_profile_and_failed_recovery_restart_keep_exact_recovery_details(self):
        path = self.profile / "settings.sqlite3"
        with closing(sqlite3.connect(path)) as db:
            db.execute("PRAGMA user_version=1")
        def migrate_then_refuse_next_restart():
            with closing(sqlite3.connect(path)) as db:
                db.execute("PRAGMA user_version=2")
            self.restart_failures = 1
        self.restart_hook = migrate_then_refuse_next_restart
        self.readiness[self.new] = False
        self.prepare()
        self.approve()
        message = self.assert_error("install_failed", self.run_worker)
        state = self.updater.load()
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), self.new)
        self.assertIn("RECOVERY INCOMPLETE", message)
        self.assertIn(state["backup"], message)
        self.assertIn(state["failedBackup"], message)
        self.assertEqual(state["recoveryCommand"], "/usr/share/omarchy/bin/omarchy-restart-shell")
        self.assertIn(state["recoveryCommand"], message)
        self.assertFalse(any(event == ("restart", self.old) for event in self.lifecycle))

    def test_readiness_status_probe_does_not_wait_for_live_worker_state_lock(self):
        self.prepare()
        self.approve()
        self.now += 31000
        self.status_during_readiness = True
        self.run_worker()
        self.assertEqual(self.updater.load()["phase"], "updated")

    def test_enabled_service_without_bar_placement_still_requires_runtime_readiness(self):
        self.enabled = False
        self.config["bar"]["layout"]["right"].pop(1)
        self.config["plugins"].append({"id": PLUGIN_ID})
        self.readiness[self.new] = False
        self.prepare()
        self.approve()
        self.assert_error("install_failed", self.run_worker)
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), self.old)
        self.assertEqual(self.updater.load()["phase"], "idle")

    def test_ready_service_with_failed_bar_widget_cannot_succeed(self):
        before = copy.deepcopy(self.config)
        self.bar_readiness[self.new] = False
        self.prepare()
        self.approve()
        message = self.assert_error("install_failed", self.run_worker)
        self.assertIn("ready components", message)
        self.assertEqual(self.config, before)
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), self.old)
        self.assertEqual(self.updater.load()["phase"], "idle")
        self.assertTrue(self.updater.load()["recoveryRequired"])
        self.assertIn(("readiness", self.old), self.lifecycle)
        self.assertEqual(self.hotloads, 0)

    def test_service_only_activation_does_not_require_bar_widget_readiness(self):
        self.enabled = False
        self.config["bar"]["layout"]["right"].pop(1)
        self.config["plugins"].append({"id": PLUGIN_ID})
        self.bar_readiness[self.new] = False
        self.prepare()
        self.approve()
        self.run_worker()
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), self.new)
        self.assertEqual(self.updater.load()["phase"], "updated")
        self.assertIn(("readiness", self.new), self.lifecycle)

    def test_exchange_failure_restores_shell_without_discarding_original_code(self):
        self.prepare()
        self.approve()
        self.updater.exchanger = lambda *args: (_ for _ in ()).throw(UpdateError("exchange_failed", "synthetic failure"))
        self.assert_error("install_failed", self.run_worker)
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), self.old)
        self.assertEqual(sum(Path(call[0]).name == "omarchy-restart-shell" for call in self.calls), 1)
        self.assertTrue(self.shell_running)
        self.assertFalse(self.updater.load().get("recoveryRequired", False))

    def test_exchange_durability_failure_still_rolls_back_completed_exchange(self):
        self.prepare()
        self.approve()
        exchanges = []
        def exchange_then_fail(left, right):
            exchange(left, right)
            exchanges.append(True)
            if len(exchanges) == 1:
                error = UpdateError("exchange_durability", "synthetic directory fsync failure")
                error.exchanged = True
                raise error
        self.updater.exchanger = exchange_then_fail
        self.assert_error("install_failed", self.run_worker)
        self.assertEqual(len(exchanges), 2)
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), self.old)
        self.assertTrue(self.updater.load()["recoveryRequired"])

    def test_command_deadline_and_output_bound_are_explicit(self):
        self.assert_error("timeout", run_command,
                          [sys.executable, "-c", "import time; time.sleep(2)"], 0.01)
        self.assert_error("output_limit", run_command,
                          [sys.executable, "-c", "print('x' * 1100000)"])


if __name__ == "__main__":
    unittest.main()
