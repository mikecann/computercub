# A private service under an authorized GUI host

Use this mode when the user has already authorized the GUI host and the requested work.
For example, a remote desktop runner may already have Accessibility and Screen Recording
access. Start ComputerCub as that host's child; macOS decides which existing permissions
apply. An SSH shell alone does not establish that context. Use the host's supported command
runner and any required desktop lease, keeping the service inside that lease for its whole
lifetime. Host names and lease commands depend on the environment.

This procedure preserves the OS trust checks. If access is denied, stop and report it.
Do not re-sign the app, impersonate another app, edit TCC, auto-grant permissions, or switch
hosts to get around a denial. New permissions require the user's own decision.

## Preserve the bundle

Copy or archive the entire trusted `ComputerCub.app`, including `Contents/Info.plist`,
resources and signature metadata. Copying just `Contents/MacOS/computercub` breaks signature
verification. Keep the copied app at a unique job-owned path, separate from the installation.
For a local copy, `ditto "$source_app" "$job_app"` preserves the bundle. For a transfer,
archive the whole bundle with metadata preserved and extract it on the destination.

On the destination, verify before launching:

```bash
codesign --verify --strict "$job_app"
codesign -dv --verbose=4 "$job_app" 2>&1
```

Require verification to succeed and compare the signing identity and identifier with the
trusted source. If either differs or verification fails, stop; preserve the original signing.

## Start explicitly inside the authorized host

Run the following in one Bash shell started by that host, after acquiring its desktop lease.
Set `job_app` to the absolute path of the intact verified copy first. These are separate
steps to inspect, not an unattended script to run through a permission failure.

```bash
umask 077
cub_home=$(mktemp -d /tmp/cub.XXXXXXXX) || exit 1
cub_bin="$job_app/Contents/MacOS/computercub"
COMPUTERCUB_HOME="$cub_home" "$cub_bin" serve >"$cub_home/service.log" 2>&1 &
cub_pid=$!
cub_identity=$(LC_ALL=C ps -ww -p "$cub_pid" -o lstart= -o command=)
```

Record the PID, start time, full executable path and arguments, private directory, and socket
path in the job's ownership record. Require a live child with the expected `"$cub_bin" serve`
command and a nonempty start time. Keep the private path short: the Unix socket path has a
103-byte limit. Wait briefly for `$cub_home/computercub.sock`; if the child exits or the socket
does not appear, inspect the log and stop. Do not launch a client as a readiness probe.

Before each connection, verify that `ps` still matches the recorded identity and that
`lsof -a -p "$cub_pid" -U` shows that exact private socket held by the owned server.
If ownership is missing or differs, stop; do not connect or signal a replacement process.

## Check permissions through that socket

The bundled CLI normally starts an app through LaunchServices (`open`) when no service
answers. That makes the app its own responsible process and may give a different permission
result. `COMPUTERCUB_HOME` alone does not disable this auto-launch. The CLI also retries some
screenshot failures by restarting the service. For this mode, send requests directly to the
existing private socket so failure cannot launch or restart anything:

```bash
printf '%s\n' '{"args":["doctor"]}' | /usr/bin/nc -w 5 -U "$cub_home/computercub.sock"
```

The response is one JSON line with `ok`, `out` and `restart`. Require a complete valid reply;
`nc` succeeding only proves transport, and `doctor` can return `ok: true` with permissions
off. Confirm that `Running from:` names the copied app and recorded PID, `Accessibility: on`,
and `Screen: unlocked`. Require `Screen Recording: on` before any screenshot. If a required
permission is off, the screen is locked, or the response is missing or unexpected, stop.
Do not use `shot` to request missing permission. If any later command is denied or returns
`restart: true`, stop rather than retrying through another launch context.

After those checks, requests use the same JSON protocol, for example:

```bash
printf '%s\n' '{"args":["windows"]}' | /usr/bin/nc -w 5 -U "$cub_home/computercub.sock"
```

Check `ok: true` and inspect `out` after every command. Encode variable arguments with a JSON
encoder. Use only refs from this private service; refs from the installed service or another
job are unrelated. The usual rules for reading, actions, focus and pointer use still apply.
Choose a timeout that fits the command; a screenshot can take 15 seconds. A timeout leaves
the command's result unknown, so inspect fresh state before considering another action.

## Clean up only the owned run

Before cleanup, repeat the process identity and socket ownership checks. If they match, send
`{"args":["quit"]}` through the same private socket. Wait for that exact child to exit. If it
cannot answer, a fallback `TERM` may target only the recorded PID after rechecking its start
time and full executable path/arguments against `cub_identity`. Never use a broad `pkill`,
`killall`, or an unscoped installed `computercub quit`. If identity cannot be proved, report
the remaining process rather than guessing. Release the desktop lease after the service exits.

`COMPUTERCUB_HOME` isolates the socket and service refs, but screenshots and saved reads still
use the shared `~/Library/Caches/ComputerCub` directory. Avoid `clean`, which deletes other
jobs' captures too. Remove only exact artifacts returned to this job, then remove its private
directory and copied bundle after its server has exited and their ownership is confirmed.
