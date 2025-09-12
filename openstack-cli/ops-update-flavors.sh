openstack flavor delete pgpu.example
openstack flavor delete vgpu.example
openstack flavor delete t2.micro
openstack flavor delete t2.pico
openstack flavor delete t2.nano
openstack flavor create --vcpus 8 --ram 8192 --disk 200 --property hw:cpu_cores=8 --public appfw.medium
openstack flavor create --vcpus 12 --ram 12288 --disk 200 --property hw:cpu_cores=12 --public appfw.large
openstack flavor create --vcpus 16 --ram 16384 --disk 200 --property hw:cpu_cores=16 --public appfw.xlarge
openstack flavor create --vcpus 1 --ram 1024 --disk 60 --public a1.micro
openstack flavor create --vcpus 2 --ram 2048 --disk 60 --public a1.small
openstack flavor create --vcpus 4 --ram 4096 --disk 60 --property hw:cpu_cores=4 --public a1.medium
openstack flavor create --vcpus 8 --ram 8192 --disk 60 --property hw:cpu_cores=8 --public a1.large
openstack flavor create --vcpus 16 --ram 16384 --disk 60 --property hw:cpu_threads=2 --property hw:cpu_cores=16 --public a1.xlarge
openstack flavor create --vcpus 32 --ram 32768 --disk 60 --property hw:cpu_threads=2 --property hw:cpu_cores=32 --public a1.2xlarge
openstack flavor create --vcpus 1 --ram 1024 --disk 120 --public a2.micro
openstack flavor create --vcpus 2 --ram 2048 --disk 120 --public a2.small
openstack flavor create --vcpus 4 --ram 4096 --disk 120 --property hw:cpu_cores=4 --public a2.medium
openstack flavor create --vcpus 8 --ram 8192 --disk 120 --property hw:cpu_cores=8 --public a2.large
openstack flavor create --vcpus 16 --ram 16384 --disk 120 --property hw:cpu_threads=2 --property hw:cpu_cores=16 --public a2.xlarge
openstack flavor create --vcpus 32 --ram 32768 --disk 120 --property hw:cpu_threads=2 --property hw:cpu_cores=32 --public a2.2xlarge