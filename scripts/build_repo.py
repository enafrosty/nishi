#!/usr/bin/env python3
"""
Nishi APT / Sileo Repository Index Generator
Generates Packages, Packages.gz, and Release index files for the Nishi rootless repository.
"""

import os
import sys
import hashlib
import gzip
import tarfile
import io
import struct
import shutil

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DEBS_DIR = os.path.join(REPO_ROOT, "debs")
DIST_DIR = REPO_ROOT

def get_hashes(filepath):
    md5 = hashlib.md5()
    sha1 = hashlib.sha1()
    sha256 = hashlib.sha256()
    size = os.path.getsize(filepath)
    with open(filepath, "rb") as f:
        while chunk := f.read(65536):
            md5.update(chunk)
            sha1.update(chunk)
            sha256.update(chunk)
    return {
        "md5": md5.hexdigest(),
        "sha1": sha1.hexdigest(),
        "sha256": sha256.hexdigest(),
        "size": size
    }

def read_control_from_deb(deb_path):
    """Extracts control file fields from a .deb archive (ar archive)."""
    with open(deb_path, "rb") as f:
        magic = f.read(8)
        if magic != b"!<arch>\n":
            raise ValueError(f"Not a valid ar/deb archive: {deb_path}")
        
        while True:
            header = f.read(60)
            if len(header) < 60:
                break
            name = header[0:16].decode("ascii", errors="ignore").strip()
            size = int(header[48:58].decode("ascii", errors="ignore").strip())
            file_data = f.read(size)
            if size % 2 == 1:
                f.read(1) # ar 2-byte alignment padding
            
            if name.startswith("control.tar"):
                # Open tar archive from memory
                tar_bytes = io.BytesIO(file_data)
                mode = "r:gz" if name.endswith(".gz") else ("r:xz" if name.endswith(".xz") else "r:*")
                with tarfile.open(fileobj=tar_bytes, mode=mode) as tar:
                    for member in tar.getmembers():
                        if member.name.endswith("control") or member.name == "./control":
                            extracted = tar.extractfile(member)
                            if extracted:
                                return extracted.read().decode("utf-8", errors="replace")
    return None

def parse_control(control_text):
    fields = {}
    current_key = None
    for line in control_text.splitlines():
        if line.startswith(" ") or line.startswith("\t"):
            if current_key:
                fields[current_key] += "\n" + line
        elif ":" in line:
            key, val = line.split(":", 1)
            current_key = key.strip()
            fields[current_key] = val.strip()
    return fields

def format_control(fields):
    order = [
        "Package", "Name", "Version", "Architecture", "Maintainer", "Author",
        "Section", "Depends", "Tag", "SileoDepiction", "Icon", "Filename",
        "Size", "MD5sum", "SHA1", "SHA256", "Description"
    ]
    lines = []
    seen = set()
    for key in order:
        if key in fields:
            lines.append(f"{key}: {fields[key]}")
            seen.add(key)
    for key, val in fields.items():
        if key not in seen:
            lines.append(f"{key}: {val}")
    return "\n".join(lines) + "\n\n"

def collect_built_packages():
    """Collects packages built by Theos into the debs directory."""
    os.makedirs(DEBS_DIR, exist_ok=True)
    potential_dirs = [
        os.path.join(REPO_ROOT, "packages"),
        os.path.join(REPO_ROOT, "built_debs"),
        os.path.join(REPO_ROOT, "downloaded_debs"),
    ]
    tweaks_dir = os.path.join(REPO_ROOT, "Tweaks")
    if os.path.isdir(tweaks_dir):
        for tweak in os.listdir(tweaks_dir):
            potential_dirs.append(os.path.join(tweaks_dir, tweak, "packages"))

    for pdir in potential_dirs:
        if os.path.isdir(pdir):
            for fname in os.listdir(pdir):
                if fname.endswith(".deb"):
                    src = os.path.join(pdir, fname)
                    dst = os.path.join(DEBS_DIR, fname)
                    if not os.path.exists(dst) or os.path.getmtime(src) > os.path.getmtime(dst):
                        shutil.copy2(src, dst)
                        print(f"[*] Imported deb: {fname} -> debs/")

def build_repo():
    collect_built_packages()
    os.makedirs(DEBS_DIR, exist_ok=True)
    deb_files = [f for f in os.listdir(DEBS_DIR) if f.endswith(".deb")]
    if not deb_files:
        print("[!] No .deb packages found in debs/. Generating default package...")
        try:
            import package_yuna
            package_yuna.build_yuna_deb()
        except ImportError:
            sys.path.insert(0, os.path.dirname(__file__))
            import package_yuna
            package_yuna.build_yuna_deb()
        deb_files = [f for f in os.listdir(DEBS_DIR) if f.endswith(".deb")]
    
    package_entries = []
    print(f"[*] Scanning {len(deb_files)} package(s) in {DEBS_DIR}...")
    
    for deb in sorted(deb_files):
        deb_path = os.path.join(DEBS_DIR, deb)
        try:
            ctrl_text = read_control_from_deb(deb_path)
            if not ctrl_text:
                print(f"[!] Warning: Could not read control from {deb}")
                continue
            fields = parse_control(ctrl_text)
            hashes = get_hashes(deb_path)
            
            # Add relative filename and hashes
            fields["Filename"] = f"debs/{deb}"
            fields["Size"] = str(hashes["size"])
            fields["MD5sum"] = hashes["md5"]
            fields["SHA1"] = hashes["sha1"]
            fields["SHA256"] = hashes["sha256"]
            
            package_entries.append(format_control(fields))
            print(f"    + Added {fields.get('Package', deb)} ({fields.get('Version', '?')})")
        except Exception as e:
            print(f"[!] Error processing {deb}: {e}")
            
    # Write Packages
    packages_content = "".join(package_entries)
    packages_path = os.path.join(DIST_DIR, "Packages")
    with open(packages_path, "w", encoding="utf-8") as f:
        f.write(packages_content)
    print(f"[*] Wrote {packages_path} ({len(packages_content)} bytes)")
    
    # Write Packages.gz
    packages_gz_path = os.path.join(DIST_DIR, "Packages.gz")
    with gzip.open(packages_gz_path, "wb") as f:
        f.write(packages_content.encode("utf-8"))
    print(f"[*] Wrote {packages_gz_path}")
    
    # Generate Release file
    pkg_h = get_hashes(packages_path)
    pkg_gz_h = get_hashes(packages_gz_path)
    
    release_lines = [
        "Origin: Nishi",
        "Label: Nishi",
        "Suite: stable",
        "Version: 1.0",
        "Codename: ios",
        "Architectures: iphoneos-arm64",
        "Components: main",
        "Description: Rootless iOS jailbreak tweak repository by frosty",
        "MD5Sum:",
        f" {pkg_h['md5']} {pkg_h['size']} Packages",
        f" {pkg_gz_h['md5']} {pkg_gz_h['size']} Packages.gz",
        "SHA1:",
        f" {pkg_h['sha1']} {pkg_h['size']} Packages",
        f" {pkg_gz_h['sha1']} {pkg_gz_h['size']} Packages.gz",
        "SHA256:",
        f" {pkg_h['sha256']} {pkg_h['size']} Packages",
        f" {pkg_gz_h['sha256']} {pkg_gz_h['size']} Packages.gz",
        ""
    ]
    release_path = os.path.join(DIST_DIR, "Release")
    with open(release_path, "w", encoding="utf-8") as f:
        f.write("\n".join(release_lines))
    print(f"[*] Wrote {release_path}")
    print("[*] Repository index built successfully.")

if __name__ == "__main__":
    build_repo()
