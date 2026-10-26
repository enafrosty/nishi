#!/usr/bin/env python3
"""
Verification Test Suite for Yuna (iOS Rootless Tweak - Nishi Repository)
Validates Plist configurations, Sileo depiction, Debian control files,
Makefiles, Rootless path logic, PreferenceLoader staging, and Storage/Row layout algorithms.
"""

import os
import sys
import json
import plistlib
import subprocess

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
YUNA_DIR = os.path.join(REPO_ROOT, "Tweaks", "Yuna")

passed = 0
failed = 0

def test(name):
    def decorator(fn):
        def wrapper(*args, **kwargs):
            global passed, failed
            try:
                fn(*args, **kwargs)
                print(f"  [PASS] {name}")
                passed += 1
            except AssertionError as e:
                print(f"  [FAIL] {name}: {e}")
                failed += 1
            except Exception as e:
                print(f"  [ERROR] {name}: {type(e).__name__}: {e}")
                failed += 1
        return wrapper
    return decorator


print("=" * 60)
print("RUNNING YUNA VERIFICATION TEST SUITE")
print("=" * 60)

# ---------------------------------------------------------
# 1. Plist & Configuration Tests
# ---------------------------------------------------------
print("\n[Section 1: Plist & Filter Manifest Tests]")

@test("Yuna.plist Filter Structure & Safety")
def test_filter_plist():
    plist_path = os.path.join(YUNA_DIR, "Yuna.plist")
    assert os.path.exists(plist_path), f"Missing {plist_path}"
    with open(plist_path, "rb") as f:
        data = plistlib.load(f)
    assert "Filter" in data, "Missing Filter dictionary"
    bundles = data["Filter"].get("Bundles", [])
    assert "com.apple.springboard" in bundles, "Must target com.apple.springboard"
    assert "com.apple.UIKitCore" in bundles, "Must target com.apple.UIKitCore"
    assert "com.apple.UIKit" not in bundles, "Wildcard com.apple.UIKit should not be used directly without Core"

@test("Preferences entry.plist Structure")
def test_entry_plist():
    entry_path = os.path.join(YUNA_DIR, "Preferences", "entry.plist")
    assert os.path.exists(entry_path), f"Missing {entry_path}"
    with open(entry_path, "rb") as f:
        data = plistlib.load(f)
    entry = data.get("entry", {})
    assert entry.get("bundle") == "YunaPrefs", f"Expected bundle YunaPrefs, got {entry.get('bundle')}"
    assert entry.get("cell") == "PSLinkCell", "Expected PSLinkCell"
    assert entry.get("detail") == "YNARootListController", "Expected detail YNARootListController"
    assert entry.get("label") == "Yuna", "Expected label Yuna"

@test("Preferences Root.plist Specifiers & Row Management")
def test_root_plist():
    root_path = os.path.join(YUNA_DIR, "Preferences", "Resources", "Root.plist")
    assert os.path.exists(root_path), f"Missing {root_path}"
    with open(root_path, "rb") as f:
        data = plistlib.load(f)
    items = data.get("items", [])
    assert len(items) > 0, "Root.plist items is empty"
    
    keys = {item.get("key"): item for item in items if "key" in item}
    assert "enabled" in keys, "Missing enabled toggle switch"
    assert "numberOfRows" in keys, "Missing numberOfRows segment/picker for managing rows"
    
    # Check rows valid values
    row_spec = keys["numberOfRows"]
    assert row_spec.get("cell") == "PSSegmentCell", "Expected PSSegmentCell for numberOfRows"
    assert row_spec.get("default") == 2, "Default rows should be 2"
    assert row_spec.get("validValues") == [1, 2, 3, 4], "Valid row values must be [1, 2, 3, 4]"
    assert row_spec.get("PostNotification") == "com.frosty.yuna/ReloadPrefs", "Expected reload Darwin notification"
    
    assert "saveImages" in keys, "Missing saveImages toggle"
    assert "saveFiles" in keys, "Missing saveFiles toggle"
    assert "hapticFeedback" in keys, "Missing hapticFeedback segment"
    assert "dockPosition" in keys, "Missing dockPosition segment"
    
    # Actions
    actions = [item.get("action") for item in items if "action" in item]
    assert "clearUnpinnedHistory:" in actions, "Missing clearUnpinnedHistory action"
    assert "clearAllHistory:" in actions, "Missing clearAllHistory action"
    assert "respring:" in actions, "Missing respring action"

