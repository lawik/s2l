# Builds the aubio NIF, including aubio itself.
#
# aubio is downloaded, checksummed and compiled from source into a static
# archive that is linked into the NIF. Nothing is installed on the system and
# nothing is linked dynamically, so a host build and a Nerves cross-build are
# the same path: point CC and AR at a toolchain and the output is a NIF for
# that target.
#
# Only aubio's DSP sources are built. Its io/ layer (libsndfile, ffmpeg,
# CoreAudio) and synth/sampler are excluded, and no external FFT backend is
# enabled, so aubio uses its bundled ooura implementation. That leaves libm as
# the only dependency, which is what makes this cross-compile without fuss.
#
# Overridable from the environment:
#   CC, AR, CFLAGS, LDFLAGS, CROSS_COMPILE
#   AUBIO_SOURCE_DIR  an already-extracted aubio tree; skips download entirely
#   AUBIO_TARBALL     an already-downloaded tarball; skips the network fetch

AUBIO_VERSION = 0.4.9

# Two independent release artifacts of the same version, each pinned to its own
# checksum. They are tried in order and both extract to aubio-$(AUBIO_VERSION)/
# with identical sources; only the compression differs, which `tar xf` detects.
# GitHub goes first purely because aubio.org is frequently slow to the point of
# timing out, and an unreachable mirror should be an inconvenience rather than a
# failed build.
AUBIO_SOURCES = \
  https://github.com/aubio/aubio/archive/refs/tags/$(AUBIO_VERSION).tar.gz@0f09bee62f752d2be3a620966f020e72a027fed6838d7e9389e8305507f12455 \
  https://aubio.org/pub/aubio-$(AUBIO_VERSION).tar.bz2@d48282ae4dab83b3dc94c16cf011bcb63835c1c02b515490e1883049c3d1f3da

# Set by elixir_make; the fallbacks are for standalone `make`.
MIX_ENV ?= dev
MIX_APP_PATH ?= $(CURDIR)/_build/$(MIX_ENV)/lib/s2l
ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval "io:format('~ts/erts-~ts/include', [code:root_dir(), erlang:system_info(version)])." -s init stop)

PRIV_DIR = $(MIX_APP_PATH)/priv
NATIVE_DIR = $(MIX_APP_PATH)/native
OBJ_DIR = $(NATIVE_DIR)/obj

NIF = $(PRIV_DIR)/s2l_aubio_nif.so
VERIFY = $(NATIVE_DIR)/verify

# Make defines CC and AR itself, so `?=` cannot see whether the caller meant
# them. $(origin) can: only fill them in from CROSS_COMPILE when they are still
# Make's own defaults.
ifneq ($(CROSS_COMPILE),)
  ifeq ($(origin CC),default)
    CC = $(CROSS_COMPILE)gcc
  endif
  ifeq ($(origin AR),default)
    AR = $(CROSS_COMPILE)ar
  endif
endif

# Named without a compression suffix because which mirror answered decides the
# format, and `tar xf` works it out either way.
AUBIO_TARBALL ?= $(NATIVE_DIR)/aubio-$(AUBIO_VERSION).tar
AUBIO_LIB = $(NATIVE_DIR)/libaubio.a
# Written once the tree is extracted, so the archive does not depend on a
# directory timestamp that every write inside it would bump.
AUBIO_STAMP = $(NATIVE_DIR)/.aubio-$(AUBIO_VERSION)-extracted

# A caller-supplied tree is used as-is: nothing to fetch, nothing to unpack.
ifndef AUBIO_SOURCE_DIR
AUBIO_SOURCE_DIR = $(NATIVE_DIR)/aubio-$(AUBIO_VERSION)
AUBIO_SRC_DEP = $(AUBIO_STAMP)
endif

# aubio guards every system include behind a HAVE_ macro that its waf build
# would put in a config.h. Supplying them directly avoids running waf, and
# therefore avoids needing Python on the build host or in a cross environment.
AUBIO_DEFS = -DHAVE_STDLIB_H=1 -DHAVE_STDIO_H=1 -DHAVE_MATH_H=1 -DHAVE_STRING_H=1 \
             -DHAVE_ERRNO_H=1 -DHAVE_LIMITS_H=1 -DHAVE_STDARG_H=1
AUBIO_BUILD_CFLAGS = -O2 -fPIC -std=c99 $(AUBIO_DEFS) -I$(AUBIO_SOURCE_DIR)/src

