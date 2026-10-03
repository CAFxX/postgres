
# Copyright (c) 2026, PostgreSQL Global Development Group

# Test that lazy VACUUM deallocates the filesystem blocks backing completely
# empty heap pages ("hole punching"), while leaving the logical relation
# size unchanged and the remaining data intact.
#
# Hole punching is best-effort: platforms and filesystems without support
# are supposed to silently do nothing.  So first probe the filesystem
# directly with a small C program that mirrors md.c's platform branches;
# if it can't punch holes, there is nothing to test here.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use File::Spec;

# Portable pre-flight probe.  Compiles and runs a tiny C program that tries
# the platform's hole-punch API (same #ifdef chain as md_punchhole_range())
# on a file in tmp_check (same filesystem as the test cluster's data dir).
# Returns true iff blocks were deallocated while the file size was unchanged.
my $probe_c = File::Spec->catfile(
	$PostgreSQL::Test::Utils::tmp_check, 'punch_probe.c');
my $probe_bin = File::Spec->catfile(
	$PostgreSQL::Test::Utils::tmp_check, 'punch_probe');
my $probe_file = File::Spec->catfile(
	$PostgreSQL::Test::Utils::tmp_check, 'punch_probe_file');

my $probe_source = <<'EOF';
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

#ifdef __linux__
#include <linux/falloc.h>
#endif
#ifdef __FreeBSD__
#include <sys/spacectl.h>
#endif

int
main(int argc, char **argv)
{
	const char *path;
	int			fd;
	struct stat st_before, st_after;
	char		buf[8192];
	int			i;
	int			rc = -1;

	if (argc != 2)
		return 2;
	path = argv[1];

	fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		return 2;

	memset(buf, 0, sizeof(buf));
	for (i = 0; i < 16; i++)
	{
		if (write(fd, buf, sizeof(buf)) != sizeof(buf))
		{
			close(fd);
			return 2;
		}
	}

	/*
	 * fsync before fstat: st_blocks must reflect allocated storage, not
	 * page-cache state the kernel has not accounted yet.
	 */
	if (fsync(fd) < 0)
	{
		close(fd);
		return 2;
	}
	if (fstat(fd, &st_before) < 0)
	{
		close(fd);
		return 2;
	}

	/*
	 * Branch conditions mirror src/backend/storage/smgr/md.c
	 * (md_punchhole_range), so the probe tests the same API the backend
	 * will use on this platform.
	 */
#if defined(FALLOC_FL_PUNCH_HOLE)
	rc = fallocate(fd, FALLOC_FL_KEEP_SIZE | FALLOC_FL_PUNCH_HOLE, 0, 65536);
#elif defined(F_PUNCHHOLE)
	{
		fpunchhole_t fp;

		memset(&fp, 0, sizeof(fp));
		fp.fp_offset = 0;
		fp.fp_length = 65536;
		rc = fcntl(fd, F_PUNCHHOLE, &fp);
	}
#elif defined(__FreeBSD__) && defined(SPACECTL_DEALLOC)
	{
		struct spacectl_range range;

		range.r_offset = 0;
		range.r_len = 65536;
		rc = fspacectl(fd, SPACECTL_DEALLOC, &range, 0, NULL);
	}
#elif (defined(__sun) || defined(__illumos__)) && defined(F_FREESP)
	{
		struct flock fl;

		memset(&fl, 0, sizeof(fl));
		fl.l_whence = SEEK_SET;
		fl.l_start = 0;
		fl.l_len = 65536;
		rc = fcntl(fd, F_FREESP, &fl);
	}
#else
	/* No hole-punch API on this platform. */
	close(fd);
	return 3;
#endif

	if (rc != 0)
	{
		close(fd);
		return 1;
	}

	if (fsync(fd) < 0)
	{
		close(fd);
		return 2;
	}
	if (fstat(fd, &st_after) < 0)
	{
		close(fd);
		return 2;
	}
	close(fd);

	/* Punch worked iff blocks dropped but the file size is unchanged. */
	if (st_after.st_blocks < st_before.st_blocks &&
		st_after.st_size == st_before.st_size)
		return 0;
	return 1;
}
EOF

