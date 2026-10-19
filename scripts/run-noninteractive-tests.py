#!/usr/bin/env python3
"""Compile current tests with isolated settings; never run clipboard/keychain tests.

Production Swift files and checked-in tests are not rewritten. Only generated test
copies redirect UserDefaults and AppKeyStrings to a UUID suite. The generated
runner skips MonitorTests before setUp, isolates every case, and redirects theme
imports into TMPDIR. Network tests must explicitly bind to loopback.

Logs and generated test copies remain in --output-dir (or DITTO_TEST_OUTPUT_DIR).
Without either option, a unique build/noninteractive-tests/run-* directory is used.
Temporary databases/themes and the executable are removed after the run.
"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError(f"Runner layout changed; review isolation anchor: {old!r}")
    return source.replace(old, new, 1)


def prepare_sources(root, destination):
    destination.mkdir(parents=True, exist_ok=True)
    tests = sorted((root / "Tests/DittoMacKitTests").glob("*.swift"))
    if not tests:
        raise ValueError("No test sources found")
    for path in tests:
        source = path.read_text()
        source = source.replace("UserDefaults.standard", "DittoSettings.defaults")
        source = source.replace("AppKeyStrings.load()",
                                "AppKeyStrings.load(defaults: DittoSettings.defaults)")
        source = source.replace("AppKeyStrings.save(entries)",
                                "AppKeyStrings.save(entries, defaults: DittoSettings.defaults)")
        # Fail closed if old tests would start listeners on every interface.
        if path.name == "NetSyncTests.swift":
            for call in re.findall(r"\.start\(port:[^)]*\)", source):
                if "loopbackOnly: true" not in call:
                    raise ValueError(f"Network test listener is not loopback-only: {call}")
        (destination / path.name).write_text(source)

    source = (root / "Tests/MiniTestShim/main.swift").read_text()
    source = replace_once(source, "import Foundation", """import Foundation
import Darwin

setbuf(stdout, nil)
var totalSkipped = 0
func skipReason(suite: String, test: String) -> String? {
    if suite == "MonitorTests" {
        return "Uses the system clipboard or synthesized keyboard events (including setUp)."
    }
    if suite == "NetSyncTests" && test == "keychainPasswordRoundtrip" {
        return "Reads, overwrites and deletes the real NetSync keychain item."
    }
    return nil
}
""")
    source = replace_once(source,
                          "    for (testName, method) in regs {",
                          """    for (testName, method) in regs {
        if let reason = skipReason(suite: name, test: testName) {
            totalSkipped += 1
            print("SKIP \\(name)/\\(testName): \\(reason)")
            continue
        }
        let suiteName = "org.dittomac.noninteractive.\\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        DittoSettings.defaults = isolatedDefaults
        let themeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-\\(UUID().uuidString)", isDirectory: true)
        if name == "Wave4FeatureTests" && testName == "themeImportRoundTrip" {
            PortableMode.setResolvedRootForTesting(themeRoot)
        }
        defer {
            PortableMode.setResolvedRootForTesting(nil)
            isolatedDefaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: themeRoot)
        }""")
    source = replace_once(source,
                          "\\(MiniTest.totalFailures) assertion failures\")",
                          "\\(MiniTest.totalFailures) assertion failures; \\(totalSkipped) skipped\")")
    (destination / "main.swift").write_text(source)
    return [destination / path.name for path in tests] + [destination / "main.swift"]


def logged_run(command, log_path, environment):
    with log_path.open("w") as log:
        process = subprocess.Popen(command, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True,
                                   env=environment, errors="replace")
        try:
            for line in process.stdout:
                log.write(line)
                log.flush()
                print(line, end="", flush=True)
            code = process.wait()
        except BaseException:
            process.terminate()
            process.wait()
            raise
    return code if code >= 0 else 128 - code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", default=os.environ.get("DITTO_TEST_OUTPUT_DIR"),
                        help="Directory for compile.log, tests.log, summary.json and generated sources")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    if args.output_dir:
        output = Path(args.output_dir).expanduser().resolve()
        output.mkdir(parents=True, exist_ok=True)
    else:
        base = root / "build/noninteractive-tests"
        base.mkdir(parents=True, exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix="run-", dir=base))
    print(f"Noninteractive test artifacts: {output}", flush=True)
    summary = {"exit_code": 2, "skipped": None, "phase": "prepare"}
    try:
        # Use a fresh source directory even when a caller reuses its log directory.
        generated = Path(tempfile.mkdtemp(prefix="sources-", dir=output))
        tests = prepare_sources(root, generated)
        with tempfile.TemporaryDirectory(prefix="runtime-", dir=output) as temporary:
            runtime = Path(temporary)
            tempdir = runtime / "tmp"
            tempdir.mkdir()
            environment = dict(os.environ, TMPDIR=str(tempdir) + "/")
            command = ["swiftc", "-O", "-D", "DITTO_NO_SPM_RESOURCES", "-o", str(runtime / "tests")]
            command += [str(path) for path in sorted((root / "Sources/DittoMacKit").glob("*.swift"))]
            command += [str(root / path) for path in (
                "Sources/DittoMac/ClipDescription.swift", "Sources/DittoMac/L10n.swift",
                "Tests/MiniTestShim/MiniTest.swift")]
            command += [str(path) for path in tests]
            (output / "compile-command.json").write_text(json.dumps(command, indent=2) + "\n")
            summary["phase"] = "compile"
            summary["exit_code"] = logged_run(command, output / "compile.log", environment)
            if summary["exit_code"] == 0:
                summary["phase"] = "tests"
                summary["exit_code"] = logged_run([str(runtime / "tests")], output / "tests.log", environment)
                result = (output / "tests.log").read_text()
                summary["skipped"] = len(re.findall(r"^SKIP ", result, re.MULTILINE))
                match = re.search(r"Executed (\d+) tests: (\d+) passed, (\d+) failed, (\d+) assertion failures", result)
                if match:
                    summary.update(zip(("executed", "passed", "failed", "assertion_failures"),
                                       map(int, match.groups())))
    except (OSError, ValueError) as error:
        print(f"Noninteractive runner failed: {error}", file=sys.stderr)
        summary["exit_code"] = 2
    except KeyboardInterrupt:
        summary["exit_code"] = 130
    finally:
        (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(f"Exit code: {summary['exit_code']}; skipped: {summary['skipped']}; artifacts: {output}", flush=True)
    return summary["exit_code"]


if __name__ == "__main__":
    sys.exit(main())
