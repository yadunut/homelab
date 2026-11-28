# Storage placement and recovery

## Sites

Penguin is a separate site from `nut-gc1` and `nut-gc2`. Measurements on
2026-11-28 found roughly 189–197 ms round-trip latency between sites, versus
0.7 ms between the cloud nodes. Synchronous writes across that link delay
application I/O and make rebuilds slow.

Longhorn node tags define storage placement: `cloud` on both cloud nodes and
`penguin` on Penguin. The partial Node manifests only manage tags; disk paths,
reservations, and scheduling settings remain operational configuration.

| Storage class | Placement | Copies | Reclaim policy |
| --- | --- | --- | --- |
| `longhorn` (default) | Cloud nodes | 2 | Delete |
| `longhorn-penguin-1r` | Penguin, strict local | 1 | Retain |
| `longhorn-local-1r` | Legacy/general local volumes, best effort | 1 | Delete |

Changing a StorageClass affects newly provisioned volumes. Existing volumes
keep their own replica count and node selector. Existing active cloud volumes
were assigned the `cloud` selector; existing Penguin volumes were assigned
`penguin`. Do not adopt individual PVC-generated Longhorn Volume resources into
Flux: their lifecycle belongs to the CSI provisioner.

Keep workloads beside their state. Books, Hermes, and Harbor have required cloud
node affinity. Immich server, machine learning, and Valkey are pinned to Penguin;
its database already uses a Penguin-local volume. Valkey moved from cloud storage
to `immich-valkey-penguin`, reducing measured service PING latency from about
189 ms to 0.11 ms. PostgreSQL clusters with application-level replication use
single-copy volumes for each instance.

## Backups

`penguin-backup` runs at 00:15, 06:15, 12:15, and 18:15 UTC, retains seven
backups, and processes one volume at a time. Volumes select it using
`recurring-job-group.longhorn.io/penguin=enabled`. The Penguin StorageClass adds
this group to newly created volumes. A PVC can manage its volume's labels only
when `recurring-job.longhorn.io/source=enabled` is also present.

Backups go to the existing Garage S3 target in the cloud. That is offsite for
Penguin, but does not provide a separate geographic site for cloud workloads.
Credentials remain in the 1Password-backed `longhorn-garage-key` Secret.
The existing daily default-group backups remain enabled on legacy volumes.

Six hours is a scheduling interval, not a guaranteed recovery point: the actual
RPO is the age of the latest **completed** backup. Large initial backups and a
WAN outage can extend it. Detached volumes are not automatically attached for
scheduled backups. Monitor backup errors, last completion times, disk space,
and failed recurring Jobs. Single-copy Penguin volumes do not provide live
failover when Penguin or its disk is unavailable.

Penguin's native public IPv6 uplink was unavailable during migration. CoreDNS
uses a scoped DNS64 view for Penguin pod addresses (`fd00:10:96:2::/64`) to
route public dual-stack names through NAT64. Internal cluster and reverse DNS
retain their normal behavior. Cloud pods retain native public AAAA answers.
This workaround does not repair the host's uplink or make IPv6-only public
services reachable.

## November 2026 migration

Cloud volumes were reduced from three copies to two only after verifying two
healthy cloud replicas and a recent completed backup. Incomplete, superseded
Penguin rebuild replicas were removed after those checks. Existing unused
legacy volumes were retained.

Immich Valkey was quiesced, saved, and copied through Valkey's RDB replication
protocol. The copied RDB passed its checksum check and loaded the same 49 keys
as the quiesced source. The original `immich-valkey` PVC has Helm's `keep`
policy and remains available for rollback. It becomes stale once the new
instance accepts writes; copy the current RDB back during another quiesced
window before switching back. Never run two writable instances against one
data directory.

The new local Valkey volume was backed up to Garage and independently restored
on Penguin. `valkey-check-rdb` validated the restored checksum; the temporary
server loaded 49 unexpired keys (the backup contained 57 keys, eight expired).
The disposable restore-check volume was then removed; the backup and original
rollback PVC were retained. With Longhorn 1.11.2, a restore using `strict-local`
initially selected an incompatible node. Restore with `best-effort` and the
`penguin` replica selector, verify the data, and only change to `strict-local`
while the restored volume is detached.

Immich library is still rebuilding its local copy as of 2026-11-28 07:00 UTC.
The temporary `longhorn-system/penguin-finish-library` Job waits for both
replicas to be healthy and writable, checks the completed offsite backup is
under 24 hours old, then requests one replica with the `penguin` node selector.
It checks the resource version before changing the volume and verifies the
remaining replica is local and healthy. It has no permission to delete PVCs,
backups, or replicas, or to modify other volumes. Its deadline is 12 hours;
unmet prerequisites leave both copies in place for inspection. Existing library locality
stays `best-effort`, because switching to `strict-local` requires a detach;
the workload and replica selectors both constrain it to Penguin.

Check completion rather than assuming the migration finished:

```sh
kubectl -n longhorn-system logs job/penguin-finish-library
kubectl -n longhorn-system get job penguin-finish-library
kubectl -n longhorn-system get volumes.longhorn.io \
  pvc-08f8d7b5-d15e-4a7d-84e3-1c6b55e0c09d -o yaml
kubectl -n longhorn-system get backups.longhorn.io
```

The large Jellyfin media backup is also still running at this checkpoint.
Other migration backup retries completed after the DNS64 fix. Inspect its
completion before relying on this checkpoint for media recovery.

Migration inputs, original resources, the quiesced Valkey RDB, and the temporary
Job definition are kept privately under
`/Users/yadunut/.bb/thread-storage/penguin-site-migration/`. Earlier recovery and
the verified pre-upgrade Immich PostgreSQL dump are under
`/Users/yadunut/.bb/thread-storage/penguin-recovery/`.

After confirming the library Job completed, archive its logs and remove only
the temporary Job, ConfigMap, ServiceAccount, Role, and RoleBinding named
`penguin-finish-library`. Retain rollback PVCs and backups until their owner
explicitly retires them.

## Capacity

On `nut-gc2`, `/srv` is shared by Longhorn and Garage. Do not count those as
independent capacity pools. Longhorn's minimum free disk percentage is 15%;
nut-gc1's reserved space is 23,342,388,838 bytes (20% of its data filesystem).
Check current physical free space before restores or rebuilds; logical PVC
sizes, sparse replica allocation, backup size, and filesystem free space are
different measurements.
