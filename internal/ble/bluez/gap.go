//go:build linux

package bluez

import (
	"slices"
	"time"

	"github.com/godbus/dbus/v5"

	"github.com/yuzi-co/btproxy/internal/ble"
)

// Scan gaps let bonded keyboards and mice reconnect while the proxy scans actively.
//
// Such a device reconnects by sending directed advertisements to the adapter's own address, and the kernel
// connects when its background scan, a passive one with the adapter's own address, sees them. Active
// discovery replaces that scan and uses a random address, so the controller drops directed advertisements
// aimed at the real one: seen with a Lofree Flow84 keyboard on an Intel Wireless-AC 3168, which got back in
// only when the proxy happened to stop discovery for a connect. So while a bonded HID device is not
// connected, the supervisor stops discovery for gapLen every gapEvery and lets the kernel's own scan run.
//
// A local keyboard matters more than the advertisements of devices around, so the defaults (1 s of every 2 s)
// halve active scanning while one is away. The active stretches stay under 1.28 s, the longest burst of
// high duty cycle directed advertising a device may send, so every such burst meets a gap, even from a device
// that sends only one before it gives up. The advertisements lost meanwhile are mostly delayed, not missed:
// devices repeat them.

// hidUUID is the HID over GATT service, which BlueZ connects again on its own once a device is bonded.
const hidUUID = "00001812-0000-1000-8000-00805f9b34fb"

// gap runs the scan gaps and tells whether one runs now; the caller then leaves scanning off. The
// supervisor's own, like the fields it uses.
func (a *Adapter) gap(want bool) bool {
	if a.tm.gapEvery <= 0 {
		return false
	}
	now := time.Now()
	if !a.gapUntil.IsZero() {
		if want && now.Before(a.gapUntil) {
			return true
		}
		a.gapUntil = time.Time{}
		a.gapRearm = want
		a.gapAt = now.Add(a.tm.gapEvery)
		a.kickAfter(a.tm.gapEvery)
		return false
	}
	if !want || !a.armed || a.armedMode != ble.ScanActive {
		a.gapAt = time.Time{}
		return false
	}
	if a.gapAt.IsZero() {
		a.gapAt = now.Add(a.tm.gapEvery)
		a.kickAfter(a.tm.gapEvery)
		return false
	}
	if now.Before(a.gapAt) {
		return false
	}
	a.gapAt = now.Add(a.tm.gapEvery)
	if !a.hidWaiting() {
		a.kickAfter(a.tm.gapEvery)
		return false
	}
	a.log.Debug("scan gap for a bonded device to reconnect")
	a.disarm()
	a.gapUntil = now.Add(a.tm.gapLen)
	a.kickAfter(a.tm.gapLen)
	return true
}

// kickAfter has the supervisor run again after d.
func (a *Adapter) kickAfter(d time.Duration) {
	if a.gapTimer == nil {
		a.gapTimer = time.AfterFunc(d, a.kickScan)
		return
	}
	a.gapTimer.Reset(d)
}

// hidWaiting tells whether a bonded HID device is not connected. The list of those devices is read again
// every hidRefresh; their Connected property every time, which costs a call per device.
func (a *Adapter) hidWaiting() bool {
	if a.hidRead.IsZero() || time.Since(a.hidRead) >= a.tm.hidRefresh {
		objs, err := a.managedObjects()
		if err != nil {
			return false
		}
		a.hidRead = time.Now()
		a.hidDevs = a.hidDevs[:0]
		waiting := false
		for p, ifs := range objs {
			props, ok := ifs[ifDevice]
			if !ok || !a.underAdapter(p) || !bonded(props) {
				continue
			}
			if uuids, _ := props["UUIDs"].Value().([]string); !slices.Contains(uuids, hidUUID) {
				continue
			}
			a.hidDevs = append(a.hidDevs, p)
			if c, _ := props["Connected"].Value().(bool); !c {
				waiting = true
			}
		}
		return waiting
	}
	for _, p := range a.hidDevs {
		if v, err := a.getProperty(p, ifDevice+".Connected"); err == nil && v.Value() == false {
			return true
		}
	}
	return false
}

// bonded tells whether Device1 properties show a bond: Bonded where BlueZ has it, Paired in older versions.
func bonded(props map[string]dbus.Variant) bool {
	v, ok := props["Bonded"]
	if !ok {
		v = props["Paired"]
	}
	b, _ := v.Value().(bool)
	return b
}