test_filter_plist()
test_entry_plist()
test_root_plist()

# ---------------------------------------------------------
# 2. Package Manager & Sileo Depiction Tests
# ---------------------------------------------------------
print("\n[Section 2: Sileo & Packaging Standards]")

@test("Debian Control File Format & Sileo Attributes")
def test_control_file():
    ctrl_path = os.path.join(YUNA_DIR, "control")
    assert os.path.exists(ctrl_path), f"Missing {ctrl_path}"
    with open(ctrl_path, "r", encoding="utf-8") as f:
        content = f.read()
    
    lines = content.strip().split("\n")
    fields = {}
    for line in lines:
        if ":" in line:
            k, v = line.split(":", 1)
            fields[k.strip()] = v.strip()
            
    assert fields.get("Package") == "com.frosty.yuna", f"Expected com.frosty.yuna, got {fields.get('Package')}"
    assert fields.get("Architecture") == "iphoneos-arm64", f"Rootless architecture must be iphoneos-arm64, got {fields.get('Architecture')}"
    assert "ellekit" in fields.get("Depends", ""), "Must depend on ellekit for arm64e PAC support"
    assert "preferenceloader" in fields.get("Depends", ""), "Must depend on preferenceloader"
    assert "SileoDepiction" in fields, "Must include SileoDepiction field for Sileo compatibility"
    assert "cydia::respring" in fields.get("Tag", ""), "Must include cydia::respring tag for native Sileo respring button"

@test("Sileo Depiction JSON Schema & Compatibility")
def test_sileo_depiction():
    depiction_path = os.path.join(YUNA_DIR, "depiction", "depiction.json")
    assert os.path.exists(depiction_path), f"Missing {depiction_path}"
    with open(depiction_path, "r", encoding="utf-8") as f:
        data = json.load(f)
    assert data.get("minVersion") == "0.4", "Expected minVersion 0.4"
    assert "tabs" in data, "Missing tabs in depiction"
    assert len(data["tabs"]) >= 2, "Expected at least Details and Changelog tabs"
    
    details_tab = data["tabs"][0]
    assert details_tab.get("tabname") == "Details"
    views = details_tab.get("views", [])
    markdown_views = [v for v in views if v.get("class") == "DepictionMarkdownView"]
    assert len(markdown_views) > 0, "Missing markdown view in details tab"

@test("Maintainer Scripts (postinst / prerm) Safety Audit")
def test_maintainer_scripts():
    postinst = os.path.join(YUNA_DIR, "layout", "DEBIAN", "postinst")
    prerm = os.path.join(YUNA_DIR, "layout", "DEBIAN", "prerm")
    
    # If maintainer scripts are present, ensure they do not perform hard kills
    if os.path.exists(postinst):
        with open(postinst, "r", encoding="utf-8") as f:
            postinst_src = f.read()
        assert "sbreload" not in postinst_src, "postinst must not call sbreload directly; rely on cydia::respring for native Sileo button"
    if os.path.exists(prerm):
        with open(prerm, "r", encoding="utf-8") as f:
            prerm_src = f.read()
        assert "killall -HUP SpringBoard" not in prerm_src, "prerm must not abruptly kill SpringBoard"

