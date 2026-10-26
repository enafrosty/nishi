#include <iostream>
#include <vector>
#include <string>
#include <algorithm>
#include <cassert>
#include <cmath>

enum class ItemType {
    Text = 0,
    Image = 1,
    URL = 2,
    File = 3
};

struct Item {
    std::string uuid;
    ItemType type;
    std::string text;
    std::string relPath; // SHA-256 based image filename
    std::string fileURL;
    double timestamp;
    bool isPinned;
    size_t itemSize;
};

class StorageEngine {
public:
    int maxItems = 30;
    std::vector<Item> items;

    bool addItem(const Item& newItem) {
        // Accurate deduplication check
        for (auto& existing : items) {
            if (existing.type == newItem.type) {
                if (newItem.type == ItemType::Text || newItem.type == ItemType::URL) {
                    if (existing.text == newItem.text) {
                        existing.timestamp = newItem.timestamp;
                        prune();
                        return true;
                    }
                } else if (newItem.type == ItemType::Image) {
                    // Check SHA-256 relPath rather than loose itemSize
                    if (!existing.relPath.empty() && existing.relPath == newItem.relPath) {
                        existing.timestamp = newItem.timestamp;
                        prune();
                        return true;
                    }
                } else if (newItem.type == ItemType::File) {
                    if (!existing.fileURL.empty() && existing.fileURL == newItem.fileURL) {
                        existing.timestamp = newItem.timestamp;
                        prune();
                        return true;
                    }
                }
            }
        }

        items.insert(items.begin(), newItem);
        prune();
        return true;
    }

    void prune() {
        std::vector<Item> pinned;
        std::vector<Item> unpinned;

        for (const auto& it : items) {
            if (it.isPinned) {
                pinned.push_back(it);
            } else {
                unpinned.push_back(it);
            }
        }

        // Sort unpinned descending by timestamp before truncating
        std::sort(unpinned.begin(), unpinned.end(), [](const Item& a, const Item& b) {
            return a.timestamp > b.timestamp;
        });

        std::sort(pinned.begin(), pinned.end(), [](const Item& a, const Item& b) {
            return a.timestamp > b.timestamp;
        });

        if (unpinned.size() > static_cast<size_t>(maxItems)) {
            unpinned.resize(maxItems);
        }

        items.clear();
        items.insert(items.end(), pinned.begin(), pinned.end());
        items.insert(items.end(), unpinned.begin(), unpinned.end());
    }

    void togglePin(const std::string& uuid) {
        for (auto& it : items) {
            if (it.uuid == uuid) {
                it.isPinned = !it.isPinned;
                break;
            }
        }
        prune();
    }

    void clearUnpinned() {
        std::vector<Item> pinned;
        for (const auto& it : items) {
            if (it.isPinned) pinned.push_back(it);
        }
        items = pinned;
        prune();
    }
};

// Row calculation geometry
struct CellGeometry {
    double width;
    double height;
};

CellGeometry calculateCellGeometry(double containerHeight, int rows) {
    if (rows < 1) rows = 1;
    if (rows > 4) rows = 4;

    double top = 6.0, bottom = 6.0, spacing = 8.0;
    double totalSpacing = top + bottom + (spacing * (rows - 1));
    double availableHeight = containerHeight - totalSpacing;
    if (availableHeight < 40.0) availableHeight = 40.0;

    double h = std::floor(availableHeight / rows);
    double w = (rows == 1) ? 250.0 : 210.0;
    return {w, h};
}

