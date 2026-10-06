/*-------------------------------------------------------------------------
 *
 * md.c
 *	  This code manages relations that reside on magnetic disk.
 *
 * Or at least, that was what the Berkeley folk had in mind when they named
 * this file.  In reality, what this code provides is an interface from
 * the smgr API to Unix-like filesystem APIs, so it will work with any type
 * of device for which the operating system provides filesystem support.
 * It doesn't matter whether the bits are on spinning rust or some other
 * storage technology.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *
 * IDENTIFICATION
 *	  src/backend/storage/smgr/md.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <limits.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/file.h>
#ifdef HAVE_SYS_FSPACECTL_H
#include <sys/fspacectl.h>
#endif

/*
 * Detect hole-punching support here, right after the system headers that
 * define the feature-test macros, so that the <sys/statvfs.h> include below
 * can be conditioned on it (MSVC has no such header, and fstatvfs() is only
 * used by the hole-punching code).  See the longer platform discussion
 * further down, above md_punchhole_errno_unsupported().
 */
#if defined(FALLOC_FL_PUNCH_HOLE) || defined(F_PUNCHHOLE) || \
	defined(HAVE_SYS_FSPACECTL_H) || \
	((defined(__sun) || defined(__illumos__)) && defined(F_FREESP)) || \
	defined(WIN32)
#define HAVE_PUNCH_HOLE
#endif

#ifdef HAVE_PUNCH_HOLE
#ifndef WIN32
#include <sys/statvfs.h>
#endif
#endif

#include "access/xlogutils.h"
#include "commands/tablespace.h"
#include "common/file_utils.h"
#include "miscadmin.h"
#include "pg_trace.h"
#include "pgstat.h"
#include "storage/aio.h"
#include "storage/bufmgr.h"
#include "storage/fd.h"
#include "storage/md.h"
#include "storage/relfilelocator.h"
#include "storage/smgr.h"
#include "storage/sync.h"
#include "utils/memutils.h"
#include "utils/wait_event.h"

/*
 * The magnetic disk storage manager keeps track of open file
 * descriptors in its own descriptor pool.  This is done to make it
 * easier to support relations that are larger than the operating
 * system's file size limit (often 2GBytes).  In order to do that,
 * we break relations up into "segment" files that are each shorter than
 * the OS file size limit.  The segment size is set by the RELSEG_SIZE
 * configuration constant in pg_config.h.
 *
 * On disk, a relation must consist of consecutively numbered segment
 * files in the pattern
 *	-- Zero or more full segments of exactly RELSEG_SIZE blocks each
 *	-- Exactly one partial segment of size 0 <= size < RELSEG_SIZE blocks
 *	-- Optionally, any number of inactive segments of size 0 blocks.
 * The full and partial segments are collectively the "active" segments.
 * Inactive segments are those that once contained data but are currently
 * not needed because of an mdtruncate() operation.  The reason for leaving
 * them present at size zero, rather than unlinking them, is that other
 * backends and/or the checkpointer might be holding open file references to
 * such segments.  If the relation expands again after mdtruncate(), such
 * that a deactivated segment becomes active again, it is important that
 * such file references still be valid --- else data might get written
 * out to an unlinked old copy of a segment file that will eventually
 * disappear.
 *
 * RELSEG_SIZE must fit into BlockNumber; but since we expose its value
 * as an integer GUC, it actually needs to fit in signed int.  It's worth
 * having a cross-check for this since configure's --with-segsize options
 * could let people select insane values.
 */
StaticAssertDecl(RELSEG_SIZE > 0 && RELSEG_SIZE <= INT_MAX,
				 "RELSEG_SIZE must fit in an integer");

/*
 * File descriptors are stored in the per-fork md_seg_fds arrays inside
 * SMgrRelation. The length of these arrays is stored in md_num_open_segs.
 * Note that a fork's md_num_open_segs having a specific value does not
 * necessarily mean the relation doesn't have additional segments; we may
 * just not have opened the next segment yet.  (We could not have "all
 * segments are in the array" as an invariant anyway, since another backend
 * could extend the relation while we aren't looking.)  We do not have
 * entries for inactive segments, however; as soon as we find a partial
 * segment, we assume that any subsequent segments are inactive.
 *
 * The entire MdfdVec array is palloc'd in the MdCxt memory context.
 */

typedef struct _MdfdVec
{
	File		mdfd_vfd;		/* fd number in fd.c's pool */
	BlockNumber mdfd_segno;		/* segment number, from 0 */
	/*
	 * Set when the filesystem backing this segment rejected hole punching
	 * (EOPNOTSUPP etc.), so we don't pay for a failed syscall on every
	 * mdpunchhole() call.
	 */
	bool		mdfd_punchhole_unsupported;
} MdfdVec;

static MemoryContext MdCxt;		/* context for all MdfdVec objects */


/* Populate a file tag describing an md.c segment file. */
#define INIT_MD_FILETAG(a,xx_rlocator,xx_forknum,xx_segno) \
( \
	memset(&(a), 0, sizeof(FileTag)), \
	(a).handler = SYNC_HANDLER_MD, \
	(a).rlocator = (xx_rlocator), \
	(a).forknum = (xx_forknum), \
	(a).segno = (xx_segno) \
)


/*** behavior for mdopen & _mdfd_getseg ***/
/* ereport if segment not present */
#define EXTENSION_FAIL				(1 << 0)
/* return NULL if segment not present */
#define EXTENSION_RETURN_NULL		(1 << 1)
/* create new segments as needed */
#define EXTENSION_CREATE			(1 << 2)
/* create new segments if needed during recovery */
#define EXTENSION_CREATE_RECOVERY	(1 << 3)
/* don't try to open a segment, if not already open */
#define EXTENSION_DONT_OPEN			(1 << 5)


/*
 * Fixed-length string to represent paths to files that need to be built by
 * md.c.
 *
 * The maximum number of segments is MaxBlockNumber / RELSEG_SIZE, where
 * RELSEG_SIZE can be set to 1 (for testing only).
 */
#define SEGMENT_CHARS	OIDCHARS
#define MD_PATH_STR_MAXLEN \
	(\
		REL_PATH_STR_MAXLEN \
		+ sizeof((char)'.') \
		+ SEGMENT_CHARS \
	)
typedef struct MdPathStr
{
	char		str[MD_PATH_STR_MAXLEN + 1];
} MdPathStr;


/* local routines */
static void mdunlinkfork(RelFileLocatorBackend rlocator, ForkNumber forknum,
						 bool isRedo);
static MdfdVec *mdopenfork(SMgrRelation reln, ForkNumber forknum, int behavior);
static void register_dirty_segment(SMgrRelation reln, ForkNumber forknum,
								   MdfdVec *seg);
static void register_unlink_tombstone(RelFileLocatorBackend rlocator);
static void register_forget_request(RelFileLocatorBackend rlocator, ForkNumber forknum,
									BlockNumber segno);
static void _fdvec_resize(SMgrRelation reln,
						  ForkNumber forknum,
						  int nseg);
static MdPathStr _mdfd_segpath(SMgrRelation reln, ForkNumber forknum,
							   BlockNumber segno);
static MdfdVec *_mdfd_openseg(SMgrRelation reln, ForkNumber forknum,
							  BlockNumber segno, int oflags);
static MdfdVec *_mdfd_getseg(SMgrRelation reln, ForkNumber forknum,
							 BlockNumber blkno, bool skipFsync, int behavior);
static BlockNumber _mdnblocks(SMgrRelation reln, ForkNumber forknum,
							  MdfdVec *seg);

static PgAioResult md_readv_complete(PgAioHandle *ioh, PgAioResult prior_result, uint8 cb_data);
static void md_readv_report(PgAioResult result, const PgAioTargetData *td, int elevel);

const PgAioHandleCallbacks aio_md_readv_cb = {
	.complete_shared = md_readv_complete,
	.report = md_readv_report,
};


static inline int
_mdfd_open_flags(void)
{
	int			flags = O_RDWR | PG_BINARY;

	if (io_direct_flags & IO_DIRECT_DATA)
		flags |= PG_O_DIRECT;

	return flags;
}

/*
 * mdinit() -- Initialize private state for magnetic disk storage manager.
 */
void
mdinit(void)
{
	MdCxt = AllocSetContextCreate(TopMemoryContext,
								  "MdSmgr",
								  ALLOCSET_DEFAULT_SIZES);
}

/*
 * mdexists() -- Does the physical file exist?
 *
 * Note: this will return true for lingering files, with pending deletions
 */
bool
mdexists(SMgrRelation reln, ForkNumber forknum)
{
	/*
	 * Close it first, to ensure that we notice if the fork has been unlinked
	 * since we opened it.  As an optimization, we can skip that in recovery,
	 * which already closes relations when dropping them.
	 */
	if (!InRecovery)
		mdclose(reln, forknum);

	return (mdopenfork(reln, forknum, EXTENSION_RETURN_NULL) != NULL);
}

/*
 * mdcreate() -- Create a new relation on magnetic disk.
 *
 * If isRedo is true, it's okay for the relation to exist already.
 */
void
mdcreate(SMgrRelation reln, ForkNumber forknum, bool isRedo)
{
	MdfdVec    *mdfd;
	RelPathStr	path;
	File		fd;

	if (isRedo && reln->md_num_open_segs[forknum] > 0)
		return;					/* created and opened already... */

	Assert(reln->md_num_open_segs[forknum] == 0);

	/*
	 * We may be using the target table space for the first time in this
	 * database, so create a per-database subdirectory if needed.
	 *
	 * XXX this is a fairly ugly violation of module layering, but this seems
	 * to be the best place to put the check.  Maybe TablespaceCreateDbspace
	 * should be here and not in commands/tablespace.c?  But that would imply
	 * importing a lot of stuff that smgr.c oughtn't know, either.
	 */
	TablespaceCreateDbspace(reln->smgr_rlocator.locator.spcOid,
							reln->smgr_rlocator.locator.dbOid,
							isRedo);

	path = relpath(reln->smgr_rlocator, forknum);

	fd = PathNameOpenFile(path.str, _mdfd_open_flags() | O_CREAT | O_EXCL);

	if (fd < 0)
	{
		int			save_errno = errno;

		if (isRedo)
			fd = PathNameOpenFile(path.str, _mdfd_open_flags());
		if (fd < 0)
		{
			/* be sure to report the error reported by create, not open */
			errno = save_errno;
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not create file \"%s\": %m", path.str)));
		}
	}

	_fdvec_resize(reln, forknum, 1);
	mdfd = &reln->md_seg_fds[forknum][0];
	mdfd->mdfd_vfd = fd;
	mdfd->mdfd_segno = 0;
	mdfd->mdfd_punchhole_unsupported = false;

	if (!SmgrIsTemp(reln))
		register_dirty_segment(reln, forknum, mdfd);
}

