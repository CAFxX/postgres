# Copyright (c) 2026, PostgreSQL Global Development Group

# Unit test for md_foreach_punch_segment()
# (src/backend/storage/smgr/md.c), the function that splits a hole-punch
# block range at relation segment boundaries.
#
# The test extracts the real function text from md.c (via brace matching,
# so it always tests the current code), compiles it standalone with several
# RELSEG_SIZE values, and verifies that the emitted per-segment
# (first block, segment, byte offset, byte length) tuples exactly tile the
# input range: contiguous, non-overlapping, block-aligned, and each confined
# to a single segment.
#
# Three segment sizes are exercised: a small one (8 blocks), an odd
# non-power-of-two one (100 blocks, to catch bitmask-instead-of-modulo
# bugs), and the real 131072 blocks (1 GiB segments).
#
# A full end-to-end test through real segment files would need a >1 GiB
# relation; this unit test covers the splitting arithmetic deterministically
# in milliseconds instead.  Punching the wrong byte range would corrupt
# data, so this logic must not rely on inspection alone.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Utils;
use Test::More;
use File::Spec;
use File::Basename qw(dirname);

# The test compiles C code; skip everything if no C compiler exists.
my $cc_probe = $ENV{CC} || 'cc';
if (system("$cc_probe --version >/dev/null 2>&1") != 0)
{
	plan skip_all => 'no C compiler available';
}

plan tests => 5;

my $test_dir = dirname(__FILE__);
my $md_c = File::Spec->rel2abs(
	File::Spec->catfile($test_dir, '..', '..', '..', '..',
		'backend', 'storage', 'smgr', 'md.c'));
my $tmpdir = $PostgreSQL::Test::Utils::tmp_check;

# Extract md_foreach_punch_segment() from md.c by brace matching.  Always
# extracts from the current source, so the test can never go stale.  The
# signature spans multiple lines, so locate its start, back up to the
# "static void" declaration, then brace-match from the body's opening brace.
sub extract_function
{
	my ($path) = @_;
	open my $fh, '<', $path or die "cannot open $path: $!";
	my $src = do { local $/; <$fh> };
	close $fh;

	my $sig = "md_foreach_punch_segment(BlockNumber startblk, BlockNumber nblocks,";
	my $pos = index($src, $sig);
	die "md_foreach_punch_segment not found in $path" if $pos < 0;

	my $decl = rindex($src, "static void\n", $pos);
	die "declaration start not found in $path" if $decl < 0;

	my $brace = index($src, "\n{", $pos);
	die "opening brace not found in $path" if $brace < 0;
	$brace++;    # at the '{'

	my $depth = 0;
	my $i = $brace;
	while ($i < length($src))
	{
		my $ch = substr($src, $i, 1);
		$depth++ if $ch eq '{';
		$depth-- if $ch eq '}';
		if ($depth == 0)
		{
			return substr($src, $decl, $i - $decl + 1) . "\n";
		}
		$i++;
	}
	die "unbalanced braces extracting md_foreach_punch_segment from $path";
}

my $func_text = extract_function($md_c);
ok(length($func_text) > 500, 'extracted md_foreach_punch_segment from md.c');

# C template: minimal type definitions plus the recording callback and the
# test driver.  The real function text is appended after the template.
# RELSEG_SIZE is supplied with -D on the compiler command line.
my $c_template = <<'EOF';
/* Unit test for md_foreach_punch_segment(). */
#include <sys/types.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef uint32_t BlockNumber;
#define BLCKSZ 8192
#define Min(a, b) ((a) < (b) ? (a) : (b))

#if !defined(RELSEG_SIZE)
#error "Define RELSEG_SIZE on the compiler command line"
#endif

/* ---- real md_foreach_punch_segment() text follows ---- */
EOF

my $c_main = <<'EOF';

typedef struct
{
	BlockNumber first;
	int			segno;
	off_t		off;
	off_t		len;
} Piece;

static Piece pieces[16];
static int npieces;

static void
record_cb(BlockNumber firstblock, int segno, off_t seg_off, off_t seg_len,
		  void *arg)
{
	(void) arg;
	if (npieces >= 16)
	{
		printf("FAIL: too many pieces\n");
		exit(1);
	}
	pieces[npieces].first = firstblock;
	pieces[npieces].segno = segno;
	pieces[npieces].off = seg_off;
	pieces[npieces].len = seg_len;
	npieces++;
}

