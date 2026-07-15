# SmallLab backups — rsync hard-link snapshots

Every 3 hours, `rsync` copies the stack's `volumes/` tree into a new dated directory. Unchanged
files are hardlinked to the previous snapshot (`rsync --link-dest`), so many snapshots cost
about one full copy plus the deltas — no dedup engine, no special format. Each snapshot is a
plain, browsable copy; recovery is one rsync back, then `docker compose up`.

```
DEST/
  20260619T000000/   caddy/  stepca/  technitium/  gitlab/  minio/  share/  ...
  20260619T030000/   (unchanged files hardlinked to 00:00; only deltas are new)
  latest -> 20260619T030000
```

## How it works

- **Hot by default.** Containers are never touched. A DB written mid-copy (GitLab's or
  Mattermost's Postgres, filebrowser's BoltDB, step-ca's badger store) could be copied torn;
  these LAN services are near-idle, so the risk is small. Set `PAUSE_CONTAINERS=1` for a
  guaranteed copy — it briefly `docker pause`s the stack (a cgroup freeze, not a stop/restart).
- **Retention.** Keeps the snapshot nearest each of: 3h, 6h, 12h, 18h, 1d, 2d, 3d, 4d, 5d, 1w,
  2w, 4w, 1mo, 3mo; deletes the rest; hard-deletes anything older than 3 months. Edit
  `KEEP_AGES` in `lab-backup.sh` to change it.
- **One-command recovery.** `lab-restore.sh restore latest` rsyncs a snapshot back into a
  `volumes/` dir.

## What's backed up

Just `volumes/` — every service's runtime state (step-ca's PKI, GitLab's and Mattermost's data,
MinIO objects, the file share, the embedded DBs). Everything else is reproducible from git.
`.env` and `lab-root-ca.crt` are neither volumes nor in git — keep them in a password manager.

## Setup

Runs on a separate backup server that pulls from the docker host (so the host can't reach the
backups), or on the host writing to a mounted NAS. The two-server walkthrough is in
[`../README.md`](../README.md#backup-server); in short:

```bash
sudo install -d /etc/lab-backup
sudo cp backup/config.env.example /etc/lab-backup/config.env
sudoedit /etc/lab-backup/config.env          # set SRC, DEST, SSH_RSH, RESTORE_TARGET
sudo install -m755 backup/lab-backup.sh   /opt/lab-backup/lab-backup.sh
sudo install -m755 backup/lab-restore.sh  /opt/lab-backup/lab-restore.sh
sudo cp backup/systemd/lab-backup.* /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now lab-backup.timer
sudo /opt/lab-backup/lab-backup.sh           # prove it works
```

Cron equivalent of the timer:

```cron
0 */3 * * *  LAB_BACKUP_CONFIG=/etc/lab-backup/config.env /opt/lab-backup/lab-backup.sh >> /var/log/lab-backup.log 2>&1
```

## Restore

```bash
./backup/lab-restore.sh list                        # pick a snapshot (or 'latest')
sudo ./backup/lab-restore.sh restore latest --target /opt/lab/volumes   # onto this host (stop the stack first)
./backup/lab-restore.sh restore latest --to root@newhost:/opt/lab/volumes   # push to a new host
docker compose up -d && ./bootstrap.sh
```

The tree comes back with the same paths, perms, and UIDs (`rsync -aH --numeric-ids`), so the
stack mounts it straight back in. `--force` skips the overwrite prompt.

## Notes

- `DEST` should be on a different machine/disk than the docker host — a hardlink farm on the
  same dying disk isn't a backup.
- Test a restore now and then; a backup you've never restored isn't a backup.
- Off-site: point a second timer at `rsync -aH DEST/ user@offsite:/backups/` or
  `rclone sync DEST remote:lab`.

## Files

| File | Purpose |
|------|---------|
| `lab-backup.sh`      | the 3-hourly rsync snapshot + retention prune |
| `lab-restore.sh`     | `list` and `restore` |
| `config.env.example` | `SRC` / `DEST` / `RESTORE_TARGET` / `SSH_RSH` / pause toggle |
| `systemd/*`          | the every-3-hours timer |
