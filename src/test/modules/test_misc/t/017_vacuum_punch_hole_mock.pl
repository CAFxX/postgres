
# Copyright (c) 2026, PostgreSQL Global Development Group

# Unit test for md_punchhole_range() (src/backend/storage/smgr/md.c), the
# platform-specific syscall layer behind mdpunchhole().
#
# The test extracts the real function text from md.c (via brace matching,
# so it always tests the current code), compiles it with mocked
# fallocate() / fcntl() / fspacectl(), and verifies that each platform
# branch (Linux, macOS, FreeBSD, Solaris) marshals its syscall arguments
# correctly, retries EINTR, and propagates errors.  A separate no-op
# variant exercises the #else stub compiled when no platform API exists.
#
# The errno classifier (md_punchhole_errno_unsupported) is extracted and
# tested too, including the EINVAL platform split: EINVAL counts as
# "unsupported" only on macOS/Solaris (compiled with -D__APPLE__ /
# -D__sun), while on Linux/FreeBSD it is an unexpected failure.
#
# This does NOT test mdpunchhole()'s segment-splitting; that logic is
# exercised by t/019_vacuum_punch_hole_segment.pl instead.  Per-segment
# unsupported-filesystem suppression requires the smgr infrastructure and
# is covered by t/016_vacuum_punch_hole.pl (including the LD_PRELOAD
# EOPNOTSUPP interposer test).

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Utils;
use Test::More;
use File::Spec;
use File::Basename qw(dirname);

# The mock test compiles C code; skip everything if no C compiler exists.
my $cc_probe = $ENV{CC} || 'cc';
if (system("$cc_probe --version >/dev/null 2>&1") != 0)
{
	plan skip_all => 'no C compiler available';
}

plan tests => 11;

my $test_dir = dirname(__FILE__);
my $md_c = File::Spec->rel2abs(
	File::Spec->catfile($test_dir, '..', '..', '..', '..',
		'backend', 'storage', 'smgr', 'md.c'));
my $tmpdir = $PostgreSQL::Test::Utils::tmp_check;

# Extract md_punchhole_range() from md.c by brace matching.  Always extracts
# from the current source, so the test can never go stale.
sub extract_function
{
	my ($path) = @_;
	open my $fh, '<', $path or die "cannot open $path: $!";
	my $src = do { local $/; <$fh> };
	close $fh;

	my $sig = "static int\nmd_punchhole_range(int rawfd, off_t offset, off_t length)\n{";
	my $pos = index($src, $sig);
	die "md_punchhole_range not found in $path" if $pos < 0;

	# Brace-match from the opening brace of the function body.
	my $i = $pos + length($sig) - 1;    # at the '{'
	my $depth = 0;
	my $start = $i;
	while ($i < length($src))
	{
		my $ch = substr($src, $i, 1);
		$depth++ if $ch eq '{';
		$depth-- if $ch eq '}';
		if ($depth == 0)
		{
			return substr($src, $pos, $i - $pos + 1) . "\n";
		}
		$i++;
	}
	die "unbalanced braces extracting md_punchhole_range from $path";
}

my $func_text = extract_function($md_c);
ok(length($func_text) > 100, 'extracted md_punchhole_range from md.c');

# C template with mocked syscalls.  The real function text is appended.
my $c_template = <<'EOF';
/* Mock-platform test of md_punchhole_range(). */
#include <sys/types.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>

#if !defined(TEST_LINUX) && !defined(TEST_MACOS) && !defined(TEST_FREEBSD) && !defined(TEST_SOLARIS) && !defined(TEST_WINDOWS)
#error "Define TEST_LINUX, TEST_MACOS, TEST_FREEBSD, TEST_SOLARIS or TEST_WINDOWS to select the branch under test"
#endif

/* Hide the Linux/macOS macros so the #elif chain reaches the branch under test. */
#undef FALLOC_FL_PUNCH_HOLE
#undef F_PUNCHHOLE
#undef HAVE_SYS_FSPACECTL_H
#undef SPACECTL_DEALLOC
#undef F_FREESP
#undef WIN32

#define MemSet(start, c, m) memset((start), (c), (m))

#ifdef TEST_LINUX
#define FALLOC_FL_KEEP_SIZE 1
#define FALLOC_FL_PUNCH_HOLE 2

static int fallocate_calls;
static int fallocate_errno_seq[4];
static int fallocate_seq_len;
static int last_mode;
static off_t last_offset;
static off_t last_len;

#define fallocate mock_fallocate
int
mock_fallocate(int fd, int mode, off_t offset, off_t len)
{
	int		e;

	assert(fallocate_calls < fallocate_seq_len);
	e = fallocate_errno_seq[fallocate_calls];
	fallocate_calls++;
	last_mode = mode;
	last_offset = offset;
	last_len = len;
	assert(fd == 42);
	if (e != 0)
	{
		errno = e;
		return -1;
	}
	return 0;
}
#endif