CFLAGS ?= -O2 -Wall -Wextra
CFLAGS += -std=c11 -fPIC -I$(ERTS_INCLUDE_DIR) -I$(AUBIO_SOURCE_DIR)/src

# Shared-library flags follow the *target*, not the build host. `uname -s`
# reports the host, so a macOS machine cross-compiling for a Linux device would
# hand Darwin flags to a GNU linker, where `-dynamiclib` parses as a string of
# one-letter debug options and `-undefined` sends ld hunting for a file named
# `dynamic_lookup`. Asking the compiler what it targets is right either way.
TARGET_TRIPLE := $(shell $(CC) -dumpmachine 2>/dev/null)
ifneq (,$(findstring darwin,$(TARGET_TRIPLE)))
SO_LDFLAGS = -dynamiclib -undefined dynamic_lookup
else
SO_LDFLAGS = -shared
endif

ifeq ($(shell command -v sha256sum >/dev/null 2>&1 && echo yes),yes)
SHA256 = sha256sum
else
SHA256 = shasum -a 256
endif

# Fail reasonably fast on an unresponsive mirror, since there is another one.
ifeq ($(shell command -v curl >/dev/null 2>&1 && echo yes),yes)
FETCH = curl -fsSL --connect-timeout 15 --max-time 600 -o
else
FETCH = wget -q --timeout=15 -O
endif

.PHONY: all clean distclean verify

all: $(NIF)

$(NIF): c_src/s2l_aubio_nif.c $(AUBIO_LIB)
	@mkdir -p $(PRIV_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) $(SO_LDFLAGS) $< $(AUBIO_LIB) -lm -o $@

# The standalone C spike. Proves the aubio call sequence with no BEAM in the
# picture, so a failure here is DSP, and a failure only in the NIF is glue.
verify: $(VERIFY)
	$(VERIFY)

$(VERIFY): c_src/verify.c $(AUBIO_LIB)
	@mkdir -p $(NATIVE_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) $< $(AUBIO_LIB) -lm -o $@

# One archive rule rather than per-file rules: these sources are pinned to a
# release and change only when AUBIO_VERSION does, so incremental compilation
# would buy nothing.
$(AUBIO_LIB): $(AUBIO_SRC_DEP)
	@mkdir -p $(OBJ_DIR)
	@echo "Compiling aubio $(AUBIO_VERSION) with $(CC)"
	cd $(OBJ_DIR) && find $(AUBIO_SOURCE_DIR)/src -name '*.c' \
	    ! -path '*/io/*' ! -path '*/synth/*' ! -name 'windll.c' -print0 \
	  | xargs -0 $(CC) $(AUBIO_BUILD_CFLAGS) -c
	$(AR) rcs $@ $(OBJ_DIR)/*.o

$(AUBIO_STAMP): $(AUBIO_TARBALL)
	@mkdir -p $(NATIVE_DIR)
	tar xf $(AUBIO_TARBALL) -C $(NATIVE_DIR)
	@touch $@

# Tries each mirror until one both downloads and matches its pinned checksum.
# A tarball is only moved into place after it verifies, so an interrupted or
# corrupted fetch cannot leave a poisoned cache behind.
$(AUBIO_TARBALL):
	@mkdir -p $(NATIVE_DIR)
	@for entry in $(AUBIO_SOURCES); do \
	  url=$${entry%@*}; want=$${entry##*@}; \
	  echo "Fetching aubio $(AUBIO_VERSION) from $$url"; \
	  if ! $(FETCH) $@.tmp "$$url"; then \
	    echo "  unreachable, trying next source"; \
	    continue; \
	  fi; \
	  got=`$(SHA256) $@.tmp | cut -d' ' -f1`; \
	  if [ "$$got" = "$$want" ]; then \
	    mv $@.tmp $@; \
	    exit 0; \
	  fi; \
	  echo "  checksum mismatch: expected $$want, got $$got"; \
	  rm -f $@.tmp; \
	done; \
	echo "Could not obtain aubio $(AUBIO_VERSION) from any source."; \
	echo "Set AUBIO_TARBALL or AUBIO_SOURCE_DIR to build from a local copy."; \
	exit 1

clean:
	$(RM) -r $(NIF) $(VERIFY) $(AUBIO_LIB) $(OBJ_DIR)

# Also drops the downloaded and extracted aubio tree.
distclean: clean
	$(RM) -r $(NATIVE_DIR)
