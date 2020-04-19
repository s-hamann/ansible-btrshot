btrshot
=======

This role configures automatic periodic snapshots of btrfs filesystems.

Requirements
------------

This role requires Ansible 2.5 but has no further requirements on the controller.

Role Variables
--------------

* `btrshot_snapshot`  
  Subvolumes to set up automatic snapshots for.
  Structured as a dictionary where keys are devices and values are lists of subvolumes on the respective devices.
  Defaults to all btrfs subvolumes mounted at run time.
* `btrshot_no_snapshot`  
  Subvolumes not to set up automatic snapshots for.
  Structured as a dictionary where keys are devices and values are lists of subvolumes on the respective devices.
  Optional.
* `btrshot_snapshot_frequency`  
  When to do periodic btrfs snapshots.
  This variable is a dictionary with keys that are used to group snapshots.
  Note that for the purpose of grouping snapshots the key is used only up to the first `%` while for the purpose of identifying cron jobs the full key is used.
  The values can be a time specification as understood by cron or the special keywords `hourly`, `daily`, `weekly` or `monthly`.
  The default consists of the aforementioned special keywords as keys *and* values.
* `btrshot_snapshot_keep`  
  How many old snapshots to keep when creating a new snapshot.
  This variable is a dictionary with the same keys (up to the first `%`) as `btrshot_snapshot_frequency`.
  The values are integers that specify the total number of snapshots to keep for the respective interval.
  Defaults to keeping 24 hourlies, 7 dailies, 4 weeklies and 3 monthlies.

Dependencies
------------

This role creates cron jobs and therefore depends on a running cron daemon on the target system.
While most Linux distributions come with some cron implementation pre-installed, it may occasionally require further setup using a separate role.

Example Configuration
---------------------

The following is a short example for some of the configuration options this role provides:

```yaml
btrshot_snapshot:
  /dev/sda1:
    - /root
    - /home
  /dev/sda2:
    - /var/log
btrshot_snapshot_frequency:
    hourly: '0 * * * *'
    daily: '0 0 * * *'
    daily%sunday_special: '0 1 * * sun'
    weekly: weekly
```

License
-------

MIT
