import os
import sys

def patch(path):
    with open(path, "rb") as f:
        data = f.read()

    old = b"MOZ_REQUIRE_SIGNING: true"
    new = b"MOZ_REQUIRE_SIGNING:false"  # 等长，不破坏文件结构

    if old not in data:
        print("Target string not found.")
        return

    patched = data.replace(old, new, 1)
    backup = path + ".old"
    os.replace(path, backup)
    with open(path, "wb") as f:
        f.write(patched)

if len(sys.argv) < 2:
    print(f"Usage: python {sys.argv[0]} \"C:\\Program Files\\Mozilla Firefox\\omni.ja\"")
    raise SystemExit(1)

path = sys.argv[1]
if os.path.basename(path) != "omni.ja":
    print("Please specify omni.ja path!")
    raise SystemExit(1)

try:
    patch(path)
except PermissionError:
    print("Run as Administrator.")
    raise SystemExit(1)

print("Successfully patched omni.ja!")
print("Clear startup cache in about:support if needed.")