# wip-mirror

`wip-mirror.sh` creates a private-remote snapshot of the current repository
contents without changing the source branch, working tree, index, HEAD, or
stash. It is an early, manually invoked proof—not an installable Pado product.

## Current scope

- One Git repository and one named remote per invocation.
- GitHub push destinations only. Every effective `pushurl` must be confirmed
  private and writable through the GitHub API and explicitly approved in the
  source repository's `pado.approvedRemote` configuration.
- Modified, staged, and untracked files are included; `.gitignore` is honored.
- Restore is a manual fetch and checkout into an empty repository or disposable
  worktree.

Scheduling, repository discovery, retention, quota validation, organization
policy validation, and a restore command are not implemented.

## Safety boundary

The script stops before sending a snapshot unless all of these checks pass:

1. It resolves and validates every effective push URL, rather than trusting the
   fetch URL. Unsupported providers, public/internal repositories, missing API
   results, missing push access, URL credentials, and unapproved URLs all stop.
2. It builds the immutable Git tree first and scans the exact blobs that would
   be pushed. Sensitive filenames, common credential patterns, external Git
   filters, and Git LFS pointers stop the run.
3. It sends a harmless, empty root commit to a unique probe ref and requires
   successful probe cleanup.
4. It creates the snapshot as a synthetic root commit. Local `HEAD` and its
   history are never parents of the uploaded snapshot.

The pattern-based secret gate is a secondary defense and cannot recognize every
secret. Explicit destination approval remains required. Logs omit destination
URLs, filenames, and secret values and are written with owner-only permissions.
Outbound Git objects are copied into an isolated temporary repository, and
repository pre-push hooks are skipped. Every write uses the exact URL that was
validated rather than resolving the remote name again.

The successful snapshot is stored at:

```text
refs/pado-wip/<host>/<branch>
```

Each invocation replaces that ref. Ordinary branch listings and clones do not
fetch it automatically.

## Use

Review the effective destination first:

```sh
git remote get-url --push --all origin
```

After independently confirming that each URL is an acceptable private GitHub
destination, approve each exact URL in the source repository:

```sh
git config --add pado.approvedRemote '<exact-push-url>'
```

Then run:

```sh
./wip-mirror.sh <repo-path> [remote-name]
```

Exit codes are `0` for mirrored, `3` for a failed safety precondition, `4` for
the secret gate, and `1` for another error.

## Restore

Use an empty repository or disposable worktree so restoration cannot overwrite
active work:

```sh
git fetch <remote> 'refs/pado-wip/<host>/<branch>'
git checkout FETCH_HEAD
```

Git preserves file contents and executable bits. It does not preserve mtimes,
extended attributes, ACLs, or ignored files.

## Offline proof

```sh
./proof.sh
```

The proof creates only synthetic repositories and values under the ignored
`run/` directory. It never calls GitHub or uses a real credential, remote, host
inventory, or development repository. Its checks cover:

- unknown/public/unapproved destinations and mismatched push URLs;
- a test bypass restricted to the local harness;
- source state invariance and byte-identical content restoration;
- ignored, staged, untracked, unusual-name, and subdirectory cases;
- exact-tree secret blocking without value logging;
- external-filter and Git LFS rejection before hooks or remote writes;
- GitHub API host pinning and validation-to-push destination binding;
- local-history exclusion, repeat snapshots, and unborn repositories;
- unique probe cleanup, URL-credential redaction, and private log permissions.