/*
 * mdunlink() -- Unlink a relation.
 *
 * Note that we're passed a RelFileLocatorBackend --- by the time this is called,
 * there won't be an SMgrRelation hashtable entry anymore.
 *
 * forknum can be a fork number to delete a specific fork, or InvalidForkNumber
 * to delete all forks.
 *
 * For regular relations, we don't unlink the first segment file of the rel,
 * but just truncate it to zero length, and record a request to unlink it after
 * the next checkpoint.  Additional segments can be unlinked immediately,
 * however.  Leaving the empty file in place prevents that relfilenumber
 * from being reused.  The scenario this protects us from is:
 * 1. We delete a relation (and commit, and actually remove its file).
 * 2. We create a new relation, which by chance gets the same relfilenumber as
 *	  the just-deleted one (OIDs must've wrapped around for that to happen).
 * 3. We crash before another checkpoint occurs.
 * During replay, we would delete the file and then recreate it, which is fine
 * if the contents of the file were repopulated by subsequent WAL entries.
 * But if we didn't WAL-log insertions, but instead relied on fsyncing the
 * file after populating it (as we do at wal_level=minimal), the contents of
 * the file would be lost forever.  By leaving the empty file until after the
 * next checkpoint, we prevent reassignment of the relfilenumber until it's
 * safe, because relfilenumber assignment skips over any existing file.
 *
 * Additional segments, if any, are truncated and then unlinked.  The reason
 * for truncating is that other backends may still hold open FDs for these at
 * the smgr level, so that the kernel can't remove the file yet.  We want to
 * reclaim the disk space right away despite that.
 *
 * We do not need to go through this dance for temp relations, though, because
 * we never make WAL entries for temp rels, and so a temp rel poses no threat
 * to the health of a regular rel that has taken over its relfilenumber.
 * The fact that temp rels and regular rels have different file naming
 * patterns provides additional safety.  Other backends shouldn't have open
 * FDs for them, either.
 *
 * We also don't do it while performing a binary upgrade.  There is no reuse
 * hazard in that case, since after a crash or even a simple ERROR, the
 * upgrade fails and the whole cluster must be recreated from scratch.
 * Furthermore, it is important to remove the files from disk immediately,
 * because we may be about to reuse the same relfilenumber.
 *
 * All the above applies only to the relation's main fork; other forks can
 * just be removed immediately, since they are not needed to prevent the
 * relfilenumber from being recycled.  Also, we do not carefully
 * track whether other forks have been created or not, but just attempt to
 * unlink them unconditionally; so we should never complain about ENOENT.
 *
 * If isRedo is true, it's unsurprising for the relation to be already gone.
 * Also, we should remove the file immediately instead of queuing a request
 * for later, since during redo there's no possibility of creating a
 * conflicting relation.
 *
 * Note: we currently just never warn about ENOENT at all.  We could warn in
 * the main-fork, non-isRedo case, but it doesn't seem worth the trouble.
 *
 * Note: any failure should be reported as WARNING not ERROR, because
 * we are usually not in a transaction anymore when this is called.
 */
void
mdunlink(RelFileLocatorBackend rlocator, ForkNumber forknum, bool isRedo)
{
	/* Now do the per-fork work */
	if (forknum == InvalidForkNumber)
	{
		for (forknum = 0; forknum <= MAX_FORKNUM; forknum++)
			mdunlinkfork(rlocator, forknum, isRedo);
	}
	else
		mdunlinkfork(rlocator, forknum, isRedo);
}

/*
 * Truncate a file to release disk space.
 */
static int
do_truncate(const char *path)
{
	int			save_errno;
	int			ret;

	ret = pg_truncate(path, 0);

	/* Log a warning here to avoid repetition in callers. */
	if (ret < 0 && errno != ENOENT)
	{
		save_errno = errno;
		ereport(WARNING,
				(errcode_for_file_access(),
				 errmsg("could not truncate file \"%s\": %m", path)));
		errno = save_errno;
	}

	return ret;
}

static void
mdunlinkfork(RelFileLocatorBackend rlocator, ForkNumber forknum, bool isRedo)
{
	RelPathStr	path;
	int			ret;
	int			save_errno;

	path = relpath(rlocator, forknum);

	/*
	 * Truncate and then unlink the first segment, or just register a request
	 * to unlink it later, as described in the comments for mdunlink().
	 */
	if (isRedo || IsBinaryUpgrade || forknum != MAIN_FORKNUM ||
		RelFileLocatorBackendIsTemp(rlocator))
	{
		if (!RelFileLocatorBackendIsTemp(rlocator))
		{
			/* Prevent other backends' fds from holding on to the disk space */
			ret = do_truncate(path.str);

			/* Forget any pending sync requests for the first segment */
			save_errno = errno;
			register_forget_request(rlocator, forknum, 0 /* first seg */ );
			errno = save_errno;
		}
		else
			ret = 0;

		/* Next unlink the file, unless it was already found to be missing */
		if (ret >= 0 || errno != ENOENT)
		{
			ret = unlink(path.str);
			if (ret < 0 && errno != ENOENT)
			{
				save_errno = errno;
				ereport(WARNING,
						(errcode_for_file_access(),
						 errmsg("could not remove file \"%s\": %m", path.str)));
				errno = save_errno;
			}
		}
	}
	else
	{
		/* Prevent other backends' fds from holding on to the disk space */
		ret = do_truncate(path.str);

		/* Register request to unlink first segment later */
		save_errno = errno;
		register_unlink_tombstone(rlocator);
		errno = save_errno;
	}

	/*
	 * Delete any additional segments.
	 *
	 * Note that because we loop until getting ENOENT, we will correctly
	 * remove all inactive segments as well as active ones.  Ideally we'd
	 * continue the loop until getting exactly that errno, but that risks an
	 * infinite loop if the problem is directory-wide (for instance, if we
	 * suddenly can't read the data directory itself).  We compromise by
	 * continuing after a non-ENOENT truncate error, but stopping after any
	 * unlink error.  If there is indeed a directory-wide problem, additional
	 * unlink attempts wouldn't work anyway.
	 */
	if (ret >= 0 || errno != ENOENT)
	{
		MdPathStr	segpath;
		BlockNumber segno;

		for (segno = 1;; segno++)
		{
			sprintf(segpath.str, "%s.%u", path.str, segno);

			if (!RelFileLocatorBackendIsTemp(rlocator))
			{
				/*
				 * Prevent other backends' fds from holding on to the disk
				 * space.  We're done if we see ENOENT, though.
				 */
				if (do_truncate(segpath.str) < 0 && errno == ENOENT)
					break;

				/*
				 * Forget any pending sync requests for this segment before we
				 * try to unlink.
				 */
				register_forget_request(rlocator, forknum, segno);
			}

			if (unlink(segpath.str) < 0)
			{
				/* ENOENT is expected after the last segment... */
				if (errno != ENOENT)
					ereport(WARNING,
							(errcode_for_file_access(),
							 errmsg("could not remove file \"%s\": %m", segpath.str)));
				break;
			}
		}
	}
}

/*
 * mdextend() -- Add a block to the specified relation.
 *
 * The semantics are nearly the same as mdwrite(): write at the
 * specified position.  However, this is to be used for the case of
 * extending a relation (i.e., blocknum is at or beyond the current
 * EOF).  Note that we assume writing a block beyond current EOF
 * causes intervening file space to become filled with zeroes.
 */
void
mdextend(SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum,
		 const void *buffer, bool skipFsync)
{
	pgoff_t		seekpos;
	ssize_t		nbytes;
	MdfdVec    *v;

	/* If this build supports direct I/O, the buffer must be I/O aligned. */
	if (PG_O_DIRECT != 0 && PG_IO_ALIGN_SIZE <= BLCKSZ)
		Assert((uintptr_t) buffer == TYPEALIGN(PG_IO_ALIGN_SIZE, buffer));

	/* This assert is too expensive to have on normally ... */
#ifdef CHECK_WRITE_VS_EXTEND
	Assert(blocknum >= mdnblocks(reln, forknum));
#endif

	/*
	 * If a relation manages to grow to 2^32-1 blocks, refuse to extend it any
	 * more --- we mustn't create a block whose number actually is
	 * InvalidBlockNumber.  (Note that this failure should be unreachable
	 * because of upstream checks in bufmgr.c.)
	 */
	if (blocknum == InvalidBlockNumber)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("cannot extend file \"%s\" beyond %u blocks",
						relpath(reln->smgr_rlocator, forknum).str,
						InvalidBlockNumber)));

	v = _mdfd_getseg(reln, forknum, blocknum, skipFsync, EXTENSION_CREATE);

	seekpos = (pgoff_t) BLCKSZ * (blocknum % ((BlockNumber) RELSEG_SIZE));

	Assert(seekpos < (pgoff_t) BLCKSZ * RELSEG_SIZE);

	if ((nbytes = FileWrite(v->mdfd_vfd, buffer, BLCKSZ, seekpos, WAIT_EVENT_DATA_FILE_EXTEND)) != BLCKSZ)
	{
		if (nbytes < 0)
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not extend file \"%s\": %m",
							FilePathName(v->mdfd_vfd)),
					 errhint("Check free disk space.")));
		/* short write: complain appropriately */
		ereport(ERROR,
				(errcode(ERRCODE_DISK_FULL),
				 errmsg("could not extend file \"%s\": wrote only %zd of %zu bytes at block %u",
						FilePathName(v->mdfd_vfd),
						nbytes, (size_t) BLCKSZ, blocknum),
				 errhint("Check free disk space.")));
	}

	if (!skipFsync && !SmgrIsTemp(reln))
		register_dirty_segment(reln, forknum, v);

	Assert(_mdnblocks(reln, forknum, v) <= ((BlockNumber) RELSEG_SIZE));
}

/*
 * mdzeroextend() -- Add new zeroed out blocks to the specified relation.
 *
 * Similar to mdextend(), except the relation can be extended by multiple
 * blocks at once and the added blocks will be filled with zeroes.
 */
void
mdzeroextend(SMgrRelation reln, ForkNumber forknum,
			 BlockNumber blocknum, int nblocks, bool skipFsync)
{
	MdfdVec    *v;
	BlockNumber curblocknum = blocknum;
	int			remblocks = nblocks;

	Assert(nblocks > 0);

	/* This assert is too expensive to have on normally ... */
#ifdef CHECK_WRITE_VS_EXTEND
	Assert(blocknum >= mdnblocks(reln, forknum));
#endif

	/*
	 * If a relation manages to grow to 2^32-1 blocks, refuse to extend it any
	 * more --- we mustn't create a block whose number actually is
	 * InvalidBlockNumber or larger.
	 */
	if ((uint64) blocknum + nblocks >= (uint64) InvalidBlockNumber)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("cannot extend file \"%s\" beyond %u blocks",
						relpath(reln->smgr_rlocator, forknum).str,
						InvalidBlockNumber)));

	while (remblocks > 0)
	{
		BlockNumber segstartblock = curblocknum % ((BlockNumber) RELSEG_SIZE);
		pgoff_t		seekpos = (pgoff_t) BLCKSZ * segstartblock;
		int			numblocks;

		if (segstartblock + remblocks > RELSEG_SIZE)
			numblocks = RELSEG_SIZE - segstartblock;
		else
			numblocks = remblocks;

		v = _mdfd_getseg(reln, forknum, curblocknum, skipFsync, EXTENSION_CREATE);

		Assert(segstartblock < RELSEG_SIZE);
		Assert(segstartblock + numblocks <= RELSEG_SIZE);

		/*
		 * If available and useful, use posix_fallocate() (via
		 * FileFallocate()) to extend the relation. That's often more
		 * efficient than using write(), as it commonly won't cause the kernel
		 * to allocate page cache space for the extended pages.
		 *
		 * However, we don't use FileFallocate() for small extensions, as it
		 * defeats delayed allocation on some filesystems. Not clear where
		 * that decision should be made though? For now just use a cutoff of
		 * 8, anything between 4 and 8 worked OK in some local testing.
		 */
		if (numblocks > 8 &&
			file_extend_method != FILE_EXTEND_METHOD_WRITE_ZEROS)
		{
			int			ret = 0;

#ifdef HAVE_POSIX_FALLOCATE
			if (file_extend_method == FILE_EXTEND_METHOD_POSIX_FALLOCATE)
			{
				ret = FileFallocate(v->mdfd_vfd,
									seekpos, (pgoff_t) BLCKSZ * numblocks,
									WAIT_EVENT_DATA_FILE_EXTEND);
			}
			else
#endif
			{
				elog(ERROR, "unsupported file_extend_method: %d",
					 file_extend_method);
			}
			if (ret != 0)
			{
				ereport(ERROR,
						errcode_for_file_access(),
						errmsg("could not extend file \"%s\" with FileFallocate(): %m",
							   FilePathName(v->mdfd_vfd)),
						errhint("Check free disk space."));
			}
		}
		else
		{
			int			ret;

			/*
			 * Even if we don't want to use fallocate, we can still extend a
			 * bit more efficiently than writing each 8kB block individually.
			 * pg_pwrite_zeros() (via FileZero()) uses pg_pwritev_with_retry()
			 * to avoid multiple writes or needing a zeroed buffer for the
			 * whole length of the extension.
			 */
			ret = FileZero(v->mdfd_vfd,
						   seekpos, (pgoff_t) BLCKSZ * numblocks,
						   WAIT_EVENT_DATA_FILE_EXTEND);
			if (ret < 0)
				ereport(ERROR,
						errcode_for_file_access(),
						errmsg("could not extend file \"%s\": %m",
							   FilePathName(v->mdfd_vfd)),
						errhint("Check free disk space."));
		}

		if (!skipFsync && !SmgrIsTemp(reln))
			register_dirty_segment(reln, forknum, v);

		Assert(_mdnblocks(reln, forknum, v) <= ((BlockNumber) RELSEG_SIZE));

		remblocks -= numblocks;
		curblocknum += numblocks;
	}
}

