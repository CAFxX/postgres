
# Copyright (c) 2026, PostgreSQL Global Development Group

# Crash/recovery test for VACUUM hole punching.
#
# Verifies the crash-safety argument: punched pages (deallocated filesystem
# blocks, not WAL-logged) recover correctly after a kill -9, both with
# full_page_writes=on and off.
#
# Scenario:
#   1. Create table, insert data, checkpoint (so page LSNs are old)
#   2. Delete to create empty pages, VACUUM with vacuum_punch_hole=on
#   3. Verify blocks were deallocated (st_blocks decreased)
#   4. Insert new data into the punched pages (exercises the zeroed-buffer
#      XLOG_HEAP_INIT_PAGE path)
#   5. kill -9 before the next checkpoint
#   6. Restart and verify all data is intact and the table is readable

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use File::Spec;

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

plan tests => 3;

sub run_crash_test
{
	my ($fpw) = @_;

	my $node = PostgreSQL::Test::Cluster->new("crash_fpw_$fpw");
	$node->init;
	$node->append_conf('postgresql.conf', 'autovacuum = off');
	$node->append_conf('postgresql.conf', "checkpoint_timeout = '1d'");
	$node->append_conf('postgresql.conf', "full_page_writes = '$fpw'");
	$node->start;

	# Create table with enough data for multiple pages, then checkpoint
	# so the page LSNs predate the punch.
	$node->safe_psql('postgres',
		"CREATE TABLE punch_crash (id serial primary key, payload char(2000))");
	$node->safe_psql('postgres',
		"INSERT INTO punch_crash (payload) SELECT 'x' FROM generate_series(1, 1200)");
	$node->safe_psql('postgres', 'CHECKPOINT');

	# Delete to create empty pages.  Prepare with punching enabled so the
	# empty pages are left unmarked (not all-visible) and eligible for
	# the punching VACUUM below.
	$node->safe_psql('postgres',
		'DELETE FROM punch_crash WHERE id BETWEEN 401 AND 800');
	$node->safe_psql('postgres',
		'SET vacuum_punch_hole = on; VACUUM punch_crash');
	$node->safe_psql('postgres', 'CHECKPOINT');

	my $relpath = $node->safe_psql('postgres',
		"SELECT pg_relation_filepath('punch_crash')");
	my $heapfile =
	  File::Spec->catfile($node->data_dir, split(/\//, $relpath));
	my $blocks_before = (stat($heapfile))[12];

	# Punch the empty pages (SET and VACUUM in the same session).
	$node->safe_psql('postgres',
		'SET vacuum_punch_hole = on; VACUUM punch_crash;');
	my $blocks_after = (stat($heapfile))[12];

	# Insert into the punched space.  This exercises the zeroed-buffer
	# path: the punched pages read as zeroes, so heap_insert takes the
	# XLOG_HEAP_INIT_PAGE path.
	$node->safe_psql('postgres',
		"INSERT INTO punch_crash (payload) SELECT 'y' FROM generate_series(1, 400)");

	my $count_before = $node->safe_psql('postgres',
		'SELECT count(*) FROM punch_crash');

	# Crash before the next checkpoint.
	$node->kill9();
	$node->start;

	# Verify data survived and the table is fully readable.
	my $count_after = $node->safe_psql('postgres',
		'SELECT count(*) FROM punch_crash');
	my $payload_check = $node->safe_psql('postgres',
		"SELECT count(*) FROM punch_crash WHERE payload NOT IN ('x', 'y')");

	# Check the log for PANIC/FATAL during recovery BEFORE the fast
	# shutdown below: stop('fast') terminates backends with SIGTERM,
	# which appends benign FATAL lines that would false-positive the
	# regex if we read the log afterwards.
	my $logfile = $node->logfile();
	open my $lfh, '<', $logfile or die "cannot read $logfile: $!";
	my $log = do { local $/; <$lfh> };
	close $lfh;
	my $bad = ($log =~ /PANIC|FATAL/i) ? 1 : 0;

	$node->stop('fast');

	diag("fpw=$fpw count_before=$count_before count_after=$count_after " .
		 "payload_bad=$payload_check blocks_before=$blocks_before " .
		 "blocks_after=$blocks_after log_bad=$bad");

	return ($count_before eq $count_after && $payload_check == 0 &&
			$blocks_after < $blocks_before && !$bad);
}

my $ok_on = run_crash_test('on');
ok($ok_on, 'crash recovery with full_page_writes=on preserves punched table');

my $ok_off = run_crash_test('off');
ok($ok_off, 'crash recovery with full_page_writes=off preserves punched table');

# LSN-gate crash test: pages whose LSN is newer than the last redo pointer
# must NOT be punched (the punch is not WAL-logged), and crashing before
# the next checkpoint must still recover cleanly with the blocks intact.
my $node_lsn = PostgreSQL::Test::Cluster->new('crash_lsn_gate');
$node_lsn->init;
$node_lsn->append_conf('postgresql.conf', 'autovacuum = off');
$node_lsn->append_conf('postgresql.conf', "checkpoint_timeout = '1d'");
$node_lsn->start;

$node_lsn->safe_psql('postgres',
	"CREATE TABLE punch_lsn_crash (id serial primary key, payload char(2000))"
);
$node_lsn->safe_psql('postgres',
	"INSERT INTO punch_lsn_crash (payload) SELECT 'x' FROM generate_series(1, 1200)"
);
$node_lsn->safe_psql('postgres', 'CHECKPOINT');
$node_lsn->safe_psql('postgres',
	'DELETE FROM punch_lsn_crash WHERE id BETWEEN 401 AND 800');

my $relpath_lsn = $node_lsn->safe_psql('postgres',
	"SELECT pg_relation_filepath('punch_lsn_crash')");
my $heapfile_lsn =
  File::Spec->catfile($node_lsn->data_dir, split(/\//, $relpath_lsn));

# Prune with punching enabled (so empty pages are left unmarked, not
# all-visible), then VACUUM with punching on but no checkpoint since the
# DELETE: the emptied pages' LSNs are newer than redo, so nothing may be
# punched (LSN gate, not the all-visible check, must be what blocks it).
$node_lsn->safe_psql('postgres',
	'SET vacuum_punch_hole = on; VACUUM punch_lsn_crash');
my $blocks_lsn_before = (stat($heapfile_lsn))[12];
$node_lsn->safe_psql('postgres',
	'SET vacuum_punch_hole = on; VACUUM punch_lsn_crash;');
my $blocks_lsn_after = (stat($heapfile_lsn))[12];
my $lsn_gate_ok = ($blocks_lsn_after == $blocks_lsn_before);

my $count_lsn_before = $node_lsn->safe_psql('postgres',
	'SELECT count(*) FROM punch_lsn_crash');

# Crash before the next checkpoint; recovery must be clean.
$node_lsn->kill9();
$node_lsn->start;

my $count_lsn_after = $node_lsn->safe_psql('postgres',
	'SELECT count(*) FROM punch_lsn_crash');
my $blocks_lsn_crash = (stat($heapfile_lsn))[12];

# Read the log before the fast shutdown appends benign FATALs.
my $logfile_lsn = $node_lsn->logfile();
open my $lfh_lsn, '<', $logfile_lsn or die "cannot read $logfile_lsn: $!";
my $log_lsn = do { local $/; <$lfh_lsn> };
close $lfh_lsn;
my $bad_lsn = ($log_lsn =~ /PANIC|FATAL/i) ? 1 : 0;

$node_lsn->stop('fast');

diag("lsn_gate_ok=$lsn_gate_ok count_before=$count_lsn_before " .
	 "count_after=$count_lsn_after blocks_before=$blocks_lsn_before " .
	 "blocks_after=$blocks_lsn_after blocks_crash=$blocks_lsn_crash " .
	 "log_bad=$bad_lsn");

ok($lsn_gate_ok && $count_lsn_before eq $count_lsn_after &&
	$count_lsn_after eq '800' && $blocks_lsn_crash == $blocks_lsn_before &&
	!$bad_lsn,
	'too-new-LSN pages are not punched and survive kill -9 cleanly');
