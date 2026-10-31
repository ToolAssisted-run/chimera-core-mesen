/* guest-syscalls.c - the system calls Mesen makes that the sandbox does not
 * provide, answered in the guest. Compiled into core.wbx only.
 *
 * mkdir: Mesen makes sure its folders exist (FolderUtilities::CreateFolder,
 * called whenever it asks for the firmware or save folder). A core's files
 * are the ones the frontend mounts, and nothing is created: the folder is
 * refused as on a read-only disk, which CreateFolder ignores.
 */
#include <errno.h>
#include <sys/stat.h>

int mkdir(const char *path, mode_t mode)
{
	(void)path;
	(void)mode;
	errno = EROFS;
	return -1;
}