static int failures = 0;

static void
fail(const char *msg)
{
	printf("FAIL: %s\n", msg);
	failures++;
}

typedef struct
{
	BlockNumber first;
	int			segno;
	off_t		off;
	off_t		len;
} Expect;

typedef struct
{
	const char *name;
	BlockNumber start;
	BlockNumber nblocks;
	int			nexpect;
	Expect		expect[8];
} Case;

#if RELSEG_SIZE == 8
static const Case cases[] = {
	/* single block mid-segment */
	{"single block", 3, 1, 1,
		{{3, 0, (off_t) 3 * 8192, 8192}}},
	/* exactly one full segment */
	{"full segment", 0, 8, 1,
		{{0, 0, 0, (off_t) 8 * 8192}}},
	/* straddles a boundary */
	{"straddle", 7, 2, 2,
		{{7, 0, (off_t) 7 * 8192, 8192},
		 {8, 1, 0, 8192}}},
	/* starts exactly on a boundary */
	{"start on boundary", 8, 3, 1,
		{{8, 1, 0, (off_t) 3 * 8192}}},
	/* ends exactly on a boundary */
	{"end on boundary", 5, 3, 1,
		{{5, 0, (off_t) 5 * 8192, (off_t) 3 * 8192}}},
	/* spans four segments */
	{"four segments", 5, 20, 4,
		{{5, 0, (off_t) 5 * 8192, (off_t) 3 * 8192},
		 {8, 1, 0, (off_t) 8 * 8192},
		 {16, 2, 0, (off_t) 8 * 8192},
		 {24, 3, 0, 8192}}},
	/* empty range invokes no callbacks */
	{"empty range", 10, 0, 0,
		{{0, 0, 0, 0}}},
	/* large block numbers */
	{"large block numbers", 1000000, 5, 1,
		{{1000000, 125000, 0, (off_t) 5 * 8192}}},
};
#elif RELSEG_SIZE == 100
static const Case cases[] = {
	/* straddles a boundary (odd segment size) */
	{"straddle odd", 99, 3, 2,
		{{99, 0, (off_t) 99 * 8192, 8192},
		 {100, 1, 0, (off_t) 2 * 8192}}},
	/* spans three segments */
	{"three segments odd", 50, 200, 3,
		{{50, 0, (off_t) 50 * 8192, (off_t) 50 * 8192},
		 {100, 1, 0, (off_t) 100 * 8192},
		 {200, 2, 0, (off_t) 50 * 8192}}},
	/* exactly one full segment */
	{"full segment odd", 0, 100, 1,
		{{0, 0, 0, (off_t) 100 * 8192}}},
	/* single block, mid-segment */
	{"single block odd", 150, 1, 1,
		{{150, 1, (off_t) 50 * 8192, 8192}}},
};
#elif RELSEG_SIZE == 131072
static const Case cases[] = {
	/* straddles the real 1 GiB boundary */
	{"straddle 1 GiB", 131071, 3, 2,
		{{131071, 0, (off_t) 131071 * 8192, 8192},
		 {131072, 1, 0, (off_t) 2 * 8192}}},
	/* exactly one full real segment */
	{"full 1 GiB segment", 0, 131072, 1,
		{{0, 0, 0, (off_t) 131072 * 8192}}},
	/* ends one block into the next segment */
	{"cross 1 GiB", 131070, 4, 2,
		{{131070, 0, (off_t) 131070 * 8192, (off_t) 2 * 8192},
		 {131072, 1, 0, (off_t) 2 * 8192}}},
	/* boundary between segments 1 and 2 */
	{"second boundary", 262143, 2, 2,
		{{262143, 1, (off_t) 131071 * 8192, 8192},
		 {262144, 2, 0, 8192}}},
};
#else
#error "unexpected RELSEG_SIZE"
#endif

