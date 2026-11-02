"""Validate test execution/report gating without launching a GUI or hardware."""
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class UIRunnerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        (self.root / "scripts").mkdir()
        (self.root / "bin").mkdir()
        shutil.copy2(ROOT / "scripts/check-ui.sh", self.root / "scripts")
        tool = textwrap.dedent("""\
            #!/usr/bin/env python3
            import json, os, pathlib, sys
            name = pathlib.Path(sys.argv[0]).name
            args = sys.argv[1:]
            with open(os.environ["TEST_COMMAND_LOG"], "a") as file:
                file.write(json.dumps([name, args]) + "\\n")
            if name == "xcodebuild":
                if os.environ.get("TEST_NO_BUNDLE") != "1":
                    pathlib.Path(args[args.index("-resultBundlePath") + 1]).mkdir()
                sys.exit(int(os.environ.get("TEST_XCODE_STATUS", "0")))
            if name == "xcrun":
                sys.stdout.write(os.environ["TEST_UI_SUMMARY"])
                sys.exit(int(os.environ.get("TEST_SUMMARY_STATUS", "0")))
            """)
        for name in ("xcodebuild", "xcrun"):
            executable = self.root / "bin" / name
            executable.write_text(tool)
            executable.chmod(0o700)
        self.log = self.root / "commands.jsonl"
        self.env = dict(os.environ)
        self.env.pop("OPENJBL_HOST_RESTRICTED", None)
        self.env.update(
            PATH=str(self.root / "bin") + os.pathsep + self.env["PATH"],
            TEST_COMMAND_LOG=str(self.log),
            TEST_UI_SUMMARY=json.dumps(
                dict(result="Passed", totalTestCount=5, passedTests=5, failedTests=0, skippedTests=0)
            ),
        )

    def run_ui(self, *arguments):
        return subprocess.run(
            ["bash", str(self.root / "scripts/check-ui.sh"), *arguments],
            capture_output=True, text=True, env=self.env, timeout=10,
        )

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_invokes_serial_runtime_test_action_and_keeps_result_bundle(self):
        result = self.run_ui()
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.commands()
        self.assertEqual([name for name, _ in commands], ["xcodebuild", "xcrun"])
        xcode = commands[0][1]
        self.assertEqual(xcode[-1], "test")
        self.assertIn("-only-testing:OpenJBLUITests", xcode)
        self.assertEqual(xcode[xcode.index("-parallel-testing-enabled") + 1], "NO")
        self.assertIn("CODE_SIGN_IDENTITY=-", xcode)
        self.assertNotIn("build-for-testing", xcode)
        bundle = pathlib.Path(xcode[xcode.index("-resultBundlePath") + 1])
        self.assertTrue(bundle.is_dir())
        self.assertEqual(json.loads((bundle.parent / "summary.json").read_text())["passedTests"], 5)
        self.assertIn("5 tests", result.stdout)

    def test_failed_test_process_cannot_be_hidden_by_passing_summary(self):
        self.env["TEST_XCODE_STATUS"] = "65"
        result = self.run_ui()
        self.assertEqual(result.returncode, 65)
        self.assertNotIn("Offline UI runtime checks passed.", result.stdout)
        self.assertEqual([name for name, _ in self.commands()], ["xcodebuild", "xcrun"])

    def test_build_only_or_empty_selection_is_not_runtime_success(self):
        self.env["TEST_UI_SUMMARY"] = json.dumps(
            dict(result="Passed", totalTestCount=0, passedTests=0, failedTests=0, skippedTests=0)
        )
        result = self.run_ui()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("UI runtime validation failed", result.stderr)

    def test_failed_or_skipped_ui_tests_fail_the_check(self):
        for passed, failed, skipped in ((4, 1, 0), (4, 0, 1), (4, 0, 0)):
            with self.subTest(passed=passed, failed=failed, skipped=skipped):
                self.env["TEST_UI_SUMMARY"] = json.dumps(
                    dict(result="Passed", totalTestCount=5, passedTests=passed,
                         failedTests=failed, skippedTests=skipped)
                )
                self.assertNotEqual(self.run_ui().returncode, 0)

    def test_missing_bundle_and_unreadable_summary_fail_closed(self):
        self.env["TEST_NO_BUNDLE"] = "1"
        result = self.run_ui()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not produce an xcresult", result.stderr)
        self.env.pop("TEST_NO_BUNDLE")
        self.env["TEST_SUMMARY_STATUS"] = "1"
        result = self.run_ui()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not read", result.stderr)

    def test_malformed_summary_and_boolean_test_counts_are_rejected(self):
        for summary in ("not json", "[]", json.dumps(
            dict(result="Passed", totalTestCount=True, passedTests=5, failedTests=0, skippedTests=0)
        )):
            self.env["TEST_UI_SUMMARY"] = summary
            self.assertNotEqual(self.run_ui().returncode, 0)

    def test_host_workaround_only_changes_compiler_flags(self):
        self.env["OPENJBL_HOST_RESTRICTED"] = "1"
        result = self.run_ui()
        self.assertEqual(result.returncode, 0, result.stderr)
        xcode = self.commands()[0][1]
        self.assertIn("-IDEPackageSupportDisableManifestSandbox=YES", xcode)
        self.assertIn("OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox", xcode)
        self.assertFalse(any("ENTITLEMENTS" in value or "SANDBOX=NO" in value for value in xcode))

    def test_repeated_runs_retain_distinct_results(self):
        self.assertEqual(self.run_ui().returncode, 0)
        self.assertEqual(self.run_ui().returncode, 0)
        paths = [args[args.index("-resultBundlePath") + 1]
                 for name, args in self.commands() if name == "xcodebuild"]
        self.assertEqual(len(set(paths)), 2)
        self.assertTrue(all(pathlib.Path(path).is_dir() for path in paths))


if __name__ == "__main__":
    unittest.main()
