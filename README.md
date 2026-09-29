# iperf-cable-tester

Turn a Raspberry Pi 4/5 (Raspberry Pi OS) or a PiKVM into an always-on iperf3 peer for checking whether a LAN cable run really carries gigabit.

A cable tester only proves continuity: all eight wires go through. It does not tell you whether the run actually delivers 1 Gbit/s. Only a throughput test does, and that needs something at the other end to talk to. This project makes that something: a small box that you plug into one end of the run while your laptop sits at the other.

- The Pi starts an iperf3 server at boot (port 5201).
- Its Ethernet port always carries the fixed link-local address `169.254.99.1`. A laptop on a bare cable (no router, no DHCP) reaches it without any configuration, because Windows (APIPA) and macOS assign themselves a `169.254.x.x` address when no DHCP answer arrives.
- On a normal LAN the Pi also gets an address via DHCP.
- It never serves DHCP itself, so it is safe to plug into someone else's network.

Languages: English (this file), [Deutsch](README.de.md).

## Hardware

- **Raspberry Pi 4 or 5.** A Pi 3B+ manages only about 300 Mbit/s, older models 100 Mbit/s. That would look exactly like a bad cable, so do not use them.
- **The laptop needs a gigabit port as well.** Some USB-C Ethernet adapters are 100 Mbit/s only. The client scripts show the link speed of the laptop's interface.
- A short patch cable, and a power supply for the Pi.

## Setup

Pick the variant that matches the device. Run it once; both scripts are safe to run again.

### Raspberry Pi OS (Bookworm or newer, NetworkManager)

On the Pi, with internet access:

```
sudo bash server/setup-raspberry-pi-os.sh
sudo reboot
```

The hostname defaults to `iperf-peer`; change it with `--hostname NAME` or `HOSTNAME_NEW=name`. The script:

- installs iperf3 and starts it as a systemd service (`lantester-iperf3`);
- creates two NetworkManager profiles on `eth0`: DHCP first (20 s timeout), and if no address arrives, the fixed `169.254.99.1/16`;
- disables (but does not delete) other wired profiles, so a running SSH session over the cable does not drop. Everything takes effect after the reboot.

After the reboot the Pi answers at `169.254.99.1` on a bare cable, and at its DHCP address or `iperf-peer.local` on a network.

Caveat: NetworkManager ignores carrier loss shorter than about 6 seconds. When you move the Pi from one network to another, unplug the cable for at least 10 seconds or reboot, otherwise it may keep the old address and skip the fallback. With the fallback working, the fixed address is active about 22 seconds after link-up.

### PiKVM (Arch Linux ARM, read-only root, systemd-networkd)

Run `pikvm-update` first (and reboot if asked). Partial upgrades on Arch can break things, so the script deliberately does not update the system itself.

Then, as root on the PiKVM (use your PiKVM credentials):

```
bash server/setup-pikvm.sh
```

The script checks that it is running on a PiKVM, switches the root filesystem to writable (`rw`), installs iperf3, installs the `lantester-iperf3` service, adds a systemd-networkd drop-in `/etc/systemd/network/eth0.network.d/lantester.conf` with `Address=169.254.99.1/16` (the package's own `eth0.network` stays untouched), and switches back to read-only (`ro`) on exit, even after an error. The address is added next to whatever DHCP provides. No reboot needed.

## Measuring

The client scripts run 10 seconds in each direction and print the receiver figure. Get iperf3 for the laptop first:

- Windows: a build such as https://github.com/ar51an/iperf3-win-builds/releases (unzip, put `client/lantest.cmd` in the same folder as `iperf3.exe`).
- macOS: `brew install iperf3`.
- Linux: `apt install iperf3` or your distribution's equivalent.

### Bare cable (no router)

1. Put the Pi at one end of the run, the laptop at the other. Turn Wi-Fi off on the laptop.
2. Power on the Pi and wait a minute or two. With no DHCP answer, the laptop gives itself a `169.254.x.x` address (about 30 s after plugging in), which puts it in the same network as the Pi. Nothing needs to be configured.
3. Run the client script (below).

### Through switches (normal network)

Plug the Pi into the wall socket or switch; the laptop is on the network as usual. Pass the Pi's DHCP address (from the router's lease list, or `iperf-peer.local`) to the script. Using `169.254.99.1` works only if the laptop also has a direct `169.254` route, which is usually not the case on a routed network.

### Windows

Double-click `client/lantest.cmd`, or from a command prompt:

```
lantest.cmd                  rem bare cable, target 169.254.99.1
lantest.cmd 192.168.1.50     rem Pi on a normal network
```

`iperf3.exe` must be in the same folder. The script also lists the laptop's link speeds.

### macOS and Linux

```
client/lantest.sh                  # target 169.254.99.1
client/lantest.sh 192.168.1.50     # Pi on a normal network
```

It shows which interface the target is reached through, warns if that is Wi-Fi, shows the interface's link speed, runs both directions, and prints a one-line verdict. If the Pi is unreachable it exits non-zero with a hint. It works with the bash 3.2 that ships with macOS.

On macOS, `169.254.99.1` is reachable even on a normal DHCP network, because macOS keeps an on-link `169.254/16` route.

Measured example: a MacBook Air with a USB-C Ethernet adapter against a Raspberry Pi 4 over a 1 Gbit/s link gave 940 and 941 Mbit/s in the two directions to `169.254.99.1`, with 0 retransmits.

## Reading the results

The line to look at is the one ending in `receiver` at the end of each run.

| # | Result | Meaning |
|---|--------|---------|
| 1 | about 900-940 Mbit/s in both directions | Gigabit run is fine |
| 2 | about 94 Mbit/s, link shows 100 Mbit/s | The run links at 100 Mbit/s only, see below |
| 3 | Link shows 1 Gbit/s, throughput clearly below 900 | Interference on the run (crosstalk, bad socket or patching); with TCP it shows as many retransmits (`Retr`) |
| 4 | Very different per direction | Usually one wire pair with a problem, or an end device at its limit |

The Pi's own link speed: `ethtool eth0 | grep Speed` (on a PiKVM: `cat /sys/class/net/eth0/speed`).

## Link only at 100 Mbit/s

100BASE-TX uses only two of the four wire pairs (pins 1, 2, 3, 6). 1000BASE-T needs all four. So when a run links at only 100 Mbit/s, one of the pairs on pins 4/5 or 7/8 is almost always broken, swapped or untwisted too far. Or the run has a split pair, which a simple cable tester does not detect even though every single wire has continuity.

To cross-check, connect the Pi and the laptop directly to the two ends of the run, without a switch in between. If it links at 1 Gbit/s directly, the switch or a patch cable is at fault. If it also links at only 100 Mbit/s directly, the fault is in the installed run or the sockets.

## Security note

The iperf3 server listens on port 5201 without authentication. That is fine for a test device that is plugged in for a measurement. Do not leave it running on an untrusted network long term. The Pi does not route and does not serve DHCP.

## License

MIT, see [LICENSE](LICENSE).
