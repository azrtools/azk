# azk

Create Azure Kubernetes clusters.

## Installation

```
make install
```

## Usage

To create a new cluster, first create a configuration file
(see [example-config.json](example-config.json)). Then run

```
azk create ./config.json --confirm
```

To delete the cluster:

```
azk delete mycluster01
```

## License

[MIT](LICENSE)