static void
run_case(const Case *c)
{
	int			i;
	off_t		total_len = 0;

	npieces = 0;
	md_foreach_punch_segment(c->start, c->nblocks, record_cb, NULL);

	if (npieces != c->nexpect)
	{
		char		buf[256];

		snprintf(buf, sizeof(buf),
				 "%s: expected %d pieces, got %d",
				 c->name, c->nexpect, npieces);
		fail(buf);
		return;
	}

	/* each emitted piece matches the expected tuple */
	for (i = 0; i < npieces; i++)
	{
		char		buf[256];

		if (pieces[i].first != c->expect[i].first ||
			pieces[i].segno != c->expect[i].segno ||
			pieces[i].off != c->expect[i].off ||
			pieces[i].len != c->expect[i].len)
		{
			snprintf(buf, sizeof(buf),
					 "%s: piece %d mismatch: got (first=%u seg=%d off=%lld len=%lld)",
					 c->name, i,
					 pieces[i].first, pieces[i].segno,
					 (long long) pieces[i].off, (long long) pieces[i].len);
			fail(buf);
		}
	}

	/*
	 * Generic tiling invariants, independent of the expected table: the
	 * pieces must exactly tile [start, start + nblocks) with no gaps or
	 * overlaps, each confined to its segment.
	 */
	for (i = 0; i < npieces; i++)
	{
		char		buf[256];

		if (pieces[i].len <= 0 || pieces[i].len % BLCKSZ != 0 ||
			pieces[i].off % BLCKSZ != 0)
		{
			snprintf(buf, sizeof(buf),
					 "%s: piece %d not block-aligned", c->name, i);
			fail(buf);
		}
		if (pieces[i].off != (off_t) (pieces[i].first % RELSEG_SIZE) * BLCKSZ)
		{
			snprintf(buf, sizeof(buf),
					 "%s: piece %d offset does not match block number",
					 c->name, i);
			fail(buf);
		}
		if (pieces[i].segno != (int) (pieces[i].first / RELSEG_SIZE))
		{
			snprintf(buf, sizeof(buf),
					 "%s: piece %d segment does not match block number",
					 c->name, i);
			fail(buf);
		}
		if (pieces[i].off + pieces[i].len > (off_t) RELSEG_SIZE * BLCKSZ)
		{
			snprintf(buf, sizeof(buf),
					 "%s: piece %d escapes its segment", c->name, i);
			fail(buf);
		}
		if (i > 0 &&
			pieces[i].first !=
			pieces[i - 1].first + pieces[i - 1].len / BLCKSZ)
		{
			snprintf(buf, sizeof(buf),
					 "%s: gap or overlap between pieces %d and %d",
					 c->name, i - 1, i);
			fail(buf);
		}
		total_len += pieces[i].len;
	}
	if (npieces > 0 && pieces[0].first != c->start)
	{
		char		buf[256];

		snprintf(buf, sizeof(buf),
				 "%s: first piece does not start at range start", c->name);
		fail(buf);
	}
	if (total_len != (off_t) c->nblocks * BLCKSZ)
	{
		char		buf[256];

		snprintf(buf, sizeof(buf),
				 "%s: pieces cover %lld bytes, expected %lld",
				 c->name,
				 (long long) total_len,
				 (long long) c->nblocks * BLCKSZ);
		fail(buf);
	}

	printf("%s: OK (%d pieces)\n", c->name, npieces);
}

int
main(void)
{
	unsigned int i;

	for (i = 0; i < sizeof(cases) / sizeof(cases[0]); i++)
		run_case(&cases[i]);

	if (failures == 0)
		printf("SEGMENT SPLIT TESTS PASSED\n");
	else
		printf("%d FAILURES\n", failures);
	return failures != 0;
}
EOF

sub run_split_variant
{
	my ($segsize) = @_;
	my $c_file = File::Spec->catfile($tmpdir, "punch_split_$segsize.c");
	my $bin = File::Spec->catfile($tmpdir, "punch_split_$segsize");
	# $ENV{CC} may contain flags; split into words.
	my @cc = split(' ', $ENV{CC} || 'cc');

	open my $fh, '>', $c_file or die "cannot write $c_file: $!";
	print $fh $c_template;
	print $fh $func_text;
	print $fh $c_main;
	close $fh or die "cannot close $c_file: $!";

	my $rc = system(@cc, '-Wall', '-Wextra', "-DRELSEG_SIZE=$segsize",
		'-o', $bin, $c_file);
	unlink $c_file;
	if ($rc != 0)
	{
		unlink $bin;
		return (0, "compile failed for RELSEG_SIZE=$segsize");
	}

	my $output = qx{$bin 2>&1};
	$rc = $?;
	unlink $bin;
	if ($rc != 0 || $output !~ /SEGMENT SPLIT TESTS PASSED/)
	{
		return (0, "RELSEG_SIZE=$segsize failed:\n$output");
	}
	return (1, $output);
}