#ifdef TEST_MACOS
#define F_PUNCHHOLE 99
typedef struct fpunchhole
{
	unsigned int	fp_flags;
	unsigned int	reserved;
	off_t			fp_offset;
	off_t			fp_length;
} fpunchhole_t;

static int fcntl_calls;
static int fcntl_errno_seq[4];
static int fcntl_seq_len;
static int last_cmd;
static fpunchhole_t last_fp;

#define fcntl mock_fcntl_macos
int
mock_fcntl_macos(int fd, int cmd, fpunchhole_t *fp)
{
	int		e;

	assert(fcntl_calls < fcntl_seq_len);
	e = fcntl_errno_seq[fcntl_calls];
	fcntl_calls++;
	last_cmd = cmd;
	last_fp = *fp;
	assert(fd == 42);
	if (e != 0)
	{
		errno = e;
		return -1;
	}
	return 0;
}
#endif

#ifdef TEST_FREEBSD
#define HAVE_SYS_FSPACECTL_H 1
#define SPACECTL_DEALLOC 1
struct spacectl_range
{
	off_t		r_offset;
	off_t		r_len;
};

static int fspacectl_calls;
static int fspacectl_errno_seq[4];
static int fspacectl_seq_len;
static struct spacectl_range last_range;
static int last_flags;
static void *last_rmsr;

#define fspacectl mock_fspacectl
int
mock_fspacectl(int fd, int cmd, struct spacectl_range *rqsr, int flags,
			   void *rmsr)
{
	int			e;

	assert(fspacectl_calls < fspacectl_seq_len);
	e = fspacectl_errno_seq[fspacectl_calls];
	fspacectl_calls++;
	assert(cmd == SPACECTL_DEALLOC);
	last_range = *rqsr;
	last_flags = flags;
	last_rmsr = rmsr;
	assert(fd == 42);
	if (e != 0)
	{
		errno = e;
		return -1;
	}
	return 0;
}
#endif

#ifdef TEST_SOLARIS
#define __sun 1
#define F_FREESP 11

static int fcntl_calls;
static int fcntl_errno_seq[4];
static int fcntl_seq_len;
static struct flock last_fl;
static int last_cmd;

#define fcntl mock_fcntl
int
mock_fcntl(int fd, int cmd, struct flock *fl)
{
	int			e;

	assert(fcntl_calls < fcntl_seq_len);
	e = fcntl_errno_seq[fcntl_calls];
	fcntl_calls++;
	last_cmd = cmd;
	last_fl = *fl;
	assert(fd == 42);
	if (e != 0)
	{
		errno = e;
		return -1;
	}
	return 0;
}
#endif

#ifdef TEST_WINDOWS
#define WIN32 1

/* Minimal Win32 API surface needed by md_punchhole_range()'s Windows branch. */
typedef void *HANDLE;
typedef unsigned long DWORD;
typedef int BOOL;
typedef long long LONGLONG;
typedef union
{
	LONGLONG	QuadPart;
} LARGE_INTEGER;
typedef struct
{
	LARGE_INTEGER FileOffset;
	LARGE_INTEGER BeyondFinalZero;
} FILE_ZERO_DATA_INFORMATION;

#define INVALID_HANDLE_VALUE ((HANDLE) -1)
#define FSCTL_SET_SPARSE 0x900c4
#define FSCTL_SET_ZERO_DATA 0x980c8
#define ERROR_INVALID_FUNCTION 1
#define ERROR_NOT_SUPPORTED 50
#define ERROR_ACCESS_DENIED 5
#define TRUE 1
#define FALSE 0

static long mock_osfhandle = 0x1234;
static int get_osfhandle_calls;
static int last_osfhandle_fd;

long
_get_osfhandle(int fd)
{
	get_osfhandle_calls++;
	last_osfhandle_fd = fd;
	return mock_osfhandle;
}

static DWORD mock_last_error;
static int dio_calls;
static int dio_len;
static DWORD dio_err_seq[4];	/* 0 = success, else the GetLastError code */
static DWORD dio_fsctl_record[4];
static HANDLE dio_handle_record[4];
static LONGLONG last_file_offset;
static LONGLONG last_beyond_final_zero;

