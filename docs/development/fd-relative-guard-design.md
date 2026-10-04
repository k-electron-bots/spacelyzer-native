# Design note: fd-relative guard before Trash (proposal, not built)

Status: design only. Nothing here is implemented, compiled on macOS, or reviewed by a verifier. It does not claim an atomic Trash.

## What exists now
`spz_tree_check_identity` compares the live item (dev, ino, kind class) with the identity the scan recorded and refuses a replaced, missing, lossy-named or symlink-ancestor item. It reads by path, so the path can change between the check and the Trash call. It narrows the window. It does not close it.

## Remaining holes, stated plainly
- Time of check to time of use between the check and the Trash call, and inside Trash itself.
- The scan root and its own ancestors are taken as given.
- An inode number can be reused after delete. dev/ino/kind cannot tell a reused inode from the original.
- Names that the scanner stored lossily (U+FFFD) cannot be addressed and are refused.
- A hard link has several names. The scan identity says which inode, not which name was meant.

## Proposal to evaluate
1. Open the scan root once with `open(O_RDONLY | O_DIRECTORY)` and keep that fd for the whole review session.
2. For each path component below the root, `openat(parent_fd, name, O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)`. A symlink in any component fails with ELOOP, which closes the ancestor-swap hole for the opened chain.
3. `fstatat(parent_fd, leaf, &st, AT_SYMLINK_NOFOLLOW)`, then compare dev/ino/kind to the scanned identity. This ties the check to the parent fd rather than to a path string that can be re-resolved.
4. Hold the parent fd (and the leaf's fd where possible) until the action is done, so the inode of the parent cannot be reused while it is open.
5. Action: whether the Trash API can act relative to a directory fd is UNKNOWN. `NSFileManager.trashItem(at:resultingItemURL:)` takes a URL, which re-resolves the path. `renameat` into a private staging directory on the same volume is fd-relative, but moving to the Trash by hand loses Finder's Put Back metadata and may not be allowed for the sandbox/permissions in use. Both need a real-Mac experiment before any claim.

## Fail-closed rules
Refuse and show the user why on any of: ELOOP, ENOENT, ENOTDIR, dev/ino/kind mismatch, no scanned identity, lossy name, EACCES/EPERM, or any unexpected errno. Never fall back to path-based Trash silently after an fd step failed.

## Open questions for review
- Can the final step be made fd-relative on macOS without losing Put Back? If not, the honest wording stays "checked immediately before, not atomic".
- Is the 32-bit dev compare on macOS sufficient (bulk dev_t vs lstat st_dev)? The Swift fixture check `engine-scanned-identity-matches-lstat-on-fixture` is written but unrun.
- Do APFS clones, firmlinks (/System/Volumes/Data) or multiple volumes break dev/ino assumptions? Unmeasured.
- What does the user see for an item that changed after review: a refusal with the reason, never a silent skip.

## Not claimed
No atomicity, no safety against a hostile local process, no protection of the scan root's ancestors, no Mac behavior.