my ($ok_small, $out_small) = run_split_variant(8);
ok($ok_small, 'segment splitting with small RELSEG_SIZE=8') or diag($out_small);

my ($ok_odd, $out_odd) = run_split_variant(100);
ok($ok_odd, 'segment splitting with odd RELSEG_SIZE=100') or diag($out_odd);

my ($ok_real, $out_real) = run_split_variant(131072);
ok($ok_real, 'segment splitting with real RELSEG_SIZE=131072') or diag($out_real);

# Test 5: randomized tiling-invariant sweep over many RELSEG_SIZE values,
# including primes, powers of two around the real size, and 1.  Each
# compiled variant runs 500 deterministic (fixed-seed) random ranges and
# checks the same tiling invariants as the table-driven tests above.
my $sweep_template = <<'EOF';
/* Randomized tiling-invariant sweep for md_foreach_punch_segment(). */
#include <sys/types.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef uint32_t BlockNumber;
#define BLCKSZ 8192
#define Min(a, b) ((a) < (b) ? (a) : (b))

#if !defined(RELSEG_SIZE)
#error "Define RELSEG_SIZE on the compiler command line"
#endif

/* ---- real md_foreach_punch_segment() text follows ---- */
EOF

my $sweep_main = <<'EOF';

typedef struct
{
	BlockNumber first;
	int			segno;
	off_t		off;
	off_t		len;
} Piece;

static Piece pieces[8192];
static int npieces;
static int failures;

static void
record_cb(BlockNumber firstblock, int segno, off_t seg_off, off_t seg_len,
		  void *arg)
{
	(void) arg;
	if (npieces >= 8192)
	{
		printf("FAIL: too many pieces\n");
		exit(1);
	}
	pieces[npieces].first = firstblock;
	pieces[npieces].segno = segno;
	pieces[npieces].off = seg_off;
	pieces[npieces].len = seg_len;
	npieces++;
}

/* Deterministic LCG; fixed seed so failures reproduce. */
static uint32_t rng_state = 0xC0FFEE;

static uint32_t
next_rand(void)
{
	rng_state = rng_state * 1103515245u + 12345u;
	return (rng_state >> 16) & 0x7FFFu;
}

static void
check_range(BlockNumber start, BlockNumber nblocks)
{
	int			i;
	off_t		total_len = 0;

	/*
	 * Skip ranges that would overflow BlockNumber: such inputs are
	 * impossible in practice (block numbers never approach 2^32), and
	 * the function's arithmetic is only defined for valid ranges.
	 */
	if (nblocks > 0 && start > 0xFFFFFFFFu - nblocks)
		return;

	npieces = 0;
	md_foreach_punch_segment(start, nblocks, record_cb, NULL);

	for (i = 0; i < npieces; i++)
	{
		if (pieces[i].len <= 0 || pieces[i].len % BLCKSZ != 0 ||
			pieces[i].off % BLCKSZ != 0)
		{
			printf("FAIL: start=%u nblocks=%u piece %d not block-aligned\n",
				   start, nblocks, i);
			failures++;
		}
		if (pieces[i].off != (off_t) (pieces[i].first % RELSEG_SIZE) * BLCKSZ)
		{
			printf("FAIL: start=%u nblocks=%u piece %d offset mismatch\n",
				   start, nblocks, i);
			failures++;
		}
		if (pieces[i].segno != (int) (pieces[i].first / RELSEG_SIZE))
		{
			printf("FAIL: start=%u nblocks=%u piece %d segment mismatch\n",
				   start, nblocks, i);
			failures++;
		}
		if (pieces[i].off + pieces[i].len > (off_t) RELSEG_SIZE * BLCKSZ)
		{
			printf("FAIL: start=%u nblocks=%u piece %d escapes segment\n",
				   start, nblocks, i);
			failures++;
		}
		if (i > 0 &&
			pieces[i].first !=
			pieces[i - 1].first + pieces[i - 1].len / BLCKSZ)
		{
			printf("FAIL: start=%u nblocks=%u gap/overlap at piece %d\n",
				   start, nblocks, i);
			failures++;
		}
		total_len += pieces[i].len;
	}
	if (nblocks > 0 && npieces > 0 && pieces[0].first != start)
	{
		printf("FAIL: start=%u nblocks=%u first piece misplaced\n",
			   start, nblocks);
		failures++;
	}
	if (total_len != (off_t) nblocks * BLCKSZ)
	{
		printf("FAIL: start=%u nblocks=%u covered %lld, expected %lld\n",
			   start, nblocks,
			   (long long) total_len, (long long) nblocks * BLCKSZ);
		failures++;
	}
	if (nblocks == 0 && npieces != 0)
	{
		printf("FAIL: empty range produced %d pieces\n", npieces);
		failures++;
	}
}