/*
 * mdopenfork() -- Open one fork of the specified relation.
 *
 * Note we only open the first segment, when there are multiple segments.
 *
 * If first segment is not present, either ereport or return NULL according
 * to "behavior".  We treat EXTENSION_CREATE the same as EXTENSION_FAIL;
 * EXTENSION_CREATE means it's OK to extend an existing relation, not to
 * invent one out of whole cloth.
 */
static MdfdVec *
mdopenfork(SMgrRelation reln, ForkNumber forknum, int behavior)
{
	MdfdVec    *mdfd;
	RelPathStr	path;
	File		fd;

	/* No work if already open */
	if (reln->md_num_open_segs[forknum] > 0)
		return &reln->md_seg_fds[forknum][0];

	path = relpath(reln->smgr_rlocator, forknum);

	fd = PathNameOpenFile(path.str, _mdfd_open_flags());

	if (fd < 0)
	{
		if ((behavior & EXTENSION_RETURN_NULL) &&
			FILE_POSSIBLY_DELETED(errno))
			return NULL;
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not open file \"%s\": %m", path.str)));
	}

	_fdvec_resize(reln, forknum, 1);
	mdfd = &reln->md_seg_fds[forknum][0];
	mdfd->mdfd_vfd = fd;
	mdfd->mdfd_segno = 0;
	mdfd->mdfd_punchhole_unsupported = false;

	Assert(_mdnblocks(reln, forknum, mdfd) <= ((BlockNumber) RELSEG_SIZE));

	return mdfd;
}

/*
 * mdopen() -- Initialize newly-opened relation.
 */
void
mdopen(SMgrRelation reln)
{
	/* mark it not open */
	for (int forknum = 0; forknum <= MAX_FORKNUM; forknum++)
		reln->md_num_open_segs[forknum] = 0;
}

/*
 * mdclose() -- Close the specified relation, if it isn't closed already.
 */
void
mdclose(SMgrRelation reln, ForkNumber forknum)
{
	int			nopensegs = reln->md_num_open_segs[forknum];

	/* No work if already closed */
	if (nopensegs == 0)
		return;

	/* close segments starting from the end */
	while (nopensegs > 0)
	{
		MdfdVec    *v = &reln->md_seg_fds[forknum][nopensegs - 1];

		FileClose(v->mdfd_vfd);
		_fdvec_resize(reln, forknum, nopensegs - 1);
		nopensegs--;
	}
}

/*
 * mdprefetch() -- Initiate asynchronous read of the specified blocks of a relation
 */
bool
mdprefetch(SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum,
		   int nblocks)
{
#ifdef USE_PREFETCH

	Assert((io_direct_flags & IO_DIRECT_DATA) == 0);

	if ((uint64) blocknum + nblocks > (uint64) MaxBlockNumber + 1)
		return false;

	while (nblocks > 0)
	{
		pgoff_t		seekpos;
		MdfdVec    *v;
		int			nblocks_this_segment;

		v = _mdfd_getseg(reln, forknum, blocknum, false,
						 InRecovery ? EXTENSION_RETURN_NULL : EXTENSION_FAIL);
		if (v == NULL)
			return false;

		seekpos = (pgoff_t) BLCKSZ * (blocknum % ((BlockNumber) RELSEG_SIZE));

		Assert(seekpos < (pgoff_t) BLCKSZ * RELSEG_SIZE);

		nblocks_this_segment =
			Min(nblocks,
				RELSEG_SIZE - (blocknum % ((BlockNumber) RELSEG_SIZE)));

		(void) FilePrefetch(v->mdfd_vfd, seekpos, BLCKSZ * nblocks_this_segment,
							WAIT_EVENT_DATA_FILE_PREFETCH);

		blocknum += nblocks_this_segment;
		nblocks -= nblocks_this_segment;
	}
#endif							/* USE_PREFETCH */

	return true;
}

/*
 * Convert an array of buffer address into an array of iovec objects, and
 * return the number that were required.  'iov' must have enough space for up
 * to 'nblocks' elements, but the number used may be less depending on
 * merging.  In the case of a run of fully contiguous buffers, a single iovec
 * will be populated that can be handled as a plain non-vectored I/O.
 */
static int
buffers_to_iovec(struct iovec *iov, void **buffers, int nblocks)
{
	struct iovec *iovp;
	int			iovcnt;

	Assert(nblocks >= 1);

	/* If this build supports direct I/O, buffers must be I/O aligned. */
	for (int i = 0; i < nblocks; ++i)
	{
		if (PG_O_DIRECT != 0 && PG_IO_ALIGN_SIZE <= BLCKSZ)
			Assert((uintptr_t) buffers[i] ==
				   TYPEALIGN(PG_IO_ALIGN_SIZE, buffers[i]));
	}

	/* Start the first iovec off with the first buffer. */
	iovp = &iov[0];
	iovp->iov_base = buffers[0];
	iovp->iov_len = BLCKSZ;
	iovcnt = 1;

	/* Try to merge the rest. */
	for (int i = 1; i < nblocks; ++i)
	{
		void	   *buffer = buffers[i];

		if (((char *) iovp->iov_base + iovp->iov_len) == buffer)
		{
			/* Contiguous with the last iovec. */
			iovp->iov_len += BLCKSZ;
		}
		else
		{
			/* Need a new iovec. */
			iovp++;
			iovp->iov_base = buffer;
			iovp->iov_len = BLCKSZ;
			iovcnt++;
		}
	}

	return iovcnt;
}

/*
 * mdmaxcombine() -- Return the maximum number of total blocks that can be
 *				 combined with an IO starting at blocknum.
 */
uint32
mdmaxcombine(SMgrRelation reln, ForkNumber forknum,
			 BlockNumber blocknum)
{
	BlockNumber segoff;

	segoff = blocknum % ((BlockNumber) RELSEG_SIZE);

	return RELSEG_SIZE - segoff;
}

/*
 * mdreadv() -- Read the specified blocks from a relation.
 */
void
mdreadv(SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum,
		void **buffers, BlockNumber nblocks)
{
	while (nblocks > 0)
	{
		struct iovec iov[PG_IOV_MAX];
		int			iovcnt;
		pgoff_t		seekpos;
		ssize_t		nbytes;
		MdfdVec    *v;
		BlockNumber nblocks_this_segment;
		size_t		transferred_this_segment;
		size_t		size_this_segment;

		v = _mdfd_getseg(reln, forknum, blocknum, false,
						 EXTENSION_FAIL | EXTENSION_CREATE_RECOVERY);

		seekpos = (pgoff_t) BLCKSZ * (blocknum % ((BlockNumber) RELSEG_SIZE));

		Assert(seekpos < (pgoff_t) BLCKSZ * RELSEG_SIZE);

		nblocks_this_segment =
			Min(nblocks,
				RELSEG_SIZE - (blocknum % ((BlockNumber) RELSEG_SIZE)));
		nblocks_this_segment = Min(nblocks_this_segment, lengthof(iov));

		if (nblocks_this_segment != nblocks)
			elog(ERROR, "read crosses segment boundary");

		iovcnt = buffers_to_iovec(iov, buffers, nblocks_this_segment);
		size_this_segment = nblocks_this_segment * BLCKSZ;
		transferred_this_segment = 0;

		/*
		 * Inner loop to continue after a short read.  We'll keep going until
		 * we hit EOF rather than assuming that a short read means we hit the
		 * end.
		 */
		for (;;)
		{
			TRACE_POSTGRESQL_SMGR_MD_READ_START(forknum, blocknum,
												reln->smgr_rlocator.locator.spcOid,
												reln->smgr_rlocator.locator.dbOid,
												reln->smgr_rlocator.locator.relNumber,
												reln->smgr_rlocator.backend);
			nbytes = FileReadV(v->mdfd_vfd, iov, iovcnt, seekpos,
							   WAIT_EVENT_DATA_FILE_READ);
			TRACE_POSTGRESQL_SMGR_MD_READ_DONE(forknum, blocknum,
											   reln->smgr_rlocator.locator.spcOid,
											   reln->smgr_rlocator.locator.dbOid,
											   reln->smgr_rlocator.locator.relNumber,
											   reln->smgr_rlocator.backend,
											   nbytes,
											   size_this_segment - transferred_this_segment);

#ifdef SIMULATE_SHORT_READ
			nbytes = Min(nbytes, 4096);
#endif

			if (nbytes < 0)
				ereport(ERROR,
						(errcode_for_file_access(),
						 errmsg("could not read blocks %u..%u in file \"%s\": %m",
								blocknum,
								blocknum + nblocks_this_segment - 1,
								FilePathName(v->mdfd_vfd))));

			if (nbytes == 0)
			{
				/*
				 * We are at or past EOF, or we read a partial block at EOF.
				 * Normally this is an error; upper levels should never try to
				 * read a nonexistent block.  However, if zero_damaged_pages
				 * is ON or we are InRecovery, we should instead return zeroes
				 * without complaining.  This allows, for example, the case of
				 * trying to update a block that was later truncated away.
				 *
				 * NB: We think that this codepath is unreachable in recovery
				 * and incomplete with zero_damaged_pages, as missing segments
				 * are not created. Putting blocks into the buffer-pool that
				 * do not exist on disk is rather problematic, as it will not
				 * be found by scans that rely on smgrnblocks(), as they are
				 * beyond EOF. It also can cause weird problems with relation
				 * extension, as relation extension does not expect blocks
				 * beyond EOF to exist.
				 *
				 * Therefore we do not want to copy the logic into
				 * mdstartreadv(), where it would have to be more complicated
				 * due to potential differences in the zero_damaged_pages
				 * setting between the definer and completor of IO.
				 *
				 * For PG 18, we are putting an Assert(false) in mdreadv()
				 * (triggering failures in assertion-enabled builds, but
				 * continuing to work in production builds). Afterwards we
				 * plan to remove this code entirely.
				 */
				if (zero_damaged_pages || InRecovery)
				{
					Assert(false);	/* see comment above */

					for (BlockNumber i = transferred_this_segment / BLCKSZ;
						 i < nblocks_this_segment;
						 ++i)
						memset(buffers[i], 0, BLCKSZ);
					break;
				}
				else
					ereport(ERROR,
							(errcode(ERRCODE_DATA_CORRUPTED),
							 errmsg("could not read blocks %u..%u in file \"%s\": read only %zu of %zu bytes",
									blocknum,
									blocknum + nblocks_this_segment - 1,
									FilePathName(v->mdfd_vfd),
									transferred_this_segment,
									size_this_segment)));
			}

			/* One loop should usually be enough. */
			transferred_this_segment += nbytes;
			Assert(transferred_this_segment <= size_this_segment);
			if (transferred_this_segment == size_this_segment)
				break;

			/* Adjust position and vectors after a short read. */
			seekpos += nbytes;
			iovcnt = compute_remaining_iovec(iov, iov, iovcnt, nbytes);
		}

		nblocks -= nblocks_this_segment;
		buffers += nblocks_this_segment;
		blocknum += nblocks_this_segment;
	}
}

