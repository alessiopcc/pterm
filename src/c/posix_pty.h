// forkpty lives in <util.h> on macOS, <pty.h> on Linux.
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif
#include <unistd.h>    // execvp, close, read, write
#include <stdlib.h>    // setenv
#include <sys/ioctl.h> // ioctl, TIOCSWINSZ
#include <sys/wait.h>  // waitpid, WNOHANG
#include <signal.h>    // kill
#include <fcntl.h>     // fcntl, O_NONBLOCK