@test("PreferenceLoader Staging and Resource Icons")
def test_preferenceloader_staging():
    pref_layout_plist = os.path.join(YUNA_DIR, "layout", "Library", "PreferenceLoader", "Preferences", "Yuna.plist")
    assert os.path.exists(pref_layout_plist), f"Missing staged PreferenceLoader entry plist: {pref_layout_plist}"
    with open(pref_layout_plist, "rb") as f:
        data = plistlib.load(f)
    entry = data.get("entry", {})
    assert entry.get("bundle") == "YunaPrefs", "Entry bundle must be YunaPrefs"
    
    # Check icons exist in bundle Resources
    icon1 = os.path.join(YUNA_DIR, "Preferences", "Resources", "icon.png")
    icon2 = os.path.join(YUNA_DIR, "Preferences", "Resources", "icon@2x.png")
    assert os.path.exists(icon1), "Missing Preferences/Resources/icon.png"
    assert os.path.exists(icon2), "Missing Preferences/Resources/icon@2x.png"
    
    # Check internal-stage in Preferences Makefile
    pref_mk = os.path.join(YUNA_DIR, "Preferences", "Makefile")
    with open(pref_mk, "r", encoding="utf-8") as f:
        mk_content = f.read()
    assert "internal-stage::" in mk_content, "Preferences/Makefile must include internal-stage rule"

test_control_file()
test_sileo_depiction()
test_maintainer_scripts()
test_preferenceloader_staging()

# ---------------------------------------------------------
# 3. Toolchain & Makefile Invariants
# ---------------------------------------------------------
print("\n[Section 3: Build & Toolchain Compliance]")

@test("Root Makefile & Architecture Targeting")
def test_makefiles():
    root_mk = os.path.join(REPO_ROOT, "Makefile")
    assert os.path.exists(root_mk), "Missing root Makefile"
    with open(root_mk, "r", encoding="utf-8") as f:
        content = f.read()
    assert "THEOS_PACKAGE_SCHEME := rootless" in content, "Root Makefile must enforce rootless package scheme"
    assert "SUBPROJECTS += Tweaks/Yuna" in content, "Root Makefile must include Yuna subproject"
    
    tweak_mk = os.path.join(YUNA_DIR, "Makefile")
    assert os.path.exists(tweak_mk), "Missing Tweaks/Yuna/Makefile"
    with open(tweak_mk, "r", encoding="utf-8") as f:
        tweak_content = f.read()
    assert "ARCHS := arm64 arm64e" in tweak_content, "Tweak Makefile must compile both arm64 and arm64e slices"
    assert "THEOS_PACKAGE_SCHEME := rootless" in tweak_content, "Tweak Makefile must be rootless"
    assert "Yuna_LIBRARIES = ellekit" in tweak_content, "Tweak must link ellekit"

@test("Rootless Path Safety Audit in Source Files")
def test_source_rootless_audit():
    # Verify no naked legacy root paths without JBROOT_PATH
    forbidden = ["/Library/MobileSubstrate", "/Library/PreferenceLoader", "/Library/Application Support/"]
    source_dir = os.path.join(YUNA_DIR, "Source")
    for root, _, files in os.walk(source_dir):
        for file in files:
            if file.endswith((".m", ".x", ".h")):
                path = os.path.join(root, file)
                with open(path, "r", encoding="utf-8", errors="ignore") as f:
                    lines = f.readlines()
                for line_idx, line in enumerate(lines, start=1):
                    if "JBROOT_PATH" in line:
                        continue
                    for bad in forbidden:
                        assert bad not in line, f"Naked legacy root path '{bad}' in {file}:{line_idx} without JBROOT_PATH!"

@test("Preferences Path Safety Audit (/var/mobile vs /var/jb)")
def test_preferences_path_audit():
    common_h = os.path.join(YUNA_DIR, "Source", "Headers", "YunaCommon.h")
    with open(common_h, "r", encoding="utf-8") as f:
        content = f.read()
    assert 'JBROOT_PATH("/var/mobile' not in content, "YUNA_PREFS_FILE must NOT use JBROOT_PATH on /var/mobile"
    assert '"/var/mobile/Library/Preferences/com.frosty.yuna.plist"' in content, "YUNA_PREFS_FILE must point to /var/mobile/Library/Preferences/"
    assert "YUNA_EXT_PASTEBOARD_NOTIFICATION" in content, "Must define YUNA_EXT_PASTEBOARD_NOTIFICATION"

