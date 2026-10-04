"""Build Podium's offline Cydia bootstrap with the iOS 6 Substrate stack."""
import hashlib
import io
import json
import tarfile
import urllib.request
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Podium/Resources/GuestTools/cydia-bootstrap.zip"
BOOTSTRAP_COMMIT = "33dcbfcf4d8791268292e1009e2955e3f02b4785"
BOOTSTRAP_URL = (
    f"https://raw.githubusercontent.com/LukeZGD/Legacy-iOS-Kit/{BOOTSTRAP_COMMIT}"
    "/resources/jailbreak/freeze.tar.gz"
)
BOOTSTRAP_SHA256 = "15ed578226ffe74371ff7c3d2665a99f181c5597ed1aee5d95a9ef5da17a836f"

# These are the 32-bit iOS jailbreak packages used by iOS 6.1.6. The Substrate
# release notes specifically mention its iOS 6 injection fix. PreferenceLoader
# is pinned to a build containing both armv6 and armv7 slices.
PACKAGES = [
    (
        "mobilesubstrate",
        "https://apt.saurik.com/cydia/debs/mobilesubstrate_0.9.6301_iphoneos-arm.deb",
        "8dc91a066f088632409fecf65613831b8d6802e3b799f2dc87563c3ea2ed06ca",
    ),
    (
        "com.saurik.substrate.safemode",
        "https://apt.saurik.com/cydia/debs/com.saurik.substrate.safemode_0.9.6001_iphoneos-arm.deb",
        "86515cb9f6832247dbeae8427b996099dc8759bb1ef1d719c293123f2f531ee1",
    ),
    (
        "preferenceloader",
        "http://apt.thebigboss.org/repofiles/cydia/debs2.0/preferenceloader_2.2.6.deb",
        "335fff25ff13021889ba856ce84fbc23ba25569f1c6cc65a3e113b433b1ed60f",
    ),
]


def download(url, expected_sha256):
    data = urllib.request.urlopen(url, timeout=60).read()
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected_sha256:
        raise ValueError(f"SHA-256 mismatch for {url}: {actual}")
    return data


def ar_members(data):
    if not data.startswith(b"!<arch>\n"):
        raise ValueError("not a Debian ar archive")
    offset = 8
    while offset + 60 <= len(data):
        header = data[offset : offset + 60]
        offset += 60
        name = header[:16].decode("ascii").strip().rstrip("/")
        size = int(header[48:58].decode("ascii").strip())
        end = offset + size
        if end > len(data):
            raise ValueError(f"truncated Debian archive member: {name}")
        yield name, data[offset:end]
        offset = end + (size & 1)
    if offset != len(data):
        raise ValueError("invalid trailing bytes in Debian archive")


def unpack_deb(data):
    control_archive = None
    data_archive = None
    for name, payload in ar_members(data):
        if name.startswith("control.tar"):
            control_archive = payload
        elif name.startswith("data.tar"):
            data_archive = payload
    if control_archive is None or data_archive is None:
        raise ValueError("Debian package is missing control or data archive")

    with tarfile.open(fileobj=io.BytesIO(control_archive), mode="r:*") as archive:
        control_member = next((m for m in archive.getmembers() if m.name.rstrip("/") in ("control", "./control")), None)
        if control_member is None:
            raise ValueError("Debian package has no control record")
        control = archive.extractfile(control_member).read().decode("utf-8")

    payload = []
    with tarfile.open(fileobj=io.BytesIO(data_archive), mode="r:*") as archive:
        for member in archive.getmembers():
            name = member.name.removeprefix("./").strip("/")
            if not name or name == ".":
                continue
            if name.startswith("/") or any(part in ("", ".", "..") for part in name.split("/")):
                raise ValueError(f"unsafe Debian payload path: {member.name}")
            if name in ("etc", "var", "tmp"):
                continue  # Keep iOS's stock aliases pointing into /private.
            for alias in ("etc", "var", "tmp"):
                if name.startswith(alias + "/"):
                    name = "private/" + name
            if member.isdir():
                kind, contents, target = "directory", b"", None
            elif member.issym():
                kind, contents, target = "symlink", b"", member.linkname
            elif member.isfile() or member.islnk():
                kind, contents, target = "file", archive.extractfile(member).read(), None
            else:
                raise ValueError(f"unsupported Debian payload member: {member.name}")
            payload.append((name, kind, contents, target, member.mode, member.uid, member.gid))
    return control, payload


def control_fields(control):
    fields = {}
    current = None
    for line in control.splitlines():
        if line.startswith((" ", "\t")) and current:
            fields[current] += "\n" + line
        elif ":" in line:
            current, value = line.split(":", 1)
            fields[current] = value.lstrip()
    return fields


def archive_path(path):
    return path.removeprefix("/")


bootstrap = download(BOOTSTRAP_URL, BOOTSTRAP_SHA256)
entries = {}
payload_files = {}

with tarfile.open(fileobj=io.BytesIO(bootstrap), mode="r:gz") as archive:
    for member in archive.getmembers():
        name = member.name.removeprefix("./").strip("/")
        if not name:
            continue
        if any(part in ("..", "") for part in name.split("/")):
            raise ValueError(f"unsafe base bootstrap path: {member.name}")
        # /var and /etc are existing iOS aliases; never replace them.
        if name in ("var", "etc", "tmp"):
            continue
        for alias in ("var", "etc", "tmp"):
            if name.startswith(alias + "/"):
                name = "private/" + name
        path = "/" + name
        item = {"path": path, "mode": member.mode, "uid": member.uid, "gid": member.gid}
        if member.isdir():
            item["type"] = "directory"
        elif member.issym():
            item.update(type="symlink", target=member.linkname)
        elif member.isfile() or member.islnk():
            item["type"] = "file"
            payload_files[name] = archive.extractfile(member).read()
        else:
            raise ValueError(f"unsupported bootstrap member: {member.name}")
        entries[path] = item


