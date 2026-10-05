// Owns a shell process tree. This is lifetime management, not a security sandbox.
#include <windows.h>

#include <cstdio>
#include <string>
#include <vector>

namespace {
class Handle {
 public:
  explicit Handle(HANDLE value = nullptr) : value_(value) {}
  ~Handle() {
    if (value_ && value_ != INVALID_HANDLE_VALUE) CloseHandle(value_);
  }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  HANDLE get() const { return value_; }

 private:
  HANDLE value_;
};

std::wstring Quote(const std::wstring& value) {
  std::wstring result = L"\"";
  size_t slashes = 0;
  for (wchar_t c : value) {
    if (c == L'\\') {
      ++slashes;
      continue;
    }
    result.append(c == L'\"' ? slashes * 2 + 1 : slashes, L'\\');
    slashes = 0;
    result += c;
  }
  result.append(slashes * 2, L'\\');
  return result + L"\"";
}

HANDLE DuplicateStandardHandle(DWORD id) {
  HANDLE duplicate = nullptr;
  if (!DuplicateHandle(GetCurrentProcess(), GetStdHandle(id),
                       GetCurrentProcess(), &duplicate, 0, TRUE,
                       DUPLICATE_SAME_ACCESS)) {
    return nullptr;
  }
  return duplicate;
}

int Failed(const char* operation) {
  std::fprintf(stderr, "Kelivo process launcher: %s failed (%lu)\n", operation,
               GetLastError());
  return 125;
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc < 2) return 125;
  // Dart registers cancellation before releasing this gate. A cancelled startup
  // cannot run user code or create an untracked child.
  char gate = 0;
  DWORD read = 0;
  if (!ReadFile(GetStdHandle(STD_INPUT_HANDLE), &gate, 1, &read, nullptr) ||
      read != 1 || gate != '\n') {
    return 125;
  }
  Handle job(CreateJobObjectW(nullptr, nullptr));
  if (!job.get()) return Failed("CreateJobObject");
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job.get(), JobObjectExtendedLimitInformation,
                               &limits, sizeof(limits))) {
    return Failed("SetInformationJobObject");
  }
  Handle input(DuplicateStandardHandle(STD_INPUT_HANDLE));
  Handle output(DuplicateStandardHandle(STD_OUTPUT_HANDLE));
  Handle error(DuplicateStandardHandle(STD_ERROR_HANDLE));
  if (!input.get() || !output.get() || !error.get()) {
    return Failed("DuplicateHandle");
  }
  // Inherit only the three pipes, never the job handle or unrelated handles.
  STARTUPINFOEXW startup{};
  startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup.StartupInfo.hStdInput = input.get();
  startup.StartupInfo.hStdOutput = output.get();
  startup.StartupInfo.hStdError = error.get();
  SIZE_T bytes = 0;
  InitializeProcThreadAttributeList(nullptr, 1, 0, &bytes);
  std::vector<unsigned char> storage(bytes);
  startup.lpAttributeList =
      reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
  if (!InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &bytes)) {
    return Failed("InitializeProcThreadAttributeList");
  }
  HANDLE pipes[] = {input.get(), output.get(), error.get()};
  if (!UpdateProcThreadAttribute(startup.lpAttributeList, 0,
                                 PROC_THREAD_ATTRIBUTE_HANDLE_LIST, pipes,
                                 sizeof(pipes), nullptr, nullptr)) {
    DeleteProcThreadAttributeList(startup.lpAttributeList);
    return Failed("UpdateProcThreadAttribute");
  }
  std::wstring command;
  for (int i = 1; i < argc; ++i) {
    if (i > 1) command += L' ';
    command += Quote(argv[i]);
  }
  PROCESS_INFORMATION child{};
  const BOOL created = CreateProcessW(
      argv[1], command.data(), nullptr, nullptr, TRUE,
      CREATE_SUSPENDED | CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT,
      nullptr, nullptr, &startup.StartupInfo, &child);
  DeleteProcThreadAttributeList(startup.lpAttributeList);
  if (!created) return Failed("CreateProcess");
  Handle process(child.hProcess);
  Handle thread(child.hThread);
  // Do not let the shell execute even one instruction before joining its job.
  if (!AssignProcessToJobObject(job.get(), process.get())) {
    const DWORD saved = GetLastError();
    TerminateProcess(process.get(), 125);
    WaitForSingleObject(process.get(), INFINITE);
    SetLastError(saved);
    return Failed("AssignProcessToJobObject");
  }
  if (ResumeThread(thread.get()) == static_cast<DWORD>(-1)) {
    return Failed("ResumeThread");
  }
  if (WaitForSingleObject(process.get(), INFINITE) != WAIT_OBJECT_0) {
    return Failed("WaitForSingleObject");
  }
  DWORD exit_code = 125;
  if (!GetExitCodeProcess(process.get(), &exit_code)) {
    return Failed("GetExitCodeProcess");
  }
  // The job closes on every exit path, including forced launcher termination.
  // Background children cannot outlive this one-shot shell command.
  return static_cast<int>(exit_code);
}
