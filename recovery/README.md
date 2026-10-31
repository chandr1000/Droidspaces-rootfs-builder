# Unlock recovery kit — original immutable-root code (v4)

Byte-identical backup of the FCOS-style immutable-root / unlock tooling as
shipped in release `v20261031-023351` (template commit `133934e`). Keep this
directory in the repo permanently: the immutable-root feature is on a
multi-week test window, and once it is gated from the runtime and the image,
**this is the single source to restore the unlock functionality from** — and
the fastest way to find out what happened if a shipped rootfs image ever
boots wrong.

Nothing in this directory is copied into the image; the Dockerfile does not
reference `recovery/`. It is repo-only.

## Why this exists

| Scenario | What you need | Where |
| --- | --- | --- |
| Image ships fine, need to write under `/usr` | `ds-unlock` / `ds-lock` | already in the image |
| Image misbehaves after shipping | diagnosis checklist | this file, below |
| Unlock tooling missing/damaged on a running system | `install-unlock.sh` | this directory |
| Unlock paths removed from future images (gating) | the original files | this directory |

Provenance: extracted verbatim from the `cat > ... <<'MARKER'` heredocs in
`templates/aarch64/Fedora-CoreOS.Dockerfile` (section 9) at commit `133934e`,
so `diff` against the files inside a flashed `v20261031-023351` image must
report no differences. If the template ever drifts (gating, rework), the
copies here stay frozen at the last battle-tested version.

## Inventory

| Backup file | In-image location | Purpose |
| --- | --- | --- |
| `ds-ro-root` | `/usr/local/sbin/ds-ro-root` | boot-time `pivot_root` into a read-only bind-clone of `/`; re-binds `/etc /var /root /home /tmp` (and `/usr`, read-only) on top. Fail-soft: any failure is only logged, root stays writable. Idempotent. |
| `ds-unlock` | `/usr/local/sbin/ds-unlock` | make `/usr` writable for this boot (`mount -o remount,rw,bind /usr`) |
| `ds-lock` | `/usr/local/sbin/ds-lock` | re-apply read-only `/usr` |
| `ds-ro-root.service` | `/etc/systemd/system/ds-ro-root.service` | oneshot unit, `Before=docker.service sshd.service`, skipped when `/etc/ds/immutability-off` exists |
| `etc-ds-README` | `/etc/ds/README` | documents the opt-out switch inside the image |
| `install-unlock.sh` | — | reinstalls all of the above (see below) |

## Ship-sanity checklist (did the new image ship right?)

Run inside the container after flashing a new rootfs release:

1. `findmnt /` → one single read-only mount (`ro`), e.g. a loop device.
2. `touch /should-fail` → `Read-only file system`, and the file does not exist.
3. `systemctl status ds-ro-root.service` → `active (exited)`;
   `journalctl -u ds-ro-root.service` → ends with
   `root pivoted read-only (FCOS-style); writable: /etc /var /root /home /tmp`.
4. Whitelist works: writing to `/etc`, `/var`, `/root`, `/home`, `/tmp` succeeds;
   `/usr` is read-only until `sudo ds-unlock`.
5. Docker unaffected: `docker run --rm hello-world`, and a published port
   (`-p 8080:80`) still answers from the PC.

Known-benign journal signatures (not failures):

- `WARNING: old rw root still visible under /run/ds-old` — cosmetic; a
  container restart clears it.
- `whitelist bind failed: /<dir>` — that one directory stays read-only for
  this boot; everything else is enforced normally. If you see it for a dir
  you care about, `sudo ds-unlock` does not help that dir (it only covers
  `/usr`); restart the container first, then investigate.

Real trouble looks like: unit `failed`, or journal shows
`pivot_root failed: ...` / `stage ro flip failed` — then the root silently
stayed writable (fail-soft), which the checklist in step 2 will confirm.
The journal line names the exact step that failed.

## Restoring the unlock functionality

Escalating paths; start at the top.

**0. Escape hatches (already inside every v4 image)**

```sh
sudo ds-unlock                              # /usr writable, this boot only
sudo ds-lock                                # re-lock /usr
sudo touch /etc/ds/immutability-off         # feature off from next boot on
# restart the container (Droidspaces app)   # -> fully writable root
sudo rm /etc/ds/immutability-off            # re-enable, restart again
```

`/etc` is on the writable whitelist, so the switch file can always be
created — even with the immutable root fully active.

**1. Unlock tooling missing or damaged on a running system**

Copy this directory to the device and run the installer (it first unlocks
`/usr` with the original one-liner, then reinstalls everything):

```sh
# from the PC: scp -r recovery/ <akari-container>:/tmp/recovery
cd /tmp/recovery && sudo ./install-unlock.sh
```

**2. Bare rootfs tree** (rootfs extracted/mounted on a PC, or chroot target):

```sh
sudo ./install-unlock.sh --root /mnt/rootfs
```

**3. Put the feature back into the image template** (e.g. after a gating
commit): restore section 9 of `templates/aarch64/Fedora-CoreOS.Dockerfile`
from these files (or `git revert` the gating commit), keep
`ds-ro-root.service` in the enable list of section 11, rebuild via
Actions → *Build and Release Droidspaces RootFS* → *Run workflow* on
`akari-build`. The release is cut and `rootfs.json` is regenerated
automatically; flash the new asset.

**4. Worst case:** re-flash the previous release asset that was known good
(e.g. `v20261030-231329`, the last pre-immutability build) and rebuild
`rootfs.json` from the matching commit.

## Appendix — ground-truth manual recipe

Works from any root shell with zero script files present. This is the
sequence validated live on akari (Redmi Note 15 5G, GKI kernel) on
2026-10-31; the scripts are a faithful wrapper around it.

```sh
# Apply the FCOS-style read-only root (ro: / and /usr; rw: /etc /var /root /home /tmp)
mount --make-rprivate /
S=/run/.ds-stage
mkdir -p "$S"
mount --rbind / "$S"
mkdir "$S/run/ds-old"
mount -o remount,ro,bind "$S"
for d in etc var root home tmp; do mount --rbind "/$d" "$S/$d"; done
mount --rbind /usr "$S/usr"
mount -o remount,ro,bind "$S/usr"
pivot_root "$S" "$S/run/ds-old"
umount -l /run/ds-old

# Unlock / re-lock /usr
mount -o remount,rw,bind /usr
mount -o remount,ro,bind /usr
```

Two hard-won notes for whoever has to debug this at 3 a.m.:

- A plain **overmount** (`rbind / /run/.ds-stage` + `remount,ro,bind` on top
  of `/`) is **not** sufficient: the namespace root mount is pinned beneath
  the clone, so absolute-path resolution never crosses the read-only layer —
  `touch /should-fail` still succeeds. Only `pivot_root` (which rewrites the
  ns root for every process, `chroot_fs_refs`) actually enforces.
- A process whose **cwd already sits inside `/usr` before the pivot** keeps
  a writable view via relative paths for its lifetime. Absolute-path access
  (dnf, systemd, fresh shells, new sessions) is fully blocked.
