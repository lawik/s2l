/*
 * aubio analysis NIF: one hop of f32le mono in, {beat, bpm, onset, bands} out.
 *
 * The aubio trackers are stateful, so one resource per stream and hops must be
 * fed in order. Everything is preallocated in create/5; process/2 does only
 * fixed-size arithmetic, which keeps it in the microseconds a regular scheduler
 * wants.
 */

#include <erl_nif.h>

#include <aubio.h>

#include <math.h>
#include <stdint.h>
#include <string.h>

/* The zero-copy input view below reinterprets an Erlang binary as smpl_t. That
 * is only valid while aubio is built single-precision, which is its default. */
#if HAVE_AUBIO_DOUBLE
#error "s2l needs aubio built in single precision (smpl_t == float)"
#endif
typedef char s2l_smpl_is_float[(sizeof(smpl_t) == sizeof(float)) ? 1 : -1];

#define S2L_MAX_BANDS 512
#define S2L_MAX_METHOD_LEN 32

static ErlNifResourceType *s2l_analyzer_type = NULL;

static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_true;
static ERL_NIF_TERM atom_false;
static ERL_NIF_TERM atom_badarg;
static ERL_NIF_TERM atom_bad_frame_size;
static ERL_NIF_TERM atom_init_failed;
static ERL_NIF_TERM atom_beat;
static ERL_NIF_TERM atom_bpm;
static ERL_NIF_TERM atom_confidence;
static ERL_NIF_TERM atom_onset;
static ERL_NIF_TERM atom_bands;

typedef struct {
    /* aubio state is not reentrant and a resource is shareable across
     * processes, so every mutation is serialized. Contention is a non-issue at
     * one call per hop. */
    ErlNifMutex *lock;
    aubio_tempo_t *tempo;
    aubio_onset_t *onset;
    aubio_pvoc_t *pvoc;
    aubio_filterbank_t *filterbank;
    cvec_t *spectrum;
    fvec_t *band_out;
    fvec_t *tempo_out;
    fvec_t *onset_out;
    /* Only used when the incoming binary is not smpl_t-aligned. */
    fvec_t *scratch;
    unsigned int hop_size;
    unsigned int n_bands;
} s2l_analyzer;

static void s2l_analyzer_free(s2l_analyzer *a)
{
    if (a->tempo) {
        del_aubio_tempo(a->tempo);
    }
    if (a->onset) {
        del_aubio_onset(a->onset);
    }
    if (a->pvoc) {
        del_aubio_pvoc(a->pvoc);
    }
    if (a->filterbank) {
        del_aubio_filterbank(a->filterbank);
    }
    if (a->spectrum) {
        del_cvec(a->spectrum);
    }
    if (a->band_out) {
        del_fvec(a->band_out);
    }
    if (a->tempo_out) {
        del_fvec(a->tempo_out);
    }
    if (a->onset_out) {
        del_fvec(a->onset_out);
    }
    if (a->scratch) {
        del_fvec(a->scratch);
    }
    if (a->lock) {
        enif_mutex_destroy(a->lock);
    }

    memset(a, 0, sizeof(*a));
}

static void s2l_analyzer_dtor(ErlNifEnv *env, void *obj)
{
    (void)env;
    s2l_analyzer_free((s2l_analyzer *)obj);
}

static ERL_NIF_TERM s2l_error(ErlNifEnv *env, ERL_NIF_TERM reason)
{
    return enif_make_tuple2(env, atom_error, reason);
}

/* enif_make_double raises badarg on NaN and infinity. aubio should never
 * produce either, but a hostile or denormal input must not turn into an
 * exception from a function documented to return tuples. */
static ERL_NIF_TERM s2l_make_double(ErlNifEnv *env, double value)
{
    return enif_make_double(env, isfinite(value) ? value : 0.0);
}

static int on_load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
    (void)priv_data;
    (void)load_info;

    s2l_analyzer_type = enif_open_resource_type(env, NULL, "s2l_analyzer", s2l_analyzer_dtor,
                                                ERL_NIF_RT_CREATE, NULL);

    if (!s2l_analyzer_type) {
        return 1;
    }

    atom_ok = enif_make_atom(env, "ok");
    atom_error = enif_make_atom(env, "error");
    atom_true = enif_make_atom(env, "true");
    atom_false = enif_make_atom(env, "false");
    atom_badarg = enif_make_atom(env, "badarg");
    atom_bad_frame_size = enif_make_atom(env, "bad_frame_size");
    atom_init_failed = enif_make_atom(env, "init_failed");
    atom_beat = enif_make_atom(env, "beat");
    atom_bpm = enif_make_atom(env, "bpm");
    atom_confidence = enif_make_atom(env, "confidence");
    atom_onset = enif_make_atom(env, "onset");
    atom_bands = enif_make_atom(env, "bands");

    return 0;
}

