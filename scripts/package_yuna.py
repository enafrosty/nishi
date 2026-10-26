#!/usr/bin/env python3
"""
Packages Yuna into a rootless .deb package adhering to Debian ar archive format.
Used for local testing and CI distribution in the Nishi repository.
"""

import os
import sys
import io
import time
import tarfile

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
YUNA_DIR = os.path.join(REPO_ROOT, "Tweaks", "Yuna")
DEBS_DIR = os.path.join(REPO_ROOT, "debs")

def create_ar_header(filename, size, mtime=None, mode=0o100644):
    if mtime is None:
        mtime = int(time.time())
    header = (
        f"{filename:<16}"
        f"{mtime:<12}"
        f"{'0':<6}"
        f"{'0':<6}"
        f"{oct(mode)[2:]:>8}"
        f"{size:<10}"
        "`\n"
    )
    return header.encode("ascii")

def build_yuna_deb(output_path=None):
    os.makedirs(DEBS_DIR, exist_ok=True)
    if not output_path:
        output_path = os.path.join(DEBS_DIR, "com.frosty.yuna_1.0.0_iphoneos-arm64.deb")
        
    print(f"[*] Packaging Yuna into {output_path}...")
    
    # 1. debian-binary
    debian_binary_data = b"2.0\n"
    
    # 2. control.tar.gz
    ctrl_buf = io.BytesIO()
    with tarfile.open(fileobj=ctrl_buf, mode="w:gz") as tar:
        # control file
        ctrl_path = os.path.join(YUNA_DIR, "control")
        with open(ctrl_path, "rb") as f:
            cdata = f.read()
        ti = tarfile.TarInfo("./control")
        ti.size = len(cdata)
        ti.mode = 0o644
        ti.mtime = int(time.time())
        tar.addfile(ti, io.BytesIO(cdata))
        
        # postinst
        postinst_path = os.path.join(YUNA_DIR, "layout", "DEBIAN", "postinst")
        if os.path.exists(postinst_path):
            with open(postinst_path, "rb") as f:
                pdata = f.read()
            ti = tarfile.TarInfo("./postinst")
            ti.size = len(pdata)
            ti.mode = 0o755
            ti.mtime = int(time.time())
            tar.addfile(ti, io.BytesIO(pdata))
            
        # prerm
        prerm_path = os.path.join(YUNA_DIR, "layout", "DEBIAN", "prerm")
        if os.path.exists(prerm_path):
            with open(prerm_path, "rb") as f:
                pdata = f.read()
            ti = tarfile.TarInfo("./prerm")
            ti.size = len(pdata)
            ti.mode = 0o755
            ti.mtime = int(time.time())
            tar.addfile(ti, io.BytesIO(pdata))
            
    control_tar_gz = ctrl_buf.getvalue()
    
    # 3. data.tar.gz
    data_buf = io.BytesIO()
    with tarfile.open(fileobj=data_buf, mode="w:gz") as tar:
        # Add rootless directories
        dirs = [
            "./var",
            "./var/jb",
            "./var/jb/Library",
            "./var/jb/Library/MobileSubstrate",
            "./var/jb/Library/MobileSubstrate/DynamicLibraries",
            "./var/jb/Library/PreferenceLoader",
            "./var/jb/Library/PreferenceLoader/Preferences",
            "./var/jb/Library/PreferenceBundles",
            "./var/jb/Library/PreferenceBundles/YunaPrefs.bundle",
            "./var/jb/Library/Application Support",
            "./var/jb/Library/Application Support/Yuna",
            "./var/jb/Library/Application Support/Yuna/Images"
        ]
        for d in dirs:
            ti = tarfile.TarInfo(d)
            ti.type = tarfile.DIRTYPE
            ti.mode = 0o755
            ti.mtime = int(time.time())
            tar.addfile(ti)
            
        # Add Yuna.plist
        yuna_plist = os.path.join(YUNA_DIR, "Yuna.plist")
        if os.path.exists(yuna_plist):
            with open(yuna_plist, "rb") as f:
                data = f.read()
            ti = tarfile.TarInfo("./var/jb/Library/MobileSubstrate/DynamicLibraries/Yuna.plist")
            ti.size = len(data)
            ti.mode = 0o644
            ti.mtime = int(time.time())
            tar.addfile(ti, io.BytesIO(data))

        # Check and add compiled Yuna.dylib binary if available
        dylib_candidates = [
            os.path.join(YUNA_DIR, ".theos", "obj", "debug", "Yuna.dylib"),
            os.path.join(YUNA_DIR, ".theos", "obj", "Yuna.dylib"),
            os.path.join(REPO_ROOT, ".theos", "obj", "debug", "Yuna.dylib"),
            os.path.join(REPO_ROOT, ".theos", "obj", "Yuna.dylib"),
            os.path.join(YUNA_DIR, "layout", "Library", "MobileSubstrate", "DynamicLibraries", "Yuna.dylib"),
        ]
        yuna_dylib = next((p for p in dylib_candidates if os.path.isfile(p)), None)
        if yuna_dylib:
            with open(yuna_dylib, "rb") as f:
                ddata = f.read()
            ti = tarfile.TarInfo("./var/jb/Library/MobileSubstrate/DynamicLibraries/Yuna.dylib")
            ti.size = len(ddata)
            ti.mode = 0o755
            ti.mtime = int(time.time())
            tar.addfile(ti, io.BytesIO(ddata))
            print(f"    + Packaged compiled tweak binary: {yuna_dylib} ({len(ddata)} bytes)")
        else:
            print("    [!] Note: Pre-compiled Yuna.dylib not found. Theos CI workflow builds arm64/arm64e fat binaries.")
            
        # Add PreferenceLoader entry
        pref_entry = os.path.join(YUNA_DIR, "layout", "Library", "PreferenceLoader", "Preferences", "Yuna.plist")
        if os.path.exists(pref_entry):
            with open(pref_entry, "rb") as f:
                data = f.read()
            ti = tarfile.TarInfo("./var/jb/Library/PreferenceLoader/Preferences/Yuna.plist")
            ti.size = len(data)
            ti.mode = 0o644
            ti.mtime = int(time.time())
            tar.addfile(ti, io.BytesIO(data))
            
        # Add Preferences resources
        res_dir = os.path.join(YUNA_DIR, "Preferences", "Resources")
        if os.path.exists(res_dir):
            for fname in os.listdir(res_dir):
                fpath = os.path.join(res_dir, fname)
                if os.path.isfile(fpath):
                    with open(fpath, "rb") as f:
                        data = f.read()
                    ti = tarfile.TarInfo(f"./var/jb/Library/PreferenceBundles/YunaPrefs.bundle/{fname}")
                    ti.size = len(data)
                    ti.mode = 0o644
                    ti.mtime = int(time.time())
                    tar.addfile(ti, io.BytesIO(data))

        # Check and add compiled YunaPrefs binary if available
        pref_candidates = [
            os.path.join(YUNA_DIR, "Preferences", ".theos", "obj", "debug", "YunaPrefs.bundle", "YunaPrefs"),
            os.path.join(YUNA_DIR, "Preferences", ".theos", "obj", "YunaPrefs.bundle", "YunaPrefs"),
            os.path.join(YUNA_DIR, "layout", "Library", "PreferenceBundles", "YunaPrefs.bundle", "YunaPrefs"),
        ]
        yuna_prefs = next((p for p in pref_candidates if os.path.isfile(p)), None)
        if yuna_prefs:
            with open(yuna_prefs, "rb") as f:
                pdata = f.read()
            ti = tarfile.TarInfo("./var/jb/Library/PreferenceBundles/YunaPrefs.bundle/YunaPrefs")
            ti.size = len(pdata)
            ti.mode = 0o755
            ti.mtime = int(time.time())
            tar.addfile(ti, io.BytesIO(pdata))
            print(f"    + Packaged compiled preferences binary: {yuna_prefs} ({len(pdata)} bytes)")
                    
    data_tar_gz = data_buf.getvalue()
    
    # 4. Assemble ar archive
    with open(output_path, "wb") as deb:
        deb.write(b"!<arch>\n")
        
        # debian-binary member
        deb.write(create_ar_header("debian-binary", len(debian_binary_data)))
        deb.write(debian_binary_data)
        if len(debian_binary_data) % 2 == 1:
            deb.write(b"\n")
            
        # control.tar.gz member
        deb.write(create_ar_header("control.tar.gz", len(control_tar_gz)))
        deb.write(control_tar_gz)
        if len(control_tar_gz) % 2 == 1:
            deb.write(b"\n")
            
        # data.tar.gz member
        deb.write(create_ar_header("data.tar.gz", len(data_tar_gz)))
        deb.write(data_tar_gz)
        if len(data_tar_gz) % 2 == 1:
            deb.write(b"\n")
            
    print(f"[*] Successfully built {output_path} ({os.path.getsize(output_path)} bytes)")

if __name__ == "__main__":
    build_yuna_deb()
