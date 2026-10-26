# How Yuna Works: Internal Architecture & Engineering

This document provides a technical walkthrough of **Yuna**, explaining how the tweak hooks into iOS, intercepts clipboard events across processes, manages persistent storage safely under rootless Dopamine, and dynamically calculates keyboard dock geometry.

---

## 1. System Architecture & Inter-Process Flow

iOS enforces strict sandboxing between applications. Furthermore, `SpringBoard` runs as the system shell with broad permissions, while keyboard views execute inside individual app host processes.

Yuna coordinates across this boundary using a split-process model:

```
┌───────────────────────────────────────────────────────────────┐
│                    SpringBoard (Daemon)                       │
│                                                               │
│   ┌────────────────────────────────────────────────────────┐  │
│   │                      YunaServer                        │  │
│   │   - Observes UIPasteboard & system pasteboard changes  │  │
│   │   - Downsamples & hashes images (SHA-256)              │  │
│   │   - Persists records via YunaStorage (history.plist)   │  │
│   └───────────────────────────┬────────────────────────────┘  │
└───────────────────────────────┼───────────────────────────────┘
                                │ Darwin Notification
                                │ (com.frosty.yuna/ClipboardChanged)
┌───────────────────────────────▼───────────────────────────────┐
│               App Host Process (Any UIKit App)                │
│                                                               │
│   ┌────────────────────────────────────────────────────────┐  │
│   │                  UIKeyboardDockView                    │  │
│   │   - yna_layoutDockButton inserts YunaDockButton        │  │
│   │   - Positions beside Dictation, Emoji, or Centered     │  │
│   └───────────────────────────┬────────────────────────────┘  │
│                               │ User Tap                      │
│   ┌───────────────────────────▼────────────────────────────┐  │
│   │                     YunaPanelView                      │  │
│   │   - Reads history from /var/jb/.../history.plist       │  │
│   │   - Computes dynamic rows (1, 2, 3, or 4 rows)         │  │
│   │   - Injects snippet into UIKeyboardImpl activeInstance │  │
│   └────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────┘
```

---

## 2. Keyboard Dock Injection & Layout

### 2.1 Hooking `UIKeyboardDockView`
On iPhones equipped with a Home Indicator (iPhone X and later), Apple positions a dedicated accessory bar below the keyboard: `UIKeyboardDockView`. This view normally holds the globe/emoji button on the left and the dictation button on the right.

In `Tweak.x`, Yuna hooks `UIKeyboardDockView`:
```objc
%hook UIKeyboardDockView

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        [self yna_registerPrefsObserver];
    }
}

- (void)layoutSubviews {
    %orig;
    [self yna_layoutDockButton];
}
```

### 2.2 Dock Button Positioning Algorithm
When `layoutSubviews` fires, `yna_layoutDockButton` dynamically queries the layout frames of adjacent dock items:
- **Next to Dictation (Default)**: Inspects `[self rightDockItem].button.frame`. If present, places the Yuna button 6 points to the left of the dictation button. If absent, anchors 12 points from the right edge.
- **Next to Emoji**: Inspects `[self leftDockItem].button.frame` and anchors 6 points to the right of the emoji button.
- **Center**: Calculates `(bounds.size.width - buttonWidth) / 2.0`.

This approach ensures zero collision with native iOS dock buttons across device rotations and keyboard layout changes.

---

## 3. SpringBoard Clipboard Interception (`YunaServer`)

### 3.1 Why SpringBoard?
Sandboxed third-party apps cannot reliably monitor pasteboard updates in the background. `SpringBoard` runs continuously as PID 1's main UI child, possessing universal visibility over pasteboard state changes.

### 3.2 Debounce & Main-Thread Safety
`UIPasteboard` must be queried on the main thread to prevent UIKit Main Thread Checker aborts. However, disk I/O and image processing must never block the main thread, or iOS Watchdog will terminate SpringBoard (`0x8badf00d`).

Yuna implements a dual-stage handler:
1. **Main Thread Check**: Compares `pasteboard.changeCount` with `_lastChangeCount`. If unchanged, exits immediately.
2. **Background Dispatch**: Dispatches the raw data to a private serial queue (`com.frosty.yuna.server`).

### 3.3 Image Processing & Jetsam Protection
High-resolution images copied to the clipboard can easily exceed 20–40 MB uncompressed, risking a Jetsam kill (`EXC_RESOURCE`).

When an image is intercepted:
1. Dimensions are checked: If either dimension exceeds 1200 px, the image is scaled proportionally down to 1200 px.
2. Compressed to JPEG (quality 0.85).
3. SHA-256 hashed to derive a unique filename (e.g. `a3f89e1b....png`).
4. Saved atomically into `/var/jb/Library/Application Support/Yuna/Images/`.
5. If the exact same image is copied again, the hash matches and the existing file is reused without disk bloat.

---

## 4. Storage Engine & Eviction Algorithm (`YunaStorage`)

