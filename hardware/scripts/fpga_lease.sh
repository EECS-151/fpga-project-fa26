#!/usr/bin/env bash
# fpga_lease.sh - claim an FPGA board for `make program` and give it back automatically.
#
#   fpga_lease.sh start    claim a board (or reuse the one you already hold on this machine),
#                          start hw_server for it, and print the hw_server port on stdout
#   fpga_lease.sh stop     give the board back now, stop hw_server, and clean up anything an older
#                          `make program` (or a hand-run assign-fpga-board) left behind
#   fpga_lease.sh status   show what you currently hold on this machine (this also resets the
#                          idle timer, so it doubles as "I am still using the board")
#   fpga_lease.sh version
#
# How it works: assign-fpga-board keeps a board for as long as its stdin stays open.  `start`
# launches a small background supervisor that holds that stdin open and owns the hw_server
# process group.  The board is given back (stdin is closed, so assign-fpga-board revokes the
# device/tty ACLs and drops its locks) and hw_server is killed as soon as ANY of these happens:
#   * you run `make release` (fpga_lease.sh stop)
#   * you have logged out of this machine (all of your login sessions are gone) for a couple of
#     minutes.  If the shell that ran `make program` is not tied to a login session (VS Code
#     Remote, tmux from an earlier login, GNOME terminals) the board is only given back once the
#     last use of the board is also FPGA_LEASE_DETACHED_SECS old (default 30 min)
#   * the board has not been used for FPGA_LEASE_IDLE_HOURS (default 3, at most 12).  Use means:
#     `make program`, `make board-status`, a program holding one of the board's serial ports open
#     (screen, minicom, ...), or a client connected to your hw_server (the Vivado hardware manager);
#     the last two only count while you are logged in
#   * the lease is FPGA_LEASE_MAX_HOURS old (default 12), however busy it is
#   * the board is unplugged or its USB connection is reset (it loses its ACLs), or hw_server keeps
#     dying, or assign-fpga-board exits by itself, or the supervisor is killed.  In these cases the
#     lease simply ends.  Nothing is claimed in its place, because the new claim could be a
#     different physical board: the next `make program` stops once with an explanation, and the one
#     after that claims a board.
# The lease survives `make program` finishing, so the board's UART/PMOD ports stay usable.
#
# State lives in /run/user/$UID/fpga-lease, which is private and local to each machine.  A lock
# on sup.lock is held by the supervisor for as long as it lives; it is what "you hold a lease"
# means, so an interrupted `make program` can never leave a hidden second supervisor behind.

set -u
umask 077
PATH=$PATH:/usr/sbin:/sbin	# ss and fuser live there; non-login shells often lack it

VERSION=5

