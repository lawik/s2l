# Quality review

A defensive-coding and BEAM-safety review of the library, with the NIF as the
main subject. Reviewed 2026-08-08 against aubio 0.4.9 as vendored by the build.
File/line references are to the tree at that date.

## Verdict

The NIF is unusually well defended and the test suite genuinely attacks it.
The load-bearing assumptions were verified against the aubio source rather
than trusted. Two real gaps remained — one a reachable BEAM crash (finding 1),
one a scheduler-health hazard (finding 2) — plus smaller hardening items.

**All findings below are resolved as of 2026-08-08.** Each carries a
resolution note. Every claim was re-verified against the vendored aubio source
and by executing the failing case before the fix was written, and each fix has
a regression test.

## Verified assumptions

Claims the code relies on, checked against the vendored aubio 0.4.9 source in
`_build/*/lib/s2l/native/aubio-0.4.9`:

* **aubio only reads its input.** The zero-copy view in `s2l_process` casts a
  shared immutable Erlang binary to `smpl_t *`; a write through it would
  corrupt the BEAM heap. `aubio_pvoc_do`, `aubio_tempo_do` and
  `aubio_onset_do` all take `const fvec_t *` and only `memcpy` *from* it
  (`src/spectral/phasevoc.c:165-177`). Safe.
* **aubio never exits the process.** `AUBIO_QUIT` is defined as `exit()` in
  `aubio_priv.h` but is unused in the compiled `src/` tree (it appears only in
  examples/tools, which this build excludes). No `abort()` either.
* **Non-power-of-two windows fail cleanly.** This build always uses the
  bundled ooura FFT, which rejects non-power-of-two sizes with a NULL return;
  every aubio constructor result is NULL-checked in `s2l_create`, so the
  result is `{:error, :init_failed}`, not a crash. (But see finding 6: noisy
  and undocumented.)
* **Defensive details present and correct:** compile-time `smpl_t == float`
  assert; destructor tolerates partially-initialized resources; NaN/Inf
  clamped before term building (`enif_make_double` raises on non-finite);
  `!(fmin >= 0.0)` rejects NaN; method strings length-capped before `memcpy`;
  `create` on a dirty scheduler; unaligned frames copied instead of aliased.
* **Adversarial tests in place:** 500 random binaries, correctly-sized random
  bit patterns (NaN/Inf as floats), unaligned sub-binaries, 8-process
  concurrent hammering, GC reclamation of dropped analyzers.
* The `erl_crash.dump` found in the repo root during review was unrelated: a
  boot-time `io.put_chars` failure with no s2l NIF in the taints list.

## Findings

### 1. Unbounded `buf_size`/`hop_size` is a reachable segfault

`s2l_create` (`c_src/s2l_aubio_nif.c:225-230`) caps `n_bands` at 512 but puts
no ceiling on `buf_size`/`hop_size`. Inside aubio, `AUBIO_ARRAY` is
`calloc((_n)*sizeof(_t), 1)` and the result is **never NULL-checked**:
`new_fvec` returns a non-NULL struct with a NULL `data` pointer, and
`new_aubio_window` immediately writes coefficients through it.

Consequences, all reachable from Elixir with a power-of-two size that passes
every current check:

* On a memory-constrained device (e.g. a 512 MB Nerves target),
  `Aubio.create(44_100, buf_size: 1 <<< 27, hop_size: 1 <<< 27)` fails the
  512 MB calloc and **segfaults the BEAM inside `create`**.
* On 32-bit ARM targets the multiply happens inside calloc's first argument,
  so `1 <<< 30` wraps `size_t` to 0: calloc returns a tiny valid buffer and
  aubio writes gigabytes through it — heap corruption.
* On overcommitting Linux the allocation "succeeds" and the OOM killer takes
  the BEAM down when the pages are touched.

The NIF's own NULL checks cannot catch any of this because aubio's
constructors do not propagate the failure.

**Fix:** reject `buf_size` above a hard cap (16384, or 65536 at most) in the
C validation. No audio-analysis window needs more, and `buf_size >= hop_size`
then bounds the hop too.

**Resolved.** `S2L_MAX_BUF_SIZE` is 16384, enforced in `s2l_create` before
any aubio call. Confirmed against the vendored source that `AUBIO_ARRAY` is an
unchecked `calloc` and `new_fvec` dereferences `AUBIO_NEW` without checking
either. `Aubio.create(44_100, buf_size: 1 <<< 27)` now returns `{:error,
:badarg}` instead of segfaulting.

### 2. `process/2` cost is unbounded on a normal scheduler

