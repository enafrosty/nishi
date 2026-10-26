# Nishi — Rootless iOS Jailbreak Tweak Repository

[![Test, Build & Deploy](https://github.com/enafrosty/Nishi/actions/workflows/deploy.yml/badge.svg)](https://github.com/enafrosty/Nishi/actions/workflows/deploy.yml)
[![Target](https://img.shields.io/badge/target-iOS%2015.0%2B-blue.svg)](https://github.com/enafrosty/Nishi)
[![Scheme](https://img.shields.io/badge/scheme-rootless%20%2Fvar%2Fjb-green.svg)](https://github.com/enafrosty/Nishi)
[![Arch](https://img.shields.io/badge/arch-arm64%20%7C%20arm64e-purple.svg)](https://github.com/enafrosty/Nishi)

**Nishi** is a personal, modern rootless iOS jailbreak tweak repository hosted on GitHub Pages. It serves tweaks engineered specifically for modern rootless jailbreaks (**Dopamine**, iOS 15.0 – 16.x+) across `arm64` and `arm64e` (A12/A13 hardware Pointer Authentication) architectures.

- **Web Showcase**: [https://nishi.heyfrosty.space/](https://nishi.heyfrosty.space/)
- **Repository URL**: `https://nishi.heyfrosty.space/`

---

## Adding Nishi to Your Device

Tap one of the direct links below from Safari on your jailbroken iPhone or iPad:

| Package Manager | One-Click Add Link | Manual URL |
| :--- | :--- | :--- |
| **Sileo** | [Add to Sileo](sileo://source/https://nishi.heyfrosty.space/) | `https://nishi.heyfrosty.space/` |
| **Zebra** | [Add to Zebra](zbra://sources/add/https://nishi.heyfrosty.space/) | `https://nishi.heyfrosty.space/` |

---

## Hosted Tweaks

### 1. [Yuna](file:///c:/Users/frosty/Projects/Nishi/Tweaks/Yuna/README.md) (`com.frosty.yuna`)
*Universal Keyboard Clipboard Manager & Media History*

- **Embedded Dock Button**: Integrates directly into `UIKeyboardDockView` beside emoji and dictation.
- **Universal Capture**: Records plain text, rich web URLs, photos/images (with Jetsam-safe downsampling), and file links.
- **Pinning Engine**: Pin important snippets to stay at the top; pinned items are immune to LRU pruning.
- **1–4 Row Grid Management**: Configurable row layouts (1 compact row, 2 balanced rows, or 3–4 dense rows) with mathematical height distribution.
- **Direct Input Insertion**: Injects text directly into `UIKeyboardImpl` active input responder without extra paste dialogs.
- **ElleKit PAC Safe**: Built with ElleKit trampolines for full arm64e hardware PAC compliance on A12/A13.
- **Detailed Documentation**: See [How Yuna Works](file:///c:/Users/frosty/Projects/Nishi/Tweaks/Yuna/docs/HOW_IT_WORKS.md).

---

## Repository Structure

```
Nishi/
├── .github/
│   └── workflows/
│       └── deploy.yml              # CI/CD: runs test suite, builds repo indexes, deploys to Pages
├── debs/                           # Rootless Debian packages (.deb)
│   └── com.frosty.yuna_1.0.0_iphoneos-arm64.deb
├── scripts/
│   ├── build_repo.py               # Generates Packages, Packages.gz, and Release files
│   └── package_yuna.py             # Assembles rootless .deb packages
├── index.html                      # GitHub Pages website (dark aesthetic + direct Sileo adder)
├── Packages / Packages.gz          # APT package indices
├── Release                         # APT repository release manifest
├── CydiaIcon.png                   # Repository icon for Sileo, Zebra, and Cydia
├── Makefile                        # Top-level Theos aggregate makefile
├── include/
│   └── rootless.h                  # Shared rootless path helper (JBROOT_PATH)
└── Tweaks/
    └── Yuna/                       # Flagship clipboard manager tweak
        ├── Makefile
        ├── control                 # Debian control file with SileoDepiction
        ├── Yuna.plist              # Filter manifest (SpringBoard & UIKitCore)
        ├── Source/                 # Logos hooks, UI, server daemon, and storage engine
        ├── Preferences/            # PreferenceLoader bundle for Settings.app
        ├── depiction/              # Native Sileo JSON depiction schema
        ├── layout/                 # Rootless staging hierarchy & maintainer scripts
        ├── tests/                  # Automated verification test suite
        └── docs/
            └── HOW_IT_WORKS.md     # In-depth architectural explanation
```

---

## Technical Invariants & Standards

1. **Rootless Only (`/var/jb`)**:
   - Zero hardcoded root paths.
   - All binaries and configurations target `/var/jb` via `JBROOT_PATH` from [rootless.h](file:///c:/Users/frosty/Projects/Nishi/include/rootless.h).
   - Tweak preferences strictly reside at `/var/mobile/Library/Preferences/` per Dopamine conventions.

2. **Hardware PAC & PPL Safety (`arm64e`)**:
   - A12 and A13 chips have hardware Pointer Authentication (PAC).
   - Hooks are mediated through **ElleKit** trampolines (`MSHookMessageEx`, `MSHookFunction`).
   - Zero raw vtable manipulation or unmapped code writes.

3. **Memory & Jetsam Mitigation**:
   - Daemons like `SpringBoard` operate under strict Jetsam resource limits.
   - Background clipboard image captures are downsampled to a maximum dimension of 1200px and cached to disk as SHA-256 deduplicated PNGs rather than retained in memory.

---

## Verification & Testing

Run the automated verification suite:
```bash
# Python verification suite (validates Plists, Sileo schemas, control files, storage logic)
python Tweaks/Yuna/tests/test_suite.py

# C++ storage and row layout algorithm tests
clang++ -std=c++17 Tweaks/Yuna/tests/test_storage_algo.cpp -o test_storage_algo
./test_storage_algo
```

Rebuild repository indexes:
```bash
python scripts/build_repo.py
```

---

## Author & Credits

- Maintained by **frosty** ([heyfrosty.space](https://heyfrosty.space))
- GitHub: [@enafrosty](https://github.com/enafrosty)
- Repository: [github.com/enafrosty/Nishi](https://github.com/enafrosty/Nishi)