num() { case ${1:-} in '' | *[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }

ASSIGN=${FPGA_ASSIGN_CMD:-assign-fpga-board}
HW_SERVER=${FPGA_HW_SERVER:-/share/instsww/xilinx/2025.2/Vivado/bin/hw_server}
POLL_SECS=$(num "${FPGA_LEASE_POLL_SECS:-}" 15)
[ "$POLL_SECS" -gt 0 ] 2>/dev/null || POLL_SECS=15
START_TIMEOUT=$(num "${FPGA_LEASE_START_TIMEOUT:-}" 120)
HW_TIMEOUT=$(num "${FPGA_LEASE_HW_TIMEOUT:-}" 90)
GRACE_SECS=$(num "${FPGA_LEASE_GRACE_SECS:-}" 120)
DETACHED_SECS=$(num "${FPGA_LEASE_DETACHED_SECS:-}" 1800)
LOCK_WAIT=$(num "${FPGA_LEASE_LOCK_WAIT:-}" $(( START_TIMEOUT + HW_TIMEOUT + 30 )))
# a hw_server that ran this long before dying was not "crashing in a loop"
HW_STABLE_SECS=$(num "${FPGA_LEASE_HW_STABLE_SECS:-}" 600)
MAX_IDLE_SECS=43200
IDLE_SECS=$(num "${FPGA_LEASE_IDLE_SECS:-}" "")
[ -n "$IDLE_SECS" ] || IDLE_SECS=$(( $(num "${FPGA_LEASE_IDLE_HOURS:-}" 3) * 3600 ))
[ "$IDLE_SECS" -gt 0 ] 2>/dev/null || IDLE_SECS=10800
[ "$IDLE_SECS" -le "$MAX_IDLE_SECS" ] 2>/dev/null || IDLE_SECS=$MAX_IDLE_SECS
MAX_SECS=$(num "${FPGA_LEASE_MAX_SECS:-}" "")
[ -n "$MAX_SECS" ] || MAX_SECS=$(( $(num "${FPGA_LEASE_MAX_HOURS:-}" 12) * 3600 ))
[ "$MAX_SECS" -gt 0 ] 2>/dev/null || MAX_SECS=43200
[ "$MAX_SECS" -le 172800 ] 2>/dev/null || MAX_SECS=172800
# What the old `make program` recipes left behind (only overridden by the test suite).
OLD_SLEEP=${FPGA_LEASE_OLD_SLEEP:-sleep infinity}
HW_PATTERN=${FPGA_LEASE_HW_PATTERN:-hw_server -stcp:localhost:}
AFB_FRONT=${FPGA_LEASE_AFB_FRONT:-^sudo .*/assign-fpga-board$}
# The course's own root helper that closes every program holding a USB serial port (also the
# setgid GNU screen sessions that no unprivileged tool can see); the test suite replaces it.
if [ -n "${FPGA_LEASE_KILLTTY_CMD+x}" ]; then
	KILLTTY_CMD=$FPGA_LEASE_KILLTTY_CMD
elif [ -x /usr/local/bin/killusbtty ]; then
	KILLTTY_CMD="sudo -n /usr/local/bin/killusbtty"
else
	KILLTTY_CMD=
fi
MYUID=$(id -u)
HOST=$(hostname -s 2>/dev/null || echo this-machine)
SELF=$(readlink -f "$0")
STATE=
LEFTOVERS=0
UNHEALTHY=
HW_DOWN=0
PREV_SERIAL=
NS=? NT=? NR=?

say() { echo "fpga-lease: $*" >&2; }

duration() {	# seconds -> "6h", "2h30min", "45min" (rounded up to the minute)
	local m=$(( ($1 + 59) / 60 ))
	if [ "$m" -lt 60 ]; then echo "${m}min"
	elif [ $(( m % 60 )) -eq 0 ]; then echo "$(( m / 60 ))h"
	else echo "$(( m / 60 ))h$(( m % 60 ))min"; fi
}

# The state directory must be ours and private.  There is deliberately no fallback to a path in
# shared /tmp: another user could pre-create it and make us follow their symlinks.
init_state() {
	local rundir=/run/user/$MYUID
	if [ -n "${FPGA_LEASE_DIR:-}" ]; then
		STATE=$FPGA_LEASE_DIR
	else
		if ! { [ -d "$rundir" ] && [ ! -L "$rundir" ] && [ -O "$rundir" ]; }; then
			say "no private runtime directory ($rundir): log in on the lab machine itself or over ssh and run make there"
			exit 1
		fi
		STATE=$rundir/fpga-lease
	fi
	mkdir -p "$STATE" 2>/dev/null
	if ! { [ -d "$STATE" ] && [ ! -L "$STATE" ] && [ -O "$STATE" ]; }; then
		say "unsafe state directory $STATE"
		exit 1
	fi
	chmod 700 "$STATE" 2>/dev/null
}

# One start/stop/status of yours at a time (fd 9).
take_lock() {
	exec 9> "$STATE/lock" || exit 1
	flock -n 9 && return 0
	say "waiting for another 'make program' / 'make release' of yours to finish..."
	flock -w "$LOCK_WAIT" 9 && return 0
	say "that command is still running (suspended with Ctrl-Z? try 'fg', or close its terminal); giving up"
	exit 1
}

# Is this user's supervisor alive (or still starting)?  The supervisor holds a flock on sup.lock
# from the moment it is spawned until it exits, however it exits.  Callers hold the main lock
# (fd 9), so probes never collide with a start.
sup_running() {
	flock -n -E 99 "$STATE/sup.lock" true 2>/dev/null
	[ $? = 99 ]
}

sup_pid() {	# pid of the supervisor (the command line check guards against pid reuse)
	local pid
	pid=$(cat "$STATE/supervisor.pid" 2>/dev/null) || return 1
	case $pid in '' | *[!0-9]*) return 1 ;; esac
	tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q -- "fpga_lease.sh _supervise" || return 1
	echo "$pid"
}

# Ask the supervisor to end the lease.  stop_requested tells it that WE are asking: a TERM that
# arrives without it came from somebody else, and the lease then counts as lost.
request_stop() {
	local pid= i
	for ((i = 0; i < 200; i++)); do pid=$(sup_pid) && break; sleep 0.1; done	# it may still be starting
	: > "$STATE/stop_requested"
	[ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
	return 0
}

# TERM the running supervisor and wait for it to go away.  Needs fd 8 open on sup.lock; on
# success we hold that lock.
stop_supervisor() {
	case $(cat "$STATE/status" 2>/dev/null) in
	releasing | released) ;;	# already on its way out; a second TERM would cut its cleanup short
	*) request_stop ;;
	esac
	flock -w "${1:-40}" 8
}

caller_in_session() {	# is the shell that called us tied to a live login session?
	local sid=${XDG_SESSION_ID:-}
	[ -n "$sid" ] || sid=$(loginctl show-session self -p Id --value 2>/dev/null) || sid=
	[ -n "$sid" ] || return 1
	# Terminals inside VS Code Remote or a tmux started from an earlier login inherit the ID of a
	# session that has already ended.
	case $(timeout 10 loginctl show-session "$sid" -p State --value 2>/dev/null) in
	active | online) return 0 ;;
	esac
	return 1
}

set_mode() {	# $1 = session | detached
	echo "$1" > "$STATE/mode.$$" && mv -f "$STATE/mode.$$" "$STATE/mode"
}

# Notes the supervisor leaves for the next start/status, one line "serial|time|reason":
#   lost   the lease ended because the board was lost (USB reset or unplugged, hw_server dead,
#          assign-fpga-board gone, supervisor killed): the next `make program` stops once
#   ended  an ordinary ending the student did not ask for (idle, logout, time limit): shown once
note_info() {	# $1 = lost | ended; prints the note if there is a fresh one
	local f=$STATE/$1 m
	[ -f "$f" ] || return 1
	m=$(stat -c %Y "$f" 2>/dev/null)
	if [ -n "$m" ] && [ $(( $(date +%s) - m )) -lt 86400 ]; then cat "$f"; else rm -f "$f"; return 1; fi
}

