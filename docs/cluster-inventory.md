# Cluster inventory

Collected on 2026-10-28 from the master node.

## Topology

| Node | Role | Internal IP | OS | Kernel | Runtime | CPU | Memory | Disk |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| master | control-plane | 172.31.6.211 | Ubuntu 22.04.5 LTS | 5.15.0-173-generic | containerd 2.4.2 | 4 vCPU | 15 GiB | 178 GiB |
| node | worker | 172.31.12.103 | Ubuntu 22.04.5 LTS | 5.15.0-173-generic | containerd 2.4.2 | unknown | 3.6 GiB | 50 GiB |

Kubernetes version: v1.34.1. Both nodes report Ready.

## Installed components

- kube-apiserver, etcd, kube-controller-manager, kube-scheduler
- CoreDNS, 2 replicas
- kube-proxy, one pod per node
- Flannel CNI, one pod per node
- No application workloads
- No PersistentVolume or PersistentVolumeClaim
- No StorageClass
- metrics-server is not installed

## Network findings

- Docker Hub is not reachable from the master: connection to registry-1.docker.io timed out.
- `ghcr.io` is reachable: Flannel images were pulled from GHCR.
- `registry.aliyuncs.com/google_containers` is reachable and is used for Kubernetes images.
- Huawei SWR endpoint responds, but the tested public mirror path required authentication.

Design decision: publish the demo image to GHCR through GitHub Actions. The cluster can pull it without depending on Docker Hub.

## Capacity notes

The worker has about 3.6 GiB RAM, so monitoring components must use small resource requests. Do not install a full observability stack without checking requests and limits.

## Current gaps

- No CI/CD pipeline is connected to the cluster yet.
- No Prometheus rules or Alertmanager configuration.
- No application image has been built.
- No rollback drill has been performed.
- No ingress controller.
- No storage class.

These gaps are intentional. They are the next milestones for the interview project.

## Interview summary

I built a two-node Kubernetes lab on Huawei Cloud and local virtual machines, with one control-plane node and one worker. I verified both nodes were Ready, checked the control-plane components, CNI, CoreDNS and kube-proxy, and documented the cluster capacity and network constraints. Docker Hub was not reachable, so I chose GHCR as the image registry because the cluster could already pull GHCR images. I then structured the next phase around CI/CD, observability and controlled failure drills.