BOOL
DeviceIoControl(HANDLE h, DWORD code, void *in, DWORD inlen,
				void *out, DWORD outlen, DWORD *retlen, void *ovl)
{
	DWORD		e;

	assert(dio_calls < dio_len);
	dio_fsctl_record[dio_calls] = code;
	dio_handle_record[dio_calls] = h;
	if (code == FSCTL_SET_ZERO_DATA)
	{
		FILE_ZERO_DATA_INFORMATION *zdi = (FILE_ZERO_DATA_INFORMATION *) in;

		assert(inlen == sizeof(FILE_ZERO_DATA_INFORMATION));
		last_file_offset = zdi->FileOffset.QuadPart;
		last_beyond_final_zero = zdi->BeyondFinalZero.QuadPart;
	}
	else
	{
		assert(code == FSCTL_SET_SPARSE);
		assert(in == NULL && inlen == 0);
	}
	assert(h == (HANDLE) 0x1234);
	e = dio_err_seq[dio_calls];
	dio_calls++;
	if (e != 0)
	{
		mock_last_error = e;
		return FALSE;
	}
	return TRUE;
}

DWORD
GetLastError(void)
{
	return mock_last_error;
}

void
_dosmaperr(DWORD e)
{
	(void) e;
	errno = EIO;				/* recognizable stand-in for the mock */
}
#endif

/* ---- real md_punchhole_range() text follows ---- */
EOF

my $c_main = <<'EOF';