test_makefiles()
test_source_rootless_audit()
test_preferences_path_audit()

# ---------------------------------------------------------
# 4. Algorithmic Simulation: Storage & Pinning
# ---------------------------------------------------------
print("\n[Section 4: Storage, Pinning & Pruning Logic]")

class MockYunaItem:
    def __init__(self, uuid, item_type, text="", rel_path="", file_url="", is_pinned=False, timestamp=0.0, item_size=0):
        self.uuid = uuid
        self.item_type = item_type
        self.text = text
        self.rel_path = rel_path
        self.file_url = file_url
        self.is_pinned = is_pinned
        self.timestamp = timestamp
        self.item_size = item_size

class MockYunaStorage:
    def __init__(self, max_items=30):
        self.max_items = max_items
        self.items = []
        
    def add_item(self, item):
        # Accurate deduplication check
        for existing in self.items:
            if existing.item_type == item.item_type:
                if item.item_type in ("text", "url"):
                    if existing.text == item.text:
                        existing.timestamp = item.timestamp
                        self._prune()
                        return True
                elif item.item_type == "image":
                    if existing.rel_path and existing.rel_path == item.rel_path:
                        existing.timestamp = item.timestamp
                        self._prune()
                        return True
                elif item.item_type == "file":
                    if existing.file_url and existing.file_url == item.file_url:
                        existing.timestamp = item.timestamp
                        self._prune()
                        return True
                        
        self.items.insert(0, item)
        self._prune()
        return True
        
    def _prune(self):
        pinned = [it for it in self.items if it.is_pinned]
        unpinned = [it for it in self.items if not it.is_pinned]
        
        # Sort unpinned descending by timestamp BEFORE truncating
        unpinned.sort(key=lambda x: -x.timestamp)
        pinned.sort(key=lambda x: -x.timestamp)
        
        if len(unpinned) > self.max_items:
            unpinned = unpinned[:self.max_items]
            
        self.items = pinned + unpinned
        
    def toggle_pin(self, uuid):
        for it in self.items:
            if it.uuid == uuid:
                it.is_pinned = not it.is_pinned
                break
        self._prune()
        
    def clear_unpinned(self):
        self.items = [it for it in self.items if it.is_pinned]
        self._prune()

@test("Storage Deduplication Behavior")
def test_storage_deduplication():
    storage = MockYunaStorage(max_items=10)
    item1 = MockYunaItem("1", "text", text="Hello World", is_pinned=False, timestamp=100.0)
    item2 = MockYunaItem("2", "text", text="Hello World", is_pinned=False, timestamp=200.0)
    
    storage.add_item(item1)
    assert len(storage.items) == 1
    assert storage.items[0].timestamp == 100.0
    
    # Adding duplicate text must update timestamp and NOT increase count
    storage.add_item(item2)
    assert len(storage.items) == 1
    assert storage.items[0].timestamp == 200.0

@test("Multi-Type Deduplication (Images SHA-256 and File URLs)")
def test_multitype_deduplication():
    storage = MockYunaStorage(max_items=10)
    
    # Two different images with same size (4096 bytes) but different hashes
    img1 = MockYunaItem("i1", "image", rel_path="hash_aaa.png", is_pinned=False, timestamp=10.0, item_size=4096)
    img2 = MockYunaItem("i2", "image", rel_path="hash_bbb.png", is_pinned=False, timestamp=20.0, item_size=4096)
    storage.add_item(img1)
    storage.add_item(img2)
    assert len(storage.items) == 2, "Images with different hashes must not be treated as duplicates!"
    
    # Re-adding img1 must deduplicate based on hash
    img1_again = MockYunaItem("i1_new", "image", rel_path="hash_aaa.png", is_pinned=False, timestamp=30.0, item_size=4096)
    storage.add_item(img1_again)
    assert len(storage.items) == 2
    assert storage.items[0].timestamp == 30.0
    
    # File URLs deduplication
    f1 = MockYunaItem("f1", "file", file_url="file:///tmp/sample.pdf", timestamp=40.0)
    f2 = MockYunaItem("f2", "file", file_url="file:///tmp/sample.pdf", timestamp=50.0)
    storage.add_item(f1)
    storage.add_item(f2)
    file_items = [it for it in storage.items if it.item_type == "file"]
    assert len(file_items) == 1, "File URLs must be deduplicated"
    assert file_items[0].timestamp == 50.0

