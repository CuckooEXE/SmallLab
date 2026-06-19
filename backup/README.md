# Lab backups — rsync hard-link snapshots

Dead simple: every 3 hours, `rsync` the stack's `volumes/` tree into a new dated
directory. Unchanged files are **hardlinks** to the previous backup (`rsync
--link-dest`), so keeping many snapshots costs about one full copy plus the changes —
no dedup engine, no special format. Each snapshot is a plain, browsable copy.

```
DEST/
  20260619T000000/   caddy/  stepca/  technitium/  forgejo/  minio/  share/  ...
  20260619T030000/   (unchanged files hardlinked to 00:00; only deltas are new)
  20260619T060000/
  latest -> 20260619T060000
```

Recovery is just rsyncing one of those directories back, then `docker compose up`.

## The three requirements

- **No downtime.** The backup is a plain hot `rsync` — containers are never touched.
  *Caveat:* rsync reads files over a span of time, so a database being actively
  written (Forgejo's SQLite, filebrowser's BoltDB, step-ca's badger store) could be
  copied torn. These LAN services are near-idle, so the risk is small; if you want a
  guaranteed copy, set `PAUSE_CONTAINERS=1` — it briefly `docker pause`s the stack during
  the copy (a cgroup **freeze**, not a stop/restart; the containers stay up). The static
  volumes (caddy, the MinIO object store) are fine hot regardless.
- **One-command recovery.** `lab-restore.sh restore latest` rsyncs a snapshot into
  the repo's `volumes/` dir; then `docker compose up -d`.
- **Your retention curve, auto-expiring at 3 months.** Backups run every 3h;
  `lab-backup.sh` keeps the snapshot nearest each of your ages — 3h, 6h, 12h, 18h,
  1d, 2d, 3d, 4d, 5d, 1w, 2w, 4w, 1mo, 3mo — deletes the rest, and hard-deletes
  anything older than 3 months. (The exact list, not an approximation — edit
  `KEEP_AGES` in the script to change it; the prune is `prune()` in the script.)

## What's backed up

Just **`volumes/`** — every service's runtime state (step-ca's PKI, Forgejo's data +
package store, the MinIO objects, the file share, the embedded DBs). Everything else is
reproducible from git: `compose.yaml`, the per-service files under `compose/`, the scripts,
and the checked-in `config/`. Two git-ignored files are neither volumes nor in git — `.env`
(secrets) and `lab-root-ca.crt` (step-ca's exported root); keep those in a password
manager for a full rebuild.

## Setup

Runs wherever you want the backups stored — typically a **separate backup server**
that pulls from the docker host (so the host can't reach the backups), or the host
itself writing to a mounted NAS.

```bash
# 1. config
sudo install -d /etc/lab-backup
sudo cp backup/config.env.example /etc/lab-backup/config.env
sudoedit /etc/lab-backup/config.env          # set SRC, DEST, SSH_RSH

# 2. if pulling over ssh: give this box a key the docker host trusts
ssh-keygen -t ed25519 -f /root/.ssh/lab-backup -N ''
ssh-copy-id -i /root/.ssh/lab-backup root@dockerhost.lab   # needs root to read volumes

# 3. schedule it
sudo install -m755 backup/lab-backup.sh   /opt/lab-backup/lab-backup.sh
sudo install -m755 backup/lab-restore.sh  /opt/lab-backup/lab-restore.sh
sudo cp backup/systemd/lab-backup.* /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now lab-backup.timer

# 4. test
sudo /opt/lab-backup/lab-backup.sh
/opt/lab-backup/lab-restore.sh list
```

Prefer cron? One line does the same as the timer:

```cron
0 */3 * * *  LAB_BACKUP_CONFIG=/etc/lab-backup/config.env /opt/lab-backup/lab-backup.sh >> /var/log/lab-backup.log 2>&1
```

## Restore / disaster recovery

```bash
./backup/lab-restore.sh list                        # pick a snapshot (or 'latest')
# onto THIS host's volumes (stop the stack first if it's running):
sudo ./backup/lab-restore.sh restore latest --target /opt/lab/volumes
# or push to a brand-new host before its first `up`:
./backup/lab-restore.sh restore latest --to root@newhost:/opt/lab/volumes
docker compose up -d && ./bootstrap.sh
```

The whole `volumes/` tree comes back exactly — same paths, perms and UIDs — so
`docker compose up` bind-mounts it straight back in. Add `--force` to skip the
overwrite prompt. (`/opt/lab` here = wherever the repo is checked out on that host;
the default target is `RESTORE_TARGET` from the config.)

## Notes

- `DEST` should be on a different machine/disk than the docker host — a hardlink farm
  on the same dying disk isn't a backup. The common setup is the pull model in step 2.
- `rsync --numeric-ids` preserves container UIDs across hosts; `-aH` preserves perms
  and any hardlinks inside a volume.
- **Test a restore now and then.** A backup you've never restored isn't a backup.
- Want off-site too? Point a second timer at `rsync -aH DEST/ user@offsite:/backups/`
  or `rclone sync DEST remote:lab`.

## Files

| File | Purpose |
|------|---------|
| `lab-backup.sh`      | the 3-hourly rsync snapshot + retention prune |
| `lab-restore.sh`     | `list` and `restore` |
| `config.env.example` | `SRC` / `DEST` / `RESTORE_TARGET` / `SSH_RSH` / pause toggle |
| `systemd/*`          | the every-3-hours timer |
