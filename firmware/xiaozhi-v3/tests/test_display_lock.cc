#include "display.h"
#include <cassert>
#include <type_traits>

// Only SDK/UI dependencies are stubbed. The guard under test is production code.
Display::Display() = default;
Display::~Display() = default;
void Display::SetStatus(const char*) {}
void Display::ShowNotification(const char*, int) {}
void Display::ShowNotification(const std::string&, int) {}
void Display::SetEmotion(const char*) {}
void Display::SetChatMessage(const char*, const char*) {}
void Display::SetIcon(const char*) {}
void Display::SetPreviewImage(const lv_img_dsc_t*) {}
void Display::SetTheme(const std::string&) {}
void Display::UpdateStatusBar(bool) {}
void Display::SetPowerSaveMode(bool) {}

class TestDisplay : public Display {
public:
    bool available = true;
    int depth = 0;
    int unlocks = 0;
    int timeout = -1;
    bool Lock(int timeout_ms) override {
        timeout = timeout_ms;
        if (!available) return false;
        ++depth;
        return true;
    }
    void Unlock() override {
        assert(depth > 0);
        --depth;
        ++unlocks;
    }
};

int main() {
    static_assert(!std::is_copy_constructible_v<DisplayLockGuard>);
    static_assert(!std::is_copy_assignable_v<DisplayLockGuard>);
    TestDisplay display;
    {
        DisplayLockGuard outer(&display);
        assert(outer && display.depth == 1 && display.timeout == 0);
        {
            DisplayLockGuard inner(&display, 100);
            assert(inner && display.depth == 2 && display.timeout == 100);
        }
        assert(display.depth == 1 && display.unlocks == 1);
    }
    assert(display.depth == 0 && display.unlocks == 2);

    display.available = false;
    int updates = 0;
    {
        DisplayLockGuard failed(&display, 100);
        assert(!failed && display.timeout == 100);
        if (failed) ++updates;
    }
    assert(updates == 0 && display.unlocks == 2 && display.depth == 0);

    // A timed-out attempt must not poison a later successful acquisition.
    display.available = true;
    {
        DisplayLockGuard recovered(&display, 100);
        assert(recovered);
        ++updates;
    }
    assert(updates == 1 && display.depth == 0 && display.unlocks == 3);
}
