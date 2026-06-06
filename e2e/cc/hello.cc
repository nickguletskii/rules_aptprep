#include <iostream>

#include "hello_lib.h"

// Exercises C++ compile + link + libstdc++ (<iostream>) through the generated
// aptprep cc toolchain, for both the native x86_64 build and the aarch64 cross
// build (via the platform transition wrapper).
int main() {
  std::cout << "hello_value=" << hello_value() << std::endl;
  return 0;
}
