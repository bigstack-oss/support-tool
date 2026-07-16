## check problem
```
# ceph osd df
ID  CLASS  WEIGHT   REWEIGHT  SIZE     RAW USE  DATA     OMAP     META     AVAIL    %USE   VAR   PGS  STATUS
 0    ssd  0.21790         0      0 B      0 B      0 B      0 B      0 B      0 B      0     0    0    down
 1    ssd  0.21790   1.00000  223 GiB  155 GiB  154 GiB  166 KiB  266 MiB   69 GiB  69.28  1.14  174      up
 2    ssd  0.21790   1.00000  223 GiB  165 GiB  165 GiB  767 KiB  126 MiB   58 GiB  74.05  1.22  168      up
 3    ssd  0.21790   1.00000  223 GiB  144 GiB  143 GiB  1.1 MiB  227 MiB   79 GiB  64.39  1.06  164      up
 4    ssd  0.43629   1.00000  447 GiB  286 GiB  286 GiB  2.1 MiB  438 MiB  161 GiB  64.05  1.06  337      up
 5    ssd  0.43629   1.00000  447 GiB  281 GiB  281 GiB  1.1 MiB  421 MiB  166 GiB  62.92  1.04  310      up
18    ssd  0.21790   1.00000  223 GiB  122 GiB  122 GiB  738 KiB   65 MiB  101 GiB  54.85  0.90  157      up
19    ssd  0.21790   1.00000  223 GiB  122 GiB  122 GiB  409 KiB   53 MiB  101 GiB  54.60  0.90  150      up
20    ssd  0.21790   1.00000  223 GiB  136 GiB  135 GiB  709 KiB   73 MiB   88 GiB  60.74  1.00  149      up
21    ssd  0.21790   1.00000  223 GiB  121 GiB  121 GiB  709 KiB   77 MiB  102 GiB  54.36  0.90  132      up
22    ssd  0.43629   1.00000  447 GiB  275 GiB  274 GiB  3.3 MiB  246 MiB  172 GiB  61.49  1.01  279      up
23    ssd  0.43629   1.00000  447 GiB  268 GiB  268 GiB  358 KiB  148 MiB  179 GiB  60.01  0.99  301      up
12    ssd  0.21790   1.00000  223 GiB  125 GiB  124 GiB  716 KiB   98 MiB   99 GiB  55.79  0.92  154      up
13    ssd  0.21790   1.00000  223 GiB  128 GiB  128 GiB  661 KiB  135 MiB   95 GiB  57.40  0.95  135      up
14    ssd  0.21790   1.00000  223 GiB  136 GiB  135 GiB  657 KiB  235 MiB   88 GiB  60.77  1.00  137      up
15    ssd  0.21790   1.00000  223 GiB  122 GiB  121 GiB  430 KiB  644 MiB  101 GiB  54.54  0.90  150      up
16    ssd  0.43629   1.00000  447 GiB  252 GiB  252 GiB  3.3 MiB  285 MiB  195 GiB  56.45  0.93  294      up
17    ssd  0.43629   1.00000  447 GiB  278 GiB  277 GiB  431 KiB  404 MiB  169 GiB  62.20  1.03  303      up
                       TOTAL  5.0 TiB  3.0 TiB  3.0 TiB   17 MiB  3.8 GiB  2.0 TiB  60.65
MIN/MAX VAR: 0.90/1.22  STDDEV: 5.35
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
=== Final OSD Status in 10 seconds (ceph osd df) ===
ID  CLASS  WEIGHT   REWEIGHT  SIZE     RAW USE  DATA     OMAP     META     AVAIL    %USE   VAR   PGS  STATUS
 0    ssd  0.21790   1.00000  223 GiB  110 GiB  110 GiB  2.0 MiB   65 MiB  114 GiB  49.12  0.84  132      up
 1    ssd  0.21790   1.00000  223 GiB  134 GiB  134 GiB  166 KiB  271 MiB   89 GiB  60.00  1.03  159      up
 2    ssd  0.21790   1.00000  223 GiB  149 GiB  149 GiB  767 KiB  139 MiB   74 GiB  66.64  1.14  149      up
 3    ssd  0.21790   1.00000  223 GiB  138 GiB  137 GiB  1.1 MiB  233 MiB   85 GiB  61.71  1.06  152      up
 4    ssd  0.43629   1.00000  447 GiB  264 GiB  263 GiB  2.1 MiB  436 MiB  183 GiB  59.02  1.01  305      up
 5    ssd  0.43629   1.00000  447 GiB  251 GiB  251 GiB  1.1 MiB  420 MiB  196 GiB  56.18  0.96  271      up
18    ssd  0.21790   1.00000  223 GiB  122 GiB  122 GiB  738 KiB   66 MiB  101 GiB  54.85  0.94  157      up
19    ssd  0.21790   1.00000  223 GiB  122 GiB  122 GiB  409 KiB   54 MiB  101 GiB  54.60  0.94  149      up
20    ssd  0.21790   1.00000  223 GiB  136 GiB  135 GiB  709 KiB   73 MiB   88 GiB  60.74  1.04  149      up
21    ssd  0.21790   1.00000  223 GiB  121 GiB  121 GiB  709 KiB   78 MiB  102 GiB  54.33  0.93  131      up
22    ssd  0.43629   1.00000  447 GiB  275 GiB  274 GiB  3.3 MiB  248 MiB  172 GiB  61.49  1.05  279      up
23    ssd  0.43629   1.00000  447 GiB  268 GiB  268 GiB  358 KiB  149 MiB  179 GiB  60.01  1.03  301      up
12    ssd  0.21790   1.00000  223 GiB  125 GiB  124 GiB  716 KiB   98 MiB   99 GiB  55.79  0.96  154      up
13    ssd  0.21790   1.00000  223 GiB  128 GiB  128 GiB  661 KiB  135 MiB   95 GiB  57.40  0.98  135      up
14    ssd  0.21790   1.00000  223 GiB  136 GiB  135 GiB  657 KiB  240 MiB   88 GiB  60.78  1.04  137      up
15    ssd  0.21790   1.00000  223 GiB  122 GiB  121 GiB  430 KiB  644 MiB  101 GiB  54.54  0.93  150      up
16    ssd  0.43629   1.00000  447 GiB  252 GiB  252 GiB  3.3 MiB  286 MiB  195 GiB  56.45  0.97  294      up
17    ssd  0.43629   1.00000  447 GiB  278 GiB  277 GiB  431 KiB  408 MiB  169 GiB  62.20  1.07  303      up
                       TOTAL  5.2 TiB  3.1 TiB  3.1 TiB   20 MiB  3.9 GiB  2.2 TiB  58.38
MIN/MAX VAR: 0.84/1.14  STDDEV: 3.95
```