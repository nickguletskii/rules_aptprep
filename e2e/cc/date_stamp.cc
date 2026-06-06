#include <cstdio>

// References __DATE__/__TIME__/__TIMESTAMP__ so the compiler embeds their
// expansions in the binary. The wrapper injects
// -D__DATE__="redacted" -D__TIME__="redacted" -D__TIMESTAMP__="redacted" for
// reproducibility, so the resulting binary must contain "redacted" and must NOT
// contain a real build timestamp. verify_reproducibility.sh asserts this.
static const char* kBuildDate = __DATE__;
static const char* kBuildTime = __TIME__;
static const char* kBuildTimestamp = __TIMESTAMP__;

int main() {
  std::printf("%s %s %s\n", kBuildDate, kBuildTime, kBuildTimestamp);
  return 0;
}