sub probe_punch_hole
{
	# $ENV{CC} may contain flags (e.g. "ccache cc -m64"); split into words
	# so system() does not look for a binary literally named "cc -m64".
	my @cc = split(' ', $ENV{CC} || 'cc');

	# Write, compile, and run the probe.  Clean up on every path.
	open my $fh, '>', $probe_c or return 0;
	print $fh $probe_source;
	close $fh or return 0;

	if (system(@cc, '-o', $probe_bin, $probe_c) != 0)
	{
		unlink $probe_c;
		return 0;
	}

	my $rc = system($probe_bin, $probe_file);

	unlink $probe_c, $probe_bin, $probe_file;
	return $rc == 0;
}

if (!probe_punch_hole())
{
	plan skip_all => 'filesystem does not support hole punching';
}

plan tests => 31;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
# Disable autovacuum: a worker doing index cleanup between our VACUUMs could
# convert LP_DEAD to LP_UNUSED and break the no-punch assertions below.
$node->append_conf('postgresql.conf', 'autovacuum = off');
# Disable automatic checkpoints: the LSN-gate test asserts that pages with
# LSNs newer than the last checkpoint are NOT punched, which breaks if a
# checkpoint sneaks in between the two VACUUMs.  max_wal_size is left at its
# 1 GiB default: this test writes only a few MB of WAL, far below the
# threshold, so no WAL-triggered checkpoint can move the redo pointer.
# (If the test's write volume ever approaches max_wal_size, pin it higher.)
$node->append_conf('postgresql.conf', "checkpoint_timeout = '1d'");
$node->start;

# Hole punching is opt-in: the GUC must default to off.
my $guc_default = $node->safe_psql('postgres', 'SHOW vacuum_punch_hole');
is($guc_default, 'off', 'vacuum_punch_hole defaults to off');

# With the GUC off, VACUUM must not deallocate anything.
$node->safe_psql('postgres',
	"CREATE TABLE punch_default_off (id serial primary key, payload char(2000))");
$node->safe_psql('postgres',
	"INSERT INTO punch_default_off (payload) SELECT 'x' FROM generate_series(1, 1200)"
);
$node->safe_psql('postgres',
	'DELETE FROM punch_default_off WHERE id BETWEEN 401 AND 800');

my $relpath_off = $node->safe_psql('postgres',
	"SELECT pg_relation_filepath('punch_default_off')");
