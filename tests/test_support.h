// A deliberately tiny test harness.
//
// A test dependency is still a dependency, and the thing being tested here is supposed to
// build anywhere. Each test file is its own executable; CTest runs them.
#pragma once

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

namespace testing {

inline int& failure_count() {
    static int count = 0;
    return count;
}

inline void report_failure(const char* file, int line, const std::string& message) {
    std::printf("  FAIL %s:%d\n    %s\n", file, line, message.c_str());
    ++failure_count();
}

inline bool nearly_equal(double a, double b, double tolerance) {
    return std::fabs(a - b) <= tolerance;
}

struct Case {
    const char* name;
    void (*run)();
};

inline std::vector<Case>& cases() {
    static std::vector<Case> registry;
    return registry;
}

struct Registrar {
    Registrar(const char* name, void (*run)()) { cases().push_back(Case{name, run}); }
};

inline int run_all(const char* suite) {
    std::printf("%s\n", suite);
    int failed_cases = 0;
    for (const Case& test : cases()) {
        const int before = failure_count();
        std::printf("- %s\n", test.name);
        test.run();
        if (failure_count() > before) {
            ++failed_cases;
        }
    }
    if (failed_cases == 0) {
        std::printf("%s: all %zu cases passed\n", suite, cases().size());
        return 0;
    }
    std::printf("%s: %d of %zu cases failed\n", suite, failed_cases, cases().size());
    return 1;
}

}  // namespace testing

#define TEST(name)                                                        \
    static void name();                                                   \
    static ::testing::Registrar registrar_##name(#name, &name);           \
    static void name()

#define CHECK(condition)                                                  \
    do {                                                                  \
        if (!(condition)) {                                               \
            ::testing::report_failure(__FILE__, __LINE__, #condition);    \
        }                                                                 \
    } while (false)

#define CHECK_MESSAGE(condition, message)                                 \
    do {                                                                  \
        if (!(condition)) {                                               \
            ::testing::report_failure(__FILE__, __LINE__,                 \
                                      std::string(#condition) + " — " + (message)); \
        }                                                                 \
    } while (false)

#define CHECK_NEAR(actual, expected, tolerance)                           \
    do {                                                                  \
        const double actual_value = static_cast<double>(actual);          \
        const double expected_value = static_cast<double>(expected);      \
        if (!::testing::nearly_equal(actual_value, expected_value, tolerance)) { \
            ::testing::report_failure(                                    \
                __FILE__, __LINE__,                                       \
                std::string(#actual) + " = " + std::to_string(actual_value) + \
                    ", expected " + std::to_string(expected_value) +      \
                    " within " + std::to_string(static_cast<double>(tolerance))); \
        }                                                                 \
    } while (false)

#define TEST_MAIN(suite)                                                  \
    int main() { return ::testing::run_all(suite); }
