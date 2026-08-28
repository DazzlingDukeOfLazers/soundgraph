#include "crash_dump.h"

#if defined(_WIN32)

#include <windows.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace soundgraph_godot {
namespace {

// dbghelp's MiniDumpWriteDump, reached by name so that nothing links against it.
using MiniDumpWriteDumpFn = BOOL(WINAPI*)(HANDLE, DWORD, HANDLE, int, void*, void*, void*);

MiniDumpWriteDumpFn g_write_dump = nullptr;
char g_directory[MAX_PATH] = {0};
LONG g_written = 0;

// MiniDumpWithThreadInfo | MiniDumpWithIndirectlyReferencedMemory: every thread, and the
// memory their registers point at, without the hundreds of megabytes a full-memory dump
// of Godot would cost. (0x02 is WithFullMemory and is not what is wanted here.)
constexpr int kDumpType = 0x00001000 | 0x00000040;

struct DumpRequest {
    const char* path;
    BOOL ok;
    DWORD why;
};

// Written from a thread of its own, because dbghelp has to walk the faulting thread and
// that thread is the one sitting inside the handler asking for the dump.
DWORD WINAPI write_dump(LPVOID parameter) {
    DumpRequest* request = static_cast<DumpRequest*>(parameter);
    HANDLE file = CreateFileA(request->path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        request->why = GetLastError();
        return 0;
    }
    // No exception parameter.
    //
    // Passing one is the documented way to record which thread faulted, and from inside
    // the faulting process it fails: MiniDumpWriteDump returns ERROR_NOACCESS whatever
    // is done to the arguments - copies of the record and context in stable storage,
    // ClientPointers either way, from this thread or the handler's. Without it the dump
    // writes cleanly and still holds every thread and every stack. What is lost is the
    // marker saying which thread it was, and that is printed to stderr instead.
    request->ok = g_write_dump(GetCurrentProcess(), GetCurrentProcessId(), file,
                               kDumpType, nullptr, nullptr, nullptr);
    request->why = request->ok ? 0 : GetLastError();
    CloseHandle(file);
    return 0;
}

LONG CALLBACK on_exception(EXCEPTION_POINTERS* info) {
    if (info == nullptr || info->ExceptionRecord == nullptr) {
        return EXCEPTION_CONTINUE_SEARCH;
    }
    const DWORD code = info->ExceptionRecord->ExceptionCode;

    // Only the ones that are always fatal. Godot raises and handles plenty of
    // first-chance exceptions in normal running, and dumping on those would bury the one
    // that matters.
    if (code != EXCEPTION_ACCESS_VIOLATION && code != EXCEPTION_ILLEGAL_INSTRUCTION &&
        code != EXCEPTION_STACK_OVERFLOW && code != EXCEPTION_PRIV_INSTRUCTION) {
        return EXCEPTION_CONTINUE_SEARCH;
    }

    // Once. A crash during shutdown can cascade, and the first one is the one worth
    // having.
    if (InterlockedCompareExchange(&g_written, 1, 0) != 0) {
        return EXCEPTION_CONTINUE_SEARCH;
    }

    char path[MAX_PATH * 2];
    std::snprintf(path, sizeof(path), "%s\\soundgraph-crash-%lu.dmp", g_directory,
                  GetCurrentProcessId());

    DumpRequest request{path, FALSE, 0};
    HANDLE worker = CreateThread(nullptr, 0, write_dump, &request, 0, nullptr);
    if (worker != nullptr) {
        WaitForSingleObject(worker, 30000);
        CloseHandle(worker);
    }

    // Straight to the handle: by this point in a shutdown, whatever printed the last
    // line may be gone. The thread id is the part the dump cannot carry.
    std::fprintf(stderr,
                 "\n[soundgraph] exception 0x%08lx at %p on thread %lu\n"
                 "[soundgraph] dump %s %s%s\n",
                 code, info->ExceptionRecord->ExceptionAddress, GetCurrentThreadId(),
                 request.ok ? "written to" : "FAILED at", path,
                 request.ok ? "" : " (see the error above)");
    std::fflush(stderr);

    // Let everything else run as it would have. This is a witness, not a handler.
    return EXCEPTION_CONTINUE_SEARCH;
}

}  // namespace

void install_crash_dump_handler() {
    const char* wanted = std::getenv("SOUNDGRAPH_CRASH_DUMP");
    if (wanted == nullptr || wanted[0] == '\0') {
        return;
    }

    if (std::strcmp(wanted, "1") == 0) {
        if (GetTempPathA(sizeof(g_directory), g_directory) == 0) {
            return;
        }
        const size_t length = std::strlen(g_directory);
        if (length > 0 && g_directory[length - 1] == '\\') {
            g_directory[length - 1] = '\0';
        }
    } else {
        std::snprintf(g_directory, sizeof(g_directory), "%s", wanted);
    }

    HMODULE dbghelp = LoadLibraryA("dbghelp.dll");
    if (dbghelp == nullptr) {
        return;
    }
    g_write_dump = reinterpret_cast<MiniDumpWriteDumpFn>(
        reinterpret_cast<void*>(GetProcAddress(dbghelp, "MiniDumpWriteDump")));
    if (g_write_dump == nullptr) {
        return;
    }

    // Pinned, and the handler is never removed.
    //
    // The crash being chased happens *during* shutdown, and an extension is unloaded as
    // part of shutdown. A vectored handler left pointing into an unloaded DLL is a crash
    // of its own, so the usual answer is to remove it on the way out - which would
    // remove it before the moment worth watching. Pinning the module instead keeps the
    // code valid to the end of the process. It is a deliberate leak of one DLL, and it
    // happens only when somebody has asked for a dump.
    HMODULE self = nullptr;
    GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                           GET_MODULE_HANDLE_EX_FLAG_PIN,
                       reinterpret_cast<LPCSTR>(&install_crash_dump_handler), &self);

    AddVectoredExceptionHandler(1, on_exception);
    std::fprintf(stderr, "[soundgraph] crash dumps armed, writing to %s\n", g_directory);
    std::fflush(stderr);
}

}  // namespace soundgraph_godot

#else

namespace soundgraph_godot {
void install_crash_dump_handler() {}
}  // namespace soundgraph_godot

#endif