lost_info() { note_info lost; }

note_fields() {	# $1 = note; sets NS (serial), NT (time), NR (reason; may itself contain '|')
	IFS='|' read -r NS NT NR <<< "$1"
	NS=${NS:-?}; NT=${NT:-?}; NR=${NR:-its lease ended}
}

lost_message() {	# $1 = note
	note_fields "$1"
	say "your board $NS can no longer be used (since $NT): $NR."
	say "Its lease has been ended.  Nothing was claimed in its place, because a new claim could hand you a different physical board."
	say "Run 'make program' again to claim a board, and check the serial number on its sticker."
}

ended_message() {	# $1 = note
	note_fields "$1"
	say "your board $NS was given back at $NT: $NR."
}

# A lease that was ready and whose supervisor is gone without having released it was killed (OOM,
# kill -9): print its note, and mark the lease as released.  Needs the supervisor lock.
died_note() {
	local st serial
	st=$(cat "$STATE/status" 2>/dev/null)
	[ "$st" = ready ] || return 1
	serial=$(cat "$STATE/serial" 2>/dev/null)
	echo "${serial:-?}|$(date +%T)|its lease process was killed"
}

# Is the board's UART port still ours?  After an unplug or a USB reset the board comes back as new
# device nodes that carry no ACL for us.  The JTAG port is NOT part of this check: when Vivado's
# hw_server opens the board's JTAG interface, the kernel's ftdi_sio driver is detached from it and
# /dev/ttyU-BOARDn for JTAG disappears (and stays gone) although the board is perfectly fine;
# hw_server never touches the UART interface.  (The PMOD adapter is a separate USB device; losing
# only that one does not make the board a different one.)
ttys_ok() {
	local t
	[ -f "$STATE/ttys" ] || return 0
	while read -r t; do
		if [ -n "$t" ] && [ ! -w "$t" ]; then
			UNHEALTHY="its USB connection was reset or unplugged ($t is no longer yours)"
			return 1
		fi
	done < "$STATE/ttys"
	return 0
}

pmod_gone() {	# prints the PMOD port that is no longer ours, if any
	local t
	[ -f "$STATE/ttys_extra" ] || return 1
	while read -r t; do
		if [ -n "$t" ] && [ ! -w "$t" ]; then echo "$t"; return 0; fi
	done < "$STATE/ttys_extra"
	return 1
}

lease_healthy() {	# call only when the supervisor is running and status is ready
	local g
	UNHEALTHY=; HW_DOWN=0
	[ -s "$STATE/port" ] || { UNHEALTHY="the lease has no hw_server port"; return 1; }
	g=$(cat "$STATE/hw_pgid" 2>/dev/null)
	case $g in '' | *[!0-9]*) UNHEALTHY="hw_server is not running"; HW_DOWN=1; return 1 ;; esac
	kill -0 -- "-$g" 2>/dev/null || { UNHEALTHY="hw_server stopped"; HW_DOWN=1; return 1; }
	ttys_ok
}

wait_listening() {	# $1 = port; true when hw_server accepts connections (or when we cannot tell)
	local i
	command -v ss > /dev/null || return 0
	for ((i = 0; i < HW_TIMEOUT * 2; i++)); do
		[ -n "$(ss -Hltn "sport = :$1" 2>/dev/null)" ] && return 0
		sleep 0.5
	done
	return 1
}

# Healthy now, or only hw_server is down (`pkill hw_server`, a crash) and the supervisor, which
# restarts it at its next poll, still has time to do so.  Replacing the lease would also close
# the student's screen session on the UART, so avoid that when it is not needed.
lease_usable() {
	local i waited=0
	for ((i = 0; i < (POLL_SECS + 5) * 2; i++)); do
		if lease_healthy; then
			# a restarted hw_server needs a moment before it accepts connections
			[ "$waited" = 1 ] && wait_listening "$(cat "$STATE/port" 2>/dev/null)"
			return 0
		fi
		{ [ "$HW_DOWN" = 1 ] && sup_running; } || return 1
		waited=1
		sleep 0.5
	done
	return 1
}

# Older `make program` recipes started `sleep infinity | assign-fpga-board &` and hw_server in the
# background and never stopped them.  They stay in the process group of the `make` that started
# them, long after that make has exited.  Signal exactly those processes (the keepalive sleep, the
# sudo front-end of assign-fpga-board, the hw_server chain) in groups whose leader is gone: the
# assign-fpga-board runs its own cleanup and the board is given back.  Only this user's processes
# on this machine are touched, a hw_server you started by hand from a shell that is still open is
# left alone, and so is anything else that happens to share the group (a nohup'd Vivado GUI).
kill_leftovers() {
	local snap pid pg args mypg groups= sigs= suds= p i alive
	LEFTOVERS=0
	mypg=$(ps -o pgid= -p $$ | tr -d ' ')
	# real uid (-U): the sudo front-end runs with euid root but keeps the student's real uid
	snap=$(ps -U "$MYUID" -o pid= -o pgid= -o args= 2>/dev/null)
	while read -r pid pg args; do
		case $args in "$OLD_SLEEP" | *"$HW_PATTERN"*) ;; *) continue ;; esac
		[ "$pg" != "$mypg" ] || continue
		[ -d "/proc/$pg" ] && continue		# its group leader still runs: not a leftover
		case " $groups " in *" $pg "*) ;; *) groups="$groups $pg" ;; esac
	done <<< "$snap"
	[ -n "$groups" ] || return 0
	while read -r pid pg args; do
		case " $groups " in *" $pg "*) ;; *) continue ;; esac
		if [ "$args" = "$OLD_SLEEP" ] || [[ $args == *"$HW_PATTERN"* ]]; then
			sigs="$sigs $pid"
		elif [[ $args =~ $AFB_FRONT ]]; then
			sigs="$sigs $pid"; suds="$suds $pid"
		fi
	done <<< "$snap"
	[ -n "$sigs" ] || return 0
	say "stopping leftover assign-fpga-board/hw_server processes from an earlier 'make program'"
	LEFTOVERS=1
	kill -TERM $sigs 2>/dev/null
	for ((i = 0; i < 100; i++)); do
		alive=0
		for p in $suds; do [ -d "/proc/$p" ] && alive=1; done
		[ "$alive" = 0 ] && break
		sleep 0.1
	done
}

