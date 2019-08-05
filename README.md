# azk

Create Azure Kubernetes clusters.

## Installation

```
make install
```

## Usage

To create a new cluster, first create a configuration file
(see [example-config.yaml](example-config.yaml)). Then run

```
azk create ./config.yaml --confirm
```

To delete the cluster:

```
azk delete mycluster01
```

## License

[MIT](LICENSE)
