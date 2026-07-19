// System SQLite for non-Apple platforms. On Windows, provide sqlite3.h + the
// import library on the compiler's search path (e.g. via vcpkg `sqlite3`, or by
// vendoring the SQLite amalgamation). On Linux, install libsqlite3-dev.
#include <sqlite3.h>
