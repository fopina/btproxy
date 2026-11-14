//go:build linux

package bluez

import (
	"sync"
	"testing"
	"time"

	"github.com/yuzi-co/btproxy/internal/ble"
	"github.com/yuzi-co/btproxy/internal/ble/bletest"
)

const fakeKeyboard = fakeAdapter + "/dev_F2_22_26_24_29_82"

// gapOptions has scan gaps every 200 ms that last 100 ms.
func gapOptions(opt Options) Options {
	opt = testOptions(opt)
	opt.gapEvery, opt.gapLen = 200*time.Millisecond, 100*time.Millisecond
	return opt
}

// While a bonded keyboard is not connected, discovery stops now and then so that the kernel's own scan can
// see its directed advertisements; the scan is reported running throughout. Once it is connected, the gaps
// stop.
func TestGapsWhileAKeyboardIsAway(t *testing.T) {
	addr := startBus(t)
	bz := startFakeBlueZ(t, addr, false)
	defer bz.bus.Close()
	bz.addHID(fakeKeyboard, false)
	a, err := Open("hci0", gapOptions(Options{}))
	if err != nil {
		t.Fatal(err)
	}
	a.SetScanMode(ble.ScanActive)
	stop, _ := a.Scan(func(ble.Advert) {})
	defer stop()
	bletest.WaitFor(t, "running", statusIs(a, ble.ScanRunning, ble.ScanActive))

	var mu sync.Mutex
	var states []ble.ScanStatus
	a.OnScanStatus(func(s ble.ScanStatus) {
		mu.Lock()
		states = append(states, s)
		mu.Unlock()
	})
	bletest.WaitFor(t, "three gaps", func() bool { _, stops := bz.calls(); return stops >= 3 })
	mu.Lock()
	for _, s := range states {
		if s != (ble.ScanStatus{State: ble.ScanRunning, Mode: ble.ScanActive}) {
			t.Errorf("status %v during the gaps", s)
		}
	}
	mu.Unlock()
	bletest.WaitFor(t, "scanning after a gap", func() bool { _, discovering, _ := bz.state(); return discovering })

	bz.mu.Lock()
	bz.hid[fakeKeyboard] = true
	bz.mu.Unlock()
	time.Sleep(300 * time.Millisecond) // a gap that had begun ends
	_, before := bz.calls()
	time.Sleep(time.Second)
	if _, after := bz.calls(); after != before {
		t.Errorf("%d gaps with the keyboard connected", after-before)
	}
}

// Without a bonded HID device there is nothing to wait for, and no gaps.
func TestNoGapsWithoutAKeyboard(t *testing.T) {
	addr := startBus(t)
	bz := startFakeBlueZ(t, addr, false)
	defer bz.bus.Close()
	a, err := Open("hci0", gapOptions(Options{}))
	if err != nil {
		t.Fatal(err)
	}
	a.SetScanMode(ble.ScanActive)
	stop, _ := a.Scan(func(ble.Advert) {})
	defer stop()
	bletest.WaitFor(t, "running", statusIs(a, ble.ScanRunning, ble.ScanActive))
	time.Sleep(time.Second)
	if _, stops := bz.calls(); stops != 0 {
		t.Errorf("%d gaps", stops)
	}
}

// Gaps do not restart the stall watchdog: a scan that delivers nothing is still caught, and recovered.
func TestGapsKeepTheStallWatchdog(t *testing.T) {
	addr := startBus(t)
	bz := startFakeBlueZ(t, addr, false)
	defer bz.bus.Close()
	bz.addHID(fakeKeyboard, false)
	off := make(chan struct{}, 8)
	bz.mu.Lock()
	bz.onPowerOff = func() { off <- struct{}{} }
	bz.mu.Unlock()
	a, err := Open("hci0", gapOptions(Options{WatchdogOptions: ble.WatchdogOptions{StallTimeout: 600 * time.Millisecond}}))
	if err != nil {
		t.Fatal(err)
	}
	a.SetScanMode(ble.ScanActive)
	stop, _ := a.Scan(func(ble.Advert) {})
	defer stop()
	select {
	case <-off:
	case <-time.After(5 * time.Second):
		t.Fatal("no power cycle: the gaps hid the stall")
	}
}