/*
 * mdstartreadv() -- Asynchronous version of mdreadv().
 */
void
mdstartreadv(PgAioHandle *ioh,
			 SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum,
			 void **buffers, BlockNumber nblocks)
{
	pgoff_t		seekpos;
	MdfdVec    *v;
	BlockNumber nblocks_this_segment;
	struct iovec *iov;
	int			iovcnt;
	int			ret;

	v = _mdfd_getseg(reln, forknum, blocknum, false,
					 EXTENSION_FAIL | EXTENSION_CREATE_RECOVERY);

	seekpos = (pgoff_t) BLCKSZ * (blocknum % ((BlockNumber) RELSEG_SIZE));

	Assert(seekpos < (pgoff_t) BLCKSZ * RELSEG_SIZE);

	nblocks_this_segment =
		Min(nblocks,
			RELSEG_SIZE - (blocknum % ((BlockNumber) RELSEG_SIZE)));

	if (nblocks_this_segment != nblocks)
		elog(ERROR, "read crossing segment boundary");

	iovcnt = pgaio_io_get_iovec(ioh, &iov);

	Assert(nblocks <= iovcnt);

	iovcnt = buffers_to_iovec(iov, buffers, nblocks_this_segment);

	Assert(iovcnt <= nblocks_this_segment);

	if (!(io_direct_flags & IO_DIRECT_DATA))
		pgaio_io_set_flag(ioh, PGAIO_HF_BUFFERED);

	pgaio_io_set_target_smgr(ioh,
							 reln,
							 forknum,
							 blocknum,
							 nblocks,
							 false);
	pgaio_io_register_callbacks(ioh, PGAIO_HCB_MD_READV, 0);

	ret = FileStartReadV(ioh, v->mdfd_vfd, iovcnt, seekpos, WAIT_EVENT_DATA_FILE_READ);
	if (ret != 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not start reading blocks %u..%u in file \"%s\": %m",
						blocknum,
						blocknum + nblocks_this_segment - 1,
						FilePathName(v->mdfd_vfd))));

	/*
	 * The error checks corresponding to the post-read checks in mdreadv() are
	 * in md_readv_complete().
	 *
	 * However we chose, at least for now, to not implement the
	 * zero_damaged_pages logic present in mdreadv(). As outlined in mdreadv()
	 * that logic is rather problematic, and we want to get rid of it. Here
	 * equivalent logic would have to be more complicated due to potential
	 * differences in the zero_damaged_pages setting between the definer and
	 * completor of IO.
	 */
}

/*
 * mdwritev() -- Write the supplied blocks at the appropriate location.
 *
 * This is to be used only for updating already-existing blocks of a
 * relation (ie, those before the current EOF).  To extend a relation,
 * use mdextend().
 */
void
mdwritev(SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum,
		 const void **buffers, BlockNumber nblocks, bool skipFsync)
{
	/* This assert is too expensive to have on normally ... */
#ifdef CHECK_WRITE_VS_EXTEND
	Assert((uint64) blocknum + (uint64) nblocks <= (uint64) mdnblocks(reln, forknum));
#endif

	while (nblocks > 0)
	{
		struct iovec iov[PG_IOV_MAX];
		int			iovcnt;
		pgoff_t		seekpos;
		ssize_t		nbytes;
		MdfdVec    *v;
		BlockNumber nblocks_this_segment;
		size_t		transferred_this_segment;
		size_t		size_this_segment;

		v = _mdfd_getseg(reln, forknum, blocknum, skipFsync,
						 EXTENSION_FAIL | EXTENSION_CREATE_RECOVERY);

		seekpos = (pgoff_t) BLCKSZ * (blocknum % ((BlockNumber) RELSEG_SIZE));

		Assert(seekpos < (pgoff_t) BLCKSZ * RELSEG_SIZE);

		nblocks_this_segment =
			Min(nblocks,
				RELSEG_SIZE - (blocknum % ((BlockNumber) RELSEG_SIZE)));
		nblocks_this_segment = Min(nblocks_this_segment, lengthof(iov));

		if (nblocks_this_segment != nblocks)
			elog(ERROR, "write crosses segment boundary");

		iovcnt = buffers_to_iovec(iov, (void **) buffers, nblocks_this_segment);
		size_this_segment = nblocks_this_segment * BLCKSZ;
		transferred_this_segment = 0;

		/*
		 * Inner loop to continue after a short write.  If the reason is that
		 * we're out of disk space, a future attempt should get an ENOSPC
		 * error from the kernel.
		 */
		for (;;)
		{
			TRACE_POSTGRESQL_SMGR_MD_WRITE_START(forknum, blocknum,
												 reln->smgr_rlocator.locator.spcOid,
												 reln->smgr_rlocator.locator.dbOid,
												 reln->smgr_rlocator.locator.relNumber,
												 reln->smgr_rlocator.backend);
			nbytes = FileWriteV(v->mdfd_vfd, iov, iovcnt, seekpos,
								WAIT_EVENT_DATA_FILE_WRITE);
			TRACE_POSTGRESQL_SMGR_MD_WRITE_DONE(forknum, blocknum,
												reln->smgr_rlocator.locator.spcOid,
												reln->smgr_rlocator.locator.dbOid,
												reln->smgr_rlocator.locator.relNumber,
												reln->smgr_rlocator.backend,
												nbytes,
												size_this_segment - transferred_this_segment);

#ifdef SIMULATE_SHORT_WRITE
			nbytes = Min(nbytes, 4096);
#endif

			if (nbytes < 0)
			{
				bool		enospc = errno == ENOSPC;

				ereport(ERROR,
						(errcode_for_file_access(),
						 errmsg("could not write blocks %u..%u in file \"%s\": %m",
								blocknum,
								blocknum + nblocks_this_segment - 1,
								FilePathName(v->mdfd_vfd)),
						 enospc ? errhint("Check free disk space.") : 0));
			}

			/* One loop should usually be enough. */
			transferred_this_segment += nbytes;
			Assert(transferred_this_segment <= size_this_segment);
			if (transferred_this_segment == size_this_segment)
				break;

			/* Adjust position and iovecs after a short write. */
			seekpos += nbytes;
			iovcnt = compute_remaining_iovec(iov, iov, iovcnt, nbytes);
		}

		if (!skipFsync && !SmgrIsTemp(reln))
			register_dirty_segment(reln, forknum, v);

		nblocks -= nblocks_this_segment;
		buffers += nblocks_this_segment;
		blocknum += nblocks_this_segment;
	}
}


/*
 * mdwriteback() -- Tell the kernel to write pages back to storage.
 *
 * This accepts a range of blocks because flushing several pages at once is
 * considerably more efficient than doing so individually.
 */
void
mdwriteback(SMgrRelation reln, ForkNumber forknum,
			BlockNumber blocknum, BlockNumber nblocks)
{
	Assert((io_direct_flags & IO_DIRECT_DATA) == 0);

	/*
	 * Issue flush requests in as few requests as possible; have to split at
	 * segment boundaries though, since those are actually separate files.
	 */
	while (nblocks > 0)
	{
		BlockNumber nflush = nblocks;
		pgoff_t		seekpos;
		MdfdVec    *v;
		int			segnum_start,
					segnum_end;

		v = _mdfd_getseg(reln, forknum, blocknum, true /* not used */ ,
						 EXTENSION_DONT_OPEN);

		/*
		 * We might be flushing buffers of already removed relations, that's
		 * ok, just ignore that case.  If the segment file wasn't open already
		 * (ie from a recent mdwrite()), then we don't want to re-open it, to
		 * avoid a race with PROCSIGNAL_BARRIER_SMGRRELEASE that might leave
		 * us with a descriptor to a file that is about to be unlinked.
		 */
		if (!v)
			return;

		/* compute offset inside the current segment */
		segnum_start = blocknum / RELSEG_SIZE;

		/* compute number of desired writes within the current segment */
		segnum_end = (blocknum + nblocks - 1) / RELSEG_SIZE;
		if (segnum_start != segnum_end)
			nflush = RELSEG_SIZE - (blocknum % ((BlockNumber) RELSEG_SIZE));

		Assert(nflush >= 1);
		Assert(nflush <= nblocks);

		seekpos = (pgoff_t) BLCKSZ * (blocknum % ((BlockNumber) RELSEG_SIZE));

		FileWriteback(v->mdfd_vfd, seekpos, (pgoff_t) BLCKSZ * nflush, WAIT_EVENT_DATA_FILE_FLUSH);

		nblocks -= nflush;
		blocknum += nflush;
	}
}

/*
 * mdnblocks() -- Get the number of blocks stored in a relation.
 *
 * Important side effect: all active segments of the relation are opened
 * and added to the md_seg_fds array.  If this routine has not been
 * called, then only segments up to the last one actually touched
 * are present in the array.
 */
BlockNumber
mdnblocks(SMgrRelation reln, ForkNumber forknum)
{
	MdfdVec    *v;
	BlockNumber nblocks;
	BlockNumber segno;

	mdopenfork(reln, forknum, EXTENSION_FAIL);

	/* mdopen has opened the first segment */
	Assert(reln->md_num_open_segs[forknum] > 0);

	/*
	 * Start from the last open segments, to avoid redundant seeks.  We have
	 * previously verified that these segments are exactly RELSEG_SIZE long,
	 * and it's useless to recheck that each time.
	 *
	 * NOTE: this assumption could only be wrong if another backend has
	 * truncated the relation.  We rely on higher code levels to handle that
	 * scenario by closing and re-opening the md fd, which is handled via
	 * relcache flush.  (Since the checkpointer doesn't participate in
	 * relcache flush, it could have segment entries for inactive segments;
	 * that's OK because the checkpointer never needs to compute relation
	 * size.)
	 */
	segno = reln->md_num_open_segs[forknum] - 1;
	v = &reln->md_seg_fds[forknum][segno];

	for (;;)
	{
		nblocks = _mdnblocks(reln, forknum, v);
		if (nblocks > ((BlockNumber) RELSEG_SIZE))
			elog(FATAL, "segment too big");
		if (nblocks < ((BlockNumber) RELSEG_SIZE))
			return (segno * ((BlockNumber) RELSEG_SIZE)) + nblocks;

		/*
		 * If segment is exactly RELSEG_SIZE, advance to next one.
		 */
		segno++;

		/*
		 * We used to pass O_CREAT here, but that has the disadvantage that it
		 * might create a segment which has vanished through some operating
		 * system misadventure.  In such a case, creating the segment here
		 * undermines _mdfd_getseg's attempts to notice and report an error
		 * upon access to a missing segment.
		 */
		v = _mdfd_openseg(reln, forknum, segno, 0);
		if (v == NULL)
			return segno * ((BlockNumber) RELSEG_SIZE);
	}
}

