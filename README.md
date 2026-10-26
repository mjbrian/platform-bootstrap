# platform-bootstrap

# greenfield
Here's the commands to go from 0 to initial bootstrap
## mac os
```bash xcode-select --install```
## linux, ubuntu or debian
```bash sudo apt install git curl libsecret-tools```
## windows
- install WSL2 with ubuntu, then follow the linux install

## generate the mise lockfile
[see]("# generate/update the lock file")

# generate/update the lock file
./bootstrap.sh --lock
> never write the lock file by hand, update mise.toml and re-run the bootstrap script
