# CubeCOS Root Git Commit SOP

Record a manual change on the root (`/`) git repo, push it, and sync every node to it.

> Run on the **control node** where you made the change.
> The repo lives at `/`. Run from `/`, not from a subdirectory like `/mnt`.
> If you don't, git fails with `fatal: not a git repository`.

## 1. Commit and push

```bash
cd /
git add -A
git commit -m "001 appctl 4eaec97 ROLLBACK=No fix appfw offline install Installed"
git push
```

### Commit message format

```text
<FIXPACK_ID> <FIXPACK_NAME> ROLLBACK=<Yes|No> <DESCRIPTION> Installed
```

| Field | Example |
| :-- | :-- |
| `FIXPACK_ID` | `001` |
| `FIXPACK_NAME` | `appctl 4eaec97` |
| `ROLLBACK` | `No` |
| `DESCRIPTION` | `fix appfw offline install` |
| suffix | `Installed` |

## 2. Sync all nodes

```bash
hex_sdk cmd -v "git fetch --all"
hex_sdk cmd -v "git reset --hard cube/master"
```

> **Warning:** `git reset --hard` throws away uncommitted changes to tracked files on **every node**.
> Commit and push step 1 first.

## 3. Verify

```bash
hex_sdk cmd -v "git log -1"
```

Every node should print the commit from step 1.

---

See also: `bigstack-handbook/kb/cubecos/known-issues/fixpack-git-stash-discards-hotfix.md`. That issue happened because a hotfix was never committed, and the next sync reverted it.
