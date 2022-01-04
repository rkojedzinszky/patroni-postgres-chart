# patroni-postgres-chart

## Quick installation

Create a `local.yaml` with desired values based on `values.yaml`. Then, create the namespace where patroni-postgres will be deployed:

```bash
$ kubectl create ns postgres
```

Then, install an instance with:

```bash
$ helm install -n postgres -f local.yml --set superuserpassword=$(pwgen -sB 16) --set replicationpassword=$(pwgen -sB 16) patroni-postgres .
```

