```
ubuntu@install-gpu:~$ sudo mig-setup
[INFO]  Detected model : PRO6000
[INFO]  Target GPU(s)  : 0

[INFO]  Checking existing MIG devices (nvidia-smi -L):
[INFO]  GPU 0: no MIG devices

Select action for PRO6000:
  1) 2xMIG -> 2 x 2g.48gb  (~47 GB, 94 SMs each)
  2) 4xMIG -> 4 x 1g.24gb  (~23 GB, 46 SMs each)
  3) Remove MIG (rollback)
  4) Quit
Choice [1-4]: 2

Plan:
  GPU 0 -> 4 x 1g.24gb  (~23 GB, 46 SMs each)
  + persistence mode on, layout recreated at every boot (mig-setup.service)

Proceed? [y/N] y

[INFO]  GPU 0: enabling persistence mode
[INFO]  ===== GPU 0 (PRO6000, 4xMIG) =====
[INFO]  GPU 0: enabling MIG mode
[INFO]  GPU 0: creating 1g.24gb,1g.24gb,1g.24gb,1g.24gb
Successfully created GPU instance ID  3 on GPU  0 using profile MIG 1g.24gb (ID 14)
Successfully created compute instance ID  0 on GPU  0 GPU instance ID  3 using profile MIG 1g.24gb (ID  0)
Successfully created GPU instance ID  4 on GPU  0 using profile MIG 1g.24gb (ID 14)
Successfully created compute instance ID  0 on GPU  0 GPU instance ID  4 using profile MIG 1g.24gb (ID  0)
Successfully created GPU instance ID  5 on GPU  0 using profile MIG 1g.24gb (ID 14)
Successfully created compute instance ID  0 on GPU  0 GPU instance ID  5 using profile MIG 1g.24gb (ID  0)
Successfully created GPU instance ID  6 on GPU  0 using profile MIG 1g.24gb (ID 14)
Successfully created compute instance ID  0 on GPU  0 GPU instance ID  6 using profile MIG 1g.24gb (ID  0)
[OK]    GPU 0 done.

[OK]    Boot service enabled: mig-setup.service
[INFO]  Saved boot layout (/etc/mig-setup.conf): 0:4

[INFO]  MIG devices:
GPU 0: NVIDIA RTX PRO 6000 Blackwell Server Edition (UUID: GPU-a0ff3a6a-bd06-3e5f-8b89-60a27303129e)
  MIG 1g.24gb     Device  0: (UUID: MIG-08f4e67c-1d07-5943-b4a7-ab0ac90b60ee)
  MIG 1g.24gb     Device  1: (UUID: MIG-fa5b5bd2-f9f1-5c0b-9404-f2c01cc67123)
  MIG 1g.24gb     Device  2: (UUID: MIG-0654f3dc-5deb-5330-a6c2-1f128676ea29)
  MIG 1g.24gb     Device  3: (UUID: MIG-48a35b9d-c6c2-5b6c-ab03-02ce75c1052f)

[OK]    All done. Persistence mode is on; layout will be recreated at boot by mig-setup.service.

```

```
ubuntu@install-gpu:~$ sudo mig-setup
[INFO]  Detected model : PRO6000
[INFO]  Target GPU(s)  : 0

[INFO]  Checking existing MIG devices (nvidia-smi -L):
[WARN]  GPU 0: MIG devices found
          MIG 1g.24gb     Device  0: (UUID: MIG-08f4e67c-1d07-5943-b4a7-ab0ac90b60ee)
          MIG 1g.24gb     Device  1: (UUID: MIG-fa5b5bd2-f9f1-5c0b-9404-f2c01cc67123)
          MIG 1g.24gb     Device  2: (UUID: MIG-0654f3dc-5deb-5330-a6c2-1f128676ea29)
          MIG 1g.24gb     Device  3: (UUID: MIG-48a35b9d-c6c2-5b6c-ab03-02ce75c1052f)
[INFO]  Saved boot layout: 0:4

Select action for PRO6000:
  1) 2xMIG -> 2 x 2g.48gb  (~47 GB, 94 SMs each)
  2) 4xMIG -> 4 x 1g.24gb  (~23 GB, 46 SMs each)
  3) Remove MIG (rollback)
  4) Quit
Choice [1-4]: 3

[INFO]  Current devices:
GPU 0: NVIDIA RTX PRO 6000 Blackwell Server Edition (UUID: GPU-a0ff3a6a-bd06-3e5f-8b89-60a27303129e)
  MIG 1g.24gb     Device  0: (UUID: MIG-08f4e67c-1d07-5943-b4a7-ab0ac90b60ee)
  MIG 1g.24gb     Device  1: (UUID: MIG-fa5b5bd2-f9f1-5c0b-9404-f2c01cc67123)
  MIG 1g.24gb     Device  2: (UUID: MIG-0654f3dc-5deb-5330-a6c2-1f128676ea29)
  MIG 1g.24gb     Device  3: (UUID: MIG-48a35b9d-c6c2-5b6c-ab03-02ce75c1052f)

[WARN]  Rollback will destroy ALL MIG instances, disable MIG mode and persistence mode on GPU(s): 0
[WARN]  Any saved boot layout for these GPU(s) will also be removed.
Proceed with rollback? [y/N] y

[INFO]  ===== GPU 0: rollback =====
[INFO]  GPU 0: destroying compute instances
[INFO]  GPU 0: destroying GPU instances
[INFO]  GPU 0: disabling MIG mode
[OK]    GPU 0: MIG disabled.
[INFO]  GPU 0: persistence mode disabled

[OK]    Boot service mig-setup.service removed.

[INFO]  Devices after rollback:
GPU 0: NVIDIA RTX PRO 6000 Blackwell Server Edition (UUID: GPU-a0ff3a6a-bd06-3e5f-8b89-60a27303129e)

[OK]    Rollback complete.
```