int
main(void)
{
	int			iter;

	for (iter = 0; iter < 500; iter++)
	{
		BlockNumber start;
		BlockNumber nblocks;
		uint32_t	r = next_rand();

		/*
		 * Mix range shapes: tiny, boundary-straddling, multi-segment,
		 * and huge.  Bias starts toward segment boundaries to stress
		 * the splitting arithmetic.
		 */
		if ((r % 4) == 0)
			start = (BlockNumber) (next_rand() % RELSEG_SIZE);
		else if ((r % 4) == 1)
			start = (BlockNumber) RELSEG_SIZE * (next_rand() % 5) +
				(next_rand() % 7) - 3;
		else
			start = (BlockNumber) (next_rand() * 7919u + next_rand());

		switch (next_rand() % 5)
		{
			case 0:
				nblocks = 1 + next_rand() % 10;
				break;
			case 1:
				nblocks = (BlockNumber) RELSEG_SIZE - 1 +
					next_rand() % 3;
				break;
			case 2:
				nblocks = (BlockNumber) RELSEG_SIZE * (1 + next_rand() % 3) +
					next_rand() % 11;
				break;
			case 3:
				nblocks = 0;
				break;
			default:
				nblocks = 1 + next_rand() % 1000;
				break;
		}
		check_range(start, nblocks);
	}

	if (failures == 0)
		printf("SWEEP PASSED\n");
	else
		printf("%d FAILURES\n", failures);
	return failures != 0;
}
EOF

sub run_sweep_variant
{
	my ($segsize) = @_;
	my $c_file = File::Spec->catfile($tmpdir, "punch_sweep_$segsize.c");
	my $bin = File::Spec->catfile($tmpdir, "punch_sweep_$segsize");
	my @cc = split(' ', $ENV{CC} || 'cc');

	open my $fh, '>', $c_file or die "cannot write $c_file: $!";
	print $fh $sweep_template;
	print $fh $func_text;
	print $fh $sweep_main;
	close $fh or die "cannot close $c_file: $!";

	my $rc = system(@cc, '-Wall', '-Wextra', "-DRELSEG_SIZE=$segsize",
		'-o', $bin, $c_file);
	unlink $c_file;
	if ($rc != 0)
	{
		unlink $bin;
		return (0, "compile failed for RELSEG_SIZE=$segsize");
	}

	my $output = qx{$bin 2>&1};
	$rc = $?;
	unlink $bin;
	if ($rc != 0 || $output !~ /SWEEP PASSED/)
	{
		return (0, "RELSEG_SIZE=$segsize failed:\n$output");
	}
	return (1, $output);
}

my $sweep_ok = 1;
my $sweep_diag = '';
for my $sz (1, 2, 3, 7, 1000, 131071, 131072, 131073)
{
	my ($ok, $out) = run_sweep_variant($sz);
	if (!$ok)
	{
		$sweep_ok = 0;
		$sweep_diag .= $out . "\n";
	}
}
ok($sweep_ok, 'randomized tiling sweep over RELSEG_SIZE 1,2,3,7,1000,131071,131072,131073')
	or diag($sweep_diag);