/*
 * mdtruncate() -- Truncate relation to specified number of blocks.
 *
 * Guaranteed not to allocate memory, so it can be used in a critical section.
 * Caller must have called smgrnblocks() to obtain curnblk while holding a
 * sufficient lock to prevent a change in relation size, and not used any smgr
 * functions for this relation or handled interrupts in between.  This makes
 * sure we have opened all active segments, so that truncate loop will get
 * them all!
 *
 * If nblocks > curnblk, the request is ignored when we are InRecovery,
 * otherwise, an error is raised.
 */
void
mdtruncate(SMgrRelation reln, ForkNumber forknum,
		   BlockNumber curnblk, BlockNumber nblocks)
{
	BlockNumber priorblocks;
	int			curopensegs;

	if (nblocks > curnblk)
	{
		/* Bogus request ... but no complaint if InRecovery */
		if (InRecovery)
			return;
		ereport(ERROR,
				(errmsg("could not truncate file \"%s\" to %u blocks: it's only %u blocks now",
						relpath(reln->smgr_rlocator, forknum).str,
						nblocks, curnblk)));
	}
	if (nblocks == curnblk)
		return;					/* no work */

	/*
	 * Truncate segments, starting at the last one. Starting at the end makes
	 * managing the memory for the fd array easier, should there be errors.
	 */
	curopensegs = reln->md_num_open_segs[forknum];
	while (curopensegs > 0)
	{
		MdfdVec    *v;

		priorblocks = (curopensegs - 1) * RELSEG_SIZE;

		v = &reln->md_seg_fds[forknum][curopensegs - 1];

		if (priorblocks > nblocks)
		{
			/*
			 * This segment is no longer active. We truncate the file, but do
			 * not delete it, for reasons explained in the header comments.
			 */
			if (FileTruncate(v->mdfd_vfd, 0, WAIT_EVENT_DATA_FILE_TRUNCATE) < 0)
				ereport(ERROR,
						(errcode_for_file_access(),
						 errmsg("could not truncate file \"%s\": %m",
								FilePathName(v->mdfd_vfd))));

			if (!SmgrIsTemp(reln))
				register_dirty_segment(reln, forknum, v);

			/* we never drop the 1st segment */
			Assert(v != &reln->md_seg_fds[forknum][0]);

			FileClose(v->mdfd_vfd);
			_fdvec_resize(reln, forknum, curopensegs - 1);
		}
		else if (priorblocks + ((BlockNumber) RELSEG_SIZE) > nblocks)
		{
			/*
			 * This is the last segment we want to keep. Truncate the file to
			 * the right length. NOTE: if nblocks is exactly a multiple K of
			 * RELSEG_SIZE, we will truncate the K+1st segment to 0 length but
			 * keep it. This adheres to the invariant given in the header
			 * comments.
			 */
			BlockNumber lastsegblocks = nblocks - priorblocks;

			if (FileTruncate(v->mdfd_vfd, (pgoff_t) lastsegblocks * BLCKSZ, WAIT_EVENT_DATA_FILE_TRUNCATE) < 0)
				ereport(ERROR,
						(errcode_for_file_access(),
						 errmsg("could not truncate file \"%s\" to %u blocks: %m",
								FilePathName(v->mdfd_vfd),
								nblocks)));
			if (!SmgrIsTemp(reln))
				register_dirty_segment(reln, forknum, v);
		}
		else
		{
			/*
			 * We still need this segment, so nothing to do for this and any
			 * earlier segment.
			 */
			break;
		}
		curopensegs--;
	}
}

#ifdef WIN32
#include <winioctl.h>			/* FSCTL_SET_SPARSE, FSCTL_SET_ZERO_DATA */
#include <io.h>					/* _get_osfhandle */
#endif

/*
 * Platforms with a usable hole-punching API:
 *
 * - Linux: fallocate(FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE)
 * - macOS: fcntl(F_PUNCHHOLE)
 * - FreeBSD 14+: fspacectl(SPACECTL_DEALLOC)
 * - Solaris/illumos: fcntl(F_FREESP)
 * - Windows: DeviceIoControl(FSCTL_SET_ZERO_DATA) on a file marked sparse
 *   via FSCTL_SET_SPARSE (deallocates the range; reads return zeroes)
 *
 * Platforms where mdpunchhole() is a silent no-op:
 * - NetBSD, OpenBSD, DragonFly: no hole-punching API exists
 *
 * The feature macros above (defined near the top of the file, right after the
 * system headers, so that header includes can be conditioned on them) keep
 * this future-proof: a platform that grows a matching API is picked up
 * automatically.  The FreeBSD and Solaris branches additionally require
 * their OS macros, so that a hypothetical same-named macro on an unrelated
 * platform cannot select the wrong branch.
 */
#ifdef HAVE_PUNCH_HOLE
/*
 * md_punchhole_errno_unsupported() -- is this errno "hole punching not
 * supported" (as opposed to a real failure)?
 *
 * EOPNOTSUPP and ENOSYS mean the filesystem or kernel does not support hole
 * punching.  EINVAL counts as "unsupported" only on macOS and Solaris (see
 * below); on Linux and FreeBSD it indicates invalid arguments -- a
 * programming bug in our range arithmetic -- and is treated as an unexpected
 * failure.  (ENODEV is deliberately not listed: FreeBSD's fspacectl()
 * returns ENODEV only for non-regular files, which is unreachable for
 * relation segment files; an unsupported filesystem never errors there,
 * the default vop_stddeallocate simply zero-fills the range and succeeds.)
 *
 * Anything else is an unexpected failure, but still not worth failing the
 * caller over.
 */
static bool
md_punchhole_errno_unsupported(int errnum)
{
	if (errnum == EOPNOTSUPP || errnum == ENOSYS)
		return true;

	/*
	 * EINVAL-as-unsupported is legitimate only where it is documented as a
	 * rejection rather than a bug: macOS (APFS rejects misaligned punches)
	 * and Solaris (UFS/tmpfs return EINVAL for interior ranges; only the
	 * l_len == 0 truncate form is implemented there).  On Linux,
	 * fallocate(2) documents EINVAL for PUNCH_HOLE as "offset was less than
	 * 0, or len was less than or equal to 0" -- invalid arguments, i.e. a
	 * bug in our range construction, which the caller guarantees cannot
	 * happen.  Likewise on FreeBSD, vn_fspacectl() returns EINVAL only for
	 * bad offset/length/flags.  Misclassifying it as "unsupported" there
	 * would silently and permanently disable the feature (via the latches)
	 * instead of logging the bug.
	 */
#if defined(__APPLE__) || defined(__sun) || defined(__illumos__)
	if (errnum == EINVAL)
		return true;
#endif

	return false;
}

/*
 * md_punchhole_range() -- punch a hole in one open file
 *
 * offset and length are byte offsets into the file: offset must be
 * non-negative and length must be positive.  Both should be multiples of
 * the filesystem block size; the caller aligns the range inward to
 * f_bsize, so partial edge blocks are never passed here.
 *
 * Returns 0 on success, -1 on failure with errno set.  On success the
 * punched range reads back as zeroes and the file size is unchanged; on
 * failure the range contents are undefined (a partial punch is possible),
 * and the caller decides how to classify errno.
 *
 * This function is compiled only when the platform provides a
 * deallocation API (see HAVE_PUNCH_HOLE above).  Platforms without one
 * never reach this function; mdpunchhole() handles them with a silent
 * no-op.
 *
 * OpenBSD, NetBSD and DragonFly BSD have no file-range deallocation API
 * (verified against their fcntl(2) man pages), so on those platforms this
 * function is compiled out entirely.
 */
static int
md_punchhole_range(int rawfd, off_t offset, off_t length)
{
	int			rc;

#if defined(FALLOC_FL_PUNCH_HOLE)
	do
	{
		rc = fallocate(rawfd, FALLOC_FL_KEEP_SIZE | FALLOC_FL_PUNCH_HOLE,
					   offset, length);
	} while (rc < 0 && errno == EINTR);
	return rc;
#elif defined(F_PUNCHHOLE)
	fpunchhole_t fpunchhole;

	MemSet(&fpunchhole, 0, sizeof(fpunchhole));
	fpunchhole.fp_offset = offset;
	fpunchhole.fp_length = length;

	do
	{
		rc = fcntl(rawfd, F_PUNCHHOLE, &fpunchhole);
	} while (rc < 0 && errno == EINTR);
	return rc;
#elif defined(HAVE_SYS_FSPACECTL_H)
	struct spacectl_range range;

	/*
	 * fspacectl(SPACECTL_DEALLOC) zeroes the range on every filesystem,
	 * and deallocates the underlying blocks where the filesystem
	 * implements it.  Either way the caller-observable behavior (zeroes,
	 * unchanged file size) holds.  Available since FreeBSD 14.0.
	 *
	 * Accounting wart: on filesystems without a native deallocate
	 * implementation (e.g. UFS, which uses the default vop_stddeallocate),
	 * the "punch" performs real zero-fill writes -- wasted I/O, the
	 * opposite of the feature's goal -- yet success is still counted in
	 * punched_blocks.  The range reads back as zeroes either way, so this
	 * is only a reporting inaccuracy, but VERBOSE output should not be
	 * read as "space reclaimed" on such filesystems.
	 */
	MemSet(&range, 0, sizeof(range));
	range.r_offset = offset;
	range.r_len = length;

	do
	{
		rc = fspacectl(rawfd, SPACECTL_DEALLOC, &range, 0, NULL);
	} while (rc < 0 && errno == EINTR);
	return rc;
#elif (defined(__sun) || defined(__illumos__)) && defined(F_FREESP)
	struct flock fl;

	/*
	 * F_FREESP frees the blocks in the l_start..l_start+l_len range; the
	 * file size is unchanged.  The man page specifies only the range
	 * fields -- l_type is not examined by the space operation (verified
	 * against illumos ufs_space(), tmp_space(), and zfs_space()), so we
	 * zero it along with the rest.
	 *
	 * Filesystem behavior (verified against illumos-gate source): ZFS
	 * implements F_FREESP for interior ranges via zfs_free_range(), so
	 * this is a true hole punch there.  UFS and tmpfs only implement the
	 * l_len == 0 (truncate-to-EOF) form and return EINVAL for interior
	 * ranges; that surfaces as EINVAL, which the caller treats as
	 * unsupported (best-effort no-op).  There is no truncation risk: we
	 * never pass l_len == 0.
	 */
	MemSet(&fl, 0, sizeof(fl));
	fl.l_whence = SEEK_SET;
	fl.l_start = offset;
	fl.l_len = length;

	do
	{
		rc = fcntl(rawfd, F_FREESP, &fl);
	} while (rc < 0 && errno == EINTR);
	return rc;
#elif defined(WIN32)
	HANDLE		hFile;
	FILE_ZERO_DATA_INFORMATION zdi;
	DWORD		bytesReturned;
	DWORD		err;

	/*
	 * PG's File descriptors on Windows are CRT file descriptors wrapping
	 * Win32 HANDLEs (see pgwin32_open()); recover the HANDLE for
	 * DeviceIoControl.
	 */
	hFile = (HANDLE) _get_osfhandle(rawfd);
	if (hFile == INVALID_HANDLE_VALUE)
	{
		errno = EBADF;
		return -1;
	}

	/*
	 * FSCTL_SET_ZERO_DATA deallocates the range only when the file is
	 * marked sparse; on a non-sparse file it zero-fills and allocates
	 * storage for the whole range, the opposite of what we want.  Mark
	 * the file sparse first, best-effort: the attribute is persistent and
	 * the call is idempotent, so this costs one extra ioctl per segment
	 * at most.  If the volume has no sparse support (FAT/exFAT), fail
	 * with EOPNOTSUPP so the caller latches the filesystem as
	 * unsupported.
	 */
	if (!DeviceIoControl(hFile, FSCTL_SET_SPARSE,
						 NULL, 0, NULL, 0, &bytesReturned, NULL))
	{
		err = GetLastError();
		if (err == ERROR_INVALID_FUNCTION || err == ERROR_NOT_SUPPORTED)
			errno = EOPNOTSUPP;
		else
			_dosmaperr(err);
		return -1;
	}

	/*
	 * BeyondFinalZero is the first byte after the range, not a length.
	 * On a sparse file the filesystem may deallocate the underlying
	 * clusters; either way the range reads back as zeroes and the file
	 * size is unchanged.  (This is the same mechanism Microsoft's ESE
	 * database engine uses to return space to the filesystem.)
	 */
	zdi.FileOffset.QuadPart = (LONGLONG) offset;
	zdi.BeyondFinalZero.QuadPart = (LONGLONG) offset + (LONGLONG) length;

	if (!DeviceIoControl(hFile, FSCTL_SET_ZERO_DATA,
						 &zdi, sizeof(zdi),
						 NULL, 0, &bytesReturned, NULL))
	{
		err = GetLastError();
		if (err == ERROR_INVALID_FUNCTION || err == ERROR_NOT_SUPPORTED)
			errno = EOPNOTSUPP;
		else
			_dosmaperr(err);
		return -1;
	}
	return 0;
#else
	/*
	 * Defensive fallback, not a live no-op path: HAVE_PUNCH_HOLE (above)
	 * is defined exactly when one of the API branches above matches, so
	 * this is unreachable as long as the two stay in sync.  Kept so that a
	 * future API added to HAVE_PUNCH_HOLE without a matching branch here
	 * degrades to "unsupported" instead of falling off the end of the
	 * function.  The real no-op for platforms without any deallocation
	 * API is in mdpunchhole() below.
	 */
	(void) rawfd;
	(void) offset;
	(void) length;
	errno = EOPNOTSUPP;
	return -1;
#endif
}

