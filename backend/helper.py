#!/usr/bin/env python3
"""One JSON line in, one JSON response out; no background service."""

import argparse
import json
import sqlite3
import sys

# Omarchy watches plugin files; bytecode writes would unload the live journal.
if __name__ == "__main__":
    sys.dont_write_bytecode = True

try:
    from .storage import Store, StoreError, storage_error, validate_request
except ImportError:
    from storage import Store, StoreError, storage_error, validate_request


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError("nonfinite number")


def main():
    parser = argparse.ArgumentParser(description="Daymark local SQLite helper")
    parser.add_argument("--profile", help="Absolute data profile outside the source tree")
    parser.add_argument("--read-only", action="store_true")
    options = parser.parse_args()
    request_id = ""
    try:
        try:
            line = sys.stdin.buffer.readline().decode("utf-8")
            if sys.stdin.buffer.read().strip():
                raise ValueError("more than one request")
            request = json.loads(line, object_pairs_hook=unique_object, parse_constant=reject_constant)
        except (UnicodeError, ValueError, RecursionError):
            raise StoreError("protocol", "Send one valid UTF-8 JSON request line.") from None
        if isinstance(request, dict) and isinstance(request.get("requestId"), str):
            try:
                request["requestId"].encode("utf-8")
                request_id = request["requestId"]
            except UnicodeEncodeError:
                pass
        validate_request(request)
        with Store(options.profile, options.read_only) as store:
            response = store.handle(request)
    except StoreError as error:
        response = {"protocol": 1, "requestId": request_id, "ok": False, "error": error.wire()}
    except (sqlite3.Error, OSError) as error:
        response = {"protocol": 1, "requestId": request_id, "ok": False, "error": storage_error(error).wire()}
    except Exception:
        # Do not expose SQL, paths, titles, notes, or tracebacks through diagnostics.
        response = {"protocol": 1, "requestId": request_id, "ok": False,
                    "error": {"code": "storage", "message": "The request could not be completed safely. No success was confirmed."}}
    sys.stdout.write(json.dumps(response, ensure_ascii=True, allow_nan=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
