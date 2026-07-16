## check problem
```
# ceph osd df
ID CLASS  WEIGHT REWEIGHT    SIZE RAW USE    DATA    OMAP    META    AVAIL %USE  VAR PGS STATUS
 0   hdd 5.45659  1.00000 5.5 TiB 6.5 GiB 6.5 GiB  10 KiB  38 MiB  5.5 TiB 0.12 0.83 177     up
 1   hdd 5.45659        0     0 B     0 B     0 B     0 B     0 B      0 B    0    0   0   down
 2   hdd 5.45659        0     0 B     0 B     0 B     0 B     0 B      0 B    0    0   0   down
 3   hdd 5.45659        0     0 B     0 B     0 B     0 B     0 B      0 B    0    0   0   down
 4   hdd 5.45659  1.00000     0 B     0 B     0 B     0 B     0 B      0 B    0    0   0   down
 5   hdd 5.45659  1.00000     0 B     0 B     0 B     0 B     0 B      0 B    0    0   0   down
 8   hdd 5.45659  1.00000 5.5 TiB 9.6 GiB 9.6 GiB   3 KiB  36 MiB  5.4 TiB 0.17 1.23 176     up
 9   hdd 5.45659  1.00000 5.5 TiB 6.9 GiB 6.9 GiB   6 KiB  26 MiB  5.4 TiB 0.12 0.89 150     up
 6   ssd 1.74619  1.00000 1.7 TiB 3.0 GiB 3.0 GiB   5 KiB 6.9 MiB  1.7 TiB 0.17 1.22  50     up
 7   ssd 1.74619  1.00000 1.7 TiB 2.3 GiB 2.3 GiB   4 KiB 6.6 MiB  1.7 TiB 0.13 0.93  46     up
            TOTAL  20 TiB  28 GiB  28 GiB  31 KiB 114 MiB   20 TiB 0.14
MIN/MAX VAR: 0/1.23  STDDEV: 0.08
```

## check fsid of osd
```
# ceph-osd -i 0 --get-osd-fsid --osd-data /var/lib/ceph/osd/ceph-0
00000000-0000-0000-0000-000000000000
```

## use the tools
```
=== Processing OSD.0 ===
Warning: OSD FSID mismatch for OSD.0. Expected: 50d54392-9c13-491b-a55c-18acf74cd948, Found: 00000000-0000-0000-0000-000000000000
Failed to reset failed state of unit ceph-osd@0.service: Unit ceph-osd@0.service not loaded.
OSD.0 has been successfully activated and brought online.
------------------------------------
=== Processing OSD.2 ===
OSD FSID matches for OSD.2. nothing to do.
=== Final OSD Status in 10 seconds (ceph osd df) ===
```