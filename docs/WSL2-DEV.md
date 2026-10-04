# Janus WSL2 fast dev loop

## Setup (one-time, already done)
- OTP 27.3.4 built from source at /opt/erlang (symlinked to /usr/local/bin)
- gcc/make/git via apt; ncurses+ssl dev headers installed
- Project accessed via /mnt/f/Janus (Windows filesystem bridge)

## Usage (from Windows terminal)
```bash
# Incremental eunit (~43s vs ~2min on Windows native)
wsl.exe -d Ubuntu -e bash -lc "cd /mnt/f/Janus && ./rebar3 eunit"

# Compile only
wsl.exe -d Ubuntu -e bash -lc "cd /mnt/f/Janus && ./rebar3 compile"

# Format check  
wsl.exe -d Ubuntu -e bash -lc "cd /mnt/f/Janus && ./rebar3 fmt"
```

## Benchmarks (2026-10-04)
| Operation | WSL2 | Windows native (OTP29+MinGW) |
|---|---|---|
| Clean build + eunit | 3m24s | ~5-8 min |
| Incremental eunit | 43s | 2m8s |

## Notes
- WSL2 /tmp is systemd-private (files vanish between sessions) — use /opt/build for persistent files
- Docker Hub DNS flakes (auth.docker.io -> Facebook IPv6) don't affect WSL2 direct builds
- esqlite NIF compiles natively with gcc (no MinGW PATH juggling)