/*
 * md_foreach_punch_segment() -- split a block range at segment boundaries
 *
 * Invokes callback once for each relation segment overlapped by the block
 * range [startblk, startblk + nblocks), in increasing segment order.  For
 * each segment the callback receives the first block number of the
 * sub-range, the segment number, and the byte offset and length of the
 * sub-range within that segment's file.
 *
 * The sub-ranges exactly tile the input range: they are contiguous,
 * non-overlapping, block-aligned, and each is confined to a single segment.
 * If nblocks is zero the callback is never invoked.
 *
 * This is a pure function of its arguments (it only needs RELSEG_SIZE and
 * BLCKSZ); all smgr and file-descriptor interaction happens in the
 * callback.  Keeping the splitting arithmetic separate from the syscall
 * layer makes it unit-testable, which matters here: punching the wrong
 * byte range would corrupt data.
 */
static void
md_foreach_punch_segment(BlockNumber startblk, BlockNumber nblocks,
						 void (*callback) (BlockNumber firstblock, int segno,
										   off_t seg_off, off_t seg_len,
										   void *arg),
						 void *arg)
{
	while (nblocks > 0)
	{
		BlockNumber segnoffset; /* first block's offset within its segment */
		BlockNumber segblocks;	/* # blocks of the range in this segment */

		/*
		 * Never span relation segments with a single call: each segment is
		 * a separate file.
		 */
		segnoffset = startblk % ((BlockNumber) RELSEG_SIZE);
		segblocks = Min(nblocks, ((BlockNumber) RELSEG_SIZE) - segnoffset);

		callback(startblk,
				 (int) (startblk / ((BlockNumber) RELSEG_SIZE)),
				 (off_t) BLCKSZ * segnoffset,
				 (off_t) BLCKSZ * segblocks,
				 arg);

		startblk += segblocks;
		nblocks -= segblocks;
	}
}

/* Private data threaded through md_foreach_punch_segment() to md_punch_one_segment(). */
typedef struct md_punch_cb_arg
{
	SMgrRelation reln;
	ForkNumber	forknum;
	MDPunchResult *result;		/* outcome aggregation */
	int64		min_hole_bytes;	/* minimum punch length, 0 = BLCKSZ */
} md_punch_cb_arg;

/*
 * md_punch_one_segment() -- punch the hole for one segment's sub-range
 *
 * Callback for md_foreach_punch_segment(), used by mdpunchhole().
 */
static void
md_punch_one_segment(BlockNumber firstblock, int segno,
					 off_t seg_off, off_t seg_len, void *arg)
{
	md_punch_cb_arg *cbarg = (md_punch_cb_arg *) arg;
	MdfdVec    *v;
	int			rawfd;
	BlockNumber nblocks;

	(void) segno;	/* segment identity is implicit in firstblock; exposed for unit tests */

	nblocks = (BlockNumber) (seg_len / BLCKSZ);

	/*
	 * Find the segment holding the first block, but don't create a new
	 * segment file for this best-effort operation.  (An existing segment
	 * file that isn't open yet will be opened.)
	 */
	v = _mdfd_getseg(cbarg->reln, cbarg->forknum, firstblock, false,
					 EXTENSION_RETURN_NULL);
	if (v == NULL)
	{
		/* shouldn't happen; skip this segment but try the rest */
		cbarg->result->failed_blocks += nblocks;
		return;
	}

	if (v->mdfd_punchhole_unsupported)
	{
		/* Already know this filesystem can't punch; count as unsupported. */
		cbarg->result->unsupported = true;
		return;
	}

	/*
	 * Use the raw file descriptor for the punch call.  The segment is
	 * already open, so FileGetRawDesc() will not need to do any I/O
	 * here.  Use the descriptor immediately, as nothing may close it in
	 * between.
	 */
	rawfd = FileGetRawDesc(v->mdfd_vfd);
	if (rawfd < 0)
	{
		cbarg->result->failed_blocks += nblocks;
		return;
	}

	/*
	 * Align the range inward to the filesystem block size and enforce the
	 * minimum hole size.  On most filesystems an unaligned punch silently
	 * zeroes (rather than deallocates) the partial edge blocks; on macOS
	 * APFS it fails with EINVAL.  Skipping too-small ranges avoids useless
	 * syscalls.
	 */
	{
		int64		fs_block;
		off_t		aligned_off;
		off_t		aligned_end;
		int64		effective_min;

#ifdef WIN32
		/*
		 * No fstatvfs() on Windows.  BLCKSZ (8kB) alignment is safe:
		 * NTFS/ReFS clusters are at most 64kB and typically 4kB, so an
		 * 8kB-aligned range covers whole clusters wherever deallocation
		 * is possible; a smaller cluster just means we punch a little
		 * more conservatively.
		 */
		fs_block = BLCKSZ;
#else
		struct statvfs st;

		if (fstatvfs(rawfd, &st) == 0 && st.f_bsize > 0)
			fs_block = (int64) st.f_bsize;
		else
			fs_block = BLCKSZ;	/* best we can do blind */
#endif

		/*
		 * BLCKSZ and fs_block are assumed to be powers of 2, one dividing
		 * the other.  This is not a POSIX guarantee for statvfs f_bsize,
		 * but the blast radius of a violation is benign: the byte range
		 * handed to the kernel is always correct regardless (only the
		 * nblocks counting could be off), and every byte lies within
		 * locked, verified-empty pages.
		 */
		effective_min = cbarg->min_hole_bytes > 0 ? cbarg->min_hole_bytes : BLCKSZ;
		if (effective_min < fs_block)
			effective_min = fs_block;

		aligned_off = (seg_off + fs_block - 1) / fs_block * fs_block;
		aligned_end = (seg_off + seg_len) / fs_block * fs_block;

		if (aligned_end - aligned_off < effective_min)
		{
			/* Too small to be worth punching (or nothing to punch). */
			return;
		}

		seg_off = aligned_off;
		seg_len = aligned_end - aligned_off;
		nblocks = (BlockNumber) (seg_len / BLCKSZ);
	}

	if (md_punchhole_range(rawfd, seg_off, seg_len) < 0)
	{
		if (md_punchhole_errno_unsupported(errno))
		{
			v->mdfd_punchhole_unsupported = true;
			cbarg->result->unsupported = true;
		}
		else
		{
			/* Unexpected failure; log it, but don't fail the caller. */
			ereport(LOG,
					(errcode_for_file_access(),
					 errmsg("could not punch hole in file \"%s\": %m",
							FilePathName(v->mdfd_vfd))));
			cbarg->result->failed_blocks += nblocks;
		}
	}
	else
	{
		cbarg->result->punched_blocks += nblocks;
	}
}
#endif							/* HAVE_PUNCH_HOLE */

/*
 * mdpunchhole() -- Deallocate the filesystem blocks backing a range of blocks
 *
 * Deallocates the storage for blocks that are known to read back as zeroes
 * (e.g. completely empty heap pages found by VACUUM), without changing the
 * size of the file.  A subsequent write to the range transparently
 * reallocates the storage, so this is invisible to higher layers.
 *
 * The range may span relation segments; each segment is punched with a
 * single call.  This batching is what makes punching many contiguous empty
 * pages cheap: one syscall per segment instead of one per block.
 *
 * This is strictly a best-effort space reclamation: on platforms without
 * hole-punching support, or on filesystems that don't implement it, this
 * function does nothing and never reports an error.  Segments whose
 * filesystem rejects the operation are remembered, so unsupported
 * filesystems cost a single failed syscall per segment file.
 *
 * The caller must ensure every block in the range is empty and cannot
 * concurrently gain content; e.g. vacuum punches holes in heap pages only
 * while holding a buffer lock on each page it has verified to be empty.
 *
 * This relies on the kernel implementing hole punching correctly for the
 * range given: the deallocated range must read back as zeroes without
 * disturbing adjacent blocks.  (A 2026 Linux series fixing data loss in
 * truncate_inode_partial_folio(), the generic page-cache path shared by
 * hole punching, was still unmerged at the time of writing; that is a
 * kernel bug affecting all FALLOC_FL_PUNCH_HOLE users, not something this
 * code can work around.)
 */
void
mdpunchhole(SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum,
			BlockNumber nblocks, int64 min_hole_bytes,
			MDPunchResult *result)
{
#ifdef HAVE_PUNCH_HOLE
	md_punch_cb_arg arg;

	/* Initialize result; caller may aggregate across calls. */
	result->punched_blocks = 0;
	result->failed_blocks = 0;
	result->unsupported = false;

	arg.reln = reln;
	arg.forknum = forknum;
	arg.result = result;
	arg.min_hole_bytes = min_hole_bytes;

	md_foreach_punch_segment(blocknum, nblocks, md_punch_one_segment, &arg);
#else
	/*
	 	 * No hole-punching support on this platform; silently do nothing.
	 * This is the normal path on the BSDs without a file-range
	 * deallocation API (NetBSD, OpenBSD, DragonFly).
	 */
	result->punched_blocks = 0;
	result->failed_blocks = 0;
	result->unsupported = true;
	(void) reln;
	(void) forknum;
	(void) blocknum;
	(void) nblocks;
#endif
}

/*
 * mdregistersync() -- Mark whole relation as needing fsync
 */
