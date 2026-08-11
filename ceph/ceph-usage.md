## Example
```
CEPH STORAGE SUMMARY
Generated: 2026-08-11T13:54:10+08:00
Host: ak-cosct02p

CRUSH ROOT LAYOUT
=================
default
  └── ak-cosst01p
        └── HDD osds_id:(104,105,110,111,116,117,118,119,120,121,122,123,124,125,126,127,128,129,130,131,132,133,134,135,136,137,138,139,141,142,143,144,145,146,147,148,149,150,151,152,153,154,155,156,157,158,381,382,383,384)
        └── SSD osds_id:(96,97,98,99,100,101,102,103,106,107,108,109,112,113,114,115,159,160,161,162)
  └── ak-cosst02p
        └── HDD osds_id:(175,177,189,193,207,211,215,216,220,223,227,231,234,237,241,245,248,251,252,256,258,261,264,267,270,273,276,279,282,285,288,292,295,298,301,304,307,310,313,316,319,322,325,328,331,335,338,341,344,347,350,353)
        └── SSD osds_id:(163,164,165,166,167,168,169,170,171,173,180,182,184,186,196,199,356,358,374,375)
  └── ak-cosst03p
        └── HDD osds_id:(140,188,191,206,210,224,228,230,233,236,239,243,247,250,254,257,260,263,265,268,271,274,277,281,283,287,290,293,296,299,303,306,309,312,315,318,321,324,327,330,333,336,339,342,345,348,351,354,357,376)
        └── SSD osds_id:(172,174,176,178,179,181,183,185,194,197,200,203,214,217,219,221,360,362,363,365)
  └── ak-cosst04p
        └── HDD osds_id:(213,218,232,235,246,249,253,255,259,262,266,269,272,275,278,280,284,286,289,291,294,297,302,305,308,311,314,317,320,323,326,329,332,334,337,340,343,346,349,352,355,359,361,364,366,367,368,369,377,378,379,380)
        └── SSD osds_id:(187,190,192,195,198,201,204,208,209,212,222,225,226,229,238,240,242,244,370,371)

computessd
  └── ak-coscp01p-ssd
        └── SSD osds_id:(12,13,14,15)
  └── ak-coscp02p-ssd
        └── SSD osds_id:(28,29,30,31)
  └── ak-coscp03p-ssd
        └── SSD osds_id:(44,45,46,47)
  └── ak-coscp04p-ssd
        └── SSD osds_id:(48,49,62,63)
  └── ak-coscp05p-ssd
        └── SSD osds_id:(64,65,78,79)
  └── ak-coscp06p-ssd
        └── SSD osds_id:(92,93,94,95)

computehdd
  └── ak-coscp01p
        └── HDD osds_id:(0,1,2,3,4,5,6,7,8,9,10,11)
  └── ak-coscp02p
        └── HDD osds_id:(16,17,18,19,20,21,22,23,24,25,26,27)
  └── ak-coscp03p
        └── HDD osds_id:(32,33,34,35,36,37,38,39,40,41,42,43)
  └── ak-coscp04p
        └── HDD osds_id:(50,51,52,53,54,55,56,57,58,59,60,61)
  └── ak-coscp05p
        └── HDD osds_id:(66,67,68,69,70,71,72,73,74,75,76,77)
  └── ak-coscp06p
        └── HDD osds_id:(80,81,82,83,84,85,86,87,88,89,90,91)

RBD BACKEND IMAGE COUNTS
========================
POOL                  IMAGE COUNT   NODEGROUP
cinder-volumes                 78   default~hdd
ephemeral-vms                  20   computessd~ssd
manila-volumes                  4   computehdd
glance-images                  28   default~hdd

NON-EMPTY POOLS
===============
POOL                                          STORED       PHYSICAL     NODEGROUP    POLICY     OBJECTS
.rgw.root                                     1.30 KiB     1.30 KiB     default~hdd  replica-3  4
default.rgw.log                               1.31 MiB     1.31 MiB     default~hdd  replica-3  214
default.rgw.meta                              3.66 KiB     3.66 KiB     default~hdd  replica-3  17
default.rgw.buckets.index                     1.32 MiB     1.32 MiB     default~hdd  replica-3  33
cachepool                                     670.91 GiB   670.91 GiB   default~ssd  replica-2  337125
cephfs_data                                   215.16 GiB   215.16 GiB   default~hdd  replica-3  56005
cephfs_metadata                               258.79 MiB   258.79 MiB   default~ssd  replica-3  159
ephemeral-vms                                 218.76 GiB   218.76 GiB   computessd~ssd replica-2  196300
glance-images                                 375.54 GiB   375.54 GiB   default~hdd  replica-3  48185
.mgr                                          203.31 MiB   203.31 MiB   default~hdd  replica-3  52
default.rgw.buckets.data                      89.82 MiB    89.82 MiB    default      EC:ec-543099e2-3-2 4562
manila-volumes                                158.13 MiB   158.13 MiB   computehdd   replica-3  17541

CRUSH ROOT CAPACITY SUMMARY
===========================
- computehdd (total: 58.92 TiB, used: 11.27 GiB, available: 58.91 TiB, used: 0.02%)
- default (total: 785.85 TiB, used: 2.77 TiB, available: 783.08 TiB, used: 0.35%)
- computessd (total: 10.47 TiB, used: 370.72 GiB, available: 10.11 TiB, used: 3.46%)

RAW USAGE RECONCILIATION
========================
ROOT             TOTAL SIZE       RAW USED       RESERVED       METADATA    ACTUAL DATA      AVAILABLE  REPLICATE    THEORETICAL CEPH MAX AVAIL
computehdd        58.92 TiB      11.27 GiB      11.11 GiB     936.27 MiB     158.13 MiB      58.91 TiB          3      19.64 TiB      18.65 TiB
default          785.85 TiB       2.77 TiB       1.54 TiB       4.55 GiB       1.23 TiB     783.08 TiB          3     261.03 TiB     233.30 TiB
computessd        10.47 TiB     370.72 GiB     151.96 GiB     965.67 MiB     218.76 GiB      10.11 TiB          2       5.05 TiB       4.56 TiB
TOTAL            855.24 TiB       3.14 TiB       1.70 TiB       6.41 GiB       1.45 TiB     852.09 TiB          -     285.72 TiB     256.52 TiB

Formulas:
  RAW USED - RESERVED = ACTUAL DATA
  TOTAL SIZE - RAW USED = AVAILABLE
  AVAILABLE / REPLICATE = THEORETICAL
Reserved is raw OSD usage not attributed to pools by bytes_used.
METADATA is Ceph-reported OSD metadata and is included within RESERVED.
CEPH MAX AVAIL is the representative backend pool max_avail from ceph df.
```