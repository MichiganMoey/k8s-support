local uuid = {
  initContainer: {
    // Write out the UUID prefix to a well-known location.
    // more on this, see DESIGN.md
    // https://github.com/m-lab/uuid/
    name: 'set-up-uuid-prefix-file',
    image: 'measurementlab/uuid:v0.1',
    args: [
      '-filename=' + uuid.prefixfile,
    ],
    volumeMounts: [
      uuid.volumemount {
        readOnly: false,
      },
    ],
  },
  prefixfile: '/var/local/uuid/prefix',
  volumemount: {
    mountPath: '/var/local/uuid',
    name: 'uuid-prefix',
    readOnly: true,
  },
  volume: {
    emptyDir: {},
    name: 'uuid-prefix',
  },
};

local volume(name, datatype) = {
  hostPath: {
    path: '/cache/data/' + name + '/' + datatype,
    type: 'DirectoryOrCreate',
  },
  name: datatype + '-data',
};

local VolumeMount(name, datatype) = {
  mountPath: '/var/spool/' + name + '/' + datatype,
  name: datatype + '-data',
};

local RBACProxy(name, port) = {
  name: 'kube-rbac-proxy-' + name,
  image: 'quay.io/coreos/kube-rbac-proxy:v0.4.1',
  args: [
    '--logtostderr',
    '--secure-listen-address=$(IP):' + port,
    '--upstream=http://127.0.0.1:' + port + '/',
  ],
  env: [
    {
      name: 'IP',
      valueFrom: {
        fieldRef: {
          fieldPath: 'status.podIP',
        },
      },
    },
  ],
  ports: [
    {
      containerPort: port,
    },
  ],
};

local ExperimentNoIndex(name, datatypes, hostNetworking) = {
  apiVersion: 'extensions/v1beta1',
  kind: 'DaemonSet',
  metadata: {
    name: name,
    namespace: 'default',
  },
  spec: {
    selector: {
      matchLabels: {
        workload: name,
      },
    },
    template: {
      metadata: {
        annotations: {
          'prometheus.io/scrape': 'true',
          'prometheus.io/scheme': if hostNetworking then 'https' else 'http',
        },
        labels: {
          workload: name,
        },
      },
      spec: {
        containers: [
          {
            name: 'tcpinfo',
            image: 'measurementlab/tcp-info:v0.0.8',
            args: [
              if hostNetworking then
                '-prometheusx.listen-address=127.0.0.1:9991'
              else
                '-prometheusx.listen-address=$(PRIVATE_IP):9991'
              ,
              '-output=' + VolumeMount(name, 'tcpinfo').mountPath,
              '-uuid-prefix-file=' + uuid.prefixfile,
            ],
            env: if hostNetworking then [] else [
              {
                name: 'PRIVATE_IP',
                valueFrom: {
                  fieldRef: {
                    fieldPath: 'status.podIP',
                  },
                },
              },
            ],
            ports: if hostNetworking then [] else [
              {
                containerPort: 9991,
              },
            ],
            volumeMounts: [
              VolumeMount(name, 'tcpinfo'),
              uuid.volumemount,
            ],
          },
          {
            name: 'traceroute',
            image: 'measurementlab/traceroute-caller:v0.0.5',
            args: [
              if hostNetworking then
                '-prometheusx.listen-address=127.0.0.1:9992'
              else
                '-prometheusx.listen-address=$(PRIVATE_IP):9992',
              '-outputPath=' + VolumeMount(name, 'traceroute').mountPath,
              '-uuid-prefix-file=' + uuid.prefixfile,
            ],
            env: if hostNetworking then [] else [
              {
                name: 'PRIVATE_IP',
                valueFrom: {
                  fieldRef: {
                    fieldPath: 'status.podIP',
                  },
                },
              },
            ],
            ports: if hostNetworking then [] else [
              {
                containerPort: 9992,
              },
            ],
            volumeMounts: [
              VolumeMount(name, 'traceroute'),
              uuid.volumemount,
            ],
          },
          {
            name: 'pusher',
            image: 'measurementlab/pusher:v1.8',
            args: [
              if hostNetworking then
                '-prometheusx.listen-address=127.0.0.1:9993'
              else
                '-prometheusx.listen-address=$(PRIVATE_IP):9993',
              '-experiment=' + name,
              '-archive_size_threshold=50MB',
              '-directory=/var/spool/' + name,
              '-datatype=tcpinfo',
              '-datatype=traceroute',
            ] + ['-datatype=' + d for d in datatypes],
            env: [
              {
                name: 'GOOGLE_APPLICATION_CREDENTIALS',
                value: '/etc/credentials/pusher.json',
              },
              {
                name: 'BUCKET',
                valueFrom: {
                  configMapKeyRef: {
                    key: 'bucket',
                    name: 'pusher-dropbox',
                  },
                },
              },
              {
                name: 'MLAB_NODE_NAME',
                valueFrom: {
                  fieldRef: {
                    fieldPath: 'spec.nodeName',
                  },
                },
              },
            ] + if hostNetworking then [] else [
              {
                name: 'PRIVATE_IP',
                valueFrom: {
                  fieldRef: {
                    fieldPath: 'status.podIP',
                  },
                },
              },
            ],
            ports: if hostNetworking then [] else [
              {
                containerPort: 9993,
              },
            ],
            volumeMounts: [
              VolumeMount(name, 'tcpinfo'),
              VolumeMount(name, 'traceroute'),
              {
                mountPath: '/etc/credentials',
                name: 'pusher-credentials',
                readOnly: true,
              },
            ] + [VolumeMount(name, d) for d in datatypes],
          },
        ] + if hostNetworking then [
          RBACProxy('tcpinfo', 9991),
          RBACProxy('traceroute', 9992),
          RBACProxy('pusher', 9993),
        ] else [],
        [if hostNetworking then 'serviceAccountName']: 'kube-rbac-proxy',
        initContainers: [
          uuid.initContainer,
        ],
        nodeSelector: {
          'mlab/type': 'platform',
        },
        volumes: [
          {
            name: 'pusher-credentials',
            secret: {
              secretName: 'pusher-credentials',
            },
          },
          uuid.volume,
          volume(name, 'traceroute'),
          volume(name, 'tcpinfo'),
        ] + [volume(name, d) for d in datatypes],
      },
    },
    updateStrategy: {
      rollingUpdate: {
        maxUnavailable: 2,
      },
      type: 'RollingUpdate',
    },
  },
};