# The lab manual used to tell students to leave `assign-fpga-board` running in a terminal.  Close
# the ones of yours that are still around (only your own front-end processes can be signalled; the
# root script behind it runs its cleanup when sudo relays the TERM).
close_hand_run() {
	local pids p i alive
	pids=$(pgrep -U "$MYUID" -f "$AFB_FRONT") || return 1
	say "also closing assign-fpga-board that was running in another terminal"
	kill -TERM $pids 2>/dev/null
	for ((i = 0; i < 100; i++)); do
		alive=0
		for p in $pids; do [ -d "/proc/$p" ] && alive=1; done
		[ "$alive" = 0 ] && break
		sleep 0.1
	done
	return 0
}

# Older lab Makefiles (before this script) read scripts/port.tmp and serial.tmp from their last run
# when you already hold a board, and would aim Vivado at that stale port: possibly another
# student's hw_server.  Remove the stale files of the lab checkouts next to this one.
clean_sibling_stale() {
	local repo f
	repo=$(dirname "$(dirname "$SELF")")
	for f in "$repo"/../*/scripts/port.tmp "$repo"/../*/scripts/serial.tmp \
		"$repo"/../*/hardware/scripts/port.tmp "$repo"/../*/hardware/scripts/serial.tmp; do
		[ -f "$f" ] && rm -f "$f" 2>/dev/null
	done
	return 0
}

# The board's serial ports (UART, JTAG, PMOD): everything that is closed at release and whose use
# counts as activity.
uart_ports() {
	local f t
	for f in ttys ttys_jtag ttys_extra; do
		[ -f "$STATE/$f" ] || continue
		while read -r t; do [ -n "$t" ] && echo "$t"; done < "$STATE/$f"
	done
}

# Pids of your programs that name one of the board's serial ports on their command line (screen
# /dev/ttyU-BOARD4 115200, minicom -D ...).  GNU screen is setgid, so no unprivileged tool can
# see what it holds open (fuser cannot), but its command line is public.
uart_users() {
	local t r pid args ports snap
	ports=$(uart_ports)
	[ -n "$ports" ] || return 0
	snap=$(ps -U "$MYUID" -ww -o pid= -o args= 2>/dev/null 3>&- 8>&-)
	while read -r pid args; do
		[ -n "$pid" ] && [ "$pid" != "$$" ] || continue
		for t in $ports; do
			r=$(readlink -f "$t" 2>/dev/null 3>&- 8>&-)
			case " $args " in *" $t "* | *" $r "*) echo "$pid"; break ;; esac
		done
	done <<< "$snap"
	return 0
}

# Your own handles on the board's serial ports (a detached `screen`) would stay valid after the
# ACLs are removed and garble the next holder's UART, so close them first, while the ACLs still
# exist.
close_uart_users() {
	local t pids
	[ -n "$(uart_ports)" ] || return 0	# nothing was claimed: nothing to close
	for t in $(uart_ports); do
		timeout 5 fuser -s -k -TERM "$(readlink -f "$t")" > /dev/null 2>&1 3>&- 8>&-
	done
	pids=$(uart_users)
	[ -n "$pids" ] && kill -TERM $pids 2>/dev/null
	if [ -n "$KILLTTY_CMD" ]; then
		timeout 20 $KILLTTY_CMD < /dev/null > /dev/null 2>&1 3>&- 8>&-
	fi
	return 0
}

policy() {	# when does this lease end?
	local mode idle max
	mode=$(cat "$STATE/mode" 2>/dev/null)
	idle=$(cat "$STATE/idle_secs" 2>/dev/null) || idle=$IDLE_SECS
	max=$(cat "$STATE/max_secs" 2>/dev/null) || max=$MAX_SECS
	if [ "$mode" = session ]; then
		say "it is given back when you run 'make release', when you log out of $HOST, after $(duration "$idle") without 'make program', 'make board-status' or any use of the board (a UART program, a Vivado hardware manager connection), or after $(duration "$max") in any case"
	else
		say "this terminal is not tied to a login session (VS Code? tmux?), so logging out does not free the board right away."
		say "run 'make release' when you are done.  Otherwise it is given back once you have disconnected and $(duration "$DETACHED_SECS") have passed without 'make program', 'make board-status' or use of the board, or after $(duration "$idle") of the same, or after $(duration "$max") in any case"
	fi
}