static ERL_NIF_TERM s2l_create(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    unsigned int sample_rate, buf_size, hop_size, n_bands;
    ErlNifBinary tempo_method, onset_method;
    char tempo_name[S2L_MAX_METHOD_LEN + 1];
    char onset_name[S2L_MAX_METHOD_LEN + 1];

    (void)argc;

    if (!enif_get_uint(env, argv[0], &sample_rate) || !enif_get_uint(env, argv[1], &buf_size) ||
        !enif_get_uint(env, argv[2], &hop_size) || !enif_get_uint(env, argv[3], &n_bands) ||
        !enif_inspect_binary(env, argv[4], &onset_method) ||
        !enif_inspect_binary(env, argv[5], &tempo_method)) {
        return s2l_error(env, atom_badarg);
    }

    /* aubio's pvoc needs a window at least as long as the hop, and both sizes
     * feed FFT plans, so bad values are rejected here rather than surfacing as
     * aubio's own stderr complaints plus a NULL. */
    if (sample_rate == 0 || hop_size == 0 || buf_size < hop_size || n_bands == 0 ||
        n_bands > S2L_MAX_BANDS || onset_method.size == 0 ||
        onset_method.size > S2L_MAX_METHOD_LEN || tempo_method.size == 0 ||
        tempo_method.size > S2L_MAX_METHOD_LEN) {
        return s2l_error(env, atom_badarg);
    }

    memcpy(onset_name, onset_method.data, onset_method.size);
    onset_name[onset_method.size] = '\0';
    memcpy(tempo_name, tempo_method.data, tempo_method.size);
    tempo_name[tempo_method.size] = '\0';

    s2l_analyzer *a = enif_alloc_resource(s2l_analyzer_type, sizeof(s2l_analyzer));

    if (!a) {
        return s2l_error(env, atom_init_failed);
    }

    memset(a, 0, sizeof(*a));
    a->hop_size = hop_size;
    a->n_bands = n_bands;

    a->lock = enif_mutex_create("s2l_analyzer");
    a->tempo = new_aubio_tempo(tempo_name, buf_size, hop_size, sample_rate);
    a->onset = new_aubio_onset(onset_name, buf_size, hop_size, sample_rate);
    a->pvoc = new_aubio_pvoc(buf_size, hop_size);
    a->filterbank = new_aubio_filterbank(n_bands, buf_size);
    a->spectrum = new_cvec(buf_size);
    a->band_out = new_fvec(n_bands);
    a->tempo_out = new_fvec(2);
    a->onset_out = new_fvec(2);
    a->scratch = new_fvec(hop_size);

    if (!a->lock || !a->tempo || !a->onset || !a->pvoc || !a->filterbank || !a->spectrum ||
        !a->band_out || !a->tempo_out || !a->onset_out || !a->scratch) {
        enif_release_resource(a);
        return s2l_error(env, atom_init_failed);
    }

    /* Mel bands across the full range, so the spread carries real color
     * information from bass to treble. Nyquist comes from the caller's rate;
     * hardcoding it is exactly the mismatch that skews everything downstream. */
    if (aubio_filterbank_set_mel_coeffs(a->filterbank, (smpl_t)sample_rate, 0.0f,
                                        (smpl_t)sample_rate / 2.0f) != 0) {
        enif_release_resource(a);
        return s2l_error(env, atom_init_failed);
    }

    ERL_NIF_TERM term = enif_make_resource(env, a);
    enif_release_resource(a);

    return enif_make_tuple2(env, atom_ok, term);
}

static ERL_NIF_TERM s2l_process(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    s2l_analyzer *a;
    ErlNifBinary samples;

    (void)argc;

    if (!enif_get_resource(env, argv[0], s2l_analyzer_type, (void **)&a) ||
        !enif_inspect_binary(env, argv[1], &samples)) {
        return s2l_error(env, atom_badarg);
    }

    if (samples.size != (size_t)a->hop_size * sizeof(smpl_t)) {
        return s2l_error(env, atom_bad_frame_size);
    }

    fvec_t in;
    in.length = a->hop_size;

    /* Sub-binaries can start at any byte offset, and aubio may hand the data to
     * vectorized code, so an unaligned frame is copied instead of aliased. */
    if (((uintptr_t)samples.data % sizeof(smpl_t)) == 0) {
        in.data = (smpl_t *)(void *)samples.data;
    } else {
        memcpy(a->scratch->data, samples.data, samples.size);
        in.data = a->scratch->data;
    }

    enif_mutex_lock(a->lock);

    aubio_tempo_do(a->tempo, &in, a->tempo_out);
    aubio_onset_do(a->onset, &in, a->onset_out);
    aubio_pvoc_do(a->pvoc, &in, a->spectrum);
    aubio_filterbank_do(a->filterbank, a->spectrum, a->band_out);

    int beat = a->tempo_out->data[0] != 0;
    int onset = a->onset_out->data[0] != 0;
    double bpm = aubio_tempo_get_bpm(a->tempo);
    double confidence = aubio_tempo_get_confidence(a->tempo);

    ERL_NIF_TERM bands = enif_make_list(env, 0);

    for (int i = (int)a->n_bands - 1; i >= 0; i--) {
        bands = enif_make_list_cell(env, s2l_make_double(env, a->band_out->data[i]), bands);
    }

    enif_mutex_unlock(a->lock);

    ERL_NIF_TERM keys[] = {atom_beat, atom_bpm, atom_confidence, atom_onset, atom_bands};
    ERL_NIF_TERM values[] = {beat ? atom_true : atom_false, s2l_make_double(env, bpm),
                             s2l_make_double(env, confidence), onset ? atom_true : atom_false,
                             bands};
    ERL_NIF_TERM result;

    if (!enif_make_map_from_arrays(env, keys, values, 5, &result)) {
        return s2l_error(env, atom_init_failed);
    }

    return enif_make_tuple2(env, atom_ok, result);
}

static ErlNifFunc nif_funcs[] = {
    /* Builds FFT plans and filter coefficients: milliseconds, not microseconds,
     * so it goes to a dirty scheduler. It is a setup-time call regardless. */
    {"create", 6, s2l_create, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"process", 2, s2l_process, 0},
};

ERL_NIF_INIT(Elixir.S2l.Aubio.Native, nif_funcs, on_load, NULL, NULL, NULL)
