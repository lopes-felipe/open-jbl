"""Exercise signing/build gates with isolated fake tools; never use a keychain."""
import base64
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import ssl
import subprocess
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
CERT_DER = b"synthetic certificate for isolated tool tests only"
OTHER_CERT_DER = b"another synthetic certificate"
FIRST = hashlib.sha1(CERT_DER).hexdigest().upper()
SECOND = hashlib.sha1(OTHER_CERT_DER).hexdigest().upper()
LABEL = "Developer ID Application: Test Developer (TESTTEAM)"


class ValidationBuildTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        (self.root / "scripts").mkdir()
        (self.root / "bin").mkdir()
        for name in ("build-validation.sh", "check-entitlements.sh"):
            shutil.copy2(ROOT / "scripts" / name, self.root / "scripts" / name)
            (self.root / "scripts" / name).chmod(0o700)
        self.log = self.root / "commands.jsonl"
        tool = textwrap.dedent("""\
            #!/usr/bin/env python3
            import base64, json, os, pathlib, plistlib, shutil, sys
            name = pathlib.Path(sys.argv[0]).name
            args = sys.argv[1:]
            with open(os.environ["TEST_COMMAND_LOG"], "a") as file:
                file.write(json.dumps([name, args]) + "\\n")
            if name == "security":
                if args[0] == "find-identity":
                    print(os.environ.get("TEST_IDENTITIES", "") if "-v" in args else
                          os.environ.get("TEST_ALL_IDENTITIES", os.environ.get("TEST_IDENTITIES", "")))
                elif args[0] == "find-certificate":
                    print(os.environ.get("TEST_CERTIFICATES_PEM", ""))
                elif args[0] == "verify-cert":
                    artifact = any("artifact-cert-" in arg for arg in args)
                    sys.exit(int(os.environ.get("TEST_ARTIFACT_TRUST_STATUS" if artifact else "TEST_CERT_TRUST_STATUS", "0")))
            elif name == "xcodebuild":
                if os.environ.get("TEST_XCODE_STATUS", "0") != "0":
                    sys.exit(int(os.environ["TEST_XCODE_STATUS"]))
                derived = pathlib.Path(args[args.index("-derivedDataPath") + 1])
                binary = derived / "Build/Products/Release/OpenJBL.app/Contents/MacOS/OpenJBL"
                binary.parent.mkdir(parents=True, exist_ok=True)
                binary.write_text('#!/bin/sh\\nprintf \\'%s\\\\n\\' \\'{"passed":' +
                                  os.environ.get("TEST_SELF_TEST_PASSED", "true") + '}\\'\\n')
                binary.chmod(0o700)
            elif name == "codesign":
                if "--verify" in args:
                    sys.exit(int(os.environ.get("TEST_REQUIREMENT_STATUS" if "-R" in args else "TEST_SIGNATURE_STATUS", "0")))
                if "--extract-certificates" in args:
                    prefix = args[args.index("--extract-certificates") + 1]
                    pathlib.Path(prefix + "0").write_bytes(base64.b64decode(
                        os.environ.get("TEST_ARTIFACT_CERT_DER", os.environ["TEST_CERT_DER"])))
                    sys.exit(0)
                if "--entitlements" in args:
                    sys.stdout.buffer.write(plistlib.dumps({
                        "com.apple.security.app-sandbox": True,
                        "com.apple.security.device.bluetooth": True,
                        "com.apple.security.files.user-selected.read-write": True
                    }))
                else:
                    print("Authority=Developer ID Application: Test Developer (TESTTEAM)")
                    print("CodeDirectory flags=0x10000(runtime)")
                    print("Timestamp=synthetic tool test")
            elif name == "ditto":
                shutil.copytree(args[0], args[1])
            elif name == "shasum":
                print("TEST-ARTIFACT-HASH")
            """)
        for name in ("security", "xcodebuild", "codesign", "lipo", "ditto", "shasum"):
            target = self.root / "bin" / name
            target.write_text(tool)
            target.chmod(0o700)
        self.env = dict(os.environ)
        self.env.pop("OPENJBL_SIGNING_IDENTITY", None)
        self.env.pop("OPENJBL_SIGNING_KEYCHAIN", None)
        self.env.pop("OPENJBL_HOST_RESTRICTED", None)
        self.env.pop("CI", None)
        self.env.update(
            PATH=str(self.root / "bin") + os.pathsep + self.env["PATH"],
            TEST_COMMAND_LOG=str(self.log),
            TEST_IDENTITIES=f'  1) {FIRST} "{LABEL}"\n     1 valid identities found',
            TEST_CERT_DER=base64.b64encode(CERT_DER).decode(),
            TEST_CERTIFICATES_PEM=ssl.DER_cert_to_PEM_cert(CERT_DER),
        )

    def run_build(self, *arguments):
        return subprocess.run(
            ["bash", str(self.root / "scripts/build-validation.sh"), *arguments],
            env=self.env, capture_output=True, text=True, timeout=20,
        )

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_missing_identity_blocks_before_build_without_ad_hoc_fallback(self):
        self.env["TEST_IDENTITIES"] = "0 valid identities found"
        result = self.run_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No ad-hoc fallback", result.stderr)
        self.assertEqual([item[0] for item in self.commands()], ["security"])

    def test_ambiguous_identity_requires_exact_selection(self):
        self.env["TEST_IDENTITIES"] += f'\n  2) {SECOND} "Developer ID Application: Another Developer (OTHERTEAM)"'
        self.assertNotEqual(self.run_build().returncode, 0)
        self.assertEqual([item[0] for item in self.commands()], ["security"])
        self.env["OPENJBL_SIGNING_IDENTITY"] = LABEL
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        xcode = next(args for name, args in self.commands() if name == "xcodebuild")
        self.assertIn(f"CODE_SIGN_IDENTITY={FIRST}", xcode)
        self.assertIn("ARCHS=arm64 x86_64", xcode)
        self.assertIn("ONLY_ACTIVE_ARCH=NO", xcode)
        self.assertIn("ENABLE_HARDENED_RUNTIME=YES", xcode)
        self.assertIn("OTHER_CODE_SIGN_FLAGS=--timestamp", xcode)
        lipo_commands = [args for name, args in self.commands() if name == "lipo"]
        self.assertEqual([args[:2] for args in lipo_commands], [["-verify_arch", "arm64"], ["-verify_arch", "x86_64"]])
        self.assertTrue(all(len(args) == 3 for args in lipo_commands))

    def test_substring_identity_does_not_select_certificate(self):
        self.env["OPENJBL_SIGNING_IDENTITY"] = "Test Developer"
        result = self.run_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([item[0] for item in self.commands()], ["security"])

    def test_explicit_ci_ad_hoc_never_becomes_local_default(self):
        result = self.run_build("--ci-ad-hoc")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.commands(), [])
        self.env["CI"] = "true"
        result = self.run_build("--ci-ad-hoc")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("security", [name for name, _ in self.commands()])
        xcode = next(args for name, args in self.commands() if name == "xcodebuild")
        self.assertIn("CODE_SIGN_IDENTITY=-", xcode)

    def test_self_test_failure_never_reports_validated_artifact(self):
        self.env["TEST_SELF_TEST_PASSED"] = "false"
        result = self.run_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Universal validation build passed", result.stdout)
        self.assertNotIn("shasum", [name for name, _ in self.commands()])

    def test_signature_failure_stops_before_relocated_launch(self):
        self.env["TEST_SIGNATURE_STATUS"] = "1"
        result = self.run_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("ditto", [name for name, _ in self.commands()])
        self.assertNotIn("shasum", [name for name, _ in self.commands()])

    def test_host_workaround_is_explicit_and_does_not_change_app_entitlements(self):
        self.env["OPENJBL_HOST_RESTRICTED"] = "1"
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        xcode = next(args for name, args in self.commands() if name == "xcodebuild")
        self.assertIn("-IDEPackageSupportDisableManifestSandbox=YES", xcode)
        self.assertIn("OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox", xcode)
        self.assertFalse(any("ENTITLEMENTS" in argument for argument in xcode))
        self.assertIn("TEST-ARTIFACT-HASH", result.stdout)

    def test_terminal_launcher_refuses_noninteractive_agent_context(self):
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/probe-terminal.command")],
            capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("user-launched interactive terminal", result.stderr)

    def explicit_keychain(self):
        keychain = self.root / "signing keychain.keychain-db"
        keychain.touch()
        self.env["OPENJBL_SIGNING_KEYCHAIN"] = str(keychain)
        return keychain.resolve()

    def test_explicit_keychain_can_select_independently_trusted_non_valid_only_identity(self):
        keychain = self.explicit_keychain()
        self.env["TEST_ALL_IDENTITIES"] = self.env["TEST_IDENTITIES"]
        self.env["TEST_IDENTITIES"] = "0 valid identities found"
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.commands()
        self.assertEqual(commands[0], ["security", ["find-identity", "-p", "codesigning", str(keychain)]])
        prebuild = next(index for index, (name, _) in enumerate(commands) if name == "xcodebuild")
        self.assertTrue(any(name == "security" and args[0] == "verify-cert"
                            for name, args in commands[:prebuild]))
        xcode = commands[prebuild][1]
        flags = next(argument for argument in xcode if argument.startswith("OTHER_CODE_SIGN_FLAGS="))
        self.assertEqual(flags, f"OTHER_CODE_SIGN_FLAGS=--timestamp --keychain '{keychain}'")
        requirements = [args for name, args in commands if name == "codesign" and "-R" in args]
        self.assertEqual(len(requirements), 1)
        self.assertTrue(requirements[0][requirements[0].index("-R") + 1].startswith("=anchor apple generic"))
        self.assertEqual(len([args for name, args in commands
                              if name == "security" and args[0] == "verify-cert"]), 2)

    def test_missing_keychain_and_missing_matching_certificate_stop_before_build(self):
        self.env["OPENJBL_SIGNING_KEYCHAIN"] = str(self.root / "absent.keychain-db")
        self.assertNotEqual(self.run_build().returncode, 0)
        self.assertEqual(self.commands(), [])
        self.explicit_keychain()
        self.env["TEST_CERTIFICATES_PEM"] = ssl.DER_cert_to_PEM_cert(OTHER_CERT_DER)
        result = self.run_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no exact matching certificate", result.stderr)
        self.assertNotIn("xcodebuild", [name for name, _ in self.commands()])

    def test_untrusted_keychain_identity_is_never_built(self):
        self.explicit_keychain()
        self.env["TEST_CERT_TRUST_STATUS"] = "1"
        self.assertNotEqual(self.run_build().returncode, 0)
        self.assertNotIn("xcodebuild", [name for name, _ in self.commands()])

    def test_ambiguous_explicit_keychain_needs_exact_identity(self):
        self.explicit_keychain()
        self.env["TEST_ALL_IDENTITIES"] = self.env["TEST_IDENTITIES"] + f'\n  2) {SECOND} "{LABEL}"'
        self.assertNotEqual(self.run_build().returncode, 0)
        self.assertNotIn("xcodebuild", [name for name, _ in self.commands()])
        self.env["OPENJBL_SIGNING_IDENTITY"] = FIRST
        self.assertEqual(self.run_build().returncode, 0)

    def test_artifact_must_use_selected_leaf_and_pass_apple_requirement_and_trust(self):
        for key, value in (
            ("TEST_ARTIFACT_CERT_DER", base64.b64encode(OTHER_CERT_DER).decode()),
            ("TEST_REQUIREMENT_STATUS", "1"),
            ("TEST_ARTIFACT_TRUST_STATUS", "1"),
        ):
            with self.subTest(key=key):
                self.env[key] = value
                result = self.run_build()
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("Universal validation build passed", result.stdout)
                self.env.pop(key)

    def test_xcode_discovery_failure_has_no_ad_hoc_fallback(self):
        # Even a trusted explicit certificate does not imply Xcode can find it.
        self.explicit_keychain()
        self.env["TEST_XCODE_STATUS"] = "65"
        result = self.run_build()
        self.assertEqual(result.returncode, 65)
        calls = [args for name, args in self.commands() if name == "xcodebuild"]
        self.assertEqual(len(calls), 1)
        self.assertIn(f"CODE_SIGN_IDENTITY={FIRST}", calls[0])


if __name__ == "__main__":
    unittest.main()
