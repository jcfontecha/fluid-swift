"""Run this lane's actual tests without compiling concurrently edited sibling test targets."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
with tempfile.TemporaryDirectory(prefix="fluid-odsp2-tests-") as directory:
    package = Path(directory)
    (package / "Sources").symlink_to(root / "Sources", target_is_directory=True)
    (package / "Tests").symlink_to(root / "Tests", target_is_directory=True)
    (package / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "OdspLaneTests", platforms: [.macOS(.v15)], targets: [
    .target(name: "FluidJS"),
    .target(name: "FluidDriverDefinitions", dependencies: ["FluidJS"]),
    .target(name: "FluidOdspDriver", dependencies: ["FluidJS", "FluidDriverDefinitions"]),
    .testTarget(name: "FluidOdspDriverTests", dependencies: ["FluidOdspDriver", "FluidJS", "FluidDriverDefinitions"])
])
''')
    result = subprocess.run(["swift", "test", "--package-path", str(package), "--scratch-path", str(root / ".build/odsp2")])
    raise SystemExit(result.returncode)
