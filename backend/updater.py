"""Pinned, approval-bound Omarchy updates; also the standalone detached worker.

No plugin imports: the private worker remains usable after replacing this tree.
The shell configuration is never rewritten. Verified shell quiescence precedes
every directory exchange; a cold restart then checks exact placement and runtime
readiness. Old code is never restarted against a changed post-upgrade profile.
"""
import argparse
from contextlib import contextmanager, closing
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid


PLUGIN_ID = "naolselemon.daymark"
REPOSITORY = "https://github.com/naolselemon/daymark.git"
LATEST_RELEASE = "https://api.github.com/repos/naolselemon/daymark/releases/latest"
SOURCE_ROOT = Path(__file__).absolute().parent.parent
COMMAND_ROOT = Path("/usr/share/omarchy/bin")
LIMIT = 1024 * 1024
SHA = re.compile(r"[0-9a-f]{40}\Z")
VERSION = re.compile(r"v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
SECTIONS = ("left", "centerBegin", "center", "centerEnd", "tray", "right")


class UpdateError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def fail(code, message):
    raise UpdateError(code, message)


def safe_path(path):
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        fail("unsafe_path", "Updater paths must be absolute and contain no parent traversal.")
    for part in (path, *path.parents):
        if part.is_symlink():
            fail("unsafe_path", "Updater paths must not contain symbolic links.")
    return path


def read_json(path):
    safe_path(path)
    with open(path, "rb") as stream:
        data = stream.read(LIMIT + 1)
    if len(data) > LIMIT:
        fail("invalid_state", "Updater JSON exceeds the size limit.")
    try:
        return json.loads(data)
    except (ValueError, UnicodeError):
        fail("invalid_state", "Updater JSON is invalid; existing data was not overwritten.")


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_json(path, value):
    safe_path(path)
    fd, temporary = tempfile.mkstemp(prefix=".state-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, ensure_ascii=True, allow_nan=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def run_command(argv, timeout=90, allowed=(0,)):
    # Never inherit Git URL rewrites, credential helpers, hooks, or injected config.
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith("GIT_")}
    environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null",
                       GIT_TERMINAL_PROMPT="0", GIT_CONFIG_COUNT="0",
                       GIT_ASKPASS="/bin/false", SSH_ASKPASS="/bin/false")
    environment["PATH"] = str(COMMAND_ROOT) + ":/usr/local/bin:/usr/bin:/bin"
    environment.setdefault("OMARCHY_PATH", str(COMMAND_ROOT.parent))
    with tempfile.TemporaryDirectory(prefix="daymark-command-") as home, tempfile.TemporaryFile() as output:
        if Path(str(argv[0])).name == "git":
            # libcurl may consult ~/.netrc independently of Git credential helpers.
            environment.update(HOME=home, XDG_CONFIG_HOME=home, GIT_OPTIONAL_LOCKS="0")
            environment.pop("NETRC", None)
        process = subprocess.Popen([str(arg) for arg in argv], stdin=subprocess.DEVNULL,
                                   stdout=output, stderr=subprocess.STDOUT,
                                   env=environment, start_new_session=True)
        deadline = time.monotonic() + timeout
        try:
            while process.poll() is None:
                if time.monotonic() >= deadline:
                    fail("timeout", "An updater command timed out.")
                if os.fstat(output.fileno()).st_size > LIMIT:
                    fail("output_limit", "An updater command exceeded its output limit.")
                time.sleep(0.025)
        finally:
            if process.poll() is None:
                import signal
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        output.seek(0)
        text = output.read(LIMIT + 1).decode("utf-8", errors="replace")
    if len(text.encode("utf-8")) > LIMIT:
        fail("output_limit", "An updater command exceeded its output limit.")
    if process.returncode not in allowed:
        fail("command_failed", "Updater command failed: " + str(argv[0]) + ": " + text[-1600:].strip())
    return process.returncode, text.strip()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        fail("release_identity", "The fixed release endpoint unexpectedly redirected.")


