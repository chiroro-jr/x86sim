# x86Sim sdkcov: one run.sh / inputs.sh per device at a time: each launch terminates the running app, so two runs on one
# device kill each other's app. Sourced; `devlock <command...>` after pick_device runs the calling script again as
# <command...> under flock on sdkcov.lock in the device's state dir (var/run-a64<sfx>, whose `device` names it; else the
# device dir) and exits with its status, or returns at once in the process tree that holds the lock (that run, or the
# run.sh inputs.sh starts). flock -o: the locked descriptor is not inherited, so nothing the run starts (x86sim-aot, a
# build, the app) keeps the device locked after the run ends.
devlock() {
	local st l rc
	st=$(grep -lxF "$X86SIM_DEVICE" "$X86SIM_ROOT"/var/run-a64*/device 2>/dev/null | head -1)
	st=${st%/device}; l=${st:-$X86SIM_DEVICE}/sdkcov.lock
	if [ "${SDKCOV_LOCK:-}" = "$l" ]; then
		# the holder notes itself in the lock file (rewriting it keeps the lock), for a second run's message
		[ -n "${SDKCOV_LOCK_PID:-}" ] || { export SDKCOV_LOCK_PID=$$; echo "pid $$ since $(date '+%F %T'): ${*:2}" > "$l"; }
		return 0
	fi
	SDKCOV_LOCK=$l flock -n -o -E 75 "$l" "$@"; rc=$?
	[ "$rc" = 75 ] && echo "sdkcov: $(basename "$X86SIM_DEVICE") is busy: another run.sh / inputs.sh holds $l ($(cat "$l" 2>/dev/null)). A second run would kill its app; wait for it to end, or stop it." >&2
	exit "$rc"
}
