#include "hello_lib.h"

#include <string>

// Include <string> to force libstdc++ header resolution through the generated
// toolchain's cxx_builtin_include_directories.
int hello_value() {
  std::string s = "42";
  return static_cast<int>(s.size()) * 21;
}