int main() {
    std::cout << "Testing StorageEngine algorithm with rigorous edge cases..." << std::endl;
    StorageEngine storage;
    storage.maxItems = 3;

    // 1. Add 3 items
    storage.addItem({"1", ItemType::Text, "First", "", "", 10.0, false, 5});
    storage.addItem({"2", ItemType::Text, "Second", "", "", 20.0, false, 6});
    storage.addItem({"3", ItemType::Text, "Third", "", "", 30.0, false, 5});
    assert(storage.items.size() == 3);
    assert(storage.items[0].text == "Third");

    // 2. Pin the "First" item
    storage.togglePin("1");
    assert(storage.items[0].uuid == "1"); // Pinned must be at top
    assert(storage.items[0].isPinned == true);

    // 3. Add 4 more items (should evict unpinned items, but NEVER pinned item 1)
    storage.addItem({"4", ItemType::Text, "Fourth", "", "", 40.0, false, 6});
    storage.addItem({"5", ItemType::Text, "Fifth", "", "", 50.0, false, 5});
    storage.addItem({"6", ItemType::Text, "Sixth", "", "", 60.0, false, 5});
    storage.addItem({"7", ItemType::Text, "Seventh", "", "", 70.0, false, 7});

    // We have 1 pinned + maxItems(3) unpinned = 4 items total
    assert(storage.items.size() == 4);
    assert(storage.items[0].uuid == "1"); // Pinned item 1 preserved!
    assert(storage.items[0].isPinned == true);

    // 4. Test Deduplication
    storage.addItem({"8", ItemType::Text, "Seventh", "", "", 80.0, false, 7});
    assert(storage.items.size() == 4); // Did not grow
    assert(storage.items[1].text == "Seventh");
    assert(storage.items[1].timestamp == 80.0);

    // 5. Test Image Deduplication by SHA-256 relPath vs same-size different image
    // Two different images with identical byte length (1024) but different hashes
    storage.addItem({"img1", ItemType::Image, "", "sha256_aaa.png", "", 90.0, false, 1024});
    storage.addItem({"img2", ItemType::Image, "", "sha256_bbb.png", "", 95.0, false, 1024});
    // Both images must be preserved because their SHA-256 filenames differ
    bool foundImg1 = false, foundImg2 = false;
    for (const auto& it : storage.items) {
        if (it.relPath == "sha256_aaa.png") foundImg1 = true;
        if (it.relPath == "sha256_bbb.png") foundImg2 = true;
    }
    assert(foundImg1 && foundImg2);

    // Copying img1 again must update timestamp and deduplicate
    storage.addItem({"img1_again", ItemType::Image, "", "sha256_aaa.png", "", 100.0, false, 1024});
    int img1Count = 0;
    for (const auto& it : storage.items) {
        if (it.relPath == "sha256_aaa.png") {
            img1Count++;
            assert(it.timestamp == 100.0);
        }
    }
    assert(img1Count == 1);

    // 6. Test File URL deduplication
    storage.addItem({"f1", ItemType::File, "", "", "file:///var/mobile/doc.pdf", 110.0, false, 2048});
    storage.addItem({"f2", ItemType::File, "", "", "file:///var/mobile/doc.pdf", 120.0, false, 2048});
    int fileCount = 0;
    for (const auto& it : storage.items) {
        if (it.fileURL == "file:///var/mobile/doc.pdf") {
            fileCount++;
            assert(it.timestamp == 120.0);
        }
    }
    assert(fileCount == 1);

    // 7. Clear Unpinned
    storage.clearUnpinned();
    assert(storage.items.size() == 1);
    assert(storage.items[0].uuid == "1");

    // 8. Test Geometry
    CellGeometry g1 = calculateCellGeometry(180.0, 1);
    assert(g1.width == 250.0 && g1.height == 168.0);

    CellGeometry g2 = calculateCellGeometry(180.0, 2);
    assert(g2.width == 210.0 && g2.height == 80.0);

    CellGeometry g3 = calculateCellGeometry(180.0, 3);
    assert(g3.width == 210.0 && g3.height == 50.0);

    CellGeometry g4 = calculateCellGeometry(180.0, 4);
    assert(g4.width == 210.0 && g4.height == 36.0);

    // Clamp tests
    CellGeometry g0 = calculateCellGeometry(180.0, 0);
    assert(g0.height == g1.height);

    CellGeometry g9 = calculateCellGeometry(180.0, 9);
    assert(g9.height == g4.height);

    std::cout << "All StorageEngine and Geometry tests PASSED successfully!" << std::endl;
    return 0;
}