report() {
	local port serial
	port=$(cat "$STATE/port" 2>/dev/null)
	if [ -z "$port" ]; then
		say "your board lease ended just now; run 'make program' again"
		exit 1
	fi
	serial=$(cat "$STATE/serial" 2>/dev/null)
	say "board ${serial:-?} is yours on $HOST (hw_server port $port)"
	grep -E '^(JTAG|UART|PMOD) serial port:' "$STATE/out" 2>/dev/null | sed 's/^/    /' >&2
	if [ -n "$PREV_SERIAL" ] && [ "$PREV_SERIAL" != "${serial:-?}" ]; then
		say "NOTE: this is NOT the board you had before ($PREV_SERIAL).  Check the serial number on its sticker."
	fi
	policy
	if [ -s "$STATE/warn" ]; then say "$(cat "$STATE/warn")"; rm -f "$STATE/warn"; fi
	echo "$port"
}

# Wait until a supervisor that is running (or starting) has either come up or given up.
wait_settled() {
	local i status
	for ((i = 0; i < (START_TIMEOUT + HW_TIMEOUT + 10) * 10; i++)); do
		status=$(cat "$STATE/status" 2>/dev/null)
		case $status in ready | failed | releasing | released) break ;; esac
		if [ $((i % 10)) = 9 ] && ! sup_running; then break; fi
		sleep 0.1
	done
	echo "$status"
}

claim() {	# called with fd 9 (main lock) and fd 8 (supervisor lock, taken by us) open
	local i p status m t0=$SECONDS
	kill_leftovers
	rm -f "$STATE/lost" "$STATE/stop_requested" "$STATE/warn"
	# the board this student had last (so that a different one is pointed out)
	PREV_SERIAL=
	if [ -s "$STATE/last_serial" ]; then
		m=$(stat -c %Y "$STATE/last_serial" 2>/dev/null)
		if [ -n "$m" ] && [ $(( $(date +%s) - m )) -lt 43200 ]; then PREV_SERIAL=$(cat "$STATE/last_serial"); fi
	fi
	rm -f "$STATE"/{supervisor.pid,port,serial,out,status,hw_server.pid,hw_pgid,ttys,ttys_jtag,ttys_extra,idle_secs,max_secs,mode,hw_restarts}
	clean_sibling_stale
	[ -s "$STATE/supervisor.log" ] && mv -f "$STATE/supervisor.log" "$STATE/supervisor.log.1"
	if caller_in_session; then set_mode session; else set_mode detached; fi
	echo starting > "$STATE/status"
	: > "$STATE/last_use"
	# Run the supervisor from a private copy: it lives for hours, and a script open on the NFS home
	# directory would leave .nfsXXXX files behind after a `git pull` or when the lab is deleted.
	cp -f "$SELF" "$STATE/fpga_lease.sh.$$" && mv -f "$STATE/fpga_lease.sh.$$" "$STATE/fpga_lease.sh" \
		|| { say "cannot copy the lease script into $STATE"; exit 1; }
	# setsid: the supervisor gets its own session, so closing this terminal or Ctrl-C in make does
	# not kill it.  It inherits fd 8 (the supervisor lock) and must not inherit fd 9.
	setsid -f bash "$STATE/fpga_lease.sh" _supervise < /dev/null >> "$STATE/supervisor.log" 2>&1 9>&-
	exec 8>&-
	for ((i = 0; i < (START_TIMEOUT + HW_TIMEOUT + 10) * 10; i++)); do
		status=$(cat "$STATE/status" 2>/dev/null)
		case $status in
		ready) report; return 0 ;;
		failed | releasing | released) break ;;
		esac
		if [ $((i % 10)) = 9 ] && ! sup_running; then break; fi
		sleep 0.1
	done
	say "could not get an FPGA board:"
	if [ "$status" = failed ] && [ -s "$STATE/out" ]; then
		sed 's/^/    /' "$STATE/out" >&2
	else
		tail -n 5 "$STATE/supervisor.log" 2>/dev/null | sed 's/^/    /' >&2
		if [ "$status" = failed ] || sup_running; then
			say "no answer after $(( SECONDS - t0 ))s: the machine may be overloaded.  Try again in a minute, use another machine, or ask a TA"
		fi
		if sup_running; then request_stop; fi
	fi
	if grep -q 'already have an instance' "$STATE/out" 2>/dev/null; then
		say "you have assign-fpga-board open somewhere else on $HOST (another terminal or tmux pane?)."
		say "run 'make release' (it also closes that one), then 'make program' again."
	elif grep -q 'currently in use' "$STATE/out" 2>/dev/null; then
		say "every board on $HOST is held by someone else; try another machine or ask a TA."
	fi
	exit 1
}

