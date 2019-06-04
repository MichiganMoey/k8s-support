local exp = import '../experiments/library.jsonnet';

local nodeinfoconfig = import '../../../config/nodeinfo/config.jsonnet';
local nodeinfo_datatypes = [d.Datatype for d in nodeinfoconfig];

exp.ExperimentNoNetwork('host', nodeinfo_datatypes) + {
  spec+: {
    template+: {
      spec+: {
        containers+: [
          {
            name: 'nodeinfo',
            image: 'measurementlab/nodeinfo:v1.2',
            args: [
              '-datadir=/var/spool/nodeinfo',
              '-wait=1h',
              '-prometheusx.listen-address=127.0.0.1:9990',
              '-config=/etc/nodeinfo/config.json',
            ],
            volumeMounts: [
              {
                mountPath: '/etc/nodeinfo',
                name: 'nodeinfo-config',
              },
            ] + [exp.VolumeMount('nodeinfo', d) for d in nodeinfo_datatypes],
          },
          exp.RBACProxy('nodeinfo', 9990),
        ],
        hostNetwork: true,
        hostPID: true,
        volumes+: [
          {
            configMap: {
              name: 'nodeinfo-config',
            },
            name: 'nodeinfo-config',
          },
        ],
      },
    },
  },
}
