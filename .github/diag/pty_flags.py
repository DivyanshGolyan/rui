"""PTY master/slave F_GETFL across nonblocking master, child raw+write+restore, and F_SETFL(original)."""
import fcntl, os, pty, sys, termios, tty

def flags(fd):
    return fcntl.fcntl(fd, fcntl.F_GETFL)

def show(label, master, slave):
    m, s = flags(master), flags(slave)
    print(f"{label:38} master=0x{m:08x} slave=0x{s:08x} slave^orig=0x{s ^ ORIG_S:08x}", flush=True)

master, slave = pty.openpty()
ORIG_M, ORIG_S = flags(master), flags(slave)
print(f"O_NONBLOCK=0x{os.O_NONBLOCK:x} platform={sys.platform} python={sys.version.split()[0]}")
show("open", master, slave)
fcntl.fcntl(master, fcntl.F_SETFL, ORIG_M | os.O_NONBLOCK)
show("master nonblocking", master, slave)
saved = termios.tcgetattr(slave)
pid = os.fork()
if pid == 0:
    try:
        tty.setraw(slave)
        os.write(slave, b"x")
        termios.tcsetattr(slave, termios.TCSANOW, saved)
    finally:
        os._exit(0)
_, status = os.waitpid(pid, 0)
print(f"child reaped status={status}")
show("after child raw+write+restore", master, slave)
try:
    print("master read", os.read(master, 16))
except BlockingIOError:
    print("master read: nothing")
fcntl.fcntl(master, fcntl.F_SETFL, ORIG_M)
fcntl.fcntl(slave, fcntl.F_SETFL, ORIG_S)
show("after F_SETFL(original) both", master, slave)
os.write(slave, b"y")
show("after parent slave write", master, slave)
fcntl.fcntl(slave, fcntl.F_SETFL, ORIG_S)
show("after slave F_SETFL(original) again", master, slave)
now = termios.tcgetattr(slave)
print("termios restored:", now == saved)
for i, name in enumerate(("iflag", "oflag", "cflag", "lflag", "ispeed", "ospeed")):
    if now[i] != saved[i]:
        print(f"  {name}: saved=0x{saved[i]:x} now=0x{now[i]:x} xor=0x{saved[i] ^ now[i]:x}")
for j, (a, b) in enumerate(zip(saved[6], now[6])):
    if a != b:
        print(f"  cc[{j}]: saved={a!r} now={b!r}")
# Control: same raw+restore in the parent, no write.
before = termios.tcgetattr(slave); tty.setraw(slave); termios.tcsetattr(slave, termios.TCSANOW, before)
print("parent raw+restore round-trip equal:", termios.tcgetattr(slave) == before)
os.close(slave); os.close(master)