cmd_start() {
	local status info s
	init_state
	take_lock
	exec 8> "$STATE/sup.lock" || exit 1
	if ! flock -n 8; then
		# A supervisor is running, or still starting (an earlier, interrupted `make program`).
		status=$(wait_settled)
		s=$(cat "$STATE/serial" 2>/dev/null)	# before anything below waits: the supervisor may remove it
		# Reuse its lease if it still works.
		if [ "$status" = ready ] && sup_running && lease_usable; then
			touch "$STATE/last_use"
			caller_in_session && set_mode session	# a lease reused from a live login session is tied to it
			report
			return 0
		fi
		if [ "$status" = ready ]; then
			# A lease that was working no longer is.  End it, and do not claim another board in its
			# place without telling the student: it could be a different physical board.  The
			# note is written first, so the explanation survives even if the supervisor is slow.
			info=$(lost_info) || info=
			if [ -z "$info" ]; then
				info="${s:-?}|$(date +%T)|${UNHEALTHY:-its lease is ending}"
				echo "$info" > "$STATE/lost"
			fi
			if stop_supervisor 40; then
				s=$(lost_info) && info=$s	# the supervisor may have written a more precise note
				lost_message "$info"
				rm -f "$STATE/lost"
			else
				lost_message "$info"
				say "(its lease is still being given back: run 'make program' again in a minute)"
			fi
			exit 1
		fi
		case $status in
		releasing | released) ;;
		*) say "an earlier 'make program' of yours never finished claiming a board; starting over" ;;
		esac
		stop_supervisor 40 || { say "your previous lease is still being given back; try again in a minute"; exit 1; }
	fi
	# The previous lease ended by itself because the board was lost: say so once, claim nothing.
	if info=$(lost_info); then
		lost_message "$info"
		rm -f "$STATE/lost"
		exit 1
	fi
	# ... or its supervisor was killed (OOM, kill -9) without releasing.
	if info=$(died_note); then
		lost_message "$info"
		echo released > "$STATE/status"
		exit 1
	fi
	# An ordinary ending that the student did not ask for (idle, logout, time limit): say so once.
	if info=$(note_info ended); then
		ended_message "$info"
		rm -f "$STATE/ended"
	fi
	claim
}

