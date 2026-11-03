# platform-bootstrap

One command builds the lab, one cluster at a time.

## First time on a new Mac

1. * macOS: run xcode-select --install.
   * Linux: install git, curl,libsecret-tools and Docker Engine.
   * Windows: use WSL2 with Ubuntu.
2. Run ./bootstrap.sh dev and approve GitHub in your browser once.

## Build or repair a cluster

    ./bootstrap.sh dev
    ./bootstrap.sh prod

## Tear down

    ./bootstrap.sh --destroy dev    # one cluster
    ./bootstrap.sh --destroy        # every cluster and Floci

## Switch a cluster's profile

    ./bootstrap.sh prod --profile observability

## Rebuild times

| Date | Cluster | Seconds | Notes |
| --- | --- | --- | --- |
