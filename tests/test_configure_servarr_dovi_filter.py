import json
import os
import stat
import tempfile
import threading
import unittest
import urllib.error
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from tools import configure_servarr_dovi_filter as configure


class RecordingHTTPServer:
    def __init__(self):
        self.requests = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, _format, *_args):
                return

            def do_GET(self):
                owner.requests.append((self.path, self.headers.get("X-Api-Key")))
                body = b"{}"
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server.server_port}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


class RedirectHTTPServer:
    def __init__(self, target_url):
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, _format, *_args):
                return

            def do_GET(self):
                self.send_response(302)
                self.send_header("Location", f"{target_url}/redirected")
                self.end_headers()

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server.server_port}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


class FixedDatetime(datetime):
    @classmethod
    def now(cls, tz=None):
        return cls(2026, 7, 11, 12, 34, 56, tzinfo=tz)


class ConfigureServarrDoviFilterTests(unittest.TestCase):
    def setUp(self):
        self.instance = {
            "kind": "sonarr",
            "label": "PlexTV",
            "url": "http://sonarr.test",
            "api_key": "secret",
        }
        self.custom_format = {"id": 12, "name": configure.FORMAT_NAME}
        self.profile = {
            "id": 34,
            "name": "UHD",
            "items": [{"allowed": True, "quality": {"name": "WEBDL-2160p"}}],
            "formatItems": [
                {
                    "format": 12,
                    "name": configure.FORMAT_NAME,
                    "score": configure.DEFAULT_SCORE,
                }
            ],
        }

    def test_custom_format_payload_uses_kind_specific_web_sources(self):
        sonarr = configure.custom_format_payload("sonarr")
        radarr = configure.custom_format_payload("radarr")

        def source_values(payload):
            return [
                item["fields"][0]["value"]
                for item in payload["specifications"]
                if item["implementation"] == "SourceSpecification"
            ]

        self.assertEqual(source_values(sonarr), [3, 4])
        self.assertEqual(source_values(radarr), [7, 8])
        dolby = sonarr["specifications"][0]
        self.assertTrue(dolby["required"])
        self.assertFalse(dolby["negate"])

    def test_2160_profile_selection_honours_allowed_nested_qualities(self):
        profile = {
            "items": [
                {
                    "allowed": True,
                    "items": [
                        {"allowed": False, "quality": {"name": "WEBDL-2160p"}},
                        {"allowed": True, "quality": {"name": "Bluray-1080p"}},
                    ],
                }
            ]
        }
        self.assertFalse(configure.has_2160(profile))
        profile["items"][0]["items"][1]["quality"]["name"] = "Bluray-2160p"
        self.assertTrue(configure.has_2160(profile))

    def test_dry_run_only_reads_and_reports_intended_changes(self):
        requests = []

        def fake_request(_url, _key, method, endpoint, payload=None):
            requests.append((method, endpoint, payload))
            if endpoint == "/api/v3/customformat":
                return []
            if endpoint == "/api/v3/qualityprofile":
                return [self.profile]
            self.fail(f"unexpected request: {method} {endpoint}")

        with patch.object(configure, "api_request", side_effect=fake_request):
            messages = configure.configure_instance(
                self.instance, configure.DEFAULT_SCORE, apply=False
            )

        self.assertIn("would create", messages[0])
        self.assertIn("would apply", messages[1])
        self.assertEqual(
            [(method, endpoint) for method, endpoint, _payload in requests],
            [
                ("GET", "/api/v3/customformat"),
                ("GET", "/api/v3/qualityprofile"),
            ],
        )

    def test_apply_reuses_backup_snapshot_and_skips_unchanged_profile_put(self):
        requests = []

        def fake_request(_url, _key, method, endpoint, payload=None):
            requests.append((method, endpoint, payload))
            if endpoint == "/api/v3/customformat":
                return [self.custom_format]
            if endpoint == "/api/v3/qualityprofile":
                return [self.profile]
            if endpoint == "/api/v3/customformat/12":
                return self.custom_format
            self.fail(f"unexpected request: {method} {endpoint}")

        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(configure, "api_request", side_effect=fake_request),
        ):
            snapshots = configure.collect_state([self.instance])
            backup = configure.backup_state(
                [self.instance], Path(directory), snapshots=snapshots
            )
            messages = configure.configure_instance(
                self.instance,
                configure.DEFAULT_SCORE,
                apply=True,
                snapshot=snapshots[("sonarr", "PlexTV")],
            )
            self.assertTrue(backup.exists())
            payload = json.loads(backup.read_text(encoding="utf-8"))
            self.assertNotIn("baseUrl", payload["instances"][0])
            if os.name == "posix":
                self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o600)

        self.assertIn("applied score", messages[-1])
        self.assertEqual(
            [(method, endpoint) for method, endpoint, _payload in requests],
            [
                ("GET", "/api/v3/customformat"),
                ("GET", "/api/v3/qualityprofile"),
                ("PUT", "/api/v3/customformat/12"),
            ],
        )

    def test_apply_updates_profile_when_score_changes(self):
        profile = {
            **self.profile,
            "formatItems": [{"format": 12, "name": configure.FORMAT_NAME, "score": 0}],
        }
        requests = []

        def fake_request(_url, _key, method, endpoint, payload=None):
            requests.append((method, endpoint, payload))
            if endpoint == "/api/v3/customformat/12":
                return self.custom_format
            if endpoint == "/api/v3/qualityprofile/34":
                return profile
            self.fail(f"unexpected request: {method} {endpoint}")

        snapshot = {
            "customFormats": [self.custom_format],
            "qualityProfiles": [profile],
        }
        with patch.object(configure, "api_request", side_effect=fake_request):
            configure.configure_instance(
                self.instance,
                configure.DEFAULT_SCORE,
                apply=True,
                snapshot=snapshot,
            )

        profile_puts = [
            request
            for request in requests
            if request[1].startswith("/api/v3/qualityprofile/")
        ]
        self.assertEqual(len(profile_puts), 1)
        self.assertEqual(
            profile_puts[0][2]["formatItems"][0]["score"], configure.DEFAULT_SCORE
        )

    def test_unconfigured_instances_are_not_collected(self):
        instance = {**self.instance, "api_key": ""}
        with patch.object(configure, "api_request") as request:
            self.assertEqual(configure.collect_state([instance]), {})
        request.assert_not_called()

    def test_api_redirect_is_rejected_without_forwarding_api_key(self):
        target = RecordingHTTPServer()
        redirect = RedirectHTTPServer(target.url)
        self.addCleanup(redirect.close)
        self.addCleanup(target.close)

        with self.assertRaises(urllib.error.HTTPError) as raised:
            configure.api_request(
                redirect.url,
                "credential-must-stay-on-the-original-server",
                "GET",
                "/api/v3/customformat",
            )
        raised.exception.close()

        self.assertEqual(target.requests, [])

    def test_base_url_rejects_unsafe_forms(self):
        unsafe_urls = (
            "file:///tmp/servarr.json",
            "http://user:password@servarr.example.invalid:8989",
            "http://servarr.example.invalid:8989/base?redirect=elsewhere",
            "http://servarr.example.invalid:8989/base#fragment",
            "http://servarr.example.invalid:8989/base?",
            "http://servarr.example.invalid:8989/base#",
        )
        for url in unsafe_urls:
            with self.subTest(url=url), self.assertRaises(ValueError):
                configure.validate_base_url(url)

    def test_backup_collision_and_symlink_are_rejected(self):
        snapshots = {
            ("sonarr", "PlexTV"): {
                "customFormats": [self.custom_format],
                "qualityProfiles": [self.profile],
            }
        }
        token = "a" * 32
        filename = f"servarr-dovi-profile-backup-20260711-123456-{token}.json"

        for collision_kind in ("regular", "symlink"):
            with (
                self.subTest(collision_kind=collision_kind),
                tempfile.TemporaryDirectory() as directory,
            ):
                backup_dir = Path(directory)
                destination = backup_dir / filename
                sentinel = backup_dir / "sentinel.json"
                sentinel.write_text("sentinel-must-not-change", encoding="utf-8")
                if collision_kind == "regular":
                    destination.write_text("existing-must-not-change", encoding="utf-8")
                else:
                    try:
                        destination.symlink_to(sentinel)
                    except OSError:
                        continue

                with (
                    patch.object(configure, "datetime", FixedDatetime),
                    patch.object(configure.secrets, "token_hex", return_value=token),
                    self.assertRaises(FileExistsError),
                ):
                    configure.backup_state(
                        [self.instance], backup_dir, snapshots=snapshots
                    )

                self.assertEqual(
                    sentinel.read_text(encoding="utf-8"), "sentinel-must-not-change"
                )
                if collision_kind == "regular":
                    self.assertEqual(
                        destination.read_text(encoding="utf-8"),
                        "existing-must-not-change",
                    )

    def test_failed_backup_write_or_close_removes_partial_file(self):
        snapshots = {
            ("sonarr", "PlexTV"): {
                "customFormats": [self.custom_format],
                "qualityProfiles": [self.profile],
            }
        }
        token = "b" * 32

        for failure_kind in ("write", "close"):
            with (
                self.subTest(failure_kind=failure_kind),
                tempfile.TemporaryDirectory() as directory,
            ):
                backup_dir = Path(directory)
                real_close = os.close
                close_failed = False

                def close_then_fail(fd):
                    nonlocal close_failed
                    real_close(fd)
                    if not close_failed:
                        close_failed = True
                        raise OSError("injected close failure")

                if failure_kind == "write":
                    failure_patch = patch.object(
                        configure.os,
                        "write",
                        side_effect=OSError("injected write failure"),
                    )
                else:
                    failure_patch = patch.object(
                        configure.os,
                        "close",
                        side_effect=close_then_fail,
                    )

                with (
                    patch.object(configure, "datetime", FixedDatetime),
                    patch.object(configure.secrets, "token_hex", return_value=token),
                    failure_patch,
                    self.assertRaisesRegex(OSError, f"injected {failure_kind} failure"),
                ):
                    configure.backup_state(
                        [self.instance], backup_dir, snapshots=snapshots
                    )

                self.assertEqual(
                    list(backup_dir.glob("servarr-dovi-profile-backup-*.json")),
                    [],
                )


if __name__ == "__main__":
    unittest.main()