void
mdregistersync(SMgrRelation reln, ForkNumber forknum)
{
	int			segno;
	int			min_inactive_seg;

	/*
	 * NOTE: mdnblocks makes sure we have opened all active segments, so that
	 * the loop below will get them all!
	 */
	mdnblocks(reln, forknum);

	min_inactive_seg = segno = reln->md_num_open_segs[forknum];

	/*
	 * Temporarily open inactive segments, then close them after sync.  There
	 * may be some inactive segments left opened after error, but that is
	 * harmless.  We don't bother to clean them up and take a risk of further
	 * trouble.  The next mdclose() will soon close them.
	 */
	while (_mdfd_openseg(reln, forknum, segno, 0) != NULL)
		segno++;

	while (segno > 0)
	{
		MdfdVec    *v = &reln->md_seg_fds[forknum][segno - 1];

		register_dirty_segment(reln, forknum, v);

		/* Close inactive segments immediately */
		if (segno > min_inactive_seg)
		{
			FileClose(v->mdfd_vfd);
			_fdvec_resize(reln, forknum, segno - 1);
		}

		segno--;
	}
}

/*
 * mdimmedsync() -- Immediately sync a relation to stable storage.
 *
 * Note that only writes already issued are synced; this routine knows
 * nothing of dirty buffers that may exist inside the buffer manager.  We
 * sync active and inactive segments; smgrDoPendingSyncs() relies on this.
 * Consider a relation skipping WAL.  Suppose a checkpoint syncs blocks of
 * some segment, then mdtruncate() renders that segment inactive.  If we
 * crash before the next checkpoint syncs the newly-inactive segment, that
 * segment may survive recovery, reintroducing unwanted data into the table.
 */
void
mdimmedsync(SMgrRelation reln, ForkNumber forknum)
{
	int			segno;
	int			min_inactive_seg;

	/*
	 * NOTE: mdnblocks makes sure we have opened all active segments, so that
	 * the loop below will get them all!
	 */
	mdnblocks(reln, forknum);

	min_inactive_seg = segno = reln->md_num_open_segs[forknum];

	/*
	 * Temporarily open inactive segments, then close them after sync.  There
	 * may be some inactive segments left opened after fsync() error, but that
	 * is harmless.  We don't bother to clean them up and take a risk of
	 * further trouble.  The next mdclose() will soon close them.
	 */
	while (_mdfd_openseg(reln, forknum, segno, 0) != NULL)
		segno++;

	while (segno > 0)
	{
		MdfdVec    *v = &reln->md_seg_fds[forknum][segno - 1];

		/*
		 * fsyncs done through mdimmedsync() should be tracked in a separate
		 * IOContext than those done through mdsyncfiletag() to differentiate
		 * between unavoidable client backend fsyncs (e.g. those done during
		 * index build) and those which ideally would have been done by the
		 * checkpointer. Since other IO operations bypassing the buffer
		 * manager could also be tracked in such an IOContext, wait until
		 * these are also tracked to track immediate fsyncs.
		 */
		if (FileSync(v->mdfd_vfd, WAIT_EVENT_DATA_FILE_IMMEDIATE_SYNC) < 0)
			ereport(data_sync_elevel(ERROR),
					(errcode_for_file_access(),
					 errmsg("could not fsync file \"%s\": %m",
							FilePathName(v->mdfd_vfd))));

		/* Close inactive segments immediately */
		if (segno > min_inactive_seg)
		{
			FileClose(v->mdfd_vfd);
			_fdvec_resize(reln, forknum, segno - 1);
		}

		segno--;
	}
}

int
mdfd(SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum, uint32 *off)
{
	MdfdVec    *v = mdopenfork(reln, forknum, EXTENSION_FAIL);

	v = _mdfd_getseg(reln, forknum, blocknum, false,
					 EXTENSION_FAIL);

	*off = (pgoff_t) BLCKSZ * (blocknum % ((BlockNumber) RELSEG_SIZE));

	Assert(*off < (pgoff_t) BLCKSZ * RELSEG_SIZE);

	return FileGetRawDesc(v->mdfd_vfd);
}

/*
 * register_dirty_segment() -- Mark a relation segment as needing fsync
 *
 * If there is a local pending-ops table, just make an entry in it for
 * ProcessSyncRequests to process later.  Otherwise, try to pass off the
 * fsync request to the checkpointer process.  If that fails, just do the
 * fsync locally before returning (we hope this will not happen often
 * enough to be a performance problem).
 */
static void
register_dirty_segment(SMgrRelation reln, ForkNumber forknum, MdfdVec *seg)
{
	FileTag		tag;

	INIT_MD_FILETAG(tag, reln->smgr_rlocator.locator, forknum, seg->mdfd_segno);

	/* Temp relations should never be fsync'd */
	Assert(!SmgrIsTemp(reln));

	if (!RegisterSyncRequest(&tag, SYNC_REQUEST, false /* retryOnError */ ))
	{
		instr_time	io_start;

		ereport(DEBUG1,
				(errmsg_internal("could not forward fsync request because request queue is full")));

		io_start = pgstat_prepare_io_time(track_io_timing);

		if (FileSync(seg->mdfd_vfd, WAIT_EVENT_DATA_FILE_SYNC) < 0)
			ereport(data_sync_elevel(ERROR),
					(errcode_for_file_access(),
					 errmsg("could not fsync file \"%s\": %m",
							FilePathName(seg->mdfd_vfd))));

		/*
		 * We have no way of knowing if the current IOContext is
		 * IOCONTEXT_NORMAL or IOCONTEXT_[BULKREAD, BULKWRITE, VACUUM] at this
		 * point, so count the fsync as being in the IOCONTEXT_NORMAL
		 * IOContext. This is probably okay, because the number of backend
		 * fsyncs doesn't say anything about the efficacy of the
		 * BufferAccessStrategy. And counting both fsyncs done in
		 * IOCONTEXT_NORMAL and IOCONTEXT_[BULKREAD, BULKWRITE, VACUUM] under
		 * IOCONTEXT_NORMAL is likely clearer when investigating the number of
		 * backend fsyncs.
		 */
		pgstat_count_io_op_time(IOOBJECT_RELATION, IOCONTEXT_NORMAL,
								IOOP_FSYNC, io_start, 1, 0);
	}
}

/*
 * register_unlink_tombstone() -- Schedule a tombstone file to be deleted
 *
 * A tombstone file is an empty first segment of a relation that has already
 * been dropped (see mdunlink()).  This function schedules it to be deleted
 * after the next checkpoint.
 */
static void
register_unlink_tombstone(RelFileLocatorBackend rlocator)
{
	FileTag		tag;

	INIT_MD_FILETAG(tag, rlocator.locator, MAIN_FORKNUM, 0);

	/* Should never be used with temp relations */
	Assert(!RelFileLocatorBackendIsTemp(rlocator));

	RegisterSyncRequest(&tag, SYNC_UNLINK_REQUEST, true /* retryOnError */ );
}

/*
 * register_forget_request() -- forget any fsyncs for a relation fork's segment
 */
static void
register_forget_request(RelFileLocatorBackend rlocator, ForkNumber forknum,
						BlockNumber segno)
{
	FileTag		tag;

	INIT_MD_FILETAG(tag, rlocator.locator, forknum, segno);

	RegisterSyncRequest(&tag, SYNC_FORGET_REQUEST, true /* retryOnError */ );
}

/*
 * ForgetDatabaseSyncRequests -- forget any fsyncs and unlinks for a DB
 */
void
ForgetDatabaseSyncRequests(Oid dbid)
{
	FileTag		tag;
	RelFileLocator rlocator;

	rlocator.dbOid = dbid;
	rlocator.spcOid = 0;
	rlocator.relNumber = 0;

	INIT_MD_FILETAG(tag, rlocator, InvalidForkNumber, InvalidBlockNumber);

	RegisterSyncRequest(&tag, SYNC_FILTER_REQUEST, true /* retryOnError */ );
}

/*
 * DropRelationFiles -- drop files of all given relations
 */
void
DropRelationFiles(RelFileLocator *delrels, int ndelrels, bool isRedo)
{
	SMgrRelation *srels;
	int			i;

	srels = palloc_array(SMgrRelation, ndelrels);
	for (i = 0; i < ndelrels; i++)
	{
		SMgrRelation srel = smgropen(delrels[i], INVALID_PROC_NUMBER);

		if (isRedo)
		{
			ForkNumber	fork;

			for (fork = 0; fork <= MAX_FORKNUM; fork++)
				XLogDropRelation(delrels[i], fork);
		}
		srels[i] = srel;
	}

	smgrdounlinkall(srels, ndelrels, isRedo);

	for (i = 0; i < ndelrels; i++)
		smgrclose(srels[i]);
	pfree(srels);
}


/*
 * _fdvec_resize() -- Resize the fork's open segments array
 */
static void
_fdvec_resize(SMgrRelation reln,
			  ForkNumber forknum,
			  int nseg)
{
	if (nseg == 0)
	{
		if (reln->md_num_open_segs[forknum] > 0)
		{
			pfree(reln->md_seg_fds[forknum]);
			reln->md_seg_fds[forknum] = NULL;
		}
	}
	else if (reln->md_num_open_segs[forknum] == 0)
	{
		reln->md_seg_fds[forknum] =
			MemoryContextAlloc(MdCxt, sizeof(MdfdVec) * nseg);
	}
	else if (nseg > reln->md_num_open_segs[forknum])
	{
		/*
		 * It doesn't seem worthwhile complicating the code to amortize
		 * repalloc() calls.  Those are far faster than PathNameOpenFile() or
		 * FileClose(), and the memory context internally will sometimes avoid
		 * doing an actual reallocation.
		 */
		reln->md_seg_fds[forknum] = repalloc_array(reln->md_seg_fds[forknum], MdfdVec, nseg);
	}
	else
	{
		/*
		 * We don't reallocate a smaller array, because we want mdtruncate()
		 * to be able to promise that it won't allocate memory, so that it is
		 * allowed in a critical section.  This means that a bit of space in
		 * the array is now wasted, until the next time we add a segment and
		 * reallocate.
		 */
	}

	reln->md_num_open_segs[forknum] = nseg;
}

/*
 * Return the filename for the specified segment of the relation. The
 * returned string is palloc'd.
 */
static MdPathStr
_mdfd_segpath(SMgrRelation reln, ForkNumber forknum, BlockNumber segno)
{
	RelPathStr	path;
	MdPathStr	fullpath;

	path = relpath(reln->smgr_rlocator, forknum);

	if (segno > 0)
		sprintf(fullpath.str, "%s.%u", path.str, segno);
	else
		strcpy(fullpath.str, path.str);

	return fullpath;
}

/*
 * Open the specified segment of the relation,
 * and make a MdfdVec object for it.  Returns NULL on failure.
 */
static MdfdVec *
_mdfd_openseg(SMgrRelation reln, ForkNumber forknum, BlockNumber segno,
			  int oflags)
{
	MdfdVec    *v;
	File		fd;
	MdPathStr	fullpath;

	fullpath = _mdfd_segpath(reln, forknum, segno);

	/* open the file */
	fd = PathNameOpenFile(fullpath.str, _mdfd_open_flags() | oflags);

	if (fd < 0)
		return NULL;

	/*
	 * Segments are always opened in order from lowest to highest, so we must
	 * be adding a new one at the end.
	 */
	Assert(segno == reln->md_num_open_segs[forknum]);

	_fdvec_resize(reln, forknum, segno + 1);

	/* fill the entry */
	v = &reln->md_seg_fds[forknum][segno];
	v->mdfd_vfd = fd;
	v->mdfd_segno = segno;
	v->mdfd_punchhole_unsupported = false;

	Assert(_mdnblocks(reln, forknum, v) <= ((BlockNumber) RELSEG_SIZE));

	/* all done */
	return v;
}