cmd_supervise() {
	local fifo=$STATE/stdin.fifo
	local afb_pid= hw_pid= port= serial= reason=stopped lost= ended= misses=0 hw_restarts=0 hw_started=0 st last idle need t i claimed_at
	cd / || exit 1
	echo $$ > "$STATE/supervisor.pid"
	: > "$STATE/out"
	need=$(( (GRACE_SECS + POLL_SECS - 1) / POLL_SECS ))
	[ "$need" -ge 1 ] || need=1

	hw_ok() { [ -n "$hw_pid" ] && kill -0 -- "-$hw_pid" 2>/dev/null; }

	# hw_server is a wrapper -> loader -> binary chain.  It runs in its own session/process group
	# under a small watchdog (the group leader) that kills the whole group when hw_server exits or
	# when this supervisor dies, even by SIGKILL, so it can never be orphaned.
	start_hw() {
		setsid bash -c '
			sup=$1 log=$2; shift 2
			"$@" < /dev/null > "$log" 2>&1 &
			hw=$!
			while kill -0 "$hw" 2>/dev/null && kill -0 "$sup" 2>/dev/null; do sleep 3; done
			kill -TERM -- "-$$" 2>/dev/null
		' w "$$" "$STATE/hw_server.log" "$HW_SERVER" -stcp:localhost:"$port" < /dev/null 3>&- 8>&- &
		hw_pid=$!
		hw_started=$SECONDS
		echo "$hw_pid" > "$STATE/hw_server.pid"
		echo "$hw_pid" > "$STATE/hw_pgid"
	}

	stop_hw() {
		[ -n "$hw_pid" ] || return 0
		kill -TERM -- "-$hw_pid" 2>/dev/null
		for ((i = 0; i < 30; i++)); do kill -0 -- "-$hw_pid" 2>/dev/null || break; sleep 0.1; done
		kill -KILL -- "-$hw_pid" 2>/dev/null
		hw_pid=
	}

	# Is the board in use right now?  A client connected to our hw_server (the Vivado hardware
	# manager) or a program of yours holding a serial port counts as use, so the idle limit never
	# ends a lease under somebody who is debugging over the UART.
	board_busy() {
		local t
		if [ -n "$port" ] && command -v ss > /dev/null \
			&& [ -n "$(ss -Htn state established "( sport = :$port )" 2>/dev/null 3>&- 8>&-)" ]; then
			return 0
		fi
		for t in $(uart_ports); do
			timeout 5 fuser -s "$(readlink -f "$t")" > /dev/null 2>&1 3>&- 8>&- && return 0
		done
		[ -n "$(uart_users)" ]
	}

	release() {
		trap - EXIT TERM INT HUP
		[ "$(cat "$STATE/status" 2>/dev/null)" = failed ] || echo releasing > "$STATE/status"
		close_uart_users
		exec 3>&-	# EOF on its stdin: assign-fpga-board revokes the ACLs and drops its locks
		stop_hw
		if [ -n "$afb_pid" ]; then
			for ((i = 0; i < 100; i++)); do kill -0 "$afb_pid" 2>/dev/null || break; sleep 0.1; done
		fi
		[ -n "$lost" ] && echo "${serial:-?}|$(date +%T)|$reason" > "$STATE/lost"
		[ -n "$ended" ] && [ -z "$lost" ] && echo "${serial:-?}|$(date +%T)|$reason" > "$STATE/ended"
		rm -f "$STATE"/{supervisor.pid,port,serial,hw_server.pid,hw_pgid,ttys,ttys_jtag,ttys_extra,idle_secs,max_secs,hw_restarts,stop_requested}
		[ "$(cat "$STATE/status" 2>/dev/null)" = failed ] || echo released > "$STATE/status"
		echo "$(date '+%F %T') board ${serial:-?} port ${port:-?}: released ($reason)"
		logger -t fpga-lease "$(id -un): released board ${serial:-?} port ${port:-?} ($reason)" 2>/dev/null
	}
	# TERM from `make release` (it creates stop_requested first) is an ordinary ending; a TERM or
	# HUP from anybody else means the lease was killed.
	on_signal() {
		if [ -e "$STATE/stop_requested" ]; then
			reason="stopped by signal"
		else
			reason="its lease process was killed by a signal"; lost=1
		fi
		exit 0
	}
	trap on_signal TERM INT HUP
	trap release EXIT

	# assign-fpga-board keeps the board until its stdin reaches EOF.  fd 3 (read-write, so the
	# open never blocks) is the only writer; the child gets a read-only descriptor.  No long-lived
	# child may inherit fd 3 or fd 8 (the supervisor lock).
	rm -f "$fifo"
	mkfifo "$fifo" || { reason="mkfifo failed"; echo failed > "$STATE/status"; exit 1; }
	exec 3<> "$fifo" 4< "$fifo"
	rm -f "$fifo"
	"$ASSIGN" <&4 > "$STATE/out" 2>&1 3>&- 4<&- 8>&- &
	afb_pid=$!
	exec 4<&-

	for ((i = 0; i < START_TIMEOUT * 10; i++)); do
		port=$(sed -n 's/^Vivado hw_server port: \([0-9][0-9]*\)$/\1/p' "$STATE/out")
		[ -n "$port" ] && break
		if ! kill -0 "$afb_pid" 2>/dev/null; then
			reason="assign-fpga-board failed"; echo failed > "$STATE/status"; exit 1
		fi
		sleep 0.1
	done
	if [ -z "$port" ]; then
		reason="no port from assign-fpga-board"; echo failed > "$STATE/status"; exit 1
	fi
	serial=$(sed -n 's/^The FPGA board with serial \([^ ]*\) is now assigned to you\.$/\1/p' "$STATE/out")
	# The serial ports that are ours right now.  Losing the UART port later means the board is gone
	# (see ttys_ok).  The JTAG port (hw_server takes it away from the kernel driver) and the PMOD
	# adapter (a separate USB device) are only remembered so that programs holding them are closed
	# at the end.
	sed -n 's/^UART serial port: //p' "$STATE/out" \
		| while read -r t; do [ -w "$t" ] && echo "$t"; done > "$STATE/ttys"
	sed -n 's/^JTAG serial port: //p' "$STATE/out" \
		| while read -r t; do [ -w "$t" ] && echo "$t"; done > "$STATE/ttys_jtag"
	sed -n 's/^PMOD serial port: //p' "$STATE/out" \
		| while read -r t; do [ -w "$t" ] && echo "$t"; done > "$STATE/ttys_extra"

	start_hw
	if command -v ss > /dev/null; then	# do not report ready before hw_server accepts connections
		for ((i = 0; i < HW_TIMEOUT * 10; i++)); do
			[ -n "$(ss -Hltn "sport = :$port" 2>/dev/null)" ] && break
			if ! hw_ok; then
				reason="hw_server failed to start"; echo failed > "$STATE/status"
				{ echo "hw_server exited right after starting; its output:"; tail -n 5 "$STATE/hw_server.log"; } > "$STATE/out" 2>&1
				exit 1
			fi
			sleep 0.1
		done
		if [ -z "$(ss -Hltn "sport = :$port" 2>/dev/null)" ]; then
			echo "$(date '+%F %T') hw_server is not listening on port $port after ${HW_TIMEOUT}s"
			echo "NOTE: hw_server is still starting (the machine is slow).  If Vivado cannot connect, wait a minute and run 'make program' again." > "$STATE/warn"
		fi
	fi
	claimed_at=$(date +%s)
	echo "$port" > "$STATE/port"
	echo "$serial" > "$STATE/serial"
	echo "${serial:-?}" > "$STATE/last_serial"
	echo "$IDLE_SECS" > "$STATE/idle_secs"
	echo "$MAX_SECS" > "$STATE/max_secs"
	echo 0 > "$STATE/hw_restarts"
	echo ready > "$STATE/status"
	echo "$(date '+%F %T') board ${serial:-?} port $port: claimed ($(cat "$STATE/mode" 2>/dev/null))"

	while :; do
		sleep "$POLL_SECS" 3>&- 8>&- &
		wait $!
		if ! kill -0 "$afb_pid" 2>/dev/null; then
			reason="its assign-fpga-board process exited"; lost=1; break
		fi
		# use counts only while the student is logged in (misses is from the previous poll): a screen
		# left open after the student disconnected must not hold the board
		if [ "$misses" = 0 ] && board_busy; then touch "$STATE/last_use"; fi
		last=$(stat -c %Y "$STATE/last_use" 2>/dev/null)
		case $last in '' | *[!0-9]*) last=$(date +%s) ;; esac
		idle=$(( $(date +%s) - last ))
		if [ $(( $(date +%s) - claimed_at )) -ge "$MAX_SECS" ]; then
			reason="the lease reached its time limit of $(duration "$MAX_SECS")"; ended=1; break
		fi
		if [ "$idle" -ge "$IDLE_SECS" ]; then
			reason="the board was not used for $(duration "$IDLE_SECS")"; ended=1; break
		fi
		if ! hw_ok; then
			# only a crash loop ends the lease: a hw_server that ran for a while before it died
			# (a `pkill hw_server` hours later, say) starts the count again
			if [ $((SECONDS - hw_started)) -ge "$HW_STABLE_SECS" ]; then hw_restarts=0; fi
			if [ "$hw_restarts" -ge 3 ]; then reason="hw_server keeps stopping"; lost=1; break; fi
			hw_restarts=$((hw_restarts + 1))
			echo "$hw_restarts" > "$STATE/hw_restarts"
			echo "$(date '+%F %T') hw_server stopped; restarting it ($hw_restarts)"
			start_hw
		fi
		if ! ttys_ok; then reason="$UNHEALTHY"; lost=1; break; fi
		# Is the student still logged in?  Per user, not per session: a second ssh session or a
		# reconnect keeps the lease, and shells that inherited a dead session ID are covered too.
		st=$(timeout 10 loginctl show-user "$MYUID" -p State --value 2>&1 3>&- 8>&-)
		case $st in
		active | online) misses=0 ;;
		closing | lingering | *"not logged in"*) misses=$((misses + 1)) ;;
		*) ;;	# logind did not answer: do not guess
		esac
		if [ "$misses" -ge "$need" ]; then
			if [ "$(cat "$STATE/mode" 2>/dev/null)" = session ]; then
				reason="you logged out"; ended=1; break
			elif [ "$idle" -ge "$DETACHED_SECS" ]; then
				reason="you disconnected and the board was not used for $(duration "$DETACHED_SECS")"; ended=1; break
			fi
		fi
	done
	exit 0
}