### 4.1 Persistence Structure
Clipboard metadata is serialized as an array of dictionaries inside:
```
/var/jb/Library/Application Support/Yuna/history.plist
```
Every item contains:
- `uuid`: Unique identifier string
- `type`: Enum (Text, Image, URL, File)
- `timestamp`: Unix timestamp
- `isPinned`: Boolean flag
- `itemSize`: Byte size
- `text` / `imageRelativePath` / `fileURLString`

### 4.2 Deduplication Mechanics
When a new item is added:
- **Text & URLs**: Checks if an existing item has matching content. If so, updates the timestamp to "now", moves it to the top, and skips creating a duplicate entry.
- **Images**: Matches the SHA-256 relative path.
- **Files**: Matches the canonical file URL string.

### 4.3 Pruning & Pinning Preservation
When the unpinned item count exceeds `maxItems` (configurable 5 to 200, default 30):
```objc
// Unpinned items are sorted descending by timestamp before truncating
[unpinned sortUsingComparator:^NSComparisonResult(YunaItem *a, YunaItem *b) {
    if (a.timestamp > b.timestamp) return NSOrderedAscending;
    if (a.timestamp < b.timestamp) return NSOrderedDescending;
    return NSOrderedSame;
}];

if (unpinned.count > (NSUInteger)_maxItems) {
    NSRange deleteRange = NSMakeRange(_maxItems, unpinned.count - _maxItems);
    // Associated cached image files are deleted from disk
    for (YunaItem *item in toRemove) {
        [self _lockedDeleteAssociatedImageFileForItem:item];
    }
    [unpinned removeObjectsInRange:deleteRange];
}
```
**Invariant**: Pinned items are stored in a separate collection during pruning and are **never** evaluated for eviction.

---

## 5. UI Presentation & Direct Input Insertion

### 5.1 Panel Presentation
Tapping the keyboard dock button triggers `YunaPanelView`. The panel slides smoothly above the dock view using a spring animation (`damping: 0.86, velocity: 0.2`).

### 5.2 Direct Insertion via `UIKeyboardImpl`
Traditional clipboard tweaks copy items back to `UIPasteboard`, forcing the user to tap the text field, wait for the callout bar, and select "Paste".

Yuna bypasses this using runtime reflection into `UIKeyboardImpl`:
```objc
Class kbClass = NSClassFromString(@"UIKeyboardImpl");
id kb = nil;
if (kbClass && [kbClass respondsToSelector:@selector(activeInstance)]) {
    kb = [kbClass performSelector:@selector(activeInstance)];
}
if (kb && [kb respondsToSelector:@selector(insertText:)]) {
    [kb performSelector:@selector(insertText:) withObject:textToInsert];
    return;
}
```
If `UIKeyboardImpl` is inaccessible, Yuna gracefully falls back to setting `[UIPasteboard generalPasteboard].string`.

---

## 6. Mathematical Row Layout Geometry

In `YunaPanelView`, the item height is computed dynamically so that cards evenly fill the available keyboard vertical area without clipping:

$$\text{totalSpacing} = \text{inset.top} + \text{inset.bottom} + (\text{interItemSpacing} \times (\text{rows} - 1))$$

$$\text{availableHeight} = \max(40.0, \, \text{containerHeight} - \text{totalSpacing})$$

$$\text{itemHeight} = \left\lfloor \frac{\text{availableHeight}}{\text{rows}} \right\rfloor$$

- **1 Row**: Cards occupy the full height ($168\text{ px}$ in standard mode) with extra width ($250\text{ px}$).
- **2 Rows (Default)**: Balanced height ($80\text{ px}$) showing two lines of snippet preview.
- **3–4 Rows**: Compact cards ($50\text{ px}$ and $36\text{ px}$) hiding subtitles for dense matrix navigation.

---

## 7. Rootless & PAC Engineering Invariants

### 7.1 Rootless Dopamine Paths (`/var/jb`)
Under rootless jailbreaks, the root filesystem (`/`) is immutable. All tweak resources reside under `/var/jb`:
- Dynamic libraries: `/var/jb/Library/MobileSubstrate/DynamicLibraries/`
- Preference bundles: `/var/jb/Library/PreferenceBundles/`
- History storage: `/var/jb/Library/Application Support/Yuna/`

**Critical Rule**: User preferences (`com.frosty.yuna.plist`) MUST reside in standard `/var/mobile/Library/Preferences/` without the `/var/jb` prefix, because `cfprefsd` manages this path globally.

### 7.2 ARM64e Hardware PAC (Pointer Authentication)
A12 and A13 chips cryptographically sign code pointers. Overwriting function pointers in vtables directly triggers a hardware `AUTIA` kernel panic.

Yuna avoids all raw pointer modification by relying on **ElleKit trampolines**:
- Instructions at the target function entry are rewritten into branch trampolines.
- The original pointer remains signed and authentic.
- `TARGET = iphone:clang:latest:15.0` with `ARCHS = arm64 arm64e` produces clean dual-slice Mach-O binaries.