local Experiment(name, index, datatypes=[]) = ExperimentNoIndex(name, datatypes, false) + {
  spec+: {
    template+: {
      metadata+: {
        annotations+: {
          'k8s.v1.cni.cncf.io/networks': '[{ "name": "index2ip-index-' + index + '-conf" }]',
          'v1.multus-cni.io/default-network': 'flannel-experiment-conf',
        },
      },
      spec+: {
        initContainers+: [
          // TODO: this is a hack. Remove the hack by fixing
          // contents of resolv.
          {
            name: 'fix-resolv-conf',
            image: 'busybox',
            command: [
              'sh',
              '-c',
              'echo "nameserver 8.8.8.8" > /etc/resolv.conf',
            ],
          },
        ],
      },
    },
  },
};

{
  // Returns a minimal experiment, suitable for adding a unique network config
  // before deployment. It is expected that most users of this library will use
  // Experiment().
  ExperimentNoIndex(name, datatypes, hostNetworking):: ExperimentNoIndex(name, datatypes, hostNetworking),

  // RBACProxy creates a https proxy for an http port. This allows us to serve
  // metrics securely over https, andto https-authenticate to only serve them to
  // ourselves.
  RBACProxy(name, port):: RBACProxy(name, port),

  // Returns all the trappings for a new experiment. New experiments should
  // need to add one new container.
  Experiment(name, index, datatypes):: Experiment(name, index, datatypes),

  // Returns a volumemount for a given datatype. All produced volume mounts
  // in /var/spool/name/
  VolumeMount(name, datatype):: VolumeMount(name, datatype),

  // Helper object containing uuid-related filenames, volumes, and volumemounts.
  uuid: uuid,
}