def latest_release():
    request = urllib.request.Request(LATEST_RELEASE, headers={
        "Accept": "application/vnd.github+json", "User-Agent": "Daymark-release-updater",
        "X-GitHub-Api-Version": "2022-11-28"})
    # Deliberately unauthenticated; neither ambient proxies nor credentials are used.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(request, timeout=20) as response:
            body = response.read(LIMIT + 1)
        if len(body) > LIMIT:
            fail("release_invalid", "The release response exceeds the size limit.")
        return json.loads(body)
    except UpdateError:
        raise
    except Exception as error:
        fail("network", "Could not retrieve the stable GitHub release: " + str(error))


def exchange(left, right):
    # Linux renameat2 is one atomic namespace operation, not two visible renames.
    libc = ctypes.CDLL(None, use_errno=True)
    operation = getattr(libc, "renameat2", None)
    if operation is None:
        fail("unsupported", "Atomic directory exchange is unavailable on this system.")
    if operation(-100, os.fsencode(left), -100, os.fsencode(right), 2) != 0:
        number = ctypes.get_errno()
        fail("exchange_failed", "Atomic code exchange failed: " + os.strerror(number))
    try:
        sync_directory(left.parent)
        if left.parent != right.parent:
            sync_directory(right.parent)
    except OSError as cause:
        error = UpdateError("exchange_durability", "Code exchanged, but the directory change could not be made durable.")
        error.exchanged = True
        raise error from cause


