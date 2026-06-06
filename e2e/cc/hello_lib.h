#ifndef E2E_CC_HELLO_LIB_H_
#define E2E_CC_HELLO_LIB_H_

// Declares the single value used by the hello binary. Kept in a separate
// translation unit so the e2e build exercises a cc_library -> cc_binary link.
int hello_value();

#endif  // E2E_CC_HELLO_LIB_H_