int
main(void)
{
	int			rc;

#ifdef TEST_LINUX
	/* success path: verify FALLOC_FL_KEEP_SIZE | FALLOC_FL_PUNCH_HOLE */
	fallocate_seq_len = 1;
	fallocate_errno_seq[0] = 0;
	fallocate_calls = 0;
	rc = md_punchhole_range(42, (off_t) 8192 * 5, (off_t) 8192 * 64);
	assert(rc == 0);
	assert(fallocate_calls == 1);
	assert(last_mode == (FALLOC_FL_KEEP_SIZE | FALLOC_FL_PUNCH_HOLE));
	assert(last_offset == (off_t) 8192 * 5);
	assert(last_len == (off_t) 8192 * 64);
	printf("linux: success path OK\\n");

	/* EINTR retry then success */
	fallocate_seq_len = 2;
	fallocate_errno_seq[0] = EINTR;
	fallocate_errno_seq[1] = 0;
	fallocate_calls = 0;
	rc = md_punchhole_range(42, 0, 8192);
	assert(rc == 0);
	assert(fallocate_calls == 2);
	printf("linux: EINTR retry OK\\n");

	/* hard failure propagates errno */
	fallocate_seq_len = 1;
	fallocate_errno_seq[0] = EIO;
	fallocate_calls = 0;
	rc = md_punchhole_range(42, 0, 8192);
	assert(rc == -1);
	assert(errno == EIO);
	assert(fallocate_calls == 1);
	printf("linux: error propagation OK\\n");
#endif

#ifdef TEST_MACOS
	/* success path: verify fpunchhole_t marshalling */
	fcntl_seq_len = 1;
	fcntl_errno_seq[0] = 0;
	fcntl_calls = 0;
	rc = md_punchhole_range(42, (off_t) 8192 * 2, (off_t) 8192 * 32);
	assert(rc == 0);
	assert(fcntl_calls == 1);
	assert(last_cmd == F_PUNCHHOLE);
	assert(last_fp.fp_flags == 0);
	assert(last_fp.fp_offset == (off_t) 8192 * 2);
	assert(last_fp.fp_length == (off_t) 8192 * 32);
	printf("macos: success path OK\\n");

	/* EINTR retry then success */
	fcntl_seq_len = 2;
	fcntl_errno_seq[0] = EINTR;
	fcntl_errno_seq[1] = 0;
	fcntl_calls = 0;
	rc = md_punchhole_range(42, 0, 8192);
	assert(rc == 0);
	assert(fcntl_calls == 2);
	printf("macos: EINTR retry OK\\n");

	/* hard failure propagates errno */
	fcntl_seq_len = 1;
	fcntl_errno_seq[0] = EIO;
	fcntl_calls = 0;
	rc = md_punchhole_range(42, 0, 8192);
	assert(rc == -1);
	assert(errno == EIO);
	assert(fcntl_calls == 1);
	printf("macos: error propagation OK\\n");
#endif

#ifdef TEST_FREEBSD
	/* success path */
	fspacectl_seq_len = 1;
	fspacectl_errno_seq[0] = 0;
	fspacectl_calls = 0;
	rc = md_punchhole_range(42, (off_t) 8192 * 7, (off_t) 8192 * 128);
	assert(rc == 0);
	assert(fspacectl_calls == 1);
	assert(last_range.r_offset == (off_t) 8192 * 7);
	assert(last_range.r_len == (off_t) 8192 * 128);
	assert(last_flags == 0);
	assert(last_rmsr == NULL);
	printf("freebsd: success path OK\n");

	/* EINTR retry then success */
	fspacectl_seq_len = 2;
	fspacectl_errno_seq[0] = EINTR;
	fspacectl_errno_seq[1] = 0;
	fspacectl_calls = 0;
	rc = md_punchhole_range(42, 0, 8192);
	assert(rc == 0);
	assert(fspacectl_calls == 2);
	printf("freebsd: EINTR retry OK\n");

	/* hard failure propagates errno */
	fspacectl_seq_len = 1;
	fspacectl_errno_seq[0] = EIO;
	fspacectl_calls = 0;
	rc = md_punchhole_range(42, 0, 8192);
	assert(rc == -1);
	assert(errno == EIO);
	assert(fspacectl_calls == 1);
	printf("freebsd: error propagation OK\n");
#endif

#ifdef TEST_SOLARIS
	/* success path */
	fcntl_seq_len = 1;
	fcntl_errno_seq[0] = 0;
	fcntl_calls = 0;
	rc = md_punchhole_range(42, (off_t) 8192 * 3, (off_t) 8192 * 10);
	assert(rc == 0);
	assert(fcntl_calls == 1);
	assert(last_cmd == F_FREESP);
	assert(last_fl.l_whence == SEEK_SET);
	assert(last_fl.l_start == (off_t) 8192 * 3);
	assert(last_fl.l_len == (off_t) 8192 * 10);
	assert(last_fl.l_type == 0);	/* l_type is ignored by F_FREESP */
	printf("solaris: success path OK\n");

	/* EINTR retry then success */
	fcntl_seq_len = 2;
	fcntl_errno_seq[0] = EINTR;
	fcntl_errno_seq[1] = 0;
	fcntl_calls = 0;
	rc = md_punchhole_range(42, 0, 8192);
	assert(rc == 0);
	assert(fcntl_calls == 2);
	printf("solaris: EINTR retry OK\n");

	/* hard failure propagates errno */
	fcntl_seq_len = 1;
	fcntl_errno_seq[0] = EINVAL;
	fcntl_calls = 0;
	rc = md_punchhole_range(42, 0, 8192);
	assert(rc == -1);
	assert(errno == EINVAL);
	assert(fcntl_calls == 1);
	printf("solaris: error propagation OK\n");
#endif

#ifdef TEST_WINDOWS
	/* success: sparse mark then zero-data with correct byte range */
	dio_len = 2;
	dio_err_seq[0] = 0;
	dio_err_seq[1] = 0;
	dio_calls = 0;
	get_osfhandle_calls = 0;
	mock_osfhandle = 0x1234;
	rc = md_punchhole_range(42, (off_t) 8192 * 3, (off_t) 8192 * 16);
	assert(rc == 0);
	assert(get_osfhandle_calls == 1);
	assert(last_osfhandle_fd == 42);
	assert(dio_calls == 2);
	assert(dio_fsctl_record[0] == FSCTL_SET_SPARSE);
	assert(dio_fsctl_record[1] == FSCTL_SET_ZERO_DATA);
	assert(dio_handle_record[0] == (HANDLE) 0x1234);
	assert(dio_handle_record[1] == (HANDLE) 0x1234);
	assert(last_file_offset == (LONGLONG) 8192 * 3);
	assert(last_beyond_final_zero == (LONGLONG) 8192 * 19);
	printf("windows: success path OK\n");

	/* sparse unsupported -> EOPNOTSUPP so the caller latches off */
	dio_len = 1;
	dio_err_seq[0] = ERROR_INVALID_FUNCTION;
	dio_calls = 0;
	rc = md_punchhole_range(42, 0, 8192);
	assert(rc == -1);
	assert(errno == EOPNOTSUPP);
	assert(dio_calls == 1);
	assert(dio_fsctl_record[0] == FSCTL_SET_SPARSE);
	printf("windows: sparse-unsupported OK\n");

	/* zero-data failure -> mapped errno, no latch */
	dio_len = 2;
	dio_err_seq[0] = 0;
	dio_err_seq[1] = ERROR_ACCESS_DENIED;
	dio_calls = 0;
	rc = md_punchhole_range(42, 0, 8192);
	assert(rc == -1);
	assert(errno == EIO);
	assert(dio_calls == 2);
	printf("windows: error propagation OK\n");

	/* bad handle -> EBADF before any ioctl */
	mock_osfhandle = -1;		/* INVALID_HANDLE_VALUE */
	dio_calls = 0;
	get_osfhandle_calls = 0;
	rc = md_punchhole_range(42, 0, 8192);
	assert(rc == -1);
	assert(errno == EBADF);
	assert(dio_calls == 0);
	mock_osfhandle = 0x1234;
	printf("windows: bad handle OK\n");
#endif

	printf("ALL MOCK TESTS PASSED\n");
	return 0;
}
EOF