@test("Pinning Protection During Pruning")
def test_pinning_protection():
    storage = MockYunaStorage(max_items=5)
    
    # Add 5 items
    for i in range(5):
        it = MockYunaItem(f"item_{i}", "text", text=f"Snippet {i}", is_pinned=False, timestamp=float(i))
        storage.add_item(it)
    assert len(storage.items) == 5
    
    # Pin snippet 2 and 4
    storage.toggle_pin("item_2")
    storage.toggle_pin("item_4")
    
    # Add 10 new unpinned snippets
    for i in range(10, 20):
        it = MockYunaItem(f"item_{i}", "text", text=f"Snippet {i}", is_pinned=False, timestamp=float(i))
        storage.add_item(it)
        
    # Total items should be: 2 pinned items + 5 unpinned items = 7 items
    assert len(storage.items) == 7, f"Expected 7 items (2 pinned + 5 unpinned), got {len(storage.items)}"
    uuids = [it.uuid for it in storage.items]
    assert "item_2" in uuids, "Pinned item_2 was unexpectedly pruned!"
    assert "item_4" in uuids, "Pinned item_4 was unexpectedly pruned!"
    assert storage.items[0].is_pinned, "First item in list must be pinned"
    assert storage.items[1].is_pinned, "Second item in list must be pinned"

@test("Pruning Sort Order Preserves Promoted Items")
def test_pruning_order_promotion():
    storage = MockYunaStorage(max_items=3)
    # Add 3 items
    storage.add_item(MockYunaItem("1", "text", text="Alpha", timestamp=10.0))
    storage.add_item(MockYunaItem("2", "text", text="Beta", timestamp=20.0))
    storage.add_item(MockYunaItem("3", "text", text="Gamma", timestamp=30.0))
    
    # Re-copy "Alpha" (item 1) with timestamp 100.0, promoting it
    storage.add_item(MockYunaItem("1_again", "text", text="Alpha", timestamp=100.0))
    
    # Add a new item "Delta"
    storage.add_item(MockYunaItem("4", "text", text="Delta", timestamp=110.0))
    
    # Capacity is 3: items should be Delta (110), Alpha (100), Gamma (30). Beta (20) should be pruned!
    assert len(storage.items) == 3
    texts = [it.text for it in storage.items]
    assert "Alpha" in texts, "Promoted item 'Alpha' was incorrectly pruned due to premature truncation!"
    assert "Delta" in texts, "Newest item 'Delta' must be present!"
    assert "Gamma" in texts, "Item 'Gamma' must be present!"
    assert "Beta" not in texts, "Oldest item 'Beta' must have been pruned!"

@test("Clear Unpinned Items Preserves Pinned Snippets")
def test_clear_unpinned():
    storage = MockYunaStorage(max_items=10)
    storage.add_item(MockYunaItem("p1", "text", text="Pinned 1", is_pinned=True, timestamp=10.0))
    storage.add_item(MockYunaItem("u1", "text", text="Unpinned 1", is_pinned=False, timestamp=11.0))
    storage.add_item(MockYunaItem("u2", "text", text="Unpinned 2", is_pinned=False, timestamp=12.0))
    
    assert len(storage.items) == 3
    storage.clear_unpinned()
    assert len(storage.items) == 1
    assert storage.items[0].uuid == "p1"
    assert storage.items[0].is_pinned == True