class Updater:
    def __init__(self, profile, read_only=False, *, source=None, installed_root=None,
                 repository=REPOSITORY, release_fetcher=None, runner=None,
                 launcher=None, clock=None, exchanger=None, monotonic=None, sleeper=None):
        # Injections are Python-only for isolated tests; CLI has no source/provider override.
        self.profile = safe_path(Path(profile))
        self.source = safe_path(Path(source) if source is not None else SOURCE_ROOT)
        self.installed_root = safe_path(Path(installed_root) if installed_root is not None
                                        else Path.home() / ".config/omarchy/plugins" / PLUGIN_ID)
        self.repository = repository
        self.release_fetcher = release_fetcher or latest_release
        self.runner = runner or run_command
        self.launcher = launcher or self.launch_worker
        self.clock = clock or (lambda: int(time.time() * 1000))
        self.exchanger = exchanger or exchange
        self.monotonic = monotonic or time.monotonic
        self.sleep = sleeper or time.sleep
        self.read_only = read_only
        self.root = self.profile / "updater"
        self.state_path = self.root / "state.json"

    def git(self, path, *args, allowed=(0,)):
        return self.runner(["/usr/bin/git", "--no-replace-objects", "-c", "core.hooksPath=/dev/null",
                            "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
                            "-c", "credential.helper=", "-c", "http.followRedirects=false",
                            "-c", "http.extraHeader=", "-c", "http.proxy=",
                            "-c", "fetch.fsckObjects=true", "-c",
                            "protocol.file.allow=always", "-C", str(path), *args], allowed=allowed)

    def command(self, name, *args, timeout=90):
        return self.runner([str(COMMAND_ROOT / name), *args], timeout=timeout)[1]

    def private_root(self):
        if self.read_only:
            fail("read_only", "Updates cannot modify a read-only profile.")
        safe_path(self.profile)
        safe_path(self.root)
        self.profile.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.root.mkdir(mode=0o700, exist_ok=True)
        for directory in (self.profile, self.root):
            info = directory.stat()
            if info.st_uid != os.getuid() or info.st_mode & 0o077:
                fail("unsafe_path", "The update profile and staging directory must be private (mode 0700).")
        if self.source == self.profile or self.source in self.profile.parents:
            fail("unsafe_path", "Update state must live outside the plugin source.")

    @contextmanager
    def locked(self, wait=False):
        self.private_root()
        lock = self.root / "lock"
        safe_path(lock)
        fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            deadline = time.monotonic() + (20 if wait else 0)
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        fail("busy", "Another update operation is in progress.")
                    time.sleep(0.05)
            yield
        finally:
            os.close(fd)

    def load(self):
        if not self.state_path.exists():
            return {}
        state = read_json(self.state_path)
        if not isinstance(state, dict) or state.get("format") != 1:
            fail("invalid_state", "Unsupported updater state; existing state was not overwritten.")
        return state

    def save(self, state):
        state["format"] = 1
        atomic_json(self.state_path, state)

    def manifest(self, path):
        manifest = read_json(path / "manifest.json")
        if not isinstance(manifest, dict) or manifest.get("id") != PLUGIN_ID:
            fail("identity", "The plugin manifest does not identify Daymark.")
        if not isinstance(manifest.get("version"), str) or not VERSION.fullmatch(manifest["version"]):
            fail("identity", "The plugin manifest has no stable semantic version.")
        return manifest

    def identity(self, clean=True):
        safe_path(self.source)
        if self.source != self.installed_root:
            fail("unsupported", "Updates are supported only in the installed Daymark Git checkout, not a development preview.")
        if not (self.source / ".git").is_dir() or (self.source / ".git").is_symlink():
            fail("unsupported", "The installed plugin must be a standalone Git checkout.")
        if self.git(self.source, "rev-parse", "--show-toplevel")[1] != str(self.source):
            fail("identity", "The plugin is not the root of its Git checkout.")
        origins = self.git(self.source, "config", "--get-all", "remote.origin.url")[1].splitlines()
        if origins != [self.repository]:
            fail("identity", "The installed plugin origin does not match the fixed trusted Daymark repository.")
        self.manifest(self.source)
        if clean:
            if self.git(self.source, "status", "--porcelain", "--untracked-files=all")[1]:
                fail("dirty_source", "The installed plugin has local changes; update refused without discarding them.")
            ignored = self.git(self.source, "ls-files", "--others", "--ignored", "--exclude-standard", "-z")[1]
            for filename in ignored.split("\0"):
                if filename and not ("__pycache__" in Path(filename).parts and filename.endswith(".pyc")):
                    fail("dirty_source", "The installed plugin contains ignored user files; update refused without discarding them.")
        commit = self.git(self.source, "rev-parse", "HEAD")[1]
        if not SHA.fullmatch(commit):
            fail("identity", "The installed commit is not a full Git SHA-1 identity.")
        return commit

    def reconcile(self, state):
        """Report a lost worker without inventing success or retrying its approval."""
        if (self.read_only or state.get("phase") != "installing"
                or self.clock() - state.get("workerStartedAt", self.clock()) < 30000):
            return state
        token = state.get("token", "")
        if not re.fullmatch(r"[0-9a-f]{32}", token):
            fail("invalid_state", "The recorded worker identity is invalid.")
        try:
            _, active = self.runner(["/usr/bin/systemctl", "--user", "show",
                                      "daymark-update-" + token + ".service",
                                      "--property=ActiveState", "--value"], timeout=5, allowed=(0, 1, 4))
        except (UpdateError, OSError):
            return state  # An unavailable user manager does not prove worker death.
        if active in ("active", "activating", "reloading"):
            return state
        with self.locked():
            current = self.load()
            if current.get("token") != token or current.get("phase") != "installing":
                return current
            current.update(phase="idle", recoveryRequired=True,
                           message="The approved update worker was interrupted. Installation and activation are unverified; private backups and both code trees were retained. Recovery is required before another update.")
            current.pop("prepared", None)
            current.pop("token", None)
            self.save(current)
            return current

    def result(self, state=None):
        state = self.reconcile(self.load()) if state is None else state
        supported = True
        reason = ""
        try:
            self.identity()
        except (UpdateError, OSError) as error:
            supported = False
            reason = str(error)
        try:
            version = self.manifest(self.source)["version"]
        except (UpdateError, OSError):
            version = "unknown"
        if self.read_only:
            supported, reason = False, "Updates are unavailable in a read-only profile."
        if state.get("recoveryRequired"):
            supported, reason = False, state["message"]
        return {"installedVersion": version, "availableVersion": state.get("availableVersion", ""),
                "availableCommit": state.get("availableCommit", ""),
                "lastAttemptAt": state.get("lastAttemptAt", 0),
                "lastCheckedAt": state.get("lastCheckedAt", 0),
                "phase": state.get("phase", "idle"), "supported": supported,
                "message": reason or state.get("message", "Check the latest stable GitHub release. Shell restart approval is required to install.")}

    def validate_candidate(self, candidate, commit, version):
        safe_path(candidate)
        if self.git(candidate, "rev-parse", "HEAD")[1] != commit:
            fail("candidate_changed", "The prepared candidate no longer matches the approved commit.")
        if self.git(candidate, "status", "--porcelain", "--untracked-files=all", "--ignored")[1]:
            fail("candidate_changed", "The prepared candidate has been modified.")
        if self.git(candidate, "config", "--get-all", "remote.origin.url")[1] != self.repository:
            fail("candidate_changed", "The candidate origin has changed.")
        if self.manifest(candidate)["version"].removeprefix("v") != version:
            fail("release_invalid", "The release tag and candidate manifest version disagree.")
        # Installed schema validator is trusted; no candidate code is executed.
        self.command("omarchy-plugin-validate", str(candidate))

    def check(self):
        with self.locked():
            state = self.load()
            if state.get("recoveryRequired"):
                fail("recovery_required", state["message"])
            if state.get("phase") == "installing":
                fail("busy", "An approved installation is still in progress.")
            previous = state.get("prepared", {}).get("path")
            if previous:
                old_candidate = safe_path(Path(previous))
                if old_candidate.parent != self.root or not old_candidate.name.startswith("candidate-"):
                    fail("invalid_state", "The previous candidate is outside private staging.")
                if old_candidate.exists():
                    shutil.rmtree(old_candidate)
            state.update(lastAttemptAt=self.clock(), phase="idle", availableVersion="",
                         availableCommit="", message="Checking the stable GitHub release.")
            state.pop("prepared", None)
            self.save(state)
            candidate = None
            try:
                installed = self.identity()
                release = self.release_fetcher()
                if (not isinstance(release, dict) or release.get("draft") is not False
                        or release.get("prerelease") is not False
                        or type(release.get("id")) is not int or release["id"] <= 0
                        or not isinstance(release.get("tag_name"), str)
                        or not VERSION.fullmatch(release["tag_name"])):
                    fail("release_invalid", "GitHub did not declare a valid stable latest release.")
                tag = release["tag_name"]
                if release.get("html_url") != "https://github.com/naolselemon/daymark/releases/tag/" + tag:
                    fail("release_identity", "The release does not belong to the fixed Daymark repository.")
                version = tag.removeprefix("v")
                candidate = Path(tempfile.mkdtemp(prefix="candidate-", dir=self.root))
                self.git(candidate, "init", "--quiet")
                self.git(candidate, "remote", "add", "origin", self.repository)
                self.git(candidate, "fetch", "--quiet", "--no-tags", "origin",
                         "refs/tags/" + tag + ":refs/tags/" + tag)
                commit = self.git(candidate, "rev-parse", "refs/tags/" + tag + "^{commit}")[1]
                if not SHA.fullmatch(commit):
                    fail("release_invalid", "The release tag does not resolve to a full commit.")
                # Import installed history into the isolated repository, never mutate source.
                self.git(candidate, "fetch", "--quiet", "--no-tags", str(self.source), "HEAD")
                self.git(candidate, "checkout", "--quiet", "--detach", commit)
                self.validate_candidate(candidate, commit, version)
                state.update(lastCheckedAt=self.clock(), availableVersion=version, availableCommit=commit)
                if self.git(candidate, "merge-base", "--is-ancestor", commit, installed, allowed=(0, 1))[0] == 0:
                    state.update(phase="current", message="Installed code already contains the declared latest stable release.")
                elif self.git(candidate, "merge-base", "--is-ancestor", installed, commit, allowed=(0, 1))[0] != 0:
                    fail("diverged", "Installed code and the stable release diverge; automatic replacement is unsafe.")
                elif tuple(map(int, version.split("."))) < tuple(map(int, self.manifest(self.source)["version"].removeprefix("v").split("."))):
                    fail("downgrade", "The declared stable release would downgrade the installed version.")
                else:
                    state.update(phase="ready", message="Stable release prepared and validated. Explicit whole-shell restart approval is required.",
                                 prepared={"path": str(candidate), "commit": commit, "version": version,
                                           "installed": installed})
                    candidate = None
                self.save(state)
                return self.result(state)
            except Exception as error:
                state.update(phase="idle", message=str(error), availableCommit="", availableVersion="")
                state.pop("prepared", None)
                self.save(state)
                raise
            finally:
                if candidate is not None:
                    shutil.rmtree(candidate)

    def countdown_idle(self):
        path = self.profile / "countdown.sqlite3"
        safe_path(path)
        if not path.exists():
            return
        with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=1)) as db:
            row = db.execute("SELECT status FROM countdown WHERE id=1").fetchone()
            if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='log_intents'").fetchone():
                if db.execute("SELECT 1 FROM log_intents WHERE result='' LIMIT 1").fetchone():
                    fail("countdown_active", "Resolve the pending countdown entry before updating.")
        if row is None or row[0] not in ("idle", "finished"):
            fail("countdown_active", "Cancel the active or paused countdown before updating.")

    def prepared(self, state, commit):
        plan = state.get("prepared")
        if (not isinstance(plan, dict) or plan.get("commit") != commit
                or state.get("availableCommit") != commit):
            fail("approval_stale", "Approval no longer matches the prepared release; check and approve again.")
        candidate = safe_path(Path(plan["path"]))
        if candidate.parent != self.root or not candidate.name.startswith("candidate-"):
            fail("invalid_state", "The prepared candidate is outside private staging.")
        if self.identity() != plan["installed"]:
            fail("approval_stale", "The installed commit changed after preparation.")
        self.validate_candidate(candidate, commit, plan["version"])
        self.countdown_idle()
        return candidate

    def install(self, args):
        if (set(args) != {"commit", "restartApproved"} or args.get("restartApproved") is not True
                or not isinstance(args.get("commit"), str) or not SHA.fullmatch(args["commit"])):
            fail("approval_required", "Installation requires explicit restart approval bound to a full prepared commit.")
        with self.locked():
            state = self.load()
            if state.get("phase") != "ready":
                fail("approval_stale", "There is no prepared release awaiting approval.")
            self.prepared(state, args["commit"])
            token = uuid.uuid4().hex
            worker = self.root / ("worker-" + token + ".py")
            # Copy the currently executing trusted engine, not the new release's engine.
            with open(__file__, "rb") as source, open(worker, "xb") as target:
                os.chmod(worker, 0o600)
                shutil.copyfileobj(source, target)
                target.flush()
                os.fsync(target.fileno())
            state.update(phase="installing", token=token, source=str(self.source),
                         message="Approved update is installing in an independent worker.", workerStartedAt=self.clock())
            self.save(state)
            try:
                self.launcher(worker, token)
            except Exception as error:
                state.update(phase="ready", message="Could not launch update worker: " + str(error))
                state.pop("token", None)
                self.save(state)
                raise
            return self.result(state)

    def launch_worker(self, worker, token):
        # A new user-manager service survives both Quickshell child teardown and its
        # service cgroup being stopped. setsid alone would not provide that guarantee.
        self.runner(["/usr/bin/systemd-run", "--user", "--quiet", "--collect",
                     "--unit=daymark-update-" + token, "--property=Type=exec",
                     "--property=RuntimeMaxSec=600", "--property=TimeoutStopSec=5", "--",
                     "/usr/bin/python3", "-I", str(worker), "--worker", str(self.profile), token], timeout=15)

    def activation(self):
        config = json.loads(self.command("omarchy-shell", "shell", "listShellConfig"))
        plugins = json.loads(self.command("omarchy-plugin-list", "--json"))
        matches = [entry for entry in plugins if entry.get("id") == PLUGIN_ID]
        if len(matches) != 1 or type(matches[0].get("enabled")) is not bool:
            fail("activation", "The shell cannot report a unique Daymark activation state.")
        placements = []
        layout = config.get("bar", {}).get("layout", {})
        for section in SECTIONS:
            for index, entry in enumerate(layout.get(section, [])):
                identifier = entry.get("id") if isinstance(entry, dict) else entry
                if identifier == PLUGIN_ID:
                    placements.append([section, index, entry])
        services = [[index, entry] for index, entry in enumerate(config.get("plugins", []))
                    if (entry.get("id") if isinstance(entry, dict) else entry) == PLUGIN_ID]
        return {"enabled": matches[0]["enabled"], "placements": placements,
                "services": services, "disabled": PLUGIN_ID in config.get("disabledPlugins", [])}

    def shell_configuration(self):
        _, environment = self.runner(["/usr/bin/systemctl", "--user", "show-environment"], timeout=5)
        roots = [line[len("OMARCHY_PATH="):] for line in environment.splitlines()
                 if line.startswith("OMARCHY_PATH=")]
        root = roots[-1] if roots else os.environ.get("OMARCHY_PATH", str(COMMAND_ROOT.parent))
        if not Path(root).is_absolute():
            fail("quiescence", "The session shell configuration path is not absolute.")
        return str((Path(root) / "shell/shell.qml").resolve())

    def shell_instances(self, configuration):
        _, text = self.runner(["/usr/bin/quickshell", "list", "-a", "-j"], timeout=5)
        # Quickshell emits this non-JSON sentinel even with -j when none remain.
        # Do not treat empty or arbitrary malformed output as a stopped shell.
        instances = [] if text.strip() == "No running instances." else json.loads(text)
        if not isinstance(instances, list):
            fail("quiescence", "Quickshell did not report its running instances.")
        for instance in instances:
            if (not isinstance(instance, dict) or not isinstance(instance.get("id"), str)
                    or not instance["id"] or type(instance.get("pid")) is not int
                    or instance["pid"] <= 0 or instance.get("config_path") != configuration):
                fail("quiescence", "Other or unidentified Quickshell instances are running. Close previews before updating; they will not be stopped automatically.")
        if len(instances) > 1:
            fail("quiescence", "Multiple desktop shell instances are running; automatic replacement is unsafe.")
        return instances

    def require_quiescent(self, configuration):
        if self.shell_instances(configuration):
            fail("quiescence", "The desktop shell is still running; no code may be exchanged.")

    def quiesce(self, configuration):
        instances = self.shell_instances(configuration)
        if not instances:
            return
        locked, _ = self.runner([str(COMMAND_ROOT / "omarchy-hyprland-session-locked")],
                                timeout=5, allowed=(0, 1, 2))
        if locked != 1:
            fail("session_locked", "The session is locked or its lock state is unknown; the desktop shell was not stopped.")
        lock = json.loads(self.command("omarchy-shell", "lock", "status", timeout=5))
        if (not isinstance(lock, dict) or lock.get("secure") is not False
                or lock.get("requested") is not False):
            fail("session_locked", "A session lock is active or pending; the desktop shell was not stopped.")
        # Re-resolve immediately before stopping: never kill a newly substituted instance.
        if self.shell_instances(configuration) != instances:
            fail("quiescence", "The desktop shell instance changed during restart preparation.")
        try:
            # Instance IDs are global; --any-display belongs to the mutually
            # exclusive configuration-selection group.
            self.runner(["/usr/bin/quickshell", "kill", "--id", instances[0]["id"]], timeout=30)
            deadline = self.monotonic() + 30
            while self.shell_instances(configuration):
                if self.monotonic() >= deadline:
                    fail("quiescence", "The desktop shell did not stop before the deadline; code was not exchanged.")
                self.sleep(0.1)
        except Exception as error:
            error.shell_stop_requested = True
            raise

    def runtime_ready(self, activation):
        if not activation["enabled"] and not activation["services"]:
            return
        deadline = self.monotonic() + 30
        while True:
            try:
                ready = json.loads(self.command("omarchy-shell", PLUGIN_ID, "updateReadiness", timeout=5))
                if (isinstance(ready, dict) and type(ready.get("protocol")) is int
                        and ready["protocol"] == 1 and ready.get("ready") is True
                        and ready.get("source") == str(self.source)
                        and (not activation["placements"] or ready.get("barReady") is True)):
                    return
            except (UpdateError, OSError, ValueError):
                pass
            if self.monotonic() >= deadline:
                fail("runtime_readiness", "Daymark did not report loaded, ready components from the installed source after restart.")
            self.sleep(0.25)

    def verify_activation(self, activation):
        if self.activation() != activation:
            fail("activation", "Daymark activation or exact placement was not preserved after restart.")
        self.runtime_ready(activation)
        if self.activation() != activation:
            fail("activation", "Daymark activation changed while waiting for runtime readiness.")

    @staticmethod
    def backup_fingerprint(directory):
        fingerprint = {}
        for path in directory.iterdir():
            with open(path, "rb") as stream:
                fingerprint[path.name] = hashlib.file_digest(stream, "sha256").digest()
        return fingerprint

    def backup(self, destination):
        destination.mkdir(mode=0o700)
        for source in self.profile.iterdir():
            if source == self.root:
                continue
            safe_path(source)
            if not source.is_file():
                fail("backup", "A profile entry is not a regular file; update refused before replacement.")
            if source.name.endswith(("-wal", "-shm", "-journal")):
                continue
            target = destination / source.name
            with open(source, "rb") as stream:
                sqlite = stream.read(16) == b"SQLite format 3\x00"
            if sqlite:
                with closing(sqlite3.connect(source.as_uri() + "?mode=ro", uri=True, timeout=1)) as db, \
                        closing(sqlite3.connect(target)) as saved:
                    deadline = time.monotonic() + 30
                    def progress(status, remaining, total):
                        if time.monotonic() > deadline:
                            fail("backup", "Database backup timed out; no code was replaced.")
                    db.backup(saved, pages=256, progress=progress)
                    if saved.execute("PRAGMA quick_check").fetchone() != ("ok",):
                        fail("backup", "Database backup did not pass its integrity check.")
            else:
                shutil.copyfile(source, target)
            os.chmod(target, 0o600)
            with open(target, "rb") as stream:
                os.fsync(stream.fileno())
        sync_directory(destination)

    def work(self, token):
        with self.locked(wait=True):
            state = self.load()
            if state.get("phase") != "installing" or state.get("token") != token:
                fail("approval_stale", "The detached worker no longer owns this approval.")
            swapped = False
            stopped = False
            candidate = None
            activation = None
            configuration = None
            try:
                candidate = self.prepared(state, state["availableCommit"])
                if candidate.stat().st_dev != self.source.stat().st_dev:
                    fail("unsupported", "Private staging and installed code must share a filesystem for atomic replacement.")
                activation = self.activation()
                configuration = self.shell_configuration()
                backup = self.root / ("backup-" + token)
                self.backup(backup)
                state.update(backup=str(backup), activation=activation, boundary="before_stop")
                self.save(state)
                self.prepared(state, state["availableCommit"])
                if self.activation() != activation:
                    fail("activation_changed", "Daymark activation changed during preparation; update cancelled.")
                try:
                    self.quiesce(configuration)
                except Exception as error:
                    stopped = bool(getattr(error, "shell_stop_requested", False))
                    raise
                stopped = True
                state["boundary"] = "quiescent"
                self.save(state)
                self.prepared(state, state["availableCommit"])
                self.require_quiescent(configuration)
                try:
                    self.exchanger(self.source, candidate)
                except Exception as error:
                    swapped = bool(getattr(error, "exchanged", False))
                    raise
                swapped = True
                state["boundary"] = "after_exchange"
                self.save(state)
                self.command("omarchy-restart-shell", timeout=180)
                stopped = False
                self.verify_activation(activation)
                if self.identity() != state["availableCommit"]:
                    fail("install_failed", "The installed commit differs from the approved release.")
                state.update(phase="updated", message="Stable release installed; shell restarted and Daymark runtime readiness and exact activation verified.",
                             rollbackSource=str(candidate), boundary="complete")
                state.pop("prepared", None)
                state.pop("token", None)
                self.save(state)
            except Exception as error:
                message = "Update failed: " + str(error)
                if swapped:
                    restarted = False
                    try:
                        # Never move either tree under a live native plugin watcher.
                        self.quiesce(configuration)
                        failed = self.root / ("failed-profile-" + token)
                        self.backup(failed)
                        state["failedBackup"] = str(failed)
                        self.save(state)
                        unchanged = self.backup_fingerprint(backup) == self.backup_fingerprint(failed)
                        if unchanged:
                            self.require_quiescent(configuration)
                            self.exchanger(self.source, candidate)
                            restarted = True
                            self.command("omarchy-restart-shell", timeout=180)
                            if self.identity() != state["prepared"]["installed"]:
                                fail("rollback", "Original commit could not be verified.")
                            self.verify_activation(activation)
                            message += " Original code restored only after confirming the profile was unchanged; original runtime readiness and activation verified. Profile data was NOT rolled back."
                        else:
                            # The new code may have migrated or written the profile.
                            # Restart that same generation to restore the desktop,
                            # never run old code against unverified newer data.
                            restarted = True
                            self.command("omarchy-restart-shell", timeout=180)
                            message += " Profile changed: no code or data rollback was attempted. Candidate code remains installed and the desktop shell was restarted; Daymark remains unverified."
                    except Exception as rollback_error:
                        message += " RECOVERY INCOMPLETE: " + str(rollback_error) + "."
                        if "failedBackup" not in state:
                            failed = self.root / ("failed-profile-" + token)
                            try:
                                self.backup(failed)
                                state["failedBackup"] = str(failed)
                            except Exception as backup_error:
                                message += " Failed-state profile snapshot could not be completed: " + str(backup_error) + "."
                        if not restarted:
                            try:
                                self.command("omarchy-restart-shell", timeout=180)
                                message += " Current code's desktop shell was restarted without claiming Daymark readiness."
                            except Exception as restart_error:
                                message += " Desktop shell restart also failed: " + str(restart_error) + "."
                    state["recoveryRequired"] = True
                    state["rollbackSource"] = str(candidate)
                    message += " Both code trees and available before/failed-state profile backups are retained. Recovery is required before another update."
                elif stopped:
                    try:
                        self.command("omarchy-restart-shell", timeout=180)
                        self.verify_activation(activation)
                        message += " Original desktop shell restarted; no code or data was replaced."
                    except Exception as restart_error:
                        state["recoveryRequired"] = True
                        message += " Original shell recovery failed: " + str(restart_error) + "."
                if state.get("recoveryRequired"):
                    state["recoveryCommand"] = str(COMMAND_ROOT / "omarchy-restart-shell")
                    message += " Recovery command: " + state["recoveryCommand"] + ". Backups: " + str(state.get("backup", "unavailable")) + "; " + str(state.get("failedBackup", "not completed")) + "."
                state.update(phase="idle", message=message, boundary="failed", availableCommit="", availableVersion="")
                state.pop("prepared", None)
                state.pop("token", None)
                self.save(state)
                raise UpdateError("install_failed", message) from error

    def handle(self, request):
        if (not isinstance(request, dict) or type(request.get("protocol")) is not int
                or request["protocol"] != 1 or not isinstance(request.get("requestId"), str)
                or not request["requestId"] or not isinstance(request.get("args"), dict)):
            fail("protocol", "Expected a protocol:1 request with requestId and object args.")
        op, args = request.get("op"), request["args"]
        if op == "update_install":
            return self.install(args)
        if args:
            fail("validation", "Status and check operations accept no arguments.")
        if op == "update_status":
            return self.result()
        if op == "update_check":
            return self.check()
        fail("operation", "Unknown updater operation.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path)
    parser.add_argument("--read-only", action="store_true")
    parser.add_argument("--worker", nargs=2, metavar=("PROFILE", "TOKEN"), help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    request = {}
    try:
        if args.worker:
            profile, token = args.worker
            if args.profile or args.read_only or not re.fullmatch(r"[0-9a-f]{32}", token):
                fail("protocol", "Invalid detached worker invocation.")
            state = read_json(safe_path(Path(profile)) / "updater/state.json")
            updater = Updater(profile, source=Path(state["source"]))
            updater.work(token)
            return 0
        if args.profile is None:
            fail("protocol", "An absolute --profile is required.")
        raw = sys.stdin.buffer.read(LIMIT + 1)
        if len(raw) > LIMIT:
            fail("protocol", "Updater request exceeds the size limit.")
        request = json.loads(raw)
        result = Updater(args.profile, args.read_only).handle(request)
        response = {"protocol": 1, "requestId": request["requestId"], "ok": True, "result": result}
    except Exception as error:
        response = {"protocol": 1, "requestId": request.get("requestId", "") if isinstance(request, dict) else "",
                    "ok": False, "error": {"code": getattr(error, "code", "updater"), "message": str(error)}}
        if args.worker:
            print(json.dumps(response), file=sys.stderr)
            return 1
    print(json.dumps(response, ensure_ascii=True, allow_nan=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