sub run_mock_variant
{
	my ($define) = @_;
	my $c_file = File::Spec->catfile($tmpdir, "punch_mock_$define.c");
	my $bin = File::Spec->catfile($tmpdir, "punch_mock_$define");
	# $ENV{CC} may contain flags; split into words.
	my @cc = split(' ', $ENV{CC} || 'cc');

	open my $fh, '>', $c_file or die "cannot write $c_file: $!";
	print $fh $c_template;
	print $fh $func_text;
	print $fh $c_main;
	close $fh or die "cannot close $c_file: $!";

	my $rc = system(@cc, '-Wall', '-Wextra', "-D$define", '-o', $bin, $c_file);
	unlink $c_file;
	if ($rc != 0)
	{
		unlink $bin;
		return (0, "compile failed for $define");
	}

	my $output = qx{$bin 2>&1};
	$rc = $?;
	unlink $bin;
	if ($rc != 0 || $output !~ /ALL MOCK TESTS PASSED/)
	{
		return (0, "$define failed:\n$output");
	}
	return (1, $output);
}

my ($ok_linux, $out_linux) = run_mock_variant('TEST_LINUX');
ok($ok_linux, 'Linux fallocate branch mock test') or diag($out_linux);

my ($ok_macos, $out_macos) = run_mock_variant('TEST_MACOS');
ok($ok_macos, 'macOS F_PUNCHHOLE branch mock test') or diag($out_macos);

my ($ok_fbsd, $out_fbsd) = run_mock_variant('TEST_FREEBSD');
ok($ok_fbsd, 'FreeBSD fspacectl branch mock test') or diag($out_fbsd);

my ($ok_sol, $out_sol) = run_mock_variant('TEST_SOLARIS');
ok($ok_sol, 'Solaris F_FREESP branch mock test') or diag($out_sol);

my ($ok_win, $out_win) = run_mock_variant('TEST_WINDOWS');
ok($ok_win, 'Windows FSCTL_SET_ZERO_DATA branch mock test') or diag($out_win);

# Tests 6-8: errno classifier - extract md_punchhole_errno_unsupported() and
# verify the EINVAL platform split.  EOPNOTSUPP/ENOSYS are always
# "unsupported"; EINVAL is "unsupported" only on macOS/Solaris (where the
# OS documents it as a rejection), while on Linux/FreeBSD it signals a
# programming bug and must be treated as unexpected.  ENODEV is
# deliberately NOT classified (unreachable for relation files).  EIO,
# EPERM, EINTR and 0 must never classify as unsupported.
{
	open my $fh2, '<', $md_c or die "cannot open $md_c: $!";
	my $src2 = do { local $/; <$fh2> };
	close $fh2;
	my $sig = "static bool\nmd_punchhole_errno_unsupported(int errnum)\n{";
	my $pos = index($src2, $sig);
	if ($pos < 0) {
		ok(0, 'errno classifier extraction') or diag("md_punchhole_errno_unsupported not found");
		ok(0, 'errno classifier (macOS branch)');
		ok(0, 'errno classifier (Solaris branch)');
	} else {
		# Brace matching extraction (same as extract_function)
		my $depth = 0;
		my $i = $pos;
		my $start = index($src2, "{", $pos);
		$i = $start;
		while ($i < length($src2)) {
			my $ch = substr($src2, $i, 1);
			$depth++ if $ch eq '{';
			$depth-- if $ch eq '}';
			if ($depth == 0) { last; }
			$i++;
		}
		my $classifier_text = substr($src2, $pos, $i - $pos + 1);

		# $ENV{CC} may contain flags; split into words.
		my @cc = split(' ', $ENV{CC} || 'cc');

		my $run_errno_variant = sub {
			my ($name, $einval_unsupported, @extra_defines) = @_;
			my $c_file = File::Spec->catfile($tmpdir, "errno_test_$name.c");
			my $bin = File::Spec->catfile($tmpdir, "errno_test_$name");
			open my $fh, '>', $c_file or die "cannot write $c_file: $!";
			print $fh "#include <stdbool.h>\n";
			print $fh "#include <errno.h>\n";
			print $fh "#include <stdio.h>\n";
			print $fh $classifier_text;
			print $fh "\n";
			# EXPECT_EINVAL is baked in so the same C source covers
			# both sides of the platform split.
			print $fh "#define EXPECT_EINVAL_UNSUPPORTED $einval_unsupported\n";
			print $fh <<'EOF';
int main(void) {
	int fails = 0;
	/* Always unsupported */
	if (!md_punchhole_errno_unsupported(EOPNOTSUPP)) { printf("FAIL EOPNOTSUPP\n"); fails++; }
	if (!md_punchhole_errno_unsupported(ENOSYS)) { printf("FAIL ENOSYS\n"); fails++; }
	/* EINVAL follows the platform split */
	if (md_punchhole_errno_unsupported(EINVAL) != EXPECT_EINVAL_UNSUPPORTED) { printf("FAIL EINVAL\n"); fails++; }
	/* Deliberately not classified: ENODEV is unreachable for relation files */
	if (md_punchhole_errno_unsupported(ENODEV)) { printf("FAIL ENODEV\n"); fails++; }
	/* Never unsupported */
	if (md_punchhole_errno_unsupported(EIO)) { printf("FAIL EIO\n"); fails++; }
	if (md_punchhole_errno_unsupported(EPERM)) { printf("FAIL EPERM\n"); fails++; }
	if (md_punchhole_errno_unsupported(EINTR)) { printf("FAIL EINTR\n"); fails++; }
	if (md_punchhole_errno_unsupported(0)) { printf("FAIL 0\n"); fails++; }
	if (fails == 0) printf("ALL ERRNO TESTS PASSED\n");
	return fails;
}
EOF
			close $fh;
			my $rc = system(@cc, '-Wall', '-o', $bin, @extra_defines, $c_file);
			unlink $c_file;
			my $ok = 0;
			my $out = '';
			if ($rc == 0) {
				$out = qx{$bin 2>&1};
				$ok = ($? == 0 && $out =~ /ALL ERRNO TESTS PASSED/);
				unlink $bin;
			} else {
				$out = "compile failed for $name";
			}
			return ($ok, $out);
		};

		# Native platform (Linux here): EINVAL must NOT be "unsupported".
		my ($ok_nat, $out_nat) = $run_errno_variant->('native', 0);
		ok($ok_nat, 'errno classifier: EINVAL is unexpected on Linux/FreeBSD')
			or diag($out_nat);

		# macOS branch: EINVAL IS "unsupported".
		my ($ok_mac, $out_mac) = $run_errno_variant->('macos', 1, '-D__APPLE__');
		ok($ok_mac, 'errno classifier: EINVAL is unsupported on macOS')
			or diag($out_mac);

		# Solaris branch: EINVAL IS "unsupported".
		my ($ok_sol2, $out_sol2) = $run_errno_variant->('solaris', 1, '-D__sun');
		ok($ok_sol2, 'errno classifier: EINVAL is unsupported on Solaris')
			or diag($out_sol2);
	}
}