def ensure_directory(path, mode=0o755, uid=0, gid=0):
    if not path or path == "/":
        return
    parent = path.rsplit("/", 1)[0]
    ensure_directory(parent, mode, uid, gid)
    if path not in entries:
        entries[path] = {"path": path, "mode": mode, "uid": uid, "gid": gid, "type": "directory"}


def add_file(path, contents, mode=0o644, package=None):
    ensure_directory(path.rsplit("/", 1)[0])
    if path in entries and entries[path]["type"] == "directory":
        raise ValueError(f"file conflicts with bootstrap directory: {path}")
    item = {"path": path, "mode": mode, "uid": 0, "gid": 0, "type": "file"}
    if package:
        item["podiumPackage"] = package
        item["replaceExisting"] = True
    entries[path] = item
    payload_files[archive_path(path)] = contents


installed_records = []
installed_packages = []
for expected_name, package_url, expected_sha256 in PACKAGES:
    package_data = download(package_url, expected_sha256)
    control, payload = unpack_deb(package_data)
    fields = control_fields(control)
    name = fields.get("Package")
    if name != expected_name or fields.get("Architecture") != "iphoneos-arm":
        raise ValueError(f"unexpected package identity/architecture: {name}/{fields.get('Architecture')}")
    package_paths = []
    for path, kind, contents, target, mode, uid, gid in payload:
        guest_path = "/" + path
        package_paths.append(guest_path)
        if kind == "directory":
            ensure_directory(guest_path, mode, uid, gid)
            continue
        if guest_path in entries and entries[guest_path].get("podiumPackage") != name:
            raise ValueError(f"package payload conflicts with existing bootstrap item: {guest_path}")
        if kind == "symlink":
            ensure_directory(guest_path.rsplit("/", 1)[0], uid=uid, gid=gid)
            entries[guest_path] = {
                "path": guest_path, "mode": mode, "uid": uid, "gid": gid,
                "type": "symlink", "target": target,
                "podiumPackage": name, "replaceExisting": True,
            }
            payload_files.pop(path, None)
        else:
            add_file(guest_path, contents, mode, name)

    # dpkg uses the .list file to expose and later remove the installed files.
    list_contents = ("".join(path + "\n" for path in sorted(set(package_paths)))).encode()
    add_file(f"/private/var/lib/dpkg/info/{name}.list", list_contents, 0o644, name)

    rest = [line for line in control.splitlines() if not line.startswith("Package:")]
    record = f"Package: {name}\nStatus: install ok installed\n" + "\n".join(rest).strip() + "\n"
    installed_records.append(record)
    installed_packages.append(f"{name} {fields.get('Version')} sha256:{expected_sha256}")


status_path = "/private/var/lib/dpkg/status"
status_name = archive_path(status_path)
if status_name not in payload_files:
    raise ValueError("base Cydia bootstrap has no dpkg status database")
managed_names = {expected_name for expected_name, _, _ in PACKAGES}
existing_records = [
    record.strip()
    for record in payload_files[status_name].decode("utf-8").split("\n\n")
    if record.strip()
]
existing_records = [
    record for record in existing_records
    if not any(line.startswith("Package: ") and line.removeprefix("Package: ") in managed_names
               for line in record.splitlines())
]
payload_files[status_name] = ("\n\n".join(existing_records + installed_records) + "\n").encode()

# Older bootstrap archives and guest volumes may contain this launchd hook.
# Strip only that command; Podium injects Substrate into SpringBoard through
# DYLD_INSERT_LIBRARIES, which the real-kernel integration test exercises.
substrate_launcher = (
    "bsexec .. /usr/bin/cynject 1 "
    "/Library/Frameworks/CydiaSubstrate.framework/Libraries/SubstrateLauncher.dylib"
)
launchd_name = archive_path("/private/etc/launchd.conf")
if launchd_name in payload_files:
    filtered = [line for line in payload_files[launchd_name].decode("utf-8").splitlines()
                if line.strip() != substrate_launcher]
    payload_files[launchd_name] = ("\n".join(filtered) + ("\n" if filtered else "")).encode()

origin = (
    f"{BOOTSTRAP_URL}\nSHA256 {BOOTSTRAP_SHA256}\n"
    "Cydia: https://git.saurik.com/cydia.git\n"
    "Tweak packages (package: version; source; SHA-256):\n"
    + "\n".join(installed_packages)
    + "\nMobileSubstrate is loaded into SpringBoard through DYLD_INSERT_LIBRARIES. The Podium integration boot test checks that a SpringBoard-filtered probe dylib runs.\n"
    "No package maintainer binaries are executed by the build host or guest.\n"
    "Package authors: Jay Freeman (Cydia Substrate/Safe Mode); Sam Bingner (PreferenceLoader).\n"
)

OUT.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as output:
    for name, data in sorted(payload_files.items()):
        output.writestr(name, data)
    output.writestr("manifest.json", json.dumps(sorted(entries.values(), key=lambda item: (item["path"].count("/"), item["path"])), separators=(",", ":")))
    output.writestr("ORIGIN.txt", origin)
print(f"{OUT} ({OUT.stat().st_size} bytes)")
