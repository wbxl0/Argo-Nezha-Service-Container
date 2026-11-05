package geoip

import (
	"net"
	"os"
	"testing"
)

// TestLookup is a reporting test: it prints what the compiled database and the
// override table answer for a fixed set of addresses. Run it twice in CI, once
// without GEOIP_OVERRIDES and once with, to show the override in effect.
func TestLookup(t *testing.T) {
	addresses := []string{
		"13.140.248.54", // Contabo Asia (Tokyo) - country vs registered_country disagreement
		"8.8.8.8",       // control
		"1.1.1.1",       // control
	}
	for _, addr := range addresses {
		country, err := Lookup(net.ParseIP(addr))
		t.Logf("RESULT ip=%s country=%q err=%v overrides=%q", addr, country, err, os.Getenv("GEOIP_OVERRIDES"))
	}
}

func TestParseOverrides(t *testing.T) {
	entries := parseOverrides(" 13.140.248.0/24=JP ,, nonsense, 10.0.0.0/8=XX,1.2.3.4/32=")
	if len(entries) != 2 {
		t.Fatalf("expected 2 usable entries, got %d", len(entries))
	}
	if entries[0].country != "jp" || !entries[0].network.Contains(net.ParseIP("13.140.248.54")) {
		t.Fatalf("first entry wrong: %+v", entries[0])
	}
	if entries[1].country != "xx" {
		t.Fatalf("second entry wrong: %+v", entries[1])
	}
}
