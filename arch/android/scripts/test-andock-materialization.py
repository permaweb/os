#!/usr/bin/env python3
"""Test compiled production Kotlin on the host; never access an installed node.

First run `./gradlew :app:testDebugUnitTest` in arch/android/android, then this
script with the same JAVA_HOME and GRADLE_USER_HOME. Android stubs exist only on
this isolated test classpath. Rename and sparse expansion use real host files;
Android directory fsync semantics are explicitly outside this test's scope.
"""
import argparse
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--classes", type=Path, default=root / "android/app/build/intermediates/built_in_kotlinc/debug/compileDebugKotlin/classes")
args = parser.parse_args()
cache = Path(os.environ.get("GRADLE_USER_HOME", Path.home() / ".gradle")) / "caches/modules-2/files-2.1"


def dependency(group, name):
    matches = sorted((cache / group / name).glob("*/*/*.jar"))
    if not matches:
        raise SystemExit(f"Missing cached {group}:{name}; run the existing Gradle host tests first")
    return matches[-1]


java_bin = Path(os.environ["JAVA_HOME"]) / "bin"
production = args.classes.resolve()
if not (production / "org/permaweb/andee/AndeeAndockImageMaterializer.class").is_file():
    raise SystemExit("Compile the current production source with the existing Gradle host test task first")
out = root / "build/andock-materialization-test"
out.mkdir(parents=True, exist_ok=True)
classpath = os.pathsep.join(map(str, [out, production, dependency("org.jetbrains.kotlin", "kotlin-stdlib"), dependency("org.json", "json")]))
sources = sorted((root / "execution/tests/materialization").rglob("*.java"))
subprocess.run([str(java_bin / "javac"), "-cp", classpath, "-d", str(out), *map(str, sources)], check=True)
subprocess.run([str(java_bin / "java"), "-Xmx128m", "-cp", classpath, "org.permaweb.andee.AndockMaterializationTest"], check=True)