test_storage_deduplication()
test_multitype_deduplication()
test_pinning_protection()
test_pruning_order_promotion()
test_clear_unpinned()

# ---------------------------------------------------------
# 5. Algorithmic Simulation: Row Management & Layout
# ---------------------------------------------------------
print("\n[Section 5: Row Management & Geometry Calculations]")

def calculate_cell_size(total_height, rows, section_inset_top=6.0, section_inset_bottom=6.0, spacing=8.0):
    clamped_rows = rows
    if clamped_rows < 1:
        clamped_rows = 1
    if clamped_rows > 4:
        clamped_rows = 4
        
    total_spacing = section_inset_top + section_inset_bottom + (spacing * (clamped_rows - 1))
    available_height = total_height - total_spacing
    if available_height < 40.0:
        available_height = 40.0
        
    item_height = available_height // clamped_rows
    item_width = 250.0 if clamped_rows == 1 else 210.0
    return item_width, item_height

@test("Row Geometry for 1, 2, 3, and 4 Rows")
def test_row_geometry():
    container_height = 180.0
    
    # 1 Row
    w1, h1 = calculate_cell_size(container_height, 1)
    assert w1 == 250.0
    assert h1 == (180.0 - 12.0) // 1  # 168.0
    
    # 2 Rows (Default)
    w2, h2 = calculate_cell_size(container_height, 2)
    assert w2 == 210.0
    assert h2 == (180.0 - 12.0 - 8.0) // 2  # 80.0
    
    # 3 Rows
    w3, h3 = calculate_cell_size(container_height, 3)
    assert w3 == 210.0
    assert h3 == (180.0 - 12.0 - 16.0) // 3  # 50.0
    
    # 4 Rows
    w4, h4 = calculate_cell_size(container_height, 4)
    assert w4 == 210.0
    assert h4 == (180.0 - 12.0 - 24.0) // 4  # 36.0

@test("Row Boundary Clamping (Zero, Negative, Excess Rows)")
def test_row_clamping():
    container_height = 180.0
    
    # Test zero rows clamped to 1
    w0, h0 = calculate_cell_size(container_height, 0)
    w1, h1 = calculate_cell_size(container_height, 1)
    assert (w0, h0) == (w1, h1), "Rows <= 0 must clamp to 1"
    
    # Test negative rows clamped to 1
    wn, hn = calculate_cell_size(container_height, -5)
    assert (wn, hn) == (w1, h1), "Negative rows must clamp to 1"
    
    # Test excess rows clamped to 4
    w10, h10 = calculate_cell_size(container_height, 10)
    w4, h4 = calculate_cell_size(container_height, 4)
    assert (w10, h10) == (w4, h4), "Rows > 4 must clamp to 4"

test_row_geometry()
test_row_clamping()

# ---------------------------------------------------------
# 6. Repository, Webpage & GitHub Actions Infrastructure
# ---------------------------------------------------------
print("\n[Section 6: Repository, Webpage & CI/CD Infrastructure]")

@test("Webpage (index.html) Sileo Adder & Modern Styling")
def test_webpage():
    index_path = os.path.join(REPO_ROOT, "index.html")
    assert os.path.exists(index_path), f"Missing {index_path}"
    with open(index_path, "r", encoding="utf-8") as f:
        html = f.read()
    
    assert "sileo://source/" in html or "sileo://" in html, "Webpage must include direct Sileo adder URL scheme"
    assert "zbra://sources/add/" in html or "zbra://" in html, "Webpage must include Zebra adder scheme"
    assert "YUNA" in html, "Webpage must showcase Yuna tweak"
    assert "--sign" in html and "--mono" in html, "Webpage must use typography tokens inspired by ranking.heyfrosty.space"
    assert "#0D0B0C" in html or "#0d0b0c" in html, "Webpage must use dark aesthetic color palette"
    assert "CydiaIcon.png" in html, "Webpage must reference repository icon"

