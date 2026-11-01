#!/usr/bin/env python3
"""Private notification JSON on stdin; only a selected default action on stdout."""

from contextlib import contextmanager
import ctypes
import json
import os
import signal
import sys


MAX_INPUT_BYTES = 16 * 1024
MAX_TIMEOUT_MS = 60000
DEADLINE_SECONDS = 64
STRING_LIMITS = {"title": 4096, "icon": 4096, "action": 256}
ERROR_MESSAGE = "The desktop notification could not be completed safely.\n"


class NotificationError(Exception):
    """A notification failed without exposing its contents."""


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise NotificationError()
        result[key] = value
    return result


def reject_constant(value):
    raise NotificationError()


def read_request(stream):
    """Read at most 16 KiB plus an overflow sentinel, then validate UTF-8 JSON."""
    data = stream.read(MAX_INPUT_BYTES + 1)
    if len(data) > MAX_INPUT_BYTES:
        raise NotificationError()
    try:
        request = json.loads(data.decode("utf-8"), object_pairs_hook=unique_object,
                             parse_constant=reject_constant)
        if not isinstance(request, dict) or set(request) != set(STRING_LIMITS) | {"timeoutMs"}:
            raise NotificationError()
        for key, limit in STRING_LIMITS.items():
            value = request[key]
            if not isinstance(value, str) or not 1 <= len(value) <= limit or "\0" in value:
                raise NotificationError()
            # JSON permits escaped lone surrogates, but libnotify requires UTF-8.
            value.encode("utf-8")
        timeout = request["timeoutMs"]
        if type(timeout) is not int or not 1 <= timeout <= MAX_TIMEOUT_MS:
            raise NotificationError()
    except (UnicodeError, ValueError, RecursionError):
        raise NotificationError() from None
    return request


def arm_deadline(seconds=DEADLINE_SECONDS):
    """Use a kernel-enforced deadline, including blocked stdin and native calls.

    A Python signal handler cannot interrupt a blocked ctypes call reliably.
    The default SIGALRM disposition terminates even while native code is stuck.
    This function belongs only in the short-lived helper process.
    """
    if not 0 < seconds <= DEADLINE_SECONDS:
        raise NotificationError()
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.setitimer(signal.ITIMER_REAL, seconds)


@contextmanager
def quiet_native_output():
    """Discard native diagnostics rather than risking private text in logs."""
    saved = []
    try:
        with open(os.devnull, "wb") as sink:
            for descriptor in (1, 2):
                original = os.dup(descriptor)
                saved.append((descriptor, original))
                os.dup2(sink.fileno(), descriptor)
        yield
    finally:
        for descriptor, original in reversed(saved):
            try:
                os.dup2(original, descriptor)
            finally:
                os.close(original)


VOID = ctypes.c_void_p
TEXT = ctypes.c_char_p
INT = ctypes.c_int
UINT = ctypes.c_uint
ULONG = ctypes.c_ulong
ERROR = ctypes.POINTER(VOID)
ACTION_CALLBACK = ctypes.CFUNCTYPE(None, VOID, TEXT, VOID)
CLOSED_CALLBACK = ctypes.CFUNCTYPE(None, VOID, VOID)
TIMEOUT_CALLBACK = ctypes.CFUNCTYPE(INT, VOID)


class NativeLibraries:
    """Signatures from libnotify/notification.h and GLib/GObject headers."""

    def __init__(self):
        # These are the existing notify-send runtime dependencies, not Python packages.
        self.notify = ctypes.CDLL("libnotify.so.4")
        self.glib = ctypes.CDLL("libglib-2.0.so.0")
        self.gobject = ctypes.CDLL("libgobject-2.0.so.0")
        for library, declarations in (
            (self.notify, (
                ("notify_init", INT, (TEXT,)),
                ("notify_uninit", None, ()),
                ("notify_notification_new", VOID, (TEXT, TEXT, TEXT)),
                ("notify_notification_set_timeout", None, (VOID, INT)),
                ("notify_notification_set_urgency", None, (VOID, INT)),
                ("notify_notification_set_hint", None, (VOID, TEXT, VOID)),
                ("notify_notification_add_action", None,
                 (VOID, TEXT, TEXT, ACTION_CALLBACK, VOID, VOID)),
                ("notify_notification_clear_actions", None, (VOID,)),
                ("notify_notification_show", INT, (VOID, ERROR)),
                ("notify_notification_close", INT, (VOID, ERROR)),
            )),
            (self.glib, (
                ("g_main_loop_new", VOID, (VOID, INT)),
                ("g_main_loop_run", None, (VOID,)),
                ("g_main_loop_quit", None, (VOID,)),
                ("g_main_loop_unref", None, (VOID,)),
                ("g_timeout_add", UINT, (UINT, TIMEOUT_CALLBACK, VOID)),
                ("g_source_remove", INT, (UINT,)),
                ("g_variant_new_boolean", VOID, (INT,)),
                ("g_error_free", None, (VOID,)),
            )),
            (self.gobject, (
                ("g_signal_connect_data", ULONG, (VOID, TEXT, CLOSED_CALLBACK, VOID, VOID, INT)),
                ("g_signal_handler_disconnect", None, (VOID, ULONG)),
                ("g_object_unref", None, (VOID,)),
            )),
        ):
            for name, result, arguments in declarations:
                function = getattr(library, name)
                function.restype = result
                function.argtypes = arguments


