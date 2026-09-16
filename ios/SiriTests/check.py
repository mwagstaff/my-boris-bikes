"""Run local Siri/Journey checks; optionally type-check app sources without xcodebuild."""
import argparse
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
PROJECT = ROOT / "ios/BikeSpot London"
APP = PROJECT / "BikeSpot London"
DEVELOPER = pathlib.Path("/Applications/Xcode.app/Contents/Developer")
SHARED = [APP / "Models" / name for name in
          ["JourneyComplicationModels.swift", "JourneyDataSource.swift", "SiriAvailability.swift"]]

def run(args, log=None):
    result = subprocess.run(["rtk", "proxy", *map(str, args)], cwd=ROOT, capture_output=True, text=True)
    output = result.stdout + result.stderr
    if log:
        pathlib.Path(log).write_text(output)
        print(f"{log}: exit {result.returncode}")
        if result.returncode:
            print(output)
    else:
        print(output, end="")
    if result.returncode:
        raise SystemExit(result.returncode)

parser = argparse.ArgumentParser()
parser.add_argument("--typecheck", action="store_true")
options = parser.parse_args()
with tempfile.TemporaryDirectory(prefix="bikespot-siri-") as folder:
    for runner in ["SiriTests/SiriAvailabilityChecks.swift", "JourneyTests/JourneyLogicChecks.swift"]:
        binary = pathlib.Path(folder) / pathlib.Path(runner).stem
        run(["swiftc", "-D", "DEBUG", *SHARED, ROOT / "ios" / runner, "-o", binary])
        run([binary])

if options.typecheck:
    intents = sorted((APP / "Intents").glob("*.swift"))
    components = [APP / "Components/JourneyAvailabilityViews.swift"]
    targets = [
        ("ios", "iPhoneOS", "arm64-apple-ios18.5", sorted(APP.rglob("*.swift")), True),
        ("watch-debug", "WatchOS", "arm64-apple-watchos11.5",
         sorted((PROJECT / "BikeSpot London Watch App").rglob("*.swift")) + SHARED + components + intents, True),
        ("watch-release", "WatchOS", "arm64-apple-watchos11.5",
         sorted((PROJECT / "BikeSpot London Watch App").rglob("*.swift")) + SHARED + components + intents, False),
        ("watch-extension", "WatchOS", "arm64-apple-watchos11.5",
         sorted((PROJECT / "BikeSpot London Watch App Extension").rglob("*.swift")) + SHARED + components, True),
        ("widget", "iPhoneOS", "arm64-apple-ios18.5",
         sorted((PROJECT / "BikeSpot London Widget").rglob("*.swift")) + SHARED + components
         + [APP / name for name in ["Configuration/AppConstants.swift", "Models/BikePoint.swift",
                                   "Models/LiveActivityModels.swift", "Models/WidgetModels.swift"]], True),
    ]
    for name, platform, triple, files, debug in targets:
        sdk = DEVELOPER / f"Platforms/{platform}.platform/Developer/SDKs/{platform}.sdk"
        args = ["swiftc", "-typecheck", "-swift-version", "5", "-sdk", sdk, "-target", triple]
        if debug:
            args += ["-D", "DEBUG"]
        run([*args, *files], log=f"/tmp/bikespot-{name}-typecheck.log")
