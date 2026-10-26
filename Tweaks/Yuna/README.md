# Yuna — Universal iOS Keyboard Clipboard Manager

[![Repository: Nishi](https://img.shields.io/badge/repo-Nishi-orange.svg)](https://github.com/enafrosty/Nishi)
[![Version](https://img.shields.io/badge/version-1.0.0-green.svg)](https://github.com/enafrosty/Nishi)
[![Target](https://img.shields.io/badge/target-iOS%2015.0%2B-blue.svg)](https://github.com/enafrosty/Nishi)
[![Architectures](https://img.shields.io/badge/archs-arm64%20%7C%20arm64e-purple.svg)](https://github.com/enafrosty/Nishi)
[![Scheme](https://img.shields.io/badge/scheme-rootless-brightgreen.svg)](https://github.com/enafrosty/Nishi)

**Yuna** is a rootless iOS clipboard manager tweak hosted inside the **[Nishi Repository](file:///c:/Users/frosty/Projects/Nishi/README.md)**. Built for modern Dopamine jailbreaks on iOS 15.0 through 16.x+, Yuna embeds a clipboard trigger directly into Apple's native keyboard dock (`UIKeyboardDockView`), giving you instant access to your text snippets, photos, web links, and file URLs without switching apps.

For a technical breakdown of Yuna's internal design, see **[How Yuna Works](file:///c:/Users/frosty/Projects/Nishi/Tweaks/Yuna/docs/HOW_IT_WORKS.md)**.

---

## Key Features

- **Keyboard Dock Integration**:
  - Adds a dedicated, tactile clipboard button into `UIKeyboardDockView` beside emoji and dictation.
  - Configurable dock position: Next to Dictation, Centered, or Next to Emoji.
- **Universal Content Capture**:
  - Automatically records copied snippets across all apps via the `SpringBoard` pasteboard daemon (`YunaServer`).
  - Supports **Plain Text**, **Formatted URLs**, **High-Resolution Images** (with memory-safe downsampling to prevent Jetsam kills), and **File URLs**.
- **Pinning System**:
  - Pin important snippets so they stay at the top.
  - Pinned items are **never** auto-purged or evicted when clipboard limits are reached.
- **Customizable Row Layouts (1–4 Rows)**:
  - Configure between **1, 2, 3, or 4 rows** of snippet cards in the keyboard panel.
  - 1 Row: Full-height compact horizontal strip.
  - 2 Rows: Balanced standard grid (default).
  - 3–4 Rows: Dense multi-card matrix for power users.
- **Direct Input Responder Insertion**:
  - Tapping a text snippet inserts text directly into the active `UIKeyboardImpl` input responder without additional paste taps.
  - Tapping an image or file updates `UIPasteboard` and triggers paste.
- **Rootless & PAC Safe**:
  - Built for modern Dopamine jailbreaks (`/var/jb`).
  - Full arm64e hardware PAC compliance on A12/A13 chips via **ElleKit** trampolines.
  - Native Sileo JSON depiction schema included.

---

## Directory Layout

```
Tweaks/Yuna/
├── Makefile                                # Theos build definition (arm64 & arm64e)
├── control                                 # Debian package control file with SileoDepiction
├── Yuna.plist                              # Tweak injection filter (SpringBoard & UIKitCore)
├── Source/
│   ├── Headers/
│   │   ├── YunaCommon.h                    # Paths, notifications, enums, macros
│   │   └── UIKeyboardPrivate.h             # Private UIKit keyboard declarations
│   ├── Tweak.x                             # Logos hooks for SpringBoard & UIKeyboardDockView
│   ├── YunaItem.h / .m                     # Data model (text, image, url, file, pin)
│   ├── YunaStorage.h / .m                  # Thread-safe storage & deduplication engine
│   ├── YunaServer.h / .m                   # SpringBoard clipboard observer daemon
│   └── UI/
│       ├── YunaDockButton.h / .m           # Keyboard dock trigger button
│       ├── YunaItemCell.h / .m             # UICollectionViewCell with pin styling
│       ├── YunaPanelView.h / .m            # Keyboard popup overlay with row layouts
│       └── YunaSettingsHelper.h / .m       # Preferences manager & Darwin notify listener
├── Preferences/                            # PreferenceLoader settings bundle
│   ├── Makefile
│   ├── entry.plist                         # Settings app entry specifier
│   ├── Resources/
│   │   ├── Root.plist                      # Settings UI (rows, pinning, limits, haptics)
│   │   ├── icon.png                        # Settings icon
│   │   └── icon@2x.png
│   └── Source/
│       └── YNARootListController.h / .m    # Action handlers (clear, respring)
├── depiction/
│   └── depiction.json                      # Native Sileo JSON depiction schema
├── layout/
│   ├── DEBIAN/
│   │   ├── postinst                        # Rootless directory permissions & setup
│   │   └── prerm                           # Cleanup script
│   └── Library/
│       └── PreferenceLoader/
│           └── Preferences/
│               └── Yuna.plist              # Staged PreferenceLoader entry for Settings.app
├── tests/
│   ├── test_suite.py                       # Python verification test suite
│   └── test_storage_algo.cpp               # C++ storage and row layout algorithm tests
└── docs/
    └── HOW_IT_WORKS.md                     # Deep architectural explanation
```

---

## Settings & Preferences

All tweak preferences are configurable in **Settings → Yuna**:
- **Enable / Disable Toggle**: Instantly toggles injection without needing a respring.
- **Number of Rows**: 1, 2, 3, or 4 rows of cards in the keyboard panel.
- **Dock Button Position**: Next to Dictation, Centered, or Next to Emoji.
- **Maximum History Items**: Configurable snippet limit (5 to 200 items).
- **Save Images & Files**: Independent toggles for media recording.
- **Haptic Feedback**: None, Light, Medium, or Heavy.
- **Auto-Dismiss on Paste**: Automatically closes the panel upon selecting a snippet.
- **History Maintenance**: Clear Unpinned Snippets or Clear Entire History.

---

## Verification & Testing

Run the test suite from the repository root:
```bash
# Python verification suite
python Tweaks/Yuna/tests/test_suite.py

# C++ storage and geometry tests
clang++ -std=c++17 Tweaks/Yuna/tests/test_storage_algo.cpp -o test_storage_algo
./test_storage_algo
```

---

## Author & Credits

- Developed by **frosty** ([heyfrosty.space](https://heyfrosty.space))
- Repository: **[Nishi](https://github.com/enafrosty/Nishi)**
