// C++ ABI probe for the M0 smoke binary. Verifies that a cross-built C++ TU
// with static libc++ performs static initialization, exceptions, and the
// standard library on the target. Project-owned; clang-format applies.

#include <string>

namespace {

int g_static_init = 0;

struct StaticInitProbe {
    StaticInitProbe() {
        g_static_init = 1;
    }
};

StaticInitProbe g_probe;

} // namespace
extern "C" int go_smoke_cpp_probe(void) {
    if (g_static_init != 1) {
        return 1;
    }

    try {
        throw 7;
    } catch (int value) {
        if (value != 7) {
            return 2;
        }
    }

    std::string text = "greenovercast";
    if (text.size() != 13) {
        return 3;
    }

    return 0;
}
