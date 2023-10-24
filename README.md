# testvm.sh
Quickly deploy/destroy a local Vagrant test VM (requires `vagrant` in `$PATH`).  

![](showcase.gif)

## Usage
```
$ ./testvm.sh  # (provisions a new test VM through Vagrant if none exist, then connects to it)
```
```
$ ./testvm.sh destroy  # (removes any existing test VMs & cleans up Vagrant tmp + box cache)
```
```
$ ./testvm.sh alpine  # (looks for the most popular Vagrant Cloud box matching 'alpine', provisions and connects to a new test VM with it)
```