The per-hop cost is dominated by an FFT of `buf_size`. Measured on an M-series
Mac: 20 µs at the default 1024, 535 µs at 16384, 2.4 ms at 65536, **10.3 ms at
262144** — far past the 1 ms scheduler guideline, and small ARM devices are
several times slower. Any of these sizes is legal today.

**Fix:** the cap from finding 1 solves this for a 16384 ceiling (~0.5 ms
worst case on desktop). If larger windows should stay supported, register a
second dirty-scheduler entry for `process` and select per-analyzer.

**Resolved** by the 16384 cap. Larger windows are rejected rather than run
slowly, so `process/2` stays defensible on a normal scheduler. The dirty
variant is left for whenever a real need for bigger windows turns up.

### 3. Unaligned-path `memcpy` into `scratch` races outside the mutex

`c_src/s2l_aubio_nif.c:311` copies into the shared `a->scratch` buffer
*before* taking the lock at line 315. Two processes feeding unaligned frames
concurrently: B overwrites `scratch` while A, already holding the lock, is
mid-analysis reading it. A C11 data race that silently corrupts A's input —
contradicting the documented "safe to share between processes — calls are
serialized" guarantee (`lib/s2l/aubio.ex:19`). Not a crash (same-size write
into a valid buffer) and rare in practice (Membrane sub-binaries land
4-byte-aligned), but wrong.

**Fix:** move `enif_mutex_lock` above the alignment branch.

**Resolved.** The lock is now taken before the alignment test, so the copy
into `scratch` happens under it. Covered by a test hammering the unaligned
path from eight processes at once.

### 4. No `upgrade` callback in `ERL_NIF_INIT`

`c_src/s2l_aubio_nif.c:363` passes NULL for upgrade. Hot reload of
`S2l.Aubio.Native` — a recompile in a live iex session, or a release hot
upgrade — fails the second `load_nif`, leaving the module stubbed with every
call raising `:nif_not_loaded`.

**Fix:** add a trivial upgrade callback returning 0 and open the resource
type with `ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER`.

**Resolved.** Load and upgrade share an `s2l_init` helper, since a reloaded
library gets fresh statics and the cached atoms need re-establishing too.
`load` passes `ERL_NIF_RT_CREATE`; `upgrade` adds `ERL_NIF_RT_TAKEOVER`.

### 5. `ColorMapper.configure/2` validates nothing

`lib/s2l/color_mapper.ex:278` merges options straight into config, and the
docs advertise `configure/2` as the live-tuning loop, so bad values will be
typed at runtime:

* `configure(fps: 0)` — `div(1000, 0)` crashes the GenServer on the next
  tick, dropping subscriptions and adaptation state.
* `fps: 2000` — `div(1000, fps)` is 0, producing a zero-interval tick storm
  that pegs a scheduler.
* `history: -1` — `Enum.take(list, -1)` keeps the *oldest* frame instead of
  none.
* Unknown keys merge silently; a typo'd option does nothing with no feedback.

**Fix:** validate/clamp in `configure` (and `start_link`), reject unknown
keys.

**Resolved.** A `@bounds` table drives validation in both `configure/2` and
`init/1`. Values are rejected rather than clamped — silently moving a number
makes a live tuning loop lie about what is running — as `{:error,
{:invalid_option, key, value}}` or `{:error, {:unknown_option, key}}`, leaving
the running config untouched. A compile-time check fails the build if a
default gains no bounds entry.

### 6. The power-of-two `buf_size` constraint is undocumented and noisy

A non-power-of-two `buf_size` is rejected — but as three `AUBIO ERROR:` lines
on stderr followed by a generic `{:error, :init_failed}`. On a Nerves device
that lands on the console.

**Fix:** check `buf_size & (buf_size - 1)` in `s2l_create` and return
`:badarg` before aubio is reached; document the requirement in `create/2`.

**Resolved.** Checked in `s2l_create`; `buf_size: 1000` now returns
`{:error, :badarg}` with nothing on stderr. Both the power-of-two requirement
and the ceiling are documented in `create/2`.

### Smaller notes

* ~~`Native.load_nif/0` raises a confusing function-clause error during
  on_load if `:code.priv_dir/1` returns `{:error, :bad_name}`.~~ **Resolved:**
  matched explicitly, failing the load with `{:priv_dir_unavailable, reason}`.
* ~~Calling `ColorMapper.subscribe/1` twice from the same process delivers
  duplicate frames per tick.~~ **Resolved:** a second subscribe from the same
  process is a no-op. Easy to hit with a LiveView remounting on reconnect.
* ~~The stale `erl_crash.dump` in the repo root can be deleted.~~
  **Resolved:** deleted, after confirming it was a boot-time
  `io.put_chars` failure to a closed stderr with no s2l NIF in the taints
  list — collateral from killed background runs during development.