def send_notification(request):
    """Show one validated request, returning 'default' or a quiet empty result."""
    native = NativeLibraries()
    notify, glib, gobject = native.notify, native.glib, native.gobject
    if not notify.notify_init(b"Daymark"):
        raise NotificationError()
    notification = loop = None
    source_id = handler_id = 0
    finished = closed = False
    result = ""

    def finish():
        nonlocal finished
        finished = True
        glib.g_main_loop_quit(loop)

    @ACTION_CALLBACK
    def on_action(instance, action, data):
        nonlocal result
        if not finished and action == b"default":
            result = "default"
            finish()

    @CLOSED_CALLBACK
    def on_closed(instance, data):
        nonlocal closed
        closed = True
        finish()

    @TIMEOUT_CALLBACK
    def on_timeout(data):
        nonlocal source_id
        source_id = 0  # Returning false removes this source; do not remove it twice.
        finish()
        return 0

    def checked_call(function):
        error = VOID()
        try:
            if not function(notification, ctypes.byref(error)):
                raise NotificationError()
        finally:
            if error:
                # GError messages can contain server-supplied private content.
                glib.g_error_free(error)

    try:
        loop = glib.g_main_loop_new(None, 0)
        if not loop:
            raise NotificationError()
        notification = notify.notify_notification_new(request["title"].encode("utf-8"), b"",
                                                       request["icon"].encode("utf-8"))
        if not notification:
            raise NotificationError()
        notify.notify_notification_set_timeout(notification, request["timeoutMs"])
        notify.notify_notification_set_urgency(notification, 1)  # NOTIFY_URGENCY_NORMAL
        for hint in (b"transient", b"suppress-sound"):
            # set_hint consumes the floating reference returned by new_boolean.
            notify.notify_notification_set_hint(notification, hint, glib.g_variant_new_boolean(1))
        notify.notify_notification_add_action(notification, b"default", request["action"].encode("utf-8"),
                                              on_action, None, None)
        handler_id = gobject.g_signal_connect_data(notification, b"closed", on_closed, None, None, 0)
        if not handler_id:
            raise NotificationError()
        # Start before show: a slow D-Bus reply must not extend the action window.
        source_id = glib.g_timeout_add(request["timeoutMs"], on_timeout, None)
        if not source_id:
            raise NotificationError()
        checked_call(notify.notify_notification_show)
        if not finished:
            glib.g_main_loop_run(loop)
        if not closed:
            checked_call(notify.notify_notification_close)
        return result
    finally:
        if source_id:
            glib.g_source_remove(source_id)
        if notification:
            if handler_id:
                gobject.g_signal_handler_disconnect(notification, handler_id)
            notify.notify_notification_clear_actions(notification)
            gobject.g_object_unref(notification)
        if loop:
            glib.g_main_loop_unref(loop)
        notify.notify_uninit()
        # The three CFUNCTYPE callback objects stay alive until all native owners
        # above have been disconnected/released, including failure paths.


def main():
    try:
        arm_deadline()
        request = read_request(sys.stdin.buffer)
        with quiet_native_output():
            result = send_notification(request)
        if result:
            sys.stdout.write(result + "\n")
            sys.stdout.flush()
        return 0
    except Exception:
        # Never print exception text, payloads, native errors, or tracebacks.
        sys.stderr.write(ERROR_MESSAGE)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