# Test 9: no-op stub - compile md_punchhole_range() with no platform API
# macros defined and verify it reports EOPNOTSUPP (so the caller latches
# the segment as unsupported instead of miscounting blocks as punched).
{
	my $noop_text = extract_function($md_c);
	my $c_file = File::Spec->catfile($tmpdir, 'noop_test.c');
	my $bin = File::Spec->catfile($tmpdir, 'noop_test');
	open my $fh, '>', $c_file or die "cannot write $c_file: $!";
	print $fh "#include <sys/types.h>\n";
	print $fh "#include <errno.h>\n";
	print $fh "#include <stdio.h>\n";
	# Hide every platform API macro so the #else no-op stub is compiled.
	print $fh "#undef FALLOC_FL_PUNCH_HOLE\n";
	print $fh "#undef F_PUNCHHOLE\n";
	print $fh "#undef SPACECTL_DEALLOC\n";
	print $fh "#undef F_FREESP\n";
	print $fh $noop_text;
	print $fh <<'EOF';
int main(void) {
	int rc = md_punchhole_range(42, 0, 8192);
	if (rc != -1) { printf("FAIL: expected -1, got %d\n", rc); return 1; }
	if (errno != EOPNOTSUPP) { printf("FAIL: expected EOPNOTSUPP, got %d\n", errno); return 1; }
	printf("NOOP STUB TEST PASSED\n");
	return 0;
}
EOF
	close $fh;
	my @cc = split(' ', $ENV{CC} || 'cc');
	my $rc = system(@cc, '-Wall', '-Wextra', '-o', $bin, $c_file);
	unlink $c_file;
	my $ok = 0;
	my $out = '';
	if ($rc == 0) {
		$out = qx{$bin 2>&1};
		$ok = ($? == 0 && $out =~ /NOOP STUB TEST PASSED/);
		unlink $bin;
	} else {
		$out = 'compile failed for no-op stub';
	}
	ok($ok, 'no-op stub reports EOPNOTSUPP when no platform API exists')
		or diag($out);
}

