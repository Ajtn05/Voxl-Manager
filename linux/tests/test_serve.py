import copy
import importlib.machinery
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import json
import sys
import tempfile
import io
from contextlib import redirect_stdout

path = Path(__file__).resolve().parents[1] / "voxl-manager-serve"
loader = importlib.machinery.SourceFileLoader("serve_helper", str(path))
spec = importlib.util.spec_from_loader(loader.name, loader)
serve = importlib.util.module_from_spec(spec)
loader.exec_module(serve)

HOST = "mint-server.tail439626.ts.net"
PORT = "8443"
HP = f"{HOST}:{PORT}"
TARGET = "http://127.0.0.1:6901"


class ServePolicyTests(unittest.TestCase):
    def test_manual_proxy_is_reused_without_becoming_owned(self):
        config = {"TCP": {PORT: {"HTTPS": True}},
                  "Web": {HP: {"Handlers": {"/": {"Proxy": TARGET}}}}}
        owned = {}
        self.assertFalse(serve.enable(config, HOST, PORT, 6901, owned))
        self.assertEqual(owned, {})
        self.assertEqual(serve.remove(config, HOST, owned, None), (False, []))
        self.assertEqual(serve.classify(config, HOST, PORT, 6901), ("matched", TARGET))

    def test_add_and_remove_preserve_other_service_and_funnel(self):
        config = {"TCP": {"443": {"HTTPS": True}, "9980": {"TCPForward": "localhost:9870"}},
                  "Web": {f"{HOST}:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8096"}}}},
                  "AllowFunnel": {f"{HOST}:443": True},
                  "Services": {"svc:files": {"Tun": True}},
                  "Foreground": {"session": {"TCP": {"8888": {"HTTP": True}}}}}
        original = copy.deepcopy(config)
        owned = {}
        self.assertTrue(serve.enable(config, HOST, PORT, 6901, owned))
        self.assertEqual(serve.classify(config, HOST, PORT, 6901)[0], "matched")
        self.assertEqual(serve.remove(config, HOST, owned, None), (True, []))
        self.assertEqual(config, original)
        self.assertEqual(owned, {})

    def test_conflicts_and_funnel_never_overwrite(self):
        entries = [
            ({"TCP": {PORT: {"HTTP": True}}}, "conflict"),
            ({"Foreground": {"session": {"TCP": {PORT: {"HTTPS": True}}}}}, "conflict"),
            ({"AllowFunnel": {HP: True}}, "public"),
            ({"TCP": {PORT: {"HTTPS": True}},
              "Web": {HP: {"Handlers": {"/": {"Proxy": "http://127.0.0.1:6902"}}}}}, "mismatch"),
        ]
        for config, expected in entries:
            with self.subTest(expected=expected):
                original = copy.deepcopy(config)
                self.assertEqual(serve.classify(config, HOST, PORT, 6901)[0], expected)
                with self.assertRaises(serve.Refusal):
                    serve.enable(config, HOST, PORT, 6901, {})
                self.assertEqual(config, original)

    def test_remove_preserves_other_path_and_external_replacement(self):
        config, owned = {}, {}
        serve.enable(config, HOST, PORT, 6901, owned)
        serve.enable(config, HOST, "9443", 6901, owned)
        config["Web"][HP]["Handlers"]["/other"] = {"Text": "hello"}
        changed_hp = f"{HOST}:9443"
        config["Web"][changed_hp]["Handlers"]["/"] = {"Proxy": "http://127.0.0.1:1234"}
        self.assertEqual(serve.remove(config, HOST, owned, None), (True, [9443]))
        self.assertEqual(config["Web"][HP]["Handlers"], {"/other": {"Text": "hello"}})
        self.assertEqual(config["TCP"][PORT], {"HTTPS": True})
        self.assertEqual(config["Web"][changed_hp]["Handlers"]["/"]["Proxy"], "http://127.0.0.1:1234")

    def test_write_uses_daemon_etag_and_records_ownership_after_success(self):
        def simulate(args, etag, fail):
            with tempfile.TemporaryDirectory() as directory:
                state = Path(directory)
                policy = state / "policy.json"
                policy.write_text(json.dumps({"hostname": HOST, "upstreamPort": 6901, "httpsPorts": [8443]}))
                calls = []

                def api(route, body=None, match=None):
                    calls.append((route, copy.deepcopy(body), match))
                    if route.startswith("status"):
                        return {"BackendState": "Running", "Self": {"ID": 7, "DNSName": HOST + "."},
                                "CertDomains": [HOST]}, None
                    if body is None:
                        return None, etag
                    if fail:
                        raise serve.Refusal("Serve changed.")
                    return None, None

                with patch.object(serve, "POLICY", policy), patch.object(serve, "STATE", state), \
                     patch.object(sys, "argv", args), patch.object(serve.os, "geteuid", return_value=0), \
                     patch.object(serve, "check_listening"), patch.object(serve, "api", side_effect=api), \
                     redirect_stdout(io.StringIO()):
                    if fail or not etag:
                        with self.assertRaises(serve.Refusal):
                            serve.main()
                        self.assertFalse((state / "owned.json").exists())
                    else:
                        serve.main()
                        self.assertEqual(json.loads((state / "owned.json").read_text()),
                                         {f"7:{HOST}": {PORT: {"Proxy": TARGET}}})
                return calls

        argv = ["voxl-manager-serve", "enable", PORT, HOST, "6901"]
        self.assertEqual(simulate(argv, "checked-etag", False)[-1][2], "checked-etag")
        self.assertEqual(simulate(argv, "stale-etag", True)[-1][2], "stale-etag")
        self.assertEqual(len(simulate(argv, None, False)), 2)


if __name__ == "__main__":
    unittest.main()