cmd_stop() {
	local did=0 info
	init_state
	take_lock
	exec 8> "$STATE/sup.lock" || exit 1
	if ! flock -n 8; then
		if stop_supervisor 40; then
			say "board given back"; did=1
		else
			say "your board is still being given back; check 'make board-status' in a minute"; did=1
		fi
	fi
	exec 8>&-
	# a pending explanation is shown, not swallowed
	if info=$(lost_info); then
		lost_message "$info"; did=1
	elif ! sup_running && info=$(died_note); then
		lost_message "$info"; echo released > "$STATE/status"; did=1
	fi
	rm -f "$STATE/lost"
	if info=$(note_info ended); then ended_message "$info"; did=1; fi
	rm -f "$STATE/ended"
	kill_leftovers
	[ "$LEFTOVERS" = 1 ] && did=1
	close_hand_run && did=1
	[ "$did" = 1 ] || say "you are not holding a board on $HOST"
	return 0
}

cmd_status() {
	local serial info n t
	init_state
	exec 9> "$STATE/lock" || exit 1
	flock -w 10 9 || { say "another 'make program' / 'make release' of yours is running; try again in a moment"; exit 1; }
	if sup_running; then
		case $(cat "$STATE/status" 2>/dev/null) in
		ready)
			touch "$STATE/last_use"	# using `make board-status` counts as "still here"
			serial=$(cat "$STATE/serial" 2>/dev/null)
			say "you hold board ${serial:-?} on $HOST (hw_server port $(cat "$STATE/port" 2>/dev/null))"
			grep -E '^(JTAG|UART|PMOD) serial port:' "$STATE/out" 2>/dev/null | sed 's/^/    /' >&2
			policy
			if ! lease_healthy; then
				n=$(num "$(cat "$STATE/hw_restarts" 2>/dev/null)" 0)
				if [ "$HW_DOWN" = 1 ] && [ "$n" -lt 3 ] && ttys_ok; then
					say "NOTE: $UNHEALTHY.  Your lease restarts it within about ${POLL_SECS}s and 'make program' waits for that.  If hw_server keeps stopping, the lease ends and 'make program' tells you."
				else
					say "WARNING: $UNHEALTHY.  This lease can no longer be used: 'make program' will end it and tell you; then run 'make program' again."
				fi
			fi
			if t=$(pmod_gone); then
				say "NOTE: your PMOD serial adapter ($t) is no longer yours (replugged?).  The board itself is fine.  To get the adapter back, run 'make release' and then 'make program' (and check that the board is still the one you expect)."
			fi
			;;
		*) say "your board lease is just starting or being given back; try again in a few seconds" ;;
		esac
	else
		if info=$(lost_info); then
			note_fields "$info"
			say "your board $NS was lost at $NT ($NR); its lease was ended and nothing was claimed in its place."
			say "Run 'make program' to claim a board (check the serial number on its sticker)."
		elif info=$(died_note); then
			note_fields "$info"
			say "your board $NS lease ended unexpectedly at $NT ($NR); nothing was claimed in its place."
			say "Run 'make program' to claim a board (check the serial number on its sticker)."
		fi
		if info=$(note_info ended); then ended_message "$info"; rm -f "$STATE/ended"; fi
		say "you are not holding a board on $HOST"
		if pgrep -u "$MYUID" -x -f "$OLD_SLEEP" > /dev/null || pgrep -U "$MYUID" -f "$AFB_FRONT" > /dev/null; then
			say "but an older 'make program' (or an assign-fpga-board in another terminal) is still running; 'make release' cleans it up"
		fi
	fi
}

main() {
	case ${1:-} in
	start) cmd_start ;;
	stop) cmd_stop ;;
	status) cmd_status ;;
	version) echo "fpga_lease $VERSION" ;;
	_supervise) init_state; cmd_supervise ;;
	*) echo "usage: $0 start|stop|status|version" >&2; return 2 ;;
	esac
}
main "$@"; exit