# Test 10: md_punch_one_segment() failure branches - extract the real
# function, mock the smgr layer, and verify: (a) errno (not rc) is passed
# to the classifier, (b) EOPNOTSUPP sets the per-segment latch and marks
# unsupported, (c) unexpected errnos increment failed_blocks and log,
# (d) a latched segment skips the syscall entirely, (e) NULL segment
# counts failed_blocks.
{
	open my $fh3, '<', $md_c or die "cannot open $md_c: $!";
	my $src_all = do { local $/; <$fh3> };
	close $fh3;
	my $sig = "static void\nmd_punch_one_segment(BlockNumber firstblock, int segno,\n\t\t\t\t\t off_t seg_off, off_t seg_len, void *arg)\n{";
	my $pos = index($src_all, $sig);
	if ($pos < 0) {
		ok(0, 'md_punch_one_segment failure branches') or diag("md_punch_one_segment not found");
	} else {
		my $depth = 0;
		my $i = $pos;
		my $start = index($src_all, "{", $pos);
		$i = $start;
		while ($i < length($src_all)) {
			my $ch = substr($src_all, $i, 1);
			$depth++ if $ch eq '{';
			$depth-- if $ch eq '}';
			if ($depth == 0) { last; }
			$i++;
		}
		my $seg_text = substr($src_all, $pos, $i - $pos + 1);

		# Also extract the real errno classifier to verify errno-vs-rc use.
		my $csig = "static bool\nmd_punchhole_errno_unsupported(int errnum)\n{";
		my $cpos = index($src_all, $csig);
		my $classifier_text = '';
		if ($cpos >= 0) {
			my $cdepth = 0;
			my $ci = index($src_all, "{", $cpos);
			my $cj = $ci;
			while ($cj < length($src_all)) {
				my $ch = substr($src_all, $cj, 1);
				$cdepth++ if $ch eq '{';
				$cdepth-- if $ch eq '}';
				if ($cdepth == 0) { last; }
				$cj++;
			}
			$classifier_text = substr($src_all, $cpos, $cj - $cpos + 1);
		}

		my $c_file = File::Spec->catfile($tmpdir, 'one_segment_test.c');
		my $bin = File::Spec->catfile($tmpdir, 'one_segment_test');
		open my $fh, '>', $c_file or die "cannot write $c_file: $!";
		print $fh <<'EOF';
/* Mock test for md_punch_one_segment() failure branches. */
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef uint32_t BlockNumber;
typedef int ForkNumber;
typedef int64_t int64;
#define BLCKSZ 8192
#define EXTENSION_RETURN_NULL 0

typedef struct MDPunchResult
{
	BlockNumber punched_blocks;
	BlockNumber failed_blocks;
	bool		unsupported;
} MDPunchResult;

typedef struct md_punch_cb_arg
{
	void	   *reln;
	ForkNumber	forknum;
	MDPunchResult *result;
	int64_t		min_hole_bytes;
} md_punch_cb_arg;

typedef struct MdfdVec
{
	bool		mdfd_punchhole_unsupported;
	int			mdfd_vfd;
} MdfdVec;

/* ---- mocks ---- */
static MdfdVec *mock_mdfd_vec = NULL;
static int mock_rawfd = -1;
static int mock_punch_rc = 0;
static int mock_punch_errno = 0;
static int mock_punch_calls = 0;
static int mock_ereport_count = 0;

MdfdVec *
_mdfd_getseg(void *reln, ForkNumber forknum, BlockNumber blkno,
			 bool skipFsync, int behavior)
{
	(void) reln; (void) forknum; (void) blkno;
	(void) skipFsync; (void) behavior;
	return mock_mdfd_vec;
}

int
FileGetRawDesc(int vfd)
{
	(void) vfd;
	return mock_rawfd;
}

const char *
FilePathName(int vfd)
{
	(void) vfd;
	return "mockfile";
}

#define ereport(elevel, args) do { mock_ereport_count++; } while (0)
#define errcode_for_file_access() 0
#define errmsg(fmt, ...) 0
#define LOG 15

/* Mock md_punchhole_range: controlled rc/errno, counts calls. */
static int
md_punchhole_range(int rawfd, off_t offset, off_t length)
{
	(void) rawfd; (void) offset; (void) length;
	mock_punch_calls++;
	if (mock_punch_rc < 0)
	{
		errno = mock_punch_errno;
		return -1;
	}
	return 0;
}

/* ---- real md_punchhole_errno_unsupported() text follows ---- */
EOF
		print $fh $classifier_text;
		print $fh "\n/* ---- real md_punch_one_segment() text follows ---- */\n";
		print $fh $seg_text;
		print $fh <<'EOF';

int
main(void)
{
	MdfdVec		vec;
	MDPunchResult result;
	md_punch_cb_arg arg;
	int			fd;
	int			fails = 0;

	/* Need a real fd for fstatvfs(). */
	fd = open("/tmp", O_RDONLY);
	if (fd < 0)
	{
		printf("FAIL: cannot open /tmp\n");
		return 1;
	}

	memset(&vec, 0, sizeof(vec));
	vec.mdfd_vfd = 999;
	mock_mdfd_vec = &vec;
	mock_rawfd = fd;

	arg.reln = NULL;
	arg.forknum = 0;
	arg.result = &result;
	arg.min_hole_bytes = 0;

#define RESET() do { \
	memset(&result, 0, sizeof(result)); \
	memset(&vec, 0, sizeof(vec)); \
	vec.mdfd_vfd = 999; \
	mock_punch_calls = 0; \
	mock_ereport_count = 0; \
	mock_punch_rc = 0; \
	mock_punch_errno = 0; \
} while (0)

	/* Case 1: success punches and counts punched_blocks. */
	RESET();
	md_punch_one_segment(0, 0, 0, 8192 * 10, &arg);
	if (result.punched_blocks != 10) { printf("FAIL case1 punched=%u\n", result.punched_blocks); fails++; }
	if (result.failed_blocks != 0) { printf("FAIL case1 failed=%u\n", result.failed_blocks); fails++; }
	if (result.unsupported) { printf("FAIL case1 unsupported\n"); fails++; }
	if (mock_punch_calls != 1) { printf("FAIL case1 calls=%d\n", mock_punch_calls); fails++; }

	/* Case 2: EOPNOTSUPP sets latch and unsupported, no failed_blocks. */
	RESET();
	mock_punch_rc = -1;
	mock_punch_errno = EOPNOTSUPP;
	md_punch_one_segment(0, 0, 0, 8192 * 10, &arg);
	if (!result.unsupported) { printf("FAIL case2 not unsupported\n"); fails++; }
	if (!vec.mdfd_punchhole_unsupported) { printf("FAIL case2 latch not set\n"); fails++; }
	if (result.failed_blocks != 0) { printf("FAIL case2 failed=%u\n", result.failed_blocks); fails++; }
	if (result.punched_blocks != 0) { printf("FAIL case2 punched=%u\n", result.punched_blocks); fails++; }

	/* Case 3: latched segment skips the syscall entirely. */
	mock_punch_calls = 0;
	mock_punch_rc = -1;
	mock_punch_errno = EIO;	/* would fail if called */
	memset(&result, 0, sizeof(result));
	md_punch_one_segment(0, 0, 0, 8192 * 10, &arg);
	if (mock_punch_calls != 0) { printf("FAIL case3 calls=%d\n", mock_punch_calls); fails++; }
	if (!result.unsupported) { printf("FAIL case3 not unsupported\n"); fails++; }

	/* Case 4: EIO (unexpected) counts failed_blocks and logs. */
	RESET();
	mock_punch_rc = -1;
	mock_punch_errno = EIO;
	md_punch_one_segment(0, 0, 0, 8192 * 10, &arg);
	if (result.failed_blocks != 10) { printf("FAIL case4 failed=%u\n", result.failed_blocks); fails++; }
	if (result.unsupported) { printf("FAIL case4 unsupported\n"); fails++; }
	if (vec.mdfd_punchhole_unsupported) { printf("FAIL case4 latch set\n"); fails++; }
	if (mock_ereport_count != 1) { printf("FAIL case4 ereport=%d\n", mock_ereport_count); fails++; }

	/* Case 5: NULL segment counts failed_blocks. */
	RESET();
	mock_mdfd_vec = NULL;
	md_punch_one_segment(0, 0, 0, 8192 * 10, &arg);
	if (result.failed_blocks != 10) { printf("FAIL case5 failed=%u\n", result.failed_blocks); fails++; }
	if (mock_punch_calls != 0) { printf("FAIL case5 calls=%d\n", mock_punch_calls); fails++; }
	mock_mdfd_vec = &vec;

	close(fd);
	if (fails == 0)
		printf("ONE SEGMENT TESTS PASSED\n");
	else
		printf("%d FAILURES\n", fails);
	return fails != 0;
}
EOF
		close $fh;
		my @cc = split(' ', $ENV{CC} || 'cc');
		my $rc = system(@cc, '-Wall', '-o', $bin, $c_file);
		unlink $c_file;
		my $ok = 0;
		my $out = '';
		if ($rc == 0) {
			$out = qx{$bin 2>&1};
			$ok = ($? == 0 && $out =~ /ONE SEGMENT TESTS PASSED/);
			unlink $bin;
		} else {
			$out = 'compile failed for one-segment test';
		}
		ok($ok, 'md_punch_one_segment failure branches (errno vs rc, latch, failed_blocks)')
			or diag($out);
	}
}
