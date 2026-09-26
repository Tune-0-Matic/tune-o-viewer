"""Exports Windows, Linux and macOS builds and packs the upload zips.

    python build_release.py

Everything lands in "builds/Tune-O-Viewer v<version>/" (one folder per platform, plus
"Zips for upload"). The Linux zip keeps the program's executable permission, which
Windows' own zip tool can't do. The macOS zip is Godot's own, so the .app stays intact.
"""
import os
import re
import shutil
import subprocess
import zipfile

GODOT = r"C:\Users\gavin\OneDrive\Documents\GoDot4\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64_console.exe"
here = os.path.dirname(os.path.abspath(__file__))
version = re.search(r'config/version="([^"]+)"', open(os.path.join(here, "project.godot"), encoding="utf-8").read()).group(1)
root = os.path.join(here, "builds", "Tune-O-Viewer v" + version)
zips = os.path.join(root, "Zips for upload")
targets = {"Windows Desktop": "Windows/Tune-O-Viewer.exe", "Linux": "Linux/Tune-O-Viewer.x86_64", "macOS": "macOS/Tune-O-Viewer.zip"}

for d in ["Windows", "Linux", "macOS", "Zips for upload"]:
    os.makedirs(os.path.join(root, d), exist_ok=True)
subprocess.run([GODOT, "--headless", "--path", here, "--import"], capture_output=True)
for preset, rel in targets.items():
    r = subprocess.run([GODOT, "--headless", "--path", here, "--export-release", preset, os.path.join(root, rel)], capture_output=True, text=True)
    assert os.path.exists(os.path.join(root, rel)), preset + " export failed:\n" + r.stdout + r.stderr

shutil.copyfile(os.path.join(here, "How to run.txt"), os.path.join(root, "How to run.txt"))
guide = open(os.path.join(root, "How to run.txt"), encoding="utf-8").read().replace("\r\n", "\n").replace("\n", "\r\n")
top = "Tune-O-Viewer v" + version


def pack(name, src):
    with zipfile.ZipFile(os.path.join(zips, name), "w", zipfile.ZIP_DEFLATED) as z:
        info = zipfile.ZipInfo.from_file(os.path.join(root, src), top + "/" + os.path.basename(src))
        info.external_attr = (0o100755) << 16  # regular file, executable
        info.compress_type = zipfile.ZIP_DEFLATED
        with open(os.path.join(root, src), "rb") as f:
            z.writestr(info, f.read())
        z.writestr(top + "/How to run.txt", guide)


pack(f"Tune-O-Viewer-v{version}-Windows.zip", targets["Windows Desktop"])
pack(f"Tune-O-Viewer-v{version}-Linux.zip", targets["Linux"])
mac = os.path.join(zips, f"Tune-O-Viewer-v{version}-macOS.zip")
shutil.copyfile(os.path.join(root, targets["macOS"]), mac)
with zipfile.ZipFile(mac, "a") as z:
    z.writestr("How to run.txt", guide)
for n in sorted(os.listdir(zips)):
    print(f"{n:36} {os.path.getsize(os.path.join(zips, n)) / 1e6:6.1f} MB")
