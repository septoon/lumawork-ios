#!/usr/bin/env python3
"""Generate and sign bundled Siri shortcuts from the app's Swift catalog.

Requires macOS, Xcode's Swift compiler, and Apple's shortcuts utility.
Apple receives only generic command names and IDs, never app sessions or data.
"""
import hashlib
import json
import plistlib
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "LumaWork/LumaWork/EngineerVoice"
DESTINATION = SOURCE / "ShortcutFiles"
BUNDLE_ID = "septon.LumaWork"


def main():
    DESTINATION.mkdir(parents=True, exist_ok=True)
    index_path = DESTINATION / "engineer-shortcuts-index.json"
    previous = json.loads(index_path.read_text()) if index_path.exists() else {}
    previous_hashes = previous.get("workflows", {})
    with tempfile.TemporaryDirectory(prefix="engineer-shortcuts-") as directory:
        work = Path(directory)
        main_file = work / "main.swift"
        main_file.write_text('''import Foundation
@main struct ExportCatalog {
    static func main() throws {
        let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let commands = EngineerShortcutCatalog.commands
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(commands).write(to: destination.appendingPathComponent("catalog.json"))
        for command in commands {
            try EngineerShortcutCatalog.workflowData(for: command, bundleIdentifier: "septon.LumaWork")
                .write(to: destination.appendingPathComponent(command.id + ".shortcut"))
        }
    }
}
''')
        executable = work / "export-catalog"
        subprocess.run(["swiftc", "-parse-as-library", str(SOURCE / "EngineerVoiceModels.swift"),
                        str(SOURCE / "EngineerShortcutCatalog.swift"), str(main_file), "-o", str(executable)], check=True)
        subprocess.run([str(executable), str(work)], check=True)
        catalog = json.loads((work / "catalog.json").read_text())
        hashes = {}
        for number, command in enumerate(catalog, 1):
            identifier = command["id"]
            unsigned = work / (identifier + ".shortcut")
            workflow = plistlib.loads(unsigned.read_bytes())
            workflow["WFWorkflowActions"][0]["WFWorkflowActionParameters"]["UUID"] = str(
                uuid.uuid5(uuid.NAMESPACE_DNS, BUNDLE_ID + "." + identifier)).upper()
            data = plistlib.dumps(workflow, fmt=plistlib.FMT_BINARY, sort_keys=True)
            unsigned.write_bytes(data)
            fingerprint = hashlib.sha256(data).hexdigest()
            signed = DESTINATION / ("engineer-" + identifier + ".shortcut")
            if previous_hashes.get(identifier) != fingerprint or not signed.exists():
                temporary_signed = work / (identifier + ".signed.shortcut")
                for attempt in range(3):
                    operation = subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", str(unsigned),
                                                "--output", str(temporary_signed)], capture_output=True, text=True, timeout=60)
                    if operation.returncode == 0 and temporary_signed.exists():
                        break
                    if "NSURLErrorDomain" not in operation.stderr:
                        break
                    if attempt < 2:
                        time.sleep(2)
                if operation.returncode or not temporary_signed.exists():
                    raise RuntimeError(f"Cannot sign {command['title']}: {operation.stderr.strip() or operation.stdout.strip()}")
                if temporary_signed.read_bytes()[:4] != b"AEA1":
                    raise RuntimeError(f"Invalid signed archive: {identifier}")
                temporary_signed.replace(signed)
            hashes[identifier] = fingerprint
            print(f"{number}/{len(catalog)} {command['title']}", flush=True)
        index_path.write_text(json.dumps({"bundleIdentifier": BUNDLE_ID, "commands": catalog, "workflows": hashes},
                                         ensure_ascii=False, indent=2, sort_keys=True) + "\n")
        print(f"Signed {len(catalog)} shortcuts in {DESTINATION}")


if __name__ == "__main__":
    main()
