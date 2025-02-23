This repo contains all of the scripts and configs required to set up the
world-spanning M-Lab kubernetes (k8s) cluster.  The organization is as follows:

- [manage-cluster/](manager-cluster/) contains all the scripts necessary to set
  up and configure the cloud control plane node(s) as well as new nodes in
  Google cloud for monitoring services and the like.
- [config/](config/) contains service configuration files.
- [k8s/](k8s/) contains Kubernetes config files.
- [node/](node/) DEPRECATED. The files in this directory will eventually move to
  the ePoxy repository. Contains files to set up platform nodes and have them
  join the cluster.

# Kubernetes (k8s) architecture

In order to run, k8s needs:

1. A subnet
2. A VPN on that subnet that can be joined by both GCE and non-GCE machines
3. 3 distinct `etcd` instances running on different machines, all mutually backing each other up
4. An instance of `kube-apiserver`
5. An instance of `kube-controller-manager`

4. To run `kube-proxy` (maybe, hopefully not required)
5. To install `cri-containerd` to respond appropriately to commands to run a
   container
6. To install CNI and any relevant plugins to allocate IPs to containers
   appropriately

To deploy NDT pod:

1. Check <https://grafana.mlab-staging.measurementlab.net/d/K8-zAIuik/k8s-master-cluster?orgId=1&var-datasource=k8s%20platform%20(mlab-staging)&var-master=All>
1. cd manage-cluster
1. ./bootstrap_k8s_workloads.sh
1. kubectl get pods

# Upgrading the API cluster

As a general rule, we try to keep our clusters running a version of Kubernetes
not more than two minor version numbers behind the latest stable release.
Kubernetes development moves fast, and this means that we will be upgrading
Kubernetes at least a couple times per year. kubeadm does not support upgrading
an API cluster to more than the next minor version number. For these reasons it
is advisable to not fall too far behind.

The first step in the process of upgrading a cluster to a [newer version of
Kubernetes](https://github.com/kubernetes/kubernetes/releases) is to carefully
read the changelog for the version being upgraded to. It is probably not
important to read all the changelogs for patch-level version upgrades of the
minor version being upgraded to. For example, if the cluster is currently
running v1.18.15 and you want to upgrade to v1.19.12, you probably only need to
pay close attention to the changelog for v1.19.0, which should outline the
changes between v1.18.x and v1.19.0. The changelog between minor version should
have a section titled something like "Urgent Upgrade Notes (No, really, you
MUST read this before you upgrade)". As implied in the message, you should pay
extra close attention to changes noted in this section.  If you find any
breaking changes, then you will need to fix those before upgrading the cluster.
Also pay attention to non-breaking changes, such as deprecations, which might
not break the upgrade, but may affect the cluster later on. Even if you don't
address such issues now, consider creating an issue to note that they should be
addressed in the near future.

Along with Kubernetes, during an upgrade we also update CNI plugins and crictl.
The release pages for all components are these, respectively:

- <https://github.com/kubernetes/kubernetes/releases>
- <https://github.com/containernetworking/plugins/releases>
- <https://github.com/kubernetes-sigs/cri-tools/releases>

Be sure to read the release notes for these as well, as breaking changes could
exist in the newer versions of these.

`kubeadm` also publishes [upgrade
instructions](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/)
between minor releases. You should review that carefully, as sometimes there
are changes to Kubernetes or kubeadm itself that require additional steps.

Once you feel confident that any breaking changes have been addressed (or don't
exist), then you update the file `./manage-cluster/k8s_deploy.conf`, updating
these variables with the proper version strings:

- K8S\_VERSION
- K8S\_CNI\_VERSION
- K8S\_CRICTL\_VERSION

Once that file is updated and saved you do this:

```
cd manage-cluster
./upgrade_api_cluster.sh <project>
```

