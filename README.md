#sendaudio
Dirty bash script for (possibly reencoding and) sending music albums to Phone (or pretty much any device) via sshfs

* If bitrate of source is lower than 320k, just copies, otherwise, encodes to vorbis with highest quality
* Sends image files found along with audiofiles (primarily for cover.* files)
* Sends nested directories with audiofiles as well (for albums with multiple CDs/Sides) 

##Usage
```
sendaudio.sh dir1 dir2 dir3
```

##Notes
* Uses arcfour for ssh by default for speed improvements. However, it can be disabled by default in sshd, so it must be disabled in sshd_config manually OR disabled in `$SSH_Options`
* Host is defined in .ssh/config 
