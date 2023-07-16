# testvm.sh
Quickly deploy/destroy a local Vagrant test VM (requires `vagrant` in `$PATH`).

## Usage
```
$ ./testvm.sh  # (provisions a new test VM through Vagrant if none exist, then connects to it)
```
```
$ ./testvm.sh destroy  # (removes any existing test VMs & cleans up Vagrant tmp + box cache)
```