That command should upgrade the entire API cluster for the specified GCP
project. The script is designed to be idempotent, and if it failes for some
transitory reason or is otherwise interrupted, you can safely rerun it. If the
failure is persistent and rerunning the upgrade script does not fix it, then
you will need to address the issue manually in some way. `kubeadm` also
provides [some
documentation](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/#recovering-from-a-failure-state)
on recovering from a failed state.

Once the API cluster is successfully upgraded, you should double check that the
API cluster nodes report the correct version, and that all pods in the cluster
are running normally. You can do this with something like:

```
kubectl --context <project> get nodes | grep master-platform-cluster
kubectl --context <project> get pods --all-namespaces | grep -v Running
```

There should be no pods in a broken state that cannot be explained by some
other known issue.

It is advisable to upgrade the mlab-sandbox and mlab-staging clusters one week,
and then let that settle for a while, and not upgrade the mlab-oti (production)
cluster until at least the following week. Even if all the pods are ostensibly
running normally, this bit of extra time will help to ensure that a more subtle
problem isn't occuring. If something very subtle is wrong, then hopefully this
extra time before hitting production will allow an mlab-staging alert to fire,
or for someone to notice something is amiss.

**NOTE**: This process _only_ upgrades the API cluster. After the API cluster in
a project is updated, then you will still need to upgrade all the cluster
nodes. This is done in the [epoxy-images
repository](https://github.com/m-lab/epoxy-images) by [editing the same version
strings](https://github.com/m-lab/epoxy-images/blob/main/config.sh#L6) you
did for this repository, and then pushing to the epoxy-images repository.
Pushing to the repository (or tagging, for production) will cause all boot
images to be rebuilt, after which a rolling reboot of the cluster nodes should
cause them to boot with the upgraded versions of Kubernetes components.

# Running containers as non-root

The following table outlines which processes run as which uid:gid, as well as
which capabilities the process has and why. In the table, "root", "nobody"
and "nogroup" represents uid/gid 0, uid 65534 and gid 65534, respectively. Our
configs use uid and gid, but it's easier to think about the logical names, even
though they may differ between systems.  Additionally, in several cases,
capabilities are added to the binaries in the container, added as part of the
container image build process. These so called "file" capabilities are extended
filesystem attributes that the kernel reads when a binary is executed.

## Measurement services

```text
dash: nobody:nogroup
disco: nobody:nogroup
msak: nobody:nogroup
ndt-server: nobody:nogroup
ndt-server (virtual): root:nogroup (CAP_NET_BIND_SERVICE: to bind to port 80)
revtrvp nobody:nogroup (CAP_CHOWN, CAP_DAC_OVERRIDE, CAP_NET_RAW, CAP_SETGID, CAP_SETUID, CAP_SYS_CHROOT: scamper requires all of these to operate)
```

## Sidecar services

```text
access: root:nobody (CAP_NET_ADMIN, CAP_NET_RAW: needs to manipulate iptables rules)
heartbeat: nobody:nogroup
jostler: nobody:nogroup
nodeinfo: nobody:nogroup
packet-headers: nobody:nogroup (CAP_NET_RAW: so that it can do packet captures)
pusher: root:nobody (CAP_DAC_OVERRIDE: so that it can operate on files owned by other users)
tcp-info: nobody:nogroup
traceroute-caller: nobody:nogroup (CAP_DAC_OVERRIDE, CAP_NET_RAW, CAP_SETGID, CAP_SETUID, CAP_SYS_CHROOT: scamper requires these to operate)
uuid-annotator: nobody:nogroup
wehe: nobody:nogroup (CAP_NET_RAW: it needs to do packet captures)
```

## System services

```text
cadvisor: root:root (CAP_DAC_READ_SEARCH: allows it to read all the files it needs to gather data)
flannel: root:root (CAP_NET_ADMIN, CAP_NET_RAW: flannel needs to do various privileged network operations)
kube-rbac-proxy: nobody:nogroup
kured: root:root (privileged=true: https://github.com/m-lab/ops-tracker/issues/1653)
node-exporter: nobody:nogroup
vector: root:root (CAP_DAC_READ_SEARCH: so that it can read all the necessary log files)
```
