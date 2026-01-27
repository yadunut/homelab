# Cluster Storage

This document summarizes total storage capacity by node and storage system.
All numbers are totals or configured allocations, not current usage.

## Nodes

| Node | Roles | Root filesystem size (GiB) | Root filesystem size (TiB) |
| --- | --- | --- | --- |
| nut-gc1 | ingress | 108.70 | 0.11 |
| nut-gc2 | ingress | 54.82 | 0.05 |
| penguin | none | 1862.75 | 1.82 |
| premhome-falcon-1 | none | 293.75 | 0.29 |

## Longhorn (distributed block storage)

Longhorn capacity is based on `storageMaximum` from Longhorn node status.

| Node | Disk path | Filesystem size (GiB) | Filesystem size (TiB) | Longhorn storageMaximum (GiB) | Longhorn storageMaximum (TiB) |
| --- | --- | --- | --- | --- | --- |
| nut-gc1 | `/var/lib/longhorn` | 108.70 | 0.11 | 108.70 | 0.11 |
| nut-gc2 | `/srv/longhorn` | 4030.62 | 3.94 | 4030.62 | 3.94 |
| penguin | `/var/lib/longhorn` | 1862.75 | 1.82 | 1862.75 | 1.82 |
| premhome-falcon-1 | `/var/lib/longhorn` | 293.75 | 0.29 | 293.75 | 0.29 |

Total Longhorn storageMaximum: 6295.81 GiB (6.15 TiB)

Notes:
- On nut-gc1, penguin, and premhome-falcon-1, the Longhorn disk path lives on `/`, so the filesystem size matches the root filesystem size.
- On nut-gc2, the Longhorn disk path lives on `/srv`, which is shared with Garage. Do not sum those totals together.

## Garage (S3-compatible object store)

Garage runs on `nut-gc2` and stores data under `/srv/garage/data`.

| Host | Data path | Filesystem mount | Filesystem size (GiB) | Filesystem size (TiB) |
| --- | --- | --- | --- | --- |
| nut-gc2 | `/srv/garage/data` | `/srv` | 4030.62 | 3.94 |

Notes:
- The Garage data path and Longhorn disk path share the same `/srv` filesystem on nut-gc2.