/*
 * _mdfd_getseg() -- Find the segment of the relation holding the
 *					 specified block.
 *
 * If the segment doesn't exist, we ereport, return NULL, or create the
 * segment, according to "behavior".  Note: skipFsync is only used in the
 * EXTENSION_CREATE case.
 */
static MdfdVec *
_mdfd_getseg(SMgrRelation reln, ForkNumber forknum, BlockNumber blkno,
			 bool skipFsync, int behavior)
{
	MdfdVec    *v;
	BlockNumber targetseg;
	BlockNumber nextsegno;

	/* some way to handle non-existent segments needs to be specified */
	Assert(behavior &
		   (EXTENSION_FAIL | EXTENSION_CREATE | EXTENSION_RETURN_NULL |
			EXTENSION_DONT_OPEN));

	targetseg = blkno / ((BlockNumber) RELSEG_SIZE);

	/* if an existing and opened segment, we're done */
	if (targetseg < reln->md_num_open_segs[forknum])
	{
		v = &reln->md_seg_fds[forknum][targetseg];
		return v;
	}

	/* The caller only wants the segment if we already had it open. */
	if (behavior & EXTENSION_DONT_OPEN)
		return NULL;

	/*
	 * The target segment is not yet open. Iterate over all the segments
	 * between the last opened and the target segment. This way missing
	 * segments either raise an error, or get created (according to
	 * 'behavior'). Start with either the last opened, or the first segment if
	 * none was opened before.
	 */
	if (reln->md_num_open_segs[forknum] > 0)
		v = &reln->md_seg_fds[forknum][reln->md_num_open_segs[forknum] - 1];
	else
	{
		v = mdopenfork(reln, forknum, behavior);
		if (!v)
			return NULL;		/* if behavior & EXTENSION_RETURN_NULL */
	}

	for (nextsegno = reln->md_num_open_segs[forknum];
		 nextsegno <= targetseg; nextsegno++)
	{
		BlockNumber nblocks = _mdnblocks(reln, forknum, v);
		int			flags = 0;

		Assert(nextsegno == v->mdfd_segno + 1);

		if (nblocks > ((BlockNumber) RELSEG_SIZE))
			elog(FATAL, "segment too big");

		if ((behavior & EXTENSION_CREATE) ||
			(InRecovery && (behavior & EXTENSION_CREATE_RECOVERY)))
		{
			/*
			 * Normally we will create new segments only if authorized by the
			 * caller (i.e., we are doing mdextend()).  But when doing WAL
			 * recovery, create segments anyway; this allows cases such as
			 * replaying WAL data that has a write into a high-numbered
			 * segment of a relation that was later deleted. We want to go
			 * ahead and create the segments so we can finish out the replay.
			 *
			 * We have to maintain the invariant that segments before the last
			 * active segment are of size RELSEG_SIZE; therefore, if
			 * extending, pad them out with zeroes if needed.  (This only
			 * matters if in recovery, or if the caller is extending the
			 * relation discontiguously, but that can happen in hash indexes.)
			 */
			if (nblocks < ((BlockNumber) RELSEG_SIZE))
			{
				char	   *zerobuf = palloc_aligned(BLCKSZ, PG_IO_ALIGN_SIZE,
													 MCXT_ALLOC_ZERO);

				mdextend(reln, forknum,
						 nextsegno * ((BlockNumber) RELSEG_SIZE) - 1,
						 zerobuf, skipFsync);
				pfree(zerobuf);
			}
			flags = O_CREAT;
		}
		else if (nblocks < ((BlockNumber) RELSEG_SIZE))
		{
			/*
			 * When not extending, only open the next segment if the current
			 * one is exactly RELSEG_SIZE.  If not (this branch), either
			 * return NULL or fail.
			 */
			if (behavior & EXTENSION_RETURN_NULL)
			{
				/*
				 * Some callers discern between reasons for _mdfd_getseg()
				 * returning NULL based on errno. As there's no failing
				 * syscall involved in this case, explicitly set errno to
				 * ENOENT, as that seems the closest interpretation.
				 */
				errno = ENOENT;
				return NULL;
			}

			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not open file \"%s\" (target block %u): previous segment is only %u blocks",
							_mdfd_segpath(reln, forknum, nextsegno).str,
							blkno, nblocks)));
		}

		v = _mdfd_openseg(reln, forknum, nextsegno, flags);

		if (v == NULL)
		{
			if ((behavior & EXTENSION_RETURN_NULL) &&
				FILE_POSSIBLY_DELETED(errno))
				return NULL;
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not open file \"%s\" (target block %u): %m",
							_mdfd_segpath(reln, forknum, nextsegno).str,
							blkno)));
		}
	}

	return v;
}

/*
 * Get number of blocks present in a single disk file
 */
static BlockNumber
_mdnblocks(SMgrRelation reln, ForkNumber forknum, MdfdVec *seg)
{
	pgoff_t		len;

	len = FileSize(seg->mdfd_vfd);
	if (len < 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not seek to end of file \"%s\": %m",
						FilePathName(seg->mdfd_vfd))));
	/* note that this calculation will ignore any partial block at EOF */
	return (BlockNumber) (len / BLCKSZ);
}

/*
 * Sync a file to disk, given a file tag.  Write the path into an output
 * buffer so the caller can use it in error messages.
 *
 * Return 0 on success, -1 on failure, with errno set.
 */
int
mdsyncfiletag(const FileTag *ftag, char *path)
{
	SMgrRelation reln = smgropen(ftag->rlocator, INVALID_PROC_NUMBER);
	File		file;
	instr_time	io_start;
	bool		need_to_close;
	int			result,
				save_errno;

	/* See if we already have the file open, or need to open it. */
	if (ftag->segno < reln->md_num_open_segs[ftag->forknum])
	{
		file = reln->md_seg_fds[ftag->forknum][ftag->segno].mdfd_vfd;
		strlcpy(path, FilePathName(file), MAXPGPATH);
		need_to_close = false;
	}
	else
	{
		MdPathStr	p;

		p = _mdfd_segpath(reln, ftag->forknum, ftag->segno);
		strlcpy(path, p.str, MD_PATH_STR_MAXLEN);

		file = PathNameOpenFile(path, _mdfd_open_flags());
		if (file < 0)
			return -1;
		need_to_close = true;
	}

	io_start = pgstat_prepare_io_time(track_io_timing);

	/* Sync the file. */
	result = FileSync(file, WAIT_EVENT_DATA_FILE_SYNC);
	save_errno = errno;

	if (need_to_close)
		FileClose(file);

	pgstat_count_io_op_time(IOOBJECT_RELATION, IOCONTEXT_NORMAL,
							IOOP_FSYNC, io_start, 1, 0);

	errno = save_errno;
	return result;
}

/*
 * Unlink a file, given a file tag.  Write the path into an output
 * buffer so the caller can use it in error messages.
 *
 * Return 0 on success, -1 on failure, with errno set.
 */
int
mdunlinkfiletag(const FileTag *ftag, char *path)
{
	RelPathStr	p;

	/* We only unlink tombstone files through this mechanism */
	Assert(ftag->forknum == MAIN_FORKNUM && ftag->segno == 0);

	/* Compute the path. */
	p = relpathperm(ftag->rlocator, MAIN_FORKNUM);
	strlcpy(path, p.str, MAXPGPATH);

	/* Try to unlink the file. */
	return unlink(path);
}

/*
 * Check if a given candidate request matches a given tag, when processing
 * a SYNC_FILTER_REQUEST request.  This will be called for all pending
 * requests to find out whether to forget them.
 */
bool
mdfiletagmatches(const FileTag *ftag, const FileTag *candidate)
{
	/*
	 * For now we only use filter requests as a way to drop all scheduled
	 * callbacks relating to a given database, when dropping the database.
	 * We'll return true for all candidates that have the same database OID as
	 * the ftag from the SYNC_FILTER_REQUEST request, so they're forgotten.
	 */
	return ftag->rlocator.dbOid == candidate->rlocator.dbOid;
}

/*
 * AIO completion callback for mdstartreadv().
 */
static PgAioResult
md_readv_complete(PgAioHandle *ioh, PgAioResult prior_result, uint8 cb_data)
{
	PgAioTargetData *td = pgaio_io_get_target_data(ioh);
	PgAioResult result = prior_result;

	if (prior_result.result < 0)
	{
		result.status = PGAIO_RS_ERROR;
		result.id = PGAIO_HCB_MD_READV;
		/* For "hard" errors, track the error number in error_data */
		result.error_data = -prior_result.result;
		result.result = 0;

		/*
		 * Immediately log a message about the IO error, but only to the
		 * server log. The reason to do so immediately is that the originator
		 * might not process the query result immediately (because it is busy
		 * doing another part of query processing) or at all (e.g. if it was
		 * cancelled or errored out due to another IO also failing).  The
		 * definer of the IO will emit an ERROR when processing the IO's
		 * results
		 */
		pgaio_result_report(result, td, LOG_SERVER_ONLY);

		return result;
	}

	/*
	 * As explained above smgrstartreadv(), the smgr API operates on the level
	 * of blocks, rather than bytes. Convert.
	 */
	result.result /= BLCKSZ;

	Assert(result.result <= td->smgr.nblocks);

	if (result.result == 0)
	{
		/* consider 0 blocks read a failure */
		result.status = PGAIO_RS_ERROR;
		result.id = PGAIO_HCB_MD_READV;
		result.error_data = 0;

		/* see comment above the "hard error" case */
		pgaio_result_report(result, td, LOG_SERVER_ONLY);

		return result;
	}

	if (result.status != PGAIO_RS_ERROR &&
		result.result < td->smgr.nblocks)
	{
		/* partial reads should be retried at upper level */
		result.status = PGAIO_RS_PARTIAL;
		result.id = PGAIO_HCB_MD_READV;
	}

	return result;
}

/*
 * AIO error reporting callback for mdstartreadv().
 *
 * Errors are encoded as follows:
 * - PgAioResult.error_data != 0 encodes IO that failed with that errno
 * - PgAioResult.error_data == 0 encodes IO that didn't read all data
 */
static void
md_readv_report(PgAioResult result, const PgAioTargetData *td, int elevel)
{
	RelPathStr	path;

	path = relpathbackend(td->smgr.rlocator,
						  td->smgr.is_temp ? MyProcNumber : INVALID_PROC_NUMBER,
						  td->smgr.forkNum);

	if (result.error_data != 0)
	{
		/* for errcode_for_file_access() and %m */
		errno = result.error_data;

		ereport(elevel,
				errcode_for_file_access(),
				errmsg("could not read blocks %u..%u in file \"%s\": %m",
					   td->smgr.blockNum,
					   td->smgr.blockNum + td->smgr.nblocks - 1,
					   path.str));
	}
	else
	{
		/*
		 * NB: This will typically only be output in debug messages, while
		 * retrying a partial IO.
		 */
		ereport(elevel,
				errcode(ERRCODE_DATA_CORRUPTED),
				errmsg("could not read blocks %u..%u in file \"%s\": read only %zu of %zu bytes",
					   td->smgr.blockNum,
					   td->smgr.blockNum + td->smgr.nblocks - 1,
					   path.str,
					   result.result * (size_t) BLCKSZ,
					   td->smgr.nblocks * (size_t) BLCKSZ));
	}
}