my $heapfile_off =
  File::Spec->catfile($node->data_dir, split(/\//, $relpath_off));

$node->safe_psql('postgres', 'VACUUM punch_default_off');
$node->safe_psql('postgres', 'CHECKPOINT');
my $blocks_off_before = (stat($heapfile_off))[12];
$node->safe_psql('postgres', 'VACUUM punch_default_off');
my $blocks_off_after = (stat($heapfile_off))[12];
is($blocks_off_after, $blocks_off_before,
	'VACUUM does not punch holes when vacuum_punch_hole is off');

# B1 regression: with the GUC off, empty pages must still get the stock
# all-visible/all-frozen marking.  The assertion is exact
# (relallvisible == relpages), not merely "> 0": a mutation that skips the
# visibility-map update for a subset of pages must fail this test.
my $relallvisible_off = $node->safe_psql('postgres',
	"SELECT relallvisible FROM pg_class WHERE relname = 'punch_default_off'");
my $relpages_off = $node->safe_psql('postgres',
	"SELECT relpages FROM pg_class WHERE relname = 'punch_default_off'");
is($relallvisible_off, $relpages_off,
	'empty pages are marked all-visible when vacuum_punch_hole is off');

# Enable for the rest of the test (applies to new connections).
$node->safe_psql('postgres',
	'ALTER DATABASE postgres SET vacuum_punch_hole = on');

# Build a table whose middle third will become completely empty pages.
$node->safe_psql('postgres',
	"CREATE TABLE punch_test (id serial primary key, payload char(2000))");
$node->safe_psql('postgres',
	"INSERT INTO punch_test (payload) SELECT 'x' FROM generate_series(1, 1200)"
);
$node->safe_psql('postgres',
	'DELETE FROM punch_test WHERE id BETWEEN 401 AND 800');

my $relpath = $node->safe_psql('postgres',
	"SELECT pg_relation_filepath('punch_test')");
my $heapfile = File::Spec->catfile($node->data_dir, split(/\//, $relpath));

my $blocks_before = (stat($heapfile))[12];
my $size_before =
  $node->safe_psql('postgres', "SELECT pg_relation_size('punch_test')");
ok($blocks_before > 0, 'heap file has allocated blocks before vacuum');

# First VACUUM prunes the dead tuples; CHECKPOINT makes the empty pages'
# LSNs old enough to punch; second VACUUM punches them.
$node->safe_psql('postgres', 'VACUUM punch_test');
$node->safe_psql('postgres', 'CHECKPOINT');
$node->safe_psql('postgres', 'VACUUM punch_test');

my $blocks_after = (stat($heapfile))[12];
my $size_after =
  $node->safe_psql('postgres', "SELECT pg_relation_size('punch_test')");

cmp_ok($blocks_after, '<', $blocks_before,
	'hole punching deallocated filesystem blocks');
is($size_after, $size_before,
	'logical relation size unchanged by hole punching');

# The remaining data must be intact.
my $count = $node->safe_psql('postgres', 'SELECT count(*) FROM punch_test');
is($count, '800', 'row count correct after hole punching');
my $sum = $node->safe_psql('postgres', 'SELECT sum(id) FROM punch_test');
is($sum, '480400', 'row contents correct after hole punching');

# Punched pages must be reusable: they read back as zeroes (new pages) and
# get reallocated transparently on write.
$node->safe_psql('postgres',
	"INSERT INTO punch_test (payload) SELECT 'y' FROM generate_series(1, 100)"
);
$count = $node->safe_psql('postgres', 'SELECT count(*) FROM punch_test');
is($count, '900', 'inserts into punched space succeed');

# Indexes on the table must survive the punch: the indexed lookup must
# return the actual row, not just avoid an error (a stale-TID corruption
# would return zero rows without raising one).
my $lookup = $node->safe_psql('postgres',
	'SELECT count(*) FROM punch_test WHERE id = 42');
is($lookup, '1', 'indexed lookup returns correct row after hole punching');

my $idx_count = $node->safe_psql('postgres',
	"SELECT count(*) FROM punch_test WHERE payload LIKE 'x%'");
is($idx_count, '800', 'full scan over punched relation correct');

# The LSN crash-safety gate: the punch is not WAL-logged, so pages whose
# LSN is newer than the last checkpoint's redo pointer must NOT be punched.
$node->safe_psql('postgres',
	"CREATE TABLE punch_lsn (id serial primary key, payload char(2000))");
$node->safe_psql('postgres',
	"INSERT INTO punch_lsn (payload) SELECT 'x' FROM generate_series(1, 1200)"
);
$node->safe_psql('postgres',
	'DELETE FROM punch_lsn WHERE id BETWEEN 401 AND 800');

my $relpath_lsn = $node->safe_psql('postgres',
	"SELECT pg_relation_filepath('punch_lsn')");
my $heapfile_lsn =
  File::Spec->catfile($node->data_dir, split(/\//, $relpath_lsn));

$node->safe_psql('postgres', 'VACUUM punch_lsn');
my $blocks_lsn_before = (stat($heapfile_lsn))[12];
# No checkpoint: the pages' LSNs are newer than the redo pointer, so the
# second VACUUM must leave the blocks alone.
$node->safe_psql('postgres', 'VACUUM punch_lsn');
my $blocks_lsn_after = (stat($heapfile_lsn))[12];
is($blocks_lsn_after, $blocks_lsn_before,
	'pages with LSN newer than redo pointer are not punched');
# will_be_empty: pages that became empty are deliberately NOT marked
# all-visible (they would be punched, and a zeroed page must not carry a
# visibility-map bit).  The LSN gate blocked the punch, so they stay
# unmarked: relallvisible must be strictly less than relpages.
my $relallvisible_lsn = $node->safe_psql('postgres',
	"SELECT relallvisible FROM pg_class WHERE relname = 'punch_lsn'");
my $relpages_lsn = $node->safe_psql('postgres',
	"SELECT relpages FROM pg_class WHERE relname = 'punch_lsn'");
cmp_ok($relallvisible_lsn, '<', $relpages_lsn,
	'pages blocked from punching by the LSN gate are not marked all-visible');
# After a checkpoint the LSNs are old enough: punching must happen.
$node->safe_psql('postgres', 'CHECKPOINT');
$node->safe_psql('postgres', 'VACUUM punch_lsn');
my $blocks_lsn_punched = (stat($heapfile_lsn))[12];
cmp_ok($blocks_lsn_punched, '<', $blocks_lsn_before,
	'pages are punched once LSN is older than redo pointer');

# Batching: more than PUNCH_BATCH_MAX_BLOCKS (128) contiguous empty pages
# must exercise the mid-scan batch flush, not just the end-of-scan flush.
$node->safe_psql('postgres',
	"CREATE TABLE punch_batch (id serial primary key, payload char(2000))");
$node->safe_psql('postgres',
	"INSERT INTO punch_batch (payload) SELECT 'x' FROM generate_series(1, 2400)"
);
# ~200 contiguous empty pages in the middle third.
$node->safe_psql('postgres',
	'DELETE FROM punch_batch WHERE id BETWEEN 801 AND 1600');

my $relpath_batch = $node->safe_psql('postgres',
	"SELECT pg_relation_filepath('punch_batch')");
my $heapfile_batch =
  File::Spec->catfile($node->data_dir, split(/\//, $relpath_batch));

my $blocks_batch_before = (stat($heapfile_batch))[12];
$node->safe_psql('postgres', 'VACUUM punch_batch');
$node->safe_psql('postgres', 'CHECKPOINT');
# VERBOSE on the punching VACUUM, to capture the deallocation count.
# VACUUM VERBOSE output goes to stderr, so capture the third return value
# ($ret, $stdout, $stderr) from psql in list context.
my (undef, undef, $batch_verbose) =
  $node->psql('postgres', 'VACUUM (VERBOSE) punch_batch');
my $blocks_batch_after = (stat($heapfile_batch))[12];
cmp_ok($blocks_batch_after, '<', $blocks_batch_before,
	'large run of empty pages is punched via batched flushes');
# The mid-scan flush must have run: with ~200 contiguous empty pages, the
# end-of-scan flush alone could punch at most 127 blocks (a batch that
# never reached the 128-page threshold), so a deallocation count above 128
# proves the mid-scan flush deallocated the first batch.
like($batch_verbose, qr/hole punching: (\d+) blocks deallocated/,
	'VERBOSE reports hole-punching deallocation count');
my ($batch_dealloc) =
  $batch_verbose =~ /hole punching: (\d+) blocks deallocated/;
cmp_ok($batch_dealloc, '>', 128,
	'mid-scan batch flush deallocated more than 128 blocks');
my $count_batch =
  $node->safe_psql('postgres', 'SELECT count(*) FROM punch_batch');
is($count_batch, '1600', 'row count correct after batched punching');

# Pages whose line pointers are LP_DEAD must NOT be punched: index entries
# may still reference those TIDs until index cleanup deletes them.  Punching
# such a page would lose the LP_DEAD markers (the range reads back as
# zeroes), letting a later insert reuse the offsets while stale index TIDs
# still point at them.
$node->safe_psql('postgres',
	"CREATE TABLE punch_lpdead (id serial primary key, payload char(2000))");
$node->safe_psql('postgres',
	"INSERT INTO punch_lpdead (payload) SELECT 'x' FROM generate_series(1, 1200)"
);
$node->safe_psql('postgres',
	'DELETE FROM punch_lpdead WHERE id BETWEEN 401 AND 800');

my $relpath2 = $node->safe_psql('postgres',
	"SELECT pg_relation_filepath('punch_lpdead')");
my $heapfile2 = File::Spec->catfile($node->data_dir, split(/\//, $relpath2));

# INDEX_CLEANUP OFF leaves the dead items as LP_DEAD (no second heap pass).
$node->safe_psql('postgres', 'VACUUM (INDEX_CLEANUP OFF) punch_lpdead');
$node->safe_psql('postgres', 'CHECKPOINT');
my $blocks_lpdead_before = (stat($heapfile2))[12];
$node->safe_psql('postgres', 'VACUUM punch_lpdead');
my $blocks_lpdead_after = (stat($heapfile2))[12];
is($blocks_lpdead_after, $blocks_lpdead_before,
	'pages with LP_DEAD items are not punched');

# A further VACUUM (after index cleanup converted LP_DEAD to LP_UNUSED and a
# checkpoint aged the LSNs) must punch them.
$node->safe_psql('postgres', 'CHECKPOINT');
$node->safe_psql('postgres', 'VACUUM punch_lpdead');
my $blocks_lpdead_punched = (stat($heapfile2))[12];
cmp_ok($blocks_lpdead_punched, '<', $blocks_lpdead_before,
	'pages are punched once LP_DEAD items become LP_UNUSED');

# Boolean resolution matrix: VACUUM option > reloption > GUC.  Each case
# builds a table with empty pages, applies one combination, and checks
# punch/no-punch via st_blocks.
sub punch_matrix_case
{
	my ($name, $guc, $relopt, $vacopt) = @_;

	$node->safe_psql('postgres',
		"CREATE TABLE punch_matrix_$name (id serial primary key, payload char(2000))"
	);
	$node->safe_psql('postgres',
		"INSERT INTO punch_matrix_$name (payload) SELECT 'x' FROM generate_series(1, 1200)"
	);
	$node->safe_psql('postgres',
		"DELETE FROM punch_matrix_$name WHERE id BETWEEN 401 AND 800");
	if (defined $relopt)
	{
		$node->safe_psql('postgres',
			"ALTER TABLE punch_matrix_$name SET (vacuum_punch_hole = $relopt)");
	}
	my $relpath_m = $node->safe_psql('postgres',
		"SELECT pg_relation_filepath('punch_matrix_$name')");
	my $heapfile_m =
	  File::Spec->catfile($node->data_dir, split(/\//, $relpath_m));

	# Prune with punching enabled (so empty pages are left unmarked, not
	# all-visible), then checkpoint so the LSN gate does not interfere.
	# The $guc is only applied to the test VACUUM below.
	$node->safe_psql('postgres',
		"SET vacuum_punch_hole = on; VACUUM punch_matrix_$name");
	$node->safe_psql('postgres', 'CHECKPOINT');
	my $before = (stat($heapfile_m))[12];
	my $vacuum_cmd = defined $vacopt
		? "VACUUM ($vacopt) punch_matrix_$name"
		: "VACUUM punch_matrix_$name";
	$node->safe_psql('postgres',
		"SET vacuum_punch_hole = $guc; $vacuum_cmd");
	my $after = (stat($heapfile_m))[12];
	return $after < $before;
}

ok(!punch_matrix_case('r1', 'on', 'false', undef),
	'reloption false overrides GUC on (no punch)');
ok(punch_matrix_case('r2', 'off', 'true', undef),
	'reloption true overrides GUC off (punch)');
ok(!punch_matrix_case('r3', 'on', 'true', 'PUNCH_HOLE false'),
	'VACUUM (PUNCH_HOLE false) overrides reloption true (no punch)');
ok(punch_matrix_case('r4', 'off', undef, 'PUNCH_HOLE true'),
	'VACUUM (PUNCH_HOLE true) overrides GUC off (punch)');
ok(punch_matrix_case('r5', 'off', undef, 'PUNCH_HOLE'),
	'bare VACUUM (PUNCH_HOLE) enables punching (punch)');
ok(punch_matrix_case('r6', 'on', undef, undef),
	'GUC on with no overrides punches (punch)');

# vacuum_punch_hole_min_size is GUC-only.  A huge minimum means no range
# qualifies, so nothing is punched; 0 means automatic and punches; a
# non-multiple of BLCKSZ is rejected by the check hook.
$node->safe_psql('postgres',
	"CREATE TABLE punch_min_size (id serial primary key, payload char(2000))");
$node->safe_psql('postgres',
	"INSERT INTO punch_min_size (payload) SELECT 'x' FROM generate_series(1, 1200)"
);
$node->safe_psql('postgres',
	'DELETE FROM punch_min_size WHERE id BETWEEN 401 AND 800');
my $relpath_ms = $node->safe_psql('postgres',
	"SELECT pg_relation_filepath('punch_min_size')");
my $heapfile_ms =
  File::Spec->catfile($node->data_dir, split(/\//, $relpath_ms));
$node->safe_psql('postgres', 'VACUUM punch_min_size');
$node->safe_psql('postgres', 'CHECKPOINT');
my $blocks_ms_before = (stat($heapfile_ms))[12];
$node->safe_psql('postgres',
	"SET vacuum_punch_hole = on; SET vacuum_punch_hole_min_size = '1GB'; VACUUM punch_min_size"
);
my $blocks_ms_huge = (stat($heapfile_ms))[12];
is($blocks_ms_huge, $blocks_ms_before,
	'min_size larger than any range disables punching');
my (undef, undef, $ms_err) = $node->psql('postgres',
	'SET vacuum_punch_hole_min_size = 7');
like($ms_err, qr/must be 0 or a multiple/,
	'min_size not a multiple of BLCKSZ is rejected');
$node->safe_psql('postgres',
	"SET vacuum_punch_hole = on; SET vacuum_punch_hole_min_size = 0; VACUUM punch_min_size"
);
my $blocks_ms_auto = (stat($heapfile_ms))[12];
cmp_ok($blocks_ms_auto, '<', $blocks_ms_before,
	'min_size 0 (auto) punches normally');

$node->stop;

# Unsupported-filesystem behavior is covered by t/017's errno-classifier
# mock test (EOPNOTSUPP/ENOSYS classify as unsupported; the EINVAL split is
# verified per-platform).  An LD_PRELOAD interposer was attempted here to
# exercise the live latch, but the postmaster strips LD_PRELOAD from its
# environment (security hardening), so the interposer never loads in
# backends.  The per-VACUUM/per-segment latch itself is a simple
# early-return verified by inspection.


# Autovacuum path: an autovacuum worker (not a manual VACUUM) must punch
# holes.  The empty pages are prepared with old LSNs via manual VACUUM +
# CHECKPOINT; a small DELETE then gives autovacuum dead tuples to trigger
# on, and the worker punches the pre-aged empty pages during its scan.
my $node_av = PostgreSQL::Test::Cluster->new('punch_autovacuum');
$node_av->init;
$node_av->append_conf('postgresql.conf', "autovacuum_naptime = '1s'");
$node_av->append_conf('postgresql.conf',
	"autovacuum_vacuum_threshold = '10'");
$node_av->append_conf('postgresql.conf',
	"autovacuum_vacuum_scale_factor = '0'");
$node_av->append_conf('postgresql.conf',
	"autovacuum_vacuum_insert_threshold = '1000000'");
$node_av->append_conf('postgresql.conf', "checkpoint_timeout = '1d'");
$node_av->start;

$node_av->safe_psql('postgres',
	'ALTER DATABASE postgres SET vacuum_punch_hole = on');
# New connections pick up the database-level GUC.
$node_av->safe_psql('postgres',
	"CREATE TABLE punch_autovac (id serial primary key, payload char(2000))"
);
$node_av->safe_psql('postgres',
	"INSERT INTO punch_autovac (payload) SELECT 'x' FROM generate_series(1, 1200)"
);
$node_av->safe_psql('postgres',
	'DELETE FROM punch_autovac WHERE id BETWEEN 401 AND 800');
$node_av->safe_psql('postgres', 'VACUUM punch_autovac');
$node_av->safe_psql('postgres', 'CHECKPOINT');

my $relpath_av = $node_av->safe_psql('postgres',
	"SELECT pg_relation_filepath('punch_autovac')");
my $heapfile_av =
  File::Spec->catfile($node_av->data_dir, split(/\//, $relpath_av));
my $blocks_av_before = (stat($heapfile_av))[12];

# A few dead tuples to trigger the worker.
$node_av->safe_psql('postgres',
	'DELETE FROM punch_autovac WHERE id BETWEEN 1 AND 20');

my $tries = 0;
my $av_done = 0;
while ($tries < 90)
{
	my $last_av = $node_av->safe_psql('postgres',
		"SELECT last_autovacuum FROM pg_stat_user_tables WHERE relname = 'punch_autovac'"
	);
	if (defined $last_av && $last_av ne '')
	{
		$av_done = 1;
		last;
	}
	sleep 1;
	$tries++;
}
ok($av_done, 'autovacuum worker processed the table');

my $blocks_av_after = (stat($heapfile_av))[12];
cmp_ok($blocks_av_after, '<', $blocks_av_before,
	'autovacuum worker punched holes in empty pages');

$node_av->stop;