@test("APT & Sileo Repository Index Files (Packages, Release)")
def test_repo_distribution_files():
    packages_path = os.path.join(REPO_ROOT, "Packages")
    packages_gz = os.path.join(REPO_ROOT, "Packages.gz")
    release_path = os.path.join(REPO_ROOT, "Release")
    icon_path = os.path.join(REPO_ROOT, "CydiaIcon.png")
    
    assert os.path.exists(packages_path), f"Missing {packages_path}"
    assert os.path.exists(packages_gz), f"Missing {packages_gz}"
    assert os.path.exists(release_path), f"Missing {release_path}"
    assert os.path.exists(icon_path), f"Missing {icon_path}"
    
    with open(packages_path, "r", encoding="utf-8") as f:
        pkg_data = f.read()
    assert "Package: com.frosty.yuna" in pkg_data, "Packages file must index com.frosty.yuna"
    assert "Filename: debs/" in pkg_data, "Packages file must define Filename entry"
    assert "SHA256:" in pkg_data, "Packages file must include SHA256 checksums"
    
    with open(release_path, "r", encoding="utf-8") as f:
        rel_data = f.read()
    assert "Origin: Nishi" in rel_data, "Release file must set Origin: Nishi"
    assert "Packages" in rel_data, "Release file must reference Packages checksums"

@test("Explanatory Documentation & READMEs")
def test_documentation_files():
    root_readme = os.path.join(REPO_ROOT, "README.md")
    yuna_readme = os.path.join(YUNA_DIR, "README.md")
    yuna_how = os.path.join(YUNA_DIR, "docs", "HOW_IT_WORKS.md")
    
    assert os.path.exists(root_readme), f"Missing {root_readme}"
    assert os.path.exists(yuna_readme), f"Missing {yuna_readme}"
    assert os.path.exists(yuna_how), f"Missing {yuna_how}"
    
    with open(root_readme, "r", encoding="utf-8") as f:
        root_text = f.read()
    assert "repository" in root_text.lower(), "Root README must describe Nishi as a repository"
    assert "Yuna" in root_text, "Root README must list Yuna tweak"
    
    with open(yuna_how, "r", encoding="utf-8") as f:
        how_text = f.read()
    assert "UIKeyboardDockView" in how_text, "HOW_IT_WORKS must explain dock view injection"
    assert "YunaServer" in how_text, "HOW_IT_WORKS must explain SpringBoard clipboard server"
    assert "YunaStorage" in how_text, "HOW_IT_WORKS must explain storage & pruning mechanics"
    assert "PAC" in how_text or "ElleKit" in how_text, "HOW_IT_WORKS must explain PAC and ElleKit safety"

@test("GitHub Actions Workflow Definition")
def test_github_actions_workflow():
    workflow_path = os.path.join(REPO_ROOT, ".github", "workflows", "deploy.yml")
    assert os.path.exists(workflow_path), f"Missing {workflow_path}"
    with open(workflow_path, "r", encoding="utf-8") as f:
        wf = f.read()
    assert "actions/checkout" in wf, "Workflow must checkout repository"
    assert "actions/deploy-pages" in wf, "Workflow must deploy to GitHub Pages"
    assert "test_suite.py" in wf, "Workflow must run verification test suite"
    assert "build_repo.py" in wf, "Workflow must build repository indices"
    assert "theos-action" in wf or "make package" in wf, "Workflow must support Theos tweak packaging"

test_webpage()
test_repo_distribution_files()
test_documentation_files()
test_github_actions_workflow()

# ---------------------------------------------------------
# Summary
# ---------------------------------------------------------
print("\n" + "=" * 60)
print(f"TEST RESULTS: {passed} PASSED, {failed} FAILED")
print("=" * 60)

if failed > 0:
    sys.exit(1)
else:
    sys.exit(0)

